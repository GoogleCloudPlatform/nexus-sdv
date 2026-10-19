#!/usr/bin/env bash
# Tests stage-into-aosp.sh against a fake AOSP tree — no build server needed.
# Run:  aaos/aaos-nexus-sdv-tcu/tests/stage-into-aosp.test.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../stage-into-aosp.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; failed=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { failed=$((failed+1)); echo "FAIL $1"; }

T="$WORK/aosp"; MK="$T/device/google/sdv/sdv_core_cf/sdv_core_cf.mk"
RC="$T/device/google/sdv/sdv_core_cf/init.sdv_core_cf.rc"
N="$T/vendor/nexus"
IMPORT='import /product/etc/init/nexus_connectivity_agent.rc'
LINE='PRODUCT_PRIVATE_SEPOLICY_DIRS += vendor/nexus/aaos-nexus-sdv-tcu-sepolicy'
TC_PACKAGES='PRODUCT_PACKAGES += nexus_telemetry_client.rc'
TC_IMPORT='import /product/etc/init/nexus_telemetry_client.rc'
OLD_POLICY='PRODUCT_PRIVATE_SEPOLICY_DIRS += vendor/nexus/nexus-telemetry-client/sepolicy'
mkdir -p "$(dirname "$MK")"; printf 'PRODUCT_NAME := sdv_core_cf\n' > "$MK"
printf 'import /product/etc/init/oem_partition.rc\n\non boot\n' > "$RC"
printf '#!/bin/sh\n' > "$WORK/agent"; printf '#!/bin/sh\n' > "$WORK/nats"; chmod +x "$WORK/agent" "$WORK/nats"
export NEXUS_AGENT_BIN="$WORK/agent" NEXUS_NATS_BIN="$WORK/nats"

# Stand-ins for the four build files of Google's telemetry SDK the client needs a
# min_sdk_version in (docs: aaos/nexus-telemetry-client/README.md).
SDK="$T/system/software_defined_vehicle/telemetry"; AIDL="$T/hardware/sdv/interfaces/telemetry/service/aidl"
google_files() {
    mkdir -p "$SDK/sdk/rust/client/internal" "$SDK/proto" "$AIDL"
    printf 'rust_library {\n    name: "libsdv_telemetry_rust_wrapper",\n    vendor_available: true,\n}\n' > "$SDK/sdk/rust/client/Android.bp"
    printf 'cc_library {\n    name: "libsdv_telemetry_sdk_client_internal_cc",\n    srcs: ["a.cc"],\n}\n\nrust_bindgen {\n    name: "libsdv_telemetry_sdk_client_internal_rust_bindgen",\n}\n\nrust_bindgen {\n    name: "libsdv_telemetry_sdk_client_internal_status_codes_rust_bindgen",\n}\n' > "$SDK/sdk/rust/client/internal/Android.bp"
    printf 'cc_library {\n    name: "libsdv_telemetry_proto_cpp",\n}\n\nrust_protobuf {\n    name: "libsdv_telemetry_proto_rust",\n    min_sdk_version: "35",\n}\n' > "$SDK/proto/Android.bp"
    printf 'aidl_interface {\n    name: "google.sdv.telemetry",\n    backend: {\n        rust: {\n            enabled: true,\n            min_sdk_version: "35",\n        },\n        ndk: {\n            enabled: true,\n        },\n    },\n}\n' > "$AIDL/Android.bp"
}
google_files
min_count() { grep -c 'min_sdk_version: "35"' "$1"; }
sdk_ok() {
    [ "$(min_count "$SDK/sdk/rust/client/Android.bp")" = 1 ] && [ "$(min_count "$SDK/sdk/rust/client/internal/Android.bp")" = 3 ] \
      && [ "$(min_count "$SDK/proto/Android.bp")" = 2 ] && [ "$(min_count "$AIDL/Android.bp")" = 2 ]
}
once() { [ "$(grep -cxF "$2" "$1")" = 1 ]; }

bash "$SCRIPT" "$T" >/dev/null 2>&1
[ -f "$N/aaos-nexus-sdv-tcu-sepolicy/nexus_connectivity_agent.te" ] \
  && ok "the policy directory is staged" || bad "the policy directory is staged"
[ -f "$N/aaos-nexus-sdv-tcu-sepolicy/nexus_telemetry_client.te" ] \
  && ok "the client's policy is in the one directory" || bad "the client's policy is in the one directory"
