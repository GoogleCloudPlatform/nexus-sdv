//! The registry's conversation with the vehicles over the hub: announce in, grant out.

use std::sync::Arc;

use async_trait::async_trait;
use bytes::Bytes;
use futures::StreamExt;
use nexus_aaos_sdk::mask;

use crate::grant::{Grant, parse_announce, vin_from_announce_subject};
use crate::registry::{Notifier, Registry};

pub struct NatsNotifier {
    client: async_nats::Client,
}

impl NatsNotifier {
    pub fn new(client: async_nats::Client) -> Self {
        NatsNotifier { client }
    }
}

#[async_trait]
impl Notifier for NatsNotifier {
    async fn grant_changed(&self, vin: &str, grant: &Grant) -> anyhow::Result<()> {
        self.client.publish(format!("registry.{vin}.grant"), Bytes::from(serde_json::to_vec(grant)?)).await?;
        self.client.flush().await?;
        tracing::info!(vin = %mask(vin), publish = grant.publish.len(), subscribe = grant.subscribe.len(), "grant sent");
        Ok(())
    }
}

pub async fn announces(client: &async_nats::Client) -> anyhow::Result<async_nats::Subscriber> {
    Ok(client.subscribe("registry.*.announce").await?)
}

/// Runs until the subscription ends. With async-nats 0.50, a lost connection does not end
/// it: the client reconnects without limit and resubscribes on its own, so the loop ends
/// only once the client itself is closed.
pub async fn serve_announces(
    client: async_nats::Client,
    mut announces: async_nats::Subscriber,
    registry: Arc<Registry>,
) -> anyhow::Result<()> {
    while let Some(message) = announces.next().await {
        let Some(vin) = vin_from_announce_subject(message.subject.as_str()) else {
            tracing::warn!("an announce on a subject without a valid VIN; ignored");
            continue;
        };
        let offers = match parse_announce(vin, &message.payload) {
            Ok(offers) => offers,
            Err(reason) => {
                tracing::warn!(vin = %mask(vin), reason = %reason, "announce ignored");
                continue;
            }
        };
        let grant = match registry.announce(vin, offers).await {
            Ok(grant) => grant,
            Err(e) => {
                tracing::error!(vin = %mask(vin), error = %e, "announce not answered: the store failed");
                continue;
            }
        };
        tracing::info!(vin = %mask(vin), publish = grant.publish.len(), subscribe = grant.subscribe.len(), "announce answered");
        let Some(reply) = message.reply else {
            continue;
        };
        // The hub constrains only the announce subject, not the reply-to (nats-server
        // 2.14.6 leafnode.go leafMsgAllowed checks the subject alone): a vehicle could name
        // another vehicle's grant subject as its reply-to and have the hub redirect that
        // vehicle's grant there. Only a reply-to in the vehicle's own shape is honoured.
        if !reply.as_str().starts_with(&format!("registry.{vin}.reply.")) {
            tracing::warn!(vin = %mask(vin), "a reply-to outside the vehicle's own shape; dropped");
            continue;
        }
        if let Err(e) = client.publish(reply, Bytes::from(serde_json::to_vec(&grant)?)).await {
            tracing::warn!(vin = %mask(vin), error = %e, "the reply could not be sent");
        }
    }
    anyhow::bail!("the announce subscription ended")
}
