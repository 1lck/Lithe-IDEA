use super::support::temporary_root;
use crate::execute_json;
use serde_json::Value;
use std::fs::{self, FileTimes, OpenOptions};
use std::path::Path;
use std::process::Command;
use std::time::{Duration, UNIX_EPOCH};

#[test]
fn git_status_returns_contract_shape() {
    let root = temporary_root("git");
    fs::create_dir_all(&root).expect("temporary repository should be creatable");
    let run = |arguments: &[&str]| {
        Command::new("git")
            .args(arguments)
            .current_dir(&root)
            .output()
            .expect("git should be available")
    };
    assert!(run(&["init", "-q"]).status.success());
    assert!(run(&["config", "core.autocrlf", "false"]).status.success());
    fs::write(root.join("new.txt"), "new").expect("test file should be writable");

    let request = serde_json::json!({
        "id": "git",
        "command": "git.status",
        "payload": {"root": root}
    });
    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&request).expect("Git request should encode"),
    ))
    .expect("Git response should be JSON");
    assert_eq!(response["ok"], true);
    assert_eq!(response["data"]["repositoryRoot"], ".");
    assert_eq!(response["data"]["ahead"], 0);
    assert_eq!(response["data"]["behind"], 0);
    assert_eq!(response["data"]["changes"][0]["path"], "new.txt");
    assert_eq!(response["data"]["changes"][0]["untracked"], true);

    fs::remove_dir_all(root).expect("temporary repository should be removable");
}

#[test]
fn git_status_preserves_both_paths_of_a_staged_rename() {
    let root = temporary_root("git-status-rename");
    fs::create_dir_all(&root).expect("temporary repository should be creatable");
    let run = |arguments: &[&str]| history_git(&root, arguments);
    assert!(run(&["init", "-q", "-b", "main"]).status.success());
    assert!(run(&["config", "core.autocrlf", "false"]).status.success());
    assert!(run(&["config", "user.email", "test@example.com"])
        .status
        .success());
    assert!(run(&["config", "user.name", "Lithe Test"]).status.success());
    fs::write(root.join("old-name.txt"), "content\n").expect("file should be writable");
    assert!(run(&["add", "old-name.txt"]).status.success());
    assert!(run(&["commit", "-qm", "initial"]).status.success());
    assert!(run(&["mv", "old-name.txt", "new-name.txt"])
        .status
        .success());

    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&serde_json::json!({
            "id": "git-status-rename",
            "command": "git.status",
            "payload": { "root": root }
        }))
        .expect("Git request should encode"),
    ))
    .expect("Git response should be JSON");

    assert_eq!(response["ok"], true, "{response:?}");
    assert_eq!(
        response["data"]["changes"].as_array().map(Vec::len),
        Some(1)
    );
    assert_eq!(response["data"]["changes"][0]["status"], "R ");
    assert_eq!(response["data"]["changes"][0]["path"], "new-name.txt");
    assert_eq!(
        response["data"]["changes"][0]["originalPath"],
        "old-name.txt"
    );

    fs::remove_dir_all(root).expect("temporary repository should be removable");
}

#[test]
fn git_diff_worktree_snapshot_matches_selected_path_commit_semantics() {
    let root = git_write_repository("git-diff-worktree-snapshot");
    let run = |arguments: &[&str]| history_git(&root, arguments);
    fs::write(root.join("recreated.txt"), "base\n").expect("file should be writable");
    fs::write(root.join("partial.txt"), "one\nbase\n").expect("file should be writable");
    assert!(run(&["add", "--all"]).status.success());
    assert!(run(&["commit", "-qm", "initial"]).status.success());

    assert!(run(&["rm", "--cached", "-q", "--", "recreated.txt"])
        .status
        .success());
    fs::write(root.join("recreated.txt"), "changed\n").expect("file should be writable");
    fs::write(root.join("partial.txt"), "staged\nbase\n").expect("file should be writable");
    assert!(run(&["add", "--", "partial.txt"]).status.success());
    fs::write(root.join("partial.txt"), "staged\nworktree\n").expect("file should be writable");
    let cached_before = run(&["diff", "--cached", "--binary"]).stdout;

    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&serde_json::json!({
            "id": "git-diff-worktree-snapshot",
            "command": "git.diff",
            "payload": {
                "root": root,
                "pathspecs": ["recreated.txt", "partial.txt"],
                "worktreeSnapshot": true
            }
        }))
        .expect("Git snapshot request should encode"),
    ))
    .expect("Git snapshot response should be JSON");

    assert_eq!(response["ok"], true, "{response:?}");
    let patch = response["data"]["patch"]
        .as_str()
        .expect("Git snapshot should return a patch");
    assert!(patch.contains("-one"), "{patch}");
    assert!(patch.contains("+staged"), "{patch}");
    assert!(patch.contains("-base"), "{patch}");
    assert!(patch.contains("+worktree"), "{patch}");
    assert!(patch.contains("+changed"), "{patch}");
    assert!(!patch.contains("deleted file mode"), "{patch}");
    assert_eq!(run(&["diff", "--cached", "--binary"]).stdout, cached_before);

    let reference_response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&serde_json::json!({
            "id": "git-diff-reference-with-untracked",
            "command": "git.diff",
            "payload": {
                "root": root,
                "pathspecs": ["recreated.txt"],
                "reference": "HEAD",
                "untracked": true
            }
        }))
        .expect("Git reference diff request should encode"),
    ))
    .expect("Git reference diff response should be JSON");
    assert_eq!(reference_response["ok"], true, "{reference_response:?}");
    assert!(
        reference_response["data"]["patch"]
            .as_str()
            .is_some_and(|patch| patch.contains("+changed")),
        "{reference_response:?}"
    );

    fs::remove_dir_all(root).expect("temporary repository should be removable");
}

#[test]
fn git_status_does_not_refresh_the_index() {
    let root = temporary_root("git-status-index");
    fs::create_dir_all(&root).expect("temporary repository should be creatable");
    let run = |arguments: &[&str]| {
        Command::new("git")
            .env_remove("GIT_OPTIONAL_LOCKS")
            .args(arguments)
            .current_dir(&root)
            .output()
            .expect("git should be available")
    };
    assert!(run(&["init", "-q"]).status.success());
    assert!(run(&["config", "core.autocrlf", "false"]).status.success());
    assert!(run(&["config", "core.trustctime", "true"]).status.success());
    assert!(run(&["config", "user.email", "test@example.com"])
        .status
        .success());
    assert!(run(&["config", "user.name", "Lithe Test"]).status.success());
    let tracked = root.join("tracked.txt");
    fs::write(&tracked, "tracked\n").expect("test file should be writable");
    assert!(run(&["add", "tracked.txt"]).status.success());
    assert!(run(&["commit", "-qm", "initial"]).status.success());

    let index = root.join(".git/index");
    let make_cached_stat_stale = |seconds| {
        let file = OpenOptions::new()
            .write(true)
            .open(&tracked)
            .expect("tracked file should be writable");
        file.set_times(FileTimes::new().set_modified(UNIX_EPOCH + Duration::from_secs(seconds)))
            .expect("tracked file timestamp should be mutable");
    };

    // Keep a control path so this test fails closed if the fixture does not make
    // Git consider the cached stat stale on the host running it.
    make_cached_stat_stale(946_684_800);
    let control_before = fs::metadata(&index)
        .and_then(|metadata| metadata.modified())
        .expect("index timestamp should be readable");
    assert!(run(&["status", "--porcelain"]).status.success());
    let control_after = fs::metadata(&index)
        .and_then(|metadata| metadata.modified())
        .expect("index timestamp should be readable");
    assert_ne!(
        control_before, control_after,
        "the fixture should require an index refresh"
    );

    make_cached_stat_stale(978_307_200);
    let before = fs::metadata(&index)
        .and_then(|metadata| metadata.modified())
        .expect("index timestamp should be readable");
    let request = serde_json::json!({
        "id": "git-status-readonly",
        "command": "git.status",
        "payload": {"root": root}
    });
    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&request).expect("Git request should encode"),
    ))
    .expect("Git response should be JSON");
    let after = fs::metadata(&index)
        .and_then(|metadata| metadata.modified())
        .expect("index timestamp should be readable");

    assert_eq!(response["ok"], true, "{response:?}");
    assert_eq!(response["data"]["changes"], serde_json::json!([]));
    assert_eq!(
        before, after,
        "a read-only status query must not rewrite the index"
    );

    fs::remove_dir_all(root).expect("temporary repository should be removable");
}

#[test]
fn git_command_returns_separate_process_streams_and_combined_output() {
    let root = temporary_root("git-command");
    fs::create_dir_all(&root).expect("temporary workspace should be creatable");

    let request = serde_json::json!({
        "id": "git-command",
        "command": "git.command",
        "payload": {
            "root": root,
            "arguments": ["--version"]
        }
    });
    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&request).expect("Git command request should encode"),
    ))
    .expect("Git command response should be JSON");
    assert_eq!(response["ok"], true);
    assert_eq!(response["data"]["exitCode"], 0);
    assert_eq!(
        response["data"]["invocations"].as_array().map(Vec::len),
        Some(1)
    );
    assert_eq!(
        response["data"]["invocations"][0]["arguments"],
        serde_json::json!(["--version"])
    );
    assert_eq!(response["data"]["stderr"], "");
    assert!(response["data"]["stdout"]
        .as_str()
        .expect("Git version stdout should be text")
        .contains("git version"));
    assert!(response["data"]["output"]
        .as_str()
        .expect("Git version output should be text")
        .contains("git version"));

    let failure_request = serde_json::json!({
        "id": "git-command-stderr",
        "command": "git.command",
        "payload": {
            "root": root,
            "arguments": ["rev-parse", "--verify", "refs/heads/missing"]
        }
    });
    let failure_response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&failure_request).expect("Git failure request should encode"),
    ))
    .expect("Git failure response should be JSON");
    assert_eq!(failure_response["ok"], true);
    assert_ne!(failure_response["data"]["exitCode"], 0);
    assert_eq!(failure_response["data"]["stdout"], "");
    assert!(!failure_response["data"]["stderr"]
        .as_str()
        .expect("Git failure stderr should be text")
        .is_empty());
    assert_eq!(
        failure_response["data"]["output"],
        failure_response["data"]["stderr"]
    );

    fs::remove_dir_all(root).expect("temporary workspace should be removable");
}

#[test]
fn git_write_commits_only_selected_paths_and_keeps_other_index_entries() {
    let root = temporary_root("git-write-selected-commit");
    fs::create_dir_all(&root).expect("temporary repository should be creatable");
    let run = |arguments: &[&str]| {
        Command::new("git")
            .args(arguments)
            .current_dir(&root)
            .output()
            .expect("git should be available")
    };
    assert!(run(&["init", "-q"]).status.success());
    assert!(run(&["config", "core.autocrlf", "false"]).status.success());
    assert!(run(&["config", "user.email", "test@example.com"])
        .status
        .success());
    assert!(run(&["config", "user.name", "Lithe Test"]).status.success());
    fs::write(root.join("selected.txt"), "initial\n").expect("file should be writable");
    fs::write(root.join("other.txt"), "initial\n").expect("file should be writable");
    assert!(run(&["add", "--all"]).status.success());
    assert!(run(&["commit", "-qm", "initial"]).status.success());

    fs::write(root.join("selected.txt"), "selected staged change\n")
        .expect("file should be writable");
    assert!(run(&["add", "selected.txt"]).status.success());
    fs::write(
        root.join("selected.txt"),
        "selected staged and unstaged change\n",
    )
    .expect("file should be writable");
    fs::write(root.join("other.txt"), "other staged change\n").expect("file should be writable");
    fs::write(root.join("new.txt"), "selected untracked\n").expect("file should be writable");
    assert!(run(&["add", "other.txt"]).status.success());

    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&serde_json::json!({
            "id": "selected-commit",
            "command": "git.write",
            "payload": {
                "root": root,
                "operation": "commit",
                "message": "selected paths",
                "paths": ["selected.txt", "new.txt"]
            }
        }))
        .expect("selected commit request should encode"),
    ))
    .expect("selected commit response should be JSON");
    assert_eq!(response["ok"], true, "{response:?}");

    let show = run(&["show", "--pretty=format:", "--name-only", "HEAD"]);
    let committed_paths = String::from_utf8_lossy(&show.stdout)
        .lines()
        .filter(|line| !line.is_empty())
        .map(str::to_string)
        .collect::<Vec<_>>();
    assert_eq!(committed_paths, vec!["new.txt", "selected.txt"]);
    assert_eq!(
        String::from_utf8_lossy(&run(&["diff", "--cached", "--name-only"]).stdout).trim(),
        "other.txt"
    );
    assert_eq!(
        String::from_utf8_lossy(&run(&["show", "HEAD:selected.txt"]).stdout),
        "selected staged and unstaged change\n"
    );
    assert_eq!(
        String::from_utf8_lossy(&run(&["show", "HEAD:new.txt"]).stdout),
        "selected untracked\n"
    );

    fs::remove_dir_all(root).expect("temporary workspace should be removable");
}

#[test]
fn git_write_commits_a_selected_rename_with_both_paths() {
    let root = temporary_root("git-write-selected-rename");
    fs::create_dir_all(&root).expect("temporary repository should be creatable");
    let run = |arguments: &[&str]| history_git(&root, arguments);
    assert!(run(&["init", "-q", "-b", "main"]).status.success());
    assert!(run(&["config", "core.autocrlf", "false"]).status.success());
    assert!(run(&["config", "user.email", "test@example.com"])
        .status
        .success());
    assert!(run(&["config", "user.name", "Lithe Test"]).status.success());
    fs::write(root.join("old-name.txt"), "content\n").expect("file should be writable");
    assert!(run(&["add", "old-name.txt"]).status.success());
    assert!(run(&["commit", "-qm", "initial"]).status.success());
    assert!(run(&["mv", "old-name.txt", "new-name.txt"])
        .status
        .success());

    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&serde_json::json!({
            "id": "selected-rename",
            "command": "git.write",
            "payload": {
                "root": root,
                "operation": "commit",
                "message": "rename selected file",
                "paths": ["new-name.txt", "old-name.txt"]
            }
        }))
        .expect("selected rename request should encode"),
    ))
    .expect("selected rename response should be JSON");

    assert_eq!(response["ok"], true, "{response:?}");
    assert_eq!(response["data"]["exitCode"], 0, "{response:?}");
    let changed = git_text(
        &root,
        &["show", "--pretty=format:", "--name-status", "HEAD"],
    );
    assert!(
        changed.starts_with("R100\told-name.txt\tnew-name.txt"),
        "{changed}"
    );
    assert!(!root.join("old-name.txt").exists());
    assert!(root.join("new-name.txt").exists());

    fs::remove_dir_all(root).expect("temporary repository should be removable");
}

