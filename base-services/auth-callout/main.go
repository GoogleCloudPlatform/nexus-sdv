package main

import (
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"time"

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
		glog.Debugf("  URL: %s", natsUrl)
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
				glog.Errorf(errMessage)
				return nil, errors.New(errMessage)
			}

			key, ok := keyset.LookupKeyID(keyID)
			if ok {
				var rawKey any
				if err := key.Raw(&rawKey); err != nil {
					errMessage := fmt.Sprintf("failed to create public key: %s", err)
					glog.Errorf(errMessage)
					return []byte(""), errors.New(errMessage)
				}
				rsaPublicKey, ok := rawKey.(*rsa.PublicKey)
				if !ok {
					errMessage := fmt.Sprintf("expected rsa key, got: %v", rawKey)
					glog.Errorf(errMessage)
					return nil, errors.New(errMessage)
				}
				glog.Info("Found public key")
				return rsaPublicKey, nil
			} else {
				errMessage := fmt.Sprintf("unable to find key with kid: %q", keyID)
				glog.Errorf(errMessage)
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

		glog.Infof("Claims: %v", claims)

		userRoles := claims["realm_access"].(map[string]any)["roles"].([]any)
		userName := claims["azp"].(string)

		// 3. Create a new NATS User JWT based on the claims
		userJWT, err := createNATSUserJWT(userName, userRoles, accountKeyPair, authRequestClaims)
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

		glog.Infof("Successfully issued NATS JWT for user '%s' with roles '%v'", userName, userRoles)
	})

	if err != nil {
		glog.Fatalf("Error subscribing: %v", err)
	}

	glog.Info("JWT auth callout service is running...")
	select {}
}

// createNATSUserJWT generates and signs a NATS user JWT.
func createNATSUserJWT(name string, roles []any, accountKeyPair nkeys.KeyPair, authReqClaims *natsjwt.AuthorizationRequestClaims) (string, error) {
	vin := name

	// Define permissions based on the roles from the external JWT
	var perms natsjwt.Permissions

	// roles are extracted from the Keycloak JWT
	for _, role := range roles {
		role = role.(string)
		// there can be special handling for specific role names
		switch role {
		case "edge-device":
			// this allows the subscription of a commands subject for this specific VIN/deviceID
			permission := fmt.Sprintf("commands.%s.>", vin)
			perms.Sub.Allow.Add(permission)
			glog.Debugf("Allowing the subscription of %s", permission)
		case "telemetry-client":
			permission := fmt.Sprintf("telemetry.%s.>", vin)
			perms.Pub.Allow.Add(permission)
			glog.Debugf("Allowing the publish of %s", permission)
		case "telemetry-collector":
			// TODO: check if the service has consent for the given VIN
			permission := fmt.Sprintf("telemetry.%s.>", vin)
			perms.Sub.Allow.Add(permission)
			glog.Debugf("Allowing the subscription of %s", permission)
		default:
			continue
		}
	}

	// Create the NATS user claims
	userClaims := natsjwt.NewUserClaims(authReqClaims.UserNkey)
	userClaims.Permissions = perms
	userClaims.Expires = time.Now().Add(1 * time.Hour).Unix()
	userClaims.Name = authReqClaims.ConnectOptions.Name
	userClaims.Audience = "$G"

	// Sign the claims with the account signing key to get the final JWT
	return userClaims.Encode(accountKeyPair)
}

// respondWithError is a helper to send a denial response.
func respondWithError(msg *nats.Msg, errMsg string) {
	resp := natsjwt.AuthorizationResponse{Error: errMsg}
	respJSON, _ := json.Marshal(resp)
	msg.Respond(respJSON)
}
