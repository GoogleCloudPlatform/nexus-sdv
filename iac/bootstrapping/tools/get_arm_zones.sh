#!/bin/bash

# ==============================================================================
# Get ARM Supported GCP Regions
#
# This script queries Google Cloud to find all zones that support ARM-based
# machine types (T2A, C4A, and N4A series), removes the zone suffixes,
# removes duplicates, and saves the unique list of regions to a file.
# ==============================================================================

set -euo pipefail

# Determine the script's directory to reliably find the project root
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
PROJECT_ROOT="$SCRIPT_DIR/../../.."

OUTPUT_FILE="$PROJECT_ROOT/docs/arm_supported_regions.txt"

echo "Querying GCP for ARM-supported zones..."

# 1. Run the gcloud commands to get all zones.
# 2. Pipe the output to sed to remove the zone suffix (e.g., "-a", "-b").
# 3. Pipe the result to sort -u to get a unique, sorted list of regions.

echo "***************************" > "$OUTPUT_FILE"
echo "* Zones with n4a suppport *" >> "$OUTPUT_FILE"
echo "***************************" >> "$OUTPUT_FILE"
{
  gcloud compute machine-types list --filter="name:n4a-*" --format="value(zone)"
} | sed 's/-[a-z]$//' | sort -u >> "$OUTPUT_FILE"
echo "***************************" >> "$OUTPUT_FILE"
echo "* Zones with c4a suppport *" >> "$OUTPUT_FILE"
echo "***************************" >> "$OUTPUT_FILE"
{
  gcloud compute machine-types list --filter="name:c4a-*" --format="value(zone)"
} | sed 's/-[a-z]$//' | sort -u >> "$OUTPUT_FILE"
echo "***************************" >> "$OUTPUT_FILE"
echo "* Zones with t2a suppport *" >> "$OUTPUT_FILE"
echo "***************************" >> "$OUTPUT_FILE"
{
  gcloud compute machine-types list --filter="name:t2a-*" --format="value(zone)"
} | sed 's/-[a-z]$//' | sort -u >> "$OUTPUT_FILE"

echo "Done. A list of ARM-supported regions has been saved to: $OUTPUT_FILE"
