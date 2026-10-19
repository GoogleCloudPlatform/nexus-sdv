//! F53: a connection to the leaf that the kernel joined to itself must be refused.
#[cfg(target_os = "linux")]
use socket2::{Domain, Socket, Type};
use std::net::{SocketAddr, TcpListener};

/// A socket bound to a free port and connected to that same port, with nothing listening:
/// TCP's simultaneous open joins it to itself, as on the vehicle when the leaf is down and
/// the kernel picks 4222 as the source port. Linux only: macOS refuses the connect (EINVAL).
#[cfg(target_os = "linux")]
fn self_connected() -> std::net::TcpStream {
    let free = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap();
    let socket = Socket::new(Domain::IPV4, Type::STREAM, None).unwrap();
    socket.bind(&free.into()).unwrap();
    socket.connect(&free.into()).unwrap();
    socket.into()
}

#[cfg(target_os = "linux")]
#[test]
fn a_socket_connected_to_itself_is_refused() {
    let stream = self_connected();
    assert_eq!(stream.local_addr().unwrap(), stream.peer_addr().unwrap());
    let err = crate::leaf_connect::refuse_self(stream).unwrap_err();
    assert!(err.to_string().contains("itself"), "{err}");
}

#[test]
fn a_connection_to_a_listening_leaf_is_kept() {
    let leaf = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr: SocketAddr = leaf.local_addr().unwrap();
    assert!(crate::leaf_connect::connect(&addr.to_string()).is_ok());
}
