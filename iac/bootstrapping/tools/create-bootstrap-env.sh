#!/bin/bash
# ==============================================================================
# Create / update the .bootstrap_env configuration file
#
# Determines the deployment strategy (Cloud Build vs GitHub Actions) and
# prompts for GCP project settings, environment name, PKI strategy, and other
# bootstrap configuration, then writes the result to $ENV_FILE.
#
# Usage:
#   iac/bootstrapping/tools/create-bootstrap-env.sh [environment] [-y|--yes]
#
#   environment   Optional name. When given, configuration is read from and
#                 written to iac/bootstrapping/<environment>.bootstrap_env
#                 instead of the default iac/bootstrapping/.bootstrap_env.
#
# Env vars:
#   AUTO_APPROVE   Set to "true" to use default values for all prompts.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/config.sh"

AUTO_APPROVE="${AUTO_APPROVE:-false}"
ENVIRONMENT=""

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)
            AUTO_APPROVE=true
            shift
            ;;
        -h|--help)
            log_text "Usage: $0 [environment] [-y|--yes]"
            log_text "  environment   Optional name. When given, configuration is read from and"
            log_text "                written to iac/bootstrapping/<environment>.bootstrap_env"
            log_text "                instead of the default iac/bootstrapping/.bootstrap_env."
            log_text "  -y, --yes     Use default values for all prompts (non-interactive)."
            exit 0
            ;;
        -*)
            log_error "Unknown option: $1"
            ;;
        *)
            [ -z "$ENVIRONMENT" ] || log_error "Unexpected argument: $1"
            ENVIRONMENT="$1"
            shift
            ;;
    esac
done

load_bootstrap_env "$ENVIRONMENT"

# --- Deployment strategy ---
log_subsection_title "Deployment strategy (CloudBuild or Github)"
if [ "$AUTO_APPROVE" != true ]; then
    log_text "1: Google Cloud Build"
    log_text "   - only uses cloned Github repo, no further GitHub connection required"
    log_text "2: GitHub Actions"
    log_text "   - must be authorized via Workplace Identity Federation (may be prohibited by organizational policies)"
    DEFAULT_OPT="1"
    read -rp "Selection [$DEFAULT_OPT]: " INPUT_OPT
    SEL=${INPUT_OPT:-$DEFAULT_OPT}
else
    SEL="1"
fi

if [[ "$SEL" == "2" ]]; then
    DEPLOY_MODE="github"
    log_info "Selected Mode: GitHub Actions"
else
    DEPLOY_MODE="cloudbuild"
    log_info "Selected Mode: Cloud Build (Cloud Native)"
fi

log_subsection_title "Google Cloud Platform settings"
# --- GCP Project ID ---
# Default comes exclusively from .bootstrap_env; never read from local gcloud config.
DEFAULT_GCP_PROJECT_ID=${GCP_PROJECT_ID:-""}
if [ "$AUTO_APPROVE" != true ]; then
    read -rp "Google Cloud Project ID [${DEFAULT_GCP_PROJECT_ID}]: " INPUT_GCP_PROJECT_ID
fi
GCP_PROJECT_ID=${INPUT_GCP_PROJECT_ID:-$DEFAULT_GCP_PROJECT_ID}

# --- GCP Region ---
DEFAULT_GCP_REGION=${GCP_REGION:-""}
if [ "$AUTO_APPROVE" != true ]; then
    read -rp "GCP Region (e.g. europe-west3) [${DEFAULT_GCP_REGION}]: " INPUT_GCP_REGION
fi
GCP_REGION=${INPUT_GCP_REGION:-$DEFAULT_GCP_REGION}

if [ "$DEPLOY_MODE" == "github" ]; then
    # GitHub Repo (Conditional)
    DEFAULT_GITHUB_REPO=${GITHUB_REPO:-""}
    if [ -z "$DEFAULT_GITHUB_REPO" ]; then
         DEFAULT_GITHUB_REPO=$(git config --get remote.origin.url 2>/dev/null | sed 's/.*github.com[:/]\(.*\).git/\1/' || echo "")
    fi
    if [ "$AUTO_APPROVE" != true ]; then
        read -rp "Enter your GitHub repository name (format: 'owner/repo'):  [${DEFAULT_GITHUB_REPO}]: " INPUT_GITHUB_REPO
    fi
    GITHUB_REPO=${INPUT_GITHUB_REPO:-$DEFAULT_GITHUB_REPO}
else
    GITHUB_REPO=""
