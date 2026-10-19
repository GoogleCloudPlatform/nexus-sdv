#!/usr/bin/env bash
# Increment 2.2: does the cloud's grant bound what this vehicle may do?
#
#   (a) closed — the vehicle's grant is empty: a hub subscriber on pubsub.<vin>.pressure
#       receives nothing, and a pressure limit published on the hub does not arrive. There is no
#       refusal to quote: the leaf never sends a publish the hub forwards it no interest for
#       (F41), so "closed" is proven by absence at the hub —
#   (b) open — the grant opens: the nexus-connectivity-agent reports the change within
#       NEXUS_GRANT_WAIT seconds, its status line shows it, and a second limit arrives —
#   (c) and the same hub subscriber now receives pressure. Only (c) in the same run makes
#       (a)'s silence evidence: a silent pipe fails here (spec section 6, A6).
#
# Usage:
#   TCU_ADB="adb -s 0.0.0.0:6522" APP_ADB="adb -s 0.0.0.0:6521" \
#   NEXUS_RESTART_CMD='…' NEXUS_GRANT_CMD='…' NEXUS_HUB_PUB_CMD='…' NEXUS_HUB_SUB_CMD='…' \
#   ./registry-test.sh [seconds]
#
#   NEXUS_RESTART_CMD  restarts the nexus-connectivity-agent on the TCU (the leaf
#                      reconnects and announces; the restart also empties the logs)
#   NEXUS_GRANT_CMD    opens the grant: by hand in the mock stage, or by starting the cloud
#                      services that register pressure and pressure-limit
#   NEXUS_HUB_PUB_CMD  publishes its first argument on pubsub.<vin>.pressure-limit on the
#                      hub: an encoded PressureLimit, written as printf octal escapes
#                      (\010\270\060) — plain ASCII, because kubectl exec refused arguments
#                      that are not UTF-8 (measured 2026-10-07: "string field contains
#                      invalid UTF-8"); the command turns them into bytes with printf
#   NEXUS_HUB_SUB_CMD  subscribes pubsub.<vin>.pressure on the hub for its first argument
#                      in seconds and prints how many messages arrived
#   seconds            the hub subscriber's window in (c), default 60
#
# Every decision comes from captured output; the commands' exit codes are ignored, as
# adb's are. The waits (NEXUS_SETTLE, NEXUS_DELIVERY_WAIT, NEXUS_GRANT_WAIT,
# NEXUS_SUB_SECONDS) are overridable so the script's own tests need no minutes.
set -u
TCU_ADB="${TCU_ADB:?set TCU_ADB, e.g. TCU_ADB=\"adb -s 0.0.0.0:6522\"}"
APP_ADB="${APP_ADB:?set APP_ADB, e.g. APP_ADB=\"adb -s 0.0.0.0:6521\"}"
: "${NEXUS_RESTART_CMD:?set NEXUS_RESTART_CMD}"
: "${NEXUS_GRANT_CMD:?set NEXUS_GRANT_CMD}"
: "${NEXUS_HUB_PUB_CMD:?set NEXUS_HUB_PUB_CMD}"
: "${NEXUS_HUB_SUB_CMD:?set NEXUS_HUB_SUB_CMD}"
GRANT_WAIT="${NEXUS_GRANT_WAIT:-30}"
SETTLE="${NEXUS_SETTLE:-10}"
DELIVERY_WAIT="${NEXUS_DELIVERY_WAIT:-5}"
SUB_SECONDS="${NEXUS_SUB_SECONDS:-10}"
OBSERVE_SECONDS="${1:-60}"
# The init service's run directory (nexus_connectivity_agent.rc).
AGENT_LOG="/data/misc/nexus/agent.log"
LEAF_LOG="/data/misc/nexus/nats-leaf.log"

fail_reason=""
note() { printf '  %s\n' "$1"; }
# Keeps the FIRST reason: later checks usually fail as a consequence of the first.
fail() { [ -z "${fail_reason}" ] && fail_reason="$1"; return 0; }

guest_count() {
    local adb="$1" pattern="$2" file="$3" n
    n="$(${adb} shell "grep -c '${pattern}' '${file}' 2>/dev/null" </dev/null | tr -dc '0-9')"
    echo "${n:-0}"
}
last_line() {
    local adb="$1" pattern="$2" file="$3"
    ${adb} shell "grep '${pattern}' '${file}' 2>/dev/null | tail -1" </dev/null | tr -d '\r'
}
forwarded_count() {
    local n
    n="$(${TCU_ADB} shell "grep -o 'forwarded [0-9]* message' '${AGENT_LOG}' 2>/dev/null | grep -o '[0-9]*' | tail -1" </dev/null | tr -dc '0-9')"
    echo "${n:-0}"
}
# How many pressure messages a hub subscriber received in <seconds>: the last non-empty
# output line, when it is made entirely of digits. Anything else is unreadable — not a
# count, and never silently taken as zero. (Named differently from the documented tester
# function NEXUS_HUB_SUB_CMD=hub_count, TESTING.md — sharing a name with an exported bash
# function the caller passes in would make this script's own definition, which keeps the
# export attribute, shadow the caller's in every child it starts, recursing without end.)
hub_received() {
    local line
    line="$(bash -c "${NEXUS_HUB_SUB_CMD} $1" </dev/null 2>/dev/null | grep -v '^[[:space:]]*$' | tail -1)"
    case "${line}" in
        ''|*[!0-9]*) echo "unreadable:${line:-<no output>}" ;;
        *) echo "${line}" ;;
    esac
}
# The marker is a max_pressure between 6144 and 7423. Its PressureLimit encodes to
# 08, (0x80 | low seven bits), (value >> 7) — https://protobuf.dev/programming-guides/encoding/ —
# and in this range the last byte is an ASCII digit, never a line end that a shell's command
# substitution would strip on the hub side. Handed over as octal escapes (see the header).
limit_octal() {
    printf '\\010\\%03o\\%03o' $(( 128 | ($1 & 127) )) $(( $1 >> 7 ))
}
# PressureAdvisor logs the limit it received; the marker in that line makes it this run's.
marker_received() {
    ${APP_ADB} logcat -d </dev/null 2>/dev/null | grep -cE "pressure-advisor: max_pressure=$1([^0-9]|\$)"
}
# Waits until the count of <pattern> in <file> rises above <baseline>; 0 when it did in time.
wait_above() {
    local secs="$1" adb="$2" pattern="$3" file="$4" baseline="$5" t=0 n
    while :; do
        n="$(guest_count "$adb" "$pattern" "$file")"
        [ "$n" -gt "$baseline" ] && return 0
        [ "$t" -ge "$secs" ] && return 1
        sleep 1; t=$((t + 1))
    done
}

