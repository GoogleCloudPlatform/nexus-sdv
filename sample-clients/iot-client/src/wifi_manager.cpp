#include "wifi_manager.h"
#include <Arduino.h>
#include <WiFi.h>

bool wifi_init(const char *ssid, const char *password) {
    WiFi.mode(WIFI_STA);
    WiFi.setSleep(false);
    WiFi.begin(ssid, password);
    Serial.printf("[WiFi] Connecting to %s", ssid);
    return true;
}

bool wifi_is_connected() {
    return WiFi.status() == WL_CONNECTED;
}

void wifi_wait_for_connection(unsigned long timeout_ms) {
    unsigned long start = millis();
    while (!wifi_is_connected() && (millis() - start) < timeout_ms) {
        Serial.print(".");
        delay(500);
    }
    Serial.println();

    if (wifi_is_connected()) {
        Serial.printf("[WiFi] Connected. IP: %s\n", WiFi.localIP().toString().c_str());
    } else {
        Serial.println("[WiFi] Connection timed out.");
    }
}

void wifi_disconnect() {
    WiFi.disconnect(true);
    Serial.println("[WiFi] Disconnected.");
}
