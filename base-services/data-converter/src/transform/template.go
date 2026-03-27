package transform

import (
	"fmt"
	"strings"
	"text/template"
)

// TemplateFuncs returns the custom function map for use in Go templates.
func TemplateFuncs() template.FuncMap {
	return template.FuncMap{
		"seg":      seg,
		"jsonpath": jsonpath,
	}
}

// seg extracts a segment from a topic string split by "/".
// Example: seg("factory/line1/sensors/temp", 1) → "line1"
func seg(topic string, index int) (string, error) {
	parts := strings.Split(topic, "/")
	if index < 0 || index >= len(parts) {
		return "", fmt.Errorf("seg: index %d out of range for topic %q (has %d segments)", index, topic, len(parts))
	}
	return parts[index], nil
}

// jsonpath extracts a value from a map by a dot-separated path.
// Example: jsonpath(payload, "name") → value of payload["name"]
// Example: jsonpath(payload, "nested.field") → payload["nested"]["field"]
func jsonpath(data interface{}, path string) (interface{}, error) {
	keys := strings.Split(path, ".")
	current := data

	for _, key := range keys {
		m, ok := current.(map[string]interface{})
		if !ok {
			return nil, fmt.Errorf("jsonpath: cannot traverse %q — value is not an object", key)
		}
		val, exists := m[key]
		if !exists {
			return nil, fmt.Errorf("jsonpath: key %q not found", key)
		}
		current = val
	}

	return current, nil
}
