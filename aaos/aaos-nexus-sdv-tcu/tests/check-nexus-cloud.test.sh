#!/usr/bin/env bash
# Tests check-nexus-cloud.sh against stand-ins for curl and openssl — no network, no cloud.
# Run:  aaos/aaos-nexus-sdv-tcu/tests/check-nexus-cloud.test.sh
#
# The certificates are real, made here with the real openssl, and the stand-in for
# `openssl s_client` verifies them for real against the anchor it is given: an expired
# certificate fails because it is expired, not because a fixture says so. Every call to
# either stand-in is recorded, so the test can prove the operator secret and the token never
# reach a command line.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/../check-nexus-cloud.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REAL_OPENSSL="$(command -v openssl)"
DOMAIN=example.test
SECRET='s3cret-not-on-any-command-line'
TOKEN='TOKEN-not-on-any-command-line'

# --- Certificates: one test CA, server certificates signed by it ---
CA="$WORK/ca"
mkdir -p "$CA/new"; : > "$CA/index.txt"; echo 01 > "$CA/serial"
cat > "$CA/ca.cnf" <<EOF
[ ca ]
default_ca = d
[ d ]
database = $CA/index.txt
new_certs_dir = $CA/new
serial = $CA/serial
default_md = sha256
policy = p
unique_subject = no
[ p ]
commonName = supplied
[ req ]
distinguished_name = dn
[ dn ]
[ v3ca ]
basicConstraints = critical,CA:true
keyUsage = keyCertSign,cRLSign
EOF
"$REAL_OPENSSL" req -x509 -newkey rsa:2048 -nodes -keyout "$CA/ca.key" -out "$CA/ca.pem" -days 3650 \
    -subj "/CN=Test Root CA" -config "$CA/ca.cnf" -extensions v3ca >/dev/null 2>&1
# cert <name> <CN> <ca-args…>: a key and a certificate signed by the test CA.
cert() {
    local name="$1" cn="$2"; shift 2
    "$REAL_OPENSSL" req -newkey rsa:2048 -nodes -keyout "$CA/$name.key" -out "$CA/$name.csr" \
        -subj "/CN=$cn" -config "$CA/ca.cnf" >/dev/null 2>&1
    "$REAL_OPENSSL" ca -batch -config "$CA/ca.cnf" -cert "$CA/ca.pem" -keyfile "$CA/ca.key" \
        -in "$CA/$name.csr" -out "$CA/$name.pem" -notext "$@" >/dev/null 2>&1
}
for h in keycloak factory registration; do cert "$h" "$h.$DOMAIN" -days 400; done
cert registration-expired "registration.$DOMAIN" -startdate 20200101000000Z -enddate 20200201000000Z
cert keycloak-short "keycloak.$DOMAIN" -days 5
cert keycloak-wrongname "other.$DOMAIN" -days 400
cert vehicle "TESTVIN01" -days 30

# --- The stand-ins ---
cat > "$WORK/curl" <<FAKE
#!/usr/bin/env bash
REAL_OPENSSL="$REAL_OPENSSL"
FAKE
cat >> "$WORK/curl" <<'FAKE'
printf 'curl %s\n' "$*" >> "$FAKE_ROOT/argv"
url=""; out=""; insecure=no; secret_stdin=no; header_stdin=no; data=""; cacert=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -k|-[a-z]*k) insecure=yes ;;
    --data-urlencode) [ "$2" = "client_secret@-" ] && secret_stdin=yes; shift ;;
    -H) [ "$2" = "@-" ] && header_stdin=yes; shift ;;
    -d) data="$data $2"; shift ;;
    --cacert) cacert="$2"; shift ;;
    -*) case "$1" in --max-time|-X|--connect-timeout) shift ;; esac ;;
    *) url="$1" ;;
  esac
  shift
done
hostport="${url#*://}"; hostport="${hostport%%/*}"; host="${hostport%%:*}"
case "$url" in
  https://storage.googleapis.com/*)
    f="$FAKE_ROOT/bucket/${url##*/}"
    [ -f "$f" ] || exit 22
    case "$(head -c 4 "$f")" in fail) exit "$(sed 's/^fail//' "$f")" ;; esac
    cp "$f" "$out"; exit 0 ;;
