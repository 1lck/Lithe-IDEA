//! Real-Git workspace commit regressions, isolated by the timed Rust harness.

use super::support::temporary_root;
use crate::execute_json;
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};

struct Repository(PathBuf);
impl Drop for Repository {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn request(root: &Path, command: &str, mut payload: Value) -> Value {
    payload["root"] = json!(root);
    serde_json::from_str(&execute_json(
        &json!({"id":"workspace-commit-test", "command":command, "payload":payload}).to_string(),
    ))
    .unwrap()
}

fn git(root: &Path, arguments: &[&str]) -> String {
    // The shared host owns the subprocess deadline and process-tree cleanup.
    let response = request(root, "git.command", json!({"arguments": arguments}));
    assert_eq!(response["ok"], true, "{response}");
    assert_eq!(response["data"]["exitCode"], 0, "{arguments:?}: {response}");
    response["data"]["stdout"].as_str().unwrap().to_string()
}

fn init(root: &Path) {
    fs::create_dir_all(root).unwrap();
    git(root, &["init", "-q"]);
    git(root, &["config", "user.name", "Workspace Test"]);
    git(root, &["config", "user.email", "workspace@example.invalid"]);
    git(root, &["config", "commit.gpgsign", "false"]);
    git(root, &["config", "core.autocrlf", "false"]);
}

fn repository(name: &str) -> Repository {
    let result = Repository(temporary_root(name));
    init(&result.0);
    result
}

fn state(root: &Path) -> Value {
    let result = request(root, "git.commitState", json!({}));
    assert_eq!(result["ok"], true, "{result}");
    result["data"].clone()
}

#[test]
fn git_workspace_commit_rejects_a_changed_index_before_writing() {
    let repo = repository("workspace-commit-stale");
    fs::write(repo.0.join("first.txt"), "first").unwrap();
    git(&repo.0, &["add", "first.txt"]);
    let expected = state(&repo.0);
    assert!(expected["head"].is_null());
    fs::write(repo.0.join("second.txt"), "second").unwrap();
    git(&repo.0, &["add", "second.txt"]);
    let result = request(
        &repo.0,
        "git.write",
        json!({"operation":"commit", "message":"reviewed", "expectedCommitState":expected}),
    );
    assert_eq!(
        result["data"]["operationError"]["code"], "invalid_request",
        "{result}"
    );
    assert!(state(&repo.0)["head"].is_null());
    assert_eq!(
        git(&repo.0, &["diff", "--cached", "--name-only"]),
        "first.txt\nsecond.txt\n"
    );
}

#[test]
fn git_workspace_commit_distinguishes_child_dirt_and_updates_only_the_gitlink() {
    let repo = repository("workspace-commit-submodule");
    let child = repo.0.join("libs/B");
    init(&child);
    fs::write(child.join("hello.ts"), "one").unwrap();
    git(&child, &["add", "hello.ts"]);
    git(&child, &["commit", "-qm", "child initial"]);
    fs::write(repo.0.join("parent.txt"), "parent one").unwrap();
    fs::write(
        repo.0.join(".gitmodules"),
        "[submodule \"B\"]\npath = libs/B\nurl = ./libs/B\n",
    )
    .unwrap();
    git(&repo.0, &["add", "."]);
    git(&repo.0, &["commit", "-qm", "parent initial"]);
    fs::write(child.join("hello.ts"), "two").unwrap();
    let dirty = request(&repo.0, "git.status", json!({}));
    assert_eq!(dirty["data"]["changes"][0]["path"], "libs/B");
    assert_eq!(
        dirty["data"]["changes"][0]["submodule"]["trackedChanges"],
        true
    );
    assert_eq!(
        dirty["data"]["changes"][0]["submodule"]["commitChanged"],
        false
    );
    assert_eq!(dirty["data"]["changes"].as_array().unwrap().len(), 1);
    assert_eq!(dirty["data"]["changes"][0]["canToggleStaging"], false);
    fs::write(repo.0.join("parent.txt"), "must stay unstaged").unwrap();
    let expected = state(&repo.0);
    git(&child, &["add", "hello.ts"]);
    let child_commit = request(
        &child,
        "git.write",
        json!({"operation":"commit", "message":"child update", "expectedCommitState":state(&child)}),
    );
    assert_eq!(child_commit["data"]["exitCode"], 0, "{child_commit}");
    let child_state = state(&child);
    let advanced = request(&repo.0, "git.status", json!({}));
    assert_eq!(
        advanced["data"]["changes"][0]["submodule"]["commitChanged"],
        true
    );
    let result = request(
        &repo.0,
        "git.write",
        json!({"operation":"commit", "message":"parent reference", "expectedCommitState":expected,
        "gitlinkUpdates":[{"path":"libs/B", "revision":child_state["head"]}]}),
    );
    assert_eq!(result["ok"], true, "{result}");
    assert_eq!(result["data"]["exitCode"], 0, "{result}");
    assert_eq!(git(&repo.0, &["show", "HEAD:parent.txt"]), "parent one");
    assert_eq!(
        git(&repo.0, &["rev-parse", "HEAD:libs/B"]).trim(),
        child_state["head"].as_str().unwrap()
    );
    assert_eq!(
        fs::read_to_string(repo.0.join("parent.txt")).unwrap(),
        "must stay unstaged"
    );
}

#[test]
fn git_workspace_commit_unstage_preserves_edits_after_initial_staging() {
    let repo = repository("workspace-commit-unstage");
    fs::write(repo.0.join("new.txt"), "staged").unwrap();
    git(&repo.0, &["add", "new.txt"]);
    fs::write(repo.0.join("new.txt"), "newer worktree").unwrap();
    let result = request(
        &repo.0,
        "git.write",
        json!({"operation":"unstage", "paths":["new.txt"]}),
    );
    assert_eq!(result["data"]["exitCode"], 0, "{result}");
    assert!(state(&repo.0)["stagedPaths"].as_array().unwrap().is_empty());
    assert_eq!(
        fs::read_to_string(repo.0.join("new.txt")).unwrap(),
        "newer worktree"
    );
}

#[test]
fn git_workspace_commit_state_matches_the_shared_fixture() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/git/workspace-commit-v1.json"
    ))
    .unwrap();
    let state: crate::git::GitCommitState =
        serde_json::from_value(fixture["commitState"].clone()).unwrap();
    assert_eq!(serde_json::to_value(state).unwrap(), fixture["commitState"]);
}

