#include <Arduino.h>
#include <ArduinoJson.h>
#include "config.h"
#include "wifi_manager.h"
#include "fs_manager.h"
#include "keycloak_auth.h"
#include "nats_client.h"
#include "gps_manager.h"
#include "telemetry_sender.h"

enum ClientState {
    STATE_WIFI_CONNECT,
    STATE_NTP_SYNC,
    STATE_LOAD_CERTS,
    STATE_AUTHENTICATE,
    STATE_GPS_WAIT,
    STATE_NATS_CONNECT,
    STATE_SEND_TELEMETRY,
    STATE_DEEP_SLEEP,
    STATE_ERROR
};

static ClientState currentState = STATE_WIFI_CONNECT;

// Runtime URL overrides (loaded from /urls.json on LittleFS, fallback to config.h defaults)
static char keycloakUrl[256];
static char natsUrl[256];

// Certificate PEM strings (loaded once, kept for token refresh)
static char *opCertPem = nullptr;
static char *opKeyPem  = nullptr;
static char *caCertPem = nullptr;

// Auth state
static char *accessToken = nullptr;

// NATS + telemetry state
static NatsClient *natsClient = nullptr;
RTC_DATA_ATTR int messageIndex = 0;
static unsigned long lastSendTime = 0;

// Fallback for users whose (gitignored) config.h predates this flag.
#ifndef TOKEN_CHECK_INTERVAL_MS
#define TOKEN_CHECK_INTERVAL_MS 10000
#endif
static unsigned long lastTokenCheck = 0;

// Tracks when STATE_GPS_WAIT was entered to enforce GPS_FIX_TIMEOUT_S
static unsigned long gpsWaitStart = 0;

// JWT cache path (LittleFS) for deep sleep persistence
static const char *JWT_CACHE_PATH = "/cache/jwt.txt";

void setup() {
    Serial.begin(115200);
    delay(1000);

    Serial.println("==========================================");
    Serial.println("  Nexus SDV IoT Client");
    Serial.println("==========================================");
    strlcpy(keycloakUrl, KEYCLOAK_URL, sizeof(keycloakUrl));
    strlcpy(natsUrl, NATS_URL, sizeof(natsUrl));

    Serial.printf("  DEVICE ID:             %s\n", DEVICE_ID);
    Serial.printf("  Keycloak auth:         %s\n", SKIP_KEYCLOAK_AUTH ? "skipped" : "enabled");
    Serial.printf("  Telemetry interval:    %d ms\n", TELEMETRY_INTERVAL_MS);
    Serial.printf("  Deep sleep:            %s\n", DEEP_SLEEP_ENABLED ? "ON" : "OFF");
    if (DEEP_SLEEP_ENABLED) {
        Serial.printf("  Sleep duration:        %d s\n", DEEP_SLEEP_DURATION_S);
    }
    Serial.printf("  Free heap: %u bytes\n", ESP.getFreeHeap());
    Serial.println("==========================================\n");

    gps_init(GPS_RX_PIN, GPS_TX_PIN);
}

