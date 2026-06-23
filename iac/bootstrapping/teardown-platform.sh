#!/bin/bash
# ==============================================================================
# Nexus SDV Teardown Script v1.0
#
# This script performs a complete, automated teardown of the Nexus SDV GCP Platform
#
# Author: Team Sky
# Version: 1.0
# ==============================================================================

# Terminates the script immediately if a command fails or a variable is not set
set -euo pipefail
i=0
# Load shared utility libraries
source "$(dirname "$0")/lib/common.sh"
source "$(dirname "$0")/lib/authenticate.sh"
source "$(dirname "$0")/lib/config.sh"
source "$(dirname "$0")/lib/terraform.sh"
source "$(dirname "$0")/lib/secrets.sh"
source "$(dirname "$0")/lib/deployment.sh"

# Override check_prerequisites: teardown does not use 'nk' (NATS key generation
# is only needed during bootstrap), so we exclude it from the required tool list.
check_prerequisites() {
    local tools=("gcloud" "terraform" "openssl" "jq" "sed")
    if [ "$DEPLOY_MODE" == "github" ]; then
        tools+=("gh")
    fi
    check_tools "${tools[@]}"
}

# --- Parse command line arguments ---
AUTO_APPROVE=false

confirm_resource_preservation() {
    # --- Ask about preserving reusable resources ---
    if [ "$AUTO_APPROVE" = false ] && [ "$PKI_STRATEGY" == "remote" ]; then
        log_text "You can preserve specific resources for reuse when bootstrapping again."
        log_text ""

        # Determine actual CA pool names from environment
        SERVER_CA="${EXISTING_SERVER_CA_POOL:-server-ca-pool}"
        FACTORY_CA="${EXISTING_FACTORY_CA_POOL:-factory-ca-pool}"
        REG_CA="${EXISTING_REG_CA_POOL:-registration-ca-pool}"

        # Ask about Server CA Pool
        read -rp "Preserve Server CA Pool ('$SERVER_CA')? (y/N): " PRESERVE_SERVER_CA
        PRESERVE_SERVER_CA=${PRESERVE_SERVER_CA:-N}
        if [[ "$PRESERVE_SERVER_CA" =~ ^[Yy]$ ]]; then
            log_info "  ${CHECK} Server CA will be preserved"
        else
            log_warn "  ${FOLLOWING} Server CA will be deleted"
        fi

        # Ask about Factory CA Pool
        read -rp "Preserve Factory CA Pool ('$FACTORY_CA')? (y/N): " PRESERVE_FACTORY_CA
        PRESERVE_FACTORY_CA=${PRESERVE_FACTORY_CA:-N}
        if [[ "$PRESERVE_FACTORY_CA" =~ ^[Yy]$ ]]; then
            log_info "  ${CHECK} Factory CA will be preserved"
        else
            log_warn "  ${FOLLOWING} Factory CA will be deleted"
        fi

        # Ask about Registration CA Pool
        read -rp "Preserve Registration CA Pool ('$REG_CA')? (y/N): " PRESERVE_REG_CA
        PRESERVE_REG_CA=${PRESERVE_REG_CA:-N}
        if [[ "$PRESERVE_REG_CA" =~ ^[Yy]$ ]]; then
            log_info "  ${CHECK} Registration CA will be preserved"
        else
            log_warn "  ${FOLLOWING} Registration CA will be deleted"
        fi

        # Ask about CloudDNS Zone
        read -rp "Preserve CloudDNS Zone? (y/N): " PRESERVE_DNS
        PRESERVE_DNS=${PRESERVE_DNS:-N}
        if [[ "$PRESERVE_DNS" =~ ^[Yy]$ ]]; then
            log_info "  ${CHECK} DNS Zone will be preserved"
        else
            log_warn "  ${FOLLOWING} DNS Zone will be deleted"
        fi
    else
        # Auto-approve mode: respect env var overrides, default to preserve (Y)
        PRESERVE_SERVER_CA=${PRESERVE_SERVER_CA:-Y}
        PRESERVE_FACTORY_CA=${PRESERVE_FACTORY_CA:-Y}
        PRESERVE_REG_CA=${PRESERVE_REG_CA:-Y}
        PRESERVE_DNS=${PRESERVE_DNS:-Y}
        log_info "Resource preservation (override via env vars):"
        log_info "  PRESERVE_SERVER_CA=${PRESERVE_SERVER_CA}"
        log_info "  PRESERVE_FACTORY_CA=${PRESERVE_FACTORY_CA}"
        log_info "  PRESERVE_REG_CA=${PRESERVE_REG_CA}"
        log_info "  PRESERVE_DNS=${PRESERVE_DNS}"
    fi
}