#[test]
fn git_write_selected_commit_uses_stdin_for_a_large_path_set() {
    let root = temporary_root("git-write-selected-many-paths");
    fs::create_dir_all(root.join("selected")).expect("temporary repository should be creatable");
    let run = |arguments: &[&str]| history_git(&root, arguments);
    assert!(run(&["init", "-q", "-b", "main"]).status.success());
    assert!(run(&["config", "core.autocrlf", "false"]).status.success());
    assert!(run(&["config", "user.email", "test@example.com"])
        .status
        .success());
    assert!(run(&["config", "user.name", "Lithe Test"]).status.success());
    assert!(run(&["commit", "-q", "--allow-empty", "-m", "initial"])
        .status
        .success());

    let paths = (0..384)
        .map(|index| {
            let path = format!(
                "selected/{index:04}-{}.txt",
                "long-path-component-used-to-cross-the-windows-command-line-limit"
            );
            fs::write(root.join(&path), format!("{index}\n")).expect("file should be writable");
            path
        })
        .collect::<Vec<_>>();
    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&serde_json::json!({
            "id": "selected-many-paths",
            "command": "git.write",
            "payload": {
                "root": root,
                "operation": "commit",
                "message": "commit many selected paths",
                "paths": paths
            }
        }))
        .expect("large selected commit request should encode"),
    ))
    .expect("large selected commit response should be JSON");

    assert_eq!(response["ok"], true, "{response:?}");
    assert_eq!(response["data"]["exitCode"], 0, "{response:?}");
    let stage_invocation = response["data"]["invocations"]
        .as_array()
        .expect("invocations should be present")
        .iter()
        .find(|invocation| invocation["arguments"][0] == "add")
        .expect("stage invocation should be recorded");
    assert!(stage_invocation["arguments"]
        .as_array()
        .expect("stage arguments should be present")
        .iter()
        .any(|argument| argument == "--pathspec-from-file=-"));
    assert_eq!(
        git_text(&root, &["show", "--pretty=format:", "--name-only", "HEAD"])
            .lines()
            .filter(|line| !line.is_empty())
            .count(),
        384
    );

    fs::remove_dir_all(root).expect("temporary repository should be removable");
}

#[test]
fn git_write_restores_the_index_when_a_selected_commit_hook_fails() {
    let root = temporary_root("git-write-selected-hook-failure");
    fs::create_dir_all(&root).expect("temporary repository should be creatable");
    let run = |arguments: &[&str]| {
        Command::new("git")
            .args(arguments)
            .current_dir(&root)
            .output()
            .expect("git should be available")
    };
    assert!(run(&["init", "-q"]).status.success());
    assert!(run(&["config", "core.autocrlf", "false"]).status.success());
    assert!(run(&["config", "user.email", "test@example.com"])
        .status
        .success());
    assert!(run(&["config", "user.name", "Lithe Test"]).status.success());
    fs::write(root.join("selected.txt"), "initial\n").expect("file should be writable");
    fs::write(root.join("other.txt"), "initial\n").expect("file should be writable");
    assert!(run(&["add", "--all"]).status.success());
    assert!(run(&["commit", "-qm", "initial"]).status.success());

    fs::write(root.join("selected.txt"), "selected worktree change\n")
        .expect("file should be writable");
    fs::write(root.join("other.txt"), "other staged change\n").expect("file should be writable");
    assert!(run(&["add", "other.txt"]).status.success());
    let cached_before = run(&["diff", "--cached", "--binary"]).stdout;

    let hook = root.join(".git/hooks/pre-commit");
    fs::write(&hook, "#!/bin/sh\nexit 1\n").expect("hook should be writable");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut permissions = fs::metadata(&hook)
            .expect("hook metadata should be readable")
            .permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&hook, permissions).expect("hook should be executable");
    }

    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&serde_json::json!({
            "id": "selected-commit-hook-failure",
            "command": "git.write",
            "payload": {
                "root": root,
                "operation": "commit",
                "message": "must fail",
                "paths": ["selected.txt"]
            }
        }))
        .expect("selected commit request should encode"),
    ))
    .expect("selected commit response should be JSON");
    assert_eq!(response["ok"], true, "{response:?}");
    assert_ne!(response["data"]["exitCode"], 0, "{response:?}");
    assert_eq!(run(&["diff", "--cached", "--binary"]).stdout, cached_before);
    assert_eq!(
        String::from_utf8_lossy(&run(&["diff", "--name-only"]).stdout).trim(),
        "selected.txt"
    );

    fs::remove_dir_all(root).expect("temporary workspace should be removable");
}

#[test]
fn git_write_preserves_real_index_changes_made_by_a_failing_hook() {
    let root = temporary_root("git-write-selected-hook-real-index");
    fs::create_dir_all(&root).expect("temporary repository should be creatable");
    let run = |arguments: &[&str]| history_git(&root, arguments);
    assert!(run(&["init", "-q", "-b", "main"]).status.success());
    assert!(run(&["config", "core.autocrlf", "false"]).status.success());
    assert!(run(&["config", "user.email", "test@example.com"])
        .status
        .success());
    assert!(run(&["config", "user.name", "Lithe Test"]).status.success());
    fs::write(root.join("selected.txt"), "initial\n").expect("file should be writable");
    fs::write(root.join("hook-staged.txt"), "initial\n").expect("file should be writable");
    assert!(run(&["add", "--all"]).status.success());
    assert!(run(&["commit", "-qm", "initial"]).status.success());
    fs::write(root.join("selected.txt"), "selected change\n").expect("file should be writable");
    fs::write(root.join("hook-staged.txt"), "staged by hook\n").expect("file should be writable");

    let hook = root.join(".git/hooks/pre-commit");
    fs::write(
        &hook,
        "#!/bin/sh\nunset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE\ngit add -- hook-staged.txt\nexit 1\n",
    )
    .expect("hook should be writable");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut permissions = fs::metadata(&hook)
            .expect("hook metadata should be readable")
            .permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&hook, permissions).expect("hook should be executable");
    }

    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&serde_json::json!({
            "id": "selected-hook-real-index",
            "command": "git.write",
            "payload": {
                "root": root,
                "operation": "commit",
                "message": "must fail",
                "paths": ["selected.txt"]
            }
        }))
        .expect("selected commit request should encode"),
    ))
    .expect("selected commit response should be JSON");

    assert_eq!(response["ok"], true, "{response:?}");
    assert_ne!(response["data"]["exitCode"], 0, "{response:?}");
    assert_eq!(
        git_text(&root, &["diff", "--cached", "--name-only"]),
        "hook-staged.txt"
    );
    assert_eq!(git_text(&root, &["diff", "--name-only"]), "selected.txt");

    fs::remove_dir_all(root).expect("temporary repository should be removable");
}

#[test]
fn git_write_checks_selected_worktree_conflict_markers_before_committing() {
    let root = temporary_root("git-write-selected-markers");
    fs::create_dir_all(root.join("selected")).expect("temporary repository should be creatable");
    let run = |arguments: &[&str]| {
        Command::new("git")
            .args(arguments)
            .current_dir(&root)
            .output()
            .expect("git should be available")
    };
    assert!(run(&["init", "-q"]).status.success());
    assert!(run(&["config", "core.autocrlf", "false"]).status.success());
    assert!(run(&["config", "user.email", "test@example.com"])
        .status
        .success());
    assert!(run(&["config", "user.name", "Lithe Test"]).status.success());
    fs::write(root.join("selected/file.txt"), "initial\n").expect("file should be writable");
    assert!(run(&["add", "--all"]).status.success());
    assert!(run(&["commit", "-qm", "initial"]).status.success());
    let head_before = run(&["rev-parse", "HEAD"]).stdout;

    fs::write(
        root.join("selected/file.txt"),
        "<<<<<<< ours\nleft\n=======\nright\n>>>>>>> theirs\n",
    )
    .expect("file should be writable");
    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&serde_json::json!({
            "id": "selected-commit-markers",
            "command": "git.write",
            "payload": {
                "root": root,
                "operation": "commit",
                "message": "must not commit markers",
                "paths": ["selected"]
            }
        }))
        .expect("selected commit request should encode"),
    ))
    .expect("selected commit response should be JSON");

    assert_eq!(response["ok"], true, "{response:?}");
    assert_eq!(
        response["data"]["operationError"]["message"],
        "Conflict markers remain in selected files"
    );
    assert!(run(&["diff", "--cached", "--name-only"]).stdout.is_empty());
    assert_eq!(run(&["rev-parse", "HEAD"]).stdout, head_before);

    fs::remove_dir_all(root).expect("temporary workspace should be removable");
}

#[test]
fn git_write_appends_shared_and_local_ignore_patterns_without_duplicates() {
    let root = temporary_root("git-write-ignore");
    fs::create_dir_all(&root).expect("temporary repository should be creatable");
    let run = |arguments: &[&str]| {
        Command::new("git")
            .args(arguments)
            .current_dir(&root)
            .output()
            .expect("git should be available")
    };
    assert!(run(&["init", "-q"]).status.success());
    fs::write(root.join(".gitignore"), "# existing").expect("gitignore should be writable");

    let request = |operation: &str, paths: Value| -> Value {
        serde_json::from_str(&execute_json(
            &serde_json::to_string(&serde_json::json!({
                "id": operation,
                "command": "git.write",
                "payload": {"root": root, "operation": operation, "paths": paths}
            }))
            .expect("ignore request should encode"),
        ))
        .expect("ignore response should be JSON")
    };

    let shared_paths = serde_json::json!(["build output/", "reports/file[1].txt"]);
    let shared = request("ignore", shared_paths.clone());
    assert_eq!(shared["ok"], true, "{shared:?}");
    assert_eq!(request("ignore", shared_paths)["ok"], true);
    assert_eq!(
        fs::read_to_string(root.join(".gitignore")).expect("gitignore should be readable"),
        "# existing\n/build\\ output/\n/reports/file\\[1\\].txt\n"
    );

    fs::create_dir_all(root.join("cache")).expect("excluded directory should be creatable");
    fs::create_dir_all(root.join("unselected")).expect("unselected directory should be creatable");
    fs::write(root.join("cache/data.txt"), "excluded\n").expect("excluded file should be writable");
    fs::write(root.join("secret#file.txt"), "excluded\n")
        .expect("excluded file should be writable");
    fs::write(root.join("unselected/keep.txt"), "keep\n")
        .expect("unselected file should be writable");

    let local_paths = serde_json::json!(["cache/", "secret#file.txt"]);
    let local = request("exclude", local_paths.clone());
    assert_eq!(local["ok"], true, "{local:?}");
    assert_eq!(request("exclude", local_paths)["ok"], true);
    assert_eq!(
        fs::read_to_string(root.join(".git/info/exclude"))
            .expect("local exclude file should be readable")
            .lines()
            .filter(|line| line.starts_with('/'))
            .collect::<Vec<_>>(),
        vec!["/cache/", "/secret\\#file.txt"]
    );
    assert!(root.join("cache/data.txt").is_file());
    assert!(root.join("secret#file.txt").is_file());
    assert!(root.join("unselected/keep.txt").is_file());

    fs::create_dir_all(root.join("build output")).expect("ignored directory should be creatable");
    fs::create_dir_all(root.join("reports")).expect("ignored directory should be creatable");
    fs::write(root.join("build output/generated.txt"), "ignored\n")
        .expect("ignored file should be writable");
    fs::write(root.join("reports/file[1].txt"), "ignored\n")
        .expect("ignored file should be writable");
    assert!(run(&["check-ignore", "-q", "build output/generated.txt"])
        .status
        .success());
    assert!(run(&["check-ignore", "-q", "reports/file[1].txt"])
        .status
        .success());
    assert!(run(&["check-ignore", "-q", "cache/data.txt"])
        .status
        .success());
    assert!(run(&["check-ignore", "-q", "secret#file.txt"])
        .status
        .success());

    let invalid = request("ignore", serde_json::json!(["unsafe\npattern"]));
    assert_eq!(invalid["ok"], false);
    assert_eq!(invalid["error"]["code"], "invalid_request");

    fs::remove_dir_all(root).expect("temporary workspace should be removable");
}

#[test]
fn git_write_edits_a_local_commit_message_and_rebuilds_descendants() {
    let root = history_rewrite_repository("git-edit-commit-message");
    commit_history_file(&root, "story.txt", "one\n", "one");
    commit_history_file(&root, "story.txt", "two\n", "two");
    let target = git_text(&root, &["rev-parse", "HEAD"]);
    commit_history_file(&root, "story.txt", "three\n", "three");
    let original_tree = git_text(&root, &["rev-parse", "HEAD^{tree}"]);

    let response = history_write(
        &root,
        serde_json::json!({
            "operation": "editCommitMessage",
            "revision": target,
            "message": "two edited"
        }),
    );
    assert_eq!(response["ok"], true, "{response:?}");
    assert_eq!(response["data"]["exitCode"], 0, "{response:?}");
    assert_eq!(
        git_text(&root, &["log", "--format=%s"]),
        "three\ntwo edited\none"
    );
    assert_eq!(
        git_text(&root, &["rev-parse", "HEAD^{tree}"]),
        original_tree
    );
    assert_eq!(git_text(&root, &["status", "--porcelain"]), "");

    fs::remove_dir_all(root).expect("temporary repository should be removable");
}

#[test]
fn git_write_squashes_a_contiguous_local_commit_range() {
    let root = history_rewrite_repository("git-squash-commits");
    commit_history_file(&root, "story.txt", "one\n", "one");
    commit_history_file(&root, "story.txt", "two\n", "two");
    let older = git_text(&root, &["rev-parse", "HEAD"]);
    commit_history_file(&root, "story.txt", "three\n", "three");
    let newer = git_text(&root, &["rev-parse", "HEAD"]);
    commit_history_file(&root, "tail.txt", "tail\n", "tail");
    let tail = git_text(&root, &["rev-parse", "HEAD"]);
    let original_tree = git_text(&root, &["rev-parse", "HEAD^{tree}"]);

    let rejected = history_write(
        &root,
        serde_json::json!({
            "operation": "squashCommits",
            "revisions": [tail, older],
            "message": "must be rejected"
        }),
    );
    assert_eq!(rejected["ok"], true, "{rejected:?}");
    assert_eq!(
        rejected["data"]["operationError"]["code"],
        "invalid_request"
    );
    assert!(rejected["data"]["operationError"]["message"]
        .as_str()
        .expect("error message should be text")
        .contains("contiguous"));

    let response = history_write(
        &root,
        serde_json::json!({
            "operation": "squashCommits",
            "revisions": [newer, older],
            "message": "two and three"
        }),
    );
    assert_eq!(response["ok"], true, "{response:?}");
    assert_eq!(response["data"]["exitCode"], 0, "{response:?}");
    assert_eq!(
        git_text(&root, &["log", "--format=%s"]),
        "tail\ntwo and three\none"
    );
    assert_eq!(git_text(&root, &["rev-list", "--count", "HEAD"]), "3");
    assert_eq!(
        git_text(&root, &["rev-parse", "HEAD^{tree}"]),
        original_tree
    );
    assert_eq!(git_text(&root, &["status", "--porcelain"]), "");

    fs::remove_dir_all(root).expect("temporary repository should be removable");
}

