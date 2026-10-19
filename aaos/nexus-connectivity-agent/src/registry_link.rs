//! The vehicle's side of the registry conversation, over the local leaf: announce the
//! offer, listen for grants. It decides nothing — a grant that differs from the one in
//! force is handed to `main`, which re-establishes the upstream connection so the
//! auth-callout issues the new permissions.

use crate::{leaf_connect, leaf_status, nats_wire, offer::Offer};
use serde::Deserialize;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::sync::mpsc::{self, Receiver, Sender};
use std::time::{Duration, Instant};

#[derive(Deserialize, Debug, Clone, PartialEq, Eq, Default)]
pub struct Grant {
    #[serde(rename = "pub", default)]
    pub publish: Vec<String>,
    #[serde(rename = "sub", default)]
    pub subscribe: Vec<String>,
}

#[derive(Clone)]
pub struct Config {
    pub leaf_addr: String,
    pub vin: String,
    pub offers: Vec<Offer>,
    pub monitor_port: u16,
}

const RETRY: Duration = Duration::from_secs(3);
const READ_TICK: Duration = Duration::from_secs(2);
const REPLY_TIMEOUT: Duration = Duration::from_secs(5);

/// Sorted and without duplicates on both sides, so that two grants naming the same
/// subjects compare equal whatever order a registry emitted them in — an order-sensitive
/// comparison would turn every announce reply into a reconnect.
pub fn parse_grant(payload: &[u8]) -> Option<Grant> {
    let mut g: Grant = serde_json::from_slice(payload).ok()?;
    g.publish.sort();
    g.publish.dedup();
    g.subscribe.sort();
    g.subscribe.dedup();
    Some(g)
}

pub fn grant_subject(vin: &str) -> String {
    format!("registry.{vin}.grant")
}
pub fn reply_pattern(vin: &str) -> String {
    format!("registry.{vin}.reply.*")
}
pub fn reply_subject(vin: &str, n: u64) -> String {
    format!("registry.{vin}.reply.{n}")
}
pub fn announce_subject(vin: &str) -> String {
    format!("registry.{vin}.announce")
}

/// Whether a message on `subject` may carry a grant. The registry pushes on the grant
/// subject; the only reply expected is the one to the announce still waiting for its
/// answer. Anything else on the leaf — a reply to nothing we asked, an old announce, a
/// stranger's publish on `registry.<vin>.reply.<anything>` — is not a grant, whatever its
/// body looks like, because each accepted difference restarts the uplink.
fn accepts(subject: &str, vin: &str, outstanding: Option<u64>) -> bool {
    subject == grant_subject(vin) || outstanding.is_some_and(|n| subject == reply_subject(vin, n))
}

/// Runs on its own thread until the process ends. Every grant the registry sends is
/// delivered on the returned receiver; `main` decides what to do with it.
pub fn spawn(cfg: Config) -> Receiver<Grant> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || loop {
        match session(&cfg, &tx) {
            Ok(()) => crate::log_line!("registry link: the leaf closed the connection, reconnecting"),
            Err(e) => crate::log_err!("registry link: {e} — retrying in {}s", RETRY.as_secs()),
        }
        std::thread::sleep(RETRY);
    });
    rx
}