esac
dns="$FAKE_ROOT/dns/$host"
[ -f "$dns" ] || exit 6
[ "$(cat "$dns")" = noanswer ] && exit 28
case "$url" in
  telnet://*)
    port="${hostport##*:}"
    cat "$FAKE_ROOT/hub/$port" 2>/dev/null; exit 0 ;;
  */openid-connect/token)
    [ "$secret_stdin" = yes ] && got="$(cat)" || got=""
    if [ "$(cat "$FAKE_ROOT/login")" = ok ] && [ "$got" = "$(cat "$FAKE_ROOT/secret")" ]; then
      printf '{"access_token":"%s","expires_in":300,"token_type":"Bearer"}' "$(cat "$FAKE_ROOT/token")"
    else
      printf '{"error":"unauthorized_client","error_description":"Invalid client or Invalid client credentials"}'
    fi
    exit 0 ;;
  */v1/factory-certificates)
    [ "$header_stdin" = yes ] && hdr="$(cat)" || hdr=""
    if [ "$hdr" = "Authorization: Bearer $(cat "$FAKE_ROOT/token")" ]; then
      cat "$FAKE_ROOT/factory-response"
    else
      printf '{"error":"unauthorized"}'
    fi
    exit 0 ;;
  https://*:8443/)
    # As curl does with an OpenSSL backend: the chain against --cacert, and the name.
    [ "$insecure" = yes ] && exit 0
    served="$FAKE_ROOT/tls/$hostport.pem"
    [ -n "$cacert" ] && "$REAL_OPENSSL" verify -CAfile "$cacert" "$served" >/dev/null 2>&1 || exit 60
    "$REAL_OPENSSL" x509 -in "$served" -noout -subject | grep -Eq "CN ?= ?$host\$" || exit 60
    exit 0 ;;
esac
exit 7
FAKE
cat > "$WORK/openssl" <<FAKE
#!/usr/bin/env bash
REAL_OPENSSL="$REAL_OPENSSL"
FAKE
cat >> "$WORK/openssl" <<'FAKE'
printf 'openssl %s\n' "$*" >> "$FAKE_ROOT/argv"
if [ "${1:-}" = version ] && [ -n "${FAKE_OPENSSL_VERSION:-}" ]; then echo "$FAKE_OPENSSL_VERSION"; exit 0; fi
[ "${1:-}" = s_client ] || exec "$REAL_OPENSSL" "$@"
shift
connect=""; cafile=""; strict=no; name=
while [ $# -gt 0 ]; do
  case "$1" in
    -connect) connect="$2"; shift ;;
    -CAfile) cafile="$2"; shift ;;
    -verify_return_error) strict=yes ;;
    -servername) shift ;;
    -verify_hostname) name="$2"; shift ;;
  esac
  shift
done
served="$FAKE_ROOT/tls/$connect.pem"
[ -f "$served" ] || { echo "connect:errno=61"; exit 1; }
# The verdict s_client would reach: the real chain verification, then the name if asked.
code="0 (ok)"
if ! v="$("$REAL_OPENSSL" verify -CAfile "$cafile" "$served" 2>&1)"; then
  code="$(echo "$v" | sed -n 's/^error \([0-9]*\) at [0-9]* depth lookup: *\(.*\)$/\1 (\2)/p' | head -1)"
elif [ -n "$name" ] && ! "$REAL_OPENSSL" x509 -in "$served" -noout -subject | grep -Eq "CN ?= ?$name\$"; then
  code="62 (hostname mismatch)"
fi
if [ "$code" != "0 (ok)" ] && [ "$strict" = yes ]; then
  printf 'CONNECTED(00000005)\nverify error:num=%s\n' "$code"; exit 1
fi
printf 'CONNECTED(00000005)\n---\nServer certificate\n'; cat "$served"
printf -- '---\n    Verify return code: %s\n' "$code"

FAKE
chmod +x "$WORK/curl" "$WORK/openssl"

