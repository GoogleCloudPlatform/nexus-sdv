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
	"encoding/json"
	"encoding/pem"
	"flag"
	"fmt"
	"io"
	"log"
	mathrand "math/rand"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/nats-io/nats.go"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/anypb"
	"google.golang.org/protobuf/types/known/timestamppb"

	pb "github.com/valtech-sdv/vehicle-client/telemetry"
	pbMetrics "github.com/valtech-sdv/vehicle-client/telemetry"
	pbVehicle "github.com/valtech-sdv/vehicle-client/telemetry"
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

// VehicleClient handles the complete vehicle authentication flow
type VehicleClient struct {
	VIN                   string
	pkiStrategy           string
	FactoryCertFile       string
	FactoryKeyFile        string
	RegistrationServerURL string
	MessageType           string // "telemetry" or "metrics_report"

	// Generated during registration
	operationalCert    *x509.Certificate
	operationalKey     *rsa.PrivateKey
	operationalCertPEM []byte
	keycloakURL        string
	natsURL            string
}

func main() {
	defaultRegistrationURL := os.Getenv("REGISTRATION_URL")

	vin := flag.String("vin", "1HGBH41JXMN109186", "Vehicle Identification Number")
	pkiStrategy := flag.String("pki_strategy", "local", "PKI Strategy")
	factoryCert := flag.String("factory-cert", "", "Path to factory-issued certificate (required when registration is needed)")
	factoryKey := flag.String("factory-key", "", "Path to factory-issued private key (required when registration is needed)")
	registrationURL := flag.String("registration-url", defaultRegistrationURL, "Registration server URL (required when registration is needed)")
	keycloakURL := flag.String("keycloak-url", "", "Keycloak URL (used when reusing existing certificates)")
	natsURL := flag.String("nats-url", "", "NATS URL (used when reusing existing certificates)")
	interval := flag.Int("interval", 5, "Interval in seconds between telemetry messages")
	messageType := flag.String("message-type", "telemetry", "Message type to send: 'telemetry' (TelemetryMessage) or 'metrics_report' (MetricsReport)")
	flag.Parse()

	if *messageType != "telemetry" && *messageType != "metrics_report" {
		log.Fatal("Message type must be either 'telemetry' or 'metrics_report'")
	}

	mathrand.Seed(time.Now().UnixNano())

	client := &VehicleClient{
		VIN:         *vin,
		pkiStrategy: *pkiStrategy,
		MessageType: *messageType,
	}

	log.Printf("================================================")
	log.Printf("Starting vehicle client for VIN: %s", client.VIN)
	log.Printf("Message Type: %s", client.MessageType)
	log.Printf("================================================")
	log.Printf("Telemetry interval: %d seconds", *interval)

	var jwt string

	// Try to reuse existing certificates and token
	if existingJWT, ok := client.loadExistingCertsAndToken(); ok {
		log.Println("✓ Existing certificates and token are valid — skipping registration")
		if *keycloakURL == "" || *natsURL == "" {
			log.Fatal("-keycloak-url and -nats-url are required when reusing existing certificates")
		}
		client.keycloakURL = *keycloakURL
		client.natsURL = *natsURL
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
		client.FactoryCertFile = *factoryCert
		client.FactoryKeyFile = *factoryKey
		client.RegistrationServerURL = *registrationURL

		if err := client.Register(); err != nil {
			log.Fatalf("Registration failed: %v", err)
		}
		log.Println("✓ Registered and obtained operational certificate")

		var err error
		jwt, err = client.AuthenticateWithKeycloak()
		if err != nil {
			log.Fatalf("Keycloak authentication failed: %v", err)
		}
		log.Println("✓ Authenticated with Keycloak")
	}

	// Smoke test NATS connectivity
	log.Println("Smoke testing NATS connectivity...")
	if err := client.ConnectToNATS(jwt); err != nil {
		log.Fatalf("NATS smoke test failed: %v", err)
	}
	log.Println("✓ NATS smoke test passed")

	log.Println("Starting continuous telemetry publishing...")
	if err := client.PublishTelemetryContinuously(*interval); err != nil {
		log.Fatalf("Failed to publish telemetry: %v", err)
	}
}

