#!/bin/bash
# =================================================================================
# Platform Health Check
#
# Consolidated, on-demand health check for one or more bootstrapped Nexus SDV
# environments. Covers:
#   APIs:            required GCP APIs enabled for the project
#   Cloud Build:     presence of the bootstrap/teardown/test/health-check triggers
#   Infrastructure:  GKE cluster status, BigTable instance/table, Compute SA
#   Nodes:           kubectl connectivity and GKE node readiness
#   Certificates:    CA pool/cert expiry (remote PKI) or Secret Manager certs (local PKI)
#   Endpoints:       DNS resolution and pinging Keycloak/NATS/Registration directly
#   Base services:   Deployment/StatefulSet/NATS-pod availability in base-services
#   Data pipeline (opt-in, --e2e): re-runs run-sample-clients.yaml end-to-end
#
# Usage:
#   ./iac/bootstrapping/tools/platform-health-check.sh [MODE] [OPTIONS]
#
# Mode (mutually exclusive; default: --envs-dir against the current project's
# bootstrap-envs bucket):
#   --envs-dir GS_PATH   Check every *.bootstrap_env file found under this GCS
#                        directory (same convention as
#                        iac/cloudbuild/test-environments.yaml's
#                        _BOOTSTRAP_ENVS_DIR).
#   --env-file PATH      Check exactly one environment, described by this
#                        local file or gs:// object.
#   --project ID         Check exactly one project using the current gcloud
#                        context, without a .bootstrap_env file (ENV/hostnames
#                        unknown — checks that depend on them are skipped with
#                        a warning).
#
# Options:
#   --e2e             Also run the data pipeline end-to-end check (submits a real
#                     Cloud Build job per environment — costs money and takes a few
#                     minutes; off by default). Requires the environment's
#                     .bootstrap_env to be reachable as a gs:// path (true for
#                     --envs-dir, and for --env-file when given a gs:// path).
#   --strict          Exit non-zero if there are any warnings, not just
#                     failures.
#   --report-metrics  Push pass/warn/fail counts and per-failure detail to
#                     Cloud Monitoring (see iac/terraform/monitoring.tf). Off
#                     by default so local debugging doesn't skew the
#                     dashboard. Requires jq.
#   -h/--help
#
# Prerequisites: gcloud, kubectl, nslookup, openssl, curl.
#
# Troubleshooting: "kubectl unreachable" in the Nodes check usually means the
# cluster's master_authorized_networks (iac/terraform/gke.tf) only allows
# GCP's own CIDRs. Temporarily authorize your own IP:
#   gcloud container clusters update ${CLUSTER_NAME} --region=${REGION} \
#     --project=$(gcloud config get-value project) \
#     --enable-master-authorized-networks \
#     --master-authorized-networks="$(curl -s ipv4.myexternalip.com/raw)/32"
# (terraform apply will revert this — it's a temporary override only.)
# =================================================================================

# No -e: checks must keep running after a failure to produce a full report;
# each fallible command below is guarded explicitly (if/||) instead.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

command -v gcloud >/dev/null || { echo "gcloud not found in PATH" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl not found in PATH" >&2; exit 1; }
command -v openssl >/dev/null || { echo "openssl not found in PATH" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl not found in PATH" >&2; exit 1; }

# A private/unreachable cluster can hang before kubectl's own
# --request-timeout kicks in, and macOS ships no GNU `timeout`. Wrap every
# kubectl call in with_timeout so this fails one check, not the whole run.
KUBECTL_OPTS=(--request-timeout=15s)

with_timeout() {
    local secs="$1"
    shift
    "$@" &
    local pid=$!
    ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) &
    local watcher=$!
    wait "$pid" 2>/dev/null
    local rc=$?
    kill "$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null
    return $rc
}

COLOR_GREEN='\033[0;32m'
COLOR_BLUE='\033[0;34m'
COLOR_YELLOW='\033[1;33m'
COLOR_RED='\033[0;31m'
COLOR_NC='\033[0m'

log_info()    { echo -e "${COLOR_BLUE}[INFO]${COLOR_NC} $*"; }
log_warn()    { echo -e "${COLOR_YELLOW}[WARN]${COLOR_NC} $*" >&2; }
log_error()   { echo -e "${COLOR_RED}[ERROR]${COLOR_NC} $*" >&2; exit 1; }
log_ok()      { echo -e "${COLOR_GREEN}[OK]${COLOR_NC}   $*"; }
log_fail()    { echo -e "${COLOR_RED}[FAIL]${COLOR_NC} $*" >&2; }
log_section() { echo -e "\n${COLOR_BLUE}=== $* ===${COLOR_NC}"; }

PASS=0
WARN=0
FAIL=0
FAIL_DETAILS=()
ENV_SUMMARY=()
KUBECTL_READY=false

record_pass() { log_ok   "$1"; PASS=$((PASS + 1)); }
record_warn() { log_warn "$1"; WARN=$((WARN + 1)); }
record_fail() { log_fail "$1"; FAIL=$((FAIL + 1)); FAIL_DETAILS+=("$1"); }

usage() {
    # Text between the two "# ====" banners, so --help can't desync from edits
    # to the header comment above.
    awk '/^# ====/{n++; next} n==1' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
MODE=""
ENVS_DIR=""
ENV_FILE=""
TARGET_PROJECT=""
RUN_E2E=false
STRICT=false
REPORT_METRICS=false

while [ $# -gt 0 ]; do
    case "$1" in
        --envs-dir)        [ $# -ge 2 ] || log_error "--envs-dir requires a value"; ENVS_DIR="$2"; MODE="envs-dir"; shift 2 ;;
        --envs-dir=*)      ENVS_DIR="${1#*=}"; MODE="envs-dir"; shift ;;
        --env-file)        [ $# -ge 2 ] || log_error "--env-file requires a value"; ENV_FILE="$2"; MODE="env-file"; shift 2 ;;
        --env-file=*)      ENV_FILE="${1#*=}"; MODE="env-file"; shift ;;
        --project)         [ $# -ge 2 ] || log_error "--project requires a value"; TARGET_PROJECT="$2"; MODE="project"; shift 2 ;;
        --project=*)       TARGET_PROJECT="${1#*=}"; MODE="project"; shift ;;
        --e2e)             RUN_E2E=true; shift ;;
        --report-metrics)  REPORT_METRICS=true; shift ;;
        --strict)          STRICT=true; shift ;;
        -h|--help)         usage; exit 0 ;;
        *)                 log_error "Unknown argument: $1" ;;
    esac
