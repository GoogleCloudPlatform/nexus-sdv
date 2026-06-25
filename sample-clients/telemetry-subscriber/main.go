package main

import (
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/nats-io/nats.go"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"

	aaospb "telemetry-subscriber/aaos_telemetry"
	pb "telemetry-subscriber/telemetry"
)

// RegistrationResponse is returned by the registration server
type RegistrationResponse struct {
	Certificate string `json:"certificate"`
	KeycloakURL string `json:"keycloak_url"`
	NatsURL     string `json:"nats_url"`
}

// KeycloakTokenResponse contains the JWT token from Keycloak
type KeycloakTokenResponse struct {
	AccessToken      string `json:"access_token"`
	IDToken          string `json:"id_token,omitempty"`
	RefreshToken     string `json:"refresh_token,omitempty"`
	ExpiresIn        int    `json:"expires_in"`
	RefreshExpiresIn int    `json:"refresh_expires_in"`
	TokenType        string `json:"token_type"`
}

// TelemetrySubscriber handles subscribing to vehicle telemetry
type TelemetrySubscriber struct {
	VIN                   string
	pkiStrategy           string
	FactoryCertFile       string
	FactoryKeyFile        string
	RegistrationServerURL string
	Subject               string
	RecordDir             string
	operationalCert       *x509.Certificate
	operationalKey        *rsa.PrivateKey
	operationalCertPEM    []byte
	keycloakURL           string
	natsURL               string
	messageCount          int
	lastMessage           time.Time
}

func main() {
	defaultRegistrationURL := os.Getenv("REGISTRATION_URL_VALUE")

	vin := flag.String("vin", "VEHICLE001", "Vehicle Identification Number")
	pkiStrategy := flag.String("pki_strategy", "local", "PKI Strategy")
	factoryCert := flag.String("factory-cert", "", "Path to factory-issued certificate (required when registration is needed)")
	factoryKey := flag.String("factory-key", "", "Path to factory-issued private key (required when registration is needed)")
	registrationURL := flag.String("registration-url", defaultRegistrationURL, "Registration server URL (required when registration is needed)")
	keycloakURL := flag.String("keycloak-url", "", "Keycloak URL (used when reusing existing certificates)")
	natsURL := flag.String("nats-url", "", "NATS URL (used when reusing existing certificates)")
	subject := flag.String("subject", "telemetry.>", "NATS subject to subscribe to")
	recordDir := flag.String("record-dir", "", "Directory to record received messages for later replay (disabled if empty)")
	flag.Parse()

	subscriber := &TelemetrySubscriber{
		VIN:         *vin,
		pkiStrategy: *pkiStrategy,
		Subject:     *subject,
		RecordDir:   *recordDir,
	}

	log.Printf("================================================")
	log.Printf("Starting telemetry subscriber for VIN: %s", subscriber.VIN)
	log.Printf("Subject: %s", subscriber.Subject)
	if subscriber.RecordDir != "" {
		log.Printf("Recording to: %s", subscriber.RecordDir)
	}
	log.Printf("================================================")

	var jwt string

	// Try to reuse existing certificates and token
	if existingJWT, ok := subscriber.loadExistingCertsAndToken(); ok {
		log.Println("✓ Existing certificates and token are valid — skipping registration")
		if *keycloakURL == "" || *natsURL == "" {
			log.Fatal("-keycloak-url and -nats-url are required when reusing existing certificates")
		}
		subscriber.keycloakURL = *keycloakURL
		subscriber.natsURL = *natsURL
		jwt = existingJWT
	} else {
		// Full registration + auth flow
		log.Println("No valid existing certificates found — starting registration flow")
		if *factoryCert == "" || *factoryKey == "" {
			log.Fatal("-factory-cert and -factory-key are required for registration")
		}
		if *registrationURL == "" {
			log.Fatal("-registration-url is required for registration")
		}
		subscriber.FactoryCertFile = *factoryCert
		subscriber.FactoryKeyFile = *factoryKey
		subscriber.RegistrationServerURL = *registrationURL

		if err := subscriber.Register(); err != nil {
			log.Fatalf("Registration failed: %v", err)
		}
		log.Println("✓ Registered and obtained operational certificate")

		var err error
		jwt, err = subscriber.AuthenticateWithKeycloak()
		if err != nil {
			log.Fatalf("Keycloak authentication failed: %v", err)
		}
		log.Println("✓ Authenticated with Keycloak")
	}

	if err := subscriber.SubscribeToTelemetry(jwt); err != nil {
		log.Fatalf("NATS subscription failed: %v", err)
	}
}

