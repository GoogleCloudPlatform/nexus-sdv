#!/bin/bash
# ==============================================================================
# Nexus SDV Bootstrapping — Shared Authentication Library
#
# Sourced by all bootstrap and teardown scripts to avoid code duplication.
# ==============================================================================

# Authenticate with gcloud. Handles Cloud Shell stale-session recovery.
# Expects IS_CLOUD_SHELL to be set (defaults to false).
authenticate_with_gcloud() {
    log_info "Checking gcloud cli authentication"
    if ! gcloud auth print-access-token &>/dev/null; then
        log_info "${FAIL} gcloud (re)authentication required."

        if [ "${IS_CLOUD_SHELL:-false}" = true ]; then
            log_warn "Cloud Shell session credentials seem expired. Attempting auto-refresh..."
            if ! gcloud auth login --quiet; then
                log_text "${COLOR_RED}=========================================================${COLOR_NC}"
                log_text "${COLOR_RED} CRITICAL: Cloud Shell Session is stale / unresponsive ${COLOR_NC}"
                log_text "${COLOR_RED}=========================================================${COLOR_NC}"
                log_text "${COLOR_YELLOW}Please manually RESTART your Cloud Shell session:${COLOR_NC}"
                log_text "  1. Click the 'Three Dots' menu icon in the Cloud Shell toolbar."
                log_text "  2. Select 'Restart'"
                log_text "  3. Or simply refresh this browser tab."
                log_text "${COLOR_RED}Script aborted.${COLOR_NC}"
                exit 1
            fi
        else
            log_info "gcloud (re)authentication required."
            gcloud auth login
            log_info "gcloud (re)authentication required."
            gcloud auth application-default login
        fi
    else
        log_info "${CHECK} gcloud cliauthentication still valid."
    fi
}

# Authenticate with GitHub CLI and export GH_TOKEN.
# No-op if DEPLOY_MODE != "github".
authenticate_with_github() {
    if [ "${DEPLOY_MODE:-}" != "github" ]; then return; fi

    log_info "Checking GitHub cli authentication"
    if ! gh auth status &>/dev/null; then
        log_info "${FAIL} GitHub cli (re)authentication required."
        gh auth login --skip-ssh-key
    else
        USER_LOGIN=$(gh api user -q .login 2>/dev/null)
        log_info "${CHECK} GitHub cli authentication still valid."
    fi
    export GH_TOKEN=$(gh auth token)
}

check_authentication() {

    authenticate_with_gcloud

    authenticate_with_github

    log_info "${CHECK} Authentication checks passed."
}
