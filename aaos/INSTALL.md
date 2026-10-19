# Installing Nexus on an AAOS SDV vehicle

Four parts:

1. [Build](#1-build)
2. [Install](#2-install)
3. [Connect — the factory process](#3-connect--the-factory-process)
4. [Test](#4-test)

Each step ends with a check.

VMs named in this guide: *the VM that holds the connectivity* (with the Telemetry Service), *the VM with the sample bundles*, *the head unit*.

| Place | What it has | Used in |
|---|---|---|
| Build machine | an AOSP tree and a checkout of this repository | part 1 |
| Host of the vehicle | `adb` access to the VMs and a checkout of this repository | parts 2, 3, 4 |
| Machine with access to the Nexus cluster | `kubectl`, `gcloud` and a checkout of this repository | part 4 |

---

## 1. Build

On the build machine. Result:

- `com.android.nexus.aaos_nexus_sdv_tcu.apex` — Nexus Bridge, `nexus-connectivity-agent`, `nats-server`, `nexus-telemetry-client`, init files
- `com.nexussdv.sample.apex` — `PressureAdvisor`, `DoorController`; optional
- `app-debug.apk` — Nexus VHAL example for the head unit; optional
- the image of `sdv_core_cf` — Nexus SELinux policy, Google's quickstart `Manager`; the same for every VM

### 1.1 What the build environment needs

- An AOSP tree for `sdv_core_cf`.
- A checkout of this repository beside the tree.
- Rust with the target `x86_64-unknown-linux-musl`.
- Network access to the hub (port 4222) and to github.com.

### 1.2 The two binaries from outside the tree

In the checkout:

```bash
cd aaos/nexus-connectivity-agent
cargo build --release --target x86_64-unknown-linux-musl
cd ../aaos-nexus-sdv-tcu
./fetch-nats-server.sh nats.<base-domain>
```

`fetch-nats-server.sh` fetches the `nats-server` release in the hub's version.

**Check:** the script ends with `Live Nexus NATS version: <version>` and `Fetched to …/prebuilt-nats-server`.

### 1.3 Into the AOSP tree

From the root of the checkout:

```bash
for d in nexus-bridge nexus-sdv-sample; do
  rsync -a --delete aaos/$d/ <aosp-root>/vendor/nexus/$d/
done
aaos/aaos-nexus-sdv-tcu/stage-into-aosp.sh <aosp-root>   # Nexus-Bridge APEX, telemetry client, policy
aaos/google-quickstart/stage.sh            <aosp-root>   # Manager with its TODO filled
```

Changes in Google's tree:
- one line in `device/google/sdv/sdv_core_cf/sdv_core_cf.mk`: `PRODUCT_PRIVATE_SEPOLICY_DIRS += vendor/nexus/aaos-nexus-sdv-tcu-sepolicy`;
- `min_sdk_version: "35"` on the modules of Google's telemetry SDK ([client's README](nexus-telemetry-client/README.md)).

SELinux:
- Permissive: the mode this version is developed and tested in, and recommended.
- Enforcing: in progress, not tested.

**Check:** `tail` of `sdv_core_cf.mk` shows the line; `ls <aosp-root>/vendor/nexus` shows the staged directories.

### 1.4 The APEXes and the image

In the AOSP tree:

```bash
source build/envsetup.sh && lunch sdv_core_cf-trunk_staging-userdebug
m com.android.nexus.aaos_nexus_sdv_tcu com.nexussdv.sample
m installclean && m
```

The APEXes are in `out/target/product/sdv_core_cf/obj/ETC/<name>_intermediates/`. `installclean` keeps them out of the image. A new version needs a higher `version` in `apex_manifest.json`.

**Check:** `out/target/product/sdv_core_cf/installed-files-product.txt` lists neither APEX under `/product/apex/`.

### 1.5 The head-unit app

JDK 21 or newer:

```bash
cd aaos/nexus-vhal-example && make build
```

**Check:** `app/build/outputs/apk/debug/app-debug.apk` exists.

---

## 2. Install

On the host of the vehicle. Result: every Nexus module in place.

### 2.1 The image onto the VMs

The head unit needs one boot configuration line for the app; the other VMs need none:

```
androidboot.nexus.leaf=<address of the VM with the leaf>:4222
```

On a Cuttlefish mesh, in `aaos/test-environment` ([mesh.md](test-environment/mesh.md)):

```bash
sudo ./install-images.sh /opt/sdv-images-new core=sdv_core_instance2 core3=sdv_core_instance3
```

Start the VMs from fresh disks after an image change.

**Check:** `getprop ro.build.date` shows the new build; on the head unit `getprop ro.boot.nexus.leaf` shows the line.

### 2.2 What the vehicle's network must provide

On a Cuttlefish mesh `test-environment/mesh-start.sh` sets these:
- a default route on the VM that holds the connectivity: `ip route replace default via 192.168.98.1 dev eth1`;
- forwarding on the host;
- name resolution: `provision-and-run.sh` resolves the cloud's names on the host.

### 2.3 The APEXes

With the platform's update manager ([commands](aaos-nexus-sdv-tcu/TESTING.md#1-install-the-apex-on-the-guest)):

| APEX | VM |
|---|---|
| `com.android.nexus.aaos_nexus_sdv_tcu` | the VM that holds the connectivity |
| `com.nexussdv.sample` | the VM with the sample bundles |

On a VM without a Telemetry Service, switch the telemetry client off: `NEXUS_TELEMETRY_CLIENT=off` in part 3, or later `setprop persist.nexus.telemetry_client.enabled false` and a restart of `nexus_telemetry_client`.

### 2.4 The head-unit app

```bash
adb -s <head unit> install -r aaos/nexus-vhal-example/app/build/outputs/apk/debug/app-debug.apk
```

### 2.5 Are the Nexus modules installed?

```bash
adb -s <serial> shell 'ls /apex | grep -E "nexus"'
adb -s <serial> shell 'ps -AZ | grep -E "nexus|nats-server"'
adb -s <head unit> shell getprop ro.boot.nexus.leaf
adb -s <head unit> shell pm list packages io.nexussdv.vhalexample
```

| On | Expected |
|---|---|
| the VM that holds the connectivity | `com.android.nexus.aaos_nexus_sdv_tcu@<version>`; `nexus-connectivity-agent` in `u:r:nexus_connectivity_agent:s0`, `nexus-telemetry-client` in `u:r:nexus_telemetry_client:s0`; after part 3 also `nats-server` |
| the VM with the sample bundles | `com.nexussdv.sample@<version>` |
| the head unit | `package:io.nexussdv.vhalexample`; the leaf line |

---

## 3. Connect — the factory process

On the host of the vehicle, once per vehicle. Needs: base domain, GCP project, operator secret. The default operator client is `factory-operator`; its secret is in Secret Manager as `FACTORY_OPERATOR_CLIENT_SECRET`.

### 3.1 Is the Nexus cloud there?

```bash
cd aaos/aaos-nexus-sdv-tcu
PKI_BUCKET_PROJECT=<GCP project> ./check-nexus-cloud.sh <base-domain> --login
```

**Check:** `Summary: 9 passed, 0 failed`.

### 3.2 Provision the vehicle

```bash
printf "Operator secret: "; read -rs FACTORY_OPERATOR_CLIENT_SECRET; echo; export FACTORY_OPERATOR_CLIENT_SECRET
```

Enter the secret, then:

```bash
PKI_BUCKET_PROJECT=<GCP project> ./provision-and-run.sh <VIN> <base-domain> [adb-serial]
unset FACTORY_OPERATOR_CLIENT_SECRET
```

Further operator clients: [`iac/operating/keycloak-provision-client.sh`](../iac/operating/keycloak-provision-client.sh), selected with `FACTORY_CLIENT_ID=<client id>`. After a first provisioning the vehicle connects twice: the second connection carries its pub/sub channels.

**Check:** `✓ PASS`.

---

## 4. Test

### 4.1 In the vehicle: what runs by itself

| Program | Started by |
|---|---|
| `nexus-connectivity-agent`, `nats-server`, `nexus-telemetry-client` | init |
| Nexus Bridge | the platform's lifecycle |

### 4.2 In the vehicle: what is started by hand

After every boot. In the example **VM A** has the sample bundles, **VM B** the connectivity.

| Program | VM |
|---|---|
| `com.android.sdv.sample.quickstart.Manager`, `…Monitor` | A |
| `com.nexussdv.sample.PressureAdvisor`, `…DoorController` | A |
| `telemetry_sample_publisher`, the source of the telemetry speed | B |

```bash
ADB="adb -s <serial of VM A>"
$ADB root
$ADB shell sdv_service_bundle start local-vm:com.android.sdv.sample.quickstart.Manager/instance
$ADB shell sdv_service_bundle start local-vm:com.android.sdv.sample.quickstart.Monitor/instance
$ADB shell sdv_service_bundle start local-vm:com.nexussdv.sample.PressureAdvisor/instance
$ADB shell sdv_service_bundle start local-vm:com.nexussdv.sample.DoorController/instance
```

**Check:** `$ADB logcat -d | grep 'Publishing on TirePressure'` shows a changing pressure.

In `aaos/` of the checkout:

```bash
ADB="adb -s <serial of VM B>" nexus-telemetry-client/start-sample-publisher.sh
```

**Check:** `adb -s <serial of VM B> logcat -d -s nexus-telemetry-client | grep 'Report ready'` shows one a second.

### 4.3 In the cloud: the services of the samples

| Cloud service | Counterpart in the vehicle | What it does |
|---|---|---|
| `pressure-monitor` | `Manager`, `PressureAdvisor` | logs the tyre pressure, sends a pressure limit |
| `door-control` | `DoorController` | sends `LOCK` and `UNLOCK` |

A channel is open only while its cloud service is registered. Once per Nexus instance:

```bash
gcloud builds submit . --project <project> --region <region> \
  --config=iac/cloudbuild/build-push-deploy-reference-services.yaml \
  --substitutions=_ARCH=<arm64|amd64>
```

**Check:**

```bash
kubectl -n sample-services get pods
# door-control-…       1/1   Running
# pressure-monitor-…   1/1   Running
kubectl -n sample-services logs deploy/door-control | grep registered
# registered door-control for door-command, cloud-to-vehicle
kubectl -n sample-services logs deploy/pressure-monitor | grep registered
# registered pressure-monitor for pressure and pressure-monitor-limit for pressure-limit
```

### 4.4 See it work

`$ADB` is VM A unless VM B is named.

#### Vehicle to cloud: the tyre pressure

```bash
$ADB logcat -d | grep -E 'sdv_lm_manager: Publishing|sdv_lm_monitor: Received message' | tail -4
# … sdv_lm_manager: Publishing on TirePressure#PRESSURE: 230
# … sdv_lm_monitor: Received message on TirePressure#PRESSURE: [TirePressure { pressure: 230, …
kubectl -n sample-services logs deploy/pressure-monitor --tail=2
# … pressure received vin=…<last four characters of the VIN> pressure=230
```

**Check:** the cloud logs the vehicle's values, 240 down to 200 in steps of 5.

#### Cloud to vehicle: pressure limit and door command

Terminal 1:

```bash
$ADB logcat | grep --line-buffered -E 'pressure-advisor|door-controller'
```

Terminal 2, from the root of the checkout; asks for the kubectl context and the VIN:

```bash
NEXUS_DEMO_ROUNDS=5 sample-services/aaos/demo-sequence.sh
# round 1 of 5
# limit 250: 202
# door lock: 202
# …
# ✓ sequence sent
```

**Check:** terminal 1 shows `pressure-advisor: max_pressure=250`, `door-controller: action=LOCK`, `max_pressure=230`, `action=UNLOCK`, repeating.

#### Telemetry

Each report is one row of the BigTable table `telemetry`, key `<VIN>#<time>`.

```bash
adb -s <serial of VM B> logcat -d -s nexus-telemetry-client | grep -E 'publishing|Report ready' | tail -3
# … connected to the leaf at 127.0.0.1:4222, publishing telemetry-aaos-sdv.<VIN>
# … Report ready: config UUID "778f6d44-…", report UUID "…"
```

Three equivalent ways to read the rows; one is enough.

**Data API**, through `data-api-sampler`:

```bash
printf "Operator secret: "; read -rs SECRET; echo
```

```bash
curl -s https://storage.googleapis.com/<project>-nexus-sdv-public/pki/KEYCLOAK_TLS_CRT.pem -o keycloak-ca.pem
TOKEN=$(curl -s --cacert keycloak-ca.pem -X POST \
  https://keycloak.<base-domain>:8443/realms/sdv-telemetry/protocol/openid-connect/token \
  -d grant_type=client_credentials -d client_id=factory-operator \
  --data-urlencode "client_secret=$SECRET" | jq -r .access_token); unset SECRET
kubectl -n sample-services port-forward svc/data-api-sampler 18090:8080 &
```

After `Forwarding from 127.0.0.1:18090`:

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "localhost:18090/data/<VIN>/datatypes/dynamic:VELOCITY?lookback=5s"
# {"dynamic:VELOCITY":["38","4","187","48","172"]}
kill %1
```

**`cbt`** (`gcloud components install cbt`):

```bash
cbt -project <project> -instance bigtable-production-storage \
  read telemetry prefix='<VIN>#' columns='dynamic:VELOCITY' reversed=true count=3
# <VIN>#2026-10-13T14:43:55.048612817Z
#   dynamic:VELOCITY                         @ 2026/10/13-16:43:57.133000
#     "34"
```

**BigTable Studio**, instance `bigtable-production-storage`:

```sql
SELECT _key, dynamic['VELOCITY'] AS velocity
FROM telemetry
WHERE STARTS_WITH(_key, '<VIN>#')
ORDER BY _key DESC
LIMIT 3
```

**Check:** one row a second, a speed from 0 to 255 that changes.

#### The head-unit app

```bash
HU="adb -s <serial of the head unit>"
$HU shell am start -n io.nexussdv.vhalexample/.MainActivity
```

Allow the permissions (the first reads "access this device's location"), then *Start sending*.

**Check:** `Leaf: reachable · VIN: <VIN>`, `Sent` counts up every two seconds.

```bash
$HU root
$HU shell dumpsys android.hardware.automotive.vehicle.IVehicle/default --set 0x11600207 -f 15
cbt -project <project> -instance bigtable-production-storage \
  read telemetry prefix='<VIN>#' columns='dynamic:PERF_VEHICLE_SPEED' reversed=true count=3
#     "15"
```

**Check:** the screen and the cloud show 15.

A message reaches only whoever is connected at the moment it is sent.
