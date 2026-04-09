# Data Converter — Deployment Guide

The data-converter is an **optional service** that bridges external IoT protocols (MQTT) into the Nexus platform by converting telemetry payloads to Protobuf and publishing them to NATS.

This service is deployed manually and is **not** part of the platform bootstrap or Helmfile pipeline.

## Prerequisites

- `kubectl` configured with access to the GKE cluster
- `helm` v3
- `docker` and `gcloud` CLI for building and pushing images
- Customer MQTT broker details: hostname, port, credentials
- NATS credentials from the existing cluster (see [Retrieve NATS Credentials](#retrieve-nats-credentials))

## 1. Build and Push Image

From the repository root:

```bash
export GCP_PROJECT_ID=<your-project-id>
export GCP_REGION=<your-region>
export REGISTRY=${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/artifact-registry

# Authenticate to Artifact Registry
gcloud auth configure-docker ${GCP_REGION}-docker.pkg.dev

# Build and push
docker build -t ${REGISTRY}/data-converter:latest base-services/data-converter/
docker push ${REGISTRY}/data-converter:latest
```

## 2. Retrieve NATS Credentials

The data-converter publishes to the in-cluster NATS server using basic auth.
Retrieve the existing credentials:

```bash
# Username
kubectl get secret nats-basic-auth -n base-services \
  -o jsonpath='{.data.username}' | base64 -d

# Password
kubectl get secret nats-basic-auth -n base-services \
  -o jsonpath='{.data.password}' | base64 -d
```

> **Note:** If the secret name differs in your cluster, check with:
> `kubectl get secrets -n base-services | grep nats`

## 3. Configure

Create a `values-override.yaml` with your deployment-specific values:

```yaml
image:
  repository: <GCP_REGION>-docker.pkg.dev/<GCP_PROJECT_ID>/artifact-registry/data-converter
  tag: latest

config:
  logLevel: info
  nats:
    url: "nats://nats:4222"
  mqtt:
    broker: "tcp://mqtt.customer.example.com:1883"
    clientId: "nexus-data-converter"
    bufferSize: 1000
  converters:
    - name: customer-telemetry
      source:
        adapter: mqtt
        topic: "telemetry/+/sensors/#"
        qos: 1
      mapping:
        device_id: '{{ seg .topic 1 }}'
        sensors:
          - sensor: '{{ jsonpath .payload "name" }}'
            value: '{{ jsonpath .payload "value" }}'
            data_type: DYNAMIC
      target:
        subject_pattern: 'telemetry.{{ .device_id }}.{{ .sensor }}'

secrets:
  natsUser: "<from step 2>"
  natsPassword: "<from step 2>"
  mqttUser: "<customer mqtt username>"
  mqttPassword: "<customer mqtt password>"
```

Adapt the `converters` section to match the customer's MQTT topic structure and payload format.
See the [Configuration Guide](../../../base-services/data-converter/docs/configuration.md) for details on mapping templates.

> **Important:** Do not commit `values-override.yaml` — it contains credentials.

### Demo/Test Mode (Built-in MQTT Broker)

For testing without an external MQTT broker, enable the built-in Mosquitto instance:

```yaml
mosquitto:
  enabled: true
```

When enabled, a Mosquitto broker is deployed alongside the data-converter and the MQTT broker URL is automatically set to the internal service. No `config.mqtt.broker` override is needed.

## 4. Deploy

```bash
helm upgrade --install data-converter iac/helm/data-converter/ \
  --namespace base-services \
  -f values-override.yaml
```

## 5. Verify

```bash
# Check pod status
kubectl get pods -n base-services -l app.kubernetes.io/name=data-converter

# Check logs for successful connections
kubectl logs -n base-services -l app.kubernetes.io/name=data-converter --tail=50
```

Expected log output:
- `connected to broker` — MQTT connection established
- `connected to NATS` — NATS connection established
- `subscribed` — listening on configured MQTT topics

To verify end-to-end, publish a test message to the customer's MQTT broker and check the NATS output in the data-converter logs.

## 6. Update

To update the configuration, edit `values-override.yaml` and re-run the deploy command.
The deployment automatically restarts when the ConfigMap or Secret changes.

To update the image:

```bash
docker build -t ${REGISTRY}/data-converter:latest base-services/data-converter/
docker push ${REGISTRY}/data-converter:latest
kubectl rollout restart deployment/data-converter -n base-services
```

## 7. Teardown

```bash
helm uninstall data-converter --namespace base-services
```

This removes the Deployment, ConfigMap, and Secret.
