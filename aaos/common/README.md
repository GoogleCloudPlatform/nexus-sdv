# common

Rust sources shared by the vehicle-side components, included with `#[path = "..."]`.

| File | Contents | Used by |
|---|---|---|
| `nats_wire.rs` | NATS client protocol, publishing and subscribing | `nexus-connectivity-agent`, `nexus-telemetry-client` |
| `leaf_connect.rs` | connects to the leaf on the same VM and refuses a connection to itself | `nexus-connectivity-agent`, `nexus-telemetry-client` |
| `egress_wire.rs` | `[topic][payload]` framing on the Unix socket between Bridge and `nexus-connectivity-agent` | Nexus Bridge, `nexus-connectivity-agent` |
| `authz_policy.rs` | reader for the Bridge's `AuthzPolicy` and slot-size file | Nexus Bridge, `nexus-connectivity-agent` |
| `read_all.rs` | read all (experimental): which discovered publications the Bridge carries, and the list it leaves for the agent | Nexus Bridge, `nexus-connectivity-agent` |
| `slot_wire.rs` | a message in a Data Tunnel slot: varint length, message, zero padding | Nexus Bridge |
| `identity.rs` | reads the VIN from `operational-cert.pem` | — |

Test one file:

```bash
rustc --test --edition 2021 common/<file>.rs -o /tmp/t && /tmp/t
```
