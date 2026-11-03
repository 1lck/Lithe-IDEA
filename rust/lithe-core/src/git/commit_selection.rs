//! Prepares the real index for an explicitly selected set of changed files.

use super::{
    commit_state, execute_git_readonly_with_environment, is_safe_pathspec, parse_status,
    pathspec_batches, rewrite::RewriteLease, stage_paths, unstage_paths, validate_root,
    LS_FILES_PATHSPEC_BUDGET,
};
use crate::protocol::{CoreError, ErrorCode, GitChange};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

const MAX_REPOSITORIES: usize = 128;
const MAX_SELECTION: usize = 10_000;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Request {
    repositories: Vec<Repository>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Repository {
    root: String,
    selected: Vec<Selected>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Selected {
    path: String,
    original_path: Option<String>,
    status: String,
}

fn invalid(message: &'static str) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, message)
}
fn stale() -> CoreError {
    invalid("GIT_COMMIT_SELECTION_STALE")
}
fn safe(path: &str) -> bool {
    is_safe_pathspec(path) && !path.contains('\0')
}
struct Snapshot {
    changes: Vec<GitChange>,
    expanded: BTreeMap<String, Vec<String>>,
}

// Managed Git processes honour cancellation. Untracked enumeration is scoped
// to selected paths, so a large unrelated directory does not delay the action.
fn snapshot(
    root: &str,
    roots: &[String],
    selected: &[Selected],
    state: &commit_state::GitCommitState,
) -> Result<Snapshot, CoreError> {
    let literal = [("GIT_LITERAL_PATHSPECS".to_string(), "1".to_string())];
    let tracked_args = [
        "status",
        "--porcelain=v2",
        "--ignore-submodules=none",
        "-z",
        "--untracked-files=no",
    ]
    .map(str::to_string);
    let tracked = execute_git_readonly_with_environment(root, &tracked_args, None, &literal)?;
    if tracked.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Could not inspect Git status")
                .with_details(tracked.output),
        );
    }
    let mut changes = parse_status(tracked.stdout.as_bytes(), true);
    let tracked_paths: BTreeSet<String> =
        changes.iter().map(|change| change.path.clone()).collect();
    let gitlinks: BTreeSet<String> = changes
        .iter()
        .filter(|change| change.submodule.is_some())
        .map(|change| change.path.clone())
        .collect();
    let indexed_paths: BTreeSet<&str> = state
        .index_entries
        .split('\0')
        .filter_map(|entry| entry.split_once('\t').map(|(_, path)| path))
        .collect();
    let paths: Vec<String> = selected
        .iter()
        .filter(|item| item.status == "??")
        .map(|item| item.path.clone())
        .collect();
    for item in selected {
        let target = Path::new(root).join(&item.path);
        let tracked_gitlink = gitlinks.contains(&item.path);
        if roots.iter().any(|other| {
            other != root
                && target.starts_with(other)
                && (target != Path::new(other) || item.status == "??" || !tracked_gitlink)
        }) {
            return Err(stale());
        }
        if item.path.ends_with('/')
            && roots
                .iter()
                .any(|other| other != root && Path::new(other).starts_with(&target))
        {
            return Err(stale());
        }
        if item.status == "??" && item.path.ends_with('/') {
            if indexed_paths
                .range(item.path.as_str()..)
                .next()
                .is_some_and(|path| path.starts_with(&item.path))
                || tracked_paths
                    .range(item.path.clone()..)
                    .next()
                    .is_some_and(|path| path.starts_with(&item.path))
            {
                return Err(stale());
            }
        }
    }
    let mut observed = BTreeSet::new();
    for batch in pathspec_batches(&paths, LS_FILES_PATHSPEC_BUDGET) {
        let mut args = vec![
            "status".into(),
            "--porcelain=v2".into(),
            "-z".into(),
            "--untracked-files=all".into(),
            "--".into(),
        ];
        args.extend_from_slice(batch);
        let result = execute_git_readonly_with_environment(root, &args, None, &literal)?;
        if result.exit_code != 0 {
            return Err(CoreError::new(
                ErrorCode::ProcessFailed,
                "Could not inspect selected Git paths",
            )
            .with_details(result.output));
        }
        for change in parse_status(result.stdout.as_bytes(), true) {
            if change.untracked {
                observed.insert(change.path);
            }
        }
    }
    let mut expanded = BTreeMap::new();
    for item in selected.iter().filter(|item| item.status == "??") {
        if item.original_path.is_some() {
            return Err(stale());
        }
        let files: Vec<String> = if item.path.ends_with('/') {
            observed
                .range(item.path.clone()..)
                .take_while(|path| path.starts_with(&item.path))
                .cloned()
                .collect()
        } else if observed.contains(&item.path) {
            vec![item.path.clone()]
        } else {
            Vec::new()
        };
        // Git reports an embedded independent repository as an untracked path
        // ending in '/'; never turn it into a gitlink through a directory add.
        if files.is_empty()
            || files.iter().any(|path| path.ends_with('/'))
            || tracked_paths.contains(&item.path)
        {
            return Err(stale());
        }
        if item.path.ends_with('/') {
            expanded.insert(item.path.clone(), files);
        }
        changes.push(GitChange {
            path: item.path.clone(),
            original_path: None,
            status: "??".into(),
            staged: false,
            worktree: false,
            untracked: true,
            submodule: None,
            can_toggle_staging: true,
            untracked_file_count: item.path.ends_with('/').then_some(1),
        });
    }
    Ok(Snapshot { changes, expanded })
}
fn conflict(change: &GitChange) -> bool {
    change.status.contains('U') || change.status == "AA" || change.status == "DD"
}
fn validate_selected(selected: &[Selected], changes: &[GitChange]) -> Result<(), CoreError> {
    let mut records: BTreeMap<&str, Vec<&GitChange>> = BTreeMap::new();
    for change in changes {
        records.entry(&change.path).or_default().push(change);
    }
    for item in selected {
        let found = records.get(item.path.as_str()).is_some_and(|rows| {
            rows.iter().any(|change| {
                change.original_path == item.original_path
                    && change.status == item.status
                    && change.can_toggle_staging
                    && !conflict(change)
            })
        });
        if !found {
            return Err(stale());
        }
    }
    Ok(())
}