// loadExistingCertsAndToken checks whether a valid operational certificate and
// unexpired JWT token already exist on disk. If both are valid it loads them
// into the subscriber and returns (token, true); otherwise it returns ("", false).
func (s *TelemetrySubscriber) loadExistingCertsAndToken() (string, bool) {
	certPEM, err := os.ReadFile("certificates/operational-cert.pem")
	if err != nil {
		log.Printf("No existing operational certificate: %v", err)
		return "", false
	}
	block, _ := pem.Decode(certPEM)
	if block == nil {
		log.Println("Could not decode existing operational certificate PEM")
		return "", false
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		log.Printf("Could not parse existing operational certificate: %v", err)
		return "", false
	}
	if time.Until(cert.NotAfter) < 60*time.Second {
		log.Printf("Operational certificate expired at %s", cert.NotAfter.Format(time.RFC3339))
		return "", false
	}

	keyPEM, err := os.ReadFile("certificates/operational-key.pem")
	if err != nil {
		log.Printf("No existing operational key: %v", err)
		return "", false
	}
	keyBlock, _ := pem.Decode(keyPEM)
	if keyBlock == nil {
		log.Println("Could not decode existing operational key PEM")
		return "", false
	}
	key, err := x509.ParsePKCS1PrivateKey(keyBlock.Bytes)
	if err != nil {
		log.Printf("Could not parse existing operational key: %v", err)
		return "", false
	}

	tokenBytes, err := os.ReadFile("certificates/oidc-access-token")
	if err != nil {
		log.Printf("No existing access token: %v", err)
		return "", false
	}
	token := strings.TrimSpace(string(tokenBytes))
	expiry := jwtExpiry(token)
	if time.Until(expiry) < 60*time.Second {
		log.Printf("Access token expired at %s", expiry.Format(time.RFC3339))
		return "", false
	}

	s.operationalCert = cert
	s.operationalCertPEM = certPEM
	s.operationalKey = key
	log.Printf("  Certificate valid until: %s", cert.NotAfter.Format(time.RFC3339))
	log.Printf("  Token valid until:       %s", expiry.Format(time.RFC3339))
	return token, true
}

// jwtExpiry decodes the exp claim from a JWT without verifying the signature.
func jwtExpiry(token string) time.Time {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return time.Time{}
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return time.Time{}
	}
	var claims map[string]interface{}
	if err := json.Unmarshal(payload, &claims); err != nil {
		return time.Time{}
	}
	exp, ok := claims["exp"].(float64)
	if !ok {
		return time.Time{}
	}
	return time.Unix(int64(exp), 0)
}

