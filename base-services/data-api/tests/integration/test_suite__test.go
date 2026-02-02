package integration

import (
	"context"
	"fmt"
	"log"
	"os"
	"testing"
	"time"

	"cloud.google.com/go/bigtable"
	"github.com/cucumber/godog"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	dataapiv1 "data-api/api/gen/dataapi/v1"
)

// TestSuite holds the shared state between steps for a single scenario.
type TestSuite struct {
	// Bigtable Emulator state
	BtAdminClient *bigtable.AdminClient
	BtClient      *bigtable.Client
	BtTable       *bigtable.Table

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
				os.Setenv("BIGTABLE_EMULATOR_HOST", "localhost:8086")
				ts.CurrentTime = time.Now()

				// --- gRPC Client Setup ---
				// The server runs in Docker in the background.
				grpcServerAddr := "localhost:8080"
				conn, err := grpc.NewClient(grpcServerAddr, grpc.WithTransportCredentials(insecure.NewCredentials()))
				if err != nil {
					return ctx, fmt.Errorf("failed to dial gRPC server at %s: %w", grpcServerAddr, err)
				}

				// Store the client in the TestSuite so steps can use it.
				ts.ApiClient = dataapiv1.NewTelemetryDataAPIClient(conn)

				return ctx, nil
			})

			ctx.After(func(ctx context.Context, sc *godog.Scenario, err error) (context.Context, error) {
				// --- gRPC and Bigtable Client Cleanup ---
				if ts.BtClient != nil {
					ts.BtClient.Close()
				}
				if ts.BtAdminClient != nil {
					// --- Table Deletion ---
					deleteErr := ts.BtAdminClient.DeleteTable(ctx, bigtableTable)
					if deleteErr != nil {
						// We log this error but don't fail the test, as it's a cleanup step.
						log.Printf("Warning: failed to delete table '%s' during cleanup: %v", bigtableTable, deleteErr)
					}
					ts.BtAdminClient.Close()
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