fn steps(
    selected: &[Selected],
    changes: &[GitChange],
    expanded: &BTreeMap<String, Vec<String>>,
) -> Result<(Vec<String>, Vec<String>), CoreError> {
    let chosen: BTreeSet<_> = selected.iter().map(|item| item.path.as_str()).collect();
    let mut excluded = BTreeSet::new();
    for change in changes
        .iter()
        .filter(|change| change.staged && !chosen.contains(change.path.as_str()))
    {
        if conflict(change) {
            return Err(stale());
        }
        excluded.insert(change.path.clone());
        if !change.status.contains('C') {
            if let Some(source) = &change.original_path {
                if chosen.contains(source.as_str()) {
                    return Err(stale());
                }
                excluded.insert(source.clone());
            }
        }
    }
    let staged: BTreeSet<_> = changes
        .iter()
        .filter(|change| change.staged)
        .map(|change| change.path.as_str())
        .collect();
    let mut included = BTreeSet::new();
    for item in selected {
        if !staged.contains(item.path.as_str()) {
            if let Some(files) = expanded.get(&item.path) {
                included.extend(files.iter().cloned());
            } else {
                included.insert(item.path.clone());
            }
            if !item.status.contains('C') {
                if let Some(source) = &item.original_path {
                    included.insert(source.clone());
                }
            }
        }
    }
    if included.iter().any(|path| excluded.contains(path)) {
        return Err(stale());
    }
    Ok((
        excluded.into_iter().collect(),
        included.into_iter().collect(),
    ))
}
fn verify(
    selected: &[Selected],
    staged_paths: &[String],
    expanded: &BTreeMap<String, Vec<String>>,
) -> Result<(), CoreError> {
    let mut expected = BTreeSet::new();
    for item in selected {
        if let Some(files) = expanded.get(&item.path) {
            expected.extend(files.iter().cloned());
        } else {
            expected.insert(item.path.clone());
        }
        // Git's no-renames index view reports both sides of a rename; copies
        // must not claim or modify their independent source.
        if item.status.contains('R') && !item.status.contains('C') {
            if let Some(source) = &item.original_path {
                expected.insert(source.clone());
            }
        }
    }
    let staged: BTreeSet<_> = staged_paths.iter().cloned().collect();
    if staged != expected {
        return Err(stale());
    }
    Ok(())
}

