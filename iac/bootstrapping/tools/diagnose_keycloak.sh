#!/bin/bash
# Keycloak Pod Diagnostic Script for Remote PKI Strategy
# Project: horizon-sdv-lal
# Environment: dev-lal
# PKI Strategy: remote (Google CAS)

set -euo pipefail

# Colors
COLOR_BLUE='\033[0;34m'
COLOR_YELLOW='\033[1;33m'
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_NC='\033[0m'

log_info() { echo -e "${COLOR_BLUE}[INFO]${COLOR_NC} $*"; }
log_warn() { echo -e "${COLOR_YELLOW}[WARN]${COLOR_NC} $*"; }
log_error() { echo -e "${COLOR_RED}[ERROR]${COLOR_NC} $*"; }
log_success() { echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_NC} $*"; }

# Configuration
PROJECT_ID="horizon-sdv-lal"
REGION="us-central1"
CLUSTER_NAME="dev-lal-gke"
NAMESPACE="base-services"

log_info "=========================================="
log_info "Keycloak Pod Diagnostics - Remote PKI"
log_info "=========================================="
log_info "Project: $PROJECT_ID"
log_info "Cluster: $CLUSTER_NAME"
log_info "Region: $REGION"
log_info "Namespace: $NAMESPACE"
log_info ""

# Step 1: Authenticate and connect to cluster
log_info "Step 1: Connecting to GKE cluster..."
gcloud config set project "$PROJECT_ID"
gcloud container clusters get-credentials "$CLUSTER_NAME" --region="$REGION" --project="$PROJECT_ID"

# Step 2: Get pod status
log_info ""
log_info "Step 2: Checking Keycloak pod status..."
echo "=========================================="
kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=keycloak -o wide
echo "=========================================="

# Get pod name
POD_NAME=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$POD_NAME" ]; then
    log_error "No Keycloak pod found in namespace $NAMESPACE"
    log_info "Checking if deployment exists..."
    kubectl get deployment -n "$NAMESPACE" -l app.kubernetes.io/name=keycloak
    exit 1
fi

log_info "Found pod: $POD_NAME"

# Step 3: Get detailed pod status
log_info ""
log_info "Step 3: Checking detailed pod status..."
echo "=========================================="
kubectl describe pod "$POD_NAME" -n "$NAMESPACE"
echo "=========================================="

# Step 4: Check pod events
log_info ""
log_info "Step 4: Checking pod events..."
echo "=========================================="
kubectl get events -n "$NAMESPACE" --field-selector involvedObject.name="$POD_NAME" --sort-by='.lastTimestamp'
echo "=========================================="

# Step 5: Check init container logs
log_info ""
log_info "Step 5: Checking init container logs (import-ca-certs)..."
echo "=========================================="
kubectl logs "$POD_NAME" -n "$NAMESPACE" -c import-ca-certs --tail=100 || log_warn "Init container logs not available (may not have started yet)"
echo "=========================================="

# Step 6: Check cloud-sql-proxy logs
log_info ""
log_info "Step 6: Checking Cloud SQL Proxy logs..."
echo "=========================================="
kubectl logs "$POD_NAME" -n "$NAMESPACE" -c cloud-sql-proxy --tail=100 || log_warn "Cloud SQL Proxy logs not available"
echo "=========================================="

# Step 7: Check main Keycloak container logs
log_info ""
log_info "Step 7: Checking Keycloak container logs..."
echo "=========================================="
kubectl logs "$POD_NAME" -n "$NAMESPACE" -c keycloak --tail=200 || log_warn "Keycloak container logs not available"
echo "=========================================="

# Step 8: Check ConfigMaps and Secrets
log_info ""
log_info "Step 8: Checking ConfigMaps and Secrets..."
echo "=========================================="
log_info "ConfigMaps:"
kubectl get configmap -n "$NAMESPACE" | grep keycloak
echo ""
log_info "Secrets:"
kubectl get secret -n "$NAMESPACE" | grep keycloak
echo "=========================================="

# Step 9: Check TLS secret contents
log_info ""
log_info "Step 9: Checking TLS secret structure..."
echo "=========================================="
TLS_SECRET=$(kubectl get secret -n "$NAMESPACE" -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[?(@.type=="Opaque")].metadata.name}' | grep tls || echo "")
if [ -n "$TLS_SECRET" ]; then
    log_info "TLS Secret: $TLS_SECRET"
    kubectl get secret "$TLS_SECRET" -n "$NAMESPACE" -o jsonpath='{.data}' | jq 'keys'
