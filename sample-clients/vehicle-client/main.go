package main

import (
	"bytes"
	"context"
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
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/nats-io/nats.go"
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

	// Optional static IPs to dial instead of resolving the request's hostname via DNS —
	// needed on guests with no resolver at all (see docs/superpowers/plans/2026-08-07-
	// nexus-connectivity-agent.md, Task 3). TLS SNI/cert validation is unaffected: Go's
	// http.Transport infers ServerName from the original request host, not the dialed addr.
	RegistrationResolveIP string
	KeycloakResolveIP     string

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
	registrationResolveIP := flag.String("registration-resolve-ip", "", "Dial this IP instead of resolving the registration URL's hostname (for guests with no DNS resolver)")
	keycloakResolveIP := flag.String("keycloak-resolve-ip", "", "Dial this IP instead of resolving the Keycloak URL's hostname (for guests with no DNS resolver)")
	interval := flag.Int("interval", 3, "Interval in seconds between telemetry messages")
	messageType := flag.String("message-type", "telemetry", "Message type to send: 'telemetry' (TelemetryMessage) or 'metrics_report' (MetricsReport)")
	flag.Parse()

	if *messageType != "telemetry" && *messageType != "metrics_report" {
		log.Fatal("Message type must be either 'telemetry' or 'metrics_report'")
	}

	mathrand.Seed(time.Now().UnixNano())

	client := &VehicleClient{
		VIN:                   *vin,
		pkiStrategy:           *pkiStrategy,
		RegistrationResolveIP: *registrationResolveIP,
		KeycloakResolveIP:     *keycloakResolveIP,
		MessageType:           *messageType,
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
// certificateBelongsToVIN reports whether a certificate's common name was
// issued to this VIN. The convention is "VIN:<vin> DEVICE:<id>"; only the VIN
// field is compared, because DEVICE differs between clients.
func certificateBelongsToVIN(commonName, vin string) bool {
	for _, field := range strings.Fields(commonName) {
		if after, ok := strings.CutPrefix(field, "VIN:"); ok {
			return after == vin
		}
	}
	return false
}

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

	// The stored files carry no VIN in their names, so a client started for a
	// different VIN in the same directory would otherwise adopt this identity
	// and publish under someone else's name. Checked here rather than by
	// renaming the files, so an existing checkout keeps working.
	if !certificateBelongsToVIN(cert.Subject.CommonName, v.VIN) {
		log.Printf("Existing operational certificate belongs to %q, not to %s — registering anew",
			cert.Subject.CommonName, v.VIN)
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
// dialContextResolving returns a DialContext that connects to resolveIP instead of
// resolving addr's hostname, keeping addr's port. Returns nil (falling back to the
// default resolver) when resolveIP is empty.
func dialContextResolving(resolveIP string) func(ctx context.Context, network, addr string) (net.Conn, error) {
	if resolveIP == "" {
		return nil
	}
	return func(ctx context.Context, network, addr string) (net.Conn, error) {
		_, port, err := net.SplitHostPort(addr)
		if err != nil {
			return nil, err
		}
		return (&net.Dialer{}).DialContext(ctx, network, net.JoinHostPort(resolveIP, port))
	}
}

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

	client, err := newMTLSClient(factoryCert, "certificates/REGISTRATION_SERVER_TLS_CERT.pem", v.pkiStrategy == "local", "Server", v.RegistrationResolveIP)
	if err != nil {
		return fmt.Errorf("failed to configure mTLS client: %w", err)
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

	client, err := newMTLSClient(cert, "certificates/KEYCLOAK_TLS_CRT.pem", false, "Keycloak", v.KeycloakResolveIP)
	if err != nil {
		return "", fmt.Errorf("failed to configure mTLS client: %w", err)
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
	return fmt.Sprintf("telemetry.%s.%s", v.VIN, sensor)
}

// buildMetricsReportSubject constructs the NATS subject for MetricsReport publishing
// Format: telemetry.{VIN}
func (v *VehicleClient) buildMetricsReportSubject() string {
	return fmt.Sprintf("telemetry-generic.%s", v.VIN)
}

// PublishTelemetryContinuously sends telemetry data to NATS continuously
// Supports two message types: "telemetry" (TelemetryMessage) and "metrics_report" (MetricsReport)
func (v *VehicleClient) PublishTelemetryContinuously(intervalSeconds int) error {
	sim := NewVehicleSimulator()
	conn := &telemetryConnection{}

	log.Println("Establishing initial telemetry NATS connection...")
	if err := conn.refresh(v); err != nil {
		return err
	}
	defer conn.nc.Close()

	ticker := time.NewTicker(time.Duration(intervalSeconds) * time.Second)
	defer ticker.Stop()

	messageCount := 0

	for range ticker.C {
		if err := conn.refreshIfNeeded(v); err != nil {
			log.Printf("Failed to refresh connection: %v", err)
			continue
		}

		sim.Tick()

		subject, payload, err := buildPayload(v, sim, messageCount+1, time.Now())
		if err != nil {
			log.Printf("Failed to build message: %v", err)
			continue
		}

		if err := conn.nc.Publish(subject, payload); err != nil {
			log.Printf("Failed to publish: %v", err)
			// Try to reconnect on publish error
			if err := conn.refresh(v); err != nil {
				log.Printf("Failed to reconnect: %v", err)
			}
			continue
		}

		messageCount++
		logPublished(v, messageCount, subject, sim)
	}

	return nil
}

// logPublished prints the per-message-type summary line after a successful publish.
func logPublished(v *VehicleClient, count int, subject string, sim *VehicleSimulator) {
	if v.MessageType == "telemetry" {
		log.Printf("[%d] Published TelemetryMessage to %s: SoC=%.1f%%, Voltage=%.2fV, Current=%.2fA, Temp=%.1f°C",
			count, subject, sim.BatterySoC, sim.BatteryVoltage, sim.BatteryCurrent, sim.BatteryTemp)
	} else {
		log.Printf("[%d] Published MetricsReport to %s: Power=%.1fW, RPM=%.0f, Speed=%.1fkm/h, Fuel=%.1f%%",
			count, subject, sim.EnginePower, sim.EngineRPM, sim.Velocity, sim.FuelLevel)
	}
}
