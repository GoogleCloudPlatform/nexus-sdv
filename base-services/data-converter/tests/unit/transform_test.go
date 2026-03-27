package unit

import (
	"testing"

	"data-converter/src/transform"

	"go.uber.org/zap"
)

func newTestTransformer(mapping transform.MappingConfig, target transform.TargetConfig) *transform.Transformer {
	return transform.NewTransformer(transform.ConverterDef{
		Name:    "test",
		Mapping: mapping,
		Target:  target,
	}, zap.NewNop())
}

func TestTransform_BasicJSON(t *testing.T) {
	tr := newTestTransformer(
		transform.MappingConfig{
			DeviceID: `{{ seg .topic 1 }}`,
			Sensors: []transform.SensorMapping{
				{
					Sensor:   `{{ jsonpath .payload "name" }}`,
					Value:    `{{ jsonpath .payload "value" }}`,
					DataType: "DYNAMIC",
				},
			},
		},
		transform.TargetConfig{
			SubjectPattern: "telemetry.{{ .device_id }}.{{ .sensor }}",
		},
	)

	result, err := tr.Transform("factory/line1/sensors/temp", []byte(`{"name":"temperature","value":"42.3"}`))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if result.Message.DeviceId != "line1" {
		t.Errorf("device_id = %q, want %q", result.Message.DeviceId, "line1")
	}
	if len(result.Message.SensorData) != 1 {
		t.Fatalf("sensor_data count = %d, want 1", len(result.Message.SensorData))
	}
	if result.Message.SensorData[0].Sensor != "temperature" {
		t.Errorf("sensor = %q, want %q", result.Message.SensorData[0].Sensor, "temperature")
	}
	if result.Message.SensorData[0].Value != "42.3" {
		t.Errorf("value = %q, want %q", result.Message.SensorData[0].Value, "42.3")
	}
	if result.Subject != "telemetry.line1.temperature" {
		t.Errorf("subject = %q, want %q", result.Subject, "telemetry.line1.temperature")
	}
	if result.Message.MessageId == "" {
		t.Error("message_id should not be empty")
	}
	if result.Message.SchemaVersion != 1 {
		t.Errorf("schema_version = %d, want 1", result.Message.SchemaVersion)
	}
}

func TestTransform_MultipleSensors(t *testing.T) {
	tr := newTestTransformer(
		transform.MappingConfig{
			DeviceID: `{{ seg .topic 1 }}`,
			Sensors: []transform.SensorMapping{
				{
					Sensor:   `{{ jsonpath .payload "temp_name" }}`,
					Value:    `{{ jsonpath .payload "temp_value" }}`,
					DataType: "DYNAMIC",
				},
				{
					Sensor:   `{{ jsonpath .payload "speed_name" }}`,
					Value:    `{{ jsonpath .payload "speed_value" }}`,
					DataType: "STATIC",
				},
			},
		},
		transform.TargetConfig{
			SubjectPattern: "telemetry.{{ .device_id }}.{{ .sensor }}",
		},
	)

	payload := `{"temp_name":"temperature","temp_value":"42.3","speed_name":"speed","speed_value":"120.5"}`
	result, err := tr.Transform("vehicles/VIN123/data", []byte(payload))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(result.Message.SensorData) != 2 {
		t.Fatalf("sensor_data count = %d, want 2", len(result.Message.SensorData))
	}
	if result.Message.SensorData[0].Sensor != "temperature" {
		t.Errorf("sensor[0] = %q, want %q", result.Message.SensorData[0].Sensor, "temperature")
	}
	if result.Message.SensorData[1].Sensor != "speed" {
		t.Errorf("sensor[1] = %q, want %q", result.Message.SensorData[1].Sensor, "speed")
	}
	// Subject should use the last sensor name
	if result.Subject != "telemetry.VIN123.speed" {
		t.Errorf("subject = %q, want %q", result.Subject, "telemetry.VIN123.speed")
	}
}

