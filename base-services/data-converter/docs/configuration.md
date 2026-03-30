# Configuration

The data-converter service is configured via a single YAML file.
The path to this file must be set in the `CONFIG_PATH` environment variable.

## Environment Variable Substitution

The configuration file supports environment variable expansion using `${VAR_NAME}` syntax.
Variables are resolved at startup before YAML parsing.
This allows secrets and environment-specific values to be injected at runtime (e.g. via Kubernetes Secrets).

```yaml
nats:
  token: "${NATS_TOKEN}"
```

## Configuration Structure

### Top-Level

| Field | Type | Required | Description |
|---|---|---|---|
| `service` | object | yes | General service settings |
| `nats` | object | yes | NATS connection settings for publishing |
| `adapters` | map | yes | Named adapter configurations (keyed by adapter name) |
| `converters` | list | yes | List of conversion pipelines |

### `service`

| Field | Type | Default | Description |
|---|---|---|---|
| `name` | string | — | Service name (used for logging) |
| `log_level` | string | `"info"` | Log level. Set to `"debug"` for verbose development logging |

### `nats`

| Field | Type | Description |
|---|---|---|
| `url` | string | NATS server URL, e.g. `nats://localhost:4222` |
| `token` | string | Authentication token for NATS |

## Adapters

Adapters define the ingress protocol configuration.
Each adapter is registered under a unique name in the `adapters` map.
The adapter name is referenced by converters in their `source.adapter` field.

### MQTT Adapter

Register an MQTT adapter by adding an entry under `adapters`:

```yaml
adapters:
  mqtt:
    broker: tcp://localhost:1883
    client_id: nexus-converter
    buffer_size: 1000
    auth:
      username: "${MQTT_USER}"
      password: "${MQTT_PASS}"
```

| Field | Type | Default | Description |
|---|---|---|---|
| `broker` | string | — | MQTT broker URL, e.g. `tcp://localhost:1883` |
| `client_id` | string | — | Client ID for the MQTT connection |
| `buffer_size` | int | `1000` | Internal message channel capacity |
| `auth.username` | string | — | MQTT username (optional — omit for anonymous access) |
| `auth.password` | string | — | MQTT password (optional) |

MQTT topics support standard MQTT wildcards:

- `+` matches a single level (e.g. `telemetry/+/sensors` matches `telemetry/deviceId001/sensors`)
- `#` matches multiple levels (e.g. `telemetry/#` matches `telemetry/deviceId001/sensors/temp`)

## Converters

Each converter defines a complete pipeline: where to read from, how to transform the data, and where to publish it.

```yaml
converters:
  - name: telemetry-sensors
    source:
      adapter: mqtt
      topic: "telemetry/+/sensors/#"
      qos: 1
    mapping:
      device_id: "{{ seg .topic 1 }}"
      sensors:
        - sensor: "{{ jsonpath .payload \"name\" }}"
          value: "{{ jsonpath .payload \"value\" }}"
          data_type: DYNAMIC
    target:
      subject_pattern: "telemetry.{{ .device_id }}.{{ .sensor }}"
```

### `source`

| Field | Type | Description |
|---|---|---|
| `adapter` | string | Name of the adapter (must match a key in `adapters`) |
| `topic` | string | Topic to subscribe to (supports adapter-specific wildcards) |
| `qos` | int | Quality of Service level (MQTT: 0, 1, or 2) |

### `mapping`

Defines how incoming messages are transformed into `TelemetryMessage` protobuf format.
All string values are evaluated as [Go templates](https://pkg.go.dev/text/template).

| Field | Type | Description |
|---|---|---|
| `device_id` | string (template) | Expression to extract the device identifier |
| `sensors` | list | List of sensor mappings |
| `sensors[].sensor` | string (template) | Expression to extract the sensor name |
| `sensors[].value` | string (template) | Expression to extract the sensor value |
| `sensors[].data_type` | string | `DYNAMIC` (default) or `STATIC` |

#### Template Context

Templates in `mapping` have access to the following variables:

| Variable | Type | Description |
|---|---|---|
| `.topic` | string | The full topic the message was received on |
| `.topic_segments` | []string | The topic split by `/` |
| `.payload` | map | The JSON payload parsed into a map |

#### Template Functions

| Function | Signature | Description |
|---|---|---|
| `seg` | `seg <topic> <index>` | Extracts a segment from a `/`-separated topic by index (0-based) |
| `jsonpath` | `jsonpath <map> <path>` | Extracts a value from a map by dot-separated path |

**Examples:**

Given topic `telemetry/deviceId001/sensors/temp` and payload `{"name": "temperature", "value": "22.5"}`:

- `{{ seg .topic 1 }}` resolves to `deviceId001`
- `{{ seg .topic 3 }}` resolves to `temp`
- `{{ jsonpath .payload "name" }}` resolves to `temperature`
- `{{ jsonpath .payload "nested.field" }}` traverses nested objects

### `target`

| Field | Type | Description |
|---|---|---|
| `subject_pattern` | string (template) | Go template for the NATS subject to publish to |

The subject pattern template has access to:

| Variable | Type | Description |
|---|---|---|
| `.device_id` | string | The resolved device ID from the mapping |
| `.sensor` | string | The name of the last resolved sensor |
| `.topic` | string | The original source topic |

## Full Example

```yaml
service:
  name: data-converter
  log_level: debug

nats:
  url: nats://${NATS_HOST}:4222
  token: "${NATS_TOKEN}"

adapters:
  mqtt:
    broker: tcp://${MQTT_HOST}:1883
    client_id: nexus-converter
    buffer_size: 1000
    auth:
      username: "${MQTT_USER}"
      password: "${MQTT_PASS}"

converters:
  - name: telemetry-sensors
    source:
      adapter: mqtt
      topic: "telemetry/+/sensors/#"
      qos: 1
    mapping:
      device_id: "{{ seg .topic 1 }}"
      sensors:
        - sensor: "{{ jsonpath .payload \"name\" }}"
          value: "{{ jsonpath .payload \"value\" }}"
          data_type: DYNAMIC
    target:
      subject_pattern: "telemetry.{{ .device_id }}.{{ .sensor }}"
```
