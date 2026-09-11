use super::support::temporary_root;
use crate::execute_json;
use serde_json::{json, Value};
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

static REQUEST_SEQUENCE: AtomicU64 = AtomicU64::new(0);

/// Temporary integration repository whose files are removed even after a failed assertion.
struct Repository(PathBuf);

impl Repository {
    fn new(label: &str) -> Self {
        let result = Self(temporary_root(label));
        fs::create_dir_all(&result.0).unwrap();
        result.git(&["init", "-q", "-b", "main"]);
        result.git(&["config", "user.name", "Lithe Fixture"]);
        result.git(&["config", "user.email", "fixture@example.invalid"]);
        result.git(&["config", "core.autocrlf", "false"]);
        result.git(&["config", "commit.gpgSign", "false"]);
        result.git(&["config", "gc.auto", "0"]);
        result.git(&["config", "core.hooksPath", "disabled-fixture-hooks"]);
        result
    }

    fn request(&self, command: &str, mut payload: Value) -> Value {
        payload["root"] = json!(self.0);
        // Each real Git subprocess is governed by Core's local deadline; tests
        // do not synchronize using sleeps or depend on a network remote. A rewrite
        // starts many Git processes on Windows, so allow ten seconds within the
        // outer 15-second per-test watchdog.
        serde_json::from_str(&execute_json(&json!({
            "id": format!("history-integration-{}", REQUEST_SEQUENCE.fetch_add(1, Ordering::Relaxed)),
            "timeoutMilliseconds": 10_000,
            "command": command,
            "payload": payload,
        }).to_string())).unwrap()
    }

    fn git(&self, arguments: &[&str]) -> String {
        let response = self.request("git.command", json!({"arguments": arguments}));
        assert_eq!(response["ok"], true, "{response}");
        assert_eq!(response["data"]["exitCode"], 0, "{response}");
        assert!(response["data"]["operationError"].is_null(), "{response}");
        response["data"]["stdout"]
            .as_str()
            .unwrap()
            .trim()
            .to_string()
    }

    fn commit(&self, path: &str, content: &str, message: &str) -> String {
        fs::write(self.0.join(path), content).unwrap();
        self.git(&["add", "--", path]);
        self.git(&["commit", "-qm", message]);
        self.git(&["rev-parse", "HEAD"])
    }

    fn preview(&self, operation: &str, revisions: &[&str]) -> Value {
        let response = self.request(
            "git.historyRewritePreview",
            json!({"operation": operation, "revisions": revisions}),
        );
        assert_eq!(response["ok"], true, "{response}");
        response["data"].clone()
    }

    fn apply(&self, preview: &Value, message: Option<&str>) -> Value {
        let selected = preview["selectedCommits"].as_array().unwrap();
        self.request("git.write", json!({
            "operation": preview["operation"],
            "revision": selected.first().map(|commit| &commit["hash"]),
            "revisions": selected.iter().map(|commit| commit["hash"].clone()).collect::<Vec<_>>(),
            "message": message,
            "expectedState": preview["expectedState"],
        }))
    }
}

impl Drop for Repository {
    fn drop(&mut self) {
        if let Err(error) = fs::remove_dir_all(&self.0) {
            eprintln!("Could not clean history integration repository: {error}");
        }
    }
}

#[test]
fn undo_preserves_staged_unstaged_and_untracked_content_and_keeps_recovery() {
    let repo = Repository::new("undo-reviewed");
    let parent = repo.commit("story.txt", "one\n", "one");
    let head = repo.commit("story.txt", "two\n", "two\n\nComplete description");
    fs::write(repo.0.join("story.txt"), "staged\n").unwrap();
    repo.git(&["add", "story.txt"]);
    fs::write(repo.0.join("story.txt"), "unstaged\n").unwrap();
    fs::write(repo.0.join("new.txt"), "untracked\n").unwrap();
    let index = fs::read(repo.0.join(".git/index")).unwrap();
    let preview = repo.preview("undoCommit", &[&head]);
    assert_eq!(preview["allowed"], true, "{preview}");
    assert!(preview["suggestedMessage"]
        .as_str()
        .unwrap()
        .contains("Complete description"));
    let response = repo.apply(&preview, None);
    assert_eq!(
        response["data"]["historyRewrite"]["mutationApplied"], true,
        "{response}"
    );
    assert_eq!(repo.git(&["rev-parse", "HEAD"]), parent);
    assert_eq!(fs::read(repo.0.join(".git/index")).unwrap(), index);
    assert_eq!(
        fs::read_to_string(repo.0.join("story.txt")).unwrap(),
        "unstaged\n"
    );
    assert_eq!(
        fs::read_to_string(repo.0.join("new.txt")).unwrap(),
        "untracked\n"
    );
    let recovery = response["data"]["historyRewrite"]["recoveryReference"]
        .as_str()
        .unwrap();
    assert_eq!(repo.git(&["rev-parse", recovery]), head);
    let history = repo.request("git.history", json!({"limit": 20}));
    assert!(history["data"]["commits"]
        .as_array()
        .unwrap()
        .iter()
        .all(|commit| commit["hash"] != head));
}

