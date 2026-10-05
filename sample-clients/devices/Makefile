PROTO_SRC := ../../proto/telemetry.proto
PROTO_OUT := proto/telemetry_pb2.py proto/telemetry_pb2.pyi

# Generate protobuf files (rebuilds when source changes or outputs are missing)
$(PROTO_OUT): $(PROTO_SRC)
	mkdir -p proto/
	touch proto/__init__.py
	uv run python -m grpc_tools.protoc \
		--proto_path=../../proto \
		--python_out=proto \
		--pyi_out=proto \
		telemetry.proto

proto: $(PROTO_OUT)

downloadcerts:
	@[ -n "$(GCP_PROJECT_ID)" ] || { echo "Set GCP_PROJECT_ID, e.g. make downloadcerts GCP_PROJECT_ID=<project>"; exit 1; }
	mkdir -p certificates
	gcloud secrets versions access latest --project=$(GCP_PROJECT_ID) --secret="REGISTRATION_SERVER_TLS_CERT" > certificates/REGISTRATION_SERVER_TLS_CERT.pem
	gcloud secrets versions access latest --project=$(GCP_PROJECT_ID) --secret="KEYCLOAK_TLS_CRT" > certificates/KEYCLOAK_TLS_CRT.pem

run: proto
	uv run main.py $(ARGS)

all: run

# Clean generated files
clean:
	rm -rf proto
	rm -f *.pem *.csr
	rm -rf certificates/
