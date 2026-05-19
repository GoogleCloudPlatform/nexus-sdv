package main

import (
	"testing"
	"time"

	natsjwt "github.com/nats-io/jwt/v2"
	"github.com/nats-io/nkeys"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestCreateNATSUserJWT(t *testing.T) {
	// Generate a temporary account key pair for signing
	accountKeyPair, err := nkeys.CreateAccount()
	require.NoError(t, err)

	// Generate a user nkey for the request
	userKeyPair, err := nkeys.CreateUser()
	require.NoError(t, err)
	userPub, err := userKeyPair.PublicKey()
	require.NoError(t, err)

	// Create dummy AuthorizationRequestClaims
	authReqClaims := &natsjwt.AuthorizationRequestClaims{
		AuthorizationRequest: natsjwt.AuthorizationRequest{
			UserNkey: userPub,
			ConnectOptions: natsjwt.ConnectOptions{
				Name: "test-user",
			},
		},
	}

	tests := []struct {
		name          string
		userName      string
		roles         []any
		validatePerms func(t *testing.T, claims *natsjwt.UserClaims)
	}{
		{
			name:     "Edge Device Role",
			userName: "vin-123",
			roles:    []any{"edge-device"},
			validatePerms: func(t *testing.T, claims *natsjwt.UserClaims) {
				assert.Contains(t, claims.Permissions.Sub.Allow, "commands.vin-123.>")
			},
		},
		{
			name:     "Telemetry Client Role",
			userName: "vin-456",
			roles:    []any{"telemetry-client"},
			validatePerms: func(t *testing.T, claims *natsjwt.UserClaims) {
				assert.Contains(t, claims.Permissions.Pub.Allow, "telemetry.vin-456.>")
			},
		},
		{
			name:     "Telemetry Collector Role",
			userName: "vin-789",
			roles:    []any{"telemetry-collector"},
			validatePerms: func(t *testing.T, claims *natsjwt.UserClaims) {
				assert.Contains(t, claims.Permissions.Sub.Allow, "telemetry.vin-789.>")
			},
		},
		{
			name:     "Multiple Roles",
			userName: "vin-mixed",
			roles:    []any{"edge-device", "telemetry-client"},
			validatePerms: func(t *testing.T, claims *natsjwt.UserClaims) {
				assert.Contains(t, claims.Permissions.Sub.Allow, "commands.vin-mixed.>")
				assert.Contains(t, claims.Permissions.Pub.Allow, "telemetry.vin-mixed.>")
			},
		},
		{
			name:     "Unknown Role",
			userName: "vin-unknown",
			roles:    []any{"unknown-role"},
			validatePerms: func(t *testing.T, claims *natsjwt.UserClaims) {
				assert.Empty(t, claims.Permissions.Sub.Allow)
				assert.Empty(t, claims.Permissions.Pub.Allow)
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			authReqClaims.ConnectOptions.Name = tt.userName
			jwtStr, err := createNATSUserJWT(tt.userName, tt.roles, accountKeyPair, authReqClaims)
			require.NoError(t, err)

			// Decode the generated JWT to verify claims
			claims, err := natsjwt.DecodeUserClaims(jwtStr)
			require.NoError(t, err)

			assert.Equal(t, tt.userName, claims.Name)
			assert.Equal(t, userPub, claims.Subject)
			assert.WithinDuration(t, time.Now().Add(1*time.Hour), time.Unix(claims.Expires, 0), 5*time.Second)

			if tt.validatePerms != nil {
				tt.validatePerms(t, claims)
			}
		})
	}
}