// Register performs the vehicle registration flow
func (s *TelemetrySubscriber) Register() error {
	log.Printf("************************************************")
	log.Println(" Starting client registration")
	log.Printf("************************************************")
	log.Println("Retrieving operational certificate...")

	// Generate a new RSA key pair for operational use
	privateKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return fmt.Errorf("failed to generate key pair: %w", err)
	}
	s.operationalKey = privateKey

	// Create a Certificate Signing Request (CSR)
	log.Println("Creating Certificate Signing Request (CSR)...")
	csrPEM, err := s.createCSR(privateKey)
	if err != nil {
		return fmt.Errorf("failed to create CSR: %w", err)
	}

	// Load factory certificate and key for mTLS
	log.Println("Loading factory-issued certificate for mTLS...")
	factoryCert, err := tls.LoadX509KeyPair(s.FactoryCertFile, s.FactoryKeyFile)
	if err != nil {
		return fmt.Errorf("failed to load factory certificate: %w", err)
	}

	// Load CA certificate for the registration server
	regServerCA, err := os.ReadFile("certificates/REGISTRATION_SERVER_TLS_CERT.pem")
	if err != nil {
		return fmt.Errorf("failed to load registration server CA: %w", err)
	}
	caCertPool := x509.NewCertPool()
	caCertPool.AppendCertsFromPEM(regServerCA)

	// Configure mTLS client
	tlsConfig := &tls.Config{
		Certificates:       []tls.Certificate{factoryCert},
		InsecureSkipVerify: s.pkiStrategy == "local",
		RootCAs:            caCertPool,
		MinVersion:         tls.VersionTLS12,
		MaxVersion:         tls.VersionTLS13,
		CurvePreferences:   []tls.CurveID{tls.X25519, tls.CurveP256, tls.CurveP384},
		GetClientCertificate: func(info *tls.CertificateRequestInfo) (*tls.Certificate, error) {
			log.Println("  Server requested client certificate")
			return &factoryCert, nil
		},
	}

	client := &http.Client{
		Transport: &http.Transport{
			TLSClientConfig: tlsConfig,
		},
		Timeout: 30 * time.Second,
	}

	// Send CSR to registration server
	log.Printf("Sending CSR to registration server at %s...", s.RegistrationServerURL)
	req, err := http.NewRequest("POST", s.RegistrationServerURL+"/registration", bytes.NewReader(csrPEM))
	if err != nil {
		return fmt.Errorf("failed to create registration request: %w", err)
	}
	req.Header.Set("Content-Type", "application/x-pem-file")

	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("failed to send registration request: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("failed to read registration response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("registration failed with status %d: %s", resp.StatusCode, string(body))
	}

	// Parse registration response
	var regResp RegistrationResponse
	if err := json.Unmarshal(body, &regResp); err != nil {
		return fmt.Errorf("failed to parse registration response: %w", err)
	}

	// Parse the operational certificate
	block, _ := pem.Decode([]byte(regResp.Certificate))
	if block == nil {
		return fmt.Errorf("failed to decode certificate PEM")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return fmt.Errorf("failed to parse certificate: %w", err)
	}

	s.operationalCert = cert
	s.operationalCertPEM = []byte(regResp.Certificate)
	s.keycloakURL = regResp.KeycloakURL
	s.natsURL = regResp.NatsURL

	log.Printf("  Keycloak URL: %s", s.keycloakURL)
	log.Printf("  NATS URL: %s", s.natsURL)
	log.Printf("  Certificate valid until: %s", cert.NotAfter)

	// Save operational certificate and key to files for reuse
	certDir := "certificates/"
	if err := os.WriteFile(certDir+"operational-cert.pem", s.operationalCertPEM, 0644); err != nil {
		log.Printf("Warning: Failed to save operational certificate: %v", err)
	} else {
		log.Println("  Saved operational certificate to operational-cert.pem")
	}

	keyPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "RSA PRIVATE KEY",
		Bytes: x509.MarshalPKCS1PrivateKey(s.operationalKey),
	})
	if err := os.WriteFile(certDir+"operational-key.pem", keyPEM, 0600); err != nil {
		log.Printf("Warning: Failed to save operational key: %v", err)
	} else {
		log.Println("  Saved operational key to operational-key.pem")
	}

	return nil
}

// createCSR generates a Certificate Signing Request
func (s *TelemetrySubscriber) createCSR(key *rsa.PrivateKey) ([]byte, error) {
	// The registration server expects CN in format: "VIN:xxx DEVICE:yyy"
	// and requires the CN to be encoded as UTF8String (not PrintableString).
	// Using pkix.Name.CommonName would produce PrintableString; instead we use
	// ExtraNames with an explicit asn1.RawValue to force UTF8String encoding.
	cn := fmt.Sprintf("VIN:%s DEVICE:%s", s.VIN, s.VIN)
	subject := pkix.Name{
		Organization: []string{"Vehicle Manufacturer"},
		ExtraNames: []pkix.AttributeTypeAndValue{
			{
				Type: asn1.ObjectIdentifier{2, 5, 4, 3}, // CN OID
				Value: asn1.RawValue{
					Tag:   asn1.TagUTF8String,
					Bytes: []byte(cn),
				},
			},
		},
	}

	template := x509.CertificateRequest{
		Subject:            subject,
		SignatureAlgorithm: x509.SHA256WithRSA,
	}

	csrDER, err := x509.CreateCertificateRequest(rand.Reader, &template, key)
	if err != nil {
		return nil, fmt.Errorf("failed to create CSR: %w", err)
	}

	csrPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "CERTIFICATE REQUEST",
		Bytes: csrDER,
	})

	return csrPEM, nil
}

