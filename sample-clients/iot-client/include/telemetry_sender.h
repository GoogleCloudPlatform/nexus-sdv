#ifndef TELEMETRY_SENDER_H
#define TELEMETRY_SENDER_H

#include <stdbool.h>
#include "nats_client.h"

// Build and publish a telemetry message via NATS.
// Sends sample sensor readings (time_passed, index, test_key) matching the Python client.
// index: message sequence number
// interval_sec: telemetry interval in seconds (used for time_passed calculation)
bool telemetry_send_message(NatsClient *nc, const char *vin,
                            const char *prefix, int index, int interval_sec);

#endif
