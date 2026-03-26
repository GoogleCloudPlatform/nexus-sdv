.PHONY: proto clean build run test deps

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
