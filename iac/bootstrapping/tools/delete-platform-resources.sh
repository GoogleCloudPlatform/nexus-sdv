#!/bin/bash

# ==============================================================================
# Delete Core Platform Resources
#
# Deletes the following resources from the GCP project:
#   1. GKE cluster         (<ENV>-gke)
#   2. BigTable instance   (bigtable-production-storage)
#   3. DNS record sets     (all non-SOA/NS records in the managed zone)
#   4. Cloud NAT           (nat)
#   5. Cloud Router        (router)
#   6. VPC + dependencies  (<ENV>-vpc: firewall rules, routes, subnet)
#   7. All Secret Manager secrets (except those containing 'github-oauthtoken')
#
# Useful for clearing out the main platform resources without running a full
# Terraform destroy — e.g. when the Terraform state is lost or corrupted.
#
# Usage:
#   bash iac/bootstrapping/tools/delete-platform-resources.sh
#   bash iac/bootstrapping/tools/delete-platform-resources.sh <PROJECT_ID>
#
# Project, region and environment are read from iac/bootstrapping/.bootstrap_env
# if present, then from gcloud config, then from the optional argument.
# ==============================================================================

set -euo pipefail

# Colors
COLOR_RED='\033[0;31m'
COLOR_YELLOW='\033[1;33m'
COLOR_GREEN='\033[0;32m'
COLOR_BLUE='\033[0;34m'
COLOR_NC='\033[0m'

log_info()  { echo -e "${COLOR_BLUE}[INFO]${COLOR_NC} $*"; }
log_warn()  { echo -e "${COLOR_YELLOW}[WARN]${COLOR_NC} $*"; }
log_ok()    { echo -e "${COLOR_GREEN}[ OK ]${COLOR_NC} $*"; }
log_error() { echo -e "${COLOR_RED}[ERR ]${COLOR_NC} $*"; }

# ---------------------------------------------------------------------------
# Resolve project / region / environment
# ---------------------------------------------------------------------------
if [ -f "iac/bootstrapping/.bootstrap_env" ]; then
    # shellcheck source=/dev/null
    source "iac/bootstrapping/.bootstrap_env"
fi

if [ -n "${1:-}" ]; then
    PROJECT_ID="$1"
else
    PROJECT_ID="${GCP_PROJECT_ID:-}"
fi

if [ -z "${PROJECT_ID:-}" ]; then
    PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "")
fi

if [ -z "${PROJECT_ID:-}" ]; then
    log_error "Could not determine project ID."
    echo "Usage: $0 [PROJECT_ID]"
    echo "Or set it via: gcloud config set project <PROJECT_ID>"
    echo "Or ensure iac/bootstrapping/.bootstrap_env exists with GCP_PROJECT_ID set."
    exit 1
fi

GCP_REGION="${GCP_REGION:-europe-west4}"
ENV="${ENV:-sandbox}"

GKE_CLUSTER="${ENV}-gke"
BIGTABLE_INSTANCE="bigtable-production-storage"
VPC_NAME="${ENV}-vpc"
SUBNET_NAME="${ENV}-subnet"
ROUTER_NAME="router"
NAT_NAME="nat"

# Derive DNS zone name — same logic as Terraform: replace(var.base_domain, ".", "-")
# Falls back to EXISTING_DNS_ZONE if base_domain is not set.
if [ -n "${EXISTING_DNS_ZONE:-}" ]; then
    DNS_ZONE="${EXISTING_DNS_ZONE}"
elif [ -n "${BASE_DOMAIN:-}" ]; then
    DNS_ZONE="${BASE_DOMAIN//./-}"
else
    DNS_ZONE=""
fi

