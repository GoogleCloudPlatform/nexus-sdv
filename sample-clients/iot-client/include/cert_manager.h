#ifndef CERT_MANAGER_H
#define CERT_MANAGER_H

#include <stdbool.h>

// Mount LittleFS filesystem.
bool cert_manager_init();

// Load a PEM file from LittleFS into a heap-allocated null-terminated buffer.
// Caller must free() the returned pointer.
char *cert_load_pem(const char *path);

#endif
