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

/// When logging the original Error we lose
/// the context where it happened
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
            Json(json!(
            {
              "error": {
                "code": status.as_str(),
                "message": message
              }
            }
            )),
        )
            .into_response()
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
        .ok_or(AppError::ClientCertificate(anyhow!(
            "Client Certificate is missing"
        )))?;

    debug!(
        "Parsing the CN of the Client certificate: {:?}",
        client_certificate.subject
    );
    let vehicle_info = client_certificate
        .subject
        .parse_vehicleinfo()
        .map_err(AppError::ClientCertificate)?;

    debug!("Reading the CSR: {csr}");
    let mut csr_params = read_csr(&csr).map_err(AppError::Csr)?;
    let Some(rcgen::DnValue::Utf8String(csr_cn)) = csr_params
        .params
        .distinguished_name
        .get(&rcgen::DnType::CommonName)
    else {
        Err(AppError::Csr(anyhow!(
            "no utf8string encoding in CN of CSR"
        )))?
    };

    debug!("Parsing the CN from the CSR: {csr_cn}");
    let csr_vehicle_info =
        VehicleInfoHolder::parse_from_cn(csr_cn).map_err(AppError::ClientCertificate)?;

    if csr_vehicle_info != vehicle_info {
        Err(AppError::Csr(anyhow!(
            "csr and client certificate CN not matching"
        )))?
    }
    debug!("CN from CSR and from Client Certificate match");

    csr_params.params = csr::set_csr_params(csr_params.params);

    let issuer = &app_state.issuer;

    debug!("Signing the CSR");
    let certificate = sign_csr(csr_params, issuer).map_err(AppError::Signing)?;

    // Read the CA certificate to include in the chain
    let ca_cert_pem = std::fs::read_to_string("certificates/ca/ca.crt.pem")
        .context("Failed to read CA certificate")
        .map_err(AppError::Signing)?;

    // Create full certificate chain: leaf certificate + CA certificate
    let cert_chain = format!("{}{}", certificate.pem(), ca_cert_pem);

    Ok(Json(
        RegistrationResponse {
            certificate: cert_chain,
            keycloak_url: env::var("KEYCLOAK_URL").expect("KEYCLOAK_URL expected to be set in environment."),
            nats_url: env::var("NATS_URL").expect("NATS_URL expected to be set in environment."),
        }
    ))
}

#[instrument]
async fn health() -> &'static str {
    "healthy"
}

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
        SocketAddr::from_str("0.0.0.0:8080").unwrap(),
        reloadable_config.shared(),
    )
    .await?;

    let app_state = Arc::new(AppState {
        issuer: read_signing_ca()?,
    });

    // TODO add https://docs.rs/tower-http/latest/tower_http/limit/index.html
    // to hinder overflowing with huge requests
    let app = Router::new()
        .route("/registration", post(registration))
        .with_state(app_state)
        .layer(TraceLayer::new_for_http());

    let health = Router::new().route("/health", get(health));
    let tcp_listener = TcpListener::bind("0.0.0.0:8888").await.unwrap();

    info!("Server started with certificate hot-reloading enabled");
    info!("Watching {} for certificate changes", certificates_path.display());

    let _ = tokio::join! {
        tokio::spawn(async {
           let _ = axum::serve(tcp_listener, health).with_graceful_shutdown(shutdown_signal()).await;
           info!("Health Service stopped");
        }),
        tokio::spawn(async {
            let _= axum::serve(tls_listener,
            app.into_make_service_with_connect_info::<TlsConnectInfo>())
            .with_graceful_shutdown(shutdown_signal()).await;
            info!("Service stopped")})
    };

    Ok(())
}

fn init_tracing() {
    tracing_subscriber::fmt()
        .with_line_number(true)
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("debug")),
        )
        .init();
}

async fn shutdown_signal() {
    let ctrl_c = async {
        signal::ctrl_c()
            .await
            .expect("failed to install Ctrl+C handler");
    };

    let terminate = async {
        signal::unix::signal(signal::unix::SignalKind::terminate())
            .expect("failed to install signal handler")
            .recv()
            .await;
    };

    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }
}
