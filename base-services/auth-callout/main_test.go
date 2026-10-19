package main

import (
	"strings"
	"testing"

	"auth-callout/grant"
	"time"

	natsjwt "github.com/nats-io/jwt/v2"
	"github.com/nats-io/nkeys"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestControlSubjectIsAlwaysIssued(t *testing.T) {
	perms := buildPermissions("WBA123", nil, nil)
	assert.Equal(t, natsjwt.StringList{"registry.WBA123.>"}, perms.Pub.Allow)
	assert.Equal(t, natsjwt.StringList{"registry.WBA123.>"}, perms.Sub.Allow)
}

func TestGrantSubjectsAreIssuedVerbatim(t *testing.T) {
	g := &grant.Grant{Pub: []string{"pubsub.WBA123.pressure"}, Sub: []string{"pubsub.WBA123.command"}}
	perms := buildPermissions("WBA123", nil, g)
	assert.Contains(t, perms.Pub.Allow, "pubsub.WBA123.pressure")
	assert.Contains(t, perms.Sub.Allow, "pubsub.WBA123.command")
	assert.NotContains(t, perms.Pub.Allow, "pubsub.WBA123.command")
}

func TestGrantSubjectsOutsideTheVinNamespaceAreDropped(t *testing.T) {
	g := &grant.Grant{
		Pub: []string{"pubsub.>", "pubsub.OTHERVIN.pressure", "telemetry.WBA123.x", "pubsub.WBA123.ok"},
		Sub: []string{">", "pubsub.WBA123.ok"},
	}
	perms := buildPermissions("WBA123", nil, g)
	assert.Equal(t, natsjwt.StringList{"registry.WBA123.>", "pubsub.WBA123.ok"}, perms.Pub.Allow)
	assert.Equal(t, natsjwt.StringList{"registry.WBA123.>", "pubsub.WBA123.ok"}, perms.Sub.Allow)
}

func TestTelemetryRoleGrantsBothSubjectShapes(t *testing.T) {
	perms := buildPermissions("WBA123", []string{"telemetry-client"}, nil)
	for _, s := range []string{"telemetry.WBA123", "telemetry.WBA123.>", "telemetry.*.*.WBA123", "local.telemetry.WBA123", "local.telemetry.WBA123.>"} {
		assert.Contains(t, perms.Pub.Allow, s)
	}
}

// The subject names the format and the vehicle (spec 2026-10-09-telemetry-subjects): Google's
// SDV report travels on telemetry-aaos-sdv.<vin>, with room for a suffix, and only for the
// vehicle's own VIN.
func TestTelemetryRoleGrantsTheAaosSdvReportSubject(t *testing.T) {
	perms := buildPermissions("WBA123", []string{"telemetry-client"}, nil)
	assert.Contains(t, perms.Pub.Allow, "telemetry-aaos-sdv.WBA123")
	assert.Contains(t, perms.Pub.Allow, "telemetry-aaos-sdv.WBA123.>")
	for _, s := range perms.Pub.Allow {
		if strings.HasPrefix(s, "telemetry-aaos-sdv.") {
			assert.True(t, s == "telemetry-aaos-sdv.WBA123" || s == "telemetry-aaos-sdv.WBA123.>",
				"no wildcard and no other vehicle in the report family: %s", s)
		}
	}
}

func TestPubsubClientRoleNoLongerGrantsAnything(t *testing.T) {
	perms := buildPermissions("WBA123", []string{"pubsub-client"}, nil)
	assert.NotContains(t, perms.Pub.Allow, "pubsub.WBA123.>")
	assert.NotContains(t, perms.Sub.Allow, "pubsub.WBA123.>")
}

func TestValidVIN(t *testing.T) {
	for _, ok := range []string{"WBA123", "SMOKEKARSTEN01", "A", "ABCDEFGHJKLMNPRST"} {
		assert.True(t, validVIN(ok), ok)
	}
	for _, bad := range []string{"", "wba123", "WBA 123", "WBA.123", "WBA*", "WBA>", "ABCDEFGHJKLMNPRSTU", "car"} {
		assert.False(t, validVIN(bad), bad)
	}
}

// The issued JWT carries the permissions as built, the user's nkey as subject, the
// connection's name, and expires in an hour — the shape the server expects.
func TestCreateNATSUserJWT(t *testing.T) {
	accountKeyPair, err := nkeys.CreateAccount()
	require.NoError(t, err)
	userKeyPair, err := nkeys.CreateUser()
	require.NoError(t, err)
	userPub, err := userKeyPair.PublicKey()
	require.NoError(t, err)
	authReqClaims := &natsjwt.AuthorizationRequestClaims{
		AuthorizationRequest: natsjwt.AuthorizationRequest{
			UserNkey:       userPub,
			ConnectOptions: natsjwt.ConnectOptions{Name: "leaf-WBA123"},
		},
	}
	perms := buildPermissions("WBA123", []string{"edge-device"}, &grant.Grant{Pub: []string{"pubsub.WBA123.pressure"}})
	jwtStr, err := createNATSUserJWT(perms, accountKeyPair, authReqClaims)
	require.NoError(t, err)
	claims, err := natsjwt.DecodeUserClaims(jwtStr)
	require.NoError(t, err)
	assert.Equal(t, "leaf-WBA123", claims.Name)
	assert.Equal(t, userPub, claims.Subject)
	assert.WithinDuration(t, time.Now().Add(1*time.Hour), time.Unix(claims.Expires, 0), 5*time.Second)
	assert.Contains(t, claims.Permissions.Sub.Allow, "commands.WBA123.>")
	assert.Contains(t, claims.Permissions.Pub.Allow, "pubsub.WBA123.pressure")
	assert.Contains(t, claims.Permissions.Pub.Allow, "registry.WBA123.>")
	// D8: the vehicles live in the named account NEXUS, which has JetStream; $G cannot.
	assert.Equal(t, "NEXUS", claims.Audience)
}
