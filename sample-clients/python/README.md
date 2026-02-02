# Python Client
This directory contains a simple python client which goes through the entire registration process and sends test data to nats.

## Setup
First, generate the protobuf files:
```bash
make proto
```

## Generate Factory Certificates
If using GCP CA, generate factory certificates from the parent directory:
```bash
cd ..
./generate-factory-cert-gcp.sh 12345678901234567
cd python
```

## Running
Run the client with the registration load balancer IP:
```bash
uv run main.py <registration-loadbalancer-ip>
```

Example:
```bash
uv run main.py 34.123.45.67
```

The IP address is readable from the "registration" workload in the GKE cluster via the Google Cloud Console.