# ---------------------------------------------------------------------------
# Show what will be deleted
# ---------------------------------------------------------------------------
echo ""
echo -e "${COLOR_RED}========================================${COLOR_NC}"
echo -e "${COLOR_RED}  WARNING: DESTRUCTIVE OPERATION${COLOR_NC}"
echo -e "${COLOR_RED}========================================${COLOR_NC}"
echo ""
echo "Project  : ${PROJECT_ID}"
echo "Region   : ${GCP_REGION}"
echo "Env      : ${ENV}"
echo ""
echo "The following resources will be permanently deleted:"
echo ""
echo -e "  ${COLOR_YELLOW}1. GKE cluster       :${COLOR_NC} ${GKE_CLUSTER} (region: ${GCP_REGION})"
echo -e "  ${COLOR_YELLOW}2. BigTable instance :${COLOR_NC} ${BIGTABLE_INSTANCE}"
echo -e "  ${COLOR_YELLOW}3. DNS record sets   :${COLOR_NC} ${DNS_ZONE:-"(zone not set — skipping)"} (all non-SOA/NS records)"
echo -e "  ${COLOR_YELLOW}4. Cloud NAT         :${COLOR_NC} ${NAT_NAME} (router: ${ROUTER_NAME}, region: ${GCP_REGION})"
echo -e "  ${COLOR_YELLOW}5. Cloud Router      :${COLOR_NC} ${ROUTER_NAME} (region: ${GCP_REGION})"
echo -e "  ${COLOR_YELLOW}6. VPC + dependencies:${COLOR_NC} ${VPC_NAME} (firewall rules, routes, subnet ${SUBNET_NAME})"
echo -e "  ${COLOR_YELLOW}7. Secrets           :${COLOR_NC} all secrets EXCEPT those containing 'github-oauthtoken'"
echo ""

# ---------------------------------------------------------------------------
# Fetch and display secrets that will be deleted
# ---------------------------------------------------------------------------
log_info "Fetching secrets list..."
SECRETS=$(gcloud secrets list --project="$PROJECT_ID" --format="value(name)" \
    | grep -v 'github-oauthtoken' || true)

if [ -z "$SECRETS" ]; then
    SECRET_COUNT=0
    echo "  (no secrets to delete)"
else
    SECRET_COUNT=$(echo "$SECRETS" | wc -l | tr -d ' ')
    echo "  Secrets to delete (${SECRET_COUNT}):"
    echo "$SECRETS" | sed 's/^/    /'
fi
echo ""

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------
read -rp "Are you sure you want to delete all of the above? (type 'yes' to confirm): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo -e "${COLOR_GREEN}Operation cancelled.${COLOR_NC}"
    exit 0
fi

echo ""
echo -e "${COLOR_RED}FINAL WARNING: This cannot be undone!${COLOR_NC}"
read -rp "Type the project ID '${PROJECT_ID}' to proceed: " PROJECT_CONFIRM
if [ "$PROJECT_CONFIRM" != "$PROJECT_ID" ]; then
    echo -e "${COLOR_GREEN}Operation cancelled.${COLOR_NC}"
    exit 0
fi

echo ""

# ---------------------------------------------------------------------------
# 1. Delete GKE cluster
# ---------------------------------------------------------------------------
echo -e "${COLOR_YELLOW}--- GKE cluster ---${COLOR_NC}"
if gcloud container clusters describe "$GKE_CLUSTER" \
        --region="$GCP_REGION" \
        --project="$PROJECT_ID" &>/dev/null; then
    log_info "Deleting GKE cluster '${GKE_CLUSTER}'..."
    if gcloud container clusters delete "$GKE_CLUSTER" \
            --region="$GCP_REGION" \
            --project="$PROJECT_ID" \
            --quiet; then
        log_ok "GKE cluster '${GKE_CLUSTER}' deleted."
    else
        log_error "Failed to delete GKE cluster '${GKE_CLUSTER}'."
    fi
else
    log_info "GKE cluster '${GKE_CLUSTER}' not found — skipping."
fi
echo ""

# ---------------------------------------------------------------------------
# 2. Delete BigTable instance
# ---------------------------------------------------------------------------
echo -e "${COLOR_YELLOW}--- BigTable instance ---${COLOR_NC}"
if gcloud bigtable instances describe "$BIGTABLE_INSTANCE" \
        --project="$PROJECT_ID" &>/dev/null; then
    log_info "Deleting BigTable instance '${BIGTABLE_INSTANCE}'..."
    if gcloud bigtable instances delete "$BIGTABLE_INSTANCE" \
            --project="$PROJECT_ID" \
            --quiet; then
        log_ok "BigTable instance '${BIGTABLE_INSTANCE}' deleted."
    else
        log_error "Failed to delete BigTable instance '${BIGTABLE_INSTANCE}'."
    fi
else
    log_info "BigTable instance '${BIGTABLE_INSTANCE}' not found — skipping."
fi
echo ""

