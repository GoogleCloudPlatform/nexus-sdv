#!/bin/bash
# Generate a leaf node client certificate using the local Server CA.
# Use this in LOCAL PKI mode (development / no GCP CAS).
#
# Usage:
#   ./generate-leaf-node-cert.sh <partner-name> [output-prefix]
#
# Example:
#   ./generate-leaf-node-cert.sh acme-motors ./leaf-certs/acme

set -e

# --- Args ---
PARTNER_NAME="${1:?Usage: $0 <partner-name> [output-prefix]}"
OUTPUT_PREFIX="${2:-leaf-node-${PARTNER_NAME}}"

SERVER_CA_CERT="../base-services/registration/pki/server-ca/ca.crt.pem"
SERVER_CA_KEY="../base-services/registration/pki/server-ca/ca.key.pem"

echo "=========================================="
echo "Leaf Node Client Certificate (Local CA)"
echo "=========================================="
echo "Partner:       $PARTNER_NAME"
echo "Output prefix: $OUTPUT_PREFIX"
echo ""

# --- Validate CA files ---
if [ ! -f "$SERVER_CA_CERT" ]; then
    echo "Error: Server CA certificate not found at $SERVER_CA_CERT"
    echo "Run the bootstrap script in local mode to generate it first."
    exit 1
fi
if [ ! -f "$SERVER_CA_KEY" ]; then
    echo "Error: Server CA key not found at $SERVER_CA_KEY"
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

# 3. Sign with local Server CA
echo "3. Signing with local Server CA..."
openssl x509 -req \
  -in "${OUTPUT_PREFIX}.csr" \
  -CA "$SERVER_CA_CERT" \
  -CAkey "$SERVER_CA_KEY" \
  -CAcreateserial \
  -out "${OUTPUT_PREFIX}.pem" \
  -days 365 \
  -sha256

# 4. Copy Server CA cert so the partner can verify our NATS server
echo "4. Copying Server CA certificate..."
cp "$SERVER_CA_CERT" "${OUTPUT_PREFIX}-server-ca.pem"

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
echo "      - url: nats://<nats-ip>:7422"
echo "        tls:"
echo "          cert: /path/to/${PARTNER_NAME}.pem"
echo "          key:  /path/to/${PARTNER_NAME}-key.pem"
echo "          ca:   /path/to/${PARTNER_NAME}-server-ca.pem"
echo ""

# 5. Verify
echo "Certificate details:"
openssl x509 -in "${OUTPUT_PREFIX}.pem" -noout -subject -issuer -dates
