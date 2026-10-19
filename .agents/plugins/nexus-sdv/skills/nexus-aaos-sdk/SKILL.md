---
name: nexus-aaos-sdk
description: Walk a workshop participant through service pairs between an AAOS SDV vehicle and the Nexus SDV cloud — the demo pairs for tyre pressure, pressure limit and door command, writing a service pair of one's own with the Bridge's generic Uplink and Command (or read all), and a deep dive into the Bridge's permissions, the registry's grants and provisioning. Use in the Nexus workshop after nexus-connectivity, or when asked how a vehicle service and a cloud service exchange messages through Nexus.
---

# Nexus AAOS SDK: service pairs between vehicle and cloud

**Draft for the workshop.** One of three building blocks, each usable on its own:

- **nexus-connectivity**: what is in your vehicle, where the cloud is, how the two are
  connected.
- **nexus-aaos-sdk** (this one): the demo service pairs between vehicle and cloud, and a
  service of your own.
- **nexus-telemetry**: a vehicle's signals on their way into the platform's storage.

It assumes a workstation prepared for the workshop: for the workshop we use two SDV Core
VMs of a Cuttlefish vehicle; the Nexus Bridge and all examples needed are installed; the
vehicle is provisioned under the participant's VIN (how to find yours: [Session
values](#session-values)); and a Nexus platform runs in the workshop's GCP project.

Developer guide behind it: [NEXUS-AAOS-SDK.md](../../../../../aaos/NEXUS-AAOS-SDK.md).

A **service pair** is a service bundle in the vehicle and a cloud service, connected through
Nexus: the bundle speaks on the vehicle's Data Tunnel, the Nexus Bridge carries the message
to the cloud as `pubsub.<VIN>.<topic>`, and the cloud service is registered for that topic.

## Contents

- [First: who runs the commands?](#first-who-runs-the-commands)
- [Session values](#session-values)
- [1. The demo pairs](#1-the-demo-pairs)
  - [1.1 Start the bundles](#11-start-the-bundles)
  - [1.2 Inside the vehicle only: Google's quickstart](#12-inside-the-vehicle-only-googles-quickstart)
  - [1.3 The cloud services](#13-the-cloud-services)
  - [1.4 The same message in the cloud](#14-the-same-message-in-the-cloud)
  - [1.5 Cloud → vehicle: pressure limit and door command](#15-cloud--vehicle-pressure-limit-and-door-command)
  - [1.6 In your own words](#16-in-your-own-words)
- [2. A service pair of your own](#2-a-service-pair-of-your-own)
  - [2.1 The bundle: catalog and generated code](#21-the-bundle-catalog-and-generated-code)
  - [2.2 The bundle: your code](#22-the-bundle-your-code)
  - [2.3 The bundle: build, install, start](#23-the-bundle-build-install-start)
  - [2.4 The cloud service](#24-the-cloud-service)
  - [2.5 Hand it over](#25-hand-it-over)
  - [2.6 See the loop](#26-see-the-loop)
  - [2.7 Read all, for your own message type](#27-read-all-for-your-own-message-type)
- [3. Deep dive](#3-deep-dive)
  - [3.1 What the Bridge may carry](#31-what-the-bridge-may-carry)
  - [3.2 Offer and grant: the cloud decides](#32-offer-and-grant-the-cloud-decides)
  - [3.3 How the vehicle got its identity](#33-how-the-vehicle-got-its-identity)
- [When something is not as expected](#when-something-is-not-as-expected)
  - [No VIN](#no-vin)

## First: who runs the commands?

As in `nexus-connectivity`: ask once whether the participant runs the commands or you run
them, and keep to it. One step at a time, the result first, then two or three sentences.
Never print a token, key or password.

## Session values

**First, your VIN.** The workstation has set it for you:

```bash
echo "$MY_VIN"
```

Expected: your VIN, e.g. `STUDENT07`. If the line is empty, go to
[No VIN](#no-vin) under "When something is not as expected" first.

Then the rest, once per shell; every step uses them.

```bash
A=/opt/cvd-host-sdv/bin/adb
CORE="$A -s 0.0.0.0:6521"; CORE3="$A -s 0.0.0.0:6522"
# The workshop's Nexus platform
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)   # set by the workstation: qwiklabs-asl-04-585aa17d04cc
REGION=europe-west4; CLUSTER=nxs-ws-01-gke
DNS_ZONE=nexus-automobility-cloud; BASE_DOMAIN=nexus.automobility.cloud
CTX=gke_${PROJECT_ID}_${REGION}_${CLUSTER}     # the kubectl context
# Your trees on this workstation (step 2)
AAOS_ROOT=${AAOS_ROOT:?set AAOS_ROOT to the workstation's AOSP tree}
NEXUS_ROOT=${NEXUS_ROOT:?set NEXUS_ROOT to the workstation's Nexus checkout}
echo "project $PROJECT_ID, AOSP $AAOS_ROOT, Nexus $NEXUS_ROOT"
```

`PROJECT_ID` comes from the workstation's `gcloud` configuration, where the workshop has
set it. If the line above shows an empty project, set it once:
`gcloud config set project qwiklabs-asl-04-585aa17d04cc`, then the session values again.

Once, if `nexus-connectivity` has not done it on this workstation:

```bash
gcloud container clusters get-credentials "$CLUSTER" --region "$REGION" --project "$PROJECT_ID" --dns-endpoint
```

`--dns-endpoint` reaches the cluster through Google's front end, from any address.

## 1. The demo pairs

This is the heart of the workshop: here the SDV ecosystem should click. Take the time it
needs. Before each step that sends a message, ask the participant where they expect it to
show up, and wait for the answer before running the command; afterwards, compare.

| Pair | In the vehicle (Core) | In the cloud | Direction |
|---|---|---|---|
| Tyre pressure | Google's `Manager` publishes `TirePressure` on `pressure`; Google's `Monitor` reads it in the vehicle | `pressure-monitor` logs it | vehicle → cloud |
| Pressure limit | `PressureAdvisor` receives `PressureLimit` on `pressure-limit` | `pressure-monitor` sends it | cloud → vehicle |
| Door command | `DoorController` receives `DoorCommand` on `door-command` | `door-control` sends `LOCK`, `UNLOCK` | cloud → vehicle |

### 1.1 Start the bundles

After every boot of the vehicle:

```bash
$CORE root >/dev/null
for b in com.android.sdv.sample.quickstart.Manager com.android.sdv.sample.quickstart.Monitor \
         com.nexussdv.sample.PressureAdvisor com.nexussdv.sample.DoorController; do
  $CORE shell sdv_service_bundle start "local-vm:$b/instance"
done
$CORE shell 'ps -A | grep -E "Manager|Monitor|PressureAdvisor|DoorController"'
```

Expected: four processes `<Bundle>:instance`.

`Manager` and `Monitor` are Google's own quickstart sample, as the platform ships it
(`com.android.sdv.sample.quickstart`). `PressureAdvisor` and `DoorController` are examples
from the Nexus repository (`com.nexussdv.sample`, in `aaos/nexus-sdv-sample/`).

### 1.2 Inside the vehicle only: Google's quickstart

Ask first: `Manager` publishes a tyre pressure — who receives it?

```bash
$CORE logcat -d | grep -E 'sdv_lm_manager: Publishing|sdv_lm_monitor: Received message' | tail -4
```

Expected: `Manager` publishes `240`, `235`, … and `Monitor` receives the same values. This is
Google's sample as Google ships it: two service bundles on the vehicle's Data Tunnel, nothing
of Nexus involved yet.

### 1.3 The cloud services

Deployed by the workshop leaders, shared by everyone:

```bash
kubectl --context "$CTX" -n sample-services get pods
kubectl --context "$CTX" -n sample-services logs deploy/pressure-monitor | grep registered
kubectl --context "$CTX" -n sample-services logs deploy/door-control | grep registered
```

Expected: both pods `Running`; `registered pressure-monitor for pressure and
pressure-monitor-limit for pressure-limit`; `registered door-control for door-command,
cloud-to-vehicle`. A registration is what opens the channel for every vehicle that offers the
topic.

### 1.4 The same message in the cloud

Ask first: does the cloud get the tyre pressure too, and did anyone change Google's
`Manager` for it?

```bash
kubectl --context "$CTX" -n sample-services logs deploy/pressure-monitor --tail=200 \
  | grep -E "vin=(\*\*\*${MY_VIN: -4}|${MY_VIN}) " | tail -3
```

Expected: `pressure received vin=<your VIN> pressure=<n>`, the same values as in 1.2. A
platform can be set to log VINs masked, as `vin=***<last four>`; the command finds both. One publication, two subscribers: `Monitor` in the vehicle
and `pressure-monitor` in the cloud. The Nexus Bridge subscribed to it like any other bundle;
`Manager` is unchanged.

### 1.5 Cloud → vehicle: pressure limit and door command

Ask first: the cloud sends a door command — which vehicle gets it?

Terminal 1, the vehicle:

```bash
$CORE logcat | grep --line-buffered -E 'pressure-advisor|door-controller'
```

Terminal 2, from the root of the Nexus checkout:

```bash
NEXUS_DEMO_CONTEXT="$CTX" NEXUS_DEMO_VIN="$MY_VIN" NEXUS_DEMO_ROUNDS=3 sample-services/aaos/demo-sequence.sh
```

Expected: terminal 2 `✓ sequence sent`; terminal 1 `pressure-advisor: max_pressure=250`,
`door-controller: action=LOCK`, `max_pressure=230`, `action=UNLOCK`, three times. Each
message went to your vehicle only: the cloud names the VIN, the hub routes by it.

**Optional: watch the commands arrive in your vehicle.**

> **Stay on the vehicle's side for this one: the AAOS terminal on the workstation, not the
> cloud.** The leaf is the vehicle's own NATS server — it runs in Cuttlefish, on Core3, so
> leaf = Cuttlefish = your vehicle. What shows up here has already crossed from the cloud
> into the car.

In a third terminal, before running `demo-sequence.sh`. The leaf accepts local subscribers
on its port 4222 without a login; this needs the `nats` command line on the workstation:

```bash
nats --server nats://192.168.98.5:4222 sub "pubsub.$MY_VIN.>" --timestamp
```

Expected: `Received on "pubsub.<VIN>.pressure-limit"` and `"pubsub.<VIN>.door-command"`, one
for each message of the sequence — and in between, every second, `pubsub.<VIN>.pressure`:
the tyre pressure leaving the vehicle the other way. The commands appear here before the
Nexus Bridge hands them to `PressureAdvisor` and `DoorController`.

**Optional: the same commands leaving the cloud.** This one runs on the cloud's side, in the
cluster (nats-box), and needs nothing on the workstation besides `kubectl`. It subscribes to
exactly the two subjects the cloud services send to your vehicle and shows each message's
bytes; it ends after the first round, four messages:

```bash
gcloud secrets versions access latest --secret=NATS_CONNECTOR_PASSWORD --project "$PROJECT_ID" \
| kubectl --context "$CTX" -n base-services exec -i deploy/nats-box -- \
    sh -c "IFS= read -r NATS_PASSWORD; export NATS_PASSWORD NATS_USER=connector; nats sub pubsub.$MY_VIN.pressure-limit pubsub.$MY_VIN.door-command --count 4 --timestamp --translate 'od -An -tx1'"
```

Expected (measured on a test platform on 2026-10-19):

```
[#1] @ Oct 19 16:00:22.572689 Received on "pubsub.PKG16MESH02.pressure-limit"
 08 fa 01
[#2] @ Oct 19 16:00:23.723167 Received on "pubsub.PKG16MESH02.door-command"
 08 01
```

The bytes are the protobuf messages themselves: `08 fa 01` is field 1 with the value 250, the
`PressureLimit` of 250; `08 01` is field 1 with the value 1, `DoorCommand` `LOCK`. The subject
carries your VIN: that is how the hub knows the message is for your vehicle only. With both
optional views side by side, the same message is seen twice — leaving the cloud at the hub,
arriving in the car at the leaf.

### 1.6 In your own words

Close step 1 by asking the participant to describe the way of one message — the tyre
pressure, or the door command — from one end to the other. Fill in what is missing, along
this line:

```
bundle → Data Tunnel → Nexus Bridge → leaf (Core3) → hub (cloud) → cloud service
```

and back for the door command. Move on to step 2 once this way is clear: everything after
builds on it.

## 2. A service pair of your own

Two ways; the first is the one to take.

| | Uplink and Command (recommended) | Read all (experimental) |
|---|---|---|
| Vehicle → cloud | your bundle publishes `com.nexussdv.sdk.Uplink` on `uplink` | the Bridge carries your bundle's own message and topic |
| Cloud → vehicle | the cloud sends `com.nexussdv.sdk.Command` on `command`, `target` = your bundle | — |
| On the vehicle | install your bundle's APEX | also `read-all.conf`, restart Bridge and agent |
| Bridge or image rebuilt | no | no |

The two messages ([`nexus_sdk.proto`](../../../../../aaos/nexus-sdk-catalog/nexus_sdk.proto)):

```proto
message Uplink  { string name = 1; bytes payload = 2; }                  // name ≤ 64, payload ≤ 880 bytes
message Command { string target = 1; string name = 2; bytes payload = 3; }
```

What you build: a bundle `MyService` that publishes an `Uplink` every two seconds and logs
every `Command` addressed to it, and a cloud service that receives your vehicle's `Uplink`
and answers each with a `Command`. The two directions in one loop.

### 2.1 The bundle: catalog and generated code

Your code lives in your AOSP tree, `$AAOS_ROOT/vendor/nexus/workshop/my-service/`. The tree is
yours alone; the names need not be unique beyond your vehicle. Open the directory in Android
Studio for Platform to edit; build in a terminal.

```bash
W=$AAOS_ROOT/vendor/nexus/workshop/my-service
mkdir -p $W/catalog
cat > $W/catalog/my_service.vsidl <<'EOF'
# My service bundle: sends an Uplink, receives a Command. Both types come from the Nexus
# SDK catalog (vendor/nexus/nexus-sdk-catalog); the Nexus Bridge carries them.
package: "com.nexussdv.workshop"

service_bundle {
  name: "MyService"
  publisher { message: "com.nexussdv.sdk.Uplink" topic: "uplink" capacity: 8 }
  subscriber { message: "com.nexussdv.sdk.Command" topic: "command" }
}
EOF
cat > $W/catalog/Android.bp <<'EOF'
package {
    default_applicable_licenses: ["Android-Apache-2.0"],
}

filegroup {
    name: "vsidl_my_service_catalog",
    srcs: ["**/*"],
}
EOF
```

Generate the bundle's code, configuration and APEX with Google's VSIDL compiler, once:

```bash
cd $AAOS_ROOT && source build/envsetup.sh && lunch sdv_core_cf-trunk_staging-userdebug
m vsidlc
out/host/linux-x86/bin/vsidlc -c $W/catalog -o $W --genrule --services --apex \
  --target-api latest -d $AAOS_ROOT/vendor/nexus/nexus-sdk-catalog
ls $W
```

Expected: `apex/`, `configs/`, `services/MyService/` beside `catalog/`, the same layout as the
Nexus example (`vendor/nexus/nexus-sdv-sample/`).

**The APEX key.** The vehicle's update manager installs a new APEX only if it is signed with
the platform's samples key. The generated `apex/` has a key pair of its own: overwrite both
files with the samples key, keeping the generated names:

```bash
ls $W/apex/*.pem $W/apex/*.avbpubkey
cp $AAOS_ROOT/vendor/nexus/nexus-sdv-sample/apex/com.nexussdv.sample.pem       $W/apex/<generated name>.pem
cp $AAOS_ROOT/vendor/nexus/nexus-sdv-sample/apex/com.nexussdv.sample.avbpubkey $W/apex/<generated name>.avbpubkey
```

### 2.2 The bundle: your code

In Android Studio for Platform, open `$W/services/MyService/src/main.rs`. The generator wrote
the frame — start, stop, publisher and observer — and leaves two places to fill, marked
`TODO`, in the functions named after message and topic. The pattern is the one of Google's
`Manager` (publishes) and of our `DoorController` (receives).

Android Studio for Platform knows the AOSP tree: beside your two places it shows the
generated frame and lets you follow it into Google's `sdv` library — worth a look, to see
what the generator does for you. Build in the terminal (2.3). Whoever prefers not to type
the code can ask the agent to fill in the two places below.

The publisher, every two seconds an `Uplink` with a counter:

```rust
let mut n: u32 = 0;
loop {
    sleep(Duration::from_secs(2)).await;
    n += 1;
    let message = Uplink { name: "counter".into(), payload: n.to_be_bytes().to_vec(), ..Default::default() };
    info!("my-service: uplink {n}");
    if let Err(e) = publisher.publish(&message) {
        error!("my-service: publish failed: {e:?}");
    }
}
```

The observer, every `Command` for `MyService`:

```rust
Ok(messages) => {
    for command in messages {
        if command.target == "MyService" {
            info!("my-service: command {} with {} byte(s)", command.name, command.payload.len());
        }
    }
}
```

### 2.3 The bundle: build, install, start

```bash
cd $AAOS_ROOT && m com.nexussdv.workshop
APEX=$AAOS_ROOT/out/target/product/sdv_core_cf/obj/ETC/com.nexussdv.workshop_intermediates/com.nexussdv.workshop.apex
UM=/apex/com.android.sdv.sample.update_manager.client/bin/sdv_update_manager_client
$CORE root >/dev/null; $CORE shell mkdir -p /data/mydir
$CORE push "$APEX" /data/mydir/
$CORE shell $UM prepare service-bundle --boot_attempts 2 --apex_path /data/mydir/com.nexussdv.workshop.apex
$CORE shell $UM activate
$CORE reboot && $CORE wait-for-device
$CORE root >/dev/null; $CORE shell $UM commit
$CORE shell sdv_service_bundle start local-vm:com.nexussdv.workshop.MyService/instance
$CORE logcat -d | grep my-service | tail -3
```

Expected: `com.nexussdv.workshop@1` in `ls /apex`; `my-service: uplink 1`, `2`, … every two
seconds. If `commit` fails right after the reboot, wait a few seconds and repeat it. A rebuilt
APEX needs a higher `version` in `$W/apex/apex_manifest.json`. After the reboot of Core, start
the sample bundles of 1.1 again if you still need them.

Your `Uplink` does not reach the cloud yet: no cloud service is registered for `uplink`, so
the registry has not granted it (`nexus-connectivity`, step 7).

### 2.4 The cloud service

Start from the reference service `door-control` in your Nexus checkout, under a name with your
VIN — in the cloud all participants share one cluster:

```bash
S=${MY_VIN,,}-service
cd $NEXUS_ROOT/sample-services/aaos && mkdir -p $S/src
sed "s/^name = \"door-control\"/name = \"$S\"/" door-control/Cargo.toml > $S/Cargo.toml
cp door-control/Cargo.lock $S/Cargo.lock
sed -e "s#door-control#$S#g" door-control/Dockerfile > $S/Dockerfile
```

This copies `door-control`'s build files only, renamed: the dependencies (`Cargo.toml`, with
the exact versions `door-control` is tested with in `Cargo.lock`) and the image build
(`Dockerfile`). The code is new: write `$S/src/main.rs` in Android Studio for Platform or any
editor.

`$S/src/main.rs`, the whole service — register both directions, and answer every `Uplink` of
your vehicle with a `Command`:

```rust
use std::sync::Arc;
use nexus_aaos_sdk::{CloudService, Config, Direction};
use nexus_sample_messages::sdk::{Command, Uplink};

const MY_VIN: &str = "<your VIN>";

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let service = Arc::new(CloudService::connect(Config::from_env()?).await?);
    service.register("<your VIN in lower case>-up", "uplink", Direction::VehicleToCloud).await?;
    service.register("<your VIN in lower case>-cmd", "command", Direction::CloudToVehicle).await?;
    let replies = service.clone();
    service
        .subscribe("uplink", move |delivery| {
            if delivery.vin != MY_VIN {
                return; // every vehicle's Uplink reaches every service registered for it
            }
            let Ok(uplink) = delivery.decode::<Uplink>() else { return };
            println!("uplink {} with {} byte(s)", uplink.name, uplink.payload.len());
            let replies = replies.clone();
            tokio::spawn(async move {
                let command = Command { target: "MyService".into(), name: "ack".into(), payload: uplink.payload };
                if let Err(e) = replies.publish_message(MY_VIN, "command", &command).await {
                    eprintln!("command failed: {e}");
                }
            });
        })
        .await?;
    Ok(())
}
```

Check that it builds:

```bash
cd $NEXUS_ROOT/sample-services/aaos/$S && cargo build
```

### 2.5 Hand it over

Participants do not deploy. Put your service into the workshop's handover bucket; the
workshop leaders build and deploy it, and tell you when it runs:

```bash
cd $NEXUS_ROOT && tar czf /tmp/$S.tgz sample-services/aaos/$S
gcloud storage cp /tmp/$S.tgz gs://$PROJECT_ID-workshop-handover/$MY_VIN/
```

What the leaders need is in the archive: the directory with `Cargo.toml`, `Dockerfile` and
`src/main.rs`, built from the root of the Nexus checkout like `door-control`.

### 2.6 See the loop

Once the leaders say it runs:

```bash
kubectl --context "$CTX" -n sample-services logs deploy/$S --tail=5
$CORE logcat -d | grep my-service | tail -4
```

Expected: in the cloud `uplink counter with 4 byte(s)`; in the vehicle `my-service: uplink <n>`
and `my-service: command ack with 4 byte(s)`. Your bundle's message went to the cloud, your
service answered, the answer came back — through the Nexus Bridge as installed, without a new
Bridge or image.

### 2.7 Read all, for your own message type

If your bundle publishes a message type of its own instead of `Uplink`:

```bash
$CORE3 root >/dev/null
D=/data/service_bundle_data/com.android.nexus.aaos_nexus_sdv_tcu/NexusBridge
$CORE3 shell "echo 'com.nexussdv.workshop MyService' >> $D/read-all.conf"
$CORE3 shell "sdv_service_bundle destroy local-vm:com.android.nexus.aaos_nexus_sdv_tcu.NexusBridge/instance; sdv_service_bundle start local-vm:com.android.nexus.aaos_nexus_sdv_tcu.NexusBridge/instance"
$CORE3 shell 'stop nexus_connectivity_agent; start nexus_connectivity_agent'
$CORE3 shell "cat $D/discovered; grep 'read all' /data/misc/nexus/agent.log | tail -n 1"
```

`destroy`, not `stop`: the Bridge reads `read-all.conf` when its process starts. Your bundle
must run before that: the Bridge looks once. Expected: your topic in `discovered`, and
`read all: offering 1 publication(s)` from the agent. The cloud service registers for your
topic like for `uplink` and decodes your own `.proto`.

## 3. Deep dive

### 3.1 What the Bridge may carry

The platform enforces the Bridge's permissions file, and the Bridge derives its subscriptions
from the same file:

```bash
$CORE3 shell 'cat /apex/com.android.nexus.aaos_nexus_sdv_tcu/etc/permissions/com.android.nexus.aaos_nexus_sdv_tcu.NexusBridge.permissions' | grep -vE '^#|^$'
```

Expected: `subscriber` for `TirePressure`/`pressure` and `Uplink`/`uplink`, `publisher` for
`PressureLimit`, `DoorCommand`, `Command`, and `allow_read_all: true`. Source: the Bridge's
catalog [`nexus_bridge.vsidl`](../../../../../aaos/nexus-bridge/catalog/nexus_bridge.vsidl);
`allow_read_all` is added by
[`vsidl-generate.sh`](../../../../../aaos/vsidl-generate.sh), as Google's Telemetry agent
declares it.

### 3.2 Offer and grant: the cloud decides

The vehicle offers what the Bridge may carry; the registry grants a topic while a cloud
service is registered for it; the hub lets the vehicle use exactly the granted subjects.

In the vehicle, what was offered and granted:

```bash
$CORE3 shell 'grep -E "announced|grant received|grant changed" /data/misc/nexus/agent.log | tail -n 4'
$CORE3 shell 'grep "leaf status" /data/misc/nexus/agent.log | tail -n 1'
```

Expected: `announced 5 offer(s)` (pressure, uplink, pressure-limit, door-command, command),
`grant received …: pub=<n> sub=<m>`. Only registered topics are granted: `uplink` and
`command` stay out until a service registers them.

At the hub, the grant stored for your vehicle (read-only):

```bash
gcloud secrets versions access latest --secret=NATS_REGISTRY_PASSWORD --project "$PROJECT_ID" \
| kubectl --context "$CTX" -n base-services exec -i deploy/nats-box -- \
    sh -c "IFS= read -r NATS_PASSWORD; export NATS_PASSWORD NATS_USER=nexus-registry; nats kv get nexus-registry-grants $MY_VIN"
```

Expected: `{"pub":["pubsub.<VIN>.pressure"],"sub":["pubsub.<VIN>.pressure-limit","pubsub.<VIN>.door-command"]}`.

At your own leaf, what arrives in the vehicle: the optional step at the end of 1.5.

### 3.3 How the vehicle got its identity

`provision-and-run.sh` ([INSTALL.md](../../../../../aaos/INSTALL.md), part 3), as run for
your vehicle before the workshop:

```bash
PKI_BUCKET_PROJECT=<project> ./provision-and-run.sh <VIN> <base-domain> 0.0.0.0:6522
```

| Step | Who | What |
|---|---|---|
| 1 | the script | trust anchors from the platform's public bucket |
| 2 | the script, as the factory | a factory identity for the VIN from `factory.` — the operator secret proves it is the factory |
| 3 | the script | resolves the cloud's names on the workstation, writes `nexus.env`, starts the `nexus-connectivity-agent` |
| 4 | `nexus-connectivity-agent` | exchanges the factory identity at `registration.` for its operational certificate |
| 5 | `nexus-connectivity-agent` | gets a token at `keycloak.` with that certificate, writes `leaf.conf`, starts the leaf |
| 6 | the leaf | connects to the hub at `nats.` over TLS; the hub's callout reads the VIN from the certificate and lets the vehicle use its control subject and its grant |

```bash
$CORE3 shell 'ls -l /data/misc/nexus/certificates' | awk '{print $6, $7, $8}'
```

The times show it: trust anchors and factory identity from the script, `operational-*` and
`oidc-access-token` from the agent.

## When something is not as expected

| Seen | Likely cause |
|---|---|
| `nats: command not found` in 1.5 | the workstation should have it at `/usr/local/bin/nats`; without it, watch the commands at the hub instead (the second view in 1.5) |
| `echo "$MY_VIN"` prints nothing | the workstation did not set your VIN: [No VIN](#no-vin) |

### No VIN

`echo "$MY_VIN"` prints nothing: the workstation did not set it. Set it from your workshop
account, by the same rule:

```bash
ACCOUNT=$(gcloud config get-value account 2>/dev/null)
export MY_VIN=$(printf '%s' "${ACCOUNT%@*}" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9' | cut -c1-17)
echo "$MY_VIN"
```

If your vehicle is not provisioned under this VIN yet (`NEXUS_VIN` in
`/data/misc/nexus/nexus.env` on Core3 is missing or different), provision it — from
`aaos/aaos-nexus-sdv-tcu/` of the Nexus checkout, with the operator secret the workshop gave
you. First the secret:

```bash
printf "Operator secret: "; read -rs FACTORY_OPERATOR_CLIENT_SECRET; echo; export FACTORY_OPERATOR_CLIENT_SECRET
```

Then, with the workshop's values:

```bash
ADB_BIN=/opt/cvd-host-sdv/bin/adb PKI_BUCKET_PROJECT=qwiklabs-asl-04-585aa17d04cc \
  ./provision-and-run.sh "$MY_VIN" nexus.automobility.cloud 0.0.0.0:6522
unset FACTORY_OPERATOR_CLIENT_SECRET
```

Expected at the end: `✓ PASS`.
