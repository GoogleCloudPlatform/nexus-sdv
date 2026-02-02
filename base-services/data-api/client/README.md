# Data API Test Client

This is a small testing client written in Go to test a GKE cluster deployed Data-API instance.

Executable via this shell command:
```
go run client/main.go --addr "{loadBalancer_IP}:8080" --tls=false --vin "12345678901234567"
```

As a prerequisite it is necessary to first execute the Python Test client intended for the Registration process as it sends example data into BigTable.
Another essential is including your current ip address (curlable via `curl ifconfig.me`) in the data-api helmfile `iac/helm/helmfile.d/data-api.yaml.gotmpl`, if the data-api is in production state.
Currently, the `loadBalancerSourceRanges` setting is empty which means free ingress for every client. If you want to prevent free ingress, you have to include a specific ip address within the `data-api.yaml.gotmpl`values section:

```
- service:
          loadBalancerSourceRanges:
            - "{YOUR_IP}/32"
```

The Data API Test Client queries the latest data entry from BigTable.