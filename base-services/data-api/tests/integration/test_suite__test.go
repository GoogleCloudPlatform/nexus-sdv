package integration

import (
	"context"
	"fmt"
	"log"
	"net"
	"testing"
	"time"

	"cloud.google.com/go/bigtable"
	"cloud.google.com/go/bigtable/bttest"
	"github.com/cucumber/godog"
	"go.uber.org/zap"
	"google.golang.org/api/option"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	dataapiv1 "data-api/api/gen/dataapi/v1"
	"data-api/src/service"
)

// TestSuite holds the shared state between steps for a single scenario.
type TestSuite struct {
	// Bigtable Emulator state
	BtServer      *bttest.Server
	BtAdminClient *bigtable.AdminClient
	BtClient      *bigtable.Client
	BtTable       *bigtable.Table

	// gRPC Server
	GrpcServer *grpc.Server

	// gRPC Client
	ApiClient dataapiv1.TelemetryDataAPIClient

	// Test execution state
	LastResponse []*dataapiv1.TelemetryPoint
	LastError    error
	CurrentTime  time.Time
}

// TestIntegration is the main entry point for running the Godog test suite.
func TestIntegration(t *testing.T) {
	ts := &TestSuite{}
	suite := godog.TestSuite{
		Name: "integration",
		ScenarioInitializer: func(ctx *godog.ScenarioContext) {
			// --- Register steps from all our step files ---
			ts.registerBigtableSteps(ctx)
			ts.registerAPISteps(ctx)
			ts.registerAssertSteps(ctx)

			ctx.Before(func(ctx context.Context, sc *godog.Scenario) (context.Context, error) {
				// --- Global Setup ---
				ts.CurrentTime = time.Now()

				// --- Bigtable Emulator Setup (In-Memory) ---
				srv, err := bttest.NewServer("localhost:0")
				if err != nil {
					return ctx, fmt.Errorf("failed to start bttest server: %w", err)
				}
				ts.BtServer = srv

				// --- Bigtable Client Setup ---
				// Connect to the in-memory server
				conn, err := grpc.NewClient(srv.Addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
				if err != nil {
					return ctx, fmt.Errorf("failed to dial bttest server: %w", err)
				}

				ts.BtAdminClient, err = bigtable.NewAdminClient(ctx, "test-project", "test-instance", option.WithGRPCConn(conn))
				if err != nil {
					return ctx, fmt.Errorf("failed to create admin client: %w", err)
				}

				ts.BtClient, err = bigtable.NewClient(ctx, "test-project", "test-instance", option.WithGRPCConn(conn))
				if err != nil {
					return ctx, fmt.Errorf("failed to create bigtable client: %w", err)
				}

				// --- gRPC Server Setup (In-Process) ---
				// Create a listener on a random port
				lis, err := net.Listen("tcp", "localhost:0")
				if err != nil {
					return ctx, fmt.Errorf("failed to listen: %w", err)
				}

				// Create the service
				logger := zap.NewNop()
				// We need to open the table for the service.
				// Note: The table might not exist yet when the service is created,
				// but the service uses the table object which is just a handle.
				// The actual existence is checked when operations are performed.
				// However, bigtable.Client.Open() just returns a *Table struct, it doesn't make a call.
				tbl := ts.BtClient.Open("telemetry")

				svc := service.NewServer(logger, tbl, service.Options{
					MaxLookback: 365 * 24 * time.Hour,
				})

				grpcServer := grpc.NewServer()
				dataapiv1.RegisterTelemetryDataAPIServer(grpcServer, svc)

				// Start server in a goroutine
				go func() {
					if err := grpcServer.Serve(lis); err != nil {
						// We can't easily fail the test from here, but we can log
						log.Printf("gRPC server failed: %v", err)
					}
				}()
				ts.GrpcServer = grpcServer

				// --- gRPC Client Setup ---
				// Connect to the in-process server
				clientConn, err := grpc.NewClient(lis.Addr().String(), grpc.WithTransportCredentials(insecure.NewCredentials()))
				if err != nil {
					return ctx, fmt.Errorf("failed to dial gRPC server: %w", err)
				}
				ts.ApiClient = dataapiv1.NewTelemetryDataAPIClient(clientConn)

				return ctx, nil
			})

			ctx.After(func(ctx context.Context, sc *godog.Scenario, err error) (context.Context, error) {
				// --- Cleanup ---
				if ts.GrpcServer != nil {
					ts.GrpcServer.Stop()
				}
				if ts.BtClient != nil {
					ts.BtClient.Close()
				}
				if ts.BtAdminClient != nil {
					ts.BtAdminClient.Close()
				}
				if ts.BtServer != nil {
					ts.BtServer.Close()
				}
				return ctx, nil
			})
		},
		Options: &godog.Options{
			Format:   "pretty",
			Paths:    []string{"features"},
			TestingT: t,
		},
	}

	if suite.Run() != 0 {
		t.Fatal("non-zero status returned, failed to run feature tests")
	}
}
