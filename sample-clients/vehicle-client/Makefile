.PHONY: all build clean test deps proto run help

BINARY_NAME=vehicle-client
GO=go
GOFLAGS=-v
PROTO_SOURCE=../../proto/telemetry.proto
PROTO_OUT_DIR=telemetry

# Default target - builds everything needed for a working binary
all: run

help:
	@echo "Available targets:"
	@echo "  all      - Build everything (default target)"
	@echo "  build    - Build the vehicle client binary"
	@echo "  clean    - Remove build artifacts"
	@echo "  test     - Run tests"
	@echo "  deps     - Download and verify dependencies"
	@echo "  proto    - Generate protobuf code"
	@echo "  run      - Run the application"
	@echo "  help     - Show this help message"

deps:
	$(GO) mod download
	$(GO) mod verify

proto: deps
	@if [ ! -f "$(PROTO_SOURCE)" ]; then \
		echo "Error: Proto file not found at $(PROTO_SOURCE)"; \
		exit 1; \
	fi
	@echo "Generating protobuf code from $(PROTO_SOURCE)..."
	@mkdir -p $(PROTO_OUT_DIR)
	protoc --proto_path=../../proto --go_out=$(PROTO_OUT_DIR) --go_opt=paths=source_relative telemetry.proto

build: proto
	$(GO) build $(GOFLAGS) -o $(BINARY_NAME) .

downloadcerts: build
	mkdir -p certificates
	gcloud secrets versions access latest --secret="REGISTRATION_SERVER_TLS_CERT" > certificates/REGISTRATION_SERVER_TLS_CERT.pem
	gcloud secrets versions access latest --secret="KEYCLOAK_TLS_CRT" > certificates/KEYCLOAK_TLS_CRT.pem

run: downloadcerts
	./run-vehicle-client.sh

test:
	$(GO) test $(GOFLAGS) ./...

clean:
	$(GO) clean
	rm *.pem
	rm *.csr
	rm certificates/*.pem
