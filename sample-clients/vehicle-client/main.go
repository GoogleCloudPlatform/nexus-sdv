package main

import (
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/json"
	"encoding/pem"
	"flag"
	"fmt"
	"io"
	"log"
	mathrand "math/rand"
	"net/http"
	"os"
	"time"

	"github.com/google/uuid"
	"github.com/nats-io/nats.go"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"

	pb "github.com/valtech-sdv/vehicle-client/telemetry"
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

	// Generated during registration
	operationalCert    *x509.Certificate
	operationalKey     *rsa.PrivateKey
	operationalCertPEM []byte
	keycloakURL        string
	natsURL            string
}

func main() {
	// Get registration URL from environment variable (optional default)
	defaultRegistrationURL := os.Getenv("REGISTRATION_URL")

	vin := flag.String("vin", "1HGBH41JXMN109186", "Vehicle Identification Number")
	pkiStrategy := flag.String("pki_strategy", "local", "PKI Strategy")
	factoryCert := flag.String("factory-cert", "factory-cert.pem", "Path to factory-issued certificate")
	factoryKey := flag.String("factory-key", "factory-key.pem", "Path to factory-issued private key")
	registrationURL := flag.String("registration-url", defaultRegistrationURL, "Registration server URL")
	interval := flag.Int("interval", 5, "Interval in seconds between telemetry messages")
	flag.Parse()

	// Validate that registration URL is provided (either via flag or environment variable)
	if *registrationURL == "" {
		log.Fatal("Registration URL must be provided via -registration-url flag or REGISTRATION_URL environment variable")
	}

	// Initialize random seed for telemetry variations
	mathrand.Seed(time.Now().UnixNano())

	client := &VehicleClient{
		VIN:                   *vin,
		pkiStrategy:           *pkiStrategy,
		FactoryCertFile:       *factoryCert,
		FactoryKeyFile:        *factoryKey,
		RegistrationServerURL: *registrationURL,
	}

	log.Printf("Starting vehicle client for VIN: %s", client.VIN)
	log.Printf("Telemetry interval: %d seconds", *interval)

	// Step 1: Register with the registration server
	if err := client.Register(); err != nil {
		log.Fatalf("Registration failed: %v", err)
	}
	log.Println("✓ Successfully registered and obtained operational certificate")

	// Step 2: Authenticate with Keycloak to get JWT
	jwt, err := client.AuthenticateWithKeycloak()
	if err != nil {
		log.Fatalf("Keycloak authentication failed: %v", err)
	}
	log.Println("✓ Successfully authenticated with Keycloak and obtained JWT")

	// Step 3: Connect to NATS with JWT
	if err := client.ConnectToNATS(jwt); err != nil {
		log.Fatalf("NATS connection failed: %v", err)
	}
	log.Println("✓ Successfully connected to NATS")

	// Step 4: Publish telemetry data continuously
	log.Println("Starting continuous telemetry publishing...")
	if err := client.PublishTelemetryContinuously(*interval); err != nil {
		log.Fatalf("Failed to publish telemetry: %v", err)
	}
}

// Register performs the vehicle registration flow
func (v *VehicleClient) Register() error {
	log.Println("Step 1: Generating operational key pair...")

	// Generate a new RSA key pair for operational use
	privateKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return fmt.Errorf("failed to generate key pair: %w", err)
	}
	v.operationalKey = privateKey

	// Create a Certificate Signing Request (CSR)
	log.Println("Step 2: Creating Certificate Signing Request (CSR)...")
	csrPEM, err := v.createCSR(privateKey)
	if err != nil {
		return fmt.Errorf("failed to create CSR: %w", err)
	}

	// Load factory certificate and key for mTLS
	log.Println("Step 3: Loading factory-issued certificate for mTLS...")
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
	log.Printf("Step 4: Sending CSR to registration server at %s...", v.RegistrationServerURL)
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

	log.Println("Step 5: Parsing operational certificate...")
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

	// Save operational certificate and key to files for reuse
	if err := os.WriteFile("operational-cert.pem", v.operationalCertPEM, 0644); err != nil {
		log.Printf("Warning: Failed to save operational certificate: %v", err)
	} else {
		log.Println("  Saved operational certificate to operational-cert.pem")
	}

	keyPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "RSA PRIVATE KEY",
		Bytes: x509.MarshalPKCS1PrivateKey(v.operationalKey),
	})
	if err := os.WriteFile("operational-key.pem", keyPEM, 0600); err != nil {
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
	log.Println("Step 1: Configuring mTLS with operational certificate...")

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
	log.Printf("Step 2: Requesting JWT from Keycloak at %s...", v.keycloakURL)
	tokenURL := fmt.Sprintf("%s/realms/sdv-telemetry/protocol/openid-connect/token", v.keycloakURL)

	// For client certificate authentication, we use grant_type=client_credentials
	// The client_id should match the clientId configured in Keycloak (configured as "car")
	data := "grant_type=client_credentials&client_id=car"

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
	return tokenResp.AccessToken, nil
}

