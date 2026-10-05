#!/bin/bash
# ==============================================================================
# Nexus GCP Scan — read-only inventory and verdict per project
#
# Answers one question per project: is a Nexus platform deployed here, and is it
# whole? Use it before cleaning up, before bootstrapping into a project someone
# else may be using, and to find environments that are quietly costing money.
#
# STRICTLY READ-ONLY. Every gcloud call below is a `list` or an `access`. Nothing
# in this script creates, updates or deletes. Run it against anything.
#
# Usage:
#   iac/operating/nexus-scan-gcp.sh                 # every accessible project
#   iac/operating/nexus-scan-gcp.sh PROJECT [...]   # named projects only
#   iac/operating/nexus-scan-gcp.sh --json          # machine-readable output
#
# Verdicts:
#   COMPLETE  GKE + Cloud SQL + BigTable + Nexus secrets all present
#   PARTIAL   some Nexus resources, but not a working set — a failed bootstrap,
#             a half-finished teardown, or leftovers (this is the interesting one)
#   EMPTY     no Nexus footprint
#   FOREIGN   substantial non-Nexus resources, no Nexus footprint
#   BLOCKED   project is on the do-not-touch list below
#
# Three gcloud traps this script works around — do not "simplify" them away:
#   1. macOS ships no GNU `timeout`; wrapping calls in it makes every call fail
#      silently, which looks exactly like "this project is empty".
#   2. With an API disabled, gcloud asks "enable and retry? (y/N)" on stdin and
#      waits forever. Every call gets </dev/null so it answers no and errors out.
#   3. CA pools and Cloud Build triggers are regional. Querying the wrong region
#      succeeds and returns an empty list — indistinguishable from "none exist".
#      The region is derived per project, never assumed.
# ==============================================================================

set -uo pipefail

GCLOUD="$(command -v gcloud || echo /opt/homebrew/bin/gcloud)"
[ -x "$GCLOUD" ] || { echo "gcloud not found" >&2; exit 1; }

# Do-not-touch policy — shared with nexus-force-cleanup.sh.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/nexus-policy.sh"
echo "Policy: $NEXUS_POLICY_SOURCE" >&2

JSON=false
PROJECTS=()
for arg in "$@"; do
    case "$arg" in
        --json) JSON=true ;;
        -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "Unknown option: $arg" >&2; exit 1 ;;
        *) PROJECTS+=("$arg") ;;
    esac
done

C_G='\033[0;32m'; C_Y='\033[1;33m'; C_R='\033[0;31m'; C_B='\033[0;34m'; C_N='\033[0m'
say() { $JSON || echo -e "$@"; }

# Run a gcloud list. Echoes results, or nothing when the API is off or access is
# denied; the caller can read LAST_STATUS to tell those cases apart.
# Results come back in G_OUT, not on stdout: command substitution runs in a
# subshell, so a status set inside one would be lost to the caller — the very
# way a failed query turns into a silent "this resource does not exist".
LAST_STATUS=ok
G_OUT=""
g() {
    local out rc
    out=$("$GCLOUD" "$@" </dev/null 2>&1); rc=$?

    # Exit status alone is not enough: `gcloud compute instances list` against a
    # non-existent project exits 0 and merely warns, and its warning text is
    # non-empty, so a naive reader counts it as two resources. Classify on both
    # the status and the message, and never let diagnostic lines reach the data.
    G_OUT=""
    if grep -qi 'has not been used\|SERVICE_DISABLED\|not enabled' <<<"$out"; then
        LAST_STATUS=api-off; return
    elif grep -qi 'PERMISSION_DENIED\|does not have permission' <<<"$out"; then
        LAST_STATUS=denied; return
    elif [ "$rc" -ne 0 ] \
         || grep -qi '^ERROR\|Some requests did not succeed\|was not found' <<<"$out"; then
        LAST_STATUS=error; return
    fi
    LAST_STATUS=ok
    G_OUT=$(grep -v '^$\|^Listing items under\|^WARNING\|^ERROR\|^ - ' <<<"$out")
}


# The region a Nexus instance lives in: from the GKE cluster if there is one,
# else from the GCP_REGION secret the bootstrap writes. Empty means unknown, and
# the caller then falls back to searching CANDIDATE_REGIONS rather than
# reporting "no CA pools" for a region it never looked in.
detect_region() {
    local p="$1" gke="$2" r
    r=$(awk 'NR==1 {print $2}' <<<"$gke")
    [ -n "$r" ] && { echo "$r"; return; }
    "$GCLOUD" secrets versions access latest --secret=GCP_REGION \
        --project="$p" </dev/null 2>/dev/null | tr -d '[:space:]'
}

