#!/bin/bash
#
# Setup Workload Identity Federation for GitHub Actions
#
# This script creates:
# - Workload Identity Federation Pool
# - GitHub Actions OIDC Provider
# - Service Account with necessary roles
# - IAM bindings to connect them
#
# Based on existing setup in horizon-sdv-lal project

set -euo pipefail

# Colors for output
COLOR_GREEN='\033[0;32m'
COLOR_BLUE='\033[0;34m'
COLOR_YELLOW='\033[1;33m'
COLOR_RED='\033[0;31m'
COLOR_NC='\033[0m'

# Default values (can be overridden by environment variables or script arguments)
PROJECT_ID="${GCP_PROJECT_ID:-horizon-sdv-lal}"
POOL_ID="${WIF_POOL_ID:-github-pool}"
PROVIDER_ID="${WIF_PROVIDER_ID:-github-provider}"
SA_NAME="${SA_NAME:-github-sa}"
GITHUB_ORG="${GITHUB_ORG:-DE-Nexus-SDV}"
GITHUB_REPO="${GITHUB_REPO:-valtech-sdv-sandbox}"

# DNS Configuration (optional - set DNS_DOMAIN to enable DNS zone creation)
DNS_DOMAIN="${DNS_DOMAIN:-}"  # e.g., "example.com"
DNS_ZONE_NAME="${DNS_ZONE_NAME:-}"  # e.g., "example-com"

# CA Pool Configuration (optional - set CA_POOL_NAME to enable CA pool creation)
CA_POOL_NAME="${CA_POOL_NAME:-}"  # e.g., "my-ca-pool"
CA_POOL_TIER="${CA_POOL_TIER:-DEVOPS}"  # DEVOPS or ENTERPRISE

# Derived values
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
POOL_RESOURCE="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}"
PROVIDER_RESOURCE="${POOL_RESOURCE}/providers/${PROVIDER_ID}"

echo -e "${COLOR_BLUE}=== GitHub Workload Identity Federation Setup ===${COLOR_NC}\n"
echo "Project: $PROJECT_ID ($PROJECT_NUMBER)"
echo "Pool ID: $POOL_ID"
echo "Provider ID: $PROVIDER_ID"
echo "Service Account: $SA_EMAIL"
echo "GitHub: $GITHUB_ORG/$GITHUB_REPO"
if [[ -n "$DNS_DOMAIN" ]]; then
    echo "DNS Zone: $DNS_ZONE_NAME ($DNS_DOMAIN)"
fi
if [[ -n "$CA_POOL_NAME" ]]; then
    echo "CA Pool: $CA_POOL_NAME (tier: $CA_POOL_TIER)"
fi
echo

# Confirm
read -p "Continue with these settings? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

# ==============================================================================
# Step 1: Create Workload Identity Pool
# ==============================================================================
echo -e "${COLOR_YELLOW}Step 1: Creating Workload Identity Pool...${COLOR_NC}"

if gcloud iam workload-identity-pools describe "$POOL_ID" --location=global --project="$PROJECT_ID" &>/dev/null; then
    echo -e "${COLOR_GREEN}✓ Pool already exists${COLOR_NC}"
else
    gcloud iam workload-identity-pools create "$POOL_ID" \
        --project="$PROJECT_ID" \
        --location=global \
        --display-name="GitHub WIF Pool" \
        --description="Workload Identity Pool for GitHub Actions to access GCP resources"

    echo -e "${COLOR_GREEN}✓ Pool created${COLOR_NC}"
fi

# ==============================================================================
# Step 2: Create GitHub Actions OIDC Provider
# ==============================================================================
echo -e "\n${COLOR_YELLOW}Step 2: Creating GitHub Actions OIDC Provider...${COLOR_NC}"

if gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
    --workload-identity-pool="$POOL_ID" \
    --location=global \
    --project="$PROJECT_ID" &>/dev/null; then
    echo -e "${COLOR_GREEN}✓ Provider already exists${COLOR_NC}"
else
    gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_ID" \
        --project="$PROJECT_ID" \
        --location=global \
        --workload-identity-pool="$POOL_ID" \
        --display-name="GitHub Actions OIDC Provider" \
        --description="OIDC Provider for GitHub Actions" \
        --issuer-uri="https://token.actions.githubusercontent.com/" \
        --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner,attribute.aud=attribute.aud,google.groups=assertion.groups" \
        --attribute-condition="assertion.repository_owner=='${GITHUB_ORG}'"

    echo -e "${COLOR_GREEN}✓ Provider created${COLOR_NC}"
fi

