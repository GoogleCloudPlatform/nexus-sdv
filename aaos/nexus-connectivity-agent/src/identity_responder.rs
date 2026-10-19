//! Answers "which vehicle is this?" on the leaf.
//!
//! Other programs of ours in the vehicle — the nexus-telemetry-client first — need the VIN
//! and must not get it from a second source: the nexus-connectivity-agent alone holds the
//! vehicle's identity (telemetry client spec, D5 and R4). They ask with a NATS request on
//! `nexus.identity.vin`; this answers with the VIN this process is provisioned with.
//! The subject stays on the leaf: the hub grants the vehicle no such subject.

use crate::{leaf_connect, nats_wire};
use std::io::{Read, Write};
use std::time::Duration;

pub const SUBJECT: &str = "nexus.identity.vin";
const RETRY: Duration = Duration::from_secs(3);
const READ_TICK: Duration = Duration::from_secs(5);

/// The frame that answers one request, or `None` when there is nothing to answer.
fn answer(subject: &str, reply: Option<&str>, vin: &str) -> Option<Vec<u8>> {
    if subject != SUBJECT {
        return None;
    }
    reply.map(|r| nats_wire::pub_frame(r, vin.as_bytes()))
}

/// Runs on its own thread for as long as the process lives; reconnects when the leaf goes.
pub fn spawn(leaf_addr: String, vin: String) {
    std::thread::spawn(move || loop {
        if let Err(e) = session(&leaf_addr, &vin) {
            crate::log_err!("identity responder: {e} — retrying in {}s", RETRY.as_secs());
        }
        std::thread::sleep(RETRY);
    });
}

fn session(leaf_addr: &str, vin: &str) -> Result<(), String> {
    let mut leaf =
        leaf_connect::connect(leaf_addr).map_err(|e| format!("connect leaf {leaf_addr}: {e}"))?;
    leaf.set_read_timeout(Some(READ_TICK)).map_err(|e| format!("set_read_timeout: {e}"))?;
    leaf.write_all(&nats_wire::connect_frame("nexus-connectivity-agent-identity"))
        .map_err(|e| format!("write CONNECT: {e}"))?;
    leaf.write_all(&nats_wire::sub_frame(SUBJECT, 1)).map_err(|e| format!("write SUB: {e}"))?;
    crate::log_line!("identity responder: answering on {SUBJECT}");
    let mut buf: Vec<u8> = Vec::new();
    let mut chunk = [0u8; 4096];
    loop {
        match leaf.read(&mut chunk) {
            Ok(0) => return Err("the leaf closed the connection".to_string()),
            Ok(n) => {
                if nats_wire::server_pinged(&String::from_utf8_lossy(&chunk[..n])) {
                    leaf.write_all(nats_wire::PONG).map_err(|e| format!("write PONG: {e}"))?;
                }
                buf.extend_from_slice(&chunk[..n]);
                while let Some((subject, reply, _)) = nats_wire::take_request(&mut buf)? {
                    if let Some(frame) = answer(&subject, reply.as_deref(), vin) {
                        leaf.write_all(&frame).map_err(|e| format!("write reply: {e}"))?;
                    }
                }
            }
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) => {}
            Err(e) => return Err(format!("read: {e}")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_request_is_answered_on_its_reply_subject_with_the_vin() {
        let frame = answer(SUBJECT, Some("_INBOX.tc.1"), "PKG11MESH01").unwrap();
        assert_eq!(frame, b"PUB _INBOX.tc.1 11\r\nPKG11MESH01\r\n");
    }

    #[test]
    fn a_request_without_a_reply_subject_gets_no_answer() {
        assert!(answer(SUBJECT, None, "PKG11MESH01").is_none());
    }

    #[test]
    fn another_subject_gets_no_answer() {
        assert!(answer("nexus.identity.other", Some("_INBOX.x"), "PKG11MESH01").is_none());
    }
}
