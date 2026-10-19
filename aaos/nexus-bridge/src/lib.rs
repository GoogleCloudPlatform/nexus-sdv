//! Nexus Bridge — an SDV service bundle (Increment 1.1).
//!
//! Subscribes cross-VM to onboard Data Tunnel (`dt`) publications and logs
//! receipt. It uses the raw `dt` SDK and NEVER decodes payloads (Architecture
//! Principle 2) — it only records length + a hex preview (see `decode`).
//!
//! Packaged as a `rust_ffi_shared` `.so` and loaded by the SDV lifecycle
//! runtime, which calls `ServiceBundle::{new,on_start,on_stop}`. API names pinned
//! against the AOSP tree in the plan's "Task 0 findings".

mod decode;
mod link;
mod publish;
// Read at startup so that what the Bridge does and what it is permitted to do cannot
// disagree. Included by path like the other shared sources: Soong has no crate graph for
// our own files.
#[path = "../../common/authz_policy.rs"]
mod authz_policy;
// How a payload is laid out inside a fixed-size Data Tunnel slot, the middleware's way:
// `pack` towards the vehicle's services, `unpack_all` towards the cloud.
#[path = "../../common/slot_wire.rs"]
mod slot_wire;
// Read all (experimental): which discovered publications to carry, and the list the
// nexus-connectivity-agent offers to the registry.
#[path = "../../common/read_all.rs"]
mod read_all;

use futures::StreamExt;
use log::{error, info, warn};
use std::sync::Arc;
use sdv_comms::dt::{SubscriberOptions, SubscriberStream};
use sdv_comms::sd::{ServiceDiscoveryManager, UnitMetadata, UnitNameDiscoveryArgs, UnitType};
use std::str::FromStr;
use std::time::Duration;
use tokio_util::sync::CancellationToken;

/// How long to wait before retrying a subscription whose publisher isn't up yet.
/// The retry serves two different situations: a publisher that is merely slow to
/// boot (retry quickly), and one that is gone and staying gone (retrying every
/// three seconds then just floods logcat). Hence a backoff between the two
/// bounds, reset as soon as a subscription succeeds.
const RESUBSCRIBE_DELAY_MIN: Duration = Duration::from_secs(3);
const RESUBSCRIBE_DELAY_MAX: Duration = Duration::from_secs(30);

/// Drop a silent stream and re-subscribe after this long without a message.
/// A publisher that restarts (or comes back with a different message_size) leaves
/// the old stream alive but permanently silent — it yields neither an error nor
/// end-of-stream — so idleness is the only signal we get.
const STREAM_IDLE_TIMEOUT: Duration = Duration::from_secs(15);

/// The NATS leaf runs on this same VM, started by the TCU APEX's nexus-connectivity-agent.
// The handover socket lives in the bundle's own data directory. The nexus-connectivity-agent
// connects here; since it runs under user system, link.rs opens the directory for traversal
// and the socket for connecting (finding F47).
const LINK_SOCK: &str =
    "/data/service_bundle_data/com.android.nexus.aaos_nexus_sdv_tcu/NexusBridge/handover.sock";

// `register_service_bundle!` emits `use sdv_lifecycle_client::_ContextRef as
// ContextRef;` and `use sdv_lifecycle_client::service_bundle::ServiceBundle;`,
// so those two names are in scope below without an explicit `use`.
sdv_lifecycle_client::register_service_bundle!(NexusBridge);

/// Read all (experimental): the bundles whose publications the Bridge carries besides its
/// catalog, one `<package> <bundle>` per line. Without the file read all is off.
const READ_ALL_CONF: &str =
    "/data/service_bundle_data/com.android.nexus.aaos_nexus_sdv_tcu/NexusBridge/read-all.conf";

/// What read all found, for the nexus-connectivity-agent to offer: one `unit_type topic` per
/// line, readable by the agent's user.
const DISCOVERED: &str =
    "/data/service_bundle_data/com.android.nexus.aaos_nexus_sdv_tcu/NexusBridge/discovered";

/// Read all: how long one bundle's discovery may take before it is skipped. Discovery runs
/// before the link and the publications start, so without a bound it could stall both.
const DISCOVERY_TIMEOUT: Duration = Duration::from_secs(10);

/// The Bridge's own declaration, inside its own APEX. What it subscribes to and publishes
/// is derived from it, because this is the file the platform enforces — deriving behaviour
/// from anything else would let the two disagree, and the symptom of that is a silent
/// subscription rather than an error.
const POLICY_PATH: &str =
    "/apex/com.android.nexus.aaos_nexus_sdv_tcu/etc/permissions/com.android.nexus.aaos_nexus_sdv_tcu.NexusBridge.permissions";

/// Slot size per publish target, beside the policy. The policy says what may be published;
/// this says how large a Data Tunnel slot is registered for it.
const PUBLICATIONS_PATH: &str =
    "/apex/com.android.nexus.aaos_nexus_sdv_tcu/etc/permissions/nexus_bridge.publications";

