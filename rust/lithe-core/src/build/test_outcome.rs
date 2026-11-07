//! Final verdict of one test run (`build.resolveTestRunOutcome`).
//!
//! Hosts collect how the run ended and the summary the provider's decoded
//! results reported; Core reduces those facts to one tool-neutral outcome, so
//! a run that executed no selected test reads the same on every platform. No
//! tool, framework, or selector syntax is interpreted here: the selection is
//! only the scope the host asked for, and the summary is whatever the
//! provider's decoder produced.

use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};

/// How the test process ended, as observed by the host.
#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub(crate) enum TestRunTermination {
    /// The tool exited by itself with this code.
    #[serde(rename_all = "camelCase")]
    Exited { exit_code: i32 },
    /// The host's deadline stopped the tool.
    TimedOut,
    /// The user or a replacement run stopped the tool.
    Cancelled,
}

/// The scope the host asked to run. Only the breadth matters: an explicit
/// suite or case that runs nothing did not match, a broader scope found none.
#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) enum TestRunScope {
    Workspace,
    Project,
    Suite,
    Case,
}

/// Counts from the provider's decoded results.
#[derive(Debug, Clone, Copy, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct TestRunSummary {
    pub(crate) total: u64,
    #[serde(default)]
    pub(crate) passed: u64,
    #[serde(default)]
    pub(crate) failed: u64,
    #[serde(default)]
    pub(crate) errors: u64,
    #[serde(default)]
    pub(crate) skipped: u64,
}

/// Input of `build.resolveTestRunOutcome`.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ResolveTestRunOutcomeRequest {
    pub(crate) termination: TestRunTermination,
    pub(crate) scope: TestRunScope,
    /// `None` when the run has no structured results (the provider declares
    /// none). The verdict then rests on the termination alone.
    #[serde(default)]
    pub(crate) summary: Option<TestRunSummary>,
}

/// The unified verdict. Every variant except `passed` is unsuccessful.
#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) enum TestRunOutcome {
    Passed,
    /// At least one test failed or errored.
    TestsFailed,
    /// The tool exited non-zero without reporting a failing test, for example
    /// a compilation error.
    ExitedWithError,
    /// An explicit suite or case was selected and no test ran.
    NoTestsMatched,
    /// A project or workspace scope ran and no test was found.
    NoTestsFound,
    TimedOut,
    Cancelled,
}

/// Output of `build.resolveTestRunOutcome`.
#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TestRunVerdict {
    pub(crate) outcome: TestRunOutcome,
    pub(crate) success: bool,
    /// The tool's exit code when it exited by itself.
    pub(crate) exit_code: Option<i32>,
}

/// Reduces one run's termination and decoded summary to its verdict.
///
/// Precedence: an interrupted run (cancelled, timed out) never claims a test
/// outcome; reported failures outrank the exit code; a non-zero exit outranks
/// an empty result; and a zero exit with decoded results but no executed test
/// is not a pass.
pub(crate) fn resolve_test_run_outcome(
    request: ResolveTestRunOutcomeRequest,
) -> Result<TestRunVerdict, CoreError> {
    if let Some(summary) = request.summary {
        let counted = [
            summary.passed,
            summary.failed,
            summary.errors,
            summary.skipped,
        ]
        .into_iter()
        .try_fold(0u64, u64::checked_add);
        if counted.is_none_or(|counted| counted > summary.total) {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Test summary counts exceed the reported total.",
            ));
        }
    }
    let exit_code = match request.termination {
        TestRunTermination::Cancelled => return Ok(verdict(TestRunOutcome::Cancelled, None)),
        TestRunTermination::TimedOut => return Ok(verdict(TestRunOutcome::TimedOut, None)),
        TestRunTermination::Exited { exit_code } => exit_code,
    };
    let outcome = match request.summary {
        Some(summary) if summary.failed + summary.errors > 0 => TestRunOutcome::TestsFailed,
        _ if exit_code != 0 => TestRunOutcome::ExitedWithError,
        Some(summary) if summary.total == 0 => match request.scope {
            TestRunScope::Suite | TestRunScope::Case => TestRunOutcome::NoTestsMatched,
            TestRunScope::Workspace | TestRunScope::Project => TestRunOutcome::NoTestsFound,
        },
        _ => TestRunOutcome::Passed,
    };
    Ok(verdict(outcome, Some(exit_code)))
}

fn verdict(outcome: TestRunOutcome, exit_code: Option<i32>) -> TestRunVerdict {
    TestRunVerdict {
        outcome,
        success: outcome == TestRunOutcome::Passed,
        exit_code,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn fixture() -> Value {
        serde_json::from_str(include_str!(
            "../../../../shared/fixtures/build/test-run-outcome-v1.json"
        ))
        .unwrap()
    }

    // The shared fixture is the cross-platform contract: both hosts feed the
    // same facts and must show the same verdict.
    #[test]
    fn shared_fixture_cases_resolve_to_their_expected_verdicts() {
        let fixture = fixture();
        let cases = fixture["cases"].as_array().unwrap();
        assert!(!cases.is_empty());
        for case in cases {
            let name = case["name"].as_str().unwrap();
            let request: ResolveTestRunOutcomeRequest =
                serde_json::from_value(case["request"].clone()).unwrap();
            let actual = serde_json::to_value(resolve_test_run_outcome(request).unwrap()).unwrap();
            assert_eq!(actual, case["expected"], "{name}");
        }
        for case in fixture["rejected"].as_array().unwrap() {
            let name = case["name"].as_str().unwrap();
            let accepted =
                serde_json::from_value::<ResolveTestRunOutcomeRequest>(case["request"].clone())
                    .map_err(|_| ())
                    .and_then(|request| resolve_test_run_outcome(request).map_err(|_| ()));
            assert!(accepted.is_err(), "{name}");
        }
    }

    // Regression for RUN-03: macOS reported a zero-match selection as passed
    // because it only looked at the exit code.
    #[test]
    fn zero_exit_without_any_executed_test_is_not_a_pass() {
        let request = ResolveTestRunOutcomeRequest {
            termination: TestRunTermination::Exited { exit_code: 0 },
            scope: TestRunScope::Case,
            summary: Some(TestRunSummary::default()),
        };
        let verdict = resolve_test_run_outcome(request).unwrap();
        assert_eq!(verdict.outcome, TestRunOutcome::NoTestsMatched);
        assert!(!verdict.success);
    }
}
