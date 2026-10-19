//! The agent's side of the local handover with the Nexus Bridge: the **client**, in both
//! directions.
//!
//! The Bridge is a service bundle and may not open a socket to the leaf — its SELinux
//! domain has no `tcp_socket` permissions. So the two exchange `[topic][payload]` frames
//! over a Unix socket in the Bridge's own data directory:
//!
//! - **outbound** — the Bridge writes what a vehicle service published, this module reads
//!   it and publishes to `pubsub.<vin>.<topic>` on the local leaf;
//! - **inbound** — this module subscribes `pubsub.<vin>.>`, and writes what the cloud sent
//!   into the same socket for the Bridge to publish on the Data Tunnel.
//!
//! One Unix socket for both: the Bridge accepts a single connection at a time, so a second
//! one would silently displace the first. Two separate TCP connections to the leaf, though
//! — mixing the publish path's PING acknowledgements with the subscribe path's `MSG` lines
//! would buy nothing and cost clarity.
//!
//! The split is deliberate: the Bridge owns the AAOS integration and never speaks NATS;
//! the `nexus-connectivity-agent` owns connectivity and never interprets a payload.

use crate::{egress_wire, leaf_connect, nats_wire};
use std::io::{Read, Write};
use std::net::TcpStream;
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// Where the Bridge binds its socket. Overridable with `NEXUS_BRIDGE_SOCKET`, which is
/// what a test on a differently packaged Bridge needs.
pub const DEFAULT_SOCKET: &str =
    "/data/service_bundle_data/com.android.nexus.aaos_nexus_sdv_tcu/NexusBridge/handover.sock";

/// Before the Bridge is up, its socket does not exist yet; this is how long to wait
/// before trying again, and the same pause after any failure.
const RETRY: Duration = Duration::from_secs(3);

/// How long the leaf may take to acknowledge a publish before the connection counts as
/// unusable. Generous: the acknowledgement is local, the leaf is on the same machine.
const ACK_TIMEOUT: Duration = Duration::from_secs(5);

/// One line for the first message, then every hundredth — enough to see it working
/// without burying the rest of the log.
const LOG_EVERY: u64 = 100;

#[derive(Clone)]
pub struct Config {
    pub socket_path: String,
    pub leaf_addr: String,
    pub vin: String,
    /// The topics the Bridge declares that it publishes, read from its own AuthzPolicy.
    /// One subscription per topic, named exactly — the same way a Data Tunnel subscriber
    /// names one unit type and one topic. A wildcard over the vehicle's namespace would
    /// also collect what this process publishes outbound.
    pub inbound_topics: Vec<String>,
}

/// How long the inbound connection may be silent before it counts as gone. The leaf pings
/// every 15 s (`leaf.rs`), so nothing at all for a minute is a dead connection, not an idle one.
const INBOUND_IDLE: Duration = Duration::from_secs(60);

/// Runs until the process ends: connect, carry both directions, and on any failure wait and
/// start over. Intended for its own thread.
pub fn run(cfg: Config) {
    let mut forwarded: u64 = 0;
    loop {
        match link_until_closed(&cfg, &mut forwarded) {
            Ok(()) => crate::log_line!("bridge link: the Bridge closed the connection, reconnecting"),
            Err(e) => crate::log_err!("bridge link: {e} — retrying in {}s", RETRY.as_secs()),
        }
        std::thread::sleep(RETRY);
    }
}

/// Refuses to talk to anything at the socket path that the Bridge would not have created:
/// not a socket at all, a symlink to somewhere else, a socket in a directory that group or
/// others can write, or a socket owned by someone other than that directory's owner.
/// Whatever answers there receives every command the cloud sends this vehicle and supplies
/// every frame the nexus-connectivity-agent publishes, so a socket anyone could have put
/// there must not be trusted.
///
/// The trust comes from the directory: it is the Bridge bundle's data directory, owned by
/// the bundle's uid, and only that uid can create a file in it. The socket's own mode is not
/// the check: since APEX 16 the Bridge opens it for the nexus-connectivity-agent, which runs
/// as an init service under user system rather than as root (seen on the mesh 2026-10-07).
///
/// This checks the files, not the process behind them: the Bridge's uid is assigned per
/// installation, so there is nothing fixed to compare `SO_PEERCRED` against.
fn check_socket_path(path: &str) -> Result<(), String> {
    use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
    let meta = std::fs::symlink_metadata(path)
        .map_err(|e| format!("cannot reach the Bridge at {path}: {e}"))?;
    if !meta.file_type().is_socket() {
        return Err(format!("{path} is not a socket (a symlink or a file put there); not connecting"));
    }
    let dir = std::path::Path::new(path)
        .parent()
        .ok_or_else(|| format!("{path} has no directory; not connecting"))?;
    let dir_meta = std::fs::metadata(dir)
        .map_err(|e| format!("cannot read the directory of {path}: {e}"))?;
    let dir_mode = dir_meta.permissions().mode() & 0o7777;
    if dir_mode & 0o022 != 0 {
        return Err(format!(
            "{} is writable by group or others (mode {dir_mode:o}), so anyone could have put {path} there — not connecting",
            dir.display()
        ));
    }
    if meta.uid() != dir_meta.uid() {
        return Err(format!(
            "{path} belongs to uid {}, its directory to uid {} — not the Bridge's; not connecting",
            meta.uid(),
            dir_meta.uid()
        ));
    }
    Ok(())
}