json_escape() { awk '{printf "%s\\n", $0}' "$1"; }

# A case: a healthy cloud, which each test then breaks on purpose.
setup() {
    local name="$1" r="$WORK/$1" h
    rm -rf "$r"; mkdir -p "$r/bucket" "$r/dns" "$r/tls" "$r/hub"
    cat "$CA/keycloak.pem" "$CA/ca.pem" > "$r/bucket/KEYCLOAK_TLS_CRT.pem"
    cat "$CA/registration.pem" "$CA/ca.pem" > "$r/bucket/REGISTRATION_SERVER_TLS_CERT.pem"
    cp "$CA/ca.pem" "$r/bucket/NATS_LEAF_TLS_CA.pem"
    for h in keycloak factory registration nats; do echo ok > "$r/dns/$h.$DOMAIN"; done
    for h in keycloak factory registration; do cp "$CA/$h.pem" "$r/tls/$h.$DOMAIN:8443.pem"; done
    echo 'INFO {"server_id":"N1","version":"2.14.6","proto":1,"auth_required":true,"max_payload":1048576}' > "$r/hub/4222"
    echo 'INFO {"server_id":"N1","version":"2.14.6","proto":3,"auth_required":true,"tls_required":true,"tls_verify":true}' > "$r/hub/7422"
    echo ok > "$r/login"
    printf '%s' "$SECRET" > "$r/secret"
    printf '%s' "$TOKEN" > "$r/token"
    printf '{"certificate":"%s","ca_certificate_chain":"%s","private_key":"%s"}' \
        "$(json_escape "$CA/vehicle.pem")" "$(json_escape "$CA/ca.pem")" "$(json_escape "$CA/vehicle.key")" \
        > "$r/factory-response"
    : > "$r/argv"
}

# run <name> <args…>: runs the check; stdin is whatever the caller pipes in.
run() {
    local name="$1"; shift
    FAKE_ROOT="$WORK/$name" PATH="$WORK:$PATH" PKI_BUCKET_PROJECT=test \
        FAKE_OPENSSL_VERSION="${FAKE_OPENSSL_VERSION:-OpenSSL 3.0.0 (stand-in)}" bash "$CHECK" "$@" 2>&1
    echo "exit=$?"
}
# run_x: the same under bash -x, whose trace goes to stderr and is captured with the rest.
run_x() {
    local name="$1"; shift
    FAKE_ROOT="$WORK/$name" PATH="$WORK:$PATH" PKI_BUCKET_PROJECT=test \
        FAKE_OPENSSL_VERSION="OpenSSL 3.0.0 (stand-in)" bash -x "$CHECK" "$@" 2>&1
    echo "exit=$?"
}

pass=0; fail=0
expect() {
    local name="$1" want="$2" out="$3"
    if echo "$out" | grep -q -- "$want"; then
        echo "  ok   $name"; pass=$((pass + 1))
    else
        echo "  FAIL $name — expected '$want' in:"; echo "$out" | sed 's/^/       /'
        fail=$((fail + 1))
    fi
}
expect_not() {
    local name="$1" unwanted="$2" where="$3" what="$4"
    if echo "$where" | grep -q -- "$unwanted"; then
        echo "  FAIL $name — '$unwanted' found in $what"; fail=$((fail + 1))
    else
        echo "  ok   $name"; pass=$((pass + 1))
    fi
}

echo "check-nexus-cloud.sh"

# 1 — everything healthy, read-only.
setup good
out="$(run good "$DOMAIN" </dev/null)"
expect "a healthy cloud passes" "^exit=0$" "$out"
expect "and says nothing failed" " 0 failed" "$out"
expect "and shows the hub version" "2.14.6" "$out"
expect "and skips the login without --login" "pass --login" "$out"

