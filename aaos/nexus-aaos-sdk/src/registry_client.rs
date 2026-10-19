//! The REST client for the Cloud Service Registry.

use std::sync::Arc;
use std::time::Duration;

use reqwest::StatusCode;
use tokio::sync::oneshot;
use tokio::task::JoinHandle;
use tokio::time::{Instant, MissedTickBehavior, interval_at};

use crate::{Direction, Error, PATTERN_PUBSUB, Registration, valid_token};

/// The two REST calls to the Cloud Service Registry. Plain HTTP: the registry is a
/// ClusterIP service inside the cluster.
pub struct RegistryClient {
    http: reqwest::Client,
    base: String,
}

impl RegistryClient {
    pub fn new(base_url: &str) -> Self {
        RegistryClient {
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(10))
                .build()
                .expect("an HTTP client without TLS always builds"),
            base: base_url.trim_end_matches('/').to_string(),
        }
    }

    pub async fn register(&self, name: &str, topic: &str, direction: Direction) -> Result<(), Error> {
        let registration = Registration { name: name.into(), topic: topic.into(), pattern: PATTERN_PUBSUB.into(), direction };
        registration.validate().map_err(Error::Invalid)?;
        let response = self
            .http
            .post(format!("{}/v1/services", self.base))
            .json(&registration)
            .send()
            .await
            .map_err(|e| Error::Registry(e.to_string()))?;
        match response.status() {
            StatusCode::CREATED => Ok(()),
            other => Err(Error::Registry(format!("the registration was answered {other}"))),
        }
    }

    /// Registers once — that error is returned and nothing is kept — then registers again
    /// every `every`, so the registry's lease does not run out (spec section 4, "Lease"). A
    /// failed renewal is logged and tried again on the next tick. It never deregisters: when
    /// the `Renewal` ends, the registration simply expires unless someone deletes it.
    pub async fn keep_registered(
        self: &Arc<Self>,
        name: &str,
        topic: &str,
        direction: Direction,
        every: Duration,
    ) -> Result<Renewal, Error> {
        self.register(name, topic, direction).await?;
        let (stop, mut stopped) = oneshot::channel::<()>();
        let (client, name, topic) = (self.clone(), name.to_string(), topic.to_string());
        let task = tokio::spawn(async move {
            let mut ticks = interval_at(Instant::now() + every, every);
            ticks.set_missed_tick_behavior(MissedTickBehavior::Delay);
            loop {
                // `stop` is looked at only between renewals, so one in flight finishes first.
                tokio::select! {
                    _ = &mut stopped => return,
                    _ = ticks.tick() => {}
                }
                if let Err(e) = client.register(&name, &topic, direction).await {
                    tracing::warn!(service = %name, error = %e, "renewing the registration failed, trying again on the next tick");
                }
            }
        });
        Ok(Renewal { stop: Some(stop), task })
    }

    pub async fn deregister(&self, name: &str) -> Result<(), Error> {
        if !valid_token(name) {
            return Err(Error::Invalid("name must match [a-z0-9-]{1,64}".into()));
        }
        let response = self
            .http
            .delete(format!("{}/v1/services/{name}", self.base))
            .send()
            .await
            .map_err(|e| Error::Registry(e.to_string()))?;
        match response.status() {
            StatusCode::NO_CONTENT | StatusCode::NOT_FOUND => Ok(()),
            other => Err(Error::Registry(format!("the deregistration was answered {other}"))),
        }
    }
}

/// A registration being renewed. `stop()` ends the renewal after any renewal in flight has
/// been answered, so a `DELETE` sent afterwards stays in force; dropping it aborts at once.
/// Use `stop()`, not drop, before a `DELETE`: a dropped renewal's POST may already be in
/// flight and can still reach the registry after the drop returns.
pub struct Renewal {
    stop: Option<oneshot::Sender<()>>,
    task: JoinHandle<()>,
}

impl Renewal {
    pub async fn stop(mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        let _ = (&mut self.task).await;
    }
}

impl Drop for Renewal {
    fn drop(&mut self) {
        self.task.abort();
    }
}
