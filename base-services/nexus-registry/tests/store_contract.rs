//! What every store must do, run against the memory store always and against JetStream when
//! a server is given: `docker run -d --rm --name nexus-test-nats -p 4222:4222 nats:2.14.6 -js`,
//! then `NEXUS_TEST_NATS_URL=nats://127.0.0.1:4222 cargo test -- --include-ignored`.

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use nexus_aaos_sdk::{Direction, Registration};
use nexus_registry::grant::{Grant, Offer};
use nexus_registry::store::{JetStreamStore, MemoryStore, Store};

fn registration(name: &str) -> Registration {
    Registration { name: name.into(), topic: "pressure".into(), pattern: "pubsub".into(), direction: Direction::VehicleToCloud }
}

fn offer() -> Offer {
    Offer { topic: "pressure".into(), pattern: "pubsub".into(), direction: "vehicle-to-cloud".into(), unit_type: "t".into() }
}

/// Keeps names apart on a server that outlives the run, and across tests running
/// concurrently: the millisecond timestamp alone can repeat under concurrent execution, so a
/// process-wide counter is appended.
fn tag() -> String {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let millis = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() % 100_000_000;
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{millis}-{n}")
}

async fn contract(store: &dyn Store) {
    let tag = tag();
    let name = format!("svc-{tag}");
    let vin = format!("VIN{tag}");

    store.put_registration(&registration(&name)).await.unwrap();
    assert!(store.registrations().await.unwrap().iter().any(|r| r.name == name));
    let written = store
        .registration_times()
        .await
        .unwrap()
        .into_iter()
        .find(|(r, _)| r.name == name)
        .map(|(_, at)| at)
        .expect("registration_times lists the registration");
    let now = SystemTime::now();
    let apart = match now.duration_since(written) {
        Ok(apart) => apart,
        Err(e) => e.duration(),
    };
    assert!(apart < Duration::from_secs(60), "the write time is within 60 s of now, was {apart:?} apart");
    assert!(store.delete_registration(&name).await.unwrap());
    assert!(!store.delete_registration(&name).await.unwrap(), "a second delete says the name is gone");
    assert!(!store.registrations().await.unwrap().iter().any(|r| r.name == name));

    assert_eq!(store.grant(&vin).await.unwrap(), None, "an unknown VIN has no grant");
    store.put_offers(&vin, &[offer()]).await.unwrap();
    let all = store.all_offers().await.unwrap();
    assert_eq!(all.iter().find(|(v, _)| *v == vin).map(|(_, o)| o.clone()), Some(vec![offer()]));

    let grant = Grant { publish: vec![format!("pubsub.{vin}.pressure")], subscribe: vec![] };
    store.put_grant(&vin, &grant).await.unwrap();
    assert_eq!(store.grant(&vin).await.unwrap(), Some(grant));
}

async fn jetstream() -> async_nats::jetstream::Context {
    let url = std::env::var("NEXUS_TEST_NATS_URL")
        .expect("set NEXUS_TEST_NATS_URL to a JetStream server, e.g. nats://127.0.0.1:4222");
    async_nats::jetstream::new(async_nats::connect(url.as_str()).await.unwrap())
}

// No lock around the four tests below: they share the SERVICES/OFFERS/GRANTS buckets (the
// production names, not per-test ones) and run fully concurrently on purpose — `latest_entries`
// (store.rs) is exactly what the two `a_listing_is_complete_while_*` tests below hold it to.

#[tokio::test]
async fn the_memory_store_keeps_the_contract() {
    contract(&MemoryStore::default()).await;
}

#[tokio::test]
#[ignore = "needs a JetStream server: NEXUS_TEST_NATS_URL"]
async fn the_jetstream_store_keeps_the_contract() {
    let js = jetstream().await;
    contract(&JetStreamStore::open(&js).await.unwrap()).await;
}

#[tokio::test]
#[ignore = "needs a JetStream server: NEXUS_TEST_NATS_URL"]
async fn a_registration_survives_reopening_the_buckets() {
    let js = jetstream().await;
    let first = JetStreamStore::open(&js).await.unwrap();
    let name = format!("svc-{}", tag());
    first.put_registration(&registration(&name)).await.unwrap();
    let second = JetStreamStore::open(&js).await.expect("opening finds the existing buckets");
    assert!(second.registrations().await.unwrap().iter().any(|r| r.name == name), "registrations survive a restart");
    second.delete_registration(&name).await.unwrap();
}

