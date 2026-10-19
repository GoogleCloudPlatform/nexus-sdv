#!/usr/bin/env bash
# Tests round-trip-test.sh against a stand-in for adb — no device needed.
# Run:  aaos/aaos-nexus-sdv-tcu/tests/round-trip-test.test.sh
#
# The point is that the acceptance check can FAIL. A check that only ever passes proves
# nothing, and we have had one: on 2026-09-14 a PASS came out of a stack whose link kept
# dropping. Every case below therefore fixes one condition and asserts the verdict.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/../round-trip-test.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The stand-in answers from files in $FAKE_ROOT, so a case is just a set of fixtures:
#   booted, authz        what getprop returns
#   agent.log            what the nexus-connectivity-agent has logged
#   leaf.log             what the leaf has logged
#   logcat               what logcat -d returns
# A second serial gets its own directory, so the two guests can differ.
cat > "$WORK/adb" <<'FAKE'
#!/usr/bin/env bash
serial="unknown"
[ "${1:-}" = "-s" ] && { serial="$2"; shift 2; }
root="$FAKE_ROOT/${serial}"
case "${1:-}" in
  logcat) cat "$root/logcat" 2>/dev/null; exit 0 ;;
  shell)  shift ;;
  *)      exit 0 ;;
esac
cmd="$*"
case "$cmd" in
  *sys.boot_completed*)   cat "$root/booted" 2>/dev/null; exit 0 ;;
  *sdv.authz.enable*)     cat "$root/authz"  2>/dev/null; exit 0 ;;
  *"forwarded "*)
    # The outbound counter: deterministic instead of timed. Each read returns the next
    # value when the case wants growth, and the same one when it does not. Appending to a
    # fixture from a background job raced with the script's own reads.
    n="$(cat "$root/forwarded" 2>/dev/null || echo 100)"
    [ "$(cat "$root/grow" 2>/dev/null)" = yes ] && { n=$((n + 100)); echo "$n" > "$root/forwarded"; }
    echo "$n"; exit 0 ;;
esac
# Everything else is a guest shell command over the fixture files.
cmd="${cmd//\/data\/misc\/nexus\/agent.log/$root/agent.log}"
cmd="${cmd//\/data\/misc\/nexus\/nats-leaf.log/$root/leaf.log}"
cmd="${cmd//nc -w 2 127.0.0.1 4222/cat >$root\/injected}"
eval "$cmd"
FAKE
chmod +x "$WORK/adb"

pass=0; fail=0
# Builds a case: healthy fixtures for both guests, which each test then breaks on purpose.
setup() {
    local name="$1"
    rm -rf "$WORK/$name"; mkdir -p "$WORK/$name/tcu" "$WORK/$name/app"
    for g in tcu app; do
        echo 1 > "$WORK/$name/$g/booted"
        echo true > "$WORK/$name/$g/authz"
        : > "$WORK/$name/$g/leaf.log"
        : > "$WORK/$name/$g/logcat"
    done
    # The outbound counter must grow between the two reads, so the fixture carries a
    # later line than the first read will see. The stand-in reads the file each time, so
    # the test appends to it from a background job during the observation window.
    echo 100 > "$WORK/$name/tcu/forwarded"
    echo yes > "$WORK/$name/tcu/grow"
    : > "$WORK/$name/tcu/agent.log"
    printf 'nexus-bridge: published 1 message(s) from the cloud\n' > "$WORK/$name/tcu/logcat"
    export FAKE_ROOT="$WORK/$name"
}

# Runs the check with a 1-second window. The marker is fixed so a case can prepare the
# matching receipt, and whether the outbound counter grows is a fixture, not a timing.
run_check() {
    local name="$1" grow="${2:-yes}"
    echo "$grow" > "$WORK/$name/tcu/grow"
    PATH="$WORK:$PATH" TCU_ADB="adb -s tcu" APP_ADB="adb -s app" \
        NEXUS_VIN=TESTVIN01 NEXUS_RT_MARKER="$MARKER" bash "$CHECK" 1 2>&1
}

# One fixed marker for every case, and the receipt fixture is written from it: the line
# PressureAdvisor logs for a PressureLimit carrying the marker as max_pressure.
MARKER="123456"
receipt() {
    printf 'I sdv_lm_pressure_advisor: pressure-advisor: max_pressure=%s\n' "$MARKER" > "$1"
}

expect() {
    local name="$1" want="$2" out="$3"
    if echo "$out" | grep -q -- "$want"; then
        echo "  ok   $name"; pass=$((pass + 1))
    else
        echo "  FAIL $name — expected '$want' in:"; echo "$out" | sed 's/^/       /'
        fail=$((fail + 1))
    fi
}

echo "round-trip-test.sh"

