#!/usr/bin/env bash
# Launches the APEX-installed Nexus TCU stack (nexus-connectivity-agent +
# nats-server, both from /apex/com.android.nexus.aaos_nexus_sdv_tcu/bin/) on an
# AAOS-SDV guest — sourcing the vehicle identity SELF-SERVICE from factory-helper
# and the trust certs from the public PKI bucket. No gcloud, no Secret Manager.
#
# Runs on the machine that has adb access to the guest. Requires: curl, jq, adb.
# The nexus-connectivity-agent obtains the vehicle's operational certificate and
# its access token itself; nothing else has to sit next to this script but
# check-leaf-connection.sh.
#
# Works on both a standard single Cuttlefish instance (adb serial 0.0.0.0:6520)
# and a custom mesh (e.g. Core3 at 0.0.0.0:6522): the serial is auto-detected
# if there's exactly one device, else pass it as the 3rd argument. The adb
# binary is found on PATH, or via ADB_BIN, or a couple of well-known locations.
#
# Usage:
#   FACTORY_OPERATOR_CLIENT_SECRET=<secret> ./provision-and-run.sh <VIN> <base-domain> [adb-serial]
#   (FACTORY_CLIENT_ID=<your client id> — set this; the shared default won't match your secret)
#   (OBSERVE_SECONDS=<n> — how long the cloud link must stay up in the final check; default 30)
#   PKI_BUCKET_PROJECT=<project> — the GCP project of the Nexus instance; its public bucket
#     holds the trust anchors. Required.
#   (NEXUS_TELEMETRY_CLIENT=off|on — switches the nexus-telemetry-client off, for a VM without
#     a Telemetry Service, or on again; left as it is when not given)
# Example:
#   FACTORY_OPERATOR_CLIENT_SECRET=… FACTORY_CLIENT_ID=factory-operator-you \
#     PKI_BUCKET_PROJECT=my-nexus-project ./provision-and-run.sh MYVIN01 nexus.example.org
set -euo pipefail
VIN="${1:?usage: provision-and-run.sh <VIN> <base-domain> [adb-serial]}"
BASE_DOMAIN="${2:?usage: provision-and-run.sh <VIN> <base-domain> [adb-serial]}"
SERIAL_ARG="${3:-}"
FACTORY_HOSTNAME="${FACTORY_HOSTNAME:-factory}"
FACTORY_CLIENT_ID="${FACTORY_CLIENT_ID:-factory-operator}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APEX_BIN_DIR="/apex/com.android.nexus.aaos_nexus_sdv_tcu/bin"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
[ -n "${FACTORY_OPERATOR_CLIENT_SECRET:-}" ] || { echo "set FACTORY_OPERATOR_CLIENT_SECRET" >&2; exit 1; }
case "${NEXUS_TELEMETRY_CLIENT:-}" in
    ""|on|off) ;;
    *) echo "NEXUS_TELEMETRY_CLIENT must be on or off, not '${NEXUS_TELEMETRY_CLIENT}'" >&2; exit 2 ;;
esac
[ -x "${SCRIPT_DIR}/check-leaf-connection.sh" ] || { echo "missing ${SCRIPT_DIR}/check-leaf-connection.sh (ship it next to this script)" >&2; exit 1; }

# --- Locate adb ---
ADB_BIN_PATH="${ADB_BIN:-}"
if [ -z "$ADB_BIN_PATH" ]; then
    if command -v adb >/dev/null; then ADB_BIN_PATH="$(command -v adb)";
    elif [ -x /opt/cvd-host-sdv/bin/adb ]; then ADB_BIN_PATH=/opt/cvd-host-sdv/bin/adb;
    elif [ -x /opt/cvd-host/bin/adb ]; then ADB_BIN_PATH=/opt/cvd-host/bin/adb;
    else echo "adb not found — set ADB_BIN" >&2; exit 1; fi
fi

# --- Resolve adb serial ---
if [ -n "$SERIAL_ARG" ]; then
    SERIAL="$SERIAL_ARG"
else
    mapfile -t DEVS < <("$ADB_BIN_PATH" devices | awk 'NR>1 && $2=="device"{print $1}')
    if [ "${#DEVS[@]}" -eq 1 ]; then SERIAL="${DEVS[0]}";
    elif [ "${#DEVS[@]}" -eq 0 ]; then echo "no adb device found (is the guest up?)" >&2; exit 1;
    else echo "multiple adb devices — pass one as the 3rd arg: ${DEVS[*]}" >&2; exit 1; fi
