#include "telemetry_sender.h"
#include "config.h"
#include "uuid_gen.h"
#include <Arduino.h>
#include <sys/time.h>
#include <pb_encode.h>
#include "telemetry.pb.h"

bool telemetry_send_message(NatsClient *nc, const char *vin, const char *prefix, int index, int interval_sec, const GpsData *gps) {

    telemetry_TelemetryMessage msg = telemetry_TelemetryMessage_init_zero;

    // Message ID (UUID v4)
    uuid_v4(msg.message_id, sizeof(msg.message_id));

    // Schema version
    msg.schema_version = SCHEMA_VERSION;

    // Device ID
    strncpy(msg.device_id, vin, sizeof(msg.device_id) - 1);

    // Get current time
    struct timeval tv;
    gettimeofday(&tv, NULL);

    int idx = 0;

    // Reading 1: time_passed (DYNAMIC)
    msg.sensor_data[idx].has_timestamp = true;
    msg.sensor_data[idx].timestamp.seconds = (int64_t)tv.tv_sec;
    msg.sensor_data[idx].timestamp.nanos = (int32_t)(tv.tv_usec * 1000);
    snprintf(msg.sensor_data[idx].value, sizeof(msg.sensor_data[idx].value), "%d seconds", index * interval_sec);
    msg.sensor_data[idx].data_type = telemetry_DataType_DYNAMIC;
    strncpy(msg.sensor_data[idx].sensor, "time_passed", sizeof(msg.sensor_data[idx].sensor) - 1);
    idx++;

    // Reading 2: index (STATIC)
    msg.sensor_data[idx].has_timestamp = true;
    msg.sensor_data[idx].timestamp.seconds = (int64_t)tv.tv_sec;
    msg.sensor_data[idx].timestamp.nanos = (int32_t)(tv.tv_usec * 1000);
    snprintf(msg.sensor_data[idx].value, sizeof(msg.sensor_data[idx].value), "%d", index);
    msg.sensor_data[idx].data_type = telemetry_DataType_STATIC;
    strncpy(msg.sensor_data[idx].sensor, "index", sizeof(msg.sensor_data[idx].sensor) - 1);
    idx++;

    // Reading 3: test_key (STATIC)
    msg.sensor_data[idx].has_timestamp = true;
    msg.sensor_data[idx].timestamp.seconds = (int64_t)tv.tv_sec;
    msg.sensor_data[idx].timestamp.nanos = (int32_t)(tv.tv_usec * 1000);
    strncpy(msg.sensor_data[idx].value, "test_value", sizeof(msg.sensor_data[idx].value) - 1);
    msg.sensor_data[idx].data_type = telemetry_DataType_STATIC;
    strncpy(msg.sensor_data[idx].sensor, "test_key", sizeof(msg.sensor_data[idx].sensor) - 1);
    idx++;

    // GPS readings (only when fix is available)
    if (gps && gps->valid) {
        msg.sensor_data[idx].has_timestamp = true;
        msg.sensor_data[idx].timestamp.seconds = (int64_t)tv.tv_sec;
        msg.sensor_data[idx].timestamp.nanos = (int32_t)(tv.tv_usec * 1000);
        snprintf(msg.sensor_data[idx].value, sizeof(msg.sensor_data[idx].value), "%.6f", gps->latitude);
        msg.sensor_data[idx].data_type = telemetry_DataType_DYNAMIC;
        strncpy(msg.sensor_data[idx].sensor, "gps.latitude", sizeof(msg.sensor_data[idx].sensor) - 1);
        idx++;

        msg.sensor_data[idx].has_timestamp = true;
        msg.sensor_data[idx].timestamp.seconds = (int64_t)tv.tv_sec;
        msg.sensor_data[idx].timestamp.nanos = (int32_t)(tv.tv_usec * 1000);
        snprintf(msg.sensor_data[idx].value, sizeof(msg.sensor_data[idx].value), "%.6f", gps->longitude);
        msg.sensor_data[idx].data_type = telemetry_DataType_DYNAMIC;
        strncpy(msg.sensor_data[idx].sensor, "gps.longitude", sizeof(msg.sensor_data[idx].sensor) - 1);
        idx++;

        msg.sensor_data[idx].has_timestamp = true;
        msg.sensor_data[idx].timestamp.seconds = (int64_t)tv.tv_sec;
        msg.sensor_data[idx].timestamp.nanos = (int32_t)(tv.tv_usec * 1000);
        snprintf(msg.sensor_data[idx].value, sizeof(msg.sensor_data[idx].value), "%.2f", gps->altitude);
        msg.sensor_data[idx].data_type = telemetry_DataType_DYNAMIC;
        strncpy(msg.sensor_data[idx].sensor, "gps.altitude", sizeof(msg.sensor_data[idx].sensor) - 1);
        idx++;

        Serial.printf("[Telemetry] GPS: lat=%.6f lng=%.6f alt=%.2f\n", gps->latitude, gps->longitude, gps->altitude);
    }

    msg.sensor_data_count = idx;

    // Encode to protobuf binary
    uint8_t buffer[512];
    pb_ostream_t stream = pb_ostream_from_buffer(buffer, sizeof(buffer));
    if (!pb_encode(&stream, telemetry_TelemetryMessage_fields, &msg)) {
        Serial.printf("[Telemetry] Encode error: %s\n", PB_GET_ERROR(&stream));
        return false;
    }

    // Build NATS subject: telemetry.{prefix}.{vin}
    char subject[128];
    if (prefix && prefix[0] != '\0') {
        snprintf(subject, sizeof(subject), "telemetry.%s.%s", prefix, vin);
    } else {
        snprintf(subject, sizeof(subject), "telemetry.%s", vin);
    }

    bool ok = nats_publish(nc, subject, buffer, stream.bytes_written);
    if (ok) {
        Serial.printf("[Telemetry] Published %u bytes to %s (msg_id=%s)\n", (unsigned)stream.bytes_written, subject, msg.message_id);
    }
    return ok;
}
