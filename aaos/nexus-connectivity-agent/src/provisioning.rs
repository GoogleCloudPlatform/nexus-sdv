//! The provisioning chain, in this process: factory certificate → operational
//! certificate → access token.
//!
//! It writes the same two files in the same place as the `vehicle-client` binary
//! it replaces — `certificates/operational-cert.pem` and
//! `certificates/oidc-access-token` in the run directory — because the
//! provisioning script, the acceptance check and TESTING.md all know those paths
//! and none of them should change because the implementation language did.
//!
//! What it does not do is retry: the caller already retries every 15 seconds
//! (aaos/nexus-connectivity-agent/src/main.rs:117-124), and a second layer of
//! retries inside would only hide which step failed.

use std::path::{Path, PathBuf};

use crate::credentials::{Credentials, FetchError, ProvisioningConfig};
use crate::csr;
use crate::http_tls::{self, Identity, Post, Target};
use crate::private_file;

/// Where the two trust anchors are staged (aaos/aaos-nexus-sdv-tcu/provision-and-run.sh:114-115).
const REGISTRATION_TRUST_ANCHOR: &str = "certificates/REGISTRATION_SERVER_TLS_CERT.pem";
const KEYCLOAK_TRUST_ANCHOR: &str = "certificates/KEYCLOAK_TLS_CRT.pem";

/// The three files this path produces. The first two are read by other tools;
/// the third is what the caller returns to the leaf.
const OPERATIONAL_CERT: &str = "certificates/operational-cert.pem";
const OPERATIONAL_KEY: &str = "certificates/operational-key.pem";
const ACCESS_TOKEN: &str = "certificates/oidc-access-token";

const REGISTRATION_PATH: &str = "/registration";
const TOKEN_PATH: &str = "/realms/sdv-telemetry/protocol/openid-connect/token";

/// Character for character what the Go client sends
/// (sample-clients/vehicle-client/main.go:483). The scope is kept although only
/// the access token is used, so that Keycloak's side of the exchange is
/// unchanged by this rewrite.
const TOKEN_REQUEST_BODY: &str = "grant_type=client_credentials&client_id=car&scope=openid+offline_access";

#[derive(serde::Deserialize)]
struct RegistrationResponse {
    /// The operational certificate followed by the CA chain
    /// (base-services/registration/server/src/main.rs:119).
    certificate: String,
    /// The Go client authenticates against this URL rather than the configured
    /// one (sample-clients/vehicle-client/main.go:361,477-478).
    keycloak_url: String,
    // `nats_url` is in the response as well. The leaf takes its broker from
    // NEXUS_CLOUD_NATS_HOST (aaos/nexus-connectivity-agent/src/main.rs:60-61),
    // so it is deliberately not read here.
}

#[derive(serde::Deserialize)]
struct TokenResponse {
    access_token: String,
}

#[derive(serde::Deserialize)]
struct TokenErrorBody {
    error: Option<String>,
    error_description: Option<String>,
}

fn failed(message: impl Into<String>) -> FetchError {
    FetchError::Provisioning(message.into())
}

/// Configuration paths may be relative to the run directory or absolute.
fn resolve(run_dir: &Path, path: &Path) -> PathBuf {
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        run_dir.join(path)
    }
}

fn keycloak_base<'a>(from_response: &'a str, configured: &'a str) -> &'a str {
    if from_response.trim().is_empty() {
        configured
    } else {
        from_response
    }
}

fn registration_error_summary(status: u16, body: &[u8]) -> String {
    let text = String::from_utf8_lossy(body);
    let excerpt: String = text.chars().take(200).collect();
    format!("the registration server refused the request (HTTP {status}): {excerpt}")
}

fn token_error_summary(status: u16, body: &[u8]) -> String {
    match serde_json::from_slice::<TokenErrorBody>(body) {
        Ok(parsed) => format!(
            "Keycloak refused the token request (HTTP {status}): {} {}",
            parsed.error.as_deref().unwrap_or("no error code"),
            parsed.error_description.as_deref().unwrap_or(""),
        ),
        // Not quoted: a body from this endpoint can hold a token.
        Err(_) => format!(
            "Keycloak refused the token request (HTTP {status}); the body was not the expected JSON and is not repeated here, because this endpoint's bodies can carry a token"
        ),
    }
}

