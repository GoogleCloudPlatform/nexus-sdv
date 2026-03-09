# Device Client

A Python sample client that simulates devices registering with the Nexus platform and optionally sending telemetry data.

## Overview

This client demonstrates the full device onboarding flow:

1. **Factory certificate** — obtains or generates a certificate signed by the factory CA to authenticate the device
2. **Registration** — presents the factory certificate via mTLS to the registration server and receives an operational certificate
3. **Authentication** — uses the operational certificate to obtain a JWT from Keycloak via client credentials
4. **Telemetry** — publishes protobuf-encoded sensor data to NATS using the JWT

## Prerequisites

- Python 3.13+
- [`uv`](https://docs.astral.sh/uv/) package manager

## Setup

Install dependencies:

```bash
uv sync
```

### PKI strategy

The client supports two PKI strategies:

| Strategy | Description |
|----------|-------------|
| `local`  | Factory CA key and cert are read from `../../base-services/registration/pki/factory-ca/`. Use this for local development. |
| `remote` | Factory cert and key are provided explicitly via `-factory-cert` / `-factory-key`. CA certs for the registration server and Keycloak are downloaded from GCP Secret Manager (see `make downloadcerts`). |

For remote mode, download the required CA certificates first:

```bash
make downloadcerts
```

## Usage

```bash
uv run python main.py [OPTIONS]
```

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `-uid <id>` | random base64url | Device identifier |
| `-pki_strategy local\|remote` | `local` | PKI strategy to use (read from an existing env file) |
| `-factory-cert <path>` | — | Factory certificate chain (PEM) — required for `remote` |
| `-factory-key <path>` | — | Factory private key (PEM) — required for `remote` |
| `-registration-url <url>` | `https://localhost:8080` | Registration server URL (read from an existing env file)  |
| `-output <dir>` | `certificates/` | Output directory for operational certificate and key |
| `-with-telemetry` | off | Also send fake telemetry after registration |
| `-interval <seconds>` | `5` | Telemetry send interval (used with `-with-telemetry`) |

### Examples

**Local PKI, registration only:**
```bash
uv run python main.py
```

**Local PKI, with telemetry:**
```bash
uv run python main.py -with-telemetry -interval 3
```

**Remote PKI (GCP):**
```bash
make downloadcerts
uv run python main.py \
  -pki_strategy remote \
  -factory-cert path/to/device-chain.pem \
  -factory-key path/to/device-key.pem \
  -registration-url https://registration.example.com:8080
```

**Remote PKI (GCP) - installed from the local workstation:**
```bash
make downloadcerts
uv run python main.py \
  -factory-cert path/to/device-chain.pem \
  -factory-key path/to/device-key.pem \
```


## Output files

After a successful run, the following files are written to the output directory (default: `certificates/`):

| File | Description |
|------|-------------|
| `certs/operational.crt.pem` | Device operational certificate (signed by the platform CA) |
| `certs/operational.key.pem` | Corresponding private key |
| `certs/ca.crt.pem` | Keycloak CA certificate (for TLS verification) |
| `urls.json` | Keycloak and NATS server URLs returned by the registration server |

Intermediate files (CSR, factory cert, etc.) are kept under `history/<uid>/` for debugging.

## Telemetry format

Telemetry messages are encoded using Protocol Buffers (`telemetry.proto` in `../../proto/`). Protobuf Python files are auto-generated on first run into the `proto/` directory. To regenerate manually:

```bash
make proto
```

Messages are published to the NATS subject `telemetry.prod.bigtable.<uid>`.
