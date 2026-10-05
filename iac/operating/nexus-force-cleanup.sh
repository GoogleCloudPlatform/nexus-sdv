#!/bin/bash
# ==============================================================================
# Nexus Force Cleanup — remove what Terraform can no longer remove
#
# For the cases a normal teardown cannot handle: the tfstate is gone or
# untrusted, a bootstrap died halfway, or resources are left over from earlier
# generations that no .bootstrap_env references any more. A regular teardown
# only deletes the CA pools named in the current .bootstrap_env — everything
# from previous bootstraps stays behind, forever, costing money.
#
# DRY RUN BY DEFAULT. Nothing is deleted without --apply.
#
# Usage:
#   nexus-force-cleanup.sh --project P                    # show what would go
#   nexus-force-cleanup.sh --project P --apply            # delete it
#   nexus-force-cleanup.sh --project P --only ca-pools --apply
#   nexus-force-cleanup.sh --project P --keep-tfstate --apply
#
# Options:
#   --project ID     required; refused if the project is on the blocked list
#   --apply          actually delete (without this, nothing is touched)
#   --region R       override the region (default: derived from the project)
#   --only LIST      comma-separated subset of:
#                    triggers,gke,bigtable,sql,secrets,artifacts,dns,network,
#                    ca-pools,scheduler,service-accounts,buckets
#   --keep-tfstate   keep the <project>-tfstate bucket
#
# What it never touches:
#   - blocked projects (iac/operating/nexus-policy.sh)
#   - Compute Engine instances — no Nexus bootstrap creates VMs, so any VM
#     belongs to someone else
#   - protected DNS zones, and in every other zone only Nexus-owned records
#   - the DNS zone itself; only records go, so registrar delegation survives
#
# Deliberately no `set -e`: a destructive run must not stop silently halfway
# through. Every step is checked on its own and tallied at the end.
# ==============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/nexus-policy.sh"
echo "Policy: $NEXUS_POLICY_SOURCE" >&2

GCLOUD="$(command -v gcloud || echo /opt/homebrew/bin/gcloud)"
[ -x "$GCLOUD" ] || { echo "gcloud not found" >&2; exit 1; }

PROJECT=""; APPLY=false; REGION=""; ONLY=""; KEEP_TFSTATE=false
while [ $# -gt 0 ]; do
    case "$1" in
        --project) PROJECT="${2:-}"; shift 2 ;;
        --apply) APPLY=true; shift ;;
        --region) REGION="${2:-}"; shift 2 ;;
        --only) ONLY="${2:-}"; shift 2 ;;
        --keep-tfstate) KEEP_TFSTATE=true; shift ;;
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done
[ -n "$PROJECT" ] || { echo "--project is required" >&2; exit 1; }

REASON=$(blocked_reason "$PROJECT")
if [ -n "$REASON" ]; then
    echo "REFUSED: $PROJECT is on the blocked list — $REASON" >&2
    exit 1
fi

C_G='\033[0;32m'; C_Y='\033[1;33m'; C_R='\033[0;31m'; C_B='\033[0;34m'; C_N='\033[0m'
DONE=0; FAILED=0; PLANNED=0
section() { echo -e "\n${C_B}--- $* ---${C_N}"; }
note()    { echo -e "  $*"; }
skip()    { echo -e "  ${C_B}skip${C_N}  $*"; }

wants() { [ -z "$ONLY" ] || grep -q "\(^\|,\)$1\(,\|$\)" <<<"$ONLY"; }

# Print what would happen, or do it and tally the result.
act() {
    local what="$1"; shift
    if ! $APPLY; then
        echo -e "  ${C_Y}would delete${C_N}  $what"
        PLANNED=$((PLANNED + 1))
        return
    fi
    local err
    if err=$("$@" </dev/null 2>&1 >/dev/null); then
        echo -e "  ${C_G}deleted${C_N}  $what"
        DONE=$((DONE + 1))
    else
        # Show why. A bare "FAILED" sent us hunting by hand more than once —
        # a router holding the VPC, a soft-deleted CA holding its pool. The
        # reason is always in the first line gcloud prints.
        echo -e "  ${C_R}FAILED${C_N}   $what"
        [ -n "$err" ] && echo "           $(head -2 <<<"$err" | tr '\n' ' ' | cut -c1-160)"
        FAILED=$((FAILED + 1))
    fi
}

q() { "$GCLOUD" "$@" </dev/null 2>/dev/null; }

# --- region -----------------------------------------------------------------
if [ -z "$REGION" ]; then
    REGION=$(q container clusters list --project="$PROJECT" --format='value(location)' | head -1)
    [ -z "$REGION" ] && REGION=$(q secrets versions access latest --secret=GCP_REGION --project="$PROJECT" | tr -d '[:space:]')
