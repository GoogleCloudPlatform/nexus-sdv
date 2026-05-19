#!/bin/bash
# Check architecture of all running pods across namespaces
# Usage: ./check-pod-architectures.sh [cluster-name] [region]

CLUSTER_NAME="${1:-dev-lal-gke}"
REGION="${2:-europe-west4}"

# Connect to cluster
echo "Connecting to cluster: $CLUSTER_NAME in $REGION..."
gcloud container clusters get-credentials "$CLUSTER_NAME" --dns-endpoint --region "$REGION" --quiet 2>/dev/null

if [ $? -ne 0 ]; then
  echo "ERROR: Could not connect to cluster $CLUSTER_NAME in $REGION"
  exit 1
fi

echo ""
echo "=== Node Architecture ==="
echo "-----------------------------------------------------------"
printf "%-45s %-10s %s\n" "NODE" "ARCH" "MACHINE TYPE"
echo "-----------------------------------------------------------"
kubectl get nodes -o json | jq -r '
  .items[] |
  [.metadata.name, .status.nodeInfo.architecture, (.metadata.labels["node.kubernetes.io/instance-type"] // "unknown")] |
  @tsv' | while IFS=$'\t' read -r name arch instance; do
    printf "%-45s %-10s %s\n" "$name" "$arch" "$instance"
done

echo ""
echo "=== Pod Architecture ==="
echo "-----------------------------------------------------------"
printf "%-20s %-40s %-10s %s\n" "NAMESPACE" "POD" "ARCH" "NODE"
echo "-----------------------------------------------------------"

for ns in $(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -v '^kube-'); do
  for pod in $(kubectl get pods -n "$ns" --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    node=$(kubectl get pod "$pod" -n "$ns" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
    # Try uname -m in the first container
    arch=$(kubectl exec -n "$ns" "$pod" -- uname -m 2>/dev/null || echo "N/A")
    printf "%-20s %-40s %-10s %s\n" "$ns" "$pod" "$arch" "$node"
  done
done

echo ""
echo "=== Summary ==="
echo "-----------------------------------------------------------"
echo "aarch64 = ARM64 | x86_64 = AMD64 | N/A = container lacks uname"
