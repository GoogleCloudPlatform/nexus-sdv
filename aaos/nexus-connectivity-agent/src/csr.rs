//! The common name the registration server insists on, and the certificate
//! signing request that carries it.
//!
//! The server parses the common name out of the client certificate presented in
//! the TLS handshake, parses the CSR's common name the same way, and refuses the
//! request unless both yield the same VIN and device id
//! (base-services/registration/server/src/main.rs:90-108). The common name is
//! therefore read out of the factory certificate rather than composed from a
//! VIN: composing it would reintroduce exactly the mismatch the server is
//! guarding against, and the resulting error says only "Csr is not valid".

use rcgen::{CertificateParams, DnType, KeyPair};
use x509_parser::prelude::{FromDer, X509Certificate};

#[derive(Debug)]
pub enum CsrError {
    NoCertificate,
    NoCommonName,
    NoVehicleInfo(String),
    Parse(String),
    Generate(String),
}

impl std::fmt::Display for CsrError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CsrError::NoCertificate => {
                write!(f, "the factory certificate file holds no CERTIFICATE block")
            }
            CsrError::NoCommonName => write!(
                f,
                "the factory certificate has no common name — the registration server needs one of the form 'VIN:<vin> DEVICE:<device-id>'"
            ),
            CsrError::NoVehicleInfo(cn) => write!(
                f,
                "the common name {cn:?} does not carry both a 'VIN:' and a 'DEVICE:' token"
            ),
            CsrError::Parse(e) => write!(f, "cannot read the factory certificate: {e}"),
            CsrError::Generate(e) => write!(f, "cannot build the signing request: {e}"),
        }
    }
}

pub struct VehicleInfo {
    pub vin: String,
    // Parsed because the server requires the token to be there, and its absence is
    // the error this reports; nothing downstream needs the value itself.
    #[allow(dead_code)]
    pub device_id: String,
}

/// The server's own rule, mirrored: split the common name on whitespace, take
/// the text after `VIN:` and after `DEVICE:`
/// (base-services/registration/server/src/listener/tls_listener.rs:39-59).
pub fn parse_vehicle_info(cn: &str) -> Result<VehicleInfo, CsrError> {
    let mut vin = None;
    let mut device_id = None;
    for part in cn.split_whitespace() {
        if let Some(v) = part.strip_prefix("VIN:") {
            vin = Some(v.to_string());
        } else if let Some(d) = part.strip_prefix("DEVICE:") {
            device_id = Some(d.to_string());
        }
    }
    match (vin, device_id) {
        (Some(vin), Some(device_id)) => Ok(VehicleInfo { vin, device_id }),
        _ => Err(CsrError::NoVehicleInfo(cn.to_string())),
    }
}

/// The common name of the first certificate in `pem`. The factory file is a
/// chain (leaf first, then the CA — provision-and-run.sh:81 concatenates them in
/// that order), and the leaf is the identity the handshake presents.
pub fn common_name_from_cert_pem(pem: &str) -> Result<String, CsrError> {
    let der = rustls_pemfile::certs(&mut std::io::BufReader::new(pem.as_bytes()))
        .next()
        .ok_or(CsrError::NoCertificate)?
        .map_err(|e| CsrError::Parse(e.to_string()))?;

    let (_, cert) =
        X509Certificate::from_der(der.as_ref()).map_err(|e| CsrError::Parse(e.to_string()))?;

    let cn = cert
        .subject()
        .iter_common_name()
        .next()
        .ok_or(CsrError::NoCommonName)?
        .as_str()
        .map_err(|e| CsrError::Parse(format!("the common name is not UTF-8: {e}")))?
        .to_string();

    // Refuse here rather than at the server: a name that does not parse produces
    // "Client Certificate missing" on its side, which points at the wrong thing.
    parse_vehicle_info(&cn)?;
    Ok(cn)
}

pub struct KeyAndCsr {
    pub key_pem: String,
    pub csr_pem: String,
}

