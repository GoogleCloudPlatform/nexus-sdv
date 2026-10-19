//! Renders `leaf.conf` and owns the `nats-server` child process directly — no adb/SSH
//! round-trip, since this agent runs natively on Core3 (unlike the manual workflow this
//! session, which had to reach it via `adb shell` over an occasionally-flaky SSH/IAP
//! tunnel).

use std::fs;
use std::io;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};

/// Same substitution `bootstrap-leaf.sh` does against `leaf.conf.tpl` — kept as an
/// inline template here rather than shelling out to `sed` against that file, since this
/// agent owns its own config lifecycle end to end.
///
/// Note: the original template's comment claims the JWT is "short-lived (~300s)" — this
/// session measured a real 14-day TTL against a deployed platform's Keycloak. That
/// comment describes an assumption this agent's whole design exists to not depend on
/// (see `jwt::expiry_unix` — the real expiry is parsed, never assumed).
///
/// Keepalive values follow Google's test of 2026-09-14: an idle link dropped after
/// about two minutes, which is also NATS's default ping interval; with a 15 s
/// interval injected into this file the link stayed up. 15 s is the value they
/// verified, so it is used as is.
/// What the leaf presents to the hub and what it verifies the hub against. `None` keeps
/// the plain connection, for a hub that has no TLS on its leaf port yet.
pub struct LeafTls {
    /// The vehicle's operational certificate — its identity at the hub (spec R1).
    pub cert: PathBuf,
    pub key: PathBuf,
    /// The CA that issued the hub's leaf certificate, fetched from the public PKI bucket.
    pub ca: PathBuf,
    /// The name the hub's certificate is issued to (`nats.<domain>`). The leaf dials a
    /// pinned address on guests without DNS, and nats-server verifies the certificate
    /// against the URL's host — unless that host is an address and an earlier URL carried
    /// a name (2.14.6, client.go:6651-6659). So the name goes first in the URL list.
    pub server_name: String,
}

/// Three base64url segments — a JWT. The signature segment may be empty. Nothing else can
/// appear: the token is written between double quotes into `leaf.conf`, where a `"`, a
/// newline or a space would end the string and let the rest be read as configuration.
fn jwt_is_config_safe(jwt: &str) -> bool {
    let mut segments = jwt.split('.');
    let shape = (segments.next(), segments.next(), segments.next(), segments.next());
    let (Some(head), Some(body), Some(sig), None) = shape else {
        return false;
    };
    let base64url = |s: &str| s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
    !head.is_empty() && !body.is_empty() && base64url(head) && base64url(body) && base64url(sig)
}

/// A DNS name or an IPv4 address, as it appears in a `tls://…@host:7422` URL.
fn host_is_config_safe(host: &str) -> bool {
    !host.is_empty() && host.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')
}

fn path_is_config_safe(path: &std::path::Path) -> bool {
    path.to_str()
        .is_some_and(|s| !s.is_empty() && !s.chars().any(|c| c.is_control() || c == '"' || c == '\\'))
}

/// Refuses inputs that could change the meaning of `leaf.conf`. The messages never quote
/// the token.
fn check_conf_inputs(cloud_nats_host: &str, jwt: &str, tls: Option<&LeafTls>) -> Result<(), String> {
    if !jwt_is_config_safe(jwt) {
        return Err("the access token is not a plain JWT (three base64url segments); not written to leaf.conf".into());
    }
    if !host_is_config_safe(cloud_nats_host) {
        return Err(format!("the cloud NATS host {cloud_nats_host:?} is not a plain name or address"));
    }
    if let Some(t) = tls {
        if !host_is_config_safe(&t.server_name) {
            return Err(format!("the cloud NATS name {:?} is not a plain name or address", t.server_name));
        }
        for (what, p) in [("certificate", &t.cert), ("key", &t.key), ("CA", &t.ca)] {
            if !path_is_config_safe(p) {
                return Err(format!("the {what} path {p:?} holds a quote, a backslash or a control character"));
            }
        }
    }
    Ok(())
}

fn render_leaf_conf(cloud_nats_host: &str, jwt: &str, monitor_port: u16, tls: Option<&LeafTls>) -> String {
    let remote = match tls {
        Some(t) => {
            let mut urls = vec![format!("\"tls://{jwt}@{}:7422\"", t.server_name)];
            if t.server_name != cloud_nats_host {
                urls.push(format!("\"tls://{jwt}@{cloud_nats_host}:7422\""));
            }
            format!(
                "{{\n      urls: [{}]\n      tls {{\n        cert_file: \"{}\"\n        key_file: \"{}\"\n        ca_file: \"{}\"\n      }}\n    }}",
                urls.join(", "),
                t.cert.display(),
                t.key.display(),
                t.ca.display()
            )
        }
        None => format!("{{ url: \"nats://{jwt}@{cloud_nats_host}:7422\" }}"),
    };
    format!(
        r#"# Rendered by nexus-connectivity-agent — do not edit, do not commit (holds a JWT).
port: 4222

# Keepalive for the leaf node link. Without it an idle link is cut after about
# two minutes and has to reconnect. The leaf checks the link every 15 s and
# treats three missed answers as a dead link.
ping_interval: "15s"
ping_max: 3

# Monitoring endpoint, localhost only. It lets the agent ask the leaf itself
# whether the link to the cloud is up, instead of inferring that from log lines.
http: "127.0.0.1:{monitor_port}"

leafnodes {{
  remotes = [
    {remote}
  ]
}}
"#
    )
}

