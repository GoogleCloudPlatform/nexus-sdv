#!/bin/bash
# ==============================================================================
# Nexus Preflight — can a Nexus platform be bootstrapped into this project?
#
# The companion to nexus-scan-gcp.sh, which answers the opposite question: that
# one reports whether Nexus IS deployed here, this one whether it CAN be.
# Written for a fresh Google Cloud project, and for the agent frameworks that
# are expected to install Nexus into one.
#
# STRICTLY READ-ONLY. Every call below is a describe, a list or a permission
# test. Nothing here creates, enables, updates or deletes — a preflight that
# changed the thing it inspects would be worthless.
#
# Usage:
#   iac/operating/nexus-preflight.sh                        # current gcloud project
#   iac/operating/nexus-preflight.sh PROJECT_ID
#   iac/operating/nexus-preflight.sh PROJECT_ID --region europe-west4 --pki remote
#   iac/operating/nexus-preflight.sh PROJECT_ID --json
#   iac/operating/nexus-preflight.sh PROJECT_ID --require-clean  # leftovers block
#
# Exit status:
#   0  ready — nothing blocks a bootstrap
#   1  blocked — at least one FAIL; fix it before bootstrapping
#   2  ready with reservations — WARN or UNKNOWN only
#
# --require-clean is for automation, and escalates exactly the three checks that
# mean "an earlier run left something behind": occupancy, leftover secrets and
# leftover Terraform state. It deliberately does not escalate the rest. Two
# warnings are permanent facts rather than leftovers — no Cloud Build GitHub
# connection (which the submit path does not need) and DNS delegation (which
# cannot be checked from inside the project) — and a flag that blocked on those
# would refuse every run forever.
#
# Verdicts:
#   OK       checked, fine
#   WARN     worth a look, does not block
#   FAIL     a bootstrap will not succeed until this is resolved
#   UNKNOWN  could not be determined, usually a missing read permission —
#            reported as such rather than guessed, because a preflight that
#            reports OK on a failed check is worse than no preflight
#
# The same three gcloud traps nexus-scan-gcp.sh documents apply here and are
# handled the same way: no GNU `timeout` on macOS, a disabled API prompting on
# stdin, and regional resources returning an empty list for the wrong region.
# ==============================================================================

set -uo pipefail

GCLOUD="$(command -v gcloud || echo /opt/homebrew/bin/gcloud)"
[ -x "$GCLOUD" ] || { echo "gcloud not found" >&2; exit 1; }

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/nexus-policy.sh"

JSON=false
REQUIRE_CLEAN=false
PROJECT=""
REGION=""
PKI="remote"          # the stricter of the two: it checks DNS and the CA API
for ((i = 1; i <= $#; i++)); do
    case "${!i}" in
        --json)   JSON=true ;;
        --region) i=$((i + 1)); REGION="${!i:-}" ;;
        --pki)    i=$((i + 1)); PKI="${!i:-}" ;;
        --require-clean) REQUIRE_CLEAN=true ;;
        -h|--help) sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "Unknown option: ${!i}" >&2; exit 1 ;;
        *)  PROJECT="${!i}" ;;
    esac
done

case "$PKI" in local|remote) ;; *) echo "--pki must be local or remote" >&2; exit 1 ;; esac

[ -n "$PROJECT" ] || PROJECT="$("$GCLOUD" config get-value project 2>/dev/null)"
[ -n "$PROJECT" ] && [ "$PROJECT" != "(unset)" ] || {
    echo "No project given and no gcloud default project set." >&2; exit 1; }

# The policy exists to stop a cleanup, but a bootstrap into someone else's
# project is just as unwelcome. Refuse before making a single call.
if grep -q "^${PROJECT}|" <<<"${BLOCKED_PROJECTS}"; then
    reason=$(grep "^${PROJECT}|" <<<"${BLOCKED_PROJECTS}" | cut -d'|' -f2-)
    echo "REFUSED: ${PROJECT} is on the do-not-touch list (${reason})" >&2
    exit 1
fi

C_G='\033[0;32m'; C_Y='\033[1;33m'; C_R='\033[0;31m'; C_B='\033[0;34m'; C_N='\033[0m'
say() { $JSON || echo -e "$@"; }

