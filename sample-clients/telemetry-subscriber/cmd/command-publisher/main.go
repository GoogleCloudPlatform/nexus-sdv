// command-publisher publishes a vehicle.command.Command with an
// ActuatorCommand payload to commands.<VIN>.actuator so you can test the
// cloud→vehicle command path against a connected client.
//
// It re-uses the JWT token cached in certificates/oidc-access-token (same
// mechanism as cmd/publish-test), so run the telemetry-subscriber or the
// vehicle-client once first.
//
// Usage (run from the telemetry-subscriber directory):
//
//	go run ./cmd/command-publisher \
//	  -nats-url nats://<host>:4222 \
//	  -vin WBA123 -actuator door_lock -value true
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/nats-io/nats.go"
	cmdpb "telemetry-subscriber/command"

	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"
)

func buildCommand(vin, actuator string, value bool) *cmdpb.Command {
	return &cmdpb.Command{
		VehicleId: vin,
		TargetId:  actuator,
		Timestamp: timestamppb.New(time.Now().UTC()),
		Priority:  cmdpb.Priority_NORMAL,
		RequestId: uuid.NewString(),
		Payload: &cmdpb.Command_ActuatorCommand{
			ActuatorCommand: &cmdpb.ActuatorCommand{
				ActuatorId: actuator,
				Value:      &cmdpb.ActuatorCommand_BoolValue{BoolValue: value},
			},
		},
	}
}

func commandSubject(vin string) string {
	return fmt.Sprintf("commands.%s.actuator", vin)
}

func main() {
	natsURL := flag.String("nats-url", "", "NATS server URL (e.g. nats://host:4222)")
	vin := flag.String("vin", "", "target VIN")
	actuator := flag.String("actuator", "door_lock", "actuator id")
	value := flag.Bool("value", true, "boolean actuator value")
	tokenFile := flag.String("token-file", "certificates/oidc-access-token", "path to cached OIDC access token")
	flag.Parse()

	if *natsURL == "" || *vin == "" {
		log.Fatal("-nats-url and -vin are required")
	}

	tokenBytes, err := os.ReadFile(*tokenFile)
	if err != nil {
		log.Fatalf("Cannot read token file %q: %v", *tokenFile, err)
	}
	jwt := strings.TrimSpace(string(tokenBytes))

	nc, err := nats.Connect(*natsURL, nats.Token(jwt))
	if err != nil {
		log.Fatalf("Failed to connect to NATS at %s: %v", *natsURL, err)
	}
	defer nc.Close()

	cmd := buildCommand(*vin, *actuator, *value)
	data, err := proto.Marshal(cmd)
	if err != nil {
		log.Fatalf("Failed to marshal command: %v", err)
	}

	subject := commandSubject(*vin)
	if err := nc.Publish(subject, data); err != nil {
		log.Fatalf("Publish %s: %v", subject, err)
	}
	if err := nc.Flush(); err != nil {
		log.Fatalf("Flush: %v", err)
	}
	fmt.Printf("✅ published %s: actuator=%s value=%t request_id=%s\n", subject, *actuator, *value, cmd.RequestId)
}
