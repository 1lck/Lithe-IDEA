//! Merging a run's test results into the stored history
//! (`build.mergeTestOutcomes`).
//!
//! Hosts keep the last known result of every test. A run only speaks for the
//! tests it covered, so the history keeps every other result. The covered set
//! is stated by the host: exact identifiers and identifier prefixes. Core
//! compares strings only; how a tool names nested suites or how a host builds
//! identifiers is decided by the provider adapter that builds the scope.

use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

/// What the run replaces. A result is covered when its identifier equals one
/// of `ids` or starts with one of `prefixes`. An empty scope covers nothing.
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct TestOutcomeScope {
    #[serde(default)]
    pub(crate) ids: Vec<String>,
    #[serde(default)]
    pub(crate) prefixes: Vec<String>,
}

/// Input of `build.mergeTestOutcomes`. Results are passed as identifiers; the
/// host keeps the payloads and maps the answer back by position.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct MergeTestOutcomesRequest {
    /// Identifiers of the stored history, in display order.
    #[serde(default)]
    pub(crate) previous: Vec<String>,
    /// Identifiers the run reported, in report order.
    #[serde(default)]
    pub(crate) incoming: Vec<String>,
    #[serde(default)]
    pub(crate) scope: TestOutcomeScope,
}

/// Which input list a merged entry comes from.
#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) enum TestOutcomeSource {
    Previous,
    Incoming,
}

/// One merged entry: the position in the `previous` or `incoming` input.
#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MergedTestOutcome {
    pub(crate) source: TestOutcomeSource,
    pub(crate) index: usize,
}

/// Output of `build.mergeTestOutcomes`.
#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MergedTestOutcomes {
    pub(crate) entries: Vec<MergedTestOutcome>,
}

/// Merges one run into the history.
///
/// Stored results the scope covers are dropped, the others stay in place. The
/// run's results follow, but only those inside the scope: a run cannot
/// overwrite what it did not claim. When an identifier repeats, the later
/// entry wins and takes the later position.
pub(crate) fn merge_test_outcomes(
    request: MergeTestOutcomesRequest,
) -> Result<MergedTestOutcomes, CoreError> {
    if request.scope.prefixes.iter().any(String::is_empty) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "A test outcome scope prefix must not be empty.",
        ));
    }
    let ids: HashSet<&str> = request.scope.ids.iter().map(String::as_str).collect();
    let covered = |id: &str| {
        ids.contains(id)
            || request
                .scope
                .prefixes
                .iter()
                .any(|prefix| id.starts_with(prefix.as_str()))
    };
    let candidates = request
        .previous
        .iter()
        .enumerate()
        .filter(|(_, id)| !covered(id))
        .map(|(index, id)| (TestOutcomeSource::Previous, index, id))
        .chain(
            request
                .incoming
                .iter()
                .enumerate()
                .filter(|(_, id)| covered(id))
                .map(|(index, id)| (TestOutcomeSource::Incoming, index, id)),
        )
        .collect::<Vec<_>>();
    // Walk backwards so the last occurrence of an identifier is the one kept.
    let mut seen = HashSet::new();
    let mut entries = candidates
        .iter()
        .rev()
        .filter(|(_, _, id)| seen.insert(id.as_str()))
        .map(|&(source, index, _)| MergedTestOutcome { source, index })
        .collect::<Vec<_>>();
    entries.reverse();
    Ok(MergedTestOutcomes { entries })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    // The shared fixture is the cross-platform contract: both hosts build the
    // same scope and must keep the same history.
    #[test]
    fn shared_fixture_cases_merge_to_their_expected_history() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/build/test-outcome-merge-v1.json"
        ))
        .unwrap();
        let cases = fixture["cases"].as_array().unwrap();
        assert!(!cases.is_empty());
        for case in cases {
            let name = case["name"].as_str().unwrap();
            let request: MergeTestOutcomesRequest =
                serde_json::from_value(case["request"].clone()).unwrap();
            let actual = serde_json::to_value(merge_test_outcomes(request).unwrap()).unwrap();
            assert_eq!(actual, case["expected"], "{name}");
        }
        for case in fixture["rejected"].as_array().unwrap() {
            let name = case["name"].as_str().unwrap();
            let rejected =
                serde_json::from_value::<MergeTestOutcomesRequest>(case["request"].clone())
                    .map_err(|_| ())
                    .and_then(|request| merge_test_outcomes(request).map_err(|_| ()));
            assert!(rejected.is_err(), "{name}");
        }
    }
}
