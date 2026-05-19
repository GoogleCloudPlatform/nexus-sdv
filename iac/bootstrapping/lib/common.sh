#!/bin/bash
# ==============================================================================
# Nexus SDV Bootstrapping — Shared Utility Library
#
# Sourced by all bootstrap and teardown scripts to avoid code duplication.
# ==============================================================================

# ==============================================================================
# General functions
# ==============================================================================

# --- Color constants ---
COLOR_GREEN='\033[0;32m'
COLOR_BLUE='\033[0;34m'
COLOR_YELLOW='\033[1;33m'
COLOR_RED='\033[0;31m'
COLOR_NC='\033[0m'

CHECK="${COLOR_GREEN}✓${COLOR_NC}"
NOTSET="${COLOR_GREEN}-${COLOR_NC}"
FOLLOWING="${COLOR_GREEN}→${COLOR_NC}"
FAIL="${COLOR_RED}✗${COLOR_NC}"


CLOUD_SHELL_JOB_DELAY=120

# --- Portable sed in-place editing (works on both macOS and Linux) ---
sed_inplace() {
    if sed --version >/dev/null 2>&1; then
        sed -i "$@"
    else
        sed -i '' "$@"
    fi
}

# --- Logging functions ---
log_info() {
    echo -e "${COLOR_BLUE}[INFO]${COLOR_NC} $*"
}
log_warn() {
    echo -e  "${COLOR_YELLOW}[WARN]${COLOR_NC} $*" >&2
}
log_error() {
    echo -e  "${COLOR_RED}[ERROR]${COLOR_NC} $*" >&2
    exit 1
}
log_text() {
    echo -e "$*"
}

log_section_title() {
       log_text ""
       log_text "******************************************************************"
       log_text "$*"
       log_text "******************************************************************"
}

log_subsection_title() {
       log_text ""
       log_text "$*"
       log_text "------------------------------------------------------------------"
}

log_divider() {
       log_text ""
       log_text "------------------------------------------------------------------"
       log_text ""
}


# Parse arguments
parse_arguments() {
while [[ $# -gt 0 ]]; do
    case $1 in
        -y|--yes)
            AUTO_APPROVE=true
            log_warn "Auto-approve mode: All prompts will use default values (delete resources)"
            log_info ""
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done
}

# ==============================================================================
# Cloud Shell Detection
# ==============================================================================

# Detect if running in Google Cloud Shell. Sets IS_CLOUD_SHELL=true/false.
check_if_running_in_cloud_shell() {
    #The bootstrapping script is able to run both on the local machine and the GCP Cloud Shell.
    IS_CLOUD_SHELL=false

    if [[ -n "${DEVSHELL_PROJECT_ID:-}" ]] || [[ -n "${CLOUD_SHELL:-}" ]]; then
        IS_CLOUD_SHELL=true
        log_info "Deployment is running in CloudShell"
    else
        log_info "Deployment is not running in CloudShell"
    fi

}

# ==============================================================================
# Prerequisites
# ==============================================================================

# Check that all specified tools are installed. Exits on failure.
# Usage: check_tools "gcloud" "terraform" "jq"
check_tools() {
    log_info "Checking if required tools are installed..."
    local missing=()
    for tool in "$@"; do
        if ! command -v "$tool" &> /dev/null; then
            missing+=("$tool")
            log_info "$tool: ${FAIL}"
        else
            log_info "$tool: ${CHECK}"
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "The following necessary tools were not found:"
        for tool in "${missing[@]}"; do
            log_error "  - $tool"
        done
        log_error "Please install them and run the script again."
        exit 1
    fi
}

install_cloud_shell_tools(){
     # Cloud Shell: install/update Terraform
    if [ "$IS_CLOUD_SHELL" != true ]; then
        # Bootstrapping is not running in CloudBuild, skipping this step
        return;
    fi
    log_info "Cloud Shell detected. Checking and updating Terraform..."
    log_info "Adding HashiCorp repository and updating Terraform..."

    sudo apt-get update && sudo apt-get install -y gnupg software-properties-common

    wget -O- https://apt.releases.hashicorp.com/gpg | \
        gpg --dearmor | \
        sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg > /dev/null

    log_text "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
        https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
        sudo tee /etc/apt/sources.list.d/hashicorp.list

    sudo apt-get update
    sudo apt-get install -y terraform

    log_info "Terraform updated to version: $(terraform version | head -n1)"
    sudo apt-get install -y protobuf-compiler libprotobuf-dev
}

check_prerequisites() {
    local tools=("gcloud" "terraform" "openssl" "nk" "jq" "sed")
    if [ "$DEPLOY_MODE" == "github" ]; then
        tools+=("gh")
    fi
    check_tools "${tools[@]}"
}

add_delay_if_run_in_cloudshell(){
  #If run in Cloudshell the CloudShell build might fail if run too quickly in succession.
  #because CloudShell is a shared service. So in this case we add a delay to give CloudShell
  #the time to recover.
  if [ "$IS_CLOUD_SHELL" == "true" ]; then
    sleep $CLOUD_SHELL_JOB_DELAY
  fi
}

