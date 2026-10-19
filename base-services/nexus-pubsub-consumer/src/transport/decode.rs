//! Decoding the shared `telemetry.TelemetryMessage`.
//!
//! Unlike the vehicle-side Bridge, which forwards bytes opaquely by design, the
//! cloud side resolves every field — proving the payload survived the trip.

pub mod telemetry {
    include!(concat!(env!("OUT_DIR"), "/telemetry.rs"));
}

use prost::Message;
use telemetry::TelemetryMessage;

#[derive(Debug, PartialEq, Eq)]
pub enum DecodeError {
    /// The bytes are not a valid TelemetryMessage. Carries protobuf's reason.
    Malformed(String),
    /// Decoded, but carries no readings — nothing to report, and a strong hint
    /// that a producer built the message wrongly.
    NoReadings,
    /// A reading has no timestamp. Carries the offending sensor's name.
    /// The BigTable row key is device_id#timestamp, so this reading cannot be
    /// stored — it must be rejected rather than silently dropped downstream.
    MissingTimestamp(String),
}

pub fn decode(bytes: &[u8]) -> Result<TelemetryMessage, DecodeError> {
    let msg = TelemetryMessage::decode(bytes).map_err(|e| DecodeError::Malformed(e.to_string()))?;
    if msg.sensor_data.is_empty() {
        return Err(DecodeError::NoReadings);
    }
    if let Some(r) = msg.sensor_data.iter().find(|r| r.timestamp.is_none()) {
        return Err(DecodeError::MissingTimestamp(r.sensor.clone()));
    }
    Ok(msg)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Byte-for-byte what `aaos/nexus-sdv-sample/src/telemetry.rs` emits for
    /// device_id "APEXCAR01", value "220", sensor "tire_pressure", seconds
    /// 1789133942 — captured from the running vehicle, not hand-written here.
    const FROM_VEHICLE: &[u8] = &[
        0x0a, 0x0c, 0x6e, 0x65, 0x78, 0x75, 0x73, 0x2d, 0x73, 0x61, 0x6d, 0x70, 0x6c, 0x65, 0x18,
        0x01, 0x2a, 0x09, 0x41, 0x50, 0x45, 0x58, 0x43, 0x41, 0x52, 0x30, 0x31, 0x32, 0x1e, 0x0a,
        0x06, 0x08, 0xf6, 0x88, 0x90, 0xd5, 0x06, 0x12, 0x03, 0x32, 0x32, 0x30, 0x18, 0x01, 0x22,
        0x0d, 0x74, 0x69, 0x72, 0x65, 0x5f, 0x70, 0x72, 0x65, 0x73, 0x73, 0x75, 0x72, 0x65,
    ];

    #[test]
    fn decodes_every_field_of_a_real_vehicle_message() {
        let m = decode(FROM_VEHICLE).expect("decodes");
        assert_eq!(m.message_id, "nexus-sample");
        assert_eq!(m.schema_version, 1);
        assert_eq!(m.device_id, "APEXCAR01");
        assert_eq!(m.sensor_data.len(), 1);
        let r = &m.sensor_data[0];
        assert_eq!(r.sensor, "tire_pressure");
        assert_eq!(r.value, "220");
        assert_eq!(r.data_type, 1); // DYNAMIC
        assert_eq!(
            r.timestamp.as_ref().expect("timestamp present").seconds,
            1_789_133_942
        );
    }

    #[test]
    fn garbage_is_reported_not_panicked_on() {
        match decode(&[0xff, 0xff, 0xff, 0xff]) {
            Err(DecodeError::Malformed(m)) => assert!(!m.is_empty()),
            other => panic!("expected Malformed, got {other:?}"),
        }
    }

    #[test]
    fn a_truncated_message_is_malformed() {
        let short = &FROM_VEHICLE[..FROM_VEHICLE.len() - 5];
        assert!(matches!(decode(short), Err(DecodeError::Malformed(_))));
    }

    #[test]
    fn a_message_without_readings_is_rejected() {
        // A TelemetryMessage carrying only a device_id — decodes, but useless.
        let mut buf = Vec::new();
        TelemetryMessage {
            device_id: "APEXCAR01".into(),
            ..Default::default()
        }
        .encode(&mut buf)
        .unwrap();
        assert_eq!(decode(&buf), Err(DecodeError::NoReadings));
    }

    #[test]
    fn a_timestamp_is_required_for_the_cloud_row_key() {
        // The BigTable row key is device_id#timestamp; a reading without one was
        // the defect that silently dropped every sample message for a week.
        // Otherwise valid — only the timestamp is missing.
        let mut buf = Vec::new();
        TelemetryMessage {
            device_id: "APEXCAR01".into(),
            sensor_data: vec![telemetry::SensorReading {
                timestamp: None,
                value: "220".into(),
                data_type: 1, // DYNAMIC
                sensor: "tire_pressure".into(),
            }],
            ..Default::default()
        }
        .encode(&mut buf)
        .unwrap();
        assert_eq!(
            decode(&buf),
            Err(DecodeError::MissingTimestamp("tire_pressure".into()))
        );
    }
}
