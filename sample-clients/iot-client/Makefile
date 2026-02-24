PROTO_SOURCE = ../../proto/telemetry.proto

.PHONY: all proto config build upload uploadfs monitor clean help

help:
	@echo "Available targets:"
	@echo "  config     - Create include/config.h from config.example.h (won't overwrite)"
	@echo "  proto      - Copy and generate nanopb code from telemetry.proto"
	@echo "  build      - Build the firmware"
	@echo "  upload     - Build and upload firmware to ESP32"
	@echo "  uploadfs   - Upload LittleFS filesystem (certificates)"
	@echo "  monitor    - Open serial monitor"
	@echo "  clean      - Clean build artifacts"
	@echo "  all        - Build and upload firmware and filesystem"

config:
	@if [ -f include/config.h ]; then \
		echo "include/config.h already exists — not overwriting."; \
	else \
		cp include/config.example.h include/config.h; \
		echo "Created include/config.h from config.example.h — edit it with your settings."; \
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

all: upload uploadfs
