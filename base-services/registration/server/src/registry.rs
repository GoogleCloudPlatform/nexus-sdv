//! Best-effort reporting to vin-registry.
//!
//! A vehicle must never fail to register because the registry is slow, broken or
//! absent: the report is spawned onto a background task with a short timeout and
//! its failure is logged, never propagated. With `VIN_REGISTRY_URL` unset nothing
//! is sent at all, so a platform without the registry behaves exactly as it did
//! before it existed.
//!
//! The call is plain HTTP to a ClusterIP service, so reqwest is pulled in without
//! any TLS feature — this avoids a second rustls crypto provider alongside the
//! one the TLS listener installs.

use serde_json::json;
use std::time::Duration;
use tracing::{debug, warn};

const TIMEOUT: Duration = Duration::from_secs(2);

pub fn report_registered(vin: &str) {
    let Some(base) = std::env::var("VIN_REGISTRY_URL").ok().filter(|v| !v.is_empty()) else {
        return;
    };
    let vin = vin.to_string();
    tokio::spawn(async move {
        let body = json!({
            "vin": vin,
            "source": "registration",
            "action": "operational-certificate-issued",
            "result": "success",
        });
        let client = match reqwest::Client::builder().timeout(TIMEOUT).build() {
            Ok(c) => c,
            Err(e) => {
                warn!("vin-registry: building client failed: {e}");
                return;
            }
        };
        match client.post(format!("{base}/v1/events")).json(&body).send().await {
            Ok(r) if r.status().is_success() => debug!("vin-registry: reported {vin}"),
            Ok(r) => warn!("vin-registry: rejected report for {vin}: HTTP {}", r.status()),
            Err(e) => warn!("vin-registry: report for {vin} failed: {e}"),
        }
    });
}
