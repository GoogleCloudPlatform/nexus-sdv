//! nexus-telemetry-client: activates a metrics configuration with the platform's Telemetry
//! Service on this VM and publishes each MetricsReport to the Nexus leaf on the same VM.
//!
//! Started by init (nexus_telemetry_client.rc), shipped in the Nexus-Bridge APEX beside the
//! leaf. Which vehicle this is comes from the nexus-connectivity-agent over the leaf
//! (core/src/uplink.rs). With `persist.nexus.telemetry_client.enabled` set to `false` it says
//! so once and stays idle, for a VM without a Telemetry Service.
use anyhow::{Context, Result};
use log::{error, info, warn};
use nexus_telemetry_client_core::{enabled, uplink::Uplink, ENABLED_PROPERTY, LOCAL_LEAF};

mod report_source;

const METRICS_CONFIG: &str =
    "/apex/com.android.nexus.aaos_nexus_sdv_tcu/etc/nexus/vehicle_telemetry_config_live.pb";

fn main() -> Result<()> {
    logger::init(
        logger::Config::default()
            .with_tag_on_device("nexus-telemetry-client")
            .with_max_level(log::LevelFilter::Info),
    );
    let switch = rustutils::android::system_properties::read(ENABLED_PROPERTY).ok().flatten();
    if !enabled(switch.as_deref()) {
        // Never returns: init starts a service that exits again.
        warn!("switched off ({ENABLED_PROPERTY}=false) — idle");
        loop {
            std::thread::park();
        }
    }
    let leaf = LOCAL_LEAF.to_string();

    // The SDK calls back into this process over binder; without a thread pool its init blocks.
    binder::ProcessState::set_thread_pool_max_thread_count(4);
    binder::ProcessState::start_thread_pool();

    let config = std::fs::read(METRICS_CONFIG).with_context(|| format!("read {METRICS_CONFIG}"))?;
    info!("leaf at {leaf}; metrics configuration {METRICS_CONFIG} ({} bytes)", config.len());
    let mut uplink = Uplink::new(leaf, Box::new(|line| info!("{line}")));

    let rt = tokio::runtime::Runtime::new().context("tokio runtime")?;
    let result = rt.block_on(report_source::run(config, |bytes| uplink.on_report(bytes)));
    if let Err(e) = &result {
        error!("the Telemetry Service session ended: {e:#}");
    }
    result
}
