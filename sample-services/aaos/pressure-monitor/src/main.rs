//! The reference service for both directions of one domain: it registers `pressure` and
//! logs each reading decoded, and registers `pressure-limit` and sends a limit to a vehicle
//! when asked over REST. Cluster-internal, no authentication — see Plan B ruling 7.

use std::sync::Arc;

use async_trait::async_trait;
use axum::body::Bytes;
use axum::extract::State;
use axum::http::StatusCode;
use axum::routing::{get, post};
use axum::{Json, Router};
use nexus_aaos_sdk::{CloudService, Config, Delivery, Direction, Error, mask, valid_vin};
use nexus_sample_messages::quickstart::TirePressure;
use nexus_sample_messages::sample::PressureLimit;
use prost::Message;
use serde::Deserialize;
use serde_json::{Value, json};

const NAME: &str = "pressure-monitor";
const TOPIC: &str = "pressure";
/// The registry keys a registration by name, one topic each; the second topic gets a name
/// of its own.
const LIMIT_NAME: &str = "pressure-monitor-limit";
const LIMIT_TOPIC: &str = "pressure-limit";

/// `TirePressure` from Google's quickstart catalog, the type generated from its `.proto`
/// (nexus-sample-messages). Unknown fields are skipped; a cut-off message is an error.
fn decode_pressure(bytes: &[u8]) -> Result<u32, String> {
    TirePressure::decode(bytes).map(|m| m.pressure).map_err(|e| e.to_string())
}

/// `PressureLimit` from our catalog, aaos/nexus-sdv-sample/catalog/nexus_sample.proto.
fn encode_limit(max_pressure: u32) -> Vec<u8> {
    PressureLimit { max_pressure }.encode_to_vec()
}

/// A VIN as it is logged: masked unless `LOG_DETAIL=full`.
fn shown(vin: &str, full: bool) -> String {
    if full { vin.to_string() } else { mask(vin) }
}

fn describe(delivery: &Delivery, full: bool) -> String {
    let vin = shown(&delivery.vin, full);
    match decode_pressure(&delivery.payload) {
        Ok(p) => format!("pressure received vin={vin} pressure={p}"),
        Err(e) => format!("pressure received vin={vin} undecodable bytes={}: {e}", delivery.payload.len()),
    }
}

/// The one thing the HTTP side needs from NATS, so the tests need no hub.
#[async_trait]
trait Publisher: Send + Sync {
    async fn publish(&self, vin: &str, payload: Bytes) -> Result<(), Error>;
}

struct Nexus(Arc<CloudService>);

#[async_trait]
impl Publisher for Nexus {
    async fn publish(&self, vin: &str, payload: Bytes) -> Result<(), Error> {
        self.0.publish(vin, LIMIT_TOPIC, payload).await
    }
}

/// The VIN travels in the body, never in the URI. `u32` makes serde refuse negative,
/// fractional, too large and quoted numbers.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Limit {
    vin: String,
    max_pressure: u32,
}

#[derive(Clone)]
struct AppState {
    publisher: Arc<dyn Publisher>,
    full: bool,
}

fn router(state: AppState) -> Router {
    Router::new()
        .route("/health", get(|| async { "ok" }))
        .route("/v1/pressure-limit", post(send))
        .with_state(state)
}

fn refuse(message: &str) -> (StatusCode, Json<Value>) {
    (StatusCode::BAD_REQUEST, Json(json!({ "error": message })))
}

