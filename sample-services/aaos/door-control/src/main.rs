//! The reference service for cloud-to-vehicle: registers `door-command`, sends one DoorCommand per
//! request. Cluster-internal, no authentication — see Plan B ruling 7.

use std::sync::Arc;

use async_trait::async_trait;
use axum::body::Bytes;
use axum::extract::State;
use axum::http::StatusCode;
use axum::routing::{get, post};
use axum::{Json, Router};
use nexus_aaos_sdk::{CloudService, Config, Direction, Error, mask, valid_vin};
use nexus_sample_messages::sample::{DoorCommand, door_command::Action};
use prost::Message;
use serde::Deserialize;
use serde_json::{Value, json};

const NAME: &str = "door-control";
const TOPIC: &str = "door-command";

/// The one thing the HTTP side needs from NATS, so the tests need no hub.
#[async_trait]
trait Publisher: Send + Sync {
    async fn publish(&self, vin: &str, payload: Bytes) -> Result<(), Error>;
}

struct Nexus(Arc<CloudService>);

#[async_trait]
impl Publisher for Nexus {
    async fn publish(&self, vin: &str, payload: Bytes) -> Result<(), Error> {
        self.0.publish(vin, TOPIC, payload).await
    }
}

/// The VIN travels in the body, never in the URI.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Command {
    vin: String,
    action: String,
}

/// `DoorCommand` from our catalog, aaos/nexus-sdv-sample/catalog/nexus_sample.proto — the
/// type generated from that file (nexus-sample-messages), not bytes written by hand.
fn encode_command(action: &str) -> Option<Vec<u8>> {
    let action = match action {
        "lock" => Action::Lock,
        "unlock" => Action::Unlock,
        _ => return None,
    };
    Some(DoorCommand { action: action as i32 }.encode_to_vec())
}

/// The router's state: the publishing seam plus whether a VIN is logged whole.
#[derive(Clone)]
struct AppState {
    publisher: Arc<dyn Publisher>,
    full: bool,
}

/// A VIN as it is logged: masked unless `LOG_DETAIL=full`, matching pressure-monitor.
fn shown(vin: &str, full: bool) -> String {
    if full { vin.to_string() } else { mask(vin) }
}

fn router(state: AppState) -> Router {
    Router::new()
        .route("/health", get(|| async { "ok" }))
        .route("/v1/commands", post(send))
        .with_state(state)
}

fn refuse(message: &str) -> (StatusCode, Json<Value>) {
    (StatusCode::BAD_REQUEST, Json(json!({ "error": message })))
}

async fn send(State(state): State<AppState>, body: Bytes) -> (StatusCode, Json<Value>) {
    let Ok(command) = serde_json::from_slice::<Command>(&body) else {
        return refuse("the body must be {vin, action} and nothing else");
    };
    if !valid_vin(&command.vin) {
        return refuse("vin must match [A-Z0-9]{1,17}");
    }
    let Some(payload) = encode_command(&command.action) else {
        return refuse("action must be lock or unlock");
    };
    match state.publisher.publish(&command.vin, Bytes::from(payload)).await {
        Ok(()) => {
            tracing::info!(vin = %shown(&command.vin, state.full), action = %command.action, "command sent");
            (StatusCode::ACCEPTED, Json(json!({ "status": "sent" })))
        }
        Err(e) => {
            tracing::error!(vin = %shown(&command.vin, state.full), error = %e, "command not sent");
            (StatusCode::SERVICE_UNAVAILABLE, Json(json!({ "error": "the hub did not take the command" })))
        }
    }
}

