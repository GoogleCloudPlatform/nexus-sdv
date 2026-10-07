package auth

import (
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

// keycloak stands in for Keycloak's discovery endpoint. It can be switched off
// to play a Keycloak that is not up yet, and counts how often it is asked.
type keycloak struct {
	issuer string
	up     atomic.Bool
	asked  atomic.Int32
	srv    *httptest.Server
}

func newKeycloak(t *testing.T, issuer string) *keycloak {
	t.Helper()
	k := &keycloak{issuer: issuer}
	k.up.Store(true)
	k.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		k.asked.Add(1)
		if !k.up.Load() {
			http.Error(w, "starting", http.StatusServiceUnavailable)
			return
		}
		_, _ = w.Write([]byte(`{"issuer":"` + k.issuer + `","jwks_uri":"unused"}`))
	}))
	t.Cleanup(k.srv.Close)
	return k
}

func TestIssuerFromDiscovery(t *testing.T) {
	client := &http.Client{Timeout: 2 * time.Second}

	t.Run("reads the issuer field", func(t *testing.T) {
		k := newKeycloak(t, testIssuer)
		got, err := IssuerFromDiscovery(client, k.srv.URL)
		require.NoError(t, err)
		require.Equal(t, testIssuer, got)
	})

	t.Run("a non-200 answer is an error", func(t *testing.T) {
		k := newKeycloak(t, testIssuer)
		k.up.Store(false)
		_, err := IssuerFromDiscovery(client, k.srv.URL)
		require.Error(t, err)
	})

	t.Run("a document without an issuer is an error", func(t *testing.T) {
		k := newKeycloak(t, "")
		_, err := IssuerFromDiscovery(client, k.srv.URL)
		require.ErrorContains(t, err, "no issuer")
	})
}

// TestTheIssuerIsLearnedFromKeycloak covers what the change exists for: the
// Data API checks against whatever Keycloak puts into its tokens, on local and
// remote PKI alike, and does not need Keycloak at start-up.
func TestTheIssuerIsLearnedFromKeycloak(t *testing.T) {
	r := newRealm(t)
	hour := time.Now().Add(time.Hour)

	t.Run("an unreachable Keycloak does not stop the verifier from being built", func(t *testing.T) {
		_, err := NewVerifierFromDiscovery(r.jwkB64, "http://127.0.0.1:1/never-there", testRole)
		require.NoError(t, err)
	})

	t.Run("a token from the discovered issuer passes, one from elsewhere does not", func(t *testing.T) {
		local := "https://34.158.153.37:8443/realms/sdv-telemetry" // the shape a local-PKI platform mints
		k := newKeycloak(t, local)
		v, err := NewVerifierFromDiscovery(r.jwkB64, k.srv.URL, testRole)
		require.NoError(t, err)

		_, err = v.Verify(r.token(t, local, []string{testRole}, hour))
		require.NoError(t, err)

		_, err = v.Verify(r.token(t, testIssuer, []string{testRole}, hour))
		require.Error(t, err)
	})

	t.Run("Keycloak not up yet: that call is refused, the next one succeeds", func(t *testing.T) {
		k := newKeycloak(t, testIssuer)
		k.up.Store(false)
		v, err := NewVerifierFromDiscovery(r.jwkB64, k.srv.URL, testRole)
		require.NoError(t, err)
		token := r.token(t, testIssuer, []string{testRole}, hour)

		_, err = v.Verify(token)
		require.ErrorContains(t, err, "cannot establish the issuer")

		k.up.Store(true)
		_, err = v.Verify(token)
		require.NoError(t, err)
	})

	t.Run("a learned issuer is asked for once, not on every call", func(t *testing.T) {
		k := newKeycloak(t, testIssuer)
		v, err := NewVerifierFromDiscovery(r.jwkB64, k.srv.URL, testRole)
		require.NoError(t, err)
		token := r.token(t, testIssuer, []string{testRole}, hour)
		for i := 0; i < 5; i++ {
			_, err = v.Verify(token)
			require.NoError(t, err)
		}
		require.Equal(t, int32(1), k.asked.Load())
	})
}
