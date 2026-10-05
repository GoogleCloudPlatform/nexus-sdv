#!/bin/bash
# ==============================================================================
# Public PKI distribution bucket
#
# Server TLS certificates that every Nexus client must trust — KEYCLOAK_TLS_CRT
# and REGISTRATION_SERVER_TLS_CERT — are published to a public, read-only GCS
# bucket. They are public certificates with no private key, so a client can
# fetch them with no GCP credential at all, which is the point: a vehicle or an
# external party can obtain the trust anchor without being granted Secret
# Manager access to the instance.
#
# The fetch is protected by the WebPKI certificate of storage.googleapis.com,
# which clients already trust. That is why this works without prior trust in the
# instance's own endpoints.
#
# Sourced by the deploy pipelines that write those certificates to Secret
# Manager, so the bucket is refreshed wherever a certificate is written or
# rotated, rather than by a separate sync that can fall behind.
#
# Usage:
#   source iac/bootstrapping/lib/public-pki.sh
#   publish_public_pki <project> <region> <object-name> <local-file> [suffix]
#
# Bucket naming: `<project>-nexus-sdv-public`, derivable by any client that
# knows the project. GCS bucket names are globally unique, but project ids
# already are, so a collision means someone else deliberately took the name. In
# that case the optional suffix is appended and the resulting name is printed —
# the caller is responsible for recording it, because it is no longer derivable.
# ==============================================================================

# Resolves the bucket to use, creating it if needed. Echoes the bucket name.
# Returns non-zero only if no usable bucket could be established.
resolve_public_pki_bucket() {
    local project="$1" region="$2" suffix="${3:-}"
    local bucket="${project}-nexus-sdv-public"

    if gcloud storage buckets create "gs://${bucket}" \
            --project="$project" --location="$region" \
            --uniform-bucket-level-access >/dev/null 2>&1; then
        echo "$bucket"
        return 0
    fi

    # Creation failed: either it is already ours (the normal case on every run
    # after the first), or the globally unique name belongs to someone else.
    # `describe` cannot tell these apart — it returns permission denied for a
    # foreign bucket — so ask which buckets this project actually owns.
    if gcloud storage buckets list --project="$project" \
            --format='value(name)' 2>/dev/null | grep -qx "$bucket"; then
        echo "$bucket"
        return 0
    fi

    if [ -z "$suffix" ]; then
        echo "Bucket name gs://${bucket} is taken by another project and no suffix was given." >&2
        return 1
    fi

    local fallback="${bucket}-${suffix}"
    echo "Bucket name gs://${bucket} is taken by another project — using gs://${fallback} instead." >&2
    echo "This name is NOT derivable by clients; record it as PKI_PUBLIC_BUCKET." >&2
    if gcloud storage buckets create "gs://${fallback}" \
            --project="$project" --location="$region" \
            --uniform-bucket-level-access >/dev/null 2>&1 \
       || gcloud storage buckets list --project="$project" \
            --format='value(name)' 2>/dev/null | grep -qx "$fallback"; then
        echo "$fallback"
        return 0
    fi
    echo "Could not create gs://${fallback} either." >&2
    return 1
}

# Publishes one certificate into the bucket under pki/, creating and opening the
# bucket if necessary. Idempotent.
publish_public_pki() {
    local project="$1" region="$2" name="$3" file="$4" suffix="${5:-}"

    if [ ! -s "$file" ]; then
        echo "publish_public_pki: '$file' is missing or empty — not publishing ${name}." >&2
        return 1
    fi

    local bucket
    bucket=$(resolve_public_pki_bucket "$project" "$region" "$suffix") || return 1

    # allUsers/objectViewer is what makes this a credential-free trust-anchor
    # endpoint. Re-applied every time; the API is idempotent.
    gcloud storage buckets add-iam-policy-binding "gs://${bucket}" \
        --member=allUsers --role=roles/storage.objectViewer \
        --project="$project" >/dev/null 2>&1 \
        || { echo "publish_public_pki: could not make gs://${bucket} publicly readable." >&2; return 1; }

    if gcloud storage cp "$file" "gs://${bucket}/pki/${name}" --project="$project" >/dev/null 2>&1; then
        echo "Published ${name} to gs://${bucket}/pki/"
        PKI_PUBLIC_BUCKET="$bucket"
        return 0
    fi
    echo "publish_public_pki: upload of ${name} to gs://${bucket}/pki/ failed." >&2
    return 1
}
