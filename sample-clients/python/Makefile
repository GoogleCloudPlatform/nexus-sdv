# Generate protobuf files (no copy needed)
proto:
	mkdir -p proto/
	touch proto/__init__.py
	protoc \
    --proto_path=../../proto \
    --python_out=proto \
    --pyi_out=proto \
    telemetry.proto

downloadcerts: proto
	mkdir -p certificates
	gcloud secrets versions access latest --secret="REGISTRATION_SERVER_TLS_CERT" > certificates/REGISTRATION_SERVER_TLS_CERT.pem
	gcloud secrets versions access latest --secret="KEYCLOAK_TLS_CRT" > certificates/KEYCLOAK_TLS_CRT.pem

run: downloadcerts
	./run-python-client.sh

all: run

# Clean generated files
clean:
	rm -rf proto
	rm *.pem
	rm *.csr
	rm certificates/*.pem
