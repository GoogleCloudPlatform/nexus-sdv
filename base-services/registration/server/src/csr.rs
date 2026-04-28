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

/// set the CSR params for the issued Certificate
pub fn set_csr_params(mut csr_params: CertificateParams) -> CertificateParams {
    csr_params.not_after = OffsetDateTime::now_utc() + Duration::days(365);
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
    fn test_set_csr_params() {
        let params = CertificateParams::default();
        let modified_params = set_csr_params(params);

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
        // Check validity period is roughly 365 days from now
        let now = OffsetDateTime::now_utc();
        let diff = modified_params.not_after - now;
        assert!(diff >= Duration::days(364) && diff <= Duration::days(366));
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