/// Owns the one Unix socket both directions share and runs them side by side.
///
/// The inbound thread is detached rather than joined: it blocks reading its own leaf
/// connection, and a failure there must not stop the outbound direction from noticing that
/// the Bridge went away. It is told to stop through `alive`, and the socket is shut down on
/// the way out — without both, a rebuilt link left the previous thread running with its own
/// subscription, and every message was delivered twice (measured on the mesh, 2026-09-23).
fn link_until_closed(cfg: &Config, forwarded: &mut u64) -> Result<(), String> {
    check_socket_path(&cfg.socket_path)?;
    let bridge = UnixStream::connect(&cfg.socket_path)
        .map_err(|e| format!("cannot reach the Bridge at {}: {e}", cfg.socket_path))?;
    let bridge_in = bridge
        .try_clone()
        .map_err(|e| format!("cannot split the Bridge connection: {e}"))?;
    let shutdown_handle = bridge
        .try_clone()
        .map_err(|e| format!("cannot split the Bridge connection: {e}"))?;

    let alive = Arc::new(AtomicBool::new(true));
    let inbound_failed = Arc::new(AtomicBool::new(false));
    let inbound_cfg = cfg.clone();
    let inbound_alive = Arc::clone(&alive);
    let inbound_flag = Arc::clone(&inbound_failed);
    let inbound_shutdown = shutdown_handle
        .try_clone()
        .map_err(|e| format!("cannot split the Bridge connection: {e}"))?;
    std::thread::spawn(move || {
        match inbound_until_closed(&inbound_cfg, bridge_in, &inbound_alive) {
            Ok(()) => crate::log_line!("bridge link: inbound stopped"),
            Err(e) => {
                crate::log_err!("bridge link: inbound: {e}");
                // The outbound direction blocks reading the Bridge and would carry on alone
                // until its next publish failed — which may never come (F54). Closing the
                // shared socket ends it, and the whole link is rebuilt.
                inbound_flag.store(true, Ordering::Relaxed);
                let _ = inbound_shutdown.shutdown(std::net::Shutdown::Both);
            }
        }
    });

    let result = outbound_until_closed(cfg, bridge, forwarded);
    let result = if inbound_failed.load(Ordering::Relaxed) {
        Err("the inbound direction ended, rebuilding the link".to_string())
    } else {
        result
    };

    // Tell the inbound thread to stop, and make sure it notices: its read blocks for up to
    // INBOUND_IDLE, but writing to a socket that has been shut down fails at once.
    alive.store(false, Ordering::Relaxed);
    let _ = shutdown_handle.shutdown(std::net::Shutdown::Both);
    result
}

