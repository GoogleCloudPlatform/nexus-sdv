// Package auth validates Keycloak access tokens on the Data API's gRPC calls.
//
// It follows the auth-callout service rather than the factory-helper: the realm's
// public keys arrive as a base64-encoded JWK set in KEYCLOAK_JWK_B64 — the same
// Secret Manager secret deploy-keycloak.yaml writes and deploy-nats-auth-callout.yaml
// already consumes. Nothing is fetched at run time, so the Data API needs no trust
// anchor for Keycloak's own TLS certificate.
//
// The cost of that choice, shared with the auth-callout: a Keycloak signing-key
// rotation does not reach a running pod. The key set is read once at start-up, so
// a rotation needs a redeploy.
package auth

import (
	"context"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/lestrrat-go/jwx/jwk"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

// Claims carries the one Keycloak-specific field we read beyond the registered
// ones. Keycloak puts realm roles under realm_access.roles.
type Claims struct {
	RealmAccess struct {
		Roles []string `json:"roles"`
	} `json:"realm_access"`
	jwt.RegisteredClaims
}

// HasRole reports whether the token carries the given realm role.
func (c *Claims) HasRole(role string) bool {
	for _, r := range c.RealmAccess.Roles {
		if r == role {
			return true
		}
	}
	return false
}

// Verifier checks a bearer token against the realm's keys, its issuer and one
// required realm role.
//
// The issuer is not configured but learned: it is whatever Keycloak writes into
// its tokens, and that differs by installation - keycloak-ui.<domain> on remote
// PKI, the load balancer address on local PKI. Building it from the base domain
// matched only the remote case and rejected every token on a local platform.
type Verifier struct {
	keys         jwk.Set
	requiredRole string

	// issuerSource returns the issuer to check against. It is asked on the first
	// verification rather than at start-up, so the Data API does not depend on
	// Keycloak being up when its pod starts; a failed lookup rejects that one
	// call and is retried on the next.
	issuerSource func() (string, error)
	mu           sync.Mutex
	issuer       string
}

// NewVerifier builds a Verifier that checks against a fixed issuer.
func NewVerifier(jwkB64, issuer, requiredRole string) (*Verifier, error) {
	if issuer == "" {
		return nil, errors.New("empty issuer")
	}
	return newVerifier(jwkB64, requiredRole, func() (string, error) { return issuer, nil })
}

// NewVerifierFromDiscovery builds a Verifier that learns the issuer from
// Keycloak's OpenID discovery document - the issuer field there is, by the
// OpenID Connect Discovery specification, the value Keycloak puts into iss.
func NewVerifierFromDiscovery(jwkB64, discoveryURL, requiredRole string) (*Verifier, error) {
	if discoveryURL == "" {
		return nil, errors.New("empty discovery URL: set KEYCLOAK_DISCOVERY_URL")
	}
	client := &http.Client{Timeout: 5 * time.Second}
	return newVerifier(jwkB64, requiredRole, func() (string, error) {
		return IssuerFromDiscovery(client, discoveryURL)
	})
}

// newVerifier holds what both constructors share. All arguments are required:
// an empty one is a configuration error, never a reason to let a call through.
func newVerifier(jwkB64, requiredRole string, issuerSource func() (string, error)) (*Verifier, error) {
	if jwkB64 == "" {
		return nil, errors.New("empty JWK set: set KEYCLOAK_JWK_B64")
	}
	if requiredRole == "" {
		return nil, errors.New("empty required role: set REQUIRED_REALM_ROLE")
	}

	raw, err := base64.StdEncoding.DecodeString(jwkB64)
	if err != nil {
		return nil, fmt.Errorf("decode JWK set: %w", err)
	}
	set, err := jwk.Parse(raw)
	if err != nil {
		return nil, fmt.Errorf("parse JWK set: %w", err)
	}
	if set.Len() == 0 {
		return nil, errors.New("JWK set contains no keys")
	}

	return &Verifier{keys: set, requiredRole: requiredRole, issuerSource: issuerSource}, nil
}

// currentIssuer returns the issuer, asking the source once and remembering a
// successful answer.
func (v *Verifier) currentIssuer() (string, error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	if v.issuer != "" {
		return v.issuer, nil
	}
	issuer, err := v.issuerSource()
	if err != nil {
		return "", err
	}
	v.issuer = issuer
	return issuer, nil
}

// IssuerFromDiscovery reads the issuer field of an OpenID discovery document.
func IssuerFromDiscovery(client *http.Client, url string) (string, error) {
	resp, err := client.Get(url)
	if err != nil {
		return "", fmt.Errorf("fetch discovery document: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("fetch discovery document: HTTP %d", resp.StatusCode)
	}
	var doc struct {
		Issuer string `json:"issuer"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&doc); err != nil {
		return "", fmt.Errorf("decode discovery document: %w", err)
	}
	if doc.Issuer == "" {
		return "", errors.New("discovery document has no issuer")
	}
	return doc.Issuer, nil
}

// Verify parses and validates a bearer token. Signature, issuer and expiry are
// checked by the parser; the realm role is checked here. The audience is
// deliberately not checked — Keycloak's client_credentials tokens carry an aud
// that depends on the mapper configuration, which is the same reason
// factory-helper's auth.rs sets validate_aud to false.
func (v *Verifier) Verify(bearer string) (*Claims, error) {
	issuer, err := v.currentIssuer()
	if err != nil {
		return nil, fmt.Errorf("cannot establish the issuer: %w", err)
	}
	claims := &Claims{}
	_, err = jwt.ParseWithClaims(bearer, claims, v.keyFor,
		jwt.WithValidMethods([]string{"RS256"}),
		jwt.WithIssuer(issuer),
		jwt.WithExpirationRequired(),
	)
	if err != nil {
		return nil, fmt.Errorf("invalid token: %w", err)
	}
	if !claims.HasRole(v.requiredRole) {
		return nil, fmt.Errorf("token lacks realm role %q", v.requiredRole)
	}
	return claims, nil
}

// keyFor resolves the signing key named by the token's kid header.
func (v *Verifier) keyFor(token *jwt.Token) (any, error) {
	kid, ok := token.Header["kid"].(string)
	if !ok {
		return nil, errors.New("token header has no string kid")
	}
	key, ok := v.keys.LookupKeyID(kid)
	if !ok {
		return nil, fmt.Errorf("no key with kid %q — a Keycloak key rotation needs a redeploy", kid)
	}
	var raw any
	if err := key.Raw(&raw); err != nil {
		return nil, fmt.Errorf("materialise key %q: %w", kid, err)
	}
	pub, ok := raw.(*rsa.PublicKey)
	if !ok {
		return nil, fmt.Errorf("key %q is not RSA", kid)
	}
	return pub, nil
}

// bearerFromContext pulls the token out of the gRPC authorization metadata.
func bearerFromContext(ctx context.Context) (string, error) {
	md, ok := metadata.FromIncomingContext(ctx)
	if !ok {
		return "", errors.New("no metadata on the call")
	}
	values := md.Get("authorization")
	if len(values) == 0 {
		return "", errors.New("no authorization metadata")
	}
	const prefix = "bearer "
	v := values[0]
	if len(v) < len(prefix) || !strings.EqualFold(v[:len(prefix)], prefix) {
		return "", errors.New("authorization metadata is not a bearer token")
	}
	return strings.TrimSpace(v[len(prefix):]), nil
}

// UnaryInterceptor guards unary calls.
//
// The Data API has no unary RPC today. It is here so that adding one cannot
// quietly arrive unguarded.
func (v *Verifier) UnaryInterceptor() grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, _ *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		if err := v.authorize(ctx); err != nil {
			return nil, err
		}
		return handler(ctx, req)
	}
}

// StreamInterceptor guards streaming calls.
//
// GetTelemetryData is server-streaming, so this is the interceptor that actually
// protects the Data API. A unary interceptor alone would compile, deploy and
// leave every telemetry read open.
func (v *Verifier) StreamInterceptor() grpc.StreamServerInterceptor {
	return func(srv any, ss grpc.ServerStream, _ *grpc.StreamServerInfo, handler grpc.StreamHandler) error {
		if err := v.authorize(ss.Context()); err != nil {
			return err
		}
		return handler(srv, ss)
	}
}

// authorize turns any failure into Unauthenticated without telling the caller
// which part failed.
func (v *Verifier) authorize(ctx context.Context) error {
	bearer, err := bearerFromContext(ctx)
	if err != nil {
		return status.Error(codes.Unauthenticated, "a bearer token is required")
	}
	if _, err := v.Verify(bearer); err != nil {
		return status.Error(codes.Unauthenticated, "the bearer token was rejected")
	}
	return nil
}