fi
# --- Environment Name ---
DEFAULT_ENV=${ENV:-"sandbox"}
if [ "$AUTO_APPROVE" != true ]; then
    while true; do
        read -rp "Name of deployment environment, e.g. dev, qa, production (max 15 chars) [${DEFAULT_ENV}]: " INPUT_ENV
        ENV=${INPUT_ENV:-$DEFAULT_ENV}
        if [ ${#ENV} -le 15 ]; then break; fi
        log_warn "${FAIL} name is too long."
    done
else
    ENV=${ENV:-$DEFAULT_ENV}
fi

# --- CPU Architecture ---
DEFAULT_ARCH=${ARCH:-"arm64"}
if [ "$AUTO_APPROVE" != true ]; then
    log_subsection_title "CPU Architecture Selection"
    log_text "  arm64 = default - e.g. Google Axion (N4A,C4A)"
    log_text "  amd64 = x86 - Intel, AMD"
    while true; do
        read -rp "Architecture (arm64/amd64) [${DEFAULT_ARCH}]: " INPUT_ARCH
        ARCH=${INPUT_ARCH:-$DEFAULT_ARCH}
        if [[ "$ARCH" == "arm64" || "$ARCH" == "amd64" ]]; then break; fi
    done
else
    ARCH=${ARCH:-$DEFAULT_ARCH}
fi

# --- PKI Strategy ---
DEFAULT_PKI_STRATEGY=${PKI_STRATEGY:-"local"}
if [ "$AUTO_APPROVE" != true ]; then
    log_subsection_title "PKI Strategy Selection"
    log_text "  local  = Self-signed certificates & IP addresses as hostnames"
    log_text "  remote = Google CAS issued certifcates & Cloud DNS based hostnames"
    while true; do
        read -rp "Strategy (local/remote) [${DEFAULT_PKI_STRATEGY}]: " INPUT_PKI_STRATEGY
        PKI_STRATEGY=${INPUT_PKI_STRATEGY:-$DEFAULT_PKI_STRATEGY}
        if [[ "$PKI_STRATEGY" == "local" || "$PKI_STRATEGY" == "remote" ]]; then break; fi
    done
else
    PKI_STRATEGY=${PKI_STRATEGY:-$DEFAULT_PKI_STRATEGY}
fi

# --- Base Domain ---
BASE_DOMAIN=${BASE_DOMAIN:-""}
if [ "$PKI_STRATEGY" == "remote" ]; then
    if [ "$AUTO_APPROVE" != true ]; then
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
    fi
else
    BASE_DOMAIN="" # Ensure base domain is empty for local strategy
    EXISTING_DNS_ZONE=""
fi

# --- Service Hostnames ---
if [ "$PKI_STRATEGY" == "remote" ]; then
    if [ "$AUTO_APPROVE" != true ]; then
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

        DEFAULT_FLEETVIEW_HOSTNAME=${FLEETVIEW_HOSTNAME:-"fleetview"}
        read -rp "Fleet View Hostname [${DEFAULT_FLEETVIEW_HOSTNAME}]: " INPUT_FLEETVIEW_HOSTNAME
        FLEETVIEW_HOSTNAME=${INPUT_FLEETVIEW_HOSTNAME:-$DEFAULT_FLEETVIEW_HOSTNAME}
    else
        KEYCLOAK_HOSTNAME=${KEYCLOAK_HOSTNAME:-"keycloak"}
        NATS_HOSTNAME=${NATS_HOSTNAME:-"nats"}
        REGISTRATION_HOSTNAME=${REGISTRATION_HOSTNAME:-"registration"}
        FLEETVIEW_HOSTNAME=${FLEETVIEW_HOSTNAME:-"fleetview"}
    fi
else
    # for the local PKI strategy, these values will be filled with
    # the external IP addresses of the loadbalancer service
    KEYCLOAK_HOSTNAME="keycloak"
    NATS_HOSTNAME="nats"
    REGISTRATION_HOSTNAME="registration"
    FLEETVIEW_HOSTNAME="fleetview"
fi

# --- Google Maps ---
DEFAULT_GOOGLE_MAPS_API_KEY=${NEXT_PUBLIC_GOOGLE_MAPS_API_KEY:-""}
DEFAULT_GOOGLE_MAPS_MAP_ID=${NEXT_PUBLIC_GOOGLE_MAPS_MAP_ID:-""}
if [ "$AUTO_APPROVE" != true ]; then
    log_subsection_title "Google Maps settings"
    log_text "Required by the data-web-client. Leave blank to skip (web client map features will be disabled)."
    read -rp "Google Maps API Key [${DEFAULT_GOOGLE_MAPS_API_KEY}]: " INPUT_GOOGLE_MAPS_API_KEY
    read -rp "Google Maps Map ID [${DEFAULT_GOOGLE_MAPS_MAP_ID}]: " INPUT_GOOGLE_MAPS_MAP_ID
fi
NEXT_PUBLIC_GOOGLE_MAPS_API_KEY=${INPUT_GOOGLE_MAPS_API_KEY:-$DEFAULT_GOOGLE_MAPS_API_KEY}
NEXT_PUBLIC_GOOGLE_MAPS_MAP_ID=${INPUT_GOOGLE_MAPS_MAP_ID:-$DEFAULT_GOOGLE_MAPS_MAP_ID}

# --- Random Suffix (Global for consistency) ---
# Preserve the suffix from a previous run so resource names and password
# keepers stay stable across re-runs. Only generate a new value on the
# very first bootstrap of a project (when the env file has no entry yet).
DEPLOYMENT_SUFFIX=${DEPLOYMENT_SUFFIX:-$(openssl rand -hex 4)}

# need random names for ca pool (to be able to deploy and teardown frequently)
derive_ca_pool_names

# --- Existing CA Configuration (Optional) ---
log_text "" # For spacing

if [ "$PKI_STRATEGY" == "remote" ]; then
    if [ "$AUTO_APPROVE" != true ]; then
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
        EXISTING_SERVER_CA=${EXISTING_SERVER_CA:-""}
        EXISTING_SERVER_CA_POOL=${EXISTING_SERVER_CA_POOL:-""}
        EXISTING_FACTORY_CA=${EXISTING_FACTORY_CA:-""}
        EXISTING_FACTORY_CA_POOL=${EXISTING_FACTORY_CA_POOL:-""}
        EXISTING_REG_CA=${EXISTING_REG_CA:-""}
        EXISTING_REG_CA_POOL=${EXISTING_REG_CA_POOL:-""}
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
# the .bootstrap_env will be updated AFTER Terraform creates the CAs.
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
    echo "FLEETVIEW_HOSTNAME=\"${FLEETVIEW_HOSTNAME}\""
    echo "EXISTING_SERVER_CA=\"${EXISTING_SERVER_CA}\""
    echo "EXISTING_SERVER_CA_POOL=\"${EXISTING_SERVER_CA_POOL}\""
    echo "EXISTING_FACTORY_CA=\"${EXISTING_FACTORY_CA}\""
    echo "EXISTING_FACTORY_CA_POOL=\"${EXISTING_FACTORY_CA_POOL}\""
    echo "EXISTING_REG_CA=\"${EXISTING_REG_CA}\""
    echo "EXISTING_REG_CA_POOL=\"${EXISTING_REG_CA_POOL}\""
    echo "ARCH=\"${ARCH}\""
    echo "NEXT_PUBLIC_GOOGLE_MAPS_API_KEY=\"${NEXT_PUBLIC_GOOGLE_MAPS_API_KEY}\""
    echo "NEXT_PUBLIC_GOOGLE_MAPS_MAP_ID=\"${NEXT_PUBLIC_GOOGLE_MAPS_MAP_ID}\""
    echo "DEPLOYMENT_SUFFIX=\"${DEPLOYMENT_SUFFIX}\""
    # ---------------------------------------------------------------------
    # Everything below is written but never prompted for: these keys are
    # optional, or are set by another tool. They must still be listed here.
    # This block REPLACES the file, so a key missing from it is silently
    # dropped on every bootstrap — a custom value then survives exactly one
    # run and reverts without a word. Add new keys here as well as wherever
    # they are consumed.
    # ---------------------------------------------------------------------
    [ -n "${OPERATIONAL_CERT_VALIDITY:-}" ] && \
        echo "OPERATIONAL_CERT_VALIDITY=\"${OPERATIONAL_CERT_VALIDITY}\""
    [ -n "${FACTORY_HELPER_CERT_VALIDITY_DAYS:-}" ] && \
        echo "FACTORY_HELPER_CERT_VALIDITY_DAYS=\"${FACTORY_HELPER_CERT_VALIDITY_DAYS}\""
    # Written by setup-cloudbuild-triggers.sh. Losing it makes terraform.sh
    # skip the platform-health-check trigger and its schedule (terraform.sh:24).
    [ -n "${CLOUDBUILD_REPO_RESOURCE:-}" ] && \
        echo "CLOUDBUILD_REPO_RESOURCE=\"${CLOUDBUILD_REPO_RESOURCE}\""
    :
} > "$ENV_FILE"
log_text "" # For spacing