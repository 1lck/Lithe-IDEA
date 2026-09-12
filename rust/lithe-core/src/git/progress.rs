//! Deterministic phase progress independent of console rendering and pipe framing.
use serde::Serialize;

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
/// A percentage applies only to its named phase, never to an entire multi-remote operation.
pub(super) struct Progress {
    stage: &'static str,
    percent: Option<u8>,
    completed: Option<u64>,
    total: Option<u64>,
}

pub(super) fn parse(text: &str) -> Option<Progress> {
    let text = text.trim().strip_prefix("remote: ").unwrap_or(text.trim());
    let stages = [
        ("Enumerating objects:", "enumerating"),
        ("Counting objects:", "counting"),
        ("Compressing objects:", "compressing"),
        ("Receiving objects:", "receiving"),
        ("Resolving deltas:", "resolving"),
        ("Writing objects:", "writing"),
        ("Updating files:", "updating"),
    ];
    let (prefix, stage) = stages.iter().find(|(prefix, _)| text.starts_with(prefix))?;
    let detail = text.strip_prefix(prefix)?.trim();
    let percent = detail
        .split_once('%')
        .and_then(|(value, _)| value.trim().parse::<u8>().ok())
        .filter(|value| *value <= 100);
    let counts = detail
        .split_once('(')
        .and_then(|(_, value)| value.split_once(')'))
        .and_then(|(value, _)| value.split_once('/'))
        .and_then(|(completed, total)| {
            Some((completed.parse::<u64>().ok()?, total.parse::<u64>().ok()?))
        })
        .filter(|(completed, total)| completed <= total);
    Some(Progress {
        stage,
        percent,
        completed: counts.map(|value| value.0),
        total: counts.map(|value| value.1),
    })
}

#[cfg(test)]
mod tests {
    #[test]
    fn progress_matches_shared_phases_without_treating_errors_as_percentages() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/git/execution-policy-v1.json"
        ))
        .unwrap();
        for case in fixture["progress"].as_array().unwrap() {
            assert_eq!(
                serde_json::to_value(super::parse(case["text"].as_str().unwrap())).unwrap(),
                case["expected"]
            );
        }
    }
}
