---
name: nexus-telemetry
description: Walk a workshop participant along their vehicle's telemetry — from Google's Telemetry Service in the vehicle, through the nexus-telemetry-client and the hub, into the platform's BigTable and back out through the Data API — and show the metrics configuration that decides what is sent. Use in the Nexus workshop, or when asked how vehicle signals reach Nexus storage, why a vehicle shows no telemetry, or what a metrics configuration is.
---

# Nexus telemetry: your vehicle's signals into the cloud's storage

**Draft for the workshop.** One of three building blocks, each usable on its own:

- **nexus-connectivity**: what is in your vehicle, where the cloud is, how the two are
  connected.
- **nexus-aaos-sdk**: the demo service pairs between vehicle and cloud, and a service of
  your own.
- **nexus-telemetry** (this one): a vehicle's signals on their way into the platform's
  storage.

It assumes a workstation prepared for the workshop: for the workshop we use two SDV Core
VMs of a Cuttlefish vehicle; the Nexus Bridge and all examples needed are installed; the
vehicle is provisioned under the participant's VIN (how to find yours: [Session
values](#session-values)); and a Nexus platform runs in the workshop's GCP project.

## Contents

- [First: who runs the commands?](#first-who-runs-the-commands)
- [Session values](#session-values)
- [The way of one report](#the-way-of-one-report)
- [1. In the vehicle: the client and its switch](#1-in-the-vehicle-the-client-and-its-switch)
- [2. The source: Google's sample publisher](#2-the-source-googles-sample-publisher)
- [3. At the hub](#3-at-the-hub)
- [4. In storage: BigTable](#4-in-storage-bigtable)
- [5. Back out: the Data API](#5-back-out-the-data-api)
- [6. What decides what is sent: the metrics configuration](#6-what-decides-what-is-sent-the-metrics-configuration)
- [7. Switch it off and on](#7-switch-it-off-and-on)
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
CORE3="$A -s 0.0.0.0:6522"
# The workshop's Nexus platform
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)   # set by the workstation: qwiklabs-asl-04-585aa17d04cc
REGION=europe-west4; CLUSTER=nxs-ws-01-gke
DNS_ZONE=nexus-automobility-cloud; BASE_DOMAIN=nexus.automobility.cloud
CTX=gke_${PROJECT_ID}_${REGION}_${CLUSTER}     # the kubectl context
echo "project $PROJECT_ID"
```

`PROJECT_ID` comes from the workstation's `gcloud` configuration, where the workshop has
set it. If the line above shows an empty project, set it once:
`gcloud config set project qwiklabs-asl-04-585aa17d04cc`, then the session values again.

For the cloud steps, once if `nexus-connectivity` has not done it on this workstation:
`gcloud container clusters get-credentials "$CLUSTER" --region "$REGION" --project "$PROJECT_ID" --dns-endpoint`.

## The way of one report

| # | Where | Who | What happens |
|---|---|---|---|
| 1 | Core3 | Google's `telemetry_sample_publisher` | publishes a value — here a random speed |
| 2 | Core3 | Google's Telemetry Service | collects it as the metrics configuration says, builds a report |
| 3 | Core3 | `nexus-telemetry-client` | takes the report and publishes it unchanged on `telemetry-aaos-sdv.<VIN>`, through the leaf |
| 4 | cloud | the hub | receives it over the vehicle's leaf link |
| 5 | cloud | `nats-bigtable-connector` | decodes the report, writes one row per report |
| 6 | cloud | BigTable, table `telemetry` | row key `<VIN>#<time>`, one column per signal (`dynamic:VELOCITY`, …) |
| 7 | cloud | Data API | reads the rows back for any application |

The Telemetry Service and the publisher are Google's; Nexus adds steps 3 to 7. Nothing in
between decodes the report until step 5.

## 1. In the vehicle: the client and its switch

```bash
$CORE3 root >/dev/null
$CORE3 shell 'getprop init.svc.nexus_telemetry_client; getprop persist.nexus.telemetry_client.enabled'
$CORE3 shell 'logcat -d -s nexus-telemetry-client | grep -E "publishing|switched off" | tail -n 1'
```

Expected, line by line:

- `running`: init started the `nexus-telemetry-client`, and it runs.
- empty or `true`: its switch is on. Only `false` would keep it idle — for a VM without a
  Telemetry Service.
- the third command shows nothing yet, and that is expected: the client connects to the leaf
  with its first report, and reports only come once the publisher of step 2 runs. Step 2
  checks it.

## 2. The source: Google's sample publisher

After every boot of the vehicle, from `aaos/` of the Nexus checkout:

```bash
ADB="$CORE3" nexus-telemetry-client/start-sample-publisher.sh
$CORE3 shell 'logcat -d -s nexus-telemetry-client | grep "Report ready" | tail -n 2'
```

Expected: `✓ the sample publisher is running`; `Report ready` lines, one a second. Now the
client sends — the line step 1 could not show yet:

```bash
$CORE3 shell 'logcat -d -s nexus-telemetry-client | grep publishing | tail -n 1'
```

Expected: `connected to the leaf at 127.0.0.1:4222, publishing telemetry-aaos-sdv.<VIN>`.

Why a script for one program: Google's publisher aborts when a metrics configuration is
already active as it starts (`there is no reactor running …`), and Google's Telemetry Service
keeps the active configuration on disk across restarts. So the script stops the client and
the service, removes the stored configuration, starts the service and the publisher, and
starts the client last — which activates the configuration again, now with the publisher
running.

## 3. At the hub

The reports pass the hub on your vehicle's subject. Watch three of them arrive, as the
`connector` user that the storage side uses; the readable parts of each report are printed:

```bash
gcloud secrets versions access latest --secret=NATS_CONNECTOR_PASSWORD --project "$PROJECT_ID" \
| kubectl --context "$CTX" -n base-services exec -i deploy/nats-box -- \
    sh -c "IFS= read -r NATS_PASSWORD; export NATS_PASSWORD NATS_USER=connector; nats sub telemetry-aaos-sdv.$MY_VIN --count 3 --timestamp --translate 'strings -n 6'"
```

Expected, one a second (measured on a test platform on 2026-10-19):

```
[#1] @ Oct 19 15:28:16.819216 Received on "telemetry-aaos-sdv.PKG16MESH02"
"$778f6d44-0c8a-4240-9937-0b92f90b4b4a(
vehicle_telemetry_report:c
Btype.googleapis.com/com.android.sdv.telemetry.VehicleTelemetryData
R$6eec60d4-083c-455e-b67a-95e9ec24a72e

[#2] @ Oct 19 15:28:17.823354 Received on "telemetry-aaos-sdv.PKG16MESH02"
…
```

| Line | Is |
|---|---|
| `Received on "telemetry-aaos-sdv.<VIN>"`, with the time | one report, on your vehicle's subject |
| `778f6d44-…` | the metrics configuration that built it (step 6) |
| `vehicle_telemetry_report` | the report's name in that configuration |
| `…/com.android.sdv.telemetry.VehicleTelemetryData` | the report type: the signals inside |
| the last UUID | this report's own identity, new each time |

The report is protobuf; these are only its readable parts — the leading and trailing
characters are protobuf's field markers. Google's Telemetry Service built it, the
`nexus-telemetry-client` sent it unchanged, the hub received it. Nothing has decoded it yet;
that happens on the way into storage.

## 4. In storage: BigTable

One row per report. Any of the three ways:

**`cbt`** (`gcloud components install cbt`):

```bash
cbt -project "$PROJECT_ID" -instance bigtable-production-storage \
  read telemetry prefix="$MY_VIN#" columns='dynamic:VELOCITY' reversed=true count=3
```

**BigTable Studio**, in the console, instance `bigtable-production-storage`:

```sql
SELECT _key, dynamic['VELOCITY'] AS velocity
FROM telemetry
WHERE STARTS_WITH(_key, '<your VIN>#')
ORDER BY _key DESC
LIMIT 3
```

**Data API**: see 5.

Expected: one row a second, keys `<VIN>#<time>`, a speed from 0 to 255 that changes.

## 5. Back out: the Data API

Applications read through the Data API, not BigTable directly. In the cluster,
`data-api-sampler` offers it over HTTP; it needs a token of the platform's Keycloak. The
operator secret is in the workstation's home directory or given by the workshop leaders:

```bash
printf "Operator secret: "; read -rs SECRET; echo
```

```bash
curl -s "https://storage.googleapis.com/$PROJECT_ID-nexus-sdv-public/pki/KEYCLOAK_TLS_CRT.pem" -o keycloak-ca.pem
TOKEN=$(curl -s --cacert keycloak-ca.pem -X POST \
  "https://keycloak.$BASE_DOMAIN:8443/realms/sdv-telemetry/protocol/openid-connect/token" \
  -d grant_type=client_credentials -d client_id=factory-operator \
  --data-urlencode "client_secret=$SECRET" | jq -r .access_token); unset SECRET
kubectl --context "$CTX" -n sample-services port-forward svc/data-api-sampler 18090:8080 &
```

After `Forwarding from 127.0.0.1:18090`:

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "localhost:18090/data/$MY_VIN/datatypes/dynamic:VELOCITY?lookback=5s"
kill %1; unset TOKEN
```

Expected: `{"dynamic:VELOCITY":["38","4","187",…]}`, the last five seconds.

## 6. What decides what is sent: the metrics configuration

Google calls it a `MetricsConfig`: which sources the Telemetry Service listens to, when it
builds a report, and what goes into it. The client activates one at its start; it ships in
the Nexus-Bridge APEX. Its source:
[`vehicle_telemetry_config_live.textproto`](../../../../../aaos/nexus-telemetry-client/metrics/vehicle_telemetry_config_live.textproto).

| Part | In ours |
|---|---|
| `descriptor_protos` | the report type `com.android.sdv.telemetry.VehicleTelemetryData`: `VELOCITY`, `ENGINE_RPM`, `FUEL_LEVEL`, `GPS_LATITUDE`, `GPS_LONGITUDE`, `IGNITION_STATE`, `LOCKED` |
| `sources` | `SamplePub`: Google's sample publisher |
| `expression_nodes` | `VELOCITY` from the publisher's `sample_data`; every other field a constant (2500 rpm, 75.5 % fuel, Berlin) |
| `triggers` | a report whenever the publisher sends |
| `metrics_report_configs` | assigns the expressions to the report's fields |

So only the speed is live. A configuration that reads the speed from Google's driving
simulation is beside it (`vehicle_telemetry_config_drive.textproto`), not installed: the
platform's authorization refuses that source on our vehicle.

## 7. Switch it off and on

The second level: change something and watch the storage follow.

```bash
$CORE3 shell 'setprop persist.nexus.telemetry_client.enabled false; stop nexus_telemetry_client; start nexus_telemetry_client'
```

Run step 4 twice, half a minute apart: no new rows. Then on again:

```bash
$CORE3 shell 'setprop persist.nexus.telemetry_client.enabled true; stop nexus_telemetry_client; start nexus_telemetry_client'
```

Rows again within seconds. The switch survives a reboot. If the publisher stopped meanwhile,
step 2 again.

## When something is not as expected

| Seen | Likely cause |
|---|---|
| `echo "$MY_VIN"` prints nothing | the workstation did not set your VIN: [No VIN](#no-vin) |
| no project in the session values, or `kubectl` cannot find the context | `gcloud config set project qwiklabs-asl-04-585aa17d04cc`, then the session values again |
| no `Report ready` | the sample publisher is not running: step 2 |
| step 2 ends with `✗ … did not stay up` | Google's publisher still aborts at start; run step 2 again. If it keeps failing, the abort reason: `$CORE3 logcat -d \| grep 'Abort message' \| tail -n 1` |
| `switched off … idle` | the switch is `false`: step 7, on |
| reports in the vehicle, none at the hub | the leaf link is down: `nexus-connectivity`, step 7 |
| at the hub, no rows | ask the workshop leaders about `nats-bigtable-connector` |

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
