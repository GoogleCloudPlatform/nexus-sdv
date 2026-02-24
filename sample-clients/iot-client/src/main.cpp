#include <Arduino.h>
#include "config.h"
#include "wifi_manager.h"
#include "cert_manager.h"
#include "keycloak_auth.h"
#include "nats_client.h"
#include "telemetry_sender.h"

enum ClientState {
    STATE_WIFI_CONNECT,
    STATE_NTP_SYNC,
    STATE_LOAD_CERTS,
    STATE_AUTHENTICATE,
    STATE_NATS_CONNECT,
    STATE_SEND_TELEMETRY,
    STATE_ERROR
};

static ClientState currentState = STATE_WIFI_CONNECT;

// Certificate PEM strings (loaded once, kept for token refresh)
static char *opCertPem = nullptr;
static char *opKeyPem  = nullptr;
static char *caCertPem = nullptr;

// Auth state
static char *accessToken = nullptr;

// NATS + telemetry state
static NatsClient *natsClient = nullptr;
static int messageIndex = 0;
static unsigned long lastSendTime = 0;

void setup() {
    Serial.begin(115200);
    delay(1000);

    Serial.println("==========================================");
    Serial.println("  Nexus SDV IoT Client");
    Serial.println("==========================================");
    Serial.printf("  DEVICE ID:             %s\n", DEVICE_ID);
    Serial.printf("  Keycloak URL:          %s\n", KEYCLOAK_URL);
    Serial.printf("  NATS URL:              %s\n", NATS_URL);
    Serial.printf("  Telemetry interval: %d ms\n", TELEMETRY_INTERVAL_MS);
    Serial.printf("  Free heap: %u bytes\n", ESP.getFreeHeap());
    Serial.println("==========================================\n");
}

void loop() {
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
        Serial.println("[Main] Step 3/5: Loading certificates...");
        if (!cert_manager_init()) {
            currentState = STATE_ERROR;
            break;
        }
        opCertPem = cert_load_pem(OP_CERT_PATH);
        opKeyPem  = cert_load_pem(OP_KEY_PATH);
        caCertPem = cert_load_pem(CA_CERT_PATH);
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
            AuthResult auth = keycloak_get_token(KEYCLOAK_URL, opCertPem, opKeyPem, caCertPem);
            if (auth.success) {
                free(accessToken);
                accessToken = auth.access_token;
                currentState = STATE_NATS_CONNECT;
            } else {
                Serial.println("[Main] Authentication failed. Retrying in 5s...");
                delay(5000);
            }
        }
        break;

    case STATE_NATS_CONNECT:
        Serial.println("[Main] Step 5/5: Connecting to NATS...");
        natsClient = nats_create();
        if (nats_connect(natsClient, NATS_URL, accessToken)) {
            lastSendTime = 0;
            currentState = STATE_SEND_TELEMETRY;
        } else {
            Serial.println("[Main] NATS connection failed. Retrying in 5s...");
            nats_destroy(natsClient);
            natsClient = nullptr;
            delay(5000);
        }
        break;

    case STATE_SEND_TELEMETRY:
        // Check if token is still valid for at least TOKEN_MIN_REMAINING_S
        if (!token_valid_for(accessToken, TOKEN_MIN_REMAINING_S)) {
            Serial.println("[Main] Token expiring soon. Re-authenticating...");
            nats_destroy(natsClient);
            natsClient = nullptr;
            currentState = STATE_AUTHENTICATE;
            break;
        }

        if (!nats_process(natsClient)) {
            Serial.println("[Main] NATS connection lost. Reconnecting...");
            nats_destroy(natsClient);
            natsClient = nullptr;
            currentState = STATE_NATS_CONNECT;
            break;
        }

        if (lastSendTime == 0 || (millis() - lastSendTime) >= (unsigned long)TELEMETRY_INTERVAL_MS) {
            int interval_sec = TELEMETRY_INTERVAL_MS / 1000;
            if (telemetry_send_message(natsClient, DEVICE_ID, TELEMETRY_PREFIX, messageIndex, interval_sec)) {
                Serial.printf("[Main] Message %d sent.\n", messageIndex + 1);
                messageIndex++;
            } else {
                Serial.println("[Main] Failed to send telemetry.");
            }
            lastSendTime = millis();
        }

        delay(100);
        break;

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
