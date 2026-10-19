#!/usr/bin/env bash
# Tests registry-test.sh against a stand-in for adb and for the four commands the tester
# supplies — no device, no cluster. Run:  aaos/aaos-nexus-sdv-tcu/tests/registry-test.test.sh
#
# The point is that the proof can FAIL, and fails for the right reason: pressure at the hub
# while the grant is closed, a silent pipe whose silence would pass for "closed", a grant
# that changes nothing, a command through a closed channel.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/../registry-test.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The stand-in answers from files in $FAKE_ROOT — the same one round-trip-test.test.sh uses.
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
  *"forwarded "*)
    n="$(cat "$root/forwarded" 2>/dev/null || echo 100)"
    [ "$(cat "$root/grow" 2>/dev/null)" = yes ] && { n=$((n + 100)); echo "$n" > "$root/forwarded"; }
    echo "$n"; exit 0 ;;
esac
cmd="${cmd//\/data\/misc\/nexus\/agent.log/$root/agent.log}"
cmd="${cmd//\/data\/misc\/nexus\/nats-leaf.log/$root/leaf.log}"
eval "$cmd"
FAKE
chmod +x "$WORK/adb"

pass=0; fail=0
VIN=PKG11MESH01

# A case: healthy fixtures, which each test then breaks on purpose. The four commands are
# scripts in the case directory; a case rewrites the ones it wants to misbehave.
setup() {
    local name="$1"
    rm -rf "$WORK/$name"; mkdir -p "$WORK/$name/tcu" "$WORK/$name/app"
    printf 'leaf status: link=up links=1 grant=none\n' > "$WORK/$name/tcu/agent.log"
    : > "$WORK/$name/tcu/leaf.log"
    : > "$WORK/$name/tcu/logcat"
    : > "$WORK/$name/app/logcat"
    echo 100 > "$WORK/$name/tcu/forwarded"
    echo yes > "$WORK/$name/tcu/grow"
    # The restart empties the logs (as provision-and-run.sh does); the leaf comes up with an
    # empty grant.
    cat > "$WORK/$name/restart-cmd" <<'CMD'
printf 'leaf status: link=up links=1 grant=none\n' > "$FAKE_ROOT/tcu/agent.log"
: > "$FAKE_ROOT/tcu/leaf.log"
CMD
    # The grant command: the vehicle reports the change and the new status.
    cat > "$WORK/$name/grant-cmd" <<'CMD'
printf 'grant changed: pub=1 sub=1 — re-establishing the upstream connection\nleaf status: link=up links=1 grant=pub:1 sub:1\n' >> "$FAKE_ROOT/tcu/agent.log"
CMD
    # The hub publish: nothing arrives while the grant holds no subscription.
    cat > "$WORK/$name/hub-pub-cmd" <<'CMD'
printf '%s\n' "$1" >> "$FAKE_ROOT/hub-pub-args"
if grep -q 'grant=pub:1 sub:1' "$FAKE_ROOT/tcu/agent.log"; then
  printf 'nexus-bridge: published topic=pressure-limit\n' >> "$FAKE_ROOT/tcu/logcat"
  # The vehicle side as the service logs it: the PressureLimit decoded (08, then a
  # two-byte varint), its max_pressure in the line.
  set -- $(printf "$1" | od -An -tu1)
  printf 'I sdv_lm_pressure_advisor: pressure-advisor: max_pressure=%s\n' $(( ($2 & 127) | ($3 << 7) )) >> "$FAKE_ROOT/app/logcat"
fi
true
CMD
    # The hub subscriber: called with seconds, prints how many pressure messages arrived —
    # none while the grant is closed, some once it is open.
    cat > "$WORK/$name/hub-sub-cmd" <<'CMD'
if grep -q 'grant=pub:1' "$FAKE_ROOT/tcu/agent.log"; then echo 15; else echo 0; fi
CMD
}

