#!/usr/bin/env bash
# The demonstration's cloud side: a pressure limit and door commands to one vehicle,
# through pressure-monitor and door-control. Both are cluster-internal, so the script
# opens a port-forward to each and closes them when it ends.
#   ./demo-sequence.sh        prompts for the kubectl context and the VIN
#   NEXUS_DEMO_ROUNDS=5 ./demo-sequence.sh    sends the four messages five times — with the
#                                             pause of three seconds, about a minute to watch
set -euo pipefail
CTX="${NEXUS_DEMO_CONTEXT:-}"; VIN="${NEXUS_DEMO_VIN:-}"; PAUSE="${NEXUS_DEMO_PAUSE:-3}"
ROUNDS="${NEXUS_DEMO_ROUNDS:-1}"
[[ "$ROUNDS" =~ ^[1-9][0-9]?$ ]] || { echo "NEXUS_DEMO_ROUNDS must be a number from 1 to 99" >&2; exit 1; }
[ -n "$CTX" ] || read -rp "kubectl context: " CTX
[ -n "$VIN" ] || read -rp "VIN: " VIN
[[ "$VIN" =~ ^[A-Z0-9]{1,17}$ ]] || { echo "the VIN must match [A-Z0-9]{1,17}" >&2; exit 1; }

kubectl --context "$CTX" -n sample-services port-forward svc/pressure-monitor 18082:8080 >/dev/null 2>&1 & PF1=$!
kubectl --context "$CTX" -n sample-services port-forward svc/door-control 18081:8080 >/dev/null 2>&1 & PF2=$!
trap 'kill $PF1 $PF2 2>/dev/null || true' EXIT
# A port-forward takes a moment and can fail without a word (wrong context, port in use):
# ask each service's /health until it answers, and say which one never did.
wait_ready() {   # wait_ready <service> <port>
    local t=0
    until curl -s -o /dev/null --max-time 2 "localhost:$2/health"; do
        [ "$t" -ge "${NEXUS_DEMO_FORWARD_WAIT:-10}" ] && {
            echo "✗ no port-forward to $1 on localhost:$2 — check the context '$CTX' and that the port is free" >&2
            exit 1
        }
        sleep 1; t=$((t + 1))
    done
}
wait_ready pressure-monitor 18082
wait_ready door-control 18081

send() {   # send <step name> <port> <path> <json>
    local code
    # `|| true`: a connection that fails must reach the message below, not end the script here.
    code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "localhost:$2$3" -H 'content-type: application/json' -d "$4" || true)"
    echo "$1: $code"
    [ "$code" = 202 ] || { echo "✗ $1 was not accepted ($code)" >&2; exit 1; }
    sleep "$PAUSE"
}
for round in $(seq 1 "$ROUNDS"); do
    [ "$ROUNDS" -gt 1 ] && echo "round $round of $ROUNDS"
    send "limit 250"   18082 /v1/pressure-limit "{\"vin\":\"$VIN\",\"max_pressure\":250}"
    send "door lock"   18081 /v1/commands       "{\"vin\":\"$VIN\",\"action\":\"lock\"}"
    send "limit 230"   18082 /v1/pressure-limit "{\"vin\":\"$VIN\",\"max_pressure\":230}"
    send "door unlock" 18081 /v1/commands       "{\"vin\":\"$VIN\",\"action\":\"unlock\"}"
done
echo "✓ sequence sent — on Core: logcat | grep -E 'pressure-advisor|door-controller'"
