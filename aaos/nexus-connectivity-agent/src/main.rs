mod bridge_link;
mod clock;
mod credentials;
// Shared with the Bridge and the sample CLI, included by path because the AAOS tree
// builds these through Soong, which has no crate graph for our own files. Both halves
// of the handover framing are used here now: read for what the vehicle sends out,
// write for what the cloud sends in.
#[path = "../../common/egress_wire.rs"]
mod egress_wire;
// The nexus-connectivity-agent publishes telemetry and subscribes to commands, so it uses
// neither `command_subject` (the cloud composes those) nor the classify path's unused half.
#[path = "../../common/nats_wire.rs"]
#[allow(dead_code)]
mod nats_wire;
// Both the Bridge and the nexus-connectivity-agent read this one file: the Bridge to know
// what it may carry, this process to know which subjects to subscribe to on the vehicle's
// behalf. One declaration, two readers — a second list would drift from it.
#[path = "../../common/authz_policy.rs"]
#[allow(dead_code)]
mod authz_policy;
// The Bridge's consumer again — included here because this crate is the host-runnable
// place to test the shared sources.
#[path = "../../common/leaf_connect.rs"]
mod leaf_connect;
// Read all: only the list format is needed here; what to subscribe is the Bridge's part.
#[path = "../../common/read_all.rs"]
#[allow(dead_code)]
mod read_all;
#[path = "../../common/slot_wire.rs"]
#[allow(dead_code)]
mod slot_wire;
mod csr;
mod discovery;
mod env_file;
mod http_tls;
mod identity_responder;
mod jwt;
mod leaf;
mod leaf_status;
mod log_sink;
mod offer;
mod ports;
mod private_file;
mod provisioning;
mod registry_link;
#[cfg(test)]
mod leaf_self_connect_test;

use std::env;
use std::path::PathBuf;
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

// Bounds on the expiry-driven refresh schedule (Global Constraints: never a fixed
// interval, but a raw "80% of whatever the token says" is unbounded in both directions —
// a misconfigured 1-second TTL would crash-loop without a floor, and a 1-year TTL would
// leave the agent looking dead for months without a ceiling / natural health-check beat).
const MIN_REFRESH_SECS: i64 = 30;
const MAX_REFRESH_SECS: i64 = 24 * 60 * 60;
const REFRESH_FRACTION: f64 = 0.8;
const HEALTH_CHECK_INTERVAL: Duration = Duration::from_secs(10);
const FETCH_RETRY_BACKOFF: Duration = Duration::from_secs(15);
// A state change is logged immediately; an unchanged state at most this often, so the
// log stays readable over days while still proving the agent was alive at a given time.
const STATUS_REPORT_INTERVAL_SECS: i64 = 60;

fn now_unix() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before 1970")
        .as_secs() as i64
}

fn compute_sleep_secs(exp: i64) -> i64 {
    // `exp` comes out of a token the cloud issued; a hostile or corrupt value must clamp,
    // not overflow.
    let remaining = exp.saturating_sub(now_unix());
    let target = (remaining as f64 * REFRESH_FRACTION) as i64;
    target.clamp(MIN_REFRESH_SECS, MAX_REFRESH_SECS)
}

fn env_or(key: &str, default: &str) -> String {
    env::var(key).unwrap_or_else(|_| default.to_string())
}

fn env_opt(key: &str) -> Option<String> {
    env::var(key).ok().filter(|v| !v.is_empty())
}

/// The Bridge's own declaration, inside the APEX both components ship in. Overridable for
/// a test on a differently packaged Bridge.
const BRIDGE_POLICY_PATH: &str =
    "/apex/com.android.nexus.aaos_nexus_sdv_tcu/etc/permissions/com.android.nexus.aaos_nexus_sdv_tcu.NexusBridge.permissions";

