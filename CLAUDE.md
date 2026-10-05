# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Nexus SDV** is an open-source connected vehicle platform reference implementation. It bridges automotive in-vehicle software (Android Automotive OS / AAOS) with Google Cloud infrastructure via NATS pub/sub messaging, protobuf serialization, BigTable storage, and a gRPC query layer.

## Commands

### Data API (Go) — `base-services/data-api/`
```bash
make deps      # Download Go dependencies
make proto     # Regenerate protobuf Go code
make build     # Build binary
make test      # Integration tests (requires Docker for BigTable emulator)
make clean
```

### Auth Callout (Go) — `base-services/auth-callout/`
```bash
make test      # Unit tests
make build
```

### Data Converter (Go) — `base-services/data-converter/`
MQTT → NATS protobuf adapter service.
```bash
make config    # Create config/config.yaml from example (won't overwrite)
make proto     # Regenerate protobuf Go code
make build
make test      # Unit tests (./tests/unit/...)
docker compose up --build   # Full local stack: Mosquitto + NATS + converter + subscriber
```

### Factory Helper (Rust) — `base-services/factory-helper/`
Issues factory identities over HTTPS so a vehicle can be provisioned without
project IAM. Remote PKI only.
```bash
cargo build
cargo test     # unit tests, no cloud access needed
```

### VIN Registry (Go) — `base-services/vin-registry/`
Holds which vehicles the platform knows; FleetView reads it.
```bash
go build ./...
go test ./...
```

### Registration Server (Rust) — `base-services/registration/server/`
```bash
cargo build
cargo test
cargo run
```

### Vehicle Client (Go) — `sample-clients/vehicle-client/`
```bash
make deps
make proto
make certs     # Fetch certificates from GCP Secrets
make build
make run
make test
```

### Telemetry Subscriber (Go) — `sample-clients/telemetry-subscriber/`
```bash
make proto
make build
make downloadcerts   # Fetch TLS certs from GCP Secrets
make run
make test
```

### Python Clients & Services — `sample-clients/python/`, `sample-services/*/`
```bash
make proto           # Generate gRPC Python stubs
make downloadcerts
uv sync              # Install dependencies
uv run <app>         # Run a specific app
```

### Data Web Client (Next.js) — `sample-clients/data-web-client/`
```bash
npm install
npm run dev     # Development server
npm run build
npm run lint    # ESLint
npm run test    # Jest unit tests
```

### IoT Client (C++/ESP32, PlatformIO) — `sample-clients/iot-client/`
```bash
make config    # Create include/config.h from example (won't overwrite)
make proto     # Regenerate nanopb code from telemetry.proto
make build     # pio run
make upload    # Build and flash to ESP32
make monitor   # Open serial monitor
```

### Devices Client (Python) — `sample-clients/devices/`
```bash
make proto          # Generate gRPC Python stubs
make downloadcerts  # Fetch TLS certs from GCP Secrets
uv run main.py
```

### Trip Analyzer (Python/FastAPI) — `sample-services/trip_analyzer/`
```bash
make install   # uv sync
make dev       # FastAPI dev server on :8000
make test      # pytest tests/
make lint      # ruff check + mypy
make generate  # Regenerate betterproto gRPC stubs
```

### Data API Sampler (Java/Spring Boot) — `sample-services/data-api-sampler/`
Requires JDK 21.
```bash
./mvnw clean install
./mvnw spring-boot:run -Dspring-boot.run.arguments="--data-api.client.data-api-url=<address:port>"
```
The Data API is cluster-internal, so running the sampler from your own machine
needs a port forward first; in the cluster the address is
`data-api.base-services.svc.cluster.local:8080`.
```bash
kubectl port-forward -n base-services svc/data-api 8080:8080
```