# ---------------------------------------------------------------------------
# 3. Delete DNS record sets
#    external-dns creates A + TXT ownership records that survive teardown and
#    cause "alreadyExists" 409 errors when bootstrapping again. Deleting all
#    non-SOA/NS records clears those stale entries while leaving the zone itself
#    (and its nameservers) intact so DNS delegation at the registrar is preserved.
# ---------------------------------------------------------------------------
echo -e "${COLOR_YELLOW}--- DNS record sets ---${COLOR_NC}"
if [ -z "${DNS_ZONE:-}" ]; then
    log_info "BASE_DOMAIN and EXISTING_DNS_ZONE not set — skipping DNS cleanup."
elif ! gcloud dns managed-zones describe "$DNS_ZONE" \
        --project="$PROJECT_ID" &>/dev/null; then
    log_info "DNS zone '${DNS_ZONE}' not found — skipping."
else
    log_info "Listing record sets in zone '${DNS_ZONE}'..."
    # List all record sets; exclude SOA and NS (managed by GCP, cannot be deleted)
    DNS_RECORDS=$(gcloud dns record-sets list \
        --zone="$DNS_ZONE" \
        --project="$PROJECT_ID" \
        --format="csv[no-heading](name,type)" 2>/dev/null \
        | grep -v ',SOA$' | grep -v ',NS$' || true)
    if [ -z "$DNS_RECORDS" ]; then
        log_info "  No deletable record sets found."
    else
        while IFS=',' read -r rec_name rec_type; do
            [ -n "$rec_name" ] || continue
            if gcloud dns record-sets delete "$rec_name" \
                    --type="$rec_type" \
                    --zone="$DNS_ZONE" \
                    --project="$PROJECT_ID" \
                    --quiet 2>/dev/null; then
                log_ok "  Deleted: ${rec_name} (${rec_type})"
            else
                log_error "  Failed to delete: ${rec_name} (${rec_type})"
            fi
        done <<< "$DNS_RECORDS"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# 4. Delete Cloud NAT (must go before the router)
# ---------------------------------------------------------------------------
echo -e "${COLOR_YELLOW}--- Cloud NAT ---${COLOR_NC}"
if gcloud compute routers nats describe "$NAT_NAME" \
        --router="$ROUTER_NAME" \
        --region="$GCP_REGION" \
        --project="$PROJECT_ID" &>/dev/null; then
    log_info "Deleting Cloud NAT '${NAT_NAME}'..."
    if gcloud compute routers nats delete "$NAT_NAME" \
            --router="$ROUTER_NAME" \
            --region="$GCP_REGION" \
            --project="$PROJECT_ID" \
            --quiet; then
        log_ok "Cloud NAT '${NAT_NAME}' deleted."
    else
        log_error "Failed to delete Cloud NAT '${NAT_NAME}'."
    fi
else
    log_info "Cloud NAT '${NAT_NAME}' not found — skipping."
fi
echo ""

# ---------------------------------------------------------------------------
# 5. Delete Cloud Router
# ---------------------------------------------------------------------------
echo -e "${COLOR_YELLOW}--- Cloud Router ---${COLOR_NC}"
if gcloud compute routers describe "$ROUTER_NAME" \
        --region="$GCP_REGION" \
        --project="$PROJECT_ID" &>/dev/null; then
    log_info "Deleting Cloud Router '${ROUTER_NAME}'..."
    if gcloud compute routers delete "$ROUTER_NAME" \
            --region="$GCP_REGION" \
            --project="$PROJECT_ID" \
            --quiet; then
        log_ok "Cloud Router '${ROUTER_NAME}' deleted."
    else
        log_error "Failed to delete Cloud Router '${ROUTER_NAME}'."
    fi
else
    log_info "Cloud Router '${ROUTER_NAME}' not found — skipping."
fi
echo ""

# ---------------------------------------------------------------------------
# 6. Delete VPC and its dependencies
#    Order: GKE cluster (if still present) → firewall rules → subnet → VPC
# ---------------------------------------------------------------------------
echo -e "${COLOR_YELLOW}--- VPC and dependencies ---${COLOR_NC}"

# Delete the GKE cluster before the VPC — GKE creates firewall rules and NEGs
# attached to the VPC that must be gone before the network can be deleted.
log_info "Ensuring GKE cluster '${GKE_CLUSTER}' is deleted before removing VPC..."
if gcloud container clusters describe "$GKE_CLUSTER" \
        --region="$GCP_REGION" \
        --project="$PROJECT_ID" &>/dev/null; then
    log_info "GKE cluster '${GKE_CLUSTER}' still exists — deleting now..."
    if gcloud container clusters delete "$GKE_CLUSTER" \
            --region="$GCP_REGION" \
            --project="$PROJECT_ID" \
            --quiet; then
        log_ok "GKE cluster '${GKE_CLUSTER}' deleted."
    else
        log_error "Failed to delete GKE cluster '${GKE_CLUSTER}' — VPC deletion may fail."
    fi
