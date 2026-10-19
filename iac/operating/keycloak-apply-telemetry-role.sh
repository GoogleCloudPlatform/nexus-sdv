#!/usr/bin/env bash
# Applies the telemetry-client role to a RUNNING Keycloak realm (Increment 2.2, D5a): the
# realm file in the chart is only read on a fresh bootstrap. Idempotent; prints no secret.
#   ./keycloak-apply-telemetry-role.sh [namespace]
#
# Through the admin REST interface over a port-forward, because kcadm.sh accepts a password
# only from an interactive console and the Keycloak image carries no curl. The operator
# supplies nothing: the admin user and password are read from the pod's own environment
# into this shell; the password travels in a request body from stdin and the token in a
# header file — neither ever appears on a command line, here or in the pod.
set -euo pipefail
NS="${1:-base-services}"; REALM="sdv-telemetry"; PORT="${KEYCLOAK_LOCAL_PORT:-18080}"
ROLE="telemetry-client"; ROLE_DESC="Publishes vehicle telemetry: telemetry.<vin>.> and telemetry.*.*.<vin>"
command -v curl >/dev/null && command -v jq >/dev/null || { echo "needs curl and jq" >&2; exit 1; }

POD="$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[0].metadata.name}')"
ADMIN_USER="$(kubectl -n "$NS" exec "$POD" -c keycloak -- sh -c 'printf %s "$KEYCLOAK_ADMIN"')"
ADMIN_PW="$(kubectl -n "$NS" exec "$POD" -c keycloak -- sh -c 'printf %s "$KEYCLOAK_ADMIN_PASSWORD"')"
[ -n "$ADMIN_USER" ] && [ -n "$ADMIN_PW" ] || { echo "the pod holds no admin credentials" >&2; exit 1; }

WORK="$(mktemp -d)"; chmod 700 "$WORK"
kubectl -n "$NS" port-forward "svc/keycloak" "${PORT}:8080" >"$WORK/pf.log" 2>&1 &
PF=$!; disown $PF 2>/dev/null || true   # the trap ends it; no job-control message
trap 'kill $PF 2>/dev/null; rm -rf "$WORK"' EXIT
for _ in $(seq 1 30); do curl -sf "http://127.0.0.1:${PORT}/realms/master" >/dev/null 2>&1 && break; sleep 1; done
BASE="http://127.0.0.1:${PORT}"

# The token: credentials in the body, from stdin.
TOKEN="$(printf 'grant_type=password&client_id=admin-cli&username=%s&password=%s' \
           "$(printf %s "$ADMIN_USER" | jq -sRr @uri)" "$(printf %s "$ADMIN_PW" | jq -sRr @uri)" \
         | curl -sf -X POST "$BASE/realms/master/protocol/openid-connect/token" \
             -H 'Content-Type: application/x-www-form-urlencoded' --data @- | jq -r .access_token)"
unset ADMIN_PW
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "admin login failed" >&2; exit 1; }
printf 'Authorization: Bearer %s\n' "$TOKEN" > "$WORK/auth"; unset TOKEN
api() { curl -s -o "$WORK/body" -w '%{http_code}' -H @"$WORK/auth" -H 'Content-Type: application/json' "$@"; }

# 1. the role
code="$(jq -n --arg n "$ROLE" --arg d "$ROLE_DESC" '{name:$n, description:$d}' | api -X POST "$BASE/admin/realms/$REALM/roles" --data @-)"
case "$code" in 201) echo "role $ROLE created" ;; 409) echo "role $ROLE exists" ;; *) echo "creating the role: HTTP $code" >&2; exit 1 ;; esac

# 2. the service account and the role's representation
uid="$(api "$BASE/admin/realms/$REALM/users?username=service-account-car&exact=true" >/dev/null; jq -r '.[0].id // empty' "$WORK/body")"
[ -n "$uid" ] || { echo "user service-account-car not found" >&2; exit 1; }
api "$BASE/admin/realms/$REALM/roles/$ROLE" >/dev/null; jq -c '[.]' "$WORK/body" > "$WORK/role"

# 3. the mapping (a POST of an already-mapped role is a no-op)
code="$(api -X POST "$BASE/admin/realms/$REALM/users/$uid/role-mappings/realm" --data @"$WORK/role")"
case "$code" in 204) ;; *) echo "mapping the role: HTTP $code" >&2; exit 1 ;; esac
api "$BASE/admin/realms/$REALM/users/$uid/role-mappings/realm" >/dev/null
jq -e --arg r "$ROLE" 'map(.name) | index($r)' "$WORK/body" >/dev/null && echo "service-account-car holds $ROLE"
