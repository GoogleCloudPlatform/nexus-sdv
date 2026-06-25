#!/bin/bash
# ==============================================================================
# Nexus SDV Bootstrapping — Shared Terraform Library
#
# Sourced by all bootstrap and teardown scripts to avoid code duplication.
# ==============================================================================

setup_terraform_backend() {
    TF_BUCKET="${GCP_PROJECT_ID}-tfstate"
    if ! gsutil ls -b "gs://${TF_BUCKET}" &> /dev/null; then
        gcloud storage buckets create gs://"${TF_BUCKET}" --location="$GCP_REGION" --project="$GCP_PROJECT_ID" --uniform-bucket-level-access
        gcloud storage buckets update gs://"${TF_BUCKET}" --project="$GCP_PROJECT_ID" --versioning
    fi
    rm -rf iac/terraform/.terraform/terraform.tfstate || true
}

run_terraform_apply() {
    log_info "Strategy: $PKI_STRATEGY"
    add_delay_if_run_in_cloudshell
    gcloud auth print-access-token
    cd iac/terraform
    terraform init -backend-config="bucket=${GCP_PROJECT_ID}-tfstate"

    # Shared var set for both the refresh-only reconcile and the apply.
    local -a TF_VARS=(
      -var="project_id=${GCP_PROJECT_ID}"
      -var="region=${GCP_REGION}"
      -var="environment=${ENV}"
      -var="zone=${GCP_REGION}-a"
      -var="deployment_suffix=${DEPLOYMENT_SUFFIX}"
      -var="enable_github_oidc=${enable_github_oidc}"
      -var="repository=${GITHUB_REPO}"
      -var="github_org=${GITHUB_REPO%/*}/"
      -var="pki_strategy=${PKI_STRATEGY}"
      -var="base_domain=${BASE_DOMAIN}"
      -var="existing_dns_zone=${EXISTING_DNS_ZONE}"
      -var="keycloak_hostname=${KEYCLOAK_HOSTNAME}"
      -var="nats_hostname=${NATS_HOSTNAME}"
      -var="registration_hostname=${REGISTRATION_HOSTNAME}"
      -var="existing_server_ca=${EXISTING_SERVER_CA}"
      -var="existing_server_ca_pool=${EXISTING_SERVER_CA_POOL}"
      -var="existing_factory_ca=${EXISTING_FACTORY_CA}"
      -var="existing_factory_ca_pool=${EXISTING_FACTORY_CA_POOL}"
      -var="existing_reg_ca=${EXISTING_REG_CA}"
      -var="existing_reg_ca_pool=${EXISTING_REG_CA_POOL}"
      -var="created_reg_ca_pool=${CREATED_REG_CA_POOL}"
      -var="created_server_ca_pool=${CREATED_SERVER_CA_POOL}"
      -var="created_factory_ca_pool=${CREATED_FACTORY_CA_POOL}"
      -var="wif_pool_id=${GCP_WORKLOAD_IDENTITY_POOL_ID}"
      -var="wif_provider_id=${GCP_WORKLOAD_IDENTITY_PROVIDER_ID}"
    )

    # Import the docker-hub remote repository if it already exists in GCP but is
    # not yet in Terraform state. This handles projects where the repo was created
    # manually before Terraform managed it. In fresh projects the repo won't exist
    # yet and Terraform will create it during the apply below.
    if gcloud artifacts repositories describe docker-hub \
            --location="${GCP_REGION}" --project="${GCP_PROJECT_ID}" &>/dev/null 2>&1; then
        if ! terraform state list 2>/dev/null | grep -q "google_artifact_registry_repository.docker_hub_proxy"; then
            log_info "Importing pre-existing docker-hub Artifact Registry repository into Terraform state..."
            terraform import "${TF_VARS[@]}" \
                google_artifact_registry_repository.docker_hub_proxy \
                "projects/${GCP_PROJECT_ID}/locations/${GCP_REGION}/repositories/docker-hub"
        fi
    fi

    # Reconcile state with reality before applying. If resources tracked in state
    # were deleted out-of-band (e.g. secrets removed by delete-platform-resources.sh
    # or delete-all-secrets.sh while the tfstate bucket survived), refresh-only drops
    # them from state so the apply recreates them cleanly. Without this, apply tries
    # to add a secret VERSION to a secret that no longer exists -> 404. On a fresh
    # (empty) state this is a harmless no-op.
    log_info "Reconciling Terraform state with GCP (refresh-only)..."
    terraform apply -refresh-only -auto-approve "${TF_VARS[@]}" \
      || log_warn "Refresh-only encountered errors — continuing with apply."

    # Re-import SQL users that exist in Cloud SQL but are absent from state.
    # This handles the case where a previous apply abandoned them (deletion_policy
    # = ABANDON) before failing, leaving the users in GCP but out of state.
    # Without this, the next apply would try to create users that already exist.
    local sql_instance="cloud-sql-${ENV}"
    if gcloud sql instances describe "${sql_instance}" \
            --project="${GCP_PROJECT_ID}" &>/dev/null 2>&1; then
        for _user_name in keycloak webclient postgres; do
            local tf_addr="google_sql_user.${_user_name}_user"
            if gcloud sql users list --instance="${sql_instance}" \
                    --project="${GCP_PROJECT_ID}" --format="value(name)" 2>/dev/null \
                    | grep -q "^${_user_name}$"; then
                if ! terraform state list 2>/dev/null | grep -q "${tf_addr}"; then
                    log_info "Re-importing SQL user '${_user_name}' into Terraform state..."
                    terraform import "${TF_VARS[@]}" \
                        "${tf_addr}" \
                        "${GCP_PROJECT_ID}/cloud-sql-${ENV}//${_user_name}" || \
                        log_warn "Could not import SQL user '${_user_name}' — apply will attempt to create it."
                fi
            fi
        done
    fi

    terraform apply -auto-approve "${TF_VARS[@]}"


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
    DEPLOYMENT_SUFFIX=$(gcloud iam workload-identity-pools list --location="global" --project="$GCP_PROJECT_ID" --format="value(name)" 2>/dev/null | sed -n "s/.*${ENV}-github-wif-\([a-f0-9]*\).*/\1/p" | head -1)
    if [ -z "$DEPLOYMENT_SUFFIX" ]; then
        log_warn "WARNING: Could not extract DEPLOYMENT_SUFFIX from existing WIF pools."
        log_warn "Using fallback value '00000000'. If Terraform fails, WIF resources may need manual cleanup."
        DEPLOYMENT_SUFFIX="00000000"
    fi
    log_info "Using DEPLOYMENT_SUFFIX: $DEPLOYMENT_SUFFIX"

    log_info "Removing resources that may have recovery periods from Terraform state..."

    # Remove the Compute SA owner binding from state so terraform destroy does not
    # attempt to revoke it. The binding has lifecycle.prevent_destroy = true (which
    # would abort the destroy) because revoking it mid-run causes all subsequent IAM
    # and resource deletions to fail with 403. Removing it from state leaves the
    # IAM binding intact in GCP (the SA retains roles/owner) while allowing the
    # rest of the resources to be destroyed cleanly.
    log_info "Removing Compute SA owner binding from Terraform state (lifecycle.prevent_destroy)..."
    terraform state rm 'google_project_iam_member.compute_sa_owner[0]' 2>/dev/null || log_info "  - compute_sa_owner not in state"

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

    # Honour the user's DNS preservation choice: remove the zone from state so terraform destroy
    # does not delete it even though it remains in GCP.
    if [[ "${PRESERVE_DNS:-N}" =~ ^[Yy]$ ]]; then
        log_info "Preserving DNS zone — removing from Terraform state..."
        terraform state rm 'google_dns_managed_zone.sdv_zone[0]' 2>/dev/null || log_info "  - dns_zone not in state"
    fi

    # Remove Cloud SQL child resources from state when the parent instance was deleted outside Terraform.
    # Terraform's refresh-only drops the instance itself but leaves dependent databases and users in state,
    # causing 404 errors during destroy because they reference a non-existent instance.
    log_info "Removing Cloud SQL child resources from Terraform state (if instance was deleted externally)..."
    SQL_CHILDREN=$(terraform state list 2>/dev/null | grep -E '^google_sql_(database|user)\.' || true)
    if [ -n "$SQL_CHILDREN" ]; then
        while IFS= read -r resource; do
            if [ -n "$resource" ]; then
                log_info "  - Removing: $resource"
                terraform state rm "$resource" 2>/dev/null || log_info "    (not in state)"
            fi
        done <<< "$SQL_CHILDREN"
    else
        log_info "  - No Cloud SQL child resources in state"
    fi

    log_info "Terraform state prepared."
    echo ""

    # --- Sync state against reality before destroy ---
    # Resources deleted outside Terraform will be removed from state here,
    # so the subsequent destroy does not fail trying to delete them.
    log_info "Syncing Terraform state with GCP (removing resources deleted outside Terraform)..."
    WIF_POOL_ID="${ENV}-github-wif-${DEPLOYMENT_SUFFIX}"
    terraform apply -refresh-only -auto-approve -lock-timeout=60s \
      -var="project_id=${GCP_PROJECT_ID}" \
      -var="region=${GCP_REGION}" \
      -var="environment=${ENV}" \
      -var="zone=${GCP_REGION}-a" \
      -var="deployment_suffix=${DEPLOYMENT_SUFFIX}" \
      -var="repository=${GITHUB_REPO:-}" \
      -var="github_org=${GITHUB_REPO:-}/" \
      -var="pki_strategy=${PKI_STRATEGY:-local}" \
      -var="base_domain=${BASE_DOMAIN:-}" \
      -var="keycloak_hostname=${KEYCLOAK_HOSTNAME:-}" \
      -var="nats_hostname=${NATS_HOSTNAME:-}" \
      -var="registration_hostname=${REGISTRATION_HOSTNAME:-}" \
      -var="wif_pool_id=${WIF_POOL_ID}" \
      -var="wif_provider_id=github" 2>&1 || log_warn "Refresh encountered errors — some resources may already be gone. Continuing with destroy."
    log_info "State sync complete."
    echo ""

    # --- Remove API service resources from state ---
    # Done AFTER refresh-only so that refresh cannot add them back before destroy.
    # Terraform destroy would otherwise try to disable APIs while GKE node pools
    # (created by Autopilot) still exist, causing a 400 precondition failure.
    log_info "Removing API service management from Terraform state..."
    API_SERVICES=$(terraform state list 2>/dev/null | grep 'google_project_service\.' || true)
    if [ -n "$API_SERVICES" ]; then
        log_info "Found API service resources in state. Removing them..."
        while IFS= read -r resource; do
            if [ -n "$resource" ]; then
                log_info "  - Removing: $resource"
                terraform state rm "$resource" 2>&1 || log_info "    Failed to remove $resource"
            fi
        done <<< "$API_SERVICES"
        log_info "  All API service resources removed from state."
    else
        log_info "  No google_project_service resources found in state."
    fi
    echo ""

    # --- Delete GKE cluster before Terraform destroy ---
    # GKE Autopilot creates node pools outside Terraform that block API disabling.
    # Deleting the cluster here ensures no node pools remain when terraform destroy
    # runs, regardless of whether Terraform's own cluster deletion succeeds first.
    GKE_CLUSTER_NAME="${ENV}-gke"
    log_info "Ensuring GKE cluster '${GKE_CLUSTER_NAME}' is deleted before Terraform destroy..."
    if gcloud container clusters describe "${GKE_CLUSTER_NAME}" \
            --location="${GCP_REGION}" \
            --project="${GCP_PROJECT_ID}" &>/dev/null; then
        log_info "  Deleting GKE cluster '${GKE_CLUSTER_NAME}'..."
        gcloud container clusters delete "${GKE_CLUSTER_NAME}" \
            --location="${GCP_REGION}" \
            --project="${GCP_PROJECT_ID}" \
            --quiet 2>/dev/null \
          && log_info "  GKE cluster deleted." \
          || log_warn "  GKE cluster deletion failed — continuing with destroy."
    else
        log_info "  GKE cluster '${GKE_CLUSTER_NAME}' not found — already gone."
    fi
    echo ""

    # --- Delete GKE/CSM-managed resources attached to the VPC ---
    # GKE and Cloud Service Mesh create firewall rules and Network Endpoint Groups (NEGs)
    # outside Terraform. They remain attached to the VPC after cluster deletion and block
    # network destroy.
    VPC_NAME="${ENV}-vpc"

    log_info "Deleting GKE/CSM-managed firewall rules on '${VPC_NAME}'..."
    GKE_FW_RULES=$(gcloud compute firewall-rules list \
        --filter="network:${VPC_NAME} AND (name:gke-* OR name:k8s-*)" \
        --format="value(name)" \
        --project="${GCP_PROJECT_ID}" 2>/dev/null || true)
    if [ -n "$GKE_FW_RULES" ]; then
        while IFS= read -r rule; do
            [ -n "$rule" ] || continue
            log_info "  - Deleting firewall rule: $rule"
            gcloud compute firewall-rules delete "$rule" \
                --project="${GCP_PROJECT_ID}" --quiet 2>/dev/null || log_info "    (already gone)"
        done <<< "$GKE_FW_RULES"
        log_info "  GKE/CSM firewall rules deleted."
    else
        log_info "  No GKE/CSM firewall rules found on '${VPC_NAME}'."
    fi

    log_info "Deleting GKE-managed Network Endpoint Groups (NEGs) on '${VPC_NAME}'..."
    # NEGs are zonal resources — list across all zones in the region
    GKE_NEGS=$(gcloud compute network-endpoint-groups list \
        --filter="network:${VPC_NAME} AND (name:k8s* OR name:gke*)" \
        --format="csv[no-heading](name,zone.basename())" \
        --project="${GCP_PROJECT_ID}" 2>/dev/null || true)
    if [ -n "$GKE_NEGS" ]; then
        while IFS=',' read -r neg_name neg_zone; do
            [ -n "$neg_name" ] || continue
            log_info "  - Deleting NEG: $neg_name (zone: $neg_zone)"
            gcloud compute network-endpoint-groups delete "$neg_name" \
                --zone="${neg_zone}" \
                --project="${GCP_PROJECT_ID}" --quiet 2>/dev/null || log_info "    (already gone)"
        done <<< "$GKE_NEGS"
        log_info "  GKE NEGs deleted."
    else
        log_info "  No GKE NEGs found on '${VPC_NAME}'."
    fi
    echo ""

    # --- Execute Terraform destroy ---
    log_warn "Executing Terraform destroy..."

    # Construct WIF pool ID from ENV and DEPLOYMENT_SUFFIX (extracted earlier)
    add_delay_if_run_in_cloudshell
    terraform destroy -auto-approve -lock-timeout=60s \
      -var="project_id=${GCP_PROJECT_ID}" \
      -var="region=${GCP_REGION}" \
      -var="environment=${ENV}" \
      -var="zone=${GCP_REGION}-a" \
      -var="deployment_suffix=${DEPLOYMENT_SUFFIX}" \
      -var="repository=${GITHUB_REPO:-}" \
      -var="github_org=${GITHUB_REPO:-}/" \
      -var="pki_strategy=${PKI_STRATEGY:-local}" \
      -var="base_domain=${BASE_DOMAIN:-}" \
      -var="keycloak_hostname=${KEYCLOAK_HOSTNAME:-}" \
      -var="nats_hostname=${NATS_HOSTNAME:-}" \
      -var="registration_hostname=${REGISTRATION_HOSTNAME:-}" \
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