#[test]
fn git_workspace_commit_status_keeps_index_only_files_visible_when_requested() {
    let repo = repository("workspace-commit-index-only");
    fs::write(repo.0.join("new.txt"), "staged content").unwrap();
    git(&repo.0, &["add", "new.txt"]);
    fs::remove_file(repo.0.join("new.txt")).unwrap();
    let legacy = request(&repo.0, "git.status", json!({}));
    assert!(legacy["data"]["changes"].as_array().unwrap().is_empty());
    let staged = request(
        &repo.0,
        "git.status",
        json!({"includeIndexOnlyChanges":true}),
    );
    assert_eq!(staged["data"]["changes"][0]["status"], "AD");
    assert_eq!(staged["data"]["changes"][0]["staged"], true);
    assert_eq!(state(&repo.0)["stagedPaths"], json!(["new.txt"]));
}

#[test]
fn git_workspace_commit_does_not_treat_corrupt_refs_as_an_unborn_repository() {
    let repo = repository("workspace-commit-corrupt-ref");
    let branch = git(&repo.0, &["symbolic-ref", "HEAD"]).trim().to_string();
    let reference = repo.0.join(".git").join(branch);
    fs::create_dir_all(reference.parent().unwrap()).unwrap();
    fs::write(reference, "not-an-object-id\n").unwrap();
    assert_eq!(request(&repo.0, "git.commitState", json!({}))["ok"], false);
    let history = request(
        &repo.0,
        "git.historyPage",
        json!({"reference":"HEAD", "limit":10}),
    );
    assert_eq!(history["ok"], false, "{history}");
}

