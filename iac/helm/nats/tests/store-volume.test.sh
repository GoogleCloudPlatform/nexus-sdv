#!/usr/bin/env bash
# The hub's store must ask for a disk every node can take: renders the real helmfile with
# the real chart for both architectures and reads the StatefulSet's volume claim template.
# Needs helmfile and helm, and network access to the NATS chart repository.
#   ./store-volume.test.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELMFILE="$HERE/../../helmfile.d/nats.yaml.gotmpl"
WANT_CLASS="dynamic-rwo"; WANT_SIZE="4Gi"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; }

# Stand-in values: the helmfile refuses to render without them, none reaches a cluster.
export BASE_DOMAIN="" ENVIRONMENT="test" NATS_BASIC_AUTH_USER="u" NATS_BASIC_AUTH_PASSWORD="p" \
       NATS_AUTH_CALLOUT_PASSWORD="p" NATS_CONNECTOR_PASSWORD="p" NATS_GRANT_READER_PASSWORD="p" \
       NATS_REGISTRY_PASSWORD="p" NATS_AUTH_CALLOUT_NKEY_PUB="ABJHLOVMPA4CI6R5KLNGOB4GSLNIY7IOUPAJC4YFNDLQVIOBYQGUWVLA"

for arch in arm64 amd64; do
    out="$(helmfile --file "$HELMFILE" template --state-values-set pkiStrategy=local --state-values-set baseDomain= --state-values-set "arch=$arch" 2>&1)" \
      || { bad "$arch: the helmfile does not render: $(printf '%s' "$out" | tail -n 2)"; continue; }
    # The claim template of the StatefulSet named nats: its storage request and its class.
    claim="$(printf '%s\n' "$out" | awk '/^kind: StatefulSet/{s=1} s&&/volumeClaimTemplates:/{v=1} v{print} s&&/^---/{s=0;v=0}')"
    [ -n "$claim" ] || { bad "$arch: no volume claim template in the StatefulSet"; continue; }
    class="$(printf '%s\n' "$claim" | sed -n 's/^ *storageClassName: *//p' | head -n 1 | tr -d '"')"
    size="$(printf '%s\n' "$claim" | sed -n 's/^ *storage: *//p' | head -n 1 | tr -d '"')"
    [ "$class" = "$WANT_CLASS" ] && ok "$arch: storage class $class" || bad "$arch: storage class is '${class:-none}', want $WANT_CLASS"
    [ "$size" = "$WANT_SIZE" ] && ok "$arch: size $size" || bad "$arch: size is '${size:-none}', want $WANT_SIZE"
done
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
