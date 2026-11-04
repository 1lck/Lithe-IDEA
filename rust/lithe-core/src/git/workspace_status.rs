//! Plans publication of fresh and previously confirmed repository snapshots.

use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Request {
    roots: Vec<String>,
    previous_roots: Vec<String>,
    outcomes: Vec<Outcome>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Outcome {
    root: String,
    success: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Plan {
    entries: Vec<Entry>,
    confirmed_roots: Vec<String>,
    failed_roots: Vec<String>,
}

#[derive(Serialize)]
struct Entry {
    root: String,
    source: &'static str,
}

fn invalid() -> CoreError {
    CoreError::new(
        ErrorCode::InvalidRequest,
        "Invalid workspace Git status outcomes",
    )
}

/// A failed read preserves an existing snapshot, never proves a clean tree,
/// and never resurrects a root that discovery has removed. Hosts retain the
/// actual snapshots and apply this plan under their own publication generation.
pub(crate) fn plan(request: Request) -> Result<Plan, CoreError> {
    if request.roots.len() > 10_000
        || request.previous_roots.len() > 10_000
        || request.outcomes.len() != request.roots.len()
    {
        return Err(invalid());
    }
    let mut roots = BTreeSet::new();
    for root in &request.roots {
        if root.is_empty() || !roots.insert(root.as_str()) {
            return Err(invalid());
        }
    }
    let mut previous = BTreeSet::new();
    for root in &request.previous_roots {
        if root.is_empty() || !previous.insert(root.as_str()) {
            return Err(invalid());
        }
    }
    let mut outcomes = BTreeMap::new();
    for outcome in &request.outcomes {
        if !roots.contains(outcome.root.as_str())
            || outcomes
                .insert(outcome.root.as_str(), outcome.success)
                .is_some()
        {
            return Err(invalid());
        }
    }
    let mut entries = Vec::with_capacity(request.roots.len());
    let mut confirmed_roots = Vec::new();
    let mut failed_roots = Vec::new();
    for root in request.roots {
        let success = *outcomes.get(root.as_str()).ok_or_else(invalid)?;
        let source = if success {
            confirmed_roots.push(root.clone());
            "current"
        } else {
            failed_roots.push(root.clone());
            if previous.contains(root.as_str()) {
                "previous"
            } else {
                "missing"
            }
        };
        entries.push(Entry { root, source });
    }
    Ok(Plan {
        entries,
        confirmed_roots,
        failed_roots,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn call(payload: serde_json::Value) -> serde_json::Value {
        serde_json::from_str(&crate::execute_json(
            &json!({"id":"status", "command":"git.workspaceStatusMerge", "payload":payload})
                .to_string(),
        ))
        .unwrap()
    }

    #[test]
    fn keeps_failed_existing_snapshots_and_only_confirms_successes() {
        let response = call(
            json!({"roots":["a","b","c"], "previousRoots":["a","b","removed"], "outcomes":[
                {"root":"a","success":true}, {"root":"b","success":false}, {"root":"c","success":false}
            ]}),
        );
        assert_eq!(response["ok"], true, "{response}");
        assert_eq!(
            response["data"],
            json!({"entries":[{"root":"a","source":"current"},{"root":"b","source":"previous"},{"root":"c","source":"missing"}], "confirmedRoots":["a"], "failedRoots":["b","c"]})
        );
    }

    #[test]
    fn rejects_incomplete_duplicate_and_foreign_outcomes() {
        for payload in [
            json!({"roots":["a","b"],"previousRoots":[],"outcomes":[{"root":"a","success":true}]}),
            json!({"roots":["a","b"],"previousRoots":[],"outcomes":[{"root":"a","success":true},{"root":"a","success":false}]}),
            json!({"roots":["a"],"previousRoots":[],"outcomes":[{"root":"b","success":true}]}),
        ] {
            assert_eq!(call(payload)["ok"], false);
        }
    }
}
