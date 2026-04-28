#!/bin/bash
set -euo pipefail

# Define the directory containing the charts
HELM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Running Helm structure tests in $HELM_DIR..."

# List of expected chart directories
CHARTS=(
  "data-api"
  "keycloak"
  "nats"
  "nats-auth-callout"
  "nats-bigtable-connector"
  "registration"
)

for chart in "${CHARTS[@]}"; do
  CHART_PATH="$HELM_DIR/$chart"
  
  if [ ! -d "$CHART_PATH" ]; then
    echo "❌ Error: Chart directory '$chart' not found."
    exit 1
  fi

  # Check for Chart.yaml
  if [ ! -f "$CHART_PATH/Chart.yaml" ]; then
    echo "❌ Error: '$chart/Chart.yaml' missing."
    exit 1
  else
    echo "✅ Found '$chart/Chart.yaml'."
  fi

  # Check for values.yaml
  if [ ! -f "$CHART_PATH/values.yaml" ]; then
    echo "❌ Error: '$chart/values.yaml' missing."
    exit 1
  else
    echo "✅ Found '$chart/values.yaml'."
  fi
done

echo "All Helm structure tests passed!"
