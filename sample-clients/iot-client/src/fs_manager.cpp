#include "fs_manager.h"
#include <Arduino.h>
#include <LittleFS.h>

bool fs_init() {
    if (!LittleFS.begin(true)) {
        Serial.println("[FS] Failed to mount LittleFS.");
        return false;
    }

    Serial.println("[FS] LittleFS mounted.");
    return true;
}

char *fs_load_file(const char *path) {
    File f = LittleFS.open(path, "r");
    if (!f) {
        Serial.printf("[FS] Failed to open %s\n", path);
        return nullptr;
    }

    size_t size = f.size();
    // +1 for null terminator
    char *buf = (char *)malloc(size + 1);
    if (!buf) {
        Serial.println("[FS] malloc failed for file buffer.");
        f.close();
        return nullptr;
    }

    f.readBytes(buf, size);
    buf[size] = '\0';
    f.close();

    Serial.printf("[FS] Loaded %s (%u bytes)\n", path, (unsigned)size);
    return buf;
}

bool fs_save_file(const char *path, const char *data) {
    File f = LittleFS.open(path, "w", true);  // true = create parent dirs
    if (!f) {
        Serial.printf("[FS] Failed to open %s for writing\n", path);
        return false;
    }

    size_t len = strlen(data);
    size_t written = f.print(data);
    f.close();

    if (written != len) {
        Serial.printf("[FS] Write incomplete: %u of %u bytes\n", (unsigned)written, (unsigned)len);
        return false;
    }

    Serial.printf("[FS] Saved %s (%u bytes)\n", path, (unsigned)len);
    return true;
}
