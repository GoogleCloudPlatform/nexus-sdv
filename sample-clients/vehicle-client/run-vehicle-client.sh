#!/bin/bash
# Run the vehicle client with automatic certificate generation and build
#
# Usage:
#   ./run-vehicle-client.sh <pki_strategy> [VIN] [REGISTRATION_URL] [INTERVAL]
#
# Arguments:
#   pki_strategy     - Required: "local" or "remote"
#   VIN             - Optional: Vehicle Identification Number (default: VEHICLE001)
#   REGISTRATION_URL - Optional: Registration server URL (default: https://registration.sdv-lal.com:8080)
#   INTERVAL        - Optional: Telemetry interval in seconds (default: 5)

set -e

FILE_PATH="../../iac/bootstrapping/.bootstrap_env"
echo "=========================================="
echo "Check for environment file"
echo "=========================================="

if [ -f "$FILE_PATH" ]; then
    echo "Found environment file at $FILE_PATH"
    source  $FILE_PATH
    echo -e "\nUsing these variables"
    echo "GCP_PROJECT_ID ${GCP_PROJECT_ID}"
    echo "GCP_REGION ${GCP_REGION}"
    echo "GITHUB_REPO ${GITHUB_REPO}"
    echo "ENV ${ENV}"
    echo "PKI_STRATEGY ${PKI_STRATEGY}"
    echo "BASE_DOMAIN ${BASE_DOMAIN}"
    echo "EXISTING_DNS_ZONE ${EXISTING_DNS_ZONE}"
    echo "KEYCLOAK_HOSTNAME ${KEYCLOAK_HOSTNAME}"
    echo "NATS_HOSTNAME ${NATS_HOSTNAME}"
    echo "REGISTRATION_HOSTNAME ${REGISTRATION_HOSTNAME}"
    echo "EXISTING_SERVER_CA ${EXISTING_SERVER_CA}"
    echo "EXISTING_SERVER_CA_POOL ${EXISTING_SERVER_CA_POOL}"
    echo "EXISTING_FACTORY_CA ${EXISTING_FACTORY_CA}"
    echo "EXISTING_FACTORY_CA_POOL ${EXISTING_FACTORY_CA_POOL}"
    echo "EXISTING_REG_CA ${EXISTING_REG_CA}"
    echo "EXISTING_REG_CA_POOL ${EXISTING_REG_CA_POOL}"
else
    echo "Could not find environment file at $FILE_PATH"
fi

# --- Get the directory of this script ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Parse arguments
PKI_STRATEGY_PARAM="${1}"
VIN_VALUE="${2:-VEHICLE001}"
REGISTRATION_URL_PARAM="${3}"
INTERVAL_VALUE="${4:-5}"


PKI_STRATEGY_VALUE="${PKI_STRATEGY_PARAM:-$PKI_STRATEGY}"
# Validate PKI strategy
if [ -z "$PKI_STRATEGY_VALUE" ]; then
    echo "Error: pki_strategy is required"
    echo ""
    echo "Usage: $0 <pki_strategy> [VIN] [REGISTRATION_URL] [INTERVAL]"
    echo ""
    echo "Arguments:"
    echo "  pki_strategy     - Required: 'local' or 'remote'"
    echo "  VIN             - Optional: Vehicle Identification Number (default: VEHICLE001)"
    echo "  REGISTRATION_URL - Optional: Registration server URL"
    echo "  INTERVAL        - Optional: Telemetry interval in seconds (default: 5)"
    echo ""
    echo "Examples:"
    echo "  $0 local"
    echo "  $0 remote VEHICLE001"
    echo "  $0 local VEHICLE001 https://registration.sdv-lal.com:8080 10"
    exit 1
fi

if [ "$PKI_STRATEGY_VALUE" != "local" ] && [ "$PKI_STRATEGY_VALUE" != "remote" ]; then
    echo "Error: pki_strategy must be 'local' or 'remote'"
    exit 1
fi

