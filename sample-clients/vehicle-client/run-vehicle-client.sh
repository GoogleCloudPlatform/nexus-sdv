#!/bin/bash
# Run the vehicle client.
#
# The binary automatically decides whether to reuse existing certificates and
# tokens or perform a full PKI registration, based on their validity.
#
# Usage:
#   ./run-vehicle-client.sh [options]
#
# Options:
#   --vin <VIN>             Vehicle Identification Number (default: VEHICLE001)
#   --interval <seconds>    Telemetry publish interval (default: 5)
#   --message-type <type>   metrics_report|telemetry (default: metrics_report)

set -e

# --- Parse flags ---
VIN_VALUE="VEHICLE001"
INTERVAL_VALUE="3"
MESSAGE_TYPE="metrics_report"

while [[ $# -gt 0 ]]; do
    case $1 in
        --vin)        VIN_VALUE="$2";    shift 2 ;;
        --interval)   INTERVAL_VALUE="$2"; shift 2 ;;
        --message-type) MESSAGE_TYPE="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; echo "Usage: $0 [--vin <VIN>] [--interval <seconds>] [--message-type <type>]"; exit 1 ;;
    esac
done

# --- Load environment ---
FILE_PATH="../../iac/bootstrapping/.bootstrap_env"
echo ""
echo "=========================================="
echo "Check for environment file"
echo "=========================================="
if [ -f "$FILE_PATH" ]; then
    echo "Found environment file at $FILE_PATH"
    source "$FILE_PATH"
    echo -e "\nUsing these variables"
    echo "GCP_PROJECT_ID    ${GCP_PROJECT_ID}"
    echo "GCP_REGION        ${GCP_REGION}"
    echo "ENV               ${ENV}"
    echo "PKI_STRATEGY      ${PKI_STRATEGY}"
    echo "BASE_DOMAIN       ${BASE_DOMAIN}"
    echo "KEYCLOAK_HOSTNAME ${KEYCLOAK_HOSTNAME}"
    echo "NATS_HOSTNAME     ${NATS_HOSTNAME}"
    echo "REGISTRATION_HOSTNAME ${REGISTRATION_HOSTNAME}"
else
    echo "Could not find environment file at $FILE_PATH"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
CERT_DIR="${SCRIPT_DIR}/certificates"
mkdir -p "$CERT_DIR"

# --- Derive URLs ---
PKI_STRATEGY_VALUE="${PKI_STRATEGY:-remote}"
if [ "$PKI_STRATEGY_VALUE" = "remote" ]; then
    KEYCLOAK_URL="https://${KEYCLOAK_HOSTNAME}.${BASE_DOMAIN}:8443"
    NATS_URL="nats://${NATS_HOSTNAME}.${BASE_DOMAIN}:4222"
    REGISTRATION_URL="https://${REGISTRATION_HOSTNAME}.${BASE_DOMAIN}:8443"
else
    KEYCLOAK_URL="https://${KEYCLOAK_HOSTNAME}:8443"
    NATS_URL="nats://${NATS_HOSTNAME}:4222"
    REGISTRATION_URL="https://${REGISTRATION_HOSTNAME}:8443"
fi

echo ""
echo "=========================================="
echo "Vehicle Client"
echo "=========================================="
echo "VIN:          $VIN_VALUE"
echo "Interval:     ${INTERVAL_VALUE}s"
echo "Message Type: $MESSAGE_TYPE"
echo "Keycloak URL: $KEYCLOAK_URL"
echo "NATS URL:     $NATS_URL"

# --- Ensure factory certificate exists ---
if [ "$PKI_STRATEGY_VALUE" = "remote" ]; then
    CERT_PREFIX="${CERT_DIR}/vehicle-${VIN_VALUE}-factory-gcp"
else
    CERT_PREFIX="${CERT_DIR}/vehicle-${VIN_VALUE}-factory"
fi
FACTORY_CERT="${CERT_PREFIX}-chain.pem"
FACTORY_KEY="${CERT_PREFIX}-key.pem"

if [ ! -f "$FACTORY_CERT" ] || [ ! -f "$FACTORY_KEY" ]; then
    echo ""
    echo "*** Factory certificate not found — generating... ***"
    if [ "$PKI_STRATEGY_VALUE" = "remote" ]; then
        (cd "${SCRIPT_DIR}/.." && ./generate-factory-cert-gcp.sh "$VIN_VALUE" "$CERT_PREFIX")
    else
        (cd "${SCRIPT_DIR}/.." && ./generate-factory-cert.sh "$VIN_VALUE" "$CERT_PREFIX")
    fi
    echo "✓ Factory certificate generated"
else
    echo "✓ Factory certificate exists"
fi

