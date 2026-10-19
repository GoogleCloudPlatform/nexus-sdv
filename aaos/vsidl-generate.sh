#!/usr/bin/env bash
# Generates code and configuration from our VSIDL catalogs with the platform's vsidlc.
# Run on the build server, in an AOSP tree where aaos/ is staged under vendor/nexus/:
#   ./vsidl-generate.sh <aosp-root> [--first]
# --first also generates the service code skeletons (services/*/src/main.rs); without it
# they are left alone, because their TODOs are filled by hand — that is the developer's part.
set -euo pipefail
AOSP="${1:?usage: vsidl-generate.sh <aosp-root> [--first]}"
SERVICES=""; [ "${2:-}" = "--first" ] && SERVICES="--services"
VSIDLC="$AOSP/out/host/linux-x86/bin/vsidlc"
[ -x "$VSIDLC" ] || { echo "no vsidlc at $VSIDLC — build it: m vsidlc" >&2; exit 1; }
N="$AOSP/vendor/nexus"
QUICKSTART="$AOSP/system/software_defined_vehicle/samples/quickstart/catalog"
export ANDROID_BUILD_TOP="$AOSP"

# Our examples: code, permissions, orchestration, APEX scaffold.
"$VSIDLC" -c "$N/nexus-sdv-sample/catalog" -o "$N/nexus-sdv-sample" \
    --genrule $SERVICES --apex --target-api latest
# The Bridge: permissions only. Its code is ours (skip_codegen) and its APEX is the TCU's,
# so the scaffold goes to a scratch directory and only configs/permissions is kept.
SCRATCH="$(mktemp -d)"; trap 'rm -rf "$SCRATCH"' EXIT
cp -r "$N/nexus-bridge/catalog" "$SCRATCH/catalog"
"$VSIDLC" -c "$SCRATCH/catalog" -o "$SCRATCH" --apex --target-api latest \
    -d "$N/nexus-sdv-sample/catalog" "$N/nexus-sdk-catalog" "$QUICKSTART"
rm -rf "$N/nexus-bridge/configs"
mkdir -p "$N/nexus-bridge/configs"
cp -r "$SCRATCH/configs/permissions" "$N/nexus-bridge/configs/permissions"
# VSIDL has no field for it: the Bridge may discover and subscribe to every publication
# (read all, experimental), the way Google's Telemetry agent declares it
# (system/software_defined_vehicle/telemetry/apex/permissions.textproto).
P="$N/nexus-bridge/configs/permissions/com.android.nexus.aaos_nexus_sdv_tcu.NexusBridge.permissions.textproto"
printf '\nallow_read_all: true\n' >> "$P"
echo "generated: $N/nexus-sdv-sample and $N/nexus-bridge/configs/permissions"