#[test]
fn git_write_deletes_a_local_commit_and_replays_later_changes() {
    let root = history_rewrite_repository("git-delete-commit");
    commit_history_file(&root, "base.txt", "base\n", "base");
    commit_history_file(&root, "dropped.txt", "drop\n", "drop this commit");
    let target = git_text(&root, &["rev-parse", "HEAD"]);
    commit_history_file(&root, "kept.txt", "keep\n", "keep this commit");

    let response = history_write(
        &root,
        serde_json::json!({"operation": "deleteCommit", "revision": target}),
    );
    assert_eq!(response["ok"], true, "{response:?}");
    assert_eq!(response["data"]["exitCode"], 0, "{response:?}");
    assert_eq!(
        git_text(&root, &["log", "--format=%s"]),
        "keep this commit\nbase"
    );
    assert!(!root.join("dropped.txt").exists());
    assert_eq!(
        fs::read_to_string(root.join("kept.txt")).expect("kept file should remain"),
        "keep\n"
    );
    assert_eq!(git_text(&root, &["status", "--porcelain"]), "");

    fs::remove_dir_all(root).expect("temporary repository should be removable");
}

#[test]
fn git_write_deletes_a_local_commit_and_preserves_a_later_empty_commit() {
    let root = history_rewrite_repository("git-delete-before-empty-commit");
    commit_history_file(&root, "base.txt", "base\n", "base");
    commit_history_file(&root, "dropped.txt", "drop\n", "drop this commit");
    let target = git_text(&root, &["rev-parse", "HEAD"]);
    assert!(
        history_git(&root, &["commit", "--allow-empty", "-qm", "keep empty"])
            .status
            .success()
    );

    let response = history_write(
        &root,
        serde_json::json!({"operation": "deleteCommit", "revision": target}),
    );
    assert_eq!(response["ok"], true, "{response:?}");
    assert_eq!(response["data"]["exitCode"], 0, "{response:?}");
    assert_eq!(git_text(&root, &["log", "--format=%s"]), "keep empty\nbase");
    assert!(!root.join("dropped.txt").exists());
    assert_eq!(git_text(&root, &["status", "--porcelain"]), "");

    fs::remove_dir_all(root).expect("temporary repository should be removable");
}

#[test]
fn git_history_rewrite_rejects_commits_reachable_from_remote_refs() {
    let root = history_rewrite_repository("git-rewrite-published");
    commit_history_file(&root, "story.txt", "published\n", "published");
    let target = git_text(&root, &["rev-parse", "HEAD"]);
    assert!(
        history_git(&root, &["update-ref", "refs/remotes/origin/main", "HEAD"])
            .status
            .success()
    );

    let response = history_write(
        &root,
        serde_json::json!({
            "operation": "editCommitMessage",
            "revision": target,
            "message": "must be rejected"
        }),
    );
    assert_eq!(response["ok"], true, "{response:?}");
    assert_eq!(
        response["data"]["operationError"]["code"],
        "invalid_request"
    );
    assert!(response["data"]["operationError"]["message"]
        .as_str()
        .expect("error message should be text")
        .contains("remote"));
    assert_eq!(git_text(&root, &["log", "-1", "--format=%s"]), "published");

    fs::remove_dir_all(root).expect("temporary repository should be removable");
}

#[test]
fn git_history_rewrite_rejects_a_dirty_working_tree() {
    let root = history_rewrite_repository("git-rewrite-dirty");
    commit_history_file(&root, "story.txt", "clean\n", "clean");
    let target = git_text(&root, &["rev-parse", "HEAD"]);
    fs::write(root.join("story.txt"), "dirty\n").expect("test file should be writable");

    let response = history_write(
        &root,
        serde_json::json!({
            "operation": "editCommitMessage",
            "revision": target,
            "message": "must be rejected"
        }),
    );
    assert_eq!(response["ok"], true, "{response:?}");
    assert_eq!(
        response["data"]["operationError"]["code"],
        "invalid_request"
    );
    assert!(response["data"]["operationError"]["message"]
        .as_str()
        .expect("error message should be text")
        .contains("clean working tree"));
    assert_eq!(git_text(&root, &["log", "-1", "--format=%s"]), "clean");

    fs::remove_dir_all(root).expect("temporary repository should be removable");
}

#[test]
fn git_write_executes_stage_and_discard_mutations() {
    let root = git_write_repository("git-write-stage-discard");
    let run = |arguments: &[&str]| history_git(&root, arguments);
    fs::write(root.join("example.txt"), "initial\n").expect("file should be writable");
    let request = |operation: &str, payload: Value| git_write_request(&root, operation, payload);

    let stage = request("stage", serde_json::json!({"paths": ["example.txt"]}));
    assert_eq!(stage["ok"], true);
    let commit = request(
        "commit",
        serde_json::json!({"message": "initial", "amend": false}),
    );
    assert_eq!(commit["ok"], true);

    fs::write(root.join("example.txt"), "staged change\n").expect("file should be writable");
    assert_eq!(
        request("stage", serde_json::json!({"paths": ["example.txt"]}))["ok"],
        true
    );
    assert_eq!(
        request("unstage", serde_json::json!({"paths": ["example.txt"]}))["ok"],
        true
    );
    assert_eq!(
        String::from_utf8_lossy(&run(&["status", "--porcelain"]).stdout),
        " M example.txt\n"
    );
    assert_eq!(
        request("discard", serde_json::json!({"paths": ["example.txt"]}))["ok"],
        true
    );
    assert_eq!(
        fs::read_to_string(root.join("example.txt")).expect("file should be readable"),
        "initial\n"
    );

    // A confirmed rollback must discard both sides of a file, including a
    // staged edit followed by a working-tree edit.
    fs::write(root.join("example.txt"), "staged\n").expect("file should be writable");
    assert!(run(&["add", "example.txt"]).status.success());
    fs::write(root.join("example.txt"), "working\n").expect("file should be writable");
    let discard_all = request("discardAll", serde_json::json!({"paths": ["example.txt"]}));
    assert_eq!(discard_all["ok"], true, "{discard_all:?}");
    assert_eq!(
        discard_all["data"]["arguments"],
        serde_json::json!([
            "restore",
            "--source=HEAD",
            "--staged",
            "--worktree",
            "--pathspec-from-file=-",
            "--pathspec-file-nul"
        ])
    );
    assert_eq!(
        discard_all["data"]["invocations"]
            .as_array()
            .expect("discardAll invocations should be an array")
            .iter()
            .map(|invocation| invocation["arguments"][0].as_str().unwrap_or_default())
            .collect::<Vec<_>>(),
        vec!["status", "restore"]
    );
    assert_eq!(
        fs::read_to_string(root.join("example.txt")).expect("file should be readable"),
        "initial\n"
    );
    assert_eq!(
        String::from_utf8_lossy(&run(&["status", "--porcelain"]).stdout),
        ""
    );

    fs::write(root.join("newly-added.txt"), "staged addition\n")
        .expect("new file should be writable");
    assert!(run(&["add", "newly-added.txt"]).status.success());
    fs::write(root.join("untracked-all.txt"), "untracked\n")
        .expect("untracked file should be writable");
    let discard_added = request(
        "discardAll",
        serde_json::json!({"paths": ["newly-added.txt", "untracked-all.txt"]}),
    );
    assert_eq!(discard_added["ok"], true, "{discard_added:?}");
    assert!(!root.join("newly-added.txt").exists());
    assert!(!root.join("untracked-all.txt").exists());
    assert_eq!(
        String::from_utf8_lossy(&run(&["status", "--porcelain"]).stdout),
        ""
    );

    // An invalid checkout reference is discovered after smart checkout has
    // already started; the executed stash command must remain visible.
    let partial_failure = request(
        "checkout",
        serde_json::json!({
            "reference": "invalid branch",
            "referenceKind": "local",
            "autoStash": true
        }),
    );
    assert_eq!(partial_failure["ok"], true, "{partial_failure:?}");
    assert_eq!(
        partial_failure["data"]["operationError"]["code"], "invalid_request",
        "{partial_failure:?}"
    );
    assert_eq!(
        partial_failure["data"]["invocations"][0]["arguments"][0], "stash",
        "{partial_failure:?}"
    );
    let final_invocation = partial_failure["data"]["invocations"]
        .as_array()
        .and_then(|invocations| invocations.last())
        .expect("partial failure should retain its final Git invocation");
    for field in ["arguments", "stdout", "stderr", "exitCode"] {
        assert_eq!(
            partial_failure["data"][field], final_invocation[field],
            "partial failure compatibility field {field} should match the final invocation"
        );
    }
    assert_eq!(
        partial_failure["data"]["output"],
        format!(
            "{}{}",
            final_invocation["stdout"].as_str().unwrap(),
            final_invocation["stderr"].as_str().unwrap()
        ),
        "partial failure compatibility output should match the final invocation"
    );

    fs::write(root.join("untracked.txt"), "discard me\n")
        .expect("untracked file should be writable");
    assert_eq!(
        request("discard", serde_json::json!({"paths": ["untracked.txt"]}))["ok"],
        true
    );
    assert!(!root.join("untracked.txt").exists());

    fs::remove_dir_all(root).expect("temporary repository should be removable");
}

#[test]
fn git_write_executes_branch_pull_and_stash_mutations() {
    let root = git_write_repository("git-write-branch-workflows");
    let run = |arguments: &[&str]| history_git(&root, arguments);
    commit_history_file(&root, "example.txt", "initial\n", "initial");
    let request = |operation: &str, payload: Value| git_write_request(&root, operation, payload);

    let current = String::from_utf8_lossy(&run(&["branch", "--show-current"]).stdout)
        .trim()
        .to_string();
    let create = request(
        "createBranch",
        serde_json::json!({
            "reference": format!("refs/heads/{current}"),
            "name": "feature/core",
            "checkout": true
        }),
    );
    assert_eq!(create["ok"], true);
    assert_eq!(
        String::from_utf8_lossy(&run(&["branch", "--show-current"]).stdout).trim(),
        "feature/core"
    );

    let checkout = request(
        "checkout",
        serde_json::json!({
            "reference": format!("refs/heads/{current}"),
            "referenceKind": "local"
        }),
    );
    assert_eq!(checkout["ok"], true);
    assert_eq!(checkout["data"]["exitCode"], 0, "{checkout:?}");
    assert_eq!(
        String::from_utf8_lossy(&run(&["branch", "--show-current"]).stdout).trim(),
        current
    );

    // Nested branch names go through the same short-name path.
    assert!(run(&["branch", "feature/nested"]).status.success());
    let nested = request(
        "checkout",
        serde_json::json!({
            "reference": "refs/heads/feature/nested",
            "referenceKind": "local"
        }),
    );
    assert_eq!(nested["ok"], true);
    assert_eq!(nested["data"]["exitCode"], 0, "{nested:?}");
    assert_eq!(
        String::from_utf8_lossy(&run(&["branch", "--show-current"]).stdout).trim(),
        "feature/nested"
    );
    assert!(run(&["switch", &current]).status.success());

    let repeated_checkout = request(
        "checkout",
        serde_json::json!({
            "reference": format!("refs/heads/{current}"),
            "referenceKind": "local"
        }),
    );
    assert_eq!(
        repeated_checkout["data"]["operationError"]["code"], "invalid_request",
        "{repeated_checkout:?}"
    );

    assert!(run(&["branch", "feature/rebase"]).status.success());
    fs::write(root.join("rebase.txt"), "new base\n").expect("file should be writable");
    assert!(run(&["add", "rebase.txt"]).status.success());
    assert!(run(&["commit", "-qm", "new base"]).status.success());
    let checkout_and_rebase = request(
        "checkoutAndRebase",
        serde_json::json!({
            "reference": "refs/heads/feature/rebase",
            "referenceKind": "local"
        }),
    );
    assert_eq!(checkout_and_rebase["ok"], true, "{checkout_and_rebase:?}");
    assert_eq!(
        checkout_and_rebase["data"]["exitCode"], 0,
        "{checkout_and_rebase:?}"
    );
    assert_eq!(
        String::from_utf8_lossy(&run(&["branch", "--show-current"]).stdout).trim(),
        "feature/rebase"
    );
    assert!(run(&["merge-base", "--is-ancestor", &current, "HEAD"])
        .status
        .success());
    assert!(run(&["switch", &current]).status.success());

    fs::write(root.join("dirty.txt"), "keep me\n").expect("file should be writable");
    let dirty_checkout_and_rebase = request(
        "checkoutAndRebase",
        serde_json::json!({
            "reference": "refs/heads/feature/rebase",
            "referenceKind": "local"
        }),
    );
    assert_eq!(
        dirty_checkout_and_rebase["ok"], true,
        "{dirty_checkout_and_rebase:?}"
    );
    assert_eq!(
        dirty_checkout_and_rebase["data"]["operationError"]["code"], "invalid_request",
        "{dirty_checkout_and_rebase:?}"
    );
    assert_eq!(
        String::from_utf8_lossy(&run(&["branch", "--show-current"]).stdout).trim(),
        current
    );
    fs::remove_file(root.join("dirty.txt")).expect("file should be removable");

    let explicit_pull = request(
        "pull",
        serde_json::json!({
            "reference": "refs/remotes/origin/feature/core",
            "referenceKind": "remote",
            "mode": "rebase"
        }),
    );
    assert_eq!(explicit_pull["ok"], true, "{explicit_pull:?}");
    assert_eq!(
        explicit_pull["data"]["arguments"],
        serde_json::json!(["pull", "--rebase", "--", "origin", "feature/core"])
    );

    fs::write(root.join("example.txt"), "working tree\n").expect("file should be writable");
    let stash = request(
        "stashPush",
        serde_json::json!({"message": "core write", "includeUntracked": false}),
    );
    assert_eq!(stash["ok"], true);
    let pop = request("stashPop", serde_json::json!({"reference": "stash@{0}"}));
    assert_eq!(pop["ok"], true);
    assert_eq!(
        fs::read_to_string(root.join("example.txt")).expect("file should be readable"),
        "working tree\n"
    );

    fs::remove_dir_all(root).expect("temporary repository should be removable");
}

#[test]
fn git_write_sets_upstream_from_the_complete_remote_reference() {
    let root = git_write_repository("git-write-complete-upstream");
    commit_history_file(&root, "base.txt", "base\n", "initial");
    let current = git_text(&root, &["branch", "--show-current"]);
    assert!(history_git(
        &root,
        &[
            "remote",
            "add",
            "team/origin",
            "https://example.invalid/team/repository.git"
        ]
    )
    .status
    .success());
    assert!(history_git(
        &root,
        &["update-ref", "refs/remotes/team/origin/feature/foo", "HEAD"]
    )
    .status
    .success());
    assert!(history_git(&root, &["branch", "team/origin/feature/foo"])
        .status
        .success());

    let response = git_write_request(
        &root,
        "setUpstream",
        serde_json::json!({
            "name": current,
            "gitReference": {
                "fullName": "refs/remotes/team/origin/feature/foo",
                "shortName": "team/origin/feature/foo",
                "kind": "remote"
            }
        }),
    );
    assert_eq!(response["ok"], true, "{response:?}");
    assert_eq!(response["data"]["exitCode"], 0, "{response:?}");
    assert_eq!(
        git_text(&root, &["config", &format!("branch.{current}.remote")]),
        "team/origin"
    );
    assert_eq!(
        git_text(&root, &["config", &format!("branch.{current}.merge")]),
        "refs/heads/feature/foo"
    );

    fs::remove_dir_all(root).expect("temporary repository should be removable");
}

