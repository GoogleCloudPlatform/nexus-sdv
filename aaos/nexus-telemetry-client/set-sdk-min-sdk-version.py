#!/usr/bin/env python3
"""Gives the modules of Google's telemetry SDK the min_sdk_version an updatable APEX asks
of everything it links. Google's answer to our open question 9 (2026-10-09): the libraries
lack it, and an integrator may set it in the tree.

  set-sdk-min-sdk-version.py <aosp-root>

Each line is added once, by module name. A module that already has one is left alone; a
module that is not where this script expects it stops the run before any file is written,
because a tree Google has reorganised must not be patched blindly.
"""
import re
import sys

LINE = 'min_sdk_version: "35",'
SDK = "system/software_defined_vehicle/telemetry"
# file -> the modules in it that the client's APEX pulls in
MODULES = {
    f"{SDK}/sdk/rust/client/Android.bp": ["libsdv_telemetry_rust_wrapper"],
    f"{SDK}/sdk/rust/client/internal/Android.bp": [
        "libsdv_telemetry_sdk_client_internal_cc",
        "libsdv_telemetry_sdk_client_internal_rust_bindgen",
        "libsdv_telemetry_sdk_client_internal_status_codes_rust_bindgen",
    ],
    f"{SDK}/proto/Android.bp": ["libsdv_telemetry_proto_cpp"],
}
# The telemetry interface: its ndk backend, inside the aidl_interface of this name.
AIDL_FILE = "hardware/sdv/interfaces/telemetry/service/aidl/Android.bp"
AIDL_NAME = "google.sdv.telemetry"


def block_end(src, start):
    """The index of the line that closes the module a `name:` line at `start` belongs to."""
    # From one character back: a module whose last line is its name closes right here.
    end = src.find("\n}\n", start - 1)
    return len(src) if end < 0 else end


def with_module_line(src, module):
    m = re.search(r'^([ \t]*)name:\s*"%s",\n' % re.escape(module), src, re.M)
    if not m:
        return None
    if "min_sdk_version" in src[m.end():block_end(src, m.end())]:
        return src
    return src[:m.end()] + m.group(1) + LINE + "\n" + src[m.end():]


def with_ndk_line(src):
    m = re.search(r'^[ \t]*name:\s*"%s",\n' % re.escape(AIDL_NAME), src, re.M)
    if not m:
        return None
    end = block_end(src, m.end())
    n = re.compile(r'^([ \t]*)ndk:\s*\{\n', re.M).search(src, m.end(), end)
    if not n:
        return None
    close = src.find("}", n.end())
    if "min_sdk_version" in src[n.end():close]:
        return src
    return src[:n.end()] + n.group(1) + "    " + LINE + "\n" + src[n.end():]


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: set-sdk-min-sdk-version.py <aosp-root>")
    root = sys.argv[1]
    changed, missing = {}, []
    for rel, modules in MODULES.items():
        try:
            src = open(f"{root}/{rel}").read()
        except OSError:
            missing.append(f"{rel} (file)")
            continue
        for module in modules:
            out = with_module_line(src, module)
            if out is None:
                missing.append(f"{module} in {rel}")
            else:
                src = out
        changed[rel] = src
    try:
        src = open(f"{root}/{AIDL_FILE}").read()
        out = with_ndk_line(src)
        if out is None:
            missing.append(f"the ndk backend of {AIDL_NAME} in {AIDL_FILE}")
        else:
            changed[AIDL_FILE] = out
    except OSError:
        missing.append(f"{AIDL_FILE} (file)")
    if missing:
        sys.exit("Google's telemetry SDK is not where this script expects it; nothing was changed. Not found: "
                 + "; ".join(missing))
    for rel, src in changed.items():
        path = f"{root}/{rel}"
        if open(path).read() != src:
            open(path, "w").write(src)
            print(f"min_sdk_version set in {rel}")


if __name__ == "__main__":
    main()
