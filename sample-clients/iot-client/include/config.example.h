#ifndef CONFIG_H
#define CONFIG_H

// ---- WiFi ----
#define WIFI_SSID              "your-wifi-ssid"
#define WIFI_PASSWORD          "your-wifi-password"
#define WIFI_CONNECT_TIMEOUT_MS 15000
#define WIFI_RETRY_DELAY_MS     5000

// ---- Device Identity ----
#define DEVICE_ID              "DEVICE001"

// ---- NATS ----
#define NATS_URL               "nats://localhost:4222"
#define NATS_CONNECT_TIMEOUT_MS 10000
#define NATS_DEFAULT_PORT       4222

// ---- Telemetry ----
#define TELEMETRY_INTERVAL_MS  300000
#define TELEMETRY_PREFIX       "prod.bigtable"
#define SCHEMA_VERSION         1

#endif