/// The topics the Bridge declares that it publishes — which is exactly what the cloud may
/// send to this vehicle, so it is exactly what to subscribe to.
///
/// An unreadable policy is not fatal: the outbound direction does not depend on it, and a
/// vehicle that still reports is worth more than one that stops because nothing can reach
/// it. The reason is logged with the path.
fn inbound_topics() -> Vec<String> {
    let path = env_or("NEXUS_BRIDGE_POLICY", BRIDGE_POLICY_PATH);
    let text = match std::fs::read_to_string(&path) {
        Ok(t) => t,
        Err(e) => {
            crate::log_err!("cannot read the Bridge policy at {path}: {e} — sending only");
            return Vec::new();
        }
    };
    match authz_policy::parse(&text) {
        Ok(policy) => policy
            .publishers
            .iter()
            .flat_map(|e| e.topics.clone())
            .collect(),
        Err(e) => {
            crate::log_err!("cannot parse the Bridge policy at {path}: {e} — sending only");
            Vec::new()
        }
    }
}

/// Read all (experimental): the publications the Bridge found at its start, written beside
/// its socket. Read once, at this process's start — a new list needs a restart.
const BRIDGE_DISCOVERED_PATH: &str =
    "/data/service_bundle_data/com.android.nexus.aaos_nexus_sdv_tcu/NexusBridge/discovered";

