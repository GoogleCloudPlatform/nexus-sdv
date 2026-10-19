#!/usr/bin/env bash
# Copies the Nexus-Bridge APEX module — nexus-connectivity-agent, nats-server, the Bridge and
# the nexus-telemetry-client — and its product policy into an AOSP tree so Soong can build
# them, and gives Google's telemetry SDK the min_sdk_version an updatable APEX asks of what
# it links (set-sdk-min-sdk-version.py beside the client).
# Usage: ./stage-into-aosp.sh <aosp-root> [module-parent=vendor/nexus]
set -euo pipefail
AOSP="$1"; PARENT="${2:-vendor/nexus}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$AOSP/$PARENT/aaos-nexus-sdv-tcu"

# NEXUS_AGENT_BIN / NEXUS_NATS_BIN name the binaries when the sources are not beside this
# package, e.g. on a build server that gets only the built nexus-connectivity-agent.
AGENT_BIN="${NEXUS_AGENT_BIN:-$SRC/../nexus-connectivity-agent/target/x86_64-unknown-linux-musl/release/nexus-connectivity-agent}"
NATS_BIN="${NEXUS_NATS_BIN:-$SRC/prebuilt-nats-server}"
PRODUCT_MK="$AOSP/device/google/sdv/sdv_core_cf/sdv_core_cf.mk"
POLICY_LINE="PRODUCT_PRIVATE_SEPOLICY_DIRS += $PARENT/aaos-nexus-sdv-tcu-sepolicy"
[ -f "$PRODUCT_MK" ] || { echo "missing $PRODUCT_MK — is this an sdv_core_cf tree?" >&2; exit 1; }
# The init files are in the APEX; a tree staged before names them in Google's files, and
# those lines are removed.
CORE_RC="$AOSP/device/google/sdv/sdv_core_cf/init.sdv_core_cf.rc"
[ -f "$CORE_RC" ] || { echo "missing $CORE_RC — is this an sdv_core_cf tree?" >&2; exit 1; }
[ -x "$AGENT_BIN" ] || { echo "missing $AGENT_BIN — cargo build --release --target x86_64-unknown-linux-musl" >&2; exit 1; }
[ -x "$NATS_BIN" ] || { echo "missing $NATS_BIN — run ./fetch-nats-server.sh first" >&2; exit 1; }

rsync -a --delete --exclude 'prebuilt-nats-server' "$SRC/" "$DEST/"
mkdir -p "$DEST/prebuilt"
cp "$AGENT_BIN" "$DEST/prebuilt/nexus-connectivity-agent"
cp "$NATS_BIN" "$DEST/prebuilt/nats-server"

# Product policy for the two daemons (spec R6): beside the APEX, and named once in the
# product makefile, the way Google names its own (sdv_core_cf.mk:101).
mkdir -p "$AOSP/$PARENT/aaos-nexus-sdv-tcu-sepolicy"
rsync -a --delete "$SRC/../aaos-nexus-sdv-tcu-sepolicy/" "$AOSP/$PARENT/aaos-nexus-sdv-tcu-sepolicy/"
grep -qxF "$POLICY_LINE" "$PRODUCT_MK" \
  || printf '\n# Nexus TCU daemons (spec R6)\n%s\n' "$POLICY_LINE" >> "$PRODUCT_MK"
# The nexus-telemetry-client, built into this APEX, and the sources it shares.
python3 "$SRC/../nexus-telemetry-client/set-sdk-min-sdk-version.py" "$AOSP"
mkdir -p "$AOSP/$PARENT/nexus-telemetry-client" "$AOSP/$PARENT/common"
rsync -a --delete --exclude 'core/target' --exclude 'core/Cargo.lock' --exclude 'tests' \
  "$SRC/../nexus-telemetry-client/" "$AOSP/$PARENT/nexus-telemetry-client/"
rsync -a --delete "$SRC/../common/" "$AOSP/$PARENT/common/"
# A tree staged when the client had an APEX of its own names its former policy directory.
OLD_POLICY_LINE="PRODUCT_PRIVATE_SEPOLICY_DIRS += $PARENT/nexus-telemetry-client/sepolicy"
if grep -qxF "$OLD_POLICY_LINE" "$PRODUCT_MK"; then
    grep -vxF "$OLD_POLICY_LINE" "$PRODUCT_MK" > "$PRODUCT_MK.tmp" && mv "$PRODUCT_MK.tmp" "$PRODUCT_MK"
fi
for f in "$PRODUCT_MK" "$CORE_RC"; do
    for old in "PRODUCT_PACKAGES += nexus_connectivity_agent.rc" "PRODUCT_PACKAGES += nexus_telemetry_client.rc" \
               "import /product/etc/init/nexus_connectivity_agent.rc" "import /product/etc/init/nexus_telemetry_client.rc" \
               "# Nexus TCU: the nexus-connectivity-agent service (vendor/nexus/aaos-nexus-sdv-tcu-sepolicy)"; do
        if grep -qxF "$old" "$f"; then grep -vxF "$old" "$f" > "$f.tmp" && mv "$f.tmp" "$f"; fi
    done
done

echo "Staged to $DEST and the policy to $AOSP/$PARENT/aaos-nexus-sdv-tcu-sepolicy."
echo "The policy is part of the image: build the APEX and then the image (m). Build with:"
echo "  cd $AOSP && source build/envsetup.sh && lunch sdv_core_cf-trunk_staging-userdebug && m com.android.nexus.aaos_nexus_sdv_tcu"