#[test]
fn git_write_creates_a_tracked_worktree_from_an_unambiguous_complete_remote_reference() {
    struct RemovePathsOnDrop(Vec<std::path::PathBuf>);

    impl Drop for RemovePathsOnDrop {
        fn drop(&mut self) {
            for path in self.0.iter().rev() {
                let _ = fs::remove_dir_all(path);
            }
        }
    }

    let root = git_write_repository("git-write-complete-worktree-reference");
    let destination = root.with_extension("tracked-worktree");
    let _cleanup = RemovePathsOnDrop(vec![root.clone(), destination.clone()]);
    commit_history_file(&root, "base.txt", "base\n", "initial");
    assert!(
        history_git(&root, &["update-ref", "refs/remotes/origin/main", "HEAD"])
            .status
            .success()
    );
    assert!(history_git(&root, &["branch", "origin/main", "HEAD"])
        .status
        .success());

    let response = git_write_request(
        &root,
        "createWorktree",
        serde_json::json!({
            "destination": destination,
            "name": "feature/tracked-worktree",
            "gitReference": {
                "fullName": "refs/remotes/origin/main",
                "shortName": "origin/main",
                "kind": "remote"
            }
        }),
    );

    assert_eq!(response["ok"], true, "{response:?}");
    assert_eq!(response["data"]["exitCode"], 0, "{response:?}");
    let invocations = response["data"]["invocations"]
        .as_array()
        .expect("worktree invocations should be an array");
    assert_eq!(
        invocations
            .iter()
            .filter(|invocation| invocation["arguments"][0] == "worktree")
            .count(),
        1,
        "{response:?}"
    );
    assert!(
        invocations
            .iter()
            .all(|invocation| invocation["arguments"][0] != "config"),
        "{response:?}"
    );
    assert_eq!(
        response["data"]["arguments"],
        serde_json::json!([
            "worktree",
            "add",
            "--track",
            "-b",
            "feature/tracked-worktree",
            "--",
            destination,
            "refs/remotes/origin/main"
        ])
    );
    assert_eq!(
        git_text(&root, &["config", "branch.feature/tracked-worktree.remote"]),
        "origin"
    );
    assert_eq!(
        git_text(&root, &["config", "branch.feature/tracked-worktree.merge"]),
        "refs/heads/main"
    );
    assert_eq!(
        git_text(&destination, &["branch", "--show-current"]),
        "feature/tracked-worktree"
    );
}

#[test]
fn git_write_executes_checkout_preflight_clone_and_validation() {
    let root = git_write_repository("git-write-checkout-workflows");
    let run = |arguments: &[&str]| history_git(&root, arguments);
    commit_history_file(&root, "example.txt", "initial\n", "initial");
    let request = |operation: &str, payload: Value| git_write_request(&root, operation, payload);
    let current = git_text(&root, &["branch", "--show-current"]);
    assert!(run(&["branch", "feature/core"]).status.success());

    // Checkout conflict handling. `feature/core` and the current branch hold different
    // content for conflict.txt, so a dirty working copy of it blocks a plain switch.
    fs::write(root.join("conflict.txt"), "on main\n").expect("file should be writable");
    assert!(run(&["add", "conflict.txt"]).status.success());
    assert!(run(&["commit", "-qm", "main conflict"]).status.success());
    assert!(run(&["switch", "feature/core"]).status.success());
    fs::write(root.join("conflict.txt"), "on feature\n").expect("file should be writable");
    assert!(run(&["add", "conflict.txt"]).status.success());
    assert!(run(&["commit", "-qm", "feature conflict"]).status.success());
    assert!(run(&["switch", &current]).status.success());

    let preflight = |reference: &str| -> Value {
        let value = execute_json(
            &serde_json::to_string(&serde_json::json!({
                "id": "preflight",
                "command": "git.checkoutPreflight",
                "payload": {"root": root, "reference": reference}
            }))
            .expect("request should encode"),
        );
        serde_json::from_str(&value).expect("response should decode")
    };

    // Clean tree: nothing blocks the switch.
    let clean = preflight("refs/heads/feature/core");
    assert_eq!(clean["ok"], true, "{clean:?}");
    assert_eq!(
        clean["data"]["blockingPaths"],
        serde_json::json!([]),
        "{clean:?}"
    );

    // Dirty and divergent: preflight names the exact blocking file.
    fs::write(root.join("conflict.txt"), "local edit\n").expect("file should be writable");
    let blocked = preflight("refs/heads/feature/core");
    assert_eq!(blocked["ok"], true);
    assert_eq!(
        blocked["data"]["blockingPaths"],
        serde_json::json!(["conflict.txt"]),
        "{blocked:?}"
    );

    // Untracked files that the target branch tracks also block a checkout, even
    // though they never appear in `git diff HEAD`.
    assert!(run(&["stash", "-u"]).status.success());
    fs::write(root.join("conflict.txt"), "untracked local\n").expect("file should be writable");
    let untracked_block = preflight("refs/heads/feature/core");
    assert_eq!(
        untracked_block["data"]["blockingPaths"],
        serde_json::json!(["conflict.txt"]),
        "{untracked_block:?}"
    );
    fs::remove_file(root.join("conflict.txt")).expect("file should be removable");
    assert!(run(&["stash", "pop"]).status.success());

    // A plain checkout is refused rather than clobbering the edit.
    let refused = request(
        "checkout",
        serde_json::json!({
            "reference": "refs/heads/feature/core",
            "referenceKind": "local"
        }),
    );
    assert_ne!(refused["data"]["exitCode"], 0, "{refused:?}");
    assert_eq!(
        String::from_utf8_lossy(&run(&["branch", "--show-current"]).stdout).trim(),
        current
    );

    // Smart checkout stashes the edit, switches, and restores it.
    assert!(run(&["switch", "-c", "feature/smart"]).status.success());
    let smart = request(
        "checkout",
        serde_json::json!({
            "reference": format!("refs/heads/{current}"),
            "referenceKind": "local",
            "autoStash": true
        }),
    );
    assert_eq!(smart["ok"], true);
    assert_eq!(smart["data"]["exitCode"], 0, "{smart:?}");
    assert_eq!(
        String::from_utf8_lossy(&run(&["branch", "--show-current"]).stdout).trim(),
        current
    );
    assert_eq!(
        fs::read_to_string(root.join("conflict.txt")).expect("file should be readable"),
        "local edit\n"
    );
    assert!(
        String::from_utf8_lossy(&run(&["stash", "list"]).stdout).is_empty(),
        "smart checkout should consume its stash"
    );

    // Force checkout discards the local edit and lands on the target branch.
    let forced = request(
        "checkout",
        serde_json::json!({
            "reference": "refs/heads/feature/core",
            "referenceKind": "local",
            "force": true
        }),
    );
    assert_eq!(forced["ok"], true);
    assert_eq!(forced["data"]["exitCode"], 0, "{forced:?}");
    assert_eq!(
        String::from_utf8_lossy(&run(&["branch", "--show-current"]).stdout).trim(),
        "feature/core"
    );
    assert_eq!(
        fs::read_to_string(root.join("conflict.txt")).expect("file should be readable"),
        "on feature\n"
    );
    assert!(run(&["switch", &current]).status.success());

    let clone = root
        .parent()
        .expect("temporary root should have a parent")
        .join(format!("lithe-core-clone-{}", std::process::id()));
    let clone_result = request(
        "clone",
        serde_json::json!({
            "remote": root.to_string_lossy(),
            "destination": clone.to_string_lossy()
        }),
    );
    assert_eq!(clone_result["ok"], true);
    assert!(clone.join(".git").exists());
    fs::remove_dir_all(clone).expect("temporary clone should be removable");

    let invalid = request(
        "reset",
        serde_json::json!({"revision": "HEAD", "mode": "--invalid"}),
    );
    assert_eq!(invalid["ok"], false);
    assert_eq!(invalid["error"]["code"], "invalid_request");

    fs::remove_dir_all(root).expect("temporary repository should be removable");
}

#[test]
fn git_write_rolls_back_large_selected_path_set_without_command_line_overflow() {
    let root = temporary_root("git-write-large-rollback");
    fs::create_dir_all(root.join("bulk")).expect("temporary repository should be creatable");
    let run = |arguments: &[&str]| {
        Command::new("git")
            .args(arguments)
            .current_dir(&root)
            .output()
            .expect("git should be available")
    };
    assert!(run(&["init", "-q"]).status.success());
    assert!(run(&["config", "core.autocrlf", "false"]).status.success());
    assert!(run(&["config", "user.email", "test@example.com"])
        .status
        .success());
    assert!(run(&["config", "user.name", "Lithe Test"]).status.success());

    // This path set exceeds the Windows process command-line limit when every
    // path is passed as a separate argument.
    let paths = (0..240)
        .map(|index| format!("bulk/{index:03}_{}.txt", "selected_path_segment_".repeat(6)))
        .collect::<Vec<_>>();
    for path in &paths {
        fs::write(root.join(path), "initial\n").expect("tracked file should be writable");
    }
    assert!(run(&["add", "--all"]).status.success());
    assert!(run(&["commit", "-qm", "initial"]).status.success());
    for path in &paths {
        fs::write(root.join(path), "changed\n").expect("tracked file should be writable");
    }
    assert!(run(&["add", "--all"]).status.success());

    let request = serde_json::json!({
        "id": "large-rollback",
        "command": "git.write",
        "payload": {
            "root": root,
            "operation": "discardAll",
            "paths": paths
        }
    });
    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&request).expect("rollback request should encode"),
    ))
    .expect("rollback response should be JSON");
    assert_eq!(response["ok"], true, "{response:?}");
    assert!(run(&["status", "--porcelain"]).stdout.is_empty());
    assert_eq!(
        fs::read_to_string(root.join(&paths[0])).expect("tracked file should be readable"),
        "initial\n"
    );

    fs::remove_dir_all(root).expect("temporary repository should be removable");
}

#[test]
fn detached_worktree_context_can_publish_a_pull_request_branch() {
    let repository = temporary_root("detached-pr-repository");
    let root = temporary_root("detached-pr-worktree");
    let remote = temporary_root("detached-pr-remote");
    fs::create_dir_all(&repository).expect("temporary repository should be creatable");
    fs::create_dir_all(&remote).expect("temporary remote should be creatable");
    let run = |directory: &Path, arguments: &[&str]| {
        Command::new("git")
            .args(arguments)
            .current_dir(directory)
            .output()
            .expect("git should be available")
    };
    assert!(run(&remote, &["init", "--bare", "-q"]).status.success());
    assert!(run(&repository, &["init", "-q"]).status.success());
    assert!(
        run(&repository, &["config", "user.email", "test@example.com"])
            .status
            .success()
    );
    assert!(run(&repository, &["config", "user.name", "Lithe Test"])
        .status
        .success());
    fs::write(repository.join("example.txt"), "initial\n").expect("file should be writable");
    assert!(run(&repository, &["add", "example.txt"]).status.success());
    assert!(run(&repository, &["commit", "-qm", "initial"])
        .status
        .success());
    assert!(run(&repository, &["branch", "-M", "preview"])
        .status
        .success());
    assert!(run(
        &repository,
        &["remote", "add", "origin", remote.to_string_lossy().as_ref(),],
    )
    .status
    .success());
    assert!(run(&repository, &["push", "-qu", "origin", "preview"],)
        .status
        .success());
    assert!(run(
        &repository,
        &[
            "worktree",
            "add",
            "--detach",
            "-q",
            root.to_string_lossy().as_ref(),
            "preview",
        ],
    )
    .status
    .success());
    fs::write(root.join("example.txt"), "published from detached\n")
        .expect("file should be writable");
    assert!(run(&root, &["add", "example.txt"]).status.success());
    assert!(run(&root, &["commit", "-qm", "detached change"])
        .status
        .success());

    let context_request = serde_json::json!({
        "id": "context",
        "command": "git.pullRequestContext",
        "payload": { "root": root }
    });
    let context: Value = serde_json::from_str(&execute_json(&context_request.to_string()))
        .expect("context response should be JSON");
    assert_eq!(context["ok"], true, "{context:?}");
    assert_eq!(context["data"]["detached"], true);
    assert_eq!(
        context["data"]["suggestedBaseBranch"], "preview",
        "{context:?}"
    );
    assert_eq!(context["data"]["requiresPublish"], true);
    let suggested = context["data"]["suggestedPublishBranch"]
        .as_str()
        .expect("detached context should suggest a branch")
        .to_string();
    assert!(suggested.starts_with("codex/pr-"));

    let publish_request = serde_json::json!({
        "id": "publish",
        "command": "git.write",
        "payload": {
            "root": root,
            "operation": "publishBranch",
            "name": suggested
        }
    });
    let published: Value = serde_json::from_str(&execute_json(&publish_request.to_string()))
        .expect("publish response should be JSON");
    assert_eq!(published["ok"], true, "{published:?}");
    assert_eq!(published["data"]["exitCode"], 0, "{published:?}");

    let refreshed: Value = serde_json::from_str(&execute_json(&context_request.to_string()))
        .expect("refreshed context should be JSON");
    assert_eq!(refreshed["data"]["currentBranch"], suggested);
    assert_eq!(
        refreshed["data"]["suggestedBaseBranch"], "preview",
        "publishing must preserve the detached worktree's inferred base: {refreshed:?}"
    );
    assert_eq!(refreshed["data"]["requiresPublish"], false);
    assert!(run(
        &remote,
        &["show-ref", "--verify", &format!("refs/heads/{suggested}")],
    )
    .status
    .success());

    fs::remove_dir_all(root).expect("temporary workspace should be removable");
    fs::remove_dir_all(repository).expect("temporary repository should be removable");
    fs::remove_dir_all(remote).expect("temporary remote should be removable");
}

