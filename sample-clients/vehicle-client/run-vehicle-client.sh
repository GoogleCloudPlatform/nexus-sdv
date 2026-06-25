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
INTERVAL_VALUE="5"
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

# --- Ensure server TLS certificates are present ---
# KEYCLOAK_TLS_CRT.pem — Server CA cert for trusting the Istio IngressGateway's TLS endpoint.
#   In remote mode this is the GCP CAS server CA; the vehicle appends it to the system cert pool.
# REGISTRATION_SERVER_TLS_CERT.pem — TLS cert for the registration server endpoint.
if [ ! -f "$CERT_DIR/KEYCLOAK_TLS_CRT.pem" ] || [ ! -f "$CERT_DIR/REGISTRATION_SERVER_TLS_CERT.pem" ]; then
    echo "Downloading server TLS certificates from Secret Manager..."
    gcloud secrets versions access latest --secret="KEYCLOAK_TLS_CRT" --project="$GCP_PROJECT_ID" > "$CERT_DIR/KEYCLOAK_TLS_CRT.pem"
    gcloud secrets versions access latest --secret="REGISTRATION_SERVER_TLS_CERT" --project="$GCP_PROJECT_ID" > "$CERT_DIR/REGISTRATION_SERVER_TLS_CERT.pem"
    echo "✓ Server TLS certificates downloaded"
else
    echo "✓ Server TLS certificates exist"
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
  -message-type="$MESSAGE_TYPE" \
  -interval="$INTERVAL_VALUE"
