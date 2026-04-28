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

check_deployment_strategy () {
    # Set default deploy mode to GCP Cloud Build
    DEPLOY_MODE="cloudbuild"
    log_text "1: Google Cloud Build"
    log_text "   - only uses cloned Github repo, no further GitHub connection required"
    log_text "2: GitHub Actions"
    log_text "   - must be authorized via Workplace Identity Federation (may be prohibited by organizational policies)"
    DEFAULT_OPT="1"
    read -rp "Selection [$DEFAULT_OPT]: " INPUT_OPT
    SEL=${INPUT_OPT:-$DEFAULT_OPT}

    if [[ "$SEL" == "2" ]]; then
        DEPLOY_MODE="github"
        enable_github_oidc="true"
        REQUIRED_TOOLS=("gcloud" "terraform" "gh" "openssl" "nk" "jq" "sed")
        log_info "Selected Mode: GitHub Actions"
    else
        DEPLOY_MODE="cloudbuild"
        enable_github_oidc="false"
        REQUIRED_TOOLS=("gcloud" "terraform" "openssl" "jq" "sed")
        log_info "Selected Mode: Cloud Build (Cloud Native)"
    fi
}

get_user_inputs() {
    log_subsection_title "Google Cloud Platform settings"
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

    if [ "$DEPLOY_MODE" == "github" ]; then
        # GitHub Repo (Conditional)
        DEFAULT_GITHUB_REPO=${GITHUB_REPO:-""}
        if [ -z "$DEFAULT_GITHUB_REPO" ]; then
             DEFAULT_GITHUB_REPO=$(git config --get remote.origin.url 2>/dev/null | sed 's/.*github.com[:/]\(.*\).git/\1/' || echo "")
        fi
        read -rp "Enter your GitHub repository name (format: 'owner/repo'):  [${DEFAULT_GITHUB_REPO}]: " INPUT_GITHUB_REPO
        GITHUB_REPO=${INPUT_GITHUB_REPO:-$DEFAULT_GITHUB_REPO}
    else
        GITHUB_REPO=""
    fi
    # --- Environment Name ---
    DEFAULT_ENV=${ENV:-"sandbox"}
    while true; do
        read -rp "Name of deployment environment, e.g. dev, qa, production (max 15 chars) [${DEFAULT_ENV}]: " INPUT_ENV
        ENV=${INPUT_ENV:-$DEFAULT_ENV}
        if [ ${#ENV} -le 15 ]; then break; fi
        log_warn "${FAIL} name is too long."
    done

    # --- CPU Architecture ---
    DEFAULT_ARCH=${ARCH:-"arm64"}
    log_subsection_title "CPU Architecture Selection"
    log_text "  arm64 = default - e.g. Google Axion (N4A,C4A)"
    log_text "  amd64 = x86 - Intel, AMD"
    while true; do
        read -rp "Architecture (arm64/amd64) [${DEFAULT_ARCH}]: " INPUT_ARCH
        ARCH=${INPUT_ARCH:-$DEFAULT_ARCH}
        if [[ "$ARCH" == "arm64" || "$ARCH" == "amd64" ]]; then break; fi
    done

    # --- PKI Strategy ---
    DEFAULT_PKI_STRATEGY=${PKI_STRATEGY:-"local"}
    log_subsection_title "PKI Strategy Selection"
    log_text "  local  = Self-signed certificates & IP addresses as hostnames"
    log_text "  remote = Google CAS issued certifcates & Cloud DNS based hostnames"
    while true; do
        read -rp "Strategy (local/remote) [${DEFAULT_PKI_STRATEGY}]: " INPUT_PKI_STRATEGY
        PKI_STRATEGY=${INPUT_PKI_STRATEGY:-$DEFAULT_PKI_STRATEGY}
        if [[ "$PKI_STRATEGY" == "local" || "$PKI_STRATEGY" == "remote" ]]; then break; fi
    done

    # --- Base Domain ---
    BASE_DOMAIN=${BASE_DOMAIN:-""}
    if [ "$PKI_STRATEGY" == "remote" ]; then
        log_subsection_title "DNS settings"
        read -rp "Base Domain (e.g. sdv.example.com) [${BASE_DOMAIN}]: " INPUT_BASE_DOMAIN
        BASE_DOMAIN=${INPUT_BASE_DOMAIN:-$BASE_DOMAIN}
        if [ -z "$BASE_DOMAIN" ]; then log_error "Domain required."; fi

        # --- Existing DNS Zone (Optional) ---
        log_text "" # For spacing
        log_text "Existing Cloud DNS Zone (Optional):"
        log_text "If you want to use an existing Cloud DNS zone, enter its name below."
        log_text "Leave blank to create a new DNS zone."
        log_text "Note: You first need to register and activate a domain at"
        log_text "https://console.cloud.google.com/net-services/domains/registrations/list"
        DEFAULT_EXISTING_DNS_ZONE=${EXISTING_DNS_ZONE:-""}
        read -rp "Existing DNS zone name [${DEFAULT_EXISTING_DNS_ZONE}]: " INPUT_EXISTING_DNS_ZONE
        EXISTING_DNS_ZONE=${INPUT_EXISTING_DNS_ZONE:-$DEFAULT_EXISTING_DNS_ZONE}
    else
        BASE_DOMAIN="" # Ensure base domain is empty for local strategy
        EXISTING_DNS_ZONE=""
    fi

    # --- Service Hostnames ---
    if [ "$PKI_STRATEGY" == "remote" ]; then
        log_text ""
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

    # WIF & Random Suffix (Global for consistency)
    RANDOM_SUFFIX=$(openssl rand -hex 4)
    if [ "$DEPLOY_MODE" == "github" ]; then
        GCP_WORKLOAD_IDENTITY_POOL_ID="${ENV}-github-wif-${RANDOM_SUFFIX}"
        GCP_WORKLOAD_IDENTITY_PROVIDER_ID="github"
    else
        # empty values for Terraform (count=0)
        GCP_WORKLOAD_IDENTITY_POOL_ID=""
        GCP_WORKLOAD_IDENTITY_PROVIDER_ID=""
    fi

    # need random names for ca pool (to be able to deploy and teardown frequently)
    CREATED_SERVER_CA_POOL="server-ca-pool-${RANDOM_SUFFIX}"
    CREATED_FACTORY_CA_POOL="factory-ca-pool-${RANDOM_SUFFIX}"
    CREATED_REG_CA_POOL="registration-ca-pool-${RANDOM_SUFFIX}"

    # --- Existing CA Configuration (Optional) ---
    log_text "" # For spacing

    if [ "$PKI_STRATEGY" == "remote" ]; then
        log_subsection_title "Certificate Authority Service settings"
        log_text "Existing CA Configuration (Optional):"
        log_text "If you want to use existing CAs instead of creating new ones, enter their names below."
        log_text "Leave blank to create new CAs."
        log_text "" # For spacing

        # Server CA
        DEFAULT_EXISTING_SERVER_CA=${EXISTING_SERVER_CA:-""}
        read -rp "Server certificate certificate authority [${DEFAULT_EXISTING_SERVER_CA}]: " INPUT_EXISTING_SERVER_CA
        EXISTING_SERVER_CA=${INPUT_EXISTING_SERVER_CA:-$DEFAULT_EXISTING_SERVER_CA}

        if [ -n "$EXISTING_SERVER_CA" ]; then
            DEFAULT_EXISTING_SERVER_CA_POOL=${EXISTING_SERVER_CA_POOL:-$CREATED_SERVER_CA_POOL}
            read -rp "Server certificate CA Pool name [${DEFAULT_EXISTING_SERVER_CA_POOL}]: " INPUT_EXISTING_SERVER_CA_POOL
            EXISTING_SERVER_CA_POOL=${INPUT_EXISTING_SERVER_CA_POOL:-$DEFAULT_EXISTING_SERVER_CA_POOL}
        else
            EXISTING_SERVER_CA_POOL=""
        fi

        # Factory CA
        DEFAULT_EXISTING_FACTORY_CA=${EXISTING_FACTORY_CA:-""}
        read -rp "Factory certificate certificate authority [${DEFAULT_EXISTING_FACTORY_CA}]: " INPUT_EXISTING_FACTORY_CA
        EXISTING_FACTORY_CA=${INPUT_EXISTING_FACTORY_CA:-$DEFAULT_EXISTING_FACTORY_CA}

        if [ -n "$EXISTING_FACTORY_CA" ]; then
            DEFAULT_EXISTING_FACTORY_CA_POOL=${EXISTING_FACTORY_CA_POOL:-$CREATED_FACTORY_CA_POOL}
            read -rp "Factory certificate certificate pool name [${DEFAULT_EXISTING_FACTORY_CA_POOL}]: " INPUT_EXISTING_FACTORY_CA_POOL
            EXISTING_FACTORY_CA_POOL=${INPUT_EXISTING_FACTORY_CA_POOL:-$DEFAULT_EXISTING_FACTORY_CA_POOL}
        else
            EXISTING_FACTORY_CA_POOL=""
        fi

        # Registration CA
        DEFAULT_EXISTING_REG_CA=${EXISTING_REG_CA:-""}
        read -rp "Registration server certificate authority name [${DEFAULT_EXISTING_REG_CA}]: " INPUT_EXISTING_REG_CA
        EXISTING_REG_CA=${INPUT_EXISTING_REG_CA:-$DEFAULT_EXISTING_REG_CA}

        if [ -n "$EXISTING_REG_CA" ]; then
            DEFAULT_EXISTING_REG_CA_POOL=${EXISTING_REG_CA_POOL:-$CREATED_REG_CA_POOL}
            read -rp "Registration server certificate pool name [${DEFAULT_EXISTING_REG_CA_POOL}]: " INPUT_EXISTING_REG_CA_POOL
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
    log_text ""
    log_info "Configuration is complete, saving to $ENV_FILE..."
    {
        echo "GCP_PROJECT_ID=\"${GCP_PROJECT_ID}\""
        echo "GCP_REGION=\"${GCP_REGION}\""
        echo "DEPLOY_MODE=\"${DEPLOY_MODE}\""
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
        echo "ARCH=\"${ARCH}\""
    } > "$ENV_FILE"
    log_text "" # For spacing

    gcloud config set project "$GCP_PROJECT_ID"
    log_text "" # For spacing
}

main() {
    log_text "=================================================================="
    log_text "===               Nexus SDV Platform Bootstrapping             ==="
    log_text "=================================================================="
    parse_arguments
    load_bootstrap_env
    # Step 0
    (( ++i ))
    log_section_title "Step ${i}: Check if bootstrap runs in CloudShell"
    check_if_running_in_cloud_shell
    # Step 1
    (( ++i ))
    log_section_title "Step ${i}: Check deployment strategy (CloudBuild or Github)"
    check_deployment_strategy
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
    log_section_title "Step ${i}: Get user inputs for project configuration"
    get_user_inputs
    # Step 5
    (( ++i ))
    log_section_title "Step ${i}: Enable required GCP APIs"
    enable_gcp_apis
    # Step 6
    if [ "$DEPLOY_MODE" == "github" ]; then
      (( ++i ))
      log_section_title "Step ${i}: Set initial GitHub variables"
      setup_initial_github_vars
    fi
    # Step 7
    (( ++i ))
    log_section_title "Step ${i}: Set up Terraform"
    setup_terraform_backend
    # Step 8
    (( ++i ))
    log_section_title "${i}: Run Terraform to apply infrastructure changes"
    run_terraform_apply
    # Step 9
    if [ "$DEPLOY_MODE" == "github" ]; then
      (( ++i ))
      log_section_title "Step ${i}: Finalize GitHub variables"
      finalize_github_vars
    fi
    # Step 10
    (( ++i ))
    log_section_title "Step ${i}: Configure first batch of generated secrets in Secret Manager"
    configure_secrets
    # Step 11
    (( ++i ))
    log_section_title "Step ${i}: Initialize PKI"
    initialize_pki
    # Step 12
    (( ++i ))
    log_section_title "Step ${i}: Create remaining secrets from PKI setup"
    upload_pki_secrets
    # Step 13
    (( ++i ))
    log_section_title "Step ${i}: Trigger and monitor the deployment pipeline"
    trigger_deployment_pipeline
    # Step 14
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

