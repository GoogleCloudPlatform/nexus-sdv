#!/bin/bash
# ==============================================================================
# Nexus SDV Bootstrapping — Shared Terraform Library
#
# Sourced by all bootstrap and teardown scripts to avoid code duplication.
# ==============================================================================

setup_terraform_backend() {
    TF_BUCKET="${GCP_PROJECT_ID}-tfstate"
    if ! gsutil ls -b "gs://${TF_BUCKET}" &> /dev/null; then
        gcloud storage buckets create gs://"${TF_BUCKET}" --location="$GCP_REGION" --uniform-bucket-level-access
        gcloud storage buckets update gs://"${TF_BUCKET}" --versioning
    fi
    rm -rf iac/terraform/.terraform/terraform.tfstate || true
}

run_terraform_apply() {
    log_info "Strategy: $PKI_STRATEGY"
    add_delay_if_run_in_cloudshell
    gcloud auth print-access-token
    cd iac/terraform
    terraform init -backend-config="bucket=${GCP_PROJECT_ID}-tfstate"

    terraform apply \
      -var="project_id=${GCP_PROJECT_ID}" \
      -var="region=${GCP_REGION}" \
      -var="environment=${ENV}" \
      -var="zone=${GCP_REGION}-a" \
      -var="random_suffix=${RANDOM_SUFFIX}" \
      -var="enable_github_oidc=${enable_github_oidc}"\
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


    add_delay_if_run_in_cloudshell

    # The service account is only necessary for Github actions to authenticate against GCP. When running in ClodeBuid
    # we leave it empty
    SERVICE_ACCOUNT=$(terraform output -raw service_account_email 2>/dev/null || echo "")
    KEYCLOAK_DB_PASSWORD=$(terraform output -raw keycloak_db_password)
    cd ../..
}

run_terraform_destroy() {
    # --- Prepare Terraform for destroy ---
    log_warn "Preparing Terraform for destroy..."
    add_delay_if_run_in_cloudshell
    cd ./iac/terraform

    log_info "Initializing Terraform in $(pwd)..."
    terraform init -reconfigure -backend-config="bucket=${GCP_PROJECT_ID}-tfstate"

    # Extract random suffix from resources if available (BSD grep compatible)
    RANDOM_SUFFIX=$(gcloud iam workload-identity-pools list --location="global" --project="$GCP_PROJECT_ID" --format="value(name)" 2>/dev/null | sed -n "s/.*${ENV}-github-wif-\([a-f0-9]*\).*/\1/p" | head -1)
    if [ -z "$RANDOM_SUFFIX" ]; then
        log_warn "WARNING: Could not extract RANDOM_SUFFIX from existing WIF pools."
        log_warn "Using fallback value '00000000'. If Terraform fails, WIF resources may need manual cleanup."
        RANDOM_SUFFIX="00000000"
    fi
    log_info "Using RANDOM_SUFFIX: $RANDOM_SUFFIX"

    log_info "Removing resources that may have recovery periods from Terraform state..."

    # Remove CA pools from state (they have a 30-day recovery period)
    add_delay_if_run_in_cloudshell
    terraform state rm 'google_privateca_ca_pool.server_pool[0]' 2>/dev/null || log_info "  - server_pool not in state"
    terraform state rm 'google_privateca_ca_pool.factory_pool[0]' 2>/dev/null || log_info "  - factory_pool not in state"
    terraform state rm 'google_privateca_ca_pool.reg_pool[0]' 2>/dev/null || log_info "  - reg_pool not in state"

    # Remove CAs from state
    add_delay_if_run_in_cloudshell
    terraform state rm 'google_privateca_certificate_authority.server_root[0]' 2>/dev/null || log_info "  - server_root not in state"
    terraform state rm 'google_privateca_certificate_authority.factory_root[0]' 2>/dev/null || log_info "  - factory_root not in state"
    terraform state rm 'google_privateca_certificate_authority.reg_root[0]' 2>/dev/null || log_info "  - reg_root not in state"

    # Remove API service resources from state to prevent disabling APIs with resources still in recovery
    log_info "Removing API service management from Terraform state..."

    # Get all google_project_service resources first (avoid subshell issue)
    API_SERVICES=$(terraform state list 2>/dev/null | grep 'google_project_service\.' || log_info "")

    if [ -n "$API_SERVICES" ]; then
        log_info "Found API service resources in state. Removing them..."
        while IFS= read -r resource; do
            if [ -n "$resource" ]; then
                log_info "  - Removing: $resource"
                terraform state rm "$resource" 2>&1 || log_info "    Failed to remove $resource"
            fi
        done <<< "$API_SERVICES"
        log_info "  ${CHECK} All API service resources removed from state"
    else
        log_info "  ${NOTSET} No google_project_service resources found in state"
    fi

    log_info "Terraform state prepared."
    echo ""

    # --- Execute Terraform destroy ---
    log_warn "Executing Terraform destroy..."

    # Provide default values for optional variables
    # Construct WIF pool ID from ENV and RANDOM_SUFFIX (extracted earlier)
    WIF_POOL_ID="${ENV}-github-wif-${RANDOM_SUFFIX}"
    add_delay_if_run_in_cloudshell
    terraform destroy -auto-approve -lock-timeout=60s \
      -var="project_id=${GCP_PROJECT_ID}" \
      -var="region=${GCP_REGION}" \
      -var="environment=${ENV}" \
      -var="zone=${GCP_REGION}-a" \
      -var="random_suffix=${RANDOM_SUFFIX}" \
      -var="repository=${GITHUB_REPO}" \
      -var="github_org=${GITHUB_REPO}/" \
      -var="pki_strategy=${PKI_STRATEGY}" \
      -var="base_domain=${BASE_DOMAIN}" \
      -var="keycloak_hostname=${KEYCLOAK_HOSTNAME}" \
      -var="nats_hostname=${NATS_HOSTNAME}" \
      -var="registration_hostname=${REGISTRATION_HOSTNAME}" \
      -var="wif_pool_id=${WIF_POOL_ID}" \
      -var="wif_provider_id=github"
    add_delay_if_run_in_cloudshell

    log_info "Terraform destroy complete."

    cd ../..
    echo ""
}

delete_tfstate_bucket() {
    add_delay_if_run_in_cloudshell
    gcloud storage rm -r "gs://${GCP_PROJECT_ID}-tfstate"
    log_info "Successfully deleted 'gs://${GCP_PROJECT_ID}-tfstate' bucket."
}
