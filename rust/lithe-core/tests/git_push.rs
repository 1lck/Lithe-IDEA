use lithe_core::execute_json;
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

static NEXT_FIXTURE_ID: AtomicU64 = AtomicU64::new(0);

struct GitFixture {
    root: PathBuf,
}

impl GitFixture {
    fn new() -> Self {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock should be valid")
            .as_nanos();
        let fixture_id = NEXT_FIXTURE_ID.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "lithe-git-push-{}-{nonce}-{fixture_id}",
            std::process::id()
        ));
        fs::create_dir_all(&root).expect("Git fixture root should be creatable");
        Self { root }
    }
}

impl Drop for GitFixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn git(directory: &Path, arguments: &[&str]) -> Output {
    Command::new("git")
        .args(arguments)
        .current_dir(directory)
        .output()
        .expect("git should be available")
}

fn require_git(directory: &Path, arguments: &[&str]) {
    let output = git(directory, arguments);
    assert!(
        output.status.success(),
        "git {} failed: {}",
        arguments.join(" "),
        String::from_utf8_lossy(&output.stderr)
    );
}

fn core(command: &str, root: &Path, payload: Value) -> Value {
    let mut payload = payload.as_object().cloned().unwrap_or_default();
    payload.insert("root".into(), json!(root));
    let request = json!({
        "id": format!("test-{command}"),
        "command": command,
        "payload": payload
    });
    serde_json::from_str(&execute_json(
        &serde_json::to_string(&request).expect("Core request should encode"),
    ))
    .expect("Core response should be JSON")
}

fn initialize_repository(fixture: &GitFixture) -> (PathBuf, PathBuf) {
    let remote = fixture.root.join("remote.git");
    let repository = fixture.root.join("repository");
    fs::create_dir_all(&remote).expect("remote should be creatable");
    fs::create_dir_all(&repository).expect("repository should be creatable");
    require_git(&remote, &["init", "--bare", "-q"]);
    require_git(&repository, &["init", "-q"]);
    require_git(&repository, &["config", "user.email", "tests@lithe.local"]);
    require_git(&repository, &["config", "user.name", "Lithe Tests"]);
    fs::write(repository.join("tracked.txt"), "initial\n")
        .expect("tracked fixture should be writable");
    require_git(&repository, &["add", "tracked.txt"]);
    require_git(&repository, &["commit", "-q", "-m", "initial"]);
    require_git(&repository, &["branch", "-M", "main"]);
    let remote_path = remote.to_string_lossy().into_owned();
    require_git(&repository, &["remote", "add", "origin", &remote_path]);
    require_git(&repository, &["push", "-q", "-u", "origin", "main"]);
    (repository, remote)
}

fn add_bare_remote(fixture: &GitFixture, repository: &Path, name: &str) -> PathBuf {
    let remote = fixture.root.join(format!("{}.git", name.replace('/', "-")));
    fs::create_dir_all(&remote).expect("additional remote should be creatable");
    require_git(&remote, &["init", "--bare", "-q"]);
    let remote_path = remote.to_string_lossy().into_owned();
    require_git(repository, &["remote", "add", name, &remote_path]);
    remote
}

fn push_expectation(preview: &Value) -> Value {
    json!({
        "localBranch": preview["data"]["localBranch"],
        "localHead": preview["data"]["localHead"],
        "remote": preview["data"]["remote"],
        "remoteBranch": preview["data"]["remoteBranch"],
        "targetKind": preview["data"]["targetKind"],
        "remoteTrackingOid": preview["data"]["remoteTrackingOid"],
        "tags": preview["data"]["tags"],
    })
}

/// The same payload without `targetKind`, shaped like a caller that predates it.
fn legacy_push_expectation(preview: &Value) -> Value {
    json!({
        "localBranch": preview["data"]["localBranch"],
        "localHead": preview["data"]["localHead"],
        "remote": preview["data"]["remote"],
        "remoteBranch": preview["data"]["remoteBranch"],
        "remoteTrackingOid": preview["data"]["remoteTrackingOid"],
        "tags": preview["data"]["tags"],
    })
}

/// Issue #1272: `targetKind` is an additive review field. A caller that omits it
/// must keep pushing exactly as before — treating the omission as a mismatch would
/// turn every reviewed push from an un-upgraded client into a stale-preview error.
#[test]
fn reviewed_push_without_target_kind_keeps_working() {
    let fixture = GitFixture::new();
    let (repository, _) = initialize_repository(&fixture);
    fs::write(repository.join("tracked.txt"), "initial\nsecond\n")
        .expect("fixture should be writable");
    require_git(&repository, &["commit", "-q", "-am", "second"]);

    let preview = core("git.pushPreview", &repository, json!({}));
    assert_eq!(preview["ok"], true, "response: {preview}");

    let pushed = core(
        "git.write",
        &repository,
        json!({
            "operation": "push",
            "expectedPush": legacy_push_expectation(&preview)
        }),
    );
    assert_eq!(pushed["ok"], true, "response: {pushed}");
    assert!(
        pushed["data"]["operationError"].is_null(),
        "omitting targetKind must not mark the preview stale: {pushed}"
    );
    assert_eq!(pushed["data"]["exitCode"], 0, "response: {pushed}");
}

/// Issue #1272: an explicit but wrong `targetKind` is still a real mismatch, so the
/// compatibility allowance above must not weaken the review check.
#[test]
fn reviewed_push_with_a_wrong_target_kind_is_rejected() {
    let fixture = GitFixture::new();
    let (repository, _) = initialize_repository(&fixture);
    fs::write(repository.join("tracked.txt"), "initial\nsecond\n")
        .expect("fixture should be writable");
    require_git(&repository, &["commit", "-q", "-am", "second"]);

    let preview = core("git.pushPreview", &repository, json!({}));
    assert_eq!(preview["data"]["targetKind"], "tracking");
    let mut expectation = push_expectation(&preview);
    expectation["targetKind"] = json!("divergent");

    let pushed = core(
        "git.write",
        &repository,
        json!({ "operation": "push", "expectedPush": expectation }),
    );
    assert_eq!(
        pushed["data"]["operationError"]["code"], "invalid_request",
        "a wrong targetKind must be rejected: {pushed}"
    );
    assert!(
        pushed["data"]["operationError"]["message"]
            .as_str()
            .is_some_and(|message| message.contains("stale")),
        "the rejection must report a stale preview: {pushed}"
    );
}

