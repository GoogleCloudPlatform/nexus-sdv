//! Minimal NATS client wire protocol — framing and reply classification only.
//!
//! No I/O: the Bridge drives these with `tokio::net::TcpStream`, the CLI with
//! `std::net::TcpStream`, and the tests with plain strings. There is no NATS
//! crate in the AOSP tree, so the protocol is hand-written; keeping it free of
//! sockets is what makes it testable at all.

/// What the server has told us about a publish so far.
#[derive(Debug, PartialEq, Eq)]
pub enum Verdict {
    /// The server acknowledged everything sent before our PING.
    Acked,
    /// The server rejected something — the payload is its message.
    Rejected(String),
    /// Nothing conclusive yet; read more.
    Pending,
}

/// Sent immediately after the INFO greeting. `verbose:false` means the server
/// does not +OK every publish; correctness comes from PING/PONG instead.
pub fn connect_frame(name: &str) -> Vec<u8> {
    format!("CONNECT {{\"verbose\":false,\"pedantic\":false,\"name\":\"{name}\"}}\r\n").into_bytes()
}

/// `PUB <subject> <len>\r\n<payload>\r\n`. The length is in **bytes**, which is
/// why the payload is `&[u8]` and never a string.
pub fn pub_frame(subject: &str, payload: &[u8]) -> Vec<u8> {
    let mut f = format!("PUB {} {}\r\n", subject, payload.len()).into_bytes();
    f.extend_from_slice(payload);
    f.extend_from_slice(b"\r\n");
    f
}

/// `PUB <subject> <reply-to> <len>\r\n<payload>\r\n` — a request. Whoever answers
/// publishes on `reply-to`, which the caller subscribed to beforehand.
pub fn pub_frame_with_reply(subject: &str, reply: &str, payload: &[u8]) -> Vec<u8> {
    let mut f = format!("PUB {subject} {reply} {}\r\n", payload.len()).into_bytes();
    f.extend_from_slice(payload);
    f.extend_from_slice(b"\r\n");
    f
}

/// `pubsub.<vin>.<topic>` — the VIN is the **second** token on purpose: a single
/// permission `pubsub.<vin>.>` then covers every topic of one vehicle, however deep,
/// and in both directions. Topic-first would need `pubsub.*.<vin>`, which breaks the
/// first time a topic has more than one token.
pub fn pubsub_subject(vin: &str, topic: &str) -> String {
    format!("pubsub.{vin}.{topic}")
}

/// `pubsub.<vin>.<topic>` → `<topic>`, for a subject this vehicle subscribed to.
///
/// A subject for another vehicle yields `None` rather than a topic: a subscription to an
/// exact subject cannot produce one, so its arrival means something upstream is wrong, and
/// carrying it on would put a foreign vehicle's data into this vehicle's Data Tunnel.
pub fn topic_from_subject(subject: &str, vin: &str) -> Option<String> {
    let rest = subject.strip_prefix("pubsub.")?;
    let rest = rest.strip_prefix(vin)?;
    let topic = rest.strip_prefix('.')?;
    if topic.is_empty() {
        return None;
    }
    Some(topic.to_string())
}

/// Forces the server to answer only after it has processed everything sent
/// before it — which is what turns a fire-and-forget publish into something
/// checkable.
pub const PING: &[u8] = b"PING\r\n";

/// Classify whatever has been read so far. Callers accumulate into a String and
/// call this after every read until it stops returning `Pending`.
pub fn classify(buffer: &str) -> Verdict {
    if let Some(at) = buffer.find("-ERR") {
        let msg = buffer[at..].lines().next().unwrap_or("-ERR").trim().to_string();
        return Verdict::Rejected(msg);
    }
    if buffer.contains("PONG") {
        return Verdict::Acked;
    }
    Verdict::Pending
}

/// `SUB <subject> <sid>\r\n`. The sid identifies the subscription in later `MSG`
/// lines; one subscription per connection is enough here, so callers pass 1.
pub fn sub_frame(subject: &str, sid: u64) -> Vec<u8> {
    format!("SUB {subject} {sid}\r\n").into_bytes()
}

/// The answer a client owes the server's `PING`. A client that stays silent is cut
/// after `ping_max` misses — which looks exactly like a flaky network, and is not.
pub const PONG: &[u8] = b"PONG\r\n";

/// True while the buffer holds a server `PING`. The line is matched whole: `PONG`
/// contains no `PING`, but a subject might, and a substring test would answer a ping
/// that never happened.
pub fn server_pinged(buf: &str) -> bool {
    buf.lines().any(|l| l.trim() == "PING")
}

