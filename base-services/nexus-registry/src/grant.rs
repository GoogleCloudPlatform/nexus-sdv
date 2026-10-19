//! The offer a vehicle announces, the grant the cloud gives it, and the match between them.

use nexus_aaos_sdk::{Direction, Registration, valid_token, valid_vin};
use serde::{Deserialize, Serialize};

/// One entry of a vehicle's offer, as the `nexus-connectivity-agent` writes it
/// (`aaos/nexus-connectivity-agent/src/offer.rs`). `direction` stays a string: an offer
/// naming a direction value the registry does not recognize simply matches nothing in
/// `compute`, instead of failing the whole announce. A missing `topic` or `pattern` is not
/// the same case: both are required fields of this struct, so an offer missing either fails
/// to deserialize, which fails `parse_announce` for the whole announce, not only that entry.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct Offer {
    pub topic: String,
    pub pattern: String,
    pub direction: String,
    #[serde(rename = "type", default)]
    pub unit_type: String,
}

#[derive(Deserialize)]
struct Announce {
    vin: String,
    offers: Vec<Offer>,
}

/// What a vehicle may publish (`pub`) and receive (`sub`) beyond its control subject.
#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq, Eq)]
pub struct Grant {
    #[serde(rename = "pub", default)]
    pub publish: Vec<String>,
    #[serde(rename = "sub", default)]
    pub subscribe: Vec<String>,
}

/// `registry.<vin>.announce` with a valid VIN, else nothing.
pub fn vin_from_announce_subject(subject: &str) -> Option<&str> {
    let vin = subject.strip_prefix("registry.")?.strip_suffix(".announce")?;
    valid_vin(vin).then_some(vin)
}

/// The subject's VIN is the one the hub let publish there; a body naming another is refused.
pub fn parse_announce(subject_vin: &str, payload: &[u8]) -> Result<Vec<Offer>, String> {
    let announce: Announce =
        serde_json::from_slice(payload).map_err(|_| "the announce is not the expected JSON".to_string())?;
    if announce.vin != subject_vin {
        return Err("the announce names another VIN than its subject".into());
    }
    Ok(announce.offers)
}

/// The grant is the intersection of offer and registrations: topic, pattern and direction
/// equal (spec section 4). Registered topics are valid tokens, so an offer with any other
/// topic can never match. `valid_token` is checked again here, not only trusted from REST's
/// `validate()`: a registration written straight to the store (bypassing REST) must still
/// be unable to turn a registered `>` into a `pubsub.<vin>.>` grant.
pub fn compute(vin: &str, offers: &[Offer], registrations: &[Registration]) -> Grant {
    let mut grant = Grant::default();
    for offer in offers {
        let registered = valid_token(&offer.topic)
            && registrations.iter().any(|r| {
                r.topic == offer.topic && r.pattern == offer.pattern && r.direction.as_str() == offer.direction
            });
        if !registered {
            continue;
        }
        let subject = format!("pubsub.{vin}.{}", offer.topic);
        if offer.direction == Direction::VehicleToCloud.as_str() {
            grant.publish.push(subject);
        } else {
            grant.subscribe.push(subject);
        }
    }
    grant.publish.sort();
    grant.publish.dedup();
    grant.subscribe.sort();
    grant.subscribe.dedup();
    grant
}

#[cfg(test)]
mod tests {
    use super::*;

    const ANNOUNCE: &str = r#"{"vin":"WBA123","offers":[{"topic":"pressure","pattern":"pubsub","direction":"vehicle-to-cloud","type":"com.android.nexus.aaos_nexus_sdv_sample.NexusPressure"},{"topic":"command","pattern":"pubsub","direction":"cloud-to-vehicle","type":"com.android.nexus.aaos_nexus_sdv_sample.NexusCommand"}]}"#;

    fn offer(topic: &str, direction: &str) -> Offer {
        Offer { topic: topic.into(), pattern: "pubsub".into(), direction: direction.into(), unit_type: "t".into() }
    }

    fn registration(topic: &str, direction: Direction) -> Registration {
        Registration { name: format!("{topic}-service"), topic: topic.into(), pattern: "pubsub".into(), direction }
    }