else
    log_info "GKE cluster '${GKE_CLUSTER}' already gone."
fi

if gcloud compute networks describe "$VPC_NAME" \
        --project="$PROJECT_ID" &>/dev/null; then

    # Firewall rules
    log_info "Listing firewall rules on '${VPC_NAME}'..."
    FW_RULES=$(gcloud compute firewall-rules list \
        --filter="network:${VPC_NAME}" \
        --format="value(name)" \
        --project="$PROJECT_ID" 2>/dev/null || true)
    if [ -n "$FW_RULES" ]; then
        while IFS= read -r fw; do
            [ -n "$fw" ] || continue
            if gcloud compute firewall-rules delete "$fw" \
                    --project="$PROJECT_ID" --quiet 2>/dev/null; then
                log_ok "  Deleted firewall rule: ${fw}"
            else
                log_error "  Failed to delete firewall rule: ${fw}"
            fi
        done <<< "$FW_RULES"
    else
        log_info "  No firewall rules found on '${VPC_NAME}'."
    fi

    # Routes — GCP auto-creates default routes (e.g. default-route-*) that
    # block VPC deletion. Peering/subnet routes cannot be deleted manually and
    # are removed implicitly when their subnet or peering is removed; we skip
    # them if deletion fails.
    log_info "Deleting routes on '${VPC_NAME}'..."
    ROUTES=$(gcloud compute routes list \
        --filter="network:${VPC_NAME}" \
        --format="value(name)" \
        --project="$PROJECT_ID" 2>/dev/null || true)
    if [ -n "$ROUTES" ]; then
        while IFS= read -r route; do
            [ -n "$route" ] || continue
            if gcloud compute routes delete "$route" \
                    --project="$PROJECT_ID" --quiet 2>/dev/null; then
                log_ok "  Deleted route: ${route}"
            else
                log_info "  Skipped route (system-managed): ${route}"
            fi
        done <<< "$ROUTES"
    else
        log_info "  No routes found on '${VPC_NAME}'."
    fi

    # Subnet
    log_info "Deleting subnet '${SUBNET_NAME}'..."
    if gcloud compute networks subnets describe "$SUBNET_NAME" \
            --region="$GCP_REGION" \
            --project="$PROJECT_ID" &>/dev/null; then
        if gcloud compute networks subnets delete "$SUBNET_NAME" \
                --region="$GCP_REGION" \
                --project="$PROJECT_ID" \
                --quiet; then
            log_ok "Subnet '${SUBNET_NAME}' deleted."
        else
            log_error "Failed to delete subnet '${SUBNET_NAME}'."
        fi
    else
        log_info "Subnet '${SUBNET_NAME}' not found — skipping."
    fi

    # VPC
    log_info "Deleting VPC '${VPC_NAME}'..."
    if gcloud compute networks delete "$VPC_NAME" \
            --project="$PROJECT_ID" \
            --quiet; then
        log_ok "VPC '${VPC_NAME}' deleted."
    else
        log_error "Failed to delete VPC '${VPC_NAME}'. There may be remaining dependent resources."
    fi
else
    log_info "VPC '${VPC_NAME}' not found — skipping."
fi
echo ""

# ---------------------------------------------------------------------------
# 7. Delete secrets
# ---------------------------------------------------------------------------
echo -e "${COLOR_YELLOW}--- Secrets ---${COLOR_NC}"
if [ -z "$SECRETS" ]; then
    log_info "No secrets to delete."
else
    DELETED=0
    FAILED=0
    while IFS= read -r secret; do
        if gcloud secrets delete "$secret" --project="$PROJECT_ID" --quiet 2>/dev/null; then
            log_ok "Deleted secret: ${secret}"
            ((DELETED++))
        else
            log_error "Failed to delete secret: ${secret}"
            ((FAILED++))
        fi
    done <<< "$SECRETS"
    echo ""
    log_info "Secrets: ${DELETED} deleted, ${FAILED} failed."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${COLOR_GREEN}========================================${COLOR_NC}"
echo -e "${COLOR_GREEN}  Done.${COLOR_NC}"
echo -e "${COLOR_GREEN}========================================${COLOR_NC}"
