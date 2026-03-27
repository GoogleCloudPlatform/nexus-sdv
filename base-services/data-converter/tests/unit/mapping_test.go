package unit

import (
	"testing"

	"data-converter/src/transform"
)

func TestSeg_ValidIndex(t *testing.T) {
	tests := []struct {
		topic string
		index int
		want  string
	}{
		{"factory/line1/sensors/temp", 0, "factory"},
		{"factory/line1/sensors/temp", 1, "line1"},
		{"factory/line1/sensors/temp", 3, "temp"},
		{"single", 0, "single"},
	}

	funcs := transform.TemplateFuncs()
	segFn := funcs["seg"].(func(string, int) (string, error))

	for _, tt := range tests {
		got, err := segFn(tt.topic, tt.index)
		if err != nil {
			t.Errorf("seg(%q, %d) error: %v", tt.topic, tt.index, err)
			continue
		}
		if got != tt.want {
			t.Errorf("seg(%q, %d) = %q, want %q", tt.topic, tt.index, got, tt.want)
		}
	}
}

func TestSeg_InvalidIndex(t *testing.T) {
	funcs := transform.TemplateFuncs()
	segFn := funcs["seg"].(func(string, int) (string, error))

	_, err := segFn("a/b", 5)
	if err == nil {
		t.Error("expected error for out-of-range index")
	}

	_, err = segFn("a/b", -1)
	if err == nil {
		t.Error("expected error for negative index")
	}
}

func TestJsonpath_FlatObject(t *testing.T) {
	funcs := transform.TemplateFuncs()
	jpFn := funcs["jsonpath"].(func(interface{}, string) (interface{}, error))

	data := map[string]interface{}{
		"name":  "temperature",
		"value": "42.3",
	}

	got, err := jpFn(data, "name")
	if err != nil {
		t.Fatalf("jsonpath error: %v", err)
	}
	if got != "temperature" {
		t.Errorf("jsonpath(data, 'name') = %v, want %q", got, "temperature")
	}
}

func TestJsonpath_NestedObject(t *testing.T) {
	funcs := transform.TemplateFuncs()
	jpFn := funcs["jsonpath"].(func(interface{}, string) (interface{}, error))

	data := map[string]interface{}{
		"sensor": map[string]interface{}{
			"type":    "humidity",
			"reading": "65.2",
		},
	}

	got, err := jpFn(data, "sensor.type")
	if err != nil {
		t.Fatalf("jsonpath error: %v", err)
	}
	if got != "humidity" {
		t.Errorf("jsonpath(data, 'sensor.type') = %v, want %q", got, "humidity")
	}
}

func TestJsonpath_MissingKey(t *testing.T) {
	funcs := transform.TemplateFuncs()
	jpFn := funcs["jsonpath"].(func(interface{}, string) (interface{}, error))

	data := map[string]interface{}{"name": "test"}

	_, err := jpFn(data, "missing")
	if err == nil {
		t.Error("expected error for missing key")
	}
}

func TestJsonpath_NonObjectTraversal(t *testing.T) {
	funcs := transform.TemplateFuncs()
	jpFn := funcs["jsonpath"].(func(interface{}, string) (interface{}, error))

	data := map[string]interface{}{"name": "test"}

	_, err := jpFn(data, "name.sub")
	if err == nil {
		t.Error("expected error when traversing non-object value")
	}
}

func TestJsonpath_NumericValue(t *testing.T) {
	funcs := transform.TemplateFuncs()
	jpFn := funcs["jsonpath"].(func(interface{}, string) (interface{}, error))

	data := map[string]interface{}{
		"value": 42.3,
	}

	got, err := jpFn(data, "value")
	if err != nil {
		t.Fatalf("jsonpath error: %v", err)
	}
	if got != 42.3 {
		t.Errorf("jsonpath(data, 'value') = %v, want 42.3", got)
	}
}
