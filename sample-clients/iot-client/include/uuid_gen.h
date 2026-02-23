#ifndef UUID_GEN_H
#define UUID_GEN_H

#include <stddef.h>

// Generate a UUID v4 string: "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
// buf must be at least 37 bytes.
void uuid_v4(char *buf, size_t buf_size);

#endif
