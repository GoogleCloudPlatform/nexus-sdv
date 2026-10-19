# Acceptance tests for the Nexus-Bridge APEX (`com.android.nexus.aaos_nexus_sdv_tcu`)

For Nexus developers and administrators. Installation: [INSTALL.md](../INSTALL.md).

| Script | Answers | Needs |
|---|---|---|
| `check-nexus-cloud.sh` | is the Nexus cloud there? | `curl`, `openssl` |
| `provision-and-run.sh` + `check-leaf-connection.sh` | does the vehicle get its identity and a stable link? | `adb`, operator secret, Linux host (`getent`, bash 4) |
| `round-trip-test.sh` | does a message get out of and into the vehicle? | `adb` |
| `registry-test.sh` | does the cloud decide which channels a vehicle may use? | `adb`, cluster access |

Each ends with `✓ PASS` or `✗ FAIL` and the first cause. Their own tests, without a device: `tests/`.

## Before the vehicle: is the cloud there?

```bash
PKI_BUCKET_PROJECT=<GCP project> ./check-nexus-cloud.sh <base-domain> [--login] [--identity <VIN>]
```

| Station | Checked |
|---|---|
| public PKI bucket | the three trust anchors |
| Keycloak, factory-helper, registration server (port 8443) | certificate against its anchor, expiry (warning under 14 days) |
| hub, ports 4222 and 7422 | NATS version, TLS on the leaf port |
| `--login` | operator login |
| `--identity <VIN>` | issues a real factory identity for that VIN |

Ends with `Summary: <n> passed, <m> failed, <w> warning(s)`.

## 1. Install the APEX on the guest

On an image that pre-trusts the samples key (`/product/etc/brand_new_apex/sample.avbpubkey`):

```bash
ADB="adb -s <serial>"
$ADB root
$ADB shell mkdir -p /data/mydir
$ADB push com.android.nexus.aaos_nexus_sdv_tcu.apex /data/mydir/
$ADB shell /apex/com.android.sdv.sample.update_manager.client/bin/sdv_update_manager_client \
    prepare service-bundle --boot_attempts 2 \
    --apex_path /data/mydir/com.android.nexus.aaos_nexus_sdv_tcu.apex
$ADB shell /apex/com.android.sdv.sample.update_manager.client/bin/sdv_update_manager_client activate
$ADB reboot && $ADB wait-for-device
$ADB root
$ADB shell /apex/com.android.sdv.sample.update_manager.client/bin/sdv_update_manager_client commit
$ADB shell ls /apex | grep nexus
# com.android.nexus.aaos_nexus_sdv_tcu
# com.android.nexus.aaos_nexus_sdv_tcu@<version>
```

If `commit` fails right after the reboot, wait a few seconds and repeat it.

## 2. Provision the vehicle

Command: [INSTALL.md](../INSTALL.md), part 3.2. `NEXUS_DISCOVERY_PORT=<port>` moves the discovery endpoint off `18051`.

What lands in `/data/misc/nexus/certificates/` (list only, the keys and tokens are credentials):

| Files | What | From |
|---|---|---|
| `KEYCLOAK_TLS_CRT.pem`, `REGISTRATION_SERVER_TLS_CERT.pem`, `NATS_LEAF_TLS_CA.pem` | trust anchors | public PKI bucket, by the script |
| `vehicle-<VIN>-factory-gcp-chain.pem`, `…-key.pem` | factory identity | factory-helper, by the script |
| `operational-cert.pem`, `operational-key.pem` | operational identity | registration server, by the `nexus-connectivity-agent` |
| `oidc-access-token` | token for the leaf | Keycloak, by the `nexus-connectivity-agent` |

Factory files without `operational-*`: registration failed. `operational-*` without `oidc-*`: Keycloak refused.

## 3. Verify: `check-leaf-connection.sh`

Run by `provision-and-run.sh`; on its own:

```bash
ADB="$ADB" ./check-leaf-connection.sh [seconds, default 30]
```

Passes when the link came up within 60 s, `agent.log` has no fatal error, the link does not drop in the window, the agent reports `leaf status: link=up`, and the leaf log has no `Authorization Violation`.

## 4. Round trip: `round-trip-test.sh`

```bash
NEXUS_VIN=<VIN> TCU_ADB="adb -s <VM with the connectivity>" APP_ADB="adb -s <VM with the bundles>" ./round-trip-test.sh [seconds, default 120]
```

| Check |
|---|
| both guests booted, `sdv.authz.enable=true` |
| the forwarded counter grows in the window |
| a message published into the leaf reaches the Bridge |
| `PressureAdvisor` logs this run's marker (`NEXUS_RT_MARKER` to choose it) |
| no permissions or authorization violations |

A link drop is reported and does not fail the run.

## 5. The cloud decides: `registry-test.sh`

