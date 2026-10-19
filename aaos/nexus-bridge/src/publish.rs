//! The cloud-to-vehicle half: what the `nexus-connectivity-agent` delivers through the
//! local socket is published on the Data Tunnel here.
//!
//! The Bridge still decodes nothing. It receives `[topic][payload]`, looks up the
//! publication declared for that topic, and hands the bytes over unchanged.

// `register_service_bundle!` emits the ContextRef alias at the crate root, so it is
// imported from there rather than from sdv_lifecycle_client directly.
use crate::link::Inbound;
use crate::slot_wire;
use crate::ContextRef;
use log::{error, info, warn};
use sdv_comms::dt::Publisher;
use sdv_comms::sd::{PublisherUnitMetadata, UnitMetadata, UnitRegistrationArgs, UnitType};
use std::collections::HashMap;
use std::str::FromStr;
use std::sync::mpsc::Receiver;
use std::time::Duration;
use tokio_util::sync::CancellationToken;

/// How many messages a publication's ring holds. Matches the sample publisher; the Data
/// Tunnel needs a count as well as a size at registration.
const MESSAGE_COUNT: u32 = 16;

/// How long to wait for a message before checking whether the Bridge is shutting down.
/// `Receiver::recv` would block forever, and `on_stop` must not have to wait for traffic
/// that may never come.
const RECV_POLL: Duration = Duration::from_millis(500);

/// One message in a hundred is logged, plus the first: enough to see it working without
/// burying everything else in logcat.
const LOG_EVERY: u64 = 100;

/// One declared publication: what the policy allows, plus the slot size it is registered
/// with.
pub struct PublishTarget {
    pub unit_type: String,
    pub topic: String,
    pub message_size: u32,
}

/// Registers every target once, then publishes whatever arrives for it.
///
/// Blocking on the channel is why this runs on a thread of its own: the subscriber side
/// owns the other current-thread runtime, and a blocking receive there would stop it
/// polling its streams.
pub async fn run_publisher(
    ctx: ContextRef,
    targets: Vec<PublishTarget>,
    rx: Receiver<Inbound>,
    cancel: CancellationToken,
) {
    let mut publishers: HashMap<String, (Publisher, u32)> = HashMap::new();
    for t in &targets {
        let unit_type = match UnitType::from_str(&t.unit_type) {
            Ok(u) => u,
            Err(e) => {
                error!("nexus-bridge: bad unit_type {}: {e:?}", t.unit_type);
                continue;
            }
        };
        let mut md = PublisherUnitMetadata::new();
        md.set_message_size(t.message_size);
        md.set_message_count(MESSAGE_COUNT);
        md.set_topic(&t.topic);
        let mut args = UnitRegistrationArgs::new();
        args.set_unit_type(&unit_type);
        args.set_unit_name(&t.topic);
        args.set_unit_metadata(&UnitMetadata::Publisher(md));

        match Publisher::create(ctx, args).await {
            Ok(p) => {
                info!(
                    "nexus-bridge: registered publisher unit_type={} topic={} slot={}",
                    t.unit_type, t.topic, t.message_size
                );
                publishers.insert(t.topic.clone(), (p, t.message_size));
            }
            Err(e) => error!("nexus-bridge: cannot publish topic={}: {e:?}", t.topic),
        }
    }

    if publishers.is_empty() {
        info!("nexus-bridge: no publication registered — nothing from the cloud can be delivered");
    }

    let mut delivered: u64 = 0;
    loop {
        if cancel.is_cancelled() {
            return;
        }
        let (topic, payload) = match rx.recv_timeout(RECV_POLL) {
            Ok(frame) => frame,
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                info!("nexus-bridge: inbound channel closed");
                return;
            }
        };
        let Some((publisher, slot)) = publishers.get(&topic) else {
            warn!(
                "nexus-bridge: no publication declared for topic={topic}, dropping {} bytes",
                payload.len()
            );
            continue;
        };
        // The Data Tunnel writes whole slots: "the size of the array must be divisible by
        // the size of a message" (publisher.rs:117-119). The payload is therefore laid out
        // with its length in front and zero padding behind. Dropping beats truncating: a
        // cut-off message reaches the receiving service as a decode error far from its cause.
        let slot_bytes = match slot_wire::pack(&payload, *slot as usize) {
            Ok(b) => b,
            Err(e) => {
                warn!("nexus-bridge: dropping a message for topic={topic}: {e}");
                continue;
            }
        };
        match publisher.write_messages(&slot_bytes) {
            Ok(_) => {
                delivered += 1;
                if delivered == 1 || delivered.is_multiple_of(LOG_EVERY) {
                    info!(
                        "nexus-bridge: published {delivered} message(s) from the cloud, latest topic={topic}"
                    );
                }
            }
            Err(e) => warn!("nexus-bridge: publish failed topic={topic}: {e:?}"),
        }
    }
}
