#!/bin/bash
# dependabot-public-report.sh — which Dependabot pull requests on the public
# repository will the next release sync resolve?
#
# The public repository is a bit-for-bit mirror of our main
# (release-to-gcpgithub.sh), so its Dependabot pull requests can never be merged
# there. Dependabot closes them itself once the default branch carries the
# dependency at or above the proposed version ("Looks like X is up-to-date now").
# This report compares every open Dependabot pull request with our main, so the
# missing updates can be applied here first — the sync then clears them.
#
# Read-only. Needs gh (read access to the public repository), git and python3.
#
# Usage: dependabot-public-report.sh [--repo OWNER/NAME] [--ref GIT_REF]
#   --repo  default GoogleCloudPlatform/nexus-sdv
#   --ref   default origin/main (fetched first)
set -euo pipefail

REPO="GoogleCloudPlatform/nexus-sdv"
REF="origin/main"
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="${2:?--repo needs a value}"; shift 2 ;;
        --ref)  REF="${2:?--ref needs a value}"; shift 2 ;;
        -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
for tool in gh git python3; do
    command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 1; }
done

cd "$(git rev-parse --show-toplevel)"
if [ "$REF" = "origin/main" ]; then git fetch origin main -q; fi

PRS=$(mktemp); trap 'rm -f "$PRS"' EXIT
gh pr list --repo "$REPO" --state open --author app/dependabot --limit 200 \
    --json number,title,body > "$PRS"

REF="$REF" python3 - "$PRS" <<'PY'
import json, os, re, subprocess, sys

ref = os.environ["REF"]
prs = json.load(open(sys.argv[1]))

def show(path):
    r = subprocess.run(["git", "show", f"{ref}:{path}"], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None

def vt(version):
    return tuple(int(x) if x.isdigit() else 0 for x in re.split(r"[.\-+]", version.lstrip("v")))

def resolved(pkg, directory):
    """Every version of pkg resolved in that directory's manifest; None without a manifest."""
    d = directory.strip("/")
    gomod = show(f"{d}/go.mod")
    if gomod is not None:
        return re.findall(rf"^\s*(?:require\s+)?{re.escape(pkg)}\s+(v\S+)", gomod, re.M)
    lock = show(f"{d}/package-lock.json")
    if lock is not None:
        packages = json.loads(lock).get("packages", {})
        return [v["version"] for k, v in packages.items()
                if k.split("node_modules/")[-1] == pkg and "version" in v]
    for name in ("uv.lock", "Cargo.lock"):
        text = show(f"{d}/{name}")
        if text is not None:
            return re.findall(rf'^name = "{re.escape(pkg)}"\nversion = "([^"]+)"', text, re.M | re.I)
    return None

def verdict(pkg, target, directory):
    found = resolved(pkg, directory)
    if found is None:
        return "unknown", f"no manifest in {directory}"
    # A package can be installed several times at different majors (nested npm
    # copies); only the copies on the target's major line are comparable.
    comparable = [v for v in found if vt(v)[:1] == vt(target)[:1]]
    if not comparable:
        # No copy on the target's major line: a major upgrade if everything
        # installed is older, already beyond it if everything is newer.
        if found and max(vt(v) for v in found) < vt(target):
            return "pending", f"{pkg} {max(found, key=vt)} → {target} (major upgrade)"
        if found and min(vt(v) for v in found) > vt(target):
            return "satisfied", f"{pkg} {min(found, key=vt)} ≥ {target}"
        return "unknown", f"{pkg} {target}: not found (installed: {', '.join(found) or 'none'})"
    lowest = min(comparable, key=vt)
    return ("satisfied" if vt(lowest) >= vt(target) else "pending"), f"{pkg} {lowest} → {target}"

groups = {"satisfied": [], "pending": [], "unknown": []}
for pr in sorted(prs, key=lambda p: p["number"]):
    title = pr["title"]
    where = re.search(r" in (\S+)$", title)
    directory = where.group(1) if where else "/"
    single = re.match(r"^Bump (\S+) from \S+ to (\S+) in \S+$", title)
    # Grouped pull requests name no versions in the title; the body lists them.
    updates = [single.groups()] if single else re.findall(r"Updates `([^`]+)` from \S+ to (\S+)", pr["body"] or "")
    if not updates:
        groups["unknown"].append(f"#{pr['number']}  {title}  (no versions found)")
        continue
    results = [verdict(pkg, target, directory) for pkg, target in updates]
    kinds = {kind for kind, _ in results}
    kind = "unknown" if "unknown" in kinds else "pending" if "pending" in kinds else "satisfied"
    groups[kind].append(f"#{pr['number']}  {'; '.join(text for _, text in results)}  in {directory}")

labels = {
    "satisfied": f"Resolved on {ref} — Dependabot closes these after the next sync",
    "pending":   "Still to update here before the sync",
    "unknown":   "Could not be decided automatically — check by hand",
}
for kind in ("satisfied", "pending", "unknown"):
    print(f"\n=== {labels[kind]}: {len(groups[kind])} ===")
    for line in groups[kind]:
        print("  " + line)
print(f"\n{len(prs)} open Dependabot pull requests on the public repository.")
PY
