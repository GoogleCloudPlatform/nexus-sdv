use std::sync::Arc;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use nexus_registry::api::router;
use nexus_registry::grant::Grant;
use nexus_registry::registry::{Notifier, Registry};
use nexus_registry::store::MemoryStore;
use serde_json::{Value, json};
use tower::ServiceExt;

struct Silent;
#[async_trait::async_trait]
impl Notifier for Silent {
    async fn grant_changed(&self, _: &str, _: &Grant) -> anyhow::Result<()> {
        Ok(())
    }
}

fn app() -> axum::Router {
    router(Arc::new(Registry::new(Arc::new(MemoryStore::default()), Arc::new(Silent))))
}

async fn call(app: &axum::Router, method: &str, uri: &str, body: String) -> (StatusCode, String) {
    let request = Request::builder()
        .method(method)
        .uri(uri)
        .header("content-type", "application/json")
        .body(Body::from(body))
        .unwrap();
    let response = app.clone().oneshot(request).await.unwrap();
    let status = response.status();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    (status, String::from_utf8(bytes.to_vec()).unwrap())
}

fn body(name: &str, topic: &str, pattern: &str, direction: &str) -> String {
    json!({"name": name, "topic": topic, "pattern": pattern, "direction": direction}).to_string()
}

async fn listed(app: &axum::Router) -> Vec<Value> {
    let (status, text) = call(app, "GET", "/v1/services", String::new()).await;
    assert_eq!(status, StatusCode::OK);
    serde_json::from_str(&text).unwrap()
}

#[tokio::test]
async fn every_accepted_body_is_answered_201() {
    let app = app();
    for (name, topic, direction) in [("pressure-monitor", "pressure", "vehicle-to-cloud"), ("door-control", "command", "cloud-to-vehicle")] {
        let (status, text) = call(&app, "POST", "/v1/services", body(name, topic, "pubsub", direction)).await;
        assert_eq!(status, StatusCode::CREATED, "{name}: {text}");
    }
    assert_eq!(listed(&app).await.len(), 2);
}

#[tokio::test]
async fn every_rejected_body_is_answered_400_and_changes_nothing() {
    let app = app();
    let long = "a".repeat(65);
    let rejected: Vec<(&str, String)> = vec![
        ("not JSON", "name=pressure-monitor".into()),
        ("empty object", "{}".into()),
        ("missing direction", json!({"name": "a", "topic": "pressure", "pattern": "pubsub"}).to_string()),
        ("upper-case topic", body("a", "Pressure", "pubsub", "vehicle-to-cloud")),
        ("dot in topic", body("a", "pressure.left", "pubsub", "vehicle-to-cloud")),
        ("wildcard topic", body("a", ">", "pubsub", "vehicle-to-cloud")),
        ("topic of 65 characters", body("a", &long, "pubsub", "vehicle-to-cloud")),
        ("empty name", body("", "pressure", "pubsub", "vehicle-to-cloud")),
        ("dot in name", body("a.b", "pressure", "pubsub", "vehicle-to-cloud")),
        ("pattern rpc", body("a", "pressure", "rpc", "vehicle-to-cloud")),
        ("unknown direction", body("a", "pressure", "pubsub", "sideways")),
        ("a VIN smuggled in", json!({"name": "a", "topic": "pressure", "pattern": "pubsub", "direction": "vehicle-to-cloud", "vin": "WBA123"}).to_string()),
        ("topic not a string", json!({"name": "a", "topic": 42, "pattern": "pubsub", "direction": "vehicle-to-cloud"}).to_string()),
    ];
    for (case, b) in rejected {
        let (status, text) = call(&app, "POST", "/v1/services", b).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{case}: {text}");
        assert!(text.contains("\"error\""), "{case}: {text}");
    }
    assert!(listed(&app).await.is_empty());
}

#[tokio::test]
async fn a_registered_service_can_be_deleted_once() {
    let app = app();
    call(&app, "POST", "/v1/services", body("pressure-monitor", "pressure", "pubsub", "vehicle-to-cloud")).await;
    let (status, _) = call(&app, "DELETE", "/v1/services/pressure-monitor", String::new()).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (status, _) = call(&app, "DELETE", "/v1/services/pressure-monitor", String::new()).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(listed(&app).await.is_empty());
}

#[tokio::test]
async fn deleting_an_invalid_name_is_answered_400() {
    let (status, _) = call(&app(), "DELETE", "/v1/services/Pressure", String::new()).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn health_answers_200() {
    let (status, _) = call(&app(), "GET", "/health", String::new()).await;
    assert_eq!(status, StatusCode::OK);
}
