# Telemetry Subscriber

A NATS subscriber client that listens to vehicle telemetry data published on NATS subjects.

## Prerequisites

- **Operational certificate and key**: Generated automatically by the vehicle-client during registration
  - The vehicle-client saves these to `operational-cert.pem` and `operational-key.pem` in the vehicle-client directory
  - These certificates are valid for 1 year
  - You must run the vehicle-client at least once to generate these certificates
- Access to Keycloak for JWT authentication (e.g., `keycloak.nexus-sdv.io:8443`)
- Access to NATS server (e.g., `nats.nexus-sdv.io:4222`)

## How It Works

1. Authenticates with Keycloak using an operational certificate to get a JWT token
2. Connects to NATS using the JWT token
3. Subscribes to the specified telemetry subject
4. Receives and displays telemetry messages in JSON format

## Usage

### Quick Start with Run Script (Recommended)

The easiest way to run the telemetry subscriber is using the provided run script, which automatically:
- Locates operational certificates from vehicle-client
- Builds the binary if needed
- Runs with appropriate parameters

```bash
# First, run vehicle-client to generate operational certificates
cd ../vehicle-client
./run-vehicle-client.sh local

# Then in a new terminal, run the subscriber
cd ../telemetry-subscriber
./run-telemetry-subscriber.sh local

# Subscribe to wildcard subjects
./run-telemetry-subscriber.sh local "telemetry.*.battery"

# Full customization (subject, Keycloak URL, NATS URL)
./run-telemetry-subscriber.sh local "telemetry.VEHICLE001.battery" https://keycloak.nexus-sdv.io nats://nats.nexus-sdv.io:4222
```

**Script Parameters:**
- `pki_strategy` (required): `local` or `remote` (must match what was used for vehicle-client)
- `SUBJECT` (optional): NATS subject to subscribe (default: telemetry.VEHICLE001.battery)
- `KEYCLOAK_URL` (optional): Keycloak URL (default: https://keycloak.nexus-sdv.io)
- `NATS_URL` (optional): NATS URL (default: nats://nats.nexus-sdv.io:4222)

### Manual Usage

#### Step 1: Generate Operational Certificates

First, run the vehicle-client to generate operational certificates. **Important**: Use a VIN that matches your factory certificate.

```bash
cd ../vehicle-client
./vehicle-client \
  -vin="VEHICLE001" \
  -factory-cert="vehicle001-factory-chain.pem" \
  -factory-key="vehicle001-factory-key.pem" \
  -registration-url="https://registration.nexus-sdv.io:8080"
```

This will create:
- `operational-cert.pem` - Operational certificate issued by registration server
- `operational-key.pem` - Private key for the operational certificate

#### Step 2: Start the Subscriber

Open a **new terminal** and run the subscriber:

```bash
cd ../telemetry-subscriber
./telemetry-subscriber \
  -operational-cert="../vehicle-client/operational-cert.pem" \
  -operational-key="../vehicle-client/operational-key.pem" \
  -subject="telemetry.VEHICLE001.battery"
```

#### Step 3: Publish Telemetry

In the first terminal (or another new terminal), run the vehicle-client to publish telemetry:

```bash
cd ../vehicle-client
./vehicle-client \
  -vin="VEHICLE001" \
  -factory-cert="vehicle001-factory-chain.pem" \
  -factory-key="vehicle001-factory-key.pem" \
  -registration-url="https://registration.nexus-sdv.io:8080"
```

The subscriber will receive and display the telemetry data:

```json
{
  "battery_current": 45.2,
  "battery_soc": 85.5,
  "battery_temp": 25.3,
  "battery_voltage": 12.6,
  "timestamp": 1762797742,
  "vin": "1HGBH41JXMN109186"
}
```

## Command Line Options

- `-operational-cert` - Path to operational certificate (required)
- `-operational-key` - Path to operational private key (required)
- `-subject` - NATS subject to subscribe to (default: "telemetry.1HGBH41JXMN109186.battery")
- `-keycloak-url` - Keycloak URL (default: "https://keycloak.nexus-sdv.io")
- `-nats-url` - NATS URL (default: "nats://nats.nexus-sdv.io:4222")

## Example: Subscribe to All Battery Telemetry

Using the run script:
```bash
./run-telemetry-subscriber.sh local "telemetry.*.battery"
```

Or manually:
```bash
./telemetry-subscriber \
  -operational-cert="../vehicle-client/operational-cert.pem" \
  -operational-key="../vehicle-client/operational-key.pem" \
  -subject="telemetry.*.battery"
```

## Stopping the Subscriber

Press `Ctrl+C` to gracefully shutdown the subscriber.

## Building

### Using Make (Recommended)

```bash
# Build the application
make build

# Run tests
make test

# Clean build artifacts
make clean

# Show all available targets
make help
```

### Manual Build

Alternatively, you can build manually:

```bash
go build -o telemetry-subscriber .
```

## Notes

- The subscriber uses the same `vehicle-client` Keycloak client ID for authentication
- Operational certificates are valid for 1 year and must be renewed by re-running the registration process
- The subscriber can listen to wildcard subjects using NATS wildcard patterns (e.g., `telemetry.*.battery` or `telemetry.>`)
