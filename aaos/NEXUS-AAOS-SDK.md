# The Nexus AAOS SDK

Status: in the making · 2026-10-16

A service bundle in the vehicle and a cloud service form a **service pair**, declared once in a VSIDL catalog and connected through Nexus.

The samples extend Google's quickstart (`system/software_defined_vehicle/samples/quickstart/`): its `Manager` publishes `TirePressure`, and the cloud receives it.

## How it works

```
   you write                        you get                          you write

 ┌──────────────┐   ┌──────────────────────────────────────┐   ┌───────────────┐
 │ service      │   │ Nexus Bridge · connectivity · hub    │   │ cloud         │
 │ bundle       │◀─▶│ identity per vehicle · registry      │◀─▶│ service       │
 └──────────────┘   └──────────────────────────────────────┘   └───────────────┘
        ▲                  topic named in the Bridge's catalog          ▲
        └───────────── one VSIDL catalog: message and topic ────────────┘
```

| | Vehicle to cloud | Cloud to vehicle |
|---|---|---|
| Sample | tyre pressure: `Manager` → `pressure-monitor` | door command: `door-control` → `DoorController` |
| In the vehicle you write | a bundle that publishes | a bundle that subscribes |
| In the cloud you write | `register`, `subscribe` | `register`, `publish_message` |
| The message reaches | every cloud service registered for the topic | the one vehicle named by its VIN |

### What you do

| Step | What | Where |
|---|---|---|
| 1 | Declare message and bundle, generate, fill in the TODO | a VSIDL catalog, e.g. [`nexus-sdv-sample/catalog/`](nexus-sdv-sample/catalog/) |
| 2 | Name the topic in the Bridge's catalog | [`nexus-bridge/catalog/`](nexus-bridge/catalog/) |
| 3 | Write the cloud service | e.g. [`sample-services/aaos/door-control/`](../sample-services/aaos/door-control/) |
| 4 | Package and deploy it | `Dockerfile`, Helm chart, Cloud Build |
| 5 | See the message arrive | [`demo-sequence.sh`](../sample-services/aaos/demo-sequence.sh), logs |

### What you get

| Part | What it does |
|---|---|
| [Nexus Bridge](nexus-bridge/README.md), [`nexus-connectivity-agent`](nexus-connectivity-agent/README.md) | carry messages between the Data Tunnel and the cloud |
| Vehicle identity | each vehicle connects under its own VIN |
| Cloud Service Registry | opens a vehicle's channel while a cloud service is registered for it |
| [`nexus-aaos-sdk`](nexus-aaos-sdk/README.md) | connection, registration, publish, subscribe |
| [`sample-services/aaos/messages/`](../sample-services/aaos/messages/) | cloud message types, generated from the same `.proto` at build time |
| [`vsidl-generate.sh`](vsidl-generate.sh) | runs `vsidlc` over the catalogs |
| Cloud Build file, Helm chart | build and deploy the cloud services |

## Step by step: the door command

### 1. Declare the message and the bundle

[`nexus_sample.proto`](nexus-sdv-sample/catalog/nexus_sample.proto):

```proto
message DoorCommand {
  enum Action { ACTION_UNSPECIFIED = 0; LOCK = 1; UNLOCK = 2; }
  Action action = 1;
}
```

[`nexus_sample.vsidl`](nexus-sdv-sample/catalog/nexus_sample.vsidl):

```
service_bundle {
  name: "DoorController"
  subscriber { message: "DoorCommand" topic: "door-command" }
}
```

In an AOSP tree with `aaos/` staged under `vendor/nexus/`:

```bash
aaos/vsidl-generate.sh <aosp-root> --first     # --first only once: it writes the code skeletons
```

The TODO in [`DoorController/src/main.rs`](nexus-sdv-sample/services/DoorController/src/main.rs), filled:

```rust
for command in messages {
    info!("door-controller: action={:?}", command.action.enum_value_or_default());
}
```

### 2. Name the topic in the Bridge's catalog

[`nexus_bridge.vsidl`](nexus-bridge/catalog/nexus_bridge.vsidl):

```
publisher { message: "com.nexussdv.sample.DoorCommand" topic: "door-command" capacity: 8 }
```

[`nexus_bridge.publications`](nexus-bridge/nexus_bridge.publications), the slot size:

```
com.nexussdv.sample.DoorCommand door-command 64
```

Then `vsidl-generate.sh` again and a Nexus-Bridge APEX with a higher version.

### 3. Write the cloud service

Message types: add the catalog's `.proto` to [`messages/build.rs`](../sample-services/aaos/messages/build.rs) and a module to [`lib.rs`](../sample-services/aaos/messages/src/lib.rs).

Dependencies ([`door-control/Cargo.toml`](../sample-services/aaos/door-control/Cargo.toml)):

```toml
nexus-aaos-sdk        = { path = "../../../aaos/nexus-aaos-sdk" }
nexus-sample-messages = { path = "../messages" }
```

The service:

```rust
let service = CloudService::connect(Config::from_env()?).await?;
service.register("door-control", "door-command", Direction::CloudToVehicle).await?;
service.publish_message(vin, "door-command", &DoorCommand { action: Action::Lock as i32 }).await?;
```

### 4. Package and deploy

A `Dockerfile` like [door-control's](../sample-services/aaos/door-control/Dockerfile), a template in `iac/helm/reference-services`, the name in the Cloud Build file's list:

```bash
gcloud builds submit . --project <project> --region <region> \
  --config=iac/cloudbuild/build-push-deploy-reference-services.yaml \
  --substitutions=_ARCH=<arm64|amd64>
```

At runtime: the vehicle offers `door-command`, the service registers it, the registry grants `pubsub.<vin>.door-command`, the message reaches `DoorController`.

### 5. See it end to end

```bash
sample-services/aaos/demo-sequence.sh
adb logcat -d | grep door-controller
# door-controller: action=LOCK
```

## The tyre pressure: the other direction

| Step | Door command | Tyre pressure |
|---|---|---|
| 1 | our catalog | Google's `TirePressure`, published by `Manager` ([`google-quickstart/`](google-quickstart/README.md)) |
| 2 | `publisher` line and slot size | `subscriber` line |
| 3, types | from our catalog | from an excerpt of Google's `.proto` in [`messages/proto/`](../sample-services/aaos/messages/proto/) |
| 3, service | `Direction::CloudToVehicle`, `publish_message` | `Direction::VehicleToCloud`, `subscribe`, `Delivery::decode` |
| 5 | `logcat` in the vehicle | `pressure received vin=… pressure=<n>` in the service's log |

## Roadmap to a complete SDK

**For the developer**

1. A template for a new cloud service.
2. One command to deploy a new service.
3. Message types for any catalog.
4. A check that the bundle's and the Bridge's catalogs agree, and a derived slot size.
5. A developer guide, "Developing a cloud SDV service".
6. A skill for coding agents along the same steps.

**What a service pair can do**

7. Request and reply.
8. More than one topic per registration.
9. Cloud services in other languages.

**The platform underneath**

10. An identity per cloud service.
11. Schema compatibility across vehicle generations.
12. A common top-level place for library, `vsidl-generate.sh` and template.

A new channel reaches a vehicle as an update of the Nexus-Bridge APEX.
