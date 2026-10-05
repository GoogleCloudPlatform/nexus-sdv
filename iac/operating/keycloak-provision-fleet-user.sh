#!/usr/bin/env bash
# keycloak-provision-fleet-user.sh — create the FleetView group and its login
# user via the Keycloak Admin REST API.
#
# FleetView authorises by group membership, not by role: the data-web-client has
# an oidc-group-membership-mapper that puts the user's groups into a "groups"
# claim, and the app matches that claim against the vehicle_groups table. The
# realm import ships the mapper but no group and no user, so a freshly
# bootstrapped platform has a working FleetView that nobody can log into.
#
# The password is generated and marked temporary: Keycloak forces the user to
# replace it at first login, which makes the stored secret worthless afterwards.
# It is only ever set when the user is created — a redeploy must not reset a
# password somebody has already chosen.
#
# Usage:
#   ./keycloak-provision-fleet-user.sh <keycloak-base-url> <realm> [--user <name>]
#                                      [--group <name>] [--project <gcp-project>]
#
# Example:
#   ./keycloak-provision-fleet-user.sh https://keycloak.<base-domain>:8443 sdv-telemetry \
#       --project <gcp-project>
set -euo pipefail

KC_URL="${1:?usage: keycloak-provision-fleet-user.sh <keycloak-base-url> <realm> [--user <name>] [--group <name>] [--project <gcp-project>]}"
REALM="${2:?missing realm}"
USER_NAME="nexus-fleet"
GROUP_NAME="nexus-fleet"
ADMIN_ROLE="nexus-admin"
WEB_CLIENT_ID="data-web-client"
ROLE_MAPPER_NAME="realm roles"
GCP_PROJECT=""
shift 2
while [ $# -gt 0 ]; do
  case "$1" in
    --user)    USER_NAME="$2"; shift 2 ;;
    --group)   GROUP_NAME="$2"; shift 2 ;;
    --project) GCP_PROJECT="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

ADMIN_USER="${KEYCLOAK_ADMIN_USER:-admin}"
if [ -z "${KEYCLOAK_ADMIN_PASSWORD:-}" ] && [ -z "$GCP_PROJECT" ]; then
  echo "set KEYCLOAK_ADMIN_PASSWORD or pass --project <gcp-project> for the Secret Manager lookup" >&2
  exit 2
fi
ADMIN_PASS="${KEYCLOAK_ADMIN_PASSWORD:-$(gcloud secrets versions access latest --secret=KEYCLOAK_ADMIN_PASSWORD --project="$GCP_PROJECT")}"

# --data-urlencode: generated admin passwords are base64 and may contain '+'
# which plain -d would decode as a space, silently failing the login.
TOKEN=$(curl -sfk -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli \
  --data-urlencode "username=${ADMIN_USER}" --data-urlencode "password=${ADMIN_PASS}" | jq -r .access_token)
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "admin login failed" >&2; exit 1; }
api() { curl -sfk -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" "$@"; }

# --- group (idempotent) ---
GROUP_ID=$(api "${KC_URL}/admin/realms/${REALM}/groups?search=${GROUP_NAME}&exact=true" | jq -r '.[0].id // empty')
if [ -z "$GROUP_ID" ]; then
  api -X POST "${KC_URL}/admin/realms/${REALM}/groups" -d "{\"name\": \"${GROUP_NAME}\"}" >/dev/null
  GROUP_ID=$(api "${KC_URL}/admin/realms/${REALM}/groups?search=${GROUP_NAME}&exact=true" | jq -r '.[0].id')
  echo "created group ${GROUP_NAME} (uuid ${GROUP_ID})"
else
  echo "group ${GROUP_NAME} already exists (uuid ${GROUP_ID})"
fi

# --- user (idempotent; the password is set only on creation) ---
USER_ID=$(api "${KC_URL}/admin/realms/${REALM}/users?username=${USER_NAME}&exact=true" | jq -r '.[0].id // empty')
PASSWORD=""
if [ -z "$USER_ID" ]; then
  PASSWORD=$(openssl rand -base64 18)
  # firstName/lastName/email are filled on purpose: Keycloak's VERIFY_PROFILE
  # required action fires on an incomplete profile and would make the first login
  # stop at an "Update Account Information" form. This is a shared demo account,
  # so the values are deliberately generic — nobody's real address belongs here.
  api -X POST "${KC_URL}/admin/realms/${REALM}/users" -d "{
      \"username\": \"${USER_NAME}\",
      \"enabled\": true,
      \"firstName\": \"Nexus\",
      \"lastName\": \"Fleet\",
      \"email\": \"${USER_NAME}@nexus-sdv.invalid\",
      \"emailVerified\": true,
      \"requiredActions\": [\"UPDATE_PASSWORD\"],
      \"credentials\": [{\"type\": \"password\", \"value\": \"${PASSWORD}\", \"temporary\": true}]
    }" >/dev/null
  USER_ID=$(api "${KC_URL}/admin/realms/${REALM}/users?username=${USER_NAME}&exact=true" | jq -r '.[0].id')
  echo "created user ${USER_NAME} (uuid ${USER_ID}) with a temporary password"
