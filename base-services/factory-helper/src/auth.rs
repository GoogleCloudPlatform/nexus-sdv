use crate::error::AppError;
use jsonwebtoken::{decode, decode_header, Algorithm, DecodingKey, Validation};
use serde::Deserialize;
use std::{collections::HashMap, future::Future, pin::Pin};
use tokio::sync::RwLock;

pub const REQUIRED_ROLE: &str = "factory-operator";

#[derive(Debug, Deserialize)]
pub struct RealmAccess {
    pub roles: Vec<String>,
}

#[derive(Debug, Deserialize)]
pub struct Claims {
    pub exp: u64,
    pub iss: String,
    pub realm_access: Option<RealmAccess>,
}

pub fn has_factory_operator_role(claims: &Claims) -> bool {
    claims
        .realm_access
        .as_ref()
        .map_or(false, |r| r.roles.iter().any(|x| x == REQUIRED_ROLE))
}

pub trait TokenVerifier: Send + Sync {
    fn verify<'a>(
        &'a self,
        bearer: &'a str,
    ) -> Pin<Box<dyn Future<Output = Result<Claims, AppError>> + Send + 'a>>;
}

#[derive(Deserialize)]
struct Jwk {
    kid: String,
    n: String,
    e: String,
    kty: String,
}
#[derive(Deserialize)]
struct Jwks {
    keys: Vec<Jwk>,
}

pub struct KeycloakVerifier {
    issuer: String,
    keys: RwLock<HashMap<String, DecodingKey>>,
    http: reqwest::Client,
}

impl KeycloakVerifier {
    /// `extra_ca_pem`: optional PEM trust anchor for the JWKS fetch — Keycloak's
    /// TLS cert is issued by Nexus's own server CA, not a public root.
    pub fn new(issuer: String, extra_ca_pem: Option<Vec<u8>>) -> Self {
        let mut builder = reqwest::Client::builder();
        if let Some(pem) = extra_ca_pem {
            for cert in reqwest::Certificate::from_pem_bundle(&pem).unwrap_or_default() {
                builder = builder.add_root_certificate(cert);
            }
        }
        Self {
            issuer,
            keys: RwLock::new(HashMap::new()),
            http: builder.build().expect("reqwest client"),
        }
    }

    async fn refresh_jwks(&self) -> Result<(), AppError> {
        let url = format!("{}/protocol/openid-connect/certs", self.issuer);
        let jwks: Jwks = self
            .http
            .get(&url)
            .send()
            .await
            .map_err(|_| AppError::Unauthorized)?
            .json()
            .await
            .map_err(|_| AppError::Unauthorized)?;
        let mut map = self.keys.write().await;
        map.clear();
        for k in jwks.keys.into_iter().filter(|k| k.kty == "RSA") {
            if let Ok(dk) = DecodingKey::from_rsa_components(&k.n, &k.e) {
                map.insert(k.kid, dk);
            }
        }
        Ok(())
    }
}

impl TokenVerifier for KeycloakVerifier {
    fn verify<'a>(
        &'a self,
        bearer: &'a str,
    ) -> Pin<Box<dyn Future<Output = Result<Claims, AppError>> + Send + 'a>> {
        Box::pin(async move {
            let header = decode_header(bearer).map_err(|_| AppError::Unauthorized)?;
            let kid = header.kid.ok_or(AppError::Unauthorized)?;
            if !self.keys.read().await.contains_key(&kid) {
                self.refresh_jwks().await?; // unknown kid: refresh once (rotation)
            }
            let keys = self.keys.read().await;
            let key = keys.get(&kid).ok_or(AppError::Unauthorized)?;
            let mut validation = Validation::new(Algorithm::RS256);
            validation.set_issuer(&[&self.issuer]);
            validation.validate_aud = false; // Keycloak client_credentials tokens: aud varies by mapper config
            let data = decode::<Claims>(bearer, key, &validation).map_err(|_| AppError::Unauthorized)?;
            Ok(data.claims)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn role_present_passes_absent_fails() {
        let with = Claims {
            exp: 0,
            iss: String::new(),
            realm_access: Some(RealmAccess {
                roles: vec!["x".into(), "factory-operator".into()],
            }),
        };
        let without = Claims {
            exp: 0,
            iss: String::new(),
            realm_access: Some(RealmAccess { roles: vec!["other".into()] }),
        };
        let none = Claims { exp: 0, iss: String::new(), realm_access: None };
        assert!(has_factory_operator_role(&with));
        assert!(!has_factory_operator_role(&without));
        assert!(!has_factory_operator_role(&none));
    }
}
