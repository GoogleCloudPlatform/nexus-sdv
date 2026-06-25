#ifndef FS_MANAGER_H
#define FS_MANAGER_H

#include <stdbool.h>

// Mount LittleFS filesystem.
bool fs_init();

// Load a file from LittleFS into a heap-allocated null-terminated buffer.
// Caller must free() the returned pointer.
char *fs_load_file(const char *path);

// Write a null-terminated string to a LittleFS file (creates parent dirs).
bool fs_save_file(const char *path, const char *data);

#endif
