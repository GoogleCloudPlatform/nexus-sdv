#!/usr/bin/env bash
# Deploys the Nexus Connectivity Agent (Rust) to Core3 (the mesh's TCU domain), replacing
# the nats-leaf Task-5 cron with an expiry-aware, on-device credential-refresh loop.
#
# Core3 has no DNS resolver at all (not even Android's own netd/ndc — confirmed empirically,
# not assumed), and no curl/openssl either. This script resolves the hostnames the agent
# needs on the host (which has working DNS) and passes the IPs in; the
# nexus-connectivity-agent walks the provisioning chain itself, so there is no second
# binary to push and no curl/openssl dependency on the guest at all.
#
# Prereqs (built once, staged locally — this script only pushes + launches):
#   - aaos/nexus-connectivity-agent/target/x86_64-unknown-linux-musl/release/
#       nexus-connectivity-agent
#       (cargo build --release --target x86_64-unknown-linux-musl)
#   - ${VEHICLE_CLIENT_DIR}/certificates/ already contains a valid factory cert/key for
#       <VIN> and the two TLS trust certs (KEYCLOAK_TLS_CRT.pem,
#       REGISTRATION_SERVER_TLS_CERT.pem). This developer script still takes them from
#       that directory; the tester package fetches both self-service instead
#       (aaos/aaos-nexus-sdv-tcu/provision-and-run.sh). A real vehicle's factory identity
#       is injected at manufacture, not synthesized at boot — this mirrors that.
#
# Usage: ./deploy.sh <VIN> <cloud-nats-host> <base-domain> [adb-serial]
#   e.g. ./deploy.sh CLDLEAF01 nats.nexus.example.org nexus.example.org
set -euo pipefail
VIN="${1:?usage: deploy.sh <VIN> <cloud-nats-host> <base-domain> [adb-serial]}"
CLOUD_NATS_HOST="${2:?usage: deploy.sh <VIN> <cloud-nats-host> <base-domain> [adb-serial]}"
BASE_DOMAIN="${3:?usage: deploy.sh <VIN> <cloud-nats-host> <base-domain> [adb-serial]}"
CORE3_ADB="${4:-0.0.0.0:6522}"
CORE3_LEAF_HOST="${5:-192.168.98.5}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VEHICLE_CLIENT_DIR="$(cd "${SCRIPT_DIR}/../../sample-clients/vehicle-client" && pwd)"
ADB="/opt/cvd-host-sdv/bin/adb -s ${CORE3_ADB}"

resolve() {
    local ip
    ip="$(getent hosts "$1" | awk '{print $1}')"
    [ -n "${ip}" ] || { echo "failed to resolve $1 on the host" >&2; exit 1; }
    echo "${ip}"
}

CLOUD_NATS_IP="$(resolve "${CLOUD_NATS_HOST}")"
REGISTRATION_IP="$(resolve "registration.${BASE_DOMAIN}")"
KEYCLOAK_IP="$(resolve "keycloak.${BASE_DOMAIN}")"
echo "=== Resolved on host (Core3 has no resolver) ==="
echo "    ${CLOUD_NATS_HOST} -> ${CLOUD_NATS_IP}"
echo "    registration.${BASE_DOMAIN} -> ${REGISTRATION_IP}"
echo "    keycloak.${BASE_DOMAIN} -> ${KEYCLOAK_IP}"

AGENT_BIN="${SCRIPT_DIR}/target/x86_64-unknown-linux-musl/release/nexus-connectivity-agent"
FACTORY_CHAIN="${VEHICLE_CLIENT_DIR}/certificates/vehicle-${VIN}-factory-gcp-chain.pem"
FACTORY_KEY="${VEHICLE_CLIENT_DIR}/certificates/vehicle-${VIN}-factory-gcp-key.pem"
[ -x "${AGENT_BIN}" ] || { echo "missing ${AGENT_BIN} — cargo build --release --target x86_64-unknown-linux-musl" >&2; exit 1; }
[ -f "${FACTORY_CHAIN}" ] && [ -f "${FACTORY_KEY}" ] || {
    echo "missing factory cert/key for VIN ${VIN} in ${VEHICLE_CLIENT_DIR}/certificates/" >&2
    echo "provision once with: (cd ${VEHICLE_CLIENT_DIR} && ./run-vehicle-client.sh --vin ${VIN})" >&2
    exit 1
}

REMOTE_DIR="/data/local/tmp/nexus-connectivity-agent-run"
echo "=== Pushing to Core3 (${CORE3_ADB}) ==="
${ADB} shell "mkdir -p ${REMOTE_DIR}/certificates"
${ADB} push "${AGENT_BIN}" "${REMOTE_DIR}/nexus-connectivity-agent"
${ADB} push "${VEHICLE_CLIENT_DIR}/certificates/KEYCLOAK_TLS_CRT.pem" "${REMOTE_DIR}/certificates/KEYCLOAK_TLS_CRT.pem"
${ADB} push "${VEHICLE_CLIENT_DIR}/certificates/REGISTRATION_SERVER_TLS_CERT.pem" "${REMOTE_DIR}/certificates/REGISTRATION_SERVER_TLS_CERT.pem"
# The hub's leaf port speaks TLS since Increment 2.2; the anchor is the CA that issued its
# certificate. Without the file the leaf connects plain — for a hub that has no TLS yet.
if [ -s "${VEHICLE_CLIENT_DIR}/certificates/NATS_LEAF_TLS_CA.pem" ]; then
    ${ADB} push "${VEHICLE_CLIENT_DIR}/certificates/NATS_LEAF_TLS_CA.pem" "${REMOTE_DIR}/certificates/NATS_LEAF_TLS_CA.pem"
    LEAF_TLS="${NEXUS_LEAF_TLS:-on}"