fi
ADB="$ADB_BIN_PATH -s $SERIAL"
echo "Using adb: ${ADB_BIN_PATH}  serial: ${SERIAL}"
# Root adbd so we can stop a previous (root-owned) run and start cleanly.
# Harmless if already root; userdebug images allow it.
${ADB} root >/dev/null 2>&1 || true
${ADB} wait-for-device 2>/dev/null || true

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "=== Trust certs from the public PKI bucket (always fresh) ==="
# The trust anchors come from the public bucket of the GCP project the Nexus instance runs
# in. There is no default: a silent one pointed every other instance at the wrong cloud's
# certificates (seen 2026-10-10).
if [ -z "${PKI_BUCKET_PROJECT:-}" ]; then
    echo "set PKI_BUCKET_PROJECT=<GCP project of the Nexus instance at $BASE_DOMAIN> — its public bucket holds the trust anchors" >&2
    exit 2
fi
BUCKET="https://storage.googleapis.com/${PKI_BUCKET_PROJECT}-nexus-sdv-public/pki"
curl -sf --max-time 30 "${BUCKET}/KEYCLOAK_TLS_CRT.pem" -o "$WORK/KEYCLOAK_TLS_CRT.pem"
curl -sf --max-time 30 "${BUCKET}/REGISTRATION_SERVER_TLS_CERT.pem" -o "$WORK/REGISTRATION_SERVER_TLS_CERT.pem"
# The hub's leaf port speaks TLS since Increment 2.2 and verifies the vehicle's operational
# certificate; the vehicle verifies the hub against this CA. A hub that publishes no anchor
# has no TLS on that port yet: connect without it, and say so.
if curl -sf --max-time 30 "${BUCKET}/NATS_LEAF_TLS_CA.pem" -o "$WORK/NATS_LEAF_TLS_CA.pem"; then
    LEAF_TLS="${NEXUS_LEAF_TLS:-on}"
else
    echo "note: the hub publishes no NATS_LEAF_TLS_CA.pem — connecting the leaf without TLS"
    LEAF_TLS="off"
fi

echo "=== Vehicle identity from factory-helper (mode 2) ==="
# Say what actually failed: an unverifiable certificate (curl exit 60: expired, or the public
# anchor does not match), no answer, or a login Keycloak rejected. With -f and a pipe all
# three looked the same and sent the tester after the credentials.
CURL_RC=0
RESP=$(curl -s --max-time 30 --cacert "$WORK/KEYCLOAK_TLS_CRT.pem" -X POST \
  "https://keycloak.${BASE_DOMAIN}:8443/realms/sdv-telemetry/protocol/openid-connect/token" \
  -d grant_type=client_credentials -d "client_id=${FACTORY_CLIENT_ID}" \
  --data-urlencode "client_secret=${FACTORY_OPERATOR_CLIENT_SECRET}") || CURL_RC=$?
[ "$CURL_RC" -ne 60 ] || { echo "cannot verify Keycloak's TLS certificate: expired, or the public anchor does not match it. Renew it: iac/operating/nexus-cert-status.sh --renew KEYCLOAK_TLS_CRT" >&2; exit 1; }
[ "$CURL_RC" -eq 0 ] || { echo "no answer from keycloak.${BASE_DOMAIN} (curl exit ${CURL_RC})" >&2; exit 1; }
TOKEN=$(jq -r '.access_token // empty' <<<"$RESP")
[ -n "$TOKEN" ] || { echo "operator login rejected by Keycloak (client id/secret?): $(jq -r '.error_description // .error // "no detail"' <<<"$RESP" 2>/dev/null)" >&2; exit 1; }
unset RESP
CURL_RC=0
RESPONSE=$(curl -s --max-time 60 --cacert "$WORK/KEYCLOAK_TLS_CRT.pem" -X POST \
  "https://${FACTORY_HOSTNAME}.${BASE_DOMAIN}:8443/v1/factory-certificates" \
  -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  -d "{\"vin\": \"${VIN}\"}") || CURL_RC=$?
