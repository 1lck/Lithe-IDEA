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
    discover_with(root, &[], &[])
}

fn discover_with(root: &Path, excluded: &[&str], roots: &[&Path]) -> Vec<String> {
    data(
        "workspace.repositories",
        json!({
            "root": root, "manualExcludedDirectories": excluded, "workspaceRoots": roots,
        }),
    )["repositories"]
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
    let patterns = fixture["gitIgnorePatterns"]
        .as_array()
        .unwrap()
        .iter()
        .map(|value| value.as_str().unwrap())
        .collect::<Vec<_>>()
        .join("\n");
    fs::write(workspace.0.join(".gitignore"), patterns).unwrap();
    fs::write(
        workspace.0.join(".build/checkouts/SwiftTerm/local.txt"),
        "generated change",
    )
    .unwrap();
    let excluded = fixture["manualExcludedDirectories"]
        .as_array()
        .unwrap()
        .iter()
        .map(|value| value.as_str().unwrap())
        .collect::<Vec<_>>();
    let actual = discover_with(&workspace.0, &excluded, &[]);
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
    fs::write(root.join(".gitignore"), ".worktrees/\n").unwrap();
    assert_eq!(discover(&root), expected[..2]);
    assert_eq!(
        discover_with(&root, &[".worktree"], &[]),
        vec![canonical(&root)]
    );
    let explicit = root.join(".worktrees/topic");
    assert_eq!(discover(&explicit), vec![canonical(&explicit)]);
}

#[test]
fn discovery_filters_ignored_and_manual_roots_without_filtering_parent_changes() {
    let workspace = Workspace::new();
    let root = workspace.initialize(".");
    workspace.initialize("test/test2");
    workspace.initialize("manual/project");
    let visible = workspace.initialize("visible");
    workspace.initialize("visible/ignored-child");
    fs::write(root.join(".gitignore"), "test\n").unwrap();
    fs::write(visible.join(".gitignore"), "ignored-child/\n").unwrap();
    fs::write(root.join("manual/tracked.txt"), "tracked").unwrap();
    git(&root, &["add", "--", "manual/tracked.txt"]);
    fs::write(root.join("manual/tracked.txt"), "modified").unwrap();
    fs::write(root.join("manual/untracked.txt"), "untracked").unwrap();
    let roots = discover_with(&root, &["manual"], &[]);
    assert_eq!(roots, vec![canonical(&root), canonical(&visible)]);
    let status = data(
        "git.status",
        json!({"root": root, "repositoryRoots": roots}),
    );
    let paths = status["changes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|change| change["path"].as_str().unwrap())
        .collect::<Vec<_>>();
    assert!(paths.contains(&"manual/tracked.txt"), "{status}");
    assert!(paths.contains(&"manual/untracked.txt"), "{status}");
    assert_eq!(discover(&root).len(), 3);
    fs::write(root.join(".gitignore"), "").unwrap();
    assert_eq!(discover(&root).len(), 4);
}

#[test]
fn discovery_uses_native_negations_local_excludes_and_independent_explicit_roots() {
    let workspace = Workspace::new();
    let root = workspace.initialize(".");
    let included = workspace.initialize("projects/keep");
    let ignored = workspace.initialize("projects/skip");
    let local = workspace.initialize("local");
    fs::write(root.join(".gitignore"), "projects/*\n!projects/keep/\n").unwrap();
    fs::create_dir_all(root.join(".git/info")).unwrap();
    fs::write(root.join(".git/info/exclude"), "local/\n").unwrap();
    assert_eq!(
        discover(&root),
        vec![canonical(&root), canonical(&included)]
    );
    assert_eq!(discover(&ignored), vec![canonical(&ignored)]);
    assert_eq!(discover(&local), vec![canonical(&local)]);
}

#[test]
fn discovery_delegates_nested_workspace_roots_to_their_own_policy() {
    let workspace = Workspace::new();
    let root = workspace.initialize(".");
    let nested = workspace.initialize("nested");
    let child = workspace.initialize("nested/child");
    let roots = [&root as &Path, &nested as &Path];
    assert_eq!(discover_with(&root, &[], &roots), vec![canonical(&root)]);
    assert_eq!(
        discover_with(&nested, &["child"], &roots),
        vec![canonical(&nested)]
    );
    assert_eq!(
        discover_with(&nested, &[], &roots),
        vec![canonical(&nested), canonical(&child)]
    );
    assert_eq!(
        discover_with(&root, &["nested"], &roots),
        vec![canonical(&root)]
    );
    assert_eq!(discover(&root).len(), 3);
}

#[test]
fn discovery_keeps_index_registered_submodules_inside_excluded_containers() {
    let workspace = Workspace::new();
    let root = workspace.initialize(".");
    let module = workspace.initialize("excluded/module");
    workspace.initialize("excluded/ordinary");
    git(
        &module,
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
    let revision = data(
        "git.command",
        json!({"root": module, "arguments": ["rev-parse", "HEAD"]}),
    );
    let entry = format!(
        "160000,{},excluded/module",
        revision["stdout"].as_str().unwrap().trim()
    );
    git(&root, &["update-index", "--add", "--cacheinfo", &entry]);
    fs::write(root.join(".gitignore"), "excluded/\n").unwrap();
    assert_eq!(
        discover_with(&root, &["excluded"], &[]),
        vec![canonical(&root), canonical(&module)]
    );
}

#[test]
fn discovery_reports_invalid_rules_and_git_failures_instead_of_empty_success() {
    let workspace = Workspace::new();
    let root = workspace.initialize(".");
    for path in ["../outside", "/outside", "bad\0path"] {
        let response: Value = serde_json::from_str(&execute_json(
            &json!({
                "command": "workspace.repositories", "timeoutMilliseconds": 5000,
                "payload": {"root": root, "manualExcludedDirectories": [path]},
            })
            .to_string(),
        ))
        .unwrap();
        assert_eq!(response["ok"], false, "{response}");
        assert_eq!(response["error"]["code"], "invalid_request", "{response}");
    }
    fs::write(root.join(".git/config"), "[invalid\n").unwrap();
    let response: Value = serde_json::from_str(&execute_json(&json!({
        "command": "workspace.repositories", "timeoutMilliseconds": 5000, "payload": {"root": root},
    }).to_string())).unwrap();
    assert_eq!(response["ok"], false, "{response}");
    assert_eq!(response["error"]["code"], "process_failed", "{response}");
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