#[test]
fn git_workspace_commit_push_checks_submodule_publication_before_updating_the_remote() {
    let parent = repository("workspace-commit-push-parent");
    let child = parent.0.join("libs/B");
    init(&child);
    let child_remote = Repository(temporary_root("workspace-commit-child-remote"));
    let parent_remote = Repository(temporary_root("workspace-commit-parent-remote"));
    for remote in [&child_remote, &parent_remote] {
        fs::create_dir_all(&remote.0).unwrap();
        git(&remote.0, &["init", "--bare", "-q"]);
    }
    fs::write(child.join("hello.ts"), "initial").unwrap();
    git(&child, &["add", "hello.ts"]);
    git(&child, &["commit", "-qm", "initial child"]);
    git(&child, &["branch", "-M", "main"]);
    git(
        &child,
        &["remote", "add", "origin", child_remote.0.to_str().unwrap()],
    );
    git(&child, &["push", "-qu", "origin", "main"]);
    // Let Git quote native paths; literal Windows backslashes are escapes in
    // config syntax and must not be interpolated into .gitmodules directly.
    git(
        &parent.0,
        &[
            "config",
            "--file",
            ".gitmodules",
            "submodule.B.path",
            "libs/B",
        ],
    );
    git(
        &parent.0,
        &[
            "config",
            "--file",
            ".gitmodules",
            "submodule.B.url",
            child_remote.0.to_str().unwrap(),
        ],
    );
    git(&parent.0, &["add", "."]);
    git(&parent.0, &["commit", "-qm", "initial parent"]);
    git(&parent.0, &["branch", "-M", "main"]);
    git(
        &parent.0,
        &["remote", "add", "origin", parent_remote.0.to_str().unwrap()],
    );
    git(&parent.0, &["push", "-qu", "origin", "main"]);
    let remote_before = git(&parent_remote.0, &["rev-parse", "refs/heads/main"]);
    fs::write(child.join("hello.ts"), "not yet published").unwrap();
    git(&child, &["commit", "-qam", "child update"]);
    git(&parent.0, &["add", "libs/B"]);
    git(&parent.0, &["commit", "-qm", "parent pointer"]);
    let push = |root: &Path| {
        request(
            root,
            "git.write",
            json!({"operation":"push", "reference":"refs/heads/main",
        "checkSubmodules":true, "expectedCommitState":state(root)}),
        )
    };
    let blocked = push(&parent.0);
    assert_ne!(blocked["data"]["exitCode"], 0, "{blocked}");
    assert_eq!(
        git(&parent_remote.0, &["rev-parse", "refs/heads/main"]),
        remote_before
    );
    let pushed_child = push(&child);
    assert_eq!(pushed_child["data"]["exitCode"], 0, "{pushed_child}");
    let pushed_parent = push(&parent.0);
    assert_eq!(pushed_parent["data"]["exitCode"], 0, "{pushed_parent}");
    assert_eq!(
        git(&parent_remote.0, &["rev-parse", "refs/heads/main"]).trim(),
        state(&parent.0)["head"].as_str().unwrap()
    );
}

#[test]
fn git_workspace_commit_rejects_a_removed_child_repository_instead_of_using_its_parent() {
    let parent = repository("workspace-commit-removed-child");
    let child = parent.0.join("child");
    init(&child);
    // Both repositories have valid staged content; losing the child boundary
    // must invalidate its state instead of reading any state from the parent.
    for root in [&parent.0, &child] {
        fs::write(root.join("selected.txt"), "same staged content").unwrap();
        git(root, &["add", "selected.txt"]);
    }
    let expected = state(&child);
    fs::remove_dir_all(child.join(".git")).unwrap();
    let result = request(
        &child,
        "git.write",
        json!({"operation":"commit", "message":"must not commit parent", "expectedCommitState":expected}),
    );
    assert!(
        result["ok"] == false || !result["data"]["operationError"].is_null(),
        "{result}"
    );
    assert!(state(&parent.0)["head"].is_null());
    assert_eq!(request(&child, "git.commitState", json!({}))["ok"], false);
}