#[test]
fn stash_restore_conflicts_return_structured_recovery_data() {
    let root = temporary_root("git-stash-conflict");
    fs::create_dir_all(&root).expect("temporary repository should be creatable");
    let run = |arguments: &[&str]| {
        Command::new("git")
            .args(arguments)
            .current_dir(&root)
            .output()
            .expect("git should be available")
    };
    assert!(run(&["init", "-q", "-b", "main"]).status.success());
    assert!(run(&["config", "core.autocrlf", "false"]).status.success());
    assert!(run(&["config", "user.email", "test@example.com"])
        .status
        .success());
    assert!(run(&["config", "user.name", "Lithe Test"]).status.success());
    fs::write(root.join("shared.txt"), "base\n").expect("file should be writable");
    assert!(run(&["add", "shared.txt"]).status.success());
    assert!(run(&["commit", "-qm", "initial"]).status.success());

    assert!(run(&["switch", "-qc", "feature"]).status.success());
    fs::write(root.join("shared.txt"), "feature\n").expect("file should be writable");
    assert!(run(&["commit", "-qam", "feature edit"]).status.success());
    assert!(run(&["switch", "-q", "main"]).status.success());

    fs::write(root.join("shared.txt"), "local\n").expect("file should be writable");
    assert!(run(&["stash", "push", "-qm", "restore conflict"])
        .status
        .success());
    let stash_reference = String::from_utf8_lossy(&run(&["stash", "list", "--format=%gd"]).stdout)
        .lines()
        .next()
        .expect("stash reference should exist")
        .trim()
        .to_string();
    assert!(run(&["switch", "-q", "feature"]).status.success());

    let write = |operation: &str| -> Value {
        serde_json::from_str(&execute_json(
            &serde_json::to_string(&serde_json::json!({
                "id": format!("stash-{operation}"),
                "command": "git.write",
                "payload": {
                    "root": root,
                    "operation": operation,
                    "reference": stash_reference
                }
            }))
            .expect("stash request should encode"),
        ))
        .expect("stash response should be JSON")
    };

    let applied = write("stashApply");
    assert_eq!(applied["ok"], true, "{applied:?}");
    assert_eq!(
        applied["data"]["stashRestore"]["stashReference"], stash_reference,
        "{applied:?}"
    );
    assert_eq!(
        applied["data"]["stashRestore"]["conflictedPaths"],
        serde_json::json!(["shared.txt"]),
        "{applied:?}"
    );
    assert_eq!(
        applied["data"]["arguments"],
        applied["data"]["invocations"]
            .as_array()
            .unwrap()
            .last()
            .unwrap()["arguments"],
        "composite response should expose the final invocation arguments"
    );
    assert_eq!(
        applied["data"]["stdout"],
        applied["data"]["invocations"]
            .as_array()
            .unwrap()
            .last()
            .unwrap()["stdout"],
        "composite response should expose the final invocation stdout"
    );
    assert_eq!(
        applied["data"]["stderr"],
        applied["data"]["invocations"]
            .as_array()
            .unwrap()
            .last()
            .unwrap()["stderr"],
        "composite response should expose the final invocation stderr"
    );
    assert_eq!(
        applied["data"]["exitCode"],
        applied["data"]["invocations"]
            .as_array()
            .unwrap()
            .last()
            .unwrap()["exitCode"],
        "composite response should expose the final invocation exit code"
    );

    // Clear the index conflict without dropping the saved entry, then verify
    // `pop` reports the same structured recovery data.
    assert!(run(&["reset", "--hard", "HEAD"]).status.success());
    let popped = write("stashPop");
    assert_eq!(popped["ok"], true, "{popped:?}");
    assert_eq!(
        popped["data"]["stashRestore"]["stashReference"], stash_reference,
        "{popped:?}"
    );
    assert_eq!(
        popped["data"]["stashRestore"]["conflictedPaths"],
        serde_json::json!(["shared.txt"]),
        "{popped:?}"
    );
    assert_eq!(
        popped["data"]["arguments"],
        popped["data"]["invocations"]
            .as_array()
            .unwrap()
            .last()
            .unwrap()["arguments"],
        "composite response should expose the final invocation arguments"
    );
    assert_eq!(
        popped["data"]["stdout"],
        popped["data"]["invocations"]
            .as_array()
            .unwrap()
            .last()
            .unwrap()["stdout"],
        "composite response should expose the final invocation stdout"
    );
    assert_eq!(
        popped["data"]["stderr"],
        popped["data"]["invocations"]
            .as_array()
            .unwrap()
            .last()
            .unwrap()["stderr"],
        "composite response should expose the final invocation stderr"
    );
    assert_eq!(
        popped["data"]["exitCode"],
        popped["data"]["invocations"]
            .as_array()
            .unwrap()
            .last()
            .unwrap()["exitCode"],
        "composite response should expose the final invocation exit code"
    );

    assert!(run(&["reset", "--hard", "HEAD"]).status.success());
    assert!(run(&["stash", "drop", &stash_reference]).status.success());
    fs::remove_dir_all(root).expect("temporary repository should be removable");
}

#[test]
fn git_operation_state_reports_and_resolves_a_merge_conflict() {
    let root = temporary_root("git-operation");
    fs::create_dir_all(&root).expect("temporary workspace should be creatable");
    let run = |arguments: &[&str]| {
        Command::new("git")
            .args(arguments)
            .current_dir(&root)
            .output()
            .expect("git should be available")
    };
    assert!(run(&["init", "-q"]).status.success());
    assert!(run(&["config", "core.autocrlf", "false"]).status.success());
    assert!(run(&["config", "user.email", "test@example.com"])
        .status
        .success());
    assert!(run(&["config", "user.name", "Lithe Test"]).status.success());

    fs::write(root.join("shared.txt"), "base\n").expect("file should be writable");
    assert!(run(&["add", "shared.txt"]).status.success());
    assert!(run(&["commit", "-qm", "initial"]).status.success());
    let current = String::from_utf8_lossy(&run(&["branch", "--show-current"]).stdout)
        .trim()
        .to_string();

    let state = || -> Value {
        let value = execute_json(
            &serde_json::to_string(&serde_json::json!({
                "id": "operation-state",
                "command": "git.operationState",
                "payload": {"root": root}
            }))
            .expect("request should encode"),
        );
        serde_json::from_str(&value).expect("response should decode")
    };
    let write = |operation: &str| -> Value {
        let value = execute_json(
            &serde_json::to_string(&serde_json::json!({
                "id": "operation-write",
                "command": "git.write",
                "payload": {"root": root, "operation": operation}
            }))
            .expect("request should encode"),
        );
        serde_json::from_str(&value).expect("response should decode")
    };

    // A settled repository reports no operation and no conflicts.
    let idle = state();
    assert_eq!(idle["ok"], true, "{idle:?}");
    assert_eq!(idle["data"]["kind"], "", "{idle:?}");
    assert_eq!(idle["data"]["conflictedPaths"], serde_json::json!([]));

    // Resolving the operation state invokes Git before discovering that
    // there is nothing to continue, so the trace and logical error coexist.
    let nothing = write("operationContinue");
    assert_eq!(nothing["ok"], true, "{nothing:?}");
    assert_eq!(
        nothing["data"]["operationError"]["code"], "invalid_request",
        "{nothing:?}"
    );
    assert!(!nothing["data"]["invocations"]
        .as_array()
        .unwrap()
        .is_empty());

    // Build two branches that edit the same line, so merging must conflict.
    assert!(run(&["switch", "-qc", "feature/conflict"]).status.success());
    fs::write(root.join("shared.txt"), "from feature\n").expect("file should be writable");
    assert!(run(&["commit", "-qam", "feature edit"]).status.success());
    assert!(run(&["switch", "-q", &current]).status.success());
    fs::write(root.join("shared.txt"), "from main\n").expect("file should be writable");
    assert!(run(&["commit", "-qam", "main edit"]).status.success());

    // Conflicting merges exit non-zero; the point is the state they leave behind.
    assert!(!run(&["merge", "--no-edit", "feature/conflict"])
        .status
        .success());

    let conflicted = state();
    assert_eq!(conflicted["ok"], true, "{conflicted:?}");
    assert_eq!(conflicted["data"]["kind"], "merge", "{conflicted:?}");
    assert_eq!(
        conflicted["data"]["conflictedPaths"],
        serde_json::json!(["shared.txt"]),
        "{conflicted:?}"
    );

    // Continuing with the conflict unresolved is refused, so the user cannot
    // commit conflict markers by clicking through the banner.
    let premature = write("operationContinue");
    assert_eq!(premature["ok"], true, "{premature:?}");
    assert_eq!(
        premature["data"]["operationError"]["code"], "invalid_request",
        "{premature:?}"
    );

    // A merge has no skip step, but the state probes remain visible.
    let skip = write("operationSkip");
    assert_eq!(skip["ok"], true, "{skip:?}");
    assert_eq!(
        skip["data"]["operationError"]["code"], "invalid_request",
        "{skip:?}"
    );

    // Resolving the file and continuing completes the merge without opening an editor.
    fs::write(root.join("shared.txt"), "resolved\n").expect("file should be writable");
    assert!(run(&["add", "shared.txt"]).status.success());
    let finished = write("operationContinue");
    assert_eq!(finished["ok"], true, "{finished:?}");
    assert_eq!(finished["data"]["exitCode"], 0, "{finished:?}");

    let settled = state();
    assert_eq!(settled["data"]["kind"], "", "{settled:?}");
    assert_eq!(settled["data"]["conflictedPaths"], serde_json::json!([]));

    // Abort restores the pre-merge state of a fresh conflict.
    fs::write(root.join("shared.txt"), "main again\n").expect("file should be writable");
    assert!(run(&["commit", "-qam", "main again"]).status.success());
    assert!(run(&["switch", "-q", "feature/conflict"]).status.success());
    fs::write(root.join("shared.txt"), "feature again\n").expect("file should be writable");
    assert!(run(&["commit", "-qam", "feature again"]).status.success());
    assert!(!run(&["merge", "--no-edit", &current]).status.success());
    assert_eq!(state()["data"]["kind"], "merge");

    let aborted = write("operationAbort");
    assert_eq!(aborted["ok"], true, "{aborted:?}");
    assert_eq!(aborted["data"]["exitCode"], 0, "{aborted:?}");
    assert_eq!(state()["data"]["kind"], "");
    assert_eq!(
        fs::read_to_string(root.join("shared.txt")).expect("file should be readable"),
        "feature again\n"
    );

    fs::remove_dir_all(root).expect("temporary repository should be removable");
}

#[test]
fn git_diff_and_apply_round_trip_a_patch() {
    let root = temporary_root("git-diff");
    fs::create_dir_all(&root).expect("temporary workspace should be creatable");
    let run = |arguments: &[&str]| {
        Command::new("git")
            .args(arguments)
            .current_dir(&root)
            .output()
            .expect("git should be available")
    };
    assert!(run(&["init", "-q"]).status.success());
    assert!(run(&["config", "core.autocrlf", "false"]).status.success());
    assert!(run(&["config", "user.email", "test@example.com"])
        .status
        .success());
    assert!(run(&["config", "user.name", "Lithe Test"]).status.success());
    fs::write(root.join("example.txt"), "before\n").expect("file should be writable");
    assert!(run(&["add", "example.txt"]).status.success());
    assert!(run(&["commit", "-qm", "initial"]).status.success());
    fs::write(root.join("example.txt"), "after\n").expect("file should be writable");

    let diff = serde_json::json!({
        "id": "diff",
        "command": "git.diff",
        "payload": {
            "root": root,
            "pathspecs": ["example.txt"],
            "contextLines": 80
        }
    });
    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&diff).expect("diff request should encode"),
    ))
    .expect("diff response should be JSON");
    assert_eq!(response["ok"], true);
    assert!(response["data"]["patch"]
        .as_str()
        .expect("diff output should be text")
        .contains("+after"));
    assert_eq!(response["data"]["hunks"].as_array().unwrap().len(), 1);
    assert!(response["data"]["rows"]
        .as_array()
        .unwrap()
        .iter()
        .any(|row| row["kind"] == "changed" && row["right"] == "after"));

    let reference_diff = serde_json::json!({
        "id": "reference-diff",
        "command": "git.diff",
        "payload": {
            "root": root,
            "pathspecs": ["example.txt"],
            "reference": "HEAD",
            "contextLines": 80
        }
    });
    let reference_response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&reference_diff).expect("reference diff should encode"),
    ))
    .expect("reference diff response should be JSON");
    assert_eq!(reference_response["ok"], true);
    assert!(reference_response["data"]["patch"]
        .as_str()
        .expect("reference diff patch should be text")
        .contains("+after"));

    let apply = serde_json::json!({
        "id": "apply",
        "command": "git.apply",
        "payload": {
            "root": root,
            "patch": response["data"]["patch"],
            "mode": "stage"
        }
    });
    let apply_response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&apply).expect("apply request should encode"),
    ))
    .expect("apply response should be JSON");
    assert_eq!(apply_response["ok"], true);
    assert_eq!(apply_response["data"]["exitCode"], 0);

    let status = run(&["status", "--porcelain"]).stdout;
    assert_eq!(String::from_utf8_lossy(&status), "M  example.txt\n");

    // Shelve restores the index snapshot and the unstaged worktree delta
    // separately. Verify that a file with both kinds of edits returns as MM
    // and keeps the final worktree content.
    assert!(run(&["reset", "--hard", "HEAD"]).status.success());
    fs::write(root.join("example.txt"), "staged\n").expect("file should be writable");
    assert!(run(&["add", "example.txt"]).status.success());
    let staged_diff = serde_json::json!({
        "id": "staged-diff",
        "command": "git.diff",
        "payload": {
            "root": root,
            "pathspecs": ["example.txt"],
            "staged": true
        }
    });
    let staged_response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&staged_diff).expect("staged diff request should encode"),
    ))
    .expect("staged diff response should be JSON");
    let staged_patch = staged_response["data"]["patch"]
        .as_str()
        .expect("staged patch should be text")
        .to_string();

    fs::write(root.join("example.txt"), "final\n").expect("file should be writable");
    let working_diff = serde_json::json!({
        "id": "working-diff",
        "command": "git.diff",
        "payload": {
            "root": root,
            "pathspecs": ["example.txt"]
        }
    });
    let working_response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&working_diff).expect("working diff request should encode"),
    ))
    .expect("working diff response should be JSON");
    let working_patch = working_response["data"]["patch"]
        .as_str()
        .expect("working patch should be text")
        .to_string();
    assert!(run(&["reset", "--hard", "HEAD"]).status.success());

    for (id, patch, mode) in [
        ("restore-index", staged_patch.as_str(), "restoreIndex"),
        ("restore-worktree", working_patch.as_str(), "worktree"),
    ] {
        let apply = serde_json::json!({
            "id": id,
            "command": "git.apply",
            "payload": {"root": root, "patch": patch, "mode": mode}
        });
        let response: Value = serde_json::from_str(&execute_json(
            &serde_json::to_string(&apply).expect("restore apply request should encode"),
        ))
        .expect("restore apply response should be JSON");
        assert_eq!(response["ok"], true, "{response:?}");
        assert_eq!(response["data"]["exitCode"], 0, "{response:?}");
    }
    assert_eq!(
        String::from_utf8_lossy(&run(&["status", "--porcelain"]).stdout),
        "MM example.txt\n"
    );
    assert_eq!(
        fs::read_to_string(root.join("example.txt")).expect("file should be readable"),
        "final\n"
    );

    for (id, patch, mode) in [
        (
            "restore-index-check",
            staged_patch.as_str(),
            "restoreIndexCheck",
        ),
        ("worktree-check", working_patch.as_str(), "worktreeCheck"),
    ] {
        let check = serde_json::json!({
            "id": id,
            "command": "git.apply",
            "payload": {"root": root, "patch": patch, "mode": mode}
        });
        let response: Value = serde_json::from_str(&execute_json(
            &serde_json::to_string(&check).expect("patch check request should encode"),
        ))
        .expect("patch check response should be JSON");
        assert_eq!(response["ok"], true, "{response:?}");
        assert_eq!(response["data"]["exitCode"], 0, "{response:?}");
    }

    assert!(run(&["reset", "--hard", "HEAD"]).status.success());
    fs::write(root.join("new.txt"), "untracked\n").expect("file should be writable");
    let untracked_diff = serde_json::json!({
        "id": "untracked-diff",
        "command": "git.diff",
        "payload": {
            "root": root,
            "pathspecs": ["new.txt"],
            "untracked": true
        }
    });
    let untracked_response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&untracked_diff).expect("untracked diff request should encode"),
    ))
    .expect("untracked diff response should be JSON");
    let untracked_patch = untracked_response["data"]["patch"]
        .as_str()
        .expect("untracked patch should be text")
        .to_string();
    fs::remove_file(root.join("new.txt")).expect("file should be removable");
    let untracked_apply = serde_json::json!({
        "id": "untracked-apply",
        "command": "git.apply",
        "payload": {"root": root, "patch": untracked_patch, "mode": "worktree"}
    });
    let untracked_apply_response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&untracked_apply).expect("untracked apply request should encode"),
    ))
    .expect("untracked apply response should be JSON");
    assert_eq!(untracked_apply_response["ok"], true);
    assert_eq!(untracked_apply_response["data"]["exitCode"], 0);
    assert_eq!(
        fs::read_to_string(root.join("new.txt")).expect("file should be readable"),
        "untracked\n"
    );
    fs::remove_dir_all(root).expect("temporary workspace should be removable");
}

