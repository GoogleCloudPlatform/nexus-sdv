---
name: nexus-connectivity
description: Walk a workshop participant through their own AAOS SDV vehicle and the Nexus SDV cloud it is connected to — what is installed and running in the vehicle, whether it reaches the internet, where the cloud's endpoints are, how the vehicle is configured to reach them, and how to find it in FleetView under its own VIN. Use at the start of the Nexus workshop, or when asked what runs in the vehicle, where it connects to, or whether its link to the cloud is up.
---

# Nexus connectivity: your vehicle and its cloud

**Draft for the workshop.** One of three building blocks, each usable on its own:

- **nexus-connectivity** (this one): what is in your vehicle, where the cloud is, how the
  two are connected.
- **nexus-aaos-sdk**: the demo service pairs between vehicle and cloud, and a service of
  your own.
- **nexus-telemetry**: a vehicle's signals on their way into the platform's storage.

It assumes a workstation prepared for the workshop: for the workshop we use two SDV Core
VMs of a Cuttlefish vehicle; the Nexus Bridge and all examples needed are installed; the
vehicle is provisioned under the participant's VIN (how to find yours: [Session
values](#session-values)); and a Nexus platform runs in the workshop's GCP project.

**Not part of the workshop**, for whoever wants more: the vehicle's third VM, the head unit
(IVI), is installed but not needed; on it you can try the
[Nexus VHAL example](../../../../../aaos/nexus-vhal-example/README.md), an app that sends the
head unit's vehicle properties to Nexus. To install a Nexus platform of your own, use the
skill `nexus-install`; to check a platform's health or explore examples on an installed
Nexus instance, `nexus-operate`.

## Contents

- [First: who runs the commands?](#first-who-runs-the-commands)
- [Session values](#session-values)
- [1. Your vehicle: two SDV Core VMs](#1-your-vehicle-two-sdv-core-vms)
- [2. What is installed](#2-what-is-installed)
- [3. What runs](#3-what-runs)
- [4. Does the vehicle reach the internet?](#4-does-the-vehicle-reach-the-internet)
- [5. Where is the cloud?](#5-where-is-the-cloud)
- [6. How the vehicle is configured to reach it](#6-how-the-vehicle-is-configured-to-reach-it)
- [7. Is the link up?](#7-is-the-link-up)
- [8. Your vehicle in FleetView](#8-your-vehicle-in-fleetview)
- [When something is not as expected](#when-something-is-not-as-expected)
  - [No VIN](#no-vin)

## First: who runs the commands?

Ask the participant once, before anything else, and keep to the answer:

1. **I run them myself.** Hand over one step at a time: what it shows, the command block,
   the line to look for. Wait for the pasted output, then say in two or three sentences
   what it means and whether it is as expected.
2. **You run them for me.** Run each step's commands in the workstation's terminal, show
   the command and the lines that matter, and explain them the same way. Stop and say so
   when a result is not as expected; do not repair anything unasked.

Either way: one step at a time, the result first (as expected / not as expected), then the
explanation. Never print a token, key or password — the commands below mask them.

## Session values

**First, your VIN.** The workstation has set it for you:

```bash
echo "$MY_VIN"
```

Expected: your VIN, e.g. `STUDENT07`. If the line is empty, go to
[No VIN](#no-vin) under "When something is not as expected" first.

**Your VIN** is your workshop account's name, in capitals and without dashes, at most 17
characters (`student-07@…` → `STUDENT07`). A vehicle identification number is the one key
the cloud knows your vehicle by: every message carries it, every subject names it
(`pubsub.<VIN>.<topic>`, `telemetry.<VIN>`), and FleetView lists it. It stays with you for
the whole workshop.

Then the rest, once per shell; every step uses them.

```bash
A=/opt/cvd-host-sdv/bin/adb
CORE="$A -s 0.0.0.0:6521"; CORE3="$A -s 0.0.0.0:6522"
# The workshop's Nexus platform
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)   # set by the workstation: qwiklabs-asl-04-585aa17d04cc
REGION=europe-west4; CLUSTER=nxs-ws-01-gke
DNS_ZONE=nexus-automobility-cloud; BASE_DOMAIN=nexus.automobility.cloud
CTX=gke_${PROJECT_ID}_${REGION}_${CLUSTER}     # the kubectl context, once step 5 has fetched it
echo "project $PROJECT_ID"
```

`PROJECT_ID` comes from the workstation's `gcloud` configuration, where the workshop has
set it. If the line above shows an empty project, set it once:
`gcloud config set project qwiklabs-asl-04-585aa17d04cc`, then the session values again.

## 1. Your vehicle: two SDV Core VMs

| VM | adb | Role |
|---|---|---|
| Core | `$CORE` | the sample service bundles (`PressureAdvisor`, `DoorController`, Google's `Manager` and `Monitor`) |
| Core3 | `$CORE3` | connectivity: the Nexus-Bridge APEX and Google's Telemetry Service |

The head unit (IVI, `0.0.0.0:6520`) is installed as well; the workshop does not need it. If
you like, try the [Nexus VHAL example](../../../../../aaos/nexus-vhal-example/README.md) on it.

## 2. What is installed

```bash
$CORE3 root >/dev/null; $CORE root >/dev/null
P='nexus|sdv.sample.quickstart$|google.sdv.telemetry$|update_manager.client$'
$CORE3 shell "ls /apex | grep -v @ | grep -E '$P'"
$CORE  shell "ls /apex | grep -v @ | grep -E '$P'"
$CORE3 shell 'ls /vendor/bin/telemetry_sample_publisher'
```

Expected, on both VMs Google's three and on each its Nexus one:

| APEX or program | From | Contents | Used in |
|---|---|---|---|
| `com.android.nexus.aaos_nexus_sdv_tcu` (Core3) | Nexus | the Nexus-Bridge APEX: Nexus Bridge, `nexus-connectivity-agent`, `nats-server` (the leaf), `nexus-telemetry-client` | everywhere |
| `com.nexussdv.sample` (Core) | Nexus | the Nexus example APEX: `PressureAdvisor`, `DoorController` | `nexus-aaos-sdk` |
| `com.android.sdv.sample.quickstart` | Google | the quickstart sample: `Manager` publishes the tyre pressure, `Monitor` reads it | `nexus-aaos-sdk` |
| `com.google.sdv.telemetry` | Google | the Telemetry Service | `nexus-telemetry` |
| `/vendor/bin/telemetry_sample_publisher` | Google | the telemetry sample publisher, a source of signals | `nexus-telemetry` |
| `com.android.sdv.sample.update_manager.client` | Google | the update manager's client: how the Nexus APEXes were installed | here |

Google's samples are used exactly as the platform ships them: Nexus connects them to the
cloud without changing them. The image carries some forty more of Google's samples
(`ls /apex | grep sample`).

An APEX is an Android package that can be installed and updated without a new system image.

## 3. What runs

```bash
$CORE3 shell 'ps -AZ | grep -E "nexus|nats-server|NexusBridge"'
$CORE  shell 'ps -A | grep ":instance"'
```

On Core3, expected:

| Process | Domain | Does |
|---|---|---|
| `nexus-connectivity-agent` | `nexus_connectivity_agent` | the vehicle's identity and its link to the cloud |
| `nats-server` | `nexus_nats_server` | the leaf: the vehicle's own NATS server, linked to the cloud's hub |
| `nexus-telemetry-client` | `nexus_telemetry_client` | sends the Telemetry Service's reports to Nexus |
| `NexusBridge:instance` | `untrusted_service_bundle` | connects the vehicle's SDV services with the cloud |

The domain is the SELinux sandbox a process runs in; the Bridge, a service bundle, runs in
the platform's sandbox for bundles. On Core, service bundles show as `<Bundle>:instance`:
`Manager`, `Monitor`, `PressureAdvisor`, `DoorController`, beside Google's own samples
(`Diagnostics…`, `ApexDiscoveryHelloWorld`).

Right after a boot, `Manager`, `Monitor`, `PressureAdvisor` and `DoorController` are not
running yet: that is how the workshop finds them, and starting them is part of
`nexus-aaos-sdk`.

## 4. Does the vehicle reach the internet?

```bash
$CORE3 shell 'ping -c 3 8.8.8.8'
$CORE3 shell 'ip route | grep default'
```

Expected: three replies, and `default via 192.168.98.1 dev eth1`. Core3 reaches the internet
through the workstation. Core has no route out; only Core3 talks to the cloud.

The vehicle reaches the cloud by address: the cloud's names were resolved once, on the
workstation, when the vehicle was provisioned, and written into its configuration (step 6).

## 5. Where is the cloud?

The cloud is already installed, and the connection from this workstation is established.
From here we go through the main pillars of that connection, one by one — from the outside
in.

**The endpoints.** The platform publishes its services under its own domain,
`nexus.automobility.cloud`, and writes the DNS records itself:

```bash
gcloud dns record-sets list --zone="$DNS_ZONE" --project="$PROJECT_ID" --filter="type=A" \
  --format="table[box] (name.sub('\.$',''):label='DNS NAME',rrdatas.list():label='EXTERNAL IP')"
```

The result, with the platform's own addresses:

```
┌─────────────────────────────────────────┬────────────────┐
│                DNS NAME                 │  EXTERNAL IP   │
├─────────────────────────────────────────┼────────────────┤
│ factory.nexus.automobility.cloud        │ …              │
│ fleetview.nexus.automobility.cloud      │ …              │
│ keycloak.nexus.automobility.cloud       │ …              │
│ keycloak-ui.nexus.automobility.cloud    │ …              │
│ nats.nexus.automobility.cloud           │ …              │
│ registration.nexus.automobility.cloud   │ …              │
└─────────────────────────────────────────┴────────────────┘
```

| Name | Who reaches it | For |
|---|---|---|
| `factory.` | the factory, at production | the vehicle's first identity (factory-helper) |
| `registration.` | the vehicle, once | exchanges the factory identity for its operational certificate |
| `keycloak.` | the vehicle, regularly | the token its leaf presents to the hub |
| `nats.` | the vehicle's leaf, always | the hub: every message between vehicle and cloud |
| `fleetview.`, `keycloak-ui.` | a person, in the browser | the fleet view and its login |

**Inside: GKE in `europe-west4`, on ARM.** Behind the endpoints runs a GKE cluster. Fetch
its credentials once; the command answers `kubeconfig entry generated for nxs-ws-01-gke`,
and from then on the kubectl context `$CTX` (`gke_qwiklabs-asl-04-585aa17d04cc_europe-west4_nxs-ws-01-gke`)
reaches it:

```bash
gcloud container clusters get-credentials "$CLUSTER" --region "$REGION" --project "$PROJECT_ID" --dns-endpoint
kubectl --context "$CTX" get nodes -L kubernetes.io/arch,topology.kubernetes.io/zone
kubectl --context "$CTX" -n base-services get pods -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName
```

Expected: nodes with `ARCH` `arm64` and zones `europe-west4-a/b/c`; the Nexus services in
`base-services` — `nats-0` (the hub), `nats-auth-callout`, `keycloak`, `registration-server`,
`nexus-registry`, `vin-registry`, `data-api`, `nats-bigtable-connector`, `nats-box` — all on
the `arm64` node. Nexus runs on ARM. GKE Autopilot also keeps `amd64` nodes for its own
system pods.

Say this to the participant as well: these commands also prove early that this
workstation can reach the cluster — the later parts of the workshop need exactly this
access. If `get-credentials` or `kubectl` fails here, tell the workshop leaders now.

**Outside and inside agree.** The hub's service has the address DNS gives for `nats.`:

```bash
kubectl --context "$CTX" -n base-services get svc nats -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}'
```

## 6. How the vehicle is configured to reach it

Two files on Core3 hold it.

**The vehicle's configuration**, `/data/misc/nexus/nexus.env`. In a real car these values
are set in the factory, when the car is built; this workstation plays that part for a
small, virtual prototype of a car:

```bash
$CORE3 shell 'cat /data/misc/nexus/nexus.env'
```

| Line | Means |
|---|---|
| `NEXUS_VIN` | the vehicle's VIN — must be yours, `$MY_VIN` |
| `NEXUS_NATS_URL`, `NEXUS_CLOUD_NATS_NAME` | the hub, by name |
| `NEXUS_CLOUD_NATS_HOST` | the hub's address, resolved on the workstation |
| `NEXUS_REGISTRATION_URL`, `NEXUS_KEYCLOAK_URL` and their `_IP` | registration and token |
| `NEXUS_LEAF_TLS` | the leaf link is TLS with the vehicle's certificate |

**The leaf's configuration**, `/data/misc/nexus/leaf.conf`. It is the result of the
vehicle's connectivity bootstrapping — the step in which the vehicle gets its own identity
and its access to the cloud, in a real car typically done for the first time in the factory
as well. Inside the Nexus Bridge APEX, the process that does it is the
`nexus-connectivity-agent`. The file's URLs carry the vehicle's token, so show it masked:

```bash
$CORE3 shell 'cat /data/misc/nexus/leaf.conf' | sed -E 's#//[^@/]+@#//<token>@#g'
```

What to point out: `port: 4222` (where the vehicle's own services and the head-unit app
reach the leaf), and under `leafnodes` the hub twice — `tls://<token>@nats.nexus.automobility.cloud:7422`
and the same at its address, which is how the vehicle uses it — with the vehicle's
operational certificate (`cert_file`).

**The vehicle's certificates and token**, `/data/misc/nexus/certificates/`.

Ask the participant first: go through the certificates in detail — all of them, or the ones
of particular interest — or skip this part and move on? Skipping is fine: the vehicle is
already connected to the cloud and everything works without looking inside.

```bash
$CORE3 shell 'ls -l /data/misc/nexus/certificates'
```

| File | What | From | Valid |
|---|---|---|---|
| `KEYCLOAK_TLS_CRT.pem`, `REGISTRATION_SERVER_TLS_CERT.pem` | the server certificates of `keycloak.` and `registration.` themselves: the vehicle trusts exactly these | the platform's public bucket, fresh at every provisioning | 30 days |
| `NATS_LEAF_TLS_CA.pem` | the root that signed the hub's certificate: how the vehicle recognises the real hub | the platform's public bucket | ten years |
| `vehicle-<VIN>-factory-gcp-chain.pem`, `…-key.pem` | the factory identity: "this VIN was built by the factory" | `factory.`, at provisioning | two years |
| `operational-cert.pem`, `operational-key.pem` | the operational identity, the vehicle's passport for everyday use | `registration.`, in exchange for the factory identity | three months |
| `oidc-access-token` | the token the leaf presents to the hub | `keycloak.`, with the operational identity | as the platform sets it; the agent renews it at 80 % of its remaining life, at least once a day |

The `-key.pem` files and the token are readable by the `nexus-connectivity-agent` only
(`-rw-------`) and are never shown. The certificates are public; their content is worth a
look:

```bash
for f in vehicle-${MY_VIN}-factory-gcp-chain.pem operational-cert.pem NATS_LEAF_TLS_CA.pem; do
  echo "== $f"
  $CORE3 shell "cat /data/misc/nexus/certificates/$f" | openssl x509 -noout -subject -issuer -enddate
done
```

Expected, for `PKG16MESH02` (with `-enddate`, each one's expiry):

```
== vehicle-PKG16MESH02-factory-gcp-chain.pem
subject=O = Nexus SDV, CN = VIN:PKG16MESH02 DEVICE:PKG16MESH02
issuer=O = Nexus Factory, CN = Nexus Factory Root CA
== operational-cert.pem
subject=CN = VIN:PKG16MESH02 DEVICE:PKG16MESH02
issuer=… OU = Registration, CN = Registration CA
== NATS_LEAF_TLS_CA.pem
subject=O = Nexus SDV, CN = Nexus Server Root CA
```

Both identities carry the VIN in their name; the hub reads it from the operational
certificate on the leaf link, which is how the cloud knows which vehicle is talking — not
from anything the vehicle claims about itself.

**Is it the right hub?** The address in `NEXUS_CLOUD_NATS_HOST` must be the `nats.` address
from step 5.

**Where the two files come from.** The vehicle was provisioned before the workshop with one
command on the workstation, from `aaos/aaos-nexus-sdv-tcu/`, after entering the operator
secret ([INSTALL.md](../../../../../aaos/INSTALL.md), part 3):

```bash
PKI_BUCKET_PROJECT=$PROJECT_ID ./provision-and-run.sh $MY_VIN $BASE_DOMAIN 0.0.0.0:6522
```

It fetched the vehicle's identity from `factory.`, resolved the cloud's names on the
workstation and wrote `nexus.env`; the `nexus-connectivity-agent` then wrote `leaf.conf`.
Running the script again renews the vehicle's operational certificate and its token, and
`leaf.conf` with them.

## 7. Is the link up?

```bash
$CORE3 shell 'grep "leaf status" /data/misc/nexus/agent.log | tail -n 1'
```

Expected: `leaf status: link=up links=1 grant=pub:<n> sub:<m>`. The
`nexus-connectivity-agent` asks the leaf once a minute. `link=up` means the leaf is connected
to the hub; the grant is what the cloud currently lets this vehicle send and receive.

**The full check**, from `aaos/aaos-nexus-sdv-tcu/` of the Nexus checkout:

```bash
ADB="$CORE3" ./check-leaf-connection.sh
```

It watches the vehicle for a little over a minute: the leaf must report its link to the hub
within 60 seconds, the `nexus-connectivity-agent`'s log must be free of fatal errors, the
link must not drop while it watches, and the leaf's log must show no authorization
violation. It ends with `✓ PASS — nexus-connectivity-agent running without fatal errors,
leaf node link up and stable for 70 s, zero authorization violations`.

That line means: the connection between AAOS and Nexus stands. The Nexus Bridge — the APEX
and everything in it — has done its first job: the vehicle has its identity, its leaf is
linked to the hub, and the cloud accepts it.

**Optional: what the cloud knows about your vehicle.** Skipping this loses nothing — offer
it, and move on if the participant would rather keep pace; `nexus-aaos-sdk` comes back to
it in its deep dive (step 3.2). The vehicle tells the Cloud Service Registry
which channels it can carry (its offers); the registry answers with the channels a cloud
service is currently registered for (the grant). The vehicle's side:

```bash
$CORE3 shell 'grep -E "announced|grant received" /data/misc/nexus/agent.log | tail -n 2'
```

The registry's side, read from its store in the cloud (JetStream key-value buckets):

```bash
nats_registry() {
  gcloud secrets versions access latest --secret=NATS_REGISTRY_PASSWORD --project "$PROJECT_ID" \
  | kubectl --context "$CTX" -n base-services exec -i deploy/nats-box -- \
      sh -c "IFS= read -r NATS_PASSWORD; export NATS_PASSWORD NATS_USER=nexus-registry; nats $*"
}
nats_registry kv get nexus-registry-offers "$MY_VIN" --raw; echo
nats_registry kv get nexus-registry-grants "$MY_VIN" --raw; echo
nats_registry kv ls nexus-registry-services
```

Expected (measured on a test platform):

```
[{"topic":"pressure","direction":"vehicle-to-cloud",…},{"topic":"uplink",…},{"topic":"pressure-limit",…},{"topic":"door-command",…},{"topic":"command",…}]
{"pub":["pubsub.<VIN>.pressure"],"sub":["pubsub.<VIN>.door-command","pubsub.<VIN>.pressure-limit"]}
pressure-monitor-limit
pressure-monitor
door-control
```

Five offers, three granted: `uplink` and `command` stay closed until a cloud service registers
for them — the subject of `nexus-aaos-sdk`.

## 8. Your vehicle in FleetView

Open `https://fleetview.nexus.automobility.cloud` and log in with the workshop user you were
given.

- **The list of vehicles** shows every vehicle the platform knows; yours is there under
  `$MY_VIN` since its provisioning.
- **Your vehicle's provisioning log** shows how it got its identity: factory identity,
  registration, its first connection.
- **Your vehicle's telemetry** stays empty for now: it fills once the telemetry source runs,
  in `nexus-telemetry`.

The VIN on the vehicle (`NEXUS_VIN`, step 6), the VIN in FleetView and `$MY_VIN` must be the
same. If they are not, see [No VIN](#no-vin).

## When something is not as expected

| Seen | Likely cause |
|---|---|
| `echo "$MY_VIN"` prints nothing | the workstation did not set your VIN: [No VIN](#no-vin) |
| no project in the session values, or `kubectl` cannot find the context | `gcloud config set project qwiklabs-asl-04-585aa17d04cc`, then the session values again |
| `ping` fails, no `default` route on Core3 | Core3 lost its route at a reboot: `$CORE3 shell 'ip route replace default via 192.168.98.1 dev eth1'` |
| no `nats-server` on Core3, or `link=unknown` | the leaf is not up yet after a boot (the agent first fetches its credentials); wait a minute and look again |
| `link=down` | the hub is not reachable: compare the `nats.` address of step 5 with `NEXUS_CLOUD_NATS_HOST` of step 6 |
| `NEXUS_VIN` differs from `$MY_VIN` | the vehicle was provisioned under another VIN: provision it under yours, [No VIN](#no-vin) |

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