// loadExistingCertsAndToken checks whether a valid operational certificate and
// unexpired JWT token already exist on disk. If both are valid it loads them
// into the client and returns (token, true); otherwise it returns ("", false).
func (v *VehicleClient) loadExistingCertsAndToken() (string, bool) {
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

	v.operationalCert = cert
	v.operationalCertPEM = certPEM
	v.operationalKey = key
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
func (v *VehicleClient) Register() error {
	log.Printf("************************************************")
	log.Println(" Starting client registration")
	log.Printf("************************************************")
	log.Println("Retrieving operational certificate...")

	// Generate a new RSA key pair for operational use
	privateKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return fmt.Errorf("failed to generate key pair: %w", err)
	}
	v.operationalKey = privateKey

	// Create a Certificate Signing Request (CSR)
	log.Println("Creating Certificate Signing Request (CSR)...")
	csrPEM, err := v.createCSR(privateKey)
	if err != nil {
		return fmt.Errorf("failed to create CSR: %w", err)
	}

	// Load factory certificate and key for mTLS
	log.Println("Loading factory-issued certificate for mTLS...")
	factoryCert, err := tls.LoadX509KeyPair(v.FactoryCertFile, v.FactoryKeyFile)
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
		InsecureSkipVerify: v.pkiStrategy == "local", // Verify the server certificate
		RootCAs:            caCertPool,
		MinVersion:         tls.VersionTLS12,
		MaxVersion:         tls.VersionTLS13,
		// Use classic key exchange curves to avoid post-quantum compatibility issues
		// between Go's crypto/tls and rustls's X25519MLKEM768 implementation
		CurvePreferences: []tls.CurveID{tls.X25519, tls.CurveP256, tls.CurveP384},
		// Force client certificate to be sent
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
	log.Printf("Sending CSR to registration server at %s...", v.RegistrationServerURL)
	req, err := http.NewRequest("POST", v.RegistrationServerURL+"/registration", bytes.NewReader(csrPEM))
	if err != nil {
		return fmt.Errorf("failed to create request: %w", err)
	}
	req.Header.Set("Content-Type", "application/x-pem-file")

	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("failed to send request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("registration failed with status %d: %s", resp.StatusCode, string(body))
	}

	// Parse the registration response
	var regResp RegistrationResponse
	if err := json.NewDecoder(resp.Body).Decode(&regResp); err != nil {
		return fmt.Errorf("failed to decode response: %w", err)
	}

	log.Println("Parsing operational certificate...")
	// Parse the operational certificate
	block, _ := pem.Decode([]byte(regResp.Certificate))
	if block == nil {
		return fmt.Errorf("failed to parse certificate PEM")
	}

	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return fmt.Errorf("failed to parse certificate: %w", err)
	}

	v.operationalCert = cert
	v.operationalCertPEM = []byte(regResp.Certificate)
	v.keycloakURL = regResp.KeycloakURL
	v.natsURL = regResp.NatsURL

	log.Printf("  Keycloak URL: %s", v.keycloakURL)
	log.Printf("  NATS URL: %s", v.natsURL)
	log.Printf("  Certificate valid until: %s", cert.NotAfter)

	certDir := "certificates/"
	// Save operational certificate and key to files for reuse
	if err := os.WriteFile(certDir+"operational-cert.pem", v.operationalCertPEM, 0644); err != nil {
		log.Printf("Warning: Failed to save operational certificate: %v", err)
	} else {
		log.Println("  Saved operational certificate to operational-cert.pem")
	}

	keyPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "RSA PRIVATE KEY",
		Bytes: x509.MarshalPKCS1PrivateKey(v.operationalKey),
	})
	if err := os.WriteFile(certDir+"operational-key.pem", keyPEM, 0600); err != nil {
		log.Printf("Warning: Failed to save operational key: %v", err)
	} else {
		log.Println("  Saved operational key to operational-key.pem")
	}

	return nil
}

