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
#define SKIP_KEYCLOAK_AUTH     false
#define KEYCLOAK_URL           "https://keycloak.example.com"
#define TOKEN_MIN_REMAINING_S  120
// Throttles re-validation of the cached JWT (each check decodes/parses it).
// Must be < TOKEN_MIN_REMAINING_S * 1000 with comfortable margin.
// Typical: 10000 (10 s, conservative), 30000 (30 s, recommended),
// 60000 (60 s, max useful with TOKEN_MIN_REMAINING_S=120).
#define TOKEN_CHECK_INTERVAL_MS 10000

// ---- Certificate Paths (LittleFS) ----
#define OP_CERT_PATH           "/certs/operational.crt.pem"
#define OP_KEY_PATH            "/certs/operational.key.pem"
#define CA_CERT_PATH           "/certs/ca.crt.pem"

// ---- NATS ----
#define NATS_URL               "nats://localhost:4222"
#define NATS_CONNECT_TIMEOUT_MS 10000
#define NATS_DEFAULT_PORT       4222

// ---- Telemetry ----
// How often to publish a telemetry message. In deep-sleep mode this is
// effectively ignored (the cycle time equals DEEP_SLEEP_DURATION_S instead).
// Without deep sleep the device stays awake and sends every interval.
#define TELEMETRY_INTERVAL_MS  300000  // 5 min (5 * 60 * 1000)
// Inserted into the NATS subject: telemetry.<TELEMETRY_PREFIX>.<DEVICE_ID>.
// Used for routing/multi-tenancy on the broker side. Leave empty to publish
// to telemetry.<DEVICE_ID> with no extra path segment.
#define TELEMETRY_PREFIX       "prod.bigtable"
// Stamped into every TelemetryMessage as schema_version. Bump whenever the
// proto definition changes in a way consumers must branch on.
#define SCHEMA_VERSION         1

// ---- GPS (GY-NEO M8N on UART2) ----
// If true, the state machine blocks in STATE_GPS_WAIT until a fix is acquired
// (or GPS_FIX_TIMEOUT_S elapses). If false, telemetry is sent without waiting
// and GPS values stay invalid/zero until the receiver gets its first fix.
#define GPS_WAIT_FOR_FIX       false
// Maximum seconds to wait for a GPS fix when GPS_WAIT_FOR_FIX is true.
// After the timeout the device proceeds without GPS. 0 = wait indefinitely.
#define GPS_FIX_TIMEOUT_S      90
#define GPS_RX_PIN             16
#define GPS_TX_PIN             17

// ---- Deep Sleep ----
#define DEEP_SLEEP_ENABLED     false
#define DEEP_SLEEP_DURATION_S  300    // 5 minutes

#endif
