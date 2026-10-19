#!/usr/bin/env bash
# A changed pipeline or a changed message definition must restart the connector: it reads
# both once, at start. The pod template therefore carries a checksum of each, and this test
# checks that the checksum follows the content. Needs helm.
#   ./rollout.test.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="$HERE/.."
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; }
sum_of() { helm template t "$1" --show-only templates/deployment.yaml 2>/dev/null | sed -n "s/^ *checksum\/$2: *//p" | head -n 1; }

before_config="$(sum_of "$CHART" config)"; before_proto="$(sum_of "$CHART" proto)"
[ -n "$before_config" ] && ok "the pod template carries a checksum of the pipeline" || bad "the pod template carries a checksum of the pipeline"
[ -n "$before_proto" ]  && ok "the pod template carries a checksum of the message definitions" || bad "the pod template carries a checksum of the message definitions"

cp -RL "$CHART" "$WORK/chart"
printf '\n# changed\n' >> "$WORK/chart/templates/configmap-template.yaml"
[ -n "$before_config" ] && [ "$(sum_of "$WORK/chart" config)" != "$before_config" ] \
  && ok "a changed pipeline changes its checksum" || bad "a changed pipeline changes its checksum"
printf '\n// changed\n' >> "$WORK/chart/files/telemetry.proto"
[ -n "$before_proto" ] && [ "$(sum_of "$WORK/chart" proto)" != "$before_proto" ] \
  && ok "a changed message definition changes its checksum" || bad "a changed message definition changes its checksum"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
