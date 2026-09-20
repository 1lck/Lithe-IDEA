//! User-facing Java preparation state derived from the existing session and build owner.

use super::jdt::MavenProfileTaskStatus;
use crate::lsp::LspLifecycleState;
use serde::Serialize;

/// Stable presentation state. Ready means project preparation, not compilation, completed.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProjectPreparation {
    /// Current stage: starting, importing, configuring, building, ready, or stopped.
    pub phase: &'static str,
    /// Presentation outcome: idle, loading, ready, or failed.
    pub status: &'static str,
    /// Whether Java launch must wait for the session-wide preparation gate.
    pub blocks_run: bool,
}

/// Projects upstream lifecycle facts without starting work or treating indexing as a gate.
pub(crate) fn snapshot(
    lifecycle: LspLifecycleState,
    profiles: MavenProfileTaskStatus,
    configuring: bool,
    building: bool,
) -> ProjectPreparation {
    use LspLifecycleState::*;
    let (phase, status) = match lifecycle {
        Created | ProcessStarting => ("starting", "loading"),
        Initializing => ("importing", "loading"),
        Failed => ("starting", "failed"),
        Stopping | Stopped => ("stopped", "idle"),
        Ready => match profiles {
            MavenProfileTaskStatus::Running => ("configuring", "loading"),
            _ if configuring => ("configuring", "loading"),
            _ if building => ("building", "loading"),

            MavenProfileTaskStatus::Failed
            | MavenProfileTaskStatus::TimedOut
            | MavenProfileTaskStatus::PartiallySucceeded
            | MavenProfileTaskStatus::Cancelled => ("configuring", "failed"),
            _ => ("ready", "ready"),
        },
    };
    ProjectPreparation {
        phase,
        status,
        // Profile errors are per-project. Keep their failure visible, but let JDT
        // validate the selected target rather than blocking unrelated modules.
        blocks_run: lifecycle != LspLifecycleState::Ready || status == "loading",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serialized_snapshots_match_the_shared_fixture() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../../shared/fixtures/lsp/project-preparation-v1.json"
        ))
        .unwrap();
        let cases = [
            (
                LspLifecycleState::Created,
                MavenProfileTaskStatus::Idle,
                false,
                false,
            ),
            (
                LspLifecycleState::Initializing,
                MavenProfileTaskStatus::Idle,
                false,
                false,
            ),
            (
                LspLifecycleState::Ready,
                MavenProfileTaskStatus::Running,
                false,
                false,
            ),
            (
                LspLifecycleState::Ready,
                MavenProfileTaskStatus::Succeeded,
                false,
                true,
            ),
            (
                LspLifecycleState::Ready,
                MavenProfileTaskStatus::Succeeded,
                false,
                false,
            ),
            (
                LspLifecycleState::Ready,
                MavenProfileTaskStatus::Failed,
                false,
                false,
            ),
            (
                LspLifecycleState::Stopped,
                MavenProfileTaskStatus::Idle,
                false,
                false,
            ),
        ];
        for ((lifecycle, profiles, configuring, building), expected) in cases
            .into_iter()
            .zip(fixture["snapshots"].as_array().unwrap())
        {
            assert_eq!(
                &serde_json::to_value(snapshot(lifecycle, profiles, configuring, building))
                    .unwrap(),
                expected
            );
        }
    }

    #[test]
    fn service_ready_does_not_bypass_project_configuration() {
        let ready = LspLifecycleState::Ready;
        assert_eq!(
            snapshot(ready, MavenProfileTaskStatus::Running, false, false).phase,
            "configuring"
        );
        assert!(snapshot(ready, MavenProfileTaskStatus::Succeeded, true, false).blocks_run);
        assert_eq!(
            snapshot(ready, MavenProfileTaskStatus::Succeeded, false, true).phase,
            "building"
        );
        assert!(!snapshot(ready, MavenProfileTaskStatus::Succeeded, false, false).blocks_run);
    }

    #[test]
    fn failures_and_stopped_sessions_never_report_ready() {
        for profiles in [
            MavenProfileTaskStatus::Failed,
            MavenProfileTaskStatus::TimedOut,
            MavenProfileTaskStatus::Cancelled,
            MavenProfileTaskStatus::PartiallySucceeded,
        ] {
            assert!(snapshot(LspLifecycleState::Ready, profiles, true, false).blocks_run);
            assert!(snapshot(LspLifecycleState::Ready, profiles, false, true).blocks_run);
            assert_eq!(
                snapshot(LspLifecycleState::Ready, profiles, false, false).status,
                "failed"
            );
        }
        assert!(
            snapshot(
                LspLifecycleState::Stopped,
                MavenProfileTaskStatus::Idle,
                false,
                false
            )
            .blocks_run
        );
        assert_eq!(
            snapshot(
                LspLifecycleState::Initializing,
                MavenProfileTaskStatus::Idle,
                false,
                false
            )
            .phase,
            "importing"
        );
    }
}