fn read(path: &Path, what: &str) -> Result<Vec<u8>, FetchError> {
    std::fs::read(path).map_err(|e| failed(format!("cannot read {what} at {}: {e}", path.display())))
}

/// Everything the token step needs from the registration step.
struct Operational {
    cert_pem: String,
    key_pem: String,
    cert_path: PathBuf,
    keycloak_url: String,
}

fn post_registration(
    target: &Target,
    csr_pem: &str,
    trust_anchor_pem: &[u8],
    identity: &Identity,
) -> Result<RegistrationResponse, FetchError> {
    let response = http_tls::post(Post {
        target,
        path: REGISTRATION_PATH,
        // The content type the Go client sends
        // (sample-clients/vehicle-client/main.go:328). The handler takes the body
        // as a plain string and does not select on it
        // (base-services/registration/server/src/main.rs:83).
        content_type: "application/x-pem-file",
        body: csr_pem.as_bytes(),
        trust_anchor_pem,
        identity,
    })
    .map_err(|e| failed(format!("registration at {}:{} failed: {e}", target.host, target.port)))?;

    if response.status != 200 {
        return Err(failed(registration_error_summary(
            response.status,
            &response.body,
        )));
    }
    serde_json::from_slice::<RegistrationResponse>(&response.body)
        .map_err(|e| failed(format!("cannot read the registration server's answer: {e}")))
}

fn obtain_operational_cert(
    run_dir: &Path,
    cfg: &ProvisioningConfig,
) -> Result<Operational, FetchError> {
    let factory_cert_path = resolve(run_dir, &cfg.factory_cert);
    let factory_cert_pem = read(&factory_cert_path, "the factory certificate")?;
    let factory_key_pem = read(&resolve(run_dir, &cfg.factory_key), "the factory key")?;
    let trust_anchor = read(
        &run_dir.join(REGISTRATION_TRUST_ANCHOR),
        "the registration server's trust anchor",
    )?;

    let factory_cert_text = String::from_utf8(factory_cert_pem.clone())
        .map_err(|_| failed(format!("{} is not text", factory_cert_path.display())))?;
    let common_name = csr::common_name_from_cert_pem(&factory_cert_text).map_err(|e| failed(e.to_string()))?;

    // The factory files of every VIN ever provisioned accumulate side by side in
    // the run directory, and only `operational-*` and `oidc-*` are cleared
    // between runs (aaos/common/identity.rs:4-11). Staging the wrong one is a
    // real mistake, and the server's answer to it would be a bare 400.
    let info = csr::parse_vehicle_info(&common_name).map_err(|e| failed(e.to_string()))?;
    if info.vin != cfg.vin {
        return Err(failed(format!(
            "the staged factory certificate is for VIN {} but this vehicle is configured as {} ({})",
            info.vin,
            cfg.vin,
            factory_cert_path.display()
        )));
    }

    let generated = csr::generate(&common_name).map_err(|e| failed(e.to_string()))?;

    let (host, port) = http_tls::split_https_url(&cfg.registration_url)
        .map_err(|e| failed(format!("NEXUS_REGISTRATION_URL: {e}")))?;
    let target = Target {
        host,
        port,
        dial_addr: cfg.registration_resolve_ip.clone(),
    };
    let identity = Identity {
        cert_chain_pem: factory_cert_pem,
        key_pem: factory_key_pem,
    };

    let registered = post_registration(&target, &generated.csr_pem, &trust_anchor, &identity)?;

    let cert_path = run_dir.join(OPERATIONAL_CERT);
    private_file::write(&cert_path, registered.certificate.as_bytes())
        .map_err(|e| failed(format!("cannot write {}: {e}", cert_path.display())))?;
    let key_path = run_dir.join(OPERATIONAL_KEY);
    private_file::write(&key_path, generated.key_pem.as_bytes())
        .map_err(|e| failed(format!("cannot write {}: {e}", key_path.display())))?;

    Ok(Operational {
        cert_pem: registered.certificate,
        key_pem: generated.key_pem,
        cert_path,
        keycloak_url: registered.keycloak_url,
    })
}