[ "$CURL_RC" -ne 60 ] || { echo "cannot verify factory-helper's TLS certificate: expired, or not signed by the CA in the Keycloak anchor. Renew it: iac/operating/nexus-cert-status.sh --renew FACTORY_HELPER_TLS_CERT" >&2; exit 1; }
[ "$CURL_RC" -eq 0 ] || { echo "no answer from ${FACTORY_HOSTNAME}.${BASE_DOMAIN} (curl exit ${CURL_RC})" >&2; exit 1; }
[ -n "$(jq -r '.certificate // empty' <<<"$RESPONSE" 2>/dev/null)" ] || { echo "factory-helper issued no certificate: $(jq -r '.error // .message // empty' <<<"$RESPONSE" 2>/dev/null | head -c 200)" >&2; exit 1; }
{ jq -r .certificate <<<"$RESPONSE"; jq -r .ca_certificate_chain <<<"$RESPONSE"; } > "$WORK/vehicle-${VIN}-factory-gcp-chain.pem"
jq -r .private_key <<<"$RESPONSE" > "$WORK/vehicle-${VIN}-factory-gcp-key.pem"
chmod 600 "$WORK/vehicle-${VIN}-factory-gcp-key.pem"
unset RESPONSE
echo "✓ identity issued for ${VIN}"

echo "=== Resolving hostnames on this host (guests have no DNS resolver) ==="
resolve() { getent hosts "$1" | awk '{print $1; exit}'; }
CLOUD_NATS_IP="$(resolve "nats.${BASE_DOMAIN}")"
REGISTRATION_IP="$(resolve "registration.${BASE_DOMAIN}")"
KEYCLOAK_IP="$(resolve "keycloak.${BASE_DOMAIN}")"
[ -n "$CLOUD_NATS_IP" ] && [ -n "$REGISTRATION_IP" ] && [ -n "$KEYCLOAK_IP" ] || { echo "hostname resolution failed" >&2; exit 1; }
echo "    nats=${CLOUD_NATS_IP} registration=${REGISTRATION_IP} keycloak=${KEYCLOAK_IP}"

echo "=== Verifying the APEX is installed ==="
${ADB} shell "[ -x ${APEX_BIN_DIR}/nexus-connectivity-agent ] && [ -x ${APEX_BIN_DIR}/nats-server ]" \
  || { echo "APEX not installed at ${APEX_BIN_DIR} — install it first (see TESTING.md step 1)" >&2; exit 1; }

# Leaf host = the guest's own eth1 address (only matters if OTHER guests connect
# to this leaf; on a single instance it's cosmetic). Android's shell has no awk,
# so parse `ip` output with sed; fall back to env, then to localhost.
if [ -n "${CORE3_LEAF_HOST:-}" ]; then
    LEAF_HOST="$CORE3_LEAF_HOST"
else
    LEAF_HOST="$(${ADB} shell "ip -o -4 addr show eth1 2>/dev/null" | sed -n 's#.*inet \([0-9.]*\)/.*#\1#p' | head -1 | tr -d '\r')"
fi
[ -n "$LEAF_HOST" ] || LEAF_HOST="127.0.0.1"
echo "    leaf host (guest eth1): ${LEAF_HOST}"

# The run directory of the init service (nexus_connectivity_agent.rc), created here and labelled
# nexus_data_file by the image's policy (aaos/aaos-nexus-sdv-tcu-sepolicy/).
REMOTE_DIR="/data/misc/nexus"
echo "=== Staging runtime deps to the guest (serial ${SERIAL}) ==="
${ADB} shell "mkdir -p ${REMOTE_DIR}/certificates"
${ADB} push "$WORK/KEYCLOAK_TLS_CRT.pem" "${REMOTE_DIR}/certificates/" >/dev/null
${ADB} push "$WORK/REGISTRATION_SERVER_TLS_CERT.pem" "${REMOTE_DIR}/certificates/" >/dev/null
[ -s "$WORK/NATS_LEAF_TLS_CA.pem" ] && ${ADB} push "$WORK/NATS_LEAF_TLS_CA.pem" "${REMOTE_DIR}/certificates/" >/dev/null
${ADB} push "$WORK/vehicle-${VIN}-factory-gcp-chain.pem" "${REMOTE_DIR}/certificates/" >/dev/null
${ADB} push "$WORK/vehicle-${VIN}-factory-gcp-key.pem" "${REMOTE_DIR}/certificates/" >/dev/null
# Lock the staged identity down (F28): adb push leaves every file readable and
# writable for everyone, and on guests where SELinux runs permissive nothing else
# protects them. The run directory belongs to the service's user alone.
${ADB} shell "chmod 700 ${REMOTE_DIR} && chmod 700 ${REMOTE_DIR}/certificates && chmod 644 ${REMOTE_DIR}/certificates/*.pem && chmod 600 ${REMOTE_DIR}/certificates/*-key.pem"

