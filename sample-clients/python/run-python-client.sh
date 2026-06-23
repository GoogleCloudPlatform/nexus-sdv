#!/bin/bash
# Run the Python vehicle client.
#
# The client automatically decides whether to reuse existing certificates and
# tokens or perform a full PKI registration, based on their validity.
#
# Usage:
#   ./run-python-client.sh [options]
#
# Options:
#   --vin <VIN>          Vehicle Identification Number (default: VEHICLE001)
#   --interval <seconds> Telemetry publish interval (default: 5)

set -e

# --- Parse flags ---
VIN_VALUE="VEHICLE001"
INTERVAL_VALUE="5"

while [[ $# -gt 0 ]]; do
    case $1 in
        --vin)      VIN_VALUE="$2";    shift 2 ;;
        --interval) INTERVAL_VALUE="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; echo "Usage: $0 [--vin <VIN>] [--interval <seconds>]"; exit 1 ;;
    esac
done

# --- Load environment ---
FILE_PATH="../../iac/bootstrapping/.bootstrap_env"
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
echo "Python Vehicle Client"
echo "=========================================="
echo "VIN:          $VIN_VALUE"
echo "Interval:     ${INTERVAL_VALUE}s"
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

# --- Ensure Keycloak TLS certificate is present ---
if [ ! -f "$CERT_DIR/KEYCLOAK_TLS_CRT.pem" ]; then
    echo "Downloading Keycloak TLS certificate from Secret Manager..."
    gcloud secrets versions access latest --secret="KEYCLOAK_TLS_CRT" --project="$GCP_PROJECT_ID" > "$CERT_DIR/KEYCLOAK_TLS_CRT.pem"
    echo "✓ Keycloak TLS certificate downloaded"
else
    echo "✓ Keycloak TLS certificate exists"
fi
if [ ! -f "$CERT_DIR/REGISTRATION_SERVER_TLS_CERT.pem" ]; then
    echo "Downloading registration server TLS certificate from Secret Manager..."
    gcloud secrets versions access latest --secret="REGISTRATION_SERVER_TLS_CERT" --project="$GCP_PROJECT_ID" > "$CERT_DIR/REGISTRATION_SERVER_TLS_CERT.pem"
    echo "✓ Registration server TLS certificate downloaded"
else
    echo "✓ Registration server TLS certificate exists"
fi

# --- Run ---
echo ""
echo "*** Running Python vehicle-client... ***"
echo ""

uv run main.py \
  -vin="$VIN_VALUE" \
  -pki_strategy="$PKI_STRATEGY_VALUE" \
  -factory-cert="$FACTORY_CERT" \
  -factory-key="$FACTORY_KEY" \
  -registration-url="$REGISTRATION_URL" \
  -keycloak-url="$KEYCLOAK_URL" \
  -nats-url="$NATS_URL" \
  -interval="$INTERVAL_VALUE"
