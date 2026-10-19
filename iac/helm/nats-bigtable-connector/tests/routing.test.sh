#!/usr/bin/env bash
# Runs the connector's real pipeline — the chart's rendered configuration, in the image the
# chart deploys — on sample messages, and reads the rows it would write to BigTable. Only the
# input (NATS) and the output (BigTable) are replaced.
#
# What it covers: each subject family reaches its decoder, the vehicle is read from the right
# token, both senders of Google's SDV report produce the same columns, a value of zero is
# written, and the subjects of before 2026-10-09 are still accepted.
#
# Needs: helm, protoc, docker (pulls the connector's image once).
#   ./routing.test.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="$HERE/.."
PROTO="$HERE/../../../../proto"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; }

IMAGE="$(sed -n 's/^  repository: *//p' "$CHART/values.yaml" | head -n 1):$(sed -n 's/^  tag: *"\(.*\)"/\1/p' "$CHART/values.yaml" | head -n 1)"
helm template t "$CHART" --show-only templates/configmap-template.yaml 2>/dev/null \
  | awk 'f{sub(/^    /,""); print} /^  config.yaml: \|/{f=1}' > "$WORK/rendered.yaml"
awk '/^pipeline:/{f=1} /^output:/{f=0} f' "$WORK/rendered.yaml" > "$WORK/pipeline.yaml"
[ -s "$WORK/pipeline.yaml" ] || { echo "the chart rendered no pipeline"; exit 1; }
mkdir -p "$WORK/proto"; cp "$PROTO"/*.proto "$WORK/proto/"

encode() {   # encode <message type> <text format> <out file>
    printf '%s' "$2" | protoc --proto_path="$PROTO" --encode="$1" \
        metrics_report.proto vehicle_telemetry.proto aaos_vehicle_telemetry.proto display_safety.proto telemetry.proto > "$3"
}
rows() {     # rows <subject> <message file>: the rows the pipeline produces, one JSON per line
    # A directory of its own per run: a file rewritten under the same name can reach the
    # container stale through Docker's file sharing (seen on macOS, 2026-10-09).
    local run out; run="$(mktemp -d "$WORK/run.XXXXXX")"; chmod 755 "$run"
    cp "$2" "$run/msg.bin"
    {
        printf 'input:\n  generate:\n    count: 1\n    interval: ""\n    mapping: |\n      root = file("/run/msg.bin")\n      meta nats_subject = "%s"\n' "$1"
        cat "$WORK/pipeline.yaml"
        printf 'output:\n  stdout: {}\nlogger:\n  level: ERROR\n'
    } > "$run/run.yaml"
    out="$(docker run --rm -v "$run:/run:ro" -v "$WORK/proto:/proto:ro" "$IMAGE" run /run/run.yaml 2>"$WORK/stderr")"
    # No row at all is never right; say what the pipeline said instead of failing mutely.
    [ -n "$out" ] || { echo "    no rows for $1 — the pipeline said:" >&2; sed 's/^/      /' "$WORK/stderr" | cut -c1-300 >&2; }
    printf '%s\n' "$out"
}
value_of() { # value_of <rows> <sensor>: the row's value, or "absent"
    printf '%s\n' "$1" | grep -F "\"sensor\":\"$2\"" | head -n 1 | LC_ALL=C sed -n 's/.*"value":\([^,}]*\).*/\1/p' | grep . || echo absent
}
device_of() { printf '%s\n' "$1" | head -n 1 | LC_ALL=C sed -n 's/.*"device_id":"\([^"]*\)".*/\1/p'; }
columns() { printf '%s\n' "$1" | LC_ALL=C sed -n 's/.*"sensor":"\([^"]*\)".*/\1/p' | sort | tr '\n' ' '; }

