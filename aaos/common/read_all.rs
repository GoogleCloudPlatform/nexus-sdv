//! Read all (experimental): which discovered publications the Bridge carries, and the list
//! it leaves for the nexus-connectivity-agent. Pairs are `(unit_type, topic)`.

/// The discovered publications the Bridge subscribes in addition to its policy: none on a
/// topic the policy names (`declared`, every publisher and subscriber topic) — those it
/// carries already, or publishes itself and must not send back to the cloud — and one per
/// topic, the first found, since `pubsub.<vin>.<topic>` names no message type.
pub fn targets(found: &[(String, String)], declared: &[String]) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    for (unit_type, topic) in found {
        if declared.contains(topic) || out.iter().any(|(_, t)| t == topic) {
            continue;
        }
        out.push((unit_type.clone(), topic.clone()));
    }
    out
}

/// One `unit_type topic` per line.
pub fn format_list(list: &[(String, String)]) -> String {
    list.iter().map(|(u, t)| format!("{u} {t}\n")).collect()
}

/// Lines of exactly two words; anything else is skipped.
pub fn parse_list(text: &str) -> Vec<(String, String)> {
    text.lines()
        .filter_map(|l| match l.split_whitespace().collect::<Vec<_>>()[..] {
            [u, t] => Some((u.to_string(), t.to_string())),
            _ => None,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pair(u: &str, t: &str) -> (String, String) {
        (u.into(), t.into())
    }

    #[test]
    fn own_publications_and_declared_subscriptions_are_left_out() {
        let declared = ["command".to_string(), "uplink".to_string()];
        let found = [pair("x.Cmd", "command"), pair("x.Up", "uplink"), pair("g.Tire", "pressure2")];
        assert_eq!(targets(&found, &declared), vec![pair("g.Tire", "pressure2")]);
    }

    #[test]
    fn the_first_of_two_types_on_one_topic_wins() {
        let found = [pair("a.A", "t"), pair("b.B", "t")];
        assert_eq!(targets(&found, &[]), vec![pair("a.A", "t")]);
    }

    #[test]
    fn the_list_survives_its_file() {
        let l = vec![pair("a.A", "t1"), pair("b.B", "t2")];
        assert_eq!(parse_list(&format_list(&l)), l);
        assert_eq!(parse_list("\n  \nbroken\n"), vec![]);
    }
}