# The guest has no default route of its own — on a standard single instance as
# well — and loses it on every reboot, so add it on every run.
${ADB} shell "ip route | grep -q '^default' || ip route replace default via 192.168.98.1 dev eth1" 2>/dev/null || true

# The telemetry client's switch (persist.nexus.telemetry_client.enabled), only when asked.
if [ -n "${NEXUS_TELEMETRY_CLIENT:-}" ]; then
    [ "${NEXUS_TELEMETRY_CLIENT}" = off ] && TC_VALUE=false || TC_VALUE=true
    ${ADB} shell "setprop persist.nexus.telemetry_client.enabled ${TC_VALUE}; stop nexus_telemetry_client; start nexus_telemetry_client" </dev/null
    echo "nexus-telemetry-client switched ${NEXUS_TELEMETRY_CLIENT}"
fi

echo "=== Configuration file and service start ==="
# The nexus-connectivity-agent runs as an init service (nexus_connectivity_agent.rc). It
# has no command line of ours and no environment, so its configuration goes into a file in
# its run directory; the service waits for that file and is restarted here once it is
# written. One KEY=VALUE per line, no secrets (env_file.rs in the nexus-connectivity-agent).
ENV_PREFIX="NEXUS_VIN=${VIN} NEXUS_CLOUD_NATS_HOST=${CLOUD_NATS_IP} NEXUS_RUN_DIR=${REMOTE_DIR} NEXUS_NATS_SERVER_BIN=${APEX_BIN_DIR}/nats-server NEXUS_LEAF_HOST=${LEAF_HOST} NEXUS_REGISTRATION_URL=https://registration.${BASE_DOMAIN}:8443 NEXUS_KEYCLOAK_URL=https://keycloak.${BASE_DOMAIN}:8443 NEXUS_NATS_URL=nats://nats.${BASE_DOMAIN}:4222 NEXUS_REGISTRATION_IP=${REGISTRATION_IP} NEXUS_KEYCLOAK_IP=${KEYCLOAK_IP} NEXUS_LEAF_TLS=${LEAF_TLS} NEXUS_CLOUD_NATS_NAME=nats.${BASE_DOMAIN}${NEXUS_DISCOVERY_PORT:+ NEXUS_DISCOVERY_PORT=${NEXUS_DISCOVERY_PORT}}"
ENV_FILE="$WORK/nexus.env"
{
    echo "# Written by provision-and-run.sh on $(date -u +%FT%TZ). No secrets in here."
    # Values contain no spaces, so the word split gives one KEY=VALUE each.
    for kv in ${ENV_PREFIX}; do echo "$kv"; done
    echo "NEXUS_LOG_FILE=${REMOTE_DIR}/agent.log"
    echo "NEXUS_LEAF_CONF=${REMOTE_DIR}/leaf.conf"
    echo "NEXUS_LEAF_LOG=${REMOTE_DIR}/nats-leaf.log"
} > "$ENV_FILE"
${ADB} push "$ENV_FILE" "${REMOTE_DIR}/nexus.env" >/dev/null
# Stop the running service, clear a stale identity and logs, hand the directory to the
# service's user, give its files the policy's label, then start it again. leaf.conf holds the
# vehicle's NATS token and is rewritten at start, so it is removed first (F28).
${ADB} shell "stop nexus_connectivity_agent; cd ${REMOTE_DIR} && rm -f certificates/operational-* certificates/oidc-* nats-leaf.log leaf.conf agent.log; chmod 600 nexus.env && chown -R system:system ${REMOTE_DIR} && restorecon -R ${REMOTE_DIR} && start nexus_connectivity_agent && echo started"

echo "=== Acceptance check ==="
# check-leaf-connection.sh decides; its header explains what PASS means. It can
# also be re-run on its own at any time.
ADB="${ADB}" "${SCRIPT_DIR}/check-leaf-connection.sh" "${OBSERVE_SECONDS:-30}"
