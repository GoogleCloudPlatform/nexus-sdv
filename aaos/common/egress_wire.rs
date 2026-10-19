//! Framing for the local handover between the Bridge and the connectivity agent.
//!
//! The two talk over a Unix domain socket, which carries a byte stream with no
//! message boundaries — so the boundaries are written into the bytes:
//!
//! ```text
//! [4 bytes topic length, big endian][topic][4 bytes payload length, big endian][payload]
//! ```
//!
//! The Bridge writes frames, the agent reads them and turns each into a NATS publish
//! on `pubsub.<vin>.<topic>`. The Bridge never sees a subject and never decodes a
//! payload; the agent never needs to know what the payload means.
//!
//! Pure functions, no sockets, so both sides can be tested without a device.

/// Refuses absurd lengths early: a corrupt or hostile stream must not make the reader
/// allocate gigabytes. Topics are short names, payloads are vehicle signals.
pub const MAX_TOPIC_LEN: usize = 256;
pub const MAX_PAYLOAD_LEN: usize = 1024 * 1024;

/// One NATS subject token: ASCII letters, digits, `-` and `_`. Nothing that a NATS
/// protocol line or a subject pattern gives a meaning to — no whitespace, no CR/LF, no
/// `.`, `*` or `>`.
pub fn is_token(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// A topic that can be appended to `pubsub.<vin>.` without changing what the subject
/// means: one or more tokens joined by single dots. The agent puts the topic into a
/// `PUB` line, so a CR/LF or a space in it would let the sender add protocol commands.
pub fn topic_is_safe(topic: &str) -> bool {
    topic.split('.').all(is_token)
}

/// One frame, ready to be written to the socket.
pub fn frame(topic: &str, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(8 + topic.len() + payload.len());
    out.extend_from_slice(&(topic.len() as u32).to_be_bytes());
    out.extend_from_slice(topic.as_bytes());
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    out.extend_from_slice(payload);
    out
}

/// Takes the first complete frame off the front of an accumulating read buffer.
///
/// `Ok(None)` means "not all of it has arrived yet" — read more and call again.
/// `Err` means the stream cannot be trusted any more; the caller closes the connection,
/// which also resynchronises it, because the next one starts at a frame boundary.
pub fn take_frame(buf: &mut Vec<u8>) -> Result<Option<(String, Vec<u8>)>, String> {
    let topic_len = match read_len(buf, 0)? {
        Some(n) if n > MAX_TOPIC_LEN => return Err(format!("topic length {n} out of range")),
        Some(n) => n,
        None => return Ok(None),
    };
    let payload_at = 4 + topic_len;
    let payload_len = match read_len(buf, payload_at)? {
        Some(n) if n > MAX_PAYLOAD_LEN => return Err(format!("payload length {n} out of range")),
        Some(n) => n,
        None => return Ok(None),
    };
    let end = payload_at + 4 + payload_len;
    if buf.len() < end {
        return Ok(None);
    }
    let topic = String::from_utf8(buf[4..4 + topic_len].to_vec())
        .map_err(|_| "topic is not valid UTF-8".to_string())?;
    if !topic_is_safe(&topic) {
        return Err(format!("topic {topic:?} is not a plain dotted name"));
    }
    let payload = buf[payload_at + 4..end].to_vec();
    buf.drain(..end);
    Ok(Some((topic, payload)))
}

/// A big-endian length at `at`, or `None` while fewer than four bytes have arrived.
fn read_len(buf: &[u8], at: usize) -> Result<Option<usize>, String> {
    if buf.len() < at + 4 {
        return Ok(None);
    }
    let bytes: [u8; 4] = buf[at..at + 4]
        .try_into()
        .map_err(|_| "short length field".to_string())?;
    Ok(Some(u32::from_be_bytes(bytes) as usize))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_frame_survives_the_round_trip() {
        let mut buf = frame("pressure", b"\x01\x02\x03");
        let (topic, payload) = take_frame(&mut buf).unwrap().unwrap();
        assert_eq!(topic, "pressure");
        assert_eq!(payload, b"\x01\x02\x03");
        assert!(buf.is_empty(), "the frame should be consumed");
    }

    #[test]
    fn two_frames_in_one_buffer_come_out_in_order() {
        let mut buf = frame("a", b"one");
        buf.extend(frame("b", b"two"));
        assert_eq!(take_frame(&mut buf).unwrap().unwrap().0, "a");
        assert_eq!(take_frame(&mut buf).unwrap().unwrap().1, b"two");
        assert_eq!(take_frame(&mut buf).unwrap(), None);
    }

    /// A stream delivers whatever has arrived, which is regularly half a frame.
    #[test]
    fn half_a_frame_is_not_a_frame_yet() {
        let full = frame("pressure", b"payload");
        for cut in 0..full.len() {
            let mut buf = full[..cut].to_vec();
            assert_eq!(take_frame(&mut buf).unwrap(), None, "cut at {cut}");
            assert_eq!(buf.len(), cut, "nothing may be consumed at {cut}");
        }
    }

    #[test]
    fn an_empty_payload_is_a_valid_frame() {
        let mut buf = frame("heartbeat", b"");
        let (topic, payload) = take_frame(&mut buf).unwrap().unwrap();
        assert_eq!(topic, "heartbeat");
        assert!(payload.is_empty());
    }

    #[test]
    fn absurd_lengths_are_refused_instead_of_allocated() {
        let mut buf = (MAX_TOPIC_LEN as u32 + 1).to_be_bytes().to_vec();
        buf.extend([0u8; 8]);
        assert!(take_frame(&mut buf).is_err());

        let mut buf = frame("t", b"");
        buf[5..9].copy_from_slice(&(MAX_PAYLOAD_LEN as u32 + 1).to_be_bytes());
        assert!(take_frame(&mut buf).is_err());
    }

    #[test]
    fn plain_and_dotted_topics_are_accepted() {
        for ok in ["pressure", "door-control", "a_b", "vehicle.speed", "A1.b2.c-3"] {
            assert!(topic_is_safe(ok), "{ok:?}");
            let mut buf = frame(ok, b"x");
            assert_eq!(take_frame(&mut buf).unwrap().unwrap().0, ok);
        }
    }

    /// The agent writes the topic into `PUB pubsub.<vin>.<topic> <len>\r\n`. Anything
    /// that a NATS line or a subject pattern treats specially must never get there, and
    /// the connection is closed rather than the frame skipped: a sender that sends one
    /// cannot be trusted with the next.
    #[test]
    fn a_topic_that_could_change_the_nats_line_is_refused() {
        let attacks = [
            "x 0\r\n\r\nSUB > 9\r\nPUB registry.V.grant 2\r\n{}",
            "a b",
            "a\r\nb",
            "a\nb",
            "a\tb",
            "*",
            ">",
            "a.*",
            "a.>",
            "a..b",
            ".a",
            "a.",
            "",
            "ä",
            "a\0b",
        ];
        for bad in attacks {
            assert!(!topic_is_safe(bad), "{bad:?}");
            let mut buf = frame(bad, b"payload");
            assert!(take_frame(&mut buf).is_err(), "{bad:?} got through take_frame");
        }
    }

    #[test]
    fn a_token_is_letters_digits_dash_and_underscore() {
        assert!(is_token("SMOKEKARSTEN01"));
        assert!(is_token("ab-12_XY"));
        for bad in ["", "a.b", "a b", "a*", "a>", "a/b", "a\n"] {
            assert!(!is_token(bad), "{bad:?}");
        }
    }

    #[test]
    fn a_topic_that_is_not_text_is_refused() {
        let mut buf = 1u32.to_be_bytes().to_vec();
        buf.push(0xff);
        buf.extend(0u32.to_be_bytes());
        assert!(take_frame(&mut buf).is_err());
    }
}
