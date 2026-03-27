package transform

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
	"text/template"
	"time"

	telemetry "data-converter/api/gen/telemetry"

	"github.com/google/uuid"
	"go.uber.org/zap"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// Transformer converts RawMessages into TelemetryMessages using a ConverterDef.
type Transformer struct {
	def    ConverterDef
	logger *zap.Logger
	funcs  template.FuncMap
}

// NewTransformer creates a new Transformer for the given converter definition.
func NewTransformer(def ConverterDef, logger *zap.Logger) *Transformer {
	return &Transformer{
		def:    def,
		logger: logger.Named("transform").Named(def.Name),
		funcs:  TemplateFuncs(),
	}
}

// TransformResult holds the output of a successful transformation.
type TransformResult struct {
	Message *telemetry.TelemetryMessage
	Subject string
}

// Transform converts a raw message topic + payload into a TelemetryMessage and NATS subject.
func (t *Transformer) Transform(topic string, payload []byte) (*TransformResult, error) {
	// Parse JSON payload
	var payloadMap map[string]interface{}
	if err := json.Unmarshal(payload, &payloadMap); err != nil {
		return nil, fmt.Errorf("json unmarshal: %w", err)
	}

	topicSegments := strings.Split(topic, "/")

	// Build template context
	ctx := map[string]interface{}{
		"topic":          topic,
		"topic_segments": topicSegments,
		"payload":        payloadMap,
	}

	// Resolve device_id
	deviceID, err := t.execTemplate("device_id", t.def.Mapping.DeviceID, ctx)
	if err != nil {
		return nil, fmt.Errorf("resolve device_id: %w", err)
	}
	if deviceID == "" {
		t.logger.Warn("device_id resolved to empty string", zap.String("topic", topic))
	}

	// Resolve sensors
	var sensorReadings []*telemetry.SensorReading
	var lastSensorName string

	for i, sm := range t.def.Mapping.Sensors {
		sensorName, err := t.execTemplate(fmt.Sprintf("sensor[%d].sensor", i), sm.Sensor, ctx)
		if err != nil {
			t.logger.Warn("failed to resolve sensor name, skipping",
				zap.Int("index", i), zap.Error(err))
			continue
		}

		sensorValue, err := t.execTemplate(fmt.Sprintf("sensor[%d].value", i), sm.Value, ctx)
		if err != nil {
			t.logger.Warn("failed to resolve sensor value, skipping",
				zap.Int("index", i), zap.Error(err))
			continue
		}

		dataType := resolveDataType(sm.DataType)
		lastSensorName = sensorName

		sensorReadings = append(sensorReadings, &telemetry.SensorReading{
			Timestamp: timestamppb.New(time.Now()),
			Value:     sensorValue,
			DataType:  dataType,
			Sensor:    sensorName,
		})
	}

	if len(sensorReadings) == 0 {
		return nil, fmt.Errorf("no sensor readings could be resolved from payload")
	}

	msg := &telemetry.TelemetryMessage{
		MessageId:     uuid.NewString(),
		SchemaVersion: 1,
		DeviceId:      deviceID,
		SensorData:    sensorReadings,
	}

	// Resolve NATS subject
	subjectCtx := map[string]interface{}{
		"device_id": deviceID,
		"sensor":    lastSensorName,
		"topic":     topic,
	}
	subject, err := t.execTemplate("subject", t.def.Target.SubjectPattern, subjectCtx)
	if err != nil {
		return nil, fmt.Errorf("resolve subject: %w", err)
	}

	return &TransformResult{Message: msg, Subject: subject}, nil
}

// execTemplate parses and executes a Go template string against the given data.
func (t *Transformer) execTemplate(name, tmplStr string, data interface{}) (string, error) {
	tmpl, err := template.New(name).Funcs(t.funcs).Parse(tmplStr)
	if err != nil {
		return "", fmt.Errorf("parse template %q: %w", name, err)
	}

	var buf bytes.Buffer
	if err := tmpl.Execute(&buf, data); err != nil {
		return "", fmt.Errorf("execute template %q: %w", name, err)
	}

	return strings.TrimSpace(buf.String()), nil
}

// resolveDataType converts a string data type to the protobuf enum.
func resolveDataType(dt string) telemetry.DataType {
	switch strings.ToUpper(dt) {
	case "STATIC":
		return telemetry.DataType_STATIC
	case "DYNAMIC":
		return telemetry.DataType_DYNAMIC
	default:
		return telemetry.DataType_DYNAMIC
	}
}
