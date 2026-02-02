#!/bin/bash
# --- Force refresh ---

# ==============================================================================
# Nexus SDV Bootstrapping Script
#
# This script performs a complete, automated setup of the Nexus SDV GCP Platform
#
# Author: Team Sky
# Version: 3.0
# ==============================================================================

set -euo pipefail

# --- Colors ---
COLOR_GREEN='\033[0;32m'
COLOR_BLUE='\033[0;34m'
COLOR_YELLOW='\033[1;33m'
COLOR_RED='\033[0;31m'
COLOR_NC='\033[0m'

# --- Checks ---
check_all_prerequisites() {
    local missing=()
    for tool in "$@"; do
        if ! command -v "$tool" &> /dev/null; then missing+=("$tool"); fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${COLOR_RED}Missing tools: ${missing[*]}. Please install.${COLOR_NC}"
        exit 1
    fi
}

echo -e "${COLOR_BLUE}=== Nexus SDV Platform Bootstrapping ===${COLOR_NC}\n"

# 1. Prereqs
echo -e "${COLOR_YELLOW}Step 1: Checking prerequisites...${COLOR_NC}"
check_all_prerequisites "gcloud" "terraform" "gh" "openssl" "nk" "jq" "sed"
echo -e "${COLOR_GREEN}OK.${COLOR_NC}\n"

# 2. Auth
echo -e "${COLOR_YELLOW}Step 2: Authentication...${COLOR_NC}"

# This avoids repeated login prompts if the user is already authenticated.
if ! gcloud auth print-access-token &>/dev/null; then
    echo "gcloud authentication required."
    gcloud auth login
    gcloud auth application-default login
fi

if ! gh auth status &>/dev/null; then

    USER_LOGIN=$(gh api user -q .login 2>/dev/null)

    if [ $? -ne 0 ]; then
        echo "GitHub CLI authentication required."
        gh auth login --skip-ssh-key
    else
        echo "GitHub CLI authentication token found:  $USER_LOGIN"
    fi
else
    USER_LOGIN=$(gh api user -q .login 2>/dev/null)
    echo "GitHub CLI authentication token found: $USER_LOGIN"

fi

# Export GH_TOKEN to ensure consistent authentication throughout the script.
# This works around keychain access issues in some terminal environments (e.g., IntelliJ IDEA).
export GH_TOKEN=$(gh auth token)

echo -e "${COLOR_GREEN}Authentication checks passed.${COLOR_NC}\n"

# 3. Inputs
echo -e "${COLOR_YELLOW}Step 3: Project Configuration...${COLOR_NC}"

# --- .env file for persistence ---
# Load saved configuration from a .bootstrap_env file to avoid re-entering values.
ENV_FILE="iac/bootstrapping/.bootstrap_env"
if [ -f "$ENV_FILE" ]; then
    echo "Loading saved configuration from $ENV_FILE..."
    source "$ENV_FILE"
fi

# --- GCP Project ID ---
# Get default from gcloud config, but allow override from .bootstrap_env or user input.
DEFAULT_GCP_PROJECT_ID_GCLOUD=$(gcloud config get-value project 2>/dev/null || echo "")
DEFAULT_GCP_PROJECT_ID=${GCP_PROJECT_ID:-$DEFAULT_GCP_PROJECT_ID_GCLOUD}
read -rp "Google Cloud Project ID [${DEFAULT_GCP_PROJECT_ID}]: " INPUT_GCP_PROJECT_ID
GCP_PROJECT_ID=${INPUT_GCP_PROJECT_ID:-$DEFAULT_GCP_PROJECT_ID}

# --- GCP Region ---
DEFAULT_GCP_REGION_GCLOUD=$(gcloud config get-value compute/region 2>/dev/null || echo "")
DEFAULT_GCP_REGION=${GCP_REGION:-$DEFAULT_GCP_REGION_GCLOUD}
read -rp "GCP Region (e.g. europe-west3) [${DEFAULT_GCP_REGION}]: " INPUT_GCP_REGION
GCP_REGION=${INPUT_GCP_REGION:-$DEFAULT_GCP_REGION}

# --- GitHub Repo ---
DEFAULT_GITHUB_REPO=${GITHUB_REPO:-""}
read -rp "Enter your GitHub repository (format: 'owner/repo'):  [${DEFAULT_GITHUB_REPO}]: " INPUT_GITHUB_REPO
GITHUB_REPO=${INPUT_GITHUB_REPO:-$DEFAULT_GITHUB_REPO}

