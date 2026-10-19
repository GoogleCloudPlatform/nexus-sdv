//! Extracts the `exp` claim from a JWT so refresh can be scheduled against the token's
//! real, deployment-configured lifetime — never a hardcoded interval. See the plan's
//! Global Constraints: a 14-day TTL was measured against a deployed platform's Keycloak,
//! against tooling that previously assumed ~300s.
//!
//! No signature verification: the token was already validated by Keycloak at issuance,
//! and this is only used for local refresh scheduling, not an authorization decision.

use base64::Engine;
use serde::Deserialize;

#[derive(Deserialize)]
struct Claims {
    exp: i64,
}

#[derive(Debug)]
pub enum JwtError {
    MalformedToken,
    Base64(base64::DecodeError),
    Json(serde_json::Error),
}

impl std::fmt::Display for JwtError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            JwtError::MalformedToken => write!(f, "token does not have 3 dot-separated segments"),
            JwtError::Base64(e) => write!(f, "failed to base64-decode JWT payload: {e}"),
            JwtError::Json(e) => write!(f, "failed to parse JWT payload as JSON: {e}"),
        }
    }
}

/// Returns the token's `exp` claim as a Unix timestamp (seconds).
pub fn expiry_unix(jwt: &str) -> Result<i64, JwtError> {
    let payload_b64 = jwt
        .split('.')
        .nth(1)
        .ok_or(JwtError::MalformedToken)?;
    let payload_bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload_b64)
        .map_err(JwtError::Base64)?;
    let claims: Claims = serde_json::from_slice(&payload_bytes).map_err(JwtError::Json)?;
    Ok(claims.exp)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    /// Builds a syntactically-valid (unsigned) JWT with the given `exp`, matching real
    /// tokens' structure closely enough for this parser (header/signature content is
    /// irrelevant here).
    fn fake_jwt(exp: i64) -> String {
        let header = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(r#"{"alg":"none"}"#);
        let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .encode(format!(r#"{{"exp":{exp},"iat":0}}"#));
        format!("{header}.{payload}.fake-signature")
    }

    #[test]
    fn extracts_exp_from_a_well_formed_token() {
        let exp = 1786900260; // matches the 14-day-TTL token observed this session
        assert_eq!(expiry_unix(&fake_jwt(exp)).unwrap(), exp);
    }

    #[test]
    fn extracts_exp_from_a_token_expiring_soon() {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
        let exp = now + 300; // the ~300s the tooling's comments originally (wrongly) assumed
        assert_eq!(expiry_unix(&fake_jwt(exp)).unwrap(), exp);
    }

    #[test]
    fn rejects_a_token_without_three_segments() {
        assert!(matches!(expiry_unix("not-a-jwt"), Err(JwtError::MalformedToken)));
    }

    #[test]
    fn rejects_invalid_base64_in_the_payload_segment() {
        assert!(matches!(
            expiry_unix("header.not-valid-base64!!!.sig"),
            Err(JwtError::Base64(_))
        ));
    }
}