#[test]
fn git_diff_resolves_the_empty_tree_for_a_sha256_repository() {
    let root = temporary_root("git-diff-sha256-empty-tree");
    fs::create_dir_all(&root).expect("temporary workspace should be creatable");
    let run = |arguments: &[&str]| history_git(&root, arguments);
    assert!(run(&["init", "-q", "--object-format=sha256", "-b", "main"])
        .status
        .success());
    assert!(run(&["config", "core.autocrlf", "false"]).status.success());
    assert!(run(&["config", "user.email", "test@example.com"])
        .status
        .success());
    assert!(run(&["config", "user.name", "Lithe Test"]).status.success());
    fs::write(root.join("root.txt"), "root\n").expect("root file should be writable");
    assert!(run(&["add", "root.txt"]).status.success());
    assert!(run(&["commit", "-qm", "root"]).status.success());
    fs::write(root.join("later.txt"), "later\n").expect("later file should be writable");
    assert!(run(&["add", "later.txt"]).status.success());
    assert!(run(&["commit", "-qm", "later"]).status.success());

    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "sha256-root-range",
            "command": "git.diff",
            "payload": {
                "root": root,
                "pathspecs": ["."],
                "reference": "HEAD",
                "emptyTreeBase": true
            }
        })
        .to_string(),
    ))
    .expect("Git diff response should be JSON");

    assert_eq!(response["ok"], true, "{response:?}");
    let patch = response["data"]["patch"]
        .as_str()
        .expect("root range should return a patch");
    assert!(patch.contains("root.txt"), "{patch}");
    assert!(patch.contains("later.txt"), "{patch}");

    fs::remove_dir_all(root).expect("temporary repository should be removable");
}

#[test]
fn git_typed_two_reference_comparison_preserves_both_identities() {
    let root = temporary_root("git-typed-comparison");
    fs::create_dir_all(&root).expect("temporary workspace should be creatable");
    let run = |arguments: &[&str]| {
        Command::new("git")
            .args(arguments)
            .current_dir(&root)
            .output()
            .expect("git should be available")
    };
    assert!(run(&["init", "-q"]).status.success());
    assert!(run(&["config", "core.autocrlf", "false"]).status.success());
    assert!(run(&["config", "user.email", "test@example.com"])
        .status
        .success());
    assert!(run(&["config", "user.name", "Lithe Test"]).status.success());
    let main = String::from_utf8_lossy(&run(&["branch", "--show-current"]).stdout)
        .trim()
        .to_string();
    fs::write(root.join("example.txt"), "main\n").expect("file should be writable");
    assert!(run(&["add", "example.txt"]).status.success());
    assert!(run(&["commit", "-qm", "initial"]).status.success());
    assert!(run(&["switch", "-qc", "feature"]).status.success());
    fs::write(root.join("example.txt"), "feature\n").expect("file should be writable");
    assert!(run(&["commit", "-qam", "feature"]).status.success());
    assert!(run(&["switch", "-q", &main]).status.success());

    let typed_references = serde_json::json!({
        "gitReference": {
            "fullName": format!("refs/heads/{main}"),
            "shortName": main,
            "kind": "local"
        },
        "targetGitReference": {
            "fullName": "refs/heads/feature",
            "shortName": "feature",
            "kind": "local"
        }
    });
    for (command, id) in [
        ("git.diff", "typed-diff"),
        ("git.comparison", "typed-files"),
    ] {
        let mut payload = typed_references.clone();
        payload["root"] = serde_json::json!(root);
        if command == "git.diff" {
            payload["pathspecs"] = serde_json::json!(["."]);
        }
        let request = serde_json::json!({ "id": id, "command": command, "payload": payload });
        let response: Value = serde_json::from_str(&execute_json(&request.to_string()))
            .expect("comparison response should be JSON");
        assert_eq!(response["ok"], true, "{response:?}");
        assert!(response["data"].to_string().contains("example.txt"));
    }

    fs::remove_dir_all(root).expect("temporary repository should be removable");
}

#[test]
fn git_history_returns_references_and_commit_graph_fields() {
    let root = temporary_root("git-history");
    fs::create_dir_all(&root).expect("temporary workspace should be creatable");
    let run = |arguments: &[&str]| {
        Command::new("git")
            .args(arguments)
            .current_dir(&root)
            .output()
            .expect("git should be available")
    };
    assert!(run(&["init", "-q"]).status.success());
    assert!(run(&["config", "core.autocrlf", "false"]).status.success());
    assert!(run(&["config", "user.email", "test@example.com"])
        .status
        .success());
    assert!(run(&["config", "user.name", "Lithe Test"]).status.success());
    fs::write(root.join("example.txt"), "hello\n").expect("file should be writable");
    assert!(run(&["add", "example.txt"]).status.success());
    assert!(run(&["commit", "-qm", "initial"]).status.success());

    let commit_hash = String::from_utf8_lossy(&run(&["rev-parse", "HEAD"]).stdout)
        .trim()
        .to_string();

    let blame_request = serde_json::json!({
        "id": "blame",
        "command": "git.blame",
        "payload": {"root": root, "path": "example.txt"}
    });
    let blame_response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&blame_request).expect("blame request should encode"),
    ))
    .expect("blame response should be JSON");
    assert_eq!(blame_response["ok"], true);
    assert_eq!(blame_response["data"]["lines"][0]["line"], 1);
    assert_eq!(
        blame_response["data"]["lines"][0]["commitHash"],
        commit_hash
    );

    let commit_request = serde_json::json!({
        "id": "commit",
        "command": "git.commit",
        "payload": {"root": root, "commit": commit_hash}
    });
    let commit_response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&commit_request).expect("commit request should encode"),
    ))
    .expect("commit response should be JSON");
    assert_eq!(commit_response["ok"], true);
    assert_eq!(commit_response["data"]["commit"]["hash"], commit_hash);

    let files_request = serde_json::json!({
        "id": "files",
        "command": "git.commitFiles",
        "payload": {"root": root, "commit": commit_hash}
    });
    let files_response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&files_request).expect("commit files request should encode"),
    ))
    .expect("commit files response should be JSON");
    assert_eq!(files_response["ok"], true);
    assert_eq!(files_response["data"]["files"][0]["path"], "example.txt");

    fs::write(root.join("example.txt"), "changed\n").expect("file should be writable");
    let comparison_request = serde_json::json!({
        "id": "comparison",
        "command": "git.comparison",
        "payload": {"root": root, "reference": "HEAD"}
    });
    let comparison_response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&comparison_request).expect("comparison request should encode"),
    ))
    .expect("comparison response should be JSON");
    assert_eq!(comparison_response["ok"], true);
    assert_eq!(
        comparison_response["data"]["files"][0]["path"],
        "example.txt"
    );

    assert!(run(&["stash", "push", "-qm", "saved"]).status.success());
    let stashes_request = serde_json::json!({
        "id": "stashes",
        "command": "git.stashes",
        "payload": {"root": root}
    });
    let stashes_response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&stashes_request).expect("stashes request should encode"),
    ))
    .expect("stashes response should be JSON");
    assert_eq!(stashes_response["ok"], true);
    assert_eq!(stashes_response["data"]["stashes"][0]["message"], "saved");

    let request = serde_json::json!({
        "id": "history",
        "command": "git.history",
        "payload": {"root": root, "reference": "HEAD", "limit": 10}
    });
    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&request).expect("history request should encode"),
    ))
    .expect("history response should be JSON");
    assert_eq!(response["ok"], true);
    assert_eq!(response["data"]["commits"][0]["subject"], "initial");
    assert_eq!(response["data"]["userName"], "Lithe Test");
    assert_eq!(response["data"]["userEmail"], "test@example.com");
    assert!(
        response["data"]["commits"][0]["hash"]
            .as_str()
            .expect("commit hash should be text")
            .len()
            >= 7
    );
    assert!(response["data"]["references"]
        .as_array()
        .expect("references should be an array")
        .iter()
        .any(|reference| reference["kind"] == "local"));

    fs::remove_dir_all(root).expect("temporary workspace should be removable");
}

#[test]
fn git_history_reports_tracking_counts_for_a_noncurrent_local_branch() {
    struct RemoveOnDrop(std::path::PathBuf);

    impl Drop for RemoveOnDrop {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    let root = temporary_root("git-history-tracking-counts");
    let _cleanup = RemoveOnDrop(root.clone());
    fs::create_dir_all(&root).expect("temporary repository should be creatable");
    let run = |arguments: &[&str]| {
        Command::new("git")
            .args(arguments)
            .current_dir(&root)
            .output()
            .expect("git should be available")
    };
    assert!(run(&["init", "-q", "-b", "main"]).status.success());
    assert!(run(&[
        "remote",
        "add",
        "origin",
        "https://example.invalid/repository.git",
    ])
    .status
    .success());
    assert!(run(&["config", "user.email", "test@example.com"])
        .status
        .success());
    assert!(run(&["config", "user.name", "Lithe Test"]).status.success());
    fs::write(root.join("story.txt"), "base\n").expect("test file should be writable");
    assert!(run(&["add", "story.txt"]).status.success());
    assert!(run(&["commit", "-qm", "base"]).status.success());
    assert!(run(&["branch", "feature"]).status.success());

    assert!(run(&["checkout", "-q", "feature"]).status.success());
    fs::write(root.join("story.txt"), "local\n").expect("test file should be writable");
    assert!(run(&["commit", "-qam", "local feature"]).status.success());

    assert!(run(&["checkout", "-q", "main"]).status.success());
    assert!(run(&["checkout", "-qb", "remote-feature"]).status.success());
    fs::write(root.join("story.txt"), "remote\n").expect("test file should be writable");
    assert!(run(&["commit", "-qam", "remote feature"]).status.success());
    let remote_commit = git_text(&root, &["rev-parse", "HEAD"]);
    assert!(run(&["checkout", "-q", "main"]).status.success());
    assert!(
        run(&["update-ref", "refs/remotes/origin/feature", &remote_commit,])
            .status
            .success()
    );
    assert!(run(&["branch", "-D", "remote-feature"]).status.success());
    assert!(
        run(&["update-ref", "refs/remotes/origin/main", "refs/heads/main"])
            .status
            .success()
    );
    assert!(run(&["branch", "--set-upstream-to=origin/main", "main"])
        .status
        .success());
    assert!(
        run(&["branch", "--set-upstream-to=origin/feature", "feature",])
            .status
            .success()
    );

    let request = serde_json::json!({
        "id": "history-tracking-counts",
        "command": "git.history",
        "payload": {"root": root, "limit": 10}
    });
    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&request).expect("history request should encode"),
    ))
    .expect("history response should be JSON");
    assert_eq!(response["ok"], true, "{response:?}");
    let feature = response["data"]["references"]
        .as_array()
        .expect("references should be an array")
        .iter()
        .find(|reference| reference["shortName"] == "feature")
        .expect("feature reference should be returned");
    assert_eq!(feature["isCurrent"], false);
    assert_eq!(feature["upstreamShortName"], "origin/feature");
    assert_eq!(feature["ahead"], 1);
    assert_eq!(feature["behind"], 1);
}

#[test]
fn git_history_returns_bounded_recent_checkout_order_and_stable_fallback() {
    struct RemoveOnDrop(std::path::PathBuf);

    impl Drop for RemoveOnDrop {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    let root = temporary_root("git-recent-branches");
    let _cleanup = RemoveOnDrop(root.clone());
    fs::create_dir_all(&root).expect("temporary repository should be creatable");
    let run = |arguments: &[&str]| {
        Command::new("git")
            .args(arguments)
            .current_dir(&root)
            .output()
            .expect("git should be available")
    };
    assert!(run(&["init", "-q"]).status.success());
    assert!(run(&["config", "user.email", "test@example.com"])
        .status
        .success());
    assert!(run(&["config", "user.name", "Lithe Test"]).status.success());
    fs::write(root.join("example.txt"), "initial\n").expect("file should be writable");
    assert!(run(&["add", "example.txt"]).status.success());
    assert!(run(&["commit", "-qm", "initial"]).status.success());
    assert!(run(&["branch", "-M", "main"]).status.success());
    for branch in ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"] {
        assert!(run(&["branch", branch]).status.success());
    }

    let history = || {
        let request = serde_json::json!({
            "id": "recent-branches",
            "command": "git.history",
            "payload": {"root": root, "limit": 10}
        });
        serde_json::from_str::<Value>(&execute_json(
            &serde_json::to_string(&request).expect("history request should encode"),
        ))
        .expect("history response should be JSON")
    };
    let recent_names = |response: &Value| {
        response["data"]["recentReferences"]
            .as_array()
            .expect("recent references should be an array")
            .iter()
            .map(|reference| {
                reference["shortName"]
                    .as_str()
                    .expect("recent reference name should be text")
                    .to_string()
            })
            .collect::<Vec<_>>()
    };

    let initial = history();
    assert_eq!(initial["ok"], true, "{initial:?}");
    assert_eq!(
        recent_names(&initial),
        ["main", "alpha", "beta", "delta", "epsilon"]
    );

    for branch in [
        "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "gamma",
    ] {
        assert!(run(&["checkout", "-q", branch]).status.success());
    }
    assert!(run(&["branch", "-D", "beta"]).status.success());

    let switched = history();
    assert_eq!(switched["ok"], true, "{switched:?}");
    assert_eq!(
        recent_names(&switched),
        ["gamma", "zeta", "epsilon", "delta", "alpha"]
    );
}

