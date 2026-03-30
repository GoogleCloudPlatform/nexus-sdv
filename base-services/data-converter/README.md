# Data Converter Service

Converts telemetry data from IoT protocols (MQTT) into the Nexus Protobuf format (`TelemetryMessage`) and publishes it to NATS.

## Prerequisites

- Go 1.24+
- Docker & Docker Compose
- `protoc` with `protoc-gen-go` (for proto regeneration only)
- NATS CLI (`nats`) for subscribing to output
- Mosquitto clients (`mosquitto_pub`) for publishing test data

### Install optional tools

```bash
# NATS CLI
brew install nats-io/nats-tools/nats

# Mosquitto clients
brew install mosquitto

# protoc-gen-go (only needed if regenerating proto)
go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
```

## Local Test Environment

### Start the full stack

```bash
docker compose up -d
```

This starts:
- **Mosquitto** (MQTT broker) on `localhost:1883` — anonymous access enabled
- **NATS** on `localhost:4222` — with JetStream, monitoring on `localhost:8222`
- **Data Converter** — connected to both, using `config/config.example.yaml`
- **NATS Subscriber** — decodes and pretty-prints TelemetryMessages from NATS

### End-to-end test

Terminal 1 — watch decoded NATS output:
```bash
docker compose logs -f nats-subscriber
```

Terminal 2 — publish a test message via MQTT:
```bash
mosquitto_pub -t "telemetry/deviceId001/sensors/temp" -m '{"name":"temperature","value":"42.3"}'
```

Expected output: decoded TelemetryMessage with `device_id: "deviceId001"` on subject `telemetry.deviceId001.temperature`.

### Inspect MQTT messages

Subscribe to all messages on the Mosquitto broker (runs inside the container, no local install needed):

```bash
docker compose exec mosquitto mosquitto_sub -t "telemetry/#" -v
```

### NATS monitoring

The NATS server exposes an HTTP monitoring endpoint:

- [http://localhost:8222/connz](http://localhost:8222/connz) — active connections
- [http://localhost:8222/subsz](http://localhost:8222/subsz) — subscriptions
- [http://localhost:8222/varz](http://localhost:8222/varz) — server statistics

### View logs

```bash
docker compose logs -f data-converter
```

### Stop

```bash
docker compose down
```

### Running outside Docker

For local development without rebuilding the container:

```bash
docker compose up -d mosquitto nats
MQTT_HOST=localhost NATS_HOST=localhost CONFIG_PATH=./config/config.example.yaml go run ./src/
```

### Configuration

See [`config/config.example.yaml`](config/config.example.yaml) for the full reference.

| Environment Variable | Description                                        |
|----------------------|----------------------------------------------------|
| `CONFIG_PATH`        | Path to the YAML config file (required)            |
| `MQTT_HOST`          | MQTT broker hostname (set automatically in Docker) |
| `NATS_HOST`          | NATS server hostname (set automatically in Docker) |
| `MQTT_USER`          | Injected into config via `${MQTT_USER}`            |
| `MQTT_PASS`          | Injected into config via `${MQTT_PASS}`            |
| `NATS_TOKEN`         | Injected into config via `${NATS_TOKEN}`           |

Secrets are injected via `${VAR_NAME}` syntax in the YAML file — they are resolved from environment variables at startup.

### Mapping template functions

The field mapping uses Go `text/template` with two custom functions:

| Function                    | Description                              | Example                                                              |
|-----------------------------|------------------------------------------|----------------------------------------------------------------------|
| `seg <topic> <index>`       | Extract segment from `/`-delimited topic | `{{ seg .topic 1 }}` on `telemetry/deviceId001/data` → `deviceId001` |
| `jsonpath <payload> <path>` | Extract value from JSON by dot-path      | `{{ jsonpath .payload "sensor.type" }}`                              |

## Unit Tests

```bash
make test
```

Or directly:
```bash
go test -v -count=1 ./tests/unit/...
```

## Build

```bash
# Binary
make build

# Docker image
docker build -t data-converter .
```

## Makefile Targets

| Target       | Description                               |
|--------------|-------------------------------------------|
| `make proto` | Regenerate Go code from `telemetry.proto` |
| `make build` | Compile binary to `bin/data-converter`    |
| `make run`   | Run the service with `go run`             |
| `make test`  | Run unit tests                            |
| `make deps`  | Tidy and download Go modules              |
| `make clean` | Remove generated `api/` directory         |