pub struct NatsServer {
    binary_path: PathBuf,
    config_path: PathBuf,
    log_path: PathBuf,
    monitor_port: u16,
    child: Option<Child>,
}

impl NatsServer {
    pub fn new(
        binary_path: PathBuf,
        config_path: PathBuf,
        log_path: PathBuf,
        monitor_port: u16,
    ) -> Self {
        Self {
            binary_path,
            config_path,
            log_path,
            monitor_port,
            child: None,
        }
    }

    /// Writes a fresh `leaf.conf` and (re)starts `nats-server` against it, killing any
    /// previous instance first. Called on startup and on every credential refresh.
    pub fn restart_with(&mut self, cloud_nats_host: &str, jwt: &str, tls: Option<&LeafTls>) -> io::Result<()> {
        // Before stopping anything: a bad input must not take down a leaf that works.
        check_conf_inputs(cloud_nats_host, jwt, tls)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
        self.stop();

        let rendered = render_leaf_conf(cloud_nats_host, jwt, self.monitor_port, tls);
        // Readable by its owner only, and by this code rather than by the
        // caller's umask: this file holds the vehicle's NATS token, and on a
        // guest where SELinux runs permissive nothing else protects it (F28).
        crate::private_file::write(&self.config_path, rendered.as_bytes())?;

        let log_file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.log_path)?;
        let log_file_err = log_file.try_clone()?;

        let child = Command::new(&self.binary_path)
            .arg("-c")
            .arg(&self.config_path)
            .stdin(Stdio::null())
            .stdout(log_file)
            .stderr(log_file_err)
            .spawn()?;

        self.child = Some(child);
        Ok(())
    }

    /// True if the process is still alive. Reaps it (updating internal state) if it has
    /// exited, so a subsequent `is_running` call reflects reality rather than a stale Some.
    pub fn is_running(&mut self) -> bool {
        match &mut self.child {
            None => false,
            Some(child) => match child.try_wait() {
                Ok(None) => true,
                Ok(Some(_status)) => {
                    self.child = None;
                    false
                }
                Err(_) => false,
            },
        }
    }

    pub fn stop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