# 1 — everything healthy, both directions seen.
setup healthy
receipt "$WORK/healthy/app/logcat"
out="$(run_check healthy)"
expect "a healthy run passes" "✓ PASS" "$out"
# What went into the leaf: a PressureLimit{max_pressure: 123456}, whose protobuf bytes are
# 08 c0 c4 07 (protoc --encode of aaos/nexus-sdv-sample/catalog/nexus_sample.proto).
injected="$(od -An -tx1 "$WORK/healthy/tcu/injected" 2>/dev/null | tr -d ' \n')"
expect "the injected payload is the encoded PressureLimit" "08c0c407" "$injected"
expect "on the pressure-limit subject with its length" "PUB pubsub.TESTVIN01.pressure-limit 4" "$(cat "$WORK/healthy/tcu/injected" 2>/dev/null)"

# 1b — a receipt from an EARLIER run must not count as this one's. This is the check that
# would have caught the 1.1 mistake, where a stale line looked like a delivery.
setup stale-receipt
printf 'I sdv_lm_pressure_advisor: pressure-advisor: max_pressure=%s\n' 1234567 > "$WORK/stale-receipt/app/logcat"
out="$(run_check stale-receipt)"
expect "a receipt from another run does not count" "did not receive this run's message" "$out"

# 2 — the inbound message never arrives at the service.
setup inbound-missing
out="$(run_check inbound-missing)"
expect "a missing inbound message fails" "did not receive this run's message" "$out"
expect "and the failure names the inbound direction" "✗ FAIL" "$out"

# 3 — the Bridge never published it.
setup bridge-silent
: > "$WORK/bridge-silent/tcu/logcat"
out="$(run_check bridge-silent)"
expect "a silent Bridge fails" "did not publish the message" "$out"

# 4 — the outbound counter does not move.
setup outbound-stalled
out="$(run_check outbound-stalled no)"
expect "a stalled outbound direction fails" "forwarded nothing" "$out"

# 5 — the leaf refused a publish.
setup permissions
receipt "$WORK/permissions/app/logcat"   # otherwise healthy: only the violation differs
printf 'Permissions Violation for Publish to "pubsub.x.y"\n' > "$WORK/permissions/tcu/leaf.log"
out="$(run_check permissions)"
expect "a permissions violation fails" "the leaf refused" "$out"

# 6 — the platform refused an AuthZ request. The fixture is a real line, copied from the
# logcat of 2026-09-24: an invented one is how this check came to look for a phrase the
# platform never writes.
setup authz-violation
receipt "$WORK/authz-violation/app/logcat"   # otherwise healthy: only the violation differs
printf 'E SdvServiceManagerServer: sdv_authz::authz_service: Authz violation. instance2:com.example.Bundle/instance does not declare permission to access instance3:com.example.Other/instance#topic\n' >> "$WORK/authz-violation/app/logcat"
out="$(run_check authz-violation)"
expect "an authz violation fails" "the platform refused" "$out"

# 6b — adbd echoes into logcat every shell command it runs, including this check's own
# grep. Finding itself must not count as a violation.
setup adbd-echo
receipt "$WORK/adbd-echo/app/logcat"
printf 'I adbd    : adbd service requested %s\n' \
    "'shell,v2,TERM=unknown,raw:logcat -d | grep -ci Authz violation'" >> "$WORK/adbd-echo/app/logcat"
out="$(run_check adbd-echo)"
expect "the check does not find its own grep" "✓ PASS" "$out"

# 7 — AuthZ is off, so a PASS would prove nothing.
setup authz-off
echo false > "$WORK/authz-off/app/authz"
out="$(run_check authz-off)"
expect "authz disabled fails before anything else" "sdv.authz.enable=true" "$out"

# 8 — a link drop during the window is reported, not failed: delivery across a drop is
# explicitly not claimed.
setup with-drop
printf 'Leafnode connection closed: Read Error\n' > "$WORK/with-drop/tcu/leaf.log"
receipt "$WORK/with-drop/app/logcat"
out="$(run_check with-drop)"
expect "a link drop is noted, not failed" "link drop(s) recorded" "$out"
expect "and the run still passes" "✓ PASS" "$out"

# 9 — the VIN is the caller's to give: there is no vehicle the test could assume.
setup no-vin
out="$(PATH="$WORK:$PATH" TCU_ADB="adb -s tcu" APP_ADB="adb -s app" NEXUS_RT_MARKER="$MARKER" bash "$CHECK" 1 2>&1)"
expect "a run without NEXUS_VIN is refused and says so" "set NEXUS_VIN" "$out"

# 10 — the note on a link drop explains itself and names no document the reader lacks.
setup drop-note
printf 'Leafnode connection closed: Read Error\n' > "$WORK/drop-note/tcu/leaf.log"
receipt "$WORK/drop-note/app/logcat"
out="$(run_check drop-note)"
case "$out" in *".md"*) fail=$((fail + 1)); echo "  FAIL the note on a link drop names a document";; *) pass=$((pass + 1)); echo "  ok   the note on a link drop names no document";; esac

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
