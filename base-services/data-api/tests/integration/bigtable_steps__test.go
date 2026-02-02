package integration

import (
	"context"
	"fmt"
	"strings"
	"time"

	"cloud.google.com/go/bigtable"
	"github.com/cucumber/godog"
)

const (
	gcpProjectID     = "test-project"
	bigtableInstance = "test-instance"
	bigtableTable    = "telemetry"
)

func (ts *TestSuite) registerBigtableSteps(ctx *godog.ScenarioContext) {
	ctx.Step(`^the telemetry bigtable is available$`, ts.theTelemetryBigtableIsAvailable)
	ctx.Step(`^vehicle "([^"]*)" has the following telemetry data:$`, ts.vehicleHasTheFollowingTelemetryData)
}

// Connects to the emulator and ensures the table and family exist.
func (ts *TestSuite) theTelemetryBigtableIsAvailable(ctx context.Context) error {
	var err error

	// Create an admin client to manage tables
	ts.BtAdminClient, err = bigtable.NewAdminClient(ctx, gcpProjectID, bigtableInstance)
	if err != nil {
		return err
	}

	// Delete any old table, create a fresh table and families
	_ = ts.BtAdminClient.DeleteTable(ctx, bigtableTable)

	if err := ts.BtAdminClient.CreateTable(ctx, bigtableTable); err != nil {
		return fmt.Errorf("failed to create table '%s': %w", bigtableTable, err)
	}

	if err := ts.BtAdminClient.CreateColumnFamily(ctx, bigtableTable, "dynamic"); err != nil {
		return fmt.Errorf("failed to create column family 'dynamic': %w", err)
	}
	if err := ts.BtAdminClient.CreateColumnFamily(ctx, bigtableTable, "static"); err != nil {
		return fmt.Errorf("failed to create column family 'static': %w", err)
	}

	// Create a data client for reading/writing data
	ts.BtClient, err = bigtable.NewClient(ctx, gcpProjectID, bigtableInstance)
	if err != nil {
		return err
	}
	ts.BtTable = ts.BtClient.Open(bigtableTable)

	return nil
}

// vehicleHasTheFollowingTelemetryData parses a Gherkin table and writes the data to Bigtable.
func (ts *TestSuite) vehicleHasTheFollowingTelemetryData(ctx context.Context, vehicleID string, table *godog.Table) error {
	// We will apply each row as an individual mutation.
	// While ApplyBulk could be used, a loop of Apply is clearer for this test logic.
	for i := 1; i < len(table.Rows); i++ {
		row := table.Rows[i]
		if len(row.Cells) != 3 {
			return fmt.Errorf("expected 3 columns in the data table (timestamp, data_type, value), but got %d", len(row.Cells))
		}

		timestampStr := row.Cells[0].Value
		fullDataType := row.Cells[1].Value
		value := row.Cells[2].Value

		// Parse the data type into family and qualifier.
		parts := strings.SplitN(fullDataType, ":", 2)
		if len(parts) != 2 {
			return fmt.Errorf("invalid data_type format in row %d: expected 'family:qualifier', got '%s'", i+1, fullDataType)
		}
		family, qualifier := parts[0], parts[1]

		// Parse the timestamp string from the feature file.
		timestamp, err := time.Parse(time.RFC3339Nano, timestampStr)
		if err != nil {
			return fmt.Errorf("failed to parse timestamp in row %d: '%s': %w", i+1, timestampStr, err)
		}

		// Construct the unique row key for this single data point.
		rowKey := fmt.Sprintf("%s#%s", vehicleID, timestamp.UTC().Format("2006-01-02T15:04:05.000000000Z07:00"))

		// Create a mutation for this single cell.
		mut := bigtable.NewMutation()
		mut.Set(family, qualifier, bigtable.Now(), []byte(value))

		// Apply the mutation for this single row.
		if err := ts.BtTable.Apply(ctx, rowKey, mut); err != nil {
			return fmt.Errorf("failed to apply mutation for row key '%s': %w", rowKey, err)
		}
	}

	return nil
}
