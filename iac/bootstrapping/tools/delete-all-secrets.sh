#!/bin/bash

# ==============================================================================
# Delete All Secrets from GCP Secret Manager
#
# WARNING: This script will permanently delete ALL secrets in the project!
# ==============================================================================

set -euo pipefail

# Colors
COLOR_RED='\033[0;31m'
COLOR_YELLOW='\033[1;33m'
COLOR_GREEN='\033[0;32m'
COLOR_NC='\033[0m'

PROJECT_ID="horizon-sdv-lal"

echo -e "${COLOR_RED}========================================${COLOR_NC}"
echo -e "${COLOR_RED}  WARNING: DESTRUCTIVE OPERATION${COLOR_NC}"
echo -e "${COLOR_RED}========================================${COLOR_NC}"
echo ""
echo "This script will delete ALL secrets from project: ${PROJECT_ID}"
echo ""

# List all secrets
echo -e "${COLOR_YELLOW}Fetching list of secrets...${COLOR_NC}"
SECRETS=$(gcloud secrets list --project="$PROJECT_ID" --format="value(name)")

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

# Confirmation prompt
read -rp "Are you sure you want to delete ALL ${SECRET_COUNT} secrets? (type 'yes' to confirm): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo -e "${COLOR_GREEN}Operation cancelled.${COLOR_NC}"
    exit 0
fi

# Second confirmation
echo ""
echo -e "${COLOR_RED}FINAL WARNING: This cannot be undone!${COLOR_NC}"
read -rp "Type the project ID '${PROJECT_ID}' to proceed: " PROJECT_CONFIRM

if [ "$PROJECT_CONFIRM" != "$PROJECT_ID" ]; then
    echo -e "${COLOR_GREEN}Operation cancelled.${COLOR_NC}"
    exit 0
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