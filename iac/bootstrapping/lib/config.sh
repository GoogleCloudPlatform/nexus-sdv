#!/bin/bash
# ==============================================================================
# Nexus SDV Bootstrapping — Shared Configuration Library
#
# Sourced by all bootstrap and teardown scripts to avoid code duplication.
# ==============================================================================

# Source .bootstrap_env if it exists. Sets ENV_FILE variable.
load_bootstrap_env() {
    ENV_FILE="iac/bootstrapping/.bootstrap_env"
    if [ -f "$ENV_FILE" ]; then
        log_info "Loading saved configuration from $ENV_FILE..."
        # shellcheck source=/dev/null
        source "$ENV_FILE"
    fi
}

# Load all GitHub environment variables into the current shell.
# Usage: load_github_environment_variables "owner/repo" "env-name"
load_github_environment_variables() {
    local GITHUB_REPO="$1"
    local ENV_NAME="$2"

    log_text "Loading variables from Github Repo $GITHUB_REPO & environment '$ENV_NAME'..."

    local variables_json
    variables_json=$(gh variable list --env "$ENV_NAME" --repo "$GITHUB_REPO" --json name,value)

    if [ -z "$variables_json" ]; then
        log_error "${FAIL}: Failed loading variables from Github."
        log_text "Check that the repo, environment, and your permissions are correct."
        exit 1
    fi

    while read -r line; do
        local VAR_NAME
        local VAR_VALUE

        VAR_NAME=$(log_text "$line" | jq -r '.name')
        VAR_VALUE=$(log_text "$line" | jq -r '.value')

        export "$VAR_NAME"="$VAR_VALUE"

        log_text "  ${COLOR_GREEN}✓ Loaded: $VAR_NAME${COLOR_NC}"
    done < <(log_text "$variables_json" | jq -c '.[]')

    log_text "${COLOR_GREEN}All environment variables successfully loaded.${COLOR_NC}"
    echo
}

