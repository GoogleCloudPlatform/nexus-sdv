package service

import (
	"testing"

	dataapiv1 "data-api/api/gen/dataapi/v1"

	"cloud.google.com/go/bigtable"
	"github.com/stretchr/testify/assert"
	"go.uber.org/zap"
)

func TestParseRowToTelemetryPoint(t *testing.T) {
	logger := zap.NewNop()
	server := &Server{log: logger}

	tests := []struct {
		name        string
		row         bigtable.Row
		wantPoint   bool
		checkValues func(t *testing.T, point *dataapiv1.TelemetryPoint)
	}{
		{
			name: "Valid Row",
			row: bigtable.Row{
				"vin#2023-10-26T10:00:00.000000000Z": []bigtable.ReadItem{
					{Row: "vin#2023-10-26T10:00:00.000000000Z", Column: "f1:q1", Value: []byte("val1")},
					{Row: "vin#2023-10-26T10:00:00.000000000Z", Column: "f1:q2", Value: []byte("val2")},
				},
			},
			wantPoint: true,
			checkValues: func(t *testing.T, point *dataapiv1.TelemetryPoint) {
				assert.NotNil(t, point)
				assert.Equal(t, int64(1698314400), point.Timestamp.Seconds)
				assert.Equal(t, []byte("val1"), point.Values["f1:q1"])
				assert.Equal(t, []byte("val2"), point.Values["f1:q2"])
			},
		},
		{
			name: "Malformed Key",
			row: bigtable.Row{
				"invalid-key": []bigtable.ReadItem{
					{Row: "invalid-key", Column: "f1:q1", Value: []byte("val1")},
				},
			},
			wantPoint: false,
		},
		{
			name: "Empty Values",
			row: bigtable.Row{
				"vin#2023-10-26T10:00:00.000000000Z": []bigtable.ReadItem{},
			},
			wantPoint: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// bigtable.Row is a map[string][]ReadItem.
			// We need to iterate over it to simulate how it's passed in the real code?
			// Wait, parseRowToTelemetryPoint takes a bigtable.Row which IS the map.
			// But inside the function it iterates over the map.
			// The map key is the row key.

			point, ok := server.parseRowToTelemetryPoint(tt.row)
			assert.Equal(t, tt.wantPoint, ok)
			if tt.wantPoint && tt.checkValues != nil {
				if assert.NotNil(t, point) {
					tt.checkValues(t, point)
				}
			}
		})
	}
}
