package main

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	natsjwt "github.com/nats-io/jwt/v2"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// A self-signed certificate with the given common name, PEM-encoded — what the NATS
// server hands the callout as the first element of the first verified chain.
func certWithCN(t *testing.T, cn string) string {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	require.NoError(t, err)
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: cn, Organization: []string{"Nexus"}},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	require.NoError(t, err)
	return string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
}

func chain(pemCert string) *natsjwt.ClientTLS {
	return &natsjwt.ClientTLS{VerifiedChains: []natsjwt.StringList{{pemCert}}}
}

func TestVinFromVerifiedChain(t *testing.T) {
	vin, ok := vinFromVerifiedChains(chain(certWithCN(t, "VIN:WBA123 DEVICE:WBA123")))
	assert.True(t, ok)
	assert.Equal(t, "WBA123", vin)
	vin, ok = vinFromVerifiedChains(chain(certWithCN(t, "VIN:SMOKEKARSTEN01 DEVICE:SMOKEKARSTEN01")))
	assert.True(t, ok)
	assert.Equal(t, "SMOKEKARSTEN01", vin)
}

func TestNoChainNoVin(t *testing.T) {
	_, ok := vinFromVerifiedChains(nil)
	assert.False(t, ok)
	_, ok = vinFromVerifiedChains(&natsjwt.ClientTLS{})
	assert.False(t, ok)
	_, ok = vinFromVerifiedChains(chain("not a certificate"))
	assert.False(t, ok)
}

func TestCommaInCommonNameYieldsNoVin(t *testing.T) {
	// F31: a comma inside the identity must not become a truncated VIN.
	_, ok := vinFromVerifiedChains(chain(certWithCN(t, "VIN:AB,CD DEVICE:x")))
	assert.False(t, ok)
	_, ok = vinFromCommonName("VIN:wba123 DEVICE:x")
	assert.False(t, ok, "lowercase is not a VIN")
	_, ok = vinFromCommonName("garbage")
	assert.False(t, ok)
}

func TestIdentityPrefersTheCertificate(t *testing.T) {
	id := resolveIdentityFrom(chain(certWithCN(t, "VIN:WBA123 DEVICE:WBA123")), jwt.MapClaims{"vehicle_vin": "OTHER", "azp": "car"})
	assert.Equal(t, identity{vin: "WBA123", source: "certificate", legacy: false}, id)
	id = resolveIdentityFrom(nil, jwt.MapClaims{"vehicle_vin": "WBA123", "azp": "car"})
	assert.Equal(t, identity{vin: "WBA123", source: "claim", legacy: false}, id)
	id = resolveIdentityFrom(nil, jwt.MapClaims{"azp": "car"})
	assert.Equal(t, identity{vin: "car", source: "azp", legacy: true}, id)
}

func TestLeafWithoutVinIsDenied(t *testing.T) {
	setEnforcement(t, "enforce", "log")
	assert.True(t, enforceFor("Leafnode"))
}

func TestTokenOnlyClientIsLoggedNotDenied(t *testing.T) {
	setEnforcement(t, "enforce", "log")
	assert.False(t, enforceFor("Client"))
	setEnforcement(t, "enforce", "enforce")
	assert.True(t, enforceFor("Client"), "1.3 flips this")
}

func TestRolesAreReadDefensively(t *testing.T) {
	assert.Equal(t, []string{"telemetry-client"}, extractRealmRoles(jwt.MapClaims{"realm_access": map[string]any{"roles": []any{"telemetry-client"}}}))
	assert.Nil(t, extractRealmRoles(jwt.MapClaims{"azp": "car"}), "no realm_access must not panic")
	assert.Nil(t, extractRealmRoles(jwt.MapClaims{"realm_access": map[string]any{}}))
}
