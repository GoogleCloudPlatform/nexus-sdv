//! The configuration an init service cannot get on a command line.
//!
//! Until the init service, provisioning launched the nexus-connectivity-agent through the
//! adb shell with its configuration as environment variables
//! (aaos/aaos-nexus-sdv-tcu/provision-and-run.sh). init starts it with none, so
//! provisioning writes the same variables into a file and the service is started with
//! `--env-file <path>`. One `KEY=VALUE` per line; `#` comments and blank lines are skipped.
//! Until the file exists the service waits for it (`read_waiting`).
//! A variable already in the environment wins, so a test or an operator can override one.

pub fn parse(text: &str) -> Result<Vec<(String, String)>, String> {
    let mut out = Vec::new();
    for (i, raw) in text.lines().enumerate() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        // The message names the line, never its content: a misplaced value could be a secret.
        let Some((key, value)) = line.split_once('=') else {
            return Err(format!("line {}: expected KEY=VALUE", i + 1));
        };
        let valid = key.len() > "NEXUS_".len()
            && key.starts_with("NEXUS_")
            && key.bytes().all(|b| b.is_ascii_uppercase() || b.is_ascii_digit() || b == b'_');
        if !valid {
            return Err(format!("line {}: the key must match NEXUS_[A-Z0-9_]+", i + 1));
        }
        out.push((key.to_string(), value.to_string()));
    }
    Ok(out)
}

/// Sets each variable the environment does not already have. Called first thing in
/// `main`, before any thread exists.
pub fn apply(vars: &[(String, String)]) {
    for (key, value) in vars {
        if std::env::var_os(key).is_none() {
            std::env::set_var(key, value);
        }
    }
}

pub fn path_from_args(args: &[String]) -> Option<String> {
    args.windows(2).find(|w| w[0] == "--env-file").map(|w| w[1].clone())
}

/// Reads the configuration, waiting for it to exist. init starts the service at every boot,
/// also before provisioning has written the file; then it waits instead of exiting, because
/// an init service that exits is restarted every few seconds. `give_up_after` bounds the
/// polls for tests; the service passes `None`.
pub fn read_waiting(
    path: &std::path::Path,
    poll: std::time::Duration,
    give_up_after: Option<u32>,
) -> std::io::Result<String> {
    let mut polls = 0u32;
    loop {
        match std::fs::read_to_string(path) {
            // Not there yet, or its directory not readable yet: provisioning creates the
            // directory as root and hands it over a moment later (finding F48).
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::NotFound | std::io::ErrorKind::PermissionDenied
                ) =>
            {
                if polls == 0 {
                    eprintln!("waiting for the configuration {} (written by provisioning)", path.display());
                }
                polls += 1;
                if give_up_after.is_some_and(|max| polls >= max) {
                    return Err(e);
                }
                std::thread::sleep(poll);
            }
            other => return other,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_and_values_are_read_in_order() {
        let got = parse("# provisioned 2026-10-07\nNEXUS_VIN=PKG11MESH01\n\nNEXUS_LEAF_TLS=on\n").unwrap();
        assert_eq!(
            got,
            vec![
                ("NEXUS_VIN".to_string(), "PKG11MESH01".to_string()),
                ("NEXUS_LEAF_TLS".to_string(), "on".to_string()),
            ]
        );
    }

    #[test]
    fn a_value_may_contain_an_equals_sign() {
        let got = parse("NEXUS_NATS_URL=nats://n?a=b\n").unwrap();
        assert_eq!(got[0].1, "nats://n?a=b");
    }

    #[test]
    fn a_line_without_equals_names_its_line_number_not_its_content() {
        let err = parse("NEXUS_VIN=A\nsecret-looking-text\n").unwrap_err();
        assert!(err.contains("line 2"), "{err}");
        assert!(!err.contains("secret-looking-text"), "{err}");
    }

    #[test]
    fn a_key_outside_the_nexus_namespace_is_refused() {
        assert!(parse("PATH=/tmp\n").unwrap_err().contains("line 1"));
        assert!(parse("NEXUS_vin=A\n").is_err());
        assert!(parse("NEXUS_=A\n").is_err());
    }

    #[test]
    fn applying_keeps_what_the_environment_already_has() {
        std::env::set_var("NEXUS_TEST_ENV_FILE_KEEP", "from-env");
        apply(&[
            ("NEXUS_TEST_ENV_FILE_KEEP".into(), "from-file".into()),
            ("NEXUS_TEST_ENV_FILE_NEW".into(), "from-file".into()),
        ]);
        assert_eq!(std::env::var("NEXUS_TEST_ENV_FILE_KEEP").unwrap(), "from-env");
        assert_eq!(std::env::var("NEXUS_TEST_ENV_FILE_NEW").unwrap(), "from-file");
    }

    #[test]
    fn the_path_comes_from_the_command_line() {
        let args = ["bin", "--env-file", "/data/misc/nexus/nexus.env"].map(String::from);
        assert_eq!(path_from_args(&args), Some("/data/misc/nexus/nexus.env".to_string()));
        assert_eq!(path_from_args(&["bin".to_string()]), None);
    }

    #[test]
    fn a_file_that_never_appears_gives_up_after_the_given_polls() {
        let path = std::env::temp_dir().join(format!("env_file_absent_{}", std::process::id()));
        let started = std::time::Instant::now();
        assert!(read_waiting(&path, std::time::Duration::from_millis(10), Some(3)).is_err());
        assert!(started.elapsed() >= std::time::Duration::from_millis(20));
    }

    #[test]
    fn a_present_file_is_read_at_once() {
        let path = std::env::temp_dir().join(format!("env_file_present_{}", std::process::id()));
        std::fs::write(&path, "NEXUS_VIN=A\n").unwrap();
        assert_eq!(read_waiting(&path, std::time::Duration::from_secs(60), None).unwrap(), "NEXUS_VIN=A\n");
        std::fs::remove_file(&path).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn a_file_that_cannot_be_read_yet_is_waited_for_like_a_missing_one() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("env_file_denied_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("nexus.env");
        std::fs::write(&path, "NEXUS_VIN=A\n").unwrap();
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o000)).unwrap();
        let started = std::time::Instant::now();
        let result = read_waiting(&path, std::time::Duration::from_millis(10), Some(3));
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
        std::fs::remove_dir_all(&dir).unwrap();
        assert!(result.is_err());
        assert!(
            started.elapsed() >= std::time::Duration::from_millis(20),
            "it polled, it did not give up at once"
        );
    }
}
