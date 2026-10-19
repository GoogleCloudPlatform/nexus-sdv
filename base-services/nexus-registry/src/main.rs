//! nexus-registry: REST for cloud services on 8080, announces from vehicles over the hub.

use std::env;
use std::future::IntoFuture;
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use anyhow::Context;
use nexus_registry::api::router;
use nexus_registry::nats::{NatsNotifier, announces, serve_announces};
use nexus_registry::registry::Registry;
use nexus_registry::store::JetStreamStore;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")))
        .init();
    let url = env::var("NATS_URL").unwrap_or_else(|_| "nats://nats.base-services.svc.cluster.local:4222".into());
    let user = env::var("NATS_USER").unwrap_or_else(|_| "nexus-registry".into());
    let password = env::var("NATS_PASSWORD").context("NATS_PASSWORD is required")?;
    let listen = env::var("LISTEN_ADDR").unwrap_or_else(|_| "0.0.0.0:8080".into());
    let lease = Duration::from_secs(match env::var("LEASE_SECONDS") {
        Ok(seconds) => parse_lease_seconds(&seconds)?,
        Err(_) => 900,
    });

    tracing::info!(user = %user, "connecting to the hub");
    let client = async_nats::ConnectOptions::with_user_and_password(user, password)
        .name("nexus-registry")
        .retry_on_initial_connect()
        .connect(url.as_str())
        .await?;
    let store = Arc::new(JetStreamStore::open(&async_nats::jetstream::new(client.clone())).await?);
    let registry = Arc::new(Registry::new(store, Arc::new(NatsNotifier::new(client.clone()))));
    let subscription = announces(&client).await?;
    let announce_loop = tokio::spawn(serve_announces(client, subscription, registry.clone()));
    tokio::spawn(sweep_leases(registry.clone(), lease));

    let listener = tokio::net::TcpListener::bind(&listen).await?;
    tracing::info!(listen = %listen, lease_seconds = lease.as_secs(), "serving");
    tokio::select! {
        served = axum::serve(listener, router(registry)).into_future() => served?,
        ended = announce_loop => ended??,
    }
    Ok(())
}

/// Every 60 s, drops the registrations not renewed within the lease (spec section 4, "Lease").
/// A failed sweep is logged and tried again on the next tick; it never ends the process.
async fn sweep_leases(registry: Arc<Registry>, lease: Duration) {
    let mut tick = tokio::time::interval(Duration::from_secs(60));
    loop {
        tick.tick().await;
        if let Err(e) = registry.expire(SystemTime::now(), lease).await {
            tracing::warn!(error = %e, "lease sweep failed; retrying on the next tick");
        }
    }
}

/// `LEASE_SECONDS`: a non-number is rejected, and so is `0` — a lease of no length would
/// drop every registration on the sweep right after it was written.
fn parse_lease_seconds(value: &str) -> anyhow::Result<u64> {
    let seconds: u64 = value.parse().context("LEASE_SECONDS must be a whole number of seconds")?;
    if seconds == 0 {
        anyhow::bail!("LEASE_SECONDS must be greater than 0");
    }
    Ok(seconds)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_is_rejected() {
        assert!(parse_lease_seconds("0").is_err());
    }

    #[test]
    fn nine_hundred_is_accepted() {
        assert_eq!(parse_lease_seconds("900").unwrap(), 900);
    }

    #[test]
    fn a_non_number_is_rejected() {
        assert!(parse_lease_seconds("abc").is_err());
    }
}
