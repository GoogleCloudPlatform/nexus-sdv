# Data API Test Client

This is a small testing client written in Go to test a GKE cluster deployed Data-API instance.

The Data API is cluster-internal, so running this client from your own machine
needs a port forward first; in the cluster the address is
`data-api.base-services.svc.cluster.local:8080`.

```
kubectl port-forward -n base-services svc/data-api 8080:8080
go run client/main.go --addr "localhost:8080" --tls=false --vin "12345678901234567"
```

As a prerequisite it is necessary to first execute the Python Test client intended for the Registration process as it sends example data into BigTable.

The Data API Test Client queries the latest data entry from BigTable.
