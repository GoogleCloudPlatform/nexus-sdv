package main

import (
	"context"
	"crypto/tls"
	"flag"
	"log"
	"strings"
	"time"

	dataapiv1 "data-api/api/gen/dataapi/v1"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
)

func main() {
	serverAddr := flag.String("addr", "localhost:8080", "host:port of the Data API")
	vin := flag.String("vin", "12345678901234567", "the VIN to query")
	useTls := flag.Bool("tls", false, "use TLS; the Data API speaks plaintext gRPC inside the cluster")
	caFile := flag.String("ca", "", "with --tls: PEM trust anchor for the server certificate; empty uses the system roots")
	token := flag.String("token", "", "Keycloak access token; the Data API requires one since #558")
	// The default is what the devices and IoT clients write. A vehicle writes
	// different signals - the Go vehicle-client VELOCITY and ENGINE_RPM, the
	// Python VSS client Vehicle.Speed - so querying a vehicle with the default
	// returns nothing and looks like a broken platform.
	dataTypes := flag.String("datatypes", "static:index,static:test_key,dynamic:time_passed",
		"comma-separated data types to query")
	flag.Parse()

	log.Printf("Connecting to %s (TLS: %v)...", *serverAddr, *useTls)

	var creds credentials.TransportCredentials
	if *useTls {
		// For an endpoint that does speak TLS. Verification is not skipped: an
		// unverified TLS connection would accept any certificate, which is how a
		// token ends up with whoever answered.
		if *caFile != "" {
			var err error
			creds, err = credentials.NewClientTLSFromFile(*caFile, "")
			if err != nil {
				log.Fatalf("Could not read the trust anchor %s: %v", *caFile, err)
			}
		} else {
			creds = credentials.NewTLS(&tls.Config{})
		}
	} else {
		creds = insecure.NewCredentials()
	}

	opts := []grpc.DialOption{grpc.WithTransportCredentials(creds)}
	if *token != "" {
		opts = append(opts, grpc.WithPerRPCCredentials(bearer(*token)))
	}

	conn, err := grpc.NewClient(*serverAddr, opts...)
	if err != nil {
		log.Fatalf("Did not connect: %v", err)
	}
	defer conn.Close()

	client := dataapiv1.NewTelemetryDataAPIClient(conn)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	types := strings.Split(*dataTypes, ",")
	for i := range types {
		types[i] = strings.TrimSpace(types[i])
	}

	req := &dataapiv1.GetTelemetryDataRequest{
		VehicleId: *vin,
		DataTypes: types,
		TimeSelector: &dataapiv1.GetTelemetryDataRequest_Latest{
			Latest: true,
		},
	}

	log.Printf("Querying telemetry for VIN: %s, data types: %s", *vin, strings.Join(types, ", "))
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
	if count == 0 {
		// An empty answer is far more often the wrong data type than a broken
		// platform, so say which ones were asked for rather than just "0".
		log.Printf("Done. Received 0 data points for %s. The vehicle may not write %s — pass --datatypes.",
			*vin, strings.Join(types, ", "))
	} else {
		log.Println("Done. Received", count, "data points.")
	}
}

// bearer puts a Keycloak access token on every call. Obtain one with the
// client_credentials flow, for example:
//
//	curl -s -d grant_type=client_credentials -d client_id=factory-operator \
//	  -d client_secret="$(gcloud secrets versions access latest \
//	    --secret=FACTORY_OPERATOR_CLIENT_SECRET --project=<PROJECT_ID>)" \
//	  https://keycloak-ui.<BASE_DOMAIN>/realms/sdv-telemetry/protocol/openid-connect/token \
//	  | jq -r .access_token
type bearer string

func (b bearer) GetRequestMetadata(context.Context, ...string) (map[string]string, error) {
	return map[string]string{"authorization": "Bearer " + string(b)}, nil
}

// RequireTransportSecurity is false because the Data API is cluster-internal and
// speaks plaintext gRPC; a port forward to it is already encrypted from the
// workstation to the pod. Returning true would make gRPC refuse to send the
// token at all on a plaintext connection.
func (b bearer) RequireTransportSecurity() bool { return false }
