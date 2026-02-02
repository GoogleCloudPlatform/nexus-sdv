#!/bin/bash
# ==============================================================================
# Nexus SDV Teardown Script v1.0
#
# This script performs a complete, automated teardown of the Nexus SDV GCP Platform
#
# Author: Team Sky
# Version: 1.0
# ==============================================================================

# Terminates the script immediately if a command fails or a variable is not set
set -euo pipefail

# --- Colour variables for improved readability of the output ---
COLOR_GREEN='\033[0;32m'
COLOR_BLUE='\033[0;34m'
COLOR_YELLOW='\033[1;33m'
COLOR_RED='\033[0;31m'
COLOR_NC='\033[0m' # No Color

# --- Parse command line arguments ---
AUTO_APPROVE=false

# Show usage information
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -y, --yes          Auto-approve: skip all prompts and use default options (delete all resources)"
    echo "  -h, --help         Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                 # Interactive mode with prompts"
    echo "  $0 --yes           # Non-interactive mode, delete everything"
    echo ""
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -y|--yes)
            AUTO_APPROVE=true
            echo -e "${COLOR_YELLOW}Auto-approve mode: All prompts will use default values (delete resources)${COLOR_NC}"
            echo ""
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            echo -e "${COLOR_RED}Unknown option: $1${COLOR_NC}"
            show_usage
            exit 1
            ;;
    esac
done