// Keep independent Git scenarios separately timed: combining five repositories
// in one test exceeds the Windows per-test process budget.
fn assert_history_preview_detects_change(change: &str) {
    // Each mutation preserves HEAD's OID, so a HEAD-only stale guard would miss it.
    let repo = Repository::new(&format!("history-stale-{change}"));
    repo.commit("story.txt", "one\n", "one");
    let head = repo.commit("story.txt", "two\n", "two");
    fs::write(repo.0.join("new.txt"), "initial\n").unwrap();
    let preview = repo.preview("undoCommit", &[&head]);
    assert_eq!(preview["allowed"], true, "{preview}");
    match change {
        "index" => {
            fs::write(repo.0.join("story.txt"), "staged\n").unwrap();
            repo.git(&["add", "story.txt"]);
        }
        "worktree" => fs::write(repo.0.join("story.txt"), "changed\n").unwrap(),
        "untracked" => fs::write(repo.0.join("new.txt"), "changed\n").unwrap(),
        "refs" => {
            repo.git(&["update-ref", "refs/remotes/origin/older", "HEAD^"]);
        }
        "checkout" => {
            repo.git(&["switch", "-qc", "other"]);
        }
        _ => unreachable!(),
    }
    let response = repo.apply(&preview, None);
    assert!(
        response["data"]["operationError"]["message"]
            .as_str()
            .unwrap()
            .contains("stale"),
        "{change}: {response}"
    );
    assert_eq!(repo.git(&["rev-parse", "HEAD"]), head);
    assert!(repo
        .git(&[
            "for-each-ref",
            "--format=%(refname)",
            "refs/lithe/history-recovery"
        ])
        .is_empty());
}

#[test]
fn history_preview_detects_index_changes() {
    assert_history_preview_detects_change("index");
}

#[test]
fn history_preview_detects_worktree_changes() {
    assert_history_preview_detects_change("worktree");
}

#[test]
fn history_preview_detects_untracked_changes() {
    assert_history_preview_detects_change("untracked");
}

#[test]
fn history_preview_detects_refs_changes() {
    assert_history_preview_detects_change("refs");
}

#[test]
fn history_preview_detects_checkout_changes() {
    assert_history_preview_detects_change("checkout");
}

#[test]
fn history_preview_preserves_complete_messages_and_requires_reviewed_execution() {
    let repo = Repository::new("history-full-message");
    let first = repo.commit("one.txt", "one\n", "one\n\nFirst body");
    let second = repo.commit("two.txt", "two\n", "two\n\nSecond body");
    let preview = repo.preview("squashCommits", &[&second, &first]);
    assert_eq!(preview["allowed"], true, "{preview}");
    assert_eq!(preview["selectedCommits"][0]["hash"], first);
    assert_eq!(
        preview["suggestedMessage"],
        "one\n\nFirst body\n\ntwo\n\nSecond body"
    );
    let rejected = repo.request(
        "git.write",
        json!({"operation":"editCommitMessage", "revision":second, "message":"must not write"}),
    );
    assert_eq!(
        rejected["data"]["operationError"]["code"], "invalid_request",
        "{rejected}"
    );
    assert_eq!(repo.git(&["rev-parse", "HEAD"]), second);
    let tree = repo.git(&["rev-parse", "HEAD^{tree}"]);
    let result = repo.apply(&preview, Some("combined\n\nFull replacement body\n"));
    assert_eq!(
        result["data"]["historyRewrite"]["mutationApplied"], true,
        "{result}"
    );
    assert_eq!(repo.git(&["rev-parse", "HEAD^{tree}"]), tree);
    assert_eq!(
        repo.git(&["log", "-1", "--format=%B"]),
        "combined\n\nFull replacement body"
    );
}

#[test]
fn delete_replay_failure_keeps_original_branch_and_durable_recovery() {
    let repo = Repository::new("drop-replay-failure");
    repo.commit("base.txt", "base\n", "base");
    let target = repo.commit("dependent.txt", "created\n", "create dependency");
    let head = repo.commit("dependent.txt", "modified\n", "modify dependency");
    let index = fs::read(repo.0.join(".git/index")).unwrap();
    let preview = repo.preview("deleteCommit", &[&target]);
    let response = repo.apply(&preview, None);
    assert_eq!(
        response["data"]["historyRewrite"]["mutationApplied"], false,
        "{response}"
    );
    assert_eq!(response["data"]["historyRewrite"]["outcomeKnown"], true);
    assert!(!response["data"]["operationError"].is_null());
    assert_eq!(repo.git(&["rev-parse", "HEAD"]), head);
    assert_eq!(fs::read(repo.0.join(".git/index")).unwrap(), index);
    assert_eq!(
        fs::read_to_string(repo.0.join("dependent.txt")).unwrap(),
        "modified\n"
    );
    let recovery = response["data"]["historyRewrite"]["recoveryReference"]
        .as_str()
        .unwrap();
    assert_eq!(repo.git(&["rev-parse", recovery]), head);
    let operation = repo.request("git.operationState", json!({}));
    assert_eq!(operation["data"]["kind"], "");
}