#[test]
fn git_workspace_commit_rejects_a_removed_submodule_before_updating_its_pointer() {
    let parent = repository("workspace-commit-removed-submodule");
    let child = parent.0.join("child");
    init(&child);
    fs::write(child.join("selected.txt"), "child content").unwrap();
    git(&child, &["add", "."]);
    git(&child, &["commit", "-qm", "child initial"]);
    git(&parent.0, &["add", "child"]);
    git(&parent.0, &["commit", "-qm", "parent initial"]);
    let expected = state(&parent.0);
    fs::remove_dir_all(child.join(".git")).unwrap();
    // Without boundary validation, rev-parse in the child returns the parent's
    // HEAD and incorrectly permits that revision to replace the child pointer.
    let result = request(
        &parent.0,
        "git.write",
        json!({"operation":"commit", "message":"must not replace child",
            "expectedCommitState":expected,
            "gitlinkUpdates":[{"path":"child", "revision":expected["head"]}]}),
    );
    assert_eq!(
        result["data"]["operationError"]["code"], "invalid_request",
        "{result}"
    );
    assert_eq!(state(&parent.0), expected);
}

fn prepare_workspace(root: &Path, repositories: &[(&str, &Path)], push: bool) -> Value {
    let repositories: Vec<_> = repositories
        .iter()
        .map(|(id, path)| json!({"id":id,"root":path}))
        .collect();
    let response = request(
        root,
        "git.workspaceCommitPrepare",
        json!({"repositories":repositories,"message":"batch","push":push,"includeParentReferences":true}),
    );
    assert_eq!(response["ok"], true, "{response}");
    response["data"].clone()
}

fn next_workspace(root: &Path, session: Value) -> Value {
    let response = request(root, "git.workspaceCommitStep", json!({"session":session}));
    assert_eq!(response["ok"], true, "{response}");
    response["data"].clone()
}

fn staged_file(root: &Path, path: &str, content: &str) {
    fs::write(root.join(path), content).unwrap();
    git(root, &["add", path]);
}

#[test]
fn git_workspace_workflow_commits_independent_repositories_and_rejects_replayed_steps() {
    let repo = repository("workspace-workflow-independent");
    let child = repo.0.join("independent");
    init(&child);
    staged_file(&repo.0, "parent.txt", "one");
    staged_file(&child, "child.txt", "one");
    let prepared = prepare_workspace(&repo.0, &[(".", &repo.0), ("independent", &child)], false);
    assert_eq!(prepared["requiresConfirmation"], false);
    let original = prepared["session"].clone();
    let first = next_workspace(&repo.0, original.clone());
    assert_eq!(first["results"]["."]["committed"], true);
    assert!(state(&child)["head"].is_null());
    let replay = next_workspace(&repo.0, original);
    assert_eq!(replay["results"]["."]["status"], "reviewRequired");
    let finished = next_workspace(&repo.0, first);
    assert_eq!(finished["succeeded"], true, "{finished}");
    assert_eq!(git(&repo.0, &["rev-list", "--count", "HEAD"]).trim(), "1");
    assert_eq!(git(&child, &["rev-list", "--count", "HEAD"]).trim(), "1");
}

#[test]
fn git_workspace_workflow_updates_clean_parent_without_including_unstaged_parent_files() {
    let repo = repository("workspace-workflow-parent");
    let child = repo.0.join("B");
    init(&child);
    staged_file(&child, "hello.ts", "one");
    git(&child, &["commit", "-qm", "initial"]);
    staged_file(&repo.0, "parent.txt", "one");
    git(&repo.0, &["add", "B"]);
    git(&repo.0, &["commit", "-qm", "initial"]);
    staged_file(&child, "hello.ts", "two");
    fs::write(repo.0.join("parent.txt"), "unstaged").unwrap();
    let prepared = prepare_workspace(&repo.0, &[(".", &repo.0), ("B", &child)], false);
    assert_eq!(prepared["session"]["plan"]["orderedIds"], json!(["B", "."]));
    let child_done = next_workspace(&repo.0, prepared["session"].clone());
    let finished = next_workspace(&repo.0, child_done);
    assert_eq!(finished["succeeded"], true, "{finished}");
    assert_eq!(
        git(&repo.0, &["rev-parse", "HEAD:B"]),
        git(&child, &["rev-parse", "HEAD"])
    );
    assert_eq!(git(&repo.0, &["show", "HEAD:parent.txt"]), "one");
}