# See nexus-scan-gcp.sh for why results come back in G_OUT rather than on
# stdout: command substitution runs in a subshell, so a status set inside one
# would never reach the caller.
LAST_STATUS=ok
G_OUT=""
g() {
    local out rc
    out=$("$GCLOUD" "$@" </dev/null 2>&1); rc=$?
    G_OUT=""
    if grep -qi 'has not been used\|SERVICE_DISABLED\|not enabled' <<<"$out"; then
        LAST_STATUS=api-off; return
    elif grep -qi 'PERMISSION_DENIED\|does not have permission\|Permission denied' <<<"$out"; then
        LAST_STATUS=denied; return
    elif [ "$rc" -ne 0 ] || grep -qi '^ERROR\|was not found' <<<"$out"; then
        LAST_STATUS=error; return
    fi
    LAST_STATUS=ok
    G_OUT="$out"
}

FAILS=0; WARNS=0; UNKNOWNS=0
ROWS=()
result() {   # result <verdict> <check> <detail>
    local v="$1" check="$2" detail="$3" colour
    # Under --require-clean a leftover is not a judgement call, so these three
    # become blocking. The other warnings are standing facts, not dirt.
    if $REQUIRE_CLEAN && [ "$v" = WARN ]; then
        case "$check" in
            # Leftover secrets are deliberately absent: the caller clears them
            # right afterwards, so blocking on them would stop a run that is
            # about to fix the very thing it stopped for.
            "project is empty"|"no leftover Terraform state") v=FAIL; detail="$detail [--require-clean]" ;;
        esac
    fi
    case "$v" in
        OK)      colour="$C_G"; ;;
        WARN)    colour="$C_Y"; WARNS=$((WARNS + 1)) ;;
        FAIL)    colour="$C_R"; FAILS=$((FAILS + 1)) ;;
        UNKNOWN) colour="$C_B"; UNKNOWNS=$((UNKNOWNS + 1)) ;;
    esac
    say "  ${colour}$(printf '%-8s' "$v")${C_N} $(printf '%-34s' "$check") $detail"
    ROWS+=("$(printf '{"verdict":"%s","check":"%s","detail":"%s"}' "$v" "$check" "${detail//\"/\'}")")
}

say "${C_B}=== Nexus preflight: ${PROJECT} (pki=${PKI}${REGION:+, region=$REGION}) ===${C_N}"
say ""

# ------------------------------------------------------------------ identity
ACCOUNT=$("$GCLOUD" config get-value account 2>/dev/null)
if [ -z "$ACCOUNT" ] || [ "$ACCOUNT" = "(unset)" ]; then
    result FAIL "authenticated" "no active gcloud account — run: gcloud auth login"
else
    result OK "authenticated" "$ACCOUNT"
fi

# Terraform uses Application Default Credentials, not the gcloud account, and a
# bootstrap that gets this far and then fails on ADC wastes the whole run.
if [ -f "${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/application_default_credentials.json" ]; then
    result OK "application-default credentials" "present"
else
    result WARN "application-default credentials" "absent — run: gcloud auth application-default login"
fi

# ------------------------------------------------------------- local tooling
# The cloud-native path deliberately needs very little locally: Terraform, nk
# and openssl run inside Cloud Build, not here. That is the difference from the
# script-driven install, and it is worth reporting rather than assuming.
for tool in git curl; do
    if command -v "$tool" >/dev/null 2>&1; then
        result OK "$tool" "$(command -v "$tool")"
    else
        result FAIL "$tool" "not installed — needed to check permissions and to fetch the repository"
    fi
done
if command -v kubectl >/dev/null 2>&1; then
    result OK "kubectl" "$(command -v kubectl)"
else
    result WARN "kubectl" "not installed — only needed to operate a platform, not to install one"
fi

g projects describe "$PROJECT" --format="value(projectId)"
case "$LAST_STATUS" in
    ok)     result OK      "project reachable" "$PROJECT" ;;
    denied) result FAIL    "project reachable" "no access to $PROJECT" ;;
    *)      result FAIL    "project reachable" "$PROJECT not found" ;;
esac

