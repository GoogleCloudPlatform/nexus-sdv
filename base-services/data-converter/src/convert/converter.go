package convert

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

// Converter converts RawMessages into TelemetryMessages using a ConverterDef.
type Converter struct {
	def    ConverterDef
	logger *zap.Logger
	funcs  template.FuncMap
}

// NewConverter creates a new Converter for the given converter definition.
func NewConverter(def ConverterDef, logger *zap.Logger) *Converter {
	return &Converter{
		def:    def,
		logger: logger.Named("converter").Named(def.Name),
		funcs:  TemplateFuncs(),
	}
}

// ConvertResult holds the output of a successful conversion.
type ConvertResult struct {
	Message *telemetry.TelemetryMessage
	Subject string
}

// Convert converts a raw message topic + payload into a TelemetryMessage and NATS subject.
func (c *Converter) Convert(topic string, payload []byte) (*ConvertResult, error) {
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
	deviceID, err := c.execTemplate("device_id", c.def.Mapping.DeviceID, ctx)
	if err != nil {
		return nil, fmt.Errorf("resolve device_id: %w", err)
	}
	if deviceID == "" {
		c.logger.Warn("device_id resolved to empty string", zap.String("topic", topic))
	}

	// Resolve sensors
	var sensorReadings []*telemetry.SensorReading
	var lastSensorName string

	for i, sm := range c.def.Mapping.Sensors {
		sensorName, err := c.execTemplate(fmt.Sprintf("sensor[%d].sensor", i), sm.Sensor, ctx)
		if err != nil {
			c.logger.Warn("failed to resolve sensor name, skipping",
				zap.Int("index", i), zap.Error(err))
			continue
		}

		sensorValue, err := c.execTemplate(fmt.Sprintf("sensor[%d].value", i), sm.Value, ctx)
		if err != nil {
			c.logger.Warn("failed to resolve sensor value, skipping",
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
		"device_id":      deviceID,
		"sensor":         lastSensorName,
		"topic":          topic,
		"subject_prefix": c.def.Target.SubjectPrefix,
	}
	subject, err := c.execTemplate("subject", c.def.Target.SubjectPattern, subjectCtx)
	if err != nil {
		return nil, fmt.Errorf("resolve subject: %w", err)
	}

	return &ConvertResult{Message: msg, Subject: subject}, nil
}

// execTemplate parses and executes a Go template string against the given data.
func (c *Converter) execTemplate(name, tmplStr string, data interface{}) (string, error) {
	tmpl, err := template.New(name).Funcs(c.funcs).Parse(tmplStr)
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