async fn send(State(state): State<AppState>, body: Bytes) -> (StatusCode, Json<Value>) {
    let Ok(limit) = serde_json::from_slice::<Limit>(&body) else {
        return refuse("the body must be {vin, max_pressure} with max_pressure an unsigned 32-bit integer");
    };
    if !valid_vin(&limit.vin) {
        return refuse("vin must match [A-Z0-9]{1,17}");
    }
    let payload = Bytes::from(encode_limit(limit.max_pressure));
    match state.publisher.publish(&limit.vin, payload).await {
        Ok(()) => {
            tracing::info!(vin = %shown(&limit.vin, state.full), max_pressure = limit.max_pressure, "limit sent");
            (StatusCode::ACCEPTED, Json(json!({ "status": "sent" })))
        }
        Err(e) => {
            tracing::error!(vin = %shown(&limit.vin, state.full), error = %e, "limit not sent");
            (StatusCode::SERVICE_UNAVAILABLE, Json(json!({ "error": "the hub did not take the limit" })))
        }
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt().init();
    let full = std::env::var("LOG_DETAIL").is_ok_and(|v| v == "full");
    let service = Arc::new(CloudService::connect(Config::from_env()?).await?);
    service.register(NAME, TOPIC, Direction::VehicleToCloud).await?;
    service.register(LIMIT_NAME, LIMIT_TOPIC, Direction::CloudToVehicle).await?;
    tracing::info!("registered {NAME} for {TOPIC} and {LIMIT_NAME} for {LIMIT_TOPIC}");

    let listener = tokio::net::TcpListener::bind("0.0.0.0:8080").await?;
    let state = AppState { publisher: Arc::new(Nexus(service.clone())), full };
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    tokio::select! {
        ended = service.subscribe(TOPIC, |d| tracing::info!("{}", describe(&d, full))) => ended?,
        served = axum::serve(listener, router(state)) => served?,
        _ = terminate.recv() => {}
        _ = tokio::signal::ctrl_c() => {}
    }
    // No deregistration: the registrations expire with their lease (spec section 4, "Lease").
    tracing::info!("stopping {NAME}; its registrations expire unless renewed");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::Request;
    use http_body_util::BodyExt;
    use std::sync::Mutex;
    use tower::ServiceExt;

    // Vectors from `protoc --encode` with Google's quickstart tire.proto and our catalog's
    // nexus_sample.proto (aaos/nexus-sdv-sample/catalog on the 365 branch).
    #[test]
    fn tire_pressure_is_decoded() {
        assert_eq!(decode_pressure(&[]), Ok(0), "proto3: an absent field is 0");
        assert_eq!(decode_pressure(&[0x08, 0x20]), Ok(32));
        assert_eq!(decode_pressure(&[0x08, 0xf0, 0x01]), Ok(240));
    }

    #[test]
    fn an_unknown_field_is_skipped() {
        assert_eq!(decode_pressure(&[0x1a, 0x02, b'a', b'b', 0x08, 0x20]), Ok(32));
    }

    #[test]
    fn a_cut_off_message_is_an_error() {
        assert!(decode_pressure(&[0x08]).is_err());
        assert!(decode_pressure(&[0x08, 0x80]).is_err());
    }

    #[test]
    fn a_length_beyond_the_message_is_an_error() {
        // Field 3, length-delimited, length 2^64 - 1: must not wrap the position around.
        let mut bytes = vec![0x1a];
        bytes.extend([0xff; 9]);
        bytes.push(0x01);
        assert!(decode_pressure(&bytes).is_err());
    }

    #[test]
    fn a_limit_is_encoded_as_the_catalog_says() {
        assert_eq!(encode_limit(250), vec![0x08, 0xfa, 0x01]);
        assert_eq!(encode_limit(123456), vec![0x08, 0xc0, 0xc4, 0x07]);
    }

    #[test]
    fn a_reading_is_logged_with_its_value_and_the_vin_masked() {
        let d = Delivery { vin: "PKG11MESH01".into(), topic: "pressure".into(), payload: Bytes::from_static(&[0x08, 0xf0, 0x01]) };
        assert_eq!(describe(&d, false), "pressure received vin=***SH01 pressure=240");
        assert_eq!(describe(&d, true), "pressure received vin=PKG11MESH01 pressure=240");
    }

    #[test]
    fn an_undecodable_reading_is_logged_by_size() {
        let d = Delivery { vin: "PKG11MESH01".into(), topic: "pressure".into(), payload: Bytes::from_static(&[0x08]) };
        assert!(describe(&d, false).starts_with("pressure received vin=***SH01 undecodable bytes=1"));
    }

    #[derive(Default)]
    struct Recording {
        sent: Mutex<Vec<(String, Bytes)>>,
    }
    #[async_trait]
    impl Publisher for Recording {
        async fn publish(&self, vin: &str, payload: Bytes) -> Result<(), Error> {
            self.sent.lock().unwrap().push((vin.to_string(), payload));
            Ok(())
        }
    }

    async fn post_limit(publisher: Arc<dyn Publisher>, body: String) -> StatusCode {
        let request = Request::builder()
            .method("POST")
            .uri("/v1/pressure-limit")
            .header("content-type", "application/json")
            .body(Body::from(body))
            .unwrap();
        let response = router(AppState { publisher, full: false }).oneshot(request).await.unwrap();
        let status = response.status();
        let _ = response.into_body().collect().await.unwrap();
        status
    }

    #[tokio::test]
    async fn a_valid_limit_is_published_encoded_and_answered_202() {
        let recording = Arc::new(Recording::default());
        let status = post_limit(recording.clone(), json!({"vin": "PKG11MESH01", "max_pressure": 250}).to_string()).await;
        assert_eq!(status, StatusCode::ACCEPTED);
        assert_eq!(*recording.sent.lock().unwrap(), vec![("PKG11MESH01".to_string(), Bytes::from_static(&[0x08, 0xfa, 0x01]))]);
    }

    #[tokio::test]
    async fn every_rejected_limit_is_answered_400_and_publishes_nothing() {
        let rejected = [
            ("not JSON", "vin=PKG11MESH01".to_string()),
            ("lower-case VIN", json!({"vin": "pkg11mesh01", "max_pressure": 250}).to_string()),
            ("wildcard VIN", json!({"vin": ">", "max_pressure": 250}).to_string()),
            ("negative", json!({"vin": "PKG11MESH01", "max_pressure": -1}).to_string()),
            ("beyond 32 bits", json!({"vin": "PKG11MESH01", "max_pressure": 4294967296u64}).to_string()),
            ("fraction", json!({"vin": "PKG11MESH01", "max_pressure": 2.5}).to_string()),
            ("string", json!({"vin": "PKG11MESH01", "max_pressure": "250"}).to_string()),
            ("missing", json!({"vin": "PKG11MESH01"}).to_string()),
            ("unknown field", json!({"vin": "PKG11MESH01", "max_pressure": 250, "unit": "kPa"}).to_string()),
        ];
        for (case, body) in rejected {
            let recording = Arc::new(Recording::default());
            assert_eq!(post_limit(recording.clone(), body).await, StatusCode::BAD_REQUEST, "{case}");
            assert!(recording.sent.lock().unwrap().is_empty(), "{case}");
        }
    }
}
