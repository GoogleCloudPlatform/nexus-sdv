mod cert_reloader;
mod certificates;
mod csr;
mod listener;

use std::env;
use std::net::SocketAddr;
use std::path::Path;
use std::str::FromStr;
use std::sync::Arc;

use anyhow::{anyhow, Context};
use axum::extract::{ConnectInfo, State};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use hyper::StatusCode;
use rcgen::{Issuer, SigningKey};
use serde::Serialize;
use serde_json::json;
use tokio::net::TcpListener;
use tokio::signal;
use tower_http::trace::TraceLayer;
use tracing::{debug, error, info, instrument};
use tracing_subscriber::EnvFilter;

use crate::cert_reloader::{build_server_config, start_certificate_watcher, ReloadableServerConfig};
use crate::certificates::read_signing_ca;
use crate::csr::{read_csr, sign_csr};
use crate::listener::{ReloadableTlsListener, TlsConnectInfo, VehicleInfoHolder};

enum AppError {
    ClientCertificate(anyhow::Error),
    Csr(anyhow::Error),
    Signing(anyhow::Error),
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, message) = match self {
            Self::ClientCertificate(error) => {
                error!("{error:#}");
                (StatusCode::UNAUTHORIZED, "Client Certificate missing")
            }
            Self::Csr(error) => {
                error!("{error:#}");
                (StatusCode::BAD_REQUEST, "Csr is not valid")
            }
            Self::Signing(error) => {
                error!("{error:#}");
                (StatusCode::INTERNAL_SERVER_ERROR, "Error signing CSR")
            }
        };

        (
            status,
            Json(json!({
              "error": {
                "code": status.as_str(),
                "message": message
              }
            })),
        ).into_response()
    }
}

#[derive(Debug)]
struct AppState<'a, S: SigningKey> {
    issuer: Issuer<'a, S>,
}

#[derive(Debug, Serialize)]
struct RegistrationResponse {
    certificate: String,
    keycloak_url: String,
    nats_url: String,
}

#[instrument(skip_all)]
async fn registration<S: SigningKey + std::fmt::Debug>(
    State(app_state): State<Arc<AppState<'_, S>>>,
    ConnectInfo(tls_info): ConnectInfo<TlsConnectInfo>,
    csr: String,
) -> Result<impl IntoResponse, AppError> {
    debug!("Reading client certificate");
    let client_certificate = tls_info
        .client_certificate
        .ok_or(AppError::ClientCertificate(anyhow!("Client Certificate is missing")))?;

    let vehicle_info = client_certificate
        .subject
        .parse_vehicleinfo()
        .map_err(AppError::ClientCertificate)?;

    let mut csr_params = read_csr(&csr).map_err(AppError::Csr)?;
    let Some(rcgen::DnValue::Utf8String(csr_cn)) = csr_params
        .params
        .distinguished_name
        .get(&rcgen::DnType::CommonName)
    else {
        return Err(AppError::Csr(anyhow!("no utf8string encoding in CN of CSR")));
    };

    let csr_vehicle_info = VehicleInfoHolder::parse_from_cn(csr_cn).map_err(AppError::ClientCertificate)?;

    if csr_vehicle_info != vehicle_info {
        return Err(AppError::Csr(anyhow!("csr and client certificate CN not matching")));
    }

    csr_params.params = csr::set_csr_params(csr_params.params);
    let issuer = &app_state.issuer;
    let certificate = sign_csr(csr_params, issuer).map_err(AppError::Signing)?;

    let ca_cert_pem = std::fs::read_to_string("certificates/ca/ca.crt.pem")
        .context("Failed to read CA certificate")
        .map_err(AppError::Signing)?;

    let cert_chain = format!("{}{}", certificate.pem(), ca_cert_pem);

    Ok(Json(RegistrationResponse {
        certificate: cert_chain,
        keycloak_url: env::var("KEYCLOAK_URL").expect("KEYCLOAK_URL expected"),
        nats_url: env::var("NATS_URL").expect("NATS_URL expected"),
    }))
}

