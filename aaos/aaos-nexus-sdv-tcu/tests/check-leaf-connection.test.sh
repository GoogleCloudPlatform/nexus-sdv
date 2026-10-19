#!/usr/bin/env bash
# Tests check-leaf-connection.sh against a stand-in for adb — no device needed.
# Run:  aaos/aaos-nexus-sdv-tcu/tests/check-leaf-connection.test.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/../check-leaf-connection.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The stand-in runs the guest command locally, with the guest's /data/misc/nexus
# mapped into $FAKE_ROOT, and answers `pgrep` from a file listing the "running"
# agent PIDs — an empty file means the agent is not running.
cat > "$WORK/adb" <<'FAKE'
#!/usr/bin/env bash
[ "${1:-}" = "-s" ] && shift 2
[ "${1:-}" = "shell" ] || exit 0
shift
cmd="$*"
cmd="${cmd//\/data\/misc\/nexus/$FAKE_ROOT/data/misc/nexus}"
cmd="${cmd//pgrep nexus-connectiv/cat $FAKE_ROOT/agent_pids}"
sh -c "$cmd"
FAKE
chmod +x "$WORK/adb"

# Real log lines, taken from a leaf log on the dev mesh and from Google's report.
CREATED='[941] 2026/09/14 00:12:33.077250 [INF] 34.116.195.11:7422 - lid:6 - Leafnode connection created for account: $G'
CLOSED='[941] 2026/09/14 00:14:35.080000 [INF] 34.116.195.11:7422 - lid:6 - Leafnode connection closed: Read Error - Remote: nats-0'
VIOLATION='[941] 2026/09/14 00:12:34.000000 [ERR] 34.116.195.11:7422 - lid:6 - Authorization Violation'
# The agent's own status lines (leaf_status.rs). The wording is an interface.
UP='leaf status: link=up links=1'
DOWN='leaf status: link=down links=0'
UNKNOWN='leaf status: link=unknown links=0 (leaf did not answer on 127.0.0.1:18222)'

passed=0
failed=0

# run_case <name> <PASS|FAIL> <text the output must contain> <setup function> [observe-seconds]
run_case() {
    local name="$1" expect="$2" text="$3" setup="$4" observe="${5:-1}"
    export FAKE_ROOT="$WORK/$name"
    LEAF="$FAKE_ROOT/data/misc/nexus/nats-leaf.log"
    AGENT="$FAKE_ROOT/data/misc/nexus/agent.log"
    PIDS="$FAKE_ROOT/agent_pids"
    mkdir -p "$(dirname "$AGENT")"
    : > "$LEAF"; : > "$AGENT"; echo 4242 > "$PIDS"
    "$setup"
    local out rc got
        # The script refuses a window shorter than the leaf's reporting interval on a real
    # device. These cases drive it against fixtures where no time has to pass, so the
    # minimum is lifted here and only here.
out="$(ADB="$WORK/adb -s fake" CONNECT_TIMEOUT_SECONDS=2 POLL_SECONDS=1 CHECK_MIN_OBSERVE_SECONDS=0 GRANT_SETTLE_SECONDS=1 "$CHECK" "$observe" 2>&1)"
    rc=$?
    wait 2>/dev/null
    got="PASS"; [ "$rc" -eq 0 ] || got="FAIL"
    if [ "$got" = "$expect" ] && printf '%s' "$out" | grep -qF -- "$text"; then
        echo "  ok    $name"
        passed=$((passed + 1))
    else
        echo "  FAIL  $name — expected $expect containing: $text — got $got:"
        printf '%s\n' "$out" | sed 's/^/        /'
        failed=$((failed + 1))
    fi
}

# A healthy agent keeps reporting during the window, so the check can tell a live
# leaf from a log that merely looks alive.
# The check first waits one second for a grant to settle (GRANT_SETTLE_SECONDS=1 here), so
# what a fixture wants to happen "during the window" happens after that second.
healthy()              { echo "$CREATED" >> "$LEAF"; echo "$UP" >> "$AGENT"; ( for _ in $(seq 1 16); do sleep 0.25; echo "$UP" >> "$AGENT"; done ) & }
legacy_agent()         { echo "$CREATED" >> "$LEAF"; }
status_frozen()        { echo "$CREATED" >> "$LEAF"; echo "$UP" >> "$AGENT"; }
status_down()          { healthy; ( sleep 1.5; echo "$DOWN" >> "$AGENT" ) & }
status_unknown()       { healthy; ( sleep 1.5; echo "$UNKNOWN" >> "$AGENT" ) & }
discovery_failed()     { healthy; echo "discovery server error: transport error" >> "$AGENT"; }
agent_panicked()       { healthy; echo "thread 'main' panicked at src/main.rs:80:5" >> "$AGENT"; }
drops_in_window()      { healthy; ( sleep 2.5; echo "$CLOSED" >> "$LEAF" ) & }
# Right after a first provisioning: the link comes up, the first grant arrives, and the
# nexus-connectivity-agent restarts the leaf to apply it. Seen at every first provisioning
# (2026-10-08, 2026-10-10); the check used to report it as a failure.
GRANT='grant changed: pub=1 sub=2 — re-establishing the upstream connection'
first_grant()          { echo "$CREATED" >> "$LEAF"; echo "$UP" >> "$AGENT"
                         ( sleep 0.5; echo "$GRANT" >> "$AGENT"; echo "$CLOSED" >> "$LEAF"; echo "$UNKNOWN" >> "$AGENT"
                           sleep 1.2; echo "$CREATED" >> "$LEAF"
                           for _ in $(seq 1 24); do echo "$UP" >> "$AGENT"; sleep 0.25; done ) & }
down_before_check()    { healthy; echo "$CLOSED" >> "$LEAF"; }
recovered_earlier()    { healthy; echo "$CLOSED" >> "$LEAF"; echo "$CREATED" >> "$LEAF"; }
violation()            { healthy; echo "$VIOLATION" >> "$LEAF"; }
agent_gone()           { : > "$PIDS"; }
never_connects()       { :; }
agent_dies_in_window() { healthy; ( sleep 2.5; : > "$PIDS" ) & }

echo "check-leaf-connection.sh"
run_case healthy              PASS "✓ PASS"                                             healthy
run_case discovery-failed     FAIL "agent.log reports: 'discovery server error'"         discovery_failed
run_case agent-panicked       FAIL "agent.log reports: 'panicked at'"                    agent_panicked
run_case drops-in-window      FAIL "the link dropped 1 time(s) during"                  drops_in_window 3
run_case down-before-check    FAIL "the leaf node link is down right now"               down_before_check
run_case recovered-earlier    PASS "the link had already dropped 1 time(s)"             recovered_earlier
run_case violation            FAIL "1 authorization violation(s)"                       violation
run_case agent-gone           FAIL "the nexus-connectivity-agent exited before the link came up"           agent_gone
run_case never-connects       FAIL "no leaf node link within 2 s"                       never_connects
run_case agent-dies-in-window FAIL "the nexus-connectivity-agent exited during the observation window"     agent_dies_in_window 3
run_case legacy-agent         PASS "reports no leaf status"                            legacy_agent
run_case status-frozen        FAIL "the leaf reported no healthy link during"          status_frozen
run_case status-down          FAIL "the leaf reported the link down during"            status_down
run_case status-unknown       FAIL "did not answer its own status query"               status_unknown
run_case first-grant          PASS "the first grant arrived"                           first_grant
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