#[test]
fn push_preview_and_write_share_destination_and_safe_options() {
    let fixture = GitFixture::new();
    let (repository, remote) = initialize_repository(&fixture);
    fs::write(repository.join("tracked.txt"), "initial\nsecond\n")
        .expect("tracked fixture should be writable");
    require_git(&repository, &["commit", "-q", "-am", "second"]);
    require_git(&repository, &["tag", "-a", "v1", "-m", "version one"]);

    let preview = core(
        "git.pushPreview",
        &repository,
        json!({ "pushTags": "reachable" }),
    );
    assert_eq!(preview["ok"], true, "response: {preview}");
    assert_eq!(preview["data"]["localBranch"], "main");
    assert_eq!(preview["data"]["remote"], "origin");
    assert_eq!(preview["data"]["remoteBranch"], "main");
    assert_eq!(preview["data"]["upstream"], "origin/main");
    assert_eq!(
        preview["data"]["localHead"],
        String::from_utf8_lossy(&git(&repository, &["rev-parse", "HEAD"]).stdout).trim()
    );
    assert_eq!(
        preview["data"]["remoteTrackingOid"],
        String::from_utf8_lossy(&git(&repository, &["rev-parse", "origin/main"]).stdout).trim()
    );
    assert_eq!(preview["data"]["commits"].as_array().map(Vec::len), Some(1));
    assert_eq!(preview["data"]["commits"][0]["subject"], "second");

    let pushed = core(
        "git.write",
        &repository,
        json!({
            "operation": "push",
            "expectedPush": push_expectation(&preview),
            "force": true,
            "pushTags": "reachable"
        }),
    );
    assert_eq!(pushed["ok"], true, "response: {pushed}");
    let arguments = pushed["data"]["arguments"]
        .as_array()
        .expect("push arguments should be present")
        .iter()
        .filter_map(Value::as_str)
        .collect::<Vec<_>>();
    assert!(arguments
        .iter()
        .any(|argument| argument.starts_with("--force-with-lease=refs/heads/main:")));
    assert!(!arguments.contains(&"--force"));
    assert!(!arguments.contains(&"--follow-tags"));
    let reviewed_refspec = format!(
        "{}:refs/heads/main",
        preview["data"]["localHead"]
            .as_str()
            .expect("preview should contain the local head")
    );
    assert!(arguments.contains(&reviewed_refspec.as_str()));
    let reviewed_tag_refspec = format!(
        "{}:{}",
        preview["data"]["tags"][0]["objectId"]
            .as_str()
            .expect("preview should contain the tag object"),
        preview["data"]["tags"][0]["fullName"]
            .as_str()
            .expect("preview should contain the tag reference")
    );
    assert!(arguments.contains(&reviewed_tag_refspec.as_str()));

    let local_head = git(&repository, &["rev-parse", "HEAD"]);
    let remote_head = git(&remote, &["rev-parse", "refs/heads/main"]);
    assert_eq!(local_head.stdout, remote_head.stdout);
    require_git(&remote, &["show-ref", "--verify", "refs/tags/v1"]);
}

#[test]
fn push_rejects_a_preview_after_the_local_head_changes() {
    let fixture = GitFixture::new();
    let (repository, remote) = initialize_repository(&fixture);
    let preview = core("git.pushPreview", &repository, json!({}));
    assert_eq!(preview["ok"], true, "response: {preview}");
    let remote_before = git(&remote, &["rev-parse", "refs/heads/main"]).stdout;

    fs::write(repository.join("after-preview.txt"), "changed\n")
        .expect("fixture should be writable");
    require_git(&repository, &["add", "after-preview.txt"]);
    require_git(&repository, &["commit", "-q", "-m", "after preview"]);

    let pushed = core(
        "git.write",
        &repository,
        json!({
            "operation": "push",
            "expectedPush": push_expectation(&preview)
        }),
    );
    assert_eq!(pushed["ok"], true, "response: {pushed}");
    assert_eq!(
        pushed["data"]["operationError"]["message"],
        "Git push preview is stale; refresh and try again."
    );
    assert!(!pushed["data"]["invocations"]
        .as_array()
        .expect("invocations should be present")
        .iter()
        .any(|invocation| invocation["arguments"][0] == "push"));
    assert_eq!(
        git(&remote, &["rev-parse", "refs/heads/main"]).stdout,
        remote_before
    );
}

#[test]
fn push_rejects_a_preview_after_the_configured_destination_changes() {
    let fixture = GitFixture::new();
    let (repository, origin) = initialize_repository(&fixture);
    let fork = add_bare_remote(&fixture, &repository, "fork");
    fs::write(repository.join("destination.txt"), "changed\n").expect("fixture should be writable");
    require_git(&repository, &["add", "destination.txt"]);
    require_git(&repository, &["commit", "-q", "-m", "destination change"]);
    let preview = core("git.pushPreview", &repository, json!({}));
    assert_eq!(preview["data"]["remote"], "origin");

    require_git(&repository, &["config", "branch.main.pushRemote", "fork"]);
    let pushed = core(
        "git.write",
        &repository,
        json!({
            "operation": "push",
            "expectedPush": push_expectation(&preview)
        }),
    );

    assert_eq!(pushed["ok"], true, "response: {pushed}");
    assert_eq!(
        pushed["data"]["operationError"]["message"],
        "Git push preview is stale; refresh and try again."
    );
    assert!(!pushed["data"]["invocations"]
        .as_array()
        .expect("invocations should be present")
        .iter()
        .any(|invocation| invocation["arguments"][0] == "push"));
    assert_ne!(
        git(&origin, &["rev-parse", "refs/heads/main"]).stdout,
        git(&repository, &["rev-parse", "HEAD"]).stdout
    );
    assert!(!git(&fork, &["show-ref", "--verify", "refs/heads/main"])
        .status
        .success());
}

