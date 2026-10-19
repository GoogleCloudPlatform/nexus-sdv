//! Where the registry keeps what it knows: the services registered with it, the offer each
//! vehicle announced, and the grant computed for each vehicle — three JetStream key-value
//! buckets in the account NEXUS. The grants bucket is the one the auth-callout reads.

use std::collections::BTreeMap;
use std::sync::Mutex;
use std::time::{Duration, SystemTime};

use async_nats::jetstream::{self, kv, stream::StorageType};
use async_trait::async_trait;
use bytes::Bytes;
use futures::{StreamExt, TryStreamExt};
use nexus_aaos_sdk::Registration;
use serde::{Serialize, de::DeserializeOwned};

use crate::grant::{Grant, Offer};

pub const SERVICES: &str = "nexus-registry-services";
pub const OFFERS: &str = "nexus-registry-offers";
pub const GRANTS: &str = "nexus-registry-grants";

/// Bounds `latest_entries`: a listing either completes or fails, it never hangs.
const LISTING_TIMEOUT: Duration = Duration::from_secs(10);

/// How many of `latest_entries`'s per-key `get`s run at once — each key's current value
/// needs its own round trip (see `latest_entries`), so this keeps a bucket with many keys
/// from paying for them one at a time.
const GET_CONCURRENCY: usize = 32;

#[async_trait]
pub trait Store: Send + Sync {
    async fn put_registration(&self, registration: &Registration) -> anyhow::Result<()>;
    /// `false` when no registration of that name exists.
    async fn delete_registration(&self, name: &str) -> anyhow::Result<bool>;
    /// Sorted by name.
    async fn registrations(&self) -> anyhow::Result<Vec<Registration>>;
    /// Every registration with the time it was last written — the start of its current
    /// lease (spec section 4, "Lease"). Kept with the registration, so it survives a restart.
    async fn registration_times(&self) -> anyhow::Result<Vec<(Registration, SystemTime)>>;
    async fn put_offers(&self, vin: &str, offers: &[Offer]) -> anyhow::Result<()>;
    /// Every VIN that has announced, with its latest offer, sorted by VIN.
    async fn all_offers(&self) -> anyhow::Result<Vec<(String, Vec<Offer>)>>;
    async fn grant(&self, vin: &str) -> anyhow::Result<Option<Grant>>;
    async fn put_grant(&self, vin: &str, grant: &Grant) -> anyhow::Result<()>;
}

/// For tests: the same contract, in memory.
#[derive(Default)]
pub struct MemoryStore {
    inner: Mutex<Memory>,
}

#[derive(Default)]
struct Memory {
    services: BTreeMap<String, (Registration, SystemTime)>,
    offers: BTreeMap<String, Vec<Offer>>,
    grants: BTreeMap<String, Grant>,
}

#[async_trait]
impl Store for MemoryStore {
    async fn put_registration(&self, registration: &Registration) -> anyhow::Result<()> {
        self.inner
            .lock()
            .unwrap()
            .services
            .insert(registration.name.clone(), (registration.clone(), SystemTime::now()));
        Ok(())
    }
    async fn delete_registration(&self, name: &str) -> anyhow::Result<bool> {
        Ok(self.inner.lock().unwrap().services.remove(name).is_some())
    }
    async fn registrations(&self) -> anyhow::Result<Vec<Registration>> {
        Ok(self.inner.lock().unwrap().services.values().map(|(r, _)| r.clone()).collect())
    }
    async fn registration_times(&self) -> anyhow::Result<Vec<(Registration, SystemTime)>> {
        Ok(self.inner.lock().unwrap().services.values().cloned().collect())
    }
    async fn put_offers(&self, vin: &str, offers: &[Offer]) -> anyhow::Result<()> {
        self.inner.lock().unwrap().offers.insert(vin.to_string(), offers.to_vec());
        Ok(())
    }
    async fn all_offers(&self) -> anyhow::Result<Vec<(String, Vec<Offer>)>> {
        Ok(self.inner.lock().unwrap().offers.iter().map(|(v, o)| (v.clone(), o.clone())).collect())
    }
    async fn grant(&self, vin: &str) -> anyhow::Result<Option<Grant>> {
        Ok(self.inner.lock().unwrap().grants.get(vin).cloned())
    }
    async fn put_grant(&self, vin: &str, grant: &Grant) -> anyhow::Result<()> {
        self.inner.lock().unwrap().grants.insert(vin.to_string(), grant.clone());
        Ok(())
    }
}

