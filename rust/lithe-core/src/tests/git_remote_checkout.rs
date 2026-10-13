use super::support::temporary_root;
use crate::execute_json;
use serde_json::{json, Value};
use std::{fs, path::PathBuf};

// Real repositories exercise Fetch, ref updates and worktree contents. Every
// subprocess goes through Core's native host deadline, including fixture setup.
struct CheckoutFixture {
    root: PathBuf,
    remote: PathBuf,
    work: PathBuf,
}

impl CheckoutFixture {
    fn new() -> Self {
        let root = temporary_root("remote-checkout");
        let fixture = Self {
            remote: root.join("remote"),
            work: root.join("work"),
            root,
        };
        fs::create_dir_all(&fixture.remote).unwrap();
        fixture.git_at(&fixture.remote, &["init", "-q", "-b", "preview"]);
        fixture.configure(&fixture.remote);
        fs::write(fixture.remote.join("base.txt"), "base\n").unwrap();
        fs::write(fixture.remote.join("notes.txt"), "notes\n").unwrap();
        fixture.git_at(&fixture.remote, &["add", "."]);
        fixture.git_at(&fixture.remote, &["commit", "-qm", "base"]);
        fixture.git_at(
            &fixture.root,
            &[
                "clone",
                "--config",
                "core.autocrlf=false",
                "--no-hardlinks",
                "--origin",
                "upstream",
                fixture.remote.to_str().unwrap(),
                fixture.work.to_str().unwrap(),
            ],
        );
        fixture.configure(&fixture.work);
        fixture.git(&["branch", "other"]);
        fs::write(fixture.remote.join("base.txt"), "remote update\n").unwrap();
        fs::write(fixture.remote.join("remote.txt"), "remote file\n").unwrap();
        fixture.git_at(&fixture.remote, &["add", "."]);
        fixture.git_at(&fixture.remote, &["commit", "-qm", "remote update"]);
        let fetched = fixture.call(
            "git.write",
            json!({
                "operation": "fetch", "fetchOptions": {"remote": "upstream"}
            }),
        );
        assert_success(&fetched);
        fixture
    }

    fn configure(&self, path: &std::path::Path) {
        for (key, value) in [
            ("user.name", "Lithe Test"),
            ("user.email", "test@example.com"),
            ("core.autocrlf", "false"),
            ("commit.gpgsign", "false"),
        ] {
            self.git_at(path, &["config", key, value]);
        }
    }

    fn call_at(&self, path: &std::path::Path, command: &str, mut payload: Value) -> Value {
        payload["root"] = json!(path);
        serde_json::from_str(&execute_json(
            &json!({
                "id": "remote-checkout-test", "command": command,
                "timeoutMilliseconds": 5000, "payload": payload,
            })
            .to_string(),
        ))
        .unwrap()
    }

    fn call(&self, command: &str, payload: Value) -> Value {
        self.call_at(&self.work, command, payload)
    }

    fn git_at(&self, path: &std::path::Path, arguments: &[&str]) -> String {
        let response = self.call_at(path, "git.command", json!({"arguments": arguments}));
        assert_success(&response);
        response["data"]["stdout"]
            .as_str()
            .unwrap()
            .trim()
            .to_string()
    }

    fn git(&self, arguments: &[&str]) -> String {
        self.git_at(&self.work, arguments)
    }

    fn snapshot(&self) -> Vec<String> {
        [
            vec!["symbolic-ref", "HEAD"],
            vec!["rev-parse", "HEAD"],
            vec![
                "for-each-ref",
                "--format=%(refname) %(objectname)",
                "refs/heads",
            ],
            vec!["status", "--porcelain"],
            vec!["diff", "--binary"],
            vec!["diff", "--cached", "--binary"],
            vec!["stash", "list"],
        ]
        .iter()
        .map(|arguments| self.git(arguments))
        .collect()
    }
}

impl Drop for CheckoutFixture {
    fn drop(&mut self) {
        if let Err(error) = fs::remove_dir_all(&self.root) {
            eprintln!("Could not remove remote checkout fixture: {error}");
        }
    }
}

fn assert_success(response: &Value) {
    assert_eq!(response["ok"], true, "{response}");
    assert_eq!(response["data"]["exitCode"], 0, "{response}");
    assert!(response["data"]["operationError"].is_null(), "{response}");
    assert!(response["data"]["stashRestore"].is_null(), "{response}");
}

fn contract() -> Value {
    serde_json::from_str(include_str!(
        "../../../../shared/fixtures/git/remote-checkout-v1.json"
    ))
    .unwrap()
}

