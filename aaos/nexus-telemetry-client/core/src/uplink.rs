//! The session with the leaf: ask the nexus-connectivity-agent which vehicle this is, then
//! publish each report on `telemetry-aaos-sdv.<vin>` — the subject of Google's SDV report
//! format, with the vehicle second. Nothing stores messages
//! yet, so a report that cannot be sent is dropped and counted.

use crate::{leaf_connect, nats_wire};
use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::time::{Duration, Instant};

pub const IDENTITY_SUBJECT: &str = "nexus.identity.vin";
const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);
/// How often the count of dropped reports is logged.
const DROP_LOG_EVERY: u64 = 20;

/// A VIN as it may appear in a NATS subject: 1 to 17 letters, digits, `-` or `_` — the rule
/// the nexus-connectivity-agent applies to its own VIN (`egress_wire::is_token`), with the
/// length of a VIN.
fn valid_vin(s: &str) -> bool {
    (1..=17).contains(&s.len())
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

struct Session {
    stream: TcpStream,
    vin: String,
}

pub struct Uplink {
    addr: String,
    session: Option<Session>,
    dropped: u64,
    asks: u64,
    log: Box<dyn Fn(&str) + Send>,
    /// How long an identity request waits for its answer.
    pub identity_wait: Duration,
}

impl Uplink {
    pub fn new(addr: String, log: Box<dyn Fn(&str) + Send>) -> Self {
        Uplink {
            addr,
            session: None,
            dropped: 0,
            asks: 0,
            log,
            identity_wait: Duration::from_secs(2),
        }
    }

    pub fn dropped(&self) -> u64 {
        self.dropped
    }

    /// Publishes one report on `telemetry-aaos-sdv.<vin>`, opening the session first when there
    /// is none. A report that cannot be sent is dropped and counted.
    pub fn on_report(&mut self, bytes: &[u8]) {
        // A leaf that went away is noticed here, before the write that would seem to succeed.
        if let Some(s) = self.session.as_mut() {
            if let Err(e) = service(&mut s.stream) {
                (self.log)(&format!("the leaf went away ({e}); reconnecting"));
                self.session = None;
            }
        }
        if self.session.is_none() {
            match self.open() {
                Ok(s) => {
                    (self.log)(&format!(
                        "connected to the leaf at {}, publishing telemetry-aaos-sdv.{}",
                        self.addr, s.vin
                    ));
                    self.session = Some(s);
                }
                Err(e) => return self.drop_report(&e),
            }
        }
        let Some(s) = self.session.as_mut() else { return };
        let subject = format!("telemetry-aaos-sdv.{}", s.vin);
        if let Err(e) = s.stream.write_all(&nats_wire::pub_frame(&subject, bytes)) {
            self.session = None;
            self.drop_report(&format!("publish failed: {e}"));
        }
    }

    fn drop_report(&mut self, why: &str) {
        self.dropped += 1;
        if self.dropped == 1 || self.dropped.is_multiple_of(DROP_LOG_EVERY) {
            (self.log)(&format!("report dropped ({} so far): {why}", self.dropped));
        }
    }

    fn open(&mut self) -> Result<Session, String> {
        let target = self.addr.to_socket_addrs().ok().and_then(|mut a| a.next()).ok_or_else(|| {
            format!("cannot reach the leaf at {}: the address does not resolve", self.addr)
        })?;
        let mut stream = TcpStream::connect_timeout(&target, CONNECT_TIMEOUT)
            .and_then(leaf_connect::refuse_self)
            .map_err(|e| format!("cannot reach the leaf at {}: {e}", self.addr))?;
        let addr = self.addr.clone();
        let io = move |e: std::io::Error| format!("leaf at {addr}: {e}");
        stream.write_all(&nats_wire::connect_frame("nexus-telemetry-client")).map_err(&io)?;
        self.asks += 1;
        let inbox = format!("_INBOX.nexus-telemetry-client.{}", self.asks);
        stream.write_all(&nats_wire::sub_frame(&inbox, self.asks)).map_err(&io)?;
        stream
            .write_all(&nats_wire::pub_frame_with_reply(IDENTITY_SUBJECT, &inbox, b""))
            .map_err(&io)?;

        let deadline = Instant::now() + self.identity_wait;
        let mut buf: Vec<u8> = Vec::new();
        let mut chunk = [0u8; 2048];
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Err(format!(
                    "no answer to {IDENTITY_SUBJECT} — is the nexus-connectivity-agent running?"
                ));
            }
            stream.set_read_timeout(Some(left)).map_err(&io)?;
            match stream.read(&mut chunk) {
                Ok(0) => return Err(format!("leaf at {} closed the connection", self.addr)),
                Ok(n) => {
                    if nats_wire::server_pinged(&String::from_utf8_lossy(&chunk[..n])) {
                        stream.write_all(nats_wire::PONG).map_err(&io)?;
                    }
                    buf.extend_from_slice(&chunk[..n]);
                    if let Some((_, _, payload)) = nats_wire::take_request(&mut buf)? {
                        let vin = String::from_utf8_lossy(&payload).to_string();
                        if !valid_vin(&vin) {
                            return Err(format!(
                                "the answer to {IDENTITY_SUBJECT} is not a VIN ({} bytes)",
                                payload.len()
                            ));
                        }
                        return Ok(Session { stream, vin });
                    }
                }
                Err(e)
                    if matches!(
                        e.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) => {}
                Err(e) => return Err(io(e)),
            }
        }
    }
}

