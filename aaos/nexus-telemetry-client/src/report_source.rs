//! Real adapter over the Rust Telemetry Client SDK (crate `sdv_telemetry_rust_wrapper`).
//! Connects to `google.sdv.telemetry.ITelemetryService` on the SDV Core VM,
//! registers + activates a metrics config, and forwards each ready report's
//! serialized `MetricsReport` bytes to `on_report`.
//!
//! The pattern mirrors samples/telemetry/client telemetry_rust_c_client.
//! Deliberately depends only on PUBLIC SDK crates (rust_wrapper, proto_rust) — not
//! the SDK-internal `libsdv_telemetry_utils` — so it builds out-of-tree.
use anyhow::{Context, Result};
use protobuf::Message;
use sdv_telemetry_proto_rust::metrics_configuration::MetricsConfig;
use sdv_telemetry_rust_wrapper::TelemetryServiceHolder;
use tokio::sync::mpsc;

/// Connect to the Telemetry service, register + activate the given serialized
/// `MetricsConfig` (binary protobuf), then forward each ready report's wire bytes
/// to `on_report`. Blocks until the report channel closes.
pub async fn run(config_bytes: Vec<u8>, mut on_report: impl FnMut(&[u8])) -> Result<()> {
    let service = TelemetryServiceHolder::get().context("connect to ITelemetryService")?;

    // report_ready_callback is synchronous, so it forwards the report UUID over a
    // channel; the async loop below fetches each report and publishes it.
    let (report_tx, mut report_rx) = mpsc::unbounded_channel::<String>();
    service
        .init(
            |status| log::info!("telemetry status {:?}: {}", status.code, status.message),
            move |info| {
                let _ = report_tx.send(info.report_uuid);
            },
        )
        .await
        .context("init telemetry listeners")?;

    // The Telemetry Service keeps a configuration across its restarts and refuses the same
    // UUID a second time (seen on the mesh, 2026-10-08: "Duplicate Metrics Config UUID" at the
    // second boot). The file on the image is what counts, so a stored one is replaced.
    let ours = MetricsConfig::parse_from_bytes(&config_bytes).context("parse the metrics configuration")?.uuid;
    let mut known = service.get_active_metrics_config_uuids().await.context("getActiveMetricsConfigUuids")?;
    known.extend(service.get_inactive_metrics_config_uuids().await.context("getInactiveMetricsConfigUuids")?);
    if known.contains(&ours) {
        service.remove_metrics_config(&ours).await.context("removeMetricsConfig")?;
        log::info!("replaced the stored metrics config {ours}");
    }

    let uuid = service
        .add_metrics_config(&config_bytes)
        .await
        .context("addMetricsConfig")?;
    service
        .activate_metrics_config(&uuid)
        .await
        .context("activateMetricsConfig")?;
    log::info!("activated metrics config {uuid}");

    while let Some(report_uuid) = report_rx.recv().await {
        let report = service
            .get_metrics_report(&report_uuid)
            .await
            .with_context(|| format!("get_metrics_report({report_uuid})"))?;
        let bytes = report.write_to_bytes().context("serialize MetricsReport")?;
        on_report(&bytes);
    }

    service.finish().context("finish")?;
    Ok(())
}
