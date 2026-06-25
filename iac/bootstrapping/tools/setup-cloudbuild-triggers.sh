#!/bin/bash
# ==============================================================================
# Setup Cloud Build Triggers for Bootstrap & Teardown Pipelines
#
# Creates fully automated CodePipeline-style triggers for each environment:
#
#   bootstrap-<env>-auto   Branch push trigger: push to env/<env>   → bootstrap
#   teardown-<env>-auto    Branch push trigger: push to teardown/<env> → teardown
#   bootstrap-<env>        Manual console trigger (no form — one click)
#   teardown-<env>         Manual console trigger (no form — one click)
#
# Plus generic parameterised triggers for ad-hoc use:
#   bootstrap-platform     Manual, prompts for _BOOTSTRAP_ENV_GCS_PATH
#   teardown-platform      Manual, prompts for _BOOTSTRAP_ENV_GCS_PATH
#
# Usage:
#   bash iac/bootstrapping/tools/setup-cloudbuild-triggers.sh [env1] [env2] ...
#   bash iac/bootstrapping/tools/setup-cloudbuild-triggers.sh sandbox dev staging
#
# Defaults to 'sandbox' if no environment names are provided.
#
# Prerequisites:
#   1. gcloud authenticated with sufficient permissions
#   2. Cloud Build API enabled in the project
#   3. The GitHub repo connected to Cloud Build:
#      GCP Console → Cloud Build → Repositories → Connect Repository
#
# GitOps workflow after setup:
#   git checkout -b env/sandbox && git push origin env/sandbox     # bootstrap
#   git checkout -b teardown/sandbox && git push origin teardown/sandbox  # teardown
#
# .bootstrap_env files are stored in GCS (not in git). Upload them with:
#   gsutil cp iac/bootstrapping/.bootstrap_env \
#     gs://${GCP_PROJECT_ID}-bootstrap-envs/sandbox.bootstrap_env
# ==============================================================================

set -euo pipefail

GCLOUD=$(command -v gcloud) || { echo "gcloud not found in PATH" >&2; exit 1; }

COLOR_GREEN='\033[0;32m'
COLOR_BLUE='\033[0;34m'
COLOR_YELLOW='\033[1;33m'
COLOR_RED='\033[0;31m'
COLOR_NC='\033[0m'

log_info()    { echo -e "${COLOR_BLUE}[INFO]${COLOR_NC} $*"; }
log_warn()    { echo -e "${COLOR_YELLOW}[WARN]${COLOR_NC} $*" >&2; }
log_error()   { echo -e "${COLOR_RED}[ERROR]${COLOR_NC} $*" >&2; exit 1; }
log_ok()      { echo -e "${COLOR_GREEN}[OK]${COLOR_NC}   $*"; }
log_section() { echo -e "\n${COLOR_BLUE}=== $* ===${COLOR_NC}"; }

