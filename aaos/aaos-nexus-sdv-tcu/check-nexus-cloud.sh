#!/usr/bin/env bash
# Is the Nexus cloud there? Checks one instance station by station, from the host the
# tests run on, with nothing but curl and openssl — no gcloud, no adb, no guest.
#
# Each station is a piece of the cloud a vehicle meets on its way in, in the order it meets
# them: the trust anchors it recognises the servers by, the servers themselves, the hub its
# leaf links to, and — on request — the operator login and a vehicle identity. Every line
# says what was found and what that station is for, so the output doubles as an explanation
# of the cloud integration. A failure does not stop the run: every station is checked, and
# the summary counts them.
#
# Usage:
#   ./check-nexus-cloud.sh <base-domain> [--login] [--identity <VIN>]
#     --login           also log in as operator at Keycloak (station 4)
#     --identity <VIN>  also log in, and have factory-helper issue a vehicle identity for
#                       <VIN> (station 5). This issues a REAL identity for that VIN; the
#                       private key is kept in a temporary file, never printed, and deleted
#                       when the script ends.
#   The operator credential comes from FACTORY_CLIENT_ID / FACTORY_OPERATOR_CLIENT_SECRET,
#   or is asked for. The secret never appears on a command line, and under bash -x the trace
#   stops before station 4, so neither the secret, the token nor the key reaches it.
#   (FACTORY_HOSTNAME=<name> — factory-helper's host name if not "factory")
#   PKI_BUCKET_PROJECT=<project> — the GCP project of the Nexus instance; its public bucket
#                       holds the trust anchors. Required.
# Example:
#   PKI_BUCKET_PROJECT=my-nexus-project ./check-nexus-cloud.sh nexus.example.org
#
# Exit status: 0 if nothing failed (warnings do not fail), 1 if a check failed, 2 on a usage
# error. Works on Linux and macOS (bash 3.2 and newer).
set -u

usage() { sed -n '/^# Usage:/,/^# Exit status/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//' >&2; exit 2; }

BASE_DOMAIN=""; DO_LOGIN=no; VIN=""
while [ $# -gt 0 ]; do
    case "$1" in
        --login) DO_LOGIN=yes ;;
        --identity) [ $# -ge 2 ] || usage; VIN="$2"; DO_LOGIN=yes; shift ;;
        -h|--help) usage ;;
        -*) echo "unknown option: $1" >&2; usage ;;
        *) [ -z "$BASE_DOMAIN" ] || usage; BASE_DOMAIN="$1" ;;
    esac
    shift
