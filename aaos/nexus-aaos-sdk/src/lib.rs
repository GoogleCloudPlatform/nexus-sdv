//! The cloud side of a Nexus pub/sub channel. A cloud service registers its topic with the
//! Cloud Service Registry at start-up, then publishes or subscribes on
//! `pubsub.<vin>.<topic>`. The wire types live here so the registry validates with exactly
//! the rules its clients use.

pub mod config;
pub mod registry_client;
pub mod service;
pub mod wire;

use std::fmt;

pub use config::Config;
pub use registry_client::{RegistryClient, Renewal};
pub use service::{CloudService, Delivery, delivery_from, encode, subject_for};
pub use wire::{Direction, PATTERN_PUBSUB, Registration, mask, valid_token, valid_vin};

#[derive(Debug)]
pub enum Error {
    /// A name, topic, VIN or setting the rules refuse; nothing was sent.
    Invalid(String),
    /// The registry could not be reached or did not accept the request.
    Registry(String),
    /// The hub could not be reached or refused the operation.
    Nats(String),
    /// A payload is not the message type it was to be read as.
    Decode(String),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Invalid(m) => write!(f, "invalid: {m}"),
            Error::Registry(m) => write!(f, "registry: {m}"),
            Error::Nats(m) => write!(f, "nats: {m}"),
            Error::Decode(m) => write!(f, "decode: {m}"),
        }
    }
}

impl std::error::Error for Error {}
