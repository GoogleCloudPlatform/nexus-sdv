#!/bin/bash
set -e

# Setup script for external-secrets operator
# This script installs and configures external-secrets to sync NATS credentials from GCP Secret Manager

echo "====== External Secrets Setup ======"
echo ""

# Check for required tools
for cmd in gcloud kubectl helm; do
  if ! command -v $cmd &> /dev/null; then
    echo "ERROR: $cmd is not installed"
    exit 1
  fi
done

# Get configuration from user or environment
PROJECT_ID=${GCP_PROJECT_ID:-$(gcloud config get-value project)}
if [ -z "$PROJECT_ID" ]; then
  echo "ERROR: GCP_PROJECT_ID not set and no default project configured"
  exit 1
fi

CLUSTER_NAME=${GCP_CLUSTER_NAME:-"sandbox-gke"}
CLUSTER_REGION=${GCP_REGION:-"us-central1"}

echo "GCP Project ID: $PROJECT_ID"
echo "GKE Cluster Name: $CLUSTER_NAME"
echo "GKE Cluster Region: $CLUSTER_REGION"
echo ""

# Step 1: Install external-secrets operator
echo "Step 1: Installing external-secrets operator..."
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

if helm list -n external-secrets-system | grep -q "external-secrets"; then
  echo "  ✓ external-secrets already installed"
else
  helm install external-secrets external-secrets/external-secrets \
    -n external-secrets-system \
    --create-namespace
  echo "  ✓ external-secrets installed"
fi

# Step 2: Create GCP service account
echo ""
echo "Step 2: Creating GCP service account for external-secrets..."
SA_NAME="external-secrets-sa"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

if gcloud iam service-accounts describe "$SA_EMAIL" &> /dev/null; then
  echo "  ✓ Service account already exists: $SA_EMAIL"
else
  gcloud iam service-accounts create "$SA_NAME" \
    --display-name="external-secrets operator"
  echo "  ✓ Created service account: $SA_EMAIL"
fi

# Step 3: Grant Secret Manager access
echo ""
echo "Step 3: Granting Secret Manager permissions..."
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/secretmanager.secretAccessor" \
  --condition=None
echo "  ✓ Granted roles/secretmanager.secretAccessor to $SA_EMAIL"

# Step 4: Set up Workload Identity
echo ""
echo "Step 4: Setting up Workload Identity..."

# Grant the Kubernetes service account permission to impersonate the GCP service account
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[external-secrets-system/external-secrets]" \
  --condition=None
echo "  ✓ Granted Workload Identity binding"

# Annotate the Kubernetes service account
kubectl annotate serviceaccount external-secrets \
  -n external-secrets-system \
  "iam.gke.io/gcp-service-account=${SA_EMAIL}" \
  --overwrite
echo "  ✓ Annotated Kubernetes service account"

# Restart external-secrets pod to apply annotation
kubectl rollout restart deployment/external-secrets -n external-secrets-system
kubectl rollout wait --for=condition=available --timeout=300s \
  deployment/external-secrets -n external-secrets-system
echo "  ✓ Restarted external-secrets pod"

# Step 5: Create SecretStore
echo ""
echo "Step 5: Creating SecretStore in base-services namespace..."

# Create namespace if it doesn't exist
kubectl create namespace base-services --dry-run=client -o yaml | kubectl apply -f -

# Create SecretStore
cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: gcpsm-secret-store
  namespace: base-services
spec:
  provider:
    gcpsm:
      projectID: "$PROJECT_ID"
      auth:
        workloadIdentity:
          clusterLocation: "$CLUSTER_REGION"
          clusterName: "$CLUSTER_NAME"
          serviceAccountRef:
            name: nats-bigtable-connector-ksa
EOF
echo "  ✓ Created SecretStore: gcpsm-secret-store"

# Step 6: Verify setup
echo ""
echo "Step 6: Verifying setup..."
echo ""

echo "Checking external-secrets operator..."
if kubectl get deployment external-secrets -n external-secrets-system &> /dev/null; then
  echo "  ✓ external-secrets deployment exists"
else
  echo "  ✗ external-secrets deployment not found"
  exit 1
fi

echo ""
echo "Checking SecretStore..."
if kubectl get secretstore gcpsm-secret-store -n base-services &> /dev/null; then
  echo "  ✓ SecretStore exists"
else
  echo "  ✗ SecretStore not found"
  exit 1
fi

echo ""
echo "====== Setup Complete ======"
echo ""
echo "Next steps:"
echo "1. Update iac/helm/nats-bigtable-connector/values.yaml:"
echo "   - Set externalSecrets.clusterLocation to: $CLUSTER_REGION"
echo "   - Set externalSecrets.clusterName to: $CLUSTER_NAME"
echo ""
echo "2. Deploy the nats-bigtable-connector:"
echo "   helm install ... iac/helm/nats-bigtable-connector"
echo ""
echo "3. Verify the Secret is synced:"
echo "   kubectl get secret nats-bigtable-connector-secret -n base-services"
echo ""
