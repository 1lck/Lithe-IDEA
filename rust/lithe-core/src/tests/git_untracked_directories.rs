use super::support::temporary_root;
use crate::execute_json;
use crate::git::UNTRACKED_DIRECTORY_SUMMARY_THRESHOLD;
use serde_json::{json, Value};
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

// Real Git runs through Core's bounded process owner; Drop also cleans the
// fixture when an assertion fails.
struct Repository(PathBuf);

impl Repository {
    fn new(label: &str) -> Self {
        let root = temporary_root(label);
        fs::create_dir_all(&root).unwrap();
        let repository = Self(root);
        repository.git(&["init", "--template=", "-q", "-b", "main"]);
        repository.git(&["config", "core.autocrlf", "false"]);
        repository.write("tracked/kept.txt", "kept\n");
        repository.write(".gitignore", "*.log\n");
        repository.git(&["add", "."]);
        repository.git(&[
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.invalid",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-qm",
            "initial",
        ]);
        repository
    }

    fn write(&self, path: &str, contents: &str) {
        let path = self.0.join(path);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, contents).unwrap();
    }

    /// Writes `count` files spread over two directory levels below `directory`.
    fn write_many(&self, directory: &str, count: usize) {
        for index in 0..count {
            self.write(&format!("{directory}/deps/{index}.o"), "object\n");
        }
    }

    fn nested_repository(&self, path: &str) {
        let root = self.0.join(path);
        fs::create_dir_all(&root).unwrap();
        let output = Command::new("git")
            .args(["init", "--template=", "-q"])
            .current_dir(&root)
            .output()
            .unwrap();
        assert!(output.status.success());
        fs::write(root.join("inner.txt"), "inner\n").unwrap();
    }

    fn git(&self, arguments: &[&str]) {
        let result = data(
            "git.command",
            json!({"root": self.0, "arguments": arguments}),
        );
        assert_eq!(result["exitCode"], 0, "{result}");
    }
}

impl Drop for Repository {
    fn drop(&mut self) {
        if let Err(error) = fs::remove_dir_all(&self.0) {
            eprintln!("Could not remove untracked directory fixture: {error}");
        }
    }
}

fn data(command: &str, payload: Value) -> Value {
    let response: Value = serde_json::from_str(&execute_json(
        &json!({"command": command, "timeoutMilliseconds": 10_000, "payload": payload}).to_string(),
    ))
    .unwrap();
    assert_eq!(response["ok"], true, "{response}");
    response["data"].clone()
}

/// Returns `(path, untrackedFileCount)` for every reported change.
fn entries(changes: &Value) -> Vec<(String, Option<u64>)> {
    changes
        .as_array()
        .unwrap()
        .iter()
        .map(|change| {
            (
                change["path"].as_str().unwrap().to_string(),
                change["untrackedFileCount"].as_u64(),
            )
        })
        .collect()
}

fn status(root: &Path, summarize: bool) -> Value {
    data(
        "git.status",
        json!({"root": root, "summarizeUntrackedDirectories": summarize}),
    )
}

#[test]
fn status_summarizes_large_untracked_directories_and_keeps_small_ones_file_level() {
    // Regression for #1385: one unignored build directory produced one status
    // entry per artifact and flooded the changes panel.
    let repository = Repository::new("untracked-summary");
    let large = UNTRACKED_DIRECTORY_SUMMARY_THRESHOLD + 1;
    repository.write_many("rust/core/target", large);
    repository.write("rust/core/target/build.log", "ignored\n");
    repository.write("src/feature/a.rs", "a\n");
    repository.write("src/feature/b.rs", "b\n");
    repository.write("tracked/new.txt", "new\n");

    assert_eq!(
        entries(&status(&repository.0, true)["changes"]),
        [
            ("rust/".to_string(), Some(large as u64)),
            ("src/feature/a.rs".to_string(), None),
            ("src/feature/b.rs".to_string(), None),
            ("tracked/new.txt".to_string(), None),
        ]
    );
    // Omitting the flag keeps the file-level projection Windows consumes.
    let legacy = status(&repository.0, false);
    assert_eq!(legacy["changes"].as_array().unwrap().len(), large + 3);
    assert!(legacy["changes"][0].get("untrackedFileCount").is_none());
}

