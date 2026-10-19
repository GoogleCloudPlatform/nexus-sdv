//! UTC timestamps for the agent's own log lines.
//!
//! Without them the agent's output cannot be lined up with the leaf's, which is
//! exactly what blocked the analysis of 32 overnight link drops on 2026-09-17: the
//! agent had written 725 status lines and not one could be tied to a drop. The
//! format matches `nats-server`'s own (`2026/09/17 07:31:56`) so the two logs read
//! side by side.
//!
//! Hand-rolled rather than pulling in a date crate: every dependency added here has
//! to be vendored for the AOSP build, and this is twenty lines of arithmetic.

use std::time::{SystemTime, UNIX_EPOCH};

/// `YYYY/MM/DD HH:MM:SS` in UTC for the current time.
pub fn now_stamp() -> String {
    stamp(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0),
    )
}

/// Same, for a given number of seconds since the epoch.
fn stamp(secs: i64) -> String {
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    format!(
        "{year:04}/{month:02}/{day:02} {:02}:{:02}:{:02}",
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    )
}

/// Howard Hinnant's days-to-civil algorithm: shift the epoch to 0000-03-01 so that
/// leap days land at the end of the cycle, then unwind the 400/100/4-year cycles.
fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// One line with a timestamp in front: to `NEXUS_LOG_FILE` when set (log_sink.rs), else stdout.
#[macro_export]
macro_rules! log_line {
    ($($arg:tt)*) => {
        $crate::log_sink::emit(
            false,
            format!("[{}] {}", $crate::clock::now_stamp(), format_args!($($arg)*)),
        )
    };
}

/// The same, falling back to stderr.
#[macro_export]
macro_rules! log_err {
    ($($arg:tt)*) => {
        $crate::log_sink::emit(
            true,
            format!("[{}] {}", $crate::clock::now_stamp(), format_args!($($arg)*)),
        )
    };
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_the_epoch() {
        assert_eq!(stamp(0), "1970/01/01 00:00:00");
    }

    #[test]
    fn formats_known_instants() {
        assert_eq!(stamp(1_000_000_000), "2001/09/09 01:46:40");
        assert_eq!(stamp(1_700_000_000), "2023/11/14 22:13:20");
    }

    /// A leap day, the case the day-to-date arithmetic exists for.
    #[test]
    fn formats_a_leap_day() {
        assert_eq!(stamp(1_709_164_800), "2024/02/29 00:00:00");
    }

    #[test]
    fn matches_the_nats_server_format() {
        let s = now_stamp();
        assert_eq!(s.len(), 19, "{s}");
        assert_eq!(&s[4..5], "/");
        assert_eq!(&s[10..11], " ");
        assert_eq!(&s[13..14], ":");
    }
}