REPORT_ONE='report_timestamp { seconds: 1791500000 }
report_data { [type.googleapis.com/com.android.sdv.telemetry.VehicleTelemetryData] { VELOCITY: 0 FUEL_LEVEL: 40.5 LOCKED: true trunk_open: true gear_status { gear: D } } }'
REPORT_OLD_AAOS='report_timestamp { seconds: 1791500000 }
report_data { [type.googleapis.com/com.android.sdv.someip.VehicleTelemetryData] { VELOCITY: 12 FUEL_LEVEL: 40.5 } }'
NEXUS_MSG='message_id: "m1" device_id: "VIN4" sensor_data { timestamp { seconds: 1791500000 } value: "17" sensor: "PERF_VEHICLE_SPEED" }'
encode google.sdv.telemetry.MetricsReport "$REPORT_ONE" "$WORK/one.bin"
encode google.sdv.telemetry.MetricsReport "$REPORT_OLD_AAOS" "$WORK/oldaaos.bin"
encode telemetry.TelemetryMessage "$NEXUS_MSG" "$WORK/nexus.bin"

echo "Google's SDV report on its family, telemetry-aaos-sdv.<vin>"
r="$(rows telemetry-aaos-sdv.VIN1 "$WORK/one.bin")"
[ "$(device_of "$r")" = VIN1 ] && ok "the vehicle is the second token" || bad "the vehicle is the second token (got '$(device_of "$r")'; $(head -c 300 "$WORK/stderr"))"
[ "$(value_of "$r" VELOCITY)" = 0 ] && ok "a speed of 0 is written as 0" || bad "a speed of 0 is written as 0 (got $(value_of "$r" VELOCITY))"
[ "$(value_of "$r" FUEL_LEVEL)" = 40.5 ] && ok "a filled field is written" || bad "a filled field is written (got $(value_of "$r" FUEL_LEVEL))"
[ "$(value_of "$r" trunk_open)" = true ] && ok "a field only the larger report has is written" || bad "a field only the larger report has is written (got $(value_of "$r" trunk_open))"
[ "$(value_of "$r" gear)" = '"D"' ] && ok "the gear is one of P, R, N, D" || bad "the gear is one of P, R, N, D (got $(value_of "$r" gear))"
NEW_COLUMNS="$(columns "$r")"
r="$(rows telemetry-aaos-sdv.VIN1.some-report "$WORK/one.bin")"
[ "$(device_of "$r")" = VIN1 ] && ok "a suffix after the vehicle changes nothing" || bad "a suffix after the vehicle changes nothing"

echo "The Nexus message on telemetry.<vin>"
r="$(rows telemetry.VIN4 "$WORK/nexus.bin")"
[ "$(device_of "$r")" = VIN4 ] && [ "$(value_of "$r" PERF_VEHICLE_SPEED)" = 17 ] \
  && ok "a reading becomes a row under the message's device" || bad "a reading becomes a row under the message's device ($r)"

echo "Accepted for one more release"
r="$(rows local.telemetry.VIN2 "$WORK/oldaaos.bin")"
[ "$(device_of "$r")" = VIN2 ] && [ "$(value_of "$r" VELOCITY)" = 12 ] \
  && ok "local.telemetry.<vin> with the earlier report type" || bad "local.telemetry.<vin> with the earlier report type ($(head -c 200 "$WORK/stderr"))"
[ "$(columns "$r")" = "$NEW_COLUMNS" ] && ok "… and it writes the same columns as the new family" || bad "… and it writes the same columns as the new family"
r="$(rows telemetry-generic.VIN3 "$WORK/one.bin")"
[ "$(device_of "$r")" = VIN3 ] && [ "$(value_of "$r" FUEL_LEVEL)" = 40.5 ] \
  && ok "telemetry-generic.<vin>" || bad "telemetry-generic.<vin> ($(head -c 200 "$WORK/stderr"))"
r="$(rows telemetry.prod.bigtable.VIN4 "$WORK/nexus.bin")"
[ "$(device_of "$r")" = VIN4 ] && ok "telemetry.prod.bigtable.<vin>" || bad "telemetry.prod.bigtable.<vin>"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
