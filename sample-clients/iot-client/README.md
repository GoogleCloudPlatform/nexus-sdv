# Nexus IoT Client (ESP32)

This firmware demonstrates the Nexus platform for IoT use cases such as geolocation of things like construction equipment:
Authentication via Keycloak and Protobuf telemetry publishing via NATS.

The initial registration (factory certificate → registration server → operational certificate) is handled by an external program. This firmware assumes pre-provisioned operational certificates on the device filesystem.

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

### Why this client?

This IoT client is a fully functional reference implementation that covers the complete device-to-cloud path — 
from certificate-based authentication through Keycloak (mTLS, JWT) to protobuf-encoded telemetry publishing via NATS,
including deep sleep power management and as an example GPS integration.
It is built entirely on open standards and open-source tooling, with no proprietary dependencies or vendor lock-in.

## Prerequisites

- [PlatformIO CLI](https://docs.platformio.org/en/latest/core/installation/methods/installer-script.html) or the VSCode PlatformIO extension
- [protoc](https://protobuf.dev/installation/) compiler (`brew install protobuf`)
- [Nanopb](https://github.com/nanopb/nanopb) protoc plugin (`brew install nanopb`)
- ESP32 development board
- Operational certificate, private key, and CA certificate (obtained via the external registration program)

## Quick Start

### 1. Generate protobuf code

```bash
cd sample-clients/iot-client
make proto
```

This copies `telemetry.proto` from the shared `proto/` directory and generates `src/telemetry.pb.h` and `src/telemetry.pb.c` using Nanopb.

### 2. Configure

```bash
make config
```

This copies `config.example.h` to `include/config.h` (which is gitignored). Then edit `include/config.h` with your settings:

```c
#define WIFI_SSID           "your-wifi-ssid"
#define WIFI_PASSWORD       "your-wifi-password"
#define DEVICE_ID           "DEVICE001"
#define KEYCLOAK_URL        "https://keycloak.example.com"
#define NATS_URL            "nats://nats-server.example.com:4222"
```

### 3. Provision certificates

Place the operational certificates (obtained from the external registration program) into `data/certs/`:

```
data/certs/operational.crt.pem   # Operational certificate
data/certs/operational.key.pem   # Operational private key
data/certs/ca.crt.pem            # CA certificate (for Keycloak TLS verification)
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

### How to start a local development NATS Server

```bash
docker run -p 4222:4222 nats:latest --debug -V
```

See [NATS Server commandline options](https://hub.docker.com/_/nats#commandline-options) for more information.

## Lifecycle

The firmware executes a 5-step flow:

1. **WiFi + NTP** -- Connect to WiFi, sync time via NTP (required for TLS certificate validation)
2. **Load Certificates** -- Mount LittleFS, load operational cert/key and CA cert from flash
3. **Authentication** -- Get JWT from Keycloak via mTLS (operational cert), `client_credentials` grant
4. **NATS Connect** -- Connect to NATS broker with JWT authentication
5. **Telemetry Loop** -- Publish protobuf-serialized `TelemetryMessage` at a configurable interval

The JWT token is automatically refreshed before it expires. When a refresh is needed, the firmware disconnects from NATS, requests a new token from Keycloak, and reconnects.

```
WiFi → NTP → Load Certs → Authenticate → NATS Connect → Send Telemetry
                            ↑                                    |
                            └──── (token expiring) ──────────────┘
```

## Serial Output

Expected output on successful run:

```
==========================================
  Nexus SDV IoT Client
==========================================
  DEVICE ID:             DEVICE001
  Keycloak URL:          https://keycloak.example.com
  NATS URL:              nats://nats-server.example.com:4222
  Telemetry interval:    300000 ms
  Free heap:             286068 bytes
==========================================

[Main] Step 1/5: Connecting to WiFi...
[WiFi] Connected. IP: 192.168.1.42
[Main] Step 2/5: Synchronizing time via NTP...
[Main] Time synced: 2026-02-24 10:30:00 UTC
[Main] Step 3/5: Loading certificates...
[CertMgr] LittleFS mounted.
[CertMgr] Loaded /certs/operational.crt.pem (1234 bytes)
[CertMgr] Loaded /certs/operational.key.pem (1704 bytes)
[CertMgr] Loaded /certs/ca.crt.pem (1234 bytes)
[Main] Step 4/5: Getting JWT from Keycloak...
[Auth] Token acquired (expires in 300 s).
[Main] Token valid for 300 s.
[Main] Step 5/5: Connecting to NATS...
[NATS] Connected and authenticated.
[Telemetry] Published 160 bytes to telemetry.prod.bigtable.DEVICE001
[Main] Message 1 sent.
...
[Main] Token expiring soon. Re-authenticating...
[Main] Step 4/5: Getting JWT from Keycloak...
[Auth] Token acquired (expires in 300 s).
[Main] Step 5/5: Connecting to NATS...
[NATS] Connected and authenticated.
```

## Architecture

```
+------------------+     +----------+     +------+
| ESP32            |     | Keycloak |     | NATS |
|                  |     |          |     |      |
| 1. Load op cert  |     |          |     |      |
|    + key from    |     |          |     |      |
|    LittleFS      |     |          |     |      |
|                  |     |          |     |      |
| 2. Get JWT ------+---->| Validate |     |      |
|    (mTLS:op cert)|     | cert     |     |      |
|    <-------------+-----| Return   |     |      |
|                  |     | JWT      |     |      |
|                  |     |          |     |      |
| 3. PUB telemetry-+-----+----------+---->| Auth |
|    (JWT token)   |     |          |     | Store|
+------------------+     +----------+     +------+
```

## Board Support

| Board | Environment | Status |
|-------|-------------|--------|
| ESP32 DevKit | `esp32dev` | Primary target |
| ESP32-S3 DevKit | `esp32s3` | Supported |
| WEMOS D1 Mini ESP32 | `esp32_d1_mini` | Supported |

Other PlatformIO Arduino-compatible boards with WiFi and mbedTLS may work with minimal changes.

## Key Libraries

| Library | Purpose |
|---------|---------|
| mbedTLS (built-in) | TLS/mTLS for Keycloak authentication |
| Nanopb | Lightweight protobuf encoding (~3KB code) |
| ArduinoJson | JSON parsing for Keycloak token response |
| LittleFS | Certificate storage on flash |

## Notes

- **Certificates** are pre-provisioned via `make uploadfs`. The initial registration (factory cert → registration server → operational cert) is handled by an external program.
- **Token refresh** happens automatically. The firmware re-authenticates with Keycloak 30 seconds before the JWT expires, then reconnects to NATS with the new token.
- The **NATS client** is a minimal implementation supporting only CONNECT, PUB, and PING/PONG -- sufficient for telemetry publishing.
- **Protobuf messages** use Nanopb for minimal memory footprint. The `.options` file constrains field sizes for static allocation.
