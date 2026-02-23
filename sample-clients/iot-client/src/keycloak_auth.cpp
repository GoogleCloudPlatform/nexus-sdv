#include "keycloak_auth.h"
#include <Arduino.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>

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
