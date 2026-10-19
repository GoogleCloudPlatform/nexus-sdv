//! The part of the nexus-telemetry-client that needs no platform SDK: where the leaf is,
//! and the session with it. Unit-tested on the host with `cargo test`.
#[path = "../../../common/leaf_connect.rs"]
#[allow(dead_code)]
mod leaf_connect;
#[path = "../../../common/nats_wire.rs"]
#[allow(dead_code)]
mod nats_wire;
pub mod uplink;

/// The leaf runs on the same VM as the client: the Nexus-Bridge APEX carries both.
pub const LOCAL_LEAF: &str = "127.0.0.1:4222";

/// Set to `false` to keep the client from running, on a VM without a Telemetry Service.
pub const ENABLED_PROPERTY: &str = "persist.nexus.telemetry_client.enabled";

/// Whether the client runs, given the property's value: anything but `false` means yes.
pub fn enabled(value: Option<&str>) -> bool {
    value.map(str::trim) != Some("false")
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_client_uses_the_leaf_on_its_own_vm() {
        let (host, port) = super::LOCAL_LEAF.rsplit_once(':').unwrap();
        assert_eq!(host, "127.0.0.1");
        assert_eq!(port.parse::<u16>().unwrap(), 4222);
    }

    #[test]
    fn the_client_runs_unless_switched_off() {
        assert!(super::enabled(None));
        assert!(super::enabled(Some("true")));
        assert!(super::enabled(Some("")));
        assert!(!super::enabled(Some("false")));
        assert!(!super::enabled(Some(" false\n")));
    }
}