/// One connection to the local leaf, from CONNECT to its end.
fn session(cfg: &Config, tx: &Sender<Grant>) -> Result<(), String> {
    let mut leaf = leaf_connect::connect(&cfg.leaf_addr)
        .map_err(|e| format!("connect leaf {}: {e}", cfg.leaf_addr))?;
    leaf.set_read_timeout(Some(READ_TICK))
        .map_err(|e| format!("set_read_timeout: {e}"))?;
    leaf.write_all(&nats_wire::connect_frame("nexus-connectivity-agent-registry"))
        .map_err(|e| format!("write CONNECT: {e}"))?;
    leaf.write_all(&nats_wire::sub_frame(&grant_subject(&cfg.vin), 1))
        .map_err(|e| format!("write SUB grant: {e}"))?;
    leaf.write_all(&nats_wire::sub_frame(&reply_pattern(&cfg.vin), 2))
        .map_err(|e| format!("write SUB reply: {e}"))?;
    crate::log_line!(
        "registry link: listening on {} and {}",
        grant_subject(&cfg.vin),
        reply_pattern(&cfg.vin)
    );

    let mut announces: u64 = 0;
    let mut link_up = link_is_up(cfg.monitor_port);
    // Unknown counts as up: without a monitor to ask (tests, an odd build) an announce
    // that is dropped costs nothing, while one that is withheld costs the grant.
    let mut awaiting: Option<Instant> = None;
    // The announce whose reply is still acceptable. Unlike `awaiting` it survives a grant
    // pushed in between and the reply timeout — a slow registry may still answer — and is
    // cleared only by that reply or by the next announce replacing it.
    let mut outstanding: Option<u64> = None;
    if link_up != Some(false) {
        announces += 1;
        announce(&mut leaf, cfg, announces)?;
        awaiting = Some(Instant::now());
        outstanding = Some(announces);
    }

    let mut buf: Vec<u8> = Vec::new();
    let mut chunk = [0u8; 8192];
    loop {
        match leaf.read(&mut chunk) {
            Ok(0) => return Ok(()),
            Ok(n) => {
                if nats_wire::server_pinged(&String::from_utf8_lossy(&chunk[..n])) {
                    leaf.write_all(nats_wire::PONG)
                        .map_err(|e| format!("write PONG: {e}"))?;
                }
                buf.extend_from_slice(&chunk[..n]);
                while let Some((subject, payload)) = nats_wire::take_msg(&mut buf)? {
                    if !accepts(&subject, &cfg.vin, outstanding) {
                        crate::log_err!("registry link: ignoring a message on {subject}, not a grant we expect");
                        continue;
                    }
                    if subject != grant_subject(&cfg.vin) {
                        outstanding = None; // the reply came; a second one is not welcome
                    }
                    match parse_grant(&payload) {
                        Some(g) => {
                            awaiting = None;
                            crate::log_line!(
                                "registry link: grant received on {subject}: pub={} sub={}",
                                g.publish.len(),
                                g.subscribe.len()
                            );
                            tx.send(g).map_err(|_| "main went away".to_string())?;
                        }
                        None => {
                            crate::log_err!("registry link: unreadable grant on {subject}, ignored")
                        }
                    }
                }
            }
            Err(e)
                if e.kind() == std::io::ErrorKind::WouldBlock
                    || e.kind() == std::io::ErrorKind::TimedOut =>
            {
                // A quiet tick: notice a link that came back, and an answer that never came.
                let now_up = link_is_up(cfg.monitor_port);
                if now_up == Some(true) && link_up == Some(false) {
                    announces += 1;
                    announce(&mut leaf, cfg, announces)?;
                    awaiting = Some(Instant::now());
                    outstanding = Some(announces);
                }
                link_up = now_up;
                if let Some(since) = awaiting {
                    if since.elapsed() > REPLY_TIMEOUT {
                        crate::log_line!(
                            "registry link: no answer to announce {announces} within {}s — the grant in force stays as it is",
                            REPLY_TIMEOUT.as_secs()
                        );
                        awaiting = None;
                    }
                }
            }
            Err(e) => return Err(format!("reading the leaf: {e}")),
        }
    }
}

fn announce(leaf: &mut TcpStream, cfg: &Config, n: u64) -> Result<(), String> {
    let body = crate::offer::announce_json(&cfg.vin, &cfg.offers);
    leaf.write_all(&nats_wire::pub_frame_with_reply(
        &announce_subject(&cfg.vin),
        &reply_subject(&cfg.vin, n),
        body.as_bytes(),
    ))
    .map_err(|e| format!("write announce: {e}"))?;
    crate::log_line!("registry link: announced {} offer(s) (announce {n})", cfg.offers.len());
    Ok(())
}

