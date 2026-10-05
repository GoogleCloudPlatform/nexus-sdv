use crate::error::AppError;
use crate::Config;
use serde_json::{json, Value};
use std::{future::Future, pin::Pin};

pub struct IssuedCert {
    pub certificate: String,
    pub chain: String,
}

pub trait CaIssuer: Send + Sync {
    fn issue<'a>(
        &'a self,
        csr_pem: &'a str,
        cert_id: &'a str,
    ) -> Pin<Box<dyn Future<Output = Result<IssuedCert, AppError>> + Send + 'a>>;
}

pub fn create_url(project: &str, region: &str, pool: &str, cert_id: &str) -> String {
    format!("https://privateca.googleapis.com/v1/projects/{project}/locations/{region}/caPools/{pool}/certificates?certificateId={cert_id}")
}

/// Default lifetime of a factory certificate: two years.
///
/// The factory identity is the vehicle's way back to a defined state, so it must
/// outlive the operational certificates derived from it by a wide margin — an
/// operational certificate cannot be renewed once this one has expired. The
/// final figure is an OEM decision, which is why it is configurable.
pub const DEFAULT_VALIDITY_DAYS: u32 = 730;

pub fn create_body(csr_pem: &str, validity_days: u32) -> Value {
    let seconds = u64::from(validity_days) * 24 * 60 * 60;
    json!({ "pemCsr": csr_pem, "lifetime": format!("{seconds}s") })
}

pub struct GcpCaIssuer {
    project: String,
    region: String,
    pool: String,
    validity_days: u32,
    http: reqwest::Client,
}

impl GcpCaIssuer {
    pub fn new(config: &Config) -> Self {
        Self {
            project: config.gcp_project_id.clone(),
            region: config.gcp_region.clone(),
            pool: config.ca_pool.clone(),
            validity_days: config.cert_validity_days,
            http: reqwest::Client::new(),
        }
    }

    /// Workload Identity: the GKE metadata server hands out tokens for the bound
    /// GSA (factory-helper-gsa, roles/privateca.certificateRequester only).
    async fn access_token(&self) -> Result<String, AppError> {
        #[derive(serde::Deserialize)]
        struct Tok {
            access_token: String,
        }
        let t: Tok = self
            .http
            .get("http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token")
            .header("Metadata-Flavor", "Google")
            .send()
            .await
            .map_err(|e| {
                tracing::error!("metadata token fetch failed: {e}");
                AppError::Upstream
            })?
            .json()
            .await
            .map_err(|_| AppError::Upstream)?;
        Ok(t.access_token)
    }
}

impl CaIssuer for GcpCaIssuer {
    fn issue<'a>(
        &'a self,
        csr_pem: &'a str,
        cert_id: &'a str,
    ) -> Pin<Box<dyn Future<Output = Result<IssuedCert, AppError>> + Send + 'a>> {
        Box::pin(async move {
            let token = self.access_token().await?;
            let url = create_url(&self.project, &self.region, &self.pool, cert_id);
            let resp = self
                .http
                .post(&url)
                .bearer_auth(token)
                .json(&create_body(csr_pem, self.validity_days))
                .send()
                .await
                .map_err(|e| {
                    tracing::error!("cas request failed: {e}");
                    AppError::Upstream
                })?;
            if !resp.status().is_success() {
                // Log status + CAS error text server-side; the client gets the generic 502 only.
                let status = resp.status();
                let text = resp.text().await.unwrap_or_default();
                tracing::error!("cas returned {status}: {text}");
                return Err(AppError::Upstream);
            }
            #[derive(serde::Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct CasCert {
                pem_certificate: String,
                #[serde(default)]
                pem_certificate_chain: Vec<String>,
            }
            let c: CasCert = resp.json().await.map_err(|_| AppError::Upstream)?;
            Ok(IssuedCert {
                certificate: c.pem_certificate,
                chain: c.pem_certificate_chain.join(""),
            })
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn url_and_body_shape() {
        let url = create_url("proj", "europe-west4", "factory-ca-pool", "factory-abc123");
        assert_eq!(url, "https://privateca.googleapis.com/v1/projects/proj/locations/europe-west4/caPools/factory-ca-pool/certificates?certificateId=factory-abc123");
        let body = create_body("PEMPEM", DEFAULT_VALIDITY_DAYS);
        assert_eq!(body["pemCsr"], "PEMPEM");
        assert_eq!(body["lifetime"], "63072000s"); // 730 days, the default
    }

    #[test]
    fn body_honours_a_custom_validity() {
        assert_eq!(create_body("PEMPEM", 30)["lifetime"], "2592000s");
        assert_eq!(create_body("PEMPEM", 1825)["lifetime"], "157680000s"); // five years
    }
}
