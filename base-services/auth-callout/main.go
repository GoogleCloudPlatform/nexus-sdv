package main

import (
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"time"

	"auth-callout/grant"

	"github.com/golang-jwt/jwt/v5"
	glog "github.com/labstack/gommon/log"
	"github.com/lestrrat-go/jwx/jwk"
	natsjwt "github.com/nats-io/jwt/v2"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nkeys"
)

var natsAccountSigningKeySeed = os.Getenv("JWT_ACC_SIGNING_KEY")
var keycloakJwkB64 = os.Getenv("KEYCLOAK_JWK_B64")
var natsUrl = os.Getenv("NATS_URL")
var natsUser = os.Getenv("NATS_USER")
var natsPassword = os.Getenv("NATS_PASSWORD")
var natsGrantUser = os.Getenv("NATS_GRANT_USER")
var natsGrantPassword = os.Getenv("NATS_GRANT_PASSWORD")

// The account every vehicle's connection is placed in — the one that has JetStream, where
// the grant store and the registry live (spec D8). The default global account cannot have
// JetStream once named accounts exist, which is why it is not "$G".
var vehicleAccount = envOr("NATS_VEHICLE_ACCOUNT", "NEXUS")

func main() {
	// Configure log level from environment variable
	logLevel := os.Getenv("LOG_LEVEL")
	if logLevel == "" {
		logLevel = "INFO" // Default to INFO if not set
	}

	switch logLevel {
	case "DEBUG":
		glog.SetLevel(glog.DEBUG)
	case "INFO":
		glog.SetLevel(glog.INFO)
	case "WARN":
		glog.SetLevel(glog.WARN)
	case "ERROR":
		glog.SetLevel(glog.ERROR)
	default:
		glog.SetLevel(glog.INFO)
		glog.Warnf("Unknown LOG_LEVEL '%s', defaulting to INFO", logLevel)
	}

	glog.Infof("Starting NATS auth callout service with log level: %s", logLevel)

	// Log connection details at DEBUG level
	if logLevel == "DEBUG" {
		maskedPassword := "****"
		if natsPassword != "" {
			// Show first 3 characters of password if available
			visibleChars := 3
			if len(natsPassword) < visibleChars {
				visibleChars = len(natsPassword)
			}
			if visibleChars > 0 {
				maskedPassword = natsPassword[:visibleChars] + "****"
			}
		}
		glog.Debugf("NATS connection details:")
		glog.Debugf("  URL: %s", redactURL(natsUrl))
		glog.Debugf("  User: %s", natsUser)
		glog.Debugf("  Password: %s", maskedPassword)
	}

	// Connect to NATS cluster
	var opts []nats.Option
	if natsUser != "" && natsPassword != "" {
		opts = append(opts, nats.UserInfo(natsUser, natsPassword))
		glog.Debug("Using username/password authentication")
	} else {
		glog.Debug("Connecting without authentication")
	}

	nc, err := nats.Connect(natsUrl, opts...)
	if err != nil {
		glog.Fatalf("Error connecting to NATS: %v", err)
	}
	defer nc.Close()
	glog.Info("Connected to NATS server")

	// Load the NATS account signing key from its seed
	accountKeyPair, err := nkeys.FromSeed([]byte(natsAccountSigningKeySeed))
	if err != nil {
		glog.Fatalf("Failed to load account signing key: %v", err)
	}

	// The grant store — the registry's decision per VIN (Increment 2.2). Without it, fail
	// closed: every vehicle gets its control subject only, never allow-all.
	var grants grant.Source = grant.None{}
	if natsGrantUser != "" && natsGrantPassword != "" {
		if kv, err := grant.NewKV(natsUrl, natsGrantUser, natsGrantPassword); err != nil {
			glog.Errorf("grant reader unavailable: %v — every vehicle gets its control subject only", err)
		} else {
			grants = kv
			// Not "bound": the reader connects in the background and binds at its first
			// read, where it says so. This line once claimed more than was true.
			glog.Infof("grant reader set up for bucket %s", grant.Bucket)
		}
	} else {
		glog.Warn("NATS_GRANT_USER/NATS_GRANT_PASSWORD not set — every vehicle gets its control subject only")
	}
	if err := validateEnforcement(leafEnforcement, clientEnforcement); err != nil {
		glog.Fatalf("%v", err)
	}
	glog.Infof("enforcement: leaf=%s client=%s", leafEnforcement, clientEnforcement)

	// base64 decode the JWK
	keycloakJwk, err := base64.StdEncoding.DecodeString(keycloakJwkB64)
	if err != nil {
		glog.Fatalf("error: %v", err)
	}

	// Create JWK keyset
	keyset, err := jwk.Parse(keycloakJwk)
	if err != nil {
		errMessage := fmt.Sprintf("failed to parse JWK: %v", err)
		glog.Fatal(errMessage)
	}

	// Subscribe to auth requests
	_, err = nc.Subscribe("$SYS.REQ.USER.AUTH", func(msg *nats.Msg) {
		natsTempTokenString := string(msg.Data)

		authRequestClaims, err := natsjwt.DecodeAuthorizationRequestClaims(natsTempTokenString)
		if err != nil {
			glog.Errorf("Error when decoding nats temp token: %v", err)
			respondWithError(msg, "Error when decoding nats temp token")
			return
		}

		// 1. Validate the incoming external JWT
		token, err := jwt.Parse(authRequestClaims.ConnectOptions.Token, func(token *jwt.Token) (any, error) {
			glog.Info("Trying to parse token")

			keyID, ok := token.Header["kid"].(string)
			if !ok {
				errMessage := "expecting JWT header to have string kid"
				glog.Error(errMessage)
				return nil, errors.New(errMessage)
			}

			key, ok := keyset.LookupKeyID(keyID)
			if ok {
				var rawKey any
				if err := key.Raw(&rawKey); err != nil {
					errMessage := fmt.Sprintf("failed to create public key: %s", err)
					glog.Error(errMessage)
					return []byte(""), errors.New(errMessage)
				}
				rsaPublicKey, ok := rawKey.(*rsa.PublicKey)
				if !ok {
					errMessage := fmt.Sprintf("expected rsa key, got: %v", rawKey)
					glog.Error(errMessage)
					return nil, errors.New(errMessage)
				}
				glog.Info("Found public key")
				return rsaPublicKey, nil
			} else {
				errMessage := fmt.Sprintf("unable to find key with kid: %q", keyID)
				glog.Error(errMessage)
				return nil, errors.New(errMessage)
			}
		})

		if err != nil || !token.Valid {
			glog.Errorf("Error when validating token: %v", err)
			respondWithError(msg, "invalid token")
			return
		}

		glog.Info("Validation successful!")

		// 2. Extract claims from the valid token
		claims, ok := token.Claims.(jwt.MapClaims)
		if !ok {
			glog.Error("Could not extract claims")
			respondWithError(msg, "invalid token claims")
			return
		}

		// 3. Who is this — from the certificate the server verified, if the connection is
		//    a leaf with one — then the decision: refused, served as today, or granted.
		//    Log what the decision uses, never the whole claim set.
		id := resolveIdentityFrom(authRequestClaims.TLS, claims)
		roles := extractRealmRoles(claims)
		kind := authRequestClaims.ClientInformation.Kind
		d := decide(id, kind, roles, grants)
		glog.Infof("vin=%s source=%s kind=%s legacy=%v grant=%v", id.vin, id.source, kind, id.legacy || d.reason != "", d.granted)
		glog.Debugf("  roles=%v -> pub=%v sub=%v", roles, d.perms.Pub.Allow, d.perms.Sub.Allow)
		if d.deny {
			glog.Warnf("deny: %s", d.reason)
			respondWithError(msg, "unauthorized")
			return
		}
		if d.reason != "" {
			glog.Warnf("would-deny: %s", d.reason)
		}
		perms := d.perms

		// 4. Sign the permissions into a NATS user JWT
		userJWT, err := createNATSUserJWT(perms, accountKeyPair, authRequestClaims)
		if err != nil {
			glog.Errorf("Failed to create NATS user JWT: %v", err)
			respondWithError(msg, "internal server error")
			return
		}

		// 4. Send the successful response with the new NATS User JWT
		innerRespJwt := natsjwt.AuthorizationResponse{Jwt: userJWT, IssuerAccount: authRequestClaims.Subject}

		respJwt := natsjwt.NewAuthorizationResponseClaims(authRequestClaims.UserNkey)

		// set inner JWT with permissions
		respJwt.AuthorizationResponse = innerRespJwt

		respJwt.Audience = authRequestClaims.Server.ID
		respJwt.Issuer = authRequestClaims.Subject

		respJwtResult, _ := respJwt.Encode(accountKeyPair)

		err = msg.Respond([]byte(respJwtResult))
		if err != nil {
			glog.Errorf("Failed to send NATS response: %v", err)
			respondWithError(msg, "internal server error")
			return
		}

		glog.Infof("Successfully issued NATS JWT for '%s' (vin=%s source=%s)", authRequestClaims.ConnectOptions.Name, id.vin, id.source)
	})

	if err != nil {
		glog.Fatalf("Error subscribing: %v", err)
	}

	glog.Info("JWT auth callout service is running...")
	select {}
}

