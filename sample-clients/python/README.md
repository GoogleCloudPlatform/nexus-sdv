# Python Telemetry SDK
This directory contains a simple python telemetry sdk.

## Setup and Smoke Test
First, setup everything you need to connect with Nexus (certificates, auth, dependencies):
```bash
make all
```

You will see terminal output confirming the connection:
```bash
NATS connection established.
[NATS] Telemetry sent to telemetry.prod.bigtable....
...
```

Check BigTable for your telemetry data.

## Run Samples 

To re-run the previous simulation run:
```bash
uv run simple-sim
```

### VSS Examples

To run the vss examples, you will need a Kuksa broker:
```bash
docker run -it --rm -p 56789:55555 ghcr.io/eclipse/kuksa.val/databroker
```

This bridge combines simulation (producer) and cloud relay (consumer) in one process:
```bash
uv run vss-bridge-sim
```

For a modular setup, run the simulator (feeder) and the cloud-vapp (relay) separately:
```bash
# Terminal 1: Feed data to broker
uv run vss-sim
# Terminal 2: Relay data from broker to cloud
uv run vss-vapp
```

### VHAL Simulator

The VHAL simulator provides an HTTP interface to trigger specific sensor scenarios:
```bash
uv run vhal-sim
```

List available data sets:
```bash
curl http://localhost:8080/simulations
```

Start a simulation (runs in background with 1s delay per sample to ensure unique BigTable rows):
```bash
curl -X POST http://localhost:8080/start-simulation/normal-battery
```
or
```bash
curl -X POST http://localhost:8080/start-simulation/sick-battery
```

## Explore the Code

Telemetry examples are located in apps/...

For detailed documentation, architecture diagrams, and BigTable SQL queries, visit [docs.nexus-sdv.io](docs.nexus-sdv.io)