#[test]
fn reviewed_push_uses_default_remote_and_sets_upstream_when_missing() {
    let fixture = GitFixture::new();
    let (repository, _) = initialize_repository(&fixture);
    require_git(&repository, &["switch", "-q", "-c", "feature"]);
    fs::write(repository.join("local.txt"), "local\n").expect("local fixture should be writable");
    require_git(&repository, &["add", "local.txt"]);
    require_git(&repository, &["commit", "-q", "-m", "local only"]);

    let preview = core("git.pushPreview", &repository, json!({}));
    assert_eq!(preview["ok"], true, "response: {preview}");
    assert_eq!(preview["data"]["remote"], "origin");
    assert_eq!(preview["data"]["remoteBranch"], "feature");
    assert!(preview["data"]["upstream"].is_null());
    assert_eq!(preview["data"]["commits"].as_array().map(Vec::len), Some(1));
    assert_eq!(preview["data"]["commits"][0]["subject"], "local only");

    let pushed = core(
        "git.write",
        &repository,
        json!({
            "operation": "push",
            "expectedPush": push_expectation(&preview)
        }),
    );
    assert_eq!(pushed["ok"], true, "response: {pushed}");
    assert_eq!(pushed["data"]["exitCode"], 0, "response: {pushed}");
    assert_eq!(
        String::from_utf8_lossy(
            &git(&repository, &["rev-parse", "--abbrev-ref", "@{upstream}"]).stdout
        )
        .trim(),
        "origin/feature"
    );
}

#[test]
fn unreviewed_push_without_upstream_configures_tracking_once() {
    let fixture = GitFixture::new();
    let (repository, _) = initialize_repository(&fixture);
    require_git(&repository, &["switch", "-q", "-c", "feature"]);
    fs::write(repository.join("local.txt"), "local\n").expect("local fixture should be writable");
    require_git(&repository, &["add", "local.txt"]);
    require_git(&repository, &["commit", "-q", "-m", "local only"]);

    let pushed = core("git.write", &repository, json!({ "operation": "push" }));
    assert_eq!(pushed["ok"], true, "response: {pushed}");
    assert_eq!(pushed["data"]["exitCode"], 0, "response: {pushed}");
    assert!(pushed["data"]["warnings"]
        .as_array()
        .is_none_or(Vec::is_empty));

    let invocations = pushed["data"]["invocations"]
        .as_array()
        .expect("push invocations should be present");
    let push_invocations = invocations
        .iter()
        .filter(|invocation| invocation["arguments"][0] == "push")
        .collect::<Vec<_>>();
    assert_eq!(push_invocations.len(), 1, "response: {pushed}");
    assert!(!push_invocations[0]["arguments"]
        .as_array()
        .expect("push arguments should be present")
        .iter()
        .any(|argument| argument == "--set-upstream"));

    let remote_configuration_count = invocations
        .iter()
        .filter(|invocation| {
            invocation["arguments"]
                == json!([
                    "config",
                    "--local",
                    "--replace-all",
                    "branch.feature.remote",
                    "origin"
                ])
        })
        .count();
    let merge_configuration_count = invocations
        .iter()
        .filter(|invocation| {
            invocation["arguments"]
                == json!([
                    "config",
                    "--local",
                    "--replace-all",
                    "branch.feature.merge",
                    "refs/heads/feature"
                ])
        })
        .count();
    assert_eq!(remote_configuration_count, 1, "response: {pushed}");
    assert_eq!(merge_configuration_count, 1, "response: {pushed}");
    assert_eq!(
        String::from_utf8_lossy(
            &git(&repository, &["rev-parse", "--abbrev-ref", "@{upstream}"]).stdout
        )
        .trim(),
        "origin/feature"
    );
}

#[test]
fn push_preview_preserves_a_configured_remote_name_with_slashes() {
    let fixture = GitFixture::new();
    let (repository, _) = initialize_repository(&fixture);
    require_git(&repository, &["remote", "rename", "origin", "team/origin"]);
    fs::write(repository.join("nested-remote.txt"), "local\n")
        .expect("nested remote fixture should be writable");
    require_git(&repository, &["add", "nested-remote.txt"]);
    require_git(&repository, &["commit", "-q", "-m", "nested remote"]);

    let preview = core("git.pushPreview", &repository, json!({}));
    assert_eq!(preview["ok"], true, "response: {preview}");
    assert_eq!(preview["data"]["remote"], "team/origin");
    assert_eq!(preview["data"]["remoteBranch"], "main");
    assert_eq!(preview["data"]["upstream"], "team/origin/main");
    assert_eq!(preview["data"]["commits"][0]["subject"], "nested remote");
}

#[test]
fn branch_push_remote_overrides_the_tracking_remote_for_preview_and_push() {
    let fixture = GitFixture::new();
    let (repository, _) = initialize_repository(&fixture);
    let fork = add_bare_remote(&fixture, &repository, "fork");
    require_git(&repository, &["config", "branch.main.pushRemote", "fork"]);
    fs::write(repository.join("fork.txt"), "fork\n").expect("fixture should be writable");
    require_git(&repository, &["add", "fork.txt"]);
    require_git(&repository, &["commit", "-q", "-m", "fork change"]);

    let preview = core("git.pushPreview", &repository, json!({}));
    assert_eq!(preview["ok"], true, "response: {preview}");
    assert_eq!(preview["data"]["remote"], "fork");
    assert_eq!(preview["data"]["remoteBranch"], "main");
    assert_eq!(preview["data"]["upstream"], "origin/main");

    let pushed = core("git.write", &repository, json!({ "operation": "push" }));
    assert_eq!(pushed["ok"], true, "response: {pushed}");
    assert_eq!(pushed["data"]["exitCode"], 0, "response: {pushed}");
    assert_eq!(
        git(&repository, &["rev-parse", "HEAD"]).stdout,
        git(&fork, &["rev-parse", "refs/heads/main"]).stdout
    );
}

