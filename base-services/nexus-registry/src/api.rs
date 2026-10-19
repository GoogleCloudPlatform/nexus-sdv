//! The registry's REST interface: cluster-internal, no VIN in any URI (spec section 4).

use std::sync::Arc;

use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post};
use axum::{Json, Router};
use nexus_aaos_sdk::{Registration, valid_token};
use serde_json::json;

use crate::registry::Registry;

pub fn router(registry: Arc<Registry>) -> Router {
    Router::new()
        .route("/health", get(|| async { "ok" }))
        .route("/v1/services", post(create).get(list))
        .route("/v1/services/{name}", delete(remove))
        .with_state(registry)
}

pub enum ApiError {
    Invalid(String),
    NotFound,
    Unavailable,
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (status, message) = match self {
            ApiError::Invalid(m) => (StatusCode::BAD_REQUEST, m),
            ApiError::NotFound => (StatusCode::NOT_FOUND, "no service of that name is registered".to_string()),
            ApiError::Unavailable => (StatusCode::SERVICE_UNAVAILABLE, "the store is unavailable".to_string()),
        };
        (status, Json(json!({ "error": message }))).into_response()
    }
}

fn unavailable(e: anyhow::Error) -> ApiError {
    tracing::error!(error = %e, "store unavailable");
    ApiError::Unavailable
}

/// The body is taken as bytes and parsed here, so a body that does not parse is a 400 like
/// every other refusal, not Axum's 422.
async fn create(State(registry): State<Arc<Registry>>, body: Bytes) -> Result<(StatusCode, Json<Registration>), ApiError> {
    let registration: Registration = serde_json::from_slice(&body)
        .map_err(|_| ApiError::Invalid("the body must be {name, topic, pattern, direction} and nothing else".into()))?;
    registration.validate().map_err(ApiError::Invalid)?;
    registry.register(registration.clone()).await.map_err(unavailable)?;
    tracing::info!(name = %registration.name, topic = %registration.topic,
        direction = registration.direction.as_str(), "registered");
    Ok((StatusCode::CREATED, Json(registration)))
}

async fn list(State(registry): State<Arc<Registry>>) -> Result<Json<Vec<Registration>>, ApiError> {
    Ok(Json(registry.registrations().await.map_err(unavailable)?))
}

async fn remove(State(registry): State<Arc<Registry>>, Path(name): Path<String>) -> Result<StatusCode, ApiError> {
    if !valid_token(&name) {
        return Err(ApiError::Invalid("name must match [a-z0-9-]{1,64}".into()));
    }
    match registry.deregister(&name).await {
        Ok(true) => {
            tracing::info!(name = %name, "deregistered");
            Ok(StatusCode::NO_CONTENT)
        }
        Ok(false) => Err(ApiError::NotFound),
        Err(e) => Err(unavailable(e)),
    }
}
