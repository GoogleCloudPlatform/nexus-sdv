package auth

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"io"
	"net"
	"testing"
	"time"

	dataapiv1 "data-api/api/gen/dataapi/v1"

	"github.com/golang-jwt/jwt/v5"
	"github.com/lestrrat-go/jwx/jwk"
	"github.com/stretchr/testify/require"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"
)

const (
	testIssuer = "https://keycloak.example/realms/sdv-telemetry"
	testRole   = "factory-operator"
	testKid    = "test-key"
)

// realm stands in for Keycloak: a signing key plus the base64 JWK set the
// deployment hands the service in KEYCLOAK_JWK_B64.
type realm struct {
	key    *rsa.PrivateKey
	jwkB64 string
}

func newRealm(t *testing.T) *realm {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	require.NoError(t, err)

	pub, err := jwk.New(&key.PublicKey)
	require.NoError(t, err)
	require.NoError(t, pub.Set(jwk.KeyIDKey, testKid))
	require.NoError(t, pub.Set(jwk.AlgorithmKey, "RS256"))

	keyJSON, err := json.Marshal(pub)
	require.NoError(t, err)
	setJSON := []byte(`{"keys":[` + string(keyJSON) + `]}`)

	return &realm{key: key, jwkB64: base64.StdEncoding.EncodeToString(setJSON)}
}

// token mints an access token the way Keycloak's client_credentials flow would.
func (r *realm) token(t *testing.T, issuer string, roles []string, expiry time.Time) string {
	t.Helper()
	claims := &Claims{}
	claims.RealmAccess.Roles = roles
	claims.Issuer = issuer
	claims.ExpiresAt = jwt.NewNumericDate(expiry)

	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
	tok.Header["kid"] = testKid
	signed, err := tok.SignedString(r.key)
	require.NoError(t, err)
	return signed
}

func TestNewVerifierRejectsIncompleteConfiguration(t *testing.T) {
	r := newRealm(t)
	for name, args := range map[string][3]string{
		"no key set": {"", testIssuer, testRole},
		"no issuer":  {r.jwkB64, "", testRole},
		"no role":    {r.jwkB64, testIssuer, ""},
		"not base64": {"not-base64!", testIssuer, testRole},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := NewVerifier(args[0], args[1], args[2])
			require.Error(t, err)
		})
	}
}

func TestVerify(t *testing.T) {
	r := newRealm(t)
	v, err := NewVerifier(r.jwkB64, testIssuer, testRole)
	require.NoError(t, err)

	hour := time.Now().Add(time.Hour)

	t.Run("a token with the role passes", func(t *testing.T) {
		claims, err := v.Verify(r.token(t, testIssuer, []string{"other", testRole}, hour))
		require.NoError(t, err)
		require.True(t, claims.HasRole(testRole))
	})

	t.Run("a token without the role fails", func(t *testing.T) {
		_, err := v.Verify(r.token(t, testIssuer, []string{"other"}, hour))
		require.ErrorContains(t, err, "lacks realm role")
	})

	t.Run("a token from another issuer fails", func(t *testing.T) {
		_, err := v.Verify(r.token(t, "https://elsewhere/realms/other", []string{testRole}, hour))
		require.Error(t, err)
	})

	t.Run("an expired token fails", func(t *testing.T) {
		_, err := v.Verify(r.token(t, testIssuer, []string{testRole}, time.Now().Add(-time.Minute)))
		require.Error(t, err)
	})

	t.Run("a token signed by another key fails", func(t *testing.T) {
		other := newRealm(t)
		_, err := v.Verify(other.token(t, testIssuer, []string{testRole}, hour))
		require.Error(t, err)
	})

	t.Run("nonsense fails", func(t *testing.T) {
		_, err := v.Verify("not-a-token")
		require.Error(t, err)
	})
}

// stubServer answers GetTelemetryData with one point, so that reaching the
// handler at all is observable.
type stubServer struct {
	dataapiv1.UnimplementedTelemetryDataAPIServer
}

func (stubServer) GetTelemetryData(_ *dataapiv1.GetTelemetryDataRequest, stream dataapiv1.TelemetryDataAPI_GetTelemetryDataServer) error {
	return stream.Send(&dataapiv1.TelemetryPoint{})
}

// serve starts the real gRPC server with both interceptors over an in-memory
// connection — the same wiring main.go uses.
func serve(t *testing.T, v *Verifier) dataapiv1.TelemetryDataAPIClient {
	t.Helper()
	lis := bufconn.Listen(1024 * 1024)
	srv := grpc.NewServer(
		grpc.UnaryInterceptor(v.UnaryInterceptor()),
		grpc.StreamInterceptor(v.StreamInterceptor()),
	)
	dataapiv1.RegisterTelemetryDataAPIServer(srv, stubServer{})
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(srv.Stop)

	conn, err := grpc.NewClient("passthrough:///bufnet",
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) {
			return lis.DialContext(ctx)
		}),
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	require.NoError(t, err)
	t.Cleanup(func() { _ = conn.Close() })

	return dataapiv1.NewTelemetryDataAPIClient(conn)
}

// read drains the stream and returns the first error.
func read(stream dataapiv1.TelemetryDataAPI_GetTelemetryDataClient) error {
	for {
		_, err := stream.Recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
	}
}

// TestTheStreamingCallIsGuarded is the test the whole change exists for.
//
// GetTelemetryData is the Data API's only RPC and it is server-streaming. A
// UnaryServerInterceptor alone compiles, deploys and looks finished while every
// telemetry read stays open, so this exercises the streaming path specifically.
func TestTheStreamingCallIsGuarded(t *testing.T) {
	r := newRealm(t)
	v, err := NewVerifier(r.jwkB64, testIssuer, testRole)
	require.NoError(t, err)
	client := serve(t, v)

	hour := time.Now().Add(time.Hour)
	ctx := context.Background()

	call := func(ctx context.Context) error {
		stream, err := client.GetTelemetryData(ctx, &dataapiv1.GetTelemetryDataRequest{VehicleId: "VEHICLE001"})
		require.NoError(t, err) // the stream opens; the rejection arrives on the first Recv
		return read(stream)
	}

	t.Run("without a token the stream is refused", func(t *testing.T) {
		err := call(ctx)
		require.Equal(t, codes.Unauthenticated, status.Code(err))
	})

	t.Run("without the realm role the stream is refused", func(t *testing.T) {
		md := metadata.Pairs("authorization", "Bearer "+r.token(t, testIssuer, []string{"other"}, hour))
		err := call(metadata.NewOutgoingContext(ctx, md))
		require.Equal(t, codes.Unauthenticated, status.Code(err))
	})

	t.Run("a malformed authorization header is refused", func(t *testing.T) {
		md := metadata.Pairs("authorization", r.token(t, testIssuer, []string{testRole}, hour)) // no "Bearer "
		err := call(metadata.NewOutgoingContext(ctx, md))
		require.Equal(t, codes.Unauthenticated, status.Code(err))
	})

	t.Run("with a valid token the stream is served", func(t *testing.T) {
		md := metadata.Pairs("authorization", "Bearer "+r.token(t, testIssuer, []string{testRole}, hour))
		require.NoError(t, call(metadata.NewOutgoingContext(ctx, md)))
	})

	t.Run("the scheme is matched case-insensitively", func(t *testing.T) {
		md := metadata.Pairs("authorization", "bearer "+r.token(t, testIssuer, []string{testRole}, hour))
		require.NoError(t, call(metadata.NewOutgoingContext(ctx, md)))
	})
}