else
    echo "note: no NATS_LEAF_TLS_CA.pem in ${VEHICLE_CLIENT_DIR}/certificates — the leaf connects without TLS"
    LEAF_TLS="off"
fi
${ADB} push "${FACTORY_CHAIN}" "${REMOTE_DIR}/certificates/vehicle-${VIN}-factory-gcp-chain.pem"
${ADB} push "${FACTORY_KEY}" "${REMOTE_DIR}/certificates/vehicle-${VIN}-factory-gcp-key.pem"
${ADB} shell "chmod +x ${REMOTE_DIR}/nexus-connectivity-agent"
# Lock the staged identity down (F28): adb push leaves every file readable and
# writable for everyone, and on guests where SELinux runs permissive nothing else
# protects them. The working folder must not be writable for others either, or the
# certificates folder could be swapped out and the binary run as root replaced.
${ADB} shell "chmod 755 ${REMOTE_DIR} ${REMOTE_DIR}/nexus-connectivity-agent && chmod 700 ${REMOTE_DIR}/certificates && chmod 644 ${REMOTE_DIR}/certificates/*.pem && chmod 600 ${REMOTE_DIR}/certificates/*-key.pem"

# The mesh guests carry no default route of their own, so without this the
# nexus-connectivity-agent only ever logs "credential fetch failed: … cannot reach …"
# (provision-and-run.sh does the same). It does not survive a guest reboot.
${ADB} shell "ip route | grep -q '^default' || ip route replace default via 192.168.98.1 dev eth1" 2>/dev/null || true

LEAF_LOG="/data/local/tmp/nats-leaf.log"
LEAF_CONF="/data/local/tmp/leaf.conf"

# `setsid … &` inside an adb-shell string dies silently on these builds: the call
# returns, nothing runs, and the previous run's agent.log stays behind looking
# like a fresh start (cost us a test round on 2026-09-16). The subshell + nohup +
# closing echo below is the form that survives. Old logs and leaf.conf are
# removed so nothing here can be read as evidence of this run.
echo "=== Restarting agent on Core3 ==="
# umask 077: everything the agent creates at start-up — leaf.conf with the vehicle's
# NATS token, nats-leaf.log, agent.log — is readable by root only (F28). leaf.conf is
# removed first because umask only applies to files that are created, not rewritten.
# Processes are stopped by name: a pkill -f on the agent's path also matches this
# adb shell's own command line and would kill the launch along with it.
${ADB} shell "pkill nexus-connectiv 2>/dev/null; pkill nats-server 2>/dev/null; sleep 1; cd ${REMOTE_DIR}; rm -f ${REMOTE_DIR}/agent.log ${LEAF_LOG} ${LEAF_CONF}; umask 077; ( NEXUS_VIN=${VIN} NEXUS_CLOUD_NATS_HOST=${CLOUD_NATS_IP} NEXUS_CLOUD_NATS_NAME=${CLOUD_NATS_HOST} NEXUS_LEAF_TLS=${LEAF_TLS} NEXUS_RUN_DIR=${REMOTE_DIR} NEXUS_LEAF_HOST=${CORE3_LEAF_HOST} NEXUS_REGISTRATION_URL=https://registration.${BASE_DOMAIN}:8443 NEXUS_KEYCLOAK_URL=https://keycloak.${BASE_DOMAIN}:8443 NEXUS_NATS_URL=nats://${CLOUD_NATS_HOST}:4222 NEXUS_REGISTRATION_IP=${REGISTRATION_IP} NEXUS_KEYCLOAK_IP=${KEYCLOAK_IP} NEXUS_DISCOVERY_REFLECTION=${NEXUS_DISCOVERY_REFLECTION:-on}${NEXUS_DISCOVERY_PORT:+ NEXUS_DISCOVERY_PORT=${NEXUS_DISCOVERY_PORT}} nohup ${REMOTE_DIR}/nexus-connectivity-agent > ${REMOTE_DIR}/agent.log 2>&1 < /dev/null & ); sleep 2; echo launched"

echo "Agent deployed to Core3 (${CORE3_ADB}) for VIN ${VIN} -> upstream ${CLOUD_NATS_HOST} (${CLOUD_NATS_IP}):7422"
echo "Discovery: grpcurl -plaintext ${CORE3_LEAF_HOST}:18051 nexus.discovery.Discovery/GetLeafAddress"
echo "Check: ${ADB} shell 'cat ${REMOTE_DIR}/agent.log'"
echo "Verify:  ${ADB} shell \"pgrep -af '[n]exus-connectivity-agent|[n]ats-server'\""
