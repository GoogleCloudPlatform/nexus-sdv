#ifndef KEYCLOAK_AUTH_H
#define KEYCLOAK_AUTH_H

#include <stdbool.h>

struct AuthResult {
    char *access_token;   // JWT (heap-allocated, caller frees)
    int expires_in;       // Token lifetime in seconds
    bool success;
};

// Get a JWT access token from Keycloak via mTLS client_credentials grant.
AuthResult keycloak_get_token(
    const char *keycloak_url,
    const char *op_cert_pem,
    const char *op_key_pem,
    const char *ca_cert_pem
);

void auth_result_free(AuthResult *result);

#endif