// createCSR generates a Certificate Signing Request
func (v *VehicleClient) createCSR(privateKey *rsa.PrivateKey) ([]byte, error) {
	// Create CSR with VIN and DEVICE in the expected format
	// The registration server expects CN in format: "VIN:xxx DEVICE:yyy"
	cn := fmt.Sprintf("VIN:%s DEVICE:%s", v.VIN, v.VIN)

	// Encode CN as UTF8String (required by registration server)
	// Use the string bytes directly, not asn1.Marshal which would double-encode
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

	csrDER, err := x509.CreateCertificateRequest(rand.Reader, &template, privateKey)
	if err != nil {
		return nil, fmt.Errorf("failed to create certificate request: %w", err)
	}

	// Encode to PEM
	csrPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "CERTIFICATE REQUEST",
		Bytes: csrDER,
	})

	return csrPEM, nil
}

// AuthenticateWithKeycloak obtains a JWT token using the operational certificate
func (v *VehicleClient) AuthenticateWithKeycloak() (string, error) {
	log.Println("Authenticate With Keycloak Step 1: Configuring mTLS with operational certificate...")

	// Create TLS certificate from operational cert and key
	keyPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "RSA PRIVATE KEY",
		Bytes: x509.MarshalPKCS1PrivateKey(v.operationalKey),
	})

	cert, err := tls.X509KeyPair(v.operationalCertPEM, keyPEM)
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
		InsecureSkipVerify: false, // Verify the server certificate
		RootCAs:            caCertPool,
		MinVersion:         tls.VersionTLS12,
		MaxVersion:         tls.VersionTLS13,
		// Use classic key exchange curves to avoid post-quantum compatibility issues
		CurvePreferences: []tls.CurveID{tls.X25519, tls.CurveP256, tls.CurveP384},
		// Force client certificate to be sent
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
	log.Printf("Authenticate With Keycloak Step 2: Requesting JWT from Keycloak at %s...", v.keycloakURL)
	tokenURL := fmt.Sprintf("%s/realms/sdv-telemetry/protocol/openid-connect/token", v.keycloakURL)

	// For client certificate authentication, we use grant_type=client_credentials
	// The client_id should match the clientId configured in Keycloak (configured as "car")
	// Request openid scope to get an ID token, and offline_access for a refresh token
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

// ConnectToNATS establishes a connection to NATS using the JWT
func (v *VehicleClient) ConnectToNATS(jwt string) error {
	log.Printf("[Smoke test] Connecting to NATS at %s with JWT...", v.natsURL)

	// Connect to NATS with JWT authentication
	// Use nats.Token() to pass the Keycloak JWT for auth-callout validation
	nc, err := nats.Connect(v.natsURL,
		nats.Token(jwt),
		nats.ErrorHandler(func(nc *nats.Conn, sub *nats.Subscription, err error) {
			log.Printf("NATS error: %v", err)
		}),
	)
	if err != nil {
		return fmt.Errorf("failed to connect to NATS: %w", err)
	}
	defer nc.Close()

	log.Println("  [Smoke test] Connected to NATS successfully")

	// Wait a moment to ensure connection is stable
	time.Sleep(1 * time.Second)

	return nil
}

