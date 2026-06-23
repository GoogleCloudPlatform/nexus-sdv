.PHONY: all proto downloadcerts run clean

include ../../iac/bootstrapping/.bootstrap_env

# Exporting allows sub-processes (like shell scripts) to see them too
export

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
	gcloud secrets versions access latest --project="${GCP_PROJECT_ID}" --secret="REGISTRATION_SERVER_TLS_CERT" > certificates/REGISTRATION_SERVER_TLS_CERT.pem
	gcloud secrets versions access latest --project="${GCP_PROJECT_ID}" --secret="KEYCLOAK_TLS_CRT" > certificates/KEYCLOAK_TLS_CRT.pem
ifeq ($(PKI_STRATEGY), "local")
	mkdir -p ../../base-services/registration/pki/factory-ca
	mkdir -p ../../base-services/registration/pki/server-ca
	gcloud secrets versions access latest --project="${GCP_PROJECT_ID}" --secret="REGISTRATION_FACTORY_CA_CERT" > ../../base-services/registration/pki/factory-ca/ca.crt.pem
	gcloud secrets versions access latest --project="${GCP_PROJECT_ID}" --secret="REGISTRATION_FACTORY_CA_KEY" > ../../base-services/registration/pki/factory-ca/ca.key.pem
	gcloud secrets versions access latest --project="${GCP_PROJECT_ID}" --secret="SERVER_CA_CERT" > ../../base-services/registration/pki/server-ca/ca.crt.pem
endif

run: downloadcerts
	./run-python-client.sh

all: run

# Clean generated files
clean:
	rm -rf proto
	rm -rf certificates