done
[ -n "$BASE_DOMAIN" ] || usage
# Both go into URLs and a JSON body: refuse anything that is not plainly a name or a VIN.
[[ "$BASE_DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || { echo "not a domain name: ${BASE_DOMAIN}" >&2; exit 2; }
if [ -n "$VIN" ] && ! [[ "$VIN" =~ ^[A-Z0-9]{1,17}$ ]]; then
    echo "not a VIN (1 to 17 capital letters and digits): ${VIN}" >&2; exit 2
fi
FACTORY_HOSTNAME="${FACTORY_HOSTNAME:-factory}"
[[ "$FACTORY_HOSTNAME" =~ ^[A-Za-z0-9-]+$ ]] || { echo "not a host name: ${FACTORY_HOSTNAME}" >&2; exit 2; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 2; }
command -v openssl >/dev/null || { echo "openssl is required" >&2; exit 2; }

KEYCLOAK="keycloak.${BASE_DOMAIN}"
FACTORY="${FACTORY_HOSTNAME}.${BASE_DOMAIN}"
REGISTRATION="registration.${BASE_DOMAIN}"
NATS="nats.${BASE_DOMAIN}"
# The trust anchors come from the public bucket of the GCP project the Nexus instance runs
# in. There is no default: a silent one pointed every other instance at the wrong cloud's
# certificates (seen 2026-10-10).
if [ -z "${PKI_BUCKET_PROJECT:-}" ]; then
    echo "set PKI_BUCKET_PROJECT=<GCP project of the Nexus instance at $BASE_DOMAIN> — its public bucket holds the trust anchors" >&2
    exit 2
fi
BUCKET="https://storage.googleapis.com/${PKI_BUCKET_PROJECT}-nexus-sdv-public/pki"
# Server certificates in this cloud last 30 days (F44); fewer than this many left is a warning.
WARN_DAYS=14

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASSED=0; FAILED=0; WARNED=0
good() { echo "  ✓ $*"; PASSED=$((PASSED + 1)); }
bad()  { echo "  ✗ $*"; FAILED=$((FAILED + 1)); }
warn() { echo "  ! $*"; WARNED=$((WARNED + 1)); }
note() { echo "  note: $*"; }

# The certificate a server presented, from openssl s_client's output on stdin.
served_cert() { awk '/-----BEGIN CERTIFICATE-----/{p=1} p{print} /-----END CERTIFICATE-----/{if (p) exit}'; }
expiry_date() { openssl x509 -in "$1" -noout -enddate 2>/dev/null | sed 's/^notAfter=//'; }
# Whole days a certificate has left. `date` cannot parse a certificate date the same way on
# Linux and macOS, so ask openssl instead: -checkend says whether the certificate is still
# valid that many seconds from now, and a bisection finds the last day it is.
days_left() {
    local lo=0 hi=36500 mid
    while [ $((hi - lo)) -gt 1 ]; do
        mid=$(((lo + hi) / 2))
        if openssl x509 -in "$1" -noout -checkend $((mid * 86400)) >/dev/null 2>&1; then lo=$mid; else hi=$mid; fi
    done
    echo "$lo"
}
expired() { ! openssl x509 -in "$1" -noout -checkend 0 >/dev/null 2>&1; }

echo "Nexus cloud ${BASE_DOMAIN}"

echo "=== 1/5 trust anchors from the public PKI bucket ==="
# fetch_anchor <file> <what it is for>
fetch_anchor() {
    local rc=0
    curl -sf --max-time 30 "${BUCKET}/$1" -o "$WORK/$1" || rc=$?
    if [ "$rc" -ne 0 ]; then rm -f "$WORK/$1"; return "$rc"; fi
    openssl x509 -in "$WORK/$1" -noout 2>/dev/null || { rm -f "$WORK/$1"; return 99; }
}
anchor() {
    local rc=0
    fetch_anchor "$1" || rc=$?
    case "$rc" in
        0)  good "$1 — $2" ;;
        99) bad "$1 is in the bucket but is no certificate — $2" ;;
        *)  bad "$1 could not be fetched from ${BUCKET} (curl exit ${rc}) — $2" ;;
    esac
}
anchor KEYCLOAK_TLS_CRT.pem "how a vehicle and an operator recognise Keycloak, which issues access tokens, and factory-helper"
anchor REGISTRATION_SERVER_TLS_CERT.pem "how a vehicle recognises the registration server, which swaps its factory identity for its everyday one"
LEAF_ANCHOR=no
WHY_LEAF_ANCHOR="how the vehicle's leaf recognises the hub when it opens the leaf link over TLS"
RC=0
fetch_anchor NATS_LEAF_TLS_CA.pem || RC=$?
# Only a missing file (HTTP error, curl exit 22) means the hub publishes no anchor.
case "$RC" in
    0)  LEAF_ANCHOR=yes; good "NATS_LEAF_TLS_CA.pem — ${WHY_LEAF_ANCHOR}" ;;
    22) note "the bucket holds no NATS_LEAF_TLS_CA.pem: this hub has no TLS on its leaf port, and a vehicle opens the leaf link without it" ;;
    99) bad "NATS_LEAF_TLS_CA.pem is in the bucket but is no certificate — ${WHY_LEAF_ANCHOR}" ;;
    *)  bad "NATS_LEAF_TLS_CA.pem could not be fetched from ${BUCKET} (curl exit ${RC}) — ${WHY_LEAF_ANCHOR}" ;;
esac