fi
# CA pools and triggers are swept across the candidate regions as well as the
# primary one — a leftover generation often sits in a region nothing else in the
# project points at any more.
if [ -n "$REGION" ]; then
    REGIONAL_SWEEP=$(printf '%s\n' "$REGION" $CANDIDATE_REGIONS | awk '!seen[$0]++' | tr '\n' ' ')
else
    REGION=""
    REGIONAL_SWEEP="$CANDIDATE_REGIONS"
fi

echo -e "${C_B}=============================================${C_N}"
echo "  Nexus force cleanup"
echo "  Project : $PROJECT"
echo "  Region  : ${REGION:-<undetermined>}"
echo "  Sweeping: $REGIONAL_SWEEP  (CA pools, triggers)"
echo "  Mode    : $($APPLY && echo 'APPLY — resources will be deleted' || echo 'dry run — nothing will be touched')"
[ -n "$ONLY" ] && echo "  Only    : $ONLY"
echo -e "${C_B}=============================================${C_N}"

# --- Cloud Build triggers ---------------------------------------------------
if wants triggers; then
    section "Cloud Build triggers"
    for r in $REGIONAL_SWEEP; do
        while IFS= read -r t; do
            [ -n "$t" ] || continue
            act "trigger $t ($r)" "$GCLOUD" builds triggers delete "$t" --region="$r" --project="$PROJECT" --quiet
        done < <(q builds triggers list --project="$PROJECT" --region="$r" --format='value(name)')
    done
fi

# --- GKE --------------------------------------------------------------------
# Must go before the VPC: GKE leaves firewall rules and NEGs attached to it.
if wants gke; then
    section "GKE clusters"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        set -- $line
        act "GKE cluster $1 ($2)" "$GCLOUD" container clusters delete "$1" --region="$2" --project="$PROJECT" --quiet
    done < <(q container clusters list --project="$PROJECT" --format='value(name,location)')
fi

# --- BigTable ---------------------------------------------------------------
if wants bigtable; then
    section "BigTable instances"
    while IFS= read -r i; do
        [ -n "$i" ] || continue
        act "BigTable instance $i" "$GCLOUD" bigtable instances delete "$i" --project="$PROJECT" --quiet
    done < <(q bigtable instances list --project="$PROJECT" --format='value(name)')
fi

# --- Cloud SQL --------------------------------------------------------------
if wants sql; then
    section "Cloud SQL instances"
    while IFS= read -r i; do
        [ -n "$i" ] || continue
        act "Cloud SQL instance $i" "$GCLOUD" sql instances delete "$i" --project="$PROJECT" --quiet
    done < <(q sql instances list --project="$PROJECT" --format='value(name)')
fi

# --- Secrets ----------------------------------------------------------------
# GitHub OAuth tokens and GHE keys are Cloud Build connection credentials, not
# Nexus state — deleting them breaks the repo connection the triggers need.
if wants secrets; then
    section "Secrets"
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        case "$s" in
            *github-oauthtoken*|*ghe-private-key*|*ghe-webhook-secret*)
                skip "$s (Cloud Build repo connection)"; continue ;;
        esac
        act "secret $s" "$GCLOUD" secrets delete "$s" --project="$PROJECT" --quiet
    done < <(q secrets list --project="$PROJECT" --format='value(name)')
fi

# --- Artifact Registry ------------------------------------------------------
if wants artifacts; then
    # Listed per region rather than project-wide: `value(name,location)` returns
    # an empty location — the region only appears inside the full resource name,
    # which `value(name)` shortens away — and the empty field aborted the run
    # under `set -u`.
    section "Artifact Registry repositories"
    for ARREGION in $REGIONAL_SWEEP; do
        while IFS= read -r repo; do
            [ -n "$repo" ] || continue
            act "artifact repo $repo ($ARREGION)" "$GCLOUD" artifacts repositories delete "$repo" --location="$ARREGION" --project="$PROJECT" --quiet
        done < <(q artifacts repositories list --project="$PROJECT" --location="$ARREGION" --format='value(name)')
    done
fi

