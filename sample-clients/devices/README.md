# Devices Client

Python client that registers devices with the Nexus SDV platform and optionally sends telemetry data.
It walks through the full device lifecycle: factory certificate generation, registration (CSR exchange), Keycloak authentication, and NATS telemetry publishing.

## Prerequisites

- Python 3.13+
- [uv](https://docs.astral.sh/uv/) package manager
- For **local** PKI: a running registration server with factory CA at `base-services/registration/pki/`
- For **remote** PKI: GCP access to download TLS certificates from Secret Manager

## Setup

1. Create a virtual environment and install dependencies:
    ```bash
    uv venv
    uv sync
    ```

2. Generate protobuf files (auto-generated on first run, but can be done explicitly):

    ```bash
    make proto
    ```

## Running

### Local PKI (default)

This generates a random device UID and registers a device with a locally generated factory certificate:

```bash
uv run main.py
```

### Custom Device UID

Specify a device identifier instead of using a random one:

```bash
uv run main.py -uid MY_DEVICE_001
```

### Using make

Protobuf files are automatically generated when missing or when the source `telemetry.proto` changes.
There is no need to run `make proto` manually before other targets.

Use `make run` to run the client, passing CLI arguments via the `ARGS` variable:

```bash
make run ARGS="-uid MY_DEVICE_001"
```

### Remote PKI (GCP)

First download the TLS certificates from GCP Secret Manager:

```bash
make downloadcerts
```

Then register with a remote registration server, providing pre-existing factory certificates:

```bash
uv run main.py \
  -pki_strategy remote \
  -factory-cert path/to/factory-chain.pem \
  -factory-key path/to/factory-key.pem \
  -registration-url https://registration.example.com:8080
```

### With Telemetry

Append `-with-telemetry` to also authenticate with Keycloak and publish test telemetry to NATS:

```bash
uv run main.py -with-telemetry
```

## CLI Reference

| Flag                | Default                  | Description                                                                                 |
|---------------------|--------------------------|---------------------------------------------------------------------------------------------|
| `-uid`              | random base64url UUID    | Device identifier                                                                           |
| `-pki_strategy`     | `local`                  | PKI strategy: `local` or `remote`                                                           |
| `-factory-cert`     | —                        | Path to factory certificate chain (PEM). Ignored for local PKI; **required** for remote PKI |
| `-factory-key`      | —                        | Path to factory private key (PEM). Ignored for local PKI; **required** for remote PKI       |
| `-registration-url` | `https://localhost:8080` | Registration server URL                                                                     |
| `-output`           | `certificates/`          | Output directory for operational key and certificate                                        |
| `-with-telemetry`   | `false`                  | Send test telemetry data after registration                                                 |
| `-interval`         | `5`                      | Telemetry sending interval in seconds                                                       |

## Output

After a successful run, the following files are written to the output directory (default `certificates/`):

- `operational.crt.pem` — operational certificate issued by the registration server
- `operational.key.pem` — operational private key
- `ca.crt.pem` — Keycloak CA certificate (for mTLS authentication)
- `urls.json` — Keycloak and NATS server URLs

A full history of all generated artifacts is also kept in `history/<uid>/`.

## Make Targets

| Target               | Description                                                                           |
|----------------------|---------------------------------------------------------------------------------------|
| `make proto`         | Generate Python protobuf files from `proto/telemetry.proto`                           |
| `make downloadcerts` | Download TLS certificates from GCP Secret Manager (required when pki_strategy=remote) |
| `make run`           | Run the client (generates proto files if needed)                                      |
| `make clean`         | Remove all generated files (proto, certs, keys)                                       |
