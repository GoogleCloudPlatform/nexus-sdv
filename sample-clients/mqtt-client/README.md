# MQTT Sample Client

Simple MQTT client that publishes simulated temperature telemetry data to an MQTT broker.
Designed to test the [Data Converter Service](../../base-services/data-converter/).

## Prerequisites

- Go 1.24+
- MQTT broker running on `localhost:1883` (see [Data Converter docker-compose](../../base-services/data-converter/docker-compose.yml))

## Usage

```bash
go run main.go
```

### CLI flags

| Flag        | Default | Description                                 |
|-------------|---------|---------------------------------------------|
| `-interval` | `5s`    | Publish interval (e.g. `2s`, `500ms`, `1m`) |

### Example

```bash
go run main.go -interval 2s
```

## What it does

- Connects to the MQTT broker at `tcp://localhost:1883`
- Publishes a JSON message every `-interval` to the topic `telemetry/mqttDevice001/sensors/temp`
- Payload format: `{"name": "temperature", "value": "<random 15.0–45.0>"}`
- Gracefully disconnects on Ctrl+C

## Verifying messages

Subscribe to the MQTT broker to see published messages:

```bash
docker compose -f ../../base-services/data-converter/docker-compose.yml exec mosquitto mosquitto_sub -t "telemetry/#" -v
```
