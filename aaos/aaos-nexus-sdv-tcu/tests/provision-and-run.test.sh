#!/usr/bin/env bash
# Tests provision-and-run.sh against stand-ins for adb, curl and getent — no device, no
# cloud. The point: the configuration lands in the run directory as a file, the service is
# started by init through the property, and the operator's secret goes nowhere near the guest.
# Run:  aaos/aaos-nexus-sdv-tcu/tests/provision-and-run.test.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; failed=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { failed=$((failed+1)); echo "FAIL $1"; }

# The stand-ins write to FAKE_DIR, not WORK: the script under test sets WORK for itself.
# The script under test, with a passing stand-in for the acceptance check beside it.
mkdir -p "$WORK/pkg" "$WORK/bin" "$WORK/pushed"
cp "$HERE/../provision-and-run.sh" "$WORK/pkg/"
printf '#!/bin/sh\necho "check-leaf-connection stand-in"\n' > "$WORK/pkg/check-leaf-connection.sh"
chmod +x "$WORK/pkg/"*.sh

cat > "$WORK/bin/adb" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/adb.calls"
[ "${1:-}" = "-s" ] && shift 2
case "${1:-}" in
  push) cp "$2" "$FAKE_DIR/pushed/$(basename "$3")" 2>/dev/null || cp "$2" "$FAKE_DIR/pushed/"; exit 0 ;;
  shell)
    shift
    case "$*" in
      *"ip -o -4 addr"*) echo "3: eth1    inet 192.168.98.4/24 brd 192.168.98.255 scope global eth1" ;;
      *"echo started"*) echo started ;;
    esac
    exit 0 ;;
esac
exit 0
FAKE
cat > "$WORK/bin/curl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/curl.calls"
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
# The login and the identity first: both name KEYCLOAK_TLS_CRT.pem in --cacert too.
case "$*" in
  *openid-connect/token*) echo '{"access_token":"tok-123"}'; exit 0 ;;
  *factory-certificates*)
    echo '{"certificate":"CERT","ca_certificate_chain":"CHAIN","private_key":"KEY"}'; exit 0 ;;
  *NATS_LEAF_TLS_CA.pem*|*KEYCLOAK_TLS_CRT.pem*|*REGISTRATION_SERVER_TLS_CERT.pem*)
    [ -n "$out" ] && echo "-----BEGIN CERTIFICATE-----" > "$out"; exit 0 ;;
esac
exit 0
FAKE
printf '#!/bin/sh\necho "10.0.0.7 $1"\n' > "$WORK/bin/getent"
chmod +x "$WORK/bin/"*

SECRET="s3cr3t-operator-value"
PATH="$WORK/bin:$PATH" FAKE_DIR="$WORK" ADB_BIN="$WORK/bin/adb" \
  FACTORY_OPERATOR_CLIENT_SECRET="$SECRET" FACTORY_CLIENT_ID=factory-operator-test PKI_BUCKET_PROJECT=test \
  bash "$WORK/pkg/provision-and-run.sh" PKGTEST01 example.org 0.0.0.0:6522 > "$WORK/out.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "the script completes" || { bad "the script completes (exit $rc)"; tail -5 "$WORK/out.log"; }

ENVF="$WORK/pushed/nexus.env"
if [ -f "$ENVF" ]; then
  ok "nexus.env is pushed"
  for kv in NEXUS_VIN=PKGTEST01 NEXUS_RUN_DIR=/data/misc/nexus NEXUS_LOG_FILE=/data/misc/nexus/agent.log \
            NEXUS_LEAF_CONF=/data/misc/nexus/leaf.conf NEXUS_LEAF_LOG=/data/misc/nexus/nats-leaf.log \
            NEXUS_CLOUD_NATS_HOST=10.0.0.7; do
    grep -qxF "$kv" "$ENVF" && ok "nexus.env has $kv" || bad "nexus.env has $kv"
  done
  bad_lines="$(grep -v '^#' "$ENVF" | grep -v '^$' | grep -cv '^NEXUS_[A-Z0-9_]*=')"
  [ "$bad_lines" = 0 ] && ok "every line of nexus.env is KEY=VALUE" || bad "every line of nexus.env is KEY=VALUE ($bad_lines not)"
else
  bad "nexus.env is pushed"
fi
grep -q 'push .*nexus.env /data/misc/nexus/nexus.env' "$WORK/adb.calls" && ok "it goes to /data/misc/nexus" || bad "it goes to /data/misc/nexus"
grep -q 'chown -R system:system /data/misc/nexus' "$WORK/adb.calls" && ok "the run directory is handed to system" || bad "the run directory is handed to system"
grep -q 'restorecon -R /data/misc/nexus' "$WORK/adb.calls" && ok "the run directory is relabelled" || bad "the run directory is relabelled"
grep -q 'stop nexus_connectivity_agent' "$WORK/adb.calls" && ok "the waiting service is stopped first" || bad "the waiting service is stopped first"
grep -q 'start nexus_connectivity_agent' "$WORK/adb.calls" && ok "the service is started" || bad "the service is started"
grep -q 'nohup' "$WORK/adb.calls" && bad "no nohup launch any more" || ok "no nohup launch any more"
if grep -rqF "$SECRET" "$WORK/adb.calls" "$WORK/pushed"; then bad "the secret never reaches the guest"; else ok "the secret never reaches the guest"; fi

# The telemetry client's switch: untouched by default, set off on request, anything else refused.
grep -q 'persist.nexus.telemetry_client.enabled' "$WORK/adb.calls" \
  && bad "by default the telemetry client's switch is left alone" || ok "by default the telemetry client's switch is left alone"
run_with_switch() {   # run_with_switch <value>: sets $rc
    rm -f "$WORK/adb.calls"
    PATH="$WORK/bin:$PATH" FAKE_DIR="$WORK" ADB_BIN="$WORK/bin/adb" NEXUS_TELEMETRY_CLIENT="$1" \
      FACTORY_OPERATOR_CLIENT_SECRET="$SECRET" PKI_BUCKET_PROJECT=test \
      bash "$WORK/pkg/provision-and-run.sh" PKGTEST01 example.org 0.0.0.0:6522 > "$WORK/out.log" 2>&1
    rc=$?
}
run_with_switch off
[ "$rc" -eq 0 ] && grep -q 'setprop persist.nexus.telemetry_client.enabled false' "$WORK/adb.calls" \
  && ok "NEXUS_TELEMETRY_CLIENT=off switches the client off" || bad "NEXUS_TELEMETRY_CLIENT=off switches the client off (exit $rc)"
run_with_switch on
[ "$rc" -eq 0 ] && grep -q 'setprop persist.nexus.telemetry_client.enabled true' "$WORK/adb.calls" \
  && ok "NEXUS_TELEMETRY_CLIENT=on switches it on again" || bad "NEXUS_TELEMETRY_CLIENT=on switches it on again (exit $rc)"
run_with_switch maybe
[ "$rc" -eq 2 ] && [ ! -s "$WORK/adb.calls" ] && grep -q 'NEXUS_TELEMETRY_CLIENT' "$WORK/out.log" \
  && ok "any other value is refused before the guest is touched" || bad "any other value is refused before the guest is touched (exit $rc)"

echo "$pass passed, $failed failed"; [ "$failed" -eq 0 ]