# ---------------------------------------------------------------------------
# Parse arguments — environment names
# ---------------------------------------------------------------------------
ENVIRONMENTS=("$@")
if [ ${#ENVIRONMENTS[@]} -eq 0 ]; then
    ENVIRONMENTS=("sandbox")
fi

# ---------------------------------------------------------------------------
# Load configuration
# ---------------------------------------------------------------------------
ENV_FILE="iac/bootstrapping/.bootstrap_env"
if [ -f "$ENV_FILE" ]; then
    log_info "Loading configuration from $ENV_FILE..."
    # shellcheck source=/dev/null
    source "$ENV_FILE"
fi

GCP_PROJECT_ID="${GCP_PROJECT_ID:-}"
GCP_REGION="${GCP_REGION:-europe-west3}"
GITHUB_REPO="${GITHUB_REPO:-}"

if [ -z "$GCP_PROJECT_ID" ]; then
    GCP_PROJECT_ID=$($GCLOUD config get-value project 2>/dev/null || echo "")
    [ -z "$GCP_PROJECT_ID" ] && log_error "GCP_PROJECT_ID not set. Source a .bootstrap_env or set a gcloud default project."
fi

if [ -z "$GITHUB_REPO" ]; then
    GITHUB_REPO=$(git config --get remote.origin.url 2>/dev/null \
        | sed 's/.*github.com[:/]\(.*\)\.git/\1/' || echo "")
    [ -z "$GITHUB_REPO" ] && log_error "GITHUB_REPO not set and could not be detected from git remote."
fi

GITHUB_REPO_NAME="${GITHUB_REPO##*/}"
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
BOOTSTRAP_ENVS_BUCKET="${GCP_PROJECT_ID}-bootstrap-envs"

# Triggers must specify a serviceAccount explicitly or the API returns
# INVALID_ARGUMENT without explanation (org policy enforcement in this org).
# Must be a user-managed SA or the Compute Engine default SA — Cloud Build
# rejects the legacy @cloudbuild service agent in this field.
GCP_PROJECT_NUMBER=$($GCLOUD projects describe "$GCP_PROJECT_ID" \
    --format="value(projectNumber)" 2>/dev/null || echo "")
[ -z "$GCP_PROJECT_NUMBER" ] && log_error "Could not determine project number for ${GCP_PROJECT_ID}."
CLOUDBUILD_SA="projects/${GCP_PROJECT_ID}/serviceAccounts/${GCP_PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

log_info "Project:        ${GCP_PROJECT_ID}"
log_info "Region:         ${GCP_REGION}"
log_info "GitHub repo:    ${GITHUB_REPO}"
log_info "Source branch:  ${CURRENT_BRANCH} (used for manual triggers)"
log_info "Envs bucket:    gs://${BOOTSTRAP_ENVS_BUCKET}"
log_info "Environments:   ${ENVIRONMENTS[*]}"
log_info "Build SA:       ${CLOUDBUILD_SA}"

# ---------------------------------------------------------------------------
# Check Cloud Build API
# ---------------------------------------------------------------------------
log_section "Checking prerequisites"

if ! $GCLOUD services list --enabled --filter="name:cloudbuild.googleapis.com" \
        --format="value(name)" --project="$GCP_PROJECT_ID" 2>/dev/null \
        | grep -q "cloudbuild"; then
    log_error "Cloud Build API not enabled. Run:\n  gcloud services enable cloudbuild.googleapis.com --project=${GCP_PROJECT_ID}"
fi
log_ok "Cloud Build API enabled"

# ---------------------------------------------------------------------------
# Ensure Compute Engine API is enabled and default SA exists
#
# Cloud Build triggers run as the Compute Engine default SA. In a new project
# the Compute API may not be enabled and the SA may not exist yet.
# ---------------------------------------------------------------------------
log_section "Checking Compute Engine API and default service account"

if ! $GCLOUD services list --enabled --filter="name:compute.googleapis.com" \
        --format="value(name)" --project="$GCP_PROJECT_ID" 2>/dev/null \
        | grep -q "compute"; then
    log_info "Enabling compute.googleapis.com..."
    $GCLOUD services enable compute.googleapis.com --project="$GCP_PROJECT_ID"
    log_ok "compute.googleapis.com enabled"
else
    log_ok "compute.googleapis.com already enabled"
fi

# The default SA is provisioned automatically when the API is enabled,
# but can take several seconds to appear in a new project.
COMPUTE_SA="${GCP_PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
log_info "Checking Compute Engine default SA (${COMPUTE_SA})..."
SA_WAIT=0
while ! $GCLOUD iam service-accounts describe "$COMPUTE_SA" \
        --project="$GCP_PROJECT_ID" &>/dev/null; do
    if [ "$SA_WAIT" -ge 60 ]; then
        log_error "Compute Engine default SA (${COMPUTE_SA}) was not provisioned after 60s."
    fi
    log_info "  Not yet provisioned — waiting (${SA_WAIT}s elapsed)..."
    sleep 5
    SA_WAIT=$((SA_WAIT + 5))
done

# Re-enable if it was explicitly disabled by an org policy.
if $GCLOUD iam service-accounts describe "$COMPUTE_SA" \
        --project="$GCP_PROJECT_ID" 2>/dev/null | grep -qi "disabled: true"; then
    log_info "  Default SA is disabled — enabling it..."
    $GCLOUD iam service-accounts enable "$COMPUTE_SA" --project="$GCP_PROJECT_ID"
    log_ok "  Default SA enabled"
fi
log_ok "Compute Engine default SA ready: ${COMPUTE_SA}"

# ---------------------------------------------------------------------------
# Pre-grant Compute Engine default SA with roles needed to bootstrap
#
# Cloud Build triggers use the Compute Engine default SA (the @cloudbuild
# service agent is rejected by the API). The bootstrap run executes Terraform
# against all project resources, so roles/owner is needed upfront.
# Terraform manages this binding going forward via compute_sa_owner in
# cloudbuild.tf, so it won't be lost on subsequent applies.
# ---------------------------------------------------------------------------
log_section "Granting Compute Engine default SA permissions"
log_info "Granting roles/owner to ${COMPUTE_SA}..."
$GCLOUD projects add-iam-policy-binding "$GCP_PROJECT_ID" \
    --member="serviceAccount:${COMPUTE_SA}" \
    --role="roles/owner" \
    --condition=None \
    --format="none" 2>/dev/null
log_ok "roles/owner granted to ${COMPUTE_SA}"

# ---------------------------------------------------------------------------
# Check GitHub repo connection
# ---------------------------------------------------------------------------
# List all connections, then search repositories within each for the repo name.
REPO_RESOURCE=""
# Capture the connection list into a variable and iterate with a for loop.
# (Avoids `done < <(...)` process substitution, which is unsupported when the
# script is run under POSIX sh, e.g. `sh setup-cloudbuild-triggers.sh` — macOS
# /bin/sh is bash in POSIX mode. Connection names are identifiers with no
# spaces, so word-splitting is safe, and the for loop runs in the current
# shell so REPO_RESOURCE/break persist.)
CONNECTIONS=$($GCLOUD builds connections list \
    --project="$GCP_PROJECT_ID" \
    --region="$GCP_REGION" \
    --format="value(name)" 2>/dev/null || true)
for CONNECTION_NAME in $CONNECTIONS; do
    MATCH=$($GCLOUD builds repositories list \
        --project="$GCP_PROJECT_ID" \
        --region="$GCP_REGION" \
        --connection="$CONNECTION_NAME" \
        --format="value(name)" 2>/dev/null \
        | grep -i "${GITHUB_REPO_NAME}" | head -1 || true)
    if [ -n "$MATCH" ]; then
        REPO_RESOURCE="projects/${GCP_PROJECT_ID}/locations/${GCP_REGION}/connections/${CONNECTION_NAME}/repositories/${MATCH}"
        break
    fi
done

if [ -z "$REPO_RESOURCE" ]; then
    echo ""
    log_warn "Repository '${GITHUB_REPO}' is not connected to Cloud Build (region: ${GCP_REGION})."
    log_warn "Connect it first, then re-run this script:"
    log_warn ""
    log_warn "  GCP Console → Cloud Build → Repositories → Connect Repository"
    log_warn "  Or: https://console.cloud.google.com/cloud-build/repositories?project=${GCP_PROJECT_ID}"
    echo ""
    exit 1
fi
log_ok "Repository connected: ${REPO_RESOURCE}"

# ---------------------------------------------------------------------------
# Create bootstrap-envs GCS bucket
# ---------------------------------------------------------------------------
log_section "Setting up GCS bucket for .bootstrap_env files"

if $GCLOUD storage buckets describe "gs://${BOOTSTRAP_ENVS_BUCKET}" \
        --project="$GCP_PROJECT_ID" &>/dev/null; then
    log_ok "Bucket already exists: gs://${BOOTSTRAP_ENVS_BUCKET}"
else
    log_info "Creating gs://${BOOTSTRAP_ENVS_BUCKET}..."
    $GCLOUD storage buckets create "gs://${BOOTSTRAP_ENVS_BUCKET}" \
        --location="$GCP_REGION" \
        --uniform-bucket-level-access \
        --project="$GCP_PROJECT_ID"
    log_ok "Bucket created."
fi

# ---------------------------------------------------------------------------
# Helper: upsert a Cloud Build trigger from an inline YAML definition
# ---------------------------------------------------------------------------
upsert_trigger() {
    local NAME="$1"
    local TRIGGER_YAML="$2"

    if $GCLOUD builds triggers describe "$NAME" \
            --project="$GCP_PROJECT_ID" \
            --region="$GCP_REGION" &>/dev/null; then
        log_info "  Updating trigger '${NAME}'..."
        echo "$TRIGGER_YAML" | $GCLOUD builds triggers import \
            --project="$GCP_PROJECT_ID" \
            --region="$GCP_REGION" \
            --source=/dev/stdin
    else
        log_info "  Creating trigger '${NAME}'..."
        echo "$TRIGGER_YAML" | $GCLOUD builds triggers import \
            --project="$GCP_PROJECT_ID" \
            --region="$GCP_REGION" \
            --source=/dev/stdin
    fi
    log_ok "  Trigger ready: ${NAME}"
}

# ---------------------------------------------------------------------------
# Per-environment triggers
# ---------------------------------------------------------------------------
for ENV_NAME in "${ENVIRONMENTS[@]}"; do
    log_section "Environment: ${ENV_NAME}"

    ENV_GCS_PATH="gs://${BOOTSTRAP_ENVS_BUCKET}/${ENV_NAME}.bootstrap_env"

    # --- bootstrap-<env>-auto: branch push trigger ---
    upsert_trigger "bootstrap-${ENV_NAME}-auto" "$(cat <<EOF
name: bootstrap-${ENV_NAME}-auto
description: "Auto-bootstrap ${ENV_NAME} — push to env/${ENV_NAME} to trigger"
tags:
  - bootstrap
  - ${ENV_NAME}
  - auto
filename: iac/cloudbuild/bootstrap-platform.yaml
serviceAccount: ${CLOUDBUILD_SA}
repositoryEventConfig:
  repository: ${REPO_RESOURCE}
  push:
    branch: ^env/${ENV_NAME}$
substitutions:
  _BOOTSTRAP_ENV_GCS_PATH: ${ENV_GCS_PATH}
EOF
)"

    # --- teardown-<env>-auto: branch push trigger ---
    upsert_trigger "teardown-${ENV_NAME}-auto" "$(cat <<EOF
name: teardown-${ENV_NAME}-auto
description: "Auto-teardown ${ENV_NAME} — push to teardown/${ENV_NAME} to trigger"
tags:
  - teardown
  - ${ENV_NAME}
  - auto
filename: iac/cloudbuild/teardown-platform.yaml
serviceAccount: ${CLOUDBUILD_SA}
repositoryEventConfig:
  repository: ${REPO_RESOURCE}
  push:
    branch: ^teardown/${ENV_NAME}$
substitutions:
  _BOOTSTRAP_ENV_GCS_PATH: ${ENV_GCS_PATH}
  _PRESERVE_CAS: "Y"
  _PRESERVE_DNS: "Y"
EOF
)"

    # --- bootstrap-<env>: manual console trigger ---
    upsert_trigger "bootstrap-${ENV_NAME}" "$(cat <<EOF
