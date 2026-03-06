# Generate protobuf files (no copy needed)
proto:
	mkdir -p proto/
	touch proto/__init__.py
	uv run python -m grpc_tools.protoc \
		--proto_path=../../proto \
		--python_out=proto \
		--pyi_out=proto \
		telemetry.proto

downloadcerts: proto
	mkdir -p certificates
	gcloud secrets versions access latest --project=sdv-demo-474513 --secret="REGISTRATION_SERVER_TLS_CERT" > certificates/REGISTRATION_SERVER_TLS_CERT.pem
	gcloud secrets versions access latest --project=sdv-demo-474513 --secret="KEYCLOAK_TLS_CRT" > certificates/KEYCLOAK_TLS_CRT.pem

run: downloadcerts
	./run-devices-client.sh

all: run

# Clean generated files
clean:
	rm -rf proto
	rm -f *.pem *.csr
	rm -rf certificates/