#[test]
fn signed_rewrite_is_blocked_but_undo_can_preserve_the_signed_object() {
    let repo = Repository::new("signed-history-preview");
    let parent = repo.commit("base.txt", "base\n", "base");
    let tree = repo.git(&["rev-parse", "HEAD^{tree}"]);
    // A syntactically signed object is sufficient to protect signature preservation;
    // the test requires no GPG executable, keyring, or network signature service.
    let raw = format!("tree {tree}\nparent {parent}\nauthor Fixture <fixture@example.invalid> 0 +0000\ncommitter Fixture <fixture@example.invalid> 0 +0000\ngpgsig -----BEGIN PGP SIGNATURE-----\n fixture\n -----END PGP SIGNATURE-----\n\nsigned message\n");
    let hashed = repo.request(
        "git.command",
        json!({"arguments":["hash-object","-w","-t","commit","--stdin"],"input":raw}),
    );
    assert_eq!(hashed["data"]["exitCode"], 0, "{hashed}");
    let signed = hashed["data"]["stdout"].as_str().unwrap().trim();
    repo.git(&["update-ref", "refs/heads/main", signed, &parent]);
    let preview = repo.preview("editCommitMessage", &[signed]);
    assert_eq!(preview["allowed"], false);
    assert!(preview["blockers"]
        .as_array()
        .unwrap()
        .iter()
        .any(|blocker| blocker["code"] == "signed_commit"));
    let undo = repo.preview("undoCommit", &[signed]);
    assert_eq!(undo["allowed"], true, "{undo}");
}

#[test]
fn undo_eligibility_distinguishes_head_root_published_and_merge_commits() {
    let repo = Repository::new("undo-eligibility");
    let root = repo.commit("base.txt", "base\n", "root");
    assert_eq!(
        repo.preview("undoCommit", &[&root])["blockers"][0]["code"],
        "root_commit"
    );
    let head = repo.commit("story.txt", "story\n", "next");
    assert!(repo.preview("undoCommit", &[&root])["blockers"]
        .as_array()
        .unwrap()
        .iter()
        .any(|b| b["code"] == "not_head"));
    repo.git(&["update-ref", "refs/remotes/origin/main", &head]);
    assert!(repo.preview("undoCommit", &[&head])["blockers"]
        .as_array()
        .unwrap()
        .iter()
        .any(|b| b["code"] == "published_history"));
    repo.git(&["update-ref", "-d", "refs/remotes/origin/main"]);
    repo.git(&["switch", "-qc", "side", &root]);
    repo.commit("side.txt", "side\n", "side");
    repo.git(&["switch", "-q", "main"]);
    repo.git(&["merge", "--no-ff", "--no-edit", "side"]);
    assert!(repo.preview("undoCommit", &["HEAD"])["blockers"]
        .as_array()
        .unwrap()
        .iter()
        .any(|b| b["code"] == "merge_commit"));
}

#[test]
fn drop_rejects_hidden_index_flags_before_touching_working_files() {
    for flag in ["--assume-unchanged", "--skip-worktree"] {
        let repo = Repository::new("drop-hidden-index");
        repo.commit("story.txt", "base\n", "base");
        let head = repo.commit("story.txt", "committed\n", "changed");
        repo.git(&["update-index", flag, "story.txt"]);
        fs::write(repo.0.join("story.txt"), "hidden local edit\n").unwrap();
        let preview = repo.preview("deleteCommit", &[&head]);
        assert_eq!(preview["allowed"], false, "{preview}");
        assert!(preview["blockers"]
            .as_array()
            .unwrap()
            .iter()
            .any(|blocker| blocker["code"] == "hidden_index_entries"));
        assert_eq!(
            fs::read_to_string(repo.0.join("story.txt")).unwrap(),
            "hidden local edit\n"
        );
        assert_eq!(repo.git(&["rev-parse", "HEAD"]), head);
    }
}