#[test]
fn git_workspace_workflow_failed_push_continues_independent_and_retries_without_duplicate_commits()
{
    let repo = repository("workspace-workflow-retry");
    let child = repo.0.join("B");
    init(&child);
    staged_file(&repo.0, "a.txt", "one");
    staged_file(&child, "b.txt", "one");
    // No remote: the first repository's push fails through Git's real target resolver.
    let prepared = prepare_workspace(&repo.0, &[(".", &repo.0), ("B", &child)], true);
    let mut session = prepared["session"].clone();
    for _ in 0..4 {
        session = next_workspace(&repo.0, session);
    }
    assert_eq!(session["finished"], true);
    assert_eq!(session["canRetry"], true);
    assert_eq!(session["results"]["."]["committed"], true);
    assert_eq!(session["results"]["B"]["committed"], true);
    let mut retry = prepared["session"]["plan"].clone();
    retry["previous"] = session;
    let response = request(&repo.0, "git.workspaceCommitPrepare", retry);
    assert_eq!(response["ok"], true, "{response}");
    let next = next_workspace(&repo.0, response["data"]["session"].clone());
    assert_eq!(next["cursor"], 1); // One push, never another commit.
    assert_eq!(git(&repo.0, &["rev-list", "--count", "HEAD"]).trim(), "1");
}

#[test]
fn git_workspace_workflow_confirmation_detects_external_staging_without_writing() {
    let repo = repository("workspace-workflow-confirm");
    staged_file(&repo.0, "one.txt", "one");
    let prepared = prepare_workspace(&repo.0, &[(".", &repo.0)], false);
    staged_file(&repo.0, "two.txt", "two");
    let mut review = prepared["session"]["plan"].clone();
    review["reviewed"] = review.clone();
    let response = request(&repo.0, "git.workspaceCommitPrepare", review);
    assert_eq!(response["data"]["reviewChanged"], true, "{response}");
    assert!(state(&repo.0)["head"].is_null());
}

#[test]
fn git_workspace_status_excludes_discovered_independent_nested_roots() {
    let repo = repository("workspace-status-ownership");
    let child = repo.0.join("B");
    init(&child);
    staged_file(&child, "hello.ts", "one");
    git(&child, &["commit", "-qm", "initial"]);
    let response = request(
        &repo.0,
        "git.status",
        json!({"repositoryRoots":[repo.0,child]}),
    );
    assert_eq!(response["data"]["changes"], json!([]), "{response}");
    assert_eq!(
        request(&repo.0, "git.status", json!({}))["data"]["changes"][0]["path"],
        "B/"
    );
}

#[test]
fn git_workspace_workflow_retains_a_completed_commit_when_cancellation_races_its_return() {
    use std::sync::{Arc, Mutex};
    let repo = repository("workspace-workflow-cancel");
    let child = repo.0.join("B");
    init(&child);
    staged_file(&repo.0, "a.txt", "one");
    staged_file(&child, "b.txt", "one");
    let prepared = prepare_workspace(&repo.0, &[(".", &repo.0), ("B", &child)], false);
    let invocation = Arc::new(Mutex::new(None));
    let observed = invocation.clone();
    // Cancel synchronously at the native commit's completion event: the ref has
    // advanced, but the JSON response and cleanup inspection have not returned.
    let response=crate::execute_json_with_events(&json!({"id":"workspace-cancel-after-commit",
        "command":"git.workspaceCommitStep","payload":{"session":prepared["session"]},"timeoutMilliseconds":10000}).to_string(),
        Arc::new(move |event| {
            let event:Value=serde_json::from_str(event).unwrap();
            if event["type"]=="started" && event["arguments"].as_array().is_some_and(|args| args.iter().any(|arg| arg=="commit")) {
                *observed.lock().unwrap()=event["invocationId"].as_u64();
            }
            if event["type"]=="finished" && event["invocationId"].as_u64()==*observed.lock().unwrap() {
                assert!(crate::cancel_operation("workspace-cancel-after-commit"));
            }
        }));
    let response: Value = serde_json::from_str(&response).unwrap();
    assert!(invocation.lock().unwrap().is_some());
    assert_eq!(response["ok"], true, "{response}");
    assert_eq!(
        response["data"]["results"]["."]["committed"], true,
        "{response}"
    );
    assert!(!crate::cancel_operation("workspace-cancel-after-commit"));
    let finished = next_workspace(&repo.0, response["data"].clone());
    assert_eq!(finished["succeeded"], true, "{finished}");
    assert_eq!(git(&repo.0, &["rev-list", "--count", "HEAD"]).trim(), "1");
}

