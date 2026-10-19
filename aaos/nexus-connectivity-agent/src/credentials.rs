//! Which of the two provisioning paths runs, and the older of the two: spawning the Go
//! `vehicle-client` binary directly (no shell wrapper) and reading the files it leaves
//! behind. The in-process path — `provisioning.rs` — is the default; this one stays
//! selectable for as long as that binary happens to be present on the guest, which the
//! package no longer ships.
//!
//! It is spawned rather than driven through a shell wrapper so that it needs nothing on
//! the guest but itself: no curl, no openssl, no DNS, given the factory cert/key and the
//! two TLS trust certs are already present on disk — provisioned once at deploy time,
//! mirroring how a real vehicle's factory identity is injected at manufacture, not
//! synthesized at boot.
//!
//! Because we spawn the binary directly (not through a wrapper shell), the child handle
//! IS the actual vehicle-client process — no grandchild-process indirection, so a plain
//! `child.kill()` suffices once the token file appears.

use std::io;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

pub struct Credentials {
    pub jwt: String,
    pub operational_cert_path: PathBuf,
}

/// Everything either provisioning path needs. URLs and resolve-IPs are passed
/// fully-formed (already resolved from hostnames) — the nexus-connectivity-agent that
/// builds this is responsible for that, not the path that consumes it.
pub struct ProvisioningConfig {
    pub vin: String,
    pub pki_strategy: String,
    pub factory_cert: PathBuf,
    pub factory_key: PathBuf,
    pub registration_url: String,
    pub keycloak_url: String,
    pub nats_url: String,
    pub registration_resolve_ip: Option<String>,
    pub keycloak_resolve_ip: Option<String>,
}

#[derive(Debug)]
pub enum FetchError {
    Spawn(io::Error),
    Timeout,
    EmptyToken,
    Io(io::Error),
    /// `NEXUS_PROVISIONING` held something that is neither path.
    UnknownProvisioning(String),
    /// The in-process path failed. One string, because the point of doing this in
    /// Rust is that the message says what actually went wrong instead of
    /// "timed out waiting for oidc-access-token".
    Provisioning(String),
}

impl std::fmt::Display for FetchError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FetchError::Spawn(e) => write!(f, "failed to spawn vehicle-client: {e}"),
            FetchError::Timeout => write!(f, "timed out waiting for oidc-access-token"),
            FetchError::EmptyToken => write!(f, "oidc-access-token was empty"),
            FetchError::Io(e) => write!(f, "io error reading credentials: {e}"),
            FetchError::UnknownProvisioning(v) => write!(
                f,
                "NEXUS_PROVISIONING={v:?} is neither 'vehicle-client' nor 'rust'"
            ),
            FetchError::Provisioning(e) => write!(f, "{e}"),
        }
    }
}

/// Which implementation obtains the vehicle's credentials.
///
/// Two of them exist: the `vehicle-client` binary this component drove from
/// Increment 1, and the in-process path. The in-process path is the default
/// since it passed acceptance on the development mesh and on a fresh single
/// instance. `vehicle-client` remains selectable for as long as that binary is
/// available, which the package no longer ships.
// Debug so a test can `unwrap_err` on the Result this appears in.
#[derive(Debug)]
pub enum Provisioning {
    VehicleClient,
    Rust,
}

impl std::fmt::Display for Provisioning {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Provisioning::VehicleClient => write!(f, "vehicle-client"),
            Provisioning::Rust => write!(f, "rust"),
        }
    }
}

fn from_value(value: Option<&str>) -> Result<Provisioning, FetchError> {
    match value {
        None | Some("") | Some("rust") => Ok(Provisioning::Rust),
        Some("vehicle-client") => Ok(Provisioning::VehicleClient),
        Some(other) => Err(FetchError::UnknownProvisioning(other.to_string())),
    }
}

pub fn selected() -> Result<Provisioning, FetchError> {
    from_value(std::env::var("NEXUS_PROVISIONING").ok().as_deref())
}

