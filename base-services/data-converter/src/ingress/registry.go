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

// TopicMatcher checks if a topic matches a pattern using protocol-specific rules
// (e.g. MQTT wildcards +/#, or exact string matching for other protocols).
type TopicMatcher func(pattern, topic string) bool

// AdapterFactory creates an Adapter from raw YAML config and a list of converter sources.
// Each adapter is responsible for parsing its own config structure from the yaml.Node.
type AdapterFactory func(rawCfg yaml.Node, sources []ConverterSource, logger *zap.Logger) (Adapter, error)

type adapterRegistration struct {
	factory AdapterFactory
	matcher TopicMatcher
}

var registry = map[string]adapterRegistration{}

// Register adds an adapter factory and its topic matcher to the registry.
func Register(name string, factory AdapterFactory, matcher TopicMatcher) {
	registry[name] = adapterRegistration{factory: factory, matcher: matcher}
}

// NewAdapter creates an adapter by looking up its factory in the registry.
func NewAdapter(name string, rawCfg yaml.Node, sources []ConverterSource, logger *zap.Logger) (Adapter, error) {
	reg, ok := registry[name]
	if !ok {
		return nil, &UnsupportedAdapterError{Name: name}
	}
	return reg.factory(rawCfg, sources, logger)
}

// GetTopicMatcher returns the topic matcher for a registered adapter.
func GetTopicMatcher(name string) TopicMatcher {
	reg, ok := registry[name]
	if !ok {
		return func(pattern, topic string) bool { return pattern == topic }
	}
	return reg.matcher
}

// UnsupportedAdapterError is returned when no factory is registered for the given adapter name.
type UnsupportedAdapterError struct {
	Name string
}

func (e *UnsupportedAdapterError) Error() string {
	return "unsupported adapter: " + e.Name
}
