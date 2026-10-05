# factory-helper

Self-service factory identity issuance for Nexus SDV. Issues per-VIN,
factory-CA-signed certificates via GCP Private CA — callers need a Keycloak
`factory-operator` token, never GCP access. The CA private key never leaves
Google-managed infrastructure; this service holds a single IAM permission
(`roles/privateca.certificateRequester` on the factory CA pool) and no other.
Design: `docs/superpowers/specs/2026-08-27-factory-helper-design.md`.

## Operator setup (once per environment)

```bash
./iac/operating/keycloak-provision-client.sh \
  https://keycloak.<base-domain>:8443 sdv-telemetry factory-operator --role factory-operator
# note the printed client_secret
```

## Getting a token

```bash
TOKEN=$(curl -sk -X POST "https://keycloak.<base-domain>:8443/realms/sdv-telemetry/protocol/openid-connect/token" \
  -d grant_type=client_credentials -d client_id=factory-operator -d client_secret=<secret> | jq -r .access_token)
```

## Mode 1 — sign my CSR (private key never leaves your machine)

```bash
openssl ecparam -name prime256v1 -genkey -noout -out factory.key.pem
openssl req -new -key factory.key.pem -out factory.csr.pem -subj "/CN=VIN:MYVIN01 DEVICE:car"
curl -sk -X POST "https://factory.<base-domain>:8443/v1/factory-certificates" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "$(jq -n --rawfile csr factory.csr.pem '{csr: $csr, vin: "MYVIN01"}')"
# → { vin, certificate, ca_certificate_chain }
```

## Mode 2 — generate everything for me

```bash
curl -sk -X POST "https://factory.<base-domain>:8443/v1/factory-certificates" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"vin_prefix": "VLT"}'
# → { vin, certificate, ca_certificate_chain, private_key }
```

VIN rules: pass `vin` to use a specific one (1–32 chars `[A-Za-z0-9-]`),
`vin_prefix` for a generated 17-char VIN starting with the prefix, or neither
for a short generated id. The subject CN becomes `VIN:<vin> DEVICE:<type>` —
the format the registration server expects. `device_type` defaults to **the
VIN itself**, matching the established Nexus convention
(`sample-clients/generate-factory-cert-gcp.sh`: "correct CN format (VIN:xxx
DEVICE:xxx)") and what the Go `vehicle-client` puts in its operational CSR —
the registration server requires both CNs to match. Both the Go and the
Python clients follow this `DEVICE:<vin>` convention; pass `device_type`
explicitly only for clients that deviate (e.g. the legacy bootstrap demo
cert used `DEVICE:car`).

## Development

```bash
cargo test          # unit tests (no cloud access needed)
```

Configuration is via `FACTORY_HELPER_*` env vars — see `Config::from_env()`
in `src/main.rs`. Deployed by
`iac/cloudbuild/build-push-deploy-factory-helper.yaml` into the `factory`
namespace (chart: `iac/helm/factory-helper/`).