# --- DNS records ------------------------------------------------------------
# Records only, never the zone: deleting the zone loses the nameservers and the
# delegation at the registrar. Only Nexus-owned names go; anything else in the
# zone belongs to someone else.
if wants dns; then
    # GKE manages its own private cluster.local zone; it holds no Nexus records
    # and iterating it produced twenty lines of noise per run.
    section "DNS records"
    while IFS= read -r zone; do
        [ -n "$zone" ] || continue
        if grep -qw "$zone" <<<"$PROTECTED_DNS_ZONES"; then
            skip "zone $zone is protected — no records touched"
            continue
        fi
        while IFS=$'\t' read -r rname rtype; do
            [ -n "$rname" ] || continue
            case "$rtype" in SOA|NS) continue ;; esac
            local_match=false
            # A prefix may be followed by '.' (nats.example.com.) or by '-'
            # (external-dns-a-nats.example.com.) — external-dns writes both
            # forms, and its ownership TXT records are exactly what causes
            # "alreadyExists" 409s on the next bootstrap.
            for pfx in $NEXUS_DNS_RECORD_PREFIXES; do
                [[ "$rname" == "$pfx".* || "$rname" == "$pfx"-* ]] && local_match=true && break
            done
            if ! $local_match; then
                skip "$rname ($rtype) — not a Nexus record"
                continue
            fi
            act "DNS $rname ($rtype) in $zone" "$GCLOUD" dns record-sets delete "$rname" --type="$rtype" --zone="$zone" --project="$PROJECT" --quiet
        done < <(q dns record-sets list --zone="$zone" --project="$PROJECT" --format='value(name,type)')
    done < <(q dns managed-zones list --project="$PROJECT" --format='value(name,dnsName)' \
                | grep -v 'cluster\.local\.$' | awk '{print $1}')
fi

# --- Network ----------------------------------------------------------------
# Order matters: NAT before router, firewall rules and routes before the subnet,
# subnet before the VPC. The 'default' network is left alone.
if wants network && [ -n "$REGION" ]; then
    # `compute routers list` takes --regions, plural, unlike almost every other
    # compute subcommand. Passing --region errors out, which read as "there are
    # no routers" — and the router then kept the VPC alive with nothing to say
    # why.
    section "Cloud NAT and routers"
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        while IFS= read -r n; do
            [ -n "$n" ] || continue
            act "Cloud NAT $n (router $r)" "$GCLOUD" compute routers nats delete "$n" --router="$r" --region="$REGION" --project="$PROJECT" --quiet
        done < <(q compute routers nats list --router="$r" --region="$REGION" --project="$PROJECT" --format='value(name)')
        act "router $r" "$GCLOUD" compute routers delete "$r" --region="$REGION" --project="$PROJECT" --quiet
    done < <(q compute routers list --regions="$REGION" --project="$PROJECT" --format='value(name)')

    section "VPCs and their dependencies"
    while IFS= read -r vpc; do
        [ -n "$vpc" ] || continue
        [ "$vpc" = "default" ] && { skip "network 'default'"; continue; }
        while IFS= read -r fw; do
            [ -n "$fw" ] || continue
            act "firewall rule $fw" "$GCLOUD" compute firewall-rules delete "$fw" --project="$PROJECT" --quiet
        done < <(q compute firewall-rules list --filter="network:$vpc" --project="$PROJECT" --format='value(name)')
        while IFS= read -r rt; do
            [ -n "$rt" ] || continue
            act "route $rt" "$GCLOUD" compute routes delete "$rt" --project="$PROJECT" --quiet
        done < <(q compute routes list --filter="network:$vpc" --project="$PROJECT" --format='value(name)')
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            set -- $line
            act "subnet $1 ($2)" "$GCLOUD" compute networks subnets delete "$1" --region="$2" --project="$PROJECT" --quiet
        done < <(q compute networks subnets list --filter="network:$vpc" --project="$PROJECT" --format='value(name,region)')
        # Reserved peering ranges hold the VPC open and appear nowhere in the
        # subnet, firewall or route listings — Cloud SQL's private IP creates one
        # (purpose VPC_PEERING). Without this the VPC delete fails with a message
        # naming a global address nobody was looking for.
        while IFS= read -r addr; do
            [ -n "$addr" ] || continue
            act "global address $addr (peering range)" "$GCLOUD" compute addresses delete "$addr" --global --project="$PROJECT" --quiet
        done < <(q compute addresses list --project="$PROJECT" --global --filter="network~${vpc}$" --format='value(name)')

        act "VPC $vpc" "$GCLOUD" compute networks delete "$vpc" --project="$PROJECT" --quiet
    done < <(q compute networks list --project="$PROJECT" --format='value(name)')
fi

