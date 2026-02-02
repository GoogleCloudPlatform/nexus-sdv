use anyhow::Context;
use std::{fs::File, io::BufReader, sync::Arc};

use rcgen::{Issuer, KeyPair};
use rustls_pki_types::{CertificateDer, PrivateKeyDer};

pub fn read_trusted_client_certificates_ca() -> anyhow::Result<Arc<rustls::RootCertStore>> {
    let ca_cert_file = &mut BufReader::new(File::open("certificates/trusted-factory-ca.crt.pem")?);

    let ca_certs: Vec<CertificateDer> =
        rustls_pemfile::certs(ca_cert_file).collect::<Result<Vec<_>, _>>()?;

    let mut root_store = rustls::RootCertStore::empty();
    for cert in ca_certs {
        root_store.add(cert)?;
    }

    let trusted_client_store = Arc::new(root_store);
    Ok(trusted_client_store)
}

pub fn read_server_certificate()
-> anyhow::Result<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>)> {
    let server_cert_file = &mut BufReader::new(File::open("certificates/server/server.crt.pem")?);

    let server_cert_chain: Vec<CertificateDer> = rustls_pemfile::certs(server_cert_file)
        .collect::<Result<Vec<_>, _>>()
        .with_context(|| "error reading server certificate file")?;

    let server_key: PrivateKeyDer =
        rustls_pemfile::private_key(&mut BufReader::new(File::open("certificates/server/server.key.pem")?))?
            .with_context(|| "server private key file not found")?;

    Ok((server_cert_chain, server_key))
}

pub fn read_signing_ca() -> anyhow::Result<Issuer<'static, KeyPair>> {
    let signing_cert_file = &mut BufReader::new(File::open("certificates/ca/ca.crt.pem")?);

    let signing_cert_chain: Vec<CertificateDer> = rustls_pemfile::certs(signing_cert_file)
        .collect::<Result<Vec<_>, _>>()
        .with_context(|| "error reading signing ca file")?;

    let signing_key: PrivateKeyDer =
        rustls_pemfile::private_key(&mut BufReader::new(File::open("certificates/ca/ca.key.pem")?))?
            .with_context(|| "signing private key file not found")?;

    let signing_key_pair = KeyPair::try_from(&signing_key)
        .with_context(|| "error creating KeyPair from signing key der")?;
    let issuer = Issuer::from_ca_cert_der(&signing_cert_chain[0], signing_key_pair)
        .with_context(|| "error creating issuer")?;
    Ok(issuer)
}