done

if [ -z "$MODE" ]; then
    DEFAULT_PROJECT=$(gcloud config get-value project 2>/dev/null || echo "")
    [ -z "$DEFAULT_PROJECT" ] && log_error "No --envs-dir/--env-file/--project given and no default gcloud project set."
    ENVS_DIR="gs://${DEFAULT_PROJECT}-bootstrap-envs/"
    MODE="envs-dir"
fi

# Fail fast on a broken gcloud session, rather than letting every check below
# misreport the same auth error as unrelated failures. After arg parsing so
# -h/--help never needs auth.
ACTIVE_ACCOUNT=$(gcloud config get-value account 2>/dev/null || echo "")
[ -z "$ACTIVE_ACCOUNT" ] && log_error "No active gcloud account. Run: gcloud auth login"
if ! gcloud auth print-access-token >/dev/null 2>&1; then
    log_error "gcloud session for '${ACTIVE_ACCOUNT}' is not valid (expired/needs reauth). Run: gcloud auth login"
fi
log_info "Using gcloud account: ${ACTIVE_ACCOUNT}"

# Queued Cloud Monitoring points (JSON lines), pushed in batch by push_metrics.
METRICS_QUEUE_FILE=""
if [ "$REPORT_METRICS" = true ]; then
    command -v jq >/dev/null || log_error "--report-metrics requires jq in PATH"
    METRICS_QUEUE_FILE=$(mktemp)
    trap 'rm -f "$METRICS_QUEUE_FILE"' EXIT
fi

# ---------------------------------------------------------------------------
# Environment loading
# ---------------------------------------------------------------------------
# Reset before every source so a value from a previous environment in the
# loop can't leak into the next one's checks.
ENV_VARS_TO_RESET=(GCP_PROJECT_ID GCP_REGION DEPLOY_MODE GITHUB_REPO ENV PKI_STRATEGY
    BASE_DOMAIN EXISTING_DNS_ZONE KEYCLOAK_HOSTNAME NATS_HOSTNAME REGISTRATION_HOSTNAME
    FLEETVIEW_HOSTNAME EXISTING_SERVER_CA EXISTING_SERVER_CA_POOL EXISTING_FACTORY_CA
    EXISTING_FACTORY_CA_POOL EXISTING_REG_CA EXISTING_REG_CA_POOL ARCH)

load_env_file() {
    local path="$1"
    unset "${ENV_VARS_TO_RESET[@]}" 2>/dev/null || true
    case "$path" in
        gs://*)
            local tmp
            tmp=$(mktemp)
            gcloud storage cp "$path" "$tmp" --quiet 2>/dev/null || log_error "Could not download $path"
            # shellcheck source=/dev/null
            source "$tmp"
            rm -f "$tmp"
            ;;
        *)
            [ -f "$path" ] || log_error "Env file not found: $path"
            # shellcheck source=/dev/null
            source "$path"
            ;;
    esac
    GCP_REGION="${GCP_REGION:-europe-west3}"
}