#[test]
fn remote_push_default_overrides_the_tracking_remote() {
    let fixture = GitFixture::new();
    let (repository, _) = initialize_repository(&fixture);
    add_bare_remote(&fixture, &repository, "fork");
    require_git(&repository, &["config", "remote.pushDefault", "fork"]);

    let preview = core("git.pushPreview", &repository, json!({}));
    assert_eq!(preview["ok"], true, "response: {preview}");
    assert_eq!(preview["data"]["remote"], "fork");
    assert_eq!(preview["data"]["remoteBranch"], "main");
    assert_eq!(preview["data"]["upstream"], "origin/main");
}

#[test]
fn typed_remote_deletion_preserves_remote_names_with_slashes() {
    let fixture = GitFixture::new();
    let (repository, remote) = initialize_repository(&fixture);
    require_git(&repository, &["remote", "rename", "origin", "team/origin"]);
    require_git(
        &repository,
        &[
            "push",
            "-q",
            "team/origin",
            "refs/heads/main:refs/heads/feature/orders",
        ],
    );

    let deleted = core(
        "git.write",
        &repository,
        json!({
            "operation": "deleteRemoteBranch",
            "gitReference": {
                "fullName": "refs/remotes/team/origin/feature/orders",
                "shortName": "team/origin/feature/orders",
                "kind": "remote"
            }
        }),
    );
    assert_eq!(deleted["ok"], true, "response: {deleted}");
    assert_eq!(deleted["data"]["exitCode"], 0, "response: {deleted}");
    assert!(!git(
        &remote,
        &["show-ref", "--verify", "refs/heads/feature/orders"]
    )
    .status
    .success());
}

/// Regression for issue #1272: the fixed branch-creation path must not turn
/// "check out a remote branch" into a tracking-less checkout. Those are two
/// distinct semantics and the guard here keeps a future refactor from merging
/// them and silently dropping upstream tracking.
#[test]
fn checkout_of_remote_branch_still_creates_tracking_branch() {
    let fixture = GitFixture::new();
    let (repository, _) = initialize_repository(&fixture);
    require_git(&repository, &["switch", "-q", "-c", "topic"]);
    fs::write(repository.join("topic.txt"), "topic\n").expect("fixture should be writable");
    require_git(&repository, &["add", "topic.txt"]);
    require_git(&repository, &["commit", "-q", "-m", "topic work"]);
    require_git(&repository, &["push", "-q", "-u", "origin", "topic"]);
    require_git(&repository, &["switch", "-q", "main"]);
    require_git(&repository, &["branch", "-D", "topic"]);

    let checked_out = core(
        "git.write",
        &repository,
        json!({
            "operation": "checkout",
            "gitReference": {
                "fullName": "refs/remotes/origin/topic",
                "shortName": "origin/topic",
                "kind": "remote"
            }
        }),
    );
    assert_eq!(checked_out["ok"], true, "response: {checked_out}");
    assert_eq!(
        checked_out["data"]["exitCode"], 0,
        "response: {checked_out}"
    );
    assert_eq!(
        String::from_utf8_lossy(
            &git(&repository, &["rev-parse", "--abbrev-ref", "@{upstream}"]).stdout
        )
        .trim(),
        "origin/topic",
        "checking out a remote branch must still establish tracking"
    );
}

/// Issue #1272: a branch started at a local branch or an explicit commit never
/// had a remote upstream to inherit, and the fix must not introduce one.
#[test]
fn branch_created_from_local_start_has_no_upstream() {
    let fixture = GitFixture::new();
    let (repository, _) = initialize_repository(&fixture);
    require_git(&repository, &["switch", "-q", "-c", "topic"]);
    fs::write(repository.join("topic.txt"), "topic\n").expect("fixture should be writable");
    require_git(&repository, &["add", "topic.txt"]);
    require_git(&repository, &["commit", "-q", "-m", "topic work"]);
    require_git(&repository, &["switch", "-q", "main"]);

    let from_local = core(
        "git.write",
        &repository,
        json!({
            "operation": "createBranch",
            "name": "feature/from-local",
            "reference": "refs/heads/topic",
            "checkout": false
        }),
    );
    assert_eq!(from_local["ok"], true, "response: {from_local}");
    assert_eq!(from_local["data"]["exitCode"], 0, "response: {from_local}");
    assert_no_upstream(&repository, "feature/from-local");

    let head_oid = String::from_utf8_lossy(&git(&repository, &["rev-parse", "HEAD"]).stdout)
        .trim()
        .to_string();
    let from_commit = core(
        "git.write",
        &repository,
        json!({
            "operation": "createBranch",
            "name": "feature/from-commit",
            "reference": head_oid,
            "checkout": false
        }),
    );
    assert_eq!(from_commit["ok"], true, "response: {from_commit}");
    assert_eq!(
        from_commit["data"]["exitCode"], 0,
        "response: {from_commit}"
    );
    assert_no_upstream(&repository, "feature/from-commit");
}