fn obtain_token(
    run_dir: &Path,
    cfg: &ProvisioningConfig,
    operational: &Operational,
) -> Result<String, FetchError> {
    let trust_anchor = read(&run_dir.join(KEYCLOAK_TRUST_ANCHOR), "Keycloak's trust anchor")?;

    let base = keycloak_base(&operational.keycloak_url, &cfg.keycloak_url);
    let (host, port) =
        http_tls::split_https_url(base).map_err(|e| failed(format!("the Keycloak URL {base:?}: {e}")))?;
    let target = Target {
        host,
        port,
        dial_addr: cfg.keycloak_resolve_ip.clone(),
    };
    // Keycloak matches the certificate's subject against
    // `.*CN=VIN:.* DEVICE:.*` as a regular expression
    // (iac/helm/keycloak/files/sdv-telemetry-realm.json:720,730), so the
    // operational certificate authenticates the client `car` on its own.
    let identity = Identity {
        cert_chain_pem: operational.cert_pem.clone().into_bytes(),
        key_pem: operational.key_pem.clone().into_bytes(),
    };

    let response = http_tls::post(Post {
        target: &target,
        path: TOKEN_PATH,
        content_type: "application/x-www-form-urlencoded",
        body: TOKEN_REQUEST_BODY.as_bytes(),
        trust_anchor_pem: &trust_anchor,
        identity: &identity,
    })
    .map_err(|e| failed(format!("the token request to {base} failed: {e}")))?;

    if response.status != 200 {
        return Err(failed(token_error_summary(response.status, &response.body)));
    }

    let token: TokenResponse = serde_json::from_slice(&response.body)
        .map_err(|e| failed(format!("cannot read Keycloak's answer: {e}")))?;
    if token.access_token.trim().is_empty() {
        return Err(failed("Keycloak returned an empty access token"));
    }
    Ok(token.access_token)
}