// buildTelemetrySubject constructs the NATS subject for generic TelemetryMessage publishing
// Supports configurable prefix via TELEMETRY_PREFIX environment variable
// Examples:
//   - Without prefix: telemetry-generic.{VIN}.{sensor}
//   - With prefix "prod.bigtable": telemetry-generic.prod.bigtable.{VIN}.{sensor}
func (v *VehicleClient) buildTelemetrySubject(sensor string) string {
	prefix := os.Getenv("TELEMETRY_PREFIX")
	if prefix != "" {
		return fmt.Sprintf("telemetry-generic.%s.%s.%s", prefix, v.VIN, sensor)
	}
	return fmt.Sprintf("telemetry-generic.%s.%s", v.VIN, sensor)
}

// buildMetricsReportSubject constructs the NATS subject for MetricsReport publishing
// Format: telemetry.{VIN}
func (v *VehicleClient) buildMetricsReportSubject() string {
	return fmt.Sprintf("telemetry.%s", v.VIN)
}

// PublishTelemetry sends sample telemetry data to NATS
func (v *VehicleClient) PublishTelemetry() error {
	log.Println("Publishing telemetry data...")

	// For telemetry publishing, we need a fresh NATS connection
	jwt, err := v.AuthenticateWithKeycloak()
	if err != nil {
		return fmt.Errorf("failed to get JWT for telemetry: %w", err)
	}

	nc, err := nats.Connect(v.natsURL,
		nats.Token(jwt),
	)
	if err != nil {
		return fmt.Errorf("failed to connect to NATS: %w", err)
	}
	defer nc.Close()

	// Publish sample telemetry
	subject := v.buildTelemetrySubject("battery")
	data := map[string]interface{}{
		"vin":             v.VIN,
		"timestamp":       time.Now().Unix(),
		"battery_voltage": 12.6,
		"battery_current": 45.2,
		"battery_soc":     85.5,
		"battery_temp":    25.3,
	}

	payload, err := json.Marshal(data)
	if err != nil {
		return fmt.Errorf("failed to marshal telemetry: %w", err)
	}

	if err := nc.Publish(subject, payload); err != nil {
		return fmt.Errorf("failed to publish telemetry: %w", err)
	}

	log.Printf("  Published telemetry to subject: %s", subject)
	log.Printf("  Payload: %s", string(payload))

	// Flush to ensure message is sent
	if err := nc.Flush(); err != nil {
		return fmt.Errorf("failed to flush NATS connection: %w", err)
	}

	return nil
}

