package transform

// MappingConfig defines how to map raw messages to TelemetryMessage fields.
// These types mirror the YAML config structure for converters.
type MappingConfig struct {
	DeviceID string          `yaml:"device_id"`
	Sensors  []SensorMapping `yaml:"sensors"`
}

// SensorMapping defines how to extract a single sensor reading from the payload.
type SensorMapping struct {
	Sensor   string `yaml:"sensor"`
	Value    string `yaml:"value"`
	DataType string `yaml:"data_type"`
}

// TargetConfig defines the NATS subject pattern for publishing.
type TargetConfig struct {
	SubjectPattern string `yaml:"subject_pattern"`
}

// ConverterDef holds the resolved mapping and target for a single converter pipeline.
type ConverterDef struct {
	Name    string
	Mapping MappingConfig
	Target  TargetConfig
}
