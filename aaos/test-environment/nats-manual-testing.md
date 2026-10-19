# NATS by hand

Subscribing at the hub with the `nats` command line (v0.2.4 or newer), from a workstation, to see whether a vehicle's messages arrive.

The user `connector` can also publish: use subscriptions only.

```bash
gcloud secrets versions access latest --secret=NATS_CONNECTOR_PASSWORD --project <PROJECT_ID>
```

| Subject | Contents | Sent by |
|---|---|---|
| `telemetry.<vin>` | `TelemetryMessage` | the head-unit app |
| `telemetry-aaos-sdv.<vin>` | Google's `MetricsReport` | `nexus-telemetry-client` |
| `pubsub.<vin>.<topic>` | the service pairs' messages, both directions | Nexus Bridge, cloud services |

```bash
nats --server nats://connector:<password>@nats.<base-domain>:4222 sub 'telemetry.>'
nats --server nats://connector:<password>@nats.<base-domain>:4222 sub 'telemetry-aaos-sdv.>'
nats --server nats://connector:<password>@nats.<base-domain>:4222 sub 'pubsub.>'
```

Payloads are protobuf and show as binary. Decoded: `pressure-monitor`'s log for `pubsub.<vin>.pressure`, BigTable for telemetry ([INSTALL.md](../INSTALL.md), part 4.4).

Nothing arrives: the message did not leave the vehicle, or the subject does not match (VIN, topic, wildcard depth).