# ==============================================================================
# Step 3: Create Service Account
# ==============================================================================
echo -e "\n${COLOR_YELLOW}Step 3: Creating Service Account...${COLOR_NC}"

if gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" &>/dev/null; then
    echo -e "${COLOR_GREEN}✓ Service Account already exists${COLOR_NC}"
else
    gcloud iam service-accounts create "$SA_NAME" \
        --project="$PROJECT_ID" \
        --display-name="GitHub Actions Service Account" \
        --description="Service Account for GitHub Actions workflows via Workload Identity Federation"

    echo -e "${COLOR_GREEN}✓ Service Account created${COLOR_NC}"
fi

# ==============================================================================
# Step 4: Grant WIF Pool permission to impersonate Service Account
# ==============================================================================
echo -e "\n${COLOR_YELLOW}Step 4: Binding Workload Identity Pool to Service Account...${COLOR_NC}"

# Allow all workflows from the GitHub org
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
    --project="$PROJECT_ID" \
    --role="roles/iam.workloadIdentityUser" \
    --member="principalSet://iam.googleapis.com/${POOL_RESOURCE}/attribute.repository_owner/${GITHUB_ORG}" \
    --condition=None

echo -e "${COLOR_GREEN}✓ WIF pool bound to service account (org-wide)${COLOR_NC}"

# Optionally, grant access to specific repository
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
    --project="$PROJECT_ID" \
    --role="roles/iam.serviceAccountTokenCreator" \
    --member="principalSet://iam.googleapis.com/${POOL_RESOURCE}/attribute.repository/${GITHUB_ORG}/${GITHUB_REPO}" \
    --condition=None

echo -e "${COLOR_GREEN}✓ Specific repository bound${COLOR_NC}"

# ==============================================================================
# Step 5: Grant Project-level Roles to Service Account
# ==============================================================================
echo -e "\n${COLOR_YELLOW}Step 5: Granting project-level roles to Service Account...${COLOR_NC}"

# Core roles for infrastructure management
ROLES=(
    "roles/artifactregistry.admin"
    "roles/container.admin"
    "roles/compute.networkAdmin"
    "roles/compute.securityAdmin"
    "roles/iam.serviceAccountAdmin"
    "roles/iam.workloadIdentityPoolAdmin"
    "roles/secretmanager.admin"
    "roles/serviceusage.serviceUsageAdmin"
    "roles/resourcemanager.projectIamAdmin"
    "roles/privateca.caManager"
    "roles/privateca.certificateManager"
    "roles/cloudsql.admin"
    "roles/bigtable.admin"
    "roles/run.admin"
    "roles/dns.admin"
)

for role in "${ROLES[@]}"; do
    if gcloud projects get-iam-policy "$PROJECT_ID" \
        --flatten="bindings[].members" \
        --filter="bindings.members:serviceAccount:${SA_EMAIL} AND bindings.role:${role}" \
        --format="value(bindings.role)" | grep -q "$role"; then
        echo "  ✓ $role (already granted)"
    else
        gcloud projects add-iam-policy-binding "$PROJECT_ID" \
            --member="serviceAccount:${SA_EMAIL}" \
            --role="$role" \
            --condition=None \
            --no-user-output-enabled
        echo "  ✓ $role (newly granted)"
    fi
done

echo -e "${COLOR_GREEN}✓ All roles granted${COLOR_NC}"

# ==============================================================================
# Step 6: Create Cloud DNS Zone (Optional)
# ==============================================================================
if [[ -n "$DNS_DOMAIN" ]]; then
    echo -e "\n${COLOR_YELLOW}Step 6: Creating Cloud DNS Zone...${COLOR_NC}"

    # Auto-generate zone name if not provided
    if [[ -z "$DNS_ZONE_NAME" ]]; then
        DNS_ZONE_NAME=$(echo "$DNS_DOMAIN" | tr '.' '-')
    fi

    # Ensure DNS_DOMAIN ends with a dot for Cloud DNS
    if [[ ! "$DNS_DOMAIN" =~ \.$ ]]; then
        DNS_DOMAIN_FQDN="${DNS_DOMAIN}."
    else
        DNS_DOMAIN_FQDN="$DNS_DOMAIN"
    fi

    if gcloud dns managed-zones describe "$DNS_ZONE_NAME" --project="$PROJECT_ID" &>/dev/null; then
        echo -e "${COLOR_GREEN}✓ DNS zone already exists${COLOR_NC}"
    else
        gcloud dns managed-zones create "$DNS_ZONE_NAME" \
            --project="$PROJECT_ID" \
            --dns-name="$DNS_DOMAIN_FQDN" \
            --description="Managed DNS zone for $DNS_DOMAIN" \
            --visibility=public \
            --dnssec-state=on

        echo -e "${COLOR_GREEN}✓ DNS zone created${COLOR_NC}"
    fi

    # Enable Cloud Logging for DNS queries
    if gcloud dns managed-zones describe "$DNS_ZONE_NAME" --project="$PROJECT_ID" --format="value(cloudLoggingConfig.enableLogging)" | grep -q "True"; then
        echo -e "${COLOR_GREEN}✓ Cloud Logging already enabled${COLOR_NC}"
    else
        gcloud dns managed-zones update "$DNS_ZONE_NAME" \
            --project="$PROJECT_ID" \
            --log-dns-queries

        echo -e "${COLOR_GREEN}✓ Cloud Logging enabled${COLOR_NC}"
    fi

    # Get nameservers
    NAMESERVERS=$(gcloud dns managed-zones describe "$DNS_ZONE_NAME" --project="$PROJECT_ID" --format="value(nameServers)" | tr ';' '\n')

    echo -e "\n${COLOR_BLUE}Configure your domain registrar with these nameservers:${COLOR_NC}"
    echo "$NAMESERVERS" | while read -r ns; do
        echo "  - $ns"
    done
