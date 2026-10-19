#!/usr/bin/env bash
# Tests demo-sequence.sh against stand-ins for kubectl and curl — no cluster, no network.
# Run:  sample-services/aaos/tests/demo-sequence.test.sh
#
# Every case fixes one condition and asserts the outcome, including that the script can
# fail: a sequence that is refused must stop and say which step was refused.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../demo-sequence.sh"
WORK="$(mktemp -d)"
# Whatever a broken script leaves behind, the port-forward stand-ins do not outlive the test.
cleanup() {
    cat "$WORK"/pids* 2>/dev/null | while read -r p; do kill "$p" 2>/dev/null; done
    rm -rf "$WORK"
}
trap cleanup EXIT
mkdir -p "$WORK/bin"

# kubectl records its arguments; a port-forward records its PID and waits to be killed.
# The wait is bounded, so a script that forgets to kill it cannot leave it running for long.
cat > "$WORK/bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_ROOT/kubectl.log"
case " $* " in
  *" port-forward "*) echo "$$" >> "$FAKE_ROOT/pids"; exec /bin/sleep 30 ;;
esac
FAKE

# curl records the URL and the body it is given, and answers with $FAKE_CODE (default 202).
cat > "$WORK/bin/curl" <<'FAKE'
#!/usr/bin/env bash
url=""; body=""
while [ $# -gt 0 ]; do
  case "$1" in
    -d) body="$2"; shift 2 ;;
    -o|-w|-X|-H) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
# The readiness probe is not part of the sequence: answered from $FAKE_HEALTH_RC, not logged.
case "$url" in */health) exit "${FAKE_HEALTH_RC:-0}" ;; esac
echo "$url $body" >> "$FAKE_ROOT/curl.log"
# A curl that cannot connect prints 000 for %{http_code} and exits non-zero.
if [ "${FAKE_CURL_RC:-0}" -ne 0 ]; then printf '000'; exit "$FAKE_CURL_RC"; fi
printf '%s' "${FAKE_CODE:-202}"
FAKE
chmod +x "$WORK/bin/kubectl" "$WORK/bin/curl"

pass=0; fail=0
ok()   { echo "  ok   $1"; pass=$((pass + 1)); }
nok()  { echo "  FAIL $1"; [ -n "${2:-}" ] && echo "$2" | sed 's/^/       /'; fail=$((fail + 1)); }

# Runs the script with the stand-ins first on PATH, stdin closed so a prompt cannot hang,
# and a watchdog that kills it after 20 seconds. Sets $out and $rc.
run_demo() {
    local vin="$1" code="${2:-202}"
    rm -f "$WORK/kubectl.log" "$WORK/curl.log"
    PATH="$WORK/bin:$PATH" FAKE_ROOT="$WORK" FAKE_CODE="$code" \
        FAKE_CURL_RC="${FAKE_CURL_RC:-0}" FAKE_HEALTH_RC="${FAKE_HEALTH_RC:-0}" \
        NEXUS_DEMO_CONTEXT=ctx NEXUS_DEMO_VIN="$vin" NEXUS_DEMO_PAUSE=0 NEXUS_DEMO_FORWARD_WAIT=0 \
        NEXUS_DEMO_ROUNDS="${NEXUS_DEMO_ROUNDS:-}" \
        bash "$SCRIPT" < /dev/null > "$WORK/out" 2>&1 &
    local pid=$!
    ( /bin/sleep 20; kill "$pid" 2>/dev/null ) 2>/dev/null & local watchdog=$!
    wait "$pid"; rc=$?
    pkill -P "$watchdog" 2>/dev/null; kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
    out="$(cat "$WORK/out")"
}

# The port-forwards are gone once the script has ended. A killed process can take a moment
# to disappear, so this waits up to a second.
forwards_gone() {
    [ -f "$WORK/pids" ] || return 1
    local p i
    while read -r p; do
        for i in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$p" 2>/dev/null || continue 2
            /bin/sleep 0.1
        done
        return 1
    done < "$WORK/pids"
}

echo "demo-sequence.sh"