### Operating tools — `iac/operating/`
Scripts for a platform that already runs. None of them deploy by themselves
except where noted.
```bash
./nexus-preflight.sh <PROJECT_ID> --region <REGION> --pki <local|remote>
                 # is this project ready for a bootstrap; 0 ready, 1 blocked, 2 reservations
./nexus-cert-status.sh                    # expiry of the five platform TLS certs
./nexus-cert-status.sh --renew <NAME>     # redeploys the owning service — not read-only
./nexus-matrix.sh --project <PROJECT_ID>  # start a four-shape bootstrap test matrix
./nexus-scan-gcp.sh / ./nexus-policy.sh   # inventory and the protected-project rules
./nexus-force-cleanup.sh                  # last resort when a teardown left resources behind
```

### Skills — `.agents/plugins/nexus-sdv/skills/`
`nexus-install` and `nexus-operate`, shipped experimental with 1.2.1 as the
`nexus-sdv` plugin: the
instructions an agent follows to install, operate and tear down a platform.
They are prose, not code, and carry no tests — change them the way you would
change documentation, and keep them true to what the scripts actually do.

### Infrastructure — `iac/terraform/`
```bash
terraform init
terraform plan
terraform apply
terraform destroy
```

## Architecture

### Data Flow

```
Vehicle (AAOS VHAL) / IoT device (ESP32) / Python simulator
  → Vehicle Client (Go) / IoT Client (C++) / devices client: reads signals,
    serializes to protobuf
      IoT devices may instead publish MQTT, converted to NATS protobuf by Data Converter (Go)
  → NATS topic: telemetry.{env}.{destination}.{vin}
      ↑ Auth Callout (Go) validates JWT on each connection
  → Telemetry Subscriber (Go): parses protobuf, writes to BigTable
      row key: {vehicleId}#{ISO8601_timestamp}
  → Data API (gRPC, Go): queries BigTable on demand
  → Data Web Client (Next.js): fleet UI with map + time-series
  → Sample Services: AI assistant, trip analyzer, data-api-sampler
```

Before any of that, a vehicle has to become one the platform knows:

```
Factory Helper (Rust): issues a factory identity over HTTPS
      the path a customer walks — no project IAM, authenticated by an OIDC
      client credentials token carrying the factory-operator role
  → Registration Server (Rust): exchanges it for an operational certificate
  → VIN Registry (Go): records the vehicle; FleetView reads it from there
```

### Key Components

| Directory | Language | Role |
|-----------|----------|------|
| `base-services/data-api/` | Go | gRPC service; primary BigTable interface |
| `base-services/auth-callout/` | Go | NATS authentication hook; validates JWT |
| `base-services/data-converter/` | Go | Adapts MQTT telemetry into NATS protobuf |
| `base-services/registration/` | Rust (Axum) | Vehicle registration + PKI certificate issuance |
| `base-services/factory-helper/` | Rust (Axum) | Issues factory identities over HTTPS, without project IAM; remote PKI only |
| `base-services/vin-registry/` | Go | Which vehicles the platform knows; FleetView's source |
| `sample-clients/vehicle-client/` | Go | Transmits vehicle telemetry to NATS |
| `sample-clients/telemetry-subscriber/` | Go | Receives NATS messages |
| `sample-clients/iot-client/` | C++ (ESP32/PlatformIO) | Firmware publishing telemetry via MQTT/nanopb |
| `sample-clients/devices/` | Python | Lightweight device client |
| `sample-clients/data-web-client/` | TypeScript/Next.js | FleetView: fleet management UI; Keycloak OIDC auth |
| `sample-clients/python/` | Python | `nexus_sdk` (`car.py`, `telemetry.py`) + simulator apps under `apps/` (`vhal`, `vss`, `simple_sim`) |
| `sample-services/trip_analyzer/` | Python (FastAPI) | Trip analysis; betterproto gRPC client |
| `sample-services/data-api-sampler/` | Java (Spring Boot) | Sample REST wrapper over the Data API |
| `proto/` | Protobuf | Shared message schemas across all services |
| `iac/` | Terraform + Helm | GCP infrastructure (GKE, BigTable, SQL, PKI, VPC) |
| `iac/operating/` | Bash | Tools for a running platform: preflight, certificates, matrix, cleanup |
| `.agents/plugins/nexus-sdv/skills/` | Markdown | the `nexus-sdv` plugin: `nexus-install` and `nexus-operate`, the agent-facing instructions |