pub fn fetch(run_dir: &Path, cfg: &ProvisioningConfig) -> Result<Credentials, FetchError> {
    match selected()? {
        Provisioning::VehicleClient => fetch_via_vehicle_client(run_dir, cfg),
        Provisioning::Rust => crate::provisioning::fetch(run_dir, cfg),
    }
}

/// `vehicle_client_dir` holds the `vehicle-client` binary and the `certificates/`
/// directory it reads and writes — factory cert/key and the two TLS trust certs must
/// already be present there; this function does not fetch or generate them. It is the
/// run directory whenever the binary was put there by hand.
fn fetch_via_vehicle_client(
    vehicle_client_dir: &Path,
    cfg: &ProvisioningConfig,
) -> Result<Credentials, FetchError> {
    let token_file = vehicle_client_dir.join("certificates/oidc-access-token");
    let cert_file = vehicle_client_dir.join("certificates/operational-cert.pem");
    let _ = std::fs::remove_file(&token_file); // stale token from a prior run must not be misread as fresh

    let mut command = Command::new("./vehicle-client");
    command
        .arg("-vin").arg(&cfg.vin)
        .arg("-pki_strategy").arg(&cfg.pki_strategy)
        .arg("-factory-cert").arg(&cfg.factory_cert)
        .arg("-factory-key").arg(&cfg.factory_key)
        .arg("-registration-url").arg(&cfg.registration_url)
        .arg("-keycloak-url").arg(&cfg.keycloak_url)
        .arg("-nats-url").arg(&cfg.nats_url)
        .arg("-message-type").arg("metrics_report");
    if let Some(ip) = &cfg.registration_resolve_ip {
        command.arg("-registration-resolve-ip").arg(ip);
    }
    if let Some(ip) = &cfg.keycloak_resolve_ip {
        command.arg("-keycloak-resolve-ip").arg(ip);
    }

    let mut child: Child = command
        .current_dir(vehicle_client_dir)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(FetchError::Spawn)?;

    let deadline = Instant::now() + Duration::from_secs(120);
    let got_token = loop {
        if token_file.exists() {
            break true;
        }
        if let Ok(Some(_status)) = child.try_wait() {
            // process exited on its own before writing a token -> failure, not a timeout
            break token_file.exists();
        }
        if Instant::now() >= deadline {
            break false;
        }
        thread::sleep(Duration::from_secs(1));
    };

    let _ = child.kill();
    let _ = child.wait();

    if !got_token {
        return Err(FetchError::Timeout);
    }

    let jwt = std::fs::read_to_string(&token_file)
        .map_err(FetchError::Io)?
        .trim()
        .to_string();
    if jwt.is_empty() {
        return Err(FetchError::EmptyToken);
    }

    Ok(Credentials {
        jwt,
        operational_cert_path: cert_file,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `selected` reads a process-wide environment variable, so these cases are
    /// checked through the pure function underneath it rather than by setting
    /// the variable — test threads share the environment.
    #[test]
    fn the_default_is_the_in_process_path() {
        assert!(matches!(from_value(None), Ok(Provisioning::Rust)));
        assert!(matches!(from_value(Some("")), Ok(Provisioning::Rust)));
        assert!(matches!(from_value(Some("rust")), Ok(Provisioning::Rust)));
    }

    #[test]
    fn the_old_path_is_still_selectable() {
        assert!(matches!(
            from_value(Some("vehicle-client")),
            Ok(Provisioning::VehicleClient)
        ));
    }

    /// A typo must not silently leave the vehicle on the old path — that is how
    /// an acceptance run proves the wrong thing.
    #[test]
    fn a_value_that_is_neither_is_an_error() {
        let err = from_value(Some("Rust ")).unwrap_err();
        assert!(format!("{err}").contains("NEXUS_PROVISIONING"), "{err}");
    }

    #[test]
    fn both_paths_have_a_name_for_the_log() {
        assert_eq!(Provisioning::VehicleClient.to_string(), "vehicle-client");
        assert_eq!(Provisioning::Rust.to_string(), "rust");
    }
}
