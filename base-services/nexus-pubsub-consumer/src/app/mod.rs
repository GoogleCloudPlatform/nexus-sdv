//! What happens with a decoded message. In Increment 1.2: it is logged.
//!
//! This unit knows nothing about NATS or protobuf wire format — it receives
//! typed messages. Keeping that boundary is what lets Increment 3 lift the
//! transport out as an SDK.

use crate::config::LogDetail;
use crate::transport::decode::telemetry::TelemetryMessage;

/// Strings that came from a vehicle are logged with `?`, which escapes control characters:
/// a producer that puts a newline into a sensor name must not be able to write a line of
/// its own into the log.
pub fn log_message(msg: &TelemetryMessage, detail: LogDetail) {
    tracing::info!(
        message_id = ?msg.message_id,
        schema_version = msg.schema_version,
        device_id = ?detail.id(&msg.device_id),
        readings = msg.sensor_data.len(),
        "telemetry received"
    );
    for r in &msg.sensor_data {
        let ts = r
            .timestamp
            .as_ref()
            .map(|t| format!("{}.{:09}", t.seconds, t.nanos))
            .unwrap_or_else(|| "<none>".into());
        match detail {
            LogDetail::Full => tracing::info!(
                sensor = ?r.sensor,
                value = ?r.value,
                data_type = r.data_type,
                timestamp = %ts,
                "  reading"
            ),
            // The value is left out: it is whatever the producer chose to send.
            LogDetail::Masked => tracing::info!(
                sensor = ?r.sensor,
                value_bytes = r.value.len(),
                data_type = r.data_type,
                timestamp = %ts,
                "  reading"
            ),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transport::decode::telemetry::SensorReading;
    use std::io::Write;
    use std::sync::{Arc, Mutex};

    #[derive(Clone, Default)]
    struct Captured(Arc<Mutex<Vec<u8>>>);

    impl Write for Captured {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(buf);
            Ok(buf.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for Captured {
        type Writer = Captured;
        fn make_writer(&'a self) -> Captured {
            self.clone()
        }
    }

    fn logged(msg: &TelemetryMessage, detail: LogDetail) -> String {
        let out = Captured::default();
        let subscriber = tracing_subscriber::fmt()
            .with_writer(out.clone())
            .with_ansi(false)
            .with_target(false)
            .finish();
        tracing::subscriber::with_default(subscriber, || log_message(msg, detail));
        let bytes = out.0.lock().unwrap().clone();
        String::from_utf8(bytes).unwrap()
    }

    fn message(device_id: &str, sensor: &str, value: &str) -> TelemetryMessage {
        TelemetryMessage {
            message_id: "m-1".into(),
            schema_version: 1,
            device_id: device_id.into(),
            sensor_data: vec![SensorReading {
                sensor: sensor.into(),
                value: value.into(),
                data_type: 1,
                timestamp: Some(Default::default()),
            }],
        }
    }

    #[test]
    fn masked_logs_neither_the_vin_nor_the_value() {
        let out = logged(&message("WBA12345678901234", "position", "52.5200,13.4050"), LogDetail::Masked);
        assert!(out.contains("***1234"), "{out}");
        assert!(out.contains(r#"sensor="position""#), "{out}");
        assert!(out.contains("value_bytes=15"), "{out}");
        assert!(!out.contains("WBA12345678901234"), "the VIN reached the log: {out}");
        assert!(!out.contains("52.5200"), "a value reached the log: {out}");
    }

    #[test]
    fn full_logs_every_field_as_before() {
        let out = logged(&message("APEXCAR01", "tire_pressure", "220"), LogDetail::Full);
        assert!(out.contains(r#"device_id="APEXCAR01""#), "{out}");
        assert!(out.contains(r#"sensor="tire_pressure""#), "{out}");
        assert!(out.contains(r#"value="220""#), "{out}");
    }

    #[test]
    fn a_newline_from_a_producer_cannot_start_a_log_line() {
        for detail in [LogDetail::Full, LogDetail::Masked] {
            let out = logged(
                &message("V\n2026-01-01T00:00:00Z  INFO forged", "s\r\nINFO forged", "v\nINFO forged"),
                detail,
            );
            assert_eq!(out.lines().count(), 2, "{detail:?}: one line per event, not more: {out}");
            assert!(!out.contains('\r'), "{detail:?}: {out}");
        }
    }
}
