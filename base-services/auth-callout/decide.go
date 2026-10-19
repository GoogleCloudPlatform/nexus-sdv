package main

import (
	"fmt"

	"auth-callout/grant"

	natsjwt "github.com/nats-io/jwt/v2"
)

// decision is what one connection gets: refused with a reason, or served with permissions —
// and, for a legacy identity in log mode, served with a would-deny reason to log.
type decision struct {
	perms   natsjwt.Permissions
	deny    bool
	reason  string
	granted bool
}

// decide turns an identity into permissions or a refusal (spec D6, R2). It is the whole
// decision, in one testable place: an unusable VIN counts as none; a legacy identity is
// refused where its kind is enforced and served exactly as today — empty permissions,
// which NATS treats as allow-all — where it is only logged; everyone else gets the control
// subject, the stored grant and the role grants.
func decide(id identity, kind string, roles []string, src grant.Source) decision {
	if !id.legacy && !validVIN(id.vin) {
		id.legacy = true
		id.source += "(invalid)"
	}
	if id.legacy {
		reason := fmt.Sprintf("no usable VIN (source=%s), kind=%s", id.source, kind)
		if enforceFor(kind) {
			return decision{deny: true, reason: reason}
		}
		return decision{reason: reason}
	}
	g := grant.Read(src, id.vin)
	return decision{perms: buildPermissions(id.vin, roles, g), granted: g != nil}
}

// validateEnforcement refuses to start with a switch value that means neither thing: an
// unknown value must never quietly become "log".
func validateEnforcement(leaf, client string) error {
	for name, v := range map[string]string{"LEAF_ENFORCEMENT": leaf, "CLIENT_ENFORCEMENT": client} {
		if v != "enforce" && v != "log" {
			return fmt.Errorf("%s must be \"enforce\" or \"log\", not %q", name, v)
		}
	}
	return nil
}