pub fn fetch(run_dir: &Path, cfg: &ProvisioningConfig) -> Result<Credentials, FetchError> {
    // The Go path had a "local" mode that turned server-certificate verification
    // off (sample-clients/vehicle-client/main.go:300). This path does not: it is
    // the one that runs in a vehicle, and an unverified registration server can
    // hand out any identity it likes.
    if cfg.pki_strategy != "remote" {
        return Err(failed(format!(
            "NEXUS_PKI_STRATEGY={:?} is not supported by the in-process provisioning path; it always verifies the server certificate, so only 'remote' applies",
            cfg.pki_strategy
        )));
    }

    // A token left over from a previous run must not be read as this run's.
    let token_path = run_dir.join(ACCESS_TOKEN);
    let _ = std::fs::remove_file(&token_path);

    let operational = obtain_operational_cert(run_dir, cfg)?;
    crate::log_line!(
        "registered: operational certificate at {:?}, token from {}",
        operational.cert_path,
        keycloak_base(&operational.keycloak_url, &cfg.keycloak_url)
    );

    let jwt = obtain_token(run_dir, cfg, &operational)?;
    private_file::write(&token_path, jwt.as_bytes())
        .map_err(|e| failed(format!("cannot write {}: {e}", token_path.display())))?;

    Ok(Credentials {
        jwt,
        operational_cert_path: operational.cert_path,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prefers_the_keycloak_url_the_registration_server_returned() {
        assert_eq!(
            keycloak_base("https://keycloak.from-server:8443", "https://keycloak.configured:8443"),
            "https://keycloak.from-server:8443"
        );
    }

    #[test]
    fn falls_back_to_the_configured_keycloak_url_when_the_response_has_none() {
        assert_eq!(
            keycloak_base("   ", "https://keycloak.configured:8443"),
            "https://keycloak.configured:8443"
        );
    }

    /// The registration server's failure body is its own error envelope
    /// (base-services/registration/server/src/main.rs:55-63) and carries no
    /// secret, so quoting it tells a tester what the server actually said.
    #[test]
    fn quotes_what_the_registration_server_said() {
        let summary = registration_error_summary(400, br#"{"error":{"code":"400","message":"Csr is not valid"}}"#);
        assert!(summary.contains("400"), "{summary}");
        assert!(summary.contains("Csr is not valid"), "{summary}");
    }

    #[test]
    fn bounds_the_quoted_registration_error() {
        let long = vec![b'x'; 5000];
        let summary = registration_error_summary(500, &long);
        assert!(summary.len() < 400, "an unbounded error body ended up in the log: {}", summary.len());
    }

    /// A successful token response holds the token, so nothing from that
    /// endpoint is ever quoted verbatim — only the two fields OAuth defines for
    /// an error, and only when the body parses as JSON.
    #[test]
    fn reports_a_token_error_by_its_fields() {
        let summary = token_error_summary(401, br#"{"error":"invalid_client","error_description":"Invalid client credentials"}"#);
        assert!(summary.contains("invalid_client"), "{summary}");
        assert!(summary.contains("Invalid client credentials"), "{summary}");
    }

    #[test]
    fn never_quotes_a_token_body_that_is_not_json() {
        let summary = token_error_summary(500, b"eyJhbGciOiJSUzI1NiJ9.secret.part");
        assert!(!summary.contains("eyJhbGciOiJSUzI1NiJ9"), "a raw body reached the log: {summary}");
    }

    /// Paths in the configuration may be relative to the run directory (that is
    /// how main.rs builds the factory defaults) or absolute.
    #[test]
    fn resolves_a_relative_path_against_the_run_directory() {
        let run = std::path::Path::new("/data/local/tmp/run");
        assert_eq!(
            resolve(run, std::path::Path::new("certificates/f.pem")),
            std::path::PathBuf::from("/data/local/tmp/run/certificates/f.pem")
        );
        assert_eq!(
            resolve(run, std::path::Path::new("/etc/f.pem")),
            std::path::PathBuf::from("/etc/f.pem")
        );
    }
}

/// Exercises the Rust provisioning path against the registration server from
/// this repository, with a factory CA generated here. No GCP, no secrets.
///
/// Ignored by default: it builds `base-services/registration/server` and the
/// server takes the fixed port 8443, so it cannot run beside another copy of
/// itself or beside a locally running registration server. Run it with
///
///     cargo test --package nexus-connectivity-agent local_registration_server -- --ignored --nocapture
///
/// The proof that a *wrong* hostname is refused is not here: it is in
/// `http_tls.rs` (`refuses_a_certificate_that_names_a_different_host`), against
/// an in-process rustls server, where it needs neither this server nor a fixed
/// port. This test therefore dials an address while naming a host, but only to
/// exercise the path that the vehicle actually takes.
#[cfg(test)]
mod local_server_tests {
    use super::*;
    use rcgen::{BasicConstraints, CertificateParams, DnType, IsCa, Issuer, KeyPair};
    use std::io::{Read, Write};
    use std::os::unix::fs::PermissionsExt;

    const VIN: &str = "ITEST0001";
    const COMMON_NAME: &str = "VIN:ITEST0001 DEVICE:ITEST0001";
    /// The name the server's certificate carries and the client verifies. It is
    /// deliberately not `localhost`: the point is that the socket goes to
    /// 127.0.0.1 while this name is what TLS checks.
    const RIGHT_HOST: &str = "registration.test.invalid";

    struct Ca {
        issuer: Issuer<'static, KeyPair>,
        cert_pem: String,
        /// Kept separately because `Issuer::from_ca_cert_der` takes the key pair
        /// by value and there is no way to read it back out afterwards.
        key_pem: String,
    }

    fn self_signed_ca(name: &str) -> Ca {
        let key = KeyPair::generate().expect("ca key");
        let mut params = CertificateParams::new(vec![name.to_string()]).expect("ca params");
        params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
        params.distinguished_name.push(DnType::CommonName, name);
        let cert = params.self_signed(&key).expect("self-signed ca");
        let cert_pem = cert.pem();
        let key_pem = key.serialize_pem();
        let issuer = Issuer::from_ca_cert_der(cert.der(), key).expect("issuer");
        Ca {
            issuer,
            cert_pem,
            key_pem,
        }
    }

    /// A leaf certificate signed by `ca`, with the given common name and DNS
    /// names. Returns (certificate PEM, key PEM).
    fn leaf(ca: &Ca, common_name: &str, dns_names: Vec<String>) -> (String, String) {
        let key = KeyPair::generate().expect("leaf key");
        let mut params = CertificateParams::new(dns_names).expect("leaf params");
        params.distinguished_name.push(DnType::CommonName, common_name);
        let cert = params.signed_by(&key, &ca.issuer).expect("signed leaf");
        (cert.pem(), key.serialize_pem())
    }

    fn write(path: &std::path::Path, contents: &str) {
        std::fs::create_dir_all(path.parent().expect("parent")).expect("mkdir");
        std::fs::write(path, contents).expect("write");
    }

    /// True once the server answers on its plain-HTTP health port.
    fn health_answers() -> bool {
        let Ok(mut socket) = std::net::TcpStream::connect("127.0.0.1:8888") else {
            return false;
        };
        // A peer that accepts the connection but never answers would otherwise
        // hang the whole test rather than fail it.
        let _ = socket.set_read_timeout(Some(std::time::Duration::from_secs(5)));
        if socket
            .write_all(b"GET /health HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n")
            .is_err()
        {
            return false;
        }
        let mut answer = String::new();
        let _ = socket.read_to_string(&mut answer);
        answer.contains("healthy")
    }

    #[test]
    #[ignore = "builds base-services/registration/server and binds the fixed port 8443"]
    fn local_registration_server() {
        // --- build the server -------------------------------------------------
        let manifest = "../../base-services/registration/server/Cargo.toml";
        let built = std::process::Command::new("cargo")
            .args(["build", "--manifest-path", manifest])
            .status()
            .expect("cargo build for the registration server");
        assert!(built.success(), "the registration server did not build");
        // Absolute: the server is spawned with its working directory set to the
        // prepared folder, and a relative program path would be resolved
        // against that folder rather than against this crate.
        let server_bin = std::fs::canonicalize(
            "../../base-services/registration/server/target/debug/server",
        )
        .expect("no server binary under base-services/registration/server/target/debug");

        // --- the certificates -------------------------------------------------
        let factory_ca = self_signed_ca("Nexus Factory CA (test)");
        let signing_ca = self_signed_ca("Nexus Registration CA (test)");
        let server_tls_ca = self_signed_ca("Nexus Server CA (test)");
        let (server_cert_pem, server_key_pem) = leaf(
            &server_tls_ca,
            RIGHT_HOST,
            vec![RIGHT_HOST.to_string(), "localhost".to_string()],
        );
        let (factory_cert_pem, factory_key_pem) = leaf(
            &factory_ca,
            COMMON_NAME,
            vec!["factory.test.invalid".to_string()],
        );

        let server_dir = tempfile::tempdir().expect("server dir");
        let s = server_dir.path();
        write(&s.join("certificates/ca/ca.crt.pem"), &signing_ca.cert_pem);
        write(&s.join("certificates/ca/ca.key.pem"), &signing_ca.key_pem);
        write(
            &s.join("certificates/server/server.crt.pem"),
            &server_cert_pem,
        );
        write(&s.join("certificates/server/server.key.pem"), &server_key_pem);
        write(
            &s.join("certificates/trusted-factory-ca.crt.pem"),
            &factory_ca.cert_pem,
        );

        let run_dir = tempfile::tempdir().expect("run dir");
        let r = run_dir.path();
        write(
            &r.join("certificates/REGISTRATION_SERVER_TLS_CERT.pem"),
            &server_tls_ca.cert_pem,
        );
        write(
            &r.join(format!("certificates/vehicle-{VIN}-factory-gcp-chain.pem")),
            &format!("{factory_cert_pem}{}", factory_ca.cert_pem),
        );
        write(
            &r.join(format!("certificates/vehicle-{VIN}-factory-gcp-key.pem")),
            &factory_key_pem,
        );

        // --- start the server -------------------------------------------------
        assert!(
            !health_answers(),
            "something already answers on 127.0.0.1:8888 — stop it; the registration server takes fixed ports (base-services/registration/server/src/main.rs:146,156)"
        );
        let mut server = std::process::Command::new(&server_bin)
            .current_dir(s)
            .env("KEYCLOAK_URL", "https://keycloak.test.invalid:8443")
            .env("NATS_URL", "nats://nats.test.invalid:4222")
            .env("RUST_LOG", "warn")
            .spawn()
            .expect("start the registration server");
        let mut waited = 0;
        while !health_answers() {
            assert!(waited < 60, "the registration server did not come up");
            std::thread::sleep(std::time::Duration::from_millis(500));
            waited += 1;
        }

        let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let cfg = ProvisioningConfig {
                vin: VIN.to_string(),
                pki_strategy: "remote".to_string(),
                factory_cert: format!("certificates/vehicle-{VIN}-factory-gcp-chain.pem").into(),
                factory_key: format!("certificates/vehicle-{VIN}-factory-gcp-key.pem").into(),
                registration_url: format!("https://{RIGHT_HOST}:8443"),
                keycloak_url: "https://keycloak.test.invalid:8443".to_string(),
                nats_url: "nats://nats.test.invalid:4222".to_string(),
                // The socket goes here; the name above is what TLS checks.
                registration_resolve_ip: Some("127.0.0.1".to_string()),
                keycloak_resolve_ip: None,
            };

            // --- 1. the happy path ------------------------------------------
            let operational =
                obtain_operational_cert(r, &cfg).expect("registration against the local server");
            let issued_cn = crate::csr::common_name_from_cert_pem(&operational.cert_pem)
                .expect("the issued certificate has a readable common name");
            assert_eq!(
                issued_cn, COMMON_NAME,
                "the issued certificate must carry the factory certificate's common name"
            );
            let mode = std::fs::metadata(&operational.cert_path)
                .expect("the operational certificate was written")
                .permissions()
                .mode()
                & 0o777;
            assert_eq!(mode, 0o600, "operational-cert.pem mode was {mode:o}");
            let key_mode = std::fs::metadata(r.join(OPERATIONAL_KEY))
                .expect("the operational key was written")
                .permissions()
                .mode()
                & 0o777;
            assert_eq!(key_mode, 0o600, "operational-key.pem mode was {key_mode:o}");

            // --- 2. a mismatched common name must be refused -----------------
            // Everything else stays equal: same connection, same factory
            // identity in the handshake, only the name in the signing request
            // belongs to another vehicle. This is the failure csr.rs exists to
            // prevent, and the server's answer to it says nothing about what
            // went wrong.
            let foreign = crate::csr::generate("VIN:OTHER0001 DEVICE:OTHER0001")
                .expect("a signing request for another vehicle");
            let target = Target {
                host: RIGHT_HOST.to_string(),
                port: 8443,
                dial_addr: Some("127.0.0.1".to_string()),
            };
            let identity = Identity {
                cert_chain_pem: std::fs::read(
                    r.join(format!("certificates/vehicle-{VIN}-factory-gcp-chain.pem")),
                )
                .expect("factory chain"),
                key_pem: std::fs::read(
                    r.join(format!("certificates/vehicle-{VIN}-factory-gcp-key.pem")),
                )
                .expect("factory key"),
            };
            let trust = std::fs::read(r.join(REGISTRATION_TRUST_ANCHOR)).expect("trust anchor");
            // Matched rather than `expect_err`: that would need `Debug` on
            // `RegistrationResponse`, and a derived one would put the issued
            // certificate into whatever prints it. `http_tls::Response` is
            // hand-written for the same reason.
            let err = match post_registration(&target, &foreign.csr_pem, &trust, &identity) {
                Ok(_) => panic!("a request for a foreign VIN must be refused"),
                Err(err) => err,
            };
            assert!(
                format!("{err}").contains("400"),
                "expected the server's 400, got: {err}"
            );
        }));

        let _ = server.kill();
        let _ = server.wait();
        if let Err(panic) = outcome {
            std::panic::resume_unwind(panic);
        }
    }
}
