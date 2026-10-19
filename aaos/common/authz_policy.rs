//! The subset of the AAOS-SDV `AuthzPolicy` textproto that the Bridge needs.
//!
//! The Bridge reads the very file the platform enforces, so what it subscribes to and
//! publishes cannot drift from what it is permitted to do. There is no textproto parser
//! in the AOSP Rust tree and the subset in use is four field names in flat entries, so it
//! is parsed here — the same reasoning as the hand-written NATS framing next door.
//!
//! Constructs this does not understand (the deprecated `acls`, `unit_types` and
//! `service_units`, and `server`/`client` for RPC) are ignored rather than rejected: this
//! parser decides what the Bridge *does*, never what the platform *allows*.

/// One declaration: a message type, and either the topics it names or a grant covering
/// every topic of that type.
#[derive(Debug, PartialEq, Eq)]
pub struct Entry {
    pub message: String,
    pub topics: Vec<String>,
    pub all_topics: bool,
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct Policy {
    pub publishers: Vec<Entry>,
    pub subscribers: Vec<Entry>,
    /// The top-level `allow_read_all`: discover and subscribe to every publication.
    pub read_all: bool,
}

/// Reads every `publisher` and `subscriber` entry. Entries may span lines and write a
/// space before the colon — `vsidlc` generates both. Comments (`#` to the end of a line)
/// are dropped first, so a brace inside a comment cannot open an entry. An entry without a
/// message, or one that never closes, is an error: the file is the Bridge's own, and a
/// malformed entry means the build produced something nobody intended.
pub fn parse(text: &str) -> Result<Policy, String> {
    let clean: String = text
        .lines()
        .map(|l| l.split('#').next().unwrap_or(""))
        .collect::<Vec<_>>()
        .join("\n");
    let mut policy = Policy::default();
    let mut rest = clean.as_str();
    // What stands outside every entry: where a top-level field such as allow_read_all is.
    let mut outside = String::new();
    while let Some(open) = rest.find('{') {
        outside.push_str(&rest[..open]);
        outside.push('\n');
        let mut words: Vec<&str> = rest[..open].split_whitespace().collect();
        let kind = words.pop().unwrap_or("");
        no_bodyless_entry(&words)?;
        let Some(close) = rest[open..].find('}') else {
            return Err(format!("entry never closes: {}", rest[..open].trim()));
        };
        let body = &rest[open + 1..open + close];
        rest = &rest[open + close + 1..];
        if kind != "publisher" && kind != "subscriber" {
            continue;
        }
        let entry = Entry {
            message: quoted_value(body, "message")
                .ok_or_else(|| format!("{kind} entry without a message: {}", body.trim()))?,
            topics: quoted_values(body, "topic"),
            all_topics: field_is_true(body, "allow_all_topics"),
        };
        if kind == "publisher" {
            policy.publishers.push(entry);
        } else {
            policy.subscribers.push(entry);
        }
    }
    no_bodyless_entry(&rest.split_whitespace().collect::<Vec<_>>())?;
    outside.push_str(rest);
    policy.read_all = field_is_true(&outside, "allow_read_all");
    Ok(policy)
}

/// A `publisher` or `subscriber` with no `{ … }` after it.
fn no_bodyless_entry(words: &[&str]) -> Result<(), String> {
    match words.iter().find(|w| **w == "publisher" || **w == "subscriber") {
        Some(kind) => Err(format!("{kind} entry without a body")),
        None => Ok(()),
    }
}

/// Where `field` starts a token in `body` and is followed by a colon: the text after that
/// colon, once per occurrence. A token start is the beginning, whitespace or `{`, so
/// `topic` does not match inside `allow_all_topics`.
fn field_values<'a>(body: &'a str, field: &str) -> Vec<&'a str> {
    let mut out = Vec::new();
    let mut from = 0;
    while let Some(found) = body[from..].find(field) {
        let at = from + found;
        from = at + field.len();
        let starts_token =
            body[..at].chars().last().is_none_or(|c| c.is_whitespace() || c == '{');
        if let Some(value) = body[from..].trim_start().strip_prefix(':') {
            if starts_token {
                out.push(value.trim_start());
            }
        }
    }
    out
}

/// Every `<field> : "<value>"` in one entry body, in order.
fn quoted_values(body: &str, field: &str) -> Vec<String> {
    field_values(body, field)
        .into_iter()
        .filter_map(|v| v.strip_prefix('"'))
        .filter_map(|v| v.find('"').map(|close| v[..close].to_string()))
        .collect()
}

fn quoted_value(body: &str, field: &str) -> Option<String> {
    quoted_values(body, field).into_iter().next()
}

fn field_is_true(body: &str, field: &str) -> bool {
    field_values(body, field).iter().any(|v| v.starts_with("true"))
}