#[test]
fn worktree_modes_keep_existing_branch_identity_and_separate_file_population() {
    let repo = Repository::new("worktree-creation-modes");
    let base = repo.commit("base.txt", "base\n", "base");
    let tip = repo.commit("later.txt", "later\n", "later");
    repo.git(&["branch", "feature/existing", &tip]);
    // The existing branch and a same-named tag intentionally point at different
    // commits: the worktree must attach to the selected branch, not the tag.
    repo.git(&["tag", "feature/existing", &base]);
    let existing = repo.0.join("existing space");
    let created = repo.request("git.write", json!({
        "operation":"createWorktree", "worktreeMode":"existingBranch", "destination":existing,
        "gitReference":{"kind":"local","shortName":"feature/existing","fullName":"refs/heads/feature/existing"}
    }));
    assert_eq!(created["data"]["exitCode"], 0, "{created}");
    assert!(created["data"]["operationError"].is_null(), "{created}");
    assert_eq!(
        repo.git(&["-C", existing.to_str().unwrap(), "symbolic-ref", "HEAD"]),
        "refs/heads/feature/existing"
    );
    assert_eq!(
        repo.git(&["-C", existing.to_str().unwrap(), "rev-parse", "HEAD"]),
        tip
    );
    assert!(existing.join("later.txt").exists());
    let unpopulated = repo.0.join("unpopulated");
    let created = repo.request(
        "git.write",
        json!({
            "operation":"createWorktree", "destination":unpopulated, "name":"feature/unpopulated",
            "noCheckout":true, "checkout":true,
            "gitReference":{"kind":"local","shortName":"main","fullName":"refs/heads/main"}
        }),
    );
    assert_eq!(created["data"]["exitCode"], 0, "{created}");
    assert!(unpopulated.join(".git").exists());
    assert!(created["data"]["operationError"].is_null(), "{created}");
    assert!(!unpopulated.join("base.txt").exists());
    let detached = repo.0.join("detached");
    let created = repo.request("git.write", json!({
        "operation":"createWorktree", "worktreeMode":"detached", "destination":detached, "revision":base
    }));
    assert_eq!(created["data"]["exitCode"], 0, "{created}");
    assert_eq!(
        repo.git(&["-C", detached.to_str().unwrap(), "rev-parse", "HEAD"]),
        base
    );
    assert!(!detached.join("later.txt").exists());
    let listed = repo.request("git.worktrees", json!({}));
    assert!(
        listed["data"]["worktrees"]
            .as_array()
            .unwrap()
            .iter()
            .any(|worktree| {
                worktree["path"].as_str().unwrap().ends_with("detached")
                    && worktree["isDetached"] == true
                    && worktree["branch"].is_null()
            }),
        "{listed}"
    );
    // A typed remote reference requires a configured remote, even when this
    // explicit-OID creation deliberately does not configure an upstream.
    repo.git(&["remote", "add", "origin", "."]);
    repo.git(&["update-ref", "refs/remotes/origin/main", "HEAD"]);
    repo.git(&["config", "branch.autoSetupMerge", "always"]);
    let explicit = repo.request("git.write", json!({
        "operation":"createWorktree", "destination":repo.0.join("explicit-revision"),
        "name":"feature/explicit", "revision":base,
        "gitReference":{"kind":"remote","shortName":"origin/main","fullName":"refs/remotes/origin/main"}
    }));
    assert_eq!(explicit["data"]["exitCode"], 0, "{explicit}");
    assert!(explicit["data"]["operationError"].is_null(), "{explicit}");
    assert_eq!(
        repo.git(&["rev-parse", "refs/heads/feature/explicit"]),
        base
    );
    assert_eq!(
        repo.git(&[
            "for-each-ref",
            "--format=%(upstream)",
            "refs/heads/feature/explicit"
        ]),
        ""
    );
    // Git's normal occupied-branch protection is not bypassed with --force.
    let occupied = repo.request("git.write", json!({
        "operation":"createWorktree", "worktreeMode":"existingBranch", "destination":repo.0.join("occupied"),
        "gitReference":{"kind":"local","shortName":"feature/existing","fullName":"refs/heads/feature/existing"}
    }));
    assert_ne!(occupied["data"]["exitCode"], 0, "{occupied}");
    assert!(!repo.0.join("occupied").exists());
}

#[test]
fn worktree_modes_reject_incompatible_fields_without_creating_directories() {
    let repo = Repository::new("worktree-mode-validation");
    repo.commit("base.txt", "base\n", "base");
    for fields in [
        json!({"worktreeMode":"unknown"}),
        json!({"worktreeMode":"existingBranch","name":"must-not-create","gitReference":{"kind":"local","shortName":"main","fullName":"refs/heads/main"}}),
        json!({"worktreeMode":"detached","name":"must-not-create","revision":"HEAD"}),
        json!({"worktreeMode":"detached"}),
    ] {
        let destination = repo.0.join("not-created");
        let mut payload = fields;
        payload["operation"] = json!("createWorktree");
        payload["destination"] = json!(destination);
        let rejected = repo.request("git.write", payload);
        let error = if rejected["ok"] == true {
            &rejected["data"]["operationError"]
        } else {
            &rejected["error"]
        };
        assert_eq!(error["code"], "invalid_request", "{rejected}");
        assert!(!destination.exists());
    }
}

