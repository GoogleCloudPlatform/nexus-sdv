#include "gps_manager.h"
#include <Arduino.h>
#include <TinyGPSPlus.h>
#include <HardwareSerial.h>

static TinyGPSPlus gps;
static HardwareSerial gpsSerial(2);

static void gps_exit_powersaving_mode(int tx_pin);

void gps_init(int rx_pin, int tx_pin) {
    gps_exit_powersaving_mode(tx_pin);
    gpsSerial.begin(9600, SERIAL_8N1, rx_pin, tx_pin);
    Serial.printf("[GPS] UART2 initialized (9600 baud, RX=GPIO%d, TX=GPIO%d)\n", rx_pin, tx_pin);
}

void gps_feed() {
    while (gpsSerial.available()) {
        gps.encode(gpsSerial.read());
    }
}

GpsData gps_get_data() {
    GpsData data = {};
    data.valid = gps.location.isValid();
    if (data.valid) {
        data.latitude  = gps.location.lat();
        data.longitude = gps.location.lng();
        data.altitude  = gps.altitude.isValid() ? gps.altitude.meters() : 0.0;
    }
    return data;
}

// UBX-RXM-PMREQ: enter backup mode (duration=0 indefinite, flags=0x02 backup)
static const uint8_t UBX_BACKUP[] = {
    0xB5, 0x62,             // sync
    0x02, 0x41,             // class RXM, id PMREQ
    0x08, 0x00,             // payload length = 8
    0x00, 0x00, 0x00, 0x00, // duration = 0 (until UART wake)
    0x02, 0x00, 0x00, 0x00, // flags = backup
    0x4D, 0x3B              // checksum
};

void gps_enter_powersave_mode() {
    gpsSerial.write(UBX_BACKUP, sizeof(UBX_BACKUP));
    gpsSerial.flush();
    Serial.println("[GPS] Entered power saving mode.");
}

// Pull TX pin LOW to create a falling edge on the module's RX line,
// waking it from backup / power saving mode. Harmless on cold boot (seen as a UART
// break condition, discarded by the receiver).
static void gps_exit_powersaving_mode(int tx_pin) {
    Serial.println("[GPS] Exit power saving mode.");
    pinMode(tx_pin, OUTPUT);
    digitalWrite(tx_pin, HIGH);
    delay(10);
    digitalWrite(tx_pin, LOW);
    delay(200);
    digitalWrite(tx_pin, HIGH);
    delay(100);
}
