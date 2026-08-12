use lithe_core::execute_json;
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

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

fn initialize_repository(root: &Path) {
    fs::create_dir_all(root).expect("repository should be creatable");
    require_git(root, &["init", "-q"]);
    require_git(root, &["config", "user.email", "tests@lithe.local"]);
    require_git(root, &["config", "user.name", "Lithe Tests"]);
    fs::write(root.join("tracked.txt"), "initial\n").expect("tracked fixture should be writable");
    require_git(root, &["add", "tracked.txt"]);
    require_git(root, &["commit", "-q", "-m", "initial"]);
}

fn absolute_git_path(root: &Path, arguments: &[&str]) -> String {
    let output = git(root, arguments);
    assert!(
        output.status.success(),
        "git {} failed: {}",
        arguments.join(" "),
        String::from_utf8_lossy(&output.stderr)
    );
    let path = String::from_utf8(output.stdout)
        .expect("Git path should be UTF-8")
        .trim()
        .to_string();
    fs::canonicalize(path)
        .expect("Git path should exist")
        .to_string_lossy()
        .into_owned()
}

fn watch_context(root: &Path) -> Value {
    let request = json!({
        "id": "git-watch-context",
        "command": "git.watchContext",
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
        fs::canonicalize(repository_root)
            .expect("repository root should exist")
            .to_string_lossy()
            .as_ref()
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
    require_git(
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
