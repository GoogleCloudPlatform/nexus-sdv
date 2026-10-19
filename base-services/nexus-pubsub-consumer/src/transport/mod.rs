pub mod decode;

use crate::config::{Config, LogDetail};
use decode::telemetry::TelemetryMessage;
use futures::StreamExt;

/// `pubsub.<vin>.<topic>` → `<vin>`.
fn subject_vin(subject: &str) -> Option<&str> {
    let mut tokens = subject.split('.');
    if tokens.next()? != "pubsub" {
        return None;
    }
    let vin = tokens.next().filter(|v| !v.is_empty())?;
    tokens.next()?; // a topic must follow
    Some(vin)
}

/// The subject as it may be logged: its VIN token masked the same way as everywhere else.
fn subject_for_log(subject: &str, detail: LogDetail) -> String {
    match subject_vin(subject) {
        Some(vin) => {
            let topic = subject.splitn(3, '.').nth(2).unwrap_or("");
            format!("pubsub.{}.{topic}", detail.id(vin))
        }
        None => "<not a pubsub subject>".to_string(),
    }
}

/// Subscribes and hands the application decoded messages. The application never
/// sees NATS or protobuf — that boundary is the one an SDK draws.
pub async fn run(cfg: &Config, mut handler: impl FnMut(&TelemetryMessage)) -> Result<(), String> {
    let client = async_nats::ConnectOptions::with_user_and_password(
        cfg.nats_user.clone(),
        cfg.nats_password.clone(),
    )
    .name("nexus-pubsub-consumer")
    .connect(&cfg.nats_url)
    .await
    .map_err(|e| format!("cannot connect to {}: {e}", cfg.nats_url))?;

    let mut sub = client
        .subscribe(cfg.subject.clone())
        .await
        .map_err(|e| format!("cannot subscribe to {}: {e}", cfg.subject))?;
    tracing::info!(subject = %cfg.subject, url = %cfg.nats_url, "subscribed");

    while let Some(msg) = sub.next().await {
        match decode::decode(&msg.payload) {
            Ok(decoded) => {
                // `device_id` is the vehicle's row key downstream, and the subject is what
                // the hub's per-vehicle permission actually vouches for. A message whose
                // device_id names another vehicle would be filed under the wrong car.
                if subject_vin(&msg.subject) != Some(decoded.device_id.as_str()) {
                    tracing::warn!(
                        subject = ?subject_for_log(&msg.subject, cfg.log_detail),
                        "device_id does not match the vehicle in the subject, skipping"
                    );
                    continue;
                }
                handler(&decoded)
            }
            // A bad message must not end the subscription — log it and keep going.
            Err(e) => tracing::warn!(subject = ?subject_for_log(&msg.subject, cfg.log_detail),
                                     len = msg.payload.len(), error = ?e,
                                     "undecodable message, skipping"),
        }
    }
    Err("subscription ended".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_vin_is_the_second_token_of_a_pubsub_subject() {
        assert_eq!(subject_vin("pubsub.APEXCAR01.tire-pressure"), Some("APEXCAR01"));
        assert_eq!(subject_vin("pubsub.APEXCAR01.a.b"), Some("APEXCAR01"));
    }

    #[test]
    fn anything_else_has_no_vin() {
        for s in ["", "pubsub", "pubsub.", "pubsub.V", "pubsub..t", "telemetry.V.t", "registry.V.grant"] {
            assert_eq!(subject_vin(s), None, "{s:?}");
        }
    }

    #[test]
    fn a_subject_is_logged_with_its_vin_masked() {
        assert_eq!(
            subject_for_log("pubsub.WBA12345678901234.pressure", LogDetail::Masked),
            "pubsub.***1234.pressure"
        );
        assert_eq!(
            subject_for_log("pubsub.WBA12345678901234.a.b", LogDetail::Masked),
            "pubsub.***1234.a.b"
        );
        assert_eq!(subject_for_log("pubsub.APEXCAR01.t", LogDetail::Full), "pubsub.APEXCAR01.t");
        assert_eq!(subject_for_log("garbage", LogDetail::Masked), "<not a pubsub subject>");
    }
}