echo "=== (a) closed: nothing reaches the hub, nothing reaches the vehicle ==="
note "restarting the nexus-connectivity-agent — the logs start afresh"
bash -c "${NEXUS_RESTART_CMD}" >/dev/null 2>&1
sleep "${SETTLE}"
status="$(last_line "${TCU_ADB}" 'leaf status:' "${AGENT_LOG}")"
note "status: ${status:-<none>}"
case "${status}" in
    *"link=up"*) ;;
    *) fail "the leaf holds no link to the hub (${status:-no status line})" ;;
esac
case "${status}" in
    *"grant=none"*|*"pub:0 sub:0"*) ;;
    *) fail "the vehicle already holds a grant (${status}); start from an empty one" ;;
esac
closed="$(hub_received "${SUB_SECONDS}")"
case "${closed}" in
    unreadable:*) fail "a hub subscriber printed an unreadable count instead of a number (${closed#unreadable:})" ;;
    *)
        note "a hub subscriber received ${closed} pressure message(s) in ${SUB_SECONDS}s"
        [ "${closed}" -eq 0 ] || fail "a hub subscriber received ${closed} pressure message(s) while the channel was closed" ;;
esac
# Two markers a run, closed and open; they repeat every 1278 two-second steps (about 42
# minutes), long after an earlier run's lines have left logcat's ring buffer.
MARKER="${NEXUS_RT_MARKER:-$(( 6144 + ($(date +%s) / 2) % 1278 ))}"
MARKER_OPEN=$(( MARKER + 1 ))
note "publishing PressureLimit{max_pressure: ${MARKER}} on the hub while the channel is closed"
bash -c "${NEXUS_HUB_PUB_CMD} '$(limit_octal "${MARKER}")'" >/dev/null 2>&1
sleep "${DELIVERY_WAIT}"
[ "$(marker_received "${MARKER}")" -eq 0 ] || fail "the closed-phase marker reached the service bundle although the channel was closed"

echo "=== (b) open: the grant opens, the vehicle follows ==="
changes_before="$(guest_count "${TCU_ADB}" 'grant changed' "${AGENT_LOG}")"
bash -c "${NEXUS_GRANT_CMD}" >/dev/null 2>&1
if wait_above "${GRANT_WAIT}" "${TCU_ADB}" 'grant changed' "${AGENT_LOG}" "${changes_before}"; then
    note "grant change reported: $(last_line "${TCU_ADB}" 'grant changed' "${AGENT_LOG}")"
else
    fail "the nexus-connectivity-agent did not report a grant change within ${GRANT_WAIT}s"
fi
sleep "${SETTLE}"
status="$(last_line "${TCU_ADB}" 'leaf status:' "${AGENT_LOG}")"
note "status: ${status:-<none>}"
case "${status}" in
    *"sub:0"*|*"grant=none"*|"") fail "the status line does not show the subscription grant (${status:-no status line})" ;;
esac
note "publishing PressureLimit{max_pressure: ${MARKER_OPEN}} on the hub with the channel open"
bash -c "${NEXUS_HUB_PUB_CMD} '$(limit_octal "${MARKER_OPEN}")'" >/dev/null 2>&1
sleep "${DELIVERY_WAIT}"
[ "$(marker_received "${MARKER_OPEN}")" -gt 0 ] || fail "the open-phase marker did not reach the service bundle"

echo "=== (c) open: the hub subscriber receives pressure ==="
before="$(forwarded_count)"
opened="$(hub_received "${OBSERVE_SECONDS}")"
after="$(forwarded_count)"
case "${opened}" in
    unreadable:*) fail "a hub subscriber printed an unreadable count instead of a number (${opened#unreadable:})" ;;
    *)
        note "a hub subscriber received ${opened} pressure message(s) in ${OBSERVE_SECONDS}s; the nexus-connectivity-agent forwarded ${before} → ${after}"
        [ "${opened}" -gt 0 ] || fail "nothing reached a hub subscriber in ${OBSERVE_SECONDS}s, so (a)'s silence proves nothing (the nexus-connectivity-agent forwarded ${before} → ${after})" ;;
esac

if [ -n "${fail_reason}" ]; then
    echo "✗ FAIL — ${fail_reason}"
    echo "  inspect:  ${TCU_ADB} shell tail -40 ${AGENT_LOG}"
    echo "            ${TCU_ADB} shell tail -40 ${LEAF_LOG}"
    exit 1
fi
echo "✓ PASS — closed: nothing at the hub, no limit delivered; the grant followed; open: limit delivered, pressure at the hub"
