#!/usr/bin/env bash
# Acceptance check for the Nexus TCU stack on one AAOS-SDV guest: is the agent
# healthy, and does the leaf node link to the cloud stay up?
#
# provision-and-run.sh calls it as its last step. It can be re-run on its own at
# any time.
#
# Why more than "the link came up once": on 2026-09-14 Google's test got a PASS
# from exactly that check, on a stack whose discovery server had failed and whose
# link kept dropping. This check additionally requires the agent log to be free of
# fatal errors, the link to be up right now, and the link to survive an
# observation window without a single disconnect.
#
# Usage:  ADB="adb -s <serial>" ./check-leaf-connection.sh [observe-seconds]
#   observe-seconds  how long the link must stay up without dropping (default 70,
#                    and never less: see the note at STATUS_REPORT_INTERVAL_SECONDS)
#
# It decides from captured output only, never from adb's exit status: adb does
# not pass a guest command's exit status through reliably across versions.
#
# The agent asks the leaf itself for its state and writes the answer into its log
# ("leaf status: link=up links=1"). Those lines come from the running process, so
# they cannot be faked by a log left over from an earlier run — an older agent
# without them falls back to log inference, which this check then reports.
set -u

ADB="${ADB:?set ADB, e.g. ADB=\"adb -s 0.0.0.0:6520\"}"
# The nexus-connectivity-agent reports the leaf's state at most once a minute, and this
# check requires a fresh report inside the window — that is what proves the leaf answered
# *during* the observation rather than once at the start. A window shorter than that
# reporting interval therefore fails or passes depending on where it falls in the cadence,
# which is a coin toss, not a check (measured 2026-09-24: reports exactly 60 s apart, zero
# drops, and a 30 s window failed). Anything shorter is raised to the minimum, out loud.
STATUS_REPORT_INTERVAL_SECONDS=60
# Overridable for this script's own tests, which drive it against fixtures where no time
# has to pass at all. Never set it on a device: the minimum is what makes the verdict mean
# something.
MIN_OBSERVE_SECONDS="${CHECK_MIN_OBSERVE_SECONDS:-$((STATUS_REPORT_INTERVAL_SECONDS + 10))}"
OBSERVE_SECONDS="${1:-$MIN_OBSERVE_SECONDS}"
if [ "$OBSERVE_SECONDS" -lt "$MIN_OBSERVE_SECONDS" ]; then
    echo "note: raising the observation window from ${OBSERVE_SECONDS} s to ${MIN_OBSERVE_SECONDS} s —"
    echo "      the leaf's state is reported every ${STATUS_REPORT_INTERVAL_SECONDS} s and this check needs one report inside the window"
    OBSERVE_SECONDS="$MIN_OBSERVE_SECONDS"
fi
CONNECT_TIMEOUT_SECONDS="${CONNECT_TIMEOUT_SECONDS:-60}"
POLL_SECONDS="${POLL_SECONDS:-3}"

# The init service's run directory (nexus_connectivity_agent.rc); both logs live there.
AGENT_LOG="/data/misc/nexus/agent.log"
LEAF_LOG="/data/misc/nexus/nats-leaf.log"

# agent.log lines that mean part of the agent has died although the process may
# still be running — the discovery server, for example, runs on its own thread.
FATAL_AGENT_PATTERNS=("discovery server error" "panicked at")

# Number of lines in a guest file that contain <pattern>; 0 if the file is missing.
guest_count() {
    local n
    n="$(${ADB} shell "grep -c '$1' '$2' 2>/dev/null" | tr -dc '0-9')"
    echo "${n:-0}"
}

agent_running() {
    local n
    n="$(${ADB} shell "pgrep nexus-connectiv 2>/dev/null | wc -l" | tr -dc '0-9')"
    [ "${n:-0}" != "0" ]
}

fail() {
    echo "" >&2
    echo "✗ FAIL — $1" >&2
    echo "  agent log: ${ADB} shell cat ${AGENT_LOG}" >&2
    echo "  leaf log:  ${ADB} shell cat ${LEAF_LOG}" >&2
    exit 1
}

check_agent_log() {
    local pattern
    for pattern in "${FATAL_AGENT_PATTERNS[@]}"; do
        if [ "$(guest_count "$pattern" "$AGENT_LOG")" != "0" ]; then
            ${ADB} shell "grep '$pattern' '$AGENT_LOG' | tail -3" >&2
            fail "agent.log reports: '$pattern'"
        fi
    done
}