delete_gke_cluster() {
      GKE_CLUSTER_NAME="${ENV}-gke"
      add_delay_if_run_in_cloudshell
      if ! gcloud container clusters describe "$GKE_CLUSTER_NAME" --region "$GCP_REGION" --project "$GCP_PROJECT_ID" &> /dev/null; then
          log_info "GKE Cluster '$GKE_CLUSTER_NAME' not found. Assuming it's already gone."
          echo ""
          return 0
      fi

      log_info "GKE Cluster '$GKE_CLUSTER_NAME' found."

      # Wait for any in-progress operations (e.g. a previous delete attempt or
      # node-pool scaling) before issuing a new delete request. GKE returns 400
      # if a new operation is submitted while one is already running.
      local MAX_WAIT=300 WAITED=0
      while true; do
          PENDING_OPS=$(gcloud container operations list \
              --region "$GCP_REGION" \
              --project "$GCP_PROJECT_ID" \
              --filter="status=RUNNING AND targetLink~$GKE_CLUSTER_NAME" \
              --format="value(name)" 2>/dev/null || true)
          [ -z "$PENDING_OPS" ] && break
          if [ "$WAITED" -ge "$MAX_WAIT" ]; then
              log_warn "Timed out waiting for in-progress operations on '$GKE_CLUSTER_NAME'. Proceeding anyway..."
              break
          fi
          log_info "  Waiting for in-progress operation(s) on '$GKE_CLUSTER_NAME' to complete..."
          sleep 15
          WAITED=$((WAITED + 15))
      done

      log_info "Attempting to delete cluster via GCloud API to terminate workloads..."
      if ! gcloud container clusters delete "$GKE_CLUSTER_NAME" --region "$GCP_REGION" --project "$GCP_PROJECT_ID" --quiet; then
          log_warn "WARNING: Could not trigger cluster deletion — Terraform destroy will attempt it."
      else
          log_info "Cluster deletion completed successfully."
      fi
      echo ""
}

