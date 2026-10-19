//! The library's REST half against the registry's own router — not a stand-in.

use std::sync::Arc;
use std::time::{Duration, SystemTime};

use bytes::Bytes;
use nexus_aaos_sdk::{CloudService, Config, Direction, Error, RegistryClient};
use nexus_registry::api::router;
use nexus_registry::grant::Grant;
use nexus_registry::registry::{Notifier, Registry};
use nexus_registry::store::{MemoryStore, Store};

struct Silent;
#[async_trait::async_trait]
impl Notifier for Silent {
    async fn grant_changed(&self, _: &str, _: &Grant) -> anyhow::Result<()> {
        Ok(())
    }
}

async fn serve() -> (String, Arc<Registry>) {
    let (url, registry, _) = serve_with_store().await;
    (url, registry)
}

async fn serve_with_store() -> (String, Arc<Registry>, Arc<MemoryStore>) {
    let store = Arc::new(MemoryStore::default());
    let registry = Arc::new(Registry::new(store.clone(), Arc::new(Silent)));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let app = router(registry.clone());
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    (format!("http://{address}"), registry, store)
}

#[tokio::test]
async fn the_library_registers_and_deregisters() {
    let (url, registry) = serve().await;
    let client = RegistryClient::new(&url);
    client.register("pressure-monitor", "pressure", Direction::VehicleToCloud).await.unwrap();
    let names: Vec<String> = registry.registrations().await.unwrap().into_iter().map(|r| r.name).collect();
    assert_eq!(names, vec!["pressure-monitor"]);
    client.deregister("pressure-monitor").await.unwrap();
    assert!(registry.registrations().await.unwrap().is_empty());
    client.deregister("pressure-monitor").await.expect("a second deregistration is not an error");
}

#[tokio::test]
async fn an_invalid_topic_is_refused_before_anything_is_sent() {
    let (url, registry) = serve().await;
    let result = RegistryClient::new(&url).register("pressure-monitor", "Pressure", Direction::VehicleToCloud).await;
    assert!(matches!(result, Err(Error::Invalid(_))));
    assert!(registry.registrations().await.unwrap().is_empty());
}

#[tokio::test]
async fn a_registry_that_is_not_there_is_a_registry_error() {
    let result = RegistryClient::new("http://127.0.0.1:9").register("pressure-monitor", "pressure", Direction::VehicleToCloud).await;
    assert!(matches!(result, Err(Error::Registry(_))));
}

const EVERY: Duration = Duration::from_millis(100);
const LONG_ENOUGH_FOR_THREE_TICKS: Duration = Duration::from_millis(350);

#[tokio::test]
async fn a_kept_registration_is_renewed() {
    let (url, _, store) = serve_with_store().await;
    let client = Arc::new(RegistryClient::new(&url));
    let _renewal = client.keep_registered("example-service", "example", Direction::VehicleToCloud, EVERY).await.unwrap();
    let after_first_write = SystemTime::now();
    tokio::time::sleep(LONG_ENOUGH_FOR_THREE_TICKS).await;
    let times = store.registration_times().await.unwrap();
    assert_eq!(times.len(), 1);
    assert!(times[0].1 > after_first_write, "the registration was not written again");
}

#[tokio::test]
async fn stopping_the_renewal_before_the_delete_keeps_it_deleted() {
    let (url, registry) = serve().await;
    let client = Arc::new(RegistryClient::new(&url));
    let renewal = client.keep_registered("example-service", "example", Direction::VehicleToCloud, EVERY).await.unwrap();
    renewal.stop().await;
    client.deregister("example-service").await.unwrap();
    tokio::time::sleep(LONG_ENOUGH_FOR_THREE_TICKS).await;
    assert!(registry.registrations().await.unwrap().is_empty());
}

#[tokio::test]
async fn dropping_the_renewal_stops_it() {
    let (url, registry) = serve().await;
    let client = Arc::new(RegistryClient::new(&url));
    let renewal = client.keep_registered("example-service", "example", Direction::VehicleToCloud, EVERY).await.unwrap();
    drop(renewal);
    client.deregister("example-service").await.unwrap();
    tokio::time::sleep(LONG_ENOUGH_FOR_THREE_TICKS).await;
    assert!(registry.registrations().await.unwrap().is_empty());
}

