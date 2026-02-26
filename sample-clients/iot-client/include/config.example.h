// User-specific config (copy config.example.h to config.h and edit)

#ifndef CONFIG_H
#define CONFIG_H

// ---- WiFi ----
#define WIFI_SSID              "your-wifi-ssid"
#define WIFI_PASSWORD          "your-wifi-password"
#define WIFI_CONNECT_TIMEOUT_MS 15000
#define WIFI_RETRY_DELAY_MS     5000

// ---- Device Identity ----
#define DEVICE_ID              "DEVICE001"

// ---- Keycloak ----
#define KEYCLOAK_URL           "https://keycloak.example.com"
#define TOKEN_MIN_REMAINING_S  120

// ---- Certificate Paths (LittleFS) ----
#define OP_CERT_PATH           "/certs/operational.crt.pem"
#define OP_KEY_PATH            "/certs/operational.key.pem"
#define CA_CERT_PATH           "/certs/ca.crt.pem"

// ---- NATS ----
#define NATS_URL               "nats://localhost:4222"
#define NATS_CONNECT_TIMEOUT_MS 10000
#define NATS_DEFAULT_PORT       4222

// ---- Telemetry ----
#define TELEMETRY_INTERVAL_MS  300000  // 1000*60*5 ms
#define TELEMETRY_PREFIX       "prod.bigtable"
#define SCHEMA_VERSION         1

// ---- GPS (GY-NEO M8N on UART2) ----
#define GPS_RX_PIN             16
#define GPS_TX_PIN             17

// ---- Deep Sleep ----
#define DEEP_SLEEP_ENABLED     false
#define DEEP_SLEEP_DURATION_S  300    // 5 minutes

#endif