/// Issue #1272: branches created from a remote no longer carry an upstream, so
/// the push preview falls back to excluding commits reachable from the selected
/// remote. That fallback must still list the branch's own new commits instead of
/// collapsing to an empty preview.
#[test]
fn preview_of_untracked_branch_still_lists_its_commits() {
    let fixture = GitFixture::new();
    let (repository, _) = initialize_repository(&fixture);

    let created = create_branch_from_remote(&repository, "feature/topic", "main");
    assert_eq!(created["ok"], true, "response: {created}");
    fs::write(repository.join("topic.txt"), "topic\n").expect("fixture should be writable");
    require_git(&repository, &["add", "topic.txt"]);
    require_git(&repository, &["commit", "-q", "-m", "topic work"]);

    let preview = core("git.pushPreview", &repository, json!({}));
    assert_eq!(preview["ok"], true, "response: {preview}");
    assert_eq!(preview["data"]["upstream"], Value::Null);
    assert_eq!(
        preview["data"]["commits"].as_array().map(Vec::len),
        Some(1),
        "the branch's own commit must appear in the preview: {preview}"
    );
    assert_eq!(preview["data"]["commits"][0]["subject"], "topic work");
}

/// Asserts the branch has no configured upstream. Issue #1272: creating a
/// feature branch from `origin/main` must not inherit `main` as its upstream.
fn assert_no_upstream(repository: &Path, branch: &str) {
    let lookup = git(
        repository,
        &[
            "rev-parse",
            "--abbrev-ref",
            &format!("{branch}@{{upstream}}"),
        ],
    );
    assert!(
        !lookup.status.success(),
        "{branch} unexpectedly tracks {:?}",
        String::from_utf8_lossy(&lookup.stdout).trim()
    );
}

/// Issues the same Core request shape the Windows client sends when the user
/// picks "new branch from <reference>" on a remote reference.
fn create_branch_from_remote(repository: &Path, name: &str, remote_branch: &str) -> Value {
    core(
        "git.write",
        repository,
        json!({
            "operation": "createBranch",
            "name": name,
            "gitReference": {
                "fullName": format!("refs/remotes/origin/{remote_branch}"),
                "shortName": format!("origin/{remote_branch}"),
                "kind": "remote"
            },
            "checkout": true
        }),
    )
}

/// Regression for issue #1272: the first push of a branch created from
/// `origin/main` must never update the remote `main`.
#[test]
fn branch_created_from_remote_main_does_not_track_main() {
    let fixture = GitFixture::new();
    let (repository, remote) = initialize_repository(&fixture);
    let main_oid_before =
        String::from_utf8_lossy(&git(&remote, &["rev-parse", "refs/heads/main"]).stdout)
            .trim()
            .to_string();

    let created = create_branch_from_remote(&repository, "feature/topic", "main");
    assert_eq!(created["ok"], true, "response: {created}");
    assert_eq!(created["data"]["exitCode"], 0, "response: {created}");
    assert_no_upstream(&repository, "feature/topic");

    fs::write(repository.join("topic.txt"), "topic\n").expect("fixture should be writable");
    require_git(&repository, &["add", "topic.txt"]);
    require_git(&repository, &["commit", "-q", "-m", "topic work"]);

    let preview = core("git.pushPreview", &repository, json!({}));
    assert_eq!(preview["ok"], true, "response: {preview}");
    assert_eq!(preview["data"]["remote"], "origin");
    assert_eq!(preview["data"]["remoteBranch"], "feature/topic");
    assert_eq!(preview["data"]["upstream"], Value::Null);

    let pushed = core("git.write", &repository, json!({ "operation": "push" }));
    assert_eq!(pushed["ok"], true, "response: {pushed}");
    assert_eq!(pushed["data"]["exitCode"], 0, "response: {pushed}");

    assert!(
        git(
            &remote,
            &["show-ref", "--verify", "refs/heads/feature/topic"]
        )
        .status
        .success(),
        "the feature branch should be published to its own remote branch"
    );
    let main_oid_after =
        String::from_utf8_lossy(&git(&remote, &["rev-parse", "refs/heads/main"]).stdout)
            .trim()
            .to_string();
    assert_eq!(
        main_oid_after, main_oid_before,
        "push from the feature branch must not move remote main"
    );
}

/// Regression for issue #1272: an already divergent upstream
/// (`feature/topic` tracking `origin/main`) must not be pushed to silently.
#[test]
fn divergent_upstream_requires_an_explicit_choice() {
    let fixture = GitFixture::new();
    let (repository, remote) = initialize_repository(&fixture);
    let main_oid_before =
        String::from_utf8_lossy(&git(&remote, &["rev-parse", "refs/heads/main"]).stdout)
            .trim()
            .to_string();

    // Reproduce the state Git itself leaves behind with autoSetupMerge enabled.
    require_git(
        &repository,
        &[
            "switch",
            "-q",
            "-c",
            "feature/topic",
            "refs/remotes/origin/main",
        ],
    );
    require_git(
        &repository,
        &[
            "branch",
            "-q",
            "--set-upstream-to=origin/main",
            "feature/topic",
        ],
    );
    fs::write(repository.join("topic.txt"), "topic\n").expect("fixture should be writable");
    require_git(&repository, &["add", "topic.txt"]);
    require_git(&repository, &["commit", "-q", "-m", "topic work"]);

    let preview = core("git.pushPreview", &repository, json!({}));
    assert_eq!(preview["ok"], true, "response: {preview}");
    assert_eq!(preview["data"]["upstream"], "origin/main");
    assert_eq!(preview["data"]["targetKind"], "divergent");
    assert_eq!(preview["data"]["remoteBranch"], "feature/topic");
    assert_eq!(preview["data"]["createsRemoteBranch"], true);

    let refused = core("git.write", &repository, json!({ "operation": "push" }));
    assert!(
        refused["data"]["operationError"]["code"] == "invalid_request",
        "an unconfirmed divergent push must be refused: {refused}"
    );
    assert!(
        !git(
            &remote,
            &["show-ref", "--verify", "refs/heads/feature/topic"]
        )
        .status
        .success(),
        "a refused push must not publish the branch"
    );
    assert_eq!(
        String::from_utf8_lossy(
            &git(
                &repository,
                &["config", "--get", "branch.feature/topic.merge"]
            )
            .stdout
        )
        .trim(),
        "refs/heads/main",
        "a refused push must not rewrite the user's upstream configuration"
    );
    assert_eq!(
        String::from_utf8_lossy(&git(&remote, &["rev-parse", "refs/heads/main"]).stdout).trim(),
        main_oid_before,
        "a refused push must not move remote main"
    );
}

