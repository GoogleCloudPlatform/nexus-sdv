#!/usr/bin/env bash
# keycloak-provision-client.sh — create/update a Keycloak OIDC client via the
# Admin REST API (no kcadm, no DB access, no console click-ops).
#
# v1 scope: service-account (client_credentials) clients + an optional realm
# role assigned to the client's service-account user. First consumer:
# factory-helper's `factory-operator` client (#480). Second consumer (#479,
# data-web-client) will extend this with --standard-flow/--redirect-uri.
#
# Usage:
#   ./keycloak-provision-client.sh <keycloak-base-url> <realm> <client-id> [--role <name>] [--project <gcp-project>]
# Example:
#   ./keycloak-provision-client.sh https://keycloak.<base-domain>:8443 sdv-telemetry factory-operator --role factory-operator
#
# Admin password: Secret Manager KEYCLOAK_ADMIN_PASSWORD (same secret the
# Keycloak helmfile release consumes); admin user defaults to 'admin'.
set -euo pipefail
KC_URL="${1:?usage: keycloak-provision-client.sh <keycloak-base-url> <realm> <client-id> [--role <name>]}"
REALM="${2:?missing realm}"
CLIENT_ID="${3:?missing client-id}"
ROLE=""
GCP_PROJECT=""
shift 3
while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="$2"; shift 2 ;;
    --project) GCP_PROJECT="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

ADMIN_USER="${KEYCLOAK_ADMIN_USER:-admin}"
# Password source: env var wins; otherwise Secret Manager — with an explicit
# --project, never the gcloud default (which may point at a different project
# and fail confusingly).
if [ -z "${KEYCLOAK_ADMIN_PASSWORD:-}" ] && [ -z "$GCP_PROJECT" ]; then
  echo "set KEYCLOAK_ADMIN_PASSWORD or pass --project <gcp-project> for the Secret Manager lookup" >&2
  exit 2
fi
ADMIN_PASS="${KEYCLOAK_ADMIN_PASSWORD:-$(gcloud secrets versions access latest --secret=KEYCLOAK_ADMIN_PASSWORD --project="$GCP_PROJECT")}"

# --data-urlencode: generated admin passwords are base64 and may contain '+'
# which plain -d would decode as a space, silently failing the login.
# Wrapped in `if`, not a bare assignment: `curl -sf` exits non-zero on an HTTP
# error, and under `set -e` that ends the script inside the assignment — before
# the check below can report anything. A caller then sees no output at all and
# has to guess. That cost a matrix run on 2026-09-25.
if ! TOKEN_RAW=$(curl -sk -w '\n%{http_code}' -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli \
  --data-urlencode "username=${ADMIN_USER}" --data-urlencode "password=${ADMIN_PASS}"); then
  echo "admin login failed: could not reach ${KC_URL} — is Keycloak answering yet?" >&2
  exit 1
fi
HTTP_CODE=$(tail -n1 <<<"$TOKEN_RAW")
if [ "$HTTP_CODE" != "200" ]; then
  echo "admin login failed: ${KC_URL} answered HTTP ${HTTP_CODE}" >&2
  exit 1
fi
TOKEN=$(sed '$d' <<<"$TOKEN_RAW" | jq -r .access_token)
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "admin login failed: no access_token in the response" >&2; exit 1; }
api() { curl -sfk -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" "$@"; }

# Create the client if absent (idempotent)
EXISTING=$(api "${KC_URL}/admin/realms/${REALM}/clients?clientId=${CLIENT_ID}" | jq -r '.[0].id // empty')
if [ -z "$EXISTING" ]; then
  api -X POST "${KC_URL}/admin/realms/${REALM}/clients" -d "{
    \"clientId\": \"${CLIENT_ID}\",
    \"protocol\": \"openid-connect\",
    \"publicClient\": false,
    \"serviceAccountsEnabled\": true,
    \"standardFlowEnabled\": false,
    \"directAccessGrantsEnabled\": false
  }"
  EXISTING=$(api "${KC_URL}/admin/realms/${REALM}/clients?clientId=${CLIENT_ID}" | jq -r '.[0].id')
  echo "created client ${CLIENT_ID} (uuid ${EXISTING})"
else
  echo "client ${CLIENT_ID} already exists (uuid ${EXISTING})"
fi

if [ -n "$ROLE" ]; then
  # Create the realm role if absent, then assign it to the client's service-account user
  api "${KC_URL}/admin/realms/${REALM}/roles/${ROLE}" >/dev/null 2>&1 || \
    api -X POST "${KC_URL}/admin/realms/${REALM}/roles" -d "{\"name\": \"${ROLE}\"}"
  ROLE_JSON=$(api "${KC_URL}/admin/realms/${REALM}/roles/${ROLE}")
  SA_USER=$(api "${KC_URL}/admin/realms/${REALM}/clients/${EXISTING}/service-account-user" | jq -r .id)
  api -X POST "${KC_URL}/admin/realms/${REALM}/users/${SA_USER}/role-mappings/realm" -d "[${ROLE_JSON}]"
  echo "realm role ${ROLE} assigned to ${CLIENT_ID}'s service account"
fi

SECRET=$(api "${KC_URL}/admin/realms/${REALM}/clients/${EXISTING}/client-secret" | jq -r .value)
echo "client_id:     ${CLIENT_ID}"
echo "client_secret: ${SECRET}"
echo "token_url:     ${KC_URL}/realms/${REALM}/protocol/openid-connect/token"