/// Subscribes `pubsub.<vin>.>` on the leaf and writes every message into the Bridge's socket.
fn inbound_until_closed(
    cfg: &Config,
    mut bridge: UnixStream,
    alive: &AtomicBool,
) -> Result<(), String> {
    let mut leaf = leaf_connect::connect(&cfg.leaf_addr)
        .map_err(|e| format!("connect leaf {}: {e}", cfg.leaf_addr))?;
    leaf.set_read_timeout(Some(INBOUND_IDLE))
        .map_err(|e| format!("set_read_timeout: {e}"))?;
    leaf.write_all(&nats_wire::connect_frame("nexus-connectivity-agent-sub"))
        .map_err(|e| format!("write CONNECT: {e}"))?;
    if cfg.inbound_topics.is_empty() {
        crate::log_line!(
            "bridge link: the Bridge declares no publication, so nothing from the cloud is subscribed"
        );
    }
    for (i, topic) in cfg.inbound_topics.iter().enumerate() {
        let subject = nats_wire::pubsub_subject(&cfg.vin, topic);
        leaf.write_all(&nats_wire::sub_frame(&subject, i as u64 + 1))
            .map_err(|e| format!("write SUB {subject}: {e}"))?;
        // Logged so the expectation is visible: with exact subscriptions, a message on an
        // undeclared topic never arrives and leaves no trace of its own.
        crate::log_line!("bridge link: subscribed {subject} on the leaf");
    }

    let mut buf: Vec<u8> = Vec::new();
    let mut chunk = [0u8; 8192];
    let mut delivered: u64 = 0;
    loop {
        if !alive.load(Ordering::Relaxed) {
            return Ok(());
        }
        let n = match leaf.read(&mut chunk) {
            Ok(n) => n,
            // A read timeout is not a failure: it is how this loop gets a chance to notice
            // that the link was rebuilt.
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock
                || e.kind() == std::io::ErrorKind::TimedOut => continue,
            Err(e) => return Err(format!("reading the leaf: {e}")),
        };
        if n == 0 {
            return Err("the leaf closed the inbound connection".to_string());
        }
        // The server pings its clients; staying silent gets this connection cut.
        if nats_wire::server_pinged(&String::from_utf8_lossy(&chunk[..n])) {
            leaf.write_all(nats_wire::PONG).map_err(|e| format!("write PONG: {e}"))?;
        }
        buf.extend_from_slice(&chunk[..n]);

        while let Some((subject, payload)) = nats_wire::take_msg(&mut buf)? {
            let Some(topic) = nats_wire::topic_from_subject(&subject, &cfg.vin) else {
                crate::log_err!("bridge link: ignoring unexpected subject {subject}");
                continue;
            };
            bridge
                .write_all(&egress_wire::frame(&topic, &payload))
                .map_err(|e| format!("writing to the Bridge: {e}"))?;
            delivered += 1;
            if delivered == 1 || delivered.is_multiple_of(LOG_EVERY) {
                crate::log_line!(
                    "bridge link: delivered {delivered} message(s) to the vehicle, latest topic={topic} bytes={}",
                    payload.len()
                );
            }
        }
    }
}

fn outbound_until_closed(
    cfg: &Config,
    mut bridge: UnixStream,
    forwarded: &mut u64,
) -> Result<(), String> {
    let mut leaf = connect_leaf(&cfg.leaf_addr)?;
    crate::log_line!(
        "bridge link: connected to the Bridge at {} and to the leaf at {}",
        cfg.socket_path,
        cfg.leaf_addr
    );

    let mut buf: Vec<u8> = Vec::new();
    let mut chunk = [0u8; 8192];
    loop {
        let n = bridge
            .read(&mut chunk)
            .map_err(|e| format!("reading from the Bridge: {e}"))?;
        if n == 0 {
            return Ok(()); // the Bridge went away; the caller reconnects
        }
        buf.extend_from_slice(&chunk[..n]);
        while let Some((topic, payload)) = egress_wire::take_frame(&mut buf)? {
            publish(&mut leaf, &cfg.vin, &topic, &payload)?;
            *forwarded += 1;
            if *forwarded == 1 || forwarded.is_multiple_of(LOG_EVERY) {
                crate::log_line!(
                    "bridge link: forwarded {} message(s) to the cloud, latest topic={topic} bytes={}",
                    *forwarded,
                    payload.len()
                );
            }
        }
    }
}

fn connect_leaf(addr: &str) -> Result<TcpStream, String> {
    let mut leaf = leaf_connect::connect(addr).map_err(|e| format!("connect leaf {addr}: {e}"))?;
    leaf.set_read_timeout(Some(ACK_TIMEOUT))
        .map_err(|e| format!("set_read_timeout: {e}"))?;
    leaf.write_all(&nats_wire::connect_frame("nexus-connectivity-agent"))
        .map_err(|e| format!("write CONNECT: {e}"))?;
    Ok(leaf)
}