/// Issue #1272: after confirming "publish to the same-named branch", a divergent
/// branch lands on its own remote branch and points its upstream there, while the
/// branch it used to track stays untouched.
#[test]
fn confirmed_publish_redirects_a_divergent_branch() {
    let fixture = GitFixture::new();
    let (repository, remote) = initialize_repository(&fixture);
    let main_oid_before =
        String::from_utf8_lossy(&git(&remote, &["rev-parse", "refs/heads/main"]).stdout)
            .trim()
            .to_string();
    require_git(
        &repository,
        &[
            "switch",
            "-q",
            "-c",
            "feature/topic",
            "refs/remotes/origin/main",
        ],
    );
    require_git(
        &repository,
        &[
            "branch",
            "-q",
            "--set-upstream-to=origin/main",
            "feature/topic",
        ],
    );
    fs::write(repository.join("topic.txt"), "topic\n").expect("fixture should be writable");
    require_git(&repository, &["add", "topic.txt"]);
    require_git(&repository, &["commit", "-q", "-m", "topic work"]);

    let pushed = core(
        "git.write",
        &repository,
        json!({ "operation": "push", "pushTarget": "publish" }),
    );
    assert_eq!(pushed["ok"], true, "response: {pushed}");
    assert_eq!(pushed["data"]["exitCode"], 0, "response: {pushed}");

    assert!(
        git(
            &remote,
            &["show-ref", "--verify", "refs/heads/feature/topic"]
        )
        .status
        .success(),
        "the confirmed publish must create the same-named remote branch"
    );
    assert_eq!(
        String::from_utf8_lossy(&git(&remote, &["rev-parse", "refs/heads/main"]).stdout).trim(),
        main_oid_before,
        "publishing must not move remote main"
    );
    assert_eq!(
        String::from_utf8_lossy(
            &git(&repository, &["rev-parse", "--abbrev-ref", "@{upstream}"]).stdout
        )
        .trim(),
        "origin/feature/topic",
        "a successful publish repoints the upstream at the same-named branch"
    );
}

/// Issue #1272: confirming "keep the existing upstream" must still be possible,
/// because some users intentionally publish a branch under another name.
#[test]
fn confirmed_upstream_push_keeps_the_divergent_destination() {
    let fixture = GitFixture::new();
    let (repository, remote) = initialize_repository(&fixture);
    require_git(
        &repository,
        &[
            "switch",
            "-q",
            "-c",
            "feature/topic",
            "refs/remotes/origin/main",
        ],
    );
    require_git(
        &repository,
        &[
            "branch",
            "-q",
            "--set-upstream-to=origin/main",
            "feature/topic",
        ],
    );
    fs::write(repository.join("topic.txt"), "topic\n").expect("fixture should be writable");
    require_git(&repository, &["add", "topic.txt"]);
    require_git(&repository, &["commit", "-q", "-m", "topic work"]);

    let pushed = core(
        "git.write",
        &repository,
        json!({ "operation": "push", "pushTarget": "upstream" }),
    );
    assert_eq!(pushed["ok"], true, "response: {pushed}");
    assert_eq!(pushed["data"]["exitCode"], 0, "response: {pushed}");
    let remote_main =
        String::from_utf8_lossy(&git(&remote, &["rev-parse", "refs/heads/main"]).stdout)
            .trim()
            .to_string();
    let local_head = String::from_utf8_lossy(&git(&repository, &["rev-parse", "HEAD"]).stdout)
        .trim()
        .to_string();
    assert_eq!(
        remote_main, local_head,
        "an explicitly confirmed upstream push is the one path allowed to update a foreign branch: {pushed}"
    );
    assert_eq!(
        String::from_utf8_lossy(
            &git(
                &repository,
                &["config", "--get", "branch.feature/topic.merge"]
            )
            .stdout
        )
        .trim(),
        "refs/heads/main",
        "an intentional divergent upstream is preserved"
    );
}

/// Issue #1272: the confirmed upstream destination must be resolved with the same
/// remote/branch splitter the rest of the push path uses. An upstream short name is
/// `remote/branch` and either side may contain slashes, so taking the last segment
/// resolves a slashed branch name to the wrong remote branch.
#[test]
fn confirmed_upstream_push_resolves_a_slashed_branch_name() {
    let fixture = GitFixture::new();
    let (repository, remote) = initialize_repository(&fixture);
    require_git(&repository, &["remote", "rename", "origin", "team/origin"]);
    // Publish a remote branch whose own name contains slashes.
    require_git(
        &repository,
        &["push", "-q", "team/origin", "main:refs/heads/team/release"],
    );
    require_git(&repository, &["fetch", "-q", "team/origin"]);
    require_git(
        &repository,
        &[
            "switch",
            "-q",
            "-c",
            "feature/topic",
            "team/origin/team/release",
        ],
    );
    require_git(
        &repository,
        &[
            "branch",
            "-q",
            "--set-upstream-to=team/origin/team/release",
            "feature/topic",
        ],
    );
    fs::write(repository.join("topic.txt"), "topic\n").expect("fixture should be writable");
    require_git(&repository, &["add", "topic.txt"]);
    require_git(&repository, &["commit", "-q", "-m", "topic work"]);
    let local_head = String::from_utf8_lossy(&git(&repository, &["rev-parse", "HEAD"]).stdout)
        .trim()
        .to_string();

    let preview = core("git.pushPreview", &repository, json!({}));
    assert_eq!(preview["data"]["upstream"], "team/origin/team/release");
    assert_eq!(preview["data"]["targetKind"], "divergent");

    let pushed = core(
        "git.write",
        &repository,
        json!({ "operation": "push", "pushTarget": "upstream" }),
    );
    assert_eq!(pushed["ok"], true, "response: {pushed}");
    assert_eq!(pushed["data"]["exitCode"], 0, "response: {pushed}");

    let confirmed_remote_branch =
        String::from_utf8_lossy(&git(&remote, &["rev-parse", "refs/heads/team/release"]).stdout)
            .trim()
            .to_string();
    assert_eq!(
        confirmed_remote_branch, local_head,
        "the confirmed upstream branch receives the commit: {pushed}"
    );
    let misresolved =
        String::from_utf8_lossy(&git(&remote, &["rev-parse", "refs/heads/release"]).stdout)
            .trim()
            .to_string();
    assert_ne!(
        misresolved, local_head,
        "a mis-resolved destination branch must not receive the commit: {pushed}"
    );
    assert_eq!(
        String::from_utf8_lossy(
            &git(
                &repository,
                &["config", "--get", "branch.feature/topic.merge"]
            )
            .stdout
        )
        .trim(),
        "refs/heads/team/release",
        "an intentional divergent upstream is preserved"
    );
}

