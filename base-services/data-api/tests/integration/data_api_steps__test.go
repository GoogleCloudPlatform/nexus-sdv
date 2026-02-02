package integration

import (
	"context"
	"io"
	"log"
	"time"

	dataapiv1 "data-api/api/gen/dataapi/v1"

	"github.com/cucumber/godog"
	"google.golang.org/protobuf/types/known/durationpb"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// registerAPISteps adds the Gherkin steps for API interactions.
func (ts *TestSuite) registerAPISteps(ctx *godog.ScenarioContext) {
	// WHEN steps (we will implement the logic later)
	ctx.Step(`^I request the latest telemetry data for vehicle "([^"]*)" with data types:$`, ts.iRequestTheLatestTelemetry)
	ctx.Step(`^I request telemetry data for vehicle "([^"]*)" for the last "([^"]*)" \(since testing time\) with data types:$`, ts.iRequestTelemetryForTheLastDuration)
	ctx.Step(`^I request telemetry data for vehicle "([^"]*)" from "([^"]*)" to "([^"]*)" with data types:$`, ts.iRequestTelemetryForTimeRange)
}

func (ts *TestSuite) iRequestTheLatestTelemetry(ctx context.Context, vehicleID string, dataTypesTbl *godog.Table) error {
	req := &dataapiv1.GetTelemetryDataRequest{
		VehicleId: vehicleID,
		DataTypes: parseDataTableToStringSlice(dataTypesTbl),
		TimeSelector: &dataapiv1.GetTelemetryDataRequest_Latest{
			Latest: true,
		},
	}
	// Call the gRPC method and pass the result to our new helper.
	return ts.sendRequestAndStoreResponse(ctx, req)
}

func (ts *TestSuite) iRequestTelemetryForTheLastDuration(ctx context.Context, vehicleID, durationStr string, dataTypesTbl *godog.Table) error {
	duration, err := time.ParseDuration(durationStr)
	if err != nil {
		ts.LastError = err
		return nil
	}
	req := &dataapiv1.GetTelemetryDataRequest{
		VehicleId: vehicleID,
		DataTypes: parseDataTableToStringSlice(dataTypesTbl),
		TimeSelector: &dataapiv1.GetTelemetryDataRequest_LastDuration{
			LastDuration: durationpb.New(duration),
		},
	}
	return ts.sendRequestAndStoreResponse(ctx, req)
}

func (ts *TestSuite) iRequestTelemetryForTimeRange(ctx context.Context, vehicleID, startTimeStr, endTimeStr string, dataTypesTbl *godog.Table) error {
	startTime, err := time.Parse(time.RFC3339, startTimeStr)
	if err != nil {
		ts.LastError = err
		return nil
	}
	endTime, err := time.Parse(time.RFC3339, endTimeStr)
	if err != nil {
		ts.LastError = err
		return nil
	}
	req := &dataapiv1.GetTelemetryDataRequest{
		VehicleId: vehicleID,
		DataTypes: parseDataTableToStringSlice(dataTypesTbl),
		TimeSelector: &dataapiv1.GetTelemetryDataRequest_TimeRange{
			TimeRange: &dataapiv1.TimeRange{
				Start: timestamppb.New(startTime),
				End:   timestamppb.New(endTime),
			},
		},
	}
	return ts.sendRequestAndStoreResponse(ctx, req)
}

// --- Helper Functions ---

func (ts *TestSuite) sendRequestAndStoreResponse(ctx context.Context, req *dataapiv1.GetTelemetryDataRequest) error {
	// Send the gRPC request.
	stream, err := ts.ApiClient.GetTelemetryData(ctx, req)
	if err != nil {
		ts.LastError = err
		return nil // Return nil so the test continues to the assertion step.
	}

	// Read all messages from the stream.
	var receivedPoints []*dataapiv1.TelemetryPoint
	for {
		point, err := stream.Recv()
		if err == io.EOF {
			// End of stream.
			break
		}
		if err != nil {
			// An error occurred during the stream.
			ts.LastError = err
			return nil
		}
		receivedPoints = append(receivedPoints, point)
	}
	log.Printf("Received points: %s", receivedPoints)
	// Store the results on the TestSuite.
	ts.LastResponse = receivedPoints
	ts.LastError = nil // Clear any previous error if the stream was successful.

	return nil
}
