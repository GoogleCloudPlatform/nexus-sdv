use std::{io, net::SocketAddr, sync::Arc};

use anyhow::bail;
use arc_swap::ArcSwap;
use axum::serve::Listener;
use rustls::ServerConfig;
use tokio::net::{TcpListener, TcpStream};
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
pub struct ReloadableTlsListener {
    tcp_listener: TcpListener,
    config: Arc<ArcSwap<ServerConfig>>,
}

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

        Ok(Self {
            tcp_listener,
            config,
        })
    }
}

impl Listener for ReloadableTlsListener {
    type Io = TlsConnectionStream;
    type Addr = SocketAddr;

    async fn accept(&mut self) -> (Self::Io, Self::Addr) {
        loop {
            match self.tcp_listener.accept().await {
                Ok((tcp_stream, peer_addr)) => {
                    // Get the current config - this allows hot-reloading
                    // New connections will use the latest certificates
                    let current_config: Arc<ServerConfig> = self.config.load_full();
                    let tls_acceptor = TlsAcceptor::from(current_config);

                    match tls_acceptor.accept(tcp_stream).await {
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
                    }
                }
                Err(_) => continue,
            }
        }
    }

    fn local_addr(&self) -> io::Result<SocketAddr> {
        self.tcp_listener.local_addr()
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