#[instrument]
async fn health() -> &'static str { "healthy" }

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    init_tracing();

    // Build initial TLS configuration
    let initial_config = build_server_config()?;
    let reloadable_config = ReloadableServerConfig::new(initial_config);

    // Start watching for certificate changes
    // The watcher must be kept alive for the duration of the server
    let certificates_path = Path::new("certificates");
    let _watcher = start_certificate_watcher(reloadable_config.clone(), certificates_path).await?;

    // Create the reloadable TLS listener
    let tls_listener = ReloadableTlsListener::bind(
        SocketAddr::from_str("0.0.0.0:8443").unwrap(),
        reloadable_config.shared(),
    )
    .await?;

    let app_state = Arc::new(AppState {
        issuer: read_signing_ca()?,
    });
    let app = create_app(app_state);
    let health = Router::new().route("/health", get(health));
    let tcp_listener = TcpListener::bind("0.0.0.0:8888").await.unwrap();

    info!("Server started with certificate hot-reloading enabled");
    info!("Watching {} for certificate changes", certificates_path.display());

    let _ = tokio::join! {
        tokio::spawn(async { let _ = axum::serve(tcp_listener, health).with_graceful_shutdown(shutdown_signal()).await; }),
        tokio::spawn(async { let _= axum::serve(tls_listener, app.into_make_service_with_connect_info::<TlsConnectInfo>()).with_graceful_shutdown(shutdown_signal()).await; })
    };
    Ok(())
}

fn create_app<S: SigningKey + std::fmt::Debug + Send + Sync + 'static>(app_state: Arc<AppState<'static, S>>) -> Router {
    Router::new().route("/registration", post(registration)).with_state(app_state).layer(TraceLayer::new_for_http())
}

fn init_tracing() {
    tracing_subscriber::fmt().with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("debug"))).init();
}

async fn shutdown_signal() {
    let ctrl_c = async { signal::ctrl_c().await.expect("failed Ctrl+C"); };
    let terminate = async { signal::unix::signal(signal::unix::SignalKind::terminate()).expect("failed signal").recv().await; };
    tokio::select! { _ = ctrl_c => {}, _ = terminate => {}, }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{body::Body, http::{Request, StatusCode}};
    use tower::util::ServiceExt; 
    use rcgen::{CertificateParams, KeyPair, IsCa, DnType};
    use crate::listener::{TlsConnectInfo, VehicleInfoHolder, ClientCertInfo}; 
    use std::fs;

    #[tokio::test]
    async fn test_registration_endpoint() {
        // 1. Setup ENV
        unsafe {
            std::env::set_var("KEYCLOAK_URL", "http://test-keycloak");
            std::env::set_var("NATS_URL", "nats://test-nats");
        }
        
        // 2. Setup Filesystem Mock
        fs::create_dir_all("certificates/ca").ok();
        let fake_pem = "---BEGIN CERTIFICATE---\nFAKE CA\n---END CERTIFICATE---";
        fs::write("certificates/ca/ca.crt.pem", fake_pem).ok();

        // 3. Setup AppState
        let mut ca_params = CertificateParams::new(vec!["Test CA".to_string()]).unwrap();
        ca_params.is_ca = IsCa::Ca(rcgen::BasicConstraints::Unconstrained);
        let ca_key_pair = KeyPair::generate().unwrap();
        let ca_cert = ca_params.self_signed(&ca_key_pair).unwrap();
        let issuer = Issuer::from_ca_cert_der(ca_cert.der(), ca_key_pair).unwrap();
        let app = create_app(Arc::new(AppState { issuer }));

        // 4. Create CSR
        let cn_value = "VIN:123 DEVICE:456";
        let mut csr_params = CertificateParams::new(vec![cn_value.to_string()]).unwrap();
        csr_params.distinguished_name.push(DnType::CommonName, cn_value);
        let client_key = KeyPair::generate().unwrap();
        let csr_pem = csr_params.serialize_request(&client_key).unwrap().pem().unwrap();

        // 5. Create TLS Info
        let tls_info = TlsConnectInfo {
            client_certificate: Some(ClientCertInfo {
                subject: VehicleInfoHolder::from(format!("CN={}", cn_value)),
                issuer: "Test CA".to_string(),
                serial: "1".to_string(),
                not_before: "now".to_string(),
                not_after: "later".to_string(),
                raw_der: vec![],
            }),
            peer_addr: "127.0.0.1:1234".parse().unwrap(),
        };

        let req = Request::builder()
            .method("POST")
            .uri("/registration")
            .header("content-type", "text/plain")
            .extension(ConnectInfo(tls_info))
            .body(Body::from(csr_pem))
            .unwrap();

        // 6. Execute request
        let response = app.oneshot(req).await.unwrap();

        // FIX: Capture the status BEFORE consuming the response body
        let status = response.status();

        if status != StatusCode::OK {
            let body_bytes = axum::body::to_bytes(response.into_body(), 1024).await.unwrap();
            let body_str = String::from_utf8_lossy(&body_bytes);
            panic!("Test failed with status {} and body: {}", status, body_str);
        }

        assert_eq!(status, StatusCode::OK);

        // Cleanup
        let _ = fs::remove_dir_all("certificates");
    }
}