async fn shutdown() {
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        .expect("a SIGTERM handler");
    tokio::select! {
        _ = terminate.recv() => {}
        _ = tokio::signal::ctrl_c() => {}
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt().init();
    let full = std::env::var("LOG_DETAIL").is_ok_and(|v| v == "full");
    let service = Arc::new(CloudService::connect(Config::from_env()?).await?);
    service.register(NAME, TOPIC, Direction::CloudToVehicle).await?;
    tracing::info!("registered {NAME} for {TOPIC}, cloud-to-vehicle");
    let listener = tokio::net::TcpListener::bind("0.0.0.0:8080").await?;
    let state = AppState { publisher: Arc::new(Nexus(service.clone())), full };
    axum::serve(listener, router(state))
        .with_graceful_shutdown(shutdown())
        .await?;
    // No deregistration: the registration expires with its lease (spec section 4, "Lease").
    tracing::info!("stopping {NAME}; its registration expires unless renewed");
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

    struct Failing;
    #[async_trait]
    impl Publisher for Failing {
        async fn publish(&self, _: &str, _: Bytes) -> Result<(), Error> {
            Err(Error::Nats("no hub".into()))
        }
    }

    async fn post_command(publisher: Arc<dyn Publisher>, body: String) -> StatusCode {
        let request = Request::builder()
            .method("POST")
            .uri("/v1/commands")
            .header("content-type", "application/json")
            .body(Body::from(body))
            .unwrap();
        let response = router(AppState { publisher, full: false }).oneshot(request).await.unwrap();
        let status = response.status();
        let _ = response.into_body().collect().await.unwrap();
        status
    }

    #[tokio::test]
    async fn lock_is_published_as_a_door_command_and_answered_202() {
        let recording = Arc::new(Recording::default());
        let status = post_command(recording.clone(), json!({"vin": "PKG11MESH01", "action": "lock"}).to_string()).await;
        assert_eq!(status, StatusCode::ACCEPTED);
        assert_eq!(*recording.sent.lock().unwrap(), vec![("PKG11MESH01".to_string(), Bytes::from_static(&[0x08, 0x01]))]);
    }

    #[tokio::test]
    async fn unlock_is_published_as_a_door_command_and_answered_202() {
        let recording = Arc::new(Recording::default());
        let status = post_command(recording.clone(), json!({"vin": "PKG11MESH01", "action": "unlock"}).to_string()).await;
        assert_eq!(status, StatusCode::ACCEPTED);
        assert_eq!(*recording.sent.lock().unwrap(), vec![("PKG11MESH01".to_string(), Bytes::from_static(&[0x08, 0x02]))]);
    }

    #[tokio::test]
    async fn every_rejected_command_is_answered_400_and_publishes_nothing() {
        let rejected = [
            ("not JSON", "vin=PKG11MESH01".to_string()),
            ("lower-case VIN", json!({"vin": "pkg11mesh01", "action": "lock"}).to_string()),
            ("wildcard VIN", json!({"vin": ">", "action": "lock"}).to_string()),
            ("dot in VIN", json!({"vin": "PKG.1", "action": "lock"}).to_string()),
            ("upper-case action", json!({"vin": "PKG11MESH01", "action": "LOCK"}).to_string()),
            ("unknown action", json!({"vin": "PKG11MESH01", "action": "open"}).to_string()),
            ("empty action", json!({"vin": "PKG11MESH01", "action": ""}).to_string()),
            ("missing action", json!({"vin": "PKG11MESH01"}).to_string()),
            ("unknown field", json!({"vin": "PKG11MESH01", "action": "lock", "payload": "x"}).to_string()),
        ];
        for (case, body) in rejected {
            let recording = Arc::new(Recording::default());
            assert_eq!(post_command(recording.clone(), body).await, StatusCode::BAD_REQUEST, "{case}");
            assert!(recording.sent.lock().unwrap().is_empty(), "{case}");
        }
    }

    #[tokio::test]
    async fn a_hub_that_refuses_is_answered_503() {
        let status = post_command(Arc::new(Failing), json!({"vin": "PKG11MESH01", "action": "lock"}).to_string()).await;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    }

    #[test]
    fn a_vin_is_shown_masked_unless_full() {
        assert_eq!(shown("PKG11MESH01", false), "***SH01");
        assert_eq!(shown("PKG11MESH01", true), "PKG11MESH01");
    }
}
