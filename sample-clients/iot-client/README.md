# Nexus IoT Client (ESP32)

This firmware demonstrates the Nexus platform for IoT use cases such as geolocation of things like construction equipment:
Authentication via Keycloak and Protobuf telemetry publishing via NATS.

The initial registration (factory certificate → registration server → operational certificate) is handled by an external program.
This firmware assumes pre-provisioned operational certificates on the device filesystem.

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

This copies `config.example.h` to `include/config.h` (which is gitignored).
Then edit `include/config.h` with your settings:

```c
#define WIFI_SSID           "your-wifi-ssid"
#define WIFI_PASSWORD       "your-wifi-password"
#define DEVICE_ID           "DEVICE001"
#define KEYCLOAK_URL        "https://keycloak.example.com"
#define NATS_URL            "nats://nats-server.example.com:4222"
```

#### Config Flags

| Flag                    | Default | Description                                                                                                         |
|-------------------------|---------|---------------------------------------------------------------------------------------------------------------------|
| `SKIP_KEYCLOAK_AUTH`    | `false` | Skip certificate loading and Keycloak authentication. Connects to NATS without a JWT. Useful for local development. |
| `DEEP_SLEEP_ENABLED`    | `false` | When true, send one telemetry message per wake cycle and enter deep sleep. When false, run continuously.            |
| `DEEP_SLEEP_DURATION_S` | `300`   | Deep sleep duration in seconds (5 minutes).                                                                         |
| `GPS_WAIT_FOR_FIX`      | `false` | Wait for a GPS fix before connecting to NATS. Sends without GPS if the timeout expires.                             |
| `GPS_FIX_TIMEOUT_S`     | `90`    | Maximum seconds to wait for a GPS fix before sending without it. Set to `0` to wait indefinitely.                   |

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

### Local Development with NATS

Start a local NATS server with a protobuf-decoding subscriber:

```bash
make nats
```

This runs `docker compose up` with two services: a NATS server (port 4222) and a subscriber that auto-decodes and prints telemetry messages as JSON.

Set `SKIP_KEYCLOAK_AUTH` to `true` in your `config.h` to skip certificate loading and authentication when using a local NATS server.

#### NATS monitoring

The NATS server exposes an HTTP monitoring endpoint:

- [http://localhost:8222/connz](http://localhost:8222/connz) — active connections
- [http://localhost:8222/subsz](http://localhost:8222/subsz) — subscriptions
- [http://localhost:8222/varz](http://localhost:8222/varz) — server statistics

## Lifecycle

The firmware executes a 5-step flow:

1. **WiFi + NTP** -- Connect to WiFi, sync time via NTP (required for TLS certificate validation)
2. **Load Certificates** -- Mount LittleFS, load operational cert/key and CA cert from flash
3. **Authentication** -- Get JWT from Keycloak via mTLS (operational cert), `client_credentials` grant
4. **NATS Connect** -- Connect to NATS broker with JWT authentication
5. **Telemetry Loop** -- Publish protobuf-serialized `TelemetryMessage` at a configurable interval

The JWT is automatically refreshed before expiry. See [ARCHITECTURE.md](ARCHITECTURE.md) for design details.

## Serial Output

Expected output on successful run:

```
==========================================
  Nexus SDV IoT Client
==========================================
  DEVICE ID:             DEVICE001
  Keycloak URL:          https://keycloak.example.com
  NATS URL:              nats://nats-server.example.com:4222
  Keycloak auth:         enabled
  Telemetry interval:    300000 ms
  Deep sleep:            OFF
  Free heap:             286068 bytes
==========================================

[Main] Step 1/5: Connecting to WiFi...
[WiFi] Connected. IP: 192.168.1.42
[Main] Step 2/5: Synchronizing time via NTP...
[Main] Time synced: 2026-02-24 10:30:00 UTC
[Main] Step 3/5: Loading certificates...
[FS] LittleFS mounted.
[FS] Loaded /certs/operational.crt.pem (1234 bytes)
[FS] Loaded /certs/operational.key.pem (1704 bytes)
[FS] Loaded /certs/ca.crt.pem (1234 bytes)
[Main] Step 4/5: Getting JWT from Keycloak...
[Auth] Token acquired (expires in 300 s).
[Main] Token valid for 300 s.
[Main] Step 5/5: Connecting to NATS...
[NATS] Connected and authenticated.
[Telemetry] Published 160 bytes to telemetry.prod.bigtable.DEVICE001
[Main] Message 1 sent.
```

## Board Support

| Board               | Environment     | Status         |
|---------------------|-----------------|----------------|
| ESP32 DevKit        | `esp32dev`      | Primary target |
| ESP32-S3 DevKit     | `esp32s3`       | Supported      |
| WEMOS D1 Mini ESP32 | `esp32_d1_mini` | Supported      |

Other PlatformIO Arduino-compatible boards with WiFi and mbedTLS may work with minimal changes.

## Key Libraries

| Library            | Purpose                                   |
|--------------------|-------------------------------------------|
| mbedTLS (built-in) | TLS/mTLS for Keycloak authentication      |
| Nanopb             | Lightweight protobuf encoding (~3KB code) |
| ArduinoJson        | JSON parsing for Keycloak token response  |
| LittleFS           | Certificate storage on flash              |
| TinyGPSPlus        | NMEA GPS parsing for location telemetry   |

## Build System

### Makefile Targets

PlatformIO handles the embedded toolchain (compiler, linker, flash upload).
The `Makefile` provides developer convenience targets.

The Makefile targets utilize the `pio` command; consequently, this command must be accessible within the shell environment.
PlatformIO terminals, for instance, provide this by default.


- `make config`: create `include/config.h` from `config.example.h` (won't overwrite)
- `make proto`: copy shared `.proto` file and generate nanopb C code
- `make build`: compile firmware
- `make upload`: flash to ESP32
- `make uploadfs`: flash LittleFS filesystem (certificates) to ESP32
- `make monitor`: open serial console
- `make nats`: start NATS server + protobuf subscriber (`docker compose up`)
- `make clean`: remove build artifacts and generated proto files

### Code Generation

The `make proto` target runs two `protoc` invocations:

```shell
protoc --nanopb_out=src/ google/protobuf/timestamp.proto
protoc --nanopb_opt=-fproto/telemetry.options --nanopb_out=src/ -I proto/ proto/telemetry.proto
```

1. **First invocation**: generates `src/google/protobuf/timestamp.pb.h/c` for the well-known `Timestamp` type imported by `telemetry.proto`.
2. **Second invocation**: generates `src/telemetry.pb.h/c` with the `-f` flag explicitly pointing to the `.options` file. Auto-discovery of options files looks relative to the working directory, not the `-I` include paths, so explicit `-f` is required.

The shared `proto/telemetry.proto` is the source of truth for all clients (Go, Python, ESP32). Each client copies it locally and generates language-specific code: `--go_out` for Go, `--python_out` for Python, `--nanopb_out` for embedded C.

### Nanopb Runtime vs Generator

The PlatformIO `lib_deps` includes `nanopb/Nanopb@^0.4.9`, which provides the **C runtime** (`pb.h`, `pb_encode.c`, `pb_decode.c`) compiled into the firmware. The **code generator** (`protoc-gen-nanopb`) is installed separately via Homebrew and runs on the developer's machine during `make proto`. These serve different roles:

| Component                    | Installed via                  | Runs on     | Purpose                            |
|------------------------------|--------------------------------|-------------|------------------------------------|
| `nanopb` (Homebrew)          | `brew install nanopb`          | Dev machine | `protoc-gen-nanopb` code generator |
| `nanopb/Nanopb` (PlatformIO) | `lib_deps` in `platformio.ini` | ESP32       | C runtime for encoding/decoding    |

### Build Flag: PB_FIELD_32BIT

The `platformio.ini` build flag `-DPB_FIELD_32BIT=1` allows nanopb to handle field tags above 255 and struct sizes larger than 255 bytes. Without it, nanopb uses 8-bit counters to minimize code size, which would fail for the telemetry message struct.
