package ingress

import (
	"go.uber.org/zap"
	"gopkg.in/yaml.v3"
)

// ConverterSource holds the source definition from a converter config.
// Each adapter interprets the fields it needs (e.g. MQTT uses Topic + QoS, HTTP might use Path).
type ConverterSource struct {
	Topic string
	QoS   byte
}

// AdapterFactory creates an Adapter from raw YAML config and a list of converter sources.
// Each adapter is responsible for parsing its own config structure from the yaml.Node.
type AdapterFactory func(rawCfg yaml.Node, sources []ConverterSource, logger *zap.Logger) (Adapter, error)

var registry = map[string]AdapterFactory{}

// Register adds an adapter factory to the registry.
func Register(name string, factory AdapterFactory) {
	registry[name] = factory
}

// NewAdapter creates an adapter by looking up its factory in the registry.
func NewAdapter(name string, rawCfg yaml.Node, sources []ConverterSource, logger *zap.Logger) (Adapter, error) {
	factory, ok := registry[name]
	if !ok {
		return nil, &UnsupportedAdapterError{Name: name}
	}
	return factory(rawCfg, sources, logger)
}

// UnsupportedAdapterError is returned when no factory is registered for the given adapter name.
type UnsupportedAdapterError struct {
	Name string
}

func (e *UnsupportedAdapterError) Error() string {
	return "unsupported adapter: " + e.Name
}
