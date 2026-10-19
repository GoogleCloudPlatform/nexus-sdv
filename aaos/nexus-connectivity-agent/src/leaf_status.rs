//! Asks the leaf itself whether its link to the cloud is up.
//!
//! Until now the only evidence was log lines, which can mislead: a stale log from a
//! previous run reads like a healthy one, and a killed `nats-server` never writes the
//! closing line at all (2026-09-16: a deploy that started nothing looked successful for
//! several minutes). `nats-server`'s monitoring endpoint answers from the running
//! process, so an answer is itself proof that the leaf is alive.
//!
//! Deliberately hand-rolled over `TcpStream` rather than pulling in an HTTP client: the
//! endpoint is localhost, the request is one line, and every added crate has to be
//! vendored for the AOSP build.

use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;

const TIMEOUT: Duration = Duration::from_secs(2);

/// Number of leaf node links the leaf currently holds, or `None` when the monitoring
/// endpoint did not answer — which means `nats-server` is down, starting, or wedged.
pub fn leafnode_count(monitor_port: u16) -> Option<usize> {
    let body = get(monitor_port, "/leafz")?;
    parse_leafnode_count(&body)
}

/// One line describing the leaf's state, for the agent log. The acceptance check reads
/// it, so the wording is part of the interface: `leaf status: link=up links=1`.
pub fn status_line(monitor_port: u16) -> String {
    match leafnode_count(monitor_port) {
        None => "leaf status: link=unknown links=0 (leaf did not answer on 127.0.0.1:\
                 MONITOR_PORT)"
            .replace("MONITOR_PORT", &monitor_port.to_string()),
        Some(0) => "leaf status: link=down links=0".to_string(),
        Some(n) => format!("leaf status: link=up links={n}"),
    }
}

fn get(monitor_port: u16, path: &str) -> Option<String> {
    let addr = ("127.0.0.1", monitor_port)
        .to_socket_addrs()
        .ok()?
        .next()?;
    let mut stream = TcpStream::connect_timeout(&addr, TIMEOUT).ok()?;
    stream.set_read_timeout(Some(TIMEOUT)).ok()?;
    stream.set_write_timeout(Some(TIMEOUT)).ok()?;
    let request = format!("GET {path} HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    stream.write_all(request.as_bytes()).ok()?;
    let mut response = String::new();
    stream.read_to_string(&mut response).ok()?;
    Some(response)
}

/// `/leafz` reports the number of links as `"leafnodes": N` next to the array of links.
fn parse_leafnode_count(response: &str) -> Option<usize> {
    let rest = response.split("\"leafnodes\"").nth(1)?;
    let digits: String = rest
        .trim_start_matches([':', ' '])
        .chars()
        .take_while(char::is_ascii_digit)
        .collect();
    digits.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    const RESPONSE: &str = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\
        \"server_id\": \"NC7ZQ\",\"now\": \"2026-09-16T19:26:41Z\",\"leafnodes\": 1,\
        \"leafs\": [{\"account\": \"$G\",\"ip\": \"34.116.195.11\",\"port\": 7422}]}";

    #[test]
    fn reads_the_link_count_from_a_real_response() {
        assert_eq!(parse_leafnode_count(RESPONSE), Some(1));
    }

    #[test]
    fn reads_zero_when_the_link_is_gone() {
        let body = RESPONSE.replace("\"leafnodes\": 1", "\"leafnodes\": 0");
        assert_eq!(parse_leafnode_count(&body), Some(0));
    }

    #[test]
    fn returns_nothing_for_an_unusable_answer() {
        assert_eq!(parse_leafnode_count(""), None);
        assert_eq!(parse_leafnode_count("HTTP/1.1 404 Not Found\r\n\r\n"), None);
        assert_eq!(parse_leafnode_count("{\"leafnodes\": }"), None);
    }

    /// The check script greps for these exact words; keep them stable.
    #[test]
    fn status_line_wording_is_stable() {
        // No leaf is listening on this port in the test environment.
        assert!(status_line(1).starts_with("leaf status: link=unknown"));
    }
}
