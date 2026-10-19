//! The vehicle's offer to the registry: what its Bridge declares it can carry, in the
//! registry's words. Derived from the one policy file, never written by hand.

use crate::authz_policy::Policy;
use serde::Serialize;

#[derive(Serialize, Debug, Clone, PartialEq, Eq)]
pub struct Offer {
    pub topic: String,
    pub pattern: &'static str,
    pub direction: &'static str,
    #[serde(rename = "type")]
    pub unit_type: String,
}

#[derive(Serialize)]
struct Announce<'a> {
    vin: &'a str,
    offers: &'a [Offer],
}

/// One offer per named topic. An entry with `allow_all_topics` and no topic names nothing
/// the registry could match, so it contributes nothing; the Bridge's own subscriptions
/// come from the same rule (`lib.rs`).
pub fn from_policy(policy: &Policy) -> Vec<Offer> {
    let mut offers = Vec::new();
    for e in &policy.subscribers {
        for t in &e.topics {
            offers.push(Offer {
                topic: t.clone(),
                pattern: "pubsub",
                direction: "vehicle-to-cloud",
                unit_type: e.message.clone(),
            });
        }
    }
    for e in &policy.publishers {
        for t in &e.topics {
            offers.push(Offer {
                topic: t.clone(),
                pattern: "pubsub",
                direction: "cloud-to-vehicle",
                unit_type: e.message.clone(),
            });
        }
    }
    offers
}

/// Read all: one offer per publication the Bridge found at its start (its `discovered`
/// list), each from the vehicle to the cloud.
pub fn from_discovered(list: &[(String, String)]) -> Vec<Offer> {
    list.iter()
        .map(|(unit_type, topic)| Offer {
            topic: topic.clone(),
            pattern: "pubsub",
            direction: "vehicle-to-cloud",
            unit_type: unit_type.clone(),
        })
        .collect()
}

pub fn announce_json(vin: &str, offers: &[Offer]) -> String {
    serde_json::to_string(&Announce { vin, offers }).expect("an offer always serializes")
}

#[cfg(test)]
mod tests {
    #[test]
    fn a_discovered_publication_is_offered_to_the_cloud() {
        let o = from_discovered(&[("g.Tire".to_string(), "pressure2".to_string())]);
        assert_eq!(o.len(), 1);
        assert_eq!(
            (o[0].topic.as_str(), o[0].direction, o[0].unit_type.as_str()),
            ("pressure2", "vehicle-to-cloud", "g.Tire")
        );
    }

    use super::*;
    use crate::authz_policy;

    const POLICY: &str = r#"
subscriber { message: "com.android.nexus.aaos_nexus_sdv_sample.NexusPressure" topic: "pressure" }
publisher { message: "com.android.nexus.aaos_nexus_sdv_sample.NexusCommand" topic: "command" }
"#;

    #[test]
    fn a_subscriber_entry_is_offered_vehicle_to_cloud_and_a_publisher_cloud_to_vehicle() {
        let offers = from_policy(&authz_policy::parse(POLICY).unwrap());
        assert_eq!(offers.len(), 2);
        assert_eq!(offers[0].topic, "pressure");
        assert_eq!(offers[0].direction, "vehicle-to-cloud");
        assert_eq!(offers[1].topic, "command");
        assert_eq!(offers[1].direction, "cloud-to-vehicle");
        assert!(offers.iter().all(|o| o.pattern == "pubsub"));
        assert_eq!(offers[1].unit_type, "com.android.nexus.aaos_nexus_sdv_sample.NexusCommand");
    }

    #[test]
    fn an_entry_that_names_no_topic_offers_nothing() {
        let p = authz_policy::parse(r#"subscriber { message: "a.B" allow_all_topics: true }"#).unwrap();
        assert!(from_policy(&p).is_empty());
    }

    #[test]
    fn the_announce_is_json_with_the_registry_field_names() {
        let offers = from_policy(&authz_policy::parse(POLICY).unwrap());
        let json = announce_json("WBA123", &offers);
        assert!(json.starts_with(r#"{"vin":"WBA123","offers":["#));
        assert!(json.contains(r#""topic":"pressure","pattern":"pubsub","direction":"vehicle-to-cloud","type":"#));
    }
}