fn exercise_case(id: &str) {
    let contract = contract();
    let case = contract["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|case| case["id"] == id)
        .unwrap();
    let fixture = CheckoutFixture::new();
    if case["localHistory"] == "ahead" {
        fixture.git(&["reset", "--hard", "upstream/preview"]);
    }
    if matches!(case["localHistory"].as_str(), Some("ahead" | "diverged")) {
        fs::write(fixture.work.join("local.txt"), "local commit\n").unwrap();
        fixture.git(&["add", "local.txt"]);
        fixture.git(&["commit", "-qm", "local commit"]);
    }
    fixture.git(&["switch", case["startingBranch"].as_str().unwrap()]);
    if case["localHistory"] == "missing" {
        fixture.git(&["branch", "-D", "preview"]);
    }
    if case["otherWorktree"] == true {
        fixture.git(&[
            "worktree",
            "add",
            fixture.root.join("linked").to_str().unwrap(),
            "preview",
        ]);
    }
    match case["dirty"].as_str() {
        Some("tracked" | "staged") => {
            fs::write(fixture.work.join("base.txt"), "local edit\n").unwrap();
            if case["dirty"] == "staged" {
                fixture.git(&["add", "base.txt"]);
            }
        }
        Some("untracked") => {
            fs::write(fixture.work.join("remote.txt"), "untracked edit\n").unwrap();
        }
        Some("unrelated") => {
            fs::write(fixture.work.join("notes.txt"), "local notes\n").unwrap();
        }
        _ => {}
    }
    let before = fixture.snapshot();
    let files_before =
        ["base.txt", "notes.txt", "remote.txt"].map(|name| fs::read(fixture.work.join(name)).ok());
    let response = fixture.call(
        "git.write",
        json!({
            "operation": "checkout", "gitReference": contract["reference"],
            "force": case["force"].as_bool().unwrap_or(false),
            "autoStash": case["autoStash"].as_bool().unwrap_or(false),
        }),
    );
    if case["expected"] == "blocked" {
        assert!(
            response["ok"] == false
                || response["data"]["exitCode"] != 0
                || !response["data"]["operationError"].is_null(),
            "{response}"
        );
        assert_eq!(
            fixture.snapshot(),
            before,
            "blocked checkout must preserve refs, HEAD, index and stash: {response}"
        );
        assert_eq!(
            ["base.txt", "notes.txt", "remote.txt"]
                .map(|name| fs::read(fixture.work.join(name)).ok()),
            files_before
        );
        if matches!(case["localHistory"].as_str(), Some("ahead" | "diverged")) {
            assert!(
                response["data"]["operationError"]["message"]
                    .as_str()
                    .unwrap()
                    .contains("commits not included"),
                "{response}"
            );
        }
        return;
    }
    assert_success(&response);
    assert_eq!(fixture.git(&["symbolic-ref", "HEAD"]), "refs/heads/preview");
    assert_eq!(
        fixture.git(&["rev-parse", "HEAD"]),
        fixture.git(&["rev-parse", "upstream/preview"])
    );
    assert_eq!(
        fixture.git(&[
            "rev-list",
            "--left-right",
            "--count",
            "preview...upstream/preview"
        ]),
        "0\t0"
    );
    assert_eq!(
        fixture.git(&["for-each-ref", "--format=%(upstream)", "refs/heads/preview"]),
        "refs/remotes/upstream/preview"
    );
    assert_eq!(
        fs::read_to_string(fixture.work.join("base.txt")).unwrap(),
        "remote update\n"
    );
    assert_eq!(
        fs::read_to_string(fixture.work.join("remote.txt")).unwrap(),
        "remote file\n"
    );
    assert_eq!(
        fs::read_to_string(fixture.work.join("notes.txt")).unwrap(),
        if case["dirty"] == "unrelated" {
            "local notes\n"
        } else {
            "notes\n"
        }
    );
    assert!(fixture.git(&["stash", "list"]).is_empty());
    // Repeat on the already aligned current branch: remote checkout is idempotent.
    assert_success(&fixture.call(
        "git.write",
        json!({
            "operation": "checkout", "gitReference": contract["reference"]
        }),
    ));
}

#[test]
fn remote_checkout_from_another_branch_fast_forwards() {
    exercise_case("behind-other");
}
#[test]
fn remote_checkout_updates_the_current_tracking_branch() {
    exercise_case("behind-current");
}
#[test]
fn remote_checkout_creates_a_missing_local_branch_at_the_remote_tip() {
    exercise_case("missing-local");
}
#[test]
fn remote_checkout_blocks_dirty_files_before_switching() {
    exercise_case("dirty-other");
}
#[test]
fn remote_checkout_preserves_staged_files_on_the_current_branch() {
    exercise_case("dirty-current");
}
#[test]
fn remote_checkout_preserves_blocking_untracked_files() {
    exercise_case("untracked-other");
}
#[test]
fn remote_checkout_force_discards_working_changes_and_fast_forwards() {
    exercise_case("force-other");
}
#[test]
fn remote_checkout_force_updates_the_current_branch() {
    exercise_case("force-current");
}
#[test]
fn remote_checkout_smart_restores_changes_after_switching_and_updating() {
    exercise_case("smart-other");
}
#[test]
fn remote_checkout_smart_updates_the_current_branch_and_restores_changes() {
    exercise_case("smart-current");
}
#[test]
fn remote_checkout_force_does_not_drop_local_commits() {
    exercise_case("ahead-local");
}
#[test]
fn remote_checkout_rejects_divergence_before_creating_a_stash() {
    exercise_case("diverged-local");
}
#[test]
fn remote_checkout_does_not_update_a_branch_occupied_by_another_worktree() {
    exercise_case("other-worktree");
}

#[test]
fn remote_checkout_does_not_change_ordinary_local_checkout() {
    let fixture = CheckoutFixture::new();
    let old_tip = fixture.git(&["rev-parse", "preview"]);
    fixture.git(&["switch", "other"]);
    assert_success(&fixture.call(
        "git.write",
        json!({
            "operation": "checkout", "reference": "refs/heads/preview", "referenceKind": "local"
        }),
    ));
    assert_eq!(fixture.git(&["rev-parse", "HEAD"]), old_tip);
    assert_ne!(old_tip, fixture.git(&["rev-parse", "upstream/preview"]));
}

#[test]
fn remote_checkout_updates_legacy_remote_reference_requests() {
    let fixture = CheckoutFixture::new();
    assert_success(&fixture.call("git.write", json!({
        "operation": "checkout", "reference": "refs/remotes/upstream/preview", "referenceKind": "remote"
    })));
    assert_eq!(
        fixture.git(&["rev-parse", "HEAD"]),
        fixture.git(&["rev-parse", "upstream/preview"])
    );
}

#[test]
fn remote_checkout_keeps_checkout_and_rebase_history_policy() {
    let fixture = CheckoutFixture::new();
    fs::write(fixture.work.join("local.txt"), "local commit\n").unwrap();
    fixture.git(&["add", "local.txt"]);
    fixture.git(&["commit", "-qm", "local commit"]);
    let local_tip = fixture.git(&["rev-parse", "preview"]);
    fixture.git(&["switch", "other"]);
    assert_success(&fixture.call(
        "git.write",
        json!({
            "operation": "checkoutAndRebase", "gitReference": contract()["reference"]
        }),
    ));
    assert_eq!(fixture.git(&["rev-parse", "HEAD"]), local_tip);
}

#[test]
fn remote_checkout_rechecks_the_local_tip_after_post_checkout_hooks() {
    let fixture = CheckoutFixture::new();
    let original = fixture.git(&["rev-parse", "preview"]);
    let tree = fixture.git(&["rev-parse", "preview^{tree}"]);
    let hook_commit = fixture.git(&["commit-tree", &tree, "-p", &original, "-m", "hook commit"]);
    fixture.git(&["switch", "other"]);
    let hook = fixture.work.join(".git/hooks/post-checkout");
    // The hook deterministically simulates a new local commit between the
    // initial ancestry check and integration, without timers or external races.
    fs::write(
        &hook,
        format!("#!/bin/sh\ngit update-ref refs/heads/preview {hook_commit}\n"),
    )
    .unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&hook, fs::Permissions::from_mode(0o755)).unwrap();
    }
    let response = fixture.call(
        "git.write",
        json!({
            "operation": "checkout", "gitReference": contract()["reference"]
        }),
    );
    assert_eq!(
        response["data"]["operationError"]["message"],
        "The selected branch changed; review and retry"
    );
    assert_eq!(fixture.git(&["rev-parse", "HEAD"]), hook_commit);
    assert_eq!(fixture.git(&["symbolic-ref", "HEAD"]), "refs/heads/preview");
    assert_eq!(
        fs::read_to_string(fixture.work.join("base.txt")).unwrap(),
        "base\n"
    );
}