# --- Ensure server TLS trust certificates are present ---
# KEYCLOAK_TLS_CRT.pem — Server CA cert for trusting the Istio IngressGateway's TLS endpoint.
#   In remote mode this is the GCP CAS server CA; the vehicle appends it to the system cert pool.
# REGISTRATION_SERVER_TLS_CERT.pem — TLS cert for the registration server endpoint.
#
# Both are public certs (no private key) needed by every Nexus SDV client, so they are
# published to a public, read-only GCS bucket (no GCP credential needed to fetch) instead of
# handed out via Secret Manager IAM per consumer — see
# docs/superpowers/specs/2026-07-20-leaf-core3-tcu-design.md. Bucket creation and refresh
# now live in the platform's deploy pipelines (#478); this script only fetches.
# The bucket is created and kept current by the platform's own deploy pipelines
# (iac/bootstrapping/lib/public-pki.sh), not by this script. Its name is derived
# from the project id so any client can construct the URL; PKI_BUCKET_URL
# overrides that for the rare case where the derived name was already taken.
PKI_BUCKET="${GCP_PROJECT_ID}-nexus-sdv-public"
PKI_BASE_URL="${PKI_BUCKET_URL:-https://storage.googleapis.com/${PKI_BUCKET}/pki}"

# Optional: on guests with no DNS resolver at all (e.g. Cuttlefish Core/Core3 — see
# docs/superpowers/plans/2026-08-07-nexus-connectivity-agent.md, Task 3), the caller
# resolves these hostnames once on a host that has real DNS and passes the IPs here.
# curl's --resolve keeps SNI/cert validation against the real hostname. Unset by
# default, so behavior on hosts with working DNS is unchanged.
CURL_RESOLVE_ARGS=()
if [ -n "${NEXUS_PKI_IP:-}" ]; then
    CURL_RESOLVE_ARGS+=(--resolve "storage.googleapis.com:443:${NEXUS_PKI_IP}")
fi

cert_is_valid() {
    # Usable if it exists, parses, and isn't already expired — plain existence isn't enough
    # (a stale cached copy caused a real incident: certificate has expired).
    [ -f "$1" ] && openssl x509 -in "$1" -noout -checkend 0 &>/dev/null
}

fetch_public_pki() {
    curl "${CURL_RESOLVE_ARGS[@]}" -fsSL -o "$CERT_DIR/KEYCLOAK_TLS_CRT.pem.tmp" "${PKI_BASE_URL}/KEYCLOAK_TLS_CRT.pem" \
        && curl "${CURL_RESOLVE_ARGS[@]}" -fsSL -o "$CERT_DIR/REGISTRATION_SERVER_TLS_CERT.pem.tmp" "${PKI_BASE_URL}/REGISTRATION_SERVER_TLS_CERT.pem" \
        && mv "$CERT_DIR/KEYCLOAK_TLS_CRT.pem.tmp" "$CERT_DIR/KEYCLOAK_TLS_CRT.pem" \
        && mv "$CERT_DIR/REGISTRATION_SERVER_TLS_CERT.pem.tmp" "$CERT_DIR/REGISTRATION_SERVER_TLS_CERT.pem"
}

if cert_is_valid "$CERT_DIR/KEYCLOAK_TLS_CRT.pem" && cert_is_valid "$CERT_DIR/REGISTRATION_SERVER_TLS_CERT.pem"; then
    echo "✓ Server TLS certificates exist and are still valid"
elif fetch_public_pki; then
    echo "✓ Server TLS certificates fetched from public bucket (no GCP credential used)"
else
    rm -f "$CERT_DIR"/*.tmp
    echo "Public bucket fetch failed — falling back to Secret Manager (requires gcloud auth" \
         "with Secret Manager access to $GCP_PROJECT_ID)."
    echo "The bucket is a platform guarantee, created by the deploy pipelines; if it is"
    echo "missing, the platform was not fully deployed. See issue #478."
    gcloud secrets versions access latest --secret="KEYCLOAK_TLS_CRT" --project="$GCP_PROJECT_ID" > "$CERT_DIR/KEYCLOAK_TLS_CRT.pem"
    gcloud secrets versions access latest --secret="REGISTRATION_SERVER_TLS_CERT" --project="$GCP_PROJECT_ID" > "$CERT_DIR/REGISTRATION_SERVER_TLS_CERT.pem"
    echo "✓ Server TLS certificates downloaded from Secret Manager"
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
  -pki_strategy="$PKI_STRATEGY_VALUE" \
  -factory-cert="$FACTORY_CERT" \
  -factory-key="$FACTORY_KEY" \
  -registration-url="$REGISTRATION_URL" \
  -keycloak-url="$KEYCLOAK_URL" \
  -nats-url="$NATS_URL" \
  -registration-resolve-ip="${NEXUS_REGISTRATION_IP:-}" \
  -keycloak-resolve-ip="${NEXUS_KEYCLOAK_IP:-}" \
  -message-type="$MESSAGE_TYPE" \
  -interval="$INTERVAL_VALUE"
