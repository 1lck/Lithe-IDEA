//! Shared workspace commit planning, guarded execution, and partial-success recovery.
// Decisions: .agents/notes/implemented/feature/2026-09-27-workspace-git-commit-plans.md

use super::{commit_state, GitCommitGitlink, GitCommitState, GitWriteRequest};
use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;
use std::time::Duration;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Platform binding for a workspace-relative repository identity.
pub struct RepositoryBinding {
    /// Relative path with `/` separators, including `..` for an enclosing repository.
    pub id: String,
    /// Native execution location; never used as a portable identifier.
    pub root: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
/// A mode-160000 index entry between two discovered repositories.
pub struct Relation {
    pub parent: String,
    pub child: String,
    /// Gitlink path relative to the parent repository.
    pub path: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Exact repositories, options, and Git state presented for review.
pub struct Plan {
    pub repositories: Vec<RepositoryBinding>,
    pub message: String,
    pub amend: bool,
    /// The only repository whose commit is rewritten when `amend` is set; every other
    /// repository in the plan receives a regular commit. Fixed when the plan is first
    /// built and carried through retries so a later staged state (for example the
    /// submodule pointer staged in a parent) cannot turn a regular commit into an
    /// amend. Absent for plans from clients that drop unknown fields; execution then
    /// falls back to amending the repository that has staged paths.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub amend_repository_id: Option<String>,
    pub push: bool,
    pub include_parent_references: bool,
    pub is_retry: bool,
    /// Child-before-parent order, preserving input order for independent roots.
    pub ordered_ids: Vec<String>,
    pub propagated_relations: Vec<Relation>,
    pub dependency_relations: Vec<Relation>,
    pub states: BTreeMap<String, GitCommitState>,
    pub committed_ids: BTreeSet<String>,
    pub pending_push_ids: BTreeSet<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Per-repository outcome; successful mutations are never rolled back as a batch.
pub struct RepositoryResult {
    pub committed: bool,
    pub pushed: bool,
    /// Stable presentation key, separate from optional Git diagnostics.
    pub status: String,
    pub detail: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
/// In-memory continuation returned unchanged by clients to the next step or retry.
/// It owns no native resources and is discarded when the workspace closes.
pub struct Session {
    pub plan: Plan,
    /// Last observed states, including successful commits and failed-hook index changes.
    pub states: BTreeMap<String, GitCommitState>,
    pub results: BTreeMap<String, RepositoryResult>,
    pub blocked: BTreeSet<String>,
    /// Next repository; a successful commit keeps this position for its separate push.
    pub cursor: usize,
    pub command_failed: bool,
    pub finished: bool,
    pub succeeded: bool,
    pub can_retry: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
/// The repository and HEAD whose message the client loaded for an amend.
pub struct AmendTarget {
    /// Workspace-relative identity of the repository that will be rewritten.
    pub repository_id: String,
    /// Full HEAD object ID the client read the message from.
    pub expected_head: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Builds a fresh plan; retry and reviewed snapshots are optional continuations.
pub struct PrepareRequest {
    pub repositories: Vec<RepositoryBinding>,
    pub message: String,
    #[serde(default)]
    pub amend: bool,
    /// Optional precondition for `amend`. Clients that omit it still get the
    /// single-repository rule, but not the HEAD check.
    #[serde(default)]
    pub amend_target: Option<AmendTarget>,
    #[serde(default)]
    pub push: bool,
    pub include_parent_references: bool,
    #[serde(default)]
    pub previous: Option<Session>,
    #[serde(default)]
    pub reviewed: Option<Plan>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
/// Review decision and initial continuation, both computed by Core.
pub struct Preparation {
    pub session: Session,
    pub review_changed: bool,
    pub requires_confirmation: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Executes at most one commit or push using a fresh host operation context.
pub struct StepRequest {
    pub session: Session,
}

fn invalid(message: &str) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, message)
}

fn validate_bindings(bindings: &[RepositoryBinding]) -> Result<(), CoreError> {
    let mut ids = BTreeSet::new();
    let mut roots = BTreeSet::new();
    for binding in bindings {
        if binding.id.is_empty()
            || binding.id.starts_with('/')
            || binding.id.contains('\\')
            || binding.id.contains('\0')
            || !ids.insert(&binding.id)
        {
            return Err(invalid(
                "Repository identifiers must be unique workspace-relative paths",
            ));
        }
        if binding.root.is_empty() || !roots.insert(Path::new(&binding.root)) {
            return Err(invalid("A repository cannot appear twice in a commit plan"));
        }
    }
    Ok(())
}

/// Inspects every discovered repository before calculating dependencies and retry scope.
pub fn prepare(mut request: PrepareRequest) -> Result<Preparation, CoreError> {
    for binding in &mut request.repositories {
        binding.root = super::validate_root(&binding.root)?;
    }
    validate_bindings(&request.repositories)?;
    let mut states = BTreeMap::new();
    for binding in &request.repositories {
        states.insert(
            binding.id.clone(),
            commit_state::inspect_root(&binding.root)?,
        );
    }
    build_plan(request, states)
}

fn build_plan(
    request: PrepareRequest,
    states: BTreeMap<String, GitCommitState>,
) -> Result<Preparation, CoreError> {
    let message = request.message.trim().to_string();
    if message.is_empty() {
        return Err(invalid("Enter a commit message"));
    }
    let previous = request.previous.as_ref();
    let mut results = previous.map(|s| s.results.clone()).unwrap_or_default();
    if let Some(previous) = previous {
        for id in &previous.plan.ordered_ids {
            let result = previous.results.get(id).cloned().unwrap_or_default();
            let unfinished = !result.committed || (request.push && !result.pushed);
            let binding = request.repositories.iter().find(|b| &b.id == id);
            if unfinished
                && (binding.is_none()
                    || binding != previous.plan.repositories.iter().find(|b| &b.id == id))
            {
                return Err(invalid("A repository with unfinished steps is no longer in this workspace. Restore it before retrying."));
            }
            if !result.committed
                && result.status != "outcomeUnknown"
                && states
                    .get(id)
                    .zip(previous.states.get(id))
                    .is_some_and(|(current, old)| current.head != old.head)
            {
                return Err(invalid("An unfinished repository HEAD changed. Inspect its history and dismiss the previous batch before starting a new commit."));
            }
            if result.status == "outcomeUnknown" {
                // A cancelled hook may finish the commit before its process exits.
                // Never repeat that commit merely because cleanup inspection failed.
                let current = states
                    .get(id)
                    .ok_or_else(|| invalid("Restore the repository before retrying"))?;
                if current.head != previous.states.get(id).and_then(|s| s.head.clone())
                    && current.head.is_some()
                {
                    results.entry(id.clone()).or_default().committed = true;
                }
            }
        }
    }
    let mut committed: BTreeSet<_> = results
        .iter()
        .filter(|(_, r)| r.committed)
        .map(|(id, _)| id.clone())
        .collect();
    let mut pending_push: BTreeSet<_> = results
        .iter()
        .filter(|(id, result)| {
            result.committed
                && states.contains_key(*id)
                && request.push
                && (!result.pushed
                    || previous
                        .and_then(|s| s.states.get(*id))
                        .zip(states.get(*id))
                        .is_none_or(|(old, new)| old.head != new.head || old.branch != new.branch))
        })
        .map(|(id, _)| id.clone())
        .collect();
    let mut selected: BTreeSet<_> = states
        .iter()
        .filter(|(id, state)| !committed.contains(*id) && !state.staged_paths.is_empty())
        .map(|(id, _)| id.clone())
        .collect();
    selected.extend(pending_push.iter().cloned());
    let relations = relations(&request.repositories, &states)?;
    let previously_propagated = |relation: &Relation| {
        previous.is_some_and(|s| s.plan.propagated_relations.contains(relation))
    };
    if request.include_parent_references {
        for relation in &relations {
            if committed.contains(&relation.child)
                && previously_propagated(relation)
                && !committed.contains(&relation.parent)
            {
                selected.insert(relation.parent.clone());
            }
        }
        loop {
            let before = selected.len();
            for relation in &relations {
                if selected.contains(&relation.child) && !committed.contains(&relation.parent) {
                    selected.insert(relation.parent.clone());
                }
            }
            if before == selected.len() {
                break;
            }
        }
    }
    if selected.is_empty() {
        return Err(invalid("Stage at least one change before committing"));
    }
    let amend_repository_id = resolve_amend_repository(&request, &states, &selected, &committed)?;
    let propagation: Vec<_> = relations
        .iter()
        .filter(|r| {
            ((selected.contains(&r.child) && !committed.contains(&r.child))
                || previously_propagated(r))
                && selected.contains(&r.parent)
                && !committed.contains(&r.parent)
                && (request.include_parent_references
                    || states[&r.parent].staged_paths.contains(&r.path))
        })
        .cloned()
        .collect();
    let mut dependencies = propagation.clone();
    if request.push {
        // Iterate to a fixed point: a push-only child can itself reference a grandchild.
        loop {
            let before = selected.len();
            for relation in &relations {
                if selected.contains(&relation.parent)
                    && (states[&relation.parent]
                        .staged_paths
                        .contains(&relation.path)
                        || previous.is_some_and(|s| s.plan.dependency_relations.contains(relation)))
                    && states[&relation.child].branch.is_some()
                {
                    if selected.insert(relation.child.clone()) {
                        committed.insert(relation.child.clone());
                        pending_push.insert(relation.child.clone());
                    }
                    if !dependencies.contains(relation) {
                        dependencies.push(relation.clone());
                    }
                }
            }
            if before == selected.len() {
                break;
            }
        }
    }
    let order = commit_order(
        request
            .repositories
            .iter()
            .filter(|b| selected.contains(&b.id))
            .map(|b| b.id.clone())
            .collect(),
        &dependencies,
    )?;
    let plan = Plan {
        repositories: request.repositories,
        message,
        amend: request.amend,
        amend_repository_id,
        push: request.push,
        include_parent_references: request.include_parent_references,
        is_retry: previous.is_some(),
        ordered_ids: order,
        propagated_relations: propagation,
        dependency_relations: dependencies,
        states: states.clone(),
        committed_ids: committed,
        pending_push_ids: pending_push,
    };
    let review_changed = request
        .reviewed
        .as_ref()
        .is_some_and(|reviewed| reviewed != &plan);
    let requires_confirmation = plan.is_retry || !plan.dependency_relations.is_empty();
    for id in &plan.ordered_ids {
        let result = results.entry(id.clone()).or_default();
        result.committed = plan.committed_ids.contains(id);
        if plan.pending_push_ids.contains(id) {
            result.pushed = false;
        }
        result.status = "pending".into();
        result.detail.clear();
    }
    for (id, result) in &mut results {
        if !plan.ordered_ids.contains(id) && !result.committed {
            result.status = "notIncluded".into();
            result.detail.clear();
        }
    }
    Ok(Preparation {
        session: Session {
            plan,
            states,
            results,
            blocked: BTreeSet::new(),
            cursor: 0,
            command_failed: false,
            finished: false,
            succeeded: false,
            can_retry: true,
        },
        review_changed,
        requires_confirmation,
    })
}

/// Repositories that would be committed with staged changes, and so amended.
/// Parent repositories pulled in only to record a submodule pointer have no
/// staged paths of their own and receive a regular commit.
fn amended_candidates<'a>(
    states: &'a BTreeMap<String, GitCommitState>,
    selected: &'a BTreeSet<String>,
    committed: &'a BTreeSet<String>,
) -> impl Iterator<Item = &'a String> {
    selected.iter().filter(move |id| {
        !committed.contains(*id)
            && states
                .get(*id)
                .is_some_and(|state| !state.staged_paths.is_empty())
    })
}

/// Decides which repository an amend rewrites. An amend rewrites a commit that the
/// client showed the user, so it must be bound to one repository. Core re-reads every
/// repository when it prepares, so a repository staged outside the UI after the message
/// was loaded would otherwise be rewritten with another repository's message.
///
/// A retry keeps the repository chosen by the first plan. Re-deriving it from the
/// current index would be wrong: after a child amend succeeds and the parent's commit
/// fails, the parent holds a staged submodule pointer and would be amended instead of
/// receiving the new commit the user confirmed.
fn resolve_amend_repository(
    request: &PrepareRequest,
    states: &BTreeMap<String, GitCommitState>,
    selected: &BTreeSet<String>,
    committed: &BTreeSet<String>,
) -> Result<Option<String>, CoreError> {
    if !request.amend {
        return Ok(None);
    }
    let multiple = || {
        invalid(
            "Amend rewrites one repository at a time. Unstage the other repositories or turn Amend off.",
        )
    };
    let carried = request
        .previous
        .as_ref()
        .filter(|previous| previous.plan.amend)
        .and_then(|previous| previous.plan.amend_repository_id.clone());
    let requested = request.amend_target.as_ref();
    if let (Some(carried), Some(requested)) = (&carried, requested) {
        if carried != &requested.repository_id {
            return Err(invalid(
                "The repository to amend changed since the first attempt. Dismiss the previous batch and start again.",
            ));
        }
    }
    let target = carried.or_else(|| requested.map(|r| r.repository_id.clone()));
    if let Some(target) = &target {
        let state = states.get(target).ok_or_else(|| {
            invalid("The repository to amend is not part of this workspace commit")
        })?;
        // A retry after the amend itself succeeded sees the rewritten HEAD. Without an
        // expected HEAD (a retry) the unfinished-HEAD check in `build_plan` applies.
        if let Some(requested) = requested {
            if !committed.contains(target)
                && state.head.as_deref() != Some(requested.expected_head.as_str())
            {
                return Err(invalid(
                    "The commit to amend changed after its message was loaded. Reload the message and try again.",
                ));
            }
        }
    }
    // The scope check applies to a plan that has not fixed its repository yet. A
    // continuing plan amends only its recorded repository, so other repositories with
    // staged paths simply receive regular commits.
    let continuing = request
        .previous
        .as_ref()
        .is_some_and(|previous| previous.plan.amend && previous.plan.amend_repository_id.is_some());
    let mut candidates = amended_candidates(states, selected, committed);
    if continuing {
        return Ok(target);
    }
    match target {
        Some(target) => {
            if candidates.any(|id| id != &target) {
                return Err(multiple());
            }
            Ok(Some(target))
        }
        None => {
            let first = candidates.next().cloned();
            if candidates.next().is_some() {
                return Err(multiple());
            }
            Ok(first)
        }
    }
}

/// Whether the commit step for `id` is an amend. The recorded repository decides when
/// the plan has one; plans without it keep amending the repository that has staged
/// paths, which `validate_session` limits to one.
fn amends_repository(plan: &Plan, id: &str, expected: &GitCommitState) -> bool {
    plan.amend
        && !expected.staged_paths.is_empty()
        && plan
            .amend_repository_id
            .as_deref()
            .is_none_or(|recorded| recorded == id)
}

fn relations(
    bindings: &[RepositoryBinding],
    states: &BTreeMap<String, GitCommitState>,
) -> Result<Vec<Relation>, CoreError> {
    let mut relations = Vec::new();
    for parent in bindings {
        for link in &states[&parent.id].gitlinks {
            super::validate_paths(std::slice::from_ref(&link.path))?;
            let target = Path::new(&parent.root).join(&link.path);
            if let Some(child) = bindings
                .iter()
                .find(|b| b.id != parent.id && Path::new(&b.root) == target)
            {
                relations.push(Relation {
                    parent: parent.id.clone(),
                    child: child.id.clone(),
                    path: link.path.clone(),
                });
            }
        }
    }
    Ok(relations)
}

fn commit_order(
    mut remaining: Vec<String>,
    relations: &[Relation],
) -> Result<Vec<String>, CoreError> {
    let mut ordered = Vec::new();
    while !remaining.is_empty() {
        let index = remaining
            .iter()
            .position(|candidate| {
                !relations
                    .iter()
                    .any(|r| &r.parent == candidate && remaining.contains(&r.child))
            })
            .ok_or_else(|| invalid("Cyclic repository dependencies cannot be committed"))?;
        ordered.push(remaining.remove(index));
    }
    Ok(ordered)
}

fn block_parents(session: &mut Session, child: &str) {
    let mut children = vec![child.to_string()];
    while let Some(child) = children.pop() {
        for relation in &session.plan.dependency_relations {
            if relation.child == child && session.blocked.insert(relation.parent.clone()) {
                children.push(relation.parent.clone());
            }
        }
    }
}

fn fail(session: &mut Session, id: &str, status: &str, detail: String) {
    let result = session.results.entry(id.into()).or_default();
    result.status = status.into();
    result.detail = detail;
    session.command_failed = true;
    block_parents(session, id);
    session.cursor += 1;
}

fn finish(session: &mut Session) {
    session.finished = session.cursor >= session.plan.ordered_ids.len();
    session.can_retry = session.plan.ordered_ids.iter().any(|id| {
        session
            .results
            .get(id)
            .is_none_or(|r| !r.committed || (session.plan.push && !r.pushed))
    });
    session.succeeded = session.finished && !session.command_failed && !session.can_retry;
}

/// Runs one mutation, reconciles its outcome even after cancellation, and returns
/// the continuation. The caller supplies a fresh operation ID for each next step.
pub fn step(request: StepRequest) -> Result<Session, CoreError> {
    let mut session = request.session;
    validate_session(&session)?;
    if session.finished {
        return Ok(session);
    }
    let id = session.plan.ordered_ids[session.cursor].clone();
    if session.blocked.contains(&id) {
        fail(&mut session, &id, "waitingForSubmodule", String::new());
        finish(&mut session);
        return Ok(session);
    }
    let root = session
        .plan
        .repositories
        .iter()
        .find(|b| b.id == id)
        .unwrap()
        .root
        .clone();
    let expected = session.states.get(&id).cloned();
    let preparation = prepare_step(&session, &id, &root);
    let write = match preparation {
        Ok(Some(write)) => write,
        Ok(None) => {
            session.cursor += 1;
            finish(&mut session);
            return Ok(session);
        }
        Err(error) => {
            fail(&mut session, &id, "reviewRequired", error.message);
            finish(&mut session);
            return Ok(session);
        }
    };
    let committing = write.operation == "commit";
    let result = super::write(write);
    let succeeded = result
        .as_ref()
        .is_ok_and(|r| r.exit_code == 0 && r.operation_error.is_none());
    let detail = match &result {
        Ok(r) => r
            .operation_error
            .as_ref()
            .map(|e| e.message.clone())
            .unwrap_or_else(|| r.output.trim().to_string()),
        Err(e) => e.message.clone(),
    };
    if committing {
        // Read-only cleanup has its own bounded deadline, preserving a commit
        // that completed just before cancellation without starting another write.
        let after =
            crate::protocol::cancellation::with_cleanup_deadline(Duration::from_secs(5), || {
                commit_state::inspect_root(&root)
            });
        let advanced = after.as_ref().is_ok_and(|s| {
            s.head.is_some() && s.head != expected.as_ref().and_then(|e| e.head.clone())
        });
        if let Ok(after) = &after {
            session.states.insert(id.clone(), after.clone());
        }
        let outcome = session.results.get_mut(&id).unwrap();
        outcome.committed = succeeded || advanced;
        outcome.status = if session.plan.push {
            "committedPushPending"
        } else {
            "committed"
        }
        .into();
        if !succeeded || after.is_err() {
            let status = if after.is_err() {
                "outcomeUnknown"
            } else if advanced {
                "headAdvanced"
            } else {
                "commitFailed"
            };
            fail(
                &mut session,
                &id,
                status,
                if let Err(error) = after {
                    error.message
                } else {
                    detail
                },
            );
        } else if !session.plan.push {
            session.cursor += 1;
        }
    } else {
        let outcome = session.results.get_mut(&id).unwrap();
        outcome.pushed = succeeded;
        outcome.status = "committedAndPushed".into();
        if succeeded {
            session.cursor += 1;
        } else {
            fail(&mut session, &id, "pushFailed", detail);
        }
    }
    finish(&mut session);
    Ok(session)
}

fn validate_session(session: &Session) -> Result<(), CoreError> {
    validate_bindings(&session.plan.repositories)?;
    let ids: BTreeSet<_> = session.plan.repositories.iter().map(|b| &b.id).collect();
    let order: BTreeSet<_> = session.plan.ordered_ids.iter().collect();
    if order.len() != session.plan.ordered_ids.len()
        || !order.is_subset(&ids)
        || session.cursor > order.len()
        || (!session.finished && session.cursor == order.len())
        || order
            .iter()
            .any(|id| !session.states.contains_key(*id) || !session.results.contains_key(*id))
        || session
            .plan
            .dependency_relations
            .iter()
            .chain(&session.plan.propagated_relations)
            .any(|r| !ids.contains(&r.parent) || !ids.contains(&r.child))
    {
        return Err(invalid("Invalid workspace commit continuation"));
    }
    if let Some(recorded) = &session.plan.amend_repository_id {
        if !session.plan.amend || !ids.contains(recorded) {
            return Err(invalid("Invalid workspace commit continuation"));
        }
    }
    // Without a recorded repository, step amends every repository with staged changes,
    // so a continuation that spans several of them must not have been planned as an amend.
    let planned: BTreeSet<_> = session.plan.ordered_ids.iter().cloned().collect();
    if session.plan.amend
        && session.plan.amend_repository_id.is_none()
        && amended_candidates(&session.plan.states, &planned, &session.plan.committed_ids).count()
            > 1
    {
        return Err(invalid("Invalid workspace commit continuation"));
    }
    if commit_order(
        session.plan.ordered_ids.clone(),
        &session.plan.dependency_relations,
    )? != session.plan.ordered_ids
    {
        return Err(invalid(
            "Workspace commit dependencies must precede their parents",
        ));
    }
    Ok(())
}

fn prepare_step(
    session: &Session,
    id: &str,
    root: &str,
) -> Result<Option<GitWriteRequest>, CoreError> {
    let expected = &session.states[id];
    if commit_state::inspect_root(root)? != *expected {
        return Err(invalid("Repository changed; review and retry"));
    }
    let mut request = GitWriteRequest {
        root: root.into(),
        expected_commit_state: Some(expected.clone()),
        ..Default::default()
    };
    if !session.results[id].committed {
        if !expected.conflicted_paths.is_empty() {
            return Err(invalid("Resolve conflicts before committing"));
        }
        let markers = super::staged_conflict_marker_paths(root)?;
        if !markers.is_empty() {
            return Err(invalid(&format!(
                "Resolve conflict markers: {}",
                markers.join(", ")
            )));
        }
        for relation in session
            .plan
            .propagated_relations
            .iter()
            .filter(|r| r.parent == id)
        {
            let child = session
                .plan
                .repositories
                .iter()
                .find(|b| b.id == relation.child)
                .unwrap();
            let actual = commit_state::inspect_root(&child.root)?;
            if !session.results.get(&child.id).is_some_and(|r| r.committed)
                || actual.head.is_none()
                || actual.head != session.states.get(&child.id).and_then(|s| s.head.clone())
            {
                return Err(invalid("Submodule changed; review and retry"));
            }
            request.gitlink_updates.push(GitCommitGitlink {
                path: relation.path.clone(),
                revision: actual.head.unwrap(),
            });
        }
        request.operation = "commit".into();
        request.message = Some(session.plan.message.clone());
        request.amend = amends_repository(&session.plan, id, expected);
    } else if session.plan.push && !session.results[id].pushed {
        request.operation = "push".into();
        request.reference = Some(expected.branch.clone().ok_or_else(|| {
            invalid("Committed; branch changed or detached. Review and retry push.")
        })?);
        request.check_submodules = true;
    } else {
        return Ok(None);
    }
    Ok(Some(request))
}

#[cfg(test)]
mod tests;
