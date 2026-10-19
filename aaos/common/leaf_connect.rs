//! Connecting to the leaf on this VM without connecting to oneself.
//!
//! While the leaf is down, the kernel may pick the leaf's own port as the source port of a
//! connection to it; TCP then joins the socket to itself, and that socket holds the port the
//! leaf needs. On the SDV image the source ports are 4000–5999, the leaf's is 4222 (F53).
//! Such a connection is closed and reported as an error, so the caller retries.
use std::io;
use std::net::TcpStream;

/// Connects to the leaf at `addr`.
pub fn connect(addr: &str) -> io::Result<TcpStream> {
    TcpStream::connect(addr).and_then(refuse_self)
}

/// Passes `stream` on unless it is connected to itself; such a stream is closed.
pub fn refuse_self(stream: TcpStream) -> io::Result<TcpStream> {
    if stream.local_addr()? == stream.peer_addr()? {
        return Err(io::Error::new(
            io::ErrorKind::ConnectionRefused,
            "connected to itself, the leaf is not up yet",
        ));
    }
    Ok(stream)
}
