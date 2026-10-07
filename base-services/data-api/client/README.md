# Data API Test Client

This is a small testing client written in Go to test a GKE cluster deployed Data-API instance.

The Data API is cluster-internal, speaks plaintext gRPC and requires a Keycloak access token carrying the `factory-operator` realm role. From a workstation you need a port forward and a token.

```
# the way in - needs the cluster credentials; keep it running
gcloud container clusters get-credentials <ENV>-gke --region <REGION> --project <PROJECT_ID> --dns-endpoint
kubectl port-forward -n base-services svc/data-api 9090:8080

# a token, from the Factory Helper's factory-operator client
TOKEN=$(curl -s \
  -d grant_type=client_credentials -d client_id=factory-operator \
  -d client_secret="$(gcloud secrets versions access latest \
    --secret=FACTORY_OPERATOR_CLIENT_SECRET --project=<PROJECT_ID>)" \
  https://keycloak-ui.<BASE_DOMAIN>/realms/sdv-telemetry/protocol/openid-connect/token \
  | jq -r .access_token)

go run client/main.go --addr localhost:9090 \
  --token "$TOKEN" --vin "12345678901234567"
```

`--datatypes` selects what to ask for. The default is what the devices-client and the
iot-client write (`static:index`, `static:test_key`, `dynamic:time_passed`); a
vehicle from the Go vehicle-client writes `dynamic:VELOCITY` and
`dynamic:ENGINE_RPM`, and one from the python-sdk-client writes VSS paths such as
`dynamic:Vehicle.Speed`. Asking for the wrong family returns nothing, which is
not the same as the platform being broken.

From inside the cluster the address is `data-api.base-services.svc.cluster.local:8080`. The port forward uses local port 9090 so that it does not collide with the sampler's forward on 8080.

As a prerequisite it is necessary to first execute the Python Test client intended for the Registration process as it sends example data into BigTable.

The Data API Test Client queries the latest data entry from BigTable.