impl Drop for NatsServer {
    fn drop(&mut self) {
        self.stop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tls() -> LeafTls {
        LeafTls {
            cert: PathBuf::from("certificates/operational-cert.pem"),
            key: PathBuf::from("certificates/operational-key.pem"),
            ca: PathBuf::from("certificates/NATS_LEAF_TLS_CA.pem"),
            server_name: "nats.example.org".to_string(),
        }
    }

    /// The hub's certificate names the hub, not its address. nats-server verifies the
    /// certificate against the URL's host — unless that host is an address and an earlier
    /// URL carried a name (nats-server 2.14.6, client.go:6651-6659; leafnode.go:496). So the
    /// name comes first, the pinned address second.
    #[test]
    fn renders_the_hub_name_first_then_the_pinned_address() {
        let conf = render_leaf_conf("34.116.195.11", "fake.jwt.value", 18222, Some(&tls()));
        assert!(conf.contains(r#"urls: ["tls://fake.jwt.value@nats.example.org:7422", "tls://fake.jwt.value@34.116.195.11:7422"]"#), "{conf}");
    }

    #[test]
    fn renders_one_url_when_the_name_is_the_address() {
        let conf = render_leaf_conf("nats.example.org", "fake.jwt.value", 18222, Some(&tls()));
        assert!(conf.contains(r#"urls: ["tls://fake.jwt.value@nats.example.org:7422"]"#), "{conf}");
        assert!(!conf.contains("34.116"), "{conf}");
    }

    #[test]
    fn renders_a_tls_remote_with_the_operational_certificate() {
        let conf = render_leaf_conf("nats.example.org", "fake.jwt.value", 18222, Some(&tls()));
        assert!(conf.contains(r#"tls://fake.jwt.value@nats.example.org:7422"#), "{conf}");
        assert!(conf.contains(r#"cert_file: "certificates/operational-cert.pem""#), "{conf}");
        assert!(conf.contains(r#"key_file: "certificates/operational-key.pem""#), "{conf}");
        assert!(conf.contains(r#"ca_file: "certificates/NATS_LEAF_TLS_CA.pem""#), "{conf}");
    }

    #[test]
    fn renders_a_plain_remote_when_tls_is_off() {
        let conf = render_leaf_conf("34.116.195.11", "fake.jwt.value", 18222, None);
        assert!(conf.contains(r#"url: "nats://fake.jwt.value@34.116.195.11:7422""#), "{conf}");
        assert!(!conf.contains("cert_file"), "{conf}");
    }

    #[test]
    fn renders_the_leafnode_url_with_jwt_and_host() {
        let conf = render_leaf_conf("34.116.195.11", "fake.jwt.value", 18222, None);
        assert!(conf.contains(r#"url: "nats://fake.jwt.value@34.116.195.11:7422""#));
        assert!(conf.contains("port: 4222"));
    }

    #[test]
    fn keeps_an_idle_leaf_node_link_alive() {
        let conf = render_leaf_conf("34.116.195.11", "fake.jwt.value", 18222, None);
        assert!(conf.contains(r#"ping_interval: "15s""#), "{conf}");
        assert!(conf.contains("ping_max: 3"), "{conf}");
    }

    /// Localhost only: the monitoring endpoint answers without authentication.
    #[test]
    fn exposes_monitoring_on_localhost_only() {
        let conf = render_leaf_conf("34.116.195.11", "fake.jwt.value", 19222, None);
        assert!(conf.contains(r#"http: "127.0.0.1:19222""#), "{conf}");
    }

    #[test]
    fn real_looking_inputs_pass_the_config_check() {
        assert!(check_conf_inputs("34.116.195.11", "fake.jwt.value", None).is_ok());
        assert!(check_conf_inputs("nats.example.org", "eyJhbGciOiJSUzI1NiJ9.eyJleHAiOjE3fQ.c2ln-_x", Some(&tls())).is_ok());
        assert!(jwt_is_config_safe("aaa.bbb."), "an empty signature segment is allowed");
    }

    /// The token sits inside `"…"` in leaf.conf. A quote or newline ends the string and
    /// what follows is read as configuration — an extra remote to a host of the attacker's
    /// choosing, for instance.
    #[test]
    fn a_token_that_could_end_the_config_string_is_refused() {
        let attacks = [
            "a.b.c\"\n    remotes = [{ url: \"nats://evil:7422\" }]",
            "a.b.c\"",
            "a.b.c\n",
            "a.b.c d",
            "a.b.c\\",
            "a.b",
            "a.b.c.d",
            ".b.c",
            "a..c",
            "",
        ];
        for bad in attacks {
            let err = check_conf_inputs("34.116.195.11", bad, None).unwrap_err();
            assert!(!err.contains(bad) || bad.is_empty(), "the message must not quote the token: {err}");
            let dir = tempfile::tempdir().unwrap();
            let conf = dir.path().join("leaf.conf");
            let mut server = NatsServer::new(dir.path().join("no-such-binary"), conf.clone(), dir.path().join("l.log"), 18222);
            let e = server.restart_with("34.116.195.11", bad, None).unwrap_err();
            assert_eq!(e.kind(), io::ErrorKind::InvalidInput, "{bad:?}");
            assert!(!conf.exists(), "nothing may be written for {bad:?}");
        }
    }

    #[test]
    fn a_host_or_path_that_could_end_the_config_string_is_refused() {
        for bad in ["evil\"host", "a b", "host\n", "a:7422", "a/b", ""] {
            assert!(check_conf_inputs(bad, "a.b.c", None).is_err(), "host {bad:?}");
            let mut t = tls();
            t.server_name = bad.to_string();
            assert!(check_conf_inputs("nats.example.org", "a.b.c", Some(&t)).is_err(), "name {bad:?}");
        }
        for bad in ["c\"rt.pem", "c\\rt.pem", "cert\n.pem", "cert\0.pem", ""] {
            let mut t = tls();
            t.cert = PathBuf::from(bad);
            assert!(check_conf_inputs("nats.example.org", "a.b.c", Some(&t)).is_err(), "path {bad:?}");
        }
    }

    /// leaf.conf carries the vehicle's NATS token, and on a guest where SELinux
    /// runs permissive the file mode is the only thing protecting it (F28).
    /// It must not depend on the umask of whoever started this process.
    #[test]
    fn writes_the_leaf_config_readable_by_its_owner_only() {
        use std::os::unix::fs::PermissionsExt;

        let dir = tempfile::tempdir().unwrap();
        let conf = dir.path().join("leaf.conf");
        // A pre-existing world-readable file is the case that matters: a rewrite
        // keeps the old mode unless the file is replaced.
        std::fs::write(&conf, "stale").unwrap();
        std::fs::set_permissions(&conf, std::fs::Permissions::from_mode(0o666)).unwrap();

        let mut server = NatsServer::new(
            // No such binary: the spawn fails, which is fine — the config is
            // written before the process is started, and that is what is tested.
            dir.path().join("no-such-nats-server"),
            conf.clone(),
            dir.path().join("leaf.log"),
            18222,
        );
        let _ = server.restart_with("127.0.0.1", "fake.jwt.value", None);

        let mode = std::fs::metadata(&conf).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "leaf.conf mode was {mode:o}");
        assert!(std::fs::read_to_string(&conf).unwrap().contains("fake.jwt.value"));
    }
}
