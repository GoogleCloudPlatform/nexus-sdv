# Vehicle Client - Certificate Flow Example

This Go client demonstrates the complete vehicle authentication and telemetry flow for the Software Defined Vehicle (SDV) platform.

## Certificate Flow

```
┌─────────────┐
│   Vehicle   │
│  (Client)   │
└──────┬──────┘
       │
       │ 1. Present Factory Certificate (mTLS)
       │    + Send CSR (Certificate Signing Request)
       ↓
┌──────────────────────┐
│ Registration Server  │
│                      │
│ • Validates Factory  │
│   Certificate        │
│ • Signs CSR          │
│ • Returns:           │
│   - Operational Cert │
│   - Keycloak URL     │
│   - NATS URL         │
└──────┬───────────────┘
       │
       │ 2. Present Operational Certificate (mTLS)
       │    + Request JWT Token
       ↓
┌──────────────────────┐
│     Keycloak         │
│                      │
│ • Validates Cert     │
│ • Checks Roles       │
│ • Returns JWT        │
└──────┬───────────────┘
       │
       │ 3. Connect with JWT
       │    + Publish Telemetry
       ↓
┌──────────────────────┐
│       NATS           │
│                      │
│ • Validates JWT via  │
│   Auth Callout       │
│ • Grants Permissions │
└──────────────────────┘
```

## Prerequisites

### 1. Factory-Issued Certificate

You need a client certificate issued by the local Factory CA with a specific CN format that the Registration Server requires.

**Required CN Format**: `VIN:{VIN} DEVICE:{DEVICE_ID}`

Example: `VIN:1HGBH41JXMN109186 DEVICE:1HGBH41JXMN109186`

#### Generate Factory Certificate (for development)

Use the provided script to generate properly formatted factory certificates:

```bash
# Generate factory certificate for a specific VIN
./generate-factory-cert.sh 1HGBH41JXMN109186

# Or use a custom output prefix
./generate-factory-cert.sh 1HGBH41JXMN109186 my-vehicle-cert
```

This creates:
- `factory-cert-key.pem` - Private key (keep secure)
- `factory-cert.pem` - Certificate
- `factory-cert-chain.pem` - Certificate chain (cert + CA)
- `factory-cert.csr` - Certificate signing request

**Note**: The script automatically uses the Factory CA located at `../../bootstrap/pki/factory-ca/`

### 2. Go Environment

- Go 1.24 or later
- Dependencies will be automatically installed via `go mod download`

## Build

### Using Make (Recommended)

```bash
# Build the application
make build

# Run tests
make test

# Download Certs
make downloadcerts

# Clean build artifacts
make clean

# Regenerate protobuf code (when .proto files change)
make proto

# Show all available targets
make help

#build and run the client
make all
```



### Manual Build

Alternatively, you can build manually:

```bash
# Download dependencies
go mod download

# Build the client
go build -o vehicle-client .
```

## Usage

### Quick Start with Run Script (Recommended)

The easiest way to run the vehicle client is using the provided run script, which automatically:
- Generates factory certificates (local or GCP-based)
- Builds the binary if needed
- Runs with appropriate parameters

```bash
# Using local PKI
./run-vehicle-client.sh local

# Using remote GCP PKI
./run-vehicle-client.sh remote

# With custom VIN
./run-vehicle-client.sh local VEHICLE001

# Full customization (VIN, registration URL, interval)
./run-vehicle-client.sh local VEHICLE001 https://registration.sdv-lal.com:8080 10
```

