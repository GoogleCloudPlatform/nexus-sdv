#!/usr/bin/env bash
# Standalone deployment for nexus-pubsub-consumer — deliberately NOT part of the
# Nexus deploy-all / helmfile / CloudBuild pipeline (see the Increment 1.2
# design, §4.3). Service delivery is a first-class topic for the SDK in
# Increment 3, and this service is the subject that question gets worked on.
#
# Usage: IMAGE=<registry>/nexus-pubsub-consumer:<tag> ./apply.sh <gcp-project>
set -euo pipefail

IMAGE="${IMAGE:?set IMAGE to the pushed container image}"
# IMAGE goes into a sed replacement below; only what an image reference is made of may pass.
[[ "${IMAGE}" =~ ^[A-Za-z0-9._/:@-]+$ ]] || { echo "IMAGE holds a character an image reference cannot: ${IMAGE}" >&2; exit 1; }
PROJECT="${1:?usage: IMAGE=<image> ./apply.sh <gcp-project>}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v kubectl >/dev/null || { echo "kubectl is required" >&2; exit 1; }
command -v gcloud  >/dev/null || { echo "gcloud is required" >&2; exit 1; }

echo "==> NATS password from Secret Manager (project ${PROJECT})"
PW="$(gcloud secrets versions access latest --secret=NATS_CONNECTOR_PASSWORD --project "${PROJECT}")"
[ -n "${PW}" ] || { echo "could not read NATS_CONNECTOR_PASSWORD" >&2; exit 1; }

# The password goes in on stdin: as a --from-literal argument it would sit in the process
# list for anyone on this machine to read. printf is a shell builtin, so it is not in it either.
printf '%s' "${PW}" | kubectl create secret generic nexus-pubsub-consumer \
  --namespace base-services --from-file=NATS_PASSWORD=/dev/stdin \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "${DIR}/configmap.yaml"
sed "s|IMAGE_PLACEHOLDER|${IMAGE}|" "${DIR}/deployment.yaml" | kubectl apply -f -

kubectl -n base-services rollout status deployment/nexus-pubsub-consumer --timeout=120s
echo "==> logs: kubectl -n base-services logs -f deployment/nexus-pubsub-consumer"
