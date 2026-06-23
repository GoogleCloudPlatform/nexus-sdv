.PHONY: all build clean test deps proto run help

include ../../iac/bootstrapping/.bootstrap_env

# Exporting allows sub-processes (like shell scripts) to see them too
export

BINARY_NAME=telemetry-subscriber
GO=go
GOFLAGS=-v
PROTO_SOURCES=../../proto/telemetry.proto ../../proto/metrics_report.proto ../../proto/vehicle_telemetry.proto
PROTO_OUT_DIR=telemetry
AAOS_PROTO_OUT_DIR=aaos_telemetry

# Default target - builds everything needed for a working binary
all: run

help:
	@echo "Available targets:"
	@echo "  all      - Build everything (default target)"
	@echo "  build    - Build the telemetry subscriber binary"
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
	@echo "Generating protobuf code from proto files..."
	@mkdir -p $(PROTO_OUT_DIR)
	protoc --proto_path=../../proto --go_out=$(PROTO_OUT_DIR) --go_opt=paths=source_relative telemetry.proto metrics_report.proto vehicle_telemetry.proto
	@mkdir -p $(AAOS_PROTO_OUT_DIR)
	protoc --proto_path=../../proto --go_out=$(AAOS_PROTO_OUT_DIR) --go_opt=paths=source_relative aaos_vehicle_telemetry.proto display_safety.proto
	@echo ""

build: deps
	$(GO) build $(GOFLAGS) -o $(BINARY_NAME) .

downloadcerts: build
	mkdir -p certificates
	gcloud secrets versions access latest --project="${GCP_PROJECT_ID}" --secret="REGISTRATION_SERVER_TLS_CERT" > certificates/REGISTRATION_SERVER_TLS_CERT.pem.tmp \
		&& mv certificates/REGISTRATION_SERVER_TLS_CERT.pem.tmp certificates/REGISTRATION_SERVER_TLS_CERT.pem \
		|| (rm -f certificates/REGISTRATION_SERVER_TLS_CERT.pem.tmp; echo "ERROR: failed to download REGISTRATION_SERVER_TLS_CERT"; exit 1)
	gcloud secrets versions access latest --project="${GCP_PROJECT_ID}" --secret="KEYCLOAK_TLS_CRT" > certificates/KEYCLOAK_TLS_CRT.pem.tmp \
		&& mv certificates/KEYCLOAK_TLS_CRT.pem.tmp certificates/KEYCLOAK_TLS_CRT.pem \
		|| (rm -f certificates/KEYCLOAK_TLS_CRT.pem.tmp; echo "ERROR: failed to download KEYCLOAK_TLS_CRT"; exit 1)

run: downloadcerts
	./run-telemetry-subscriber.sh --record-dir ./recordings

test:
	$(GO) test $(GOFLAGS) ./...

clean:
	$(GO) clean
	rm -f $(BINARY_NAME)