/// Publishes one frame and waits for the leaf to acknowledge it.
///
/// A NATS publish is fire-and-forget: without the PING that follows it, a rejected
/// message — wrong permissions, say — would look exactly like a delivered one.
fn publish(leaf: &mut TcpStream, vin: &str, topic: &str, payload: &[u8]) -> Result<(), String> {
    let subject = nats_wire::pubsub_subject(vin, topic);
    leaf.write_all(&nats_wire::pub_frame(&subject, payload))
        .map_err(|e| format!("write PUB {subject}: {e}"))?;
    leaf.write_all(nats_wire::PING)
        .map_err(|e| format!("write PING: {e}"))?;

    let deadline = Instant::now() + ACK_TIMEOUT;
    let mut reply = String::new();
    let mut chunk = [0u8; 1024];
    loop {
        if Instant::now() > deadline {
            return Err(format!("the leaf did not answer for {subject}"));
        }
        let n = leaf
            .read(&mut chunk)
            .map_err(|e| format!("reading the leaf's answer for {subject}: {e}"))?;
        if n == 0 {
            return Err(format!("the leaf closed the connection while publishing {subject}"));
        }
        reply.push_str(&String::from_utf8_lossy(&chunk[..n]));
        match nats_wire::classify(&reply) {
            nats_wire::Verdict::Acked => return Ok(()),
            nats_wire::Verdict::Rejected(m) => {
                return Err(format!("the leaf rejected {subject}: {m}"))
            }
            nats_wire::Verdict::Pending => continue,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{symlink, PermissionsExt};
    use std::os::unix::net::UnixListener;

    fn bound_socket(dir: &std::path::Path, mode: u32) -> std::path::PathBuf {
        let path = dir.join("handover.sock");
        let _listener = UnixListener::bind(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode)).unwrap();
        path
    }

    /// F54: when the leaf closes the inbound connection, the whole link is rebuilt — not
    /// only once the next outbound message fails, which may never come.
    #[test]
    fn the_link_ends_when_the_leaf_closes_the_inbound_connection() {
        use std::net::TcpListener;
        use std::os::unix::net::UnixListener;
        use std::sync::mpsc;

        let dir = tempfile::tempdir().unwrap();
        let sock = dir.path().join("handover.sock");
        let bridge = UnixListener::bind(&sock).unwrap();
        let leaf = TcpListener::bind("127.0.0.1:0").unwrap();
        let cfg = Config {
            socket_path: sock.to_str().unwrap().to_string(),
            leaf_addr: leaf.local_addr().unwrap().to_string(),
            vin: "TESTVIN".to_string(),
            inbound_topics: vec!["pressure-limit".to_string()],
        };

        let (done, ended) = mpsc::channel();
        std::thread::spawn(move || {
            let mut forwarded = 0;
            let _ = done.send(link_until_closed(&cfg, &mut forwarded));
        });
        let (_bridge_side, _) = bridge.accept().unwrap();

        // Two connections arrive at the leaf; the inbound one names itself "-sub".
        let mut kept = Vec::new();
        for _ in 0..2 {
            let (mut conn, _) = leaf.accept().unwrap();
            let mut hello = [0u8; 256];
            let n = conn.read(&mut hello).unwrap();
            if String::from_utf8_lossy(&hello[..n]).contains("nexus-connectivity-agent-sub") {
                drop(conn); // the leaf restarts: the inbound connection is gone
            } else {
                kept.push(conn); // outbound stays connected and idle
            }
        }

        let result = ended
            .recv_timeout(Duration::from_secs(10))
            .expect("the link kept running without its inbound direction");
        assert!(result.unwrap_err().contains("inbound"));
    }

    #[test]
    fn an_owner_only_socket_is_accepted() {
        let dir = tempfile::tempdir().unwrap();
        let path = bound_socket(dir.path(), 0o600);
        assert!(check_socket_path(path.to_str().unwrap()).is_ok());
    }

    /// What the Bridge creates since APEX 16: a socket others may connect to, in its own
    /// directory that only it can write. The service user is not the Bridge's uid.
    #[test]
    fn a_connectable_socket_in_a_directory_only_its_owner_writes_is_accepted() {
        for (dir_mode, sock_mode) in [(0o711, 0o666), (0o700, 0o600), (0o755, 0o660)] {
            let dir = tempfile::tempdir().unwrap();
            std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(dir_mode)).unwrap();
            let path = bound_socket(dir.path(), sock_mode);
            assert!(check_socket_path(path.to_str().unwrap()).is_ok(), "{dir_mode:o}/{sock_mode:o}");
        }
    }

    /// Anyone who can write the directory could have put the socket there.
    #[test]
    fn a_socket_in_a_directory_group_or_others_can_write_is_refused() {
        for dir_mode in [0o777, 0o773, 0o731, 0o1777] {
            let dir = tempfile::tempdir().unwrap();
            let path = bound_socket(dir.path(), 0o600);
            std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(dir_mode)).unwrap();
            let err = check_socket_path(path.to_str().unwrap()).unwrap_err();
            assert!(err.contains("writable by group or others"), "{dir_mode:o}: {err}");
        }
    }

    #[test]
    fn a_plain_file_or_a_symlink_is_not_the_bridge() {
        let dir = tempfile::tempdir().unwrap();

        let file = dir.path().join("plain");
        std::fs::write(&file, b"x").unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert!(check_socket_path(file.to_str().unwrap()).unwrap_err().contains("not a socket"));

        let real = bound_socket(dir.path(), 0o600);
        let link = dir.path().join("link.sock");
        symlink(&real, &link).unwrap();
        assert!(check_socket_path(link.to_str().unwrap()).unwrap_err().contains("not a socket"));
    }

    /// Before the Bridge is up there is no socket; that is the normal case and keeps
    /// the message the log has always carried.
    #[test]
    fn a_missing_socket_says_it_cannot_reach_the_bridge() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("absent.sock");
        let err = check_socket_path(path.to_str().unwrap()).unwrap_err();
        assert!(err.starts_with("cannot reach the Bridge at "), "{err}");
    }
}