pub struct JetStreamStore {
    services: kv::Store,
    offers: kv::Store,
    grants: kv::Store,
}

impl JetStreamStore {
    /// Opens the three buckets, creating any that does not exist yet, so a new environment
    /// needs no hand step (alignment note, "What changed", item 2).
    pub async fn open(js: &jetstream::Context) -> anyhow::Result<Self> {
        Ok(JetStreamStore {
            services: bucket(js, SERVICES).await?,
            offers: bucket(js, OFFERS).await?,
            grants: bucket(js, GRANTS).await?,
        })
    }
}

/// History 10 is the audit log the spec names; file storage survives a hub restart.
async fn bucket(js: &jetstream::Context, name: &str) -> anyhow::Result<kv::Store> {
    if let Ok(store) = js.get_key_value(name).await {
        return Ok(store);
    }
    Ok(js
        .create_key_value(kv::Config {
            bucket: name.to_string(),
            history: 10,
            storage: StorageType::File,
            ..Default::default()
        })
        .await?)
}

/// Every live key's latest value, complete even while another writer is active.
///
/// Round 1 (`keys()`/`history()`'s `num_pending`, captured once at consumer creation and
/// never rechecked) and round 2 (adding `entry.delta == 0`, `info.pending` reparsed fresh
/// per message) both replayed `watch_with_history`/`DeliverPolicy::LastPerSubject`, a push
/// consumer. Round 2's fix looked right from the client source but was wrong empirically:
/// traced against nexus-test-nats with `NEXUS_DEBUG_LATEST_ENTRIES=1` (temporary, removed),
/// `delta` counted down from a *fixed* total (1425, 1424, 1423, ... to 0) at exactly one per
/// delivered message, regardless of how the stream sequence jumped between them — i.e. it is
/// the remaining count of a backlog sized once at consumer creation, not a live distance to
/// the stream's current tail. A key repeatedly overwritten while still queued in that
/// backlog can have its slot silently dropped: the countdown still reaches exactly 0, but
/// that key is never delivered at all (confirmed: `existing-70642982-3-3` absent from the
/// entire replay of a call that still ended with `caught_up=true`). Reproduced:
/// `tests/store_contract.rs::a_listing_is_complete_while_a_pre_existing_key_is_overwritten`,
/// 197 of 200 listings incomplete before this fix, still 1 of 20 after round 2's `delta`
/// correction alone.
///
/// Fix, round 3: stop using any push consumer for listing. List key names with
/// `Stream::info_with_subjects` (`stream.rs:227-245`) — a plain, paginated `STREAM.INFO`
/// management request computed fresh by the server at request time, not a consumer with a
/// backlog of its own — then fetch each name's current value with `kv::Store::get`. For an
/// `allow_direct` bucket (the default `create_key_value` sets, `context.rs:1657`) `get`
/// resolves through `entry`/`entry_maybe_revision` to `Stream::direct_get_last_for_subject`
/// (`kv/mod.rs:402-417`), a single direct read of that one subject's current message, the
/// same call every `put`/`get`/`delete` in this file already relies on and which never
/// showed a staleness issue anywhere in this investigation. `get` itself already treats a
/// `Delete`/`Purge` entry as absent (`kv/mod.rs:903-911`), so a deleted key is dropped
/// without extra filtering here. Each name needs its own `get` round trip, so those run
/// `GET_CONCURRENCY` at a time rather than one after another. `LISTING_TIMEOUT` still bounds
/// the whole thing, so a stalled listing errors out rather than hang or return a partial
/// list.
///
/// Since the lease (spec section 4, "Lease"), each name is read with `kv::Store::entry`
/// (`kv/mod.rs:517`) rather than `get`: the same direct read, which `get` merely unwraps
/// (`kv/mod.rs:903-911`), but it keeps the entry's `created` time — the hub's write time,
/// i.e. the last renewal. A non-`Put` entry is dropped exactly as `get` drops it.
async fn latest_entries(bucket: &kv::Store) -> anyhow::Result<Vec<kv::Entry>> {
    let filter = format!("{}>", bucket.prefix);
    let list = async {
        let mut names = Vec::new();
        let mut pages = bucket.stream.info_with_subjects(filter).await?;
        while let Some((subject, _message_count)) = pages.try_next().await? {
            if let Some(key) = subject.strip_prefix(bucket.prefix.as_str()) {
                names.push(key.to_string());
            }
        }

        let fetched: Vec<Option<kv::Entry>> = futures::stream::iter(names)
            .map(|name| async move {
                let entry = bucket.entry(name).await?;
                Ok::<_, anyhow::Error>(entry.filter(|entry| entry.operation == kv::Operation::Put))
            })
            .buffer_unordered(GET_CONCURRENCY)
            .try_collect()
            .await?;

        Ok::<_, anyhow::Error>(fetched.into_iter().flatten().collect())
    };

    tokio::time::timeout(LISTING_TIMEOUT, list).await.map_err(|_| anyhow::anyhow!("{}: listing timed out", bucket.name))?
}

