use crate::error::AppError;
use crate::vin::{build_cn, vin_from_cn};
use zeroize::Zeroizing;

pub struct GeneratedIdentity {
    pub csr_pem: String,
    pub private_key_pem: Zeroizing<String>,
}

pub fn validate_provided_csr(
    pem: &str,
    expected_vin: Option<&str>,
) -> Result<(String, String), AppError> {
    let params = rcgen::CertificateSigningRequestParams::from_pem(pem)
        .map_err(|e| AppError::BadRequest(format!("csr is not a valid PEM certificate request: {e}")))?;
    let cn = params
        .params
        .distinguished_name
        .get(&rcgen::DnType::CommonName)
        .and_then(|v| match v {
            rcgen::DnValue::PrintableString(s) => Some(s.as_str().to_string()),
            rcgen::DnValue::Utf8String(s) => Some(s.clone()),
            _ => None,
        })
        .ok_or_else(|| AppError::BadRequest("csr subject has no CommonName".into()))?;
    let csr_vin = vin_from_cn(&cn).ok_or_else(|| {
        AppError::BadRequest(format!("csr CN '{cn}' does not match 'VIN:<vin> DEVICE:<type>'"))
    })?;
    if let Some(expected) = expected_vin {
        if expected != csr_vin {
            return Err(AppError::BadRequest(format!(
                "vin '{expected}' does not match csr CN vin '{csr_vin}'"
            )));
        }
    }
    Ok((pem.to_string(), csr_vin))
}

pub fn generate_csr(vin: &str, device_type: &str, org: &str) -> Result<GeneratedIdentity, AppError> {
    let mut params = rcgen::CertificateParams::default();
    params
        .distinguished_name
        .push(rcgen::DnType::CommonName, build_cn(vin, device_type));
    params
        .distinguished_name
        .push(rcgen::DnType::OrganizationName, org);
    // rcgen generates ECDSA P-256 keys (it cannot generate RSA); Go's crypto/tls,
    // the registration server (rustls), and GCP CAS all accept EC client certs.
    let key = rcgen::KeyPair::generate()
        .map_err(|_| AppError::BadRequest("key generation failed".into()))?;
    let csr = params
        .serialize_request(&key)
        .map_err(|_| AppError::BadRequest("csr serialization failed".into()))?;
    Ok(GeneratedIdentity {
        csr_pem: csr
            .pem()
            .map_err(|_| AppError::BadRequest("csr pem encoding failed".into()))?,
        private_key_pem: Zeroizing::new(key.serialize_pem()),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn make_csr(cn: &str) -> String {
        let mut params = rcgen::CertificateParams::default();
        params.distinguished_name.push(rcgen::DnType::CommonName, cn);
        let key = rcgen::KeyPair::generate().unwrap();
        params.serialize_request(&key).unwrap().pem().unwrap()
    }
    #[test]
    fn accepts_matching_csr() {
        let pem = make_csr("VIN:CLDLEAF01 DEVICE:car");
        let (_, vin) = validate_provided_csr(&pem, Some("CLDLEAF01")).unwrap();
        assert_eq!(vin, "CLDLEAF01");
    }
    #[test]
    fn accepts_csr_without_expected_vin_and_extracts_it() {
        let pem = make_csr("VIN:ABC123 DEVICE:tcu");
        let (_, vin) = validate_provided_csr(&pem, None).unwrap();
        assert_eq!(vin, "ABC123");
    }
    #[test]
    fn rejects_vin_mismatch_and_bad_cn_and_garbage() {
        let pem = make_csr("VIN:OTHER DEVICE:car");
        assert!(validate_provided_csr(&pem, Some("CLDLEAF01")).is_err()); // mismatch
        assert!(validate_provided_csr(&make_csr("just-a-name"), None).is_err()); // CN not in convention
        assert!(validate_provided_csr("not a pem", None).is_err()); // unparseable
    }
    #[test]
    fn generates_identity_with_matching_cn() {
        let id = generate_csr("CLDLEAF01", "car", "Nexus SDV").unwrap();
        assert!(id.private_key_pem.contains("PRIVATE KEY"));
        let (_, vin) = validate_provided_csr(&id.csr_pem, Some("CLDLEAF01")).unwrap();
        assert_eq!(vin, "CLDLEAF01");
    }
}
