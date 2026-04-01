.PHONY: proto clean build run test deps config monitor

# Generate protobuf files
proto:
	mkdir -p api/gen/telemetry
	cp ../../proto/telemetry.proto api/
	protoc --go_out=api/gen/telemetry --go_opt=paths=source_relative \
		-I api \
		api/telemetry.proto

# Clean generated files
clean:
	rm -rf api

# Build the binary
build:
	CGO_ENABLED=0 go build -o bin/data-converter ./src

# Run the service
run:
	go run ./src/

# Run tests
test:
	@echo "--- Running Unit Tests (Verbose, No Cache) ---"
	go test -v -count=1 ./tests/unit/...

# Install dependencies
deps:
	go mod tidy
	go mod download


CONFIG_FILE_SOURCE := config/config.example.yaml
CONFIG_FILE := config/config.yaml
config:
ifneq ("$(wildcard $(CONFIG_FILE))","")
	@echo "Config file $(CONFIG_FILE) already exists."
else
	@echo "Creating config $(CONFIG_FILE)"
	@cp $(CONFIG_FILE_SOURCE) $(CONFIG_FILE)
endif

MQTT_TOPIC := "telemetry/\#"
monitor:
	@echo "Subscribing to MQTT topic: $(MQTT_TOPIC)"
	docker compose exec mosquitto mosquitto_sub -t $(MQTT_TOPIC) -v
