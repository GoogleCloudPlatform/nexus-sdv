# Nexus SDV IoT Client (ESP32)

ESP32 firmware that demonstrates the Nexus SDV vehicle-to-cloud telemetry flow: registration, authentication, and protobuf telemetry publishing via NATS.

## Why Nanopb?

The IoT client targets the ESP32, a microcontroller with ~520KB of SRAM and no operating system heap management like a desktop.
The standard C++ protobuf library (libprotobuf) is completely impractical here — it requires dynamic memory allocation,
C++ exceptions, and pulls in hundreds of KB of code.

The key insight is in the `.options` file at `proto/telemetry.options`.

In standard protobuf, string and repeated fields are dynamically-sized.
Nanopb uses this .options file to turn them into fixed-size C arrays (e.g., `char message_id[40]` instead of `std::string`).
This means the entire TelemetryMessage struct has a known size at compile time — no heap allocations at all during serialization.

- The `.options` file is the bridge between protobuf's flexible schema and the ESP32's need for deterministic memory.
  Without it, Nanopb would fall back to callback-based encoding, which is much harder to use.
- `max_count:8` on `sensor_data` means the firmware can send at most 8 sensor readings per message — a deliberate constraint that keeps the struct small enough to live on the stack.
- The `-DPB_FIELD_32BIT=1` build flag in `platformio.ini` allows field tags above 255 and structs larger than 255 bytes, at the cost of slightly larger generated code.

## Prerequisites

