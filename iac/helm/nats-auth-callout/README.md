# NATS auth callout service

This Helm chart provides all necessary resources for deploying a NATS auth callout service. The `values.yaml` file outlines the general configuration options.

The auth callout service handles the authentication, when the clients do not use the JWTs from NATS itself. It validates the external authentication token and maps
it to a NATS specific token with subject permissions.

## Mandatory secrets
- **jwt.accSigningKey**
  - the private nkey for signing JWTs for a specific account
- **nats.url**
  - the url to the NATS server with the authentication embedded
    - example format: `nats://username:pass@localhost:4222`

## Mandatory variables
- **keycloak.jwkB64**
  - the base64 encoded JWK JSON from the keycloak
  - the JWK provides the public key to validate the tokens from the external token provider (keycloak)
- **image.repository**
  - the URI of the docker image repository
