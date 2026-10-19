#!/usr/bin/env bash
# Round-trip acceptance for Increment 2.1: does a message get out of the vehicle, and does
# one from the cloud get in?
#
# It proves the path from the vehicle's own leaf outwards and inwards. It does NOT prove
# delivery across a link drop — nothing stores messages yet, so a message sent while the
# link is down is lost by design (Increment 2.5).
#
# Usage:
#   NEXUS_VIN=<VIN> TCU_ADB="adb -s 0.0.0.0:6522" APP_ADB="adb -s 0.0.0.0:6521" ./round-trip-test.sh [seconds]
#
#   NEXUS_VIN  the VIN the vehicle was provisioned with
#
#   TCU_ADB  the guest running the nexus-connectivity-agent and the Nexus Bridge
#   APP_ADB  the guest running the publishing/receiving service bundle
#   seconds  observation window for the outbound direction (default 120)
#
# Like check-leaf-connection.sh it decides from captured output only, never from adb's exit
# status, which does not carry a guest command's status reliably across versions.
#
# The inbound direction is triggered by publishing straight into the vehicle's own leaf.
# That needs no credentials and exercises everything from the leaf inwards. What is
# published is a PressureLimit whose max_pressure is this run's marker; PressureAdvisor logs
# it decoded. Each run uses its own marker, so a line left over from an earlier run cannot be read as this run's
# success — the mistake that made a dropped message look delivered for a week in 1.1.
set -u

TCU_ADB="${TCU_ADB:?set TCU_ADB, e.g. TCU_ADB=\"adb -s 0.0.0.0:6522\"}"
APP_ADB="${APP_ADB:?set APP_ADB, e.g. APP_ADB=\"adb -s 0.0.0.0:6521\"}"
# The nexus-connectivity-agent logs its forwarded counter once per hundred messages; at
# Manager's one per second that is one line every 100 s, so the window must be longer.
# A shorter window can see no change while everything is working (2026-10-17: 60 s, FAIL).
OBSERVE_SECONDS="${1:-120}"
VIN="${NEXUS_VIN:?set NEXUS_VIN, the VIN the vehicle was provisioned with}"
COMMAND_TOPIC="${NEXUS_COMMAND_TOPIC:-pressure-limit}"
# Host and port as two words: the guest's toybox nc takes its options before the address
# and refuses "nc <addr> <port> -w 2" with a bare "bad argument count".
LEAF_ADDR="${NEXUS_LEAF_ADDR:-127.0.0.1 4222}"

# The init service's run directory (nexus_connectivity_agent.rc).
AGENT_LOG="/data/misc/nexus/agent.log"
LEAF_LOG="/data/misc/nexus/nats-leaf.log"

fail_reason=""
note() { printf '  %s\n' "$1"; }
# Keeps the FIRST reason. Later checks usually fail as a consequence of the first — a
# silent Bridge also means nothing arrives at the service — and reporting the last one
# would point a tester at the symptom instead of the cause. The run continues either way,
# so the output still shows every measurement.
fail() { [ -z "${fail_reason}" ] && fail_reason="$1"; return 0; }

# Number of lines in a guest file matching <pattern>; 0 when the file is missing.
guest_count() {
    local adb="$1" pattern="$2" file="$3" n
    n="$(${adb} shell "grep -c '${pattern}' '${file}' 2>/dev/null" </dev/null | tr -dc '0-9')"
    echo "${n:-0}"
}

logcat_count() {
    local adb="$1" pattern="$2" n
    n="$(${adb} logcat -d </dev/null 2>/dev/null | grep -c "${pattern}")"
    echo "${n:-0}"
}

# Counts the platform's own refusals in logcat.
#
# Two things this has to get right, both learned the hard way on 2026-09-24:
#
#   - The wording is "Authz violation", which is what the middleware writes
#     (service_discovery/sdv_sd_agent/srcs/mesh/peer_connection.rs:232 and its
#     siblings). A check that looked for "authorization violation" — the NATS
#     wording, which belongs to the leaf log — could never see a real one.
#   - adbd echoes every shell command it is asked to run into logcat, including the
#     command that greps for this very phrase. Without dropping adbd's own lines, a
#     check finds itself and reports a violation that never happened.
logcat_violations() {
    local adb="$1" n
    n="$(${adb} logcat -d </dev/null 2>/dev/null | grep -v ' adbd ' | grep -ci 'Authz violation')"
    echo "${n:-0}"
}

# The highest "forwarded N message(s)" the agent has logged, 0 if it has logged none.
forwarded_count() {
    local n
    n="$(${TCU_ADB} shell "grep -o 'forwarded [0-9]* message' '${AGENT_LOG}' 2>/dev/null | grep -o '[0-9]*' | tail -1" </dev/null | tr -dc '0-9')"
    echo "${n:-0}"
}

