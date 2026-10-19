#!/usr/bin/env bash
# Installs a freshly built image set for some of the mesh's instances, each baked with its
# own boot configuration. Runs on the Cuttlefish host, before the mesh is launched.
#
#   install-images.sh <new-image-dir> <instance>=<preset>[,<extra line>...] ...
#
#   <new-image-dir>  the *.img files and android-info.txt of one build
#   <instance>       a directory under /opt/sdv-images (NEXUS_IMAGES_ROOT), e.g. core
#   <preset>         the Cuttlefish preset the instance launches with, e.g. sdv_core_instance2
#   <extra line>     a boot-configuration line to add for this instance, e.g.
#                    androidboot.nexus.leaf=192.168.98.5:4222 — where the Nexus leaf is, for
#                    every VM that runs the nexus-telemetry-client (see mesh.md)
#
# Each instance keeps the lines its current image carries (its name, its address in the
# vehicle network, its keys): they are read from the current image and baked into the new
# one, followed by the extra lines. A line with the same key replaces the old one. The
# previous image set stays beside the new one as <instance>.prev-<date>.
#
# Not done here: launching the mesh, the host's forwarding rules and the guest's default
# route (mesh.md).
set -euo pipefail
NEW="${1:?usage: install-images.sh <new-image-dir> <instance>=<preset>[,<extra line>...] ...}"
shift
[ $# -gt 0 ] || { echo "name at least one instance=preset" >&2; exit 1; }
ROOT="${NEXUS_IMAGES_ROOT:-/opt/sdv-images}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAKE="${NEXUS_BAKE_CMD:-$HERE/bake-instance-bootconfig.sh}"
CVD_BIN="${NEXUS_CVD_BIN:-/opt/cvd-host-sdv/bin}"
STAMP="$(date +%Y%m%d-%H%M%S)"

# The boot-configuration lines baked into an image directory beyond its pristine
# vendor_boot.img.orig, one per line.
baked_lines() {
    if [ -n "${NEXUS_BOOTCONFIG_CMD:-}" ]; then "$NEXUS_BOOTCONFIG_CMD" "$1"; return; fi
    local t; t="$(mktemp -d)"
    "$CVD_BIN/unpack_bootimg" --boot_img "$1/vendor_boot.img.orig" --out "$t/o" >/dev/null
    "$CVD_BIN/unpack_bootimg" --boot_img "$1/vendor_boot.img" --out "$t/n" >/dev/null
    # diff exits 1 when the files differ, which is the point here.
    { diff <(cat "$t/o/bootconfig" 2>/dev/null) "$t/n/bootconfig" || true; } | sed -n 's/^> //p'
    rm -rf "$t"
}

# Everything is checked before anything is moved.
[ -f "$NEW/android-info.txt" ] || { echo "no android-info.txt in $NEW" >&2; exit 1; }
for spec in "$@"; do
    instance="${spec%%=*}"; rest="${spec#*=}"
    [ "$instance" != "$spec" ] && [ -n "${rest%%,*}" ] || { echo "not <instance>=<preset>: $spec" >&2; exit 1; }
    [ -d "$ROOT/$instance" ] || { echo "no instance directory $ROOT/$instance" >&2; exit 1; }
    [ -n "$(baked_lines "$ROOT/$instance")" ] \
      || { echo "no baked boot configuration found in $ROOT/$instance — nothing to keep its identity from" >&2; exit 1; }
done

for spec in "$@"; do
    instance="${spec%%=*}"; rest="${spec#*=}"
    preset="${rest%%,*}"
    extra=""; [ "$rest" != "$preset" ] && extra="${rest#*,}"

    # The instance's own lines, without those an extra line replaces; then the extra ones.
    lines="$(baked_lines "$ROOT/$instance")"
    for e in ${extra//,/ }; do
        lines="$(printf '%s\n' "$lines" | grep -v "^${e%%=*}=" || true)"
    done
    all="$(printf '%s\n' $lines ${extra//,/ } | tr '\n' ' ')"
    all="${all% }"

    stage="$ROOT/$instance.new"
    rm -rf "$stage"; mkdir -p "$stage"
    cp "$NEW"/*.img "$NEW/android-info.txt" "$stage/"
    # Left out of a transfer when it is unreadable on the build server; the partition layout
    # does not change between builds of the same product.
    [ -f "$stage/super_empty.img" ] || cp "$ROOT/$instance/super_empty.img" "$stage/"
    cp "$stage/android-info.txt" "$stage/android-info.txt.orig"
    sed "s/^config=.*/config=$preset/" "$stage/android-info.txt.orig" > "$stage/android-info.txt"
    "$BAKE" "$stage" "$all"

    owner="$(stat -c '%U:%G' "$ROOT/$instance" 2>/dev/null || stat -f '%Su:%Sg' "$ROOT/$instance")"
    mv "$ROOT/$instance" "$ROOT/$instance.prev-$STAMP"
    mv "$stage" "$ROOT/$instance"
    chown -R "$owner" "$ROOT/$instance" 2>/dev/null || true
    echo "installed $instance as $preset (previous kept as $instance.prev-$STAMP)"
done