echo "=== 2/5 TLS endpoints, verified against those anchors ==="
# OpenSSL's s_client checks the host name when asked to. LibreSSL's (macOS) cannot, and it
# also accepts certificates from the system's trust store besides -CAfile; say so rather than
# let "verified" claim more than it means there.
OPENSSL_VERSION="$(openssl version 2>/dev/null)"
case "$OPENSSL_VERSION" in
    OpenSSL*) VERIFY_NAME=yes ;;
    *) VERIFY_NAME=no
       warn "this host's openssl is ${OPENSSL_VERSION:-unknown}: it also accepts any CA the system trusts and does not check the host name, so \"verified\" below is weaker than with OpenSSL" ;;
esac
# endpoint <host> <port> <anchor file> <what it is for>
endpoint() {
    local host="$1" port="$2" anchor="$3" why="$4" rc=0 out days until reason
    local name_args=()
    [ "$VERIFY_NAME" = no ] || name_args=(-verify_hostname "$host")
    # curl first: its exit status tells "does not resolve" from "no answer" the same way on
    # every platform, and with the anchor it also says whether it accepts the certificate.
    # Without the anchor it can only tell whether the server is there.
    if [ -s "$WORK/$anchor" ]; then
        curl -s --max-time 5 --cacert "$WORK/$anchor" -o /dev/null "https://${host}:${port}/" || rc=$?
    else
        curl -sk --max-time 5 -o /dev/null "https://${host}:${port}/" || rc=$?
    fi
    case "$rc" in
        0|22|51|60) ;;
        6)  bad "${host}:${port} — the name does not resolve: ${why}"; return ;;
        35) bad "${host}:${port} — answers, but completes no TLS handshake: ${why}"; return ;;
        *)  bad "${host}:${port} — no answer (curl exit ${rc}): ${why}"; return ;;
    esac
    [ -s "$WORK/$anchor" ] || { bad "${host}:${port} — answers, but cannot be verified without ${anchor} (station 1): ${why}"; return; }
    # Decided from the output, not the exit status: LibreSSL's s_client (macOS) exits 1 after
    # a verified handshake when its input ends.
    out="$(openssl s_client -connect "${host}:${port}" -servername "$host" -verify_return_error \
        -CAfile "$WORK/$anchor" ${name_args[@]+"${name_args[@]}"} </dev/null 2>&1)"
    if [ "$rc" != 51 ] && [ "$rc" != 60 ] && echo "$out" | grep -qE '^ *Verify return code: 0 \(ok\)$'; then
        echo "$out" | served_cert > "$WORK/served.pem"
        until="$(expiry_date "$WORK/served.pem")"; days="$(days_left "$WORK/served.pem")"
        good "${host}:${port} — verified against ${anchor}, valid until ${until} (${days} days left): ${why}"
        [ "$days" -ge "$WARN_DAYS" ] || warn "${host}:${port} — only ${days} days left; these certificates last 30 days and must be renewed before they run out (F44)"
        return
    fi
    # Not verified. Fetch the certificate without insisting on verification, to say why.
    out="$(openssl s_client -connect "${host}:${port}" -servername "$host" -CAfile "$WORK/$anchor" \
        ${name_args[@]+"${name_args[@]}"} </dev/null 2>/dev/null)"
    echo "$out" | served_cert > "$WORK/served.pem"
    reason="$(echo "$out" | sed -n 's/^ *Verify return code: //p' | head -1)"
    # openssl content while curl refused: curl's verdict is the one to report.
    case "$reason" in ""|"0 (ok)") reason="curl refused it, exit ${rc}" ;; esac
    if [ -s "$WORK/served.pem" ] && expired "$WORK/served.pem"; then
        bad "${host}:${port} — certificate expired on $(expiry_date "$WORK/served.pem"): ${why}"
    else
        bad "${host}:${port} — not verifiable against ${anchor} (${reason}): ${why}"
    fi
}
endpoint "$KEYCLOAK" 8443 KEYCLOAK_TLS_CRT.pem "the vehicle logs in here for the access token its leaf presents to the hub"
# factory-helper's certificate is signed by the CA the Keycloak anchor carries — the same
# anchor provision-and-run.sh verifies it with.
endpoint "$FACTORY" 8443 KEYCLOAK_TLS_CRT.pem "factory-helper, which plays the factory and issues a vehicle its factory identity"
endpoint "$REGISTRATION" 8443 REGISTRATION_SERVER_TLS_CERT.pem "the registration server, which swaps the factory identity for the everyday one"

