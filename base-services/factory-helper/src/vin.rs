use crate::error::AppError;
use rand::Rng;

const VIN_ALPHABET: &[u8] = b"ABCDEFGHJKLMNPRSTUVWXYZ0123456789"; // no I, O, Q

fn valid_vin(v: &str) -> bool {
    !v.is_empty() && v.len() <= 32 && v.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

pub fn resolve_vin(vin: Option<&str>, vin_prefix: Option<&str>) -> Result<String, AppError> {
    if let Some(v) = vin {
        return valid_vin(v)
            .then(|| v.to_string())
            .ok_or_else(|| AppError::BadRequest("vin must be 1-32 chars of [A-Za-z0-9-]".into()));
    }
    if let Some(p) = vin_prefix {
        if p.is_empty() || p.len() > 17 || !p.chars().all(|c| c.is_ascii_alphanumeric()) {
            return Err(AppError::BadRequest(
                "vin_prefix must be 1-17 alphanumeric chars".into(),
            ));
        }
        let mut rng = rand::thread_rng();
        let tail: String = (0..17 - p.len())
            .map(|_| VIN_ALPHABET[rng.gen_range(0..VIN_ALPHABET.len())] as char)
            .collect();
        return Ok(format!("{}{}", p.to_ascii_uppercase(), tail));
    }
    Ok(uuid::Uuid::new_v4().simple().to_string()[..12].to_string())
}

pub fn build_cn(vin: &str, device_type: &str) -> String {
    format!("VIN:{vin} DEVICE:{device_type}")
}

pub fn vin_from_cn(cn: &str) -> Option<String> {
    let rest = cn.strip_prefix("VIN:")?;
    let (vin, dev) = rest.split_once(" DEVICE:")?;
    (!vin.is_empty() && !dev.is_empty()).then(|| vin.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn provided_vin_is_validated_and_used() {
        assert_eq!(resolve_vin(Some("CLDLEAF01"), None).unwrap(), "CLDLEAF01");
        assert!(resolve_vin(Some("bad vin!"), None).is_err()); // rejected: space + '!'
        assert!(resolve_vin(Some(""), None).is_err()); // rejected: empty
        assert!(resolve_vin(Some(&"X".repeat(33)), None).is_err()); // rejected: >32
    }
    #[test]
    fn prefix_yields_17_chars_starting_with_prefix() {
        let v = resolve_vin(None, Some("VLT")).unwrap();
        assert_eq!(v.len(), 17);
        assert!(v.starts_with("VLT"));
        assert!(v
            .chars()
            .all(|c| c.is_ascii_uppercase() && c != 'I' && c != 'O' && c != 'Q'
                || c.is_ascii_digit()));
        assert!(resolve_vin(None, Some(&"P".repeat(18))).is_err()); // rejected: prefix too long
        assert!(resolve_vin(None, Some("bad!")).is_err()); // rejected: invalid chars
    }
    #[test]
    fn default_is_short_uuid_id() {
        let v = resolve_vin(None, None).unwrap();
        assert_eq!(v.len(), 12);
        assert!(v.chars().all(|c| c.is_ascii_hexdigit()));
    }
    #[test]
    fn cn_roundtrip() {
        let cn = build_cn("CLDLEAF01", "car");
        assert_eq!(cn, "VIN:CLDLEAF01 DEVICE:car");
        assert_eq!(vin_from_cn(&cn).unwrap(), "CLDLEAF01");
        assert!(vin_from_cn("CN=nonsense").is_none());
    }
}
