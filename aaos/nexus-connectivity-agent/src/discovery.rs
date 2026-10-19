//! Minimal gRPC discovery endpoint — a placeholder for knowledge the agent
//! already computes to render its own `leaf.conf` (Task 2/3), not a general
//! service registry. One provider (this agent), point-to-point queries from
//! known consumers (IVI, the telemetry uploader) — see the plan's Task 6.
//!
//! Runs on its own OS thread with its own Tokio runtime, deliberately
//! separate from the main scheduler loop (which stays synchronous) — the
//! smallest change that adds an always-listening endpoint without rewriting
//! the existing credential-fetch/nats-server-ownership loop to async.

use tonic::transport::Server;
use tonic::{Request, Response, Status};

pub mod proto {
    tonic::include_proto!("nexus.discovery");
    pub const FILE_DESCRIPTOR_SET: &[u8] =
        tonic::include_file_descriptor_set!("nexus_discovery_descriptor");
}

use proto::discovery_server::{Discovery, DiscoveryServer};
use proto::{GetLeafAddressRequest, GetLeafAddressResponse};

/// The port `nats-server` always binds to locally (see `leaf.rs`'s rendered
/// `leaf.conf`, `port: 4222`) — not a credential, so the discovery response
/// carries no auth.
pub const LEAF_PORT: i32 = 4222;

/// The port to serve on: `NEXUS_DISCOVERY_PORT`, else [`ports::DEFAULT_DISCOVERY_PORT`]
/// — see `ports.rs` for why the default is what it is.
pub fn port_from_env() -> u16 {
    crate::ports::from_env("NEXUS_DISCOVERY_PORT", crate::ports::DEFAULT_DISCOVERY_PORT)
}

struct DiscoveryService {
    leaf_host: String,
}

#[tonic::async_trait]
impl Discovery for DiscoveryService {
    async fn get_leaf_address(
        &self,
        _request: Request<GetLeafAddressRequest>,
    ) -> Result<Response<GetLeafAddressResponse>, Status> {
        Ok(Response::new(GetLeafAddressResponse {
            host: self.leaf_host.clone(),
            port: LEAF_PORT,
        }))
    }
}

/// `NEXUS_DISCOVERY_REFLECTION=on` turns gRPC reflection on. Anything else, including
/// unset, leaves it off: the port answers on every interface, and reflection lets any
/// peer list the service without having the `.proto`. `grpcurl` with `-proto` needs none.
fn reflection_wanted(value: Option<&str>) -> bool {
    value == Some("on")
}

/// Blocks forever serving the discovery RPC on `0.0.0.0:{port}`, and reflection if asked for.
/// Intended to be run on a dedicated thread via `thread::spawn`.
pub fn serve_blocking(leaf_host: String, port: u16) {
    let rt = tokio::runtime::Runtime::new().expect("tokio runtime for discovery server");
    rt.block_on(async {
        let addr = format!("0.0.0.0:{port}")
            .parse()
            .expect("valid discovery bind address");

        let reflection = reflection_wanted(std::env::var("NEXUS_DISCOVERY_REFLECTION").ok().as_deref());
        let reflection_v1 = reflection.then(|| {
            tonic_reflection::server::Builder::configure()
                .register_encoded_file_descriptor_set(proto::FILE_DESCRIPTOR_SET)
                .build_v1()
                .expect("build gRPC reflection v1 service")
        });
        let reflection_v1alpha = reflection.then(|| {
            tonic_reflection::server::Builder::configure()
                .register_encoded_file_descriptor_set(proto::FILE_DESCRIPTOR_SET)
                .build_v1alpha()
                .expect("build gRPC reflection v1alpha service")
        });

        let service = DiscoveryService { leaf_host };

        crate::log_line!(
            "discovery server listening on {addr}, gRPC reflection {}",
            if reflection { "on" } else { "off" }
        );
        if let Err(e) = Server::builder()
            .add_service(DiscoveryServer::new(service))
            .add_optional_service(reflection_v1)
            .add_optional_service(reflection_v1alpha)
            .serve(addr)
            .await
        {
            crate::log_err!("discovery server error: {e}");
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reflection_is_off_unless_asked_for_exactly() {
        assert!(reflection_wanted(Some("on")));
        for off in [None, Some(""), Some("off"), Some("ON"), Some("true"), Some("1"), Some("on ")] {
            assert!(!reflection_wanted(off), "{off:?}");
        }
    }
}
