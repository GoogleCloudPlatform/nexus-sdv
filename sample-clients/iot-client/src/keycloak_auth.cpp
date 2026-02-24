#include "keycloak_auth.h"
#include <Arduino.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>
#include <time.h>

// Base64url alphabet: A-Z a-z 0-9 - _
static int b64url_char_value(char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '-') return 62;
    if (c == '_') return 63;
    return -1;
}

// Decode base64url string into output buffer. Returns decoded length, or -1 on error.
static int base64url_decode(const char *input, size_t input_len, uint8_t *output, size_t output_size) {
    size_t out_pos = 0;
    uint32_t accum = 0;
    int bits = 0;

    for (size_t i = 0; i < input_len; i++) {
        if (input[i] == '=') break;
        int val = b64url_char_value(input[i]);
        if (val < 0) return -1;
        accum = (accum << 6) | val;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (out_pos >= output_size) return -1;
            output[out_pos++] = (uint8_t)(accum >> bits) & 0xFF;
        }
    }
    return (int)out_pos;
}

AuthResult keycloak_get_token(
    const char *keycloak_url,
    const char *op_cert_pem,
    const char *op_key_pem,
    const char *ca_cert_pem
) {
    AuthResult result = {nullptr, 0, false};

    WiFiClientSecure client;
    client.setCACert(ca_cert_pem);
    client.setCertificate(op_cert_pem);
    client.setPrivateKey(op_key_pem);

    HTTPClient http;

    // Build token endpoint URL
    // keycloak_url may have trailing whitespace from JSON parsing
    String kc(keycloak_url);
    kc.trim();
    String url = kc + "/realms/sdv-telemetry/protocol/openid-connect/token";

    Serial.printf("[Auth] POST %s\n", url.c_str());

    if (!http.begin(client, url)) {
        Serial.println("[Auth] Failed to begin HTTP connection.");
        return result;
    }

    http.addHeader("Content-Type", "application/x-www-form-urlencoded");
    http.setTimeout(30000);

    int httpCode = http.POST("grant_type=client_credentials&client_id=car");

    if (httpCode != HTTP_CODE_OK) {
        Serial.printf("[Auth] HTTP error: %d\n", httpCode);
        if (httpCode > 0) {
            Serial.printf("[Auth] Response: %s\n", http.getString().substring(0, 256).c_str());
        }
        http.end();
        return result;
    }

    String body = http.getString();
    http.end();

    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, body);
    if (err) {
        Serial.printf("[Auth] JSON parse error: %s\n", err.c_str());
        return result;
    }

    const char *token = doc["access_token"];
    if (!token) {
        Serial.println("[Auth] No access_token in response.");
        return result;
    }

    result.access_token = strdup(token);
    result.expires_in = doc["expires_in"] | 300;
    result.success = (result.access_token != nullptr);

    Serial.printf("[Auth] Token acquired (expires in %d s).\n", result.expires_in);
    return result;
}

void auth_result_free(AuthResult *result) {
    free(result->access_token);
    result->access_token = nullptr;
    result->expires_in = 0;
    result->success = false;
}

bool token_valid_for(const char *jwt, int min_remaining_seconds) {
    if (!jwt) return false;

    // Find the payload segment (between first and second '.')
    const char *first_dot = strchr(jwt, '.');
    if (!first_dot) return false;
    const char *payload_start = first_dot + 1;

    const char *second_dot = strchr(payload_start, '.');
    if (!second_dot) return false;

    size_t payload_len = second_dot - payload_start;

    // Decode base64url payload (JWT payloads are typically <1KB)
    uint8_t decoded[1024];
    int decoded_len = base64url_decode(payload_start, payload_len, decoded, sizeof(decoded) - 1);
    if (decoded_len < 0) {
        Serial.println("[Auth] Failed to decode JWT payload.");
        return false;
    }
    decoded[decoded_len] = '\0';

    // Parse JSON and extract exp claim
    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, (const char *)decoded);
    if (err) {
        Serial.printf("[Auth] JWT payload parse error: %s\n", err.c_str());
        return false;
    }

    time_t exp = doc["exp"] | (time_t)0;
    if (exp == 0) {
        Serial.println("[Auth] No exp claim in JWT.");
        return false;
    }

    time_t now = time(nullptr);
    int remaining = (int)(exp - now);
    Serial.printf("[Auth] Token expires in %d s.\n", remaining);

    return remaining >= min_remaining_seconds;
}