/// A fresh key pair and a signing request carrying `common_name` verbatim.
pub fn generate(common_name: &str) -> Result<KeyAndCsr, CsrError> {
    let key = KeyPair::generate().map_err(|e| CsrError::Generate(e.to_string()))?;
    let mut params = CertificateParams::default();
    // Pushing a string stores the value as a UTF8String. The server accepts
    // nothing else: it matches on `DnValue::Utf8String` and returns "no utf8string
    // encoding in CN of CSR" for any other encoding
    // (base-services/registration/server/src/main.rs:96-102).
    params.distinguished_name.push(DnType::CommonName, common_name);
    let csr_pem = params
        .serialize_request(&key)
        .map_err(|e| CsrError::Generate(e.to_string()))?
        .pem()
        .map_err(|e| CsrError::Generate(e.to_string()))?;
    Ok(KeyAndCsr {
        key_pem: key.serialize_pem(),
        csr_pem,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use rcgen::{CertificateParams, DnType, KeyPair};

    /// A self-signed certificate carrying `cn` as its common name, as PEM —
    /// stands in for the factory certificate the vehicle is provisioned with.
    fn cert_pem_with_cn(cn: &str) -> String {
        let key = KeyPair::generate().expect("key pair");
        let mut params = CertificateParams::default();
        params.distinguished_name.push(DnType::CommonName, cn);
        params.self_signed(&key).expect("self-signed").pem()
    }

    #[test]
    fn reads_the_common_name_out_of_a_factory_certificate() {
        let cn = "VIN:PKG11MESH01 DEVICE:PKG11MESH01";
        assert_eq!(common_name_from_cert_pem(&cert_pem_with_cn(cn)).unwrap(), cn);
    }

    #[test]
    fn parses_vin_and_device_id_the_way_the_server_does() {
        let info = parse_vehicle_info("VIN:PKG11MESH01 DEVICE:PKG11MESH01").unwrap();
        assert_eq!(info.vin, "PKG11MESH01");
        assert_eq!(info.device_id, "PKG11MESH01");
    }

    /// The server splits on whitespace, so extra spaces, a tab, and the two
    /// tokens in the other order all parse the same. Anything this module
    /// accepts must survive the server's rule unchanged.
    #[test]
    fn whitespace_and_token_order_do_not_matter() {
        let info = parse_vehicle_info("DEVICE:dev-1\t  VIN:PKG11MESH01").unwrap();
        assert_eq!(info.vin, "PKG11MESH01");
        assert_eq!(info.device_id, "dev-1");
    }

    /// A VIN is not always plain uppercase alphanumerics — the factory helper
    /// issues whatever it was asked for. Nothing here may mangle it.
    #[test]
    fn unusual_but_legal_vin_characters_survive_the_round_trip() {
        let cn = "VIN:ab-12_XY/9 DEVICE:ab-12_XY/9";
        let read = common_name_from_cert_pem(&cert_pem_with_cn(cn)).unwrap();
        assert_eq!(read, cn);
        let info = parse_vehicle_info(&read).unwrap();
        assert_eq!(info.vin, "ab-12_XY/9");
        assert_eq!(info.device_id, "ab-12_XY/9");
    }

    #[test]
    fn refuses_a_common_name_without_a_device_token() {
        assert!(parse_vehicle_info("VIN:PKG11MESH01").is_err());
    }

    #[test]
    fn refuses_a_certificate_without_a_common_name() {
        let key = KeyPair::generate().expect("key pair");
        let params = CertificateParams::default();
        let pem = params.self_signed(&key).expect("self-signed").pem();
        assert!(common_name_from_cert_pem(&pem).is_err());
    }

    /// The check that matters: read the generated request back exactly the way
    /// the registration server does (base-services/registration/server/src/main.rs:95-107)
    /// — parse the PEM, pull the common name out of the distinguished name, and
    /// require it to be a UTF8String with the expected value. A different string
    /// encoding here is the subtle failure this whole module exists to prevent.
    #[test]
    fn the_generated_request_passes_the_servers_own_check() {
        let cn = "VIN:PKG11MESH01 DEVICE:PKG11MESH01";
        let generated = generate(cn).expect("generate");

        let parsed = rcgen::CertificateSigningRequestParams::from_pem(&generated.csr_pem)
            .expect("the server must be able to read this PEM");
        let Some(rcgen::DnValue::Utf8String(read_back)) =
            parsed.params.distinguished_name.get(&rcgen::DnType::CommonName)
        else {
            panic!("the common name is not a UTF8String — the server rejects that outright");
        };
        assert_eq!(read_back, cn);
    }

    #[test]
    fn the_generated_key_is_pem_the_tls_stack_can_read() {
        let generated = generate("VIN:PKG11MESH01 DEVICE:PKG11MESH01").expect("generate");
        let key = rustls_pemfile::private_key(&mut std::io::BufReader::new(
            generated.key_pem.as_bytes(),
        ))
        .expect("readable PEM");
        assert!(key.is_some(), "no private key found in the generated PEM");
    }
}
