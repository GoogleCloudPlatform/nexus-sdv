# vin-registry

Records which vehicle identities exist on this Nexus platform, and puts them in
front of the operator without anyone maintaining a list by hand.

## Why

On a platform that has been running for weeks — a workshop instance, say — there
is today no way to answer "which VINs are on here, and where did they come
from?". Certificates are issued by two different services and nothing keeps a
record. FleetView can only show vehicles that somebody entered into
`vehicle_groups` manually, which stops being true the moment a new vehicle
registers.

## What it records (increment 1)

Two facts, both reported by the services that issue the certificates:

| Source | Action |
|---|---|
| `factory-helper` | `factory-certificate-issued` |
| `registration` | `operational-certificate-issued` |

On a **successful** issuance the VIN is also added to the `nexus-fleet` group, so
it appears in FleetView automatically. A failed attempt is recorded but does not
grant membership.

## What it deliberately does not do

- **Telemetry statistics.** Counting in the ingestion path means either a 15-30x
  write amplification (the connector explodes each message into one row per
  sensor) or a `dedupe` construct that can silently drop telemetry. A scheduled
  scan over BigTable derives the same numbers from the actual data and cannot
  break ingestion. That belongs in increment 2.
- **Reconciliation against the CA pools.** Worth having eventually, so that a
  report lost while this service was down can be recovered. Not needed for
  workshop use.
- **Multiple fleets.** One fleet, `nexus-fleet`, hardcoded. Several fleets would
  be a schema and UI change, not a configuration flag.

## Callers must not depend on it

Reporting is best effort. `factory-helper` and `registration` fire a short,
timeout-bounded request and carry on regardless — a certificate is never
withheld because the registry is slow or absent. With `VIN_REGISTRY_URL` unset
they do not call at all, and the platform behaves exactly as it did before this
service existed.

## API

```
GET  /health
POST /v1/events     {"vin","source","action","result","detail"?}
GET  /v1/vins       → one row per VIN: event count, first/last seen, last action
```

Every field of `POST /v1/events` is validated before it reaches the database:
`vin` against `^[A-Za-z0-9-]{1,32}$`, `source`/`action`/`result` against closed
sets, `detail` at most 512 characters. See `main_test.go` for the accepted and
rejected cases.

## Configuration

| Variable | |
|---|---|
| `DB_HOST`, `DB_PORT` | default `localhost:5432` — the Cloud SQL proxy sidecar |
| `DB_USER`, `DB_PASSWORD`, `DB_NAME` | database credentials |
| `PORT` | listen port, default `8080` |

The service creates its own table on startup (`CREATE TABLE IF NOT EXISTS`) and
shares the `nexus_acl` database with FleetView, because that is where
`vehicle_groups` already lives.
