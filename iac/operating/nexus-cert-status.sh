#!/usr/bin/env bash
# nexus-cert-status.sh — status + targeted renewal for Nexus platform-managed
# TLS certs (KEYCLOAK_TLS_CRT, REGISTRATION_SERVER_TLS_CERT, FLEETVIEW_TLS_CRT,
# FACTORY_HELPER_TLS_CERT, NATS_LEAF_TLS_CERT).
#
# All three are short-lived (30-day, GCP CAS-issued via `gcloud privateca
# certificates create --validity=P30D`) with NO automated renewal anywhere in
# the platform — confirmed: no Cloud Scheduler job, no CloudBuild trigger
# (`gcloud builds triggers list` returns none). The only way to get a fresh
# cert is to re-run the owning per-service CloudBuild pipeline manually.
# KEYCLOAK_TLS_CRT expired silently this way (2026-07-26) and blocked the
# Core3-TCU leaf's JWT bootstrap.
#
# This script does NOT mint certs itself (that logic already exists in each
# pipeline and works) and deliberately never invokes the full
# iac/cloudbuild/deploy-all.yaml orchestrator — that would redeploy the
# ENTIRE platform (external-dns, Keycloak, NATS, Registration, Data API,
# FleetView, connectors...) just to rotate one 30-day cert, a disproportionate
# blast radius for routine maintenance. Instead it invokes the single owning
# per-service pipeline directly.
#
# Substitutions are derived from iac/bootstrapping/.bootstrap_env — the same
# values iac/bootstrapping/lib/deployment.sh's trigger_cloudbuild_deployment()
# passes to deploy-all.yaml. This is a deliberate, small, independent copy
# (not sourced from lib/deployment.sh) so an operating-tool run never risks
# pulling in bootstrap's heavier logic (Terraform, CA-pool creation, initial
# secret seeding). To catch drift between this and lib/deployment.sh's own
# substitution derivation, a renewal always re-checks status immediately
# after, rather than trusting the two stay in sync by code-review alone.
#
# Usage:
#   ./nexus-cert-status.sh                    # status of all three certs
#   ./nexus-cert-status.sh --warn-days 14     # change the yellow threshold (default: 7)
#   ./nexus-cert-status.sh --renew <NAME>     # renew one cert (asks for confirmation)
#
# NAME is one of: KEYCLOAK_TLS_CRT, REGISTRATION_SERVER_TLS_CERT, FLEETVIEW_TLS_CRT
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." &>/dev/null && pwd)"
BOOTSTRAP_ENV="${REPO_ROOT}/iac/bootstrapping/.bootstrap_env"

if [ ! -f "$BOOTSTRAP_ENV" ]; then
    echo "Missing ${BOOTSTRAP_ENV} — this script needs the platform's .bootstrap_env" >&2
    echo "(fetch it: gcloud storage cp gs://<PROJECT_ID>-bootstrap-envs/.bootstrap_env ${BOOTSTRAP_ENV})" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$BOOTSTRAP_ENV"
: "${GCP_PROJECT_ID:?GCP_PROJECT_ID not set in .bootstrap_env}"
: "${GCP_REGION:?GCP_REGION not set in .bootstrap_env}"

WARN_DAYS=7
ACTION="status"
RENEW_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --warn-days) WARN_DAYS="$2"; shift 2 ;;
        --renew)     ACTION="renew"; RENEW_NAME="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# label | secret name | owning CloudBuild config (repo-relative) | full --substitutions value