async fn list_json<T: DeserializeOwned>(bucket: &kv::Store) -> anyhow::Result<Vec<(String, T)>> {
    latest_entries(bucket)
        .await?
        .into_iter()
        .map(|entry| Ok((entry.key, serde_json::from_slice(&entry.value)?)))
        .collect()
}

async fn get_json<T: DeserializeOwned>(bucket: &kv::Store, key: &str) -> anyhow::Result<Option<T>> {
    match bucket.get(key).await? {
        Some(bytes) => Ok(Some(serde_json::from_slice(&bytes)?)),
        None => Ok(None),
    }
}

async fn put_json<T: Serialize + ?Sized>(bucket: &kv::Store, key: &str, value: &T) -> anyhow::Result<()> {
    bucket.put(key, Bytes::from(serde_json::to_vec(value)?)).await?;
    Ok(())
}

#[async_trait]
impl Store for JetStreamStore {
    async fn put_registration(&self, registration: &Registration) -> anyhow::Result<()> {
        put_json(&self.services, &registration.name, registration).await
    }
    async fn delete_registration(&self, name: &str) -> anyhow::Result<bool> {
        if self.services.get(name).await?.is_none() {
            return Ok(false);
        }
        self.services.delete(name).await?;
        Ok(true)
    }
    async fn registrations(&self) -> anyhow::Result<Vec<Registration>> {
        let mut out: Vec<Registration> =
            list_json(&self.services).await?.into_iter().map(|(_, registration)| registration).collect();
        out.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(out)
    }
    async fn registration_times(&self) -> anyhow::Result<Vec<(Registration, SystemTime)>> {
        latest_entries(&self.services)
            .await?
            .into_iter()
            .map(|entry| Ok((serde_json::from_slice(&entry.value)?, SystemTime::from(entry.created))))
            .collect()
    }
    async fn put_offers(&self, vin: &str, offers: &[Offer]) -> anyhow::Result<()> {
        put_json(&self.offers, vin, offers).await
    }
    async fn all_offers(&self) -> anyhow::Result<Vec<(String, Vec<Offer>)>> {
        let mut out = list_json::<Vec<Offer>>(&self.offers).await?;
        out.sort_by(|a, b| a.0.cmp(&b.0));
        Ok(out)
    }
    async fn grant(&self, vin: &str) -> anyhow::Result<Option<Grant>> {
        get_json(&self.grants, vin).await
    }
    async fn put_grant(&self, vin: &str, grant: &Grant) -> anyhow::Result<()> {
        put_json(&self.grants, vin, grant).await
    }
}