# Falls back to Secret Manager (written by bootstrap) when a value wasn't in
# the sourced .bootstrap_env, e.g. in --project mode.
resolve_var() {
    local var_name="$1" secret_id="$2" current
    current="${!var_name:-}"
    if [ -n "$current" ]; then
        printf '%s' "$current"
        return 0
    fi
    gcloud secrets versions access latest --secret="$secret_id" --project="$GCP_PROJECT_ID" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# APIs
# ---------------------------------------------------------------------------
check_apis() {
    log_section "APIs"

    # Required API list mirrors iac/terraform/main.tf's project_apis/remote_apis
    # and iac/bootstrapping/lib/config.sh's enable_gcp_apis.
    local required_apis=(
        cloudresourcemanager.googleapis.com iam.googleapis.com iamcredentials.googleapis.com
        compute.googleapis.com serviceusage.googleapis.com servicenetworking.googleapis.com
        artifactregistry.googleapis.com container.googleapis.com secretmanager.googleapis.com
        sqladmin.googleapis.com run.googleapis.com cloudbuild.googleapis.com
    )
    if [ "${PKI_STRATEGY:-}" = "remote" ]; then
        required_apis+=(dns.googleapis.com privateca.googleapis.com)
    fi

    for api in "${required_apis[@]}"; do
        if gcloud services list --enabled --filter="name:$api" --format="value(name)" \
                --project="$GCP_PROJECT_ID" 2>/dev/null | grep -q "$api"; then
            record_pass "API enabled: $api"
        else
            record_fail "API NOT enabled: $api"
        fi
    done
}

# ---------------------------------------------------------------------------
# Cloud Build triggers
# ---------------------------------------------------------------------------
check_cloudbuild_triggers() {
    log_section "Cloud Build Triggers"

    # Missing triggers aren't a failure — an environment can be managed
    # directly via bootstrap-platform.sh without them.
    local triggers
    triggers=$(gcloud builds triggers list --project="$GCP_PROJECT_ID" --region="$GCP_REGION" \
        --format='value(name)' 2>/dev/null || true)
    for t in bootstrap-platform teardown-platform test-environments run-sample-clients; do
        if echo "$triggers" | grep -qx "$t"; then
            record_pass "Cloud Build trigger present: $t"
        else
            log_info "Cloud Build trigger not set up: $t (fine if this environment is managed directly via bootstrap-platform.sh)"
        fi
    done
}

# ---------------------------------------------------------------------------
# Infrastructure
# ---------------------------------------------------------------------------
check_infrastructure() {
    log_section "Infrastructure"

    GKE_CLUSTER_NAME=""
    GKE_CLUSTER_LOCATION=""
    local clusters
    clusters=$(gcloud container clusters list --project="$GCP_PROJECT_ID" --format='value(name,status,location)' 2>/dev/null || true)
    if [ -z "$clusters" ]; then
        record_fail "GKE: no clusters found in project"
    else
        while IFS=$'\t' read -r name status location; do
            [ -z "$name" ] && continue
            if [ -z "$GKE_CLUSTER_NAME" ]; then
                GKE_CLUSTER_NAME="$name"
                GKE_CLUSTER_LOCATION="$location"
            fi
            if [ "$status" = "PROVISIONING" ] || [ "$status" = "RECONCILING" ]; then
                # Transient: Autopilot adjusts a cluster on its own, and a check taken
                # at that moment must not fail a healthy bootstrap (seen on nst1-124,
                # 2026-09-18). Wait up to 10 minutes before judging. </dev/null keeps
                # gcloud from reading the cluster list this loop consumes on stdin.
                local tries=0
                while { [ "$status" = "PROVISIONING" ] || [ "$status" = "RECONCILING" ]; } && [ "$tries" -lt 20 ]; do
                    sleep 30
                    tries=$((tries + 1))
                    status=$(gcloud container clusters describe "$name" --location="$location" \
                        --project="$GCP_PROJECT_ID" --format='value(status)' </dev/null 2>/dev/null || echo "$status")
                done
            fi
            if [ "$status" = "RUNNING" ]; then
                record_pass "GKE cluster '$name' status: $status"
            elif [ "$status" = "PROVISIONING" ] || [ "$status" = "RECONCILING" ]; then
                record_warn "GKE cluster '$name' still $status after waiting 10 minutes"
            else
                record_fail "GKE cluster '$name' status: $status"
            fi
        done <<< "$clusters"
    fi

    local bt_state
    if bt_state=$(gcloud bigtable instances describe bigtable-production-storage \
            --project="$GCP_PROJECT_ID" --format='value(state)' 2>/dev/null); then
        if [ "$bt_state" = "READY" ]; then
            record_pass "BigTable instance ready ($bt_state)"
        else
            record_fail "BigTable instance not ready ($bt_state)"
        fi
        if gcloud bigtable instances tables describe telemetry --instance=bigtable-production-storage \
                --project="$GCP_PROJECT_ID" &>/dev/null; then
            record_pass "BigTable table 'telemetry' exists"
        else
            record_fail "BigTable table 'telemetry' not found"
        fi
    else
        record_fail "BigTable instance 'bigtable-production-storage' not found"
    fi

    local project_number compute_sa sa_info
    project_number=$(gcloud projects describe "$GCP_PROJECT_ID" --format='value(projectNumber)' 2>/dev/null || true)
    if [ -z "$project_number" ]; then
        record_fail "Could not determine project number for $GCP_PROJECT_ID"
        return
    fi
    compute_sa="${project_number}-compute@developer.gserviceaccount.com"
    if ! sa_info=$(gcloud iam service-accounts describe "$compute_sa" --project="$GCP_PROJECT_ID" 2>/dev/null); then
        record_fail "Compute default SA not found: $compute_sa"
    elif echo "$sa_info" | grep -qi "disabled: true"; then
        record_fail "Compute default SA is disabled: $compute_sa"
    else
        record_pass "Compute default SA active: $compute_sa"
    fi
}

# ---------------------------------------------------------------------------
# Endpoint pinging helpers
# ---------------------------------------------------------------------------
check_dns() {
    local hostname="$1" base_domain="$2" label="$3" fqdn
    if [ -z "$hostname" ]; then
        record_warn "$label hostname unknown — skipping DNS check"
        return
    fi
    fqdn="${hostname}.${base_domain}"
    if nslookup "$fqdn" >/dev/null 2>&1; then
        record_pass "$label DNS resolves: $fqdn"
    else
        record_fail "$label DNS does not resolve: $fqdn"
    fi
}

# Local PKI hostnames are already IPs; remote PKI needs BASE_DOMAIN appended.
resolve_endpoint() {
    local hostname="$1" base_domain="$2"
    [ -z "$hostname" ] && return 1
    if [ "${PKI_STRATEGY:-}" = "local" ]; then
        printf '%s' "$hostname"
    else
        printf '%s.%s' "$hostname" "$base_domain"
    fi
}

# A freshly created LoadBalancer does not forward until its backend health check
# has passed, and a name served by external-dns needs a sync cycle on top of its
# 300s TTL. `helm --wait` ends at pod readiness and covers none of that, so a
# single attempt straight after a deployment measures that window rather than the
# platform. nst1-150 failed this way while real vehicles registered seconds later.
probe_retry() {
    local tries="$1" delay="$2"; shift 2
    local i
    for ((i = 1; i <= tries; i++)); do
        "$@" && return 0
        [ "$i" -lt "$tries" ] && sleep "$delay"
    done
    return 1
}

tcp_connect() { with_timeout 8 bash -c "exec 3<>\"/dev/tcp/$1/$2\"" 2>/dev/null; }

# Plain TCP connect only — Registration's port 8443 enforces mTLS, so we
# can't do a meaningful HTTP request without a client certificate.
check_tcp_port() {
    local addr="$1" port="$2" label="$3"
    if [ -z "$addr" ]; then
        record_warn "$label endpoint unknown — skipping reachability check"
        return
    fi
    if probe_retry 6 10 tcp_connect "$addr" "$port"; then
        record_pass "$label reachable at ${addr}:${port}"
    else
        record_fail "$label NOT reachable at ${addr}:${port} (6 attempts over ~1 minute)"
    fi
}

http_answers() {
    local code
    code=$(with_timeout 10 curl -ks -o /dev/null -w '%{http_code}' \
        --connect-timeout 5 --max-time 8 "$1" 2>/dev/null || true)
    [ -n "$code" ] && [ "$code" != "000" ]
}

# FleetView's login, not just its TLS. The web client is created by
# deploy-keycloak with the placeholder redirectUris ["/*"], which Keycloak reads
# relative to an empty rootUrl and therefore matches nothing; the real address is
# set afterwards by build-push-deploy-data-web-client. When that step could not
# reach the admin API it used to warn and continue, leaving a platform that
# passed every check here while its web interface could not be signed into — the
# state codex929a shipped in. Asking the authorize endpoint with FleetView's own
# redirect_uri is what tells the two apart.
check_fleetview_login() {
    local base_domain="$1" url body
    if [ "${PKI_STRATEGY:-}" = "local" ]; then
        log_info "FleetView login check needs the keycloak-ui hostname — skipping on local PKI"
        return
    fi
    if [ -z "$base_domain" ]; then
        record_warn "BASE_DOMAIN unknown — skipping FleetView login check"
        return
    fi
    url="https://keycloak-ui.${base_domain}/realms/sdv-telemetry/protocol/openid-connect/auth"
    url="${url}?client_id=data-web-client&response_type=code&scope=openid"
    url="${url}&redirect_uri=https%3A%2F%2Ffleetview.${base_domain}%2Fapi%2Fauth%2Fcallback%2Fkeycloak"
    body=$(with_timeout 15 curl -ks --connect-timeout 5 --max-time 12 "$url" 2>/dev/null || true)
    if [ -z "$body" ]; then
        record_warn "FleetView login endpoint gave no answer — Keycloak UI may still be starting"
    elif grep -qi 'Invalid parameter: redirect_uri' <<<"$body"; then
        record_fail "FleetView login rejected: the data-web-client redirect URI is not registered. Re-run build-push-deploy-data-web-client."
    else
        record_pass "FleetView login accepts its redirect URI"
    fi
}

# The Factory Helper serves an unauthenticated GET /health (main.rs:84). Nothing
# checked this endpoint before: the health check knew the service only by its TLS
# certificate in Secret Manager, so nst1-149 scored 43 PASS while the endpoint was
# dead and the failure surfaced two layers away, as a failing data pipeline.
# It exists only with remote PKI, and being a LoadBalancer behind external-dns it
# is the last endpoint to become answerable — which is why it is checked here,
# before the data pipeline runs against it.
check_factory_endpoint() {
    local base_domain="$1" url
    if [ "${PKI_STRATEGY:-}" = "local" ]; then
        log_info "Factory Helper not deployed with local PKI — skipping"
        return
    fi
    if [ -z "$base_domain" ]; then
        record_warn "BASE_DOMAIN unknown — skipping Factory Helper check"
        return
    fi
    url="https://factory.${base_domain}:8443/health"
    if probe_retry 6 10 http_answers "$url"; then
        record_pass "Factory Helper responding at $url"
    else
        record_fail "Factory Helper NOT responding at $url (6 attempts over ~1 minute)"
    fi
}

# Keycloak's Service exposes 8443 in both PKI modes. The browser Ingress on 443
# (remote PKI) has its own hostname, keycloak-ui, which this check does not cover.
# -k because local mode uses a self-signed cert and remote mode a private CA.
check_keycloak_endpoint() {
    local addr="$1" url code
    if [ -z "$addr" ]; then
        record_warn "Keycloak endpoint unknown — skipping ping"
        return
    fi
    url="https://${addr}:8443/"
    code=$(with_timeout 10 curl -ks -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 8 "$url" 2>/dev/null || true)
    if [ -n "$code" ] && [ "$code" != "000" ]; then
        record_pass "Keycloak responding at $url (HTTP $code)"
    else
        record_fail "Keycloak NOT responding at $url"
    fi
}

# /healthz (port 8222) is NATS's real health endpoint, not just a port probe.
check_nats_endpoint() {
    local addr="$1" url code
    if [ -z "$addr" ]; then
        record_warn "NATS endpoint unknown — skipping ping"
        return
    fi
    url="http://${addr}:8222/healthz"
    code=$(with_timeout 10 curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 8 "$url" 2>/dev/null || true)
    if [ "$code" = "200" ]; then
        record_pass "NATS healthy at $url"
    elif [ -n "$code" ] && [ "$code" != "000" ]; then
        record_warn "NATS monitoring endpoint returned HTTP $code at $url"
    else
        record_fail "NATS NOT reachable at $url"
    fi
}

# ---------------------------------------------------------------------------
# Nodes
# ---------------------------------------------------------------------------
check_nodes() {
    log_section "Nodes"

    KUBECTL_READY=false
    if [ -z "$GKE_CLUSTER_NAME" ]; then
        record_warn "kubectl checks skipped: no GKE cluster found"
    elif ! gcloud container clusters get-credentials "$GKE_CLUSTER_NAME" \
            --region="$GKE_CLUSTER_LOCATION" --project="$GCP_PROJECT_ID" --quiet 2>/dev/null; then
        record_fail "Could not get kubectl credentials for cluster $GKE_CLUSTER_NAME (region: $GKE_CLUSTER_LOCATION)"
    else
        # get-credentials only writes a kubeconfig entry; it doesn't confirm
        # the API server is reachable. Probe once here so a blocked
        # master_authorized_networks (iac/terraform/gke.tf) shows up as one
        # clear failure instead of every later check separately misreporting it.
        local nodes_output kubectl_rc
        nodes_output=$(with_timeout 15 kubectl "${KUBECTL_OPTS[@]}" get nodes --no-headers 2>/dev/null)
        kubectl_rc=$?
        if [ "$kubectl_rc" -ne 0 ]; then
            record_fail "kubectl unreachable for cluster $GKE_CLUSTER_NAME — timed out or blocked (likely master_authorized_networks rejecting this network; expected when running outside GCP's own IP ranges). Skipping remaining cluster checks for this environment."
        elif [ -z "$nodes_output" ]; then
            record_fail "No GKE nodes found"
        else
            KUBECTL_READY=true
            record_pass "kubectl connected to $GKE_CLUSTER_NAME"
            record_pass "GKE nodes ready: $(echo "$nodes_output" | wc -l | tr -d ' ')"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Certificates
# ---------------------------------------------------------------------------
# Expiry of one PEM certificate kept in Secret Manager. The warning threshold
# differs per certificate class: CA certificates live for years, while the
# platform's service certificates are issued for 30 days and renewed manually
# (see iac/operating/nexus-cert-status.sh), so warning 30 days ahead would fire
# on every freshly issued one.
check_cert_secret_expiry() {
    local secret="$1" warn_seconds="$2" warn_label="$3" pem
    pem=$(gcloud secrets versions access latest --secret="$secret" --project="$GCP_PROJECT_ID" 2>/dev/null || true)
    if [ -z "$pem" ]; then
        record_warn "Secret $secret not found — skipping expiry check"
    elif ! echo "$pem" | openssl x509 -noout -checkend 0 >/dev/null 2>&1; then
        record_fail "$secret has already expired"
    elif ! echo "$pem" | openssl x509 -noout -checkend "$warn_seconds" >/dev/null 2>&1; then
        record_warn "$secret expires within $warn_label"
    else
        record_pass "$secret not expiring within $warn_label"
    fi
}

check_certificates() {
    log_section "Certificates"

    if [ "${PKI_STRATEGY:-}" = "remote" ]; then
        local server_pool
        server_pool=$(resolve_var EXISTING_SERVER_CA_POOL SERVER_CA_POOL)
        if [ -z "$server_pool" ]; then
            record_warn "No server CA pool known for this environment — skipping CAS check"
        else
            # A CA pool has no state of its own — describe returns only labels,
            # name, publishingOptions and tier — so asking for value(state)
            # always came back empty and this check could never pass. What has a
            # state is the CA inside the pool, and that is what matters: an
            # existing pool whose CA is disabled issues nothing.
            local pool_name ca_states
            pool_name=$(gcloud privateca pools describe "$server_pool" --location="$GCP_REGION" \
                --project="$GCP_PROJECT_ID" --format='value(name)' 2>/dev/null || true)
            if [ -z "$pool_name" ]; then
                record_fail "Server CA pool not found: $server_pool"
            else
                ca_states=$(gcloud privateca roots list --pool="$server_pool" --location="$GCP_REGION" \
                    --project="$GCP_PROJECT_ID" --format='value(state)' 2>/dev/null || true)
                if [ -z "$ca_states" ]; then
                    record_fail "Server CA pool has no certificate authority: $server_pool"
                elif grep -q '^ENABLED$' <<<"$ca_states"; then
                    record_pass "Server CA pool has an enabled CA: $server_pool"
                else
                    record_fail "Server CA pool has no enabled CA (states: $(tr '\n' ' ' <<<"$ca_states")): $server_pool"
                fi
            fi

            # Issued certificates cannot be listed from the pool: all three pools
            # are DEVOPS tier (iac/terraform/pki.tf), which does not store them.
            # What the platform actually runs on is in Secret Manager — the CA
            # certificates written by the bootstrap, and the five 30-day service
            # certificates that nexus-cert-status.sh renews. SERVER_CA_CERT is
            # local-mode only; remote mode reads the server root from CAS.
            for secret in REGISTRATION_CA_CERT REGISTRATION_FACTORY_CA_CERT; do
                check_cert_secret_expiry "$secret" 2592000 "30 days"
            done
            # All five 30-day service certificates, not the three this comment
            # used to name: factory-helper's and the NATS leaf's were issued the
            # same way and watched by nothing (F12, 2026-09-25).
            for secret in KEYCLOAK_TLS_CRT REGISTRATION_SERVER_TLS_CERT FLEETVIEW_TLS_CRT \
                          FACTORY_HELPER_TLS_CERT NATS_LEAF_TLS_CERT; do
                check_cert_secret_expiry "$secret" 604800 "7 days"
            done
        fi
    else
        # The NATS leaf certificate is issued on this path too — self-signed for
        # a year, so the CA threshold rather than the 7-day one.
        for secret in SERVER_CA_CERT REGISTRATION_CA_CERT REGISTRATION_FACTORY_CA_CERT NATS_LEAF_TLS_CERT; do
            check_cert_secret_expiry "$secret" 2592000 "30 days"
        done
    fi
}

# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------
check_endpoints() {
    log_section "Endpoints"

    local base_domain
    base_domain=$(resolve_var BASE_DOMAIN BASE_DOMAIN)

    if [ "${PKI_STRATEGY:-}" = "local" ]; then
        # Local PKI uses IPs directly, no DNS labels to resolve.
        log_info "No DNS to check (PKI_STRATEGY=local)"
    elif [ -z "$base_domain" ]; then
        record_warn "BASE_DOMAIN unknown — skipping DNS checks"
    else
        check_dns "${KEYCLOAK_HOSTNAME:-}" "$base_domain" "Keycloak"
        check_dns "${NATS_HOSTNAME:-}" "$base_domain" "NATS"
        check_dns "${REGISTRATION_HOSTNAME:-}" "$base_domain" "Registration"
    fi

    local keycloak_addr nats_addr registration_addr
    keycloak_addr=$(resolve_endpoint "${KEYCLOAK_HOSTNAME:-}" "$base_domain")
    nats_addr=$(resolve_endpoint "${NATS_HOSTNAME:-}" "$base_domain")
    registration_addr=$(resolve_endpoint "${REGISTRATION_HOSTNAME:-}" "$base_domain")

    check_keycloak_endpoint "$keycloak_addr"
    check_nats_endpoint "$nats_addr"
    check_tcp_port "$registration_addr" 8443 "Registration"
    check_factory_endpoint "$base_domain"
    check_fleetview_login "$base_domain"
}

# ---------------------------------------------------------------------------
# Base Services
# ---------------------------------------------------------------------------
check_base_services() {
    log_section "Base Services"

    if [ "$KUBECTL_READY" != true ]; then
        record_warn "Base services checks skipped: kubectl was unreachable during the nodes check for this environment"
        return
    fi

    log_info "Only Keycloak/Registration have real readinessProbes; other services' checks above only confirm the container is running."

    local deployments
    deployments=$(with_timeout 15 kubectl "${KUBECTL_OPTS[@]}" get deployments -n base-services \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.availableReplicas}{"\t"}{.spec.replicas}{"\n"}{end}' 2>/dev/null || true)
    if [ -z "$deployments" ]; then
        record_warn "No deployments found in namespace base-services"
    else
        while IFS=$'\t' read -r name available desired; do
            [ -z "$name" ] && continue
            available="${available:-0}"
            desired="${desired:-0}"
            if [ "$available" -ge 1 ] && [ "$available" -ge "$desired" ]; then
                record_pass "Deployment '$name' available ($available/$desired)"
            else
                record_fail "Deployment '$name' not fully available ($available/$desired)"
            fi
        done <<< "$deployments"
    fi

    local statefulsets
    statefulsets=$(with_timeout 15 kubectl "${KUBECTL_OPTS[@]}" get statefulsets -n base-services \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.readyReplicas}{"\t"}{.spec.replicas}{"\n"}{end}' 2>/dev/null || true)
    while IFS=$'\t' read -r name ready desired; do
        [ -z "$name" ] && continue
        ready="${ready:-0}"
        desired="${desired:-0}"
        if [ "$ready" -ge 1 ] && [ "$ready" -ge "$desired" ]; then
            record_pass "StatefulSet '$name' ready ($ready/$desired)"
        else
            record_fail "StatefulSet '$name' not fully ready ($ready/$desired)"
        fi
    done <<< "$statefulsets"

    local nats_phases
    nats_phases=$(with_timeout 15 kubectl "${KUBECTL_OPTS[@]}" get pods -n base-services -l app.kubernetes.io/instance=nats \
        -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null || true)
    if [ -z "$nats_phases" ]; then
        record_warn "No NATS pods found in base-services (label app.kubernetes.io/instance=nats)"
    elif echo "$nats_phases" | grep -qv '^Running$'; then
        record_fail "NATS pod(s) not all Running: $(echo "$nats_phases" | tr '\n' ' ')"
    else
        record_pass "NATS pod(s) Running ($(echo "$nats_phases" | wc -l | tr -d ' '))"
    fi
}

# ---------------------------------------------------------------------------
# Data Pipeline
# ---------------------------------------------------------------------------
check_e2e_pipeline() {
    log_section "Data Pipeline"

    if [ -z "$BOOTSTRAP_ENV_GCS_PATH" ]; then
        record_warn "E2E check skipped: this environment's .bootstrap_env is not a gs:// path (run-sample-clients.yaml needs one to download it)"
        return
    fi

    log_info "Submitting run-sample-clients.yaml (publishes real telemetry; can take a few minutes)..."
    if gcloud builds submit "$PROJECT_ROOT" \
            --config="$PROJECT_ROOT/iac/cloudbuild/run-sample-clients.yaml" \
            --project="$GCP_PROJECT_ID" \
            --region="$GCP_REGION" \
            --substitutions=_BOOTSTRAP_ENV_GCS_PATH="$BOOTSTRAP_ENV_GCS_PATH" \
            --quiet >/dev/null 2>&1; then
        record_pass "Data pipeline end-to-end smoke test passed (run-sample-clients)"
    else
        record_fail "Data pipeline end-to-end smoke test failed (run-sample-clients) — see Cloud Build logs"
    fi
}

CHECK_FUNCTIONS=(check_apis check_cloudbuild_triggers check_infrastructure check_nodes
    check_certificates check_endpoints check_base_services)

# Appends one Cloud Monitoring point to METRICS_QUEUE_FILE. No-op unless
# --report-metrics was passed.
queue_metric_point() {
    [ "$REPORT_METRICS" = true ] || return
    local metric="$1" env_label="$2" section="$3" value="$4"
    jq -nc --arg type "custom.googleapis.com/platform_health/${metric}_count" \
        --arg env "$env_label" --arg section "$section" --arg project "$GCP_PROJECT_ID" \
        --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson value "$value" \
        '{metric: {type: $type, labels: {environment: $env, section: $section}},
          resource: {type: "global", labels: {project_id: $project}},
          points: [{interval: {endTime: $now}, value: {int64Value: ($value | tostring)}}]}' \
        >> "$METRICS_QUEUE_FILE"
}

# Cloud Monitoring label values are capped at 1024 bytes; truncate defensively
# so a verbose failure message can't get the whole batch push rejected.
truncate_label() {
    local s="$1" max=500
    if [ "${#s}" -gt "$max" ]; then
        printf '%s…' "${s:0:$max}"
    else
        printf '%s' "$s"
    fi
}

# Appends one fail_detail point (value 1 while active, 0 once cleared — see
# reconcile_fail_details) for a single reported failure.
queue_metric_detail_point() {
    [ "$REPORT_METRICS" = true ] || return
    local env_label="$1" section="$2" message="$3" value="${4:-1}"
    jq -nc --arg type "custom.googleapis.com/platform_health/fail_detail" \
        --arg env "$env_label" --arg section "$section" --arg project "$GCP_PROJECT_ID" \
        --arg message "$(truncate_label "$message")" \
        --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson value "$value" \
        '{metric: {type: $type, labels: {environment: $env, section: $section, message: $message}},
          resource: {type: "global", labels: {project_id: $project}},
          points: [{interval: {endTime: $now}, value: {int64Value: ($value | tostring)}}]}' \
        >> "$METRICS_QUEUE_FILE"
}

