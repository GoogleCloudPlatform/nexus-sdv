# nexus-bridge

SDV service bundle that connects SDV services and their messages with the Nexus cloud.
Part of the Nexus-Bridge APEX ([`aaos-nexus-sdv-tcu/`](../aaos-nexus-sdv-tcu/README.md)).

## What it does

- Subscribes to the topics its catalog names on the Data Tunnel, across VMs, and hands each message to the `nexus-connectivity-agent` over a Unix socket.
- Publishes on the Data Tunnel what the cloud sends for the topics its catalog names.
- Passes messages unchanged; it reads and writes only the length in front of each message.
- Re-subscribes after 15 s without a message, with a back-off from 3 s to 30 s.

Bundle identity: `com.android.nexus.aaos_nexus_sdv_tcu.NexusBridge`.

## Channels

From [`catalog/nexus_bridge.vsidl`](catalog/nexus_bridge.vsidl):

| Direction | Message | Topic |
|---|---|---|
| vehicle → cloud | `com.android.sdv.sample.quickstart.TirePressure` | `pressure` |
| cloud → vehicle | `com.nexussdv.sample.PressureLimit` | `pressure-limit` |
| cloud → vehicle | `com.nexussdv.sample.DoorCommand` | `door-command` |
| vehicle → cloud | `com.nexussdv.sdk.Uplink` | `uplink` |
| cloud → vehicle | `com.nexussdv.sdk.Command` | `command` |

`Uplink` and `Command` ([`../nexus-sdk-catalog/`](../nexus-sdk-catalog/nexus_sdk.proto)) carry a service of one's own without a new Bridge.

## Read all (experimental)

`read-all.conf` in the Bridge's data directory (`/data/service_bundle_data/com.android.nexus.aaos_nexus_sdv_tcu/NexusBridge/`), one `<package> <bundle>` per line: the Bridge also carries the publications of these bundles. Active after a restart of the Bridge, then of the `nexus-connectivity-agent`, in this order; the Bridge looks once, at its start. Without the file it is off.

## Files

| File | Contents |
|---|---|
| `src/lib.rs` | the bundle and its subscriptions |
| `src/publish.rs` | publishing on the Data Tunnel |
| `src/link.rs` | the Unix socket to the `nexus-connectivity-agent` |
| `src/decode.rs` | the log line for a received message |
| `../common/read_all.rs` | which publications read all carries |
| `catalog/nexus_bridge.vsidl` | the Bridge's channels |
| `configs/permissions/` | its `AuthzPolicy`, generated from the catalog by [`../vsidl-generate.sh`](../vsidl-generate.sh) |
| `nexus_bridge.publications` | slot size per published topic |
| `Android.bp` | builds `libnexus_bridge.so` |

## Building

```bash
m libnexus_bridge                         # the bundle alone
m com.android.nexus.aaos_nexus_sdv_tcu    # the APEX that ships it
```
