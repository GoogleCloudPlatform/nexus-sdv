.PHONY: proto clean test query-bigtable deps

PKG_LIST := $(shell go list -e ./...)

# Generate protobuf files
proto:
	mkdir -p api/gen/dataapi/v1
	cp ../../proto/data-api.proto api/
	protoc --go_out=. --go_opt=module=data-api \
		--go-grpc_out=. --go-grpc_opt=module=data-api \
		api/data-api.proto

# Clean generated files
clean:
	rm -rf api

# Run tests
test:
	@echo "--- Running All Tests (Verbose, No Cache) ---"
	go test -v -count=1 data-api/tests/integration

# Check the current content of the emulated bigtable for debugging
query-bigtable:
	BIGTABLE_EMULATOR_HOST="localhost:8086" cbt -project test-project -instance test-instance read telemetry

# Install dependencies
deps:
	go mod tidy
	go mod download
