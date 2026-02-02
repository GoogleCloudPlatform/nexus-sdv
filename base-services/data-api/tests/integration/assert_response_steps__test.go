package integration

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/cucumber/godog"
	"github.com/stretchr/testify/assert"
)

// Adds the Gherkin steps for API interactions.
func (ts *TestSuite) registerAssertSteps(ctx *godog.ScenarioContext) {
	ctx.Step(`^the resulting telemetry should be:$`, ts.theResultingTelemetryShouldBe)
}

func (ts *TestSuite) theResultingTelemetryShouldBe(expected *godog.Table) error {
	if ts.LastError != nil {
		return fmt.Errorf("expected a successful response, but got an error: %w", ts.LastError)
	}

	// Iterate through each received point and compare it with the expected row.
	for i, actualPoint := range ts.LastResponse {
		expectedRow := expected.Rows[i+1] // +1 to skip header
		expectedTimestampStr := expectedRow.Cells[0].Value
		expectedDataType := expectedRow.Cells[1].Value
		expectedValue := expectedRow.Cells[2].Value

		// --- 2a. Compare Timestamps ---
		expectedTimestamp, err := time.Parse(time.RFC3339Nano, expectedTimestampStr)
		if err != nil {
			return fmt.Errorf("failed to parse expected timestamp in row %d: %w", i+1, err)
		}
		actualTimestamp := actualPoint.Timestamp.AsTime()

		if !assert.True(new(testing.T), expectedTimestamp.UTC().Equal(actualTimestamp.UTC()), "timestamp mismatch in point #%d", i+1) {
			return fmt.Errorf("Timestamp assertion failed in row %d. Expected: %v, Got: %v", i+1, expectedTimestamp.UTC(), actualTimestamp.UTC())
		}

		// --- 2b. Compare Data Values ---
		// Since there is only one data point per row in these scenarios,
		// we build the expected map directly from the table cells.
		expectedDataMap := map[string]string{
			expectedDataType: expectedValue,
		}

		actualDataMap := make(map[string]string)
		for k, v := range actualPoint.Values {
			actualDataMap[k] = string(v)
		}

		// Use testify's assert.Equal to compare the maps.
		if !assert.Equal(new(testing.T), expectedDataMap, actualDataMap, "data value mismatch in point %d", i+1) {
			return fmt.Errorf("Data value assertion failed in row %d. Excpected %s but got %s.", i+1, expectedDataMap, actualDataMap)
		}
	}

	return nil

}

func parseKeyValueString(input string) map[string]string {
	result := make(map[string]string)
	if input == "" {
		return result
	}

	for pair := range strings.SplitSeq(input, ",") {
		parts := strings.SplitN(pair, "=", 2)
		if len(parts) == 2 {
			key := strings.TrimSpace(parts[0])
			value := strings.TrimSpace(parts[1])
			result[key] = value
		}
	}
	return result
}