// PublishTelemetryContinuously sends telemetry data to NATS continuously
// Supports two message types: "telemetry" (TelemetryMessage) and "metrics_report" (MetricsReport)
func (v *VehicleClient) PublishTelemetryContinuously(intervalSeconds int) error {
	// Initial battery state
	batteryVoltage := 12.6
	batteryCurrent := 45.2
	batterySoC := 85.5
	batteryTemp := 25.3

	// Engine state (for metrics reports)
	enginePower := 50.0
	engineRPM := 1000.0
	fuelLevel := 50.0
	velocity := 0.0
	steeringAngle := 0.0
	acceleratorPct := 0.0
	brakePct := 0.0

	// JWT refresh parameters
	var nc *nats.Conn
	var jwtExpiry time.Time
	refreshBuffer := 60 * time.Second // Refresh JWT 60 seconds before expiry

	// Helper function to get fresh connection
	refreshConnection := func() error {
		if nc != nil {
			nc.Close()
		}

		log.Println("Establishing telemetry NATS connection (re-authenticating with Keycloak)...")
		jwt, err := v.AuthenticateWithKeycloak()
		if err != nil {
			return fmt.Errorf("failed to get JWT: %w", err)
		}

		// JWT expires in 2 weeks (1209600 seconds, matching Keycloak realm config)
		jwtExpiry = time.Now().Add(1209600 * time.Second)
		log.Printf("JWT refreshed, expires at: %s", jwtExpiry.Format(time.RFC3339))

		nc, err = nats.Connect(v.natsURL, nats.Token(jwt))
		if err != nil {
			return fmt.Errorf("failed to connect to NATS: %w", err)
		}
		log.Println("  Telemetry NATS connection established")

		return nil
	}

	// Initial connection
	log.Println("Establishing initial telemetry NATS connection...")
	if err := refreshConnection(); err != nil {
		return err
	}
	defer nc.Close()

	ticker := time.NewTicker(time.Duration(intervalSeconds) * time.Second)
	defer ticker.Stop()

	messageCount := 0

	for range ticker.C {
		// Check if JWT needs refresh
		if time.Until(jwtExpiry) < refreshBuffer {
			log.Println("JWT expiring soon, refreshing connection...")
			if err := refreshConnection(); err != nil {
				log.Printf("Failed to refresh connection: %v", err)
				continue
			}
		}

		// Simulate realistic battery variations
		batteryVoltage += (mathrand.Float64() - 0.5) * 0.2 // ±0.1V
		batteryCurrent += (mathrand.Float64() - 0.5) * 5.0 // ±2.5A
		batterySoC -= mathrand.Float64() * 0.1             // Slowly discharge
		batteryTemp += (mathrand.Float64() - 0.5) * 1.0    // ±0.5°C

		// Simulate engine variations (for metrics reports)
		enginePower += (mathrand.Float64() - 0.5) * 10.0
		engineRPM += (mathrand.Float64() - 0.5) * 100.0
		fuelLevel -= mathrand.Float64() * 0.05 // Slowly consume fuel
		velocity += (mathrand.Float64() - 0.5) * 5.0
		steeringAngle += (mathrand.Float64() - 0.5) * 2.0
		acceleratorPct += (mathrand.Float64() - 0.5) * 5.0
		brakePct += (mathrand.Float64() - 0.5) * 5.0

		// Keep battery values in realistic ranges
		if batteryVoltage < 11.0 {
			batteryVoltage = 11.0
		}
		if batteryVoltage > 14.5 {
			batteryVoltage = 14.5
		}
		if batteryCurrent < 0 {
			batteryCurrent = 0
		}
		if batteryCurrent > 100 {
			batteryCurrent = 100
		}
		if batterySoC < 10 {
			batterySoC = 90.0 // Reset to charged state
		}
		if batteryTemp < 15 {
			batteryTemp = 15
		}
		if batteryTemp > 45 {
			batteryTemp = 45
		}

		// Keep engine values in realistic ranges
		if enginePower < 0 {
			enginePower = 0
		}
		if enginePower > 150 {
			enginePower = 150
		}
		if engineRPM < 0 {
			engineRPM = 0
		}
		if engineRPM > 6000 {
			engineRPM = 6000
		}
		if fuelLevel < 5 {
			fuelLevel = 60 // Reset fuel
		}
		if velocity < 0 {
			velocity = 0
		}
		if velocity > 200 {
			velocity = 200
		}
		if steeringAngle < -45 {
			steeringAngle = -45
		}
		if steeringAngle > 45 {
			steeringAngle = 45
		}
		if acceleratorPct < 0 {
			acceleratorPct = 0
		}
		if acceleratorPct > 100 {
			acceleratorPct = 100
		}
		if brakePct < 0 {
			brakePct = 0
		}
		if brakePct > 100 {
			brakePct = 100
		}

		now := time.Now()

		// Build and publish message based on message type
		var subject string
		var payload []byte
		var err error

		if v.MessageType == "telemetry" {
			// Publish TelemetryMessage
			subject = v.buildTelemetrySubject("battery")

			msg := &pb.TelemetryMessage{
				MessageId:     uuid.New().String(),
				SchemaVersion: 1,
				DeviceId:      v.VIN,
				SensorData: []*pb.SensorReading{
					{
						Timestamp: timestamppb.New(now),
						Value:     fmt.Sprintf("%.2f", batteryVoltage),
						DataType:  pb.DataType_DYNAMIC,
						Sensor:    "battery.voltage",
					},
					{
						Timestamp: timestamppb.New(now),
						Value:     fmt.Sprintf("%.2f", batteryCurrent),
						DataType:  pb.DataType_DYNAMIC,
						Sensor:    "battery.current",
					},
					{
						Timestamp: timestamppb.New(now),
						Value:     fmt.Sprintf("%.2f", batterySoC),
						DataType:  pb.DataType_DYNAMIC,
						Sensor:    "battery.soc",
					},
					{
						Timestamp: timestamppb.New(now),
						Value:     fmt.Sprintf("%.2f", batteryTemp),
						DataType:  pb.DataType_DYNAMIC,
						Sensor:    "battery.temp",
					},
				},
			}

			payload, err = proto.Marshal(msg)
			if err != nil {
				log.Printf("Failed to marshal TelemetryMessage: %v", err)
				continue
			}

		} else if v.MessageType == "metrics_report" {
			// Publish MetricsReport with VehicleTelemetryData
			subject = v.buildMetricsReportSubject()

			// Build the inner VehicleTelemetryData payload
			ignitionState := engineRPM > 0
			gpsLat := float32(0.0)
			gpsLon := float32(0.0)

			vehicleData := &pbVehicle.VehicleTelemetryData{
				ENGINE_POWER:   float32(enginePower),
				ENGINE_RPM:     float32(engineRPM),
				FUEL_CAPACITY:  50.0, // Static value
				FUEL_LEVEL:     float32(fuelLevel),
				TIRE_PRESSURE:  2.2, // Static value
				VELOCITY:       float32(velocity),
				IGNITION_STATE: &ignitionState,
				GPS_LATITUDE:   &gpsLat,
				GPS_LONGITUDE:  &gpsLon,
				VehicleDynamics: &pbVehicle.CarlaVehicleDynamics{
					SteeringAngleDeg:    steeringAngle,
					AcceleratorPedalPct: acceleratorPct,
					BrakePedalPct:       brakePct,
				},
				GearStatus: &pbVehicle.CarlaVehicleGearStatus{
					Gear: pbVehicle.CarlaVehicleGearStatus_NEUTRAL,
				},
			}

			// Marshal inner payload to Any
			anyPayload, err := anypb.New(vehicleData)
			if err != nil {
				log.Printf("Failed to create Any payload: %v", err)
				continue
			}

			// Build the outer MetricsReport
			report := &pbMetrics.MetricsReport{
				ReportNumber:         int32(messageCount) + 1,
				ReportTimestamp:      timestamppb.New(now),
				ReportReason:         pbMetrics.MetricsReport_REGULAR,
				MetricsConfigUuid:    uuid.New().String(),
				MetricsConfigVersion: 1,
				ReportConfigName:     "default",
				ReportData:           anyPayload,
				ReportUuid:           uuid.New().String(),
			}

			payload, err = proto.Marshal(report)
			if err != nil {
				log.Printf("Failed to marshal MetricsReport: %v", err)
				continue
			}
		} else {
			log.Printf("Unknown message type: %s", v.MessageType)
			continue
		}

		// Publish to NATS
		if err := nc.Publish(subject, payload); err != nil {
			log.Printf("Failed to publish: %v", err)
			// Try to reconnect on publish error
			if err := refreshConnection(); err != nil {
				log.Printf("Failed to reconnect: %v", err)
			}
			continue
		}

		messageCount++
		if v.MessageType == "telemetry" {
			log.Printf("[%d] Published TelemetryMessage to %s: SoC=%.1f%%, Voltage=%.2fV, Current=%.2fA, Temp=%.1f°C",
				messageCount, subject, batterySoC, batteryVoltage, batteryCurrent, batteryTemp)
		} else {
			log.Printf("[%d] Published MetricsReport to %s: Power=%.1fW, RPM=%.0f, Speed=%.1fkm/h, Fuel=%.1f%%",
				messageCount, subject, enginePower, engineRPM, velocity, fuelLevel)
		}
	}

	return nil
}
