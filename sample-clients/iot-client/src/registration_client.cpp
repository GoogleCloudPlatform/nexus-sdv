#include "registration_client.h"
#include <Arduino.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>

RegistrationResult registration_register(
    const char *registration_url,
    const char *factory_cert_pem,
    const char *factory_key_pem,
    const char *ca_cert_pem,
    const char *csr_pem
) {
    RegistrationResult result = {nullptr, nullptr, nullptr, false};

    WiFiClientSecure client;
    client.setCACert(ca_cert_pem);
    client.setCertificate(factory_cert_pem);
    client.setPrivateKey(factory_key_pem);

    HTTPClient http;
    String url = String(registration_url) + "/registration";

    Serial.printf("[Reg] POST %s\n", url.c_str());

    if (!http.begin(client, url)) {
        Serial.println("[Reg] Failed to begin HTTP connection.");
        return result;
    }

    http.addHeader("Content-Type", "application/x-pem-file");
    http.setTimeout(30000);

    int httpCode = http.POST((uint8_t *)csr_pem, strlen(csr_pem));

    if (httpCode != HTTP_CODE_OK) {
        Serial.printf("[Reg] HTTP error: %d\n", httpCode);
        if (httpCode > 0) {
            Serial.printf("[Reg] Response: %s\n", http.getString().substring(0, 256).c_str());
        }
        http.end();
        return result;
    }

    String body = http.getString();
    http.end();

    // Parse JSON: { "certificate": "...", "keycloak_url": "...", "nats_url": "..." }
    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, body);
    if (err) {
        Serial.printf("[Reg] JSON parse error: %s\n", err.c_str());
        return result;
    }

    const char *cert = doc["certificate"];
    const char *kc_url = doc["keycloak_url"];
    const char *nats = doc["nats_url"];

    if (!cert || !kc_url || !nats) {
        Serial.println("[Reg] Missing fields in response JSON.");
        return result;
    }

    result.certificate = strdup(cert);
    result.keycloak_url = strdup(kc_url);
    result.nats_url = strdup(nats);
    result.success = (result.certificate && result.keycloak_url && result.nats_url);

    Serial.println("[Reg] Registration successful.");
    return result;
}

void registration_result_free(RegistrationResult *result) {
    free(result->certificate);
    free(result->keycloak_url);
    free(result->nats_url);
    result->certificate = nullptr;
    result->keycloak_url = nullptr;
    result->nats_url = nullptr;
    result->success = false;
}
