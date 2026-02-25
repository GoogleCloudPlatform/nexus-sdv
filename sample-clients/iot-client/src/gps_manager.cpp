#include "gps_manager.h"
#include <Arduino.h>
#include <TinyGPSPlus.h>
#include <HardwareSerial.h>

static TinyGPSPlus gps;
static HardwareSerial gpsSerial(2);

void gps_init(int rx_pin, int tx_pin) {
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
