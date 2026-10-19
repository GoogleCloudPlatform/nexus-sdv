#!/usr/bin/env bash
# Puts our Manager into Google's quickstart in an AOSP tree, so the image carries it.
# Keeps the original once as main.rs.google.
#   ./stage.sh <aosp-root>
set -euo pipefail
AOSP="${1:?usage: stage.sh <aosp-root>}"
Q="$AOSP/system/software_defined_vehicle/samples/quickstart"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$Q/services/Manager/src/main.rs.google" ] || cp "$Q/services/Manager/src/main.rs" "$Q/services/Manager/src/main.rs.google"
cp "$HERE/Manager/src/main.rs" "$Q/services/Manager/src/main.rs"
echo "staged: $Q/services/Manager/src/main.rs"
