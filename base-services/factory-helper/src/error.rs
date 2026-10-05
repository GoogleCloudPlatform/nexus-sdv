use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde_json::json;

#[derive(Debug)]
pub enum AppError {
    BadRequest(String),
    Unauthorized,
    Forbidden,
    Upstream, // CAS failure — generic message only, never the raw GCP error
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, msg) = match self {
            AppError::BadRequest(m) => (StatusCode::BAD_REQUEST, m),
            AppError::Unauthorized => (
                StatusCode::UNAUTHORIZED,
                "missing or invalid bearer token".into(),
            ),
            AppError::Forbidden => (
                StatusCode::FORBIDDEN,
                "token lacks the factory-operator role".into(),
            ),
            AppError::Upstream => (
                StatusCode::BAD_GATEWAY,
                "certificate authority request failed".into(),
            ),
        };
        (status, Json(json!({ "error": msg }))).into_response()
    }
}