# (mirrors exactly how iac/cloudbuild/deploy-all.yaml invokes each of these
# individually — see that file's per-step `gcloud builds submit` calls)
COMMIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo manual-latest)"
CERTS=(
    "KEYCLOAK_TLS_CRT|KEYCLOAK_TLS_CRT|iac/cloudbuild/deploy-keycloak.yaml|_ARCH=${ARCH}::_PKI_STRATEGY=${PKI_STRATEGY}::_BASE_DOMAIN=${BASE_DOMAIN}::_HELM_ACTION=sync"
    "REGISTRATION_SERVER_TLS_CERT|REGISTRATION_SERVER_TLS_CERT|iac/cloudbuild/build-push-deploy-registration.yaml|_ARCH=${ARCH}::_PKI_STRATEGY=${PKI_STRATEGY}::_BASE_DOMAIN=${BASE_DOMAIN}::_HELM_ACTION=sync::_COMMIT_SHA=${COMMIT_SHA}"
    "FLEETVIEW_TLS_CRT|FLEETVIEW_TLS_CRT|iac/cloudbuild/build-push-deploy-data-web-client.yaml|_ARCH=${ARCH}::_HELM_ACTION=sync"
    # Added 2026-09-25 (F12). Both are issued with the same 30-day validity as
    # the three above and were covered by neither this script nor the health
    # check, which is how a certificate can expire with nobody warned.
    # factory-helper exists only with remote PKI; the NATS leaf certificate
    # exists in both, self-signed for a year on the local path.
    "FACTORY_HELPER_TLS_CERT|FACTORY_HELPER_TLS_CERT|iac/cloudbuild/build-push-deploy-factory-helper.yaml|_ARCH=${ARCH}::_HELM_ACTION=sync::_COMMIT_SHA=${COMMIT_SHA}"
    "NATS_LEAF_TLS_CERT|NATS_LEAF_TLS_CERT|iac/cloudbuild/deploy-nats.yaml|_ARCH=${ARCH}::_PKI_STRATEGY=${PKI_STRATEGY}::_BASE_DOMAIN=${BASE_DOMAIN}::_HELM_ACTION=sync"
)

# KEYCLOAK_TLS_CRT / REGISTRATION_SERVER_TLS_CERT are also mirrored to a public,
# unauthenticated GCS bucket so any Nexus client can fetch them without Secret
# Manager IAM. The deploy pipelines publish there themselves (#478), so the
# renewal below is belt and braces — it also covers a pipeline whose publish
# step failed. Sharing the helper keeps bucket resolution identical everywhere,
# including the collision fallback, for which the suffix is available here.
# shellcheck source=/dev/null
source "${REPO_ROOT}/iac/bootstrapping/lib/public-pki.sh"

check_one() {
    local label="$1" secret="$2"
    local pem
    local err
    if ! pem="$(gcloud secrets versions access latest --secret="$secret" --project="$GCP_PROJECT_ID" 2>/tmp/nexus-cert-status.err)"; then
        err="$(cat /tmp/nexus-cert-status.err 2>/dev/null)"; rm -f /tmp/nexus-cert-status.err
        # "Absent" and "you may not look" are different answers, and so is "this
        # platform never creates it": FleetView's certificate and the Factory
        # Helper's are issued only with remote PKI
        # (build-push-deploy-data-web-client.yaml:145,
        #  build-push-deploy-factory-helper.yaml:95).
        if grep -qi 'PERMISSION_DENIED\|does not have permission\|Reauthentication' <<<"$err"; then
            printf "  %-30s ⚪ no access — check gcloud auth login\n" "$label"
        elif [ "${PKI_STRATEGY:-}" = "local" ] && \
             { [ "$secret" = "FLEETVIEW_TLS_CRT" ] || [ "$secret" = "FACTORY_HELPER_TLS_CERT" ]; }; then
            printf "  %-30s ⚪ not issued with local PKI\n" "$label"
        else
            printf "  %-30s ⚪ secret not found\n" "$label"
        fi
        return 0
    fi
    local enddate
    enddate="$(openssl x509 -noout -enddate <<<"$pem" 2>/dev/null | cut -d= -f2)"
    if [ -z "$enddate" ]; then
        printf "  %-30s ⚪ could not parse certificate\n" "$label"
        return 0
    fi
    if ! openssl x509 -checkend 0 <<<"$pem" &>/dev/null; then
        printf "  %-30s \xf0\x9f\x94\xb4 EXPIRED (%s)\n" "$label" "$enddate"
    elif ! openssl x509 -checkend "$(( WARN_DAYS * 86400 ))" <<<"$pem" &>/dev/null; then
        printf "  %-30s \xf0\x9f\x9f\xa1 expires within %dd (%s)\n" "$label" "$WARN_DAYS" "$enddate"
    else
        printf "  %-30s \xf0\x9f\x9f\xa2 valid (until %s)\n" "$label" "$enddate"
    fi
}

