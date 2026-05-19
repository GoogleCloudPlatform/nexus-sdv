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
        # Auto-approve mode: use defaults (keep all)
        PRESERVE_SERVER_CA=Y
        PRESERVE_FACTORY_CA=Y
        PRESERVE_REG_CA=Y
        PRESERVE_DNS=Y
        log_warn "Using defaults: All resources will be preserved"
        log_info ""
    fi
}

delete_gke_cluster() {
      GKE_CLUSTER_NAME="${ENV}-gke"
      add_delay_if_run_in_cloudshell
      if gcloud container clusters describe "$GKE_CLUSTER_NAME" --region "$GCP_REGION" --project "$GCP_PROJECT_ID" &> /dev/null; then
          log_info "GKE Cluster '$GKE_CLUSTER_NAME' found."
          log_info "Attempting to delete cluster via GCloud API to terminate workloads..."

          if ! gcloud container clusters delete "$GKE_CLUSTER_NAME" --region "$GCP_REGION" --project "$GCP_PROJECT_ID" --quiet; then
              log_error "WARNING: Could not trigger cluster deletion."
              log_info "This may cause issues with Terraform destroy. Consider deleting manually."
          else
              log_info "Cluster deletion completed successfully."
          fi
      else
          log_info "GKE Cluster '$GKE_CLUSTER_NAME' not found. Assuming it's already gone."
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


main() {
    log_text "=================================================================="
    log_text "===                  Nexus SDV Platform Teardown               ==="
    log_text "=================================================================="
    parse_arguments
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
