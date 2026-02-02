# Keycloak Identity Provider

This Helm chart provides all necessary resources for deploying a Keycloak identity provider. The `values.yaml` file outlines the general configuration options.

The Keycloak uses the Cloud SQL service in GCP as its main database. The connection is handled by a sidecar container inside the pod, that authorizes with a corresponding workload identity in combinataion with a service account.

## Mandatory secrets
- **keycloak.tls.cert**
  - base64 encoded server certificate
  - ``cat ./authserver.crt | base64 | tr -d '\n'``
- **keycloak.tls.key**
  - base64 encoded server private key
  - ``cat ./authserver.key | base64 | tr -d '\n'``
- **keycloak.truststore.ca**
  - plaintext of trusted CA
  - must be one line string with "\n" as line breaks
- **keycloak.adminPassword**
  - admin password for the Keycloak admin UI

### DB password secret
You need to deploy a kubernetes secret for the database password. In the future this will come from the SecretProviderClass.
The password is located in 1Password at **Keycloak DB user**.

```bash
kubectl create secret generic keycloak-db-secret --from-literal=password='PASTE_THE_PASSWORD' -n base-services
```

In addition you need to create the db user inside the GCP console. The username is `keycloak`. Use the same password from 1Password as in the previous step.

## Mandatory variables
- **keycloak.hostname**
  - need to match the external IP of the loadbalancer service in the k8s cluster
- **database.cloudsqlproxy.instanceConnectionName**
  - the connection name of the cloud SQL instance in GCP, where the cloud sql proxy connects to
- **database.gcpServiceAccount**
  - the service account, that is used for the workload identity in order to access the cloud SQL instance
