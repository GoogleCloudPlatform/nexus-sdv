#!/bin/bash
# Run the telemetry subscriber.
#
# The binary automatically decides whether to reuse existing certificates and
# tokens or perform a full PKI registration, based on their validity.
#
# Usage:
#   ./run-telemetry-subscriber.sh [options]
#
# Options:
#   --vin <VIN>            Vehicle Identification Number (default: VEHICLE001)
#   --subject <subject>    NATS subject to subscribe to (default: local.telemetry.>)
#   --record-dir <dir>     Directory to record received messages for later replay (disabled if omitted)

set -e

# --- Parse flags ---
VIN_VALUE="VEHICLE001"
#SUBJECT_VALUE="local.telemetry.>"
SUBJECT_VALUE="scoring.>"
RECORD_DIR_VALUE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --vin)        VIN_VALUE="$2";        shift 2 ;;
        --subject)    SUBJECT_VALUE="$2";    shift 2 ;;
        --record-dir) RECORD_DIR_VALUE="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; echo "Usage: $0 [--vin <VIN>] [--subject <subject>] [--record-dir <dir>]"; exit 1 ;;
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
echo "Telemetry Subscriber"
echo "=========================================="
echo "VIN:          $VIN_VALUE"
echo "Subject:      $SUBJECT_VALUE"
echo "Keycloak URL: $KEYCLOAK_URL"
echo "NATS URL:     $NATS_URL"
if [ -n "$RECORD_DIR_VALUE" ]; then
    echo "Recording to: $RECORD_DIR_VALUE"
fi

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
BINARY_NAME="telemetry-subscriber"
if [ ! -f "$BINARY_NAME" ]; then
    echo "Binary not found — building..."
    make build
    echo "✓ Build complete"
else
    echo "✓ Binary exists"
fi

# --- Run ---
echo ""
echo "*** Running telemetry-subscriber... ***"
echo ""
echo "Listening on '$SUBJECT_VALUE'... (Press Ctrl+C to stop)"
echo ""

RECORD_ARGS=()
if [ -n "$RECORD_DIR_VALUE" ]; then
    RECORD_ARGS=(-record-dir="$RECORD_DIR_VALUE")
fi

./"$BINARY_NAME" \
  -vin="$VIN_VALUE" \
  -pki_strategy="$PKI_STRATEGY_VALUE" \
  -factory-cert="$FACTORY_CERT" \
  -factory-key="$FACTORY_KEY" \
  -registration-url="$REGISTRATION_URL" \
  -keycloak-url="$KEYCLOAK_URL" \
  -nats-url="$NATS_URL" \
  -subject="$SUBJECT_VALUE" \
  "${RECORD_ARGS[@]}"