#[test]
fn git_conflict_markers_ignore_markdown_headings() {
    let root = temporary_root("git-markers");
    fs::create_dir_all(&root).expect("temporary workspace should be creatable");
    let run = |arguments: &[&str]| {
        Command::new("git")
            .args(arguments)
            .current_dir(&root)
            .output()
            .expect("git should be available")
    };
    assert!(run(&["init", "-q", "-b", "main"]).status.success());
    assert!(run(&["config", "core.autocrlf", "false"]).status.success());
    assert!(run(&["config", "user.email", "test@example.com"])
        .status
        .success());
    assert!(run(&["config", "user.name", "Lithe Test"]).status.success());

    let markers = || -> Value {
        serde_json::from_str(&execute_json(
            &serde_json::to_string(&serde_json::json!({
                "id": "conflict-markers",
                "command": "git.conflictMarkers",
                "payload": {"root": root}
            }))
            .expect("request should encode"),
        ))
        .expect("conflict marker response should be JSON")
    };

    // A Markdown setext heading underline looks exactly like the middle of a
    // conflict block, so matching a bare `=======` would flag ordinary docs.
    fs::write(root.join("doc.md"), "Title\n=======\n\nbody\n").expect("file should be writable");
    assert!(run(&["add", "doc.md"]).status.success());
    let clean = markers();
    assert_eq!(clean["ok"], true);
    assert_eq!(
        clean["data"]["paths"].as_array().unwrap().len(),
        0,
        "a Markdown heading is not a conflict: {clean}"
    );

    // Only files carrying the opening or closing marker are real conflicts.
    fs::write(
        root.join("code.txt"),
        "a\n<<<<<<< HEAD\nmine\n=======\ntheirs\n>>>>>>> feature\n",
    )
    .expect("file should be writable");
    // The diff3 style adds a `|||||||` base section, which also counts.
    fs::write(
        root.join("diff3.txt"),
        "x\n<<<<<<< HEAD\na\n||||||| base\nb\n=======\nc\n>>>>>>> other\n",
    )
    .expect("file should be writable");
    assert!(run(&["add", "."]).status.success());

    let found = markers();
    let paths = found["data"]["paths"].as_array().unwrap();
    assert_eq!(paths.len(), 2, "{found}");
    assert_eq!(paths[0], "code.txt");
    assert_eq!(paths[1], "diff3.txt");

    fs::remove_dir_all(root).expect("Git fixture should be removable");
}

#[test]
fn git_integration_preflight_separates_merge_overlap_from_rebase_strictness() {
    let root = temporary_root("git-integration");
    fs::create_dir_all(&root).expect("temporary workspace should be creatable");
    let run = |arguments: &[&str]| {
        Command::new("git")
            .args(arguments)
            .current_dir(&root)
            .output()
            .expect("git should be available")
    };
    assert!(run(&["init", "-q", "-b", "main"]).status.success());
    assert!(run(&["config", "core.autocrlf", "false"]).status.success());
    assert!(run(&["config", "user.email", "test@example.com"])
        .status
        .success());
    assert!(run(&["config", "user.name", "Lithe Test"]).status.success());

    fs::write(root.join("shared.txt"), "base\n").expect("file should be writable");
    fs::write(root.join("other.txt"), "untouched\n").expect("file should be writable");
    assert!(run(&["add", "."]).status.success());
    assert!(run(&["commit", "-qm", "initial"]).status.success());

    // A side branch that only ever touches shared.txt.
    assert!(run(&["switch", "-qc", "feature"]).status.success());
    fs::write(root.join("shared.txt"), "incoming\n").expect("file should be writable");
    assert!(run(&["add", "shared.txt"]).status.success());
    assert!(run(&["commit", "-qm", "incoming"]).status.success());
    assert!(run(&["switch", "-q", "main"]).status.success());
    // Move main forward so the branches genuinely diverge.
    fs::write(root.join("main.txt"), "main\n").expect("file should be writable");
    assert!(run(&["add", "main.txt"]).status.success());
    assert!(run(&["commit", "-qm", "main side"]).status.success());

    let preflight = |operation: &str| -> Value {
        serde_json::from_str(&execute_json(
            &serde_json::to_string(&serde_json::json!({
                "id": "integration-preflight",
                "command": "git.integrationPreflight",
                "payload": {
                    "root": root,
                    "reference": "refs/heads/feature",
                    "operation": operation
                }
            }))
            .expect("request should encode"),
        ))
        .expect("integration preflight response should be JSON")
    };

    // A clean tree blocks neither operation.
    assert_eq!(
        preflight("merge")["data"]["blockingPaths"]
            .as_array()
            .unwrap()
            .len(),
        0
    );
    assert_eq!(
        preflight("rebase")["data"]["blockingPaths"]
            .as_array()
            .unwrap()
            .len(),
        0
    );

    // Dirty a file the incoming branch never touches. Git lets a merge proceed
    // here but still refuses a rebase, so the two must report differently.
    fs::write(root.join("other.txt"), "local edit\n").expect("file should be writable");

    let merge = preflight("merge");
    assert_eq!(merge["ok"], true);
    assert_eq!(
        merge["data"]["blockingPaths"].as_array().unwrap().len(),
        0,
        "an unrelated edit should not block a merge: {merge}"
    );
    assert_eq!(merge["data"]["blocksEntirely"], false);

    let rebase = preflight("rebase");
    assert_eq!(rebase["data"]["blockingPaths"][0], "other.txt");
    assert_eq!(rebase["data"]["blocksEntirely"], true);

    // Now dirty the file the merge would write; that one does block it.
    fs::write(root.join("shared.txt"), "local edit\n").expect("file should be writable");
    let overlapping = preflight("merge");
    assert_eq!(overlapping["data"]["blockingPaths"][0], "shared.txt");
    assert_eq!(
        overlapping["data"]["blockingPaths"]
            .as_array()
            .unwrap()
            .len(),
        1,
        "only the overlapping file blocks: {overlapping}"
    );

    // An unknown operation is rejected rather than guessed at.
    let invalid = serde_json::from_str::<Value>(&execute_json(
        &serde_json::to_string(&serde_json::json!({
            "id": "integration-preflight",
            "command": "git.integrationPreflight",
            "payload": {
                "root": root,
                "reference": "refs/heads/feature",
                "operation": "graft"
            }
        }))
        .expect("request should encode"),
    ))
    .expect("response should be JSON");
    assert_eq!(invalid["ok"], false);

    fs::remove_dir_all(root).expect("Git fixture should be removable");
}

#[test]
fn git_integration_preflight_scopes_cherry_pick_to_the_replayed_commit() {
    let root = temporary_root("git-cherry-pick");
    fs::create_dir_all(&root).expect("temporary workspace should be creatable");
    let run = |arguments: &[&str]| {
        Command::new("git")
            .args(arguments)
            .current_dir(&root)
            .output()
            .expect("git should be available")
    };
    assert!(run(&["init", "-q", "-b", "main"]).status.success());
    assert!(run(&["config", "core.autocrlf", "false"]).status.success());
    assert!(run(&["config", "user.email", "test@example.com"])
        .status
        .success());
    assert!(run(&["config", "user.name", "Lithe Test"]).status.success());

    fs::write(root.join("shared.txt"), "base\n").expect("file should be writable");
    fs::write(root.join("other.txt"), "untouched\n").expect("file should be writable");
    assert!(run(&["add", "."]).status.success());
    assert!(run(&["commit", "-qm", "initial"]).status.success());

    // A side branch of two commits. Only the second one touches shared.txt, so
    // picking it must consider that file alone rather than the whole branch.
    assert!(run(&["switch", "-qc", "feature"]).status.success());
    fs::write(root.join("early.txt"), "early\n").expect("file should be writable");
    assert!(run(&["add", "early.txt"]).status.success());
    assert!(run(&["commit", "-qm", "earlier work"]).status.success());
    fs::write(root.join("shared.txt"), "incoming\n").expect("file should be writable");
    assert!(run(&["add", "shared.txt"]).status.success());
    assert!(run(&["commit", "-qm", "touches shared"]).status.success());
    let pick =
        String::from_utf8(run(&["rev-parse", "HEAD"]).stdout).expect("a revision should be UTF-8");
    let pick = pick.trim().to_string();
    assert!(run(&["switch", "-q", "main"]).status.success());

    let preflight = |operation: &str, reference: &str| -> Value {
        serde_json::from_str(&execute_json(
            &serde_json::to_string(&serde_json::json!({
                "id": "integration-preflight",
                "command": "git.integrationPreflight",
                "payload": {
                    "root": root,
                    "reference": reference,
                    "operation": operation
                }
            }))
            .expect("request should encode"),
        ))
        .expect("integration preflight response should be JSON")
    };

    // An edit to a file the picked commit never touches is not in its way, the
    // same rule a merge follows and unlike a rebase.
    fs::write(root.join("other.txt"), "local edit\n").expect("file should be writable");
    for operation in ["cherryPick", "revert"] {
        let clear = preflight(operation, &pick);
        assert_eq!(clear["ok"], true, "{operation} should succeed: {clear}");
        assert_eq!(
            clear["data"]["blockingPaths"].as_array().unwrap().len(),
            0,
            "an unrelated edit should not block {operation}: {clear}"
        );
        assert_eq!(clear["data"]["blocksEntirely"], false);
    }

    // Dirtying the file that commit rewrites does block it.
    fs::write(root.join("shared.txt"), "local edit\n").expect("file should be writable");
    let blocked = preflight("cherryPick", &pick);
    assert_eq!(blocked["data"]["blockingPaths"][0], "shared.txt");
    assert_eq!(
        blocked["data"]["blockingPaths"].as_array().unwrap().len(),
        1,
        "only the file the commit writes blocks it: {blocked}"
    );

    // The branch tip as a whole also adds early.txt, but picking the single
    // commit must not inherit that; a merge of the same ref would report it.
    let merge = preflight("merge", "refs/heads/feature");
    let merge_blocking = merge["data"]["blockingPaths"].as_array().unwrap();
    assert!(
        merge_blocking.iter().any(|path| path == "shared.txt"),
        "the merge shares the overlap: {merge}"
    );

    fs::remove_dir_all(root).expect("Git fixture should be removable");
}

#[test]
fn git_pull_preflight_reports_divergence_and_strategies_resolve_it() {
    let root = temporary_root("git-pull");
    let upstream = root.join("upstream");
    let work = root.join("work");
    fs::create_dir_all(&upstream).expect("temporary workspace should be creatable");

    let git = |directory: &std::path::Path, arguments: &[&str]| {
        Command::new("git")
            .args(arguments)
            .current_dir(directory)
            .output()
            .expect("git should be available")
    };
    let identify = |directory: &std::path::Path| {
        assert!(git(directory, &["config", "core.autocrlf", "false"])
            .status
            .success());
        assert!(
            git(directory, &["config", "user.email", "test@example.com"])
                .status
                .success()
        );
        assert!(git(directory, &["config", "user.name", "Lithe Test"])
            .status
            .success());
    };

    assert!(git(&upstream, &["init", "-q", "-b", "main"])
        .status
        .success());
    identify(&upstream);
    fs::write(upstream.join("shared.txt"), "base\n").expect("file should be writable");
    assert!(git(&upstream, &["add", "shared.txt"]).status.success());
    assert!(git(&upstream, &["commit", "-qm", "initial"])
        .status
        .success());

    assert!(git(
        &root,
        &[
            "clone",
            "-q",
            "-c",
            "core.autocrlf=false",
            "upstream",
            "work"
        ]
    )
    .status
    .success());
    identify(&work);

    let preflight = || -> Value {
        serde_json::from_str(&execute_json(
            &serde_json::to_string(&serde_json::json!({
                "id": "pull-preflight",
                "command": "git.pullPreflight",
                "payload": {"root": work}
            }))
            .expect("request should encode"),
        ))
        .expect("pull preflight response should be JSON")
    };

    // A fresh clone is level with its upstream, so nothing needs deciding.
    let clean = preflight();
    assert_eq!(clean["ok"], true);
    assert_eq!(clean["data"]["upstream"], "origin/main");
    assert_eq!(clean["data"]["diverged"], false);
    assert_eq!(clean["data"]["ahead"], 0);
    assert_eq!(clean["data"]["behind"], 0);

    // Commit on both sides so neither can fast-forward past the other.
    fs::write(upstream.join("remote.txt"), "remote\n").expect("file should be writable");
    assert!(git(&upstream, &["add", "remote.txt"]).status.success());
    assert!(git(&upstream, &["commit", "-qm", "remote"])
        .status
        .success());
    fs::write(work.join("local.txt"), "local\n").expect("file should be writable");
    assert!(git(&work, &["add", "local.txt"]).status.success());
    assert!(git(&work, &["commit", "-qm", "local"]).status.success());
    assert!(git(&work, &["fetch", "-q"]).status.success());

    let diverged = preflight();
    assert_eq!(diverged["data"]["diverged"], true);
    assert_eq!(diverged["data"]["ahead"], 1);
    assert_eq!(diverged["data"]["behind"], 1);

    let pull = |mode: Option<&str>| -> Value {
        let mut payload = serde_json::json!({"root": work, "operation": "pull"});
        if let Some(mode) = mode {
            payload["mode"] = serde_json::json!(mode);
        }
        serde_json::from_str(&execute_json(
            &serde_json::to_string(&serde_json::json!({
                "id": "pull",
                "command": "git.write",
                "payload": payload
            }))
            .expect("request should encode"),
        ))
        .expect("pull response should be JSON")
    };

    // The default refuses a divergent history rather than inventing a merge.
    let refused = pull(None);
    assert_ne!(refused["data"]["exitCode"], 0);

    // Rebase replays the local commit on top, leaving a linear history.
    let rebased = pull(Some("rebase"));
    assert_eq!(rebased["data"]["exitCode"], 0, "{rebased}");

    let settled = preflight();
    assert_eq!(settled["data"]["diverged"], false);
    assert_eq!(settled["data"]["behind"], 0);
    assert_eq!(settled["data"]["ahead"], 1);

    // An unknown strategy is rejected before Git ever runs.
    let invalid = pull(Some("squash"));
    assert_eq!(invalid["ok"], false);

    fs::remove_dir_all(root).expect("Git fixture should be removable");
}

