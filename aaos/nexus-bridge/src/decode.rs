pub fn format_receipt(topic: &str, count: u32, bytes: &[u8]) -> String {
    let head: String = bytes.iter().take(4).map(|b| format!("{:02x}", b)).collect();
    format!("nexus-bridge: received topic={} count={} len={} head={}", topic, count, bytes.len(), head)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn receipt_line_is_stable_and_opaque() {
        let line = format_receipt("pressure", 1, &[0xDE,0xAD,0xBE,0xEF]);
        assert_eq!(line, "nexus-bridge: received topic=pressure count=1 len=4 head=deadbeef");
    }
}