    #[test]
    fn the_vin_comes_from_the_announce_subject() {
        assert_eq!(vin_from_announce_subject("registry.WBA123.announce"), Some("WBA123"));
        assert_eq!(vin_from_announce_subject("registry.wba123.announce"), None);
        assert_eq!(vin_from_announce_subject("registry.WBA.123.announce"), None);
        assert_eq!(vin_from_announce_subject("registry.WBA123.grant"), None);
    }

    #[test]
    fn the_vehicles_announce_parses_into_its_offers() {
        let offers = parse_announce("WBA123", ANNOUNCE.as_bytes()).unwrap();
        assert_eq!(offers.len(), 2);
        assert_eq!(offers[0].topic, "pressure");
        assert_eq!(offers[1].direction, "cloud-to-vehicle");
        assert_eq!(offers[1].unit_type, "com.android.nexus.aaos_nexus_sdv_sample.NexusCommand");
    }

    #[test]
    fn an_announce_naming_another_vin_is_refused() {
        assert!(parse_announce("OTHER1", ANNOUNCE.as_bytes()).is_err());
    }

    #[test]
    fn an_announce_that_is_not_json_is_refused() {
        assert!(parse_announce("WBA123", b"pressure please").is_err());
    }

    #[test]
    fn a_matching_offer_is_granted_in_its_direction() {
        let offers = [offer("pressure", "vehicle-to-cloud"), offer("command", "cloud-to-vehicle")];
        let regs = [registration("pressure", Direction::VehicleToCloud), registration("command", Direction::CloudToVehicle)];
        let g = compute("WBA123", &offers, &regs);
        assert_eq!(g.publish, vec!["pubsub.WBA123.pressure"]);
        assert_eq!(g.subscribe, vec!["pubsub.WBA123.command"]);
    }

    #[test]
    fn the_direction_must_match_too() {
        let g = compute("WBA123", &[offer("command", "vehicle-to-cloud")], &[registration("command", Direction::CloudToVehicle)]);
        assert_eq!(g, Grant::default());
    }

    #[test]
    fn an_offer_without_a_registration_grants_nothing() {
        assert_eq!(compute("WBA123", &[offer("pressure", "vehicle-to-cloud")], &[]), Grant::default());
    }

    #[test]
    fn an_offer_with_a_wildcard_topic_is_never_granted() {
        let offers = [offer(">", "vehicle-to-cloud"), offer("pressure.>", "vehicle-to-cloud"), offer("*", "vehicle-to-cloud")];
        assert_eq!(compute("WBA123", &offers, &[registration("pressure", Direction::VehicleToCloud)]), Grant::default());
    }

    #[test]
    fn a_hand_written_wildcard_registration_still_grants_nothing() {
        // REST `validate()` rejects a ">" topic, but a store write made directly (hand
        // edited, or a future caller that skips `validate()`) is not REST input. Nothing
        // but `compute` stands between such a registration and a wildcard grant.
        let reg = Registration { name: "x".into(), topic: ">".into(), pattern: "pubsub".into(), direction: Direction::VehicleToCloud };
        let offers = [offer(">", "vehicle-to-cloud")];
        assert_eq!(compute("WBA123", &offers, &[reg]), Grant::default());
    }

    #[test]
    fn the_subjects_are_sorted_and_unique() {
        let offers = [offer("tyre", "vehicle-to-cloud"), offer("pressure", "vehicle-to-cloud"), offer("pressure", "vehicle-to-cloud")];
        let regs = [registration("pressure", Direction::VehicleToCloud), registration("tyre", Direction::VehicleToCloud)];
        assert_eq!(compute("WBA123", &offers, &regs).publish, vec!["pubsub.WBA123.pressure", "pubsub.WBA123.tyre"]);
    }

    #[test]
    fn the_grant_is_written_with_the_field_names_the_vehicle_reads() {
        let g = Grant { publish: vec!["pubsub.WBA123.pressure".into()], subscribe: vec![] };
        assert_eq!(serde_json::to_string(&g).unwrap(), r#"{"pub":["pubsub.WBA123.pressure"],"sub":[]}"#);
    }
}
