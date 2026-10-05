package main

import (
	"fmt"
	"log"
	"time"

	"github.com/nats-io/nats.go"
)

// jwtRefreshBuffer is how long before JWT expiry the connection is refreshed.
const jwtRefreshBuffer = 60 * time.Second

// telemetryConnection wraps a NATS connection together with the JWT expiry
// that governs when it must be re-authenticated.
type telemetryConnection struct {
	nc     *nats.Conn
	expiry time.Time
}

func (t *telemetryConnection) needsRefresh() bool {
	return time.Until(t.expiry) < jwtRefreshBuffer
}

// refresh re-authenticates with Keycloak and re-establishes the NATS connection.
func (t *telemetryConnection) refresh(v *VehicleClient) error {
	if t.nc != nil {
		t.nc.Close()
	}

	log.Println("Establishing telemetry NATS connection (re-authenticating with Keycloak)...")
	jwt, err := v.AuthenticateWithKeycloak()
	if err != nil {
		return fmt.Errorf("failed to get JWT: %w", err)
	}

	// Take the expiry from the token itself. It used to be a hard-coded copy of
	// the realm's accessTokenLifespan, which meant lowering that value left the
	// client waiting two weeks to refresh a token that had already died.
	t.expiry = jwtExpiry(jwt)
	if t.expiry.IsZero() {
		// No readable exp claim: refresh on the next tick rather than never.
		t.expiry = time.Now().Add(jwtRefreshBuffer)
		log.Println("JWT refreshed, but it carries no readable expiry — refreshing again shortly")
	} else {
		log.Printf("JWT refreshed, expires at: %s", t.expiry.Format(time.RFC3339))
	}

	nc, err := nats.Connect(v.natsURL, nats.Token(jwt))
	if err != nil {
		return fmt.Errorf("failed to connect to NATS: %w", err)
	}
	t.nc = nc
	log.Println("  Telemetry NATS connection established")

	return nil
}

// refreshIfNeeded refreshes the connection when the JWT is close to expiry.
func (t *telemetryConnection) refreshIfNeeded(v *VehicleClient) error {
	if !t.needsRefresh() {
		return nil
	}
	log.Println("JWT expiring soon, refreshing connection...")
	return t.refresh(v)
}
