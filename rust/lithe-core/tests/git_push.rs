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

#[test]
fn push_preview_and_write_share_destination_and_safe_options() {
    let fixture = GitFixture::new();
    let (repository, remote) = initialize_repository(&fixture);
    fs::write(repository.join("tracked.txt"), "initial\nsecond\n")
        .expect("tracked fixture should be writable");
    require_git(&repository, &["commit", "-q", "-am", "second"]);
    require_git(&repository, &["tag", "-a", "v1", "-m", "version one"]);

    let preview = core("git.pushPreview", &repository, json!({}));
    assert_eq!(preview["ok"], true, "response: {preview}");
    assert_eq!(preview["data"]["localBranch"], "main");
    assert_eq!(preview["data"]["remote"], "origin");
    assert_eq!(preview["data"]["remoteBranch"], "main");
    assert_eq!(preview["data"]["upstream"], "origin/main");
    assert_eq!(preview["data"]["commits"].as_array().map(Vec::len), Some(1));
    assert_eq!(preview["data"]["commits"][0]["subject"], "second");

    let pushed = core(
        "git.write",
        &repository,
        json!({
            "operation": "push",
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
    assert!(arguments.contains(&"--force-with-lease"));
    assert!(!arguments.contains(&"--force"));
    assert!(arguments.contains(&"--follow-tags"));
    assert!(arguments.contains(&"refs/heads/main:refs/heads/main"));

    let local_head = git(&repository, &["rev-parse", "HEAD"]);
    let remote_head = git(&remote, &["rev-parse", "refs/heads/main"]);
    assert_eq!(local_head.stdout, remote_head.stdout);
    require_git(&remote, &["show-ref", "--verify", "refs/tags/v1"]);
}

#[test]
fn push_preview_uses_default_remote_when_branch_has_no_upstream() {
    let fixture = GitFixture::new();
    let (repository, _) = initialize_repository(&fixture);
    require_git(&repository, &["branch", "--unset-upstream"]);
    fs::write(repository.join("local.txt"), "local\n").expect("local fixture should be writable");
    require_git(&repository, &["add", "local.txt"]);
    require_git(&repository, &["commit", "-q", "-m", "local only"]);

    let preview = core("git.pushPreview", &repository, json!({}));
    assert_eq!(preview["ok"], true, "response: {preview}");
    assert_eq!(preview["data"]["remote"], "origin");
    assert_eq!(preview["data"]["remoteBranch"], "main");
    assert!(preview["data"]["upstream"].is_null());
    assert_eq!(preview["data"]["commits"].as_array().map(Vec::len), Some(1));
    assert_eq!(preview["data"]["commits"][0]["subject"], "local only");
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
