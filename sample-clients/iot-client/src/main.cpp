#include <Arduino.h>
#include "config.h"
#include "wifi_manager.h"
#include "nats_client.h"
#include "telemetry_sender.h"

enum ClientState {
    STATE_WIFI_CONNECT,
    STATE_NTP_SYNC,
    STATE_NATS_CONNECT,
    STATE_SEND_TELEMETRY,
    STATE_ERROR
};

static ClientState currentState = STATE_WIFI_CONNECT;
static NatsClient *natsClient = nullptr;
static int messageIndex = 0;
static unsigned long lastSendTime = 0;

void setup() {
    Serial.begin(115200);
    delay(1000);

    Serial.println("==========================================");
    Serial.println("  Nexus SDV IoT Client (Dev Mode)");
    Serial.println("==========================================");
    Serial.printf("  DEVICE ID:             %s\n", DEVICE_ID);
    Serial.printf("  NATS URL:              %s\n", NATS_URL);
    Serial.printf("  Telemetry interval: %d ms\n", TELEMETRY_INTERVAL_MS);
    Serial.printf("  Free heap: %u bytes\n", ESP.getFreeHeap());
    Serial.println("==========================================\n");
}

void loop() {
    switch (currentState) {

    case STATE_WIFI_CONNECT:
        Serial.println("[Main] Step 1/3: Connecting to WiFi...");
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
        Serial.println("[Main] Step 2/3: Synchronizing time via NTP...");
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
                currentState = STATE_NATS_CONNECT;
            } else {
                Serial.println("[Main] NTP sync failed. Retrying...");
                delay(2000);
            }
        }
        break;

    case STATE_NATS_CONNECT:
        Serial.println("[Main] Step 3/3: Connecting to NATS...");
        natsClient = nats_create();
        if (nats_connect(natsClient, NATS_URL, NULL)) {
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

        while (true) { delay(10000); }
        break;
    }
}
