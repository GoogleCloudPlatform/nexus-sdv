#include "cert_manager.h"
#include <Arduino.h>
#include <LittleFS.h>

bool cert_manager_init() {
    if (!LittleFS.begin(true)) {
        Serial.println("[CertMgr] Failed to mount LittleFS.");
        return false;
    }

    Serial.println("[CertMgr] LittleFS mounted.");
    return true;
}

char *cert_load_pem(const char *path) {
    File f = LittleFS.open(path, "r");
    if (!f) {
        Serial.printf("[CertMgr] Failed to open %s\n", path);
        return nullptr;
    }

    size_t size = f.size();
    // +1 for null terminator
    char *buf = (char *)malloc(size + 1);
    if (!buf) {
        Serial.println("[CertMgr] malloc failed for PEM buffer.");
        f.close();
        return nullptr;
    }

    f.readBytes(buf, size);
    buf[size] = '\0';
    f.close();

    Serial.printf("[CertMgr] Loaded %s (%u bytes)\n", path, (unsigned)size);
    return buf;
}
