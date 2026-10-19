//! The Bridge's local handover: a Unix domain socket the nexus-connectivity-agent
//! connects to, carrying both directions.
//!
//! The Bridge may not open a TCP socket — as a service bundle it runs in the SELinux
//! domain `untrusted_service_bundle`, which has no `tcp_socket` permissions (measured
//! 2026-09-11). A Unix socket is a different class and is permitted (measured
//! 2026-09-21), so the bytes leave through one: the Bridge is the **server**, binding
//! the socket in its own bundle data directory, and the nexus-connectivity-agent is the
//! **client** that connects and reads. Nothing is made writable for anyone else; the
//! directory and the socket are opened for connecting (see `start`, finding F47).
//!
//! The Bridge stays out of NATS entirely. Outbound it writes `[topic][payload]` frames and
//! the nexus-connectivity-agent builds `pubsub.<vin>.<topic>`; inbound the agent writes the
//! sameframing back and the Bridge publishes it on the Data Tunnel. It never sees a subject
//! and never decodes a payload in either direction.

#[path = "../../common/egress_wire.rs"]
pub mod egress_wire;

use log::{info, warn};
use std::io::{Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{sync_channel, Receiver, SyncSender, TrySendError};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// A write must never hold up the Data Tunnel loop. If the agent does not drain the
/// socket within this, the frame is dropped and the connection closed — see `send`.
const WRITE_TIMEOUT: Duration = Duration::from_millis(50);

/// Every drop matters, but one line per message would bury everything else in the log:
/// the first is reported, then every hundredth.
const DROP_LOG_EVERY: u64 = 100;

/// One message the cloud addressed to this vehicle: the topic it named, and its bytes.
pub type Inbound = (String, Vec<u8>);

/// How many cloud messages may wait for the Data Tunnel publisher. The queue is bounded so
/// that a peer writing faster than the publisher drains cannot grow the Bridge's memory
/// without limit; beyond this a message is dropped and counted, as outbound ones are.
const INBOUND_QUEUE: usize = 64;

pub struct Link {
    conn: Mutex<Option<UnixStream>>,
    dropped: AtomicU64,
    inbound: SyncSender<Inbound>,
}

impl Link {
    /// Binds the socket and starts accepting connections in the background. The returned
    /// receiver yields what the cloud sent, in arrival order.
    ///
    /// A socket file left behind by an earlier run would make `bind` fail, so it is
    /// removed first. The socket and its directory are opened to the
    /// nexus-connectivity-agent's user (see the comment at the chmod).
    pub fn start(path: &str) -> Result<(Arc<Self>, Receiver<Inbound>), String> {
        let _ = std::fs::remove_file(path);
        let listener = UnixListener::bind(path).map_err(|e| format!("bind {path}: {e}"))?;
        // The nexus-connectivity-agent runs as an init service under user system since
        // APEX 13, not as root: it needs to pass through this bundle's data directory,
        // which the lifecycle manager creates 0700 for the bundle's own uid, and to connect
        // to the socket (seen on the mesh 2026-10-07: EACCES). Traverse-only on the
        // directory, connect for everyone on the socket; which domain may connect is
        // SELinux's to decide (aaos/aaos-nexus-sdv-tcu-sepolicy/), in the enforcing stage.
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o666))
            .map_err(|e| format!("chmod {path}: {e}"))?;
        if let Some(dir) = std::path::Path::new(path).parent() {
            std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o711))
                .map_err(|e| format!("chmod {}: {e}", dir.display()))?;
        }

        let (inbound, rx) = sync_channel(INBOUND_QUEUE);
        let link = Arc::new(Self {
            conn: Mutex::new(None),
            dropped: AtomicU64::new(0),
            inbound,
        });

        let accepting = Arc::clone(&link);
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                match stream {
                    Ok(stream) => {
                        if let Err(e) = stream.set_write_timeout(Some(WRITE_TIMEOUT)) {
                            warn!("nexus-bridge: link set_write_timeout: {e}");
                            continue;
                        }
                        let reading = match stream.try_clone() {
                            Ok(s) => s,
                            Err(e) => {
                                warn!("nexus-bridge: link cannot split connection: {e}");
                                continue;
                            }
                        };
                        // The write timeout must not apply to reading: an idle inbound
                        // direction is normal, and a timeout here would tear down a healthy
                        // connection every time the cloud has nothing to say.
                        let _ = reading.set_read_timeout(None);
                        info!("nexus-bridge: link client connected");
                        // Last one wins: a reconnecting nexus-connectivity-agent replaces
                        // its old connection.
                        *accepting.conn.lock().unwrap() = Some(stream);

                        let inbound = accepting.inbound.clone();
                        std::thread::spawn(move || read_inbound(reading, inbound));
                    }
                    Err(e) => warn!("nexus-bridge: link accept: {e}"),
                }
            }
        });

        info!("nexus-bridge: link listening at {path}");
        Ok((link, rx))
    }

    /// Hands one Data Tunnel message to the agent, or drops it.
    ///
    /// Dropping is deliberate. The alternative — waiting for a client that is absent or
    /// slow — would stall the subscription loop and lose data at the source instead of
    /// here, where it can at least be counted. A failed write also closes the connection:
    /// a half-written frame would desynchronise the reader, and a fresh connection starts
    /// at a frame boundary.
    pub fn send(&self, topic: &str, payload: &[u8]) {
        let bytes = egress_wire::frame(topic, payload);
        let mut guard = self.conn.lock().unwrap();
        let Some(stream) = guard.as_mut() else {
            self.count_drop("no client connected", topic);
            return;
        };
        if let Err(e) = stream.write_all(&bytes) {
            *guard = None;
            self.count_drop(&format!("write failed ({e})"), topic);
        }
    }

    fn count_drop(&self, why: &str, topic: &str) {
        let n = self.dropped.fetch_add(1, Ordering::Relaxed) + 1;
        if n == 1 || n.is_multiple_of(DROP_LOG_EVERY) {
            warn!("nexus-bridge: dropped {n} message(s) for the cloud, latest topic={topic}: {why}");
        }
    }
}

/// Reads `[topic][payload]` frames from one connection until it closes or desynchronises.
///
/// A framing error ends the connection rather than trying to resynchronise: the next
/// connection starts at a frame boundary, which is the only reliable way back in sync.
fn read_inbound(mut stream: UnixStream, inbound: SyncSender<Inbound>) {
    let mut buf: Vec<u8> = Vec::new();
    let mut chunk = [0u8; 8192];
    let mut dropped: u64 = 0;
    loop {
        match stream.read(&mut chunk) {
            Ok(0) => {
                info!("nexus-bridge: link client disconnected");
                return;
            }
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
            Err(e) => {
                warn!("nexus-bridge: link read: {e}");
                return;
            }
        }
        loop {
            match egress_wire::take_frame(&mut buf) {
                Ok(Some(frame)) => match inbound.try_send(frame) {
                    Ok(()) => {}
                    // The publisher is not keeping up: drop, count, keep reading, so the
                    // socket does not back up into the agent.
                    Err(TrySendError::Full((topic, _))) => {
                        dropped += 1;
                        if dropped == 1 || dropped.is_multiple_of(DROP_LOG_EVERY) {
                            warn!("nexus-bridge: dropped {dropped} message(s) from the cloud, queue full, latest topic={topic}");
                        }
                    }
                    // The receiver is gone only when the Bridge is shutting down.
                    Err(TrySendError::Disconnected(_)) => return,
                },
                Ok(None) => break,
                Err(e) => {
                    warn!("nexus-bridge: link framing error: {e}");
                    return;
                }
            }
        }
    }
}
