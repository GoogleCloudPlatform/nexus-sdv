#!/usr/bin/env bash
#
# Start a bootstrap test matrix: four environments, one per shape, in sequence.
#
# Usage:
#   iac/operating/nexus-matrix.sh --project PROJECT_ID [--prefix nst1] [--dry-run]
#
# What it does, which until now was done by hand before every run:
#   1. finds the next free environment numbers
#   2. GENERATES an environment file per shape and uploads it
#   3. archives the previous run's files
#   4. submits test-environments.yaml, without --timeout
#
# Step 2 is the point. A finished bootstrap writes the CA pool names it created
# back into its environment file, and the teardown deletes the pools without
# taking the names out — so a copied file points at authorities that no longer
# exist, and the run fails late in a way that points somewhere else. Generating
# the file from its shape makes that class of failure impossible rather than
# detectable. The preflight stays as the second line.
#
# The shapes are the four combinations we care about. arm64 belongs with
# europe-west4 and amd64 with europe-west3 — the pairing that is known to work.

set -euo pipefail

GCLOUD="${GCLOUD:-$(command -v gcloud || echo /opt/homebrew/bin/gcloud)}"
[ -x "$GCLOUD" ] || { echo "gcloud not found" >&2; exit 1; }

PROJECT=""
PREFIX=""
DRY_RUN=false
MATRIX_REGION="europe-west4"   # where the matrix build itself runs

while [ $# -gt 0 ]; do
    case "$1" in
        --project) PROJECT="${2:-}"; shift 2 ;;
        --prefix)  PREFIX="${2:-}";  shift 2 ;;
        --dry-run) DRY_RUN=true;     shift ;;
        -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

[ -n "$PROJECT" ] || { echo "--project is required" >&2; exit 1; }

say() { echo -e "$*"; }

# What a run submits is the working tree, not a branch: `gcloud builds submit`
# archives the directory as it stands. Report this before anything else, and in
# a dry run too, because the commit alone can describe something other than what
# would be uploaded.
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')
COMMIT=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')
DIRTY=$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
say "Source: ${REPO_ROOT}"
say "  branch ${BRANCH}, commit ${COMMIT}"
[ "$BRANCH" != "main" ] && say "  NOTE: not on main. This run would test '${BRANCH}', not whatever main contains."
[ "${DIRTY:-0}" -gt 0 ] && say "  NOTE: ${DIRTY} uncommitted change(s) would be included; the commit above does not describe them."
say ""


BUCKET="gs://${PROJECT}-bootstrap-envs"

# The prefix continues whatever series the bucket already holds, archive
# included. Deriving it from the project name looks tidy and is wrong: it would
# silently start a second series, and Cloud SQL only reserves the names it has
# seen — a fresh series can collide with an environment torn down last week.
if [ -z "$PREFIX" ]; then
    PREFIX=$("$GCLOUD" storage ls -r "${BUCKET}/**" 2>/dev/null \
        | grep -oE '[a-z0-9]+-[0-9]+\.bootstrap_env' \
        | sed -E 's/-[0-9]+\.bootstrap_env//' | sort | uniq -c | sort -rn \
        | head -1 | awk '{print $2}' || true)
    [ -n "$PREFIX" ] || { echo "No existing environments in ${BUCKET} — pass --prefix" >&2; exit 1; }
    echo "Continuing the '${PREFIX}' series"
fi

# shape: PKI|ARCH|REGION
SHAPES=(
    "local|arm64|europe-west4"
    "remote|amd64|europe-west3"
    "remote|arm64|europe-west4"
    "local|amd64|europe-west3"
)

# --- refuse if the project is already busy ---------------------------------
# Two matrix runs in one project fight over the Terraform state, the Cloud SQL
# names and the BigTable instance, and the loser fails in a way that points
# somewhere else entirely.
BUSY=$(for r in europe-west3 europe-west4; do
    "$GCLOUD" builds list --project="$PROJECT" --region="$r" --ongoing \
        --format="value(id)" 2>/dev/null | sed "s/\$/ ($r)/"
done)
if [ -n "$BUSY" ]; then
    echo "Refusing: builds are already running in ${PROJECT}:" >&2
    echo "$BUSY" >&2
    echo "Wait for them to finish." >&2
    exit 1
fi

# --- the DNS zone, for the remote shapes -----------------------------------
# Exactly what the install skill tells a reader to do: look it up rather than
# assume. EXISTING_DNS_ZONE takes the zone's name, BASE_DOMAIN the domain it
# serves; they differ by more than punctuation. A gke-*-dns entry is the
# cluster's internal zone and is not ours.
DNS_ZONE=""
BASE_DOMAIN=""
zone_line=$("$GCLOUD" dns managed-zones list --project="$PROJECT" \
    --filter="visibility=public" --format="value(name,dnsName)" 2>/dev/null \
    | grep -v '^gke-' | head -1 || true)
