#include "cert_manager.h"
#include "config.h"
#include <Arduino.h>
#include <LittleFS.h>

#include "mbedtls/pk.h"
#include "mbedtls/rsa.h"
#include "mbedtls/entropy.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/x509_csr.h"
#include "mbedtls/error.h"

static void log_mbedtls_error(const char *context, int ret) {
    char errbuf[128];
    mbedtls_strerror(ret, errbuf, sizeof(errbuf));
    Serial.printf("[CertMgr] %s failed: -0x%04X (%s)\n", context, (unsigned int)-ret, errbuf);
}

bool cert_manager_init() {
    if (!LittleFS.begin(true)) {
        Serial.println("[CertMgr] Failed to mount LittleFS.");
        return false;
    }

    if (!LittleFS.exists(FACTORY_CERT_PATH)) {
        Serial.printf("[CertMgr] Factory cert not found at %s\n", FACTORY_CERT_PATH);
        return false;
    }
    if (!LittleFS.exists(FACTORY_KEY_PATH)) {
        Serial.printf("[CertMgr] Factory key not found at %s\n", FACTORY_KEY_PATH);
        return false;
    }
    if (!LittleFS.exists(CA_CERT_PATH)) {
        Serial.printf("[CertMgr] CA cert not found at %s\n", CA_CERT_PATH);
        return false;
    }

    Serial.println("[CertMgr] LittleFS mounted, factory certificates verified.");
    return true;
}

char *cert_load_pem(const char *path) {
    File f = LittleFS.open(path, "r");
    if (!f) {
        Serial.printf("[CertMgr] Failed to open %s\n", path);
        return nullptr;
    }

    size_t size = f.size();
    // +1 for null terminator
    char *buf = (char *)malloc(size + 1);
    if (!buf) {
        Serial.println("[CertMgr] malloc failed for PEM buffer.");
        f.close();
        return nullptr;
    }

    f.readBytes(buf, size);
    buf[size] = '\0';
    f.close();

    Serial.printf("[CertMgr] Loaded %s (%u bytes)\n", path, (unsigned)size);
    return buf;
}

bool cert_generate_operational_keypair(char **key_pem, size_t *key_pem_len) {
    int ret;
    mbedtls_pk_context pk;
    mbedtls_entropy_context entropy;
    mbedtls_ctr_drbg_context ctr_drbg;

    mbedtls_pk_init(&pk);
    mbedtls_entropy_init(&entropy);
    mbedtls_ctr_drbg_init(&ctr_drbg);

    const char *pers = "nexus_sdv_iot_keygen";
    ret = mbedtls_ctr_drbg_seed(&ctr_drbg, mbedtls_entropy_func, &entropy,
                                 (const unsigned char *)pers, strlen(pers));
    if (ret != 0) {
        log_mbedtls_error("ctr_drbg_seed", ret);
        goto cleanup;
    }

    ret = mbedtls_pk_setup(&pk, mbedtls_pk_info_from_type(MBEDTLS_PK_RSA));
    if (ret != 0) {
        log_mbedtls_error("pk_setup", ret);
        goto cleanup;
    }

    Serial.printf("[CertMgr] Generating RSA-%d key pair (this takes 15-60 seconds)...\n", RSA_KEY_SIZE);
    {
        unsigned long start = millis();
        ret = mbedtls_rsa_gen_key(mbedtls_pk_rsa(pk), mbedtls_ctr_drbg_random,
                                   &ctr_drbg, RSA_KEY_SIZE, RSA_EXPONENT);
        if (ret != 0) {
            log_mbedtls_error("rsa_gen_key", ret);
            goto cleanup;
        }
        Serial.printf("[CertMgr] Key generated in %lu ms.\n", millis() - start);
    }

    // Export private key to PEM
    {
        // mbedtls_pk_write_key_pem needs a buffer; 2048-bit RSA PEM is ~1700 bytes
        size_t buf_size = 4096;
        unsigned char *buf = (unsigned char *)malloc(buf_size);
        if (!buf) {
            Serial.println("[CertMgr] malloc failed for key PEM buffer.");
            ret = -1;
            goto cleanup;
        }

        ret = mbedtls_pk_write_key_pem(&pk, buf, buf_size);
        if (ret != 0) {
            log_mbedtls_error("pk_write_key_pem", ret);
            free(buf);
            goto cleanup;
        }

        *key_pem = (char *)buf;
        *key_pem_len = strlen((char *)buf);
    }

cleanup:
    mbedtls_pk_free(&pk);
    mbedtls_ctr_drbg_free(&ctr_drbg);
    mbedtls_entropy_free(&entropy);
    return ret == 0;
}

