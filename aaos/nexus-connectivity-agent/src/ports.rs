//! Port defaults the agent binds, and the one rule they follow.
//!
//! A default must sit outside every range the system hands out for outgoing
//! connections, or the port can be gone before the agent starts: the AAOS guests
//! measured on 2026-09-16 use 4000–5999 (`/proc/sys/net/ipv4/ip_local_port_range`,
//! with every listening system service of that guest inside it), a desktop Linux
//! uses 32768–60999. Both defaults below are outside both ranges and are no
//! framework's default — 50051, the previous discovery port, was gRPC's convention
//! and collided with a renderer on Google's AAOS media image on 2026-09-14.

/// gRPC discovery endpoint. `NEXUS_DISCOVERY_PORT` overrides it.
pub const DEFAULT_DISCOVERY_PORT: u16 = 18051;

/// `nats-server`'s monitoring endpoint on the leaf, bound to localhost.
/// `NEXUS_LEAF_MONITOR_PORT` overrides it. Mirrors NATS's own 8222.
pub const DEFAULT_LEAF_MONITOR_PORT: u16 = 18222;

/// The port named by `key`, or `default` when the variable is unset or unusable.
/// An unusable value is reported rather than silently ignored — a typo there would
/// otherwise look like the agent ignoring the operator.
pub fn from_env(key: &str, default: u16) -> u16 {
    parse(std::env::var(key).ok(), key, default)
}

fn parse(raw: Option<String>, key: &str, default: u16) -> u16 {
    match raw {
        None => default,
        Some(value) => match value.trim().parse::<u16>() {
            Ok(port) if port > 0 => port,
            _ => {
                crate::log_err!("{key}='{value}' is not a port number, using {default}");
                default
            }
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uses_the_default_when_unset() {
        assert_eq!(parse(None, "NEXUS_TEST_PORT", 18051), 18051);
    }

    #[test]
    fn honours_a_port_from_the_environment() {
        assert_eq!(parse(Some(" 19100 ".to_string()), "NEXUS_TEST_PORT", 18051), 19100);
    }

    #[test]
    fn falls_back_when_the_value_is_unusable() {
        for bad in ["harry", "0", "", "70000"] {
            assert_eq!(parse(Some(bad.to_string()), "NEXUS_TEST_PORT", 18051), 18051);
        }
    }

    /// Both defaults must stay clear of the AAOS guest range (4000–5999) and the
    /// desktop Linux range (32768–60999); see this module's documentation.
    #[test]
    fn defaults_avoid_every_ephemeral_range() {
        for port in [DEFAULT_DISCOVERY_PORT, DEFAULT_LEAF_MONITOR_PORT] {
            assert!(!(4000..=5999).contains(&port), "{port}");
            assert!(!(32768..=60999).contains(&port), "{port}");
        }
    }
}