**Script Parameters:**
- `pki_strategy` (required): `local` or `remote`
- `VIN` (optional): Vehicle Identification Number (default: VEHICLE001)
- `REGISTRATION_URL` (optional): Registration server URL (default: https://registration.sdv-lal.com:8080)
- `INTERVAL` (optional): Telemetry interval in seconds (default: 5)

### Manual Usage

**Important**: The VIN parameter must match the VIN in your factory certificate's Common Name (CN).

```bash
./vehicle-client \
  -vin="VEHICLE001" \
  -factory-cert="vehicle001-factory-chain.pem" \
  -factory-key="vehicle001-factory-key.pem" \
  -registration-url="https://registration.sdv-lal.com:8080"
```

### Parameters

| Flag | Description | Default | Required |
|------|-------------|---------|----------|
| `-vin` | Vehicle Identification Number (must match certificate CN) | `1HGBH41JXMN109186` | Yes |
| `-factory-cert` | Path to factory-issued certificate chain | `factory-cert.pem` | Yes |
| `-factory-key` | Path to factory-issued private key | `factory-key.pem` | Yes |
| `-registration-url` | Registration server URL | Value of `REGISTRATION_URL` env var | Yes (via flag or env) |
| `-interval` | Telemetry publishing interval in seconds | `5` | No |

**Note**: The `-registration-url` can be provided either as a command-line flag or via the `REGISTRATION_URL` environment variable.

### Environment Variables

| Variable | Description | Example | Default |
|----------|-------------|---------|---------|
| `REGISTRATION_URL` | Registration server URL (alternative to `-registration-url` flag) | `https://34.185.214.249:8080` | - |
| `TELEMETRY_PREFIX` | Optional prefix for telemetry NATS subjects | `prod.bigtable` | - |

#### TELEMETRY_PREFIX Examples

Without prefix (default):
```bash
# Publishes to: telemetry.{VIN}.battery
./vehicle-client -vin vehicle001 ...
# → telemetry.vehicle001.battery
```

With prefix:
```bash
# Publishes to: telemetry.{PREFIX}.{VIN}.battery
TELEMETRY_PREFIX="prod.bigtable" ./vehicle-client -vin vehicle001 ...
# → telemetry.prod.bigtable.vehicle001.battery
```

This allows the NATS-Bigtable connector to subscribe to specific environments:
- Development: `telemetry.dev.>` or `telemetry.{VIN}.>`
- Production: `telemetry.prod.bigtable.>`

## Expected Output

```
2025/11/02 12:00:00 Starting vehicle client for VIN: 1HGBH41JXMN109186
2025/11/02 12:00:00 Step 1: Generating operational key pair...
2025/11/02 12:00:00 Step 2: Creating Certificate Signing Request (CSR)...
2025/11/02 12:00:00 Step 3: Loading factory-issued certificate for mTLS...
2025/11/02 12:00:00 Step 4: Sending CSR to registration server at https://registration.sdv-lal.com:8080...
2025/11/02 12:00:01 Step 5: Parsing operational certificate...
2025/11/02 12:00:01   Keycloak URL: https://keycloak.sdv-lal.com:8443
2025/11/02 12:00:01   NATS URL: nats://nats.sdv-lal.com:4222
2025/11/02 12:00:01   Certificate valid until: 2025-12-02 12:00:01 +0000 UTC
2025/11/02 12:00:01 ✓ Successfully registered and obtained operational certificate
2025/11/02 12:00:01 Step 1: Configuring mTLS with operational certificate...
2025/11/02 12:00:01 Step 2: Requesting JWT from Keycloak at https://keycloak.sdv-lal.com:8443...
2025/11/02 12:00:02   Token expires in: 300 seconds
2025/11/02 12:00:02 ✓ Successfully authenticated with Keycloak and obtained JWT
2025/11/02 12:00:02 Connecting to NATS at nats://nats.sdv-lal.com:4222 with JWT...
2025/11/02 12:00:02   Connected to NATS successfully
2025/11/02 12:00:03 ✓ Successfully connected to NATS
2025/11/02 12:00:03 Publishing telemetry data...
2025/11/02 12:00:04   Published telemetry to subject: telemetry.1HGBH41JXMN109186.battery
2025/11/02 12:00:04   Payload: {"battery_current":45.2,"battery_soc":85.5,"battery_temp":25.3,"battery_voltage":12.6,"timestamp":1730548804,"vin":"1HGBH41JXMN109186"}
2025/11/02 12:00:04 ✓ Successfully published telemetry data
2025/11/02 12:00:04 Vehicle client completed successfully!
```

## Architecture Details

### 1. Registration Phase

**Input**: Factory-issued certificate (from Google CA)

**Process**:
1. Generate new RSA key pair for operational use
2. Create CSR with VIN as Common Name
3. Send CSR to Registration Server via mTLS
4. Receive signed operational certificate

**Output**:
- Operational certificate
- Keycloak URL
- NATS URL

### 2. Authentication Phase

**Input**: Operational certificate

**Process**:
1. Configure mTLS with operational certificate
2. Request JWT from Keycloak using certificate authentication
3. Receive JWT with vehicle roles and permissions

**Output**: JWT token

### 3. Telemetry Phase

**Input**: JWT token

**Process**:
1. Connect to NATS with JWT authentication
2. NATS validates JWT via auth-callout service
3. Publish telemetry data to authorized subjects

**Output**: Successfully published telemetry

## Security Considerations

### Production Deployment

1. **Certificate Verification**: Enable certificate verification by setting `InsecureSkipVerify: false` and providing proper CA certificates

2. **Certificate Storage**: Store factory certificates securely (HSM, TPM, secure enclave)

3. **Key Protection**: Never log or expose private keys

4. **Token Refresh**: Implement JWT token refresh before expiration

5. **Error Handling**: Implement proper retry logic with exponential backoff

## Troubleshooting

### Registration Fails with "Client Certificate missing" or "VIN or Deviceid not found in Certificate"

**Symptom**: `registration failed with status 401: {"error":{"code":"401","message":"Client Certificate missing"}}`

**Solution**:
- Ensure factory certificate and key are valid PEM files
- Check that the certificate is issued by the Factory CA (local or GCP CAS)
- **Verify the VIN parameter matches the VIN in the certificate CN**
  ```bash
  # Check your certificate's VIN
  openssl x509 -in vehicle001-factory-chain.pem -noout -subject
  # Should show: CN=VIN:VEHICLE001 DEVICE:VEHICLE001
  ```
- Use the correct VIN when running the client:
  ```bash
  ./vehicle-client -vin="VEHICLE001" -factory-cert="vehicle001-factory-chain.pem" ...
  ```
- Use `generate-factory-cert-gcp.sh` to create properly formatted certificates

### Keycloak Authentication Fails with "Invalid client credentials"

**Symptom**: `token request failed with status 401: {"error":"invalid_client","error_description":"Invalid client or Invalid client credentials"}`

**Possible Causes**:
1. **Certificate CN format mismatch**: Keycloak expects CN format `VIN:xxx DEVICE:yyy`
   - Check operational certificate: `openssl x509 -in operational-cert.pem -noout -subject`
   - Should NOT contain escape sequences like `\13`
   - If you see escape sequences, rebuild the client (the CN encoding was fixed)

2. **Keycloak truststore missing Registration CA**:
   - Keycloak must trust the Registration CA that signed the operational certificate
   - Verify CA certificates exist in Keycloak deployment: `iac/helm/keycloak/files/registration-ca.crt.pem`
   - Redeploy Keycloak if CA certificates are missing

3. **Client 'car' not configured in Keycloak**:
   - Verify the realm name is "sdv-telemetry"
   - Check that client "car" exists with certificate authentication enabled

### NATS Connection Fails

- Verify the JWT is valid and not expired
- Check that the vehicle has the required roles (telemetry-client, edge-device)
- Ensure the NATS auth-callout service is running

## Development

### Run Tests

```bash
make test
# or manually:
go test -v ./...
```

### Regenerate Protobuf Code

When you modify `telemetry/telemetry.proto`, regenerate the Go code:

```bash
make proto
# or manually:
protoc --go_out=. --go_opt=paths=source_relative telemetry/*.proto
```

**Note**: Requires `protoc` and `protoc-gen-go` to be installed.

### Format Code

```bash
go fmt ./...
```

### Update Dependencies

```bash
go mod tidy
go mod download
```

## Related Components

- **Registration Server**: `bootstrap/server/` - Rust server that issues operational certificates
- **Keycloak**: `iac/helm/keycloak/` - Identity provider for JWT issuance
- **NATS Auth Callout**: `base-services/auth-callout/` - Go service that validates JWTs
- **NATS**: `iac/helm/nats/` - Message broker for telemetry

## License

This is an example client for the SDV platform.
