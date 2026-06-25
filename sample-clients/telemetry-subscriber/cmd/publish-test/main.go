// publish-test publishes one sample MetricsReport to each connector branch so
// you can verify that Bigtable receives plain-text (non-base64) values.
//
// It re-uses the JWT token cached by the telemetry-subscriber in
// certificates/oidc-access-token, so you must have run the subscriber at
// least once (or run run-telemetry-subscriber.sh) before using this tool.
//
// Usage (run from the telemetry-subscriber directory):
//
//	go run ./cmd/publish-test \
//	  -nats-url nats://<host>:4222 \
//	  -vin TEST001
package main

import (
	"flag"
	"fmt"
	"log"
	"math/rand"
	"os"
	"strings"
	"time"

	"github.com/nats-io/nats.go"
	aaospb "telemetry-subscriber/aaos_telemetry"
	carlapb "telemetry-subscriber/carla"
	pb "telemetry-subscriber/telemetry"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/anypb"
	"google.golang.org/protobuf/types/known/timestamppb"
)

func main() {
	natsURL   := flag.String("nats-url",    "",                             "NATS server URL (e.g. nats://host:4222)")
	vin       := flag.String("vin",         "TEST001",                      "VIN to publish on")
	tokenFile := flag.String("token-file",  "certificates/oidc-access-token", "Path to cached OIDC access token")
	flag.Parse()

	if *natsURL == "" {
		log.Fatal("-nats-url is required")
	}

	tokenBytes, err := os.ReadFile(*tokenFile)
	if err != nil {
		log.Fatalf("Cannot read token file %q: %v", *tokenFile, err)
	}
	jwt := strings.TrimSpace(string(tokenBytes))
	log.Printf("Loaded JWT from %s", *tokenFile)

	nc, err := nats.Connect(*natsURL, nats.Token(jwt))
	if err != nil {
		log.Fatalf("Failed to connect to NATS at %s: %v", *natsURL, err)
	}
	defer nc.Close()
	log.Printf("Connected to NATS at %s", *natsURL)

	rng := rand.New(rand.NewSource(time.Now().UnixNano()))
	f32 := func(min, max float32) float32 { return min + rng.Float32()*(max-min) }
	f64 := func(min, max float64) float64 { return min + rng.Float64()*(max-min) }

	velocity   := f32(0, 40)      // m/s  (~0–144 km/h)
	engineRPM  := f32(800, 6000)
	maxSpeed   := f32(30, 60)     // m/s
	speedlimit := f32(10, 35)     // m/s
	lat        := float32(f64(41.49, 41.51))
	lng        := float32(f64(2.10, 2.12))
	alt        := f64(100, 150)

	now := timestamppb.New(time.Now().UTC())

	// =========================================================================
	// 1. telemetry.<VIN>  — CarlaSimulationReport inner Any
	// =========================================================================
	carlaReport := &carlapb.CarlaSimulationReport{
		Velocity:  &carlapb.CarlaMetricValue{IntValue: proto.Int64(int64(velocity)), FloatValue: proto.Float32(velocity)},
		EngineRpm: &carlapb.CarlaMetricValue{IntValue: proto.Int64(int64(engineRPM)), FloatValue: proto.Float32(engineRPM)},
		FuelLevel: &carlapb.CarlaMetricValue{IntValue: proto.Int64(60), FloatValue: proto.Float32(60.0)},
		MaxSpeed:  &carlapb.CarlaMetricValue{IntValue: proto.Int64(int64(maxSpeed)), FloatValue: proto.Float32(maxSpeed)},
		SpeedInfo: &carlapb.CarlaSpeedData{
			SpeedLimitMS: proto.Float64(float64(speedlimit)),
			MaxSpeedMS:   proto.Float64(float64(maxSpeed)),
		},
		Gnss: &carlapb.CarlaGnssData{
			Latitude:    proto.Float64(float64(lat)),
			Longitude:   proto.Float64(float64(lng)),
			Altitude:    proto.Float64(alt),
			Speed:       proto.Float64(float64(velocity)),
			TimestampMs: proto.Int64(time.Now().UnixMilli()),
		},
	}

	carlaAny, err := anypb.New(carlaReport)
	if err != nil {
		log.Fatalf("Failed to pack CarlaSimulationReport into Any: %v", err)
	}
	if err := publish(nc, "telemetry."+*vin, &pb.MetricsReport{ReportNumber: 1, ReportTimestamp: now, ReportData: carlaAny}); err != nil {
		log.Fatalf("Publish telemetry.%s: %v", *vin, err)
	}
	fmt.Printf("✅ telemetry.%s\n", *vin)
	fmt.Printf("   VELOCITY=%.3f  ENGINE_RPM=%.1f  max_speed=%.3f  speedlimit=%.3f  GPS_ALTITUDE=%.2f\n",
		velocity, engineRPM, maxSpeed, speedlimit, alt)

	// =========================================================================
	// 2. local.telemetry.<VIN>  — AAOS VehicleTelemetryData inner Any
	// =========================================================================
	aaosData := &aaospb.VehicleTelemetryData{
		ENGINE_RPM:             proto.Float32(engineRPM),
		FUEL_LEVEL:             proto.Float32(f32(10, 80)),
		GPS_LATITUDE:           proto.Float32(lat),
		GPS_LONGITUDE:          proto.Float32(lng),
		VELOCITY:               proto.Float32(velocity),
		LOCKED:                 proto.Bool(false),
		AccelerationModulusMS2: proto.Float64(f64(0, 5)),
		DistanceMeters:         proto.Uint64(uint64(rng.Intn(100000))),
		MaxSpeed:               proto.Float32(maxSpeed),
		Speedlimit:             proto.Float32(speedlimit),
		VehicleDynamics: &aaospb.CarlaVehicleDynamics{
			AcceleratorPedalPct: proto.Float64(f64(0, 100)),
			SteeringAngleDeg:    proto.Float64(f64(-30, 30)),
		},
	}

	aaosAny, err := anypb.New(aaosData)
	if err != nil {
		log.Fatalf("Failed to pack AAOS VehicleTelemetryData into Any: %v", err)
	}
	if err := publish(nc, "local.telemetry."+*vin, &pb.MetricsReport{ReportNumber: 1, ReportTimestamp: now, ReportData: aaosAny}); err != nil {
		log.Fatalf("Publish local.telemetry.%s: %v", *vin, err)
	}
	fmt.Printf("✅ local.telemetry.%s\n", *vin)
	fmt.Printf("   VELOCITY=%.3f  ENGINE_RPM=%.1f  max_speed=%.3f  speedlimit=%.3f\n",
		velocity, engineRPM, maxSpeed, speedlimit)

	nc.Flush()
	fmt.Println("\nDone. Check Bigtable in a few seconds.")
}

func publish(nc *nats.Conn, subject string, msg proto.Message) error {
	data, err := proto.Marshal(msg)
	if err != nil {
		return fmt.Errorf("marshal: %w", err)
	}
	return nc.Publish(subject, data)
}
