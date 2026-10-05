use crate::{auth, csr, error::AppError, vin, AppState};
use axum::{
    extract::State,
    http::{header, HeaderMap},
    response::{IntoResponse, Response},
    Json,
};
use serde::Deserialize;
use serde_json::json;
use std::sync::Arc;

#[derive(Deserialize)]
pub struct IssueRequest {
    pub csr: Option<String>,
    pub vin: Option<String>,
    pub vin_prefix: Option<String>,
    pub device_type: Option<String>,
}

pub async fn issue_certificate(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(req): Json<IssueRequest>,
) -> Result<Response, AppError> {
    // AuthN + role
    let bearer = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .ok_or(AppError::Unauthorized)?;
    let claims = state.verifier.verify(bearer).await?;
    if !auth::has_factory_operator_role(&claims) {
        return Err(AppError::Forbidden);
    }

    let cert_id = format!("factory-{}", &uuid::Uuid::new_v4().simple().to_string()[..12]);

    let (resolved_vin, csr_pem, private_key) = match req.csr {
        Some(pem) => {
            // Mode 1: sign-only. The private key never exists here.
            let (pem, csr_vin) = csr::validate_provided_csr(&pem, req.vin.as_deref())?;
            (csr_vin, pem, None)
        }
        None => {
            // Mode 2: server-side identity generation (spec safeguards apply).
            let v = vin::resolve_vin(req.vin.as_deref(), req.vin_prefix.as_deref())?;
            // Nexus CN convention is DEVICE:<vin> (generate-factory-cert-gcp.sh:
            // "correct CN format (VIN:xxx DEVICE:xxx)"); the registration server
            // requires factory-cert CN == operational-CSR CN, and the Go
            // vehicle-client builds its CSR with DEVICE:<vin>.
            let device_type = req.device_type.clone().unwrap_or_else(|| v.clone());
            let id = csr::generate_csr(&v, &device_type, &state.config.cert_org)?;
            (v, id.csr_pem, Some(id.private_key_pem))
        }
    };

    let issued = state.issuer.issue(&csr_pem, &cert_id).await?;

    // Fire-and-forget: see registry.rs — reporting never blocks issuance.
    crate::registry::report_issued(&state.config.vin_registry_url, &resolved_vin);

    let mut body = json!({
        "vin": resolved_vin,
        "certificate": issued.certificate,
        "ca_certificate_chain": issued.chain,
    });
    if let Some(key) = &private_key {
        body["private_key"] = json!(key.as_str());
    }
    // `private_key` (Zeroizing) drops — and zeroes — right after serialization.
    Ok(([(header::CACHE_CONTROL, "no-store")], Json(body)).into_response())
}

#[cfg(test)]
mod tests {
    use crate::{auth::*, build_router, ca::*, AppState, Config};
    use axum::{
        body::Body,
        http::{Request, StatusCode},
    };
    use http_body_util::BodyExt;
    use std::{future::Future, pin::Pin, sync::Arc};
    use tower::ServiceExt;