#[test]
fn native_rebase_excludes_published_root_base_and_preserves_reword_squash_fixup_messages() {
    let repo = Repository::new("native-rebase-messages");
    let base = repo.commit("base", "base\n", "Published base");
    let first = repo.commit("one", "one\n", "First\n\nOriginal body");
    let second = repo.commit("two", "two\n", "Second\n\nSecond body");
    let head = repo.commit("three", "three\n", "Discard fixup message");
    repo.git(&["update-ref", "refs/remotes/origin/main", &base]);
    let preview = repo.request("git.rebasePreview", json!({"revision":base}));
    assert_eq!(preview["data"]["allowed"], true, "{preview}");
    assert_eq!(preview["data"]["base"], base);
    assert_eq!(preview["data"]["commits"].as_array().unwrap().len(), 3);
    assert_eq!(preview["data"]["commits"][0]["hash"], first);
    let message = "新标题 'quoted' $(touch unexpected-file)\n\n完整正文\n";
    let started = repo.request("git.rebaseStart", json!({
        "expectedState":preview["data"]["expectedState"],
        "steps":[{"hash":first,"action":"reword","message":message}, {"hash":second,"action":"squash"}, {"hash":head,"action":"fixup"}]
    }));
    assert_eq!(
        started["data"]["session"]["status"], "completed",
        "{started}"
    );
    assert_eq!(started["data"]["command"]["exitCode"], 0, "{started}");
    let new_message = repo.git(&["log", "-1", "--format=%B"]);
    assert_eq!(
        new_message,
        format!("{}\n\nSecond\n\nSecond body", message.trim_end())
    );
    assert_eq!(
        repo.git(&["rev-list", "--count", &format!("{base}..HEAD")]),
        "1"
    );
    assert_eq!(
        repo.git(&["rev-parse", "HEAD^{tree}"]),
        repo.git(&["rev-parse", &format!("{head}^{{tree}}")])
    );
    assert!(!repo.0.join("unexpected-file").exists());
    assert!(!repo.0.join(".git/rebase-merge").exists());
    let recovery = started["data"]["session"]["recoveryReference"]
        .as_str()
        .unwrap();
    assert_eq!(repo.git(&["rev-parse", recovery]), head);
    let restored = repo.request("git.rebaseSession", json!({}));
    assert_eq!(
        restored["data"]["sessionId"],
        started["data"]["session"]["sessionId"]
    );
    assert_eq!(restored["data"]["status"], "completed");
}

#[test]
fn native_rebase_edit_pause_restores_full_message_and_amend_flows_into_squash_fixup() {
    let repo = Repository::new("native-rebase-edit");
    let base = repo.commit("base", "base\n", "Base");
    let first = repo.commit("one", "one\n", "Original edit\n\nFull edit body");
    let second = repo.commit("two", "two\n", "Second\n\nSecond body");
    let head = repo.commit("three", "three\n", "Fixup body must disappear");
    let preview = repo.request("git.rebasePreview", json!({"revision":base}));
    let started = repo.request("git.rebaseStart", json!({
        "expectedState":preview["data"]["expectedState"],
        "steps":[{"hash":first,"action":"edit"}, {"hash":second,"action":"squash"}, {"hash":head,"action":"fixup"}]
    }));
    assert_eq!(started["data"]["command"]["exitCode"], 0, "{started}");
    assert_eq!(started["data"]["session"]["status"], "edit", "{started}");
    assert_eq!(started["data"]["session"]["canSkip"], false);
    let restored = repo.request("git.rebaseSession", json!({}));
    assert_eq!(
        restored["data"]["currentMessage"],
        "Original edit\n\nFull edit body\n"
    );
    fs::write(repo.0.join("one"), "amended staged content\n").unwrap();
    repo.git(&["add", "one"]);
    let paused_head = repo.git(&["rev-parse", "HEAD"]);
    let paused_index = fs::read(repo.0.join(".git/index")).unwrap();
    let ordinary_continue = repo.request(
        "git.rebaseControl",
        json!({
            "sessionId":restored["data"]["sessionId"], "action":"continue"
        }),
    );
    assert_eq!(ordinary_continue["ok"], false, "{ordinary_continue}");
    assert_eq!(repo.git(&["rev-parse", "HEAD"]), paused_head);
    assert_eq!(fs::read(repo.0.join(".git/index")).unwrap(), paused_index);
    let continued = repo.request(
        "git.rebaseControl",
        json!({
            "sessionId":restored["data"]["sessionId"], "action":"continue",
            "amendMessage":"Amended title\n\nNew complete body\n",
            "expectedHead": paused_head
        }),
    );
    assert_eq!(
        continued["data"]["session"]["status"], "completed",
        "{continued}"
    );
    assert_eq!(
        repo.git(&["log", "-1", "--format=%B"]),
        "Amended title\n\nNew complete body\n\nSecond\n\nSecond body"
    );
    assert_eq!(
        fs::read_to_string(repo.0.join("one")).unwrap(),
        "amended staged content\n"
    );
    assert_eq!(
        repo.git(&[
            "rev-parse",
            continued["data"]["session"]["recoveryReference"]
                .as_str()
                .unwrap()
        ]),
        head
    );
}

