# nexus-pubsub-consumer

A cloud-side service for Increment 1.2 of the AAOS Nexus Bridge. It connects to
NATS as the `connector` user, subscribes to `pubsub.>`, decodes every message
on that subject as a `telemetry.TelemetryMessage` protobuf, and logs it in
full: `message_id`, `schema_version`, `device_id`, and every `SensorReading`
with its timestamp, value, `data_type` and sensor name. There is no storage or
query layer here — this service exists to prove, field by field, that a
message published by a vehicle bundle survives the trip from the vehicle
through the Bridge to the cloud intact. That is the whole point of Increment
1.2, and it is why the decoding is full and typed rather than the
best-effort, partial decode the vehicle side does.

## Rust, on purpose

Every other Nexus cloud service is Go or Python. This one is Rust, and that is
a deliberate break from house convention, not an accident of who happened to
write it. The AAOS vehicle side (the Bridge and its bundles) is Rust because
that is what AOSP's native/Soong build supports well; writing the cloud
consumer in Rust too means a developer who owns a vehicle-to-cloud feature can
use **one language for both ends of the wire**. That is a genuine ergonomic
win for whoever writes both halves, and it is worth demonstrating even though
Go remains perfectly welcome for other cloud services, and Kotlin or
Java/Groovy are plausible choices for AAOS-adjacent code later. The SDK
planned for Increment 3 will have to answer the "which language(s)" question
per-language anyway; starting here in Rust means the first answer it gets
already matches the vehicle side.

## The two-unit split

The crate is deliberately split into two units that do not know about each
other's business:

| Unit | Owns | Knows about |
|---|---|---|
| `transport` | the NATS connection, auth, subscription and protobuf decode | NATS, `telemetry.proto` |
| `app` | what happens with a decoded `TelemetryMessage` (today: log it) | neither |

`transport` hands `app` typed, fully-decoded messages; how those messages got
off the wire is not `app`'s problem. That boundary is worth keeping even if
nothing else ever changes here, because it is also the boundary Increment 3's
SDK needs: when the time comes to lift a reusable "subscribe and decode" layer
out of this service, `transport` is already shaped like the thing that gets
extracted, and `app` is already shaped like the thing a consumer of that SDK
would write for themselves.

## Running it locally

The service needs nothing beyond a reachable NATS server and a `config.toml`;
it does not care whether that NATS enforces authentication. Against a bare
local NATS:

```bash
docker run --rm -d --name nats-test -p 4222:4222 nats:2.14.2-alpine

cat > /tmp/c.toml <<'EOF'
nats_url = "nats://127.0.0.1:4222"
nats_user = "u"
nats_password = "p"
subject = "pubsub.>"
EOF

CONFIG_PATH=/tmp/c.toml cargo run
```

Publish a message on `pubsub.<anything>` from another terminal (for example
with `nexus_sample_nats`, the Bridge's test double from earlier in this
increment) and the consumer logs the decoded `TelemetryMessage`. Stop it with
`docker rm -f nats-test` when done.

What the consumer writes to the log is set by `log_detail`. The default, `masked`,
shows a VIN by its last four characters and leaves out reading values (their length
is logged instead); `full` logs everything and is meant for an environment that
carries test vehicles only. `deploy/configmap.yaml` sets `full` for the workshop
environment, and says to change it before a real vehicle's data flows through. Add
`log_detail = "full"` to the file above to see the values in a local run.

A message whose `device_id` is not the VIN in its subject (`pubsub.<vin>.<topic>`)
is skipped with a warning: `device_id` becomes the row key downstream, so it would
be filed under the wrong vehicle.

`config.example.toml` is the template for a real deployment: copy it to
`config.toml` (gitignored) for further local experiments, or let
`deploy/configmap.yaml` render it into the cluster. `${VAR}` placeholders in
the file are expanded from the process environment at load time, which is how
the NATS password reaches the process from a Kubernetes Secret without ever
sitting in the config file or the ConfigMap.

## Building and deploying

`Dockerfile` is a standard two-stage build: the `builder` stage compiles the
release binary with the full Rust toolchain and `protoc`, and the runtime
stage is `debian:bookworm-slim` running the binary as a non-root user. Build
and smoke-test it locally with:

```bash
docker build -t nexus-pubsub-consumer:dev .
docker run --rm nexus-pubsub-consumer:dev   # exits 2, config.toml not found — expected
```

Push the image to your registry of choice, then deploy with the one script in
`deploy/`:

```bash
IMAGE=<registry>/nexus-pubsub-consumer:<tag> ./deploy/apply.sh [gcp-project]
```

`apply.sh` reads the NATS `connector` password from GCP Secret Manager,
creates/updates the `nexus-pubsub-consumer` Secret and ConfigMap, substitutes
the image into `deploy/deployment.yaml` (the `IMAGE_PLACEHOLDER` there is
filled in by the script — do not hand-edit it into the checked-in manifest),
and waits for the rollout. It targets the `base-services` namespace, which the
script does not create; see `deploy/namespace-note.md` if it is missing.

## Why this does not go through the normal pipeline

This is the interesting part of the task, so it is worth saying plainly:
unlike every other Nexus service, `nexus-pubsub-consumer` is **not** wired
into `deploy-all.yaml`, `iac/helm/helmfile.d/`, or a CloudBuild trigger. There
is no Helm chart. `deploy/apply.sh` is run by hand, against an image built and
pushed by hand. This is a deliberate choice, not an oversight. In short: service delivery — "how does someone ship a
Nexus service?" — becomes a first-class topic for an SDK in Increment 3, and
that question is easier to design well when it has an actual service to work
against that is *not* already fused into the platform's release machinery.
Folding this service into the standard pipeline once that design exists is a
small step. Doing it now, and unpicking it again later once the SDK has
opinions, would not be.

## Prerequisite: the `connector` NATS permission grant

This service authenticates as the in-cluster `connector` user, which (unlike
vehicles, whose currently-empty permission set degrades to allow-all) is given
**explicit** subscribe and publish permissions in
`iac/helm/helmfile.d/nats.yaml.gotmpl`. As of this writing that file grants
`connector` only `telemetry.>`, `telemetry-aaos-sdv.>`, `telemetry-generic.>`, `local.telemetry.>` and
`scoring.>` — it does **not** yet include `pubsub.>`. Until `pubsub.>` is added
to both the subscribe and publish lists there, this consumer will be denied
the moment it tries to subscribe. That change belongs to the Nexus 1.2.1
release track on `main`, not to this service, and is the one hard cross-track
dependency of this increment — it is not something `nexus-pubsub-consumer`
can fix on its own.
