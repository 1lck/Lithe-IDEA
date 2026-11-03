//! Resolves native Git metadata ownership for nested repositories and linked workspaces.

use lithe_core::execute_json;
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

struct GitFixture {
    root: PathBuf,
}

impl GitFixture {
    fn new(label: &str) -> Self {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock should be valid")
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "lithe-git-watch-{label}-{}-{nonce}",
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

fn git(directory: &Path, arguments: &[&str]) -> Vec<u8> {
    git_within(directory, arguments, Duration::from_secs(10))
}

fn git_within(directory: &Path, arguments: &[&str], timeout: Duration) -> Vec<u8> {
    let deadline = Instant::now() + timeout;
    let output = lithe_git_host::run(
        Command::new("git").args(arguments).current_dir(directory),
        None,
        || Instant::now() >= deadline,
        || {},
        |_, _| {},
    );
    assert!(
        output.failure.is_none() && output.status.is_some_and(|status| status.success()),
        "git {} failed: {:?}; stderr: {}",
        arguments.join(" "),
        output.failure,
        String::from_utf8_lossy(&output.stderr)
    );
    output.stdout
}

fn require_git(directory: &Path, arguments: &[&str]) {
    git(directory, arguments);
}

fn initialize_repository(root: &Path) {
    fs::create_dir_all(root).expect("repository should be creatable");
    require_git(root, &["init", "-q", "-b", "main"]);
    // Keep identity/signing fixture-local without two extra native processes per repository.
    let config = root.join(".git/config");
    let mut contents = fs::read_to_string(&config).expect("Git configuration should exist");
    contents.push_str("\n[user]\n\temail = tests@lithe.local\n\tname = Lithe Tests\n[commit]\n\tgpgsign = false\n");
    fs::write(config, contents).expect("fixture identity should be writable");
    fs::write(root.join("tracked.txt"), "initial\n").expect("tracked fixture should be writable");
    require_git(root, &["add", "tracked.txt"]);
    require_git(root, &["commit", "-q", "-m", "initial"]);
}

fn absolute_git_path(root: &Path, arguments: &[&str]) -> String {
    let output = git(root, arguments);
    let path = String::from_utf8(output)
        .expect("Git path should be UTF-8")
        .trim()
        .to_string();
    contract_path(Path::new(&path))
}

fn contract_path(path: &Path) -> String {
    let canonical = fs::canonicalize(path).expect("Git path should exist");
    let text = canonical.to_string_lossy();
    if let Some(network_path) = text.strip_prefix(r"\\?\UNC\") {
        return format!(r"\\{network_path}");
    }
    text.strip_prefix(r"\\?\")
        .unwrap_or(text.as_ref())
        .to_string()
}

fn watch_context(root: &Path) -> Value {
    let request = json!({
        "id": "git-watch-context",
        "command": "git.watchContext",
        "timeoutMilliseconds": 5000,
        "payload": { "root": root }
    });
    serde_json::from_str(&execute_json(
        &serde_json::to_string(&request).expect("watch context request should encode"),
    ))
    .expect("watch context response should be JSON")
}

fn assert_context(
    response: &Value,
    repository_root: &Path,
    git_directory: &str,
    git_common_directory: &str,
) {
    assert_eq!(response["ok"], true, "response: {response}");
    assert_eq!(
        response["data"]["repositoryRoot"],
        contract_path(repository_root)
    );
    assert_eq!(response["data"]["gitDirectory"], git_directory);
    assert_eq!(response["data"]["gitCommonDirectory"], git_common_directory);
}

#[test]
fn watch_context_resolves_an_ordinary_repository_from_a_nested_workspace() {
    let fixture = GitFixture::new("nested-workspace");
    let repository = fixture.root.join("repository");
    initialize_repository(&repository);
    let workspace = repository.join("apps/editor");
    fs::create_dir_all(&workspace).expect("nested workspace should be creatable");

    let git_directory = absolute_git_path(&workspace, &["rev-parse", "--absolute-git-dir"]);
    let git_common_directory = absolute_git_path(
        &workspace,
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
    );
    let response = watch_context(&workspace);

    assert_context(
        &response,
        &repository,
        &git_directory,
        &git_common_directory,
    );
}

#[test]
fn watch_context_distinguishes_linked_worktree_git_and_common_directories() {
    let fixture = GitFixture::new("worktree");
    let repository = fixture.root.join("repository");
    let worktree = fixture.root.join("linked-worktree");
    initialize_repository(&repository);
    let worktree_path = worktree.to_string_lossy().into_owned();
    require_git(
        &repository,
        &[
            "worktree",
            "add",
            "-q",
            "-b",
            "watch-context",
            &worktree_path,
        ],
    );

    let git_directory = absolute_git_path(&worktree, &["rev-parse", "--absolute-git-dir"]);
    let git_common_directory = absolute_git_path(
        &worktree,
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
    );
    let response = watch_context(&worktree);

    assert_ne!(git_directory, git_common_directory);
    assert_context(&response, &worktree, &git_directory, &git_common_directory);
}

#[test]
fn watch_context_resolves_a_submodule_git_directory_outside_its_workspace() {
    let fixture = GitFixture::new("submodule");
    let source = fixture.root.join("source");
    let parent = fixture.root.join("parent");
    initialize_repository(&source);
    initialize_repository(&parent);
    let source_path = source.to_string_lossy().into_owned();
    // Windows runners clone the submodule slower than the 10 second default; the test budget is 30 seconds.
    git_within(
        &parent,
        &[
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "add",
            "-q",
            &source_path,
            "modules/child",
        ],
        Duration::from_secs(30),
    );
    require_git(&parent, &["commit", "-q", "-am", "add submodule"]);
    let submodule = parent.join("modules/child");

    let git_directory = absolute_git_path(&submodule, &["rev-parse", "--absolute-git-dir"]);
    let git_common_directory = absolute_git_path(
        &submodule,
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
    );
    let response = watch_context(&submodule);

    assert_eq!(git_directory, git_common_directory);
    assert!(!Path::new(&git_directory).starts_with(&submodule));
    assert_context(&response, &submodule, &git_directory, &git_common_directory);
}

#[test]
fn watch_context_resolves_a_separate_git_directory() {
    let fixture = GitFixture::new("separate-git-dir");
    let workspace = fixture.root.join("workspace");
    let external_git_directory = fixture.root.join("metadata/repository.git");
    fs::create_dir_all(
        external_git_directory
            .parent()
            .expect("external Git directory should have a parent"),
    )
    .expect("metadata parent should be creatable");
    let separate_argument = format!(
        "--separate-git-dir={}",
        external_git_directory.to_string_lossy()
    );
    let workspace_path = workspace.to_string_lossy().into_owned();
    require_git(
        &fixture.root,
        &["init", "-q", &separate_argument, &workspace_path],
    );

    let git_directory = absolute_git_path(&workspace, &["rev-parse", "--absolute-git-dir"]);
    let git_common_directory = absolute_git_path(
        &workspace,
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
    );
    let response = watch_context(&workspace);

    assert_eq!(git_directory, git_common_directory);
    assert!(!Path::new(&git_directory).starts_with(&workspace));
    assert_context(&response, &workspace, &git_directory, &git_common_directory);
}

#[test]
fn watch_context_returns_no_repository_for_a_plain_directory() {
    let fixture = GitFixture::new("plain-directory");
    let response = watch_context(&fixture.root);

    assert_eq!(response["ok"], true, "response: {response}");
    assert!(response["data"].is_null());
}
