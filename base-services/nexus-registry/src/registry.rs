//! Registrations in, grants out: on every change the grants are recomputed, the changed
//! ones stored, and each affected vehicle told.

use std::sync::Arc;
use std::time::{Duration, SystemTime};

use async_trait::async_trait;
use nexus_aaos_sdk::{Registration, mask};
use tokio::sync::Mutex;

use crate::grant::{Grant, Offer, compute};
use crate::store::Store;

#[async_trait]
pub trait Notifier: Send + Sync {
    async fn grant_changed(&self, vin: &str, grant: &Grant) -> anyhow::Result<()>;
}

pub struct Registry {
    store: Arc<dyn Store>,
    notifier: Arc<dyn Notifier>,
    /// Serializes every write. The flag is set while a sweep's recompute is owed: a sweep
    /// that deleted expired registrations and then failed to recompute leaves it set, so the
    /// next sweep recomputes although it finds nothing left to expire.
    lock: Mutex<bool>,
}

impl Registry {
    pub fn new(store: Arc<dyn Store>, notifier: Arc<dyn Notifier>) -> Self {
        Registry { store, notifier, lock: Mutex::new(false) }
    }

    pub async fn register(&self, registration: Registration) -> anyhow::Result<()> {
        let _one_at_a_time = self.lock.lock().await;
        self.store.put_registration(&registration).await?;
        self.recompute().await
    }

    /// `false` when no service of that name was registered. Recompute still runs in that
    /// case: an earlier call's `delete_registration` can have already succeeded while its
    /// own recompute then failed (a store error, answered 503), leaving a grant open that a
    /// bare "already gone" 404 on retry would never close.
    pub async fn deregister(&self, name: &str) -> anyhow::Result<bool> {
        let _one_at_a_time = self.lock.lock().await;
        let existed = self.store.delete_registration(name).await?;
        self.recompute().await?;
        Ok(existed)
    }

    /// Drops every registration last written before `now - lease` (spec section 4, "Lease")
    /// and, if any was dropped, recomputes once — the grants close and the vehicles are told,
    /// exactly as on `deregister`. Returns the dropped names.
    ///
    /// `now` is the registry's clock, a registration's time the hub's write time
    /// (`Store::registration_times`). Both run in the same cluster with synchronized clocks;
    /// a lease of minutes dwarfs any skew between them.
    pub async fn expire(&self, now: SystemTime, lease: Duration) -> anyhow::Result<Vec<String>> {
        let mut recompute_owed = self.lock.lock().await;
        let Some(deadline) = now.checked_sub(lease) else { return Ok(Vec::new()) };
        let mut expired = Vec::new();
        for (registration, written) in self.store.registration_times().await? {
            if written < deadline {
                *recompute_owed = true;
                self.store.delete_registration(&registration.name).await?;
                tracing::info!(name = %registration.name, "registration expired: not renewed within the lease");
                expired.push(registration.name);
            }
        }
        if !expired.is_empty() || *recompute_owed {
            *recompute_owed = true;
            self.recompute().await?;
            *recompute_owed = false;
        }
        Ok(expired)
    }

    pub async fn registrations(&self) -> anyhow::Result<Vec<Registration>> {
        self.store.registrations().await
    }

    /// Stores the vehicle's offer and returns its grant, for the reply.
    pub async fn announce(&self, vin: &str, offers: Vec<Offer>) -> anyhow::Result<Grant> {
        let _one_at_a_time = self.lock.lock().await;
        self.store.put_offers(vin, &offers).await?;
        let registrations = self.store.registrations().await?;
        let grant = compute(vin, &offers, &registrations);
        if self.store.grant(vin).await?.unwrap_or_default() != grant {
            self.store.put_grant(vin, &grant).await?;
        }
        Ok(grant)
    }