# --- Environment Name ---
DEFAULT_ENV=${ENV:-"sandbox"}
while true; do
    read -rp "Environment Name (max 15 chars) [${DEFAULT_ENV}]: " INPUT_ENV
    ENV=${INPUT_ENV:-$DEFAULT_ENV}
    if [ ${#ENV} -le 15 ]; then break; fi
    echo "Too long."
done

# --- PKI Strategy ---
DEFAULT_PKI_STRATEGY=${PKI_STRATEGY:-"local"}
echo
echo -e "${COLOR_BLUE}PKI Strategy Selection:${COLOR_NC}"
echo "  local  = Self-signed certs & IP addresses"
echo "  remote = Google CAS & Cloud DNS"
while true; do
    read -rp "Strategy (local/remote) [${DEFAULT_PKI_STRATEGY}]: " INPUT_PKI_STRATEGY
    PKI_STRATEGY=${INPUT_PKI_STRATEGY:-$DEFAULT_PKI_STRATEGY}
    if [[ "$PKI_STRATEGY" == "local" || "$PKI_STRATEGY" == "remote" ]]; then break; fi
done

# --- Base Domain ---
BASE_DOMAIN=${BASE_DOMAIN:-""}
if [ "$PKI_STRATEGY" == "remote" ]; then
    read -rp "Base Domain (e.g. sdv.example.com) [${BASE_DOMAIN}]: " INPUT_BASE_DOMAIN
    BASE_DOMAIN=${INPUT_BASE_DOMAIN:-$BASE_DOMAIN}
    if [ -z "$BASE_DOMAIN" ]; then echo "Domain required."; exit 1; fi

    # --- Existing DNS Zone (Optional) ---
    echo
    echo -e "${COLOR_BLUE}Existing Cloud DNS Zone (Optional):${COLOR_NC}"
    echo "If you want to use an existing Cloud DNS zone, enter its name below."
    echo "Leave blank to create a new DNS zone."
    DEFAULT_EXISTING_DNS_ZONE=${EXISTING_DNS_ZONE:-""}
    read -rp "Existing DNS zone name [${DEFAULT_EXISTING_DNS_ZONE}]: " INPUT_EXISTING_DNS_ZONE
    EXISTING_DNS_ZONE=${INPUT_EXISTING_DNS_ZONE:-$DEFAULT_EXISTING_DNS_ZONE}
else
    BASE_DOMAIN="" # Ensure base domain is empty for local strategy
    EXISTING_DNS_ZONE=""
fi

# --- Service Hostnames ---
if [ "$PKI_STRATEGY" == "remote" ]; then
    # These are used for DNS records and service discovery
    DEFAULT_KEYCLOAK_HOSTNAME=${KEYCLOAK_HOSTNAME:-"keycloak"}
    read -rp "Keycloak Hostname [${DEFAULT_KEYCLOAK_HOSTNAME}]: " INPUT_KEYCLOAK_HOSTNAME
    KEYCLOAK_HOSTNAME=${INPUT_KEYCLOAK_HOSTNAME:-$DEFAULT_KEYCLOAK_HOSTNAME}

    DEFAULT_NATS_HOSTNAME=${NATS_HOSTNAME:-"nats"}
    read -rp "NATS Hostname [${DEFAULT_NATS_HOSTNAME}]: " INPUT_NATS_HOSTNAME
    NATS_HOSTNAME=${INPUT_NATS_HOSTNAME:-$DEFAULT_NATS_HOSTNAME}

    DEFAULT_REGISTRATION_HOSTNAME=${REGISTRATION_HOSTNAME:-"registration"}
    read -rp "Registration Hostname [${DEFAULT_REGISTRATION_HOSTNAME}]: " INPUT_REGISTRATION_HOSTNAME
    REGISTRATION_HOSTNAME=${INPUT_REGISTRATION_HOSTNAME:-$DEFAULT_REGISTRATION_HOSTNAME}
else
    # for the local PKI strategy, these values will be filled with
    # the external IP addresses of the loadbalancer service
    KEYCLOAK_HOSTNAME="keycloak"
    NATS_HOSTNAME="nats"
    REGISTRATION_HOSTNAME="registration"
fi

RANDOM_SUFFIX=$(openssl rand -hex 4)

# need random names for ca pool (to be able to deploy and teardown frequently)
CREATED_SERVER_CA_POOL="server-ca-pool-${RANDOM_SUFFIX}"
CREATED_FACTORY_CA_POOL="factory-ca-pool-${RANDOM_SUFFIX}"
CREATED_REG_CA_POOL="registration-ca-pool-${RANDOM_SUFFIX}"

# --- Existing CA Configuration (Optional) ---
echo

if [ "$PKI_STRATEGY" == "remote" ]; then
    echo -e "${COLOR_BLUE}Existing CA Configuration (Optional):${COLOR_NC}"
    echo "If you want to use existing CAs instead of creating new ones, enter their details below."
    echo "Leave blank to create new CAs."
    echo

    # Server CA
    DEFAULT_EXISTING_SERVER_CA=${EXISTING_SERVER_CA:-""}
    read -rp "Existing Server CA name [${DEFAULT_EXISTING_SERVER_CA}]: " INPUT_EXISTING_SERVER_CA
    EXISTING_SERVER_CA=${INPUT_EXISTING_SERVER_CA:-$DEFAULT_EXISTING_SERVER_CA}

    if [ -n "$EXISTING_SERVER_CA" ]; then
        DEFAULT_EXISTING_SERVER_CA_POOL=${EXISTING_SERVER_CA_POOL:-$CREATED_SERVER_CA_POOL}
        read -rp "Server CA Pool name [${DEFAULT_EXISTING_SERVER_CA_POOL}]: " INPUT_EXISTING_SERVER_CA_POOL
        EXISTING_SERVER_CA_POOL=${INPUT_EXISTING_SERVER_CA_POOL:-$DEFAULT_EXISTING_SERVER_CA_POOL}
    else
        EXISTING_SERVER_CA_POOL=""
    fi

    # Factory CA
    DEFAULT_EXISTING_FACTORY_CA=${EXISTING_FACTORY_CA:-""}
    read -rp "Existing Factory CA name [${DEFAULT_EXISTING_FACTORY_CA}]: " INPUT_EXISTING_FACTORY_CA
    EXISTING_FACTORY_CA=${INPUT_EXISTING_FACTORY_CA:-$DEFAULT_EXISTING_FACTORY_CA}

    if [ -n "$EXISTING_FACTORY_CA" ]; then
        DEFAULT_EXISTING_FACTORY_CA_POOL=${EXISTING_FACTORY_CA_POOL:-$CREATED_FACTORY_CA_POOL}
        read -rp "Factory CA Pool name [${DEFAULT_EXISTING_FACTORY_CA_POOL}]: " INPUT_EXISTING_FACTORY_CA_POOL
        EXISTING_FACTORY_CA_POOL=${INPUT_EXISTING_FACTORY_CA_POOL:-$DEFAULT_EXISTING_FACTORY_CA_POOL}
    else
        EXISTING_FACTORY_CA_POOL=""
    fi

    # Registration CA
    DEFAULT_EXISTING_REG_CA=${EXISTING_REG_CA:-""}
    read -rp "Existing Registration CA name [${DEFAULT_EXISTING_REG_CA}]: " INPUT_EXISTING_REG_CA
    EXISTING_REG_CA=${INPUT_EXISTING_REG_CA:-$DEFAULT_EXISTING_REG_CA}

    if [ -n "$EXISTING_REG_CA" ]; then
        DEFAULT_EXISTING_REG_CA_POOL=${EXISTING_REG_CA_POOL:-$CREATED_REG_CA_POOL}
        read -rp "Registration CA Pool name [${DEFAULT_EXISTING_REG_CA_POOL}]: " INPUT_EXISTING_REG_CA_POOL
        EXISTING_REG_CA_POOL=${INPUT_EXISTING_REG_CA_POOL:-$DEFAULT_EXISTING_REG_CA_POOL}
    else
        EXISTING_REG_CA_POOL=""
    fi
else
    # Local mode - no existing CAs supported
    EXISTING_SERVER_CA=""
    EXISTING_SERVER_CA_POOL=""
    EXISTING_FACTORY_CA=""
    EXISTING_FACTORY_CA_POOL=""
    EXISTING_REG_CA=""
    EXISTING_REG_CA_POOL=""
fi

# --- Save configuration ---
# Save the entered values to the .bootstrap_env file for future runs.
# Note: We save the user-provided EXISTING_* values here. If user didn't provide any,
# we'll update .bootstrap_env AFTER Terraform creates the CAs (see after Step 6).
echo
echo "Saving configuration to $ENV_FILE..."
{
    echo "GCP_PROJECT_ID=\"${GCP_PROJECT_ID}\""
    echo "GCP_REGION=\"${GCP_REGION}\""
    echo "GITHUB_REPO=\"${GITHUB_REPO}\""
    echo "ENV=\"${ENV}\""
    echo "PKI_STRATEGY=\"${PKI_STRATEGY}\""
    echo "BASE_DOMAIN=\"${BASE_DOMAIN}\""
    echo "EXISTING_DNS_ZONE=\"${EXISTING_DNS_ZONE}\""
    echo "KEYCLOAK_HOSTNAME=\"${KEYCLOAK_HOSTNAME}\""
    echo "NATS_HOSTNAME=\"${NATS_HOSTNAME}\""
    echo "REGISTRATION_HOSTNAME=\"${REGISTRATION_HOSTNAME}\""
    echo "EXISTING_SERVER_CA=\"${EXISTING_SERVER_CA}\""
    echo "EXISTING_SERVER_CA_POOL=\"${EXISTING_SERVER_CA_POOL}\""
    echo "EXISTING_FACTORY_CA=\"${EXISTING_FACTORY_CA}\""
    echo "EXISTING_FACTORY_CA_POOL=\"${EXISTING_FACTORY_CA_POOL}\""
    echo "EXISTING_REG_CA=\"${EXISTING_REG_CA}\""
    echo "EXISTING_REG_CA_POOL=\"${EXISTING_REG_CA_POOL}\""
} > "$ENV_FILE"
echo

gcloud config set project "$GCP_PROJECT_ID"
echo

# --- 3.1. Enable Required GCP APIs ---
echo -e "${COLOR_YELLOW}Step 3.1: Enabling required GCP APIs...${COLOR_NC}"

# List of APIs required before Terraform runs
REQUIRED_APIS=(
    "cloudresourcemanager.googleapis.com"   # For gcloud projects describe
    "storage-api.googleapis.com"            # For GCS bucket operations
    "storage-component.googleapis.com"      # For gsutil
    "secretmanager.googleapis.com"          # For Secret Manager operations
    "iam.googleapis.com"                    # For IAM operations
    "iamcredentials.googleapis.com"         # For service account credentials
    "compute.googleapis.com"                # For basic compute operations
    "serviceusage.googleapis.com"           # For enabling other APIs
    "servicenetworking.googleapis.com"
    "artifactregistry.googleapis.com"
)

# Add PKI-strategy-specific APIs
if [ "$PKI_STRATEGY" == "remote" ]; then
    REQUIRED_APIS+=("dns.googleapis.com")
    REQUIRED_APIS+=("privateca.googleapis.com")
fi

echo "Checking and enabling APIs (this may take a few minutes)..."

# Check which APIs are disabled and enable them
APIS_TO_ENABLE=()
for api in "${REQUIRED_APIS[@]}"; do
    if ! gcloud services list --enabled --filter="name:$api" --format="value(name)" 2>/dev/null | grep -q "$api"; then
        echo "  - $api (disabled, will enable)"
        APIS_TO_ENABLE+=("$api")
    else
        echo "  ✓ $api (already enabled)"
    fi
done

# Enable all disabled APIs in one batch operation
if [ ${#APIS_TO_ENABLE[@]} -gt 0 ]; then
    echo "Enabling ${#APIS_TO_ENABLE[@]} API(s)..."
    gcloud services enable "${APIS_TO_ENABLE[@]}" --project="$GCP_PROJECT_ID"

    echo "Waiting for APIs to propagate (30 seconds)..."
    sleep 30
    echo -e "${COLOR_GREEN}APIs enabled successfully.${COLOR_NC}"
else
    echo -e "${COLOR_GREEN}All required APIs are already enabled.${COLOR_NC}"
fi
echo


# 4. GitHub Vars (Part 1)
echo -e "${COLOR_YELLOW}Step 4: Setting Initial GitHub Variables...${COLOR_NC}"
GCP_PROJECT_NUMBER=$(gcloud projects describe "$GCP_PROJECT_ID" --format="value(projectNumber)")
GCP_WORKLOAD_IDENTITY_POOL_ID="${ENV}-github-wif-${RANDOM_SUFFIX}"
GCP_WORKLOAD_IDENTITY_PROVIDER_ID="github"

gh api --method PUT -H "Accept: application/vnd.github+json" repos/"${GITHUB_REPO}"/environments/"$ENV" || true
# save variables for Github Actions workflows, re-use local
gh variable set GCP_PROJECT_ID -b "$GCP_PROJECT_ID" --repo "$GITHUB_REPO" --env "$ENV"
gh variable set GCP_PROJECT_NUMBER -b "$GCP_PROJECT_NUMBER" --repo "$GITHUB_REPO" --env "$ENV"
gh variable set GCP_REGION -b "$GCP_REGION" --repo "$GITHUB_REPO" --env "$ENV"
gh variable set GCP_WORKLOAD_IDENTITY_POOL_ID -b "$GCP_WORKLOAD_IDENTITY_POOL_ID" --repo "$GITHUB_REPO" --env "$ENV"
gh variable set GCP_WORKLOAD_IDENTITY_PROVIDER_ID -b "$GCP_WORKLOAD_IDENTITY_PROVIDER_ID" --repo "$GITHUB_REPO" --env "$ENV"
if [ "$PKI_STRATEGY" = "remote" ]; then
    gh variable set GCP_SERVER_CA_POOL -b "$CREATED_SERVER_CA_POOL" --repo "$GITHUB_REPO" --env "$ENV"
fi

echo -e "${COLOR_GREEN}Done.${COLOR_NC}\n"

echo -e "${COLOR_GREEN}Following GitHub variables are present:${COLOR_NC}"
echo -e "${COLOR_GREEN}  - GCP_PROJECT_ID: $GCP_PROJECT_ID${COLOR_NC}"
echo -e "${COLOR_GREEN}  - GCP_PROJECT_NUMBER: $GCP_PROJECT_NUMBER${COLOR_NC}"
echo -e "${COLOR_GREEN}  - GCP_REGION: $GCP_REGION${COLOR_NC}"
echo -e "${COLOR_GREEN}  - GCP_WORKLOAD_IDENTITY_POOL_ID: $GCP_WORKLOAD_IDENTITY_POOL_ID${COLOR_NC}"
echo -e "${COLOR_GREEN}  - GCP_WORKLOAD_IDENTITY_PROVIDER_ID: $GCP_WORKLOAD_IDENTITY_PROVIDER_ID${COLOR_NC}"
if [ "$PKI_STRATEGY" = "remote" ]; then
    echo -e "${COLOR_GREEN}  - GCP_SERVER_CA_POOL: $CREATED_SERVER_CA_POOL${COLOR_NC}"
fi
echo -e "${COLOR_GREEN}  - PKI_STRATEGY: $PKI_STRATEGY${COLOR_NC}"
echo

# 5. TF State
echo -e "${COLOR_YELLOW}Step 5: Terraform State Bucket...${COLOR_NC}"
TF_BUCKET="${GCP_PROJECT_ID}-tfstate"
if ! gsutil ls -b "gs://${TF_BUCKET}" &> /dev/null; then
    gcloud storage buckets create gs://"${TF_BUCKET}" --location="$GCP_REGION" --uniform-bucket-level-access
    gcloud storage buckets update gs://"${TF_BUCKET}" --versioning
fi
rm -rf iac/terraform/.terraform/terraform.tfstate || true
cd iac/terraform

# 6. Terraform Apply
echo -e "${COLOR_YELLOW}Step 6: Building Infrastructure (Terraform)...${COLOR_NC}"
echo "Strategy: $PKI_STRATEGY"
terraform init -backend-config="bucket=${TF_BUCKET}"

terraform apply \
  -var="project_id=${GCP_PROJECT_ID}" \
  -var="region=${GCP_REGION}" \
  -var="environment=${ENV}" \
  -var="zone=${GCP_REGION}-a" \
  -var="random_suffix=${RANDOM_SUFFIX}" \
  -var="repository=${GITHUB_REPO}" \
  -var="github_org=${GITHUB_REPO%/*}/" \
  -var="pki_strategy=${PKI_STRATEGY}" \
  -var="base_domain=${BASE_DOMAIN}" \
  -var="existing_dns_zone=${EXISTING_DNS_ZONE}" \
  -var="keycloak_hostname=${KEYCLOAK_HOSTNAME}" \
  -var="nats_hostname=${NATS_HOSTNAME}" \
  -var="registration_hostname=${REGISTRATION_HOSTNAME}" \
  -var="existing_server_ca=${EXISTING_SERVER_CA}" \
  -var="existing_server_ca_pool=${EXISTING_SERVER_CA_POOL}" \
  -var="existing_factory_ca=${EXISTING_FACTORY_CA}" \
  -var="existing_factory_ca_pool=${EXISTING_FACTORY_CA_POOL}" \
  -var="existing_reg_ca=${EXISTING_REG_CA}" \
  -var="existing_reg_ca_pool=${EXISTING_REG_CA_POOL}" \
  -var="created_reg_ca_pool=${CREATED_REG_CA_POOL}" \
  -var="created_server_ca_pool=${CREATED_SERVER_CA_POOL}" \
  -var="created_factory_ca_pool=${CREATED_FACTORY_CA_POOL}" \
  -var="wif_pool_id=${GCP_WORKLOAD_IDENTITY_POOL_ID}" \
  -var="wif_provider_id=${GCP_WORKLOAD_IDENTITY_PROVIDER_ID}" -auto-approve

SERVICE_ACCOUNT=$(terraform output -raw service_account_email)
KEYCLOAK_DB_PASSWORD=$(terraform output -raw keycloak_db_password)
cd ../..

# 6.1 GitHub Vars (Part 2)
echo -e "${COLOR_YELLOW}Step 6.1: Finalizing GitHub Variables...${COLOR_NC}"
gh variable set GCP_SERVICE_ACCOUNT -b "$SERVICE_ACCOUNT" --repo "$GITHUB_REPO" --env "$ENV"

echo -e "${COLOR_GREEN}Following GCP service account is created by terraform:${COLOR_NC}"
echo -e "${COLOR_GREEN}  - GCP_SERVICE_ACCOUNT: $SERVICE_ACCOUNT${COLOR_NC}"

echo -e "${COLOR_GREEN}Infrastructure ready.${COLOR_NC}\n"

# 7. Store configuration in Secret Manager (not GitHub variables)
echo -e "${COLOR_YELLOW}Step 7: Storing configuration in Secret Manager...${COLOR_NC}"
# Note: The 5 required GitHub variables must already exist and are never modified
# All other configuration is stored in Secret Manager
echo -e "${COLOR_GREEN}Configuration will be stored in Secret Manager (Step 8).${COLOR_NC}"

# 8. Secrets & Config
echo -e "${COLOR_YELLOW}Step 8: Configuring Secrets, DNS & PKI...${COLOR_NC}"

add_secret() {
    local secret_name="$1"
    local secret_value="$2"

    local create_output
    # Step 1: Attempt to create the secret
    create_output=$(gcloud secrets create "$secret_name" --replication-policy="automatic" --project="$GCP_PROJECT_ID" 2>&1) || {
        # This block runs ONLY if gcloud exits non-zero (creation failed)

        # Step 2: Check WHY it failed
        if ! echo "$create_output" | grep -q "already exists"; then
            # Error is NOT "already exists" → real problem (permissions, quota, etc.)
            echo "ERROR: Failed to create secret $secret_name: $create_output" >&2
            return 1
        fi
        # Error IS "already exists" → expected on re-runs, continue normally
    }
    # Step 3: Add new version (runs whether secret was just created or already existed)
    echo -n "$secret_value" | gcloud secrets versions add "$secret_name" --data-file=- --project="$GCP_PROJECT_ID" --quiet
}

# --- 8a. Infrastructure Secrets ---
add_secret "KEYCLOAK_GCP_SERVICE_ACCOUNT" "keycloak-gsa@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
add_secret "BIGTABLE_CONNECTOR_GCP_SERVICE_ACCOUNT" "bigtable-connector@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
add_secret "DATA_API_BIGTABLE_CONNECTOR_GCP_SERVICE_ACCOUNT" "data-api-bigtable-connector@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
add_secret "KEYCLOAK_DB_PASSWORD" "${KEYCLOAK_DB_PASSWORD}"
add_secret "KEYCLOAK_ADMIN_PASSWORD" "$(openssl rand -base64 32)"
# NATS credentials:
# - NATS_SERVER_USER/PASSWORD: Main admin user with full NATS access (publish, subscribe, admin)
# - NATS_AUTH_CALLOUT_PASSWORD: Service user for nats-auth-callout pod (basic auth, bypasses JWT)
# - NATS_CONNECTOR_PASSWORD: Restricted user "connector" with read-only access to telemetry topics only (principle of least privilege)
add_secret "NATS_SERVER_USER" "nats-user"
add_secret "NATS_SERVER_PASSWORD" "$(openssl rand -hex 32)"
add_secret "NATS_AUTH_CALLOUT_PASSWORD" "$(openssl rand -hex 32)"
add_secret "NATS_CONNECTOR_PASSWORD" "$(openssl rand -hex 32)"
add_secret "KEYCLOAK_INSTANCE_CON_SQL_PROXY" "${GCP_PROJECT_ID}:${GCP_REGION}:cloud-sql-${ENV}"
add_secret "IMAGE_REPO" "${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/artifact-registry"

NKEY_OUT=$(nk -gen account -pubout)
add_secret "JWT_ACC_SIGNING_KEY" "$(echo "$NKEY_OUT" | sed -n '1p')"
add_secret "NATS_AUTH_CALLOUT_NKEY_PUB" "$(echo "$NKEY_OUT" | sed -n '2p')"


# --- 8b. DNS, BASE_DOMAIN & PKI Configuration (Remote only) ---
if [ "$PKI_STRATEGY" == "remote" ]; then
    add_secret "BASE_DOMAIN" "$BASE_DOMAIN"

    # Store CA pool names and CA names in Secret Manager for workflows to use
    SERVER_CA_POOL_NAME="${EXISTING_SERVER_CA_POOL:-$CREATED_SERVER_CA_POOL}"
    FACTORY_CA_POOL_NAME="${EXISTING_FACTORY_CA_POOL:-$CREATED_FACTORY_CA_POOL}"
    SERVER_CA_NAME="${EXISTING_SERVER_CA:-server-ca}"
    FACTORY_CA_NAME="${EXISTING_FACTORY_CA:-factory-ca}"

    add_secret "SERVER_CA_POOL" "$SERVER_CA_POOL_NAME"
    add_secret "FACTORY_CA_POOL" "$FACTORY_CA_POOL_NAME"
    add_secret "SERVER_CA" "$SERVER_CA_NAME"
    add_secret "FACTORY_CA" "$FACTORY_CA_NAME"

    # Store hostnames
    add_secret "KEYCLOAK_HOSTNAME" "$KEYCLOAK_HOSTNAME"
    add_secret "NATS_HOSTNAME" "$NATS_HOSTNAME"
    add_secret "REGISTRATION_HOSTNAME" "$REGISTRATION_HOSTNAME"

    echo "Stored PKI configuration in Secret Manager:"
    echo "  SERVER_CA_POOL: $SERVER_CA_POOL_NAME"
    echo "  SERVER_CA: $SERVER_CA_NAME"
    echo "  FACTORY_CA_POOL: $FACTORY_CA_POOL_NAME"
    echo "  FACTORY_CA: $FACTORY_CA_NAME"

    echo -e "${COLOR_BLUE}Checking Cloud DNS configuration...${COLOR_NC}"
    cd iac/terraform
    NAME_SERVERS=$(terraform output -json name_servers | jq -r '.[]')
    cd ../..

    if [ -n "$NAME_SERVERS" ]; then
        echo -e "${COLOR_GREEN}Cloud DNS Zone '${BASE_DOMAIN}' is managed by Terraform.${COLOR_NC}"
        echo -e "${COLOR_YELLOW}>>> ACTION REQUIRED: Update your Domain Registrar with these Nameservers: <<<${COLOR_NC}"
        echo "$NAME_SERVERS"
        echo -e "${COLOR_YELLOW}>>> -------------------------------------------------------------------- <<<${COLOR_NC}"
    fi
fi


# ==============================================================================
# 8c. PKI GENERATION (The Glue for Python Client)
# ==============================================================================
echo -e "${COLOR_BLUE}Initializing PKI ($PKI_STRATEGY)...${COLOR_NC}"

# PATHS MATCHING YOUR PYTHON CODE
PKI_DIR="./base-services/registration/pki"
PYTHON_CERTS_DIR="./base-services/registration/python/certificates"

# Clean slate
rm -rf "$PKI_DIR/server-ca" "$PKI_DIR/factory-ca" "$PKI_DIR/registration-ca"
mkdir -p "$PKI_DIR/server-ca/keycloak" "$PKI_DIR/server-ca/registration" \
         "$PKI_DIR/factory-ca" "$PKI_DIR/registration-ca" \
         "$PYTHON_CERTS_DIR"

if [ "$PKI_STRATEGY" == "local" ]; then
    # === LOCAL MODE: Full CA Generation ===
    # All CAs include Key Usage extension (required by Python/OpenSSL 3.x)
    echo "Generating Local CAs..."

    # 1. Factory CA (with Key Usage extension)
    cat > "$PKI_DIR/factory-ca/ca.conf" <<FACTORYEOF
[ req ]
default_bits       = 4096
default_md         = sha256
distinguished_name = req_distinguished_name
x509_extensions    = v3_ca
prompt             = no

[ req_distinguished_name ]
CN = Nexus Factory CA (Local)
O  = Nexus

[ v3_ca ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical, CA:TRUE
keyUsage               = critical, keyCertSign, cRLSign
FACTORYEOF
    openssl req -x509 -newkey rsa:4096 -days 3650 -nodes \
        -keyout "$PKI_DIR/factory-ca/ca.key.pem" -out "$PKI_DIR/factory-ca/ca.crt.pem" \
        -config "$PKI_DIR/factory-ca/ca.conf"

    # 2. Server CA (with Key Usage extension)
    cat > "$PKI_DIR/server-ca/ca.conf" <<SERVEREOF
[ req ]
default_bits       = 4096
default_md         = sha256
distinguished_name = req_distinguished_name
x509_extensions    = v3_ca
prompt             = no

[ req_distinguished_name ]
CN = Nexus Server CA (Local)
O  = Nexus

[ v3_ca ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical, CA:TRUE
keyUsage               = critical, keyCertSign, cRLSign
SERVEREOF
    openssl req -x509 -newkey rsa:4096 -days 3650 -nodes \
        -keyout "$PKI_DIR/server-ca/ca.key.pem" -out "$PKI_DIR/server-ca/ca.crt.pem" \
        -config "$PKI_DIR/server-ca/ca.conf"

    # 3. Registration CA (with Key Usage extension)
    cat > "$PKI_DIR/registration-ca/ca.conf" <<REGEOF
[ req ]
default_bits       = 4096
default_md         = sha256
distinguished_name = req_distinguished_name
x509_extensions    = v3_ca
prompt             = no

[ req_distinguished_name ]
CN = Nexus Registration CA (Local)
O  = Nexus

[ v3_ca ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical, CA:TRUE
keyUsage               = critical, keyCertSign, cRLSign
REGEOF
    openssl req -x509 -newkey rsa:4096 -days 3650 -nodes \
        -keyout "$PKI_DIR/registration-ca/ca.key.pem" -out "$PKI_DIR/registration-ca/ca.crt.pem" \
        -config "$PKI_DIR/registration-ca/ca.conf"

    # 4. Keycloak server certificate (signed by Server CA)
    cat > "$PKI_DIR/server-ca/keycloak/keycloak.ext" <<KCEXTEOF
basicConstraints       = critical, CA:FALSE
keyUsage               = critical, digitalSignature, keyEncipherment
extendedKeyUsage       = serverAuth
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer
subjectAltName         = @alt_names

[ alt_names ]
IP.1  = 127.0.0.1
DNS.1 = localhost
DNS.2 = keycloak
KCEXTEOF
    openssl req -new -newkey rsa:2048 -nodes \
        -keyout "$PKI_DIR/server-ca/keycloak/keycloak.key.pem" \
        -out "$PKI_DIR/server-ca/keycloak/keycloak.csr.pem" -subj "/CN=127.0.0.1"
    openssl x509 -req -days 730 -in "$PKI_DIR/server-ca/keycloak/keycloak.csr.pem" \
        -CA "$PKI_DIR/server-ca/ca.crt.pem" -CAkey "$PKI_DIR/server-ca/ca.key.pem" -CAcreateserial \
        -out "$PKI_DIR/server-ca/keycloak/keycloak.crt.pem" \
        -extfile "$PKI_DIR/server-ca/keycloak/keycloak.ext"

    # 5. Registration server certificate (signed by Server CA)
    cat > "$PKI_DIR/server-ca/registration/registration.ext" <<REGEXTEOF
basicConstraints       = critical, CA:FALSE
keyUsage               = critical, digitalSignature, keyEncipherment
extendedKeyUsage       = serverAuth
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer
subjectAltName         = @alt_names

[ alt_names ]
IP.1  = 127.0.0.1
DNS.1 = localhost
DNS.2 = registration
REGEXTEOF
    openssl req -new -newkey rsa:2048 -nodes \
        -keyout "$PKI_DIR/server-ca/registration/registration.key.pem" \
        -out "$PKI_DIR/server-ca/registration/registration.csr.pem" -subj "/CN=127.0.0.1"
    openssl x509 -req -days 730 -in "$PKI_DIR/server-ca/registration/registration.csr.pem" \
        -CA "$PKI_DIR/server-ca/ca.crt.pem" -CAkey "$PKI_DIR/server-ca/ca.key.pem" -CAcreateserial \
        -out "$PKI_DIR/server-ca/registration/registration.crt.pem" \
        -extfile "$PKI_DIR/server-ca/registration/registration.ext"

    # Legacy config templates for compatibility
    cat > "$PKI_DIR/server-ca/keycloak/keycloak.conf" <<KCCONFEOF
[ req ]
distinguished_name = req_distinguished_name
[ req_distinguished_name ]
[ alt_names ]
IP.1 = 127.0.0.1
KCCONFEOF
    cp "$PKI_DIR/server-ca/keycloak/keycloak.conf" "$PKI_DIR/server-ca/registration/registration.conf"

else
    # === REMOTE MODE: Google CAS ===
    echo "Downloading Remote CAs..."

    # 1. Download Trust Anchors
    # Download Server CA (existing or newly created)
    if [ -n "$EXISTING_SERVER_CA" ]; then
        echo "Using existing Server CA: $EXISTING_SERVER_CA from pool $EXISTING_SERVER_CA_POOL"
        gcloud privateca roots describe "$EXISTING_SERVER_CA" \
            --pool="$EXISTING_SERVER_CA_POOL" \
            --location="$GCP_REGION" \
            --format="value(pemCaCertificates)" > "$PKI_DIR/server-ca/ca.crt.pem"
    else
        echo "Using newly created Server CA from server-ca-pool"
        gcloud privateca roots list --pool="$CREATED_SERVER_CA_POOL" --location="$GCP_REGION" --format="value(pemCaCertificates)" --limit=1 > "$PKI_DIR/server-ca/ca.crt.pem"
    fi

    # Download Factory CA (existing or newly created)
    if [ -n "$EXISTING_FACTORY_CA" ]; then
        echo "Using existing Factory CA: $EXISTING_FACTORY_CA from pool $EXISTING_FACTORY_CA_POOL"
        gcloud privateca roots describe "$EXISTING_FACTORY_CA" \
            --pool="$EXISTING_FACTORY_CA_POOL" \
            --location="$GCP_REGION" \
            --format="value(pemCaCertificates)" > "$PKI_DIR/factory-ca/ca.crt.pem"
        FACTORY_POOL_FOR_CLIENT="$EXISTING_FACTORY_CA_POOL"
    else
        echo "Using newly created Factory CA from factory-ca-pool"
        gcloud privateca roots list --pool="$CREATED_FACTORY_CA_POOL" --location="$GCP_REGION" --format="value(pemCaCertificates)" --limit=1 > "$PKI_DIR/factory-ca/ca.crt.pem"
        FACTORY_POOL_FOR_CLIENT="$CREATED_FACTORY_CA_POOL"
    fi

    # Generate local Registration CA if it doesn't exist
    # (Registration server needs the private key to sign vehicle operational certs)
    echo "Checking for local Registration CA..."
    if [ ! -f "$PKI_DIR/registration-ca/ca.key.pem" ] || [ ! -f "$PKI_DIR/registration-ca/ca.crt.pem" ]; then
        echo "Generating new local Registration CA..."

        # Generate private key
        openssl genrsa -out "$PKI_DIR/registration-ca/ca.key.pem" 4096

        # Generate self-signed certificate
        openssl req -new -x509 -days 3650 -key "$PKI_DIR/registration-ca/ca.key.pem" \
          -out "$PKI_DIR/registration-ca/ca.crt.pem" \
          -subj "/C=US/ST=State/L=City/O=SDV/OU=Registration/CN=Registration CA"

        echo "✓ Local Registration CA generated"
    else
        echo "✓ Local Registration CA already exists"
    fi

    # NOTE: We DO NOT download ca.key.pem for Factory CA because it's managed by Google.
    # We must pre-generate the client certificate here because factory.py cannot do it without the key.

    echo "Pre-generating Client Cert via Google CAS (Remote)..."

    # Generate Key locally
    openssl genpkey -algorithm RSA -out "$PYTHON_CERTS_DIR/client.key.pem"

    # Generate CSR
    openssl req -new -key "$PYTHON_CERTS_DIR/client.key.pem" \
        -out "$PYTHON_CERTS_DIR/client.csr.pem" \
        -subj "/CN=VIN:12345678901234567 DEVICE:car/O=Valtech Mobility GmbH"

    # Request signature from Factory CA (use the correct pool)
    # Use correct flags: --issuer-pool, --issuer-location, --csr
    gcloud privateca certificates create "car-$(date +%s)" \
        --issuer-pool="$FACTORY_POOL_FOR_CLIENT" --issuer-location="$GCP_REGION" \
        --csr="$PYTHON_CERTS_DIR/client.csr.pem" \
        --cert-output-file="$PYTHON_CERTS_DIR/client.crt.pem" \
        --validity="P30D" --quiet

    echo "Client Certificate placed in $PYTHON_CERTS_DIR"

    # Create dummy placeholders so subsequent file references don't fail
    touch "$PKI_DIR/server-ca/keycloak/keycloak.crt.pem"
    touch "$PKI_DIR/server-ca/keycloak/keycloak.key.pem"

    # --- Save created CA pool names for future runs ---
    # If we created new CAs (EXISTING_* were empty), save them to .bootstrap_env
    # so they can be reused on re-runs instead of creating new ones.
    # CA names match what Terraform creates in pki.tf: server-root-ca, factory-root-ca, registration-root-ca
    if [ -z "$EXISTING_SERVER_CA" ]; then
        echo "Saving created CA pools to $ENV_FILE for future runs..."
        sed -i '' "s|^EXISTING_SERVER_CA=.*|EXISTING_SERVER_CA=\"server-root-ca\"|" "$ENV_FILE"
        sed -i '' "s|^EXISTING_SERVER_CA_POOL=.*|EXISTING_SERVER_CA_POOL=\"${CREATED_SERVER_CA_POOL}\"|" "$ENV_FILE"
        sed -i '' "s|^EXISTING_FACTORY_CA=.*|EXISTING_FACTORY_CA=\"factory-root-ca\"|" "$ENV_FILE"
        sed -i '' "s|^EXISTING_FACTORY_CA_POOL=.*|EXISTING_FACTORY_CA_POOL=\"${CREATED_FACTORY_CA_POOL}\"|" "$ENV_FILE"
        sed -i '' "s|^EXISTING_REG_CA=.*|EXISTING_REG_CA=\"registration-root-ca\"|" "$ENV_FILE"
        sed -i '' "s|^EXISTING_REG_CA_POOL=.*|EXISTING_REG_CA_POOL=\"${CREATED_REG_CA_POOL}\"|" "$ENV_FILE"
        echo "✓ CA configuration saved for reuse"
    fi
fi

# --- 8d. Initial Secret Upload ---
# Only upload Keycloak TLS secrets in local mode (they're empty in remote mode)
if [ "$PKI_STRATEGY" == "local" ]; then
    echo "Uploading Initial TLS Secrets..."
    add_secret "KEYCLOAK_TLS_CRT" "$(cat $PKI_DIR/server-ca/keycloak/keycloak.crt.pem)"
    add_secret "KEYCLOAK_TLS_KEY" "$(cat $PKI_DIR/server-ca/keycloak/keycloak.key.pem)"
else
    echo "Skipping Keycloak TLS secret upload (will be generated by pipeline in remote mode)..."
fi

# Upload Registration CA Certificates
echo "Uploading Registration CA certificates to Secret Manager..."

if [ "$PKI_STRATEGY" = "local" ]; then
    # LOCAL mode: Upload all CA certs and keys (server certs generated by workflow after deployment)
    add_secret "SERVER_CA_CERT" "$(cat $PKI_DIR/server-ca/ca.crt.pem)"
    add_secret "SERVER_CA_KEY" "$(cat $PKI_DIR/server-ca/ca.key.pem)"
    add_secret "REGISTRATION_CA_CERT" "$(cat $PKI_DIR/registration-ca/ca.crt.pem)"
    add_secret "REGISTRATION_CA_KEY" "$(cat $PKI_DIR/registration-ca/ca.key.pem)"
    add_secret "REGISTRATION_FACTORY_CA_CERT" "$(cat $PKI_DIR/factory-ca/ca.crt.pem)"
    echo "✓ All CA certificates and keys uploaded to Secret Manager (LOCAL mode)"
    echo "  Note: Server certificates (registration, keycloak) will be generated by GitHub Actions workflows after deployment"
else
    # REMOTE mode: Skip server certs (generated by pipeline), upload CA certs and Registration CA key
    add_secret "REGISTRATION_CA_CERT" "$(cat $PKI_DIR/registration-ca/ca.crt.pem)"
    add_secret "REGISTRATION_CA_KEY" "$(cat $PKI_DIR/registration-ca/ca.key.pem)"
    add_secret "REGISTRATION_FACTORY_CA_CERT" "$(cat $PKI_DIR/factory-ca/ca.crt.pem)"
    echo "✓ CA certificates uploaded (REMOTE mode)"
    echo "✓ Registration CA key uploaded (for signing vehicle operational certs)"
    echo "  Note: Server certificates will be generated by GitHub Actions pipeline"
fi

# --- 9. Platform deployment via GitHub Actions ---
echo -e "${COLOR_YELLOW}Step 9: Start and monitor the deployment pipeline...${COLOR_NC}"
WORKFLOW_NAME="bootstrap-platform.yml"

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
WORKFLOW_REF="$CURRENT_BRANCH"

echo "Checking for previous runs on branch '$WORKFLOW_REF'..."
OLD_RUN_ID=$(gh run list --workflow="$WORKFLOW_NAME" --repo="$GITHUB_REPO" --branch "$WORKFLOW_REF" --event workflow_dispatch --limit 1 --json databaseId --jq '.[0].databaseId')

if [ -z "$OLD_RUN_ID" ] || [ "$OLD_RUN_ID" == "null" ]; then
    OLD_RUN_ID="0"
fi

echo "Triggering workflow on branch: '$WORKFLOW_REF' (Previous Run ID: $OLD_RUN_ID)"

if gh workflow run "$WORKFLOW_NAME" --repo "$GITHUB_REPO" --ref "$WORKFLOW_REF" -f environment="$ENV" -f pki_strategy="$PKI_STRATEGY" -f base_domain="$BASE_DOMAIN"; then
    echo "Workflow triggered. Waiting for new run to appear..."

    RUN_ID=""
    for _ in {1..20}; do
        sleep 5

        LATEST_RUN_JSON=$(gh run list --workflow="$WORKFLOW_NAME" --repo="$GITHUB_REPO" --branch "$WORKFLOW_REF" --event workflow_dispatch --limit 1 --json databaseId,status --jq '.[0]')

        if [ -z "$LATEST_RUN_JSON" ] || [ "$LATEST_RUN_JSON" == "null" ]; then
            continue
        fi

        FOUND_ID=$(echo "$LATEST_RUN_JSON" | jq -r '.databaseId')

        if [ "$FOUND_ID" != "$OLD_RUN_ID" ]; then
            RUN_ID="$FOUND_ID"
            break
        else
            echo -ne "Waiting for new run... (Current latest: $FOUND_ID)\r"
        fi
    done
    echo ""

    if [ -z "$RUN_ID" ]; then
        echo -e "${COLOR_RED}ERROR: Could not find the new Run ID after 100 seconds. Check GitHub Actions manually.${COLOR_NC}"
        exit 1
    fi

    echo "Monitoring New Run ID: $RUN_ID"

    if ! gh run watch "$RUN_ID" --repo "$GITHUB_REPO" --exit-status; then
        echo -e "${COLOR_YELLOW}WARNING: Connection lost locally. Checking status on GitHub...${COLOR_NC}"
        FINAL_STATUS=$(gh run view "$RUN_ID" --repo "$GITHUB_REPO" --json conclusion --jq '.conclusion')

        if [ "$FINAL_STATUS" == "success" ]; then
             echo -e "${COLOR_GREEN}GitHub Actions deployment pipeline successfully completed!${COLOR_NC}"
        else
             echo -e "${COLOR_RED}ERROR: Pipeline failed with status: '$FINAL_STATUS'.${COLOR_NC}"
             exit 1
        fi
    else
        echo -e "${COLOR_GREEN}GitHub Actions deployment pipeline successfully completed!${COLOR_NC}"
    fi
else
    echo -e "${COLOR_RED}ERROR: Could not start the GitHub Actions workflow.${COLOR_NC}"
    exit 1
fi

# --- 10. Update environment variables with generated hostnames
if [ "$PKI_STRATEGY" == "local" ]; then
    echo -e "\n\nUpdating environment file with the IP addresses from GCP secretmanager\n"
    GCP_REGISTRATION_HOSTNAME=$(gcloud secrets versions access latest --secret="REGISTRATION_HOSTNAME")
    GCP_NATS_HOSTNAME=$(gcloud secrets versions access latest --secret="NATS_HOSTNAME")
    GCP_KEYCLOAK_HOSTNAME=$(gcloud secrets versions access latest --secret="KEYCLOAK_HOSTNAME")

    echo "REGISTRATION_HOSTNAME: ${GCP_REGISTRATION_HOSTNAME}"
    echo "NATS_HOSTNAME: ${GCP_NATS_HOSTNAME}"
    echo "KEYCLOAK_HOSTNAME ${GCP_KEYCLOAK_HOSTNAME}"

    sed -i '' "s|^REGISTRATION_HOSTNAME=.*|REGISTRATION_HOSTNAME=\"${GCP_REGISTRATION_HOSTNAME}\"|" "$ENV_FILE"
    sed -i '' "s|^NATS_HOSTNAME=.*|NATS_HOSTNAME=\"${GCP_NATS_HOSTNAME}\"|" "$ENV_FILE"
    sed -i '' "s|^KEYCLOAK_HOSTNAME=.*|KEYCLOAK_HOSTNAME=\"${GCP_KEYCLOAK_HOSTNAME}\"|" "$ENV_FILE"
fi

# --- Final message ---
echo -e "${COLOR_GREEN}==================================================================${COLOR_NC}"
echo -e "${COLOR_GREEN}  🎉 Nexus SDV platform bootstrapping successfully completed! 🎉  ${COLOR_NC}"
echo -e "${COLOR_GREEN}==================================================================${COLOR_NC}"
echo "Your Nexus SDV environment is now ready for use."