### Protobuf Workflow

All inter-service message schemas live in `/proto/`. Key schemas:
- `telemetry.proto` — core `SensorReading` / `TelemetryMessage` types
- `vehicle_telemetry.proto` — AAOS-specific vehicle signals
- `aaos_vehicle_telemetry.proto` — Android Automotive OS messages
- `data-api.proto` — Data API gRPC service definition
- `display_safety.proto`, `metrics_report.proto`, `carla_simulation_report.proto` — additional sample-service schemas

After editing `.proto` files, run `make proto` in each affected service directory to regenerate language-specific bindings (Go via `protoc`, Python via `grpc_tools`/betterproto, C++ via nanopb). Generated code is committed to the repo.

### Security / PKI

Vehicles authenticate with mutual TLS (client certificates from Google Certificate Authority) plus OIDC JWT tokens. The Auth Callout service validates JWT on every NATS connection. Certificates are stored in `certificates/` directories (gitignored) and fetched via `make certs` / `make downloadcerts` using `gcloud secrets`.

### Deployment

Services are containerized (each has a `Dockerfile`), built via Cloud Build, pushed to Artifact Registry, and deployed to GKE using Helm charts in `iac/helm/`. Environment bootstrap configuration is in `iac/bootstrapping/.bootstrap_env`.

Charts in `iac/helm/`: `data-api`, `data-api-sampler`, `data-converter`,
`data-web-client`, `external-dns`, `factory-helper`, `keycloak`, `nats`,
`nats-auth-callout`, `nats-bigtable-connector`, `registration`, `trip-analyzer`,
`vin-registry`.

Read `.bootstrap_env` before writing a manifest by hand: it decides things a
chart would otherwise fill in from a default. `ARCH="amd64"` is the one that
bites — the charts default to `arm64`, and an Autopilot cluster refuses an
arm64 pod that names no compute class.

### CI/CD
Always choose CloudBuild over Github actions.

GitHub Actions workflows in `.github/workflows/`:
- `build-push-deploy-*.yml` — per-service build → push → GKE deploy
- `terraform-test.yml` — Terraform lint and validate
- `bootstrap-platform.yml` — one-time platform initialization

CloudBuild triggers in ./iac/cloudbuild:
- bootstrap-platform.yaml — spin up a new environment (no local script needed); loads config from GCS via _BOOTSTRAP_ENV_GCS_PATH
- teardown-platform.yaml  — destroy an environment (no local script needed); loads config from GCS via _BOOTSTRAP_ENV_GCS_PATH
- test-environments.yaml — the four-shape bootstrap test matrix; started with iac/operating/nexus-matrix.sh
- run-sample-clients.yaml — smoke-tests the sample clients end to end
- build-push-deploy-data-api-sampler.yaml
- build-push-deploy-data-api.yaml
- build-push-deploy-data-web-client.yaml
- build-push-deploy-factory-helper.yaml
- build-push-deploy-registration.yaml
- build-push-deploy-trip-analyzer.yaml
- build-push-deploy-vin-registry.yaml
- build-push-nats-auth-callout.yaml
- deploy-all.yaml
- deploy-external-dns.yaml
- deploy-external-secrets.yaml
- deploy-keycloak.yaml
- deploy-nats-auth-callout.yaml
- deploy-nats-bigtable-connector.yaml
- deploy-nats.yaml
- platform-health-check.yaml — runs iac/bootstrapping/tools/platform-health-check.sh (GCP infra, networking/PKI, app services, optional e2e via _RUN_E2E)

### gcloud

`gcloud` sits at a different path on each developer machine. Resolve it once per
session and reuse the result; never hardcode a personal path in a committed file:

```bash
command -v gcloud || ls /opt/homebrew/bin/gcloud ~/tools/google-cloud-sdk/bin/gcloud 2>/dev/null
```

Machine-specific paths belong in the developer's own `~/.claude/CLAUDE.md`.
