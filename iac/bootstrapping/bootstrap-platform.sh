#!/bin/bash
# ==============================================================================
# Nexus SDV Bootstrapping Script
#
# This script performs a complete, automated setup of the Nexus SDV GCP Platform.
# It supports both local execution (GitHub Actions) and Cloud Shell (Cloud Build).
#
# Author: Team Sky
# Version: 1.0
# ==============================================================================

# Terminates the script immediately if a command fails or a variable is not set
set -euo pipefail
i=0

# Debug: catch the source of any deferred parse/eval errors
trap 'echo "DEBUG TRAP: ERR at ${BASH_SOURCE[0]:-$0}:${LINENO} (exit=$?)" >&2' ERR
# Load shared utilities libraries
source "$(dirname "$0")/lib/common.sh"
source "$(dirname "$0")/lib/authenticate.sh"
source "$(dirname "$0")/lib/config.sh"
source "$(dirname "$0")/lib/terraform.sh"
source "$(dirname "$0")/lib/secrets.sh"
source "$(dirname "$0")/lib/deployment.sh"

# --- Parse command line arguments ---
AUTO_APPROVE=false

get_user_input() {
    AUTO_APPROVE="$AUTO_APPROVE" "$(dirname "$0")/tools/create-bootstrap-env.sh"

    load_bootstrap_env
    derive_ca_pool_names

    # Values derived from the persisted config, needed by later steps.
    enable_github_oidc="false"
    REQUIRED_TOOLS=("gcloud" "terraform" "openssl" "nk" "jq" "sed")
    GCP_WORKLOAD_IDENTITY_POOL_ID=""
    GCP_WORKLOAD_IDENTITY_PROVIDER_ID=""

    if [ "$DEPLOY_MODE" == "github" ]; then
        enable_github_oidc="true"
        REQUIRED_TOOLS=("gcloud" "terraform" "gh" "openssl" "nk" "jq" "sed")
        GCP_WORKLOAD_IDENTITY_POOL_ID="${ENV}-github-wif-${DEPLOYMENT_SUFFIX}"
        GCP_WORKLOAD_IDENTITY_PROVIDER_ID="github"
    fi
}

main() {
    log_text "=================================================================="
    log_text "===               Nexus SDV Platform Bootstrapping             ==="
    log_text "=================================================================="
    parse_arguments "$@"
    load_bootstrap_env

    # Step 0
    (( ++i ))
    log_section_title "Step ${i}: Check if bootstrap runs in CloudShell"
    check_if_running_in_cloud_shell

    # Step 1
    (( ++i ))
    log_section_title "Step ${i}: Get user inputs for project configuration"
    get_user_input

    # Step 2
    (( ++i ))
    log_section_title "Step ${i}: Check prerequisites"
    check_prerequisites
    # If the bootstrapping script is run from Google Cloud Console Terraform
    # needs to have the latest version
    install_cloud_shell_tools

    # Step 3
    (( ++i ))
    log_section_title "Step ${i}: Authenticate to platform"
    check_authentication

    # Step 4
    (( ++i ))
    log_section_title "Step ${i}: Enable required GCP APIs"
    enable_gcp_apis

    # Step 5
    if [ "$DEPLOY_MODE" == "github" ]; then
      (( ++i ))
      log_section_title "Step ${i}: Set initial GitHub variables"
      setup_initial_github_vars
    fi

    # Step 6 & 7: Terraform (skippable via --skip-terraform).
    # When skipped, the infrastructure is assumed to already exist and we only
    # re-run the post-Terraform steps (secrets, PKI, deployment pipeline). The
    # values normally produced by run_terraform_apply are sourced from Secret
    # Manager so later steps and `set -u` are satisfied.
    if [ "${SKIP_TERRAFORM:-false}" == "true" ]; then
        log_warn "Skipping Terraform stage (--skip-terraform)."
        SERVICE_ACCOUNT=""
        KEYCLOAK_DB_PASSWORD=$(gcloud secrets versions access latest \
            --secret="KEYCLOAK_DB_PASSWORD" --project="$GCP_PROJECT_ID" 2>/dev/null || echo "")
    else
        # Step 6
        (( ++i ))
        log_section_title "Step ${i}: Set up Terraform"
        setup_terraform_backend

        # Step 7
        (( ++i ))
        log_section_title "${i}: Run Terraform to apply infrastructure changes"
        run_terraform_apply
    fi

    # Step 8
    if [ "$DEPLOY_MODE" == "github" ]; then
      (( ++i ))
      log_section_title "Step ${i}: Finalize GitHub variables"
      finalize_github_vars
    fi

    # Step 9
    (( ++i ))
    log_section_title "Step ${i}: Configure first batch of generated secrets in Secret Manager"
    configure_secrets

    # Step 10
    (( ++i ))
    log_section_title "Step ${i}: Initialize PKI"
    initialize_pki

    # Step 11
    (( ++i ))
    log_section_title "Step ${i}: Create remaining secrets from PKI setup"
    upload_pki_secrets

    # Step 12
    (( ++i ))
    log_section_title "Step ${i}: Trigger and monitor the deployment pipeline"
    trigger_deployment_pipeline

    # Step 13
    if [ "$PKI_STRATEGY" == "local" ]; then
      (( ++i ))
      log_section_title "Step ${i}: Update hostname entries inf environment file with IP addresses"
      update_environment_file
    fi

    # --- Final message ---
    log_text "=================================================================="
    log_text "  🎉 Nexus SDV platform bootstrapping successfully completed! 🎉  "
    log_text "=================================================================="
    log_text "Your Nexus SDV environment is now ready for use."
}

main "$@"