# GCS path for (label, section)'s previously-active failure messages, reusing
# the bootstrap-envs bucket convention. If the bucket doesn't exist,
# reconcile_fail_details's read/write below just fail and clearing is
# skipped for that run.
health_state_path() {
    local label="$1" section="$2"
    printf 'gs://%s-bootstrap-envs/.health-state/%s/%s.json' \
        "$GCP_PROJECT_ID" "${label//\//_}" "${section//\//_}"
}

# Diffs this run's failures against the previously-active set in GCS, queues
# a 0 (resolved) point for anything that didn't recur, then overwrites that
# state with the current set. Best-effort: a failed write just delays the
# next clear by one run.
reconcile_fail_details() {
    [ "$REPORT_METRICS" = true ] || return
    local label="$1" section="$2"; shift 2
    local -a current=()
    local cur
    for cur in "$@"; do
        current+=("$(truncate_label "$cur")")
    done

    local path prev_json
    path=$(health_state_path "$label" "$section")
    prev_json=$(gcloud storage cat "$path" 2>/dev/null) || prev_json='[]'
    jq -e 'type == "array"' >/dev/null 2>&1 <<< "$prev_json" || prev_json='[]'

    local msg
    while IFS= read -r msg; do
        [ -z "$msg" ] && continue
        printf '%s\n' "${current[@]+"${current[@]}"}" | grep -Fxq -- "$msg" ||
            queue_metric_detail_point "$label" "$section" "$msg" 0
    done < <(jq -r '.[]' <<< "$prev_json")

    jq -nc '$ARGS.positional' --args "${current[@]+"${current[@]}"}" \
        | gcloud storage cp - "$path" --quiet 2>/dev/null \
        || log_warn "Could not write fail-detail state to $path (env=$label section=$section)"
}