/// `<unit_type> <topic> <bytes>` per line, comments and blank lines ignored.
///
/// A line that does not parse is skipped rather than fatal, unlike in the policy: a
/// missing slot size costs one publication and falls back to a default, while refusing the
/// whole file would cost all of them.
pub fn parse_slot_sizes(text: &str) -> Vec<(String, String, u32)> {
    let mut out = Vec::new();
    for raw in text.lines() {
        let line = raw.split('#').next().unwrap_or("").trim();
        if line.is_empty() {
            continue;
        }
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() != 3 {
            continue;
        }
        if let Ok(size) = parts[2].parse::<u32>() {
            out.push((parts[0].to_string(), parts[1].to_string(), size));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    #[test]
    fn a_top_level_read_all_is_seen_and_keeps_the_entries() {
        let p = parse("allow_read_all: true\nsubscriber { message: \"a.B\" topic: \"t\" }").unwrap();
        assert!(p.read_all);
        assert_eq!(p.subscribers.len(), 1);
        assert!(!parse("subscriber { message: \"a.B\" topic: \"t\" }").unwrap().read_all);
        // Inside an entry it is not the policy's.
        assert!(!parse("subscriber { message: \"a.B\" allow_read_all: true }").unwrap().read_all);
    }

    use super::*;

    /// The Bridge's real file, as it ships in the APEX.
    const REAL: &str = r#"
# Nexus Bridge authorization (AuthzPolicy declaration model).
# proto-message: AuthzPolicy
subscriber { message: "com.android.nexus.aaos_nexus_sdv_sample.NexusPressure" topic: "pressure" }

publisher { message: "com.android.nexus.aaos_nexus_sdv_sample.NexusCommand" topic: "command" }
"#;

    #[test]
    fn the_declared_entries_are_read() {
        let p = parse(REAL).unwrap();
        assert_eq!(p.subscribers.len(), 1);
        assert_eq!(
            p.subscribers[0].message,
            "com.android.nexus.aaos_nexus_sdv_sample.NexusPressure"
        );
        assert_eq!(p.subscribers[0].topics, vec!["pressure".to_string()]);
        assert_eq!(p.publishers.len(), 1);
        assert_eq!(p.publishers[0].topics, vec!["command".to_string()]);
    }

    #[test]
    fn comments_and_blank_lines_are_ignored() {
        assert!(parse("# nothing but a comment\n\n").unwrap().subscribers.is_empty());
    }

    #[test]
    fn a_comment_after_an_entry_does_not_swallow_it() {
        let p = parse(r#"subscriber { message: "a.B" topic: "x" }  # why"#).unwrap();
        assert_eq!(p.subscribers[0].topics, vec!["x".to_string()]);
    }

    #[test]
    fn several_topics_in_one_entry_are_all_read() {
        let p = parse(r#"subscriber { message: "a.B" topic: "x" topic: "y" }"#).unwrap();
        assert_eq!(p.subscribers[0].topics, vec!["x".to_string(), "y".to_string()]);
    }

    #[test]
    fn allow_all_topics_is_recognised_and_is_not_a_topic() {
        let p = parse(r#"publisher { message: "a.B" allow_all_topics: true }"#).unwrap();
        assert!(p.publishers[0].all_topics);
        assert!(p.publishers[0].topics.is_empty());
    }

    #[test]
    fn an_entry_without_a_message_is_an_error() {
        assert!(parse(r#"subscriber { topic: "x" }"#).is_err());
    }

    #[test]
    fn an_entry_without_a_body_is_an_error() {
        assert!(parse("subscriber").is_err());
    }

    #[test]
    fn slot_sizes_are_read_by_position() {
        let got = parse_slot_sizes("# comment\ncom.a.B command 4096\n");
        assert_eq!(got, vec![("com.a.B".to_string(), "command".to_string(), 4096)]);
    }

    #[test]
    fn a_malformed_slot_line_is_skipped_not_fatal() {
        let got = parse_slot_sizes("com.a.B command\ncom.a.B other 8192\ncom.a.B third xyz\n");
        assert_eq!(got, vec![("com.a.B".to_string(), "other".to_string(), 8192)]);
    }

    /// What vsidlc generated for the Bridge's catalog on 2026-10-07, after the licence header.
    const GENERATED: &str = r#"# proto-file:
# //system/software_defined_vehicle/middleware/service_authz/proto/sdv/authz/policy/authz_policy.proto
# proto-message: AuthzPolicy

publisher {
  message : "com.nexussdv.sample.PressureLimit"
  topic : "pressure-limit"
}

publisher {message : "com.nexussdv.sample.DoorCommand" topic : "door-command"}

subscriber {
  message : "com.android.sdv.sample.quickstart.TirePressure"
  topic : "pressure"
}
"#;

    #[test]
    fn generated_permissions_are_read_whole() {
        let p = parse(GENERATED).unwrap();
        let pubs: Vec<(&str, &str)> =
            p.publishers.iter().map(|e| (e.message.as_str(), e.topics[0].as_str())).collect();
        assert_eq!(
            pubs,
            vec![
                ("com.nexussdv.sample.PressureLimit", "pressure-limit"),
                ("com.nexussdv.sample.DoorCommand", "door-command"),
            ]
        );
        assert_eq!(p.subscribers[0].message, "com.android.sdv.sample.quickstart.TirePressure");
        assert_eq!(p.subscribers[0].topics, vec!["pressure"]);
    }

    #[test]
    fn an_entry_that_never_closes_is_an_error() {
        assert!(parse("subscriber {\n  message : \"a.B\"\n").is_err());
    }

    #[test]
    fn allow_all_topics_with_a_space_before_the_colon_is_recognised() {
        let p = parse("publisher {\n  message : \"a.B\"\n  allow_all_topics : true\n}").unwrap();
        assert!(p.publishers[0].all_topics);
        assert!(p.publishers[0].topics.is_empty());
    }
}
