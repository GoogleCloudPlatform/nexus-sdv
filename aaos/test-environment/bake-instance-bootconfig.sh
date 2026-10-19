#!/usr/bin/env bash
# Bake per-instance SDV bootconfig into an image's vendor_boot.img so the guest
# reads virt.address / instance identity at boot without launch_cvd's broken
# per-instance --extra_bootconfig_args (issue #365, L6a). Idempotent: always
# rebakes from the preserved .orig.
# Usage: bake-instance-bootconfig.sh <image-dir> "<space-separated extra bootconfig args>"
set -euo pipefail
IMG_DIR="$1"; EXTRA="$2"
BIN=/opt/cvd-host-sdv/bin
VB="$IMG_DIR/vendor_boot.img"

[ -f "$VB" ] || { echo "no vendor_boot.img in $IMG_DIR" >&2; exit 1; }
[ -f "$VB.orig" ] || cp -f "$VB" "$VB.orig"   # preserve the pristine image once

PART_SIZE=$(stat -c %s "$VB.orig")            # vendor_boot partition size = original file size
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 1. Unpack the pristine image and capture the exact mkbootimg args to reconstruct it.
"$BIN/unpack_bootimg" --boot_img "$VB.orig" --out "$WORK" --format mkbootimg > "$WORK/mkargs"

# 2. Append the per-instance args to the bootconfig section (one arg per line).
[ -f "$WORK/bootconfig" ] || : > "$WORK/bootconfig"
printf '%s\n' $EXTRA >> "$WORK/bootconfig"

# 2b. unpack_bootimg only emits --vendor_bootconfig in mkargs if the original
# image already had a bootconfig section. If it didn't, the appended
# bootconfig above would silently be dropped on repack; force the arg in.
grep -q -- '--vendor_bootconfig' "$WORK/mkargs" || \
    printf ' --vendor_bootconfig "%s/bootconfig"' "$WORK" >> "$WORK/mkargs"

# 3. Repack from $WORK (mkargs paths are relative to the unpack dir).
# mkargs is shell-quoted (e.g. --vendor_cmdline '...many words...'); eval it so
# the quoting is honored instead of being word-split by command substitution.
( cd "$WORK" && eval "\"$BIN/mkbootimg\" $(cat mkargs) --vendor_boot \"$WORK/vendor_boot.repacked\"" )

# 4. Re-add the AVB hash footer, sized to the original partition.
"$BIN/avbtool" add_hash_footer --image "$WORK/vendor_boot.repacked" \
    --partition_name vendor_boot --partition_size "$PART_SIZE"

# 5. Install.
cp -f "$WORK/vendor_boot.repacked" "$VB"

# 6. Verify the bake actually landed: re-unpack the installed image and confirm
# every appended token is present in its bootconfig. If not, restore the
# pristine image rather than leaving a partially-baked one in place.
mkdir -p "$WORK/verify"
"$BIN/unpack_bootimg" --boot_img "$VB" --out "$WORK/verify" > /dev/null
for token in $EXTRA; do
    grep -qF -- "$token" "$WORK/verify/bootconfig" || {
        echo "bake verification failed for $IMG_DIR: [$token] missing from repacked bootconfig" >&2
        cp -f "$VB.orig" "$VB"
        exit 1
    }
done

echo "baked $IMG_DIR: appended [$EXTRA]"