/// Builds the state Git itself leaves behind with `autoSetupMerge` enabled: a
/// feature branch with one commit of its own that tracks `origin/main`.
fn divergent_feature_branch(fixture: &GitFixture) -> (PathBuf, PathBuf) {
    let (repository, remote) = initialize_repository(fixture);
    require_git(
        &repository,
        &[
            "switch",
            "-q",
            "-c",
            "feature/topic",
            "refs/remotes/origin/main",
        ],
    );
    require_git(
        &repository,
        &[
            "branch",
            "-q",
            "--set-upstream-to=origin/main",
            "feature/topic",
        ],
    );
    fs::write(repository.join("topic.txt"), "topic\n").expect("fixture should be writable");
    require_git(&repository, &["add", "topic.txt"]);
    require_git(&repository, &["commit", "-q", "-m", "topic work"]);
    (repository, remote)
}

fn rev_parse(directory: &Path, revision: &str) -> String {
    String::from_utf8_lossy(&git(directory, &["rev-parse", revision]).stdout)
        .trim()
        .to_string()
}

/// The preview must describe the destination the user is about to choose, not a
/// fixed guess: the same request with each `pushTarget` shows the branch that
/// choice will update, so a confirmation can bind to what was displayed.
#[test]
fn preview_follows_the_chosen_destination_of_a_divergent_branch() {
    let fixture = GitFixture::new();
    let (repository, _) = divergent_feature_branch(&fixture);
    let main_oid = rev_parse(&repository, "origin/main");

    let upstream = core(
        "git.pushPreview",
        &repository,
        json!({ "pushTarget": "upstream" }),
    );
    assert_eq!(upstream["ok"], true, "response: {upstream}");
    assert_eq!(upstream["data"]["targetKind"], "divergent");
    assert_eq!(upstream["data"]["remote"], "origin");
    assert_eq!(upstream["data"]["remoteBranch"], "main");
    assert_eq!(upstream["data"]["upstream"], "origin/main");
    assert_eq!(upstream["data"]["createsRemoteBranch"], false);
    assert_eq!(upstream["data"]["remoteTrackingOid"], main_oid);

    let publish = core(
        "git.pushPreview",
        &repository,
        json!({ "pushTarget": "publish" }),
    );
    assert_eq!(publish["ok"], true, "response: {publish}");
    assert_eq!(publish["data"]["targetKind"], "divergent");
    assert_eq!(publish["data"]["remoteBranch"], "feature/topic");
    assert_eq!(publish["data"]["createsRemoteBranch"], true);
    assert_eq!(publish["data"]["remoteTrackingOid"], Value::Null);
}

/// Reviewed push bound to the upstream choice: the lease must be taken on the
/// upstream branch the user saw, not on the same-named branch, otherwise the
/// "reviewed" force push would lease an unrelated (missing) ref.
#[test]
fn reviewed_force_push_to_the_chosen_upstream_leases_that_branch() {
    let fixture = GitFixture::new();
    let (repository, remote) = divergent_feature_branch(&fixture);
    let main_oid = rev_parse(&repository, "origin/main");
    let local_head = rev_parse(&repository, "HEAD");

    let preview = core(
        "git.pushPreview",
        &repository,
        json!({ "pushTarget": "upstream" }),
    );
    let pushed = core(
        "git.write",
        &repository,
        json!({
            "operation": "push",
            "pushTarget": "upstream",
            "force": true,
            "expectedPush": push_expectation(&preview)
        }),
    );
    assert_eq!(pushed["ok"], true, "response: {pushed}");
    assert_eq!(pushed["data"]["exitCode"], 0, "response: {pushed}");
    let arguments = pushed["data"]["arguments"]
        .as_array()
        .expect("push arguments should be present")
        .iter()
        .filter_map(Value::as_str)
        .collect::<Vec<_>>();
    let lease = format!("--force-with-lease=refs/heads/main:{main_oid}");
    assert!(
        arguments.contains(&lease.as_str()),
        "the lease must name the upstream branch and its observed oid: {arguments:?}"
    );
    assert_eq!(rev_parse(&remote, "refs/heads/main"), local_head);
}

