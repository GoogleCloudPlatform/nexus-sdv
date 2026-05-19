use anyhow::{anyhow, Context}; // provides context() and anyhow!
use std::fs::File;            // provides File
use std::io::BufReader;       // provides BufReader
use std::sync::Arc;           // provides Arc
use rcgen::{Issuer, KeyPair};  // provides Issuer and KeyPair
use rustls_pki_types::{CertificateDer, PrivateKeyDer}; // provides types

pub fn read_trusted_client_certificates_ca() -> anyhow::Result<Arc<rustls::RootCertStore>> {
    let path = std::env::var("TEST_CA_PATH")
        .unwrap_or_else(|_| "certificates/trusted-factory-ca.crt.pem".to_string());

    let ca_cert_file = &mut BufReader::new(File::open(path)?);
    let ca_certs: Vec<CertificateDer> =
        rustls_pemfile::certs(ca_cert_file).collect::<Result<Vec<_>, _>>()?;

    let mut root_store = rustls::RootCertStore::empty();
    for cert in ca_certs {
        root_store.add(cert)?;
    }
    Ok(Arc::new(root_store))
}

pub fn read_server_certificate() -> anyhow::Result<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>)> {
    let cert_path = std::env::var("TEST_SERVER_CERT_PATH")
        .unwrap_or_else(|_| "certificates/server/server.crt.pem".to_string());
    let key_path = std::env::var("TEST_SERVER_KEY_PATH")
        .unwrap_or_else(|_| "certificates/server/server.key.pem".to_string());

    let server_cert_chain: Vec<CertificateDer> = rustls_pemfile::certs(&mut BufReader::new(File::open(cert_path)?))
        .collect::<Result<Vec<_>, _>>()
        .with_context(|| "error reading server certificate file")?;

    let server_key: PrivateKeyDer =
        rustls_pemfile::private_key(&mut BufReader::new(File::open(key_path)?))?
            .with_context(|| "server private key file not found")?;

    Ok((server_cert_chain, server_key))
}

pub fn read_signing_ca() -> anyhow::Result<Issuer<'static, KeyPair>> {
    let cert_path = std::env::var("TEST_SIGNING_CA_PATH")
        .unwrap_or_else(|_| "certificates/ca/ca.crt.pem".to_string());
    let key_path = std::env::var("TEST_SIGNING_KEY_PATH")
        .unwrap_or_else(|_| "certificates/ca/ca.key.pem".to_string());

    let signing_cert_chain: Vec<CertificateDer> = rustls_pemfile::certs(&mut BufReader::new(File::open(cert_path)?))
        .collect::<Result<Vec<_>, _>>()
        .with_context(|| "error reading signing ca file")?;

    let signing_key: PrivateKeyDer =
        rustls_pemfile::private_key(&mut BufReader::new(File::open(key_path)?))?
            .with_context(|| "signing private key file not found")?;

    let signing_key_pair = KeyPair::try_from(&signing_key)
        .with_context(|| "error creating KeyPair from signing key der")?;
    let issuer = Issuer::from_ca_cert_der(&signing_cert_chain[0], signing_key_pair)
        .with_context(|| "error creating issuer")?;
    Ok(issuer)
}