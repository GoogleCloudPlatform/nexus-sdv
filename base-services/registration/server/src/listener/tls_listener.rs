use std::time::Duration;
use std::{io, net::SocketAddr, sync::Arc};

use anyhow::bail;
use arc_swap::ArcSwap;
use axum::serve::Listener;
use rustls::ServerConfig;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;
use tokio::time::timeout;
use tokio_rustls::TlsAcceptor;

use x509_parser::prelude::{FromDer, X509Certificate};

use crate::listener::tls::{TlsConnectInfo, TlsConnectionStream};

#[derive(Debug, Clone)]
pub struct VehicleInfoHolder(String);

#[derive(Debug, Clone)]
pub struct VehicleInfo {
    pub vin: String,
    pub device_id: String,
}

impl PartialEq for VehicleInfo {
    fn eq(&self, other: &Self) -> bool {
        self.vin == other.vin && self.device_id == other.device_id
    }
}

impl From<String> for VehicleInfoHolder {
    fn from(value: String) -> Self {
        VehicleInfoHolder(value)
    }
}

impl VehicleInfoHolder {
    pub fn parse_from_cn(cn: &str) -> anyhow::Result<VehicleInfo> {
        let cn_value = cn;

        let mut vin = None;
        let mut device_id = None;

        for part in cn_value.split_whitespace() {
            if let Some(vin_part) = part.strip_prefix("VIN:") {
                vin = Some(vin_part.to_string());
            } else if let Some(device_part) = part.strip_prefix("DEVICE:") {
                device_id = Some(device_part.to_string());
            }
        }

        let (Some(vin), Some(device_id)) = (vin, device_id) else {
            bail!("VIN or Deviceid not found in Certificate");
        };

        let device_info = VehicleInfo { vin, device_id };
        Ok(device_info)
    }

    pub fn parse_vehicleinfo(&self) -> anyhow::Result<VehicleInfo> {
        for component in self.0.split(',') {
            let component = component.trim();
            if let Some(cn_value) = component.strip_prefix("CN=") {
                return Self::parse_from_cn(cn_value);
            }
        }
        bail!("no CN found in DN")
    }
}

/// the info for a client certificate in a [TlsConnectInfo]
#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct ClientCertInfo {
    pub subject: VehicleInfoHolder,
    pub issuer: String,
    pub serial: String,
    pub not_before: String,
    pub not_after: String,
    pub raw_der: Vec<u8>,
}

pub struct TlsListenerClientCertificate {
    tcp_listener: TcpListener,
    tls_acceptor: TlsAcceptor,
}

impl TlsListenerClientCertificate {
    pub async fn bind(addr: SocketAddr, config: ServerConfig) -> io::Result<Self> {
        let tcp_listener = TcpListener::bind(addr).await?;
        let tls_acceptor = TlsAcceptor::from(Arc::new(config));

        Ok(Self {
            tcp_listener,
            tls_acceptor,
        })
    }
}

impl Listener for TlsListenerClientCertificate {
    type Io = TlsConnectionStream;
    type Addr = SocketAddr;

    async fn accept(&mut self) -> (Self::Io, Self::Addr) {
        // it seems there is no way to communicate an error in Listener
        // so we use a loop here
        // This works because axum uses accept to get connections and spawns
        // a task for it.
        // If we here cannot accept a connection we stay in the loop and don't return this connection
        // The connection to client will be dropped
        loop {
            match self.tcp_listener.accept().await {
                Ok((tcp_stream, peer_addr)) => match self.tls_acceptor.accept(tcp_stream).await {
                    Ok(tls_stream) => {
                        let client_certificate = extract_client_certificate(&tls_stream);

                        let connect_info = TlsConnectInfo {
                            client_certificate,
                            peer_addr,
                        };

                        let connection_stream = TlsConnectionStream {
                            tls_stream,
                            connect_info,
                        };

                        return (connection_stream, self.tcp_listener.local_addr().unwrap());
                    }
                    Err(_) => continue,
                },
                Err(_) => continue,
            }
        }
    }

