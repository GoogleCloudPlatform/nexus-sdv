# Certificate Flow

This document explains the certificate lifecycle when a device registers with the platform.

## Two certificates, two purposes

The registration flow involves two distinct certificates:

| Certificate | Signed by | Purpose |
|---|---|---|
| **Device certificate** | Factory CA | Proves the device is genuine hardware from the manufacturer |
| **Operational certificate** | Platform CA (via registration server) | Grants the device access to platform services |

The **device certificate** is a per-device credential issued at manufacturing time. The Factory CA is shared across all devices, but each device gets its own certificate.

The **operational certificate** is what the device actually uses day-to-day (Keycloak auth, telemetry). It is only issued after the registration server has validated the device certificate.

Note: registration happens externally on a provisioning machine, not on the device itself, because devices in this scenario do not have onboard crypto capability. Only the operational cert and key are written to the device. The device certificate and its private key are used during registration and then discarded — they never end up on the device.

### Why not use the Factory CA directly?

mTLS requires the client to prove possession of the private key corresponding to the certificate it presents. If all devices used the Factory CA certificate, they would all share the same Factory CA private key on the provisioning machine — and the registration server could not distinguish between individual devices. With per-device certificates, the CN (`VIN:<uid> DEVICE:<uid>`) uniquely identifies the device, allowing the registration server to make per-device decisions: tracking which devices have registered, preventing duplicate registrations, and blocking specific devices if needed.

### Why not reuse the device certificate as the operational certificate?

Two separate trust domains are intentionally kept apart:

- The **manufacturer** controls the Factory CA.
- The **platform operator** controls the platform CA.

The platform should only need to trust the manufacturer's CA for the initial registration handoff, not for every ongoing mTLS connection. Operational certificates can also be revoked or rotated independently of manufacturing records.

Additionally, the CSR pattern (see Step 2 below) ensures the platform **never sees the operational private key** — the device generates it locally and only sends the public half. The device certificate does not offer this guarantee.

---

## Registration steps

### Step 0 — Obtain a device certificate

**Local PKI (development):** `factory.py` generates the device certificate locally:

1. Reads the Factory CA cert and key from `../../base-services/registration/pki/factory-ca/`
2. Generates a new RSA-2048 private key for the device
3. Creates an X.509 certificate: `CN=VIN:<uid> DEVICE:<uid>`, `O=Vehicle Manufacturer`, valid 365 days
4. Signs it with the Factory CA key
5. Writes a chain file (device cert + CA cert concatenated)

**Remote PKI:** the device certificate and key are provisioned externally and passed in via `-factory-cert` / `-factory-key`.

---

### Step 1 — Generate an operational key pair

A fresh RSA-2048 key pair is generated locally. This key never leaves the device — only its public half is ever transmitted (in the CSR below).

---

### Step 2 — Create a Certificate Signing Request (CSR)

A CSR is built from the operational public key with subject `CN=VIN:<uid> DEVICE:<uid>`, `O=Device Manufacturer`. The CN is explicitly encoded as UTF8String to match the registration server's requirements. The CSR is saved to `history/<uid>/operational.csr.pem` for debugging.

---

### Step 3 — Send the CSR to the registration server

The CSR is POSTed to `{registration_url}/registration`. The device authenticates itself using the device certificate via **mTLS** — this is how the registration server knows the request comes from a legitimate device. The registration server's TLS certificate is verified against the appropriate CA.

---

### Step 4 — Receive the operational certificate

The registration server validates the device certificate, signs the CSR, and returns a JSON response containing:

- `certificate` — the signed operational certificate
- `keycloak_url` — where to obtain JWT access tokens
- `nats_url` — where to publish telemetry

The operational certificate is saved to `history/<uid>/operational.crt.pem`.

---

## History folder vs output path

All intermediate and final files are written to `history/<uid>/` during the registration process. This folder is kept intact for debugging purposes.

After registration completes, the files the device actually needs are copied to the output directory (default: `certificates/`):

| Output path | What it is |
|---|---|
| `certs/operational.crt.pem` | Operational certificate issued by the registration server |
| `certs/operational.key.pem` | Operational private key (generated locally in Step 1) |
| `certs/ca.crt.pem` | Keycloak CA certificate (needed to verify Keycloak's TLS) |
| `urls.json` | Keycloak and NATS URLs |

The device certificate, its key, the CSR, and the chain file remain only in `history/` and are not put on the device.

---

## Optional: Telemetry

If run with `-with-telemetry`, two additional steps follow registration:

1. **Keycloak authentication** — the device uses the operational cert + key as mTLS client credentials with a `client_credentials` grant to obtain a JWT access token.
2. **NATS publish** — the device connects to NATS using the JWT and publishes protobuf-serialised `TelemetryMessage` payloads to subject `telemetry.prod.bigtable.<uid>`.