# 2 — everything healthy, with a vehicle identity issued; credentials from the environment.
setup identity
out="$(FACTORY_CLIENT_ID=factory-operator-test FACTORY_OPERATOR_CLIENT_SECRET="$SECRET" run identity "$DOMAIN" --identity TESTVIN01 </dev/null)"
expect "--identity passes on a healthy cloud" "^exit=0$" "$out"
expect "and shows the issued certificate's subject" "CN *= *TESTVIN01" "$out"
expect_not "the private key is never printed" "PRIVATE KEY" "$out" "the output"
expect_not "the secret is in no stand-in's argv" "$SECRET" "$(cat "$WORK/identity/argv")" "argv"
expect_not "the token is in no stand-in's argv" "$TOKEN" "$(cat "$WORK/identity/argv")" "argv"
expect_not "the token is never printed" "$TOKEN" "$out" "the output"

# 3 — the registration server serves an expired certificate.
setup expired
cp "$CA/registration-expired.pem" "$WORK/expired/tls/registration.$DOMAIN:8443.pem"
out="$(run expired "$DOMAIN" </dev/null)"
expect "an expired certificate fails" "^exit=1$" "$out"
expect "and names the station and 'expired'" "✗ registration.$DOMAIN:8443.*expired" "$out"

# 4 — factory's name does not resolve.
setup nodns
rm "$WORK/nodns/dns/factory.$DOMAIN"
out="$(run nodns "$DOMAIN" </dev/null)"
expect "an unresolvable name fails" "^exit=1$" "$out"
expect "and names the host" "✗ factory.$DOMAIN:8443.*does not resolve" "$out"

# 5 — a host that resolves but does not answer.
setup noanswer
echo noanswer > "$WORK/noanswer/dns/keycloak.$DOMAIN"
out="$(run noanswer "$DOMAIN" </dev/null)"
expect "a silent host is named as not answering" "✗ keycloak.$DOMAIN:8443.*no answer" "$out"

# 6 — the hub's leaf port does not require TLS although the anchor is published.
setup leafplain
echo 'INFO {"server_id":"N1","version":"2.14.6","proto":3,"auth_required":true}' > "$WORK/leafplain/hub/7422"
out="$(run leafplain "$DOMAIN" </dev/null)"
expect "7422 without TLS while the anchor is published fails" "^exit=1$" "$out"
expect "and says why" "✗ nats.$DOMAIN:7422.*NATS_LEAF_TLS_CA.pem" "$out"

# 7 — a hub without leaf TLS that publishes no anchor is consistent: a note, not a failure.
setup noleaftls
rm "$WORK/noleaftls/bucket/NATS_LEAF_TLS_CA.pem"
echo 'INFO {"server_id":"N1","version":"2.14.6","proto":3,"auth_required":true}' > "$WORK/noleaftls/hub/7422"
out="$(run noleaftls "$DOMAIN" </dev/null)"
expect "no leaf anchor and no leaf TLS passes" "^exit=0$" "$out"
expect "and says so in a note" "note:.*NATS_LEAF_TLS_CA.pem" "$out"

# 8 — a certificate with fewer than 14 days left warns, and does not fail.
setup short
cp "$CA/keycloak-short.pem" "$WORK/short/tls/keycloak.$DOMAIN:8443.pem"
out="$(run short "$DOMAIN" </dev/null)"
expect "a certificate close to expiry still passes" "^exit=0$" "$out"
expect "with a warning line" "! keycloak.$DOMAIN:8443.*days left" "$out"

# 9 — Keycloak rejects the operator login; credentials typed at the prompt.
setup rejected
echo no > "$WORK/rejected/login"
out="$(printf 'factory-operator-test\n%s\n' "$SECRET" | run rejected "$DOMAIN" --login)"
expect "a rejected login fails" "^exit=1$" "$out"
expect "and names the login" "✗ operator login.*rejected" "$out"
expect_not "the typed secret is in no stand-in's argv" "$SECRET" "$(cat "$WORK/rejected/argv")" "argv"
expect_not "the typed secret is never printed" "$SECRET" "$out" "the output"

# 10 — a login typed at the prompt that Keycloak accepts.
setup typed
out="$(printf 'factory-operator-test\n%s\n' "$SECRET" | run typed "$DOMAIN" --login)"
expect "a typed login is accepted" "✓ operator login" "$out"
expect_not "and its secret is in no stand-in's argv" "$SECRET" "$(cat "$WORK/typed/argv")" "argv"

