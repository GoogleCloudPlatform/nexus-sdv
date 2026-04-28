#!/bin/bash
set -euo pipefail

# Define the directory containing the scripts
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Running bootstrapping tests in $SCRIPT_DIR..."

# 1. Check for existence of key scripts
REQUIRED_FILES=(
  "bootstrap-platform.sh"
  "teardown-platform.sh"
  "bucket-lifecycle-rules.json"
)

for file in "${REQUIRED_FILES[@]}"; do
  if [ ! -f "$SCRIPT_DIR/$file" ]; then
    echo "❌ Error: Required file '$file' not found."
    exit 1
  else
    echo "✅ Found '$file'."
  fi
done

# 2. Check syntax of shell scripts
echo "Checking syntax of shell scripts..."
find "$SCRIPT_DIR" -maxdepth 1 -name "*.sh" | while read -r script; do
  if bash -n "$script"; then
    echo "✅ Syntax OK: $(basename "$script")"
  else
    echo "❌ Syntax Error: $(basename "$script")"
    exit 1
  fi
done

echo "All bootstrapping tests passed!"
