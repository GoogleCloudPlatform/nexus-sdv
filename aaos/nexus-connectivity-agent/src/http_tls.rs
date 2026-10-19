//! One blocking HTTPS request with a client certificate.
//!
//! Two things this file exists to get right.
//!
//! **The address is substituted, the hostname is not.** The guests have no DNS
//! resolver (aaos/nexus-connectivity-agent/deploy.sh:7-8), so the caller passes
//! the address to dial. The socket goes there; the name checked against the
//! server's certificate is still the hostname from the URL. Verifying against
//! the address instead would be a weaker thing that passes the same happy-path
//! test — and would need the certificate to carry an IP SAN, which is the
//! failure TESTING.md's troubleshooting section describes. The Go client this
//! replaces drew the same line (sample-clients/vehicle-client/main.go:225-239).
//!
//! **The response framing is not assumed.** The two peers are different servers
//! and a deployment may put a proxy in front of either, so `Content-Length`,
//! `chunked` and read-to-close are all handled rather than one of them guessed.

use std::io::{Read, Write};
use std::sync::Arc;
use std::time::Duration;

/// Upper bound on a single request. The Go client used 30 seconds
/// (sample-clients/vehicle-client/main.go:319); the caller retries, so a long
/// wait buys nothing.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

pub struct Target {
    /// The name presented in SNI and checked against the server's certificate.
    pub host: String,
    pub port: u16,
    /// The address to connect to instead of resolving `host`. `None` uses the
    /// system resolver, which the guests do not have.
    pub dial_addr: Option<String>,
}

pub struct Identity {
    pub cert_chain_pem: Vec<u8>,
    pub key_pem: Vec<u8>,
}

pub struct Response {
    pub status: u16,
    pub body: Vec<u8>,
}

/// Written out rather than derived: one of these bodies is Keycloak's answer,
/// which carries the access token. A derived `Debug` would put it into whatever
/// prints the response.
impl std::fmt::Debug for Response {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "Response {{ status: {}, body: {} bytes }}",
            self.status,
            self.body.len()
        )
    }
}

#[derive(Debug)]
pub enum HttpError {
    Url(String),
    Trust(String),
    Identity(String),
    Tls(String),
    Connect(String),
    Io(String),
    Response(String),
}

impl std::fmt::Display for HttpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            HttpError::Url(e) => write!(f, "{e}"),
            HttpError::Trust(e) => write!(f, "{e}"),
            HttpError::Identity(e) => write!(f, "{e}"),
            HttpError::Tls(e) => write!(f, "TLS failed: {e}"),
            HttpError::Connect(e) => write!(f, "{e}"),
            HttpError::Io(e) => write!(f, "{e}"),
            HttpError::Response(e) => write!(f, "cannot read the response: {e}"),
        }
    }
}

/// rustls needs exactly one crypto provider installed for the process. Only
/// `ring` is compiled in, so this can never pick the wrong one; the call is
/// idempotent and an error means somebody already installed it, which is fine.
/// The same pattern is used on the server side
/// (base-services/registration/server/src/listener/tls_listener.rs:308).
pub fn ensure_crypto_provider() {
    let _ = rustls::crypto::ring::default_provider().install_default();
}

/// Host and port of an `https://host[:port][/path]` URL. Deliberately not a
/// general URL parser: the two URLs this handles come from the deployment and
/// always name a host (`registration.<domain>:8443`, `keycloak.<domain>:8443` —
/// aaos/aaos-nexus-sdv-tcu/provision-and-run.sh:137). An address belongs in
/// `Target::dial_addr`, never in the URL; putting one in the URL is the mistake
/// TESTING.md's "IP SANs" troubleshooting entry describes. An IPv6 literal in
/// the URL is not supported and would be reported as a bad port.
pub fn split_https_url(url: &str) -> Result<(String, u16), HttpError> {
    let rest = url
        .strip_prefix("https://")
        .ok_or_else(|| HttpError::Url(format!("not an https URL: {url}")))?;
    let authority = rest.split('/').next().unwrap_or(rest);
    if authority.is_empty() {
        return Err(HttpError::Url(format!("no host in {url}")));
    }
    match authority.rsplit_once(':') {
        Some((host, port)) => {
            let port = port
                .parse::<u16>()
                .map_err(|_| HttpError::Url(format!("{port:?} is not a port number, in {url}")))?;
            Ok((host.to_string(), port))
        }
        None => Ok((authority.to_string(), 443)),
    }
}