/// The offer comes from the same policy the inbound subscriptions come from, plus what the
/// Bridge discovered under read all. An unreadable policy offers nothing; `inbound_topics`
/// has already logged why. A missing list means read all is off.
fn offers() -> Vec<offer::Offer> {
    let path = env_or("NEXUS_BRIDGE_POLICY", BRIDGE_POLICY_PATH);
    // Logged, because the Bridge rewrites the list only at its own start: whoever tests read
    // all must see what this process offered, and restart the Bridge before this process.
    let discovered = match std::fs::read_to_string(BRIDGE_DISCOVERED_PATH) {
        Ok(t) => {
            crate::log_line!(
                "read all: offering {} publication(s) the Bridge found ({BRIDGE_DISCOVERED_PATH})",
                read_all::parse_list(&t).len()
            );
            Some(t)
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => {
            crate::log_err!("read all: cannot read {BRIDGE_DISCOVERED_PATH}: {e} — offering the policy only");
            None
        }
    };
    std::fs::read_to_string(&path)
        .map(|t| offers_with(&t, discovered.as_deref()))
        .unwrap_or_default()
}

fn offers_with(policy_text: &str, discovered: Option<&str>) -> Vec<offer::Offer> {
    let Ok(policy) = authz_policy::parse(policy_text) else {
        return Vec::new();
    };
    let mut offers = offer::from_policy(&policy);
    if let Some(list) = discovered {
        offers.extend(offer::from_discovered(&read_all::parse_list(list)));
    }
    offers
}

/// `NEXUS_LEAF_TLS`: `on` or `off`, nothing else. Like the provisioning switch, an
/// unusable value stops the process rather than silently meaning one of the two.
fn leaf_tls_switch(value: &str) -> Result<bool, String> {
    match value {
        "on" => Ok(true),
        "off" => Ok(false),
        other => Err(format!("NEXUS_LEAF_TLS must be \"on\" or \"off\", not {other:?}")),
    }
}

/// A grant that differs from the one in force means one reconnect; the same grant told
/// again means none — the registry repeats itself after every announce.
fn should_reconnect(in_force: &Option<registry_link::Grant>, told: &registry_link::Grant) -> bool {
    in_force.as_ref() != Some(told)
}

/// Least time between two restarts caused by a grant. A grant that differs from the one in
/// force is applied at once, but the uplink is the vehicle's only way out: whoever can
/// reach `registry.<vin>.grant` must not be able to keep it down by alternating two grants.
const MIN_GRANT_RESTART_INTERVAL_SECS: i64 = 30;

/// True when a grant-driven restart is allowed now: none has happened yet, or the last
/// one is long enough ago.
fn grant_restart_due(last: Option<i64>, now: i64) -> bool {
    last.is_none_or(|t| now.saturating_sub(t) >= MIN_GRANT_RESTART_INTERVAL_SECS)
}

/// Appended to the leaf status line, whose prefix the acceptance check greps for.
fn status_suffix(in_force: &Option<registry_link::Grant>) -> String {
    match in_force {
        Some(g) => format!(" grant=pub:{} sub:{}", g.publish.len(), g.subscribe.len()),
        None => " grant=none".to_string(),
    }
}

fn main() {
    // An init service has no environment of its own: its configuration comes from the
    // file provisioning wrote (env_file.rs), before anything reads a variable.
    let args: Vec<String> = env::args().collect();
    if let Some(path) = env_file::path_from_args(&args) {
        let text = env_file::read_waiting(
            std::path::Path::new(&path),
            Duration::from_secs(10),
            None,
        )
        .unwrap_or_else(|e| {
            eprintln!("cannot read the configuration {path}: {e}");
            std::process::exit(1);
        });
        match env_file::parse(&text) {
            Ok(vars) => env_file::apply(&vars),
            Err(e) => {
                eprintln!("configuration {path}: {e}");
                std::process::exit(1);
            }
        }
    }
    log_sink::init_from_env();
    let vin = env::var("NEXUS_VIN").expect("NEXUS_VIN must be set");
    // The VIN becomes a NATS subject token and part of file names. A `.`, `*`, `>` or a
    // space in it would change what is subscribed and published, so stop before any of it.
    if !egress_wire::is_token(&vin) {
        crate::log_err!(
            "NEXUS_VIN={vin:?} is not usable: letters, digits, '-' and '_' only, and not empty"
        );
        std::process::exit(1);
    }
    let cloud_nats_host =
        env::var("NEXUS_CLOUD_NATS_HOST").expect("NEXUS_CLOUD_NATS_HOST must be set");
    // Where the vehicle's certificates live and where this process writes the
    // ones it obtains. The default is the current directory: the scripts launch
    // the process from the run directory anyway, and there is no separate folder
    // holding a second binary to point at any more.
    let run_dir = PathBuf::from(env_or("NEXUS_RUN_DIR", "."));
    // TLS on the leaf node link: the operational certificate is the vehicle's identity at
    // the hub, the hub's CA the trust anchor. Off only for a hub that has no TLS yet —
    // provision-and-run.sh sets it from whether the anchor could be fetched.
    let leaf_tls = match leaf_tls_switch(&env_or("NEXUS_LEAF_TLS", "on")) {
        Ok(false) => None,
        Ok(true) => Some(leaf::LeafTls {
            cert: run_dir.join("certificates/operational-cert.pem"),
            key: run_dir.join("certificates/operational-key.pem"),
            ca: run_dir.join("certificates/NATS_LEAF_TLS_CA.pem"),
            // The name on the hub's certificate; the pinned address is dialled, the name
            // is verified. Defaults to the host when that already is the name.
            server_name: env_or("NEXUS_CLOUD_NATS_NAME", &cloud_nats_host),
        }),
        Err(e) => {
            crate::log_err!("{e}");
            std::process::exit(1);
        }
    };
    let nats_server_bin = PathBuf::from(env_or("NEXUS_NATS_SERVER_BIN", "/data/local/tmp/nats-server"));
    let leaf_conf_path = PathBuf::from(env_or("NEXUS_LEAF_CONF", "/data/local/tmp/leaf.conf"));
    let leaf_log_path = PathBuf::from(env_or("NEXUS_LEAF_LOG", "/data/local/tmp/nats-leaf.log"));

    // Factory identity naming mirrors run-vehicle-client.sh's own convention
    // (certificates/vehicle-<VIN>-factory-gcp-{chain,key}.pem) so the same pre-provisioned
    // files work whether they were seeded for this agent or generated once via that script.
    let factory_cert = PathBuf::from(env_or(
        "NEXUS_FACTORY_CERT",
        &format!("certificates/vehicle-{vin}-factory-gcp-chain.pem"),
    ));
    let factory_key = PathBuf::from(env_or(
        "NEXUS_FACTORY_KEY",
        &format!("certificates/vehicle-{vin}-factory-gcp-key.pem"),
    ));
    let provisioning_config = credentials::ProvisioningConfig {
        vin: vin.clone(),
        pki_strategy: env_or("NEXUS_PKI_STRATEGY", "remote"),
        factory_cert,
        factory_key,
        registration_url: env::var("NEXUS_REGISTRATION_URL")
            .expect("NEXUS_REGISTRATION_URL must be set"),
        keycloak_url: env::var("NEXUS_KEYCLOAK_URL").expect("NEXUS_KEYCLOAK_URL must be set"),
        nats_url: env::var("NEXUS_NATS_URL").expect("NEXUS_NATS_URL must be set"),
        registration_resolve_ip: env_opt("NEXUS_REGISTRATION_IP"),
        keycloak_resolve_ip: env_opt("NEXUS_KEYCLOAK_IP"),
    };

    crate::log_line!("nexus-connectivity-agent starting: vin={vin} cloud_nats_host={cloud_nats_host}");
    crate::log_line!(
        "leaf TLS: {}",
        if leaf_tls.is_some() { "on (operational certificate)" } else { "off" }
    );

    // The switch is an environment variable, so the log is the only place a
    // tester can see which of the two paths a run actually took. An unusable
    // value stops the process rather than falling back, because a silent
    // fallback would let an acceptance run prove the wrong thing.
    let provisioning = match credentials::selected() {
        Ok(p) => p,
        Err(e) => {
            crate::log_err!("{e}");
            std::process::exit(1);
        }
    };
    crate::log_line!("provisioning path: {provisioning}");

    let leaf_host = env::var("NEXUS_LEAF_HOST").expect("NEXUS_LEAF_HOST must be set");
    let discovery_port = discovery::port_from_env();
    thread::spawn(move || discovery::serve_blocking(leaf_host, discovery_port));

    // Both directions of the local handover share the Bridge's Unix socket: what a vehicle
    // service published goes out to pubsub.<vin>.<topic>, and what the cloud publishes on a
    // subject the Bridge declared comes back in for it to put on the Data Tunnel.
    let link = bridge_link::Config {
        socket_path: env_or("NEXUS_BRIDGE_SOCKET", bridge_link::DEFAULT_SOCKET),
        leaf_addr: env_or("NEXUS_LEAF_ADDR", "127.0.0.1:4222"),
        vin: vin.clone(),
        inbound_topics: inbound_topics(),
    };
    thread::spawn(move || bridge_link::run(link));

    let monitor_port = ports::from_env("NEXUS_LEAF_MONITOR_PORT", ports::DEFAULT_LEAF_MONITOR_PORT);
    // The registry conversation: announce what the Bridge declares, follow the grant. A
    // grant that differs from the one in force is applied in the health loop below, by
    // re-establishing the upstream connection so the auth-callout issues it.
    // Other programs of ours ask the vehicle's identity here rather than keep a copy.
    identity_responder::spawn(env_or("NEXUS_LEAF_ADDR", "127.0.0.1:4222"), vin.clone());
    let grant_rx = registry_link::spawn(registry_link::Config {
        leaf_addr: env_or("NEXUS_LEAF_ADDR", "127.0.0.1:4222"),
        vin: vin.clone(),
        offers: offers(),
        monitor_port,
    });
    let mut grant_in_force: Option<registry_link::Grant> = None;
    let mut pending_grant: Option<registry_link::Grant> = None;
    let mut last_grant_restart: Option<i64> = None;
    let mut server = leaf::NatsServer::new(
        nats_server_bin,
        leaf_conf_path,
        leaf_log_path,
        monitor_port,
    );
    let mut last_status = String::new();
    let mut next_status_report = 0_i64;

    loop {
        let creds = match credentials::fetch(&run_dir, &provisioning_config) {
            Ok(c) => c,
            Err(e) => {
                crate::log_err!("credential fetch failed: {e} — retrying in {FETCH_RETRY_BACKOFF:?}");
                thread::sleep(FETCH_RETRY_BACKOFF);
                continue;
            }
        };

        let exp = match jwt::expiry_unix(&creds.jwt) {
            Ok(exp) => exp,
            Err(e) => {
                crate::log_err!("failed to parse JWT expiry: {e} — retrying in {FETCH_RETRY_BACKOFF:?}");
                thread::sleep(FETCH_RETRY_BACKOFF);
                continue;
            }
        };

        if let Err(e) = server.restart_with(&cloud_nats_host, &creds.jwt, leaf_tls.as_ref()) {
            crate::log_err!("failed to start nats-server: {e} — retrying in {FETCH_RETRY_BACKOFF:?}");
            thread::sleep(FETCH_RETRY_BACKOFF);
            continue;
        }

        let sleep_secs = compute_sleep_secs(exp);
        crate::log_line!(
            "credentials fetched (operational cert: {:?}); exp={exp}; next refresh in {sleep_secs}s",
            creds.operational_cert_path
        );
        let deadline = now_unix() + sleep_secs;

        // Health-check loop: same unconditional-restart philosophy as the cron this
        // agent replaces ("no separate watchdog"), just scoped to *this* wait window and
        // driven by the real expiry instead of a blind 4-minute tick.
        while now_unix() < deadline {
            thread::sleep(HEALTH_CHECK_INTERVAL);

            // A grant that differs from the one in force: re-establish the upstream
            // connection so the auth-callout issues the new permissions. Exactly once per
            // change, however often the registry repeats itself. Grants that queued up
            // since the last tick collapse to the newest, and a change is held back until
            // the last grant-driven restart is MIN_GRANT_RESTART_INTERVAL_SECS old.
            while let Ok(told) = grant_rx.try_recv() {
                pending_grant = Some(told);
            }
            if let Some(told) = pending_grant.take() {
                if !should_reconnect(&grant_in_force, &told) {
                    // Same as the one in force: nothing to do.
                } else if grant_restart_due(last_grant_restart, now_unix()) {
                    crate::log_line!(
                        "grant changed: pub={} sub={} — re-establishing the upstream connection",
                        told.publish.len(),
                        told.subscribe.len()
                    );
                    if let Err(e) = server.restart_with(&cloud_nats_host, &creds.jwt, leaf_tls.as_ref()) {
                        crate::log_err!("restart after grant change failed: {e}");
                    }
                    grant_in_force = Some(told);
                    last_grant_restart = Some(now_unix());
                } else {
                    crate::log_line!(
                        "grant changed: held back, the last grant-driven restart was under {MIN_GRANT_RESTART_INTERVAL_SECS}s ago"
                    );
                    pending_grant = Some(told);
                }
            }

            // Asked of the leaf itself, not inferred from its log: an answer proves the
            // process is alive, and the count proves whether the link to the cloud stands.
            let status = leaf_status::status_line(monitor_port) + &status_suffix(&grant_in_force);
            if status != last_status || now_unix() >= next_status_report {
                crate::log_line!("{status}");
                last_status = status;
                next_status_report = now_unix() + STATUS_REPORT_INTERVAL_SECS;
            }

            if !server.is_running() {
                crate::log_err!("nats-server exited unexpectedly — restarting with the same (still-valid) credentials");
                if let Err(e) = server.restart_with(&cloud_nats_host, &creds.jwt, leaf_tls.as_ref()) {
                    crate::log_err!("restart failed: {e}");
                }
            }
        }
    }
}

#[cfg(test)]
mod grant_tests {
    use super::*;
    use crate::registry_link::Grant;

    #[test]
    fn identical_grant_means_no_reconnect() {
        let a = Grant { publish: vec!["pubsub.V.p".into()], subscribe: vec![] };
        let same = a.clone();
        let other = Grant { publish: vec!["pubsub.V.p".into()], subscribe: vec!["pubsub.V.c".into()] };
        assert!(!should_reconnect(&Some(a.clone()), &same));
        assert!(should_reconnect(&Some(a), &other));
        assert!(should_reconnect(&None, &Grant::default()), "the first grant told is applied once");
    }

    #[test]
    fn a_grant_restart_waits_for_the_minimum_interval() {
        assert!(grant_restart_due(None, 1_000), "the first one is never held back");
        assert!(!grant_restart_due(Some(1_000), 1_000));
        assert!(!grant_restart_due(Some(1_000), 1_029));
        assert!(grant_restart_due(Some(1_000), 1_030));
        assert!(grant_restart_due(Some(1_000), 5_000));
        assert!(!grant_restart_due(Some(i64::MAX), i64::MIN), "a clock that jumped back must not overflow");
    }

    /// The expiry is read from a token the cloud issued; an absurd one must clamp.
    #[test]
    fn a_hostile_expiry_clamps_instead_of_overflowing() {
        assert_eq!(compute_sleep_secs(i64::MIN), MIN_REFRESH_SECS);
        assert_eq!(compute_sleep_secs(i64::MAX), MAX_REFRESH_SECS);
        assert_eq!(compute_sleep_secs(0), MIN_REFRESH_SECS);
    }

    /// Like the provisioning switch: an unusable value stops the process rather than
    /// silently meaning "on" — a silent default would let an acceptance run prove the
    /// wrong thing.
    #[test]
    fn the_leaf_tls_switch_accepts_on_and_off_only() {
        assert_eq!(leaf_tls_switch("on"), Ok(true));
        assert_eq!(leaf_tls_switch("off"), Ok(false));
        for bad in ["", "yes", "OFF", "0", "true"] {
            assert!(leaf_tls_switch(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn the_status_line_keeps_its_prefix_and_names_the_grant() {
        let g = Grant { publish: vec!["a".into(), "b".into()], subscribe: vec!["c".into()] };
        assert_eq!(status_suffix(&Some(g)), " grant=pub:2 sub:1");
        assert_eq!(status_suffix(&None), " grant=none");
    }

    /// Read all: what the Bridge found at its start joins the offer; no list, no change.
    #[test]
    fn the_bridge_s_discovered_list_joins_the_offer() {
        let text = "subscriber { message: \"a.B\" topic: \"t\" }";
        assert_eq!(offers_with(text, None).len(), 1);
        let with = offers_with(text, Some("g.Tire pressure2\n"));
        assert_eq!(with.len(), 2);
        assert_eq!(with[1].topic, "pressure2");
    }

    /// The real generated file, not a stand-in: what the vehicle offers and subscribes to
    /// follows from it.
    #[test]
    fn the_generated_bridge_permissions_give_the_offer_and_the_inbound_topics() {
        let text = include_str!(
            "../../nexus-bridge/configs/permissions/com.android.nexus.aaos_nexus_sdv_tcu.NexusBridge.permissions.textproto"
        );
        let policy = authz_policy::parse(text).unwrap();
        let mut seen: Vec<(String, &str)> =
            offer::from_policy(&policy).iter().map(|o| (o.topic.clone(), o.direction)).collect();
        seen.sort();
        assert_eq!(
            seen,
            vec![
                ("command".to_string(), "cloud-to-vehicle"),
                ("door-command".to_string(), "cloud-to-vehicle"),
                ("pressure".to_string(), "vehicle-to-cloud"),
                ("pressure-limit".to_string(), "cloud-to-vehicle"),
                ("uplink".to_string(), "vehicle-to-cloud"),
            ]
        );
        assert!(policy.read_all);
        assert!(BRIDGE_POLICY_PATH
            .ends_with("/com.android.nexus.aaos_nexus_sdv_tcu.NexusBridge.permissions"));
    }
}