print_status() {
    echo "Nexus platform TLS certificate status (project: ${GCP_PROJECT_ID})"
    echo
    for entry in "${CERTS[@]}"; do
        IFS='|' read -r label secret _ _ <<<"$entry"
        check_one "$label" "$secret"
    done
}

renew_one() {
    local target="$1"
    for entry in "${CERTS[@]}"; do
        IFS='|' read -r label secret config subs <<<"$entry"
        [ "$label" = "$target" ] || continue

        echo "About to run:"
        echo
        echo "  gcloud builds submit ${REPO_ROOT} \\"
        echo "    --config=${REPO_ROOT}/${config} \\"
        echo "    --project=${GCP_PROJECT_ID} \\"
        echo "    --region=${GCP_REGION} \\"
        echo "    --substitutions=^::^${subs}"
        echo
        echo "This redeploys the owning service live (not read-only)."
        read -rp "Proceed? [y/N] " CONFIRM
        [ "$CONFIRM" = "y" ] || { echo "Aborted."; exit 1; }

        gcloud builds submit "$REPO_ROOT" \
            --config="${REPO_ROOT}/${config}" \
            --project="$GCP_PROJECT_ID" \
            --region="$GCP_REGION" \
            --substitutions="^::^${subs}"

        if [ "$label" = "KEYCLOAK_TLS_CRT" ] || [ "$label" = "REGISTRATION_SERVER_TLS_CERT" ]; then
            echo
            echo "Re-publishing ${label} to the public PKI bucket..."
            _tmp_pem="$(mktemp)"
            if gcloud secrets versions access latest --secret="$secret" \
                    --project="$GCP_PROJECT_ID" > "$_tmp_pem"; then
                publish_public_pki "$GCP_PROJECT_ID" "$GCP_REGION" "${label}.pem" \
                    "$_tmp_pem" "${DEPLOYMENT_SUFFIX:-}" \
                    || echo "WARNING: re-publish failed — the public copy may be stale."
            else
                echo "WARNING: could not read ${secret} — public copy not refreshed." >&2
            fi
            rm -f "$_tmp_pem"
        fi

        # The factory-helper trusts Keycloak through Keycloak's own 30-day leaf
        # certificate, not the root above it: the pipeline copies KEYCLOAK_TLS_CRT
        # into the pod as keycloak-ca.pem (build-push-deploy-factory-helper.yaml,
        # iac/helm/factory-helper/templates/secret.yaml). A Keycloak renewal
        # therefore leaves the pod pinned to the certificate just replaced, after
        # which it rejects every valid token and logs no reason (F45, 2026-10-01).
        if [ "$label" = "KEYCLOAK_TLS_CRT" ] && [ "${PKI_STRATEGY}" = "remote" ]; then
            echo
            echo "NOTE: the factory-helper still trusts the certificate you just replaced."
            echo "Renew it as well, or it will reject every valid token without saying why:"
            echo
            echo "  $0 --renew FACTORY_HELPER_TLS_CERT"
        fi

        echo
        echo "✓ Pipeline finished — re-checking status:"
        check_one "$label" "$secret"
        return 0
    done

    echo "Unknown cert name: ${target}" >&2
    echo -n "Known names: " >&2
    for e in "${CERTS[@]}"; do IFS='|' read -r l _ _ _ <<<"$e"; printf '%s ' "$l" >&2; done
    echo >&2
    exit 1
}

if [ "$ACTION" = "renew" ]; then
    renew_one "$RENEW_NAME"
else
    print_status
fi