void loop() {
    gps_feed();

    switch (currentState) {

    case STATE_WIFI_CONNECT:
        Serial.println("[Main] Step 1/5: Connecting to WiFi...");
        wifi_init(WIFI_SSID, WIFI_PASSWORD);
        wifi_wait_for_connection(WIFI_CONNECT_TIMEOUT_MS);
        if (wifi_is_connected()) {
            currentState = STATE_NTP_SYNC;
        } else {
            Serial.println("[Main] WiFi failed. Retrying in 5s...");
            delay(WIFI_RETRY_DELAY_MS);
        }
        break;

    case STATE_NTP_SYNC:
        Serial.println("[Main] Step 2/5: Synchronizing time via NTP...");
        configTime(0, 0, "pool.ntp.org", "time.nist.gov");
        {
            time_t now = 0;
            unsigned long start = millis();
            while (now < 1000000000 && (millis() - start) < 15000) {
                delay(200);
                time(&now);
            }
            if (now >= 1000000000) {
                struct tm timeinfo;
                gmtime_r(&now, &timeinfo);
                char tbuf[32];
                strftime(tbuf, sizeof(tbuf), "%Y-%m-%d %H:%M:%S UTC", &timeinfo);
                Serial.printf("[Main] Time synced: %s\n", tbuf);
                currentState = STATE_LOAD_CERTS;
            } else {
                Serial.println("[Main] NTP sync failed. Retrying...");
                delay(2000);
            }
        }
        break;

    case STATE_LOAD_CERTS:
        Serial.println("[Main] Step 3/5: Loading filesystem...");
        if (!fs_init()) {
            currentState = STATE_ERROR;
            break;
        }

        // Load URL overrides from /urls.json (optional)
        {
            char *json = fs_load_file("/urls.json");
            if (json) {
                JsonDocument doc;
                if (deserializeJson(doc, json) == DeserializationError::Ok) {
                    if (doc["keycloak_url"].is<const char *>())
                        strlcpy(keycloakUrl, doc["keycloak_url"], sizeof(keycloakUrl));
                    if (doc["nats_url"].is<const char *>())
                        strlcpy(natsUrl, doc["nats_url"], sizeof(natsUrl));
                    Serial.println("[Main] URL overrides loaded from /urls.json");
                } else {
                    Serial.println("[Main] WARN: /urls.json parse failed, using defaults.");
                }
                free(json);
            }
            Serial.printf("  Keycloak URL: %s\n", keycloakUrl);
            Serial.printf("  NATS URL:     %s\n", natsUrl);
        }

        if (SKIP_KEYCLOAK_AUTH) {
            currentState = GPS_WAIT_FOR_FIX ? STATE_GPS_WAIT : STATE_NATS_CONNECT;
            break;
        }

        opCertPem = fs_load_file(OP_CERT_PATH);
        opKeyPem  = fs_load_file(OP_KEY_PATH);
        caCertPem = fs_load_file(CA_CERT_PATH);
        if (opCertPem && opKeyPem && caCertPem) {
            Serial.printf("[Main] Free heap after cert load: %u bytes\n", ESP.getFreeHeap());
            currentState = STATE_AUTHENTICATE;
        } else {
            Serial.println("[Main] ERROR: Missing certificates on filesystem.");
            currentState = STATE_ERROR;
        }
        break;

    case STATE_AUTHENTICATE:
        Serial.println("[Main] Step 4/5: Getting JWT from Keycloak...");
        {
            // Try cached JWT first (useful after deep sleep wake)
            if (!accessToken) {
                char *cached = fs_load_file(JWT_CACHE_PATH);
                if (cached && token_valid_for(cached, TOKEN_MIN_REMAINING_S)) {
                    Serial.println("[Main] Using cached JWT.");
                    accessToken = cached;
                    currentState = GPS_WAIT_FOR_FIX ? STATE_GPS_WAIT : STATE_NATS_CONNECT;
                    break;
                }
                free(cached);
            }

            AuthResult auth = keycloak_get_token(keycloakUrl, opCertPem, opKeyPem, caCertPem);
            if (auth.success) {
                free(accessToken);
                accessToken = auth.access_token;
                // Cache JWT for deep sleep persistence
                fs_save_file(JWT_CACHE_PATH, accessToken);
                currentState = GPS_WAIT_FOR_FIX ? STATE_GPS_WAIT : STATE_NATS_CONNECT;
            } else {
                Serial.println("[Main] Authentication failed. Retrying in 5s...");
                delay(5000);
            }
        }
        break;

    case STATE_NATS_CONNECT:
        Serial.println("[Main] Step 5/5: Connecting to NATS...");
        natsClient = nats_create();
        if (nats_connect(natsClient, natsUrl, accessToken)) {
            lastSendTime = 0;
            currentState = STATE_SEND_TELEMETRY;
        } else {
            Serial.println("[Main] NATS connection failed. Retrying in 5s...");
            nats_destroy(natsClient);
            natsClient = nullptr;
            delay(5000);
        }
        break;

    case STATE_GPS_WAIT:
        {
            if (gpsWaitStart == 0) {
                gpsWaitStart = millis();
                Serial.printf("[Main] Waiting for GPS fix (timeout: %d s)...\n", GPS_FIX_TIMEOUT_S);
            }

            GpsData gpsCheck = gps_get_data();
            unsigned long elapsed = millis() - gpsWaitStart;

            if (gpsCheck.valid) {
                Serial.printf("[Main] GPS fix acquired after %lu s.\n", elapsed / 1000);
                gpsWaitStart = 0;
                currentState = STATE_NATS_CONNECT;
            } else if (GPS_FIX_TIMEOUT_S > 0 && elapsed >= (unsigned long)GPS_FIX_TIMEOUT_S * 1000) {
                Serial.printf("[Main] GPS fix timeout after %d s. Sending without GPS.\n", GPS_FIX_TIMEOUT_S);
                gpsWaitStart = 0;
                currentState = STATE_NATS_CONNECT;
            } else {
                if (elapsed % 10000 < 150) {
                    Serial.printf("[Main] Waiting for GPS fix... %lu s / %d s\n", elapsed / 1000, GPS_FIX_TIMEOUT_S);
                }
                delay(100);
            }
        }
        break;

    case STATE_SEND_TELEMETRY:
        // Periodically check if token is still valid for at least TOKEN_MIN_REMAINING_S
        if (accessToken &&
            (lastTokenCheck == 0 || (millis() - lastTokenCheck) >= TOKEN_CHECK_INTERVAL_MS)) {
            lastTokenCheck = millis();
            if (!token_valid_for(accessToken, TOKEN_MIN_REMAINING_S)) {
                Serial.println("[Main] Token expiring soon. Re-authenticating...");
                nats_destroy(natsClient);
                natsClient = nullptr;
                currentState = STATE_AUTHENTICATE;
                break;
            }
        }

        if (!nats_process(natsClient)) {
            Serial.println("[Main] NATS connection lost. Reconnecting...");
            nats_destroy(natsClient);
            natsClient = nullptr;
            currentState = STATE_NATS_CONNECT;
            break;
        }

        if (lastSendTime == 0 || (millis() - lastSendTime) >= (unsigned long)TELEMETRY_INTERVAL_MS) {
            int interval_sec = DEEP_SLEEP_ENABLED ? DEEP_SLEEP_DURATION_S : TELEMETRY_INTERVAL_MS / 1000;
            GpsData gpsData = gps_get_data();
            if (telemetry_send_message(natsClient, DEVICE_ID, TELEMETRY_PREFIX, messageIndex, interval_sec, &gpsData)) {
                Serial.printf("[Main] Message %d sent.\n", messageIndex + 1);
                messageIndex++;
            } else {
                Serial.println("[Main] Failed to send telemetry.");
            }
            lastSendTime = millis();

            if (DEEP_SLEEP_ENABLED) {
                currentState = STATE_DEEP_SLEEP;
                break;
            }
        }

        delay(100);
        break;

    case STATE_DEEP_SLEEP:
        Serial.println("[Main] Entering deep sleep...");
        nats_destroy(natsClient);
        natsClient = nullptr;
        free(opCertPem);   opCertPem   = nullptr;
        free(opKeyPem);    opKeyPem    = nullptr;
        free(caCertPem);   caCertPem   = nullptr;
        free(accessToken); accessToken = nullptr;
        gps_enter_powersave_mode();
        Serial.printf("[Main] Sleeping for %d seconds. Goodnight.\n", DEEP_SLEEP_DURATION_S);
        Serial.flush();
        esp_deep_sleep(DEEP_SLEEP_DURATION_S * 1000000ULL);
        break;  // never reached

    case STATE_ERROR:
        Serial.println("\n==========================================");
        Serial.println("  IoT Client encountered an error.");
        Serial.printf("  Free heap: %u bytes\n", ESP.getFreeHeap());
        Serial.println("==========================================");
        Serial.println("Reset the device to retry.");

        if (natsClient) { nats_destroy(natsClient); natsClient = nullptr; }
        free(opCertPem);   opCertPem   = nullptr;
        free(opKeyPem);    opKeyPem    = nullptr;
        free(caCertPem);   caCertPem   = nullptr;
        free(accessToken); accessToken = nullptr;

        while (true) { delay(10000); }
        break;
    }
}