- [PlatformIO CLI](https://docs.platformio.org/en/latest/core/installation/methods/installer-script.html) or the VSCode PlatformIO extension
- `protoc` compiler (`brew install protobuf`)
- [Nanopb](https://github.com/nanopb/nanopb) protoc plugin (`brew install nanopb`)
- ESP32 development board (ESP32, ESP32-S3, ESP32-C3)
- Factory certificate and key (generated via the platform's PKI tooling)

## Quick Start

### 1. Generate protobuf code

```bash
cd sample-clients/iot-client
make proto
```

This copies `telemetry.proto` from the shared `proto/` directory and generates `src/telemetry.pb.h` and `src/telemetry.pb.c` using Nanopb.

### 2. Configure

Edit `include/config.h` with your settings:

```c
#define WIFI_SSID           "your-wifi-ssid"
#define WIFI_PASSWORD       "your-wifi-password"
#define DEVICE_ID           "DEVICE001"
#define REGISTRATION_URL    "https://registration.sdv-lal.com:8080"
```

### 3. Provision certificates

Copy your factory certificates into `data/certs/`:

**Local PKI (development):**
```bash
cp ../vehicle-VEHICLE001-factory-chain.pem data/certs/factory.crt.pem
cp ../vehicle-VEHICLE001-factory-key.pem data/certs/factory.key.pem
cp ../../base-services/registration/pki/server-ca/ca.crt.pem data/certs/ca.crt.pem
```

**Remote PKI (GCP):**
```bash
cp ../vehicle-VEHICLE001-factory-chain.pem data/certs/factory.crt.pem
cp ../vehicle-VEHICLE001-factory-key.pem data/certs/factory.key.pem
gcloud secrets versions access latest --secret="REGISTRATION_SERVER_TLS_CERT" > data/certs/ca.crt.pem
```

### 4. Upload filesystem and firmware

```bash
make uploadfs    # Upload certificates to ESP32 LittleFS
make upload      # Build and flash firmware
make monitor     # Open serial monitor
```

Or all at once:
```bash
make all
```

### Start a local development NATS Server

```bash
docker run -p 4222:4222 nats:latest --debug -V
```

See [NATS Server commandline options](https://hub.docker.com/_/nats#commandline-options) for more information.

## Lifecycle

The firmware executes the same 4-stage flow as the Python and Go clients:

1. **WiFi + NTP** -- Connect to WiFi, sync time for TLS validation
2. **Registration** -- Generate RSA-2048 keypair + CSR, POST to registration server via mTLS (factory cert), receive operational certificate and service URLs
3. **Authentication** -- Get JWT from Keycloak via mTLS (operational cert), `client_credentials` grant
4. **Telemetry** -- Connect to NATS with JWT, publish protobuf-serialized `TelemetryMessage`

## Serial Output

Expected output on successful run:

```
==========================================
  Nexus SDV IoT Client
==========================================
  VIN:              VEHICLE001
  Registration URL: https://registration.sdv-lal.com:8080
  Telemetry interval: 5000 ms
==========================================

[Main] Step 1/7: Connecting to WiFi...
[WiFi] Connected. IP: 192.168.1.42
[Main] Synchronizing time via NTP...
[Main] Time synced: 2025-01-15 10:30:00 UTC
[Main] Step 2/7: Loading certificates...
[CertMgr] LittleFS mounted, factory certificates verified.
[Main] Step 3/7: Generating operational keypair...
[CertMgr] Key generated in 23456 ms.
[Main] Step 4/7: Creating CSR...
[CertMgr] CSR created for VIN:VEHICLE001 (512 bytes)
[Main] Step 5/7: Registering with server...
[Reg] Registration successful.
[Main] Step 6/7: Getting JWT from Keycloak...
[Auth] Token acquired (expires in 300 s).
[Main] Step 7/7: Connecting to NATS...
[NATS] Connected and authenticated.
[Main] Sending 7 telemetry messages (interval: 5000 ms)...
[Telemetry] Published 128 bytes to telemetry.prod.bigtable.VEHICLE001
[Main] Message 1/7 sent.
...
==========================================
  IoT Client completed successfully.
==========================================
```

## Architecture

```
+------------------+     +--------------------+     +----------+     +------+
| ESP32            |     | Registration       |     | Keycloak |     | NATS |
|                  |     | Server             |     |          |     |      |
| 1. Generate RSA  |     |                    |     |          |     |      |
|    keypair + CSR |     |                    |     |          |     |      |
|                  |     |                    |     |          |     |      |
| 2. POST CSR ----+---->| Validate & sign    |     |          |     |      |
|    (mTLS:factory)|     | Return op cert     |     |          |     |      |
|    <-------------+-----| + URLs             |     |          |     |      |
|                  |     |                    |     |          |     |      |
| 3. Get JWT ------+-----+--------------------+---->| Validate |     |      |
|    (mTLS:op cert)|     |                    |     | Return   |     |      |
|    <-------------+-----+--------------------+-----| JWT      |     |      |
|                  |     |                    |     |          |     |      |
| 4. PUB telemetry-+-----+--------------------+-----+----------+---->| Auth |
|    (JWT token)   |     |                    |     |          |     | Store|
+------------------+     +--------------------+     +----------+     +------+
```

## Board Support

| Board | Environment | Status |
|-------|-------------|--------|
| ESP32 DevKit | `esp32dev` | Primary target |
| ESP32-S3 DevKit | `esp32s3` | Supported |

Other PlatformIO Arduino-compatible boards with WiFi and mbedTLS may work with minimal changes.

## Key Libraries

| Library | Purpose |
|---------|---------|
| mbedTLS (built-in) | RSA key generation, X.509 CSR, TLS/mTLS |
| Nanopb | Lightweight protobuf encoding (~3KB code) |
| ArduinoJson | JSON parsing for registration/auth responses |
| LittleFS | Certificate storage on flash |

## Notes

- **RSA key generation** takes 15-60 seconds on ESP32 due to limited CPU. The firmware logs progress.
- **Operational certificates** are persisted to LittleFS after registration, surviving reboots. To re-register, delete them from the filesystem or reflash.
- The **NATS client** is a minimal implementation supporting only CONNECT, PUB, and PING/PONG -- sufficient for telemetry publishing.
- **Protobuf messages** use Nanopb for minimal memory footprint. The `.options` file constrains field sizes for static allocation.