else
    log_warn "No TLS secret found for Keycloak"
fi
echo "=========================================="

# Step 10: Check Service Account and Workload Identity
log_info ""
log_info "Step 10: Checking Service Account and Workload Identity..."
echo "=========================================="
kubectl get serviceaccount keycloak-ksa -n "$NAMESPACE" -o yaml
echo "=========================================="

# Step 11: Check probes status
log_info ""
log_info "Step 11: Checking probe status..."
echo "=========================================="
kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[*]}' | jq -r '.'
echo "=========================================="

# Step 12: Check GCP resources related to PKI
log_info ""
log_info "Step 12: Checking Google CAS configuration..."
echo "=========================================="

# Get CA pool from Secret Manager
log_info "Fetching SERVER_CA_POOL from Secret Manager..."
SERVER_CA_POOL=$(gcloud secrets versions access latest --secret="SERVER_CA_POOL" --project="$PROJECT_ID" 2>/dev/null || echo "NOT_FOUND")
log_info "SERVER_CA_POOL: $SERVER_CA_POOL"

if [ "$SERVER_CA_POOL" != "NOT_FOUND" ]; then
    log_info "Checking CA pool status..."
    gcloud privateca pools describe "$SERVER_CA_POOL" --location="$REGION" --project="$PROJECT_ID" || log_warn "Could not describe CA pool"

    log_info "Listing certificates in pool..."
    gcloud privateca certificates list --pool="$SERVER_CA_POOL" --location="$REGION" --project="$PROJECT_ID" --limit=5 || log_warn "Could not list certificates"
fi
echo "=========================================="

# Step 13: Check DNS configuration
log_info ""
log_info "Step 13: Checking DNS configuration..."
echo "=========================================="
BASE_DOMAIN=$(gcloud secrets versions access latest --secret="BASE_DOMAIN" --project="$PROJECT_ID" 2>/dev/null || echo "NOT_FOUND")
log_info "BASE_DOMAIN: $BASE_DOMAIN"

if [ "$BASE_DOMAIN" != "NOT_FOUND" ]; then
    KEYCLOAK_FQDN="keycloak.$BASE_DOMAIN"
    log_info "Expected FQDN: $KEYCLOAK_FQDN"

    # Check if DNS record exists
    log_info "Checking DNS record..."
    nslookup "$KEYCLOAK_FQDN" || log_warn "DNS lookup failed"
fi
echo "=========================================="

# Step 14: Check Cloud SQL instance
log_info ""
log_info "Step 14: Checking Cloud SQL instance..."
echo "=========================================="
INSTANCE_CON=$(gcloud secrets versions access latest --secret="KEYCLOAK_INSTANCE_CON_SQL_PROXY" --project="$PROJECT_ID" 2>/dev/null || echo "NOT_FOUND")
log_info "Instance Connection Name: $INSTANCE_CON"

if [ "$INSTANCE_CON" != "NOT_FOUND" ]; then
    INSTANCE_NAME=$(echo "$INSTANCE_CON" | cut -d: -f3)
    log_info "Checking Cloud SQL instance status..."
    gcloud sql instances describe "$INSTANCE_NAME" --project="$PROJECT_ID" --format="table(state,databaseVersion,settings.tier)" || log_warn "Could not describe Cloud SQL instance"
fi
echo "=========================================="

# Step 15: Summary
log_info ""
log_info "=========================================="
log_info "DIAGNOSTIC SUMMARY"
log_info "=========================================="
log_info "Pod Name: $POD_NAME"
POD_STATUS=$(kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
log_info "Pod Phase: $POD_STATUS"

# Check container statuses
log_info ""
log_info "Container Statuses:"
kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{range .status.containerStatuses[*]}{.name}{": "}{.state}{"\n"}{end}' || echo "N/A"

# Check readiness
READY=$(kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
log_info ""
log_info "Pod Ready: $READY"

log_info ""
log_info "=========================================="
log_info "Next Steps:"
log_info "1. Check the logs above for specific error messages"
log_info "2. Look for certificate-related errors (TLS, CA, CAS)"
log_info "3. Verify Cloud SQL Proxy can connect to the database"
log_info "4. Check if certificates were properly issued by Google CAS"
log_info "5. Verify DNS is configured correctly for the base domain"
log_info "=========================================="