#[test]
fn native_rebase_conflict_rejects_external_todo_and_abort_restores_original_history() {
    let repo = Repository::new("native-rebase-conflict");
    let base = repo.commit("base", "base\n", "Base");
    let first = repo.commit("dependent", "one\n", "Create dependency");
    let head = repo.commit("dependent", "two\n", "Modify dependency");
    let preview = repo.request("git.rebasePreview", json!({"revision":base}));
    let started = repo.request(
        "git.rebaseStart",
        json!({
            "expectedState":preview["data"]["expectedState"],
            "steps":[{"hash":first,"action":"drop"}, {"hash":head,"action":"pick"}]
        }),
    );
    assert_eq!(
        started["data"]["session"]["status"], "conflict",
        "{started}"
    );
    assert_eq!(started["data"]["session"]["canContinue"], false);
    assert_eq!(started["data"]["session"]["canAbort"], true);
    let session_id = &started["data"]["session"]["sessionId"];
    fs::write(
        repo.0.join(".git/rebase-merge/git-rebase-todo"),
        "exec touch unexpected-file\n",
    )
    .unwrap();
    let altered = repo.request("git.rebaseSession", json!({}));
    assert_eq!(altered["data"]["canSkip"], false, "{altered}");
    let rejected = repo.request(
        "git.rebaseControl",
        json!({"sessionId":session_id,"action":"skip"}),
    );
    assert_eq!(rejected["ok"], false, "{rejected}");
    assert!(!repo.0.join("unexpected-file").exists());
    let aborted = repo.request(
        "git.rebaseControl",
        json!({"sessionId":session_id,"action":"abort"}),
    );
    assert_eq!(aborted["data"]["session"]["status"], "aborted", "{aborted}");
    assert_eq!(repo.git(&["rev-parse", "HEAD"]), head);
    assert_eq!(
        fs::read_to_string(repo.0.join("dependent")).unwrap(),
        "two\n"
    );
    assert!(!repo.0.join(".git/rebase-merge").exists());
}

#[test]
fn native_rebase_rejects_stale_and_incomplete_plans_before_recovery_or_sequencer_mutation() {
    let repo = Repository::new("native-rebase-stale");
    let base = repo.commit("base", "base\n", "Base");
    let head = repo.commit("one", "one\n", "One");
    let empty = repo.request("git.rebasePreview", json!({"revision":head}));
    assert_eq!(empty["data"]["allowed"], false);
    assert_eq!(empty["data"]["blockers"][0]["code"], "empty_rebase_range");
    let preview = repo.request("git.rebasePreview", json!({"revision":base}));
    let missing = repo.request(
        "git.rebaseStart",
        json!({"expectedState":preview["data"]["expectedState"],"steps":[]}),
    );
    assert_eq!(missing["ok"], false, "{missing}");
    repo.git(&["tag", "changed-after-preview", &base]);
    let stale = repo.request("git.rebaseStart", json!({"expectedState":preview["data"]["expectedState"],"steps":[{"hash":head,"action":"pick"}]}));
    assert_eq!(stale["ok"], false, "{stale}");
    assert_eq!(repo.git(&["rev-parse", "HEAD"]), head);
    assert!(!repo.0.join(".git/rebase-merge").exists());
    assert_eq!(
        repo.git(&[
            "for-each-ref",
            "--format=%(refname)",
            "refs/lithe/history-recovery/"
        ]),
        ""
    );
}

#[test]
fn native_rebase_legacy_continue_restores_editor_and_keeps_newly_empty_commit() {
    let repo = Repository::new("native-rebase-empty");
    let base = repo.commit("same", "base\n", "Base");
    let first = repo.commit("same", "changed\n", "Change content");
    let middle = repo.commit("middle", "middle\n", "Keep middle");
    let head = repo.commit("same", "base\n", "Return to base");
    let preview = repo.request("git.rebasePreview", json!({"revision":base}));
    let started = repo.request("git.rebaseStart", json!({
        "expectedState":preview["data"]["expectedState"],
        "steps":[{"hash":first,"action":"drop"}, {"hash":middle,"action":"edit"}, {"hash":head,"action":"reword","message":"Retain empty change\n\nComplete body\n"}]
    }));
    assert_eq!(started["data"]["session"]["status"], "edit", "{started}");
    let continued = repo.request("git.write", json!({"operation":"operationContinue"}));
    assert_eq!(continued["data"]["exitCode"], 0, "{continued}");
    assert!(continued["data"]["operationError"].is_null(), "{continued}");
    let session = repo.request("git.rebaseSession", json!({}));
    assert_eq!(session["data"]["status"], "completed", "{session}");
    assert_eq!(
        repo.git(&["log", "-1", "--format=%B"]),
        "Retain empty change\n\nComplete body"
    );
    assert_eq!(
        repo.git(&["rev-parse", "HEAD^{tree}"]),
        repo.git(&["rev-parse", "HEAD^1^{tree}"])
    );
    assert_eq!(
        repo.git(&["rev-list", "--count", &format!("{base}..HEAD")]),
        "2"
    );
}

