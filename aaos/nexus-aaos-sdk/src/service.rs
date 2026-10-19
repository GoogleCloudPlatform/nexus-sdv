//! `CloudService`: register with the registry, then publish or subscribe on `pubsub.<vin>.<topic>`.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use bytes::Bytes;
use futures::StreamExt;

use crate::registry_client::{RegistryClient, Renewal};
use crate::{Config, Direction, Error, valid_token, valid_vin};

/// One message from a vehicle on a subscribed topic.
#[derive(Debug, Clone)]
pub struct Delivery {
    pub vin: String,
    pub topic: String,
    pub payload: Bytes,
}

impl Delivery {
    /// The payload as a message type generated from the catalog's `.proto`. A payload that is
    /// not that message is an error — never a message of default values.
    pub fn decode<M: prost::Message + Default>(&self) -> Result<M, Error> {
        M::decode(self.payload.clone()).map_err(|e| Error::Decode(e.to_string()))
    }
}

/// A message as the bytes that travel on `pubsub.<vin>.<topic>`.
pub fn encode<M: prost::Message>(message: &M) -> Bytes {
    Bytes::from(message.encode_to_vec())
}

pub fn subject_for(vin: &str, topic: &str) -> Result<String, Error> {
    if !valid_vin(vin) {
        return Err(Error::Invalid("vin must match [A-Z0-9]{1,17}".into()));
    }
    if !valid_token(topic) {
        return Err(Error::Invalid("topic must match [a-z0-9-]{1,64}".into()));
    }
    Ok(format!("pubsub.{vin}.{topic}"))
}

/// `pubsub.<vin>.<topic>` with a valid VIN and topic, else nothing.
pub fn delivery_from(subject: &str, payload: Bytes) -> Option<Delivery> {
    let mut parts = subject.split('.');
    let (prefix, vin, topic) = (parts.next()?, parts.next()?, parts.next()?);
    if prefix != "pubsub" || parts.next().is_some() || !valid_vin(vin) || !valid_token(topic) {
        return None;
    }
    Some(Delivery { vin: vin.to_string(), topic: topic.to_string(), payload })
}

pub struct CloudService {
    registry: Arc<RegistryClient>,
    nats: async_nats::Client,
    renew_every: Duration,
    /// One renewal per registered name; it ends when the service ends.
    renewals: Mutex<HashMap<String, Renewal>>,
}

impl CloudService {
    pub async fn connect(config: Config) -> Result<Self, Error> {
        let nats = async_nats::ConnectOptions::with_user_and_password(config.nats_user, config.nats_password)
            .connect(config.nats_url.as_str())
            .await
            .map_err(|e| Error::Nats(e.to_string()))?;
        Ok(CloudService {
            registry: Arc::new(RegistryClient::new(&config.registry_url)),
            nats,
            renew_every: config.renew_every,
            renewals: Mutex::new(HashMap::new()),
        })
    }

    /// Registers `name` and renews it every `Config::renew_every` while this service lives.
    /// Stopping the service does not deregister: the registration expires with its lease.
    /// Registering a name that already has a renewal stops the old one first — same order
    /// as `deregister` — so its write cannot still be in flight when the new one starts.
    pub async fn register(&self, name: &str, topic: &str, direction: Direction) -> Result<(), Error> {
        let old = self.renewals.lock().unwrap().remove(name);
        if let Some(old) = old {
            old.stop().await;
        }
        let renewal = self.registry.keep_registered(name, topic, direction, self.renew_every).await?;
        self.renewals.lock().unwrap().insert(name.to_string(), renewal);
        Ok(())
    }

    /// Deregisters on purpose. The renewal stops first — otherwise its next tick would bring
    /// the registration back.
    pub async fn deregister(&self, name: &str) -> Result<(), Error> {
        let renewal = self.renewals.lock().unwrap().remove(name);
        if let Some(renewal) = renewal {
            renewal.stop().await;
        }
        self.registry.deregister(name).await
    }

    /// Calls `handler` for every message any vehicle sends on `topic`, until the
    /// subscription ends.
    pub async fn subscribe<F: FnMut(Delivery)>(&self, topic: &str, mut handler: F) -> Result<(), Error> {
        if !valid_token(topic) {
            return Err(Error::Invalid("topic must match [a-z0-9-]{1,64}".into()));
        }
        let mut subscription = self
            .nats
            .subscribe(format!("pubsub.*.{topic}"))
            .await
            .map_err(|e| Error::Nats(e.to_string()))?;
        while let Some(message) = subscription.next().await {
            if let Some(delivery) = delivery_from(message.subject.as_str(), message.payload) {
                handler(delivery);
            }
        }
        Err(Error::Nats("the subscription ended".into()))
    }

    /// Sends a message of a type generated from the catalog's `.proto` to one vehicle.
    pub async fn publish_message<M: prost::Message>(&self, vin: &str, topic: &str, message: &M) -> Result<(), Error> {
        self.publish(vin, topic, encode(message)).await
    }

    pub async fn publish(&self, vin: &str, topic: &str, payload: Bytes) -> Result<(), Error> {
        let subject = subject_for(vin, topic)?;
        self.nats.publish(subject, payload).await.map_err(|e| Error::Nats(e.to_string()))?;
        self.nats.flush().await.map_err(|e| Error::Nats(e.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_subject_is_built_only_from_a_valid_vin_and_topic() {
        assert_eq!(subject_for("WBA123", "command").unwrap(), "pubsub.WBA123.command");
        for (vin, topic) in [("wba123", "command"), ("WBA.123", "command"), (">", "command"), ("WBA123", ">"), ("WBA123", "a.b"), ("", "command")] {
            assert!(matches!(subject_for(vin, topic), Err(Error::Invalid(_))), "{vin} {topic}");
        }
    }

    #[test]
    fn a_delivery_names_the_vin_and_topic_of_its_subject() {
        let d = delivery_from("pubsub.PKG11MESH01.pressure", Bytes::from_static(b"x")).unwrap();
        assert_eq!((d.vin.as_str(), d.topic.as_str(), &d.payload[..]), ("PKG11MESH01", "pressure", &b"x"[..]));
    }

    // A stand-in for a generated type: one varint field, as DoorCommand or PressureLimit have.
    #[derive(Clone, PartialEq, prost::Message)]
    struct Limit {
        #[prost(uint32, tag = "1")]
        max: u32,
    }

    #[test]
    fn a_delivery_decodes_into_the_message_type_asked_for() {
        let d = delivery_from("pubsub.PKG11MESH01.pressure", Bytes::from_static(&[0x08, 0xfa, 0x01])).unwrap();
        assert_eq!(d.decode::<Limit>().unwrap(), Limit { max: 250 });
    }

    #[test]
    fn a_payload_that_is_not_the_message_is_an_error_not_a_default() {
        let d = delivery_from("pubsub.PKG11MESH01.pressure", Bytes::from_static(&[0x08])).unwrap();
        assert!(matches!(d.decode::<Limit>(), Err(Error::Decode(_))));
    }

    #[test]
    fn a_message_is_encoded_as_the_vehicle_expects_it() {
        assert_eq!(&encode(&Limit { max: 250 })[..], &[0x08, 0xfa, 0x01]);
    }

    #[test]
    fn a_subject_outside_the_pattern_is_no_delivery() {
        for s in ["telemetry.PKG11MESH01.pressure", "pubsub.pkg.pressure", "pubsub.PKG11MESH01", "pubsub.PKG11MESH01.pressure.extra"] {
            assert!(delivery_from(s, Bytes::new()).is_none(), "{s}");
        }
    }
}