/// The exact stale-preview hole from review: the user reviews "update
/// `origin/main`", then the upstream is repointed at another remote branch before
/// the push. The reviewed push must be rejected, because the effective
/// destination is no longer the one that was shown.
#[test]
fn reviewed_upstream_push_is_rejected_when_the_upstream_moves() {
    let fixture = GitFixture::new();
    let (repository, remote) = divergent_feature_branch(&fixture);
    let main_before = rev_parse(&remote, "refs/heads/main");

    let preview = core(
        "git.pushPreview",
        &repository,
        json!({ "pushTarget": "upstream" }),
    );
    assert_eq!(preview["data"]["remoteBranch"], "main");

    // Same commit on both branches, so only the branch name can tell them apart.
    require_git(
        &repository,
        &["push", "-q", "origin", "main:refs/heads/release"],
    );
    require_git(&repository, &["fetch", "-q", "origin"]);
    require_git(
        &repository,
        &[
            "branch",
            "-q",
            "--set-upstream-to=origin/release",
            "feature/topic",
        ],
    );

    let pushed = core(
        "git.write",
        &repository,
        json!({
            "operation": "push",
            "pushTarget": "upstream",
            "expectedPush": push_expectation(&preview)
        }),
    );
    assert_eq!(
        pushed["data"]["operationError"]["message"],
        "Git push preview is stale; refresh and try again.",
        "response: {pushed}"
    );
    assert_eq!(rev_parse(&remote, "refs/heads/main"), main_before);
    assert_eq!(rev_parse(&remote, "refs/heads/release"), main_before);
}

/// A confirmation answers one question. Reusing a "publish" preview with the
/// "upstream" choice (or the reverse) is a different destination and must be stale.
#[test]
fn reviewed_push_rejects_a_different_destination_choice() {
    let fixture = GitFixture::new();
    let (repository, remote) = divergent_feature_branch(&fixture);
    let main_before = rev_parse(&remote, "refs/heads/main");

    let publish_preview = core(
        "git.pushPreview",
        &repository,
        json!({ "pushTarget": "publish" }),
    );
    let pushed = core(
        "git.write",
        &repository,
        json!({
            "operation": "push",
            "pushTarget": "upstream",
            "expectedPush": push_expectation(&publish_preview)
        }),
    );
    assert_eq!(
        pushed["data"]["operationError"]["message"],
        "Git push preview is stale; refresh and try again.",
        "response: {pushed}"
    );
    assert_eq!(rev_parse(&remote, "refs/heads/main"), main_before);
}

/// Choices only mean something for a divergent upstream: a routine branch keeps
/// pushing to its own tracked branch no matter what a stale client sends.
#[test]
fn push_target_choice_is_ignored_for_a_branch_that_tracks_its_own_name() {
    let fixture = GitFixture::new();
    let (repository, remote) = initialize_repository(&fixture);
    fs::write(repository.join("tracked.txt"), "initial\nsecond\n")
        .expect("fixture should be writable");
    require_git(&repository, &["commit", "-q", "-am", "second"]);

    for choice in ["publish", "upstream"] {
        let preview = core(
            "git.pushPreview",
            &repository,
            json!({ "pushTarget": choice }),
        );
        assert_eq!(preview["data"]["targetKind"], "tracking", "{choice}");
        assert_eq!(preview["data"]["remoteBranch"], "main", "{choice}");
    }
    let pushed = core(
        "git.write",
        &repository,
        json!({ "operation": "push", "pushTarget": "publish" }),
    );
    assert_eq!(pushed["data"]["exitCode"], 0, "response: {pushed}");
    assert_eq!(
        rev_parse(&remote, "refs/heads/main"),
        rev_parse(&repository, "HEAD")
    );
}

/// Issue #1272 asks whether new worktrees carry the same implicit-tracking risk.
/// The worktree path already freezes tracking explicitly: a remote start tracks
/// that remote branch, and an explicit commit start does not track anything.
#[test]
fn new_worktree_freezes_tracking_semantics() {
    let fixture = GitFixture::new();
    let (repository, _) = initialize_repository(&fixture);
    require_git(&repository, &["switch", "-q", "-c", "topic"]);
    fs::write(repository.join("topic.txt"), "topic\n").expect("fixture should be writable");
    require_git(&repository, &["add", "topic.txt"]);
    require_git(&repository, &["commit", "-q", "-m", "topic work"]);
    require_git(&repository, &["push", "-q", "-u", "origin", "topic"]);
    require_git(&repository, &["switch", "-q", "main"]);

    let remote_worktree = fixture.root.join("worktree-remote");
    let from_remote = core(
        "git.write",
        &repository,
        json!({
            "operation": "createWorktree",
            "destination": remote_worktree.to_string_lossy(),
            "name": "feature/from-remote",
            "gitReference": {
                "fullName": "refs/remotes/origin/topic",
                "shortName": "origin/topic",
                "kind": "remote"
            }
        }),
    );
    assert_eq!(from_remote["ok"], true, "response: {from_remote}");
    assert_eq!(
        from_remote["data"]["exitCode"], 0,
        "response: {from_remote}"
    );
    assert_eq!(
        String::from_utf8_lossy(
            &git(
                &repository,
                &[
                    "rev-parse",
                    "--abbrev-ref",
                    "feature/from-remote@{upstream}"
                ]
            )
            .stdout
        )
        .trim(),
        "origin/topic",
        "a remote-started worktree branch keeps tracking that remote branch"
    );

    let head_oid = String::from_utf8_lossy(&git(&repository, &["rev-parse", "HEAD"]).stdout)
        .trim()
        .to_string();
    let pinned_worktree = fixture.root.join("worktree-pinned");
    let from_commit = core(
        "git.write",
        &repository,
        json!({
            "operation": "createWorktree",
            "destination": pinned_worktree.to_string_lossy(),
            "name": "feature/from-commit",
            "gitReference": {
                "fullName": "refs/heads/main",
                "shortName": "main",
                "kind": "local"
            },
            "revision": head_oid
        }),
    );
    assert_eq!(from_commit["ok"], true, "response: {from_commit}");
    assert_eq!(
        from_commit["data"]["exitCode"], 0,
        "response: {from_commit}"
    );
    assert_no_upstream(&repository, "feature/from-commit");
}
