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
fn git_write_validates_and_executes_shared_mutations() {
    let root = temporary_root("git-write");
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
    fs::write(root.join("example.txt"), "initial\n").expect("file should be writable");

    let request = |operation: &str, payload: Value| -> Value {
        let request = serde_json::json!({
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
        let mut request = request;
        if let Value::Object(overrides) = payload {
            for (key, value) in overrides {
                request["payload"][key.as_str()] = value;
            }
        }
        serde_json::from_str(&execute_json(
            &serde_json::to_string(&request).expect("write request should encode"),
        ))
        .expect("write response should be JSON")
    };

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

    // Conflict-dialog rollback must discard both sides of a file, including
    // a staged edit followed by a working-tree edit.
    fs::write(root.join("example.txt"), "staged\n").expect("file should be writable");
    assert!(run(&["add", "example.txt"]).status.success());
    fs::write(root.join("example.txt"), "working\n").expect("file should be writable");
    let discard_all = request("discardAll", serde_json::json!({"paths": ["example.txt"]}));
    assert_eq!(discard_all["ok"], true, "{discard_all:?}");
    assert_eq!(
        discard_all["data"]["arguments"],
        serde_json::json!(["checkout", "HEAD", "--", "example.txt"])
    );
    assert_eq!(
        discard_all["data"]["invocations"]
            .as_array()
            .expect("discardAll invocations should be an array")
            .iter()
            .map(|invocation| invocation["arguments"][0].as_str().unwrap_or_default())
            .collect::<Vec<_>>(),
        vec!["status", "checkout"]
    );
    assert_eq!(
        fs::read_to_string(root.join("example.txt")).expect("file should be readable"),
        "initial\n"
    );
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
