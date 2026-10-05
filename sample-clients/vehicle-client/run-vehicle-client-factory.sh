#!/bin/bash
# Run the vehicle client with a factory identity issued by the factory-helper
# service — the self-service path (issue #480): no gcloud or GCP IAM access
# required.
#
# This is the flow an external party (e.g. the Google partner team) follows:
#   1. Obtain a Keycloak operator token (client_credentials, factory-operator)
#   2. POST /v1/factory-certificates → per-VIN factory cert + key (mode 2)
#   3. Fetch the two TLS trust certs from the public GCS bucket (plain HTTPS)
#   4. Run vehicle-client: registration → operational cert → JWT → NATS
#
# Usage:
#   FACTORY_OPERATOR_CLIENT_SECRET=<secret> ./run-vehicle-client-factory.sh [options]
#
# Options:
#   --vin <VIN>             Vehicle Identification Number (default: VEHICLE001)
#   --interval <seconds>    Telemetry publish interval (default: 3)
#   --message-type <type>   metrics_report|telemetry (default: metrics_report)
#   --base-domain <domain>  Nexus base domain (default: from .bootstrap_env)
#   --client-id <id>        Keycloak operator client id (default: factory-operator)
#
# Environment:
#   FACTORY_CLIENT_ID               Keycloak operator client id
#                                   (default: factory-operator; --client-id wins)
#   FACTORY_OPERATOR_CLIENT_SECRET  Its client secret. If unset and the client is
#                                   factory-operator, the secret is read from Secret
#                                   Manager via gcloud using GCP_PROJECT_ID — a
#                                   convenience for operators with project access,
#                                   not a requirement.
#   PKI_BUCKET_URL                  Public trust bucket (default: derived from
#                                   GCP_PROJECT_ID)

set -e

# --- Parse flags ---
VIN_VALUE="VEHICLE001"
INTERVAL_VALUE="3"
MESSAGE_TYPE="metrics_report"
BASE_DOMAIN_FLAG=""
CLIENT_ID="${FACTORY_CLIENT_ID:-factory-operator}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --vin)          VIN_VALUE="$2";       shift 2 ;;
        --interval)     INTERVAL_VALUE="$2";  shift 2 ;;
        --message-type) MESSAGE_TYPE="$2";    shift 2 ;;
        --base-domain)  BASE_DOMAIN_FLAG="$2"; shift 2 ;;
        --client-id)    CLIENT_ID="$2";       shift 2 ;;
        *) echo "Unknown option: $1"; echo "Usage: $0 [--vin <VIN>] [--interval <seconds>] [--message-type <type>] [--base-domain <domain>] [--client-id <id>]"; exit 1 ;;
    esac
done

command -v jq >/dev/null || { echo "jq is required"; exit 1; }

# --- Load environment (optional — external parties pass --base-domain instead) ---
FILE_PATH="../../iac/bootstrapping/.bootstrap_env"
echo ""
echo "=========================================="
echo "Check for environment file"
echo "=========================================="
if [ -f "$FILE_PATH" ]; then
    echo "Found environment file at $FILE_PATH"
    source "$FILE_PATH"
else
    echo "No environment file at $FILE_PATH (fine — using flags/defaults)"
fi
BASE_DOMAIN="${BASE_DOMAIN_FLAG:-${BASE_DOMAIN:-}}"
[ -n "$BASE_DOMAIN" ] || { echo "No base domain — pass --base-domain <domain>"; exit 1; }
KEYCLOAK_HOSTNAME="${KEYCLOAK_HOSTNAME:-keycloak}"
NATS_HOSTNAME="${NATS_HOSTNAME:-nats}"
REGISTRATION_HOSTNAME="${REGISTRATION_HOSTNAME:-registration}"
FACTORY_HOSTNAME="${FACTORY_HOSTNAME:-factory}"

# factory-helper only exists in remote-PKI deployments (v1)
if [ "${PKI_STRATEGY:-remote}" != "remote" ]; then
    echo "factory-helper supports PKI_STRATEGY=remote only"; exit 1
fi

# Operator client secret: the environment wins. Otherwise, for the default
# factory-operator client, read it from Secret Manager, where deploy-keycloak
# stores it. Only for that client — Secret Manager holds no secret for any other,
# and the wrong one would surface as a confusing invalid_client. External parties
# pass the secret in the environment and never need gcloud.
if [ -z "${FACTORY_OPERATOR_CLIENT_SECRET:-}" ] && [ "$CLIENT_ID" = "factory-operator" ] \
   && [ -n "${GCP_PROJECT_ID:-}" ] && command -v gcloud >/dev/null; then
    echo "FACTORY_OPERATOR_CLIENT_SECRET not set — reading it from Secret Manager in ${GCP_PROJECT_ID}..."
    FACTORY_OPERATOR_CLIENT_SECRET="$(gcloud secrets versions access latest \
        --secret=FACTORY_OPERATOR_CLIENT_SECRET --project="$GCP_PROJECT_ID" 2>/dev/null || true)"
