//! Native repository paths must survive the actual Windows frontend normalizer.

use lithe_core::execute_json;
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

struct Fixture(PathBuf);

impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "lithe-path-roundtrip-{}-{}",
            std::process::id(),
            NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&root).unwrap();
        Self(root.canonicalize().unwrap())
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        // Canonical Windows paths keep the prefix for cleanup of dot/space fixtures.
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn run(command: &mut Command) -> String {
    // Git/Node startup can exceed five seconds on Windows CI. Keep a local
    // deadline inside the timing harness's 15-second case watchdog.
    let deadline = Instant::now() + Duration::from_secs(10);
    let result = lithe_git_host::run(
        command,
        None,
        || Instant::now() >= deadline,
        || {},
        |_, _| {},
    );
    assert!(
        result.failure.is_none(),
        "{command:?}: {:?}",
        result.failure
    );
    assert!(
        result.status.is_some_and(|status| status.success()),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    String::from_utf8(result.stdout)
        .unwrap()
        .trim_end_matches(['\r', '\n'])
        .to_owned()
}

fn git(root: &Path, arguments: &[&str]) -> String {
    run(Command::new("git")
        .current_dir(root)
        .args(["-c", "core.longpaths=true", "-c", "commit.gpgsign=false"])
        .args(arguments))
}

fn request(command: &str, root: &str) -> Value {
    serde_json::from_str(&execute_json(
        &json!({
            "command": command,
            "timeoutMilliseconds": 5000,
            "payload": { "root": root }
        })
        .to_string(),
    ))
    .unwrap()
}

fn data(command: &str, root: &str) -> Value {
    let result = request(command, root);
    assert_eq!(result["ok"], true, "{result}");
    result["data"].clone()
}

fn frontend_path(path: &str) -> String {
    let module = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../windows/tauri/src/features/git/api/git-repository-path.ts");
    // Node is already required by both platform timing harnesses. Import the
    // production TypeScript function rather than duplicating it in Rust.
    run(Command::new("node").args([
        "--experimental-strip-types", "--input-type=module", "-e",
        "import { pathToFileURL } from 'node:url'; const { normalizeRepositoryPath } = await import(pathToFileURL(process.argv[1]).href); console.log(normalizeRepositoryPath(process.argv[2]));",
        module.to_str().unwrap(), path,
    ]))
}

fn initialize(root: &Path) -> String {
    fs::create_dir_all(root).unwrap();
    git(root, &["init", "-q", "-b", "main"]);
    git(root, &["config", "user.email", "fixture@example.invalid"]);
    git(root, &["config", "user.name", "Path Fixture"]);
    git(root, &["config", "core.longpaths", "true"]);
    fs::write(root.join("tracked.txt"), "initial\n").unwrap();
    git(root, &["add", "tracked.txt"]);
    git(root, &["commit", "-q", "-m", "path identity fixture"]);
    git(root, &["rev-parse", "HEAD"])
}

fn assert_roundtrip(root: &Path, commit: &str) -> String {
    let discovered = data("git.repositoryRoot", root.to_str().unwrap());
    let normalized = frontend_path(discovered.as_str().unwrap());
    let history = data("git.history", &normalized);
    assert!(history["commits"]
        .as_array()
        .unwrap()
        .iter()
        .any(|entry| entry["hash"] == commit));
    let references = data("git.references", &normalized);
    assert!(references["references"]
        .as_array()
        .unwrap()
        .iter()
        .any(|entry| entry["fullName"] == "refs/heads/main"));
    normalized
}

#[test]
fn git_paths_roundtrip_unicode_spaces_and_linked_worktree() {
    let fixture = Fixture::new();
    let root = fixture.0.join("项目 with spaces");
    let first = initialize(&root);
    fs::write(root.join("tracked.txt"), "stash contents\n").unwrap();
    git(&root, &["stash", "push", "-q", "-m", "path-stash-marker"]);
    let normalized = assert_roundtrip(&root, &first);
    let stashes = data("git.stashes", &normalized);
    assert!(stashes["stashes"]
        .as_array()
        .unwrap()
        .iter()
        .any(|entry| entry["message"]
            .as_str()
            .unwrap()
            .contains("path-stash-marker")));

    let linked = fixture.0.join("linked 工作树");
    // Product consumers pass ordinary paths to native Git, not the verbatim
    // prefix used by this fixture for Windows filesystem cleanup.
    let linked_argument = frontend_path(linked.to_str().unwrap());
    git(
        &root,
        &["worktree", "add", "-q", "-b", "linked", &linked_argument],
    );
    let linked_normalized = assert_roundtrip(&linked, &first);
    let context = data("git.watchContext", &linked_normalized);
    assert_ne!(context["gitDirectory"], context["gitCommonDirectory"]);
    assert!(Path::new(context["gitDirectory"].as_str().unwrap())
        .join("HEAD")
        .is_file());
    assert!(Path::new(context["gitCommonDirectory"].as_str().unwrap())
        .join("refs/heads/main")
        .is_file());

    // A native external commit/checkout must be visible through the same root.
    git(
        &linked,
        &["commit", "--allow-empty", "-q", "-m", "external change"],
    );
    let second = git(&linked, &["rev-parse", "HEAD"]);
    assert_roundtrip(&linked, &second);
    git(&linked, &["checkout", "-q", "--detach", &first]);
    let refreshed = data("git.watchContext", &linked_normalized);
    let head =
        fs::read_to_string(Path::new(refreshed["gitDirectory"].as_str().unwrap()).join("HEAD"))
            .unwrap();
    assert_eq!(head.trim(), first);
}

#[test]
fn git_paths_roundtrip_or_explicitly_reject_a_repository_beyond_max_path() {
    let fixture = Fixture::new();
    let source = fixture.0.join("source");
    let commit = initialize(&source);
    let mut root = fixture.0.clone();
    while root.as_os_str().len() <= 280 {
        root.push("long-path-segment");
    }
    fs::create_dir_all(root.parent().unwrap()).unwrap();
    fs::rename(&source, &root).unwrap();
    // Windows can create this directory using verbatim filesystem APIs while
    // CreateProcess still rejects it as a working directory (ERROR_DIRECTORY).
    // Seed the repository at a short path so this tests Core, not fixture setup.
    #[cfg(windows)]
    {
        let native = root.to_str().unwrap();
        let response = request("git.repositoryRoot", native);
        if response["ok"] == false {
            for path in [native.to_string(), frontend_path(native)] {
                let error = request("git.repositoryRoot", &path);
                assert_eq!(error["ok"], false, "{error}");
                assert_eq!(error["error"]["code"], "process_start_failed", "{error}");
                assert_eq!(error["error"]["message"], "Could not start Git", "{error}");
                assert!(
                    error["error"]["details"]
                        .as_str()
                        .unwrap()
                        .contains("os error 267"),
                    "{error}"
                );
            }
            assert!(root.join(".git/HEAD").is_file());
            return;
        }
    }
    assert_roundtrip(&root, &commit);
}

#[cfg(windows)]
#[test]
fn git_paths_reject_native_dot_and_space_names_without_aliasing_a_sibling() {
    let fixture = Fixture::new();
    let ordinary = fixture.0.join("repo");
    initialize(&ordinary);
    for name in ["repo.", "repo "] {
        let special = fixture.0.join(name);
        fs::create_dir(&special).unwrap();
        fs::write(special.join("marker"), name).unwrap();
        for command in [
            "git.repositoryRoot",
            "workspace.repositories",
            "git.status",
            "git.watchContext",
            "git.history",
            "git.stashes",
        ] {
            let response = request(command, special.to_str().unwrap());
            assert_eq!(response["ok"], false, "{command}: {response}");
            assert_eq!(
                response["error"]["code"], "invalid_request",
                "{command}: {response}"
            );
        }
        assert_eq!(fs::read_to_string(special.join("marker")).unwrap(), name);
        assert!(!ordinary.join("marker").exists());
    }
}