/// One message off the wire: its subject, the reply subject if it is a request, its payload.
pub type Request = (String, Option<String>, Vec<u8>);

/// Refuses absurd lengths early: a corrupt or hostile stream must not make the reader
/// allocate gigabytes. The leaf announces `max_payload` 1 MiB.
const MAX_MSG_PAYLOAD: usize = 1024 * 1024;

/// Takes the first complete `MSG` off the front of an accumulating read buffer.
///
/// `MSG <subject> <sid> [reply-to] <#bytes>\r\n<payload>\r\n`. Any other protocol line
/// in front of it is dropped: the caller handles `PING` separately, and nothing else
/// carries data we consume.
///
/// `Ok(None)` means "not all of it has arrived yet" — read more and call again. `Err`
/// means the stream cannot be trusted any more; the caller closes the connection, which
/// also resynchronises it, because the next one starts at a line boundary.
///
/// Returns the subject, the reply subject when the line carries one, and the payload.
pub fn take_request(buf: &mut Vec<u8>) -> Result<Option<Request>, String> {
    loop {
        let Some(eol) = find(buf, b"\r\n") else { return Ok(None) };
        let line = String::from_utf8_lossy(&buf[..eol]).to_string();
        if !line.starts_with("MSG ") {
            buf.drain(..eol + 2); // some other control line; not ours
            continue;
        }
        let parts: Vec<&str> = line.split_whitespace().collect();
        // MSG subject sid [reply] len -> four tokens, or five with a reply subject.
        if parts.len() < 4 || parts.len() > 5 {
            return Err(format!("malformed MSG line: {line}"));
        }
        let subject = parts[1].to_string();
        let reply = (parts.len() == 5).then(|| parts[3].to_string());
        let len: usize = parts[parts.len() - 1]
            .parse()
            .map_err(|_| format!("unparseable length in: {line}"))?;
        if len > MAX_MSG_PAYLOAD {
            return Err(format!("payload length {len} out of range"));
        }
        let start = eol + 2;
        let end = start + len;
        // The payload is followed by its own CRLF, which must have arrived too.
        if buf.len() < end + 2 {
            return Ok(None);
        }
        let payload = buf[start..end].to_vec();
        buf.drain(..end + 2);
        return Ok(Some((subject, reply, payload)));
    }
}