# --- CA pools ---------------------------------------------------------------
# The part a normal teardown misses entirely: it only knows the pools named in
# the current .bootstrap_env, so every earlier generation survives. Sequence
# per pool: certificates, then disable + force-delete each CA, then the pool.
if wants ca-pools; then
    section "CA pools (all generations, all swept regions)"
    for CAREGION in $REGIONAL_SWEEP; do
    while IFS= read -r pool; do
        [ -n "$pool" ] || continue
        while IFS= read -r cert; do
            [ -n "$cert" ] || continue
            act "certificate $(basename "$cert") in $pool ($CAREGION)" "$GCLOUD" privateca certificates delete "$cert" --issuer-pool="$pool" --issuer-location="$CAREGION" --project="$PROJECT" --quiet
        done < <(q privateca certificates list --issuer-pool="$pool" --issuer-location="$CAREGION" --project="$PROJECT" --format='value(name)')

        # A CA deleted without --skip-grace-period stays for 30 days in state
        # DELETED, keeps its id reserved, and blocks its pool from being deleted.
        # `roots list` does show it — with its state — but it can no longer be
        # disabled or deleted directly, so it must be undeleted first. Without
        # this the pool refuses to go and nothing explains why.
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            set -- $line
            ca_id=$(basename "$1"); ca_state="${2:-}"
            if $APPLY; then
                if [ "$ca_state" = "DELETED" ]; then
                    echo "  undeleting $ca_id (soft-deleted, blocking its pool)"
                    q privateca roots undelete "$ca_id" --pool="$pool" --location="$CAREGION" --project="$PROJECT" --quiet
                fi
                q privateca roots disable "$ca_id" --pool="$pool" --location="$CAREGION" --project="$PROJECT" --quiet
            fi
            act "CA $ca_id in $pool ($CAREGION)${ca_state:+ [$ca_state]}" "$GCLOUD" privateca roots delete "$ca_id" --pool="$pool" --location="$CAREGION" --project="$PROJECT" --skip-grace-period --ignore-active-certificates --quiet
        done < <(q privateca roots list --pool="$pool" --location="$CAREGION" --project="$PROJECT" --format='value(name,state)')

        # CA deletion is asynchronous; the pool refuses to go until it settles.
        $APPLY && sleep 30
        act "CA pool $pool ($CAREGION)" "$GCLOUD" privateca pools delete "$pool" --location="$CAREGION" --project="$PROJECT" --quiet
    done < <(q privateca pools list --project="$PROJECT" --location="$CAREGION" --format='value(name)')
    done
fi

# --- Cloud Scheduler --------------------------------------------------------
if wants scheduler; then
    section "Cloud Scheduler jobs"
    for r in $REGIONAL_SWEEP; do
        while IFS= read -r job; do
            [ -n "$job" ] || continue
            act "scheduler job $(basename "$job") ($r)" "$GCLOUD" scheduler jobs delete "$(basename "$job")" --location="$r" --project="$PROJECT" --quiet
        done < <(q scheduler jobs list --location="$r" --project="$PROJECT" --format='value(name)')
    done
fi

# --- Service accounts -------------------------------------------------------
# Deleted by name, not by pattern. The project's default compute account looks
# like any other in a listing and must never go; a pattern broad enough to catch
# every Nexus account would eventually catch something else too. This list
# mirrors the account_id values in iac/terraform/*.tf — extend it there and here
# together.
if wants service-accounts; then
    section "Service accounts"
    local_sas="keycloak-gsa bigtable-connector data-api-bigtable-connector external-secrets-gsa registration-gsa factory-helper-gsa"
    for sa in $local_sas; do
        email="${sa}@${PROJECT}.iam.gserviceaccount.com"
        q iam service-accounts describe "$email" --project="$PROJECT" >/dev/null 2>&1 || continue
        act "service account $sa" "$GCLOUD" iam service-accounts delete "$email" --project="$PROJECT" --quiet
    done
    # Environment-prefixed ones: <env>-gke-nodes and <env>-sa-github-oidc.
    while IFS= read -r email; do
        [ -n "$email" ] || continue
        case "$email" in
            *-gke-nodes@*|*-sa-github-oidc@*)
                act "service account ${email%%@*}" "$GCLOUD" iam service-accounts delete "$email" --project="$PROJECT" --quiet ;;
        esac
    done < <(q iam service-accounts list --project="$PROJECT" --format='value(email)')
fi

# --- Buckets ----------------------------------------------------------------
if wants buckets; then
    # nexus-sdv-public is the per-instance public trust-anchor bucket; its
    # certificates only mean anything for this deployment.
    section "GCS buckets"
    for b in "${PROJECT}-tfstate" "${PROJECT}-bootstrap-envs" "${PROJECT}-nexus-sdv-public"; do
        if [ "$b" = "${PROJECT}-tfstate" ] && $KEEP_TFSTATE; then
            skip "$b (--keep-tfstate)"; continue
        fi
        q storage buckets describe "gs://$b" --format='value(name)' >/dev/null || continue
        act "bucket gs://$b" "$GCLOUD" storage rm -r "gs://$b" --project="$PROJECT" --quiet
    done
fi

# --- summary ----------------------------------------------------------------
echo -e "\n${C_B}=============================================${C_N}"
if $APPLY; then
    echo -e "  deleted: $DONE   ${C_R}failed: $FAILED${C_N}"
    [ "$FAILED" -gt 0 ] && echo "  Re-run to retry — deletions are asynchronous and often succeed on a second pass."
else
    echo "  $PLANNED resource(s) would be deleted. Re-run with --apply."
fi
echo -e "${C_B}=============================================${C_N}"