echo "=== 3/5 the hub ==="
# hub_greeting <port>: reads the INFO greeting a NATS server sends on connect into HUB_INFO
# (empty if none came) and curl's exit status into HUB_RC; the caller decides.
hub_greeting() {
    local rc=0 out
    out="$(curl -s --max-time 3 "telnet://${NATS}:$1" </dev/null 2>/dev/null)" || rc=$?
    HUB_INFO="$(echo "$out" | grep '^INFO ' | head -1)"
    HUB_RC="$rc"
}
hub_version() { echo "$HUB_INFO" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p'; }
hub_unreached() {
    case "$HUB_RC" in
        6) bad "${NATS}:$1 — the name does not resolve: $2" ;;
        0|28) bad "${NATS}:$1 — answers with no NATS greeting within 3 s: $2" ;;
        *) bad "${NATS}:$1 — no answer (curl exit ${HUB_RC}): $2" ;;
    esac
}
WHY_CLIENT="the hub's client port, where the cloud services publish and subscribe"
hub_greeting 4222
if [ -n "$HUB_INFO" ]; then
    good "${NATS}:4222 — hub answers, NATS server $(hub_version): ${WHY_CLIENT}"
else
    hub_unreached 4222 "$WHY_CLIENT"
fi
WHY_LEAF="the hub's leaf port, where the vehicle's leaf opens the leaf link"
hub_greeting 7422
if [ -z "$HUB_INFO" ]; then
    hub_unreached 7422 "$WHY_LEAF"
elif echo "$HUB_INFO" | grep -q '"tls_required":true'; then
    if [ "$LEAF_ANCHOR" = yes ]; then
        good "${NATS}:7422 — hub answers, NATS server $(hub_version), TLS required, matching the published NATS_LEAF_TLS_CA.pem: ${WHY_LEAF}"
    else
        bad "${NATS}:7422 — the hub requires TLS, but the bucket publishes no NATS_LEAF_TLS_CA.pem, so no vehicle can verify it: ${WHY_LEAF}"
    fi
else
    if [ "$LEAF_ANCHOR" = yes ]; then
        bad "${NATS}:7422 — the hub does not require TLS, although the bucket publishes NATS_LEAF_TLS_CA.pem and vehicles therefore insist on it: ${WHY_LEAF}"
    else
        good "${NATS}:7422 — hub answers, NATS server $(hub_version), no TLS, consistent with no NATS_LEAF_TLS_CA.pem in the bucket: ${WHY_LEAF}"
    fi
fi

# From here on the script handles the secret, the token and the vehicle's private key: no
# trace, even under bash -x.
{ set +x; } 2>/dev/null
echo "=== 4/5 operator login ==="
TOKEN=""
if [ "$DO_LOGIN" = no ]; then
    echo "  - skipped (pass --login to check it)"
