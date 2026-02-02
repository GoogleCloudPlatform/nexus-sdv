use std::{
    io,
    net::SocketAddr,
    pin::Pin,
    task::{Context, Poll},
};

use axum::{extract::connect_info::Connected, serve::IncomingStream};
use tokio::{
    io::{AsyncRead, AsyncWrite},
    net::TcpStream,
};
use tokio_rustls::server::TlsStream;

use crate::listener::tls_listener::ClientCertInfo;

use super::{ReloadableTlsListener, TlsListenerClientCertificate};

pub struct TlsConnectionStream {
    pub tls_stream: TlsStream<TcpStream>,
    pub connect_info: TlsConnectInfo,
}

impl AsyncRead for TlsConnectionStream {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        Pin::new(&mut self.tls_stream).poll_read(cx, buf)
    }
}

impl AsyncWrite for TlsConnectionStream {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<Result<usize, io::Error>> {
        Pin::new(&mut self.tls_stream).poll_write(cx, buf)
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Result<(), io::Error>> {
        Pin::new(&mut self.tls_stream).poll_flush(cx)
    }

    fn poll_shutdown(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Result<(), io::Error>> {
        Pin::new(&mut self.tls_stream).poll_shutdown(cx)
    }
}

#[derive(Debug, Clone)]
pub struct TlsConnectInfo {
    /// this is optional because we set it in the [TlsListenerClientCertificate]
    /// The processing is only stopped by the extractor with a meaningful
    /// error message if the extractor is used.
    /// So it is possible to have handlers w/ and w/o client certificate and have
    /// control over the error message
    pub client_certificate: Option<ClientCertInfo>,

    /// peer addr is set but at the moment not used
    #[allow(unused)]
    pub peer_addr: SocketAddr,
}

impl Connected<TlsConnectionStream> for TlsConnectInfo {
    fn connect_info(stream: TlsConnectionStream) -> Self {
        stream.connect_info
    }
}
impl<'a> Connected<IncomingStream<'a, TlsListenerClientCertificate>> for TlsConnectInfo {
    fn connect_info(stream: IncomingStream<'a, TlsListenerClientCertificate>) -> Self {
        stream.io().connect_info.clone()
    }
}

impl<'a> Connected<IncomingStream<'a, ReloadableTlsListener>> for TlsConnectInfo {
    fn connect_info(stream: IncomingStream<'a, ReloadableTlsListener>) -> Self {
        stream.io().connect_info.clone()
    }
}