#[test]
fn native_rebase_skip_omits_conflicted_message_from_later_squash() {
    let repo = Repository::new("native-rebase-skip");
    let base = repo.commit("base", "base\n", "Base");
    let prerequisite = repo.commit("dependent", "one\n", "Dropped prerequisite");
    let first = repo.commit("one", "one\n", "Keep first\n\nFirst body");
    let middle = repo.commit("middle", "middle\n", "Keep middle\n\nMiddle body");
    let conflict = repo.commit("dependent", "two\n", "Skip conflict\n\nSkipped body");
    let last = repo.commit("last", "last\n", "Keep last\n\nLast body");
    let preview = repo.request("git.rebasePreview", json!({"revision":base}));
    let started = repo.request("git.rebaseStart", json!({
        "expectedState":preview["data"]["expectedState"],
        "steps":[{"hash":prerequisite,"action":"drop"}, {"hash":first,"action":"pick"}, {"hash":middle,"action":"squash"}, {"hash":conflict,"action":"squash"}, {"hash":last,"action":"squash"}]
    }));
    assert_eq!(
        started["data"]["session"]["status"], "conflict",
        "{started}"
    );
    assert_eq!(started["data"]["session"]["canSkip"], true);
    let skipped = repo.request(
        "git.rebaseControl",
        json!({"sessionId":started["data"]["session"]["sessionId"],"action":"skip"}),
    );
    assert_eq!(
        skipped["data"]["session"]["status"], "completed",
        "{skipped}"
    );
    assert_eq!(
        repo.git(&["log", "-1", "--format=%B"]),
        "Keep first\n\nFirst body\n\nKeep middle\n\nMiddle body\n\nKeep last\n\nLast body"
    );
    assert!(!repo.0.join("dependent").exists());
    assert_eq!(
        repo.git(&["rev-list", "--count", &format!("{base}..HEAD")]),
        "1"
    );
}

#[test]
fn native_rebase_rejects_missing_or_stale_amend_head_without_changing_external_edits() {
    let repo = Repository::new("native-rebase-stale-amend");
    let base = repo.commit("base", "base\n", "Base");
    let first = repo.commit("one", "one\n", "Original message");
    let preview = repo.request("git.rebasePreview", json!({"revision": base}));
    let started = repo.request(
        "git.rebaseStart",
        json!({
            "expectedState": preview["data"]["expectedState"],
            "steps": [{"hash": first, "action": "edit"}]
        }),
    );
    assert_eq!(started["data"]["session"]["status"], "edit", "{started}");
    let session_id = &started["data"]["session"]["sessionId"];
    repo.git(&["commit", "--amend", "-m", "External message"]);
    let amended = repo.git(&["rev-parse", "HEAD"]);
    let index = fs::read(repo.0.join(".git/index")).unwrap();
    for expected_head in [Value::Null, json!(first)] {
        let rejected = repo.request(
            "git.rebaseControl",
            json!({
                "sessionId": session_id, "action": "continue",
                "amendMessage": "Stale editor message", "expectedHead": expected_head
            }),
        );
        assert_eq!(rejected["ok"], false, "{rejected}");
        assert_eq!(repo.git(&["rev-parse", "HEAD"]), amended);
        assert_eq!(repo.git(&["log", "-1", "--format=%B"]), "External message");
        assert_eq!(fs::read(repo.0.join(".git/index")).unwrap(), index);
    }
    let continued = repo.request(
        "git.rebaseControl",
        json!({
            "sessionId": session_id, "action": "continue",
            "amendMessage": "Reviewed current message", "expectedHead": amended
        }),
    );
    assert_eq!(
        continued["data"]["session"]["status"], "completed",
        "{continued}"
    );
    assert_eq!(
        repo.git(&["log", "-1", "--format=%B"]),
        "Reviewed current message"
    );
}

#[test]
fn externally_aborted_rebase_keeps_recovery_but_allows_a_new_reviewed_plan() {
    let repo = Repository::new("native-rebase-external-abort");
    let base = repo.commit("base", "base\n", "Base");
    let first = repo.commit("one", "one\n", "First");
    let preview = repo.request("git.rebasePreview", json!({"revision": base}));
    let started = repo.request(
        "git.rebaseStart",
        json!({
            "expectedState": preview["data"]["expectedState"],
            "steps": [{"hash": first, "action": "edit"}]
        }),
    );
    assert_eq!(started["data"]["session"]["status"], "edit", "{started}");
    repo.git(&["rebase", "--abort"]);
    let old = repo.request("git.rebaseSession", json!({}));
    assert_eq!(old["data"]["status"], "interrupted");
    for flag in ["canContinue", "canSkip", "canAbort"] {
        assert_eq!(old["data"][flag], false);
    }
    let recovery = old["data"]["recoveryReference"].as_str().unwrap();
    assert_eq!(repo.git(&["rev-parse", recovery]), first);
    let next = repo.request("git.rebasePreview", json!({"revision": base}));
    assert_eq!(next["data"]["allowed"], true, "{next}");
    let finished = repo.request(
        "git.rebaseStart",
        json!({
            "expectedState": next["data"]["expectedState"],
            "steps": [{"hash": first, "action": "reword", "message": "New plan"}]
        }),
    );
    assert_eq!(
        finished["data"]["session"]["status"], "completed",
        "{finished}"
    );
    assert_eq!(repo.git(&["log", "-1", "--format=%B"]), "New plan");
}