# 11 — a VIN that is not one is refused before anything is contacted.
setup badvin
out="$(run badvin "$DOMAIN" --identity 'abc;rm -rf' </dev/null)"
expect "an invalid VIN is refused" "^exit=2$" "$out"
expect_not "before curl or openssl is called" "." "$(cat "$WORK/badvin/argv")" "argv"

# 12 — an empty bucket: every anchor missing is a failure, the leaf anchor only a note.
setup nobucket
rm "$WORK/nobucket/bucket/"*
out="$(run nobucket "$DOMAIN" </dev/null)"
expect "a missing Keycloak anchor fails" "✗ KEYCLOAK_TLS_CRT.pem" "$out"

# 13 — OpenSSL checks the host name, and curl classifies with the anchor, not with -k.
setup names
out="$(run names "$DOMAIN" </dev/null)"
expect "OpenSSL's s_client is asked to check the host name" "-verify_hostname keycloak.$DOMAIN" "$(cat "$WORK/names/argv")"
expect "curl reaches the endpoints with the anchor" "curl .*--cacert .*https://keycloak.$DOMAIN:8443/" "$(cat "$WORK/names/argv")"
expect_not "and never with -k" "curl -sk" "$(cat "$WORK/names/argv")" "argv"

# 14 — a certificate from the right CA for the wrong name.
setup wrongname
cp "$CA/keycloak-wrongname.pem" "$WORK/wrongname/tls/keycloak.$DOMAIN:8443.pem"
out="$(run wrongname "$DOMAIN" </dev/null)"
expect "a certificate for another name fails" "^exit=1$" "$out"
expect "and says why, from openssl's verdict" "✗ keycloak.$DOMAIN:8443 — not verifiable against KEYCLOAK_TLS_CRT.pem.*hostname mismatch" "$out"

# 15 — LibreSSL (macOS) also trusts the system's CAs and checks no name: say so.
setup libressl
out="$(FAKE_OPENSSL_VERSION="LibreSSL 3.3.6" run libressl "$DOMAIN" </dev/null)"
expect "LibreSSL still passes a healthy cloud" "^exit=0$" "$out"
expect "with the caveat as a warning line" "! .*LibreSSL.*system trusts" "$out"
expect_not "and no -verify_hostname it would not understand" "verify_hostname" "$(cat "$WORK/libressl/argv")" "argv"

# 16 — the leaf anchor cannot be fetched for another reason than its absence: a failure.
setup leafunreachable
echo fail7 > "$WORK/leafunreachable/bucket/NATS_LEAF_TLS_CA.pem"
out="$(run leafunreachable "$DOMAIN" </dev/null)"
expect "a leaf anchor that cannot be fetched fails" "✗ NATS_LEAF_TLS_CA.pem.*curl exit 7" "$out"

# 17 — under bash -x, neither the secret nor the token nor the key reaches the trace.
setup xtrace
KEYLINE="$(sed -n 2p "$CA/vehicle.key" | cut -c1-40)"
out="$(FACTORY_CLIENT_ID=factory-operator-test FACTORY_OPERATOR_CLIENT_SECRET="$SECRET" run_x xtrace "$DOMAIN" --identity TESTVIN01 </dev/null)"
expect "under bash -x the identity is still issued" "✓ vehicle identity for TESTVIN01" "$out"
expect_not "the secret is not in the trace" "$SECRET" "$out" "the trace"
expect_not "the token is not in the trace" "$TOKEN" "$out" "the trace"
expect_not "the private key is not in the trace" "$KEYLINE" "$out" "the trace"

# 18 — which project's bucket holds the trust anchors must be said for every instance;
# a silent default checked the wrong cloud.
setup nobucket
out="$(FAKE_ROOT="$WORK/nobucket" PATH="$WORK:$PATH" bash "$CHECK" "$DOMAIN" 2>&1 </dev/null; echo "exit=$?")"
expect "without PKI_BUCKET_PROJECT an instance is refused" "set PKI_BUCKET_PROJECT" "$out"
expect "… as a usage error" "exit=2" "$out"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
