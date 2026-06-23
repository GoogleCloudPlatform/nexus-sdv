.PHONY: all build clean test deps proto run help

include ../../iac/bootstrapping/.bootstrap_env

# Exporting allows sub-processes (like shell scripts) to see them too
export

BINARY_NAME=vehicle-client
GO=go
GOFLAGS=-v
PROTO_SOURCES=../../proto/telemetry.proto ../../proto/metrics_report.proto ../../proto/vehicle_telemetry.proto
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
	@echo "Generating protobuf code from proto files..."
	@mkdir -p $(PROTO_OUT_DIR)
	protoc --proto_path=../../proto --proto_path=/usr/include --go_out=$(PROTO_OUT_DIR) --go_opt=paths=source_relative telemetry.proto metrics_report.proto vehicle_telemetry.proto
	@echo ""

certs: proto
	mkdir -p certificates
ifeq ($(PKI_STRATEGY), "local")
	mkdir -p ../../base-services/registration/pki/factory-ca
	mkdir -p ../../base-services/registration/pki/server-ca
	gcloud secrets versions access latest --project="${GCP_PROJECT_ID}" --secret="REGISTRATION_FACTORY_CA_CERT" > ../../base-services/registration/pki/factory-ca/ca.crt.pem
	gcloud secrets versions access latest --project="${GCP_PROJECT_ID}" --secret="REGISTRATION_FACTORY_CA_KEY" > ../../base-services/registration/pki/factory-ca/ca.key.pem
	gcloud secrets versions access latest --project="${GCP_PROJECT_ID}" --secret="SERVER_CA_CERT" > ../../base-services/registration/pki/server-ca/ca.crt.pem
endif

build: certs
	@echo "Building vehicle client..."
	$(GO) build $(GOFLAGS) -o $(BINARY_NAME) .
	@echo ""

run: build
	@echo "Build complete. Running vehicle client..."
	./run-vehicle-client.sh

test:
	$(GO) test $(GOFLAGS) ./...

clean:
	$(GO) clean
	rm certificates/*.pem
	rm certificates/*.csr
