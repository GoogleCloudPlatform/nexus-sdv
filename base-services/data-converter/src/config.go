package main

import (
	"fmt"
	"os"

	"data-converter/src/transform"

	"gopkg.in/yaml.v3"
)

// Config is the top-level configuration for the data-converter service.
type Config struct {
	Service    ServiceConfig            `yaml:"service"`
	NATS       NATSConfig               `yaml:"nats"`
	Adapters   map[string]yaml.Node     `yaml:"adapters"`
	Converters []ConverterConfig        `yaml:"converters"`
}

// ServiceConfig holds general service settings.
type ServiceConfig struct {
	Name     string `yaml:"name"`
	LogLevel string `yaml:"log_level"`
}

// NATSConfig holds NATS connection settings.
type NATSConfig struct {
	URL   string `yaml:"url"`
	Token string `yaml:"token"`
}

// ConverterConfig defines a single conversion pipeline.
type ConverterConfig struct {
	Name    string                  `yaml:"name"`
	Source  SourceConfig            `yaml:"source"`
	Mapping transform.MappingConfig `yaml:"mapping"`
	Target  transform.TargetConfig  `yaml:"target"`
}

// SourceConfig defines where a converter reads from.
type SourceConfig struct {
	Adapter string `yaml:"adapter"`
	Topic   string `yaml:"topic"`
	QoS     byte   `yaml:"qos"`
}

// LoadConfig reads the YAML config file, expands environment variables, and parses it.
func LoadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config %s: %w", path, err)
	}

	// Expand environment variables (e.g. ${MQTT_PASS})
	expanded := os.ExpandEnv(string(data))

	var cfg Config
	if err := yaml.Unmarshal([]byte(expanded), &cfg); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}

	return &cfg, nil
}