[ -x "$N/aaos-nexus-sdv-tcu/prebuilt/nexus-connectivity-agent" ] \
  && ok "the binaries are staged" || bad "the binaries are staged"
[ -f "$N/nexus-telemetry-client/Android.bp" ] && [ ! -e "$N/nexus-telemetry-client/tests" ] \
  && [ ! -e "$N/nexus-telemetry-client/core/target" ] \
  && ok "the client's sources are staged, without tests or build artefacts" || bad "the client's sources are staged, without tests or build artefacts"
[ -f "$N/common/nats_wire.rs" ] && ok "the shared sources are staged" || bad "the shared sources are staged"
once "$MK" "$LINE" && ok "the product makefile names the policy once" || bad "the product makefile names the policy once"
# The init files are in the APEX: the image names none of them.
! grep -q 'nexus_connectivity_agent.rc\|nexus_telemetry_client.rc' "$MK" "$RC" \
  && ok "the image carries no init file of ours" || bad "the image carries no init file of ours"
[ -f "$N/aaos-nexus-sdv-tcu/init/nexus_connectivity_agent.rc" ] && [ -f "$N/aaos-nexus-sdv-tcu/init/nexus_telemetry_client.rc" ] \
  && ok "the init files are staged with the APEX" || bad "the init files are staged with the APEX"
sdk_ok && ok "Google's SDK modules carry min_sdk_version" || bad "Google's SDK modules carry min_sdk_version"

bash "$SCRIPT" "$T" >/dev/null 2>&1
once "$MK" "$LINE" && ! grep -q 'nexus_.*\.rc' "$MK" "$RC" \
  && ok "staging twice adds no second line" || bad "staging twice adds no second line"
sdk_ok && ok "nor a second min_sdk_version" || bad "nor a second min_sdk_version"
grep -A2 'name: "libsdv_telemetry_proto_rust"' "$SDK/proto/Android.bp" | grep -c 'min_sdk_version' | grep -qx 1 \
  && ok "a module that already has the line is left alone" || bad "a module that already has the line is left alone"

# A tree staged before names the init files on the image; those lines go.
printf '%s\n' 'PRODUCT_PACKAGES += nexus_connectivity_agent.rc' "$TC_PACKAGES" >> "$MK"
printf '%s\n' "$IMPORT" "$TC_IMPORT" >> "$RC"
# A tree staged by the telemetry client's former script names a policy directory that is gone.
printf '%s\n' "$OLD_POLICY" >> "$MK"
mkdir -p "$N/nexus-telemetry-client/sepolicy"
bash "$SCRIPT" "$T" >/dev/null 2>&1
! grep -qxF "$OLD_POLICY" "$MK" && ok "the former policy directory's line is removed" || bad "the former policy directory's line is removed"
[ ! -e "$N/nexus-telemetry-client/sepolicy" ] && ok "and the directory itself" || bad "and the directory itself"
! grep -q 'nexus_.*\.rc' "$MK" "$RC" && grep -qxF 'import /product/etc/init/oem_partition.rc' "$RC" \
  && ok "the earlier init lines are removed, Google's stay" || bad "the earlier init lines are removed, Google's stay"

# The package without the nexus-connectivity-agent's sources beside it, binaries given.
mkdir -p "$WORK/pkg"
for d in aaos-nexus-sdv-tcu aaos-nexus-sdv-tcu-sepolicy nexus-telemetry-client common; do cp -R "$HERE/../../$d" "$WORK/pkg/"; done
bash "$WORK/pkg/aaos-nexus-sdv-tcu/stage-into-aosp.sh" "$T" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "given binaries need no sources beside the package" || bad "given binaries need no sources beside the package (exit $rc)"

# A tree whose SDK Google has reorganised is refused, by name.
sed -i.bak 's/libsdv_telemetry_rust_wrapper/libsdv_telemetry_wrapper_renamed/' "$SDK/sdk/rust/client/Android.bp"
out="$(bash "$SCRIPT" "$T" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'libsdv_telemetry_rust_wrapper' \
  && ok "a missing SDK module is refused and named" || bad "a missing SDK module is refused and named"
google_files

rm -f "$MK"
bash "$SCRIPT" "$T" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "a tree without the product makefile is refused" || bad "a tree without the product makefile is refused"

echo "$pass passed, $failed failed"; [ "$failed" -eq 0 ]
