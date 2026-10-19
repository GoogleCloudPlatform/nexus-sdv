//! Resolve the vehicle's *current* VIN from the connectivity agent's
//! operational certificate.
//!
//! Why this file and not the obvious alternative: the agent's run directory also
//! holds `vehicle-<VIN>-factory-gcp-*.pem`, and it is tempting to read the VIN
//! out of that filename. That is wrong. The agent clears only `operational-*`
//! and `oidc-*` when it starts, so factory files from every VIN ever provisioned
//! accumulate side by side — a real device was observed carrying CLDLEAF01,
//! APEXCAR01 and NATSDEMO01 at once, with the *newest* file not being the active
//! identity. `operational-cert.pem` is re-issued on every agent start, so it
//! cannot go stale.
//!
//! Its subject is `CN = VIN:<vin> DEVICE:<device>`, and that CN sits in the DER
//! as plain ASCII — so a base64 decode plus a substring scan is enough, and we
//! need no X.509 parser (there is no crate for one in this build).

/// Where the connectivity agent keeps the identity it is currently running with.
pub const OPERATIONAL_CERT: &str =
    "/data/local/tmp/nexus-connectivity-agent-run/certificates/operational-cert.pem";

/// Decode base64, skipping whitespace, stopping at padding. Returns `None` on
/// any character that is not valid base64.
fn b64_decode(s: &str) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    let (mut acc, mut bits) = (0u32, 0u32);
    for c in s.bytes() {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            b'=' => break,
            b'\n' | b'\r' | b' ' | b'\t' => continue,
            _ => return None,
        } as u32;
        acc = (acc << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
        }
    }
    Some(out)
}

/// Pull `<vin>` out of a `VIN:<vin> DEVICE:<device>` common name embedded in DER.
fn vin_from_der(der: &[u8]) -> Option<String> {
    let at = der.windows(4).position(|w| w == b"VIN:")?;
    let vin: String = der[at + 4..]
        .iter()
        .take_while(|b| b.is_ascii_alphanumeric())
        .map(|&b| b as char)
        .collect();
    if vin.is_empty() {
        None
    } else {
        Some(vin)
    }
}

/// Strip the PEM armour and return the DER body.
fn der_from_pem(pem: &str) -> Option<Vec<u8>> {
    let body: String =
        pem.lines().filter(|l| !l.starts_with("-----")).collect::<Vec<_>>().join("");
    b64_decode(&body)
}

/// Read the VIN the vehicle is currently running as. The error is a sentence a
/// tester can act on, not a code.
pub fn vin_from_cert_file(path: &str) -> Result<String, String> {
    let pem = std::fs::read_to_string(path).map_err(|e| {
        format!("cannot read {path}: {e} — is the connectivity agent provisioned on this VM?")
    })?;
    let der = der_from_pem(&pem).ok_or_else(|| format!("{path} is not valid PEM"))?;
    vin_from_der(&der)
        .ok_or_else(|| format!("no 'VIN:<vin>' common name in {path} — unexpected certificate"))
}

#[cfg(test)]
mod tests {
    use super::*;

    // Base64 of DER bytes carrying `VIN:TESTVIN01 DEVICE:TESTVIN01`.
    const PEM: &str = "-----BEGIN CERTIFICATE-----\n\
        MIIBKgYDVQQDanVua2J5dGVzVklOOlRFU1RWSU4wMSBERVZJQ0U6VEVTVFZJTjAxMA0GCQ==\n\
        -----END CERTIFICATE-----\n";

    #[test]
    fn reads_the_vin_out_of_a_pem() {
        let der = der_from_pem(PEM).expect("decodes");
        assert_eq!(vin_from_der(&der).as_deref(), Some("TESTVIN01"));
    }

    #[test]
    fn stops_at_the_space_before_device() {
        // Guards the bug where the VIN would swallow " DEVICE:..." as well.
        assert_eq!(vin_from_der(b"xxVIN:ABC123 DEVICE:ABC123").as_deref(), Some("ABC123"));
    }

    #[test]
    fn rejects_a_certificate_without_a_vin_cn() {
        assert!(vin_from_der(b"CN=SomethingElse").is_none());
    }

    #[test]
    fn b64_handles_line_breaks_and_padding() {
        assert_eq!(b64_decode("aGVs\nbG8=").as_deref(), Some(&b"hello"[..]));
    }

    #[test]
    fn missing_file_explains_itself() {
        let e = vin_from_cert_file("/nonexistent/operational-cert.pem").unwrap_err();
        assert!(e.contains("connectivity agent"), "unhelpful error: {e}");
    }
}