enable_gcp_apis() {    # List of APIs required before Terraform runs
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

    # Add Cloud Build API
    if [ "$DEPLOY_MODE" == "cloudbuild" ]; then
        REQUIRED_APIS+=("cloudbuild.googleapis.com")
    fi

    log_info "Checking and enabling APIs (this may take a few minutes)..."

    # Check which APIs are disabled and enable them
    APIS_TO_ENABLE=()
    for api in "${REQUIRED_APIS[@]}"; do
        if ! gcloud services list --enabled --filter="name:$api" --format="value(name)" 2>/dev/null | grep -q "$api"; then
            log_info "  ${NOTSET} $api (disabled, will enable)"
            APIS_TO_ENABLE+=("$api")
        else
            log_info "  ${CHECK} $api (already enabled)"
        fi
    done

    # Enable all disabled APIs in one batch operation
    if [ ${#APIS_TO_ENABLE[@]} -gt 0 ]; then
        log_info "Enabling ${#APIS_TO_ENABLE[@]} API(s)..."
        gcloud services enable "${APIS_TO_ENABLE[@]}" --project="$GCP_PROJECT_ID"

        log_info "Waiting for APIs to propagate (30 seconds)..."
        sleep 30
        log_info "APIs enabled successfully."
    else
        log_info "All required APIs are already enabled."
    fi
    log_info "" # For spacing
}

setup_initial_github_vars () {
    if [ "$DEPLOY_MODE" != "github" ]; then return; fi
    GCP_PROJECT_NUMBER=$(gcloud projects describe "$GCP_PROJECT_ID" --format="value(projectNumber)")
    GCP_WORKLOAD_IDENTITY_POOL_ID="${ENV}-github-wif-${RANDOM_SUFFIX}"
    GCP_WORKLOAD_IDENTITY_PROVIDER_ID="github"

    log_info "Creating GitHub variables for authentication with GCP"

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

    log_info "Following GitHub variables are present:"
    log_info "  ${CHECK} GCP_PROJECT_ID: $GCP_PROJECT_ID"
    log_info "  ${CHECK} GCP_PROJECT_NUMBER: $GCP_PROJECT_NUMBER"
    log_info "  ${CHECK} GCP_REGION: $GCP_REGION"
    log_info "  ${CHECK} GCP_WORKLOAD_IDENTITY_POOL_ID: $GCP_WORKLOAD_IDENTITY_POOL_ID"
    log_info "  ${CHECK} GCP_WORKLOAD_IDENTITY_PROVIDER_ID: $GCP_WORKLOAD_IDENTITY_PROVIDER_ID"
    if [ "$PKI_STRATEGY" = "remote" ]; then
        log_info "  ${CHECK} GCP_SERVER_CA_POOL: $CREATED_SERVER_CA_POOL"
    fi
    log_info "  ${CHECK} PKI_STRATEGY: $PKI_STRATEGY"
}

finalize_github_vars() {
    if [ "$DEPLOY_MODE" != "github" ]; then return; fi
    gh variable set GCP_SERVICE_ACCOUNT -b "$SERVICE_ACCOUNT" --repo "$GITHUB_REPO" --env "$ENV"
    log_info "Following GCP service account is created by terraform:"
    log_info "  ${CHECK} GCP_SERVICE_ACCOUNT: $SERVICE_ACCOUNT"

    log_info "Infrastructure ready."
}

update_environment_file() {
    if [ "$PKI_STRATEGY" != "local" ]; then
      return;
    fi
    log_info ""
    log_info "Updating environment file with the IP addresses from GCP secretmanager"
    log_info "" # For spacing

    # Secrets are written by deployment workflows after LB IPs are assigned.
    # Skip gracefully on first bootstrap run before deployments have completed.
    if ! gcloud secrets describe "REGISTRATION_HOSTNAME" --project="$GCP_PROJECT_ID" &>/dev/null; then
        log_warn "Hostname secrets not yet available in Secret Manager."
        log_warn "Re-run this step after the deployment workflows have completed."
        return 0
    fi

    GCP_REGISTRATION_HOSTNAME=$(gcloud secrets versions access latest --secret="REGISTRATION_HOSTNAME" --project="$GCP_PROJECT_ID")
    GCP_NATS_HOSTNAME=$(gcloud secrets versions access latest --secret="NATS_HOSTNAME" --project="$GCP_PROJECT_ID")
    GCP_KEYCLOAK_HOSTNAME=$(gcloud secrets versions access latest --secret="KEYCLOAK_HOSTNAME" --project="$GCP_PROJECT_ID")

    log_info "REGISTRATION_HOSTNAME: ${GCP_REGISTRATION_HOSTNAME}"
    log_info "NATS_HOSTNAME: ${GCP_NATS_HOSTNAME}"
    log_info "KEYCLOAK_HOSTNAME ${GCP_KEYCLOAK_HOSTNAME}"

    sed_inplace "s|^REGISTRATION_HOSTNAME=.*|REGISTRATION_HOSTNAME=\"${GCP_REGISTRATION_HOSTNAME}\"|" "$ENV_FILE"
    sed_inplace "s|^NATS_HOSTNAME=.*|NATS_HOSTNAME=\"${GCP_NATS_HOSTNAME}\"|" "$ENV_FILE"
    sed_inplace "s|^KEYCLOAK_HOSTNAME=.*|KEYCLOAK_HOSTNAME=\"${GCP_KEYCLOAK_HOSTNAME}\"|" "$ENV_FILE"

}

load_config() {
# Check Github Context if needed
if [ "$DEPLOY_MODE" == "github" ]; then
    DEFAULT_GITHUB_REPO=${GITHUB_REPO:-""}
    read -rp "GitHub Repository (owner/repo) [${DEFAULT_GITHUB_REPO}]: " INPUT_GITHUB_REPO
    GITHUB_REPO=${INPUT_GITHUB_REPO:-$DEFAULT_GITHUB_REPO}

    log_text "Loading GitHub variables..."
    load_github_environment_variables "$GITHUB_REPO" "$ENV"
else
    GITHUB_REPO="local/placeholder" # Dummy for Terraform
    log_text "Skipping GitHub variable download (Cloud Build mode)."
fi
}

cleanup_github_variables() {
    if [ "$DEPLOY_MODE" == "github" ]; then
        # Delete only non-required variables set by bootstrap script
        # The following 5 required variables are PRESERVED:
        #   - GCP_PROJECT_ID
        #   - GCP_REGION
        #   - GCP_SERVICE_ACCOUNT
        #   - GCP_WORKLOAD_IDENTITY_POOL_ID
        #   - GCP_WORKLOAD_IDENTITY_PROVIDER_ID

        log_info "Deleting GCP_PROJECT_NUMBER..."
        gh variable delete GCP_PROJECT_NUMBER --env "$ENV" --repo "$GITHUB_REPO" 2>/dev/null || log_info "  (already deleted or doesn't exist)"

        log_info "Deleting RANDOM_SUFFIX..."
        gh variable delete RANDOM_SUFFIX --env "$ENV" --repo "$GITHUB_REPO" 2>/dev/null || log_info "  (already deleted or doesn't exist)"

        log_info "Non-required variables cleaned. Required variables preserved for future bootstrap runs."
        log_text ""
    else
        log_text "Skipping GitHub variable cleanup (Cloud Build mode)."
    fi
}

cleanup_local_files() {
    # Remove locally generated PKI files
    if [ -d "base-services/registration/pki" ]; then
        log_info "Removing generated PKI certificates..."
        # Keep the structure but remove generated certificates
        find base-services/registration/pki -type f \( -name "*.pem" -o -name "*.srl" -o -name "index.*" -o -name "serial*" -o -name "crlnumber*" \) -delete
        log_info "PKI certificates cleaned."
    else
        log_info "No PKI directory found to clean."
    fi

    # Remove Python certificates
    if [ -d "base-services/registration/python/certificates" ]; then
        log_info "Removing Python client certificates..."
        rm -rf base-services/registration/python/certificates
        log_info "Python certificates cleaned."
    fi

    # Remove bootstrap configuration file
    if [ -f "iac/bootstrapping/.bootstrap_env" ]; then
      read -rp "Are you sure you want to delete the bootstrap configuration file? (type 'yes' to confirm): " CONFIRM
      if [ "$CONFIRM" == "yes" ]; then
        log_info "Removing bootstrap configuration file..."
        rm -f iac/bootstrapping/.bootstrap_env
        log_info "Bootstrap configuration removed."
      fi
    fi

    log_info "Local cleanup complete."
    echo ""
}