// Preserve the object IDs and conflict stages of every selected path that was
// already staged. Path equality alone would miss a concurrently replaced hunk.
fn verify_preserved_index(
    initial: &str,
    final_index: &str,
    paths: &BTreeSet<String>,
) -> Result<(), CoreError> {
    if paths.is_empty() {
        return Ok(());
    }
    fn entries<'a>(index: &'a str, paths: &BTreeSet<String>) -> BTreeMap<&'a str, Vec<&'a str>> {
        let mut result: BTreeMap<&str, Vec<&str>> = BTreeMap::new();
        for record in index.split('\0').filter(|record| !record.is_empty()) {
            if let Some((_, path)) = record.split_once('\t') {
                if paths.contains(path) {
                    result.entry(path).or_default().push(record);
                }
            }
        }
        result
    }
    let before = entries(initial, paths);
    let after = entries(final_index, paths);
    if paths
        .iter()
        .any(|path| before.get(path.as_str()) != after.get(path.as_str()))
    {
        return Err(stale());
    }
    Ok(())
}

/// Rechecks every repository, prepares each index under its Git lease, then verifies the result.
pub(crate) fn prepare_commit_selection_command(payload: Value) -> Result<Value, CoreError> {
    let mut request: Request = serde_json::from_value(payload).map_err(|_| stale())?;
    if request.repositories.is_empty()
        || request.repositories.len() > MAX_REPOSITORIES
        || request
            .repositories
            .iter()
            .map(|repo| repo.selected.len())
            .sum::<usize>()
            > MAX_SELECTION
        || request
            .repositories
            .iter()
            .all(|repo| repo.selected.is_empty())
    {
        return Err(stale());
    }
    let mut roots = BTreeSet::new();
    for repo in &mut request.repositories {
        repo.root = validate_root(&repo.root)?;
        if !roots.insert(repo.root.clone()) {
            return Err(stale());
        }
        let mut paths = BTreeSet::new();
        if repo.selected.iter().any(|item| {
            !safe(&item.path)
                || item
                    .original_path
                    .as_deref()
                    .is_some_and(|path| !safe(path))
                || !paths.insert(item.path.clone())
        }) {
            return Err(stale());
        }
        // A summary and its descendants describe overlapping scopes; callers
        // must collapse them before preparation so verification is unambiguous.
        let mut directory: Option<&str> = None;
        for path in &paths {
            if directory.is_some_and(|parent| path.starts_with(parent)) {
                return Err(stale());
            }
            directory = path.ends_with('/').then_some(path.as_str());
        }
    }
    let roots: Vec<_> = roots.into_iter().collect();
    // A single-root request can hold its lease throughout preflight and writes,
    // avoiding a second complete index/status scan on the common path.
    let single_lease = if request.repositories.len() == 1 {
        Some(RewriteLease::acquire(&request.repositories[0].root)?)
    } else {
        None
    };
    let mut states = BTreeMap::new();
    let mut planned_steps = BTreeMap::new();
    let mut expected_expansions = BTreeMap::new();
    let mut preserved_paths = BTreeMap::new();
    for repo in &request.repositories {
        crate::protocol::cancellation::check()?;
        let state = commit_state::inspect_root(&repo.root)?;
        let snapshot = snapshot(&repo.root, &roots, &repo.selected, &state)?;
        validate_selected(&repo.selected, &snapshot.changes)?;
        let planned = steps(&repo.selected, &snapshot.changes, &snapshot.expanded)?;
        planned_steps.insert(repo.root.clone(), planned);
        let chosen: BTreeSet<_> = repo
            .selected
            .iter()
            .map(|item| item.path.as_str())
            .collect();
        preserved_paths.insert(
            repo.root.clone(),
            snapshot
                .changes
                .iter()
                .filter(|change| change.staged && chosen.contains(change.path.as_str()))
                .map(|change| change.path.clone())
                .collect::<BTreeSet<_>>(),
        );
        expected_expansions.insert(repo.root.clone(), snapshot.expanded);
        states.insert(repo.root.clone(), state);
    }
    for repo in &request.repositories {
        crate::protocol::cancellation::check()?;
        let _lease = if single_lease.is_none() {
            Some(RewriteLease::acquire(&repo.root)?)
        } else {
            None
        };
        let (excluded, included) = if single_lease.is_some() {
            planned_steps.remove(&repo.root).ok_or_else(stale)?
        } else {
            let state = commit_state::inspect_root(&repo.root)?;
            if states.get(&repo.root) != Some(&state) {
                return Err(stale());
            }
            let snapshot = snapshot(&repo.root, &roots, &repo.selected, &state)?;
            validate_selected(&repo.selected, &snapshot.changes)?;
            if expected_expansions.get(&repo.root) != Some(&snapshot.expanded) {
                return Err(stale());
            }
            steps(&repo.selected, &snapshot.changes, &snapshot.expanded)?
        };
        for (paths, operation) in [
            (&excluded, unstage_paths as fn(&str, &[String]) -> _),
            (&included, stage_paths),
        ] {
            if paths.is_empty() {
                continue;
            }
            crate::protocol::cancellation::check()?;
            let result = operation(&repo.root, paths)?;
            if result.exit_code != 0 {
                return Err(CoreError::new(
                    ErrorCode::ProcessFailed,
                    "Could not prepare selected Git files",
                )
                .with_details(result.output));
            }
        }
    }
    for repo in &request.repositories {
        crate::protocol::cancellation::check()?;
        let state = commit_state::inspect_root(&repo.root)?;
        let expanded = expected_expansions.get(&repo.root).ok_or_else(stale)?;
        let initial = states.get(&repo.root).ok_or_else(stale)?;
        if initial.head != state.head || initial.branch != state.branch {
            return Err(stale());
        }
        verify(&repo.selected, &state.staged_paths, expanded)?;
        verify_preserved_index(
            &initial.index_entries,
            &state.index_entries,
            preserved_paths.get(&repo.root).ok_or_else(stale)?,
        )?;
    }
    Ok(json!({"prepared":true}))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn verification_rejects_replaced_selected_index_content() {
        let selected = BTreeSet::from(["selected.txt".to_string()]);
        let before = "100644 abc 0\tselected.txt\0";
        assert!(verify_preserved_index(before, before, &selected).is_ok());
        assert!(verify_preserved_index(before, "100644 def 0\tselected.txt\0", &selected).is_err());
    }

    #[test]
    fn verification_rejects_newly_staged_files_inside_a_selected_directory() {
        let selected = vec![Selected {
            path: "dir/".into(),
            original_path: None,
            status: "??".into(),
        }];
        let expanded = BTreeMap::from([("dir/".into(), vec!["dir/reviewed.txt".into()])]);
        assert!(verify(&selected, &["dir/reviewed.txt".into()], &expanded).is_ok());
        assert!(verify(
            &selected,
            &["dir/reviewed.txt".into(), "dir/later.txt".into()],
            &expanded
        )
        .is_err());
    }

    #[test]
    fn shared_fixture_plans_without_overwriting_selected_index_content() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/git/commit-selection-plan-v1.json"
        ))
        .unwrap();
        for case in fixture["cases"].as_array().unwrap() {
            let selected: Vec<Selected> = serde_json::from_value(case["selected"].clone()).unwrap();
            let changes = case["changes"]
                .as_array()
                .unwrap()
                .iter()
                .map(|item| {
                    let status = item["status"].as_str().unwrap().to_string();
                    GitChange {
                        path: item["path"].as_str().unwrap().into(),
                        original_path: item["originalPath"].as_str().map(str::to_string),
                        staged: !status.starts_with([' ', '?']),
                        worktree: !status.ends_with([' ', '?']),
                        untracked: status == "??",
                        status,
                        submodule: None,
                        can_toggle_staging: true,
                        untracked_file_count: None,
                    }
                })
                .collect::<Vec<_>>();
            let (unstage, stage) = steps(&selected, &changes, &BTreeMap::new()).unwrap();
            assert_eq!(json!(unstage), case["unstage"], "{}", case["name"]);
            assert_eq!(json!(stage), case["stage"], "{}", case["name"]);
        }
    }
}