# ------------------------------------------------------------------- billing
g billing projects describe "$PROJECT" --format="value(billingEnabled)"
case "$LAST_STATUS" in
    ok)
        if [ "$G_OUT" = "True" ]; then
            result OK   "billing" "enabled"
        else
            result FAIL "billing" "no billing account linked — nothing can be created"
        fi ;;
    api-off) result WARN    "billing" "cloudbilling API off; cannot verify" ;;
    denied)  result UNKNOWN "billing" "no permission to read billing" ;;
    *)       result UNKNOWN "billing" "could not determine" ;;
esac

# ---------------------------------------------------------------------- APIs
g services list --enabled --project="$PROJECT" --format="value(config.name)"
if [ "$LAST_STATUS" != ok ]; then
    result UNKNOWN "enabled APIs" "could not list services ($LAST_STATUS)"
    ENABLED=""
else
    ENABLED="$G_OUT"
fi

is_on() { grep -qx "$1" <<<"$ENABLED"; }

# Must already be on: the trigger setup refuses without it, and it is what runs
# everything else on the cloud-native path.
if [ -n "$ENABLED" ]; then
    if is_on cloudbuild.googleapis.com; then
        result OK "cloudbuild API" "enabled"
    else
        result FAIL "cloudbuild API" "enable first: gcloud services enable cloudbuild.googleapis.com --project=$PROJECT"
    fi

    # The bootstrap enables these itself (iac/bootstrapping/lib/config.sh and
    # the project_apis list in iac/terraform/main.tf), so a disabled one costs
    # time, not success — provided the caller may enable services, checked below.
    SELF_ENABLED=(
        cloudresourcemanager.googleapis.com storage-api.googleapis.com
        storage-component.googleapis.com secretmanager.googleapis.com
        iam.googleapis.com iamcredentials.googleapis.com compute.googleapis.com
        serviceusage.googleapis.com servicenetworking.googleapis.com
        artifactregistry.googleapis.com container.googleapis.com
        sqladmin.googleapis.com monitoring.googleapis.com
        cloudscheduler.googleapis.com run.googleapis.com
        certificatemanager.googleapis.com
    )
    [ "$PKI" = remote ] && SELF_ENABLED+=(dns.googleapis.com privateca.googleapis.com)

    MISSING=()
    for api in "${SELF_ENABLED[@]}"; do is_on "$api" || MISSING+=("$api"); done
    if [ ${#MISSING[@]} -eq 0 ]; then
        result OK "APIs the bootstrap enables" "all ${#SELF_ENABLED[@]} already on"
    else
        result WARN "APIs the bootstrap enables" "${#MISSING[@]} off, will be enabled: ${MISSING[*]}"
    fi

    # Nothing in the repository enables this one, and Terraform creates a
    # BigTable instance and table. Both long-lived Nexus projects have it on
    # from earlier manual work, which is why it has never been noticed.
    if is_on bigtableadmin.googleapis.com; then
        result OK "bigtable admin API" "enabled"
    else
        result FAIL "bigtable admin API" "nothing enables it; terraform will fail. Run: gcloud services enable bigtableadmin.googleapis.com --project=$PROJECT"
    fi
fi

# --------------------------------------------------------------- permissions
PERMS=(
    serviceusage.services.enable
    container.clusters.create
    cloudsql.instances.create
    bigtable.instances.create
    secretmanager.secrets.create
    storage.buckets.create
    cloudbuild.builds.create
    iam.serviceAccounts.create
    resourcemanager.projects.setIamPolicy
)
[ "$PKI" = remote ] && PERMS+=(privateca.caPools.create dns.managedZones.create)

# testIamPermissions rather than reading the IAM policy: it accounts for roles
# inherited from a group or from the folder/organisation, which a policy read
# would miss and report as missing permissions the caller actually has.
# gcloud exposes no `projects test-iam-permissions`, so this calls the API.
PERM_JSON=$(printf '{"permissions":[%s]}' \
    "$(printf '"%s",' "${PERMS[@]}" | sed 's/,$//')")
TOKEN=$("$GCLOUD" auth print-access-token 2>/dev/null)
if [ -z "$TOKEN" ]; then
    result UNKNOWN "caller permissions" "no access token"
else
    GRANTED=$(curl -s -X POST \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "$PERM_JSON" \
        "https://cloudresourcemanager.googleapis.com/v1/projects/${PROJECT}:testIamPermissions" 2>/dev/null)
    if grep -q '"error"' <<<"$GRANTED" || [ -z "$GRANTED" ]; then
        result UNKNOWN "caller permissions" "could not test (API call failed)"
    else
        LACK=()
        for p in "${PERMS[@]}"; do grep -q "\"$p\"" <<<"$GRANTED" || LACK+=("$p"); done
        if [ ${#LACK[@]} -eq 0 ]; then
            result OK "caller permissions" "all ${#PERMS[@]} present"
        else
            result FAIL "caller permissions" "missing: ${LACK[*]}"
        fi
    fi
fi

# ----------------------------------------------------------------- occupancy
# A bootstrap into an occupied project is the mistake this check exists to
# prevent: names collide, and a teardown afterwards takes the other platform
# with it.
OCCUPIED=()
g container clusters list --project="$PROJECT" --format="value(name)"
[ "$LAST_STATUS" = ok ] && [ -n "$G_OUT" ] && OCCUPIED+=("GKE: $(tr '\n' ' ' <<<"$G_OUT")")
g sql instances list --project="$PROJECT" --format="value(name)"
[ "$LAST_STATUS" = ok ] && [ -n "$G_OUT" ] && OCCUPIED+=("CloudSQL: $(tr '\n' ' ' <<<"$G_OUT")")
g bigtable instances list --project="$PROJECT" --format="value(name)"
[ "$LAST_STATUS" = ok ] && [ -n "$G_OUT" ] && OCCUPIED+=("BigTable: $(tr '\n' ' ' <<<"$G_OUT")")

if [ ${#OCCUPIED[@]} -eq 0 ]; then
    result OK "project is empty" "no cluster, database or BigTable instance"
else
    result WARN "project is empty" "already in use — ${OCCUPIED[*]}"
fi

# Secrets outlive a teardown, and these carry values belonging to one specific
# environment. A later bootstrap does not overwrite a secret that already has a
# version, so a leftover here is silently inherited: a local platform leaves an
# IP in REGISTRATION_HOSTNAME, and the next remote one composes
# "<that-ip>.<base-domain>" and cannot resolve it.
# Every secret here belongs to one environment, and a teardown has left them
# behind four times in one week — including unlabelled TLS private keys, which a
# new bootstrap then inherits rather than replacing, because add_secret skips a
# secret that already has a version. So this reports everything Nexus-shaped, not
# a list of names that is always one incident out of date.
#
# It stays a WARN even under --require-clean: the caller clears them. The matrix
# run does that unattended, the install skill asks first.
g secrets list --project="$PROJECT" --format="value(name,labels.nexussdvenv)"
if [ "$LAST_STATUS" = ok ]; then
    LEFTOVER=$(grep -v 'github-oauthtoken' <<<"$G_OUT" | grep -c . || true)
    if [ "${LEFTOVER:-0}" -eq 0 ]; then
        result OK "no leftover secrets" "none — a bootstrap here starts from nothing"
    else
        FROM=$(grep -v 'github-oauthtoken' <<<"$G_OUT" | awk '{print $2}' | grep -v '^$' | sort -u | paste -sd, - )
        result WARN "no leftover secrets" "${LEFTOVER} from an earlier environment${FROM:+, labelled: $FROM} — a bootstrap reuses any that already have a version. Clear with: iac/bootstrapping/tools/delete-all-secrets.sh $PROJECT"
    fi
else
    result UNKNOWN "no leftover secrets" "could not list secrets ($LAST_STATUS)"
fi

# Terraform keeps one state per project, and every bootstrap migrates it from the
# previous environment to the new one. A completed teardown removes the bucket, so
# a state left behind means an earlier run did not finish — and the next bootstrap
# will plan to destroy what that state still describes. That is how matrix run
# 856c0722 tried to delete a database still in use by a platform it had never
# built: the run before it was killed by a timeout mid-teardown.
TFSTATE_BUCKET="gs://${PROJECT}-tfstate"
if "$GCLOUD" storage ls "$TFSTATE_BUCKET" >/dev/null 2>&1; then
    STATE_ENV=$("$GCLOUD" storage cat "${TFSTATE_BUCKET}/default.tfstate" 2>/dev/null \
        | grep -oE '"environment": *"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
    if [ -n "$STATE_ENV" ]; then
        result WARN "no leftover Terraform state" "state in $TFSTATE_BUCKET still describes '$STATE_ENV' — the next bootstrap will plan to replace it"
    else
        result WARN "no leftover Terraform state" "$TFSTATE_BUCKET exists; a finished teardown removes it"
    fi
else
    result OK "no leftover Terraform state" "no $TFSTATE_BUCKET — nothing for a bootstrap to migrate from"
fi

# ------------------------------------------------------- the manual steps
# Neither of these can be done by an agent, and both stop a bootstrap dead.
# Only the trigger-based path needs this. A platform can equally be started
# with `gcloud builds submit`, which uploads the working tree and needs no
# connection at all, and a project without one bootstraps fine that way.
# So: never a FAIL, or every submit-based install would be told it is blocked.
if [ -z "$REGION" ]; then
    result UNKNOWN "Cloud Build GitHub connection" "pass --region to check; the listing is regional"
else
    g builds connections list --project="$PROJECT" --region="$REGION" --format="value(name)"
    case "$LAST_STATUS" in
        ok)
            if [ -n "$G_OUT" ]; then
                result OK "Cloud Build GitHub connection" "$(tr '\n' ' ' <<<"$G_OUT")"
            else
                result WARN "Cloud Build GitHub connection" "none in $REGION — needed for the recommended trigger path, which is also what creates the recurring health check. Create it in the console (browser sign-in). A gcloud builds submit install works without one, and has no schedule"
            fi ;;
        *) result UNKNOWN "Cloud Build GitHub connection" "could not list ($LAST_STATUS)" ;;
    esac
fi

if [ "$PKI" = remote ]; then
    # visibility=public only: every GKE cluster creates a private cluster.local
    # zone, and counting it would report a delegated zone that does not exist.
    g dns managed-zones list --project="$PROJECT" \
        --filter="visibility=public" --format="value(name,dnsName)"
    case "$LAST_STATUS" in
        ok)
            if [ -n "$G_OUT" ]; then
                result OK "Cloud DNS zone" "$(tr '\n' ' ' <<<"$G_OUT")"
                result WARN "DNS delegation" "verify the zone's name servers are delegated at your registrar — this cannot be checked from here"
            else
                result FAIL "Cloud DNS zone" "none — remote PKI needs a zone, delegated at the registrar"
            fi ;;
        *) result UNKNOWN "Cloud DNS zone" "could not list ($LAST_STATUS)" ;;
    esac
fi

# -------------------------------------------------------------------- region
if [ -n "$REGION" ]; then
    g compute regions describe "$REGION" --project="$PROJECT" --format="value(status)"
    if [ "$LAST_STATUS" = ok ] && [ "$G_OUT" = UP ]; then
        result OK "region" "$REGION is up"
    else
        result WARN "region" "could not confirm $REGION is up ($LAST_STATUS)"
    fi
fi

# ------------------------------------------------------------------ verdict
if $JSON; then
    printf '{"project":"%s","pki":"%s","fails":%d,"warns":%d,"unknowns":%d,"checks":[%s]}\n' \
        "$PROJECT" "$PKI" "$FAILS" "$WARNS" "$UNKNOWNS" "$(IFS=,; echo "${ROWS[*]}")"
fi

say ""
if [ "$FAILS" -gt 0 ]; then
    say "${C_R}BLOCKED${C_N} — $FAILS blocking, $WARNS warnings, $UNKNOWNS unknown"
    exit 1
elif [ "$WARNS" -gt 0 ] || [ "$UNKNOWNS" -gt 0 ]; then
    say "${C_Y}READY WITH RESERVATIONS${C_N} — $WARNS warnings, $UNKNOWNS unknown"
    exit 2
else
    say "${C_G}READY${C_N} — nothing blocks a bootstrap"
    exit 0
fi
