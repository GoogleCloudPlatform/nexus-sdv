//! Where log lines go. A process started through the adb shell had its output redirected
//! by the shell; an init service's output goes nowhere unless it is told otherwise, and the
//! acceptance scripts read the log file. With `NEXUS_LOG_FILE` set, every line is appended
//! there; without it, lines go to stdout and stderr as before.

use std::io::Write;
use std::sync::{Mutex, OnceLock};

pub struct Sink(Mutex<std::fs::File>);

impl Sink {
    pub fn to_file(path: &std::path::Path) -> std::io::Result<Sink> {
        let file = std::fs::OpenOptions::new().create(true).append(true).open(path)?;
        Ok(Sink(Mutex::new(file)))
    }

    pub fn write(&self, line: &str) {
        if let Ok(mut f) = self.0.lock() {
            let _ = writeln!(f, "{line}");
        }
    }
}

static SINK: OnceLock<Sink> = OnceLock::new();

/// Opens `NEXUS_LOG_FILE` when it is set. Call once, after the env file is applied.
pub fn init_from_env() {
    if let Some(path) = std::env::var_os("NEXUS_LOG_FILE") {
        match Sink::to_file(std::path::Path::new(&path)) {
            Ok(sink) => {
                let _ = SINK.set(sink);
            }
            Err(e) => eprintln!("cannot open NEXUS_LOG_FILE: {e} — logging to stderr"),
        }
    }
}

/// Used by `log_line!` and `log_err!`.
pub fn emit(to_stderr: bool, line: String) {
    match SINK.get() {
        Some(sink) => sink.write(&line),
        None if to_stderr => eprintln!("{line}"),
        None => println!("{line}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lines_are_appended_to_the_file() {
        let dir = std::env::temp_dir().join(format!("log_sink_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("agent.log");
        let sink = Sink::to_file(&path).unwrap();
        sink.write("first");
        sink.write("second");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "first\nsecond\n");
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