// AuthenticateWithKeycloak obtains a JWT token using the operational certificate
func (s *TelemetrySubscriber) AuthenticateWithKeycloak() (string, error) {
	log.Println("Authenticating with Keycloak using operational certificate...")

	// Create TLS certificate from operational cert and key
	keyPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "RSA PRIVATE KEY",
		Bytes: x509.MarshalPKCS1PrivateKey(s.operationalKey),
	})

	cert, err := tls.X509KeyPair(s.operationalCertPEM, keyPEM)
	if err != nil {
		return "", fmt.Errorf("failed to create X509 key pair: %w", err)
	}

	// Load CA certificate for the Keycloak server
	keycloakCA, err := os.ReadFile("certificates/KEYCLOAK_TLS_CRT.pem")
	if err != nil {
		return "", fmt.Errorf("failed to load Keycloak CA: %w", err)
	}
	caCertPool := x509.NewCertPool()
	caCertPool.AppendCertsFromPEM(keycloakCA)

	// Configure mTLS client
	tlsConfig := &tls.Config{
		Certificates:       []tls.Certificate{cert},
		InsecureSkipVerify: false,
		RootCAs:            caCertPool,
		MinVersion:         tls.VersionTLS12,
		MaxVersion:         tls.VersionTLS13,
		CurvePreferences:   []tls.CurveID{tls.X25519, tls.CurveP256, tls.CurveP384},
		GetClientCertificate: func(info *tls.CertificateRequestInfo) (*tls.Certificate, error) {
			log.Println("  Keycloak requested client certificate")
			return &cert, nil
		},
	}

	client := &http.Client{
		Transport: &http.Transport{
			TLSClientConfig: tlsConfig,
		},
		Timeout: 30 * time.Second,
	}

	// Request JWT token from Keycloak
	log.Printf("Requesting JWT from Keycloak at %s...", s.keycloakURL)
	tokenURL := fmt.Sprintf("%s/realms/sdv-telemetry/protocol/openid-connect/token", s.keycloakURL)

	data := "grant_type=client_credentials&client_id=car&scope=openid+offline_access"

	req, err := http.NewRequest("POST", tokenURL, bytes.NewBufferString(data))
	if err != nil {
		return "", fmt.Errorf("failed to create token request: %w", err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("failed to request token: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("token request failed with status %d: %s", resp.StatusCode, string(body))
	}

	var tokenResp KeycloakTokenResponse
	if err := json.NewDecoder(resp.Body).Decode(&tokenResp); err != nil {
		return "", fmt.Errorf("failed to decode token response: %w", err)
	}

	log.Printf("  Token expires in: %d seconds", tokenResp.ExpiresIn)

	// Write the full token response as JSON to disk
	tokenJSON, err := json.MarshalIndent(tokenResp, "", "  ")
	if err != nil {
		log.Printf("  Warning: failed to marshal token response: %v", err)
	} else {
		if err := os.WriteFile("certificates/oidc-token.json", tokenJSON, 0600); err != nil {
			log.Printf("  Warning: failed to write OIDC token JSON to disk: %v", err)
		} else {
			log.Println("  OIDC token response written to certificates/oidc-token.json")
		}
	}

	// Write individual tokens to separate files for easy consumption
	tokenFiles := map[string]string{
		"certificates/oidc-access-token":  tokenResp.AccessToken,
		"certificates/oidc-id-token":      tokenResp.IDToken,
		"certificates/oidc-refresh-token": tokenResp.RefreshToken,
	}
	for path, token := range tokenFiles {
		if token == "" {
			continue
		}
		if err := os.WriteFile(path, []byte(token), 0600); err != nil {
			log.Printf("  Warning: failed to write %s: %v", path, err)
		} else {
			log.Printf("  Token written to %s", path)
		}
	}

	return tokenResp.AccessToken, nil
}

// formatHexDump returns a compact hex+ASCII dump, 16 bytes per line.
func formatHexDump(data []byte) string {
	var sb strings.Builder
	for i := 0; i < len(data); i += 16 {
		end := i + 16
		if end > len(data) {
			end = len(data)
		}
		chunk := data[i:end]
		// hex
		hexPart := hex.EncodeToString(chunk)
		// pad to 32 chars
		for len(hexPart) < 32 {
			hexPart += "  "
		}
		// ASCII
		ascii := make([]byte, len(chunk))
		for j, b := range chunk {
			if b >= 32 && b < 127 {
				ascii[j] = b
			} else {
				ascii[j] = '.'
			}
		}
		fmt.Fprintf(&sb, "  %04x  %s  %s\n", i, hexPart, string(ascii))
	}
	return sb.String()
}

// decodeAaosVehicleTelemetryData prints the fields of an AAOS VehicleTelemetryData message.
func decodeAaosVehicleTelemetryData(vtd *aaospb.VehicleTelemetryData) {
	fmt.Printf("  ENGINE_POWER:              %.2f W\n", vtd.GetENGINE_POWER())
	fmt.Printf("  ENGINE_RPM:                %.2f rpm\n", vtd.GetENGINE_RPM())
	fmt.Printf("  FUEL_CAPACITY:             %.2f L\n", vtd.GetFUEL_CAPACITY())
	fmt.Printf("  FUEL_LEVEL:                %.2f L\n", vtd.GetFUEL_LEVEL())
	fmt.Printf("  TIRE_PRESSURE:             %.2f bar\n", vtd.GetTIRE_PRESSURE())
	fmt.Printf("  VELOCITY:                  %.2f m/s\n", vtd.GetVELOCITY())
	fmt.Printf("  MAX_SPEED:                 %.2f m/s\n", vtd.GetMaxSpeed())
	fmt.Printf("  SPEEDLIMIT:                %.2f m/s\n", vtd.GetSpeedlimit())
	fmt.Printf("  acceleration_modulus_m_s2: %.4f m/s²\n", vtd.GetAccelerationModulusMS2())
	fmt.Printf("  distance_meters:           %d m\n", vtd.GetDistanceMeters())
	if vtd.IGNITION_STATE != nil {
		fmt.Printf("  IGNITION_STATE:            %v\n", vtd.GetIGNITION_STATE())
	}
	if vtd.LOCKED != nil {
		fmt.Printf("  LOCKED:                    %v\n", vtd.GetLOCKED())
	}
	if vtd.GPS_LATITUDE != nil {
		fmt.Printf("  GPS_LATITUDE:              %.6f\n", vtd.GetGPS_LATITUDE())
	}
	if vtd.GPS_LONGITUDE != nil {
		fmt.Printf("  GPS_LONGITUDE:             %.6f\n", vtd.GetGPS_LONGITUDE())
	}
	if d := vtd.GetVehicleDynamics(); d != nil {
		fmt.Printf("  vehicle_dynamics:\n")
		fmt.Printf("    steering_angle_deg:    %.2f°\n", d.GetSteeringAngleDeg())
		fmt.Printf("    accelerator_pedal_pct: %.2f%%\n", d.GetAcceleratorPedalPct())
		fmt.Printf("    brake_pedal_pct:       %.2f%%\n", d.GetBrakePedalPct())
	}
	if g := vtd.GetGearStatus(); g != nil {
		fmt.Printf("  gear_status.gear:          %s\n", g.GetGear().String())
	}
	if vtd.SpeedLimitDisplayed != nil {
		fmt.Printf("  speed_limit_displayed:     %v\n", vtd.GetSpeedLimitDisplayed())
	}
	lights := []struct {
		name string
		val  *bool
	}{
		{"fog_lights", vtd.FogLights},
		{"park_lights", vtd.ParkLights},
		{"hibeam", vtd.Hibeam},
		{"lowbeam", vtd.Lowbeam},
		{"turn_signal_left", vtd.TurnSignalLeft},
		{"turn_signal_right", vtd.TurnSignalRight},
		{"trunk_open", vtd.TrunkOpen},
		{"ambient_light", vtd.CarlaVehicleAmbientLight},
		{"ambient_fog", vtd.CarlaVehicleAmbientFog},
	}
	for _, l := range lights {
		if l.val != nil {
			fmt.Printf("  %-26s %v\n", l.name+":", *l.val)
		}
	}
	if ts := vtd.GetTripStatus(); ts != nil {
		fmt.Printf("  trip_status:\n")
		fmt.Printf("    is_active:          %v\n", ts.GetIsActive())
		fmt.Printf("    start_timestamp_ms: %d\n", ts.GetStartTimestampMs())
		fmt.Printf("    end_timestamp_ms:   %d\n", ts.GetEndTimestampMs())
	}
}

// decodeAndPrint tries to decode the message payload based on the NATS subject and prints the result.
// Subjects starting with "telemetry." carry MetricsReport (wrapping VehicleTelemetryData).
// Subjects starting with "telemetry-generic." carry TelemetryMessage.
func decodeAndPrint(subject string, data []byte) {
	switch {
	case strings.HasPrefix(subject, "local.telemetry."):
		// First try MetricsReport envelope (same wrapper as telemetry.* subjects).
		// The AAOS metrics system packs VehicleTelemetryData into a MetricsReport.report_data Any.
		// We extract the raw Any.Value bytes and unmarshal directly, bypassing the type URL
		// check (the URL is com.android.sdv.someip.VehicleTelemetryData, not the telemetry package).
		var report pb.MetricsReport
		if err := proto.Unmarshal(data, &report); err == nil && report.GetReportData() != nil {
			anyVal := report.GetReportData().GetValue()
			var vtd aaospb.VehicleTelemetryData
			if err := proto.Unmarshal(anyVal, &vtd); err != nil {
				fmt.Printf("  [AAOS VehicleTelemetryData (from Any) decode error: %v]\n", err)
				return
			}
			ts := ""
			if report.GetReportTimestamp() != nil {
				ts = report.GetReportTimestamp().AsTime().Format(time.RFC3339Nano)
			}
			fmt.Printf("  Type:         AAOS MetricsReport → VehicleTelemetryData\n")
			fmt.Printf("  ReportNumber: %d\n", report.GetReportNumber())
			fmt.Printf("  ReportUUID:   %s\n", report.GetReportUuid())
			fmt.Printf("  Timestamp:    %s\n", ts)
			fmt.Printf("  TypeURL:      %s\n", report.GetReportData().GetTypeUrl())
			decodeAaosVehicleTelemetryData(&vtd)
			return
		}
		// Fallback: try raw VehicleTelemetryData (no envelope)
		var vtd aaospb.VehicleTelemetryData
		if err := proto.Unmarshal(data, &vtd); err != nil {
			fmt.Printf("  [AAOS VehicleTelemetryData decode error: %v]\n", err)
			return
		}
		fmt.Printf("  Type: AAOS VehicleTelemetryData (raw, com.android.sdv.someip)\n")
		decodeAaosVehicleTelemetryData(&vtd)

	case strings.HasPrefix(subject, "telemetry-generic."):
		var msg pb.TelemetryMessage
		if err := proto.Unmarshal(data, &msg); err != nil {
			fmt.Printf("  [TelemetryMessage decode error: %v]\n", err)
			return
		}
		fmt.Printf("  Type:          TelemetryMessage\n")
		fmt.Printf("  MessageID:     %s\n", msg.GetMessageId())
		fmt.Printf("  DeviceID:      %s\n", msg.GetDeviceId())
		fmt.Printf("  SchemaVersion: %d\n", msg.GetSchemaVersion())
		fmt.Printf("  Readings (%d):\n", len(msg.GetSensorData()))
		for _, r := range msg.GetSensorData() {
			ts := ""
			if r.GetTimestamp() != nil {
				ts = r.GetTimestamp().AsTime().Format(time.RFC3339Nano)
			}
			fmt.Printf("    %-30s  %-8s  value=%-15s  ts=%s\n",
				r.GetSensor(), r.GetDataType().String(), r.GetValue(), ts)
		}

	case strings.HasPrefix(subject, "telemetry."):
		var report pb.MetricsReport
		if err := proto.Unmarshal(data, &report); err != nil {
			fmt.Printf("  [MetricsReport decode error: %v]\n", err)
			return
		}
		ts := ""
		if report.GetReportTimestamp() != nil {
			ts = report.GetReportTimestamp().AsTime().Format(time.RFC3339Nano)
		}
		fmt.Printf("  Type:          MetricsReport\n")
		fmt.Printf("  ReportNumber:  %d\n", report.GetReportNumber())
		fmt.Printf("  ReportUUID:    %s\n", report.GetReportUuid())
		fmt.Printf("  Timestamp:     %s\n", ts)
		fmt.Printf("  Reason:        %s\n", report.GetReportReason().String())

		// Unpack the Any field into VehicleTelemetryData
		anyData := report.GetReportData()
		if anyData == nil {
			fmt.Println("  ReportData:    <nil>")
			return
		}
		var vtd pb.VehicleTelemetryData
		if err := anyData.UnmarshalTo(&vtd); err != nil {
			fmt.Printf("  ReportData:    [VehicleTelemetryData decode error: %v]\n", err)
			return
		}
		fmt.Printf("  VehicleTelemetryData:\n")
		fmt.Printf("    ENGINE_POWER:    %.2f\n", vtd.GetENGINE_POWER())
		fmt.Printf("    ENGINE_RPM:      %.2f\n", vtd.GetENGINE_RPM())
		fmt.Printf("    FUEL_CAPACITY:   %.2f\n", vtd.GetFUEL_CAPACITY())
		fmt.Printf("    FUEL_LEVEL:      %.2f\n", vtd.GetFUEL_LEVEL())
		fmt.Printf("    TIRE_PRESSURE:   %.2f\n", vtd.GetTIRE_PRESSURE())
		fmt.Printf("    VELOCITY:        %.2f\n", vtd.GetVELOCITY())
		if vtd.IGNITION_STATE != nil {
			fmt.Printf("    IGNITION_STATE:  %v\n", vtd.GetIGNITION_STATE())
		}
		if vtd.GPS_LATITUDE != nil {
			fmt.Printf("    GPS_LATITUDE:    %.6f\n", vtd.GetGPS_LATITUDE())
		}
		if vtd.GPS_LONGITUDE != nil {
			fmt.Printf("    GPS_LONGITUDE:   %.6f\n", vtd.GetGPS_LONGITUDE())
		}
		if d := vtd.GetVehicleDynamics(); d != nil {
			fmt.Printf("    vehicle_dynamics:\n")
			fmt.Printf("      steering_angle_deg:    %.2f\n", d.GetSteeringAngleDeg())
			fmt.Printf("      accelerator_pedal_pct: %.2f\n", d.GetAcceleratorPedalPct())
			fmt.Printf("      brake_pedal_pct:       %.2f\n", d.GetBrakePedalPct())
		}
		if g := vtd.GetGearStatus(); g != nil {
			fmt.Printf("    gear_status.gear: %s\n", g.GetGear().String())
		}

	default:
		// Unknown subject — try JSON, then give up
		var jsonData map[string]interface{}
		if err := json.Unmarshal(data, &jsonData); err == nil {
			pretty, _ := json.MarshalIndent(jsonData, "  ", "  ")
			fmt.Printf("  [JSON]\n  %s\n", string(pretty))
		} else {
			fmt.Println("  [Unknown format — cannot decode]")
		}
	}
}

// RecordedMessage is the JSON sidecar written alongside each .bin file.
type RecordedMessage struct {
	Subject    string      `json:"subject"`
	ReceivedAt string      `json:"received_at"`
	SizeBytes  int         `json:"size_bytes"`
	ReplayCmd  string      `json:"replay_cmd"`
	Decoded    interface{} `json:"decoded,omitempty"`
}

// decodeToJSON decodes the raw protobuf bytes for the given subject and returns
// a JSON-serialisable value. Returns nil if decoding is not possible.
func decodeToJSON(subject string, data []byte) interface{} {
	pjOpts := protojson.MarshalOptions{
		EmitUnpopulated: false,
		UseProtoNames:   true,
	}

	// Helper: marshal a proto message to a generic map so it embeds cleanly.
	toMap := func(m proto.Message) map[string]interface{} {
		b, err := pjOpts.Marshal(m)
		if err != nil {
			return map[string]interface{}{"error": err.Error()}
		}
		var out map[string]interface{}
		_ = json.Unmarshal(b, &out)
		return out
	}

	switch {
	case strings.HasPrefix(subject, "local.telemetry."):
		var report pb.MetricsReport
		if err := proto.Unmarshal(data, &report); err != nil || report.GetReportData() == nil {
			break
		}
		result := toMap(&report)
		// Additionally decode the inner Any value as AAOS VehicleTelemetryData.
		var vtd aaospb.VehicleTelemetryData
		if err := proto.Unmarshal(report.GetReportData().GetValue(), &vtd); err == nil {
			result["decoded_payload"] = toMap(&vtd)
		}
		return result

	case strings.HasPrefix(subject, "telemetry-generic."):
		var msg pb.TelemetryMessage
		if err := proto.Unmarshal(data, &msg); err != nil {
			break
		}
		return toMap(&msg)

	case strings.HasPrefix(subject, "telemetry."):
		var report pb.MetricsReport
		if err := proto.Unmarshal(data, &report); err != nil {
			break
		}
		result := toMap(&report)
		// Unpack Any into VehicleTelemetryData when possible.
		var vtd pb.VehicleTelemetryData
		if report.GetReportData() != nil {
			if err := report.GetReportData().UnmarshalTo(&vtd); err == nil {
				result["decoded_payload"] = toMap(&vtd)
			}
		}
		return result
	}

	return nil
}

// recordMessage saves msg.Data as a .bin file and a .json sidecar in dir.
// Filename pattern: <RFC3339>_<seq>_<sanitised-subject>
// The .json sidecar carries the original subject so replay knows where to publish.
func recordMessage(dir string, seq int, subject string, data []byte) {
	if err := os.MkdirAll(dir, 0755); err != nil {
		log.Printf("⚠ record: cannot create dir %s: %v", dir, err)
		return
	}

	// Build a filesystem-safe base name.
	ts := time.Now().UTC().Format("20060102T150405.000Z")
	safe := strings.NewReplacer(".", "_", "/", "_", "\\", "_", "*", "_", ">", "gt").Replace(subject)
	base := fmt.Sprintf("%s_%04d_%s", ts, seq, safe)

	binPath := filepath.Join(dir, base+".bin")
	if err := os.WriteFile(binPath, data, 0644); err != nil {
		log.Printf("⚠ record: failed to write %s: %v", binPath, err)
		return
	}

	meta := RecordedMessage{
		Subject:    subject,
		ReceivedAt: time.Now().UTC().Format(time.RFC3339Nano),
		SizeBytes:  len(data),
		ReplayCmd:  fmt.Sprintf(`cat %s | nats pub --server "$NATS_URL" %s`, binPath, subject),
		Decoded:    decodeToJSON(subject, data),
	}
	metaJSON, _ := json.MarshalIndent(meta, "", "  ")
	jsonPath := filepath.Join(dir, base+".json")
	if err := os.WriteFile(jsonPath, metaJSON, 0644); err != nil {
		log.Printf("⚠ record: failed to write %s: %v", jsonPath, err)
		return
	}

	log.Printf("⏺ recorded → %s (%d bytes)", binPath, len(data))
}

// SubscribeToTelemetry subscribes to the telemetry subject and prints received messages
func (s *TelemetrySubscriber) SubscribeToTelemetry(initialJWT string) error {
	log.Printf("Connecting to NATS at %s...", s.natsURL)

	var nc *nats.Conn
	var jwtExpiry time.Time
	refreshBuffer := 60 * time.Second
	jwt := initialJWT

	// Helper function to establish connection
	connect := func() error {
		if nc != nil {
			nc.Close()
			time.Sleep(1 * time.Second)
		}

		// Get fresh JWT if needed
		if time.Until(jwtExpiry) < refreshBuffer {
			log.Println("Getting fresh JWT token...")
			var err error
			jwt, err = s.AuthenticateWithKeycloak()
			if err != nil {
				return fmt.Errorf("failed to get JWT: %w", err)
			}
			jwtExpiry = time.Now().Add(1209600 * time.Second)
			log.Printf("JWT refreshed, expires at: %s", jwtExpiry.Format(time.RFC3339))
		}

		// Connect to NATS with JWT authentication
		var err error
		nc, err = nats.Connect(s.natsURL,
			nats.Token(jwt),
			nats.ErrorHandler(func(nc *nats.Conn, sub *nats.Subscription, err error) {
				log.Printf("⚠ NATS error: %v", err)
			}),
			nats.DisconnectErrHandler(func(nc *nats.Conn, err error) {
				if err != nil {
					log.Printf("⚠ Disconnected from NATS: %v", err)
				}
			}),
			nats.ReconnectHandler(func(nc *nats.Conn) {
				log.Printf("✓ Reconnected to NATS at %s", nc.ConnectedUrl())
			}),
		)
		if err != nil {
			return fmt.Errorf("failed to connect to NATS: %w", err)
		}

		log.Println("✓ Connected to NATS successfully")
		log.Printf("✓ Subscribing to subject: %s", s.Subject)

		// Subscribe to the telemetry subject
		_, err = nc.Subscribe(s.Subject, func(msg *nats.Msg) {
			s.messageCount++
			s.lastMessage = time.Now()

			fmt.Printf("\n[%d] === Received message on %s ===\n", s.messageCount, msg.Subject)

			// --- Record to disk (if --record-dir was set) ---
			if s.RecordDir != "" {
				recordMessage(s.RecordDir, s.messageCount, msg.Subject, msg.Data)
			}

			// --- Raw bytes ---
			fmt.Printf("Raw (%d bytes):\n", len(msg.Data))
			fmt.Println(formatHexDump(msg.Data))

			// --- Decoded ---
			fmt.Println("Decoded:")
			decodeAndPrint(msg.Subject, msg.Data)

			fmt.Println("================================")
		})

		if err != nil {
			return fmt.Errorf("failed to subscribe: %w", err)
		}

		return nil
	}

	// Initial connection
	jwtExpiry = time.Now().Add(1209600 * time.Second)
	if err := connect(); err != nil {
		return err
	}
	defer nc.Close()

	log.Println("✓ Subscription active. Listening for messages continuously...")
	log.Println("  Press Ctrl+C to exit")

	// Start statistics ticker
	statsTicker := time.NewTicker(30 * time.Second)
	defer statsTicker.Stop()

	// Start JWT refresh ticker
	jwtTicker := time.NewTicker(10 * time.Second)
	defer jwtTicker.Stop()

	// Wait for interrupt signal
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM)

	for {
		select {
		case <-sigChan:
			log.Println("\nShutting down...")
			log.Printf("Total messages received: %d", s.messageCount)
			return nil

		case <-statsTicker.C:
			if s.messageCount > 0 {
				timeSinceLast := time.Since(s.lastMessage)
				log.Printf("\n📊 Stats: %d messages received | Last message: %s ago",
					s.messageCount, timeSinceLast.Round(time.Second))
			} else {
				log.Println("\n📊 Stats: No messages received yet")
			}

		case <-jwtTicker.C:
			// Check if JWT needs refresh
			if time.Until(jwtExpiry) < refreshBuffer {
				log.Println("\n⚠ JWT expiring soon, reconnecting with fresh token...")
				if err := connect(); err != nil {
					log.Printf("Failed to reconnect: %v", err)
				}
			}
		}
	}
}
