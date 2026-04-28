#!/bin/bash
# Check architecture for all GKE and Cloud Run services in this project
# Usage: ./scripts/check-arm64-services.sh [--region REGION] [--project PROJECT]

# Don't exit on error - we want to check all services even if some fail
set +e

# Default values (can be overridden by .bootstrap_env or flags)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Source bootstrap env if available
if [ -f "$PROJECT_ROOT/iac/bootstrapping/.bootstrap_env" ]; then
  source "$PROJECT_ROOT/iac/bootstrapping/.bootstrap_env"
fi

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --region) GCP_REGION="$2"; shift 2 ;;
    --project) GCP_PROJECT_ID="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Validate required variables
: "${GCP_REGION:?GCP_REGION not set. Use --region or source .bootstrap_env}"
: "${GCP_PROJECT_ID:?GCP_PROJECT_ID not set. Use --project or source .bootstrap_env}"

echo "=========================================="
echo "  ARM64 Architecture Verification"
echo "=========================================="
echo "Project: $GCP_PROJECT_ID"
echo "Region:  $GCP_REGION"
echo ""

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

pass() { echo -e "${GREEN}✅ $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }

# ==========================================
# GKE Services
# ==========================================
echo "=========================================="
echo "  GKE Services (Autopilot)"
echo "=========================================="
echo ""

# Configure kubectl context using ENV from .bootstrap_env (cluster name pattern: ${ENV}-gke)
: "${ENV:?ENV not set. Source .bootstrap_env or check your environment}"
CLUSTER_NAME="${ENV}-gke"
echo "Configuring kubectl for cluster: $CLUSTER_NAME"
if ! gcloud container clusters get-credentials "$CLUSTER_NAME" \
    --dns-endpoint --region="$GCP_REGION" --project="$GCP_PROJECT_ID" --quiet 2>/dev/null; then
  warn "Could not configure kubectl for cluster $CLUSTER_NAME — GKE checks will be skipped"
fi
echo ""

# GKE Deployments - discovered dynamically at runtime
GKE_DEPLOYMENTS=()
while IFS= read -r line; do
  GKE_DEPLOYMENTS+=("$line")
done < <(kubectl get deployments --namespace  base-services --no-headers \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name' 2>/dev/null \
  | awk '{print $1 ":" $2}')
while IFS= read -r line; do
  GKE_DEPLOYMENTS+=("$line")
done < <(kubectl get deployments --namespace  sample-services --no-headers \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name' 2>/dev/null \
  | awk '{print $1 ":" $2}')

# GKE StatefulSets - discovered dynamically at runtime (pod suffix always 0 for first pod)
GKE_STATEFULSETS=()
while IFS= read -r line; do
  GKE_STATEFULSETS+=("$line")
done < <(kubectl get statefulsets --namespace  base-service --no-headers \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name' 2>/dev/null \
  | awk '{print $1 ":" $2 ":0"}')

while IFS= read -r line; do
  GKE_STATEFULSETS+=("$line")
done < <(kubectl get statefulsets --namespace  sample-services --no-headers \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name' 2>/dev/null \
  | awk '{print $1 ":" $2 ":0"}')

check_deployment_arch() {
  local ns="$1"
  local dep="$2"

  # First try uname -m (works for images with shell)
  ARCH=$(kubectl exec -n "$ns" "deployment/$dep" -- uname -m 2>/dev/null || echo "")
  if [ -n "$ARCH" ]; then
    echo "$ARCH"
    return 0
  fi

  # Fallback: Check node architecture for scratch images
  NODE=$(kubectl get pod -n "$ns" -l "app.kubernetes.io/name=$dep" -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || \
         kubectl get pod -n "$ns" -l "app=$dep" -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || echo "")

  if [ -n "$NODE" ]; then
    NODE_ARCH=$(kubectl get node "$NODE" -o jsonpath='{.metadata.labels.kubernetes\.io/arch}' 2>/dev/null || echo "")
    if [ -n "$NODE_ARCH" ]; then
      echo "$NODE_ARCH"
      return 0
    fi
  fi

  echo ""
  return 1
}

echo "--- Deployments ---"
if [ ${#GKE_DEPLOYMENTS[@]} -eq 0 ]; then
  warn "No deployments found"
else
  for item in "${GKE_DEPLOYMENTS[@]}"; do
    ns="${item%%:*}"
    dep="${item##*:}"

    ARCH=$(check_deployment_arch "$ns" "$dep")

    if [ -n "$ARCH" ]; then
      if [[ "$ARCH" == "aarch64"* ]] || [[ "$ARCH" == "arm64"* ]]; then
        pass "$dep ($ns): $ARCH"
      else
        fail "$dep ($ns): $ARCH"
      fi
    else
      warn "$dep ($ns): not running or not found"
    fi
  done
fi

echo ""
echo "--- StatefulSets ---"
if [ ${#GKE_STATEFULSETS[@]} -eq 0 ]; then
  warn "No statefulsets found"
else
  for item in "${GKE_STATEFULSETS[@]}"; do
    IFS=':' read -r ns sts pod_suffix <<< "$item"
    pod_name="${sts}-${pod_suffix}"

    echo "  method: uname"
    ARCH=$(kubectl exec -n "$ns" "$pod_name" -- uname -m 2>/dev/null || echo "")

    if [ -n "$ARCH" ]; then
      if [ "$ARCH" = "aarch64" ]; then
        pass "$sts ($ns): $ARCH"
      else
        fail "$sts ($ns): $ARCH"
      fi
    else
      warn "$sts ($ns): not running or not found"
    fi
  done
fi

echo ""
echo "--- Node Information ---"
kubectl get nodes -o custom-columns='NAME:.metadata.name,ARCH:.metadata.labels.kubernetes\.io/arch,FAMILY:.metadata.labels.cloud\.google\.com/machine-family' 2>/dev/null || warn "Could not get node info"

# ==========================================
# Cloud Run Services
# ==========================================
echo ""
echo "=========================================="
echo "  Cloud Run Services"
echo "=========================================="
echo ""

# Cloud Run services - discovered dynamically at runtime
CLOUDRUN_SERVICES=()
while IFS= read -r line; do
  CLOUDRUN_SERVICES+=("$line")
done < <(gcloud run services list \
  --region="$GCP_REGION" \
  --project="$GCP_PROJECT_ID" \
  --format="value(metadata.name)" 2>/dev/null)

check_cloudrun_arch() {
  local service="$1"
  local image

  # Get the image URL from Cloud Run
  echo "  method: gcloud run services describe $service (get image URL)"
  image=$(gcloud run services describe "$service" \
    --region="$GCP_REGION" \
    --project="$GCP_PROJECT_ID" \
    --format="value(template.spec.containers[0].image)" 2>/dev/null)

  if [ -z "$image" ]; then
    warn "$service: not deployed"
    return
  fi

  echo "  image:  $image"

  # Try docker manifest inspect to check architecture
  echo "  method: docker manifest inspect (check image manifest for architecture)"
  local arch
  arch=$(docker manifest inspect "$image" 2>/dev/null | grep -o '"architecture": "[^"]*"' | head -1 | cut -d'"' -f4 || echo "")

  if [ -n "$arch" ]; then
    if [ "$arch" = "arm64" ]; then
      pass "$service: $arch (from docker manifest)"
    else
      fail "$service: $arch (from docker manifest)"
    fi
  else
    warn "$service: could not read image manifest (docker not available or image is private)"
    echo "   $service: ✓ deployed (image: ${image##*/})"
  fi
}

echo "--- Cloud Run Services ---"
echo ""

if [ ${#CLOUDRUN_SERVICES[@]} -eq 0 ]; then
  warn "No Cloud Run services found in region $GCP_REGION"
else
  for service in "${CLOUDRUN_SERVICES[@]}"; do
    check_cloudrun_arch "$service"
  done
fi

echo ""
echo "=========================================="
echo "  Summary"
echo "=========================================="
echo ""
echo "To manually verify a Cloud Run service image architecture:"
echo "  gcloud run services describe SERVICE --region=$GCP_REGION --format='value(template.spec.containers[0].image)'"
echo "  docker manifest inspect IMAGE_URL | grep architecture"
echo ""