cleanup_ca_pools() {
      # Build list of pools to delete based on user choices
      CA_POOLS_TO_DELETE=()

      if [[ ! "$PRESERVE_SERVER_CA" =~ ^[Yy]$ ]]; then
          CA_POOLS_TO_DELETE+=("${EXISTING_SERVER_CA_POOL:-server-ca-pool}")
      fi

      if [[ ! "$PRESERVE_FACTORY_CA" =~ ^[Yy]$ ]]; then
          CA_POOLS_TO_DELETE+=("${EXISTING_FACTORY_CA_POOL:-factory-ca-pool}")
      fi

      if [[ ! "$PRESERVE_REG_CA" =~ ^[Yy]$ ]]; then
          CA_POOLS_TO_DELETE+=("${EXISTING_REG_CA_POOL:-registration-ca-pool}")
      fi

      # Remove duplicates from array (in case multiple pools share the same name)
      if [ ${#CA_POOLS_TO_DELETE[@]} -gt 0 ]; then
          UNIQUE_CA_POOLS=($(printf "%s\n" "${CA_POOLS_TO_DELETE[@]}" | sort -u))
      else
          UNIQUE_CA_POOLS=()
      fi

      if [ ${#UNIQUE_CA_POOLS[@]} -eq 0 ]; then
          log_info "All CA Pools preserved - skipping cleanup"
          log_info ""
      else
          log_info "Deleting ${#UNIQUE_CA_POOLS[@]} CA pool(s)..."

          for pool in "${UNIQUE_CA_POOLS[@]}"; do
              force_delete_ca_pool "$pool"
          done

          log_info "CA Pool cleanup complete - selected pools force deleted."
          echo ""
      fi
}

cleanup_dns_records() {
      add_delay_if_run_in_cloudshell
      if [[ "$PRESERVE_DNS" =~ ^[Yy]$  ]]; then
          log_info "Skipping DNS zone cleanup (preserved for reuse)"
          log_info ""
      else
          log_warn "Cleaning up DNS records..."

          # Try to find the managed DNS zone
          DNS_ZONE_NAME=$(echo -e "$BASE_DOMAIN" | tr '.' '-')

          if gcloud dns managed-zones describe "$DNS_ZONE_NAME" --project="$GCP_PROJECT_ID" &>/dev/null; then
          log_info "Found DNS zone '$DNS_ZONE_NAME'. Deleting records..."

          # Get all non-essential record sets (exclude NS and SOA for apex)
          RECORD_SETS=$(gcloud dns record-sets list \
              --zone="$DNS_ZONE_NAME" \
              --project="$GCP_PROJECT_ID" \
              --format="json" | jq -r '.[] | select(.type != "NS" and .type != "SOA") | .name + " " + .type')

          if [ -n "$RECORD_SETS" ]; then
              log_info "$RECORD_SETS" | while read -r name type; do
                  if [ -n "$name" ] && [ -n "$type" ]; then
                      log_info "  - Deleting record: $name ($type)"
                      # Delete the record
                      gcloud dns record-sets delete "$name" \
                          --type="$type" \
                          --zone="$DNS_ZONE_NAME" \
                          --project="$GCP_PROJECT_ID" \
                          --quiet 2>/dev/null || true
                  fi
              done
              log_info "DNS records deleted."
          else
              log_info "No additional DNS records to delete."
          fi
          else
              log_info "DNS zone not found or not using remote PKI. Skipping DNS cleanup."
          fi

          echo ""
      fi
}

cleanup_database() {
    # --- Clean up database dependencies ---
    SQL_INSTANCE="cloud-sql-${ENV}"
    add_delay_if_run_in_cloudshell
    if gcloud sql instances describe "$SQL_INSTANCE" --project="$GCP_PROJECT_ID" &>/dev/null; then
        log_info "Found Cloud SQL instance '$SQL_INSTANCE'."
        log_info "Dropping keycloak database to clean up dependencies..."

        # Drop the database instead of just the user
        gcloud sql databases delete "keycloak" \
            --instance="$SQL_INSTANCE" \
            --project="$GCP_PROJECT_ID" \
            --quiet 2>/dev/null || log_info "Database already deleted or doesn't exist."

        log_info "Database cleanup complete."
    else
        log_info "Cloud SQL instance not found. Skipping database cleanup."
    fi

    echo ""
}

force_delete_ca_pool() {
    local pool="$1"
    echo "Checking CA pool '$pool'..."

    # Check if pool exists
    if gcloud privateca pools describe "$pool" --location="$GCP_REGION" --project="$GCP_PROJECT_ID" &>/dev/null; then
        echo "Found CA pool '$pool'. Checking for certificates..."

        # List all certificates in the pool
        CERTS=$(gcloud privateca certificates list \
            --issuer-pool="$pool" \
            --issuer-location="$GCP_REGION" \
            --project="$GCP_PROJECT_ID" \
            --format="value(name)" 2>/dev/null || echo "")

        if [ -n "$CERTS" ]; then
            echo "Deleting certificates from pool '$pool'..."
            for cert in $CERTS; do
                echo "  - Deleting certificate: $cert"
                gcloud privateca certificates delete "$cert" \
                    --issuer-pool="$pool" \
                    --issuer-location="$GCP_REGION" \
                    --project="$GCP_PROJECT_ID" \
                    --quiet || true
            done
        else
            echo "No certificates found in pool '$pool'."
        fi

        # Now delete the CA itself
        echo "Checking for CAs in pool '$pool'..."
        CAS=$(gcloud privateca roots list \
            --pool="$pool" \
            --location="$GCP_REGION" \
            --project="$GCP_PROJECT_ID" \
            --format="value(name)" 2>/dev/null || echo "")

        if [ -n "$CAS" ]; then
            echo "Deleting CAs from pool '$pool'..."
            for ca in $CAS; do
                # Extract just the CA ID from the full resource name
                CA_ID=$(basename "$ca")
                echo "  - Disabling CA: $CA_ID"
                gcloud privateca roots disable "$CA_ID" \
                    --pool="$pool" \
                    --location="$GCP_REGION" \
                    --project="$GCP_PROJECT_ID" \
                    --quiet 2>&1 || echo "    (already disabled or error)"

                echo "  - Force deleting CA: $CA_ID"
                if gcloud privateca roots delete "$CA_ID" \
                    --pool="$pool" \
                    --location="$GCP_REGION" \
                    --project="$GCP_PROJECT_ID" \
                    --skip-grace-period \
                    --ignore-active-certificates \
                    --quiet 2>&1; then
                    echo "    ✓ CA deleted successfully"
                else
                    echo "    ✗ CA deletion failed - may need manual cleanup"
                fi
            done

            # Wait longer for CA deletion to fully process
            echo "  - Waiting 30 seconds for CA deletion to fully process..."
            sleep 30
        else
            echo "No CAs found in pool '$pool'."
        fi

        # Now force delete the pool itself
        echo "Force deleting CA pool '$pool'..."
        if gcloud privateca pools delete "$pool" \
            --location="$GCP_REGION" \
            --project="$GCP_PROJECT_ID" \
            --quiet 2>&1; then
            echo "  ✓ Pool '$pool' deleted successfully"
        else
            echo "  ✗ Pool '$pool' deletion failed - may already be deleted or still processing"
            echo "    Attempting to list remaining resources in pool..."
            gcloud privateca roots list --pool="$pool" --location="$GCP_REGION" --project="$GCP_PROJECT_ID" 2>&1 || true
        fi
    else
        echo "CA pool '$pool' not found. Skipping."
    fi
}

main() {
    log_text "=================================================================="
    log_text "===                  Nexus SDV Platform Teardown               ==="
    log_text "=================================================================="
    parse_arguments "$@"
    load_bootstrap_env
    # Step 0: Environment Detection
    (( ++i ))
    log_section_title "Step ${i}: Environment Detection"
    check_if_running_in_cloud_shell
    install_cloud_shell_tools
    # Step 1: Detect deployment strategy (CloudBuild or Github)
    (( ++i ))
    log_section_title "Step ${i}: Detect deployment strategy (CloudBuild or Github)"
    detect_deployment_strategy
    # Step 2: Check prerequisites
    (( ++i ))
    log_section_title "Step ${i}: Check prerequisites"
    check_prerequisites
    # Step 3: Authenticate to platform
    (( ++i ))
    log_section_title "Step ${i}: Authenticate to platform"
    check_authentication
    # Step 4: Get user inputs for project configuration
    (( ++i ))
    log_section_title "Step ${i}: Get user inputs for project configuration"
    load_config
    # Step 5: Check preserving reusable resource
    (( ++i ))
    log_section_title "Step ${i}: Check preserving reusable resource"
    confirm_resource_preservation
    # Step 6: Force deleting GKE cluster to free up database connections
    (( ++i ))
    log_section_title "Step ${i}: Force deleting GKE cluster to free up database connections"
    delete_gke_cluster
    # Step 7: Cleaning up CA Pool certificates
    (( ++i ))
    log_section_title "Step ${i}: Cleaning up CA Pool certificates"
    cleanup_ca_pools
    # Step 8: Cleaning up DNS records
    (( ++i ))
    log_section_title "Step ${i}: Cleaning up DNS records"
    cleanup_dns_records
    # Step 9: Cleaning up database dependencies
    (( ++i ))
    log_section_title "Step ${i}: Cleaning up database dependencies"
    cleanup_database
    # Step 10: Running Terraform destroy
    (( ++i ))
    log_section_title "Step ${i}: Running Terraform destroy"
    run_terraform_destroy
    # Step 11: Get user inputs for project configuration
    (( ++i ))
    log_section_title "Step ${i}: Deleting GCS tfstate-bucket"
    delete_tfstate_bucket
    # Step 12: Cleaning up non-required GitHub environment variables
    if [ "$DEPLOY_MODE" == "github" ]; then
      (( ++i ))
      log_section_title "Step ${i}: Cleaning up non-required GitHub environment variables"
      cleanup_github_variables
    fi
    # Step 13: Delete secrets from Secret Manager
    (( ++i ))
    log_section_title "Step ${i}: Delete secrets from Secret Manager"
    delete_gcp_secrets
    # Step 14: Cleaning up local files
    (( ++i ))
    log_section_title "Step ${i}: Cleaning up local files"
    cleanup_local_files


    log_info "=================================================================="
    log_info "  🎉 Nexus SDV platform teardown successfully completed! 🎉  "
    log_info "=================================================================="
    log_info "Your Google Cloud project environment is now empty again."
    log_info "Local files have been cleaned up."



}

main "$@"