fn client_config(
    trust_anchor_pem: &[u8],
    identity: &Identity,
) -> Result<rustls::ClientConfig, HttpError> {
    ensure_crypto_provider();

    let mut roots = rustls::RootCertStore::empty();
    for cert in rustls_pemfile::certs(&mut std::io::BufReader::new(trust_anchor_pem)) {
        let cert =
            cert.map_err(|e| HttpError::Trust(format!("cannot read the trust anchor: {e}")))?;
        roots
            .add(cert)
            .map_err(|e| HttpError::Trust(format!("the trust anchor was rejected: {e}")))?;
    }
    if roots.is_empty() {
        return Err(HttpError::Trust(
            "the trust anchor file holds no certificate".to_string(),
        ));
    }

    let chain = rustls_pemfile::certs(&mut std::io::BufReader::new(&identity.cert_chain_pem[..]))
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| HttpError::Identity(format!("cannot read the client certificate: {e}")))?;
    let key = rustls_pemfile::private_key(&mut std::io::BufReader::new(&identity.key_pem[..]))
        .map_err(|e| HttpError::Identity(format!("cannot read the client key: {e}")))?
        .ok_or_else(|| HttpError::Identity("no private key in the client key file".to_string()))?;

    rustls::ClientConfig::builder()
        .with_root_certificates(roots)
        .with_client_auth_cert(chain, key)
        .map_err(|e| HttpError::Tls(format!("rustls rejected the client certificate: {e}")))
}

pub struct Post<'a> {
    pub target: &'a Target,
    pub path: &'a str,
    pub content_type: &'a str,
    pub body: &'a [u8],
    pub trust_anchor_pem: &'a [u8],
    pub identity: &'a Identity,
}