#[tokio::test]
async fn a_first_registration_that_fails_is_returned_and_nothing_is_kept() {
    let client = Arc::new(RegistryClient::new("http://127.0.0.1:9"));
    let result = client.keep_registered("example-service", "example", Direction::VehicleToCloud, EVERY).await;
    assert!(matches!(result, Err(Error::Registry(_))));
}

#[tokio::test]
#[ignore = "needs a NATS server: NEXUS_TEST_NATS_URL"]
async fn a_cloud_service_renews_until_it_deregisters_on_purpose() {
    let (url, registry, store) = serve_with_store().await;
    let config = Config {
        registry_url: url,
        nats_url: std::env::var("NEXUS_TEST_NATS_URL").expect("set NEXUS_TEST_NATS_URL"),
        nats_user: "test".into(),
        nats_password: "test".into(),
        renew_every: EVERY,
    };
    let service = CloudService::connect(config).await.unwrap();
    service.register("example-service", "example", Direction::CloudToVehicle).await.unwrap();
    let after_first_write = SystemTime::now();
    tokio::time::sleep(LONG_ENOUGH_FOR_THREE_TICKS).await;
    assert!(store.registration_times().await.unwrap()[0].1 > after_first_write, "not renewed");
    service.deregister("example-service").await.unwrap();
    tokio::time::sleep(LONG_ENOUGH_FOR_THREE_TICKS).await;
    assert!(registry.registrations().await.unwrap().is_empty(), "a renewal brought it back");
}

const SLOW_WRITE: Duration = Duration::from_millis(300);
const OLD_RENEWAL_EVERY: Duration = Duration::from_millis(20);

/// A fake registry that answers any registration for `old-topic` only after `SLOW_WRITE`
/// and everything else at once — deliberately not the real router, so nothing here is
/// serialized by the registry's own write lock (spec section 4; `Registry::expire`'s
/// `Mutex<bool>`, `src/registry.rs`). That isolates what this test is about:
/// `CloudService::register`'s own ordering, not the server's.
async fn fake_registry_slow_on_old_topic() -> String {
    async fn handle(body: Bytes) -> axum::http::StatusCode {
        let topic = serde_json::from_slice::<serde_json::Value>(&body)
            .ok()
            .and_then(|v| v.get("topic").and_then(|t| t.as_str().map(str::to_string)));
        if topic.as_deref() == Some("old-topic") {
            tokio::time::sleep(SLOW_WRITE).await;
        }
        axum::http::StatusCode::CREATED
    }
    let app = axum::Router::new().route("/v1/services", axum::routing::post(handle));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    format!("http://{address}")
}

#[tokio::test]
#[ignore = "needs a NATS server: NEXUS_TEST_NATS_URL"]
async fn reregistering_waits_for_the_old_renewals_write_in_flight_before_starting_the_new_one() {
    let config = Config {
        registry_url: fake_registry_slow_on_old_topic().await,
        nats_url: std::env::var("NEXUS_TEST_NATS_URL").expect("set NEXUS_TEST_NATS_URL"),
        nats_user: "test".into(),
        nats_password: "test".into(),
        renew_every: OLD_RENEWAL_EVERY,
    };
    let service = CloudService::connect(config).await.unwrap();

    // The first write for "old-topic" is slow; the renewal's own timer starts once it
    // returns, so its first tick — another slow "old-topic" write — fires OLD_RENEWAL_EVERY
    // later.
    service.register("example-service", "old-topic", Direction::VehicleToCloud).await.unwrap();
    // Catch that renewal's write just after it started, deep inside SLOW_WRITE.
    tokio::time::sleep(OLD_RENEWAL_EVERY + Duration::from_millis(5)).await;

    let before = SystemTime::now();
    // "new-topic" itself is answered at once; any wait here can only be the old renewal's
    // write still in flight.
    service.register("example-service", "new-topic", Direction::VehicleToCloud).await.unwrap();
    let elapsed = before.elapsed().unwrap();
    assert!(
        elapsed >= Duration::from_millis(150),
        "re-registering must wait for the old renewal's write in flight before starting the new one, took {elapsed:?}"
    );
}