#[test]
fn native_rebase_rejects_escaped_manifest_overflow_before_replacing_session() {
    let repo = Repository::new("rebase-encoded-overflow");
    let base = repo.commit("story.txt", "base\n", "base");
    let first = repo.commit("story.txt", "first\n", "first");
    let head = repo.commit("story.txt", "last\n", "last");
    let index = fs::read(repo.0.join(".git/index")).unwrap();
    let directory = repo.0.join(".git/lithe-rebase-session");
    fs::create_dir(&directory).unwrap();
    let previous = b"previous diagnostic record";
    fs::write(directory.join("session.json"), previous).unwrap();
    let preview = repo.request("git.rebasePreview", json!({"revision":base}));
    // Both newline and backslash are valid message bytes but double in JSON.
    let message = format!("Title\n{}End", "\n\\".repeat(5 * 1024 * 1024 / 2));
    let result = repo.request("git.rebaseStart", json!({
        "expectedState":preview["data"]["expectedState"],
        "steps":[{"hash":first,"action":"edit"}, {"hash":head,"action":"reword","message":message}]
    }));
    assert_eq!(result["ok"], false);
    assert_eq!(result["error"]["code"], "invalid_request");
    assert!(result["error"]["message"]
        .as_str()
        .unwrap()
        .contains("encoded Git rebase plan"));
    assert!(!repo.0.join(".git/rebase-merge").exists());
    assert_eq!(repo.git(&["rev-parse", "HEAD"]), head);
    assert_eq!(fs::read(repo.0.join(".git/index")).unwrap(), index);
    assert_eq!(
        fs::read_to_string(repo.0.join("story.txt")).unwrap(),
        "last\n"
    );
    assert_eq!(fs::read(directory.join("session.json")).unwrap(), previous);
}

#[test]
fn native_rebase_large_escaped_manifest_remains_readable_through_abort() {
    use crate::git::{
        rebase_control, rebase_session, rebase_start, GitRebaseControlRequest,
        GitRebaseSessionRequest, GitRebaseStartRequest,
    };

    fn bounded<T>(operation: impl FnOnce() -> Result<T, crate::protocol::CoreError>) -> T {
        let _deadline = crate::protocol::cancellation::Scope::begin(None, Some(5_000));
        operation().expect("bounded rebase operation should succeed")
    }

    let repo = Repository::new("rebase-encoded-readable");
    let base = repo.commit("story.txt", "base\n", "base");
    let first = repo.commit("story.txt", "first\n", "first");
    let head = repo.commit("story.txt", "last\n", "last");
    let preview = repo.request("git.rebasePreview", json!({"revision":base}));
    let message = format!("Title\n{}End", "\n\\".repeat(4 * 1024 * 1024 / 2));
    // This integration case protects the on-disk size boundary and native abort.
    // Keep the full escaped payload, but use typed Core responses: serializing
    // and parsing it again through JSON on every inspection adds no coverage of
    // storage and can exhaust the Windows runner's per-test deadline.
    let mut request: GitRebaseStartRequest = serde_json::from_value(json!({
        "root": repo.0,
        "expectedState":preview["data"]["expectedState"],
        "steps":[{"hash":first,"action":"edit"}, {"hash":head,"action":"reword"}]
    }))
    .unwrap();
    request.steps[1].message = Some(message.clone());
    let result = bounded(|| rebase_start(request));
    assert_eq!(result.session.status, "edit");
    assert_eq!(
        result.session.steps[1].message.as_deref(),
        Some(message.as_str())
    );
    let manifest = repo.0.join(".git/lithe-rebase-session/session.json");
    assert!(fs::metadata(&manifest).unwrap().len() > 8 * 1024 * 1024);
    let query = || GitRebaseSessionRequest {
        root: repo.0.to_string_lossy().into_owned(),
    };
    let session = bounded(|| rebase_session(query())).expect("stored edit session");
    assert!(session.can_abort);
    assert_eq!(session.steps[1].message.as_deref(), Some(message.as_str()));
    let aborted = bounded(|| {
        rebase_control(GitRebaseControlRequest {
            root: repo.0.to_string_lossy().into_owned(),
            session_id: session.session_id,
            action: "abort".into(),
            amend_message: None,
            expected_head: None,
        })
    });
    assert_eq!(aborted.session.status, "aborted");
    let restored = bounded(|| rebase_session(query())).expect("stored aborted session");
    assert_eq!(restored.status, "aborted");
    assert_eq!(restored.steps[1].message.as_deref(), Some(message.as_str()));
    assert_eq!(repo.git(&["rev-parse", "HEAD"]), head);
    assert!(!repo.0.join(".git/rebase-merge").exists());
}