echo "=== 1/4 waiting for the leaf node link (up to ${CONNECT_TIMEOUT_SECONDS} s) ==="
waited=0
while [ "$(guest_count 'Leafnode connection created' "$LEAF_LOG")" = "0" ]; do
    if ! agent_running; then
        ${ADB} shell "tail -8 '$AGENT_LOG'" >&2
        fail "the nexus-connectivity-agent exited before the link came up"
    fi
    [ "$waited" -lt "$CONNECT_TIMEOUT_SECONDS" ] || fail "no leaf node link within ${CONNECT_TIMEOUT_SECONDS} s"
    sleep "$POLL_SECONDS"
    waited=$((waited + POLL_SECONDS))
done

# A first grant restarts the leaf: the nexus-connectivity-agent announces its offers over
# the fresh link, the registry answers, and the leaf is started again with the grant. That
# is the vehicle working, not a drop — but it happens a few seconds after the link first
# comes up, which is exactly when this check is run after provisioning. So the observation
# starts only once no grant change has been logged for a while and the link is up again.
GRANT_SETTLE_SECONDS="${GRANT_SETTLE_SECONDS:-15}"
grants_seen="$(guest_count 'grant changed' "$AGENT_LOG")"
quiet=0
while [ "$quiet" -lt "$GRANT_SETTLE_SECONDS" ]; do
    sleep "$POLL_SECONDS"
    quiet=$((quiet + POLL_SECONDS))
    grants_now="$(guest_count 'grant changed' "$AGENT_LOG")"
    if [ "$grants_now" != "$grants_seen" ]; then
        echo "    note: the first grant arrived and the leaf restarted to apply it — waiting for the link to come back"
        grants_seen="$grants_now"
        quiet=0
    fi
done
waited=0
while [ "$(guest_count 'Leafnode connection created' "$LEAF_LOG")" -le "$(guest_count 'Leafnode connection closed' "$LEAF_LOG")" ]; do
    agent_running || fail "the nexus-connectivity-agent exited while the link was coming back"
    [ "$waited" -lt "$CONNECT_TIMEOUT_SECONDS" ] || fail "the leaf node link is down right now"
    sleep "$POLL_SECONDS"
    waited=$((waited + POLL_SECONDS))
done

echo "=== 2/4 agent log free of fatal errors ==="
check_agent_log

closed_before="$(guest_count 'Leafnode connection closed' "$LEAF_LOG")"
up_before="$(guest_count 'leaf status: link=up' "$AGENT_LOG")"
down_before="$(guest_count 'leaf status: link=down' "$AGENT_LOG")"
unknown_before="$(guest_count 'leaf status: link=unknown' "$AGENT_LOG")"
if [ "$closed_before" != "0" ]; then
    echo "    note: the link had already dropped ${closed_before} time(s) before this check"
fi

echo "=== 3/4 link must stay up for ${OBSERVE_SECONDS} s ==="
sleep "$OBSERVE_SECONDS"
agent_running || fail "the nexus-connectivity-agent exited during the observation window"
closed_after="$(guest_count 'Leafnode connection closed' "$LEAF_LOG")"
created_after="$(guest_count 'Leafnode connection created' "$LEAF_LOG")"
dropped=$((closed_after - closed_before))
[ "$dropped" -eq 0 ] || fail "the link dropped ${dropped} time(s) during the ${OBSERVE_SECONDS} s window"
# Every connection logs one "created" and, when it ends, one "closed". The link
# is up right now only if more connections have been created than closed.
[ "$created_after" -gt "$closed_after" ] || fail "the leaf node link is down right now"

# The leaf's own answer, which beats reading its log: it proves nats-server was
# alive during the window and what it thought of the link.
up_after="$(guest_count 'leaf status: link=up' "$AGENT_LOG")"
down_after="$(guest_count 'leaf status: link=down' "$AGENT_LOG")"
unknown_after="$(guest_count 'leaf status: link=unknown' "$AGENT_LOG")"
if [ "$((up_before + down_before + unknown_before + up_after + down_after + unknown_after))" -eq 0 ]; then
    echo "    note: this nexus-connectivity-agent reports no leaf status (an older version); the verdict rests on log lines alone"
else
    [ "$up_after" -gt "$up_before" ] || fail "the leaf reported no healthy link during the window"
    [ "$((down_after - down_before))" -eq 0 ] || fail "the leaf reported the link down during the window"
    [ "$((unknown_after - unknown_before))" -eq 0 ] || fail "nats-server did not answer its own status query during the window"
fi
check_agent_log

echo "=== 4/4 zero authorization violations ==="
violations="$(guest_count 'Authorization Violation' "$LEAF_LOG")"
[ "$violations" = "0" ] || fail "${violations} authorization violation(s) in the leaf log"

echo ""
echo "✓ PASS — nexus-connectivity-agent running without fatal errors, leaf node link up and stable for ${OBSERVE_SECONDS} s, zero authorization violations"
