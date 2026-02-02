# NATS cluster

This Helm chart provides all necessary resources for deploying a NATS messaging cluster. The `values.yaml` file outlines the general configuration options.

## Mandatory variables
- **config.merge.authorization.users[0].user**
  - username of the NATS basic auth

## Mandatory secrets
- **config.merge.authorization.users[0].password**
  - password of the NATS basic auth
- **config.merge.authorization.auth_callout.issuer**
  - the public key of the nkey issuing keypair
