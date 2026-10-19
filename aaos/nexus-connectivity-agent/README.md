# nexus-connectivity-agent

Manages the vehicle's connectivity: its security and its NATS connection to the Nexus cloud.
Part of the Nexus-Bridge APEX ([`aaos-nexus-sdv-tcu/`](../aaos-nexus-sdv-tcu/README.md)).

## What it does

- Obtains the vehicle's identity: factory certificate → operational certificate → Keycloak token, renewed before the token expires.
- Runs the NATS leaf (`nats-server`) with a generated `leaf.conf` and restarts it on a new token or a new grant.
- Announces the vehicle's offer to the Cloud Service Registry and follows the grant it receives.
- Hands messages between the leaf and the Nexus Bridge over a Unix socket.
- Answers `nexus.identity.vin` on the leaf with the VIN.
- Answers "where is the leaf?" on a gRPC discovery endpoint.

## Configuration

Environment variables, written by `provision-and-run.sh` into `/data/misc/nexus/nexus.env`.

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `NEXUS_VIN` | yes | — | the vehicle's VIN |
| `NEXUS_CLOUD_NATS_HOST` | yes | — | the hub the leaf connects to (port 7422) |
| `NEXUS_LEAF_HOST` | yes | — | the leaf address the discovery endpoint hands out |
| `NEXUS_REGISTRATION_URL` | yes | — | registration service |
| `NEXUS_KEYCLOAK_URL` | yes | — | Keycloak |
| `NEXUS_NATS_URL` | yes | — | NATS URL recorded for the vehicle |
| `NEXUS_DISCOVERY_PORT` | no | `18051` | port of the discovery endpoint |
| `NEXUS_DISCOVERY_REFLECTION` | no | `off` | `on` enables gRPC reflection on the discovery endpoint |
| `NEXUS_LEAF_MONITOR_PORT` | no | `18222` | the leaf's monitoring endpoint, on `127.0.0.1` |
| `NEXUS_PKI_STRATEGY` | no | `remote` | where the operational certificate comes from |
| `NEXUS_PROVISIONING` | no | `rust` | `vehicle-client` uses the Go binary of that name instead |
| `NEXUS_REGISTRATION_IP` | no | — | address of the registration service, for guests without DNS |
| `NEXUS_KEYCLOAK_IP` | no | — | address of Keycloak, for guests without DNS |
| `NEXUS_LEAF_TLS` | no | `on` | TLS on the link to the hub, with the operational certificate |
| `NEXUS_CLOUD_NATS_NAME` | no | `NEXUS_CLOUD_NATS_HOST` | the name on the hub's certificate |
| `NEXUS_RUN_DIR` | no | `.` | run directory, holds `certificates/` |
| `NEXUS_NATS_SERVER_BIN` | no | `/data/local/tmp/nats-server` | the `nats-server` binary |
| `NEXUS_LEAF_CONF` | no | `/data/local/tmp/leaf.conf` | generated leaf configuration |
| `NEXUS_LEAF_LOG` | no | `/data/local/tmp/nats-leaf.log` | leaf log |
| `NEXUS_FACTORY_CERT` | no | `certificates/vehicle-<VIN>-factory-gcp-chain.pem` | factory certificate |
| `NEXUS_FACTORY_KEY` | no | `certificates/vehicle-<VIN>-factory-gcp-key.pem` | its key |

## Logs

- `/data/misc/nexus/agent.log`, with a line `leaf status: link=up|down|unknown` at least once a minute.
- `/data/misc/nexus/nats-leaf.log`.
- Before the log file is open: `dmesg | grep nexus`.

## Development

```bash
cargo test
cargo clippy --all-targets          # the AOSP build treats clippy findings as errors
cargo build --release --target x86_64-unknown-linux-musl
```