name: bootstrap-${ENV_NAME}
description: "Manual bootstrap ${ENV_NAME} — click Run Trigger in the console"
tags:
  - bootstrap
  - ${ENV_NAME}
  - manual
filename: iac/cloudbuild/bootstrap-platform.yaml
serviceAccount: ${CLOUDBUILD_SA}
sourceToBuild:
  repository: ${REPO_RESOURCE}
  ref: refs/heads/${CURRENT_BRANCH}
  repoType: GITHUB
substitutions:
  _BOOTSTRAP_ENV_GCS_PATH: ${ENV_GCS_PATH}
EOF
)"

    # --- teardown-<env>: manual console trigger ---
    upsert_trigger "teardown-${ENV_NAME}" "$(cat <<EOF
name: teardown-${ENV_NAME}
description: "Manual teardown ${ENV_NAME} — click Run Trigger in the console"
tags:
  - teardown
  - ${ENV_NAME}
  - manual
filename: iac/cloudbuild/teardown-platform.yaml
serviceAccount: ${CLOUDBUILD_SA}
sourceToBuild:
  repository: ${REPO_RESOURCE}
  ref: refs/heads/${CURRENT_BRANCH}
  repoType: GITHUB
substitutions:
  _BOOTSTRAP_ENV_GCS_PATH: ${ENV_GCS_PATH}
  _PRESERVE_CAS: "Y"
  _PRESERVE_DNS: "Y"
