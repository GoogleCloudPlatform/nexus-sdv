#include "uuid_gen.h"
#include <esp_random.h>
#include <stdio.h>

void uuid_v4(char *buf, size_t buf_size) {
    if (buf_size < 37) return;

    uint8_t bytes[16];
    // Use ESP32 hardware RNG
    for (int i = 0; i < 16; i += 4) {
        uint32_t r = esp_random();
        bytes[i]     = (r >> 0)  & 0xFF;
        bytes[i + 1] = (r >> 8)  & 0xFF;
        bytes[i + 2] = (r >> 16) & 0xFF;
        bytes[i + 3] = (r >> 24) & 0xFF;
    }

    // Set version 4 (bits 12-15 of time_hi_and_version)
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    // Set variant 10xx (bits 6-7 of clock_seq_hi_and_reserved)
    bytes[8] = (bytes[8] & 0x3F) | 0x80;

    snprintf(buf, buf_size,
        "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5],
        bytes[6], bytes[7],
        bytes[8], bytes[9],
        bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]);
}