// ConnectToNATS establishes a connection to NATS using the JWT
func (v *VehicleClient) ConnectToNATS(jwt string) error {
	log.Printf("Connecting to NATS at %s with JWT...", v.natsURL)

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

	log.Println("  Connected to NATS successfully")

	// Wait a moment to ensure connection is stable
	time.Sleep(1 * time.Second)

	return nil
}

// buildTelemetrySubject constructs the NATS subject for telemetry publishing
// Supports configurable prefix via TELEMETRY_PREFIX environment variable
// Examples:
//   - Without prefix: telemetry.{VIN}.{sensor}
//   - With prefix "prod.bigtable": telemetry.prod.bigtable.{VIN}.{sensor}
func (v *VehicleClient) buildTelemetrySubject(sensor string) string {
	prefix := os.Getenv("TELEMETRY_PREFIX")
	if prefix != "" {
		return fmt.Sprintf("telemetry.%s.%s.%s", prefix, v.VIN, sensor)
	}
	return fmt.Sprintf("telemetry.%s.%s", v.VIN, sensor)
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
func (v *VehicleClient) PublishTelemetryContinuously(intervalSeconds int) error {
	// Initial battery state
	batteryVoltage := 12.6
	batteryCurrent := 45.2
	batterySoC := 85.5
	batteryTemp := 25.3

	// JWT refresh parameters
	var nc *nats.Conn
	var jwtExpiry time.Time
	refreshBuffer := 60 * time.Second // Refresh JWT 60 seconds before expiry

	// Helper function to get fresh connection
	refreshConnection := func() error {
		if nc != nil {
			nc.Close()
		}

		jwt, err := v.AuthenticateWithKeycloak()
		if err != nil {
			return fmt.Errorf("failed to get JWT: %w", err)
		}

		// JWT expires in 900 seconds (from Keycloak response)
		jwtExpiry = time.Now().Add(900 * time.Second)
		log.Printf("JWT refreshed, expires at: %s", jwtExpiry.Format(time.RFC3339))

		nc, err = nats.Connect(v.natsURL, nats.Token(jwt))
		if err != nil {
			return fmt.Errorf("failed to connect to NATS: %w", err)
		}

		return nil
	}

	// Initial connection
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

		// Keep values in realistic ranges
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

		subject := v.buildTelemetrySubject("battery")
		now := time.Now()

		// Create protobuf telemetry message
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

		// Marshal to protobuf
		payload, err := proto.Marshal(msg)
		if err != nil {
			log.Printf("Failed to marshal protobuf: %v", err)
			continue
		}

		if err := nc.Publish(subject, payload); err != nil {
			log.Printf("Failed to publish telemetry: %v", err)
			// Try to reconnect on publish error
			if err := refreshConnection(); err != nil {
				log.Printf("Failed to reconnect: %v", err)
			}
			continue
		}

		messageCount++
		log.Printf("[%d] Published protobuf to %s: SoC=%.1f%%, Voltage=%.2fV, Current=%.2fA, Temp=%.1f°C",
			messageCount, subject, batterySoC, batteryVoltage, batteryCurrent, batteryTemp)
	}

	return nil
}