# --- Help functions ---
check_all_prerequisites() {
    local missing_prerequisites=()

    # loop for all arguments given to function
    for tool in "$@"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_prerequisites+=("$tool")
        fi
    done

    # checks if list is empty or not
    if [ ${#missing_prerequisites[@]} -gt 0 ]; then
        echo -e "${COLOR_RED}ERROR: The following necessary tools were not found:${COLOR_NC}"

        # output all missing tools
        for tool in "${missing_prerequisites[@]}"; do
            echo -e "${COLOR_RED}  - $tool${COLOR_NC}"
        done

        echo -e "${COLOR_RED}Please install them and run the script again.${COLOR_NC}"
        exit 1
    fi
}

load_github_environment_variables() {
    local GITHUB_REPO="$1"
    local ENV_NAME="$2"

    echo "Loading variables from Github Repo $GITHUB_REPO & environment '$ENV_NAME'..."

    local variables_json
    variables_json=$(gh variable list --env "$ENV_NAME" --repo "$GITHUB_REPO" --json name,value)

    if [ -z "$variables_json" ]; then
        echo -e "${COLOR_RED}Error: Failed loading variables from Github.${COLOR_NC}"
        echo "Check that the repo, environment, and your permissions are correct."
        exit 1
    fi

    while read -r line; do
        local VAR_NAME
        local VAR_VALUE

        VAR_NAME=$(echo "$line" | jq -r '.name')
        VAR_VALUE=$(echo "$line" | jq -r '.value')

        export "$VAR_NAME"="$VAR_VALUE"

        echo -e "  ${COLOR_GREEN}✓ Loaded: $VAR_NAME${COLOR_NC}"
    done < <(echo "$variables_json" | jq -c '.[]')

    echo -e "${COLOR_GREEN}All environment variables successfully loaded.${COLOR_NC}"
    echo
}

echo -e "${COLOR_BLUE}=======================================================${COLOR_NC}"
echo -e "${COLOR_BLUE} Nexus SDV platform teardown process is starting...   ${COLOR_NC}"
echo -e "${COLOR_BLUE}=======================================================${COLOR_NC}"
echo

# --- 1. Checking the requirements ---
echo -e "${COLOR_YELLOW}Step 1: Checking for necessary prerequisites...${COLOR_NC}"
check_all_prerequisites "gcloud" "gh" "jq"
echo -e "${COLOR_GREEN}All necessary prerequisites are available.${COLOR_NC}"
echo

# --- 2. Configuration & Authentication ---
echo -e "${COLOR_YELLOW}Step 2: Configuring the Github CLI and authentication...${COLOR_NC}"
# This avoids repeated login prompts if the user is already authenticated.
if ! gcloud auth print-access-token &>/dev/null; then
    echo "gcloud authentication required."
    gcloud auth login
    gcloud auth application-default login
fi

if ! gh auth status &>/dev/null; then
    #but there mit be problem with bash so check again
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


echo -e "${COLOR_GREEN}Authentication checks passed.${COLOR_NC}\n"

# --- 3. Query user inputs ---
# --- .env file for persistence ---
# Load saved configuration from a .bootstrap_env file to avoid re-entering values.
ENV_FILE="iac/bootstrapping/.bootstrap_env"
if [ -f "$ENV_FILE" ]; then
    echo "Loading saved configuration from $ENV_FILE..."
    source "$ENV_FILE"
fi

echo -e "${COLOR_YELLOW}Step 3: Please enter your Github project details.${COLOR_NC}"
# --- GitHub Repo ---
DEFAULT_GITHUB_REPO=${GITHUB_REPO:-""}
read -rp "Enter your GitHub repository (format: 'owner/repo'):  [${DEFAULT_GITHUB_REPO}]: " INPUT_GITHUB_REPO
GITHUB_REPO=${INPUT_GITHUB_REPO:-$DEFAULT_GITHUB_REPO}

DEFAULT_ENV=${ENV:-"sandbox"}
while true; do
    read -rp "Specify the environment (e.g. 'dev', 'prod') you have set during the bootstrap-platform process: [${DEFAULT_ENV}]: " INPUT_ENV
    ENV=${INPUT_ENV:-$DEFAULT_ENV}
    # condition that checks the input's length
    if [ ${#ENV} -le 15 ]; then
        # success: length is 15 or shorter
        echo -e "${COLOR_GREEN}Input '$ENV' as environment is valid. Checking existence...${COLOR_NC}"
        if gh api "repos/${GITHUB_REPO}/environments/${ENV}" > /dev/null 2>&1; then
            echo -e "${COLOR_GREEN}The environment '$ENV' exists within $GITHUB_REPO.${COLOR_NC}"
            break
        else
            echo -e "${COLOR_RED}The environment '$ENV' does not exist within $GITHUB_REPO (or you lack permissions). Please try again.${COLOR_NC}"
        fi
    else
        # error: length is more than 15
        echo -e "${COLOR_RED}ERROR: The input is too long (${#ENV} characters). Please use a maximum of 15 characters.${COLOR_NC}"
        echo
    fi
done

# --- 4a. Load Github variables ---
echo -e "${COLOR_YELLOW}Step 4: Load configuration from GitHub environment variables...${COLOR_NC}"
load_github_environment_variables "$GITHUB_REPO" "$ENV"

# --- 4b. Ask about preserving reusable resources ---
if [ "$AUTO_APPROVE" = false ] && [ "$PKI_STRATEGY" == "remote" ]; then
    echo -e "${COLOR_YELLOW}Reusable Resources Configuration${COLOR_NC}"
    echo "You can preserve specific resources for reuse when bootstrapping again."
    echo ""

    # Determine actual CA pool names from environment
    SERVER_CA="${EXISTING_SERVER_CA_POOL:-server-ca-pool}"
    FACTORY_CA="${EXISTING_FACTORY_CA_POOL:-factory-ca-pool}"
    REG_CA="${EXISTING_REG_CA_POOL:-registration-ca-pool}"

    # Ask about Server CA Pool
    read -rp "Preserve Server CA Pool ('$SERVER_CA')? (y/N): " PRESERVE_SERVER_CA
    PRESERVE_SERVER_CA=${PRESERVE_SERVER_CA:-N}
    if [[ "$PRESERVE_SERVER_CA" =~ ^[Yy]$ ]]; then
        echo -e "${COLOR_GREEN}  ✓ Server CA will be preserved${COLOR_NC}"
    else
        echo -e "${COLOR_YELLOW}  → Server CA will be deleted${COLOR_NC}"
    fi

    # Ask about Factory CA Pool
    read -rp "Preserve Factory CA Pool ('$FACTORY_CA')? (y/N): " PRESERVE_FACTORY_CA
    PRESERVE_FACTORY_CA=${PRESERVE_FACTORY_CA:-N}
    if [[ "$PRESERVE_FACTORY_CA" =~ ^[Yy]$ ]]; then
        echo -e "${COLOR_GREEN}  ✓ Factory CA will be preserved${COLOR_NC}"
    else
        echo -e "${COLOR_YELLOW}  → Factory CA will be deleted${COLOR_NC}"
    fi

    # Ask about Registration CA Pool
    read -rp "Preserve Registration CA Pool ('$REG_CA')? (y/N): " PRESERVE_REG_CA
    PRESERVE_REG_CA=${PRESERVE_REG_CA:-N}
    if [[ "$PRESERVE_REG_CA" =~ ^[Yy]$ ]]; then
        echo -e "${COLOR_GREEN}  ✓ Registration CA will be preserved${COLOR_NC}"
    else
        echo -e "${COLOR_YELLOW}  → Registration CA will be deleted${COLOR_NC}"
    fi

    # Ask about CloudDNS Zone
    read -rp "Preserve CloudDNS Zone? (y/N): " PRESERVE_DNS
    PRESERVE_DNS=${PRESERVE_DNS:-N}
    if [[ "$PRESERVE_DNS" =~ ^[Yy]$ ]]; then
        echo -e "${COLOR_GREEN}  ✓ DNS Zone will be preserved${COLOR_NC}"
    else
        echo -e "${COLOR_YELLOW}  → DNS Zone will be deleted${COLOR_NC}"
    fi
    echo ""
else
    # Auto-approve mode: use defaults (keep all)
    PRESERVE_SERVER_CA=Y
    PRESERVE_FACTORY_CA=Y
    PRESERVE_REG_CA=Y
    PRESERVE_DNS=Y
    echo -e "${COLOR_YELLOW}Using defaults: All resources will be preserved${COLOR_NC}"
    echo ""
fi

# --- 5. Google Cloud CLI configuration & authentication ---
echo -e "${COLOR_YELLOW}Step 5: Configure Google Cloud CLI configuration & authentication...${COLOR_NC}"

# Use 'print-access-token' for a more robust check of active credentials.
# This avoids repeated login prompts if the user is already authenticated.
if ! gcloud auth print-access-token &>/dev/null; then
    echo "gcloud authentication required."
    gcloud auth login
    gcloud auth application-default login
fi

echo -e "${COLOR_GREEN}Authentication checks passed.${COLOR_NC}"
gcloud config set project "$GCP_PROJECT_ID"

# --- 6. GKE Workload Cleanup ---
echo -e "${COLOR_YELLOW}Step 6: Force deleting GKE cluster to free up database connections...${COLOR_NC}"

GKE_CLUSTER_NAME="${ENV}-gke"

if gcloud container clusters describe "$GKE_CLUSTER_NAME" --region "$GCP_REGION" --project "$GCP_PROJECT_ID" &> /dev/null; then
    echo "GKE Cluster '$GKE_CLUSTER_NAME' found."
    echo "Attempting to delete cluster via GCloud API to terminate workloads..."

    if ! gcloud container clusters delete "$GKE_CLUSTER_NAME" --region "$GCP_REGION" --project "$GCP_PROJECT_ID" --quiet; then
        echo -e "${COLOR_RED}WARNING: Could not trigger cluster deletion.${COLOR_NC}"
        echo "This may cause issues with Terraform destroy. Consider deleting manually."
    else
        echo "Cluster deletion completed successfully."
    fi
else
    echo "GKE Cluster '$GKE_CLUSTER_NAME' not found. Assuming it's already gone."
fi
echo

# --- 7. Delete all certificates from CA pools ---
echo -e "${COLOR_YELLOW}Step 7: Cleaning up CA Pool certificates...${COLOR_NC}"

# Build list of pools to delete based on user choices
CA_POOLS_TO_DELETE=()

if [[ ! "$PRESERVE_SERVER_CA" =~ ^[Yy]$ ]]; then
    CA_POOLS_TO_DELETE+=("${EXISTING_SERVER_CA_POOL:-server-ca-pool}")
fi

if [[ ! "$PRESERVE_FACTORY_CA" =~ ^[Yy]$ ]]; then
    CA_POOLS_TO_DELETE+=("${EXISTING_FACTORY_CA_POOL:-factory-ca-pool}")
fi

if [[ ! "$PRESERVE_REG_CA" =~ ^[Yy]$ ]]; then
    CA_POOLS_TO_DELETE+=("${EXISTING_REG_CA_POOL:-registration-ca-pool}")
fi

# Remove duplicates from array (in case multiple pools share the same name)
if [ ${#CA_POOLS_TO_DELETE[@]} -gt 0 ]; then
    UNIQUE_CA_POOLS=($(printf "%s\n" "${CA_POOLS_TO_DELETE[@]}" | sort -u))
else
    UNIQUE_CA_POOLS=()
fi

if [ ${#UNIQUE_CA_POOLS[@]} -eq 0 ]; then
    echo -e "${COLOR_GREEN}All CA Pools preserved - skipping cleanup${COLOR_NC}"
    echo ""
else
    echo "Deleting ${#UNIQUE_CA_POOLS[@]} CA pool(s)..."

    for pool in "${UNIQUE_CA_POOLS[@]}"; do
    echo "Checking CA pool '$pool'..."

    # Check if pool exists
    if gcloud privateca pools describe "$pool" --location="$GCP_REGION" --project="$GCP_PROJECT_ID" &>/dev/null; then
        echo "Found CA pool '$pool'. Checking for certificates..."

        # List all certificates in the pool
        CERTS=$(gcloud privateca certificates list \
            --issuer-pool="$pool" \
            --issuer-location="$GCP_REGION" \
            --project="$GCP_PROJECT_ID" \
            --format="value(name)" 2>/dev/null || echo "")

        if [ -n "$CERTS" ]; then
            echo "Deleting certificates from pool '$pool'..."
            for cert in $CERTS; do
                echo "  - Deleting certificate: $cert"
                gcloud privateca certificates delete "$cert" \
                    --issuer-pool="$pool" \
                    --issuer-location="$GCP_REGION" \
                    --project="$GCP_PROJECT_ID" \
                    --quiet || true
            done
        else
            echo "No certificates found in pool '$pool'."
        fi

        # Now delete the CA itself
        echo "Checking for CAs in pool '$pool'..."
        CAS=$(gcloud privateca roots list \
            --pool="$pool" \
            --location="$GCP_REGION" \
            --project="$GCP_PROJECT_ID" \
            --format="value(name)" 2>/dev/null || echo "")

        if [ -n "$CAS" ]; then
            echo "Deleting CAs from pool '$pool'..."
            for ca in $CAS; do
                # Extract just the CA ID from the full resource name
                CA_ID=$(basename "$ca")
                echo "  - Disabling CA: $CA_ID"
                gcloud privateca roots disable "$CA_ID" \
                    --pool="$pool" \
                    --location="$GCP_REGION" \
                    --project="$GCP_PROJECT_ID" \
                    --quiet 2>&1 || echo "    (already disabled or error)"

                echo "  - Force deleting CA: $CA_ID"
                if gcloud privateca roots delete "$CA_ID" \
                    --pool="$pool" \
                    --location="$GCP_REGION" \
                    --project="$GCP_PROJECT_ID" \
                    --skip-grace-period \
                    --ignore-active-certificates \
                    --quiet 2>&1; then
                    echo "    ✓ CA deleted successfully"
                else
                    echo "    ✗ CA deletion failed - may need manual cleanup"
                fi
            done

            # Wait longer for CA deletion to fully process
            echo "  - Waiting 30 seconds for CA deletion to fully process..."
            sleep 30
        else
            echo "No CAs found in pool '$pool'."
        fi

        # Now force delete the pool itself
        echo "Force deleting CA pool '$pool'..."
        if gcloud privateca pools delete "$pool" \
            --location="$GCP_REGION" \
            --project="$GCP_PROJECT_ID" \
            --quiet 2>&1; then
            echo "  ✓ Pool '$pool' deleted successfully"
        else
            echo "  ✗ Pool '$pool' deletion failed - may already be deleted or still processing"
            echo "    Attempting to list remaining resources in pool..."
            gcloud privateca roots list --pool="$pool" --location="$GCP_REGION" --project="$GCP_PROJECT_ID" 2>&1 || true
        fi
    else
        echo "CA pool '$pool' not found. Skipping."
    fi
    done

    echo -e "${COLOR_GREEN}CA Pool cleanup complete - selected pools force deleted.${COLOR_NC}"
    echo
fi

# --- 8. Delete DNS records from managed zone ---
if [[ "$PRESERVE_DNS" =~ ^[Yy]$  ]]; then
    echo -e "${COLOR_GREEN}Step 8: Skipping DNS zone cleanup (preserved for reuse)${COLOR_NC}"
    echo ""
else
    echo -e "${COLOR_YELLOW}Step 8: Cleaning up DNS records...${COLOR_NC}"

    # Try to find the managed DNS zone
    DNS_ZONE_NAME=$(echo "$BASE_DOMAIN" | tr '.' '-')

    if gcloud dns managed-zones describe "$DNS_ZONE_NAME" --project="$GCP_PROJECT_ID" &>/dev/null; then
    echo "Found DNS zone '$DNS_ZONE_NAME'. Deleting records..."

    # Get all non-essential record sets (exclude NS and SOA for apex)
    RECORD_SETS=$(gcloud dns record-sets list \
        --zone="$DNS_ZONE_NAME" \
        --project="$GCP_PROJECT_ID" \
        --format="json" | jq -r '.[] | select(.type != "NS" and .type != "SOA") | .name + " " + .type')

    if [ -n "$RECORD_SETS" ]; then
        echo "$RECORD_SETS" | while read -r name type; do
            if [ -n "$name" ] && [ -n "$type" ]; then
                echo "  - Deleting record: $name ($type)"
                # Delete the record
                gcloud dns record-sets delete "$name" \
                    --type="$type" \
                    --zone="$DNS_ZONE_NAME" \
                    --project="$GCP_PROJECT_ID" \
                    --quiet 2>/dev/null || true
            fi
        done
        echo -e "${COLOR_GREEN}DNS records deleted.${COLOR_NC}"
    else
        echo "No additional DNS records to delete."
    fi
    else
        echo "DNS zone not found or not using remote PKI. Skipping DNS cleanup."
    fi

    echo
fi

# --- 9. Clean up database dependencies ---
echo -e "${COLOR_YELLOW}Step 9: Cleaning up database dependencies...${COLOR_NC}"

SQL_INSTANCE="cloud-sql-${ENV}"

if gcloud sql instances describe "$SQL_INSTANCE" --project="$GCP_PROJECT_ID" &>/dev/null; then
    echo "Found Cloud SQL instance '$SQL_INSTANCE'."
    echo "Dropping keycloak database to clean up dependencies..."

    # Drop the database instead of just the user
    gcloud sql databases delete "keycloak" \
        --instance="$SQL_INSTANCE" \
        --project="$GCP_PROJECT_ID" \
        --quiet 2>/dev/null || echo "Database already deleted or doesn't exist."

    echo -e "${COLOR_GREEN}Database cleanup complete.${COLOR_NC}"
else
    echo "Cloud SQL instance not found. Skipping database cleanup."
fi

echo

# --- 10. Prepare Terraform for destroy ---
echo -e "${COLOR_YELLOW}Step 10: Preparing Terraform for destroy...${COLOR_NC}"

cd ./iac/terraform

echo "Initializing Terraform in $(pwd)..."
terraform init -reconfigure -backend-config="bucket=${GCP_PROJECT_ID}-tfstate"

# Extract random suffix from resources if available (BSD grep compatible)
RANDOM_SUFFIX=$(gcloud iam workload-identity-pools list --location="global" --project="$GCP_PROJECT_ID" --format="value(name)" 2>/dev/null | sed -n "s/.*${ENV}-github-wif-\([a-f0-9]*\).*/\1/p" | head -1)
if [ -z "$RANDOM_SUFFIX" ]; then
    echo -e "${COLOR_YELLOW}WARNING: Could not extract RANDOM_SUFFIX from existing WIF pools.${COLOR_NC}"
    echo -e "${COLOR_YELLOW}Using fallback value '00000000'. If Terraform fails, WIF resources may need manual cleanup.${COLOR_NC}"
    RANDOM_SUFFIX="00000000"
fi
echo "Using RANDOM_SUFFIX: $RANDOM_SUFFIX"

echo "Removing resources that may have recovery periods from Terraform state..."

# Remove CA pools from state (they have a 30-day recovery period)
terraform state rm 'google_privateca_ca_pool.server_pool[0]' 2>/dev/null || echo "  - server_pool not in state"
terraform state rm 'google_privateca_ca_pool.factory_pool[0]' 2>/dev/null || echo "  - factory_pool not in state"
terraform state rm 'google_privateca_ca_pool.reg_pool[0]' 2>/dev/null || echo "  - reg_pool not in state"

# Remove CAs from state
terraform state rm 'google_privateca_certificate_authority.server_root[0]' 2>/dev/null || echo "  - server_root not in state"
terraform state rm 'google_privateca_certificate_authority.factory_root[0]' 2>/dev/null || echo "  - factory_root not in state"
terraform state rm 'google_privateca_certificate_authority.reg_root[0]' 2>/dev/null || echo "  - reg_root not in state"

# Remove API service resources from state to prevent disabling APIs with resources still in recovery
echo "Removing API service management from Terraform state..."

# Get all google_project_service resources first (avoid subshell issue)
API_SERVICES=$(terraform state list 2>/dev/null | grep 'google_project_service\.' || echo "")

if [ -n "$API_SERVICES" ]; then
    echo "Found API service resources in state. Removing them..."
    while IFS= read -r resource; do
        if [ -n "$resource" ]; then
            echo "  - Removing: $resource"
            terraform state rm "$resource" 2>&1 || echo "    Failed to remove $resource"
        fi
    done <<< "$API_SERVICES"
    echo "  ✓ All API service resources removed from state"
else
    echo "  - No google_project_service resources found in state"
fi

echo -e "${COLOR_GREEN}Terraform state prepared.${COLOR_NC}"
echo

# --- 11. Execute Terraform destroy ---
echo -e "${COLOR_YELLOW}Step 11: Executing Terraform destroy...${COLOR_NC}"

# Provide default values for optional variables
# Construct WIF pool ID from ENV and RANDOM_SUFFIX (extracted earlier)
WIF_POOL_ID="${ENV}-github-wif-${RANDOM_SUFFIX}"

terraform destroy -auto-approve -lock-timeout=60s \
  -var="project_id=${GCP_PROJECT_ID}" \
  -var="region=${GCP_REGION}" \
  -var="environment=${ENV}" \
  -var="zone=${GCP_REGION}-a" \
  -var="random_suffix=${RANDOM_SUFFIX}" \
  -var="repository=${GITHUB_REPO}" \
  -var="github_org=${GITHUB_REPO%/*}/" \
  -var="pki_strategy=local" \
  -var="base_domain=" \
  -var="keycloak_hostname=keycloak" \
  -var="nats_hostname=nats" \
  -var="registration_hostname=registration" \
  -var="wif_pool_id=${WIF_POOL_ID}" \
  -var="wif_provider_id=github"

echo -e "${COLOR_GREEN}Terraform destroy complete.${COLOR_NC}"

cd ../..
echo

# --- 12. Delete tfstate-bucket ---
echo -e "${COLOR_YELLOW}Step 12: Deleting GCS tfstate-bucket...${COLOR_NC}"
gcloud storage rm -r "gs://${GCP_PROJECT_ID}-tfstate"
echo -e "${COLOR_GREEN}Successfully deleted 'gs://${GCP_PROJECT_ID}-tfstate' bucket.${COLOR_NC}"

# --- 13. Clean up GitHub Environment Variables (preserve required variables) ---
echo -e "${COLOR_YELLOW}Step 13: Cleaning up non-required GitHub environment variables...${COLOR_NC}"

# Delete only non-required variables set by bootstrap script
# The following 5 required variables are PRESERVED:
#   - GCP_PROJECT_ID
#   - GCP_REGION
#   - GCP_SERVICE_ACCOUNT
#   - GCP_WORKLOAD_IDENTITY_POOL_ID
#   - GCP_WORKLOAD_IDENTITY_PROVIDER_ID

echo "Deleting GCP_PROJECT_NUMBER..."
gh variable delete GCP_PROJECT_NUMBER --env "$ENV" --repo "$GITHUB_REPO" 2>/dev/null || echo "  (already deleted or doesn't exist)"

echo "Deleting RANDOM_SUFFIX..."
gh variable delete RANDOM_SUFFIX --env "$ENV" --repo "$GITHUB_REPO" 2>/dev/null || echo "  (already deleted or doesn't exist)"

echo -e "${COLOR_GREEN}Non-required variables cleaned. Required variables preserved for future bootstrap runs.${COLOR_NC}"
echo

# --- 14. Delete all secrets from Secret Manager ---
echo -e "${COLOR_YELLOW}Step 14: Deleting secrets from Secret Manager...${COLOR_NC}"

# List of all secrets created by bootstrap-platform-ca.sh
SECRETS_TO_DELETE=(
    # Infrastructure secrets (always created)
    "KEYCLOAK_GCP_SERVICE_ACCOUNT"
    "BIGTABLE_CONNECTOR_GCP_SERVICE_ACCOUNT"
    "DATA_API_BIGTABLE_CONNECTOR_GCP_SERVICE_ACCOUNT"
    "KEYCLOAK_DB_PASSWORD"
    "KEYCLOAK_ADMIN_PASSWORD"
    "NATS_SERVER_USER"
    "NATS_SERVER_PASSWORD"
    "NATS_AUTH_CALLOUT_PASSWORD"  # Service user for nats-auth-callout pod
    "NATS_CONNECTOR_PASSWORD"  # Restricted connector user for BigTable connector (read-only telemetry access)
    "KEYCLOAK_INSTANCE_CON_SQL_PROXY"
    "IMAGE_REPO"
    "JWT_ACC_SIGNING_KEY"
    "NATS_AUTH_CALLOUT_NKEY_PUB"
    "${ENV}-keycloak-hostname"
    "${ENV}-nats-hostname"
    "${ENV}-registration-hostname"

    # PKI secrets (always created)
    "REGISTRATION_CA_CERT"
    "REGISTRATION_CA_KEY"
    "REGISTRATION_FACTORY_CA_CERT"

    # Remote mode secrets (may not exist in local mode)
    "BASE_DOMAIN"
    "SERVER_CA_POOL"
    "FACTORY_CA_POOL"
    "SERVER_CA"
    "FACTORY_CA"
    "KEYCLOAK_HOSTNAME"
    "NATS_HOSTNAME"
    "REGISTRATION_HOSTNAME"

    # Local mode secrets (may not exist in remote mode)
    "KEYCLOAK_TLS_CRT"
    "KEYCLOAK_TLS_KEY"
    "SERVER_CA_CERT"
    "SERVER_CA_KEY"

    # Server certificates (created by workflows)
    "REGISTRATION_SERVER_TLS_CERT"
    "REGISTRATION_SERVER_TLS_KEY"

    "KEYCLOAK_JWK_URI"
    "KEYCLOAK_JWK_B64"
)

echo "Deleting ${#SECRETS_TO_DELETE[@]} secrets..."

for secret in "${SECRETS_TO_DELETE[@]}"; do
    if gcloud secrets describe "$secret" --project="$GCP_PROJECT_ID" &>/dev/null; then
        echo "  - Deleting secret: $secret"
        gcloud secrets delete "$secret" --project="$GCP_PROJECT_ID" --quiet || echo "    Failed to delete $secret"
    else
        echo "  - Secret '$secret' not found (already deleted or never created)"
    fi
done

echo -e "${COLOR_GREEN}Secret Manager cleanup complete.${COLOR_NC}"
echo

# --- 15. Clean up local files ---
echo -e "${COLOR_YELLOW}Step 15: Cleaning up local files...${COLOR_NC}"

# Remove locally generated PKI files
if [ -d "base-services/registration/pki" ]; then
    echo "Removing generated PKI certificates..."
    # Keep the structure but remove generated certificates
    find base-services/registration/pki -type f \( -name "*.pem" -o -name "*.srl" -o -name "index.*" -o -name "serial*" -o -name "crlnumber*" \) -delete
    echo -e "${COLOR_GREEN}PKI certificates cleaned.${COLOR_NC}"
else
    echo "No PKI directory found to clean."
fi

# Remove Python certificates
if [ -d "base-services/registration/python/certificates" ]; then
    echo "Removing Python client certificates..."
    rm -rf base-services/registration/python/certificates
    echo -e "${COLOR_GREEN}Python certificates cleaned.${COLOR_NC}"
fi

# Remove bootstrap configuration file
if [ -f "iac/bootstrapping/.bootstrap_env" ]; then
  read -rp "Are you sure you want to delete the bootstrap configuration file? (type 'yes' to confirm): " CONFIRM
  if [ "$CONFIRM" == "yes" ]; then
    echo "Removing bootstrap configuration file..."
    rm -f iac/bootstrapping/.bootstrap_env
    echo -e "${COLOR_GREEN}Bootstrap configuration removed.${COLOR_NC}"
  fi
fi

echo -e "${COLOR_GREEN}Local cleanup complete.${COLOR_NC}"
echo

echo -e "${COLOR_GREEN}==================================================================${COLOR_NC}"
echo -e "${COLOR_GREEN}  🎉 Nexus SDV platform teardown successfully completed! 🎉  ${COLOR_NC}"
echo -e "${COLOR_GREEN}==================================================================${COLOR_NC}"
echo "Your Google Cloud project environment is now empty again."
echo "Local files have been cleaned up."