    fn local_addr(&self) -> io::Result<SocketAddr> {
        self.tcp_listener.local_addr()
    }
}

/// A TLS listener that supports hot-reloading of certificates.
///
/// This listener uses an `ArcSwap` to atomically swap the `ServerConfig`
/// when certificates are reloaded. Each new connection will use the
/// latest configuration.
///
/// TLS handshakes run **off** the accept path: a background task accepts TCP
/// connections and performs each handshake in its own task, pushing completed
/// connections through a channel. `accept()` only drains that channel. A slow
/// or stalled handshake therefore occupies just its own task and can never
/// block accepting — or handshaking — other connections.
pub struct ReloadableTlsListener {
    rx: mpsc::Receiver<TlsConnectionStream>,
    local_addr: SocketAddr,
}

/// Upper bound on a single TLS handshake. A stalled peer is dropped after this
/// instead of holding its socket (and task) open indefinitely.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);

impl ReloadableTlsListener {
    /// Creates a new reloadable TLS listener bound to the given address.
    ///
    /// The `config` parameter is a shared reference to an `ArcSwap` that
    /// can be updated atomically when certificates need to be reloaded.
    pub async fn bind(
        addr: SocketAddr,
        config: Arc<ArcSwap<ServerConfig>>,
    ) -> io::Result<Self> {
        let tcp_listener = TcpListener::bind(addr).await?;
        let local_addr = tcp_listener.local_addr()?;

        // Channel of fully-handshaked connections, ready to hand to axum.
        let (tx, rx) = mpsc::channel::<TlsConnectionStream>(1024);

        // Background acceptor: accept TCP fast, then hand each connection to its
        // own task for the TLS handshake.
        tokio::spawn(async move {
            loop {
                let (tcp_stream, peer_addr) = match tcp_listener.accept().await {
                    Ok(pair) => pair,
                    // TODO(#2): back off on EMFILE/ENFILE instead of spinning.
                    Err(_) => continue,
                };

                // Load the current config per connection: preserves hot-reload.
                let current_config: Arc<ServerConfig> = config.load_full();
                let tx = tx.clone();
                tokio::spawn(async move {
                    let tls_acceptor = TlsAcceptor::from(current_config);
                    // Bound the handshake so a stalled peer frees its socket/task.
                    let tls_stream =
                        match timeout(HANDSHAKE_TIMEOUT, tls_acceptor.accept(tcp_stream)).await {
                            Ok(Ok(tls_stream)) => tls_stream,
                            // Handshake failed or timed out: drop the connection.
                            Ok(Err(_)) | Err(_) => return,
                        };

                    let client_certificate = extract_client_certificate(&tls_stream);
                    let connection_stream = TlsConnectionStream {
                        tls_stream,
                        connect_info: TlsConnectInfo {
                            client_certificate,
                            peer_addr,
                        },
                    };

                    // If the receiver is gone (shutdown), just drop the connection.
                    let _ = tx.send(connection_stream).await;
                });
            }
        });

        Ok(Self { rx, local_addr })
    }
}

impl Listener for ReloadableTlsListener {
    type Io = TlsConnectionStream;
    type Addr = SocketAddr;

    async fn accept(&mut self) -> (Self::Io, Self::Addr) {
        // Hand axum the next completed connection. Handshakes proceed
        // concurrently in the background, so one slow client no longer stalls
        // this loop. `recv()` yields `None` only once the acceptor task is gone
        // (shutdown); axum's `accept()` must not return, so we park.
        match self.rx.recv().await {
            Some(connection_stream) => (connection_stream, self.local_addr),
            None => std::future::pending().await,
        }
    }

    fn local_addr(&self) -> io::Result<SocketAddr> {
        Ok(self.local_addr)
    }
}

