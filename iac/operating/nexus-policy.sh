#!/bin/bash
# ==============================================================================
# Shared do-not-touch policy for the Nexus operating tools.
#
# Sourced by nexus-scan-gcp.sh and nexus-force-cleanup.sh so the rules live in
# one place. This file only defines variables — it runs nothing.
#
# BLOCKED_PROJECTS   refused outright: no scan verdict, no cleanup, ever.
# PROTECTED_*        resources that must survive a cleanup of an otherwise
#                    eligible project.
#
# The lists are empty here. An installation keeps its own entries in
# nexus-policy.local.sh next to this file, which is loaded when present.
# ==============================================================================

# One project per line: <project-id>|<reason>
BLOCKED_PROJECTS=""

# DNS zones that must keep every record, e.g. a zone that also serves unrelated
# public sites. A blanket "delete everything except SOA and NS" would take them
# offline.
PROTECTED_DNS_ZONES=""

# Projects whose Compute Engine instances must never be deleted.
PROTECTED_VMS_PROJECTS=""

# DNS record names a Nexus teardown may remove from an unprotected zone.
# Everything else in a zone belongs to someone else and is left alone.
NEXUS_DNS_RECORD_PREFIXES="nats keycloak registration fleetview factory external-dns"

# Regions searched when a project's own region cannot be determined, and always
# swept for CA pools and Cloud Build triggers: both are regional, and orphans
# from earlier generations outlive the GKE cluster and GCP_REGION secret that
# would otherwise identify the region. Querying the wrong region succeeds and
# returns an empty list, which reads as "nothing to clean up".
CANDIDATE_REGIONS="europe-west4 europe-west3 europe-central2 us-west1"

blocked_reason() {
    awk -F'|' -v p="$1" '$1 == p { print $2 }' <<<"$BLOCKED_PROJECTS"
}

# Installation-specific entries override the empty defaults above.
NEXUS_POLICY_SOURCE="built-in defaults — no projects protected"
if [ -f "$(dirname "${BASH_SOURCE[0]}")/nexus-policy.local.sh" ]; then
    # shellcheck source=/dev/null
    source "$(dirname "${BASH_SOURCE[0]}")/nexus-policy.local.sh"
    NEXUS_POLICY_SOURCE="nexus-policy.local.sh"
fi
