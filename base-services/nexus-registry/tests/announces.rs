//! The announce loop against a real NATS server — run as in tests/store_contract.rs. One
//! test, in order: every loop subscribes `registry.*.announce`, so two loops in parallel
//! would answer each other's announces.

use std::sync::Arc;
use std::time::Duration;

use bytes::Bytes;
use futures::StreamExt;
use nexus_aaos_sdk::{Direction, Registration};
use nexus_registry::grant::Grant;
use nexus_registry::nats::{NatsNotifier, announces, serve_announces};
use nexus_registry::registry::Registry;
use nexus_registry::store::MemoryStore;

fn announce(vin: &str) -> Bytes {
    Bytes::from(format!(
        r#"{{"vin":"{vin}","offers":[{{"topic":"pressure","pattern":"pubsub","direction":"vehicle-to-cloud","type":"t"}}]}}"#
    ))
}

/// Announces the way the vehicle does — its own reply subject — and waits briefly.
async fn ask(client: &async_nats::Client, subject_vin: &str, payload: Bytes) -> Option<Grant> {
    let reply = format!("registry.{subject_vin}.reply.1");
    let mut replies = client.subscribe(reply.clone()).await.unwrap();
    client.publish_with_reply(format!("registry.{subject_vin}.announce"), reply, payload).await.unwrap();
    client.flush().await.unwrap();
    match tokio::time::timeout(Duration::from_secs(2), replies.next()).await {
        Ok(Some(message)) => Some(serde_json::from_slice(&message.payload).unwrap()),
        _ => None,
    }
}

#[tokio::test]
#[ignore = "needs a NATS server: NEXUS_TEST_NATS_URL"]
async fn the_announce_loop_answers_stores_and_notifies() {
    let url = std::env::var("NEXUS_TEST_NATS_URL").expect("set NEXUS_TEST_NATS_URL");
    let client = async_nats::connect(url.as_str()).await.unwrap();
    let registry = Arc::new(Registry::new(Arc::new(MemoryStore::default()), Arc::new(NatsNotifier::new(client.clone()))));
    let subscription = announces(&client).await.unwrap();
    client.flush().await.unwrap();
    tokio::spawn(serve_announces(client.clone(), subscription, registry.clone()));

    let empty = ask(&client, "LOOPA", announce("LOOPA")).await;
    assert_eq!(empty, Some(Grant::default()), "nothing registered: the reply is the empty grant");

    let mut grants = client.subscribe("registry.LOOPA.grant").await.unwrap();
    client.flush().await.unwrap();
    registry
        .register(Registration { name: "pressure-monitor".into(), topic: "pressure".into(), pattern: "pubsub".into(), direction: Direction::VehicleToCloud })
        .await
        .unwrap();
    let told = tokio::time::timeout(Duration::from_secs(2), grants.next()).await.expect("a grant notification").unwrap();
    let told: Grant = serde_json::from_slice(&told.payload).unwrap();
    assert_eq!(told.publish, vec!["pubsub.LOOPA.pressure"]);

    let answered = ask(&client, "LOOPA", announce("LOOPA")).await.expect("a reply");
    assert_eq!(answered.publish, vec!["pubsub.LOOPA.pressure"]);

    assert_eq!(ask(&client, "LOOPA", announce("LOOPB")).await, None, "a body naming another VIN is not answered");
    assert_eq!(ask(&client, "LOOPA", Bytes::from_static(b"not json")).await, None, "a body that is not JSON is not answered");
    assert_eq!(ask(&client, "loopa", announce("loopa")).await, None, "a subject without a valid VIN is not answered");

    // A reply-to outside LOOPA's own shape (registry.LOOPA.reply.*) must not be honoured,
    // even though the subject's VIN (whose announce the hub let through) is valid: it must
    // not let LOOPA redirect the grant onto another vehicle's subject.
    let mut foreign = client.subscribe("registry.LOOPB.grant").await.unwrap();
    client.flush().await.unwrap();
    client
        .publish_with_reply("registry.LOOPA.announce".to_string(), "registry.LOOPB.grant".to_string(), announce("LOOPA"))
        .await
        .unwrap();
    client.flush().await.unwrap();
    let received = tokio::time::timeout(Duration::from_secs(2), foreign.next()).await;
    assert!(received.is_err(), "a reply-to outside the vehicle's own shape must receive nothing");
}
