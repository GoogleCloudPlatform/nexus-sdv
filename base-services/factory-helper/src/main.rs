mod auth;
mod ca;
mod csr;
mod error;
mod handler;
mod registry;
mod vin;

use anyhow::Context;
use axum::{
    routing::{get, post},
    Router,
};
use std::{net::SocketAddr, sync::Arc};

#[derive(Clone)]
pub struct Config {
    pub gcp_project_id: String,
    pub gcp_region: String,
    pub ca_pool: String,
    pub keycloak_issuer: String,
    pub cert_org: String,
    pub tls_cert_path: String,
    pub tls_key_path: String,
    /// Optional extra TLS trust anchor for the JWKS fetch: Keycloak's server cert
    /// is issued by Nexus's own CA, which is not in the bundled webpki roots.
    pub keycloak_ca_path: Option<String>,
    /// vin-registry base URL. Unset => do not report at all; the registry is an
    /// optional companion, never a dependency.
    pub vin_registry_url: Option<String>,
    pub port: u16,
    /// Lifetime of issued factory certificates, in days. Years, not weeks: this
    /// is the credential a vehicle re-registers with, and the OEM decides.
    pub cert_validity_days: u32,
}

impl Config {
    pub fn from_env() -> anyhow::Result<Self> {
        let req = |k: &str| std::env::var(k).with_context(|| format!("missing required env var {k}"));
        let opt = |k: &str, d: &str| std::env::var(k).unwrap_or_else(|_| d.to_string());
        Ok(Self {
            gcp_project_id: req("FACTORY_HELPER_GCP_PROJECT_ID")?,
            gcp_region: req("FACTORY_HELPER_GCP_REGION")?,
            ca_pool: req("FACTORY_HELPER_CA_POOL")?,
            keycloak_issuer: req("FACTORY_HELPER_KEYCLOAK_ISSUER")?,
            cert_org: opt("FACTORY_HELPER_CERT_ORG", "Nexus SDV"),
            tls_cert_path: opt("FACTORY_HELPER_TLS_CERT_PATH", "certificates/server.crt.pem"),
            tls_key_path: opt("FACTORY_HELPER_TLS_KEY_PATH", "certificates/server.key.pem"),
            keycloak_ca_path: std::env::var("FACTORY_HELPER_KEYCLOAK_CA_PATH")
                .ok()
                .filter(|v| !v.is_empty()),
            vin_registry_url: std::env::var("FACTORY_HELPER_VIN_REGISTRY_URL")
                .ok()
                .filter(|v| !v.is_empty()),
            port: opt("FACTORY_HELPER_PORT", "8443")
                .parse()
                .context("FACTORY_HELPER_PORT must be a u16")?,
            cert_validity_days: {
                let days: u32 = opt(
                    "FACTORY_HELPER_CERT_VALIDITY_DAYS",
                    &crate::ca::DEFAULT_VALIDITY_DAYS.to_string(),
                )
                .parse()
                .context("FACTORY_HELPER_CERT_VALIDITY_DAYS must be a positive number of days")?;
                if days == 0 {
                    anyhow::bail!("FACTORY_HELPER_CERT_VALIDITY_DAYS must be greater than zero");
                }
                days
            },
        })
    }
}

pub struct AppState {
    pub config: Config,
    pub verifier: Box<dyn auth::TokenVerifier>,
    pub issuer: Box<dyn ca::CaIssuer>,
}

pub fn build_router(state: Arc<AppState>) -> Router {
    // Deliberately NO body-logging middleware anywhere: mode-2 responses carry a
    // private key (spec safeguard). Only method/path/status may ever be logged.
    Router::new()
        .route("/health", get(|| async { "ok" }))
        .route("/v1/factory-certificates", post(handler::issue_certificate))
        .with_state(state)
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // axum-server (aws-lc-rs) and reqwest (ring) both pull rustls with their
    // crypto backend — with two candidates present, rustls refuses to pick one
    // itself and panics on first TLS use. Install the process default explicitly.
    rustls::crypto::aws_lc_rs::default_provider()
        .install_default()
        .expect("install rustls crypto provider");
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "factory_helper=info,info".into()),
        )
        .init();
    let config = Config::from_env()?;
    let tls = axum_server::tls_rustls::RustlsConfig::from_pem_file(
        &config.tls_cert_path,
        &config.tls_key_path,
    )
    .await
    .context("loading TLS cert/key")?;
    let addr = SocketAddr::from(([0, 0, 0, 0], config.port));
    let keycloak_ca = match &config.keycloak_ca_path {
        Some(p) => Some(std::fs::read(p).with_context(|| format!("reading keycloak ca {p}"))?),
        None => None,
    };
    let state = Arc::new(AppState {
        verifier: Box::new(auth::KeycloakVerifier::new(
            config.keycloak_issuer.clone(),
            keycloak_ca,
        )),
        issuer: Box::new(ca::GcpCaIssuer::new(&config)),
        config,
    });
    tracing::info!("factory-helper listening on {addr}");
    axum_server::bind_rustls(addr, tls)
        .serve(build_router(state).into_make_service())
        .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn config_defaults_and_required() {
        // required vars absent -> error
        for k in [
            "FACTORY_HELPER_GCP_PROJECT_ID",
            "FACTORY_HELPER_GCP_REGION",
            "FACTORY_HELPER_CA_POOL",
            "FACTORY_HELPER_KEYCLOAK_ISSUER",
        ] {
            std::env::remove_var(k);
        }
        assert!(Config::from_env().is_err());
        std::env::set_var("FACTORY_HELPER_GCP_PROJECT_ID", "p");
        std::env::set_var("FACTORY_HELPER_GCP_REGION", "r");
        std::env::set_var("FACTORY_HELPER_CA_POOL", "pool");
        std::env::set_var("FACTORY_HELPER_KEYCLOAK_ISSUER", "https://kc/realms/sdv-telemetry");
        let c = Config::from_env().unwrap();
        assert_eq!(c.cert_org, "Nexus SDV");
        assert_eq!(c.port, 8443);
        assert_eq!(c.tls_cert_path, "certificates/server.crt.pem");
    }
}
