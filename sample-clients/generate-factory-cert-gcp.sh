#!/bin/bash
# Generate factory certificates using GCP Certificate Authority Service
# These certificates are signed by the factory CA in GCP CAS and used for initial registration

set -e

# --- Get the directory of this script ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Default values
VIN="${1:-1HGBH41JXMN109186}"
# If OUTPUT_PREFIX is a path, use it; otherwise, create files in the current directory.
OUTPUT_PREFIX="${2:-factory-cert-gcp}"

# Load environment from bootstrap, relative to the script's location
ENV_FILE="${SCRIPT_DIR}/../iac/bootstrapping/.bootstrap_env"
if [ ! -f "$ENV_FILE" ]; then
    echo "Error: Environment file not found at $ENV_FILE"
    echo "Please run the bootstrap script first."
    exit 1
fi

# Source the environment variables
source "$ENV_FILE"

# Determine which CA pool to use
if [ -n "$EXISTING_FACTORY_CA_POOL" ]; then
    FACTORY_CA_POOL="$EXISTING_FACTORY_CA_POOL"
else
    FACTORY_CA_POOL="factory-ca-pool"
fi

echo "=========================================="
echo "Factory Certificate Generation via GCP CAS"
echo "=========================================="
echo "VIN: $VIN"
echo "Output prefix: $OUTPUT_PREFIX"
echo "GCP Project: $GCP_PROJECT_ID"
echo "Region: $GCP_REGION"
echo "Factory CA Pool: $FACTORY_CA_POOL"
echo ""

# Validate GCP authentication
if ! gcloud auth print-access-token &>/dev/null; then
    echo "Error: Not authenticated with gcloud. Please run 'gcloud auth login'"
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

# Sign the CSR with GCP CAS Factory CA
echo "3. Signing certificate with GCP CAS Factory CA..."
CERT_ID="factory-cert-$(date +%s)-${VIN}"

gcloud privateca certificates create "$CERT_ID" \
  --issuer-pool="$FACTORY_CA_POOL" \
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

# Download Factory CA certificate for chain
echo "4. Downloading Factory CA certificate..."
FACTORY_CA_CERT="${OUTPUT_PREFIX}-ca.pem"
gcloud privateca roots list \
  --pool="$FACTORY_CA_POOL" \
  --location="$GCP_REGION" \
  --format="value(pemCaCertificates)" \
  --project="$GCP_PROJECT_ID" \
  --limit=1 > "$FACTORY_CA_CERT"

if [ ! -s "$FACTORY_CA_CERT" ]; then
    echo "Error: Could not download Factory CA certificate"
    exit 1
fi

# Create certificate chain (cert + CA) with proper newline separation
echo "5. Creating certificate chain..."
{ cat "${OUTPUT_PREFIX}.pem"; echo ""; cat "$FACTORY_CA_CERT"; } > "${OUTPUT_PREFIX}-chain.pem"

echo ""
echo "✓ Certificate generation complete!"
echo ""
echo "Generated files:"
echo "  - ${OUTPUT_PREFIX}-key.pem      (Private key - keep secure)"
echo "  - ${OUTPUT_PREFIX}.pem          (Certificate)"
echo "  - ${OUTPUT_PREFIX}-chain.pem    (Certificate chain for registration)"
echo "  - ${OUTPUT_PREFIX}.csr          (Certificate signing request)"
echo "  - ${OUTPUT_PREFIX}-ca.pem       (Factory CA certificate)"
echo ""
echo "Usage with vehicle-client:"
echo "  ./vehicle-client \\"
echo "    -vin=\"$VIN\" \\"
echo "    -factory-cert=\"${OUTPUT_PREFIX}-chain.pem\" \\"
echo "    -factory-key=\"${OUTPUT_PREFIX}-key.pem\" \\"
echo "    -registration-url=\"https://registration.${BASE_DOMAIN}:8080\""
echo ""

# Verify the certificate
echo "Certificate details:"
openssl x509 -in "${OUTPUT_PREFIX}.pem" -noout -subject -issuer -dates
