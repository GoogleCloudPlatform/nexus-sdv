#ifndef GPS_MANAGER_H
#define GPS_MANAGER_H

#include <stdbool.h>

struct GpsData {
    bool valid;        // true if location fix is available
    double latitude;
    double longitude;
    double altitude;   // meters
};

// Initialize GPS on UART2 at 9600 baud.
void gps_init(int rx_pin, int tx_pin);

// Feed available bytes from UART2 into the NMEA parser. Call every loop().
void gps_feed();

// Return a snapshot of the current GPS state.
GpsData gps_get_data();

#endif
