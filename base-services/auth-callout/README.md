# Auth Callout Service for NATS

This service enables NATS to leverage external identity providers by acting as an **Authorization Callout** endpoint. 

The service performs the following steps:
1. **Token Validation**: It validates incoming external **Keycloak JWTs** using a public key mechanism.
2. **Authorization Mapping**: Upon successful validation, it provides NATS with the necessary authorization metadata (such as subject permissions) based on the roles defined in the original Keycloak token.

This allows NATS to enforce fine-grained access control without needing to natively manage Keycloak integration.