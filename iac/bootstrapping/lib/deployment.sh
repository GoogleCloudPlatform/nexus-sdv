#!/bin/bash
# ==============================================================================
# Nexus SDV Bootstrapping — Shared Deployment Library
#
# Sourced by all bootstrap and teardown scripts to avoid code duplication.
# ==============================================================================

detect_deployment_strategy() {
  DEPLOY_MODE=$(gcloud secrets versions access latest --secret="DEPLOY_MODE" --project="$GCP_PROJECT_ID")
  log_info  "${CHECK} Detected DEPLOY_MODE from Secret Manager: $DEPLOY_MODE${COLOR_NC}"
}

trigger_github_deployment() {
    # --- Platform deployment via GitHub Actions ---
    WORKFLOW_NAME="bootstrap-platform.yml"

    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
    WORKFLOW_REF="$CURRENT_BRANCH"
    log_info "Starting Deployment with GitHub actions..."

    log_info "Checking for previous runs on branch '$WORKFLOW_REF'..."
    OLD_RUN_ID=$(gh run list --workflow="$WORKFLOW_NAME" --repo="$GITHUB_REPO" --branch "$WORKFLOW_REF" --event workflow_dispatch --limit 1 --json databaseId --jq '.[0].databaseId')

    if [ -z "$OLD_RUN_ID" ] || [ "$OLD_RUN_ID" == "null" ]; then
        OLD_RUN_ID="0"
    fi

    log_info "Triggering workflow on branch: '$WORKFLOW_REF' (Previous Run ID: $OLD_RUN_ID)"

    if gh workflow run "$WORKFLOW_NAME" --repo="$GITHUB_REPO" --ref "$WORKFLOW_REF" -f environment="$ENV" -f pki_strategy="$PKI_STRATEGY" -f base_domain="$BASE_DOMAIN" -f arch="$ARCH"; then
        log_info "Workflow triggered. Waiting for new run to appear..."

        RUN_ID=""
        for _ in {1..20}; do
            sleep 5

            LATEST_RUN_JSON=$(gh run list --workflow="$WORKFLOW_NAME" --repo="$GITHUB_REPO" --branch "$WORKFLOW_REF" --event workflow_dispatch --limit 1 --json databaseId,status --jq '.[0]')

            if [ -z "$LATEST_RUN_JSON" ] || [ "$LATEST_RUN_JSON" == "null" ]; then
                continue
            fi

            FOUND_ID=$(echo "$LATEST_RUN_JSON" | jq -r '.databaseId')

            if [ "$FOUND_ID" != "$OLD_RUN_ID" ]; then
                RUN_ID="$FOUND_ID"
                break
            else
                # echo -ne "Waiting for new run... (Current latest: $FOUND_ID)\r" # Removed as per instruction.
                : # No-op for removed echo
            fi
        done
        log_info "" # For spacing

        if [ -z "$RUN_ID" ]; then
            log_error "Could not find the new Run ID after 100 seconds. Check GitHub Actions manually."
        fi

        log_info "Monitoring New Run ID: $RUN_ID"

        if ! gh run watch "$RUN_ID" --repo="$GITHUB_REPO" --exit-status; then
            log_warn "Connection lost locally. Checking status on GitHub..."
            FINAL_STATUS=$(gh run view "$RUN_ID" --repo="$GITHUB_REPO" --json conclusion --jq '.conclusion')

            if [ "$FINAL_STATUS" == "success" ]; then
                  log_info "GitHub Actions deployment pipeline successfully completed!"
            else
                  log_error "Pipeline failed with status: '$FINAL_STATUS'."
            fi
        else
            log_info "GitHub Actions deployment pipeline successfully completed!"
        fi
    else
        log_error "Could not start the GitHub Actions workflow."
    fi
}

trigger_cloudbuild_deployment() {
    if [ "$DEPLOY_MODE" != "cloudbuild" ]; then
        return
    fi
    # Ensure Cloud Build API is enabled
    gcloud services enable cloudbuild.googleapis.com --project="$GCP_PROJECT_ID" >/dev/null 2>&1

    log_info "Submitting build to Cloud Build..."

    # We pass necessary context variables as substitutions.
    # Cloud Build will fetch sensitive data (passwords) directly from Secret Manager.

    # Calculate Pool Variables for Substitutions
    if [ "$PKI_STRATEGY" == "remote" ]; then
        POOL_SERVER="${EXISTING_SERVER_CA_POOL:-$CREATED_SERVER_CA_POOL}"
        POOL_FACTORY="${EXISTING_FACTORY_CA_POOL:-$CREATED_FACTORY_CA_POOL}"
    else
        POOL_SERVER=""
        POOL_FACTORY=""
    fi

    # Submit parent orchestration build — waits for all child builds to complete
    # and correctly propagates failures. Individual child builds can still be
    # run independently by calling their YAML files directly.
    gcloud builds submit . \
        --config="iac/cloudbuild/deploy-all.yaml" \
        --project="$GCP_PROJECT_ID" \
        --region="$GCP_REGION" \
        --substitutions=^::^_ARCH=${ARCH}::_PKI_STRATEGY=${PKI_STRATEGY}::_BASE_DOMAIN=${BASE_DOMAIN:-}::_REGION=${GCP_REGION}::_COMMIT_SHA=$(git rev-parse HEAD)

    if [ $? -eq 0 ]; then
        log_info "All Cloud Build deployments completed successfully!"
    else
        log_error "Cloud Build deployment failed. Check the Cloud Build logs for details."
        exit 1
    fi
}

# --- 13: Trigger and monitor the deployment pipeline
trigger_deployment_pipeline() {
  if [ "$DEPLOY_MODE" == "github" ]; then
      trigger_github_deployment
  elif [ "$DEPLOY_MODE" == "cloudbuild" ]; then
      trigger_cloudbuild_deployment
  else
      log_warn "Unknown DEPLOY_MODE '$DEPLOY_MODE'. Skipping deployment trigger."
  fi
}
