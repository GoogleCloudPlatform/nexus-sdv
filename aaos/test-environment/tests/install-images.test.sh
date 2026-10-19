#!/usr/bin/env bash
# Tests install-images.sh against stand-ins for the bake step and for reading an image's
# baked boot configuration — no Cuttlefish host needed.
# Run:  aaos/test-environment/tests/install-images.test.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../install-images.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; failed=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { failed=$((failed+1)); echo "FAIL $1"; [ -n "${2:-}" ] && echo "     $2"; }

# Stand-ins: the bake records what it was asked to bake; the reader prints the lines an
# existing image carries (from a fixture file in that image directory).
printf '#!/bin/sh\necho "$1|$2" >> "$BAKE_LOG"\n' > "$WORK/bake"
printf '#!/bin/sh\ncat "$1/baked-lines" 2>/dev/null\n' > "$WORK/read-bootconfig"
chmod +x "$WORK/bake" "$WORK/read-bootconfig"

setup() {
    rm -rf "$WORK/images" "$WORK/new" "$WORK/bake.log"
    mkdir -p "$WORK/images/core" "$WORK/images/core3" "$WORK/new"
    for i in core core3; do
        echo "old-$i" > "$WORK/images/$i/super.img"
        echo "empty-$i" > "$WORK/images/$i/super_empty.img"
        printf 'config=old\n' > "$WORK/images/$i/android-info.txt"
    done
    printf 'androidboot.sdv.instance_name=instance2\nandroidboot.virt.address=4\n' > "$WORK/images/core/baked-lines"
    printf 'androidboot.sdv.instance_name=instance3\nandroidboot.virt.address=5\n' > "$WORK/images/core3/baked-lines"
    echo "new" > "$WORK/new/super.img"; echo "vb" > "$WORK/new/vendor_boot.img"
    printf 'config=sdv_core_instance1\nother=1\n' > "$WORK/new/android-info.txt"
}
run() {
    NEXUS_IMAGES_ROOT="$WORK/images" NEXUS_BAKE_CMD="$WORK/bake" NEXUS_BOOTCONFIG_CMD="$WORK/read-bootconfig" \
        BAKE_LOG="$WORK/bake.log" bash "$SCRIPT" "$@" > "$WORK/out" 2>&1
}

setup
run "$WORK/new" "core=sdv_core_instance2,androidboot.nexus.leaf=192.168.98.5:4222" "core3=sdv_core_instance3"; rc=$?
[ "$rc" -eq 0 ] && ok "two instances are installed" || bad "two instances are installed" "$(cat "$WORK/out")"
[ "$(cat "$WORK/images/core/super.img")" = new ] && ok "the instance holds the new image" || bad "the instance holds the new image"
prev="$(ls -d "$WORK"/images/core.prev-* 2>/dev/null | head -1)"
[ -n "$prev" ] && [ "$(cat "$prev/super.img")" = old-core ] && ok "the previous set is kept" || bad "the previous set is kept"
grep -qx 'config=sdv_core_instance2' "$WORK/images/core/android-info.txt" && grep -qx 'other=1' "$WORK/images/core/android-info.txt" \
  && ok "android-info.txt carries the instance's preset and keeps its other lines" || bad "android-info.txt carries the instance's preset and keeps its other lines"
grep -qx 'config=sdv_core_instance1' "$WORK/images/core/android-info.txt.orig" && ok "the original android-info.txt is kept beside it" || bad "the original android-info.txt is kept beside it"
[ "$(cat "$WORK/images/core/super_empty.img")" = empty-core ] && ok "super_empty.img comes from the previous set when the new one has none" || bad "super_empty.img comes from the previous set when the new one has none"
grep -q 'core.new|androidboot.sdv.instance_name=instance2 androidboot.virt.address=4 androidboot.nexus.leaf=192.168.98.5:4222$' "$WORK/bake.log" \
  && ok "the bake gets the instance's lines followed by the extra one" || bad "the bake gets the instance's lines followed by the extra one" "$(cat "$WORK/bake.log")"
grep -q 'core3.new|androidboot.sdv.instance_name=instance3 androidboot.virt.address=5$' "$WORK/bake.log" \
  && ok "an instance without extra lines gets only its own" || bad "an instance without extra lines gets only its own" "$(cat "$WORK/bake.log")"

# An extra line the image already carries is not baked twice.
setup; echo 'androidboot.nexus.leaf=192.168.98.5:4222' >> "$WORK/images/core/baked-lines"
run "$WORK/new" "core=sdv_core_instance2,androidboot.nexus.leaf=192.168.98.5:4222"
[ "$(grep -o 'androidboot.nexus.leaf' "$WORK/bake.log" | wc -l | tr -d ' ')" = 1 ] && ok "a line already baked is not added twice" || bad "a line already baked is not added twice" "$(cat "$WORK/bake.log")"

# A changed value replaces the old one rather than standing beside it.
setup; echo 'androidboot.nexus.leaf=10.0.0.1:4222' >> "$WORK/images/core/baked-lines"
run "$WORK/new" "core=sdv_core_instance2,androidboot.nexus.leaf=192.168.98.5:4222"
grep -q '10.0.0.1' "$WORK/bake.log" && bad "a new value replaces the old one" "$(cat "$WORK/bake.log")" || ok "a new value replaces the old one"

# An unknown instance is refused before anything is moved.
setup
run "$WORK/new" "core=sdv_core_instance2" "nope=sdv_core_instance9"; rc=$?
[ "$rc" -ne 0 ] && [ "$(cat "$WORK/images/core/super.img")" = old-core ] && [ -z "$(ls -d "$WORK"/images/*.prev-* 2>/dev/null)" ] \
  && ok "an unknown instance is refused and nothing is touched" || bad "an unknown instance is refused and nothing is touched" "$(cat "$WORK/out")"

# An instance whose current image carries no baked lines is refused: there is nothing to keep its identity from.
setup; : > "$WORK/images/core3/baked-lines"
run "$WORK/new" "core3=sdv_core_instance3"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'no baked boot configuration' "$WORK/out" && ok "an instance without baked lines is refused" || bad "an instance without baked lines is refused" "$(cat "$WORK/out")"

echo "$pass passed, $failed failed"; [ "$failed" -eq 0 ]