EOF
)"

done

# ---------------------------------------------------------------------------
# Generic parameterised triggers (once, env-agnostic)
# ---------------------------------------------------------------------------
log_section "Generic parameterised triggers"

upsert_trigger "bootstrap-platform" "$(cat <<EOF
name: bootstrap-platform
description: "Bootstrap any environment"
tags:
  - bootstrap
  - generic
filename: iac/cloudbuild/bootstrap-platform.yaml
serviceAccount: ${CLOUDBUILD_SA}
sourceToBuild:
  repository: ${REPO_RESOURCE}
  ref: refs/heads/${CURRENT_BRANCH}
  repoType: GITHUB
substitutions:
  _BOOTSTRAP_ENV_GCS_PATH: ""
  _SKIP_TERRAFORM: "false"
EOF
)"

upsert_trigger "teardown-platform" "$(cat <<EOF
name: teardown-platform
description: "Teardown any environment "
tags:
  - teardown
  - generic
filename: iac/cloudbuild/teardown-platform.yaml
serviceAccount: ${CLOUDBUILD_SA}
sourceToBuild:
  repository: ${REPO_RESOURCE}
  ref: refs/heads/${CURRENT_BRANCH}
  repoType: GITHUB
substitutions:
  _BOOTSTRAP_ENV_GCS_PATH: ""
  _PRESERVE_CAS: "Y"
  _PRESERVE_DNS: "Y"
