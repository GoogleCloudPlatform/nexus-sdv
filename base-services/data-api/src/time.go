package main

import (
	dataapiv1 "data-api/api/gen/dataapi/v1"
	"fmt"
	"os"
	"time"
)

const TimestampFormat = "2006-01-02T15:04:05.000000000Z07:00" // magic timestamp that defines the format consistently

type Window struct {
	Start, End time.Time
}

func computeEffectiveWindow(
	req *dataapiv1.GetTelemetryDataRequest,
	maxLookback time.Duration,
) (Window, error) {
	now := time.Now().UTC()

	// --- If we are in a test environment, set "now" to a fixed date. ---
	if os.Getenv("TEST_ENV") == "true" {
		now = time.Date(2024, 1, 15, 10, 46, 0, 0, time.UTC)
	}

	capStart := now.Add(-maxLookback)

	switch selector := req.TimeSelector.(type) {
	case *dataapiv1.GetTelemetryDataRequest_Latest:
		// For 'latest' we set the window between 1970 and the current time
		return Window{Start: time.Unix(0, 0), End: now}, nil

	case *dataapiv1.GetTelemetryDataRequest_LastDuration:
		d := selector.LastDuration.AsDuration()
		if d <= 0 {
			return Window{}, fmt.Errorf("Last_duration must be positive.")
		}
		start := now.Add(-d)
		if start.Before(capStart) {
			start = capStart
		}
		// For 'LastDuration' we set the window between the queried time and the current time.
		return Window{Start: start, End: now}, nil

	case *dataapiv1.GetTelemetryDataRequest_TimeRange:
		start := selector.TimeRange.Start.AsTime()
		end := selector.TimeRange.End.AsTime()
		if end.Before(start) {
			return Window{}, fmt.Errorf("Time range End cannot be before Start.")
		}
		if start.Before(capStart) {
			start = capStart
		}
		if end.After(now) {
			end = now
		}
		if start.After(end) {
			start = end
		}
		// For 'TimeRange' we set the window between the two queried times.
		return Window{Start: start, End: end}, nil

	default:
		return Window{}, fmt.Errorf("A Time Selector is needed.")
	}
}