/// As `take_request`, for callers that do not answer.
pub fn take_msg(buf: &mut Vec<u8>) -> Result<Option<(String, Vec<u8>)>, String> {
    Ok(take_request(buf)?.map(|(subject, _, payload)| (subject, payload)))
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pub_frame_carries_the_byte_count_not_the_char_count() {
        let f = pub_frame("pubsub.V1.pressure", &[0xC3, 0xA4]);
        assert_eq!(&f[..], b"PUB pubsub.V1.pressure 2\r\n\xc3\xa4\r\n");
    }

    #[test]
    fn connect_frame_names_the_client() {
        let f = connect_frame("nexus-bridge");
        let s = String::from_utf8(f).unwrap();
        assert!(s.starts_with("CONNECT {"), "got {s}");
        assert!(s.contains("\"name\":\"nexus-bridge\""), "got {s}");
        assert!(s.ends_with("\r\n"), "got {s}");
    }

    #[test]
    fn the_vin_is_the_second_token() {
        assert_eq!(pubsub_subject("PKG11MESH01", "pressure"), "pubsub.PKG11MESH01.pressure");
    }

    #[test]
    fn a_topic_with_dots_keeps_its_depth() {
        assert_eq!(
            pubsub_subject("V1", "cabin.front.temperature"),
            "pubsub.V1.cabin.front.temperature",
            "one permission pubsub.V1.> has to keep covering it"
        );
    }

    #[test]
    fn pong_means_acked() {
        assert_eq!(classify("PONG\r\n"), Verdict::Acked);
    }

    #[test]
    fn err_beats_pong_regardless_of_order() {
        // A rejection can arrive in the same read as the PONG. Reporting success
        // there is exactly the failure mode that hid a dropped message for a week.
        let v = classify("PONG\r\n-ERR 'Permissions Violation for Publication'\r\n");
        assert!(matches!(v, Verdict::Rejected(m) if m.contains("Permissions Violation")));
    }

    #[test]
    fn a_partial_read_is_pending_not_a_verdict() {
        assert_eq!(classify("INFO {\"server_id\":\"abc\""), Verdict::Pending);
    }

    #[test]
    fn the_info_greeting_alone_is_not_an_ack() {
        assert_eq!(classify("INFO {\"server_id\":\"abc\"}\r\n"), Verdict::Pending);
    }

    #[test]
    fn a_subscription_names_its_subject_and_id() {
        assert_eq!(sub_frame("pubsub.VIN1.>", 1), b"SUB pubsub.VIN1.> 1\r\n".to_vec());
    }

    #[test]
    fn a_message_survives_the_round_trip() {
        let mut buf = b"MSG pubsub.VIN1.pressure 1 3\r\nabc\r\n".to_vec();
        let (subject, payload) = take_msg(&mut buf).unwrap().unwrap();
        assert_eq!(subject, "pubsub.VIN1.pressure");
        assert_eq!(payload, b"abc");
        assert!(buf.is_empty(), "the message should be consumed");
    }

    /// A reply-to token sits between the sid and the length when present.
    #[test]
    fn a_message_with_a_reply_subject_is_read_the_same_way() {
        let mut buf = b"MSG rpc.VIN1.door 7 _INBOX.abc 2\r\nhi\r\n".to_vec();
        let (subject, payload) = take_msg(&mut buf).unwrap().unwrap();
        assert_eq!(subject, "rpc.VIN1.door");
        assert_eq!(payload, b"hi");
    }

    #[test]
    fn half_a_message_is_not_a_message_yet() {
        let full = b"MSG pubsub.VIN1.pressure 1 3\r\nabc\r\n".to_vec();
        for cut in 0..full.len() {
            let mut buf = full[..cut].to_vec();
            assert_eq!(take_msg(&mut buf).unwrap(), None, "cut at {cut}");
            assert_eq!(buf.len(), cut, "nothing may be consumed at {cut}");
        }
    }

    /// Other protocol lines must not stall the stream or be mistaken for data.
    #[test]
    fn control_lines_before_a_message_are_skipped() {
        let mut buf = b"PING\r\n+OK\r\nMSG a.b.c 1 1\r\nx\r\n".to_vec();
        let (subject, payload) = take_msg(&mut buf).unwrap().unwrap();
        assert_eq!(subject, "a.b.c");
        assert_eq!(payload, b"x");
    }

    #[test]
    fn a_server_ping_is_recognised() {
        assert!(server_pinged("PING\r\n"));
        assert!(!server_pinged("PONG\r\n"));
    }

    #[test]
    fn an_absurd_length_is_refused_instead_of_allocated() {
        let mut buf = b"MSG a.b.c 1 99999999\r\n".to_vec();
        assert!(take_msg(&mut buf).is_err());
    }

    #[test]
    fn the_topic_is_what_follows_the_vin() {
        assert_eq!(topic_from_subject("pubsub.VIN1.pressure", "VIN1"), Some("pressure".into()));
    }

    #[test]
    fn a_foreign_vin_yields_no_topic() {
        assert_eq!(topic_from_subject("pubsub.OTHER.pressure", "VIN1"), None);
        assert_eq!(topic_from_subject("pubsub.VIN12.pressure", "VIN1"), None);
    }

    #[test]
    fn a_subject_without_a_topic_yields_none() {
        assert_eq!(topic_from_subject("pubsub.VIN1", "VIN1"), None);
        assert_eq!(topic_from_subject("pubsub.VIN1.", "VIN1"), None);
        assert_eq!(topic_from_subject("telemetry.VIN1.x", "VIN1"), None);
    }

    /// What the Bridge publishes and what a subscription maps back must be inverse.
    #[test]
    fn the_subject_and_the_topic_are_inverse() {
        let subject = pubsub_subject("VIN1", "cabin-temp");
        assert_eq!(topic_from_subject(&subject, "VIN1"), Some("cabin-temp".into()));
    }

    #[test]
    fn a_publish_with_a_reply_subject_carries_it_before_the_length() {
        let f = pub_frame_with_reply("registry.WBA123.announce", "registry.WBA123.reply.7", b"{}");
        assert_eq!(f, b"PUB registry.WBA123.announce registry.WBA123.reply.7 2\r\n{}\r\n");
    }

    #[test]
    fn a_request_carries_its_reply_subject() {
        let mut buf = b"MSG nexus.identity.vin 1 _INBOX.tc.7 0\r\n\r\n".to_vec();
        let (subject, reply, payload) = take_request(&mut buf).unwrap().unwrap();
        assert_eq!(subject, "nexus.identity.vin");
        assert_eq!(reply.as_deref(), Some("_INBOX.tc.7"));
        assert!(payload.is_empty());
        assert!(buf.is_empty());
    }

    #[test]
    fn a_plain_message_has_no_reply_subject() {
        let mut buf = b"MSG a.b 1 2\r\nhi\r\n".to_vec();
        let (_, reply, payload) = take_request(&mut buf).unwrap().unwrap();
        assert_eq!(reply, None);
        assert_eq!(payload, b"hi");
    }
}
