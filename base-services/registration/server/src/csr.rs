use anyhow::Context;
use rcgen::{
    Certificate, CertificateParams, CertificateSigningRequestParams, ExtendedKeyUsagePurpose, IsCa,
    Issuer, KeyUsagePurpose, SigningKey,
};
use time::{Duration, OffsetDateTime};

pub fn read_csr(pem: &str) -> anyhow::Result<CertificateSigningRequestParams> {
    let csr = CertificateSigningRequestParams::from_pem(pem).context("Reading CSR pem file")?;
    Ok(csr)
}

pub fn sign_csr<S: SigningKey>(
    csr_params: CertificateSigningRequestParams,
    issuer: &Issuer<'_, S>,
) -> anyhow::Result<Certificate> {
    let issued = csr_params.signed_by(issuer).context("Signing the CSR")?;

    Ok(issued)
}

/// Default lifetime of an issued operational certificate.
///
/// It must stay well below the lifetime of the factory certificate a vehicle
/// re-registers with, otherwise renewal is impossible: the credential needed to
/// obtain a new operational certificate would expire first.
pub const DEFAULT_VALIDITY: Duration = Duration::days(90);

/// Parse a validity given as `<number><unit>`, e.g. `90d`, `12h`, `5m`, `30s`.
///
/// Deliberately strict: a malformed value is an error rather than a silent
/// fallback. A certificate lifetime that quietly becomes something else is
/// worse than a service that refuses to start.
pub fn parse_validity(spec: &str) -> anyhow::Result<Duration> {
    let spec = spec.trim();
    let (digits, unit) = spec.split_at(
        spec.find(|c: char| !c.is_ascii_digit())
            .with_context(|| format!("validity '{spec}' has no unit, expected e.g. 90d"))?,
    );

    let value: i64 = digits
        .parse()
        .with_context(|| format!("validity '{spec}' does not start with a number"))?;
    if value == 0 {
        anyhow::bail!("validity '{spec}' must be greater than zero");
    }

    match unit {
        "s" => Ok(Duration::seconds(value)),
        "m" => Ok(Duration::minutes(value)),
        "h" => Ok(Duration::hours(value)),
        "d" => Ok(Duration::days(value)),
        other => anyhow::bail!("validity '{spec}' has unknown unit '{other}', expected s, m, h or d"),
    }
}

/// set the CSR params for the issued Certificate
pub fn set_csr_params(mut csr_params: CertificateParams, validity: Duration) -> CertificateParams {
    csr_params.not_after = OffsetDateTime::now_utc() + validity;
    csr_params.extended_key_usages = [ExtendedKeyUsagePurpose::ClientAuth].into();
    csr_params.key_usages = [
        KeyUsagePurpose::DigitalSignature,
        KeyUsagePurpose::KeyEncipherment,
    ]
    .into();
    csr_params.is_ca = IsCa::NoCa;

    csr_params
}

#[cfg(test)]
mod tests {
    use super::*;
    use rcgen::{KeyPair, KeyUsagePurpose};

    #[test]
    fn test_read_csr_valid() {
        // Generate a valid CSR for testing
        let params = CertificateParams::new(vec!["test.example.com".to_string()]).unwrap();
        let key_pair = KeyPair::generate().unwrap();
        let csr = params.serialize_request(&key_pair).unwrap();
        let csr_pem = csr.pem().unwrap();

        let result = read_csr(&csr_pem);
        assert!(result.is_ok());
    }

    #[test]
    fn test_read_csr_invalid() {
        let result = read_csr("invalid pem");
        assert!(result.is_err());
    }

    #[test]
    fn test_parse_validity_units() {
        assert_eq!(parse_validity("90d").unwrap(), Duration::days(90));
        assert_eq!(parse_validity("12h").unwrap(), Duration::hours(12));
        assert_eq!(parse_validity("5m").unwrap(), Duration::minutes(5));
        assert_eq!(parse_validity("30s").unwrap(), Duration::seconds(30));
        assert_eq!(parse_validity("  90d  ").unwrap(), Duration::days(90));
    }

    #[test]
    fn test_parse_validity_rejects_bad_input() {
        // Each of these would otherwise become a certificate lifetime.
        for bad in ["", "90", "d", "90x", "-1d", "0d", "9 0d", "ninety days"] {
            assert!(
                parse_validity(bad).is_err(),
                "expected '{bad}' to be rejected"
            );
        }
    }

    #[test]
    fn test_set_csr_params() {
        let params = CertificateParams::default();
        let modified_params = set_csr_params(params, DEFAULT_VALIDITY);

        assert_eq!(modified_params.is_ca, IsCa::NoCa);
        assert!(modified_params
            .extended_key_usages
            .contains(&ExtendedKeyUsagePurpose::ClientAuth));
        assert!(modified_params
            .key_usages
            .contains(&KeyUsagePurpose::DigitalSignature));
        assert!(modified_params
            .key_usages
            .contains(&KeyUsagePurpose::KeyEncipherment));
        // Check the validity period matches what was passed in
        let now = OffsetDateTime::now_utc();
        let diff = modified_params.not_after - now;
        assert!(diff >= Duration::days(89) && diff <= Duration::days(91));
    }

    #[test]
    fn test_set_csr_params_honours_a_short_validity() {
        let params = set_csr_params(CertificateParams::default(), parse_validity("30m").unwrap());
        let diff = params.not_after - OffsetDateTime::now_utc();
        assert!(diff <= Duration::minutes(30) && diff > Duration::minutes(29));
    }

    #[test]
    fn test_sign_csr() {
        // 1. Create a CA (Issuer)
        let mut ca_params = CertificateParams::new(vec!["My CA".to_string()]).unwrap();
        ca_params.is_ca = IsCa::Ca(rcgen::BasicConstraints::Unconstrained);
        let ca_key_pair = KeyPair::generate().unwrap();
        let ca_cert = ca_params.self_signed(&ca_key_pair).unwrap();
        let issuer = Issuer::from_ca_cert_der(ca_cert.der(), ca_key_pair).unwrap();

        // 2. Create a CSR
        let csr_params = CertificateParams::new(vec!["client.example.com".to_string()]).unwrap();
        let client_key_pair = KeyPair::generate().unwrap();
        let csr = csr_params.serialize_request(&client_key_pair).unwrap();
        let csr_pem = csr.pem().unwrap();

        // 3. Read CSR
        let parsed_csr_params = read_csr(&csr_pem).unwrap();

        // 4. Sign CSR
        let result = sign_csr(parsed_csr_params, &issuer);
        assert!(result.is_ok());
        let cert = result.unwrap();
        assert!(!cert.pem().is_empty());
    }
}
