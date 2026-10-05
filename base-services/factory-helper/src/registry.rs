//! Best-effort reporting to vin-registry.
//!
//! A certificate must never be withheld because the registry is slow, broken or
//! absent: the report is spawned onto a background task with a short timeout and
//! its failure is logged, never propagated. With `FACTORY_HELPER_VIN_REGISTRY_URL`
//! unset nothing is sent at all, so a platform without the registry behaves
//! exactly as it did before it existed.

use serde_json::json;
use std::time::Duration;

const TIMEOUT: Duration = Duration::from_secs(2);

pub fn report_issued(base_url: &Option<String>, vin: &str) {
    let Some(base) = base_url.clone() else { return };
    let vin = vin.to_string();
    tokio::spawn(async move {
        let body = json!({
            "vin": vin,
            "source": "factory-helper",
            "action": "factory-certificate-issued",
            "result": "success",
        });
        let client = match reqwest::Client::builder().timeout(TIMEOUT).build() {
            Ok(c) => c,
            Err(e) => {
                tracing::warn!("vin-registry: building client failed: {e}");
                return;
            }
        };
        match client.post(format!("{base}/v1/events")).json(&body).send().await {
            Ok(r) if r.status().is_success() => tracing::debug!("vin-registry: reported {vin}"),
            Ok(r) => tracing::warn!("vin-registry: rejected report for {vin}: HTTP {}", r.status()),
            Err(e) => tracing::warn!("vin-registry: report for {vin} failed: {e}"),
        }
    });
}
