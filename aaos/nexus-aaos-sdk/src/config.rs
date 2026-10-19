//! Where the registry and the hub are, read from the environment.

use std::fmt;
use std::time::Duration;

use crate::Error;

pub const DEFAULT_REGISTRY_URL: &str = "http://nexus-registry.base-services.svc.cluster.local:8080";
pub const DEFAULT_NATS_URL: &str = "nats://nats.base-services.svc.cluster.local:4222";
/// How often a registration is renewed, well inside the registry's lease (spec section 4, "Lease").
pub const DEFAULT_RENEW_SECONDS: u64 = 300;
/// The highest accepted `REGISTRY_RENEW_SECONDS`: short of the registry's default lease of
/// 900 seconds (`LEASE_SECONDS`, `base-services/nexus-registry/src/main.rs`), and short
/// enough that `Instant::now() + every` cannot overflow.
pub const MAX_RENEW_SECONDS: u64 = 600;

/// Where the registry and the hub are, and who the service is on the hub. It connects as
/// `connector` — what cloud consumers use today; per-consumer identities are release 1.3
/// (spec, "Out of scope").
#[derive(Clone)]
pub struct Config {
    pub registry_url: String,
    pub nats_url: String,
    pub nats_user: String,
    pub nats_password: String,
    /// How often the service registers again, so its lease does not run out.
    pub renew_every: Duration,
}

impl Config {
    pub fn from_env() -> Result<Config, Error> {
        Self::from_lookup(|k| std::env::var(k).ok())
    }

    pub fn from_lookup(get: impl Fn(&str) -> Option<String>) -> Result<Config, Error> {
        Ok(Config {
            registry_url: get("REGISTRY_URL").unwrap_or_else(|| DEFAULT_REGISTRY_URL.to_string()),
            nats_url: get("NATS_URL").unwrap_or_else(|| DEFAULT_NATS_URL.to_string()),
            nats_user: get("NATS_USER").unwrap_or_else(|| "connector".to_string()),
            nats_password: get("NATS_PASSWORD")
                .filter(|p| !p.is_empty())
                .ok_or_else(|| Error::Invalid("NATS_PASSWORD is required".into()))?,
            renew_every: match get("REGISTRY_RENEW_SECONDS") {
                None => Duration::from_secs(DEFAULT_RENEW_SECONDS),
                Some(v) => match v.parse::<u64>() {
                    Ok(seconds) if seconds > 0 && seconds <= MAX_RENEW_SECONDS => Duration::from_secs(seconds),
                    Ok(seconds) if seconds > MAX_RENEW_SECONDS => {
                        return Err(Error::Invalid(format!(
                            "REGISTRY_RENEW_SECONDS must be at most {MAX_RENEW_SECONDS} seconds, inside the registry's default lease of 900 seconds"
                        )));
                    }
                    _ => return Err(Error::Invalid("REGISTRY_RENEW_SECONDS must be a whole number of seconds above 0".into())),
                },
            },
        })
    }
}

impl fmt::Debug for Config {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Config")
            .field("registry_url", &self.registry_url)
            .field("nats_url", &self.nats_url)
            .field("nats_user", &self.nats_user)
            .field("nats_password", &"<hidden>")
            .field("renew_every", &self.renew_every)
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn lookup(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
        let map: HashMap<String, String> = pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
        move |k| map.get(k).cloned()
    }

    #[test]
    fn only_the_password_must_be_given() {
        let c = Config::from_lookup(lookup(&[("NATS_PASSWORD", "s3cret")])).unwrap();
        assert_eq!(c.registry_url, "http://nexus-registry.base-services.svc.cluster.local:8080");
        assert_eq!(c.nats_url, "nats://nats.base-services.svc.cluster.local:4222");
        assert_eq!(c.nats_user, "connector");
    }

    #[test]
    fn a_missing_or_empty_password_is_an_error() {
        assert!(matches!(Config::from_lookup(lookup(&[])), Err(Error::Invalid(_))));
        assert!(matches!(Config::from_lookup(lookup(&[("NATS_PASSWORD", "")])), Err(Error::Invalid(_))));
    }

    #[test]
    fn a_registration_is_renewed_every_300_seconds_by_default() {
        let c = Config::from_lookup(lookup(&[("NATS_PASSWORD", "s3cret")])).unwrap();
        assert_eq!(c.renew_every, Duration::from_secs(300));
    }

    #[test]
    fn the_renewal_period_comes_from_registry_renew_seconds() {
        let c = Config::from_lookup(lookup(&[("NATS_PASSWORD", "s3cret"), ("REGISTRY_RENEW_SECONDS", "2")])).unwrap();
        assert_eq!(c.renew_every, Duration::from_secs(2));
        assert!(format!("{c:?}").contains("renew_every"));
    }

    #[test]
    fn a_renewal_period_of_zero_or_not_a_number_is_an_error() {
        for value in ["0", "abc", "", "-1"] {
            let result = Config::from_lookup(lookup(&[("NATS_PASSWORD", "s3cret"), ("REGISTRY_RENEW_SECONDS", value)]));
            assert!(matches!(result, Err(Error::Invalid(_))), "{value:?}");
        }
    }

    #[test]
    fn a_renewal_period_above_600_seconds_is_an_error() {
        for value in ["601", "900", "1000"] {
            let result = Config::from_lookup(lookup(&[("NATS_PASSWORD", "s3cret"), ("REGISTRY_RENEW_SECONDS", value)]));
            assert!(matches!(result, Err(Error::Invalid(_))), "{value:?}");
        }
        let c = Config::from_lookup(lookup(&[("NATS_PASSWORD", "s3cret"), ("REGISTRY_RENEW_SECONDS", "600")])).unwrap();
        assert_eq!(c.renew_every, Duration::from_secs(600), "600 is still inside the registry's default lease");
    }

    #[test]
    fn the_debug_output_never_shows_the_password() {
        let c = Config::from_lookup(lookup(&[("NATS_PASSWORD", "s3cret")])).unwrap();
        assert!(!format!("{c:?}").contains("s3cret"));
    }
}