fi
[ -n "${FACTORY_OPERATOR_CLIENT_SECRET:-}" ] || {
    echo "No operator client secret. Set FACTORY_OPERATOR_CLIENT_SECRET, or — for the"
    echo "factory-operator client — set GCP_PROJECT_ID with gcloud access to Secret Manager."
    echo "(Keycloak UI: realm sdv-telemetry → Clients → ${CLIENT_ID} → Credentials)"
    exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
CERT_DIR="${SCRIPT_DIR}/certificates"
mkdir -p "$CERT_DIR"

# --- Derive URLs ---
KEYCLOAK_URL="https://${KEYCLOAK_HOSTNAME}.${BASE_DOMAIN}:8443"
NATS_URL="nats://${NATS_HOSTNAME}.${BASE_DOMAIN}:4222"
REGISTRATION_URL="https://${REGISTRATION_HOSTNAME}.${BASE_DOMAIN}:8443"
FACTORY_URL="https://${FACTORY_HOSTNAME}.${BASE_DOMAIN}:8443"
# No fallback project: a default here would point every client at one particular
# platform's trust bucket, whichever platform it is actually talking to.
if [ -z "${PKI_BUCKET_URL:-}" ]; then
    [ -n "${GCP_PROJECT_ID:-}" ] || { echo "Set PKI_BUCKET_URL, or GCP_PROJECT_ID to derive it"; exit 1; }
    PKI_BUCKET_URL="https://storage.googleapis.com/${GCP_PROJECT_ID}-nexus-sdv-public/pki"
fi

echo ""
echo "=========================================="
echo "Vehicle Client (factory-helper identity)"
echo "=========================================="
echo "VIN:          $VIN_VALUE"
echo "Interval:     ${INTERVAL_VALUE}s"
echo "Message Type: $MESSAGE_TYPE"
echo "Factory URL:  $FACTORY_URL"
echo "Keycloak URL: $KEYCLOAK_URL"
echo "NATS URL:     $NATS_URL"

# --- Ensure server TLS trust certs are present (public bucket, no gcloud) ---
# Always fetch fresh copies: cached ones may be stale or from a different
# environment (30-day rotation; an existence check alone caused exactly that).
echo ""
echo "Downloading server TLS trust certs from the public bucket..."
curl -sf --max-time 30 "${PKI_BUCKET_URL}/KEYCLOAK_TLS_CRT.pem" -o "$CERT_DIR/KEYCLOAK_TLS_CRT.pem"
curl -sf --max-time 30 "${PKI_BUCKET_URL}/REGISTRATION_SERVER_TLS_CERT.pem" -o "$CERT_DIR/REGISTRATION_SERVER_TLS_CERT.pem"
echo "✓ Trust certs downloaded (fresh)"
# The Keycloak trust cert is the server-CA cert — it also anchors the
# factory-helper endpoint (same CA). Used below instead of curl -k.
CA_BUNDLE="$CERT_DIR/KEYCLOAK_TLS_CRT.pem"

# --- Ensure factory identity exists (factory-helper, mode 2) ---
CERT_PREFIX="${CERT_DIR}/vehicle-${VIN_VALUE}-factory-helper"
FACTORY_CERT="${CERT_PREFIX}-chain.pem"
FACTORY_KEY="${CERT_PREFIX}-key.pem"

if [ ! -f "$FACTORY_CERT" ] || [ ! -f "$FACTORY_KEY" ]; then
    echo ""
    echo "*** Factory identity not found — requesting from factory-helper... ***"

    TOKEN=$(curl -sf --max-time 30 --cacert "$CA_BUNDLE" -X POST \
        "${KEYCLOAK_URL}/realms/sdv-telemetry/protocol/openid-connect/token" \
        -d grant_type=client_credentials -d "client_id=${CLIENT_ID}" \
        --data-urlencode "client_secret=${FACTORY_OPERATOR_CLIENT_SECRET}" | jq -r .access_token)
    [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "Keycloak operator login failed"; exit 1; }
    echo "✓ Operator token obtained"

    RESPONSE=$(curl -sf --max-time 60 --cacert "$CA_BUNDLE" -X POST \
        "${FACTORY_URL}/v1/factory-certificates" \
        -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
        -d "{\"vin\": \"${VIN_VALUE}\"}") || { echo "factory-helper request failed"; exit 1; }

    # Leaf + chain into one file (the Go client sends the full chain for mTLS);
    # the private key exists only here and on this machine — never server-side logs.
    { jq -r .certificate <<<"$RESPONSE"; jq -r .ca_certificate_chain <<<"$RESPONSE"; } > "$FACTORY_CERT"
    jq -r .private_key <<<"$RESPONSE" > "$FACTORY_KEY"
    chmod 600 "$FACTORY_KEY"
    unset RESPONSE
    echo "✓ Factory identity issued for VIN ${VIN_VALUE} ($(openssl x509 -in "$FACTORY_CERT" -noout -subject 2>/dev/null || echo 'subject n/a'))"

    # A fresh identity means any cached operational cert/token belongs to a
    # previous identity — clear them so the binary performs a full registration.
    rm -f "$CERT_DIR/operational-cert.pem" "$CERT_DIR/operational-key.pem" "$CERT_DIR"/oidc-*
else
    echo "✓ Factory identity exists"
fi

# --- Build binary if needed ---
echo ""
BINARY_NAME="vehicle-client"
if [ ! -f "$BINARY_NAME" ]; then
    echo "Binary not found — building..."
    make build
    echo "✓ Build complete"
else
    echo "✓ Binary exists"
fi

# --- Run ---
echo ""
echo "*** Running vehicle-client... ***"
echo ""

./"$BINARY_NAME" \
  -vin="$VIN_VALUE" \
  -pki_strategy=remote \
  -factory-cert="$FACTORY_CERT" \
  -factory-key="$FACTORY_KEY" \
  -registration-url="$REGISTRATION_URL" \
  -keycloak-url="$KEYCLOAK_URL" \
  -nats-url="$NATS_URL" \
  -message-type="$MESSAGE_TYPE" \
  -interval="$INTERVAL_VALUE"