fi

# ==============================================================================
# Step 7: Create CA Pool (Optional)
# ==============================================================================
if [[ -n "$CA_POOL_NAME" ]]; then
    echo -e "\n${COLOR_YELLOW}Step 7: Creating Certificate Authority Pool...${COLOR_NC}"

    if gcloud privateca pools describe "$CA_POOL_NAME" --location="$GCP_REGION" --project="$PROJECT_ID" &>/dev/null; then
        echo -e "${COLOR_GREEN}✓ CA pool already exists${COLOR_NC}"
    else
        gcloud privateca pools create "$CA_POOL_NAME" \
            --location="$GCP_REGION" \
            --project="$PROJECT_ID" \
            --tier="$CA_POOL_TIER" \
            --publish-ca-cert \
            --publish-crl

        echo -e "${COLOR_GREEN}✓ CA pool created${COLOR_NC}"
    fi

    echo -e "\n${COLOR_BLUE}CA Pool Details:${COLOR_NC}"
    echo "  Name: $CA_POOL_NAME"
    echo "  Location: $GCP_REGION"
    echo "  Tier: $CA_POOL_TIER"
    echo -e "\n${COLOR_YELLOW}Note: You'll need to create a Certificate Authority (CA) within this pool.${COLOR_NC}"
    echo "Example command:"
    echo "  gcloud privateca roots create my-root-ca \\"
    echo "    --pool=$CA_POOL_NAME \\"
    echo "    --location=$GCP_REGION \\"
    echo "    --subject=\"CN=My Root CA, O=My Organization\" \\"
    echo "    --max-chain-length=2 \\"
    echo "    --key-algorithm=rsa-pkcs1-4096-sha256"
fi

# ==============================================================================
# Summary
# ==============================================================================
echo -e "\n${COLOR_GREEN}=== Setup Complete! ===${COLOR_NC}\n"

echo "Workload Identity Provider:"
echo "  projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/providers/${PROVIDER_ID}"
echo
echo "Service Account:"
echo "  ${SA_EMAIL}"
echo
echo -e "${COLOR_BLUE}GitHub Actions Configuration:${COLOR_NC}"
echo "Add these to your GitHub repository secrets/variables:"
echo
echo "  GCP_PROJECT_ID: $PROJECT_ID"
echo "  GCP_PROJECT_NUMBER: $PROJECT_NUMBER"
echo "  GCP_SERVICE_ACCOUNT: $SA_EMAIL"
echo "  GCP_WORKLOAD_IDENTITY_POOL_ID: $POOL_ID"
echo "  GCP_WORKLOAD_IDENTITY_PROVIDER_ID: $PROVIDER_ID"
echo
echo -e "${COLOR_BLUE}Example workflow step:${COLOR_NC}"
cat <<'EOF'

      - name: Authenticate to Google Cloud
        uses: google-github-actions/auth@v2
        with:
          token_format: access_token
          workload_identity_provider: projects/${{ vars.GCP_PROJECT_NUMBER }}/locations/global/workloadIdentityPools/${{ vars.GCP_WORKLOAD_IDENTITY_POOL_ID }}/providers/${{ vars.GCP_WORKLOAD_IDENTITY_PROVIDER_ID }}
          service_account: ${{ vars.GCP_SERVICE_ACCOUNT }}

EOF

echo -e "${COLOR_GREEN}Done!${COLOR_NC}"