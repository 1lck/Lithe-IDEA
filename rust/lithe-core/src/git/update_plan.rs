//! Plans branch Update and Pull from facts the host collected.
//!
//! IDEA's branch Update pulls a branch inside the worktree that has it checked
//! out and fast-forwards any other local branch in place. Both products used
//! to encode the gates in their own way: one merged a diverged current branch
//! without asking, the other continued after a failed inspection. This module
//! owns every decision; hosts run Fetch, read worktrees and `git.pullPreflight`,
//! present the result, and execute the returned step.
//!
//! Strategy precedence is: what the user chose, then what Git is configured to
//! do (`pull.rebase`, `pull.ff`, reported by `git.pullPreflight`), then
//! fast-forward only. A fast-forward never invents a merge commit or replays
//! local history, so it is the default when nobody expressed a preference.

use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Upper bound for worktree facts in one request.
const MAX_WORKTREES: usize = 10_000;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// Local branch the user asked to update.
struct Branch {
    /// Complete local reference, `refs/heads/<name>`.
    full_name: String,
    /// Configured upstream short name; `null` when none is configured.
    #[serde(default)]
    upstream: Option<String>,
    /// Checked out in the worktree the request came from.
    is_current: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// One worktree of the repository as the host listed it.
struct Worktree {
    path: String,
    /// Complete checked-out reference; `null` when detached.
    #[serde(default)]
    branch: Option<String>,
    is_current: bool,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// `git.pullPreflight` for the checkout being updated, read after Fetch.
struct Preflight {
    #[serde(default)]
    upstream: Option<String>,
    ahead: usize,
    behind: usize,
    diverged: bool,
    has_local_changes: bool,
    /// Strategy Git is explicitly configured for; `null` when unset.
    #[serde(default)]
    configured_strategy: Option<Strategy>,
}

impl Preflight {
    /// The history the user reviewed; a dirty flag alone never changes it.
    fn same_history(&self, other: &Self) -> bool {
        self.upstream == other.upstream
            && self.ahead == other.ahead
            && self.behind == other.behind
            && self.diverged == other.diverged
    }
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
/// `git.write` pull mode.
enum Strategy {
    FfOnly,
    Merge,
    Rebase,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// The user's answer to a `chooseStrategy` step.
struct Confirmation {
    strategy: Strategy,
    /// Inspection shown while the user chose.
    preflight: Preflight,
}

#[derive(Debug, Deserialize)]
#[serde(
    tag = "stage",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
enum Request {
    /// Chooses where and how a branch Update runs.
    Route {
        branch: Branch,
        worktrees: Vec<Worktree>,
    },
    /// Gates a pull in one checkout after Fetch and inspection.
    Inspect {
        preflight: Preflight,
        /// The user can be asked to choose a strategy for a diverged history.
        interactive: bool,
        /// The pull names its source instead of using the configured upstream,
        /// so upstream presence and "up to date" do not apply.
        #[serde(default)]
        explicit_source: bool,
        /// Strategy already chosen by the user, for example in a Pull dialog.
        #[serde(default)]
        strategy: Option<Strategy>,
        #[serde(default)]
        confirmation: Option<Confirmation>,
    },
    /// Picks the strategy a Pull dialog preselects before the user decides.
    DefaultStrategy {
        preflight: Preflight,
        /// The selected source can be fast-forwarded into the current branch.
        fast_forward_possible: bool,
    },
}

#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
/// Stable reason a step stops; hosts localize it.
enum Blocker {
    /// The branch or checkout has no configured upstream.
    NoUpstream,
    /// Tracked local changes would be mixed into the integration.
    LocalChanges,
    /// The upstream has nothing new.
    UpToDate,
    /// The history diverged and no one can be asked for a strategy.
    NotFastForward,
    /// The inspected history changed after the user confirmed a strategy.
    StateChanged,
}

#[derive(Debug, Serialize)]
#[serde(
    tag = "step",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
enum Plan {
    Blocked {
        blocker: Blocker,
    },
    /// Fast-forward the unchecked-out branch from its upstream with `updateBranch`.
    FastForwardReference {
        expected_branch: String,
    },
    /// Fetch in `checkout`, read `git.pullPreflight` there, then plan `inspect`.
    Inspect {
        /// Worktree path; `null` means the repository root of the request.
        checkout: Option<String>,
        expected_branch: String,
        upstream: String,
        /// Only the current worktree may ask the user for a strategy.
        interactive: bool,
    },
    /// Ask merge or rebase, then plan `inspect` again with a fresh preflight.
    ChooseStrategy,
    /// Run `pull` with this mode; Update passes its `expectedBranch` as well.
    Pull {
        strategy: Strategy,
    },
    /// The strategy a dialog preselects.
    DefaultStrategy {
        strategy: Strategy,
    },
}

fn invalid(message: &str) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, message)
}

/// Handles `git.updatePlan`.
pub(crate) fn command(payload: Value) -> Result<Value, CoreError> {
    let request: Request = serde_json::from_value(payload).map_err(|error| {
        invalid("Invalid Git update plan request").with_details(error.to_string())
    })?;
    let plan = match request {
        Request::Route { branch, worktrees } => route(branch, &worktrees)?,
        Request::Inspect {
            preflight,
            interactive,
            explicit_source,
            strategy,
            confirmation,
        } => inspect(
            &preflight,
            interactive,
            explicit_source,
            strategy,
            confirmation,
        )?,
        Request::DefaultStrategy {
            preflight,
            fast_forward_possible,
        } => Plan::DefaultStrategy {
            strategy: default_strategy(&preflight, fast_forward_possible),
        },
    };
    Ok(serde_json::to_value(plan).expect("Git update plan encodes"))
}

fn route(branch: Branch, worktrees: &[Worktree]) -> Result<Plan, CoreError> {
    if !branch.full_name.starts_with("refs/heads/") || branch.full_name == "refs/heads/" {
        return Err(invalid("Branch Update requires a complete local reference"));
    }
    if worktrees.len() > MAX_WORKTREES || worktrees.iter().any(|worktree| worktree.path.is_empty())
    {
        return Err(invalid("Invalid worktree facts"));
    }
    let Some(upstream) = branch.upstream.filter(|upstream| !upstream.is_empty()) else {
        return Ok(Plan::Blocked {
            blocker: Blocker::NoUpstream,
        });
    };
    let owner = worktrees
        .iter()
        .find(|worktree| worktree.branch.as_deref() == Some(branch.full_name.as_str()));
    // Git refuses to fetch into a branch any worktree has checked out, so such
    // a branch is pulled inside its own worktree instead.
    let plan = match owner {
        Some(worktree) => Plan::Inspect {
            checkout: Some(worktree.path.clone()),
            expected_branch: branch.full_name,
            upstream,
            interactive: worktree.is_current,
        },
        None if branch.is_current => Plan::Inspect {
            checkout: None,
            expected_branch: branch.full_name,
            upstream,
            interactive: true,
        },
        None => Plan::FastForwardReference {
            expected_branch: branch.full_name,
        },
    };
    Ok(plan)
}

fn inspect(
    preflight: &Preflight,
    interactive: bool,
    explicit_source: bool,
    strategy: Option<Strategy>,
    confirmation: Option<Confirmation>,
) -> Result<Plan, CoreError> {
    if confirmation.is_some() && (!interactive || strategy.is_some()) {
        return Err(invalid(
            "Only an interactive pull without a chosen strategy can be confirmed",
        ));
    }
    if confirmation
        .as_ref()
        .is_some_and(|confirmation| confirmation.strategy == Strategy::FfOnly)
    {
        return Err(invalid(
            "A diverged history is confirmed with merge or rebase",
        ));
    }
    let blocked = |blocker| Ok(Plan::Blocked { blocker });
    if !explicit_source && preflight.upstream.as_deref().is_none_or(str::is_empty) {
        return blocked(Blocker::NoUpstream);
    }
    if let Some(confirmation) = &confirmation {
        if !confirmation.preflight.same_history(preflight) {
            return blocked(Blocker::StateChanged);
        }
    }
    if preflight.has_local_changes {
        return blocked(Blocker::LocalChanges);
    }
    if !explicit_source && preflight.behind == 0 && !preflight.diverged {
        return blocked(Blocker::UpToDate);
    }
    if let Some(confirmation) = confirmation {
        return Ok(Plan::Pull {
            strategy: confirmation.strategy,
        });
    }
    // The user's choice wins over Git's configuration, which wins over the
    // fast-forward default.
    let resolved = strategy
        .or(preflight.configured_strategy)
        .unwrap_or(Strategy::FfOnly);
    match resolved {
        Strategy::Merge | Strategy::Rebase => Ok(Plan::Pull { strategy: resolved }),
        Strategy::FfOnly if !preflight.diverged => Ok(Plan::Pull {
            strategy: Strategy::FfOnly,
        }),
        Strategy::FfOnly if interactive => Ok(Plan::ChooseStrategy),
        Strategy::FfOnly => blocked(Blocker::NotFastForward),
    }
}

/// A dialog preselects the configured strategy, then fast-forward when the
/// source allows it, then merge, which never rewrites local commits.
fn default_strategy(preflight: &Preflight, fast_forward_possible: bool) -> Strategy {
    match preflight.configured_strategy {
        Some(Strategy::FfOnly) | None if fast_forward_possible => Strategy::FfOnly,
        Some(Strategy::FfOnly) | None => Strategy::Merge,
        Some(configured) => configured,
    }
}

#[cfg(test)]
mod tests {
    use serde_json::{json, Value};

    fn call(payload: Value) -> Value {
        serde_json::from_str(&crate::execute_json(
            &json!({"id":"update", "command":"git.updatePlan", "payload":payload}).to_string(),
        ))
        .unwrap()
    }

    #[test]
    fn shared_fixture_steps_are_the_only_update_rules() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/git/update-plan-v1.json"
        ))
        .unwrap();
        for case in fixture["cases"].as_array().unwrap() {
            let response = call(case["request"].clone());
            assert_eq!(response["ok"], true, "{}: {response}", case["name"]);
            assert_eq!(response["data"], case["plan"], "{}", case["name"]);
        }
        for case in fixture["invalid"].as_array().unwrap() {
            let response = call(case["request"].clone());
            assert_eq!(response["ok"], false, "{}", case["name"]);
        }
    }
}
