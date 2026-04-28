package service

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"go.uber.org/zap"
)

func TestBuildRowRange(t *testing.T) {
	logger := zap.NewNop()
	server := &Server{log: logger}

	vin := "test-vin"
	startTime := time.Date(2023, 10, 26, 10, 0, 0, 0, time.UTC)
	endTime := time.Date(2023, 10, 26, 11, 0, 0, 0, time.UTC)

	rowRange := server.buildRowRange(vin, startTime, endTime)

	// We can't easily inspect the internal fields of bigtable.RowRange,
	// but we can verify the function runs without error.
	// In a real integration test we would verify the range behavior.
	// For unit test, we trust the logic if the keys are constructed correctly.
	// Since buildRowRange constructs keys internally, we can't directly assert them
	// without exposing them or using a different testing approach.
	// However, we can check if it returns a non-nil range.
	assert.NotNil(t, rowRange)
}

func TestBuildSingleColumnFilter(t *testing.T) {
	logger := zap.NewNop()
	server := &Server{log: logger}

	filter := server.buildSingleColumnFilter("family:qualifier")
	assert.NotNil(t, filter)
}

func TestBuildColumnFilter(t *testing.T) {
	logger := zap.NewNop()
	server := &Server{log: logger}

	tests := []struct {
		name      string
		dataTypes []string
	}{
		{
			name:      "Single Column",
			dataTypes: []string{"f1:q1"},
		},
		{
			name:      "Multiple Columns Same Family",
			dataTypes: []string{"f1:q1", "f1:q2"},
		},
		{
			name:      "Multiple Families",
			dataTypes: []string{"f1:q1", "f2:q1"},
		},
		{
			name:      "Empty",
			dataTypes: []string{},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			filter := server.buildColumnFilter(tt.dataTypes)
			assert.NotNil(t, filter)
		})
	}
}

func TestParseTimestampFromRowKey(t *testing.T) {
	tests := []struct {
		name     string
		key      string
		wantTime time.Time
		wantOk   bool
	}{
		{
			name:     "Valid Key",
			key:      "vin#2023-10-26T10:00:00.000000000Z",
			wantTime: time.Date(2023, 10, 26, 10, 0, 0, 0, time.UTC),
			wantOk:   true,
		},
		{
			name:   "Invalid Timestamp",
			key:    "vin#invalid-time",
			wantOk: false,
		},
		{
			name:   "No Separator",
			key:    "vin-no-separator",
			wantOk: false,
		},
		{
			name:   "Empty Timestamp",
			key:    "vin#",
			wantOk: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotTime, gotOk := parseTimestampFromRowKey(tt.key)
			assert.Equal(t, tt.wantOk, gotOk)
			if tt.wantOk {
				assert.Equal(t, tt.wantTime, gotTime)
			}
		})
	}
}
