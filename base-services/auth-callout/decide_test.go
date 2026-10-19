package main

import (
	"context"
	"testing"

	"auth-callout/grant"

	natsjwt "github.com/nats-io/jwt/v2"
	"github.com/stretchr/testify/assert"
)

type fixedGrant struct{ g *grant.Grant }

func (f fixedGrant) Grant(context.Context, string) (*grant.Grant, error) { return f.g, nil }

// The two switches are package state; every test sets them and restores them.
func setEnforcement(t *testing.T, leaf, client string) {
	t.Helper()
	oldLeaf, oldClient := leafEnforcement, clientEnforcement
	leafEnforcement, clientEnforcement = leaf, client
	t.Cleanup(func() { leafEnforcement, clientEnforcement = oldLeaf, oldClient })
}

func TestDecideDeniesALeafWithoutVin(t *testing.T) {
	setEnforcement(t, "enforce", "log")
	d := decide(identity{vin: "car", source: "azp", legacy: true}, "Leafnode", nil, grant.None{})
	assert.True(t, d.deny)
	assert.Contains(t, d.reason, "source=azp")
	assert.Contains(t, d.reason, "kind=Leafnode")
}

// D6: a token-only client on 4222 is served exactly as today — and today means empty
// permissions, which NATS treats as allow-all. Issuing registry.car.> instead would refuse
// its telemetry silently (the review's C5).
func TestDecideServesATokenOnlyClientAsToday(t *testing.T) {
	setEnforcement(t, "enforce", "log")
	d := decide(identity{vin: "car", source: "azp", legacy: true}, "Client", []string{"telemetry-client"}, grant.None{})
	assert.False(t, d.deny)
	assert.Contains(t, d.reason, "source=azp", "the would-deny reason names the source")
	assert.Empty(t, d.perms.Pub.Allow, "empty permissions are today's behaviour")
	assert.Empty(t, d.perms.Sub.Allow)
}

func TestDecideIssuesControlAndGrantForACertificate(t *testing.T) {
	setEnforcement(t, "enforce", "log")
	src := fixedGrant{g: &grant.Grant{Pub: []string{"pubsub.WBA123.pressure"}}}
	d := decide(identity{vin: "WBA123", source: "certificate"}, "Leafnode", nil, src)
	assert.False(t, d.deny)
	assert.Empty(t, d.reason)
	assert.Equal(t, natsjwt.StringList{"registry.WBA123.>", "pubsub.WBA123.pressure"}, d.perms.Pub.Allow)
	assert.Equal(t, natsjwt.StringList{"registry.WBA123.>"}, d.perms.Sub.Allow)
}

func TestDecideTreatsAnUnusableVinAsNone(t *testing.T) {
	setEnforcement(t, "enforce", "log")
	d := decide(identity{vin: "wba 123", source: "certificate"}, "Leafnode", nil, grant.None{})
	assert.True(t, d.deny)
	assert.Contains(t, d.reason, "certificate(invalid)")
}

// An unknown value must not silently mean "log" — that would fail open.
func TestEnforcementValuesAreValidated(t *testing.T) {
	assert.NoError(t, validateEnforcement("enforce", "log"))
	assert.NoError(t, validateEnforcement("log", "enforce"))
	assert.Error(t, validateEnforcement("Enforce", "log"))
	assert.Error(t, validateEnforcement("enforce", "yes"))
	assert.Error(t, validateEnforcement("", "log"))
}