/// Used when a declared publication has no entry in the publications file.
const DEFAULT_SLOT: u32 = 4096;

struct NexusBridge {
    ctx: ContextRef,
    cancel: CancellationToken,
}

impl ServiceBundle for NexusBridge {
    fn new(context: ContextRef) -> Self {
        info!("nexus-bridge: created");
        NexusBridge { ctx: context, cancel: CancellationToken::new() }
    }

    // Must not block: run the subscribe loop on its own thread with a
    // current-thread tokio runtime.
    fn on_start(&mut self) {
        info!("nexus-bridge: on_start");
        let ctx = self.ctx;
        let cancel = self.cancel.clone();
        std::thread::spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("tokio runtime");
            rt.block_on(run(ctx, cancel));
        });
    }

    fn on_stop(&mut self) {
        info!("nexus-bridge: on_stop");
        self.cancel.cancel();
    }
}

// Drive every target concurrently on this single-threaded runtime (join_all
// polls them cooperatively — no Send bound needed, unlike tokio::spawn).
async fn run(ctx: ContextRef, cancel: CancellationToken) {
    let policy = match std::fs::read_to_string(POLICY_PATH)
        .map_err(|e| e.to_string())
        .and_then(|t| authz_policy::parse(&t))
    {
        Ok(p) => p,
        Err(e) => {
            // Subscribing to something the policy does not contain would be refused
            // anyway, so there is nothing useful left to do. Idle and loud beats busy
            // and obscure.
            error!("nexus-bridge: cannot read {POLICY_PATH}: {e} — carrying nothing");
            return;
        }
    };
    let slots = std::fs::read_to_string(PUBLICATIONS_PATH)
        .map(|t| authz_policy::parse_slot_sizes(&t))
        .unwrap_or_default();

    // A Data Tunnel subscription names one topic, so an entry that carries only
    // allow_all_topics has nothing to subscribe to yet. The grant is what will make adding
    // a topic free of a new APEX once a registry supplies it (Increment 2.2).
    let mut subscribe_targets: Vec<(String, String)> = policy
        .subscribers
        .iter()
        .flat_map(|e| {
            if e.topics.is_empty() {
                info!("nexus-bridge: {} declares no topic to subscribe to yet", e.message);
            }
            e.topics.iter().map(|t| (e.message.clone(), t.clone())).collect::<Vec<_>>()
        })
        .collect();

    subscribe_targets.extend(read_all_targets(ctx, &policy).await);

    let publish_targets: Vec<publish::PublishTarget> = policy
        .publishers
        .iter()
        .flat_map(|e| e.topics.iter().map(|t| (e.message.clone(), t.clone())).collect::<Vec<_>>())
        .map(|(message, topic)| publish::PublishTarget {
            message_size: slots
                .iter()
                .find(|(m, t, _)| *m == message && *t == topic)
                .map(|(_, _, size)| *size)
                .unwrap_or(DEFAULT_SLOT),
            unit_type: message,
            topic,
        })
        .collect();

    info!(
        "nexus-bridge: policy declares {} subscription(s) and {} publication(s)",
        subscribe_targets.len(),
        publish_targets.len()
    );

    // Without the socket the Bridge still receives from the vehicle and logs — it just
    // cannot reach the cloud, and the cloud cannot reach it. That is worth continuing
    // with, and worth saying plainly.
    let (link, inbound) = match link::Link::start(LINK_SOCK) {
        Ok((l, rx)) => (Some(l), Some(rx)),
        Err(e) => {
            error!("nexus-bridge: link unavailable at {LINK_SOCK}: {e} — receiving only");
            (None, None)
        }
    };

    // Its own thread with its own runtime: the receive blocks, and this runtime is
    // current-thread and belongs to the subscriptions below.
    if let Some(rx) = inbound {
        let publish_cancel = cancel.clone();
        std::thread::spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("tokio runtime");
            rt.block_on(publish::run_publisher(ctx, publish_targets, rx, publish_cancel));
        });
    }

    let tasks = subscribe_targets.iter().map(|(unit_type_str, topic)| {
        subscribe_and_read(ctx, unit_type_str, topic, cancel.clone(), link.clone())
    });
    futures::future::join_all(tasks).await;
}