/// `Some(true)` = the leaf holds an upstream link, `Some(false)` = it holds none,
/// `None` = the leaf's monitor did not answer.
fn link_is_up(monitor_port: u16) -> Option<bool> {
    leaf_status::leafnode_count(monitor_port).map(|n| n > 0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::offer;
    use std::io::{BufRead, BufReader};
    use std::net::TcpListener;

    #[test]
    fn a_grant_is_read_from_the_registry_s_json() {
        let g = parse_grant(br#"{"pub":["pubsub.V.pressure"],"sub":["pubsub.V.command"]}"#).unwrap();
        assert_eq!(g.publish, vec!["pubsub.V.pressure"]);
        assert_eq!(g.subscribe, vec!["pubsub.V.command"]);
        assert_eq!(parse_grant(br#"{"pub":[]}"#).unwrap(), Grant { publish: vec![], subscribe: vec![] });
        assert!(parse_grant(b"not json").is_none());
    }

    /// A registry that builds its lists from a set may emit them in any order. The same
    /// subjects are the same grant, or every announce reply would restart the leaf.
    #[test]
    fn a_grant_in_another_order_is_the_same_grant() {
        let a = parse_grant(br#"{"pub":["b","a","a"],"sub":["y","x"]}"#).unwrap();
        let b = parse_grant(br#"{"pub":["a","b"],"sub":["x","y","x"]}"#).unwrap();
        assert_eq!(a, b);
        assert_eq!(a.publish, vec!["a", "b"]);
    }

    #[test]
    fn subjects_are_named_from_the_vin() {
        assert_eq!(grant_subject("V"), "registry.V.grant");
        assert_eq!(reply_pattern("V"), "registry.V.reply.*");
        assert_eq!(reply_subject("V", 7), "registry.V.reply.7");
        assert_eq!(announce_subject("V"), "registry.V.announce");
    }

    #[test]
    fn only_the_grant_subject_and_the_outstanding_reply_may_carry_a_grant() {
        assert!(accepts("registry.V.grant", "V", None));
        assert!(accepts("registry.V.grant", "V", Some(3)));
        assert!(accepts("registry.V.reply.3", "V", Some(3)));

        assert!(!accepts("registry.V.reply.3", "V", None), "no announce is waiting");
        assert!(!accepts("registry.V.reply.2", "V", Some(3)), "an older announce");
        assert!(!accepts("registry.V.reply.99", "V", Some(3)), "a number nobody sent");
        assert!(!accepts("registry.W.grant", "V", Some(3)), "another vehicle");
        assert!(!accepts("registry.V.announce", "V", Some(3)));
        assert!(!accepts("pubsub.V.command", "V", Some(3)));
    }

    /// Alternating two grants is the storm this closes: every difference restarts the uplink.
    /// A reply nobody asked for, and a second reply to the same announce, never reach `main`.
    #[test]
    fn a_forged_or_repeated_reply_never_reaches_main() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let cfg = Config { leaf_addr: addr.to_string(), vin: "V".into(), offers: vec![], monitor_port: 1 };
        let rx = spawn(cfg);

        let (sock, _) = listener.accept().unwrap();
        let mut writer = sock.try_clone().unwrap();
        let send = |w: &mut std::net::TcpStream, subject: &str, body: &[u8]| {
            w.write_all(format!("MSG {subject} 1 {}\r\n", body.len()).as_bytes()).unwrap();
            w.write_all(body).unwrap();
            w.write_all(b"\r\n").unwrap();
        };
        // The client announces first (announce 1); wait until it has, so `outstanding` is set.
        let mut reader = BufReader::new(sock);
        for _ in 0..5 {
            let mut l = String::new();
            reader.read_line(&mut l).unwrap();
        }

        send(&mut writer, "registry.V.reply.99", br#"{"pub":["evil.a"],"sub":[]}"#);
        send(&mut writer, "registry.V.reply.1", br#"{"pub":["pubsub.V.pressure"],"sub":[]}"#);
        send(&mut writer, "registry.V.reply.1", br#"{"pub":["evil.b"],"sub":[]}"#);
        send(&mut writer, "registry.V.grant", br#"{"pub":["pubsub.V.pressure"],"sub":["pubsub.V.command"]}"#);

        let first = rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(first.publish, vec!["pubsub.V.pressure"], "the real reply is the first thing delivered");
        let second = rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(second.subscribe, vec!["pubsub.V.command"], "then the pushed grant, with both forgeries skipped");
    }

    /// A stand-in for the local leaf: greets, reads what the client sends, then plays a
    /// grant notification and a reply. Asserts the frames the client must have sent.
    #[test]
    fn announces_after_connecting_and_hands_over_every_grant() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let offers = offer::from_policy(
            &crate::authz_policy::parse(r#"publisher { message: "a.B" topic: "command" }"#).unwrap(),
        );
        let cfg = Config { leaf_addr: addr.to_string(), vin: "V".into(), offers, monitor_port: 1 };
        let rx = spawn(cfg);

        let (sock, _) = listener.accept().unwrap();
        let mut writer = sock.try_clone().unwrap();
        writer.write_all(b"INFO {\"max_payload\":1048576}\r\n").unwrap();
        let mut reader = BufReader::new(sock);
        let mut lines = Vec::new();
        // CONNECT, SUB grant, SUB reply, PUB announce, then the announce payload.
        for _ in 0..5 {
            let mut l = String::new();
            reader.read_line(&mut l).unwrap();
            lines.push(l);
        }
        assert!(lines[0].starts_with("CONNECT "));
        assert_eq!(lines[1], "SUB registry.V.grant 1\r\n");
        assert_eq!(lines[2], "SUB registry.V.reply.* 2\r\n");
        assert!(lines[3].starts_with("PUB registry.V.announce registry.V.reply.1 "), "{}", lines[3]);
        assert!(lines[4].contains(r#""topic":"command""#));

        let grant = br#"{"pub":[],"sub":["pubsub.V.command"]}"#;
        writer.write_all(format!("MSG registry.V.grant 1 {}\r\n", grant.len()).as_bytes()).unwrap();
        writer.write_all(grant).unwrap();
        writer.write_all(b"\r\n").unwrap();
        let got = rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(got.subscribe, vec!["pubsub.V.command"]);

        // A reply to the announce is a grant too.
        let reply = br#"{"pub":["pubsub.V.pressure"],"sub":[]}"#;
        writer.write_all(format!("MSG registry.V.reply.1 2 {}\r\n", reply.len()).as_bytes()).unwrap();
        writer.write_all(reply).unwrap();
        writer.write_all(b"\r\n").unwrap();
        let got = rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(got.publish, vec!["pubsub.V.pressure"]);

        // The server pings; a silent client would be cut.
        writer.write_all(b"PING\r\n").unwrap();
        let mut l = String::new();
        reader.read_line(&mut l).unwrap();
        assert_eq!(l, "PONG\r\n");
    }
}