/// Reviewer's experiment (task-3 review, finding 1): one task puts a key, awaits the ack,
/// then lists; a second task, on its own connection, concurrently puts/deletes 50 other
/// keys in the same bucket. A listing based on `keys()`'s creation-time `num_pending` can
/// miss the caller's own just-acknowledged key. 200 iterations is enough to show it
/// (reviewer measured ~11% of 1500 misses; 0 of 300 with no concurrent writer). Needs a
/// multi-thread runtime and a second connection — the race is between two independent
/// clients, not two tasks interleaved on one.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "needs a JetStream server: NEXUS_TEST_NATS_URL"]
async fn a_listing_is_complete_while_another_writer_is_active() {
    let store = JetStreamStore::open(&jetstream().await).await.unwrap();

    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let noise = {
        let stop = stop.clone();
        tokio::spawn(async move {
            let noise_store = JetStreamStore::open(&jetstream().await).await.unwrap();
            let mut i: u64 = 0;
            while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                let name = format!("noise-{}", i % 50);
                noise_store.put_registration(&registration(&name)).await.unwrap();
                noise_store.delete_registration(&name).await.unwrap();
                i += 1;
            }
        })
    };

    let iterations = 200;
    let mut misses = 0;
    for _ in 0..iterations {
        let name = format!("mine-{}", tag());
        store.put_registration(&registration(&name)).await.unwrap();
        let seen = store.registrations().await.unwrap().iter().any(|r| r.name == name);
        store.delete_registration(&name).await.unwrap();
        if !seen {
            misses += 1;
        }
    }

    stop.store(true, std::sync::atomic::Ordering::Relaxed);
    noise.await.unwrap();

    assert_eq!(misses, 0, "{misses} of {iterations} listings missed the caller's own just-written key while another writer was active");
}

/// Reviewer's second experiment (fix round 2, finding 1 still open after round 1): a
/// last-per-subject replay sends only each key's *current* latest message, in stream order.
/// If a writer overwrites a key that already existed before the listing's snapshot, that
/// key's entry moves to a later position in the replay (its new, higher revision) — so
/// stopping at the first entry whose revision reaches the snapshot's `last_seq` can trigger
/// on a freshly-overwritten key and skip other pre-existing keys the replay hasn't reached
/// yet. Unlike the test above (a new key appearing), this never deletes anything: a fixed
/// set of keys is written before the loop starts, and the only concurrent activity is
/// re-puts (overwrites) of those same keys — the normal production pattern (`all_offers`
/// while vehicles re-announce, `registrations` while a service re-registers).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "needs a JetStream server: NEXUS_TEST_NATS_URL"]
async fn a_listing_is_complete_while_a_pre_existing_key_is_overwritten() {
    let store = JetStreamStore::open(&jetstream().await).await.unwrap();

    let pre_existing: Vec<String> = (0..20).map(|i| format!("existing-{}-{i}", tag())).collect();
    for name in &pre_existing {
        store.put_registration(&registration(name)).await.unwrap();
    }

    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let noise = {
        let stop = stop.clone();
        let keys = pre_existing.clone();
        tokio::spawn(async move {
            let noise_store = JetStreamStore::open(&jetstream().await).await.unwrap();
            let mut i = 0usize;
            while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                noise_store.put_registration(&registration(&keys[i % keys.len()])).await.unwrap();
                i += 1;
            }
        })
    };

    let iterations = 200;
    let mut incomplete = 0;
    for _ in 0..iterations {
        let seen: Vec<String> = store.registrations().await.unwrap().into_iter().map(|r| r.name).collect();
        if pre_existing.iter().any(|name| !seen.contains(name)) {
            incomplete += 1;
        }
    }

    stop.store(true, std::sync::atomic::Ordering::Relaxed);
    noise.await.unwrap();
    for name in &pre_existing {
        store.delete_registration(name).await.unwrap();
    }

    assert_eq!(incomplete, 0, "{incomplete} of {iterations} listings were missing at least one pre-existing key while it was being overwritten");
}