bool cert_create_csr(const char *vin, const char *key_pem_str,
                     char **csr_pem, size_t *csr_pem_len) {
    int ret;
    mbedtls_pk_context pk;
    mbedtls_x509write_csr csr;
    mbedtls_entropy_context entropy;
    mbedtls_ctr_drbg_context ctr_drbg;

    mbedtls_pk_init(&pk);
    mbedtls_x509write_csr_init(&csr);
    mbedtls_entropy_init(&entropy);
    mbedtls_ctr_drbg_init(&ctr_drbg);

    const char *pers = "nexus_sdv_iot_csr";
    ret = mbedtls_ctr_drbg_seed(&ctr_drbg, mbedtls_entropy_func, &entropy,
                                 (const unsigned char *)pers, strlen(pers));
    if (ret != 0) {
        log_mbedtls_error("ctr_drbg_seed", ret);
        goto cleanup;
    }

    // Parse the private key PEM
    ret = mbedtls_pk_parse_key(&pk,
                                (const unsigned char *)key_pem_str, strlen(key_pem_str) + 1,
                                nullptr, 0,
                                mbedtls_ctr_drbg_random, &ctr_drbg);
    if (ret != 0) {
        log_mbedtls_error("pk_parse_key", ret);
        goto cleanup;
    }

    // Build subject name: CN=VIN:{vin} DEVICE:{vin},O=Vehicle Manufacturer
    {
        char subject[256];
        snprintf(subject, sizeof(subject),
                 "CN=VIN:%s DEVICE:%s,O=Vehicle Manufacturer", vin, vin);

        mbedtls_x509write_csr_set_md_alg(&csr, MBEDTLS_MD_SHA256);
        mbedtls_x509write_csr_set_key(&csr, &pk);

        ret = mbedtls_x509write_csr_set_subject_name(&csr, subject);
        if (ret != 0) {
            log_mbedtls_error("csr_set_subject_name", ret);
            goto cleanup;
        }
    }

    // Write CSR to PEM
    {
        size_t buf_size = 4096;
        unsigned char *buf = (unsigned char *)malloc(buf_size);
        if (!buf) {
            Serial.println("[CertMgr] malloc failed for CSR buffer.");
            ret = -1;
            goto cleanup;
        }

        ret = mbedtls_x509write_csr_pem(&csr, buf, buf_size,
                                          mbedtls_ctr_drbg_random, &ctr_drbg);
        if (ret != 0) {
            log_mbedtls_error("csr_pem", ret);
            free(buf);
            goto cleanup;
        }

        *csr_pem = (char *)buf;
        *csr_pem_len = strlen((char *)buf);
        Serial.printf("[CertMgr] CSR created for VIN:%s (%u bytes)\n", vin, (unsigned)*csr_pem_len);
    }

cleanup:
    mbedtls_x509write_csr_free(&csr);
    mbedtls_pk_free(&pk);
    mbedtls_ctr_drbg_free(&ctr_drbg);
    mbedtls_entropy_free(&entropy);
    return ret == 0;
}

bool cert_save_operational(const char *cert_pem, const char *key_pem) {
    File f = LittleFS.open(OP_CERT_PATH, "w");
    if (!f) {
        Serial.printf("[CertMgr] Failed to open %s for writing.\n", OP_CERT_PATH);
        return false;
    }
    f.print(cert_pem);
    f.close();

    f = LittleFS.open(OP_KEY_PATH, "w");
    if (!f) {
        Serial.printf("[CertMgr] Failed to open %s for writing.\n", OP_KEY_PATH);
        return false;
    }
    f.print(key_pem);
    f.close();

    Serial.println("[CertMgr] Operational cert and key saved to LittleFS.");
    return true;
}

bool cert_has_operational() {
    return LittleFS.exists(OP_CERT_PATH) && LittleFS.exists(OP_KEY_PATH);
}