/// Read all: the publications of the bundles `read-all.conf` names, minus every topic the
/// policy names. Written to `DISCOVERED` for the nexus-connectivity-agent. Without the file,
/// or without `allow_read_all` in the policy, nothing — and a list left from before is removed.
async fn read_all_targets(ctx: ContextRef, policy: &authz_policy::Policy) -> Vec<(String, String)> {
    let conf = match std::fs::read_to_string(READ_ALL_CONF) {
        Ok(c) if policy.read_all => c,
        _ => {
            let _ = std::fs::remove_file(DISCOVERED);
            return Vec::new();
        }
    };
    let bundles = read_all::parse_list(&conf);
    let mut found: Vec<(String, String)> = Vec::new();
    for (package, bundle) in &bundles {
        let args = match UnitNameDiscoveryArgs::new_builder()
            .set_sdv_package_name(package.as_str())
            .set_service_bundle_name(bundle.as_str())
            .build()
        {
            Ok(a) => a,
            Err(e) => {
                warn!("nexus-bridge: read all: cannot ask for {package} {bundle}: {e:?}");
                continue;
            }
        };
        let listing = ServiceDiscoveryManager::new(ctx).list_units_by_name(&args).collect::<Vec<_>>();
        let units = match tokio::time::timeout(DISCOVERY_TIMEOUT, listing).await {
            Ok(units) => units,
            Err(_) => {
                warn!(
                    "nexus-bridge: read all: no answer for {package} {bundle} in {}s, skipped",
                    DISCOVERY_TIMEOUT.as_secs()
                );
                continue;
            }
        };
        for unit in units {
            if let UnitMetadata::Publisher(m) = unit.get_unit_metadata() {
                found.push((unit.get_unit_type().to_string(), m.get_topic()));
            }
        }
    }
    let declared: Vec<String> = policy
        .publishers
        .iter()
        .chain(policy.subscribers.iter())
        .flat_map(|e| e.topics.clone())
        .collect();
    let targets = read_all::targets(&found, &declared);
    write_discovered(&targets);
    info!(
        "nexus-bridge: read all: {} publication(s) from {} bundle(s)",
        targets.len(),
        bundles.len()
    );
    targets
}

fn write_discovered(targets: &[(String, String)]) {
    use std::os::unix::fs::PermissionsExt;
    let written = std::fs::write(DISCOVERED, read_all::format_list(targets)).and_then(|()| {
        std::fs::set_permissions(DISCOVERED, std::fs::Permissions::from_mode(0o644))
    });
    if let Err(e) = written {
        warn!("nexus-bridge: read all: cannot write {DISCOVERED}: {e} — the cloud is not offered these");
    }
}

/// Subscribe to one target and log every message. Retries until the publisher
/// appears (a subscription attempt before the publisher is up returns NotFound),
/// and re-subscribes if the stream ends **or goes silent** (a restarted publisher
/// leaves a live-but-mute stream). Exits promptly on cancellation.
async fn subscribe_and_read(
    ctx: ContextRef,
    unit_type_str: &str,
    topic: &str,
    cancel: CancellationToken,
    link: Option<Arc<link::Link>>,
) {
    let unit_type = match UnitType::from_str(unit_type_str) {
        Ok(u) => u,
        Err(e) => {
            error!("nexus-bridge: bad unit_type {unit_type_str}: {e:?}");
            return;
        }
    };
    let mut delay = RESUBSCRIBE_DELAY_MIN;
    loop {
        if cancel.is_cancelled() {
            return;
        }
        match SubscriberStream::create_for_topic(
            ctx,
            &unit_type,
            topic,
            Duration::ZERO,
            SubscriberOptions { fetch_last_message: false },
        )
        .await
        {
            Ok(mut stream) => {
                delay = RESUBSCRIBE_DELAY_MIN; // publisher is there — be quick again next time
                info!("nexus-bridge: registered subscriber unit_type={unit_type_str} topic={topic}");
                loop {
                    tokio::select! {
                        _ = cancel.cancelled() => return,
                        item = tokio::time::timeout(STREAM_IDLE_TIMEOUT, stream.next()) => match item {
                            Ok(Some(Ok((count, bytes)))) => {
                                info!("{}", decode::format_receipt(topic, count, &bytes));
                                // A read holds `count` whole slots, each a length-delimited
                                // record as the middleware writes it; the cloud gets each
                                // bare message on its own (slot_wire.rs).
                                let slot_size = match count {
                                    0 => bytes.len(),
                                    n => bytes.len() / n as usize,
                                };
                                match slot_wire::unpack_all(&bytes, slot_size) {
                                    Ok(messages) => {
                                        if let Some(link) = &link {
                                            for message in messages {
                                                link.send(topic, message);
                                            }
                                        }
                                    }
                                    Err(e) => warn!("nexus-bridge: dropping a read on topic={topic}: {e}"),
                                }
                            }
                            Ok(Some(Err(e))) => { warn!("nexus-bridge: read error topic={topic}: {e:?}"); break; }
                            Ok(None) => { info!("nexus-bridge: stream ended topic={topic}, resubscribing"); break; }
                            Err(_) => {
                                info!("nexus-bridge: silent for {}s on topic={topic} (publisher gone?), resubscribing",
                                      STREAM_IDLE_TIMEOUT.as_secs());
                                break;
                            }
                        }
                    }
                }
            }
            // Publisher not up yet (NotFound) or transient error — retry below.
            Err(e) => info!(
                "nexus-bridge: waiting for publisher unit_type={unit_type_str} topic={topic}, retrying in {}s ({e:?})",
                delay.as_secs()
            ),
        }
        tokio::select! {
            _ = cancel.cancelled() => return,
            _ = tokio::time::sleep(delay) => {}
        }
        delay = (delay * 2).min(RESUBSCRIBE_DELAY_MAX);
    }
}