echo "=== Preconditions ==="
for pair in "TCU:${TCU_ADB}" "APP:${APP_ADB}"; do
    name="${pair%%:*}"; adb="${pair#*:}"
    booted="$(${adb} shell getprop sys.boot_completed </dev/null 2>/dev/null | tr -d '\r')"
    [ "${booted}" = "1" ] || fail "${name} guest is not booted"
    authz="$(${adb} shell getprop sdv.authz.enable </dev/null 2>/dev/null | tr -d '\r')"
    note "${name}: booted=${booted:-no} sdv.authz.enable=${authz:-unset}"
    # Enforcing AuthZ is the point: a PASS with it off would prove nothing about what the
    # platform permits.
    [ "${authz}" = "true" ] || fail "${name} guest does not have sdv.authz.enable=true"
done
[ -n "${fail_reason}" ] && { echo "✗ FAIL — ${fail_reason}"; exit 1; }

echo "=== Outbound: vehicle to cloud ==="
before="$(forwarded_count)"
note "forwarded before: ${before}"
sleep "${OBSERVE_SECONDS}"
after="$(forwarded_count)"
note "forwarded after ${OBSERVE_SECONDS}s: ${after}"
if [ "${after}" -le "${before}" ]; then
    fail "the nexus-connectivity-agent forwarded nothing in ${OBSERVE_SECONDS}s (${before} → ${after})"
fi

echo "=== Inbound: cloud to vehicle ==="
# Overridable so a tester can watch for a value they chose, and so the script's own
# tests can fix it. Time-based by default: each run must be distinguishable from the
# last, or an old log line would count as this run's success.
MARKER="${NEXUS_RT_MARKER:-$(( 100000 + 10#$(date -u +%H%M%S) ))}"
# The subject scheme Increment 1.2 shipped, unchanged. The vehicle subscribes to exactly
# the topics its Bridge declares, so its own telemetry never comes back to it.
SUBJECT="pubsub.${VIN}.${COMMAND_TOPIC}"
# PressureLimit { uint32 max_pressure = 1 }: field 1 as a varint — tag 0x08, then the value
# seven bits at a time, low first (https://protobuf.dev/programming-guides/encoding/). As
# octal escapes, which the guest's printf understands; LEN counts them, one per byte.
limit_octal() {
    local v="$1" out='\010' b
    while :; do
        b=$(( v & 0x7f )); v=$(( v >> 7 ))
        if [ "$v" -eq 0 ]; then out+="$(printf '\\%03o' "$b")"; break; fi
        out+="$(printf '\\%03o' $(( b | 0x80 )))"
    done
    printf '%s' "$out"
}
PAYLOAD="$(limit_octal "${MARKER}")"
LEN="$(printf '%s' "${PAYLOAD}" | tr -cd '\\' | wc -c | tr -d ' ')"
note "publishing PressureLimit{max_pressure: ${MARKER}} on ${SUBJECT}"
${TCU_ADB} shell "printf 'CONNECT {\"verbose\":false}\r\nPUB ${SUBJECT} ${LEN}\r\n${PAYLOAD}\r\nPING\r\n' | nc -w 2 ${LEAF_ADDR}" </dev/null >/dev/null 2>&1
sleep 5

bridge_published="$(logcat_count "${TCU_ADB}" 'nexus-bridge: published')"
note "Bridge published lines: ${bridge_published}"
[ "${bridge_published}" -gt 0 ] || fail "the Nexus Bridge did not publish the message on the Data Tunnel"

# PressureAdvisor logs the limit it received; the marker in that line is what makes it this
# run's message rather than any message. The pattern ends at a non-digit, so 123456 does
# not match 1234567.
received="$(${APP_ADB} logcat -d </dev/null 2>/dev/null | grep -cE "pressure-advisor: max_pressure=${MARKER}([^0-9]|\$)")"
note "service received this run's marker: ${received}"
[ "${received}" -gt 0 ] || fail "the service bundle did not receive this run's message"

echo "=== Violations (must be zero) ==="
perm="$(guest_count "${TCU_ADB}" 'Permissions Violation' "${LEAF_LOG}")"
authz_tcu="$(logcat_violations "${TCU_ADB}")"
authz_app="$(logcat_violations "${APP_ADB}")"
note "leaf Permissions Violation: ${perm}"
note "Authz violations TCU/APP: ${authz_tcu}/${authz_app}"
[ "${perm}" -eq 0 ] || fail "the leaf refused ${perm} publish(es) — check the subject permissions"
[ "${authz_tcu}" -eq 0 ] && [ "${authz_app}" -eq 0 ] || fail "the platform refused an AuthZ request"

# A drop during the window is expected at the measured rate and does not fail the run: this
# check claims delivery while the link is up, nothing more.
drops="$(guest_count "${TCU_ADB}" 'Leafnode connection closed' "${LEAF_LOG}")"
[ "${drops}" -gt 0 ] && note "note: ${drops} link drop(s) recorded — the link to the cloud was re-established each time; delivery across a drop is not claimed"

if [ -n "${fail_reason}" ]; then
    echo "✗ FAIL — ${fail_reason}"
    echo "  inspect:  ${TCU_ADB} shell tail -40 ${AGENT_LOG}"
    echo "            ${TCU_ADB} logcat -d | grep nexus-bridge"
    echo "            ${APP_ADB} logcat -d | grep -E 'pressure-advisor|sdv_lm_pressure_advisor'"
    exit 1
fi

echo "✓ PASS — both directions carried a message, no violations"
echo "  outbound ${before} → ${after} forwarded, inbound marker ${MARKER} arrived"