scan_project() {
    local p="$1"
    local reason; reason=$(blocked_reason "$p")
    if [ -n "$reason" ]; then
        say "\n${C_R}##### $p — BLOCKED${C_N}\n  $reason"
        $JSON && echo "{\"project\":\"$p\",\"verdict\":\"BLOCKED\",\"reason\":\"$reason\"}"
        return
    fi

    local gke sql bigtable secrets buckets vpcs dns vms pools triggers region
    FAILED_QUERIES=()

    # Wrap g() so a failed call is recorded rather than silently read as "this
    # resource does not exist". An empty result and a failed lookup are not the
    # same fact, and treating them alike produces a confident "nothing here"
    # from a transient auth blip. A disabled API is a real answer, not a
    # failure, so it is not recorded here.
    gq() {
        local what="$1"; shift
        g "$@"
        case "$LAST_STATUS" in
            denied) FAILED_QUERIES+=("$what: access denied") ;;
            error)  FAILED_QUERIES+=("$what: query failed") ;;
        esac
    }

    gq GKE container clusters list --project="$p" --format='value(name,location,status)'; gke=$G_OUT
    gq "Cloud SQL" sql instances list --project="$p" --format='value(name,state)'; sql=$G_OUT
    gq BigTable bigtable instances list --project="$p" --format='value(name,state)'; bigtable=$G_OUT
    gq Secrets secrets list --project="$p" --format='value(name)'; secrets=$G_OUT
    gq Buckets storage buckets list --project="$p" --format='value(name)'; buckets=$G_OUT
    g compute networks list --project="$p" --format='value(name)'; vpcs=$(grep -v '^default$' <<<"$G_OUT")
    g dns managed-zones list --project="$p" --format='value(name,dnsName)'; dns=$(grep -v 'cluster\.local\.$' <<<"$G_OUT")
    gq VMs compute instances list --project="$p" --format='value(name,status)'; vms=$G_OUT

    region=$(detect_region "$p" "$gke")
    pools=""; triggers=""
    if [ -n "$region" ]; then
        g privateca pools list --project="$p" --location="$region" --format='value(name)'; pools=$G_OUT
        g builds triggers list --project="$p" --region="$region" --format='value(name)'; triggers=$G_OUT
    else
        # Region unknown: search the candidates so leftovers are still found.
        local cr found
        for cr in $CANDIDATE_REGIONS; do
            g privateca pools list --project="$p" --location="$cr" --format='value(name)'; found=$G_OUT
            [ -n "$found" ] && pools+="${pools:+$'\n'}$found"
            g builds triggers list --project="$p" --region="$cr" --format='value(name)'; found=$G_OUT
            [ -n "$found" ] && triggers+="${triggers:+$'\n'}$found"
        done
    fi

    # Nexus fingerprints. BASE_DOMAIN and NATS_HOSTNAME are written by the
    # bootstrap and appear in no other kind of project.
    local has_secrets=false has_bt=false has_state=false
    grep -q '^BASE_DOMAIN$' <<<"$secrets" && grep -q '^NATS_HOSTNAME$' <<<"$secrets" && has_secrets=true
    grep -q 'bigtable-production-storage' <<<"$bigtable" && has_bt=true
    # Either bucket is a bootstrap fingerprint that outlives a teardown.
    { grep -q -- '-tfstate$' <<<"$buckets" || grep -q -- '-bootstrap-envs$' <<<"$buckets"; } && has_state=true

    local n=0
    [ -n "$gke" ] && n=$((n+1))
    [ -n "$sql" ] && n=$((n+1))
    $has_bt && n=$((n+1))
    $has_secrets && n=$((n+1))

    # A verdict is only as good as the evidence behind it. If any fingerprint
    # query failed, say so instead of guessing.
    local verdict
    if [ ${#FAILED_QUERIES[@]} -gt 0 ] && [ "$n" -lt 4 ]; then verdict=UNKNOWN
    elif [ "$n" -eq 4 ]; then verdict=COMPLETE
    elif [ "$n" -gt 0 ] || [ -n "$pools" ] || $has_state; then verdict=PARTIAL
    # A bare DNS zone is not a foreign project — it is a prepared one. Only VMs
    # or non-default VPCs mean someone else is using this project.
    elif [ -n "$vms" ] || [ -n "$vpcs" ]; then verdict=FOREIGN
    else verdict=EMPTY; fi

    local n_pools n_gens n_vms n_run n_trig n_sec
    n_pools=$(grep -c . <<<"$pools"); [ -z "$pools" ] && n_pools=0
    n_gens=$(sed 's/.*-ca-pool-//' <<<"$pools" | sort -u | grep -c .); [ -z "$pools" ] && n_gens=0
    n_vms=$(grep -c . <<<"$vms"); [ -z "$vms" ] && n_vms=0
    n_run=$(grep -c 'RUNNING' <<<"$vms"); [ -z "$vms" ] && n_run=0
    n_trig=$(grep -c . <<<"$triggers"); [ -z "$triggers" ] && n_trig=0
    n_sec=$(grep -c . <<<"$secrets"); [ -z "$secrets" ] && n_sec=0

    if $JSON; then
        printf '{"project":"%s","verdict":"%s","region":"%s","gke":%s,"sql":%s,"bigtable":%s,"secrets":%s,"tfstate":%s,"ca_pools":%d,"ca_pool_generations":%d,"vms":%d,"vms_running":%d,"triggers":%d,"failed_queries":%d}\n' \
            "$p" "$verdict" "$region" \
            "$( [ -n "$gke" ] && echo true || echo false )" \
            "$( [ -n "$sql" ] && echo true || echo false )" \
            "$has_bt" "$has_secrets" "$has_state" \
            "$n_pools" "$n_gens" "$n_vms" "$n_run" "$n_trig" "${#FAILED_QUERIES[@]}"
        return
    fi

    local color=$C_B
    case "$verdict" in
        COMPLETE) color=$C_G ;;
        PARTIAL)  color=$C_Y ;;
        UNKNOWN)  color=$C_R ;;
    esac
    echo -e "\n${color}##### $p — $verdict${C_N}${region:+  (region: $region)}"
    [ -z "$region" ] && echo "  NOTE      : region undetermined — searched $CANDIDATE_REGIONS"
    [ -n "$gke" ]      && echo "  GKE       : $(tr '\n' ';' <<<"$gke")"
    [ -n "$sql" ]      && echo "  Cloud SQL : $(tr '\n' ';' <<<"$sql")"
    [ -n "$bigtable" ] && echo "  BigTable  : $(tr '\n' ';' <<<"$bigtable")"
    [ "$n_pools" -gt 0 ] && echo "  CA pools  : $n_pools in $n_gens generation(s)"
    [ -n "$dns" ]      && echo "  DNS zones : $(tr '\n' ';' <<<"$dns")"
    [ -n "$vpcs" ]     && echo "  VPCs      : $(tr '\n' ';' <<<"$vpcs")"
    [ "$n_vms" -gt 0 ] && echo "  VMs       : $n_vms ($n_run running)"
    [ "$n_trig" -gt 0 ] && echo "  Triggers  : $(tr '\n' ';' <<<"$triggers")"
    [ "$n_sec" -gt 0 ] && echo "  Secrets   : $n_sec"

    local f
    for f in "${FAILED_QUERIES[@]:-}"; do
        [ -n "$f" ] && echo -e "  ${C_R}NO ANSWER${C_N} : $f — result below is incomplete"
    done

    # Surface anything a cleanup must not touch.
    local z
    for z in $PROTECTED_DNS_ZONES; do
        grep -q "^${z}	" <<<"$dns" && echo -e "  ${C_R}PROTECTED${C_N} : DNS zone '$z' must keep its records"
    done
    if grep -qw "$p" <<<"$PROTECTED_VMS_PROJECTS" && [ "$n_vms" -gt 0 ]; then
        echo -e "  ${C_R}PROTECTED${C_N} : Compute instances in this project must not be deleted"
    fi
}

if [ ${#PROJECTS[@]} -eq 0 ]; then
    say "${C_B}Listing accessible projects...${C_N}"
    while IFS= read -r line; do PROJECTS+=("$line"); done \
        < <("$GCLOUD" projects list --format='value(projectId)' </dev/null 2>/dev/null)
fi

for p in "${PROJECTS[@]}"; do scan_project "$p"; done
say ""