fn parse_client_certificate(cert_der: &[u8]) -> Result<ClientCertInfo, Box<dyn std::error::Error>> {
    let (_, cert) = X509Certificate::from_der(cert_der)?;

    Ok(ClientCertInfo {
        subject: VehicleInfoHolder(cert.subject().to_string()),
        issuer: cert.issuer().to_string(),
        serial: cert.serial.to_string(),
        not_before: cert.validity().not_before.to_string(),
        not_after: cert.validity().not_after.to_string(),
        raw_der: cert_der.to_vec(),
    })
}

fn extract_client_certificate(
    tls_stream: &tokio_rustls::server::TlsStream<TcpStream>,
) -> Option<ClientCertInfo> {
    let (_, connection) = tls_stream.get_ref();

    if let Some(peer_certs) = connection.peer_certificates() {
        if let Some(client_cert_der) = peer_certs.first() {
            return parse_client_certificate(client_cert_der.as_ref()).ok();
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::ReloadableTlsListener;
    use std::sync::Arc;
    use std::time::Duration;

    use arc_swap::ArcSwap;
    use axum::serve::Listener;
    use rcgen::{CertificateParams, KeyPair};
    use rustls::{ClientConfig, RootCertStore, ServerConfig};
    use rustls_pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, ServerName};
    use tokio::net::TcpStream;
    use tokio::sync::mpsc;
    use tokio::time::timeout;
    use tokio_rustls::TlsConnector;

    fn server_config() -> (ServerConfig, CertificateDer<'static>) {
        let key_pair = KeyPair::generate().unwrap();
        let params = CertificateParams::new(vec!["localhost".to_string()]).unwrap();
        let cert = params.self_signed(&key_pair).unwrap();
        let cert_der: CertificateDer<'static> = cert.der().clone();
        let key_der = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key_pair.serialize_der()));
        let config = ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(vec![cert_der.clone()], key_der)
            .expect("server config");
        (config, cert_der)
    }

    fn client_connector(server_cert: CertificateDer<'static>) -> TlsConnector {
        let mut roots = RootCertStore::empty();
        roots.add(server_cert).unwrap();
        let config = ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth();
        TlsConnector::from(Arc::new(config))
    }

    /// #1 regression: a client that opens a TCP connection but never completes
    /// the TLS handshake must not block a healthy client from being accepted.
    /// With the old inline-handshake accept loop this test times out.
    #[tokio::test]
    async fn slow_handshake_does_not_block_accept() {
        let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();

        let (config, server_cert) = server_config();
        let shared = Arc::new(ArcSwap::from_pointee(config));

        let mut listener = ReloadableTlsListener::bind("127.0.0.1:0".parse().unwrap(), shared)
            .await
            .expect("bind");
        let addr = listener.local_addr().expect("local_addr");

        // Drive the listener the way axum's serve loop does.
        let (accepted_tx, mut accepted_rx) = mpsc::unbounded_channel::<()>();
        tokio::spawn(async move {
            loop {
                let (stream, _) = listener.accept().await;
                let _ = accepted_tx.send(());
                tokio::spawn(async move {
                    let _held = stream;
                    tokio::time::sleep(Duration::from_secs(30)).await;
                });
            }
        });

        // Stalled client: TCP connects, then never sends a ClientHello.
        let _stalled = TcpStream::connect(addr).await.expect("stalled tcp connect");
        tokio::time::sleep(Duration::from_millis(200)).await;

        // Healthy client: completes a real handshake (fire and forget).
        let connector = client_connector(server_cert);
        tokio::spawn(async move {
            if let Ok(tcp) = TcpStream::connect(addr).await {
                let domain = ServerName::try_from("localhost").unwrap();
                let _ = connector.connect(domain, tcp).await;
            }
        });

        let accepted = timeout(Duration::from_secs(3), accepted_rx.recv()).await;
        assert!(
            matches!(accepted, Ok(Some(()))),
            "healthy client was not accepted while another handshake was stalled — accept loop blocked"
        );
    }
}
