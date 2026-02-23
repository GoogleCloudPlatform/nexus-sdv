#ifndef REGISTRATION_CLIENT_H
#define REGISTRATION_CLIENT_H

#include <stdbool.h>

struct RegistrationResult {
    char *certificate;    // Operational certificate PEM (heap-allocated, caller frees)
    char *keycloak_url;   // Keycloak server URL (heap-allocated, caller frees)
    char *nats_url;       // NATS server URL (heap-allocated, caller frees)
    bool success;
};

// Register with the Nexus SDV registration server.
// Sends CSR via mTLS (factory cert) and receives operational certificate + service URLs.
RegistrationResult registration_register(
    const char *registration_url,
    const char *factory_cert_pem,
    const char *factory_key_pem,
    const char *ca_cert_pem,
    const char *csr_pem
);

void registration_result_free(RegistrationResult *result);

#endif
