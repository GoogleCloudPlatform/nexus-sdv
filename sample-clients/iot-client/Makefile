PROTO_SOURCE = ../../proto/telemetry.proto

.PHONY: all proto config build upload uploadfs monitor clean nats help

help:
	@echo "Available targets:"
	@echo "  config     - Create config.h and urls.json from examples (won't overwrite)"
	@echo "  proto      - Copy and generate nanopb code from telemetry.proto"
	@echo "  build      - Build the firmware"
	@echo "  upload     - Build and upload firmware to ESP32"
	@echo "  uploadfs   - Upload LittleFS filesystem (certificates)"
	@echo "  monitor    - Open serial monitor"
	@echo "  clean      - Clean build artifacts"
	@echo "  nats       - Start NATS server + protobuf subscriber (docker compose)"
	@echo "  all        - Build and upload firmware and filesystem"

config:
	@if [ -f include/config.h ]; then \
		echo "include/config.h already exists — not overwriting."; \
	else \
		cp include/config.example.h include/config.h; \
		echo "Created include/config.h from config.example.h — edit it with your settings."; \
	fi
	@if [ -f data/urls.json ]; then \
		echo "data/urls.json already exists — not overwriting."; \
	else \
		printf '{\n  "keycloak_url": "https://keycloak.example.com:8443",\n  "nats_url": "nats://nats.example.com:4222"\n}\n' > data/urls.json; \
		echo "Created data/urls.json with example URLs — edit it with your URLs."; \
	fi

proto:
	@echo "Copying proto file..."
	@mkdir -p proto
	@cp $(PROTO_SOURCE) proto/telemetry.proto
	@echo "Generating nanopb code..."
	protoc --nanopb_out=src/ google/protobuf/timestamp.proto
	protoc --nanopb_opt=-fproto/telemetry.options --nanopb_out=src/ -I proto/ proto/telemetry.proto
	@echo "Proto generation complete."

build:
	pio run

upload: build
	pio run -t upload

uploadfs:
	pio run -t uploadfs

monitor:
	pio device monitor

clean:
	pio run -t clean
	rm -f src/telemetry.pb.c src/telemetry.pb.h
	rm -rf src/google

nats:
	docker compose up --build

all: upload uploadfs
