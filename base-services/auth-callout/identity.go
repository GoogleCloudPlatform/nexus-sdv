package main

import (
	"crypto/x509"
	"encoding/pem"
	"os"
	"regexp"

	"github.com/golang-jwt/jwt/v5"
	natsjwt "github.com/nats-io/jwt/v2"
)

// The operational certificate's common name is VIN:<vin> DEVICE:<device>
// (base-services/registration/server/src/listener/tls_listener.rs:46-48). Subject-safe
// characters only; deliberately not ISO 3779 — test VINs carry an O.
var vinInCommonName = regexp.MustCompile(`(?:^|\s)VIN:([A-Z0-9]{1,17})(?:\s|$)`)

func vinFromCommonName(cn string) (string, bool) {
	m := vinInCommonName.FindStringSubmatch(cn)
	if m == nil {
		return "", false
	}
	return m[1], true
}

// vinFromVerifiedChains reads the VIN from the certificate the NATS server verified against
// the leaf port's CA bundle — the leaf's own, first in the first chain. No chain, no VIN.
func vinFromVerifiedChains(tls *natsjwt.ClientTLS) (string, bool) {
	if tls == nil || len(tls.VerifiedChains) == 0 || len(tls.VerifiedChains[0]) == 0 {
		return "", false
	}
	block, _ := pem.Decode([]byte(tls.VerifiedChains[0][0]))
	if block == nil {
		return "", false
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return "", false
	}
	return vinFromCommonName(cert.Subject.CommonName)
}

// identity is a connection's VIN and where it came from: the certificate the server
// verified (spec R1), a vehicle_vin claim (a transition path, unused today), or nothing
// but the shared client id — legacy, which enforcement refuses.
type identity struct {
	vin    string
	source string
	legacy bool
}

func resolveIdentityFrom(tls *natsjwt.ClientTLS, claims jwt.MapClaims) identity {
	if vin, ok := vinFromVerifiedChains(tls); ok {
		return identity{vin: vin, source: "certificate"}
	}
	if v, ok := claims["vehicle_vin"].(string); ok && v != "" {
		return identity{vin: v, source: "claim"}
	}
	if azp, ok := claims["azp"].(string); ok && azp != "" {
		return identity{vin: azp, source: "azp", legacy: true}
	}
	return identity{source: "none", legacy: true}
}

// extractRealmRoles reads realm_access.roles defensively: a token may carry no roles,
// and a missing map must not take the service down.
func extractRealmRoles(claims jwt.MapClaims) []string {
	ra, ok := claims["realm_access"].(map[string]any)
	if !ok {
		return nil
	}
	raw, ok := ra["roles"].([]any)
	if !ok {
		return nil
	}
	roles := make([]string, 0, len(raw))
	for _, r := range raw {
		if s, ok := r.(string); ok {
			roles = append(roles, s)
		}
	}
	return roles
}

// Enforcement per connection kind (spec D6). A leaf is a vehicle with a certificate and is
// enforced; a client on 4222 is one of the 1.x sample clients with a token only, logged
// until release 1.3 brings them a certificate — then CLIENT_ENFORCEMENT=enforce.
const kindLeafnode = "Leafnode"

var leafEnforcement = envOr("LEAF_ENFORCEMENT", "enforce")
var clientEnforcement = envOr("CLIENT_ENFORCEMENT", "log")

func enforceFor(kind string) bool {
	if kind == kindLeafnode {
		return leafEnforcement == "enforce"
	}
	return clientEnforcement == "enforce"
}

var vinPattern = regexp.MustCompile(`^[A-Z0-9]{1,17}$`)

// validVIN is the one rule for a VIN that is about to become part of a subject or a key:
// subject-safe characters only. Deliberately not ISO 3779 — test VINs carry an O.
func validVIN(vin string) bool { return vinPattern.MatchString(vin) }

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