EOF
)"

upsert_trigger "test-environments" "$(cat <<EOF
name: test-environments
description: "Bootstrap then teardown every env in a GCS directory"
tags:
  - test
  - generic
filename: iac/cloudbuild/test-environments.yaml
serviceAccount: ${CLOUDBUILD_SA}
sourceToBuild:
  repository: ${REPO_RESOURCE}
  ref: refs/heads/${CURRENT_BRANCH}
  repoType: GITHUB
substitutions:
  _BOOTSTRAP_ENVS_DIR: ""
  _PRESERVE_CAS: "Y"
  _PRESERVE_DNS: "Y"
EOF
)"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
CONSOLE_URL="https://console.cloud.google.com/cloud-build/triggers?project=${GCP_PROJECT_ID}"

echo ""
log_ok "=================================================================="
log_ok "  All Cloud Build triggers are ready!"
log_ok "=================================================================="
echo ""
log_info "View triggers in the console:"
log_info "  ${CONSOLE_URL}"
echo ""
log_info "Next — upload a .bootstrap_env file for each environment:"
for ENV_NAME in "${ENVIRONMENTS[@]}"; do
    log_info "  gsutil cp iac/bootstrapping/.bootstrap_env \\"
    log_info "    gs://${BOOTSTRAP_ENVS_BUCKET}/${ENV_NAME}.bootstrap_env"
done
echo ""
log_info "GitOps workflow:"
for ENV_NAME in "${ENVIRONMENTS[@]}"; do
    log_info "  Bootstrap ${ENV_NAME}:  git checkout -b env/${ENV_NAME} && git push origin env/${ENV_NAME}"
    log_info "  Teardown  ${ENV_NAME}:  git checkout -b teardown/${ENV_NAME} && git push origin teardown/${ENV_NAME}"
done
echo ""
log_info "Or use the manual triggers in the console — no form to fill in:"
for ENV_NAME in "${ENVIRONMENTS[@]}"; do
    log_info "  bootstrap-${ENV_NAME}  /  teardown-${ENV_NAME}"
done
