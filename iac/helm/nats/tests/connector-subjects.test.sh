#!/usr/bin/env bash
# The hub must let the BigTable connector subscribe every subject the connector's own
# configuration listens on. The two live in different charts; a family added to one and
# forgotten in the other is dropped by the hub without a word.
# Renders both charts and compares. Needs helm and helmfile.
#   ./connector-subjects.test.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELMFILE="$HERE/../../helmfile.d/nats.yaml.gotmpl"
CONNECTOR="$HERE/../../nats-bigtable-connector"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; }

# Stand-in values: the helmfile refuses to render without them, none reaches a cluster.
export BASE_DOMAIN="" ENVIRONMENT="test" NATS_BASIC_AUTH_USER="u" NATS_BASIC_AUTH_PASSWORD="p" \
       NATS_AUTH_CALLOUT_PASSWORD="p" NATS_CONNECTOR_PASSWORD="p" NATS_GRANT_READER_PASSWORD="p" \
       NATS_REGISTRY_PASSWORD="p" NATS_AUTH_CALLOUT_NKEY_PUB="ABJHLOVMPA4CI6R5KLNGOB4GSLNIY7IOUPAJC4YFNDLQVIOBYQGUWVLA"

hub="$(helmfile --file "$HELMFILE" template --state-values-set pkiStrategy=local --state-values-set baseDomain= --state-values-set arch=amd64 2>/dev/null)"
# The connector user's subscribe list, as the hub's configuration file states it.
# It is written as JSON with sorted keys, so a user's permissions stand before its name: keep
# the latest subscribe list and print it when the name that follows is the connector's.
allowed="$(printf '%s\n' "$hub" | awk '/"subscribe": \[/{buf=""; s=1} s{buf=buf $0 "\n"} s&&/\]/{s=0} /"user": "connector"/{printf "%s", buf; exit}' \
  | grep -o '"[a-z][a-z.>-]*"' | tr -d '"' | grep -v '^subscribe$')"
[ -n "$allowed" ] || { echo "could not read the connector user's subscribe list from the rendered hub configuration"; exit 1; }
listens="$(helm template t "$CONNECTOR" --show-only templates/configmap-template.yaml 2>/dev/null | sed -n 's/^ *subject: *//p')"
[ -n "$listens" ] || { echo "could not read the connector's subjects from its chart"; exit 1; }

for subject in $listens; do
    printf '%s\n' "$allowed" | grep -qxF "$subject" \
      && ok "the hub lets the connector subscribe $subject" \
      || bad "the connector listens on $subject, but the hub's connector user may not subscribe it"
done
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