    async fn recompute(&self) -> anyhow::Result<()> {
        let registrations = self.store.registrations().await?;
        for (vin, offers) in self.store.all_offers().await? {
            let grant = compute(&vin, &offers, &registrations);
            if self.store.grant(&vin).await?.unwrap_or_default() == grant {
                continue;
            }
            self.store.put_grant(&vin, &grant).await?;
            if let Err(e) = self.notifier.grant_changed(&vin, &grant).await {
                tracing::warn!(vin = %mask(&vin), error = %e,
                    "grant stored, notification failed; the vehicle receives it with its next announce");
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::MemoryStore;
    use nexus_aaos_sdk::Direction;

    #[derive(Default)]
    struct Recording {
        sent: std::sync::Mutex<Vec<(String, Grant)>>,
    }
    #[async_trait]
    impl Notifier for Recording {
        async fn grant_changed(&self, vin: &str, grant: &Grant) -> anyhow::Result<()> {
            self.sent.lock().unwrap().push((vin.to_string(), grant.clone()));
            Ok(())
        }
    }

    struct Failing;
    #[async_trait]
    impl Notifier for Failing {
        async fn grant_changed(&self, _: &str, _: &Grant) -> anyhow::Result<()> {
            anyhow::bail!("no NATS")
        }
    }

    const A: &str = "VEHICLEA";
    const B: &str = "VEHICLEB";

    fn setup() -> (Registry, Arc<MemoryStore>, Arc<Recording>) {
        let store = Arc::new(MemoryStore::default());
        let notifier = Arc::new(Recording::default());
        (Registry::new(store.clone(), notifier.clone()), store, notifier)
    }

    fn reg(name: &str, topic: &str, direction: Direction) -> Registration {
        Registration { name: name.into(), topic: topic.into(), pattern: "pubsub".into(), direction }
    }

    fn offer(topic: &str, direction: &str) -> Offer {
        Offer { topic: topic.into(), pattern: "pubsub".into(), direction: direction.into(), unit_type: "t".into() }
    }

    fn pressure_grant(vin: &str) -> Grant {
        Grant { publish: vec![format!("pubsub.{vin}.pressure")], subscribe: vec![] }
    }

    #[tokio::test]
    async fn an_announce_without_registrations_grants_nothing_and_tells_nobody() {
        let (registry, store, notifier) = setup();
        let grant = registry.announce(A, vec![offer("pressure", "vehicle-to-cloud")]).await.unwrap();
        assert_eq!(grant, Grant::default());
        assert_eq!(store.grant(A).await.unwrap(), None, "an empty grant over no grant is no change");
        assert!(notifier.sent.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn a_registration_opens_the_grant_of_each_matching_vehicle_and_only_those() {
        let (registry, store, notifier) = setup();
        registry.announce(A, vec![offer("pressure", "vehicle-to-cloud")]).await.unwrap();
        registry.announce(B, vec![offer("command", "cloud-to-vehicle")]).await.unwrap();
        registry.register(reg("pressure-monitor", "pressure", Direction::VehicleToCloud)).await.unwrap();
        assert_eq!(store.grant(A).await.unwrap(), Some(pressure_grant(A)));
        assert_eq!(store.grant(B).await.unwrap(), None, "a non-matching vehicle's grant is unchanged (A4)");
        assert_eq!(*notifier.sent.lock().unwrap(), vec![(A.to_string(), pressure_grant(A))]);
    }

    #[tokio::test]
    async fn an_announce_after_the_registration_is_answered_with_the_grant() {
        let (registry, store, notifier) = setup();
        registry.register(reg("pressure-monitor", "pressure", Direction::VehicleToCloud)).await.unwrap();
        let grant = registry.announce(A, vec![offer("pressure", "vehicle-to-cloud")]).await.unwrap();
        assert_eq!(grant, pressure_grant(A));
        assert_eq!(store.grant(A).await.unwrap(), Some(pressure_grant(A)));
        assert!(notifier.sent.lock().unwrap().is_empty(), "the reply carries it; no second message");
    }

    #[tokio::test]
    async fn the_same_registration_twice_tells_the_vehicle_once() {
        let (registry, _, notifier) = setup();
        registry.announce(A, vec![offer("pressure", "vehicle-to-cloud")]).await.unwrap();
        let r = reg("pressure-monitor", "pressure", Direction::VehicleToCloud);
        registry.register(r.clone()).await.unwrap();
        registry.register(r).await.unwrap();
        assert_eq!(notifier.sent.lock().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn deregistering_closes_the_grant_and_tells_the_vehicle() {
        let (registry, store, notifier) = setup();
        registry.announce(A, vec![offer("pressure", "vehicle-to-cloud")]).await.unwrap();
        registry.register(reg("pressure-monitor", "pressure", Direction::VehicleToCloud)).await.unwrap();
        assert!(registry.deregister("pressure-monitor").await.unwrap());
        assert_eq!(store.grant(A).await.unwrap(), Some(Grant::default()));
        assert_eq!(notifier.sent.lock().unwrap().last(), Some(&(A.to_string(), Grant::default())));
    }

    #[tokio::test]
    async fn deregistering_an_unknown_name_says_so() {
        let (registry, _, notifier) = setup();
        assert!(!registry.deregister("nobody").await.unwrap());
        assert!(notifier.sent.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn a_topic_stays_granted_while_another_service_still_registers_it() {
        let (registry, store, notifier) = setup();
        registry.announce(A, vec![offer("pressure", "vehicle-to-cloud")]).await.unwrap();
        registry.register(reg("pressure-monitor", "pressure", Direction::VehicleToCloud)).await.unwrap();
        registry.register(reg("pressure-archive", "pressure", Direction::VehicleToCloud)).await.unwrap();
        registry.deregister("pressure-monitor").await.unwrap();
        assert_eq!(store.grant(A).await.unwrap(), Some(pressure_grant(A)));
        assert_eq!(notifier.sent.lock().unwrap().len(), 1, "only the opening was news");
    }

    #[tokio::test]
    async fn a_failed_notification_still_stores_the_grant() {
        let store = Arc::new(MemoryStore::default());
        let registry = Registry::new(store.clone(), Arc::new(Failing));
        registry.announce(A, vec![offer("pressure", "vehicle-to-cloud")]).await.unwrap();
        registry.register(reg("pressure-monitor", "pressure", Direction::VehicleToCloud)).await.unwrap();
        assert_eq!(store.grant(A).await.unwrap(), Some(pressure_grant(A)));
    }

    const LEASE: Duration = Duration::from_secs(900);

    #[tokio::test]
    async fn an_expired_registration_closes_the_grant_and_tells_the_vehicle() {
        let (registry, store, notifier) = setup();
        registry.announce(A, vec![offer("pressure", "vehicle-to-cloud")]).await.unwrap();
        registry.register(reg("pressure-monitor", "pressure", Direction::VehicleToCloud)).await.unwrap();
        let later = SystemTime::now() + LEASE + Duration::from_secs(1);
        assert_eq!(registry.expire(later, LEASE).await.unwrap(), vec!["pressure-monitor".to_string()]);
        assert_eq!(store.grant(A).await.unwrap(), Some(Grant::default()));
        assert!(store.registrations().await.unwrap().is_empty());
        assert_eq!(notifier.sent.lock().unwrap().last(), Some(&(A.to_string(), Grant::default())));
    }

    #[tokio::test]
    async fn a_fresh_registration_survives_the_sweep() {
        let (registry, store, _) = setup();
        registry.announce(A, vec![offer("pressure", "vehicle-to-cloud")]).await.unwrap();
        registry.register(reg("pressure-monitor", "pressure", Direction::VehicleToCloud)).await.unwrap();
        assert!(registry.expire(SystemTime::now(), LEASE).await.unwrap().is_empty());
        assert_eq!(store.grant(A).await.unwrap(), Some(pressure_grant(A)));
    }

    #[tokio::test]
    async fn a_renewal_restarts_the_lease() {
        let (registry, store, _) = setup();
        registry.announce(A, vec![offer("pressure", "vehicle-to-cloud")]).await.unwrap();
        let r = reg("pressure-monitor", "pressure", Direction::VehicleToCloud);
        registry.register(r.clone()).await.unwrap();
        tokio::time::sleep(Duration::from_millis(20)).await;
        let t = SystemTime::now();
        registry.register(r).await.unwrap();
        assert!(registry.expire(t + LEASE, LEASE).await.unwrap().is_empty(), "its last write is after t");
        assert_eq!(store.grant(A).await.unwrap(), Some(pressure_grant(A)));
    }

    #[tokio::test]
    async fn a_sweep_with_nothing_expired_notifies_nobody() {
        let (registry, _, notifier) = setup();
        registry.announce(A, vec![offer("pressure", "vehicle-to-cloud")]).await.unwrap();
        registry.register(reg("pressure-monitor", "pressure", Direction::VehicleToCloud)).await.unwrap();
        let before = notifier.sent.lock().unwrap().len();
        assert!(registry.expire(SystemTime::now(), LEASE).await.unwrap().is_empty());
        assert_eq!(notifier.sent.lock().unwrap().len(), before);
    }

    /// Wraps `MemoryStore` so a test can make one `put_grant` call fail on demand, to
    /// reproduce a recompute that fails after `delete_registration` already succeeded, or
    /// make a chosen `delete_registration` call itself fail after it has already deleted —
    /// a lost reply, the hub applied the delete but the caller sees an error.
    #[derive(Default)]
    struct FlakyStore {
        inner: MemoryStore,
        fail_put_grant: std::sync::atomic::AtomicBool,
        /// The 1-based `delete_registration` call number to fail on; 0 (default) never fails.
        fail_delete_call: std::sync::atomic::AtomicUsize,
        delete_calls: std::sync::atomic::AtomicUsize,
    }

    impl FlakyStore {
        fn arm(&self) {
            self.fail_put_grant.store(true, std::sync::atomic::Ordering::SeqCst);
        }
        fn disarm(&self) {
            self.fail_put_grant.store(false, std::sync::atomic::Ordering::SeqCst);
        }
        fn fail_delete_call(&self, call_number: usize) {
            self.fail_delete_call.store(call_number, std::sync::atomic::Ordering::SeqCst);
        }
    }

    #[async_trait]
    impl Store for FlakyStore {
        async fn put_registration(&self, registration: &Registration) -> anyhow::Result<()> {
            self.inner.put_registration(registration).await
        }
        async fn delete_registration(&self, name: &str) -> anyhow::Result<bool> {
            let call = self.delete_calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
            let result = self.inner.delete_registration(name).await;
            if call == self.fail_delete_call.load(std::sync::atomic::Ordering::SeqCst) {
                anyhow::bail!("store unavailable (test): the delete happened, the reply did not");
            }
            result
        }
        async fn registrations(&self) -> anyhow::Result<Vec<Registration>> {
            self.inner.registrations().await
        }
        async fn registration_times(&self) -> anyhow::Result<Vec<(Registration, SystemTime)>> {
            self.inner.registration_times().await
        }
        async fn put_offers(&self, vin: &str, offers: &[Offer]) -> anyhow::Result<()> {
            self.inner.put_offers(vin, offers).await
        }
        async fn all_offers(&self) -> anyhow::Result<Vec<(String, Vec<Offer>)>> {
            self.inner.all_offers().await
        }
        async fn grant(&self, vin: &str) -> anyhow::Result<Option<Grant>> {
            self.inner.grant(vin).await
        }
        async fn put_grant(&self, vin: &str, grant: &Grant) -> anyhow::Result<()> {
            if self.fail_put_grant.load(std::sync::atomic::Ordering::SeqCst) {
                anyhow::bail!("store unavailable (test)");
            }
            self.inner.put_grant(vin, grant).await
        }
    }

    #[tokio::test]
    async fn a_retry_after_a_failed_recompute_still_closes_the_grant_it_left_open() {
        let store = Arc::new(FlakyStore::default());
        let notifier = Arc::new(Recording::default());
        let registry = Registry::new(store.clone(), notifier.clone());

        registry.announce(A, vec![offer("pressure", "vehicle-to-cloud")]).await.unwrap();
        registry.register(reg("pressure-monitor", "pressure", Direction::VehicleToCloud)).await.unwrap();
        assert_eq!(store.grant(A).await.unwrap(), Some(pressure_grant(A)));

        store.arm();
        assert!(registry.deregister("pressure-monitor").await.is_err(), "the store error must reach the caller");
        assert_eq!(
            store.grant(A).await.unwrap(),
            Some(pressure_grant(A)),
            "the failed write leaves the prior grant in place"
        );

        store.disarm();
        assert!(
            !registry.deregister("pressure-monitor").await.unwrap(),
            "the registration is already gone; the answer stays 404-shaped"
        );
        assert_eq!(
            store.grant(A).await.unwrap(),
            Some(Grant::default()),
            "the retry must still close the grant the first attempt left open"
        );
        assert_eq!(notifier.sent.lock().unwrap().last(), Some(&(A.to_string(), Grant::default())));
    }

    #[tokio::test]
    async fn a_sweep_after_a_failed_recompute_still_closes_the_grant_it_left_open() {
        let store = Arc::new(FlakyStore::default());
        let notifier = Arc::new(Recording::default());
        let registry = Registry::new(store.clone(), notifier.clone());

        registry.announce(A, vec![offer("pressure", "vehicle-to-cloud")]).await.unwrap();
        registry.register(reg("pressure-monitor", "pressure", Direction::VehicleToCloud)).await.unwrap();
        let later = SystemTime::now() + LEASE + Duration::from_secs(1);

        store.arm();
        assert!(registry.expire(later, LEASE).await.is_err(), "the store error must reach the caller");
        assert_eq!(store.grant(A).await.unwrap(), Some(pressure_grant(A)), "the failed write leaves the grant open");

        store.disarm();
        assert!(registry.expire(later, LEASE).await.unwrap().is_empty(), "the registration is already gone");
        assert_eq!(
            store.grant(A).await.unwrap(),
            Some(Grant::default()),
            "the next sweep must still close the grant the failed one left open"
        );
        assert_eq!(notifier.sent.lock().unwrap().last(), Some(&(A.to_string(), Grant::default())));
    }

    #[tokio::test]
    async fn a_sweep_after_a_lost_delete_reply_still_closes_the_grant_it_left_open() {
        let store = Arc::new(FlakyStore::default());
        let notifier = Arc::new(Recording::default());
        let registry = Registry::new(store.clone(), notifier.clone());

        registry.announce(A, vec![offer("pressure", "vehicle-to-cloud")]).await.unwrap();
        registry.register(reg("pressure-archive", "pressure", Direction::VehicleToCloud)).await.unwrap();
        registry.register(reg("pressure-monitor", "pressure", Direction::VehicleToCloud)).await.unwrap();
        let later = SystemTime::now() + LEASE + Duration::from_secs(1);

        // The second delete_registration call in the sweep deletes, then reports an error:
        // the hub applied it, the reply did not arrive.
        store.fail_delete_call(2);
        assert!(registry.expire(later, LEASE).await.is_err(), "the lost reply must reach the caller");
        assert!(store.registrations().await.unwrap().is_empty(), "both deletes took effect despite the lost reply");
        assert_eq!(store.grant(A).await.unwrap(), Some(pressure_grant(A)), "the failed sweep leaves the grant open");

        store.fail_delete_call(0);
        assert!(registry.expire(later, LEASE).await.unwrap().is_empty(), "both registrations are already gone");
        assert_eq!(
            store.grant(A).await.unwrap(),
            Some(Grant::default()),
            "the next sweep must still close the grant the lost reply left open"
        );
        assert_eq!(notifier.sent.lock().unwrap().last(), Some(&(A.to_string(), Grant::default())));
    }
}
