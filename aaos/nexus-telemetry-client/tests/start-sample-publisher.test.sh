#!/usr/bin/env bash
# Tests start-sample-publisher.sh against a stand-in for adb — no device needed.
# Run:  aaos/nexus-telemetry-client/tests/start-sample-publisher.test.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../start-sample-publisher.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; failed=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { failed=$((failed+1)); echo "FAIL $1"; }

# The stand-in: `pidof` answers a PID once the number of starts so far has reached
# $STAYS_FROM (0: it runs already; 99: never); every start is counted in a file.
cat > "$WORK/adb" <<'FAKE'
#!/usr/bin/env bash
[ "${1:-}" = "shell" ] || exit 0
shift
starts="$(cat "$FAKE_DIR/starts" 2>/dev/null || echo 0)"
case "$*" in
    pidof*) [ "$starts" -ge "$STAYS_FROM" ] && echo 4711 ;;
    *nexus_telemetry_client*) echo "$* at start $starts" >> "$FAKE_DIR/client"
        case "$*" in start*)
            n="$(cat "$FAKE_DIR/kills" 2>/dev/null || echo 0)"
            if [ "$n" -lt "${DIES_ON_CLIENT:-0}" ]; then echo $((n + 1)) > "$FAKE_DIR/kills"; echo 0 > "$FAKE_DIR/starts"; fi ;;
        esac ;;
    *telemetry_sample_publisher*) echo $((starts + 1)) > "$FAKE_DIR/starts" ;;
esac
FAKE
chmod +x "$WORK/adb"
run() {   # run <stays from start n>
    rm -f "$WORK/starts" "$WORK/client" "$WORK/kills"
    out="$(FAKE_DIR="$WORK" STAYS_FROM="$1" ADB="$WORK/adb" PUBLISHER_START_WAIT=0 bash "$SCRIPT" 2>&1)"; rc=$?
    starts="$(cat "$WORK/starts" 2>/dev/null || echo 0)"
}

run 0
[ "$rc" -eq 0 ] && [ "$starts" = 0 ] && ok "a running publisher is left alone" || bad "a running publisher is left alone ($rc, $starts starts)"
run 1
[ "$rc" -eq 0 ] && [ "$starts" = 1 ] && ok "a publisher that stays up at once is started once" || bad "a publisher that stays up at once is started once ($rc, $starts starts)"
run 2
[ "$rc" -eq 0 ] && [ "$starts" = 2 ] && printf '%s' "$out" | grep -q 'start 2 of 6' \
  && ok "a publisher that aborts on its first start is started again" || bad "a publisher that aborts on its first start is started again ($rc, $starts starts)"
run 99
[ "$rc" -ne 0 ] && [ "$starts" = 6 ] && printf '%s' "$out" | grep -q 'did not stay up after 6 starts' \
  && ok "after six starts it gives up and says where to look" || bad "after six starts it gives up and says where to look ($rc, $starts starts)"
# On Core3 a waiting configuration made every start abort (2026-10-16): the client is stopped
# before the publisher is started, and started again afterwards — also when it gave up.
grep -qx 'stop nexus_telemetry_client at start 0' "$WORK/client" 2>/dev/null && grep -qx 'start nexus_telemetry_client at start 6' "$WORK/client" \
  && ok "the client is stopped first and started again after giving up" || bad "the client is stopped first and started again after giving up ($(cat "$WORK/client" 2>/dev/null))"
run 4
[ "$rc" -eq 0 ] && grep -qx 'stop nexus_telemetry_client at start 0' "$WORK/client" 2>/dev/null && grep -qx 'start nexus_telemetry_client at start 4' "$WORK/client" \
  && ok "the client is started again once the publisher stays up" || bad "the client is started again once the publisher stays up ($(cat "$WORK/client" 2>/dev/null))"
# On Core3 the publisher also aborted once the client started again (2026-10-16): the script
# checks after the client's start and goes round again.
DIES_ON_CLIENT=1 run 1
[ "$rc" -eq 0 ] && [ "$(grep -c '^start nexus_telemetry_client' "$WORK/client")" = 2 ] && printf '%s' "$out" | grep -q 'round 2' \
  && ok "a publisher that dies when the client starts is caught and started again" || bad "a publisher that dies when the client starts is caught and started again ($rc; $(cat "$WORK/client" 2>/dev/null | tr '\n' ';'))"
DIES_ON_CLIENT=9 run 1
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'did not survive the client' \
  && ok "after three rounds it gives up and says so" || bad "after three rounds it gives up and says so ($rc)"
run 0
[ ! -s "$WORK/client" ] && ok "a running publisher leaves the client alone" || bad "a running publisher leaves the client alone"
out="$(bash "$SCRIPT" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'set ADB' && ok "without ADB it says what to set" || bad "without ADB it says what to set"

echo "$pass passed, $failed failed"; [ "$failed" -eq 0 ]