if [ -n "$zone_line" ]; then
    DNS_ZONE=$(awk '{print $1}' <<<"$zone_line")
    BASE_DOMAIN=$(awk '{print $2}' <<<"$zone_line" | sed 's/\.$//')
    say "DNS zone: ${DNS_ZONE} serving ${BASE_DOMAIN}"
else
    say "No public DNS zone in ${PROJECT} — the remote shapes will be skipped."
fi

# --- next free numbers ------------------------------------------------------
# Cloud SQL keeps a deleted instance's name reserved for about a week, so a
# number is never reused. The archive counts too: those environments existed.
highest=$("$GCLOUD" storage ls -r "${BUCKET}/**" 2>/dev/null \
    | grep -oE "${PREFIX}-[0-9]+\.bootstrap_env" \
    | grep -oE '[0-9]+' | sort -n | tail -1 || true)
NEXT=$(( ${highest:-100} + 1 ))
say "Next free environment number: ${PREFIX}-${NEXT}"

# --- generate ---------------------------------------------------------------
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PLANNED=()

for shape in "${SHAPES[@]}"; do
    IFS='|' read -r pki arch region <<<"$shape"
    if [ "$pki" = remote ] && [ -z "$DNS_ZONE" ]; then
        say "  skip  ${pki}/${arch}/${region} — no DNS zone"
        continue
    fi
    env_name="${PREFIX}-${NEXT}"
    NEXT=$(( NEXT + 1 ))
    file="${TMP}/${env_name}.bootstrap_env"

    # Every EXISTING_* is empty on purpose: each bootstrap creates its own
    # authorities and its teardown removes them again. Only the DNS zone is
    # referenced, because it is delegated at a registrar and must survive.
    cat > "$file" <<EOF
GCP_PROJECT_ID="${PROJECT}"
GCP_REGION="${region}"
DEPLOY_MODE="cloudbuild"
GITHUB_REPO=""
ENV="${env_name}"
PKI_STRATEGY="${pki}"
BASE_DOMAIN="$([ "$pki" = remote ] && echo "$BASE_DOMAIN")"
EXISTING_DNS_ZONE="$([ "$pki" = remote ] && echo "$DNS_ZONE")"
KEYCLOAK_HOSTNAME="keycloak"
NATS_HOSTNAME="nats"
REGISTRATION_HOSTNAME="registration"
FLEETVIEW_HOSTNAME="fleetview"
EXISTING_SERVER_CA=""
EXISTING_SERVER_CA_POOL=""
EXISTING_FACTORY_CA=""
EXISTING_FACTORY_CA_POOL=""
EXISTING_REG_CA=""
EXISTING_REG_CA_POOL=""
ARCH="${arch}"
OPERATIONAL_CERT_VALIDITY="90d"
FACTORY_HELPER_CERT_VALIDITY_DAYS="730"
NEXT_PUBLIC_GOOGLE_MAPS_API_KEY=""
NEXT_PUBLIC_GOOGLE_MAPS_MAP_ID=""
EOF
    PLANNED+=("${env_name}  ${pki}/${arch}/${region}")
    say "  plan  ${env_name}  ${pki}/${arch}/${region}"
done

[ ${#PLANNED[@]} -gt 0 ] || { echo "Nothing to run." >&2; exit 1; }

if $DRY_RUN; then
    say ""
    say "--dry-run: files written to ${TMP} and not uploaded."
    cp -r "$TMP" "${TMP}.keep" && trap - EXIT
    say "Kept at ${TMP}.keep"
    exit 0
fi

# --- archive the previous run, upload this one ------------------------------
say ""
for old in $("$GCLOUD" storage ls "${BUCKET}/*.bootstrap_env" 2>/dev/null || true); do
    "$GCLOUD" storage mv "$old" "${BUCKET}/archive/" >/dev/null 2>&1 || true
    say "  archived $(basename "$old")"
done
for f in "$TMP"/*.bootstrap_env; do
    "$GCLOUD" storage cp "$f" "${BUCKET}/" >/dev/null 2>&1
    say "  uploaded $(basename "$f")"
done

# --- submit -----------------------------------------------------------------
# No --timeout. test-environments.yaml sets 24 hours, and a smaller value on the
# command line overrides it downwards. A run cut short mid-teardown leaves both
# Terraform state and per-environment secrets behind, and the next run inherits
# them: it plans to destroy what the state still describes, and reuses secrets
# that already have a version.
cd "$REPO_ROOT"
"$GCLOUD" builds submit . \
    --config=iac/cloudbuild/test-environments.yaml \
    --project="$PROJECT" --region="$MATRIX_REGION" --async \
    --substitutions="^::^_BOOTSTRAP_ENVS_DIR=${BUCKET}/::_PRESERVE_DNS=Y::_PRESERVE_CAS=N"