| Phase | Passes when |
|---|---|
| closed | with an empty grant, no `pressure` at the hub and no limit delivered |
| open | the grant opens, the `nexus-connectivity-agent` logs `grant changed`, a limit arrives |
| (c) | the hub now receives `pressure` |

Start from an empty grant. Run in bash:

```bash
PROJECT=…; CTX=…; VIN=…
nats_as() {   # nats_as <user> <secret> <nats arguments…>
  local user="$1" secret="$2"; shift 2
  gcloud secrets versions access latest --secret="$secret" --project "$PROJECT" \
  | kubectl --context "$CTX" -n base-services exec -i deploy/nats-box -- \
      sh -c "IFS= read -r NATS_PASSWORD; export NATS_PASSWORD NATS_USER=$user; nats $*"
}
grant_open() {
  local g="{\"pub\":[\"pubsub.$VIN.pressure\"],\"sub\":[\"pubsub.$VIN.pressure-limit\",\"pubsub.$VIN.door-command\"]}"
  nats_as nexus-registry NATS_REGISTRY_PASSWORD kv put nexus-registry-grants "$VIN" "'$g'"
  nats_as nexus-registry NATS_REGISTRY_PASSWORD pub "registry.$VIN.grant" "'$g'"
}
hub_pub() {   # hub_pub <payload as printf octal escapes>
  gcloud secrets versions access latest --secret=NATS_CONNECTOR_PASSWORD --project "$PROJECT" \
  | kubectl --context "$CTX" -n base-services exec -i deploy/nats-box -- \
      sh -c "IFS= read -r NATS_PASSWORD; export NATS_PASSWORD NATS_USER=connector; nats pub pubsub.$VIN.pressure-limit \"\$(printf '$1')\""
}
hub_count() {   # hub_count <seconds>
  gcloud secrets versions access latest --secret=NATS_CONNECTOR_PASSWORD --project "$PROJECT" \
  | kubectl --context "$CTX" -n base-services exec -i deploy/nats-box -- \
      sh -c "IFS= read -r NATS_PASSWORD; export NATS_PASSWORD NATS_USER=connector; timeout $1 nats sub pubsub.$VIN.pressure 2>/dev/null | grep -c 'Received on'"
}
export -f nats_as grant_open hub_pub hub_count; export PROJECT CTX VIN

TCU_ADB="adb -s <VM with the connectivity>" APP_ADB="adb -s <VM with the bundles>" \
NEXUS_RESTART_CMD="./provision-and-run.sh …" \
NEXUS_GRANT_CMD=grant_open NEXUS_HUB_PUB_CMD=hub_pub NEXUS_HUB_SUB_CMD=hub_count \
./registry-test.sh
```

Against a running registry, `NEXUS_GRANT_CMD` starts the cloud services; a stopped service keeps its channel until its lease runs out, 15 minutes after the last renewal.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `PKI_BUCKET_PROJECT is required`, exit 2 | the GCP project of the Nexus instance is not set |
| `operator login failed (client id/secret?)` | wrong client id or secret, or the client is revoked |
| `prepare` fails: "No preinstalled apex found for unverified package" | the image does not pre-trust the samples key |
| `network is unreachable`, `credential fetch failed: … cannot reach …` | guest route or host forwarding missing ([INSTALL.md](../INSTALL.md), part 2.2) |
| `TLS failed: …` about a server's certificate | an IP address in a URL; addresses go in `NEXUS_REGISTRATION_IP` / `NEXUS_KEYCLOAK_IP` |
| `agent.log reports: 'discovery server error'` | port 18051 is taken; set `NEXUS_DISCOVERY_PORT` |
| `the link dropped … during the … window` | the link to the hub is not stable |
| `nats-server did not answer its own status query`, `link=unknown` | the leaf is down, or port 18222 is taken (`NEXUS_LEAF_MONITOR_PORT`) |
| `the nexus-connectivity-agent exited before the link came up` | see `getprop init.svc.nexus_connectivity_agent` and `agent.log` |
| the vehicle forwards, the cloud service receives nothing | the service is not registered, or the callout lacks `grant reader set up for bucket nexus-registry-grants` |
| no telemetry rows | sample publisher not running, or the token lacks the role `telemetry-client` (`iac/operating/keycloak-apply-telemetry-role.sh`) |
| two telemetry rows a second | two metrics configurations with different UUIDs |
| app: `Leaf: not reachable (no leaf configured …)` | the head unit lacks `androidboot.nexus.leaf` |
| a value set with `inject-vhal-event` does not arrive | set it in the VHAL with `dumpsys …IVehicle/default --set <property> -f <value>` |

Logs: `/data/misc/nexus/agent.log`, `/data/misc/nexus/nats-leaf.log`.

## Reporting

Issues → the Nexus SDV repository, with image and build, failing step, the two logs and the VIN.
