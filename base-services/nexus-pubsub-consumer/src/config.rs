//! Deployment configuration.
//!
//! The subject is a configuration value rather than a constant: it is static in
//! Increment 1.2, and the seam Increment 2's registry fills.

use serde::Deserialize;

/// How much of a vehicle's identity and readings reaches the log. A VIN tied to an owner is
/// personal data, and a sensor value can be anything a producer chose to send, including a
/// position. `Masked` is the default so that a deployment which says nothing is the safe
/// one; `Full` is for an environment that carries test vehicles only, and is asked for by
/// name in its config.
#[derive(Debug, Deserialize, PartialEq, Eq, Clone, Copy, Default)]
#[serde(rename_all = "lowercase")]
pub enum LogDetail {
    #[default]
    Masked,
    Full,
}

impl LogDetail {
    /// A vehicle or device id as it may be logged: whole under `Full`, otherwise only its
    /// last four characters, so two lines about the same vehicle can still be matched by eye.
    pub fn id(self, id: &str) -> String {
        match self {
            LogDetail::Full => id.to_string(),
            LogDetail::Masked => {
                let n = id.chars().count();
                if n <= 4 {
                    "****".to_string()
                } else {
                    format!("***{}", id.chars().skip(n - 4).collect::<String>())
                }
            }
        }
    }
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
pub struct Config {
    pub nats_url: String,
    pub nats_user: String,
    pub nats_password: String,
    pub subject: String,
    #[serde(default)]
    pub log_detail: LogDetail,
}

impl Config {
    pub fn load(path: &str) -> Result<Config, String> {
        let raw = std::fs::read_to_string(path).map_err(|e| format!("cannot read {path}: {e}"))?;
        Self::parse(&raw)
    }

    /// `${VAR}` is substituted from the environment before parsing, so secrets
    /// arrive as env vars from the Kubernetes Secret and never sit in the file.
    pub fn parse(raw: &str) -> Result<Config, String> {
        let expanded = expand_env(raw)?;
        toml::from_str(&expanded).map_err(|e| format!("invalid config: {e}"))
    }
}

fn expand_env(raw: &str) -> Result<String, String> {
    let mut out = String::with_capacity(raw.len());
    let mut rest = raw;
    while let Some(start) = rest.find("${") {
        out.push_str(&rest[..start]);
        let after = &rest[start + 2..];
        let end = after
            .find('}')
            .ok_or_else(|| "unterminated ${ in config".to_string())?;
        let name = &after[..end];
        let value = std::env::var(name)
            .map_err(|_| format!("config references ${{{name}}}, which is not set"))?;
        out.push_str(&value);
        rest = &after[end + 1..];
    }
    out.push_str(rest);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"
nats_url = "nats://nats.base-services.svc.cluster.local:4222"
nats_user = "connector"
nats_password = "${NATS_PASSWORD}"
subject = "pubsub.>"
"#;

    /// `env::set_var`/`remove_var` mutate one process-wide table, and cargo runs
    /// tests in parallel — glibc's setenv may reallocate `environ` even for an
    /// unrelated key. Serialising the two tests that touch the environment is what
    /// makes the `unsafe` blocks below actually sound.
    static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    #[test]
    fn substitutes_secrets_from_the_environment() {
        let _guard = ENV_LOCK.lock().unwrap();
        unsafe { std::env::set_var("NATS_PASSWORD", "s3cret") };
        let c = Config::parse(SAMPLE).expect("parses");
        assert_eq!(c.nats_password, "s3cret");
        assert_eq!(c.subject, "pubsub.>");
    }

    #[test]
    fn a_missing_variable_names_itself() {
        let _guard = ENV_LOCK.lock().unwrap();
        unsafe { std::env::remove_var("ABSENT_VALUE") };
        let err = Config::parse(r#"subject = "${ABSENT_VALUE}""#).unwrap_err();
        assert!(err.contains("ABSENT_VALUE"), "unhelpful error: {err}");
    }

    #[test]
    fn a_missing_subject_is_an_error_not_a_default() {
        // Defaulting the subject would let a misconfigured deployment sit
        // silently listening to nothing.
        let err = Config::parse(
            r#"nats_url = "x"
nats_user = "u"
nats_password = "p""#,
        )
        .unwrap_err();
        assert!(
            err.contains("subject"),
            "expected the error to name the field: {err}"
        );
    }

    #[test]
    fn log_detail_defaults_to_masked_and_accepts_full() {
        let _guard = ENV_LOCK.lock().unwrap();
        unsafe { std::env::set_var("NATS_PASSWORD", "s3cret") };
        assert_eq!(Config::parse(SAMPLE).unwrap().log_detail, LogDetail::Masked);
        let full = format!("{SAMPLE}\nlog_detail = \"full\"\n");
        assert_eq!(Config::parse(&full).unwrap().log_detail, LogDetail::Full);
    }

    #[test]
    fn an_unknown_log_detail_is_an_error_not_a_default() {
        let _guard = ENV_LOCK.lock().unwrap();
        unsafe { std::env::set_var("NATS_PASSWORD", "s3cret") };
        for bad in ["Full", "verbose", "", "off"] {
            let raw = format!("{SAMPLE}\nlog_detail = \"{bad}\"\n");
            assert!(Config::parse(&raw).is_err(), "{bad:?} must not silently mean something");
        }
    }

    #[test]
    fn a_masked_id_keeps_only_its_last_four_characters() {
        assert_eq!(LogDetail::Masked.id("WBA12345678901234"), "***1234");
        assert_eq!(LogDetail::Masked.id("APEXCAR01"), "***AR01");
        assert_eq!(LogDetail::Masked.id("ABCD"), "****", "nothing to spare on a short id");
        assert_eq!(LogDetail::Masked.id(""), "****");
        assert_eq!(LogDetail::Masked.id("ÄÖÜß12345"), "***2345", "characters, not bytes");
        assert_eq!(LogDetail::Full.id("APEXCAR01"), "APEXCAR01");
    }

    #[test]
    fn an_unterminated_placeholder_is_reported() {
        assert!(Config::parse(r#"subject = "${OOPS"#).is_err());
    }
}