# Runs one check function and, under --report-metrics, queues its
# pass/warn/fail delta and per-failure points (section=<name>), then clears
# any of this section's failures that didn't recur.
run_section() {
    local label="$1" fn="$2" section="${2#check_}"
    local sp=$PASS sw=$WARN sf=$FAIL sd=${#FAIL_DETAILS[@]}
    "$fn"
    queue_metric_point pass "$label" "$section" "$((PASS - sp))"
    queue_metric_point warn "$label" "$section" "$((WARN - sw))"
    queue_metric_point fail "$label" "$section" "$((FAIL - sf))"

    local i
    local -a section_failures=()
    for ((i = sd; i < ${#FAIL_DETAILS[@]}; i++)); do
        queue_metric_detail_point "$label" "$section" "${FAIL_DETAILS[$i]}"
        section_failures+=("${FAIL_DETAILS[$i]}")
    done
    reconcile_fail_details "$label" "$section" "${section_failures[@]+"${section_failures[@]}"}"
}

# Batches this environment's queued points into groups of <=200 (the API's
# limit per request), POSTs each batch to the Monitoring API, then empties
# the queue file so the next environment starts fresh. No-op unless
# --report-metrics was passed (or nothing was queued).
push_metrics() {
    [ "$REPORT_METRICS" = true ] || return
    [ -s "$METRICS_QUEUE_FILE" ] || return

    log_info "Pushing queued health-check metrics to Cloud Monitoring..."
    local token chunk_dir chunk_file body http_code
    token=$(gcloud auth print-access-token)
    chunk_dir=$(mktemp -d)
    split -l 200 "$METRICS_QUEUE_FILE" "$chunk_dir/chunk_"

    for chunk_file in "$chunk_dir"/chunk_*; do
        body=$(jq -s '{timeSeries: .}' "$chunk_file")
        http_code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
            "https://monitoring.googleapis.com/v3/projects/${GCP_PROJECT_ID}/timeSeries" \
            -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" \
            -d "$body")
        [ "$http_code" = "200" ] || log_warn "Metric push returned HTTP $http_code for one batch"
    done
    rm -rf "$chunk_dir"
    : > "$METRICS_QUEUE_FILE"
}

# ---------------------------------------------------------------------------
# Per-environment orchestration
# ---------------------------------------------------------------------------
run_checks_for_env() {
    local label="$1"
    BOOTSTRAP_ENV_GCS_PATH="$2"

    log_section "Environment: $label (project=$GCP_PROJECT_ID)"
    local start_pass=$PASS start_warn=$WARN start_fail=$FAIL

    local fn
    for fn in "${CHECK_FUNCTIONS[@]}"; do
        run_section "$label" "$fn"
    done
    [ "$RUN_E2E" = true ] && run_section "$label" check_e2e_pipeline

    local env_pass=$((PASS - start_pass)) env_warn=$((WARN - start_warn)) env_fail=$((FAIL - start_fail))
    ENV_SUMMARY+=("${label}:${env_pass}:${env_warn}:${env_fail}")

    queue_metric_point pass "$label" all "$env_pass"
    queue_metric_point warn "$label" all "$env_warn"
    queue_metric_point fail "$label" all "$env_fail"

    # Push now, while GCP_PROJECT_ID still refers to this environment —
    # --envs-dir can span multiple projects.
    push_metrics
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "$MODE" in
    project)
        GCP_PROJECT_ID="$TARGET_PROJECT"
        GCP_REGION="${GCP_REGION:-europe-west3}"
        run_checks_for_env "$GCP_PROJECT_ID" ""
        ;;
    env-file)
        load_env_file "$ENV_FILE"
        case "$ENV_FILE" in
            gs://*) GCS_PATH="$ENV_FILE" ;;
            *)      GCS_PATH="" ;;
        esac
        run_checks_for_env "${ENV:-$GCP_PROJECT_ID}" "$GCS_PATH"
        ;;
    envs-dir)
        case "$ENVS_DIR" in
            */) ;;
            *)  ENVS_DIR="${ENVS_DIR}/" ;;
        esac
        log_info "Listing .bootstrap_env files in $ENVS_DIR..."
        FILES=$(gcloud storage ls "$ENVS_DIR" 2>/dev/null | grep -v '/$' || true)
        [ -z "$FILES" ] && log_error "No .bootstrap_env files found in $ENVS_DIR"
        for ENV_PATH in $FILES; do
            load_env_file "$ENV_PATH"
            run_checks_for_env "${ENV:-$GCP_PROJECT_ID}" "$ENV_PATH"
        done
        ;;
esac

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log_section "Summary"
printf "%-30s %6s %6s %6s\n" "ENVIRONMENT" "PASS" "WARN" "FAIL"
TOTAL_WARN=0
TOTAL_FAIL=0
for row in "${ENV_SUMMARY[@]}"; do
    IFS=':' read -r label p w f <<< "$row"
    printf "%-30s %6s %6s %6s\n" "$label" "$p" "$w" "$f"
    TOTAL_WARN=$((TOTAL_WARN + w))
    TOTAL_FAIL=$((TOTAL_FAIL + f))
done
echo ""

if [ "$TOTAL_FAIL" -gt 0 ]; then
    log_warn "Overall: $TOTAL_FAIL failing check(s) across ${#ENV_SUMMARY[@]} environment(s)."
    exit 1
fi
if [ "$STRICT" = true ] && [ "$TOTAL_WARN" -gt 0 ]; then
    log_warn "Overall: $TOTAL_WARN warning(s) across ${#ENV_SUMMARY[@]} environment(s) (--strict)."
    exit 1
fi
log_ok "Overall: all checks passed across ${#ENV_SUMMARY[@]} environment(s)."
exit 0
