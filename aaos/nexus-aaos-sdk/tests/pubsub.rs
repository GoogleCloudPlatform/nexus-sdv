//! Publish and subscribe against a real NATS server:
//! `docker run -d --rm --name nexus-test-nats -p 4222:4222 nats:2.14.6 -js`, then
//! `NEXUS_TEST_NATS_URL=nats://127.0.0.1:4222 cargo test -- --include-ignored`.

use std::sync::Arc;
use std::time::Duration;

use bytes::Bytes;
use nexus_aaos_sdk::{CloudService, Config};

#[tokio::test]
#[ignore = "needs a NATS server: NEXUS_TEST_NATS_URL"]
async fn what_is_published_for_a_vehicle_arrives_with_its_vin_and_topic() {
    let config = Config {
        registry_url: "http://127.0.0.1:9".into(),
        nats_url: std::env::var("NEXUS_TEST_NATS_URL").expect("set NEXUS_TEST_NATS_URL"),
        nats_user: "test".into(),
        nats_password: "test".into(),
        renew_every: Duration::from_secs(300),
    };
    let service = Arc::new(CloudService::connect(config).await.unwrap());
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    let subscriber = service.clone();
    tokio::spawn(async move {
        let _ = subscriber.subscribe("lib-test", move |d| {
            let _ = tx.send(d);
        }).await;
    });
    // Publish until the subscription is in place; the first publishes may precede it.
    let delivery = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            service.publish("LIBTEST1", "lib-test", Bytes::from_static(b"hi")).await.unwrap();
            if let Ok(Some(d)) = tokio::time::timeout(Duration::from_millis(200), rx.recv()).await {
                return d;
            }
        }
    })
    .await
    .expect("a delivery within 5 s");
    assert_eq!(delivery.vin, "LIBTEST1");
    assert_eq!(delivery.topic, "lib-test");
    assert_eq!(&delivery.payload[..], b"hi");
}
