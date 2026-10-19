#!/usr/bin/env bash
# Tests mesh-start.sh against stand-ins for sudo, adb and the launch — no Cuttlefish host.
# Run:  aaos/test-environment/tests/mesh-start.test.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../mesh-start.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; failed=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { failed=$((failed+1)); echo "FAIL $1"; [ -n "${2:-}" ] && echo "$2" | sed 's/^/     /'; }

mkdir -p "$WORK/bin"
# sudo records its arguments. "iptables -C" answers with $FAKE_RULES_PRESENT (0 = the rule
# exists, 1 = it does not), so both a fresh host and a second run can be played.
cat > "$WORK/bin/sudo" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_ROOT/sudo.log"
case "$*" in *" -C "*) exit "${FAKE_RULES_PRESENT:-1}" ;; esac
exit 0
FAKE
# adb answers what a guest would. A guest in $FAKE_NEVER_BOOTS never reports boot_completed;
# the route the connectivity guest reports is $FAKE_ROUTE.
cat > "$WORK/bin/adb" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_ROOT/adb.log"
serial=""; [ "$1" = "-s" ] && { serial="$2"; shift 2; }
case "$*" in
  "shell getprop sys.boot_completed") [ "$serial" = "${FAKE_NEVER_BOOTS:-}" ] || echo 1 ;;
  "shell ip route") printf '%s\n192.168.98.0/24 dev eth1\n' "${FAKE_ROUTE-default via 192.168.98.1 dev eth1}" ;;
  "shell getprop ro.boot.sdv.instance_name") echo "instance-$serial" ;;
esac
exit 0
FAKE
cat > "$WORK/bin/launch" <<'FAKE'
#!/usr/bin/env bash
echo launched >> "$FAKE_ROOT/launch.log"; exit "${FAKE_LAUNCH_RC:-0}"
FAKE
chmod +x "$WORK/bin/"*

run() {
    rm -f "$WORK"/*.log
    PATH="$WORK/bin:$PATH" FAKE_ROOT="$WORK" NEXUS_ADB=adb NEXUS_LAUNCH="$WORK/bin/launch" \
        NEXUS_GUESTS="g1 g2 g3" NEXUS_CONNECTIVITY=g3 NEXUS_BOOT_WAIT=0 NEXUS_POLL=0 \
        bash "$SCRIPT" > "$WORK/out" 2>&1 < /dev/null
    rc=$?; out="$(cat "$WORK/out")"
}

# 1 — a fresh host: every rule is added, the mesh launched, the route set on the right guest.
run
[ "$rc" -eq 0 ] && ok "a mesh that comes up exits 0" || bad "a mesh that comes up exits 0 (rc=$rc)" "$out"
[ "$(grep -c -- ' -A \| -I ' "$WORK/sudo.log")" -eq 3 ] && ok "the three missing rules are added" || bad "the three missing rules are added" "$(cat "$WORK/sudo.log")"
grep -q 'sysctl -w net.ipv4.ip_forward=1' "$WORK/sudo.log" && ok "forwarding is switched on" || bad "forwarding is switched on"
[ -s "$WORK/launch.log" ] && ok "the mesh is launched" || bad "the mesh is launched"
grep -q -- '-s g3 shell ip route replace default via 192.168.98.1 dev eth1' "$WORK/adb.log" \
    && ok "the route is set on the connectivity guest" || bad "the route is set on the connectivity guest" "$(cat "$WORK/adb.log")"
! grep -q -- '-s g[12] shell ip route replace' "$WORK/adb.log" && ok "and on no other guest" || bad "and on no other guest"
echo "$out" | grep -q '✓ mesh up' && ok "the end says so" || bad "the end says so" "$out"

# 2 — a second run on a host whose rules are in place adds nothing.
FAKE_RULES_PRESENT=0 run
[ "$rc" -eq 0 ] && ! grep -q -- ' -A \| -I ' "$WORK/sudo.log" \
    && ok "rules already in place are not added twice" || bad "rules already in place are not added twice" "$(cat "$WORK/sudo.log")"

# 3 — a guest that never boots is named, and nothing is done to the route.
FAKE_NEVER_BOOTS=g2 run
[ "$rc" -ne 0 ] && ok "a guest that does not boot fails the run" || bad "a guest that does not boot fails the run" "$out"
echo "$out" | grep -q 'g2 did not finish booting' && ok "and is named" || bad "and is named" "$out"
! grep -q 'ip route replace' "$WORK/adb.log" && ok "and the route is not touched" || bad "and the route is not touched"

# 4 — a route that does not show up afterwards fails the run and says what was there.
FAKE_ROUTE="" run
[ "$rc" -ne 0 ] && echo "$out" | grep -q 'no default route via 192.168.98.1 on g3' \
    && ok "a missing default route fails the run" || bad "a missing default route fails the run" "$out"

# 5 — a launch that fails stops the run before any waiting.
FAKE_LAUNCH_RC=1 run
[ "$rc" -ne 0 ] && echo "$out" | grep -q 'the launch command failed' && ! [ -s "$WORK/adb.log" ] \
    && ok "a failed launch stops the run" || bad "a failed launch stops the run" "$out"

# 6 — a waiting time that is not a number is refused before anything is done.
rm -f "$WORK"/*.log
PATH="$WORK/bin:$PATH" FAKE_ROOT="$WORK" NEXUS_ADB=adb NEXUS_LAUNCH="$WORK/bin/launch" NEXUS_BOOT_WAIT=soon \
    bash "$SCRIPT" > "$WORK/out" 2>&1 < /dev/null; rc=$?
[ "$rc" -eq 2 ] && ! [ -s "$WORK/sudo.log" ] && ok "NEXUS_BOOT_WAIT=soon is refused" || bad "NEXUS_BOOT_WAIT=soon is refused (rc=$rc)" "$(cat "$WORK/out")"

echo
echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