#[test]
fn explicit_pull_resolves_nested_remote_and_branch_names_against_bare_remote() {
    let root = temporary_root("git-pull-nested-ref");
    let source = root.join("source");
    let work = root.join("work");
    fs::create_dir_all(&source).expect("source should be creatable");
    let git = |directory: &Path, arguments: &[&str]| {
        Command::new("git")
            .args(arguments)
            .current_dir(directory)
            .output()
            .expect("git should be available")
    };
    assert!(git(&source, &["init", "--bare", "-q"]).status.success());
    let seed = root.join("seed");
    fs::create_dir_all(&seed).expect("seed should be creatable");
    assert!(git(&seed, &["init", "-q", "-b", "main"]).status.success());
    assert!(git(&seed, &["config", "user.email", "test@example.com"])
        .status
        .success());
    assert!(git(&seed, &["config", "user.name", "Lithe Test"])
        .status
        .success());
    fs::write(seed.join("base.txt"), "base\n").expect("file should be writable");
    assert!(git(&seed, &["add", "."]).status.success());
    assert!(git(&seed, &["commit", "-qm", "base"]).status.success());
    assert!(git(
        &seed,
        &[
            "remote",
            "add",
            "company/origin",
            source.to_string_lossy().as_ref()
        ]
    )
    .status
    .success());
    assert!(git(&seed, &["push", "-q", "company/origin", "main"])
        .status
        .success());
    assert!(git(&seed, &["switch", "-c", "feature/core"])
        .status
        .success());
    fs::write(seed.join("nested.txt"), "nested\n").expect("file should be writable");
    assert!(git(&seed, &["add", "."]).status.success());
    assert!(git(&seed, &["commit", "-qm", "nested"]).status.success());
    assert!(
        git(&seed, &["push", "-q", "company/origin", "feature/core"])
            .status
            .success()
    );
    assert!(git(
        &root,
        &[
            "clone",
            "-q",
            seed.to_string_lossy().as_ref(),
            work.to_string_lossy().as_ref()
        ]
    )
    .status
    .success());
    assert!(git(&work, &["remote", "remove", "origin"]).status.success());
    assert!(git(
        &work,
        &[
            "remote",
            "add",
            "company/origin",
            source.to_string_lossy().as_ref()
        ]
    )
    .status
    .success());
    let response: Value = serde_json::from_str(&execute_json(&serde_json::to_string(&serde_json::json!({
        "id": "nested-pull", "command": "git.write", "payload": {
            "root": work, "operation": "pull", "reference": "refs/remotes/company/origin/feature/core",
            "referenceKind": "remote", "mode": "rebase"
        }
    })).expect("request should encode"))).expect("response should be JSON");
    assert_eq!(response["ok"], true, "{response}");
    assert_eq!(response["data"]["exitCode"], 0, "{response}");
    assert_eq!(
        fs::read_to_string(work.join("nested.txt"))
            .expect("file should exist")
            .replace("\r\n", "\n"),
        "nested\n"
    );
    fs::remove_dir_all(root).expect("fixture should be removable");
}

#[test]
fn git_typed_remote_checkout_rebase_blocks_dirty_tree_before_switching() {
    let root = temporary_root("git-checkout-rebase-remote");
    let upstream = root.join("upstream");
    let work = root.join("work");
    fs::create_dir_all(&upstream).expect("temporary workspace should be creatable");
    let git = |directory: &Path, arguments: &[&str]| history_git(directory, arguments);
    let identify = |directory: &Path| {
        assert!(git(directory, &["config", "core.autocrlf", "false"])
            .status
            .success());
        assert!(
            git(directory, &["config", "user.email", "test@example.com"])
                .status
                .success()
        );
        assert!(git(directory, &["config", "user.name", "Lithe Test"])
            .status
            .success());
    };
    assert!(git(&upstream, &["init", "-q", "-b", "main"])
        .status
        .success());
    identify(&upstream);
    fs::write(upstream.join("base.txt"), "base\n").expect("base file should be writable");
    assert!(git(&upstream, &["add", "."]).status.success());
    assert!(git(&upstream, &["commit", "-qm", "base"]).status.success());
    assert!(git(&upstream, &["switch", "-qc", "feature"])
        .status
        .success());
    fs::write(upstream.join("feature.txt"), "feature\n").expect("feature file should be writable");
    assert!(git(&upstream, &["add", "."]).status.success());
    assert!(git(&upstream, &["commit", "-qm", "feature"])
        .status
        .success());
    assert!(git(&upstream, &["switch", "-q", "main"]).status.success());
    fs::write(upstream.join("main.txt"), "main\n").expect("main file should be writable");
    assert!(git(&upstream, &["add", "."]).status.success());
    assert!(git(&upstream, &["commit", "-qm", "main"]).status.success());
    assert!(git(
        &root,
        &[
            "clone",
            "-q",
            "-c",
            "core.autocrlf=false",
            "-b",
            "main",
            upstream.to_str().expect("path should be UTF-8"),
            "work"
        ]
    )
    .status
    .success());
    identify(&work);

    let write = |operation: &str, extra: Value| -> Value {
        let mut payload = serde_json::json!({
            "root": work,
            "operation": operation,
            "gitReference": {
                "fullName": "refs/remotes/origin/feature",
                "shortName": "origin/feature",
                "kind": "remote"
            }
        });
        if let Value::Object(fields) = extra {
            for (key, value) in fields {
                payload[key] = value;
            }
        }
        serde_json::from_str(&execute_json(
            &serde_json::to_string(&serde_json::json!({
                "id": operation,
                "command": "git.write",
                "payload": payload
            }))
            .expect("request should encode"),
        ))
        .expect("response should decode")
    };

    fs::write(work.join("untracked.txt"), "dirty\n").expect("dirty file should be writable");
    let blocked = write("checkoutAndRebase", serde_json::json!({}));
    assert_eq!(blocked["ok"], true, "{blocked}");
    assert_eq!(blocked["data"]["operationError"]["code"], "invalid_request");
    assert_eq!(git_text(&work, &["branch", "--show-current"]), "main");

    fs::remove_file(work.join("untracked.txt")).expect("dirty file should be removable");
    let completed = write("checkoutAndRebase", serde_json::json!({}));
    assert_eq!(completed["ok"], true, "{completed}");
    assert_eq!(completed["data"]["exitCode"], 0, "{completed}");
    assert_eq!(git_text(&work, &["branch", "--show-current"]), "feature");
    assert!(
        git(&work, &["merge-base", "--is-ancestor", "main", "feature"])
            .status
            .success()
    );

    fs::remove_dir_all(root).expect("Git fixture should be removable");
}

#[test]
fn git_remote_checkout_rejects_a_same_named_local_branch_with_another_upstream() {
    let root = temporary_root("git-checkout-remote-upstream-identity");
    fs::create_dir_all(&root).expect("temporary repository should be creatable");
    let run = |arguments: &[&str]| history_git(&root, arguments);
    assert!(run(&["init", "-q", "-b", "main"]).status.success());
    assert!(run(&["config", "core.autocrlf", "false"]).status.success());
    assert!(run(&["config", "user.email", "test@example.com"])
        .status
        .success());
    assert!(run(&["config", "user.name", "Lithe Test"]).status.success());
    fs::write(root.join("base.txt"), "base\n").expect("file should be writable");
    assert!(run(&["add", "base.txt"]).status.success());
    assert!(run(&["commit", "-qm", "base"]).status.success());
    assert!(run(&[
        "remote",
        "add",
        "origin",
        "https://example.invalid/origin.git"
    ])
    .status
    .success());
    assert!(run(&[
        "remote",
        "add",
        "upstream",
        "https://example.invalid/upstream.git"
    ])
    .status
    .success());
    assert!(run(&["update-ref", "refs/remotes/origin/feature", "HEAD"])
        .status
        .success());
    assert!(
        run(&["update-ref", "refs/remotes/upstream/feature", "HEAD"])
            .status
            .success()
    );
    assert!(run(&["branch", "feature", "refs/remotes/origin/feature"])
        .status
        .success());
    assert!(
        run(&["branch", "--set-upstream-to=origin/feature", "feature"])
            .status
            .success()
    );

    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&serde_json::json!({
            "id": "checkout-upstream-feature",
            "command": "git.write",
            "payload": {
                "root": root,
                "operation": "checkout",
                "gitReference": {
                    "fullName": "refs/remotes/upstream/feature",
                    "shortName": "upstream/feature",
                    "kind": "remote"
                }
            }
        }))
        .expect("remote checkout request should encode"),
    ))
    .expect("remote checkout response should be JSON");

    assert_eq!(response["ok"], true, "{response:?}");
    assert_eq!(
        response["data"]["operationError"]["message"],
        "A same-named local branch tracks a different Git reference"
    );
    assert_eq!(git_text(&root, &["branch", "--show-current"]), "main");

    fs::remove_dir_all(root).expect("temporary repository should be removable");
}

#[test]
fn git_explicit_remote_pull_validates_identity_and_strategy() {
    let root = temporary_root("git-pull-remote-reference");
    let upstream = root.join("upstream");
    let work = root.join("work");
    fs::create_dir_all(&upstream).expect("temporary workspace should be creatable");
    assert!(history_git(&upstream, &["init", "-q", "-b", "main"])
        .status
        .success());
    assert!(
        history_git(&upstream, &["config", "user.email", "test@example.com"])
            .status
            .success()
    );
    assert!(
        history_git(&upstream, &["config", "user.name", "Lithe Test"])
            .status
            .success()
    );
    fs::write(upstream.join("base.txt"), "base\n").expect("base file should be writable");
    assert!(history_git(&upstream, &["add", "."]).status.success());
    assert!(history_git(&upstream, &["commit", "-qm", "base"])
        .status
        .success());
    assert!(history_git(&upstream, &["switch", "-qc", "feature"])
        .status
        .success());
    fs::write(upstream.join("feature.txt"), "feature\n").expect("feature file should be writable");
    assert!(history_git(&upstream, &["add", "."]).status.success());
    assert!(history_git(&upstream, &["commit", "-qm", "feature"])
        .status
        .success());
    assert!(history_git(&upstream, &["switch", "-q", "main"])
        .status
        .success());
    fs::write(upstream.join("main.txt"), "main\n").expect("main file should be writable");
    assert!(history_git(&upstream, &["add", "."]).status.success());
    assert!(history_git(&upstream, &["commit", "-qm", "main"])
        .status
        .success());
    assert!(history_git(
        &root,
        &[
            "clone",
            "-q",
            "-c",
            "core.autocrlf=false",
            "-b",
            "main",
            upstream.to_str().expect("path should be UTF-8"),
            "work"
        ]
    )
    .status
    .success());
    assert!(
        history_git(&work, &["config", "user.email", "test@example.com"])
            .status
            .success()
    );
    assert!(history_git(&work, &["config", "user.name", "Lithe Test"])
        .status
        .success());

    let pull = |reference: Value, mode: &str| -> Value {
        serde_json::from_str(&execute_json(
            &serde_json::to_string(&serde_json::json!({
                "id": "pull-remote",
                "command": "git.write",
                "payload": {
                    "root": work,
                    "operation": "pull",
                    "gitReference": reference,
                    "mode": mode
                }
            }))
            .expect("request should encode"),
        ))
        .expect("response should decode")
    };
    let remote_reference = serde_json::json!({
        "fullName": "refs/remotes/origin/feature",
        "shortName": "origin/feature",
        "kind": "remote"
    });
    let merged = pull(remote_reference.clone(), "merge");
    assert_eq!(merged["ok"], true, "{merged}");
    assert_eq!(merged["data"]["exitCode"], 0, "{merged}");
    assert_eq!(
        git_text(&work, &["rev-list", "--parents", "-n", "1", "HEAD"])
            .split_whitespace()
            .count(),
        3
    );

    let mismatched = pull(
        serde_json::json!({
            "fullName": "refs/remotes/origin/feature",
            "shortName": "feature",
            "kind": "local"
        }),
        "rebase",
    );
    assert_eq!(mismatched["ok"], false, "{mismatched}");
    assert_eq!(mismatched["error"]["code"], "invalid_request");

    fs::remove_dir_all(root).expect("Git fixture should be removable");
}

fn git_write_repository(label: &str) -> std::path::PathBuf {
    let root = temporary_root(label);
    fs::create_dir_all(&root).expect("temporary repository should be creatable");
    assert!(history_git(&root, &["init", "-q"]).status.success());
    assert!(history_git(&root, &["config", "core.autocrlf", "false"])
        .status
        .success());
    assert!(
        history_git(&root, &["config", "user.email", "test@example.com"])
            .status
            .success()
    );
    assert!(history_git(&root, &["config", "user.name", "Lithe Test"])
        .status
        .success());
    assert!(history_git(&root, &["remote", "add", "origin", "."])
        .status
        .success());
    root
}

fn git_write_request(root: &Path, operation: &str, overrides: Value) -> Value {
    let mut request = serde_json::json!({
        "id": operation,
        "command": "git.write",
        "payload": {
            "root": root,
            "operation": operation,
            "paths": [],
            "reference": null,
            "referenceKind": null,
            "revision": null,
            "name": null,
            "message": null,
            "remote": null,
            "destination": null,
            "mode": null,
            "includeUntracked": false,
            "checkout": false,
            "amend": false
        }
    });
    if let Value::Object(overrides) = overrides {
        for (key, value) in overrides {
            request["payload"][key.as_str()] = value;
        }
    }
    serde_json::from_str(&execute_json(
        &serde_json::to_string(&request).expect("write request should encode"),
    ))
    .expect("write response should be JSON")
}

fn history_rewrite_repository(label: &str) -> std::path::PathBuf {
    let root = temporary_root(label);
    fs::create_dir_all(&root).expect("temporary repository should be creatable");
    assert!(history_git(&root, &["init", "-q", "-b", "main"])
        .status
        .success());
    assert!(history_git(&root, &["config", "core.autocrlf", "false"])
        .status
        .success());
    assert!(
        history_git(&root, &["config", "user.email", "test@example.com"])
            .status
            .success()
    );
    assert!(history_git(&root, &["config", "user.name", "Lithe Test"])
        .status
        .success());
    root
}

fn commit_history_file(root: &Path, path: &str, contents: &str, message: &str) {
    fs::write(root.join(path), contents).expect("history fixture file should be writable");
    assert!(history_git(root, &["add", "--", path]).status.success());
    assert!(history_git(root, &["commit", "-qm", message])
        .status
        .success());
}

fn history_write(root: &Path, overrides: Value) -> Value {
    let mut payload = serde_json::json!({"root": root});
    if let Value::Object(overrides) = overrides {
        for (key, value) in overrides {
            payload[key.as_str()] = value;
        }
    }
    serde_json::from_str(&execute_json(
        &serde_json::to_string(&serde_json::json!({
            "id": "history-write",
            "command": "git.write",
            "payload": payload
        }))
        .expect("history rewrite request should encode"),
    ))
    .expect("history rewrite response should be JSON")
}

fn history_git(root: &Path, arguments: &[&str]) -> std::process::Output {
    Command::new("git")
        .args(arguments)
        .current_dir(root)
        .output()
        .expect("git should be available")
}

fn git_text(root: &Path, arguments: &[&str]) -> String {
    let output = history_git(root, arguments);
    assert!(
        output.status.success(),
        "git {:?} failed: {}",
        arguments,
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}
