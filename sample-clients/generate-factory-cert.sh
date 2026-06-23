#!/bin/bash
# Generate factory certificates for vehicle client
# These certificates are signed by the factory CA and used for initial registration

set -e

# Default values
VIN="${1:-1HGBH41JXMN109186}"
OUTPUT_PREFIX="${2:-factory-cert}"
FACTORY_CA_CERT="../base-services/registration/pki/factory-ca/ca.crt.pem"
FACTORY_CA_KEY="../base-services/registration/pki/factory-ca/ca.key.pem"

echo "=========================================="
echo "Factory Certificate Generation"
echo "=========================================="
echo "VIN: $VIN"
echo "Output prefix: $OUTPUT_PREFIX"
echo ""

# Validate factory CA files exist
if [ ! -f "$FACTORY_CA_CERT" ]; then
    echo "Error: Factory CA certificate not found at $FACTORY_CA_CERT"
    exit 1
fi

if [ ! -f "$FACTORY_CA_KEY" ]; then
    echo "Error: Factory CA key not found at $FACTORY_CA_KEY"
    exit 1
fi

# Generate private key
echo "1. Generating private key..."
openssl genrsa -out "${OUTPUT_PREFIX}-key.pem" 2048

# Create CSR with correct CN format (VIN:xxx DEVICE:xxx)
echo "2. Creating certificate signing request..."
openssl req -new -key "${OUTPUT_PREFIX}-key.pem" \
  -out "${OUTPUT_PREFIX}.csr" \
  -subj "/O=Vehicle Manufacturer/CN=VIN:${VIN} DEVICE:${VIN}"

# Sign the CSR with factory CA
echo "3. Signing certificate with factory CA..."
# Sign with explicit v3 extensions. The registration server validates the client
# cert with rustls' WebPkiClientVerifier (webpki), which only accepts X.509 v3
# certificates. Without -extfile the cert version depends on the openssl default:
# OpenSSL 3.0.x and LibreSSL emit a bare v1 cert (rejected with: sslv3 alert
# certificate unknown), while OpenSSL 3.2+ emit v3 — so the same script passed on
# some machines and failed on others. Setting extensions makes the cert
# deterministically v3 on every implementation. clientAuth/keyUsage additionally
# match the usages the server sets on the operational certs it issues (see csr.rs).
cat > "${OUTPUT_PREFIX}.ext" <<'EOF'
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
EOF
openssl x509 -req -in "${OUTPUT_PREFIX}.csr" \
  -CA "$FACTORY_CA_CERT" \
  -CAkey "$FACTORY_CA_KEY" \
  -CAcreateserial \
  -out "${OUTPUT_PREFIX}.pem" \
  -days 365 \
  -sha256 \
  -extfile "${OUTPUT_PREFIX}.ext"

# Create certificate chain (cert + CA) with proper newline separation
echo "4. Creating certificate chain..."
{ cat "${OUTPUT_PREFIX}.pem"; echo ""; cat "$FACTORY_CA_CERT"; } > "${OUTPUT_PREFIX}-chain.pem"

echo ""
echo "✓ Certificate generation complete!"
echo ""
echo "Generated files:"
echo "  - ${OUTPUT_PREFIX}-key.pem      (Private key - keep secure)"
echo "  - ${OUTPUT_PREFIX}.pem          (Certificate)"
echo "  - ${OUTPUT_PREFIX}-chain.pem    (Certificate chain for registration)"
echo "  - ${OUTPUT_PREFIX}.csr          (Certificate signing request)"
echo ""
echo "Usage with vehicle-client:"
echo "  ./vehicle-client \\"
echo "    -vin=\"$VIN\" \\"
echo "    -factory-cert=\"${OUTPUT_PREFIX}-chain.pem\" \\"
echo "    -factory-key=\"${OUTPUT_PREFIX}-key.pem\" \\"
echo "    -registration-url=\"https://<IP address of registration server>:8080\""
echo ""

# Verify the certificate
echo "Certificate details:"
openssl x509 -in "${OUTPUT_PREFIX}.pem" -noout -subject -issuer -dates
