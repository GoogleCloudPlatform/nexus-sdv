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
