//! Normalizes the change targets one Git operation acts on.
//!
//! A wholly untracked directory can be reported as one summary (`dir/`) whose
//! contents the user may list on demand. Selecting the summary together with
//! some of its listed files must act on each file exactly once: a shelf patch
//! would otherwise record the file twice, and a delete or rollback would fail
//! once the summary's files are gone. Hosts send the selection they captured;
//! Core decides which entries remain operation targets.

use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashSet;

/// Upper bound for one selection; larger requests are host bugs, not user input.
const MAX_TARGETS: usize = 100_000;

/// One selected change identity in the order the host captured it.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Target {
    /// Host-normalized repository root that owns `path`; only equality is used.
    root: String,
    /// Repository-relative path. A summary directory ends with `/`.
    path: String,
    /// True for a Core summary of a wholly untracked directory.
    #[serde(default)]
    untracked_directory: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Request {
    targets: Vec<Target>,
}

/// Positions of the retained targets, ascending, so hosts keep their own rows.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Response {
    indices: Vec<usize>,
}

fn invalid(message: &str) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, message)
}

/// Handles `git.normalizeChangeTargets`.
///
/// A target is dropped when a summary of the same repository is a strict
/// ancestor of its path. Everything else, including duplicates the host chose
/// to send, keeps its position; acting on a summary already acts on the
/// listed files below it.
pub(crate) fn command(payload: Value) -> Result<Value, CoreError> {
    let request: Request = serde_json::from_value(payload).map_err(|error| {
        invalid("Invalid Git change target request").with_details(error.to_string())
    })?;
    if request.targets.len() > MAX_TARGETS {
        return Err(invalid("Too many Git change targets"));
    }
    if request
        .targets
        .iter()
        .any(|target| target.root.is_empty() || target.path.is_empty())
    {
        return Err(invalid("Git change targets need a root and a path"));
    }
    if request
        .targets
        .iter()
        .any(|target| target.untracked_directory && !target.path.ends_with('/'))
    {
        return Err(invalid("An untracked directory summary must end with /"));
    }
    let summaries = request
        .targets
        .iter()
        .filter(|target| target.untracked_directory)
        .map(|target| (target.root.as_str(), target.path.as_str()))
        .collect::<HashSet<_>>();
    let indices = request
        .targets
        .iter()
        .enumerate()
        .filter(|(_, target)| !below_summary(target, &summaries))
        .map(|(index, _)| index)
        .collect();
    Ok(serde_json::to_value(Response { indices }).expect("change target indices encode"))
}

/// Walks the path's own ancestors, so the cost is bounded by its depth rather
/// than by the number of summaries in the selection.
fn below_summary(target: &Target, summaries: &HashSet<(&str, &str)>) -> bool {
    target
        .path
        .match_indices('/')
        .map(|(index, _)| &target.path[..=index])
        .any(|prefix| {
            prefix.len() < target.path.len() && summaries.contains(&(target.root.as_str(), prefix))
        })
}

#[cfg(test)]
mod tests {
    use serde_json::{json, Value};

    fn call(payload: Value) -> Value {
        serde_json::from_str(&crate::execute_json(
            &json!({"id":"targets", "command":"git.normalizeChangeTargets", "payload":payload})
                .to_string(),
        ))
        .unwrap()
    }

    #[test]
    fn shared_fixture_cases_keep_only_operation_targets() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/git/change-targets-v1.json"
        ))
        .unwrap();
        for case in fixture["cases"].as_array().unwrap() {
            let response = call(case["request"].clone());
            assert_eq!(response["ok"], true, "{}: {response}", case["name"]);
            assert_eq!(
                response["data"]["indices"], case["indices"],
                "{}",
                case["name"]
            );
        }
        for case in fixture["invalid"].as_array().unwrap() {
            let response = call(case["request"].clone());
            assert_eq!(response["ok"], false, "{}", case["name"]);
            assert_eq!(
                response["error"]["code"], "invalid_request",
                "{}",
                case["name"]
            );
        }
    }
}