    struct FakeVerifier {
        roles: Vec<String>,
    }
    impl TokenVerifier for FakeVerifier {
        fn verify<'a>(
            &'a self,
            bearer: &'a str,
        ) -> Pin<Box<dyn Future<Output = Result<Claims, crate::error::AppError>> + Send + 'a>>
        {
            let ok = bearer == "good";
            let roles = self.roles.clone();
            Box::pin(async move {
                if !ok {
                    return Err(crate::error::AppError::Unauthorized);
                }
                Ok(Claims {
                    exp: 0,
                    iss: String::new(),
                    realm_access: Some(RealmAccess { roles }),
                })
            })
        }
    }
    struct FakeCa;
    impl CaIssuer for FakeCa {
        fn issue<'a>(
            &'a self,
            _csr: &'a str,
            _id: &'a str,
        ) -> Pin<Box<dyn Future<Output = Result<IssuedCert, crate::error::AppError>> + Send + 'a>>
        {
            Box::pin(async {
                Ok(IssuedCert {
                    certificate: "CERT".into(),
                    chain: "CHAIN".into(),
                })
            })
        }
    }
    fn app(roles: Vec<String>) -> axum::Router {
        let config = Config {
            cert_validity_days: crate::ca::DEFAULT_VALIDITY_DAYS,
            gcp_project_id: "p".into(),
            gcp_region: "r".into(),
            ca_pool: "pool".into(),
            keycloak_issuer: "i".into(),
            cert_org: "Nexus SDV".into(),
            tls_cert_path: String::new(),
            tls_key_path: String::new(),
            keycloak_ca_path: None,
            vin_registry_url: None,
            port: 0,
        };
        build_router(Arc::new(AppState {
            config,
            verifier: Box::new(FakeVerifier { roles }),
            issuer: Box::new(FakeCa),
        }))
    }
    async fn call(
        app: axum::Router,
        auth: Option<&str>,
        body: &str,
    ) -> (StatusCode, serde_json::Value, Option<String>) {
        let mut req = Request::post("/v1/factory-certificates").header("content-type", "application/json");
        if let Some(a) = auth {
            req = req.header("authorization", format!("Bearer {a}"));
        }
        let resp = app
            .oneshot(req.body(Body::from(body.to_string())).unwrap())
            .await
            .unwrap();
        let status = resp.status();
        let cache = resp
            .headers()
            .get("cache-control")
            .map(|v| v.to_str().unwrap().to_string());
        let bytes = resp.into_body().collect().await.unwrap().to_bytes();
        (
            status,
            serde_json::from_slice(&bytes).unwrap_or(serde_json::json!({})),
            cache,
        )
    }

    #[tokio::test]
    async fn no_token_401_wrong_role_403() {
        assert_eq!(
            call(app(vec!["factory-operator".into()]), None, "{}").await.0,
            StatusCode::UNAUTHORIZED
        );
        assert_eq!(
            call(app(vec!["other".into()]), Some("good"), "{}").await.0,
            StatusCode::FORBIDDEN
        );
    }
    #[tokio::test]
    async fn mode2_returns_key_and_no_store() {
        let (status, body, cache) = call(
            app(vec!["factory-operator".into()]),
            Some("good"),
            r#"{"vin":"CLDLEAF01"}"#,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["vin"], "CLDLEAF01");
        assert_eq!(body["certificate"], "CERT");
        assert_eq!(body["ca_certificate_chain"], "CHAIN");
        assert!(body["private_key"].as_str().unwrap().contains("PRIVATE KEY"));
        assert_eq!(cache.unwrap(), "no-store");
    }
    #[tokio::test]
    async fn mode1_signs_provided_csr_and_returns_no_key() {
        let mut params = rcgen::CertificateParams::default();
        params
            .distinguished_name
            .push(rcgen::DnType::CommonName, "VIN:ABC123 DEVICE:car");
        let key = rcgen::KeyPair::generate().unwrap();
        let csr = params.serialize_request(&key).unwrap().pem().unwrap();
        let req_body = serde_json::json!({ "csr": csr }).to_string();
        let (status, body, cache) =
            call(app(vec!["factory-operator".into()]), Some("good"), &req_body).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["vin"], "ABC123");
        assert!(body.get("private_key").is_none());
        assert_eq!(cache.unwrap(), "no-store");
    }
    #[tokio::test]
    async fn mode2_default_device_type_is_the_vin() {
        // Nexus convention: DEVICE:<vin> (generate-factory-cert-gcp.sh) — the
        // generated CSR must carry it so the registration server's
        // factory-CN == ops-CSR-CN check passes for the Go vehicle-client.
        use std::sync::Mutex;
        static CAPTURED: Mutex<String> = Mutex::new(String::new());
        struct CapturingCa;
        impl CaIssuer for CapturingCa {
            fn issue<'a>(
                &'a self,
                csr: &'a str,
                _id: &'a str,
            ) -> Pin<Box<dyn Future<Output = Result<IssuedCert, crate::error::AppError>> + Send + 'a>>
            {
                *CAPTURED.lock().unwrap() = csr.to_string();
                Box::pin(async {
                    Ok(IssuedCert { certificate: "CERT".into(), chain: "CHAIN".into() })
                })
            }
        }
        let config = Config {
            cert_validity_days: crate::ca::DEFAULT_VALIDITY_DAYS,
            gcp_project_id: "p".into(), gcp_region: "r".into(), ca_pool: "pool".into(),
            keycloak_issuer: "i".into(), cert_org: "Nexus SDV".into(),
            tls_cert_path: String::new(), tls_key_path: String::new(),
            vin_registry_url: None,
            keycloak_ca_path: None, port: 0,
        };
        let app = build_router(Arc::new(AppState {
            config,
            verifier: Box::new(FakeVerifier { roles: vec!["factory-operator".into()] }),
            issuer: Box::new(CapturingCa),
        }));
        let (status, _, _) = call(app, Some("good"), r#"{"vin":"DEVDEFAULT01"}"#).await;
        assert_eq!(status, StatusCode::OK);
        let csr_pem = CAPTURED.lock().unwrap().clone();
        let params = rcgen::CertificateSigningRequestParams::from_pem(&csr_pem).unwrap();
        let cn = params.params.distinguished_name.get(&rcgen::DnType::CommonName)
            .and_then(|v| match v {
                rcgen::DnValue::PrintableString(s) => Some(s.as_str().to_string()),
                rcgen::DnValue::Utf8String(s) => Some(s.clone()),
                _ => None,
            }).unwrap();
        assert_eq!(cn, "VIN:DEVDEFAULT01 DEVICE:DEVDEFAULT01");
    }

    #[tokio::test]
    async fn csr_vin_mismatch_400() {
        let mut params = rcgen::CertificateParams::default();
        params
            .distinguished_name
            .push(rcgen::DnType::CommonName, "VIN:OTHER DEVICE:car");
        let key = rcgen::KeyPair::generate().unwrap();
        let csr = params.serialize_request(&key).unwrap().pem().unwrap();
        let req_body = serde_json::json!({ "csr": csr, "vin": "CLDLEAF01" }).to_string();
        assert_eq!(
            call(app(vec!["factory-operator".into()]), Some("good"), &req_body)
                .await
                .0,
            StatusCode::BAD_REQUEST
        );
    }
}