# 1 — the whole sequence, in order, each request to its service.
run_demo PKGTEST01
want='localhost:18082/v1/pressure-limit {"vin":"PKGTEST01","max_pressure":250}
localhost:18081/v1/commands {"vin":"PKGTEST01","action":"lock"}
localhost:18082/v1/pressure-limit {"vin":"PKGTEST01","max_pressure":230}
localhost:18081/v1/commands {"vin":"PKGTEST01","action":"unlock"}'
got="$(cat "$WORK/curl.log" 2>/dev/null)"
[ "$rc" -eq 0 ] && ok "a run where every step is accepted exits 0" || nok "a run where every step is accepted exits 0 (rc=$rc)" "$out"
[ "$got" = "$want" ] && ok "the four requests are sent in order" || nok "the four requests are sent in order" "$got"
grep -q -- '--context ctx -n sample-services port-forward svc/pressure-monitor 18082:8080' "$WORK/kubectl.log" 2>/dev/null \
    && grep -q -- '--context ctx -n sample-services port-forward svc/door-control 18081:8080' "$WORK/kubectl.log" \
    && ok "both port-forwards use the given context" || nok "both port-forwards use the given context" "$(cat "$WORK/kubectl.log" 2>/dev/null)"
[ "$(wc -l < "$WORK/pids" 2>/dev/null | tr -d ' ')" = 2 ] && forwards_gone \
    && ok "both port-forwards are gone after the script ends" || nok "both port-forwards are gone after the script ends"
mv "$WORK/pids" "$WORK/pids.case1" 2>/dev/null

# 2 — a VIN that is not [A-Z0-9]{1,17} is refused before anything is opened or sent.
run_demo 'pkg.1'
[ "$rc" -ne 0 ] && ok "an invalid VIN exits non-zero" || nok "an invalid VIN exits non-zero" "$out"
[ ! -s "$WORK/curl.log" ] && [ ! -s "$WORK/kubectl.log" ] \
    && ok "an invalid VIN sends nothing and opens no port-forward" || nok "an invalid VIN sends nothing and opens no port-forward"
echo "$out" | grep -q 'A-Z0-9' && ok "the refusal says what a VIN must be" || nok "the refusal says what a VIN must be" "$out"

# 3 — a refused step stops the sequence and is named.
run_demo PKGTEST01 400
[ "$rc" -ne 0 ] && ok "a step answered 400 exits non-zero" || nok "a step answered 400 exits non-zero" "$out"
echo "$out" | grep -q 'limit 250 was not accepted (400)' && ok "the refused step is named" || nok "the refused step is named" "$out"
[ "$(wc -l < "$WORK/curl.log" 2>/dev/null | tr -d ' ')" = 1 ] && ok "nothing is sent after the refused step" || nok "nothing is sent after the refused step" "$(cat "$WORK/curl.log" 2>/dev/null)"
forwards_gone && ok "the port-forwards are gone after a failed run too" || nok "the port-forwards are gone after a failed run too"

# 4 — a port-forward that never comes up is said so, before anything is sent.
FAKE_HEALTH_RC=7 run_demo PKGTEST01
[ "$rc" -ne 0 ] && ok "no port-forward exits non-zero" || nok "no port-forward exits non-zero" "$out"
echo "$out" | grep -q 'no port-forward to pressure-monitor' && ok "and names the service it could not reach" || nok "and names the service it could not reach" "$out"
[ ! -s "$WORK/curl.log" ] && ok "and sends nothing" || nok "and sends nothing" "$(cat "$WORK/curl.log" 2>/dev/null)"

# 5 — a connection that fails mid-sequence names the step instead of dying silently.
FAKE_CURL_RC=7 run_demo PKGTEST01
[ "$rc" -ne 0 ] && ok "a failed connection exits non-zero" || nok "a failed connection exits non-zero" "$out"
echo "$out" | grep -q 'limit 250 was not accepted (000)' && ok "and the step is named" || nok "and the step is named" "$out"

# 6 — several rounds repeat the four requests, so a watcher has something to watch.
NEXUS_DEMO_ROUNDS=3 run_demo PKGTEST01
[ "$rc" -eq 0 ] && ok "three rounds exit 0" || nok "three rounds exit 0 (rc=$rc)" "$out"
[ "$(wc -l < "$WORK/curl.log" 2>/dev/null | tr -d ' ')" = 12 ] && ok "three rounds send twelve requests" || nok "three rounds send twelve requests" "$(cat "$WORK/curl.log" 2>/dev/null)"
echo "$out" | grep -q 'round 3 of 3' && ok "each round is announced" || nok "each round is announced" "$out"

# 7 — a number of rounds that is not 1 to 99 is refused before anything is opened or sent.
for bad in 0 x 100 -1; do
    NEXUS_DEMO_ROUNDS="$bad" run_demo PKGTEST01
    [ "$rc" -ne 0 ] && [ ! -s "$WORK/curl.log" ] && [ ! -s "$WORK/kubectl.log" ] \
        && ok "rounds=$bad is refused and nothing is sent" || nok "rounds=$bad is refused and nothing is sent (rc=$rc)" "$out"
done

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
