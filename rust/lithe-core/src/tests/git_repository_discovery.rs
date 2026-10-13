use super::support::temporary_root;
use crate::execute_json;
use serde_json::{json, Value};
use std::{
    fs,
    path::{Path, PathBuf},
};

// Real Git runs through Core's bounded process owner; Drop also cleans fixtures
// when an assertion fails. The timed runner bounds each complete integration case.
struct Workspace(PathBuf);

impl Workspace {
    fn new() -> Self {
        let root = temporary_root("repository-discovery");
        fs::create_dir_all(&root).unwrap();
        Self(root)
    }

    fn initialize(&self, path: &str) -> PathBuf {
        let root = self.0.join(path);
        fs::create_dir_all(&root).unwrap();
        git(&root, &["init", "--template=", "-q", "-b", "main"]);
        root
    }
}

impl Drop for Workspace {
    fn drop(&mut self) {
        if let Err(error) = fs::remove_dir_all(&self.0) {
            eprintln!("Could not remove repository discovery fixture: {error}");
        }
    }
}

fn data(command: &str, payload: Value) -> Value {
    let response: Value = serde_json::from_str(&execute_json(
        &json!({
            "command": command, "timeoutMilliseconds": 5000, "payload": payload
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(response["ok"], true, "{response}");
    response["data"].clone()
}

fn git(root: &Path, arguments: &[&str]) {
    let result = data("git.command", json!({"root": root, "arguments": arguments}));
    assert_eq!(result["exitCode"], 0, "{result}");
}

fn discover(root: &Path) -> Vec<String> {
    data("workspace.repositories", json!({"root": root}))["repositories"]
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| entry["path"].as_str().unwrap().to_owned())
        .collect()
}

fn canonical(root: &Path) -> String {
    crate::git::simplified_canonical_path(root.canonicalize().unwrap())
        .unwrap()
        .to_string_lossy()
        .replace('\\', "/")
}

fn fixture() -> Value {
    serde_json::from_str(include_str!(
        "../../../../shared/fixtures/workspace/repository-visibility-v1.json"
    ))
    .unwrap()
}

#[test]
fn discovery_excludes_hidden_and_generated_repositories_before_status_aggregation() {
    let workspace = Workspace::new();
    let fixture = fixture();
    for path in fixture["repositoryPaths"].as_array().unwrap() {
        workspace.initialize(path.as_str().unwrap());
    }
    fs::write(workspace.0.join(".gitignore"), ".build/\nmacos/.build/\n").unwrap();
    fs::write(
        workspace.0.join(".build/checkouts/SwiftTerm/local.txt"),
        "generated change",
    )
    .unwrap();
    let actual = discover(&workspace.0);
    let expected: Vec<_> = fixture["expectedRepositoryPaths"]
        .as_array()
        .unwrap()
        .iter()
        .map(|path| canonical(&workspace.0.join(path.as_str().unwrap())))
        .collect();
    assert_eq!(actual, expected);
    // The parent ignores its cache and no dependency root is handed to the
    // product's status aggregation. This must not merely hide reference rows.
    let status = data(
        "git.status",
        json!({"root": workspace.0, "repositoryRoots": actual}),
    );
    assert!(!status["changes"]
        .as_array()
        .unwrap()
        .iter()
        .any(|change| change["path"].as_str().unwrap().starts_with(".build/")));
}

#[test]
fn discovery_honors_explicit_hidden_roots_and_their_visible_nested_repositories() {
    let workspace = Workspace::new();
    for path in fixture()["explicitRepositoryPaths"].as_array().unwrap() {
        let path = path.as_str().unwrap();
        let root = workspace.initialize(path);
        let child = workspace.initialize(&format!("{path}/source"));
        workspace.initialize(&format!("{path}/.build/dependency"));
        assert_eq!(discover(&root), vec![canonical(&root), canonical(&child)]);
        let subdirectory = root.join("src");
        fs::create_dir_all(&subdirectory).unwrap();
        assert_eq!(discover(&subdirectory), vec![canonical(&root)]);
    }
}

#[test]
fn discovery_preserves_linked_worktrees_but_excludes_their_build_checkouts() {
    let workspace = Workspace::new();
    let root = workspace.initialize(".");
    git(
        &root,
        &[
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.invalid",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "--allow-empty",
            "-qm",
            "initial",
        ],
    );
    let mut expected = vec![canonical(&root)];
    for container in [".worktree", ".worktrees"] {
        let checkout = root.join(container).join("topic");
        git(
            &root,
            &[
                "worktree",
                "add",
                "--detach",
                "-q",
                checkout.to_str().unwrap(),
                "HEAD",
            ],
        );
        assert!(checkout.join(".git").is_file());
        expected.push(canonical(&checkout));
        workspace.initialize(&format!("{container}/topic/.build/checkouts/dependency"));
    }
    assert_eq!(discover(&root), expected);
}

#[test]
fn discovery_respects_explicit_depth_limits() {
    let workspace = Workspace::new();
    let root = workspace.initialize(".");
    workspace.initialize("source/nested");
    assert_eq!(
        data(
            "workspace.repositories",
            json!({"root": root, "maxDepth": 0})
        )["repositories"],
        json!([{"path": canonical(&root)}])
    );
}

#[cfg(unix)]
#[test]
fn discovery_does_not_follow_directory_symlinks() {
    let workspace = Workspace::new();
    let outside = Workspace::new();
    let root = workspace.initialize(".");
    outside.initialize(".");
    std::os::unix::fs::symlink(&outside.0, root.join("external")).unwrap();
    std::os::unix::fs::symlink(&root, root.join("cycle")).unwrap();
    assert_eq!(discover(&root), vec![canonical(&root)]);
}