/// Reads what the leaf sent meanwhile without waiting: answers its PING, and reports a
/// closed connection as an error.
fn service(stream: &mut TcpStream) -> std::io::Result<()> {
    stream.set_read_timeout(Some(Duration::from_millis(1)))?;
    let mut chunk = [0u8; 2048];
    loop {
        match stream.read(&mut chunk) {
            Ok(0) => {
                return Err(std::io::Error::new(std::io::ErrorKind::ConnectionAborted, "closed"))
            }
            Ok(n) => {
                if nats_wire::server_pinged(&String::from_utf8_lossy(&chunk[..n])) {
                    stream.write_all(nats_wire::PONG)?;
                }
            }
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                return Ok(())
            }
            Err(e) => return Err(e),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Write};
    use std::net::{TcpListener, TcpStream};
    use std::sync::mpsc::{channel, Receiver, Sender};
    use std::sync::{Arc, Mutex};

    /// A leaf that answers the identity request with `vin` (`None`: never answers) and
    /// reports every other PUB as (subject, payload). Serves `connections` connections.
    fn leaf(vin: Option<&'static str>, connections: usize) -> (String, Receiver<(String, Vec<u8>)>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap().to_string();
        let (tx, rx) = channel();
        std::thread::spawn(move || {
            for _ in 0..connections {
                let Ok((stream, _)) = listener.accept() else { return };
                serve(stream, vin, &tx);
            }
        });
        (addr, rx)
    }

    fn serve(stream: TcpStream, vin: Option<&str>, tx: &Sender<(String, Vec<u8>)>) {
        let mut out = stream.try_clone().unwrap();
        if out.write_all(b"INFO {\"server_id\":\"test\"}\r\n").is_err() {
            return;
        }
        let mut reader = BufReader::new(stream);
        loop {
            let mut line = String::new();
            if reader.read_line(&mut line).unwrap_or(0) == 0 {
                return;
            }
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.first() != Some(&"PUB") {
                continue;
            }
            let len: usize = parts[parts.len() - 1].parse().unwrap();
            let mut payload = vec![0u8; len + 2];
            if std::io::Read::read_exact(&mut reader, &mut payload).is_err() {
                return;
            }
            payload.truncate(len);
            if parts[1] == IDENTITY_SUBJECT {
                if let Some(v) = vin {
                    let _ = write!(out, "MSG {} 1 {}\r\n{}\r\n", parts[2], v.len(), v);
                }
            } else if tx.send((parts[1].to_string(), payload)).is_err() {
                return;
            }
        }
    }

    fn uplink(addr: String) -> (Uplink, Arc<Mutex<Vec<String>>>) {
        let lines = Arc::new(Mutex::new(Vec::new()));
        let sink = lines.clone();
        let mut u = Uplink::new(addr, Box::new(move |l| sink.lock().unwrap().push(l.to_string())));
        u.identity_wait = Duration::from_millis(300);
        (u, lines)
    }

    #[test]
    fn a_report_is_published_under_the_vin_the_leaf_side_names() {
        let (addr, rx) = leaf(Some("PKG11MESH01"), 1);
        let (mut u, _) = uplink(addr);
        u.on_report(&[1, 2, 3]);
        assert_eq!(
            rx.recv_timeout(Duration::from_secs(2)).unwrap(),
            ("telemetry-aaos-sdv.PKG11MESH01".to_string(), vec![1, 2, 3])
        );
        assert_eq!(u.dropped(), 0);
    }

    #[test]
    fn an_answer_that_is_not_a_vin_is_refused_and_nothing_is_published() {
        for bad in ["", "A.B", "A B", "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ABCDE"] {
            let (addr, rx) = leaf(Some(bad), 1);
            let (mut u, lines) = uplink(addr);
            u.on_report(&[9]);
            assert!(rx.recv_timeout(Duration::from_millis(300)).is_err(), "{bad:?}");
            assert_eq!(u.dropped(), 1, "{bad:?}");
            assert!(lines.lock().unwrap().iter().any(|l| l.contains("not a VIN")), "{bad:?}");
        }
    }

    #[test]
    fn without_an_answer_the_report_is_dropped_and_the_next_one_tries_again() {
        let (addr, rx) = leaf(None, 2);
        let (mut u, lines) = uplink(addr);
        u.on_report(&[1]);
        u.on_report(&[2]);
        assert!(rx.recv_timeout(Duration::from_millis(100)).is_err());
        assert_eq!(u.dropped(), 2);
        assert!(lines.lock().unwrap().iter().any(|l| l.contains("no answer")));
    }

    #[test]
    fn after_the_leaf_restarts_the_next_report_reconnects_and_asks_again() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap().to_string();
        let (tx, rx) = channel();
        std::thread::spawn(move || {
            // First life: answer the identity request, take one report, then go away.
            let (stream, _) = listener.accept().unwrap();
            let first = stream.try_clone().unwrap();
            let t = tx.clone();
            let h = std::thread::spawn(move || serve(stream, Some("PKG11MESH01"), &t));
            std::thread::sleep(Duration::from_millis(300));
            let _ = first.shutdown(std::net::Shutdown::Both);
            let _ = h.join();
            // Second life.
            let (stream, _) = listener.accept().unwrap();
            serve(stream, Some("PKG11MESH01"), &tx);
        });
        let (mut u, lines) = uplink(addr);
        u.on_report(&[1]);
        assert_eq!(rx.recv_timeout(Duration::from_secs(2)).unwrap().1, vec![1]);
        std::thread::sleep(Duration::from_millis(600)); // the leaf is gone now
        u.on_report(&[2]); // notices, reconnects, asks again, publishes
        assert_eq!(
            rx.recv_timeout(Duration::from_secs(3)).unwrap(),
            ("telemetry-aaos-sdv.PKG11MESH01".to_string(), vec![2])
        );
        assert!(lines.lock().unwrap().iter().any(|l| l.contains("the leaf went away")));
    }

    #[test]
    fn no_leaf_at_all_drops_and_says_so() {
        let (mut u, lines) = uplink("127.0.0.1:1".to_string());
        u.on_report(&[1]);
        assert_eq!(u.dropped(), 1);
        assert!(lines.lock().unwrap().iter().any(|l| l.contains("cannot reach the leaf")));
    }
}
