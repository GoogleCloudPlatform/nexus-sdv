# nexus-registry — the Cloud Service Registry

A cloud service registers a topic; a vehicle announces its offer; the registry grants the
vehicle what both name — topic, pattern and direction equal — and the auth-callout issues it.

- **REST, cluster-internal, port 8080:** `POST /v1/services` `{name, topic, pattern, direction}`
  → 201 or 400; `DELETE /v1/services/{name}` → 204, 400 or 404; `GET /v1/services` → 200.
  `name` and `topic` match `[a-z0-9-]{1,64}`, `pattern` is `pubsub`, `direction` is
  `vehicle-to-cloud` or `cloud-to-vehicle`. No authentication: the cluster boundary is the bound.
- **NATS, user `nexus-registry` in account `NEXUS`:** answers `registry.<vin>.announce` with the
  grant; publishes changed grants on `registry.<vin>.grant`.
- **Store:** buckets `nexus-registry-services`, `nexus-registry-offers`,
  `nexus-registry-grants`, created at start-up when missing (history 10, file storage).
- **Environment:** `NATS_PASSWORD` (required), `NATS_URL`, `NATS_USER`, `LISTEN_ADDR`,
  `LEASE_SECONDS` (default `900`; chart value `lease.seconds`).

**Lease.** A registration lives as long as it is renewed: posting the same registration again
is the renewal (the spec has the library renew every 5 minutes) and changes no grant. Every 60 s the
registry drops each registration whose last write is older than `LEASE_SECONDS`, exactly as if
it had been deregistered — the grants are recomputed and the vehicles told. The time of the
last write is the store's own write time, so it survives a registry restart. A service does not
deregister when it stops; `DELETE /v1/services/{name}` is the deliberate act.

Tests: `cargo test`; with a server, `docker run -d --rm --name nexus-test-nats -p 4222:4222 nats:2.14.6 -js`
and `NEXUS_TEST_NATS_URL=nats://127.0.0.1:4222 cargo test -- --include-ignored`. The library
in `aaos/nexus-aaos-sdk/` is tested the same way.
