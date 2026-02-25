#ifndef TELEMETRY_SENDER_H
#define TELEMETRY_SENDER_H

#include <stdbool.h>
#include "nats_client.h"
#include "gps_manager.h"

// Build and publish a telemetry message via NATS.
// Includes base sensor readings (time_passed, index, test_key).
// If gps is non-NULL and gps->valid, appends gps.latitude, gps.longitude, gps.altitude.
bool telemetry_send_message(NatsClient *nc, const char *vin,
                            const char *prefix, int index, int interval_sec,
                            const GpsData *gps);

#endif
