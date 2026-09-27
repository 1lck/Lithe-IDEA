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
    fs::write(
        parent.0.join(".gitmodules"),
        format!(
            "[submodule \"B\"]\npath = libs/B\nurl = {}\n",
            child_remote.0.display()
        ),
    )
    .unwrap();
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