else
    CLIENT_ID="${FACTORY_CLIENT_ID:-}"
    [ -n "$CLIENT_ID" ] || read -rp "Factory-Client-ID: " CLIENT_ID
    SECRET="${FACTORY_OPERATOR_CLIENT_SECRET:-}"
    if [ -z "$SECRET" ]; then read -rsp "Factory-Secret: " SECRET; echo >&2; fi
    if [ -z "$CLIENT_ID" ] || [ -z "$SECRET" ]; then
        bad "operator login — no client id or no secret given: an operator logs in to ask factory-helper for vehicle identities"
    elif [ ! -s "$WORK/KEYCLOAK_TLS_CRT.pem" ]; then
        bad "operator login — not tried without KEYCLOAK_TLS_CRT.pem (station 1)"
    else
        # The secret reaches curl on its standard input, never as an argument a process
        # listing would show; printf is a shell builtin, so it does not show either.
        RC=0
        RESP="$(printf '%s' "$SECRET" | curl -s --max-time 30 --cacert "$WORK/KEYCLOAK_TLS_CRT.pem" -X POST \
            "https://${KEYCLOAK}:8443/realms/sdv-telemetry/protocol/openid-connect/token" \
            -d grant_type=client_credentials --data-urlencode "client_id=${CLIENT_ID}" \
            --data-urlencode "client_secret@-")" || RC=$?
        TOKEN="$(echo "$RESP" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p' | head -1)"
        if [ "$RC" -eq 60 ]; then
            bad "operator login — Keycloak's certificate cannot be verified (expired, or the anchor does not match)"
        elif [ "$RC" -ne 0 ]; then
            bad "operator login — no answer from ${KEYCLOAK} (curl exit ${RC})"
        elif [ -n "$TOKEN" ]; then
            good "operator login as ${CLIENT_ID} — Keycloak issued a token: with it an operator may ask factory-helper for vehicle identities"
        else
            # Only the error code, never the body: a body from this endpoint can hold a token.
            bad "operator login as ${CLIENT_ID} — rejected by Keycloak ($(echo "$RESP" | sed -n 's/.*"error":"\([^"]*\)".*/\1/p' | head -1)): check the client id and the secret"
        fi
        unset RESP
    fi
    unset SECRET
fi

echo "=== 5/5 vehicle identity ==="
if [ -z "$VIN" ]; then
    echo "  - skipped (pass --identity <VIN> to check it; it issues a real identity)"
elif [ -z "$TOKEN" ]; then
    echo "  - skipped: no operator login (station 4)"
else
    # The token reaches curl as a header on its standard input, for the same reason.
    RC=0
    RESP="$(printf 'Authorization: Bearer %s\n' "$TOKEN" | curl -s --max-time 60 --cacert "$WORK/KEYCLOAK_TLS_CRT.pem" -X POST \
        "https://${FACTORY}:8443/v1/factory-certificates" -H @- -H "Content-Type: application/json" \
        -d "{\"vin\": \"${VIN}\"}")" || RC=$?
    # json_pem <field>: one PEM value from the response, its \n escapes turned into lines.
    json_pem() { echo "$RESP" | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" | head -1 | sed 's#\\/#/#g' | awk '{gsub(/\\n/, "\n"); printf "%s", $0}'; }
    WHY_ID="what a plant puts into the unit; the registration server swaps it for the everyday identity"
    if [ "$RC" -eq 60 ]; then
        bad "vehicle identity for ${VIN} — factory-helper's certificate cannot be verified (expired, or not signed by the CA in the Keycloak anchor)"
    elif [ "$RC" -ne 0 ]; then
        bad "vehicle identity for ${VIN} — no answer from ${FACTORY} (curl exit ${RC})"
    else
        json_pem certificate > "$WORK/vehicle.pem"
        (umask 077; json_pem private_key > "$WORK/vehicle-key.pem")
        if ! openssl x509 -in "$WORK/vehicle.pem" -noout 2>/dev/null; then
            bad "vehicle identity for ${VIN} — factory-helper issued no certificate ($(echo "$RESP" | sed -n 's/.*"error":"\([^"]*\)".*/\1/p' | head -1))"
        elif ! openssl pkey -in "$WORK/vehicle-key.pem" -noout 2>/dev/null; then
            bad "vehicle identity for ${VIN} — a certificate came, but no private key with it"
        else
            good "vehicle identity for ${VIN} — factory-helper issued $(openssl x509 -in "$WORK/vehicle.pem" -noout -subject | sed 's/^subject= *//'), valid until $(expiry_date "$WORK/vehicle.pem") ($(days_left "$WORK/vehicle.pem") days left), private key received: ${WHY_ID}"
        fi
    fi
    unset RESP
fi
unset TOKEN

echo ""
echo "Summary: ${PASSED} passed, ${FAILED} failed, ${WARNED} warning(s)"
[ "$FAILED" -eq 0 ]