// buildPermissions issues, for one VIN: its control subject — always —, what the registry
// has granted it under pubsub.<vin>., and the telemetry grants its realm roles carry (the
// non-AAOS path, D5a). Never empty, so a vehicle that is known but has no grant yet can
// still announce itself.
func buildPermissions(vin string, roles []string, g *grant.Grant) natsjwt.Permissions {
	var perms natsjwt.Permissions
	control := fmt.Sprintf("registry.%s.>", vin)
	perms.Pub.Allow.Add(control)
	perms.Sub.Allow.Add(control)

	for _, role := range roles {
		switch role {
		case "edge-device":
			perms.Sub.Allow.Add(fmt.Sprintf("commands.%s.>", vin))
		case "telemetry-client":
			// The subject names the format and the vehicle: telemetry.<vin> is the Nexus
			// message, telemetry-aaos-sdv.<vin> Google's SDV report, each with room for a
			// suffix.
			perms.Pub.Allow.Add(fmt.Sprintf("telemetry.%s", vin))
			perms.Pub.Allow.Add(fmt.Sprintf("telemetry.%s.>", vin))
			perms.Pub.Allow.Add(fmt.Sprintf("telemetry-aaos-sdv.%s", vin))
			perms.Pub.Allow.Add(fmt.Sprintf("telemetry-aaos-sdv.%s.>", vin))
			// Accepted for one more release: the shapes in use before that rule — the VIN
			// last (telemetry.prod.bigtable.<vin>), and the report under local.telemetry.
			perms.Pub.Allow.Add(fmt.Sprintf("telemetry.*.*.%s", vin))
			perms.Pub.Allow.Add(fmt.Sprintf("local.telemetry.%s", vin))
			perms.Pub.Allow.Add(fmt.Sprintf("local.telemetry.%s.>", vin))
		case "telemetry-collector":
			perms.Sub.Allow.Add(fmt.Sprintf("telemetry.%s", vin))
			perms.Sub.Allow.Add(fmt.Sprintf("telemetry.%s.>", vin))
		}
	}

	if g != nil {
		for _, s := range g.Pub {
			if grant.InVinNamespace(vin, s) {
				perms.Pub.Allow.Add(s)
			} else {
				glog.Warnf("grant for vin=%s names %q outside its namespace — dropped", vin, s)
			}
		}
		for _, s := range g.Sub {
			if grant.InVinNamespace(vin, s) {
				perms.Sub.Allow.Add(s)
			} else {
				glog.Warnf("grant for vin=%s names %q outside its namespace — dropped", vin, s)
			}
		}
	}
	return perms
}

// createNATSUserJWT signs the permissions into a NATS user JWT.
func createNATSUserJWT(perms natsjwt.Permissions, accountKeyPair nkeys.KeyPair, authReqClaims *natsjwt.AuthorizationRequestClaims) (string, error) {
	userClaims := natsjwt.NewUserClaims(authReqClaims.UserNkey)
	userClaims.Permissions = perms
	userClaims.Expires = time.Now().Add(1 * time.Hour).Unix()
	userClaims.Name = authReqClaims.ConnectOptions.Name
	userClaims.Audience = vehicleAccount
	return userClaims.Encode(accountKeyPair)
}

// respondWithError is a helper to send a denial response.
func respondWithError(msg *nats.Msg, errMsg string) {
	resp := natsjwt.AuthorizationResponse{Error: errMsg}
	respJSON, _ := json.Marshal(resp)
	msg.Respond(respJSON)
}