if [ "$PKI_STRATEGY_VALUE" = "remote" ]; then
    REGISTRATION_URL_VALUE="${REGISTRATION_URL_PARAM:-"https://${REGISTRATION_HOSTNAME}.${BASE_DOMAIN}:8080"}"
else
    REGISTRATION_URL_VALUE="${REGISTRATION_URL_PARAM:-"https://${REGISTRATION_HOSTNAME}:8080"}"
fi


echo "=========================================="
echo "Vehicle Client Launcher"
echo "=========================================="
echo "PKI Strategy: $PKI_STRATEGY_VALUE"
echo "VIN: $VIN_VALUE"
echo "Registration URL: $REGISTRATION_URL_VALUE"
echo "Interval: ${INTERVAL_VALUE}s"
echo ""

# Step 1: Generate factory certificate
echo "Step 1: Generating factory certificate..."

# Define the output path for the certificates
CERT_DIR="${SCRIPT_DIR}"

if [ "$PKI_STRATEGY_VALUE" = "local" ]; then
    echo "Using local PKI (generate-factory-cert.sh)..."
    CERT_PREFIX="${CERT_DIR}/vehicle-${VIN_VALUE}-factory"
    # Call the script from the parent directory
    (cd "${SCRIPT_DIR}/.." && ./generate-factory-cert.sh "$VIN_VALUE" "$CERT_PREFIX")
elif [ "$PKI_STRATEGY_VALUE" = "remote" ]; then
    echo "Using remote PKI (generate-factory-cert-gcp.sh)..."
    CERT_PREFIX="${CERT_DIR}/vehicle-${VIN_VALUE}-factory-gcp"
    # Call the script from the parent directory
    (cd "${SCRIPT_DIR}/.." && ./generate-factory-cert-gcp.sh "$VIN_VALUE" "$CERT_PREFIX")
fi

FACTORY_CERT="${CERT_PREFIX}-chain.pem"
FACTORY_KEY="${CERT_PREFIX}-key.pem"

# Verify certificates were created
if [ ! -f "$FACTORY_CERT" ]; then
    echo "Error: Factory certificate not found at $FACTORY_CERT"
    exit 1
fi

if [ ! -f "$FACTORY_KEY" ]; then
    echo "Error: Factory key not found at $FACTORY_KEY"
    exit 1
fi

echo "✓ Factory certificate generated successfully"
echo ""

if [ "$PKI_STRATEGY_VALUE" = "remote" ]; then
    mkdir -p certificates
    gcloud secrets versions access latest --secret="REGISTRATION_SERVER_TLS_CERT" > certificates/REGISTRATION_SERVER_TLS_CERT.pem
    gcloud secrets versions access latest --secret="KEYCLOAK_TLS_CRT" > certificates/KEYCLOAK_TLS_CRT.pem
fi
# Step 2: Check and build binary
echo "Step 2: Checking vehicle-client binary..."
BINARY_NAME="vehicle-client"

if [ ! -f "$BINARY_NAME" ]; then
    echo "Binary not found. Building..."
    make build
    echo "✓ Build complete"
else
    echo "✓ Binary exists"
fi
echo ""
# Step 3: Run the vehicle client
echo "Step 3: Running vehicle-client..."
echo "Command: ./$BINARY_NAME -vin=\"$VIN_VALUE\" -pki_strategy=\"$PKI_STRATEGY_VALUE\" -factory-cert=\"$FACTORY_CERT\" -factory-key=\"$FACTORY_KEY\" -registration-url=\"$REGISTRATION_URL_VALUE\" -interval=$INTERVAL_VALUE"
echo ""

./"$BINARY_NAME" \
  -vin="$VIN_VALUE" \
  -pki_strategy="$PKI_STRATEGY_VALUE" \
  -factory-cert="$FACTORY_CERT" \
  -factory-key="$FACTORY_KEY" \
  -registration-url="$REGISTRATION_URL_VALUE" \
  -interval="$INTERVAL_VALUE"