pub fn post(req: Post<'_>) -> Result<Response, HttpError> {
    let config = client_config(req.trust_anchor_pem, req.identity)?;

    // The name verified against the server's certificate. It comes from the URL
    // and never from `dial_addr`; that split is the whole point of this module.
    let server_name = rustls_pki_types::ServerName::try_from(req.target.host.clone())
        .map_err(|e| HttpError::Url(format!("{} is not a valid hostname: {e}", req.target.host)))?;

    let dial_host = req.target.dial_addr.as_deref().unwrap_or(&req.target.host);
    let addr = format!("{dial_host}:{}", req.target.port);
    let socket = std::net::TcpStream::connect(&addr)
        .map_err(|e| HttpError::Connect(format!("cannot reach {addr}: {e}")))?;
    socket
        .set_read_timeout(Some(REQUEST_TIMEOUT))
        .map_err(|e| HttpError::Io(format!("cannot set a read timeout: {e}")))?;
    socket
        .set_write_timeout(Some(REQUEST_TIMEOUT))
        .map_err(|e| HttpError::Io(format!("cannot set a write timeout: {e}")))?;

    let conn = rustls::ClientConnection::new(Arc::new(config), server_name)
        .map_err(|e| HttpError::Tls(e.to_string()))?;
    let mut stream = rustls::StreamOwned::new(conn, socket);

    // The port is always in the Host header: the deployed URLs carry :8443, and a
    // proxy in front of either service selects on the name it was addressed by.
    let head = format!(
        "POST {path} HTTP/1.1\r\n\
         Host: {host}:{port}\r\n\
         Content-Type: {content_type}\r\n\
         Content-Length: {length}\r\n\
         Connection: close\r\n\
         \r\n",
        path = req.path,
        host = req.target.host,
        port = req.target.port,
        content_type = req.content_type,
        length = req.body.len(),
    );
    stream
        .write_all(head.as_bytes())
        .map_err(|e| HttpError::Io(format!("sending the request head to {addr}: {e}")))?;
    stream
        .write_all(req.body)
        .map_err(|e| HttpError::Io(format!("sending the request body to {addr}: {e}")))?;
    stream
        .flush()
        .map_err(|e| HttpError::Io(format!("flushing the request to {addr}: {e}")))?;

    let mut raw = Vec::new();
    match stream.read_to_end(&mut raw) {
        Ok(_) => {}
        // `Connection: close` means the peer closes when it is done. Some servers
        // drop the TCP connection without a TLS close_notify, which rustls reports
        // as an unexpected end of file. What arrived before that is still the
        // whole response.
        Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof && !raw.is_empty() => {}
        Err(e) => {
            return Err(HttpError::Io(format!(
                "reading the response from {addr}: {e}"
            )))
        }
    }
    parse_response(&raw)
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

pub fn parse_response(raw: &[u8]) -> Result<Response, HttpError> {
    let split = find(raw, b"\r\n\r\n")
        .ok_or_else(|| HttpError::Response("no header/body separator in the answer".to_string()))?;
    let head = std::str::from_utf8(&raw[..split])
        .map_err(|_| HttpError::Response("the response headers are not UTF-8".to_string()))?;

    let mut lines = head.split("\r\n");
    let status_line = lines.next().unwrap_or("");
    let status = status_line
        .split(' ')
        .nth(1)
        .and_then(|code| code.parse::<u16>().ok())
        .ok_or_else(|| {
            HttpError::Response(format!("no status code in the status line {status_line:?}"))
        })?;

    let mut content_length: Option<usize> = None;
    let mut chunked = false;
    for line in lines {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        match name.trim().to_ascii_lowercase().as_str() {
            "content-length" => content_length = value.trim().parse::<usize>().ok(),
            "transfer-encoding" => chunked = value.to_ascii_lowercase().contains("chunked"),
            _ => {}
        }
    }

    let body = &raw[split + 4..];
    let body = if chunked {
        dechunk(body)?
    } else if let Some(n) = content_length {
        body.get(..n)
            .ok_or_else(|| {
                HttpError::Response(format!("the body is shorter than its Content-Length of {n}"))
            })?
            .to_vec()
    } else {
        // No length and no chunking: with `Connection: close` the body runs to the
        // close, which is everything we already hold.
        body.to_vec()
    };

    Ok(Response { status, body })
}

fn dechunk(mut body: &[u8]) -> Result<Vec<u8>, HttpError> {
    let mut out = Vec::new();
    loop {
        let line_end = find(body, b"\r\n")
            .ok_or_else(|| HttpError::Response("a chunk header is cut off".to_string()))?;
        let header = std::str::from_utf8(&body[..line_end])
            .map_err(|_| HttpError::Response("a chunk header is not UTF-8".to_string()))?;
        // A chunk header may carry extensions after a semicolon; the size is the
        // hexadecimal number in front of it.
        let size_text = header.split(';').next().unwrap_or("").trim();
        let size = usize::from_str_radix(size_text, 16).map_err(|_| {
            HttpError::Response(format!("the chunk size {size_text:?} is not hexadecimal"))
        })?;
        body = &body[line_end + 2..];
        if size == 0 {
            return Ok(out);
        }
        let chunk = body
            .get(..size)
            .ok_or_else(|| HttpError::Response("a chunk is shorter than announced".to_string()))?;
        out.extend_from_slice(chunk);
        // Each chunk is followed by its own CRLF.
        body = body
            .get(size + 2..)
            .ok_or_else(|| HttpError::Response("a chunk is not terminated".to_string()))?;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rcgen::{BasicConstraints, CertificateParams, IsCa, Issuer, KeyPair};
    use std::io::BufReader;
    use std::net::TcpListener;

    /// If this builds and runs, rustls, ring and the client config builder are all present
    /// and agree with each other.
    #[test]
    fn builds_a_client_config_with_no_client_certificate() {
        ensure_crypto_provider();
        let roots = rustls::RootCertStore::empty();
        let _config = rustls::ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth();
    }

    #[test]
    fn splits_a_url_with_an_explicit_port() {
        let (host, port) = split_https_url("https://registration.nexus.example.org:8443").unwrap();
        assert_eq!(host, "registration.nexus.example.org");
        assert_eq!(port, 8443);
    }

    #[test]
    fn splits_a_url_with_a_trailing_path() {
        let (host, port) = split_https_url("https://keycloak.example.org:8443/auth").unwrap();
        assert_eq!(host, "keycloak.example.org");
        assert_eq!(port, 8443);
    }

    #[test]
    fn defaults_to_443_without_a_port() {
        let (host, port) = split_https_url("https://keycloak.example.org").unwrap();
        assert_eq!(host, "keycloak.example.org");
        assert_eq!(port, 443);
    }

    #[test]
    fn refuses_a_url_that_is_not_https() {
        assert!(split_https_url("http://registration.example.org:8443").is_err());
    }

    #[test]
    fn reads_a_body_announced_by_content_length() {
        let raw = b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"ok\":\"yes\"}\n";
        let response = parse_response(raw).unwrap();
        assert_eq!(response.status, 200);
        assert_eq!(response.body, b"{\"ok\":\"yes\"}\n");
    }

    #[test]
    fn reassembles_a_chunked_body() {
        let raw = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n";
        let response = parse_response(raw).unwrap();
        assert_eq!(response.status, 200);
        assert_eq!(response.body, b"hello world");
    }

    /// A chunk header may carry extensions after a semicolon; the size is what
    /// precedes it.
    #[test]
    fn ignores_chunk_extensions() {
        let raw = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;x=1\r\nhello\r\n0\r\n\r\n";
        assert_eq!(parse_response(raw).unwrap().body, b"hello");
    }

    /// Neither length nor chunking: with `Connection: close` the body is
    /// everything up to the close.
    #[test]
    fn reads_an_unframed_body_to_the_end() {
        let raw = b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nhealthy";
        assert_eq!(parse_response(raw).unwrap().body, b"healthy");
    }

    #[test]
    fn keeps_the_status_code_of_a_refusal() {
        let raw = b"HTTP/1.1 400 Bad Request\r\nContent-Length: 30\r\n\r\n{\"error\":{\"code\":\"400\",\"m\":1}}";
        let response = parse_response(raw).unwrap();
        assert_eq!(response.status, 400);
    }

    #[test]
    fn header_names_are_matched_without_regard_to_case() {
        let raw = b"HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nhi";
        assert_eq!(parse_response(raw).unwrap().body, b"hi");
    }

    #[test]
    fn says_so_when_there_is_no_header_body_separator() {
        let err = parse_response(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n").unwrap_err();
        assert!(format!("{err}").contains("separator"), "{err}");
    }

    /// A TLS server on loopback answering one request, holding a certificate
    /// that names `cert_hostname` and nothing else. Returns the port to dial and
    /// the PEM of the CA that signed it, so a test can vary the name it claims
    /// to be talking to while everything else stays equal.
    fn tls_server_for(cert_hostname: &str) -> (u16, String) {
        ensure_crypto_provider();

        let ca_key = KeyPair::generate().expect("CA key pair");
        let mut ca_params = CertificateParams::new(Vec::new()).expect("CA parameters");
        ca_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
        let ca_pem = ca_params.self_signed(&ca_key).expect("CA certificate").pem();

        let server_key = KeyPair::generate().expect("server key pair");
        let server_params =
            CertificateParams::new(vec![cert_hostname.to_string()]).expect("server parameters");
        let server_pem = server_params
            .signed_by(&server_key, &Issuer::from_params(&ca_params, &ca_key))
            .expect("server certificate")
            .pem();

        let chain = rustls_pemfile::certs(&mut BufReader::new(server_pem.as_bytes()))
            .collect::<Result<Vec<_>, _>>()
            .expect("server certificate PEM");
        let key = rustls_pemfile::private_key(&mut BufReader::new(
            server_key.serialize_pem().as_bytes(),
        ))
        .expect("server key PEM")
        .expect("a private key");
        let config = rustls::ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(chain, key)
            .expect("server config");

        let listener = TcpListener::bind("127.0.0.1:0").expect("a loopback port");
        let port = listener.local_addr().expect("the bound address").port();
        std::thread::spawn(move || {
            let Ok((socket, _)) = listener.accept() else {
                return;
            };
            let conn = rustls::ServerConnection::new(Arc::new(config)).expect("server connection");
            let mut stream = rustls::StreamOwned::new(conn, socket);
            // Reading drives the handshake. A client that rejects this
            // certificate never sends a request, so this fails and the thread
            // ends — the refusal is the client's to report.
            let mut buf = [0u8; 1024];
            if stream.read(&mut buf).is_err() {
                return;
            }
            let _ = stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");
            let _ = stream.flush();
            stream.conn.send_close_notify();
            let _ = stream.flush();
        });
        (port, ca_pem)
    }

    /// A client certificate is required by `post`, and this server does not ask
    /// for one, so any self-signed pair will do.
    fn client_identity() -> Identity {
        let key = KeyPair::generate().expect("client key pair");
        let cert = CertificateParams::new(Vec::new())
            .expect("client parameters")
            .self_signed(&key)
            .expect("client certificate");
        Identity {
            cert_chain_pem: cert.pem().into_bytes(),
            key_pem: key.serialize_pem().into_bytes(),
        }
    }

    /// The point of the module: the socket goes to the address it was given,
    /// while the name checked in the handshake is the one from the URL.
    #[test]
    fn dials_an_address_and_accepts_the_hostname_the_certificate_carries() {
        let (port, ca_pem) = tls_server_for("registration.test.invalid");
        let target = Target {
            host: "registration.test.invalid".to_string(),
            port,
            dial_addr: Some("127.0.0.1".to_string()),
        };
        let identity = client_identity();
        let response = post(Post {
            target: &target,
            path: "/register",
            content_type: "application/json",
            body: b"{}",
            trust_anchor_pem: ca_pem.as_bytes(),
            identity: &identity,
        })
        .expect("the handshake must succeed for the name the certificate carries");
        assert_eq!(response.status, 200);
        assert_eq!(response.body, b"ok");
    }

    /// Same CA, same address, different hostname. Verifying the address instead
    /// of the name would let this through, which is why it is a test.
    #[test]
    fn refuses_a_certificate_that_names_a_different_host() {
        let (port, ca_pem) = tls_server_for("registration.test.invalid");
        let target = Target {
            host: "someone-else.test.invalid".to_string(),
            port,
            dial_addr: Some("127.0.0.1".to_string()),
        };
        let identity = client_identity();
        let err = post(Post {
            target: &target,
            path: "/register",
            content_type: "application/json",
            body: b"{}",
            trust_anchor_pem: ca_pem.as_bytes(),
            identity: &identity,
        })
        .unwrap_err();
        assert!(format!("{err}").contains("not valid for name"), "{err}");
    }
}
