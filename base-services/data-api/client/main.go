package main

import (
	"context"
	"crypto/tls"
	"flag"
	"log"
	"time"

	dataapiv1 "data-api/api/gen/dataapi/v1"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
)

func main() {
	serverAddr := flag.String("addr", "localhost:8080", "Host:Port der Data API")
	vin := flag.String("vin", "12345678901234567", "Die VIN, die abgefragt werden soll")
	useTls := flag.Bool("tls", false, "Use TLS (https) for connection")
	flag.Parse()

	log.Printf("Connecting to %s (TLS: %v)...", *serverAddr, *useTls)

	var creds credentials.TransportCredentials
	if *useTls {
		creds = credentials.NewTLS(&tls.Config{
			InsecureSkipVerify: true,
		})
	} else {
		creds = insecure.NewCredentials()
	}

	conn, err := grpc.NewClient(*serverAddr, grpc.WithTransportCredentials(creds))
	if err != nil {
		log.Fatalf("Did not connect: %v", err)
	}
	defer conn.Close()

	client := dataapiv1.NewTelemetryDataAPIClient(conn)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	req := &dataapiv1.GetTelemetryDataRequest{
		VehicleId: *vin,
		DataTypes: []string{
			"static:index",
			"static:test_key",
			"dynamic:time_passed",
		},
		TimeSelector: &dataapiv1.GetTelemetryDataRequest_Latest{
			Latest: true,
		},
	}

	log.Printf("Querying telemetry for VIN: %s...", *vin)
	stream, err := client.GetTelemetryData(ctx, req)
	if err != nil {
		log.Fatalf("Error calling GetTelemetryData: %v", err)
	}

	count := 0
	for {
		point, err := stream.Recv()
		if err != nil {
			if err.Error() == "EOF" {
				break
			}
			log.Fatalf("Stream error: %v", err)
		}
		count++
		log.Printf("[%d] Time: %s | Values: %s", count, point.Timestamp.AsTime().Format(time.RFC3339), point.Values)
	}
	log.Println("Done. Received", count, "data points.")
}