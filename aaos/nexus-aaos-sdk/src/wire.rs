//! What travels between a cloud service, the registry and the vehicle, and the rules every
//! party checks before a name becomes part of a subject.

use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum Direction {
    VehicleToCloud,
    CloudToVehicle,
}

impl Direction {
    pub fn as_str(self) -> &'static str {
        match self {
            Direction::VehicleToCloud => "vehicle-to-cloud",
            Direction::CloudToVehicle => "cloud-to-vehicle",
        }
    }
}

pub const PATTERN_PUBSUB: &str = "pubsub";

/// `[a-z0-9-]{1,64}`: the intersection of the AAOS topic rule and a NATS subject token
/// (spec section 4), so a registered name can always become both.
pub fn valid_token(s: &str) -> bool {
    (1..=64).contains(&s.len()) && s.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

/// `[A-Z0-9]{1,17}`, the rule the callout applies (Plan A, Global Constraints).
pub fn valid_vin(s: &str) -> bool {
    (1..=17).contains(&s.len()) && s.bytes().all(|b| b.is_ascii_uppercase() || b.is_ascii_digit())
}

/// A cloud service's registration: one topic, one direction. Unknown fields are refused,
/// so nothing that looks like a scope (a VIN, say) is silently ignored.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Registration {
    pub name: String,
    pub topic: String,
    pub pattern: String,
    pub direction: Direction,
}

impl Registration {
    /// The messages are fixed text: nothing from the request is echoed back.
    pub fn validate(&self) -> Result<(), String> {
        if !valid_token(&self.name) {
            return Err("name must match [a-z0-9-]{1,64}".into());
        }
        if !valid_token(&self.topic) {
            return Err("topic must match [a-z0-9-]{1,64}".into());
        }
        if self.pattern != PATTERN_PUBSUB {
            return Err("pattern must be pubsub".into());
        }
        Ok(())
    }
}

/// An id as it may be logged: only its last four characters, as `nexus-pubsub-consumer`
/// does (`src/config.rs`, `LogDetail::id`), so two lines about one vehicle still match by eye.
pub fn mask(id: &str) -> String {
    let n = id.chars().count();
    if n <= 4 {
        "****".to_string()
    } else {
        format!("***{}", id.chars().skip(n - 4).collect::<String>())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_direction_is_written_in_the_registry_words() {
        assert_eq!(serde_json::to_string(&Direction::VehicleToCloud).unwrap(), r#""vehicle-to-cloud""#);
        assert_eq!(serde_json::to_string(&Direction::CloudToVehicle).unwrap(), r#""cloud-to-vehicle""#);
        assert_eq!(Direction::CloudToVehicle.as_str(), "cloud-to-vehicle");
    }

    #[test]
    fn a_token_is_lower_case_letters_digits_and_dashes_up_to_64() {
        for ok in ["pressure", "a", "other-service", "x1", "a".repeat(64).as_str()] {
            assert!(valid_token(ok), "{ok} is a valid token");
        }
        for bad in ["", "Pressure", "a.b", "a b", "*", ">", "pressure.>", "tür", "a".repeat(65).as_str()] {
            assert!(!valid_token(bad), "{bad} is not a valid token");
        }
    }

    #[test]
    fn a_vin_is_upper_case_letters_and_digits_up_to_17() {
        for ok in ["PKG11MESH01", "A", "A".repeat(17).as_str()] {
            assert!(valid_vin(ok), "{ok} is a valid VIN");
        }
        for bad in ["", "pkg11mesh01", "PKG.1", "PKG*", ">", "A".repeat(18).as_str()] {
            assert!(!valid_vin(bad), "{bad} is not a valid VIN");
        }
    }

    fn registration(name: &str, topic: &str, pattern: &str) -> Registration {
        Registration { name: name.into(), topic: topic.into(), pattern: pattern.into(), direction: Direction::VehicleToCloud }
    }

    #[test]
    fn a_registration_is_valid_only_with_token_names_and_the_pubsub_pattern() {
        assert!(registration("example-service", "pressure", "pubsub").validate().is_ok());
        assert!(registration("Pressure", "pressure", "pubsub").validate().is_err());
        assert!(registration("example-service", "pressure.>", "pubsub").validate().is_err());
        assert!(registration("example-service", "pressure", "rpc").validate().is_err());
    }

    #[test]
    fn a_registration_with_an_unknown_field_does_not_parse() {
        let body = r#"{"name":"a","topic":"b","pattern":"pubsub","direction":"vehicle-to-cloud","vin":"WBA123"}"#;
        assert!(serde_json::from_str::<Registration>(body).is_err());
    }

    #[test]
    fn a_masked_id_keeps_only_its_last_four_characters() {
        assert_eq!(mask("PKG11MESH01"), "***SH01");
        assert_eq!(mask("ABCD"), "****");
    }
}