#[test]
fn status_never_summarizes_a_directory_containing_a_nested_repository() {
    // Staging `.worktrees/` as a unit would record linked checkouts as gitlinks.
    let repository = Repository::new("untracked-nested");
    repository.nested_repository(".worktrees/feature");
    repository.write_many(
        ".worktrees/cache",
        UNTRACKED_DIRECTORY_SUMMARY_THRESHOLD + 1,
    );
    repository.write(".worktrees/notes.txt", "notes\n");

    let summary = status(&repository.0, true);
    assert_eq!(
        entries(&summary["changes"]),
        [
            (
                ".worktrees/cache/".to_string(),
                Some(UNTRACKED_DIRECTORY_SUMMARY_THRESHOLD as u64 + 1)
            ),
            (".worktrees/feature/".to_string(), None),
            (".worktrees/notes.txt".to_string(), None),
        ]
    );

    // A discovered root is excluded exactly as in the file-level projection.
    let with_roots = data(
        "git.status",
        json!({
            "root": repository.0,
            "summarizeUntrackedDirectories": true,
            "repositoryRoots": [repository.0, repository.0.join(".worktrees/feature")],
        }),
    );
    assert!(!entries(&with_roots["changes"])
        .iter()
        .any(|(path, _)| path == ".worktrees/feature/"));
}

#[test]
fn untracked_directory_lists_one_level_with_subdirectory_summaries() {
    let repository = Repository::new("untracked-children");
    repository.write_many("target/debug", 3);
    repository.write("target/.rustc_info.json", "{}\n");
    repository.write("target/skip.log", "ignored\n");

    let children = data(
        "git.untrackedDirectory",
        json!({"root": repository.0, "directory": "target/"}),
    );
    assert_eq!(
        entries(&children["changes"]),
        [
            ("target/.rustc_info.json".to_string(), None),
            ("target/debug/".to_string(), Some(3)),
        ]
    );
    let child = &children["changes"][1];
    assert_eq!(child["status"], "??");
    assert_eq!(child["untracked"], true);
    assert_eq!(child["canToggleStaging"], true);

    let invalid: Value = serde_json::from_str(&execute_json(
        &json!({
            "command": "git.untrackedDirectory",
            "payload": {"root": repository.0, "directory": "../outside/"}
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(invalid["ok"], false, "{invalid}");
}

#[test]
fn summarized_directory_supports_diff_stage_and_discard_as_a_unit() {
    let repository = Repository::new("untracked-actions");
    repository.write("generated/a.txt", "alpha\n");
    repository.write("generated/nested/b.txt", "beta\n");

    // Shelve captures the directory's patch before cleaning it; an empty patch
    // here would silently lose the files.
    let diff = data(
        "git.diff",
        json!({"root": repository.0, "pathspecs": ["generated/"], "untracked": true}),
    );
    let patch = diff["patch"].as_str().unwrap();
    assert!(patch.contains("+alpha"), "{patch}");
    assert!(patch.contains("+beta"), "{patch}");

    let discarded = data(
        "git.write",
        json!({"root": repository.0, "operation": "discardAll", "paths": ["generated/"]}),
    );
    assert_eq!(discarded["exitCode"], 0, "{discarded}");
    assert!(!repository.0.join("generated/a.txt").exists());
    assert!(!repository.0.join("generated/nested/b.txt").exists());

    repository.write("generated/c.txt", "gamma\n");
    let staged = data(
        "git.write",
        json!({"root": repository.0, "operation": "stage", "paths": ["generated/"]}),
    );
    assert_eq!(staged["exitCode"], 0, "{staged}");
    assert_eq!(
        entries(&status(&repository.0, true)["changes"]),
        [("generated/c.txt".to_string(), None)]
    );
}

// `:` cannot appear in a Windows file name.
#[cfg(not(windows))]
#[test]
fn summarized_directory_diff_fails_instead_of_dropping_a_file_it_cannot_export() {
    let repository = Repository::new("untracked-unexportable");
    repository.write("generated/a.txt", "alpha\n");
    repository.write("generated/bad:name.txt", "kept\n");

    // Shelve would save the patch and then clean `generated/`, so a patch
    // without `bad:name.txt` would delete that file without a copy.
    let response: Value = serde_json::from_str(&execute_json(
        &json!({
            "command": "git.diff",
            "timeoutMilliseconds": 10_000,
            "payload": {"root": repository.0, "pathspecs": ["generated/"], "untracked": true},
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(response["ok"], false, "{response}");
    assert!(repository.0.join("generated/bad:name.txt").exists());
}