else
  echo "user ${USER_NAME} already exists (uuid ${USER_ID}) — password left untouched"
fi

# --- membership (idempotent: PUT is a no-op when already a member) ---
api -X PUT "${KC_URL}/admin/realms/${REALM}/users/${USER_ID}/groups/${GROUP_ID}" >/dev/null
echo "user ${USER_NAME} is a member of ${GROUP_NAME}"

# --- admin realm role (idempotent) ---
# nexus-admin sees every vehicle identity in the registry view, not just its own
# group's. That matters even with a single fleet: a failed certificate issuance is
# recorded but never enrolled into any group, so a purely group-scoped view would
# hide exactly the entries an operator needs to see.
if ! api "${KC_URL}/admin/realms/${REALM}/roles/${ADMIN_ROLE}" >/dev/null 2>&1; then
  api -X POST "${KC_URL}/admin/realms/${REALM}/roles" -d "{\"name\": \"${ADMIN_ROLE}\"}" >/dev/null
  echo "created realm role ${ADMIN_ROLE}"
else
  echo "realm role ${ADMIN_ROLE} already exists"
fi
ROLE_JSON=$(api "${KC_URL}/admin/realms/${REALM}/roles/${ADMIN_ROLE}")
api -X POST "${KC_URL}/admin/realms/${REALM}/users/${USER_ID}/role-mappings/realm" -d "[${ROLE_JSON}]" >/dev/null
echo "realm role ${ADMIN_ROLE} assigned to ${USER_NAME}"

# --- realm-roles mapper on the web client (idempotent) ---
# Keycloak puts realm roles in the access token by default. The web client reads
# its claims from the ID token (next-auth exposes `profile`), so without this
# mapper session.roles stays empty and nobody is ever an admin.
CLIENT_UUID=$(api "${KC_URL}/admin/realms/${REALM}/clients?clientId=${WEB_CLIENT_ID}" | jq -r '.[0].id // empty')
if [ -z "$CLIENT_UUID" ]; then
  echo "warning: client ${WEB_CLIENT_ID} not found — skipping the realm-roles mapper" >&2
else
  HAS_MAPPER=$(api "${KC_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}" \
    | jq -r --arg n "$ROLE_MAPPER_NAME" '[.protocolMappers[]? | select(.name==$n)] | length')
  if [ "${HAS_MAPPER:-0}" = "0" ]; then
    api -X POST "${KC_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}/protocol-mappers/models" -d "{
        \"name\": \"${ROLE_MAPPER_NAME}\",
        \"protocol\": \"openid-connect\",
        \"protocolMapper\": \"oidc-usermodel-realm-role-mapper\",
        \"config\": {
          \"claim.name\": \"realm_access.roles\",
          \"jsonType.label\": \"String\",
          \"multivalued\": \"true\",
          \"id.token.claim\": \"true\",
          \"access.token.claim\": \"true\",
          \"userinfo.token.claim\": \"true\"
        }
      }" >/dev/null
    echo "created realm-roles mapper on ${WEB_CLIENT_ID}"
  else
    echo "realm-roles mapper on ${WEB_CLIENT_ID} already exists"
  fi
fi

echo "username:          ${USER_NAME}"
if [ -n "$PASSWORD" ]; then
  echo "initial_password:  ${PASSWORD}"
else
  echo "initial_password:  (unchanged — user already existed)"
fi
