#!/bin/bash

# ==============================================================================
# Delete All Secrets from GCP Secret Manager
#
# WARNING: This script will permanently delete ALL secrets in the project!
#
# Usage: delete-all-secrets.sh [PROJECT_ID] [--yes] [--ignore-build BUILD_ID]
#
# Secrets whose name contains 'github-oauthtoken' are preserved: that token does
# not belong to the platform, and deleting it means setting the repository
# connection up again, which needs a browser sign-in.
# ==============================================================================

set -euo pipefail

# Colors
COLOR_RED='\033[0;31m'
COLOR_YELLOW='\033[1;33m'
COLOR_GREEN='\033[0;32m'
COLOR_NC='\033[0m'

# --yes skips both confirmations. It exists for the matrix run and for the
# install skill once a person has confirmed: neither has anybody at a prompt.
# Spelled out rather than -y, so nobody reaches it by a slip of the hand.
ASSUME_YES=false
IGNORE_BUILD=""
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --yes) ASSUME_YES=true; shift ;;
        --ignore-build) IGNORE_BUILD="${2:-}"; shift 2 ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
set -- "${ARGS[@]:-}"

# Determine project ID from .bootstrap_env, gcloud config, or command-line argument
if [ -n "${1:-}" ]; then
    PROJECT_ID="$1"
elif [ -f "iac/bootstrapping/.bootstrap_env" ]; then
    # shellcheck source=/dev/null
    source "iac/bootstrapping/.bootstrap_env"
    PROJECT_ID="${GCP_PROJECT_ID:-}"
fi

if [ -z "${PROJECT_ID:-}" ]; then
    PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "")
fi

if [ -z "${PROJECT_ID:-}" ]; then
    echo -e "${COLOR_RED}ERROR: Could not determine project ID.${COLOR_NC}"
    echo "Usage: $0 [PROJECT_ID]"
    echo "Or set it via: gcloud config set project <PROJECT_ID>"
    echo "Or ensure iac/bootstrapping/.bootstrap_env exists with GCP_PROJECT_ID set."
    exit 1
fi

echo -e "${COLOR_RED}========================================${COLOR_NC}"
echo -e "${COLOR_RED}  WARNING: DESTRUCTIVE OPERATION${COLOR_NC}"
echo -e "${COLOR_RED}========================================${COLOR_NC}"
echo ""
echo "This script will delete ALL secrets from project: ${PROJECT_ID}"
echo "Secrets whose name contains 'github-oauthtoken' will be preserved."
echo ""

# List all secrets, excluding any that contain 'github-oauthtoken'
# Refuse while the project is busy. A platform being built or torn down holds
# its secrets open, and removing one mid-flight fails the run in a way that
# points somewhere else: on 2026-09-30 this deleted `ENV` from under a live
# bootstrap, which surfaced four builds deeper as a Keycloak deploy failure.
#
# --ignore-build exists because the matrix calls this from inside a build of its
# own and would otherwise refuse on account of itself.
BUSY=""
for region in europe-west3 europe-west4; do
    ongoing=$(gcloud builds list --project="$PROJECT_ID" --region="$region" --ongoing \
        --format="value(id)" 2>/dev/null || true)
    for id in $ongoing; do
        [ -n "$IGNORE_BUILD" ] && [ "$id" = "$IGNORE_BUILD" ] && continue
        BUSY="$BUSY $id($region)"
    done
done
if [ -n "$BUSY" ]; then
    echo -e "${COLOR_RED}Refusing: builds are running in ${PROJECT_ID}:${COLOR_NC}${BUSY}"
    echo "A platform being built or torn down is using these secrets."
    echo "Wait for them, or pass --ignore-build <ID> if one of them is you."
    exit 1
fi

echo -e "${COLOR_YELLOW}Fetching list of secrets...${COLOR_NC}"
SECRETS=$(gcloud secrets list --project="$PROJECT_ID" --format="value(name)" \
    | grep -v 'github-oauthtoken' || true)

if [ -z "$SECRETS" ]; then
    echo -e "${COLOR_GREEN}No secrets found in project.${COLOR_NC}"
    exit 0
fi

# Count secrets
SECRET_COUNT=$(echo "$SECRETS" | wc -l | tr -d ' ')
echo ""
echo -e "${COLOR_YELLOW}Found ${SECRET_COUNT} secrets:${COLOR_NC}"
echo "$SECRETS"
echo ""

if $ASSUME_YES; then
    echo -e "${COLOR_YELLOW}--yes: deleting without confirmation.${COLOR_NC}"
else
    read -rp "Are you sure you want to delete ALL ${SECRET_COUNT} secrets? (type 'yes' to confirm): " CONFIRM

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
fi

# Delete secrets
echo ""
echo -e "${COLOR_YELLOW}Deleting secrets...${COLOR_NC}"
DELETED=0
FAILED=0

while IFS= read -r secret; do
    if gcloud secrets delete "$secret" --project="$PROJECT_ID" --quiet 2>/dev/null; then
        echo -e "${COLOR_GREEN}✓ Deleted: $secret${COLOR_NC}"
        ((DELETED++))
    else
        echo -e "${COLOR_RED}✗ Failed to delete: $secret${COLOR_NC}"
        ((FAILED++))
    fi
done <<< "$SECRETS"

echo ""
echo -e "${COLOR_GREEN}========================================${COLOR_NC}"
echo -e "${COLOR_GREEN}Deletion complete!${COLOR_NC}"
echo -e "${COLOR_GREEN}  Deleted: $DELETED${COLOR_NC}"
if [ $FAILED -gt 0 ]; then
    echo -e "${COLOR_RED}  Failed: $FAILED${COLOR_NC}"
fi
echo -e "${COLOR_GREEN}========================================${COLOR_NC}"
