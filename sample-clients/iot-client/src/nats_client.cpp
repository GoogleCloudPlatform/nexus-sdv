#include "nats_client.h"
#include "config.h"
#include <Arduino.h>
#include <WiFiClient.h>

struct NatsClient {
    WiFiClient tcp;
    bool connected;
    char host[128];
    uint16_t port;
    char read_buf[1024];
    size_t buf_pos;
};

NatsClient *nats_create() {
    return new NatsClient();
}

// Parse "nats://host:port" into host and port
static bool parse_url(const char *url, char *host, size_t host_size, uint16_t *port) {
    const char *p = url;

    // Skip scheme
    if (strncmp(p, "nats://", 7) == 0) {
        p += 7;
    } else if (strncmp(p, "tls://", 6) == 0) {
        p += 6;
    }

    const char *colon = strchr(p, ':');
    if (colon) {
        size_t hlen = colon - p;
        if (hlen >= host_size) hlen = host_size - 1;
        strncpy(host, p, hlen);
        host[hlen] = '\0';
        *port = (uint16_t)atoi(colon + 1);
    } else {
        strncpy(host, p, host_size - 1);
        host[host_size - 1] = '\0';
        *port = NATS_DEFAULT_PORT;
    }

    return host[0] != '\0';
}

// Read a line (up to \r\n) from the TCP socket with timeout
static bool read_line(WiFiClient &tcp, char *buf, size_t buf_size, unsigned long timeout_ms) {
    size_t pos = 0;
    unsigned long start = millis();

    while ((millis() - start) < timeout_ms) {
        if (tcp.available()) {
            char c = tcp.read();
            if (c == '\n') {
                // Strip trailing \r
                if (pos > 0 && buf[pos - 1] == '\r') pos--;
                buf[pos] = '\0';
                return true;
            }
            if (pos < buf_size - 1) {
                buf[pos++] = c;
            }
        } else {
            delay(1);
        }
    }
    buf[pos] = '\0';
    return false;
}

bool nats_connect(NatsClient *nc, const char *url, const char *token) {
    if (!parse_url(url, nc->host, sizeof(nc->host), &nc->port)) {
        Serial.println("[NATS] Failed to parse URL.");
        return false;
    }

    Serial.printf("[NATS] Connecting to %s:%d...\n", nc->host, nc->port);

    if (!nc->tcp.connect(nc->host, nc->port)) {
        Serial.println("[NATS] TCP connection failed.");
        return false;
    }

    // Read INFO message from server
    char line[512];
    if (!read_line(nc->tcp, line, sizeof(line), NATS_CONNECT_TIMEOUT_MS)) {
        Serial.println("[NATS] Timeout waiting for INFO.");
        nc->tcp.stop();
        return false;
    }

    if (strncmp(line, "INFO ", 5) != 0) {
        Serial.printf("[NATS] Expected INFO, got: %s\n", line);
        nc->tcp.stop();
        return false;
    }
    Serial.println("[NATS] Received server INFO.");

    // Send CONNECT (with optional auth_token)
    String connect_msg = "CONNECT {\"verbose\":false,\"pedantic\":false,\"tls_required\":false";
    if (token && token[0] != '\0') {
        connect_msg += ",\"auth_token\":\"";
        connect_msg += token;
        connect_msg += "\"";
    }
    connect_msg += ",\"lang\":\"esp32\",\"version\":\"1.0.0\",\"protocol\":1}\r\n";

    nc->tcp.print(connect_msg);

    // Send PING to verify connection
    nc->tcp.print("PING\r\n");

    // Expect PONG back
    if (!read_line(nc->tcp, line, sizeof(line), NATS_CONNECT_TIMEOUT_MS)) {
        Serial.println("[NATS] Timeout waiting for PONG.");
        nc->tcp.stop();
        return false;
    }

    if (strncmp(line, "PONG", 4) == 0) {
        nc->connected = true;
        Serial.println("[NATS] Connected and authenticated.");
        return true;
    }

    if (strncmp(line, "-ERR", 4) == 0) {
        Serial.printf("[NATS] Server error: %s\n", line);
    } else {
        Serial.printf("[NATS] Unexpected response: %s\n", line);
    }

    nc->tcp.stop();
    return false;
}

bool nats_publish(NatsClient *nc, const char *subject, const uint8_t *data, size_t len) {
    if (!nc->connected || !nc->tcp.connected()) {
        Serial.println("[NATS] Not connected.");
        nc->connected = false;
        return false;
    }

    // PUB <subject> <size>\r\n<payload>\r\n
    char header[256];
    snprintf(header, sizeof(header), "PUB %s %u\r\n", subject, (unsigned)len);

    nc->tcp.print(header);
    nc->tcp.write(data, len);
    nc->tcp.print("\r\n");

    return true;
}

bool nats_process(NatsClient *nc) {
    if (!nc->connected || !nc->tcp.connected()) {
        nc->connected = false;
        return false;
    }

    while (nc->tcp.available()) {
        char c = nc->tcp.read();

        if (c == '\n') {
            // Strip \r
            if (nc->buf_pos > 0 && nc->read_buf[nc->buf_pos - 1] == '\r') {
                nc->buf_pos--;
            }
            nc->read_buf[nc->buf_pos] = '\0';

            // Handle PING
            if (strncmp(nc->read_buf, "PING", 4) == 0) {
                nc->tcp.print("PONG\r\n");
            }
            // Handle -ERR
            else if (strncmp(nc->read_buf, "-ERR", 4) == 0) {
                Serial.printf("[NATS] Server error: %s\n", nc->read_buf);
                nc->connected = false;
                return false;
            }

            nc->buf_pos = 0;
        } else {
            if (nc->buf_pos < sizeof(nc->read_buf) - 1) {
                nc->read_buf[nc->buf_pos++] = c;
            }
        }
    }

    return true;
}

bool nats_is_connected(NatsClient *nc) {
    return nc && nc->connected && nc->tcp.connected();
}

void nats_disconnect(NatsClient *nc) {
    if (!nc) return;
    if (nc->tcp.connected()) {
        nc->tcp.stop();
    }
    nc->connected = false;
    Serial.println("[NATS] Disconnected.");
}

void nats_destroy(NatsClient *nc) {
    if (!nc) return;
    nats_disconnect(nc);
    delete nc;
}