#[test]
#[cfg(unix)]
fn git_workspace_status_normalizes_native_repository_binding_aliases() {
    let repo = repository("workspace-status-alias");
    let child = repo.0.join("B");
    init(&child);
    staged_file(&child, "hello.ts", "one");
    git(&child, &["commit", "-qm", "initial"]);
    let alias = repo.0.join("binding-link");
    std::os::unix::fs::symlink(&child, &alias).unwrap();
    let response = request(
        &repo.0,
        "git.status",
        json!({"repositoryRoots":[repo.0,alias]}),
    );
    assert_eq!(response["ok"], true, "{response}");
    let paths: Vec<_> = response["data"]["changes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["path"].as_str().unwrap())
        .collect();
    // The parent still owns the symlink itself; only B's independent files are excluded.
    assert_eq!(paths, ["binding-link"]);
}

#[test]
fn git_workspace_changelist_guard_keeps_index_and_worktree_unchanged() {
    let repo = repository("workspace-changelist-guard");
    fs::write(repo.0.join("application.yaml"), "local configuration").unwrap();
    fs::write(repo.0.join("feature.txt"), "staged version").unwrap();
    git(&repo.0, &["add", "."]);
    fs::write(repo.0.join("feature.txt"), "later unstaged version").unwrap();
    let before = state(&repo.0);
    let payload = json!({"repositories":[{"id":".","root":repo.0}],"message":"feature only",
        "includeParentReferences":false,"pathScope":{"include":false,"paths":{".":["application.yaml"]}}});
    let rejected = request(&repo.0, "git.workspaceCommitPrepare", payload.clone());
    assert_eq!(rejected["ok"], false, "{rejected}");
    assert_eq!(state(&repo.0), before);
    // Explicitly unstage the protected file; the later edit must stay out of the commit.
    git(&repo.0, &["rm", "--cached", "application.yaml"]);
    let prepared = request(&repo.0, "git.workspaceCommitPrepare", payload);
    assert_eq!(prepared["ok"], true, "{prepared}");
    let result = request(
        &repo.0,
        "git.workspaceCommitStep",
        json!({"session":prepared["data"]["session"]}),
    );
    assert_eq!(result["ok"], true, "{result}");
    assert_eq!(result["data"]["succeeded"], true, "{result}");
    assert_eq!(
        git(&repo.0, &["show", "HEAD:feature.txt"]),
        "staged version"
    );
    assert_eq!(
        git(&repo.0, &["ls-tree", "--name-only", "HEAD"]),
        "feature.txt\n"
    );
    assert_eq!(
        fs::read_to_string(repo.0.join("feature.txt")).unwrap(),
        "later unstaged version"
    );
    assert_eq!(
        fs::read_to_string(repo.0.join("application.yaml")).unwrap(),
        "local configuration"
    );
}

#[test]
fn git_workspace_changelist_guard_catches_a_rename_after_the_ui_snapshot() {
    let repo = repository("workspace-changelist-rename");
    fs::write(repo.0.join("local.yaml"), "local").unwrap();
    git(&repo.0, &["add", "."]);
    git(&repo.0, &["commit", "-qm", "initial"]);
    git(&repo.0, &["mv", "local.yaml", "renamed.yaml"]);
    let before = state(&repo.0);
    let result = request(
        &repo.0,
        "git.workspaceCommitPrepare",
        json!({
            "repositories":[{"id":".","root":repo.0}], "message":"must not commit",
            "includeParentReferences":false, "pathScope":{"include":false,"paths":{".":["local.yaml"]}}
        }),
    );
    assert_eq!(result["ok"], false, "{result}");
    assert_eq!(state(&repo.0), before);
}