func TestTransform_NestedJSON(t *testing.T) {
	tr := newTestTransformer(
		transform.MappingConfig{
			DeviceID: `{{ seg .topic 1 }}`,
			Sensors: []transform.SensorMapping{
				{
					Sensor:   `{{ jsonpath .payload "sensor.type" }}`,
					Value:    `{{ jsonpath .payload "sensor.reading" }}`,
					DataType: "DYNAMIC",
				},
			},
		},
		transform.TargetConfig{
			SubjectPattern: "telemetry.{{ .device_id }}.{{ .sensor }}",
		},
	)

	payload := `{"sensor":{"type":"humidity","reading":"65.2"}}`
	result, err := tr.Transform("iot/gateway1/data", []byte(payload))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if result.Message.SensorData[0].Sensor != "humidity" {
		t.Errorf("sensor = %q, want %q", result.Message.SensorData[0].Sensor, "humidity")
	}
	if result.Message.SensorData[0].Value != "65.2" {
		t.Errorf("value = %q, want %q", result.Message.SensorData[0].Value, "65.2")
	}
}

func TestTransform_InvalidJSON(t *testing.T) {
	tr := newTestTransformer(
		transform.MappingConfig{
			DeviceID: `{{ seg .topic 1 }}`,
			Sensors: []transform.SensorMapping{
				{Sensor: `{{ jsonpath .payload "name" }}`, Value: `{{ jsonpath .payload "value" }}`},
			},
		},
		transform.TargetConfig{SubjectPattern: "telemetry.{{ .device_id }}"},
	)

	_, err := tr.Transform("test/dev1/data", []byte(`not json`))
	if err == nil {
		t.Error("expected error for invalid JSON")
	}
}

func TestTransform_EmptyPayload(t *testing.T) {
	tr := newTestTransformer(
		transform.MappingConfig{
			DeviceID: `{{ seg .topic 1 }}`,
			Sensors: []transform.SensorMapping{
				{Sensor: `{{ jsonpath .payload "name" }}`, Value: `{{ jsonpath .payload "value" }}`},
			},
		},
		transform.TargetConfig{SubjectPattern: "telemetry.{{ .device_id }}"},
	)

	_, err := tr.Transform("test/dev1/data", []byte(`{}`))
	if err == nil {
		t.Error("expected error for empty payload with missing fields")
	}
}

func TestTransform_TopicSegmentOutOfRange(t *testing.T) {
	tr := newTestTransformer(
		transform.MappingConfig{
			DeviceID: `{{ seg .topic 5 }}`,
			Sensors: []transform.SensorMapping{
				{Sensor: `{{ jsonpath .payload "name" }}`, Value: `{{ jsonpath .payload "value" }}`},
			},
		},
		transform.TargetConfig{SubjectPattern: "telemetry.{{ .device_id }}"},
	)

	_, err := tr.Transform("a/b", []byte(`{"name":"s","value":"1"}`))
	if err == nil {
		t.Error("expected error for topic segment out of range")
	}
}

func TestTransform_StaticDataType(t *testing.T) {
	tr := newTestTransformer(
		transform.MappingConfig{
			DeviceID: `{{ seg .topic 1 }}`,
			Sensors: []transform.SensorMapping{
				{
					Sensor:   `{{ jsonpath .payload "name" }}`,
					Value:    `{{ jsonpath .payload "value" }}`,
					DataType: "STATIC",
				},
			},
		},
		transform.TargetConfig{SubjectPattern: "telemetry.{{ .device_id }}.{{ .sensor }}"},
	)

	result, err := tr.Transform("test/dev1/data", []byte(`{"name":"firmware","value":"v2.1"}`))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if result.Message.SensorData[0].DataType != 0 { // STATIC = 0
		t.Errorf("data_type = %d, want 0 (STATIC)", result.Message.SensorData[0].DataType)
	}
}
