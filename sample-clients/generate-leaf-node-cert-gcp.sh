#!/bin/bash
# Generate a leaf node client certificate using GCP Certificate Authority Service.
#
# This certificate is presented by an external NATS server when it connects to
# our leaf node port (7422). The NATS server verifies it against the Server CA.
#
# Usage:
#   ./generate-leaf-node-cert-gcp.sh <partner-name> [output-prefix]
#
# Example:
#   ./generate-leaf-node-cert-gcp.sh acme-motors ./leaf-certs/acme

set -e

# --- Get the directory of this script ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# --- Args ---
PARTNER_NAME="${1:?Usage: $0 <partner-name> [output-prefix]}"
OUTPUT_PREFIX="${2:-leaf-node-${PARTNER_NAME}}"

# --- Load environment ---
ENV_FILE="${SCRIPT_DIR}/../iac/bootstrapping/.bootstrap_env"
if [ ! -f "$ENV_FILE" ]; then
    echo "Error: Environment file not found at $ENV_FILE"
    echo "Please run the bootstrap script first."
    exit 1
fi
source "$ENV_FILE"

# --- Determine Server CA pool ---
if [ -n "$EXISTING_SERVER_CA_POOL" ]; then
    SERVER_CA_POOL="$EXISTING_SERVER_CA_POOL"
else
    SERVER_CA_POOL="server-ca-pool"
fi

echo "=========================================="
echo "Leaf Node Client Certificate (GCP CAS)"
echo "=========================================="
echo "Partner:       $PARTNER_NAME"
echo "Output prefix: $OUTPUT_PREFIX"
echo "GCP Project:   $GCP_PROJECT_ID"
echo "Region:        $GCP_REGION"
echo "Server CA Pool: $SERVER_CA_POOL"
echo ""

# --- Validate GCP auth ---
if ! gcloud auth print-access-token &>/dev/null; then
    echo "Error: Not authenticated with gcloud. Run 'gcloud auth login' first."
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT_PREFIX")"

# 1. Generate private key
echo "1. Generating private key..."
openssl genrsa -out "${OUTPUT_PREFIX}-key.pem" 2048

# 2. Create CSR
echo "2. Creating certificate signing request..."
openssl req -new \
  -key "${OUTPUT_PREFIX}-key.pem" \
  -out "${OUTPUT_PREFIX}.csr" \
  -subj "/O=Leaf Node Partner/CN=${PARTNER_NAME}"

# 3. Sign via GCP CAS (Server CA pool)
echo "3. Signing with GCP CAS Server CA..."
CERT_ID="leaf-node-${PARTNER_NAME}-$(date +%s)"

gcloud privateca certificates create "$CERT_ID" \
  --issuer-pool="$SERVER_CA_POOL" \
  --issuer-location="$GCP_REGION" \
  --csr="${OUTPUT_PREFIX}.csr" \
  --cert-output-file="${OUTPUT_PREFIX}.pem" \
  --validity="P365D" \
  --project="$GCP_PROJECT_ID" \
  --quiet

if [ ! -s "${OUTPUT_PREFIX}.pem" ]; then
    echo "Error: Certificate issuance failed or output is empty."
    exit 1
fi

# 4. Download Server CA cert so the partner can verify our NATS server
echo "4. Downloading Server CA certificate..."
gcloud privateca roots list \
  --pool="$SERVER_CA_POOL" \
  --location="$GCP_REGION" \
  --format="value(pemCaCertificates)" \
  --project="$GCP_PROJECT_ID" \
  --limit=1 > "${OUTPUT_PREFIX}-server-ca.pem"

if [ ! -s "${OUTPUT_PREFIX}-server-ca.pem" ]; then
    echo "Error: Could not download Server CA certificate."
    exit 1
fi

echo ""
echo "✓ Leaf node client certificate generated!"
echo ""
echo "Generated files:"
echo "  ${OUTPUT_PREFIX}-key.pem        (Private key  — send securely to partner)"
echo "  ${OUTPUT_PREFIX}.pem            (Client certificate — send to partner)"
echo "  ${OUTPUT_PREFIX}-server-ca.pem  (Server CA cert — send to partner so they can verify our NATS server)"
echo "  ${OUTPUT_PREFIX}.csr            (CSR — can be discarded)"
echo ""
echo "Partner NATS leaf node config (remotes block):"
echo ""
echo "  leafnodes:"
echo "    remotes:"
echo "      - url: nats://${NATS_HOSTNAME:-nats.<your-domain>}:7422"
echo "        tls:"
echo "          cert: /path/to/${PARTNER_NAME}.pem"
echo "          key:  /path/to/${PARTNER_NAME}-key.pem"
echo "          ca:   /path/to/${PARTNER_NAME}-server-ca.pem"
echo ""

# 5. Verify
echo "Certificate details:"
openssl x509 -in "${OUTPUT_PREFIX}.pem" -noout -subject -issuer -dates