run() {
    local name="$1"
    FAKE_ROOT="$WORK/$name" PATH="$WORK:$PATH" TCU_ADB="adb -s tcu" APP_ADB="adb -s app" \
    NEXUS_VIN="$VIN" NEXUS_RT_MARKER=6200 NEXUS_GRANT_WAIT=2 NEXUS_SETTLE=0 NEXUS_DELIVERY_WAIT=2 \
    NEXUS_SUB_SECONDS=1 \
    NEXUS_RESTART_CMD="FAKE_ROOT=$WORK/$name bash $WORK/$name/restart-cmd" \
    NEXUS_GRANT_CMD="FAKE_ROOT=$WORK/$name bash $WORK/$name/grant-cmd" \
    NEXUS_HUB_PUB_CMD="FAKE_ROOT=$WORK/$name bash $WORK/$name/hub-pub-cmd" \
    NEXUS_HUB_SUB_CMD="FAKE_ROOT=$WORK/$name bash $WORK/$name/hub-sub-cmd" \
        bash "$CHECK" 1 2>&1
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

# Runs the check with NEXUS_HUB_SUB_CMD set to an exported bash function named hub_count —
# the exact name TESTING.md's documented tester uses. Bounded by a process-group kill: an
# unfixed script that names its own helper the same way recurses without end when the
# names collide, forking until the kernel refuses (bash 3.2: "fork: Resource temporarily
# unavailable"). The driver is a real file, not a heredoc fed to a child bash on stdin —
# set -m misbehaves there on bash 3.2 (a spurious "syntax error" after the job already
# ran). set -m gives the background job its own process group so the whole recursion tree
# can be killed by its negative pid; ulimit -u is set on the job itself, before it execs
# the check, so it — and everything it forks — inherits the cap.
run_exported_collision() {
    local name="$1"
    local driver="$WORK/$name/driver.sh"
    cat > "$driver" <<DRIVER
set -m
hub_count() { if grep -q 'grant=pub:1' "\$FAKE_ROOT/tcu/agent.log"; then echo 15; else echo 0; fi; }
export -f hub_count
( ulimit -u \$(( \$(ps -U "\$(id -un)" | wc -l) + 150 )); FAKE_ROOT="$WORK/$name" PATH="$WORK:\$PATH" TCU_ADB="adb -s tcu" APP_ADB="adb -s app" NEXUS_VIN="$VIN" NEXUS_RT_MARKER=6200 NEXUS_GRANT_WAIT=2 NEXUS_SETTLE=0 NEXUS_DELIVERY_WAIT=2 NEXUS_SUB_SECONDS=1 NEXUS_RESTART_CMD="FAKE_ROOT=$WORK/$name bash $WORK/$name/restart-cmd" NEXUS_GRANT_CMD="FAKE_ROOT=$WORK/$name bash $WORK/$name/grant-cmd" NEXUS_HUB_PUB_CMD="FAKE_ROOT=$WORK/$name bash $WORK/$name/hub-pub-cmd" NEXUS_HUB_SUB_CMD=hub_count exec bash "$CHECK" 1 ) > "$WORK/$name/out.log" 2>&1 </dev/null &
pid=\$!
( sleep 8; kill -9 -- -\$pid ) 2>/dev/null &
watcher=\$!
wait "\$pid" 2>/dev/null
kill "\$watcher" 2>/dev/null
wait "\$watcher" 2>/dev/null
DRIVER
    bash "$driver" >/dev/null 2>&1
    cat "$WORK/$name/out.log" 2>/dev/null
}

echo "registry-test.sh"

# 1 — everything as spec section 6 describes.
setup pass
out="$(run pass)"
expect "a healthy run passes" "✓ PASS" "$out"
expect "and shows the closed hub subscriber" "a hub subscriber received 0 pressure message(s) in 1s" "$out"
expect "and the open one" "a hub subscriber received 15 pressure message(s) in 1s" "$out"
# The two hub publishes: PressureLimit{max_pressure: 6200} closed and 6201 open, bytes
# 08 b8 30 and 08 b9 30 (protoc --encode of the catalog's nexus_sample.proto). They travel
# as printf octal escapes, plain ASCII: kubectl exec refuses arguments that are not UTF-8.
expect "the closed-phase payload is the encoded PressureLimit 6200, as octal escapes" '^\\010\\270\\060$' "$(sed -n 1p "$WORK/pass/hub-pub-args" 2>/dev/null)"
expect "the open-phase payload is 6201" '^\\010\\271\\060$' "$(sed -n 2p "$WORK/pass/hub-pub-args" 2>/dev/null)"

# 2 — pressure reaches the hub although the grant is closed.
setup leakatthehub
echo 'echo 3' > "$WORK/leakatthehub/hub-sub-cmd"
out="$(run leakatthehub)"
expect "pressure at the hub while closed fails" "pressure message(s) while the channel was closed" "$out"

# 3 — a silent pipe: nothing reaches the hub, ever. (a)'s silence must not pass alone.
setup silent
echo 'echo 0' > "$WORK/silent/hub-sub-cmd"
out="$(run silent)"
expect "a silent pipe fails in (c)" "so (a)'s silence proves nothing" "$out"

# 4 — the link is down: the first cause is the link.
setup nolink
cat > "$WORK/nolink/restart-cmd" <<'CMD'
printf 'leaf status: link=down links=0 grant=none\n' > "$FAKE_ROOT/tcu/agent.log"
CMD
out="$(run nolink)"
expect "a leaf without a link names the link as the first cause" "holds no link to the hub" "$out"

# 5 — the grant command changes nothing visible.
setup noreconnect
echo 'true' > "$WORK/noreconnect/grant-cmd"
out="$(run noreconnect)"
expect "no reconnect after the grant fails" "did not report a grant change within" "$out"

# 6 — a command arrives although the channel is closed.
setup leak
cat > "$WORK/leak/hub-pub-cmd" <<'CMD'
set -- $(printf "$1" | od -An -tu1)
printf 'I sdv_lm_pressure_advisor: pressure-advisor: max_pressure=%s\n' $(( ($2 & 127) | ($3 << 7) )) >> "$FAKE_ROOT/app/logcat"
CMD
out="$(run leak)"
expect "a marker through a closed channel fails" "although the channel was closed" "$out"

# 7 — a stray number in otherwise unreadable output must not be read as a count.
setup unreadable
echo 'echo "timeout: no response (attempt 42)"' > "$WORK/unreadable/hub-sub-cmd"
out="$(run unreadable)"
expect "unreadable output fails, not as a stray count" "unreadable count instead of a number" "$out"

# 8 — the critical collision (F41 follow-up): the documented tester function (TESTING.md)
# is named hub_count; an exported bash function of that name must not recurse.
setup exportedcollision
out="$(run_exported_collision exportedcollision)"
expect "an exported tester function named hub_count does not recurse" "✓ PASS" "$out"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
