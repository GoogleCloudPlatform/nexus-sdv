# nexus-aaos-sdk

Rust library for cloud services that exchange messages with vehicles on `pubsub.<vin>.<topic>`.
Overview of a service pair across vehicle and cloud: [NEXUS-AAOS-SDK.md](../NEXUS-AAOS-SDK.md).

| API | Contents |
|---|---|
| `Config::from_env()` | `REGISTRY_URL`, `NATS_URL`, `NATS_USER`, `NATS_PASSWORD` (required), `REGISTRY_RENEW_SECONDS` |
| `CloudService::connect(config)` | connection to the hub |
| `register(name, topic, direction)` | registration with the Cloud Service Registry, renewed as a lease |
| `subscribe(topic, handler)` | every message any vehicle sends on the topic, as a `Delivery` with VIN and payload |
| `publish_message(vin, topic, &message)`, `publish(vin, topic, bytes)` | a message to one vehicle |
| `deregister(name)` | closes the channel |
| `valid_vin`, `valid_token`, `mask` | rules for VINs, names and topics; a masked VIN for logs |

Used by the registry and by [`pressure-monitor`](../../sample-services/aaos/pressure-monitor/) and [`door-control`](../../sample-services/aaos/door-control/).

```rust
let service = CloudService::connect(Config::from_env()?).await?;
service.register("door-control", "door-command", Direction::CloudToVehicle).await?;
service.publish_message(vin, "door-command", &DoorCommand { action: Action::Lock as i32 }).await?;
```

```bash
cargo test
```
