use super::support::temporary_root;
use crate::execute_json;
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};

/// Every Git subprocess runs through Core's operation deadline; Drop also cleans
/// the temporary checkout when an assertion unwinds.
struct PatchRepository(PathBuf, PathBuf);

impl PatchRepository {
    fn new(name: &str) -> Self {
        // Own the checkout's parent too, so traversal assertions never depend
        // on unrelated files in the machine's shared temporary directory.
        let directory = temporary_root(name);
        let repository = Self(directory.join("checkout"), directory);
        fs::create_dir_all(&repository.0).unwrap();
        repository.git(&["init", "-q", "-b", "main"]);
        repository.git(&["config", "user.name", "Patch Test"]);
        repository.git(&["config", "user.email", "patch@example.invalid"]);
        repository.git(&["config", "commit.gpgSign", "false"]);
        repository.git(&["config", "core.autocrlf", "false"]);
        repository.git(&["config", "diff.renames", "true"]);
        repository.write("text.txt", b"first\nbase\n");
        repository.git(&["add", "--all"]);
        repository.git(&["commit", "-qm", "base"]);
        repository
    }

    fn write(&self, path: &str, bytes: &[u8]) {
        fs::write(self.0.join(path), bytes).unwrap();
    }

    fn call(&self, command: &str, mut payload: Value) -> Value {
        payload["root"] = json!(self.0);
        let request = json!({
            "id": format!("{}-{command}", self.1.file_name().unwrap().to_string_lossy()),
            "timeoutMilliseconds": if command == "git.commitMessageContext" { 30000 } else if command.starts_with("git.patch") { 15000 } else { 5000 }, "command": command, "payload": payload,
        });
        serde_json::from_str(&execute_json(&request.to_string())).unwrap()
    }

    fn data(&self, command: &str, payload: Value) -> Value {
        let response = self.call(command, payload);
        assert_eq!(response["ok"], true, "{response}");
        response["data"].clone()
    }

    fn git(&self, arguments: &[&str]) -> String {
        let data = self.data("git.command", json!({"arguments": arguments}));
        assert_eq!(data["exitCode"], 0, "{data}");
        assert!(data["operationError"].is_null(), "{data}");
        data["stdout"].as_str().unwrap().to_string()
    }

    fn export(&self, source: &str) -> Value {
        self.data("git.patchExport", json!({"source": source, "paths": []}))
    }

    fn export_shelf_working_layer(&self) -> Value {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/git/patch-exchange-v1.json"
        ))
        .unwrap();
        self.data(
            "git.patchExport",
            fixture["unstagedWithUntrackedRequest"].clone(),
        )
    }

    fn apply_patch(&self, patch: &str, target: &str, reverse: bool) {
        let index_before = fs::read(self.0.join(".git/index")).unwrap();
        let preview = self.data(
            "git.patchPreview",
            json!({"patch": patch, "target": target, "reverse": reverse}),
        );
        assert_eq!(preview["applicable"], true, "{preview}");
        assert_eq!(fs::read(self.0.join(".git/index")).unwrap(), index_before);
        let applied = self.data(
            "git.patchApply",
            json!({"patch": patch, "target": target, "reverse": reverse, "expectedState": preview["expectedState"]}),
        );
        assert_eq!(applied["exitCode"], 0, "{applied}");
    }
}

#[test]
fn patch_exchange_reverse_roundtrip_preserves_both_versions_and_untracked_bytes() {
    let repository = PatchRepository::new("shelf-reverse");
    repository.write("text.txt", b"first\nstaged\n");
    repository.git(&["add", "text.txt"]);
    repository.write("text.txt", b"first\nworking\n");
    repository.write("新增 space.txt", "内容\r\n没有末尾换行".as_bytes());
    repository.write("binary.bin", &[0, 128, 255, 0]);
    let staged = repository.export("staged")["patch"]
        .as_str()
        .unwrap()
        .to_string();
    let working = repository.export_shelf_working_layer()["patch"]
        .as_str()
        .unwrap()
        .to_string();
    let mut checked_direction = false;
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/git/patch-exchange-v1.json"
    ))
    .unwrap();
    let mut apply = |patch: &str, target: &str, reverse: bool| {
        let index_before = fs::read(repository.0.join(".git/index")).unwrap();
        let mut payload = fixture[if reverse {
            "reversePreviewRequest"
        } else {
            "previewRequest"
        }]
        .clone();
        payload["patch"] = json!(patch);
        payload["target"] = json!(target);
        let preview = repository.data("git.patchPreview", payload);
        assert_eq!(preview["applicable"], true, "{preview}");
        assert_eq!(
            fs::read(repository.0.join(".git/index")).unwrap(),
            index_before,
            "Preview must preserve exact index bytes"
        );
        if !checked_direction {
            checked_direction = true;
            let wrong_direction = repository.call("git.patchApply", json!({"patch":patch,"target":target,"reverse":!reverse,"expectedState":preview["expectedState"]}));
            assert_eq!(wrong_direction["ok"], false, "{wrong_direction}");
        }
        let applied = repository.data("git.patchApply", json!({"patch":patch,"target":target,"reverse":reverse,"expectedState":preview["expectedState"]}));
        assert_eq!(applied["exitCode"], 0, "{applied}");
    };
    apply(&working, "worktree", true);
    apply(&staged, "indexAndWorktree", true);
    assert_eq!(
        fs::read(repository.0.join("text.txt")).unwrap(),
        b"first\nbase\n"
    );
    assert!(!repository.0.join("binary.bin").exists());
    assert!(repository.git(&["status", "--porcelain"]).is_empty());
    apply(&staged, "indexAndWorktree", false);
    apply(&working, "worktree", false);
    assert_eq!(repository.git(&["show", ":text.txt"]), "first\nstaged\n");
    assert_eq!(
        fs::read(repository.0.join("text.txt")).unwrap(),
        b"first\nworking\n"
    );
    assert_eq!(
        fs::read(repository.0.join("新增 space.txt")).unwrap(),
        "内容\r\n没有末尾换行".as_bytes()
    );
    assert_eq!(
        fs::read(repository.0.join("binary.bin")).unwrap(),
        &[0, 128, 255, 0]
    );
}

#[test]
fn shelf_roundtrip_preserves_staged_deletions_with_retained_paths() {
    let repository = PatchRepository::new("shelf-retained-deletions");
    repository.write("unchanged.txt", b"unchanged\n");
    repository.git(&["add", "unchanged.txt"]);
    repository.git(&["commit", "-qm", "second path"]);
    repository.git(&["rm", "--cached", "--", "text.txt", "unchanged.txt"]);
    repository.write("text.txt", b"retained edited file\n");
    let status_before = repository.git(&["status", "--porcelain"]);
    let index_before = fs::read(repository.0.join(".git/index")).unwrap();
    let staged = repository.export("staged");
    let working = repository.export_shelf_working_layer();
    assert_eq!(
        fs::read(repository.0.join(".git/index")).unwrap(),
        index_before
    );
    assert_eq!(working["files"].as_array().unwrap().len(), 2);
    assert!(working["patch"].as_str().unwrap().contains("new file mode"));
    let staged = staged["patch"].as_str().unwrap();
    let working = working["patch"].as_str().unwrap();
    repository.apply_patch(working, "worktree", true);
    repository.apply_patch(staged, "indexAndWorktree", true);
    assert!(repository.git(&["status", "--porcelain"]).is_empty());
    assert_eq!(
        fs::read(repository.0.join("text.txt")).unwrap(),
        b"first\nbase\n"
    );
    repository.apply_patch(staged, "indexAndWorktree", false);
    repository.apply_patch(working, "worktree", false);
    assert_eq!(repository.git(&["status", "--porcelain"]), status_before);
    assert!(repository.git(&["ls-files"]).is_empty());
    assert_eq!(
        fs::read(repository.0.join("text.txt")).unwrap(),
        b"retained edited file\n"
    );
    assert_eq!(
        fs::read(repository.0.join("unchanged.txt")).unwrap(),
        b"unchanged\n"
    );
}

#[test]
fn shelf_roundtrip_preserves_staged_rename_with_recreated_source() {
    let repository = PatchRepository::new("shelf-recreated-rename");
    repository.git(&["mv", "text.txt", "renamed.txt"]);
    repository.write("text.txt", b"first\nbase\n");
    repository.write("renamed.txt", b"first\nworking after rename\n");
    let status_before = repository.git(&["status", "--porcelain"]);
    let index_before = fs::read(repository.0.join(".git/index")).unwrap();
    let staged = repository.export("staged");
    let working = repository.export_shelf_working_layer();
    assert_eq!(
        fs::read(repository.0.join(".git/index")).unwrap(),
        index_before
    );
    assert_eq!(working["files"].as_array().unwrap().len(), 2);
    let staged = staged["patch"].as_str().unwrap();
    let working = working["patch"].as_str().unwrap();
    repository.apply_patch(working, "worktree", true);
    repository.apply_patch(staged, "indexAndWorktree", true);
    assert!(repository.git(&["status", "--porcelain"]).is_empty());
    assert!(!repository.0.join("renamed.txt").exists());
    repository.apply_patch(staged, "indexAndWorktree", false);
    repository.apply_patch(working, "worktree", false);
    assert_eq!(repository.git(&["status", "--porcelain"]), status_before);
    assert_eq!(repository.git(&["show", ":renamed.txt"]), "first\nbase\n");
    assert_eq!(
        fs::read(repository.0.join("text.txt")).unwrap(),
        b"first\nbase\n"
    );
    assert_eq!(
        fs::read(repository.0.join("renamed.txt")).unwrap(),
        b"first\nworking after rename\n"
    );
}

#[test]
fn saved_stash_diff_and_drop_follow_immutable_identity_after_positions_change() {
    let repository = PatchRepository::new("saved-stash-identity");
    repository.write("text.txt", b"first\nsaved\n");
    repository.write("untracked.txt", b"saved untracked\n");
    repository.git(&["stash", "push", "-u", "-m", "first"]);
    let entries = repository.data("git.stashes", json!({}));
    let oid = entries["stashes"][0]["oid"].as_str().unwrap();
    assert_eq!(oid.len(), 40);
    repository.write("text.txt", b"first\nnewer\n");
    repository.git(&["stash", "push", "-m", "newer"]);
    let diff = repository.data("git.diff", json!({"pathspecs":["."], "stashReference":oid}));
    let patch = diff["patch"].as_str().unwrap();
    assert!(patch.contains("+saved"), "{patch}");
    assert!(patch.contains("+saved untracked"), "{patch}");
    assert!(!patch.contains("+newer"));
    let dropped = repository.data(
        "git.write",
        json!({"operation":"stashDrop", "reference":oid}),
    );
    assert_eq!(dropped["exitCode"], 0, "{dropped}");
    let remaining = repository.data("git.stashes", json!({}));
    assert_eq!(remaining["stashes"].as_array().unwrap().len(), 1);
    assert_eq!(remaining["stashes"][0]["message"], "newer");
}

#[test]
fn saved_stash_diff_returns_file_sections_and_core_documents() {
    let repository = PatchRepository::new("saved-stash-sections");
    repository.git(&["config", "diff.noprefix", "true"]);
    repository.git(&["config", "diff.mnemonicprefix", "true"]);
    repository.write("text.txt", b"first\nbase\nthird\nfourth\n");
    repository.git(&["add", "text.txt"]);
    repository.git(&["commit", "-qm", "long base"]);
    repository.git(&["mv", "text.txt", "改名 space.txt"]);
    repository.write(
        "改名 space.txt",
        b"first\nbase\nthird\nfourth\ndiff --git is content\n",
    );
    repository.write("untracked.txt", b"saved untracked\n");
    repository.write("binary.bin", &[0, 255, 128, 0]);
    repository.git(&["stash", "push", "-u", "-m", "sections"]);
    let entries = repository.data("git.stashes", json!({}));
    let oid = entries["stashes"][0]["oid"].as_str().unwrap();
    repository.write("text.txt", b"newer stash\n");
    repository.git(&["stash", "push", "-m", "newer"]);
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/git/saved-stash-v1.json"
    ))
    .unwrap();
    let mut request = fixture["sectionRequest"].clone();
    request["stashReference"] = json!(oid);
    let saved = repository.data("git.diff", request);
    let ordinary = repository.data(
        "git.diff",
        json!({"pathspecs":["."], "includeFileSections":true}),
    );
    assert!(
        ordinary["files"].is_array(),
        "ordinary Git diffs also expose sections"
    );
    let narrowed = repository.call(
        "git.diff",
        json!({
            "pathspecs":["text.txt"], "stashReference":oid, "includeFileSections":true
        }),
    );
    assert_eq!(
        narrowed["ok"], false,
        "per-file mode must not ignore a narrower path selection"
    );
    let files = saved["files"]
        .as_array()
        .expect("Core should return file sections");
    assert_eq!(files.len(), 3, "{saved}");
    assert!(!saved.to_string().contains("newer stash"));
    let rename = files
        .iter()
        .find(|file| file["path"] == "改名 space.txt")
        .unwrap();
    assert_eq!(rename["originalPath"], "text.txt");
    assert_eq!(rename["status"], "R");
    assert!(rename["patch"]
        .as_str()
        .unwrap()
        .contains("+diff --git is content"));
    assert!(rename["rows"]
        .as_array()
        .unwrap()
        .iter()
        .any(|row| row["right"] == "diff --git is content"));
    let binary = files
        .iter()
        .find(|file| file["path"] == "binary.bin")
        .unwrap();
    assert_eq!(binary["status"], "A");
    assert!(binary["patch"]
        .as_str()
        .unwrap()
        .contains("GIT binary patch"));
    assert_eq!(
        files
            .iter()
            .filter(|file| file["path"] == "untracked.txt")
            .count(),
        1
    );
    assert_eq!(
        saved["patch"], "",
        "Per-file mode must not duplicate the whole patch"
    );
}

#[test]
fn structured_patch_and_git_diff_preserve_file_identity_and_writable_hunks() {
    let repository = PatchRepository::new("structured-patch");
    repository.write("text.txt", b"first\r\nchanged");
    repository.write("新 文件.txt", "untracked\n".as_bytes());
    repository.write("binary.bin", &[0, 128, 255, 0]);
    let patch = repository.export("workingTree")["patch"]
        .as_str()
        .unwrap()
        .to_owned();
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/git/parsed-diff-v1.json"
    ))
    .unwrap();
    let mut request = fixture["parseRequest"].clone();
    request["patch"] = json!(patch);
    let parsed = repository.data("git.parsePatch", request);
    let files = parsed["files"].as_array().expect("parsed file sections");
    assert_eq!(files.len(), 3, "{parsed}");
    let text = files
        .iter()
        .find(|file| file["path"] == "text.txt")
        .unwrap();
    assert_eq!(text["hasLossyLineEndings"], true);
    assert_eq!(text["lines"], fixture["expectedTextLines"]);
    assert!(text["hunks"][0]["patch"]
        .as_str()
        .unwrap()
        .contains("\\ No newline at end of file"));
    assert!(text["hunks"][0]["patch"]
        .as_str()
        .unwrap()
        .contains("+first\r\n"));
    let binary = files
        .iter()
        .find(|file| file["path"] == "binary.bin")
        .unwrap();
    assert_eq!(binary["isBinary"], true);
    assert_eq!(binary["status"], "A");
    assert!(files.iter().any(|file| file["path"] == "新 文件.txt"));
    repository.git(&["add", "--all"]);
    let diff = repository.data("git.diff", fixture["sectionRequest"].clone());
    assert_eq!(diff["files"].as_array().unwrap().len(), 3);
    let compact = repository.data(
        "git.diff",
        json!({"pathspecs":["."], "staged":true, "includeFileSections":true, "omitFilePatch":true}),
    );
    assert_eq!(compact["files"][0]["patch"], "");
    let text = compact["files"]
        .as_array()
        .unwrap()
        .iter()
        .find(|file| file["path"] == "text.txt")
        .unwrap();
    assert!(!text["hunks"][0]["patch"].as_str().unwrap().is_empty());
    assert_eq!(
        diff["patch"], "",
        "structured mode must not duplicate the full patch"
    );
    assert_eq!(
        repository.data("git.parsePatch", json!({"patch":""}))["files"],
        json!([])
    );
}

#[test]
fn structured_git_diff_marks_invalid_utf8_without_unsafe_write_material() {
    let repository = PatchRepository::new("structured-lossy");
    repository.write(
        "text.txt",
        &[b'f', b'i', b'r', b's', b't', b'\n', 0xff, b'\n'],
    );
    let diff = repository.data(
        "git.diff",
        json!({"pathspecs":["text.txt"], "includeFileSections":true}),
    );
    assert_eq!(diff["hasDecodingLoss"], true, "{diff}");
    assert_eq!(diff["files"][0]["hasLossyLineEndings"], true);
    assert!(diff["files"][0]["patch"]
        .as_str()
        .unwrap()
        .contains('\u{fffd}'));
}

#[test]
fn structured_untracked_snapshot_and_exact_hunk_writes_use_real_git() {
    let repository = PatchRepository::new("structured-untracked-hunk");
    repository.git(&["config", "diff.noprefix", "true"]);
    repository.write("new space.txt", b"new\r\nlast");
    let untracked = repository.data(
        "git.diff",
        json!({"pathspecs":["new space.txt"], "untracked":true, "includeFileSections":true}),
    );
    assert_eq!(
        untracked["files"][0]["path"], "new space.txt",
        "{untracked}"
    );
    assert_eq!(untracked["files"][0]["status"], "A", "{untracked}");
    repository.write("text.txt", b"first\r\nchanged");
    let snapshot = repository.data(
        "git.diff",
        json!({"pathspecs":["."], "worktreeSnapshot":true, "includeFileSections":true}),
    );
    assert_eq!(snapshot["files"].as_array().unwrap().len(), 2, "{snapshot}");
    let diff = repository.data(
        "git.diff",
        json!({"pathspecs":["text.txt"], "includeFileSections":true}),
    );
    let patch = diff["files"][0]["hunks"][0]["patch"].as_str().unwrap();
    let applied = repository.data("git.apply", json!({"patch":patch, "mode":"stage"}));
    assert_eq!(applied["exitCode"], 0, "{applied}");
    assert_eq!(
        repository.git(&["show", ":text.txt"]).as_bytes(),
        b"first\r\nchanged"
    );
    let reverted = repository.data("git.apply", json!({"patch":patch, "mode":"unstage"}));
    assert_eq!(reverted["exitCode"], 0, "{reverted}");
    assert_eq!(
        repository.git(&["show", ":text.txt"]).as_bytes(),
        b"first\nbase\n"
    );
}

#[test]
fn structured_diff_keeps_git_rename_identity_and_visible_cr_changes() {
    let repository = PatchRepository::new("structured-rename");
    repository.git(&["mv", "text.txt", "改名.txt"]);
    let renamed = repository.data(
        "git.diff",
        json!({"pathspecs":["."], "staged":true, "includeFileSections":true}),
    );
    assert_eq!(renamed["files"][0]["path"], "改名.txt", "{renamed}");
    assert_eq!(renamed["files"][0]["originalPath"], "text.txt");
    assert_eq!(renamed["files"][0]["status"], "R");
    repository.git(&["commit", "-qm", "rename"]);
    repository.write("改名.txt", b"first\r\nbase\n");
    let modified = repository.data(
        "git.diff",
        json!({"pathspecs":["改名.txt"], "includeFileSections":true}),
    );
    let rows = modified["files"][0]["rows"].as_array().unwrap();
    assert!(
        rows.iter().any(|row| row["isInvisibleChange"] == true),
        "{modified}"
    );
}

#[test]
fn rename_hunk_unstage_preserves_rename_and_other_staged_changes() {
    assert_rename_hunk_unstage("new name 中文.txt");
}

// Windows filesystems do not allow control characters in a file name.
#[cfg(not(windows))]
#[test]
fn rename_hunk_unstage_preserves_tab_in_file_name() {
    assert_rename_hunk_unstage("new name\t中文.txt");
}

fn assert_rename_hunk_unstage(renamed: &str) {
    let repository = PatchRepository::new("rename-content-hunks");
    let original: Vec<String> = (0..100).map(|line| format!("line {line:03}\n")).collect();
    repository.write("text.txt", original.concat().as_bytes());
    repository.git(&["add", "text.txt"]);
    repository.git(&["commit", "-qm", "long file"]);
    repository.git(&["mv", "text.txt", renamed]);
    let mut changed = original.clone();
    changed[5] = "first changed\r\n".into();
    changed[90] = "second changed\n".into();
    repository.write(renamed, changed.concat().as_bytes());
    repository.git(&["add", "--all"]);
    let diff = repository.data(
        "git.diff",
        json!({"pathspecs":["."], "staged":true, "contextLines":3, "includeFileSections":true}),
    );
    let file = &diff["files"][0];
    assert_eq!(file["status"], "R", "{diff}");
    assert_eq!(file["hunks"].as_array().unwrap().len(), 2);
    let patch = file["hunks"][0]["contentPatch"]
        .as_str()
        .expect("content-only patch");
    let applied = repository.data("git.apply", json!({"patch":patch, "mode":"unstage"}));
    assert_eq!(applied["exitCode"], 0, "{applied}");
    let status = repository.git(&["diff", "--cached", "--name-status"]);
    assert!(status.starts_with("R"), "{status}");
    let staged = repository.git(&["show", &format!(":{renamed}")]);
    assert!(staged.contains("line 005\n"));
    assert!(staged.contains("second changed\n"));
    assert_eq!(
        fs::read(repository.0.join(renamed)).unwrap(),
        changed.concat().as_bytes()
    );
}

impl Drop for PatchRepository {
    fn drop(&mut self) {
        if let Err(error) = fs::remove_dir_all(&self.1) {
            eprintln!("Could not clean the patch test checkout: {error}");
        }
    }
}

#[test]
fn patch_exchange_snapshot_roundtrip_preserves_index_and_binary_files() {
    let repository = PatchRepository::new("patch-exchange-roundtrip");
    repository.write("text.txt", b"first\nstaged\n");
    repository.git(&["add", "text.txt"]);
    repository.write("text.txt", b"first\nfinal\n");
    repository.write("new space.txt", "新增\r\n没有末尾换行".as_bytes());
    repository.write("image.bin", &[0, 1, 2, 255, 0, 128]);
    let original_index = fs::read(repository.0.join(".git/index")).unwrap();
    // Explicit color and prefix configuration must not turn an exchange patch
    // into display output that Git cannot import.
    repository.git(&["config", "color.ui", "always"]);
    repository.git(&["config", "diff.noprefix", "true"]);
    let exported = repository.export("workingTree");
    let patch = exported["patch"].as_str().unwrap();
    assert_eq!(exported["files"].as_array().unwrap().len(), 3);
    assert!(patch.contains("GIT binary patch"));
    assert!(!patch.contains("\u{1b}["));
    assert_eq!(
        fs::read(repository.0.join(".git/index")).unwrap(),
        original_index
    );
    assert_eq!(
        fs::read(repository.0.join("text.txt")).unwrap(),
        b"first\nfinal\n"
    );

    repository.git(&["reset", "--hard", "HEAD"]);
    fs::remove_file(repository.0.join("new space.txt")).unwrap();
    fs::remove_file(repository.0.join("image.bin")).unwrap();
    let clean_index = fs::read(repository.0.join(".git/index")).unwrap();
    let preview = repository.data(
        "git.patchPreview",
        json!({"patch": patch, "target": "worktree"}),
    );
    assert_eq!(preview["applicable"], true, "{preview}");
    assert_eq!(
        fs::read(repository.0.join("text.txt")).unwrap(),
        b"first\nbase\n"
    );
    let applied = repository.data(
        "git.patchApply",
        json!({
            "patch": patch, "target": "worktree", "expectedState": preview["expectedState"],
        }),
    );
    assert_eq!(applied["exitCode"], 0, "{applied}");
    assert_eq!(
        fs::read(repository.0.join("text.txt")).unwrap(),
        b"first\nfinal\n"
    );
    assert_eq!(
        fs::read(repository.0.join("image.bin")).unwrap(),
        [0, 1, 2, 255, 0, 128]
    );
    assert_eq!(
        fs::read(repository.0.join("new space.txt")).unwrap(),
        "新增\r\n没有末尾换行".as_bytes()
    );
    assert_eq!(
        fs::read(repository.0.join(".git/index")).unwrap(),
        clean_index
    );
}

#[test]
fn patch_exchange_distinguishes_sources_and_commit_direction() {
    let repository = PatchRepository::new("patch-exchange-sources");
    let base = repository.git(&["rev-parse", "HEAD"]).trim().to_string();
    repository.write("text.txt", b"first\nstaged\n");
    repository.git(&["add", "text.txt"]);
    repository.write("text.txt", b"first\nunstaged\n");
    assert!(repository.export("staged")["patch"]
        .as_str()
        .unwrap()
        .contains("+staged"));
    assert!(repository.export("unstaged")["patch"]
        .as_str()
        .unwrap()
        .contains("-staged"));
    assert!(repository.export("workingTree")["patch"]
        .as_str()
        .unwrap()
        .contains("-base"));
    repository.git(&["commit", "-qm", "second"]);
    let target = repository.git(&["rev-parse", "HEAD"]).trim().to_string();
    let forward = repository.data(
        "git.patchExport",
        json!({
            "source": "commits", "baseRevision": base, "targetRevision": target,
        }),
    );
    let reverse = repository.data(
        "git.patchExport",
        json!({
            "source": "commits", "baseRevision": target, "targetRevision": base,
        }),
    );
    assert!(forward["patch"].as_str().unwrap().contains("+staged"));
    assert!(reverse["patch"].as_str().unwrap().contains("+base"));
}

#[test]
fn patch_exchange_rejects_stale_preview_and_forward_conflicts_without_writing() {
    let repository = PatchRepository::new("patch-exchange-stale");
    repository.write("text.txt", b"first\npatched\n");
    let exported = repository.export("workingTree");
    let patch = exported["patch"].as_str().unwrap();
    repository.git(&["reset", "--hard", "HEAD"]);
    let preview = repository.data(
        "git.patchPreview",
        json!({"patch": patch, "target": "worktree"}),
    );
    assert_eq!(preview["applicable"], true);
    repository.write("text.txt", b"first\nconcurrent\n");
    let response = repository.call(
        "git.patchApply",
        json!({
            "patch": patch, "target": "worktree", "expectedState": preview["expectedState"],
        }),
    );
    assert_eq!(response["ok"], false, "{response}");
    assert_eq!(
        fs::read(repository.0.join("text.txt")).unwrap(),
        b"first\nconcurrent\n"
    );
    let conflict = repository.data(
        "git.patchPreview",
        json!({"patch": patch, "target": "worktree"}),
    );
    assert_eq!(conflict["applicable"], false, "{conflict}");
    assert!(conflict["expectedState"].is_null());
}

#[test]
fn patch_exchange_rejects_unsafe_paths_and_lossy_text() {
    let repository = PatchRepository::new("patch-exchange-invalid");
    let patch = "diff --git a/../escape b/../escape\nnew file mode 100644\n--- /dev/null\n+++ b/../escape\n@@ -0,0 +1 @@\n+outside\n";
    let response = repository.call(
        "git.patchPreview",
        json!({"patch": patch, "target": "worktree"}),
    );
    assert_eq!(response["ok"], false, "{response}");
    assert!(!Path::new(&repository.0)
        .parent()
        .unwrap()
        .join("escape")
        .exists());
    repository.write("text.txt", &[b'f', 0xff, b'\n']);
    let response = repository.call("git.patchExport", json!({"source": "workingTree"}));
    assert_eq!(response["ok"], false, "{response}");
    assert!(response["error"]["message"]
        .as_str()
        .unwrap()
        .contains("non-UTF-8"));
}

#[test]
fn patch_exchange_detects_index_flags_and_hidden_destination_edits() {
    let repository = PatchRepository::new("patch-exchange-hidden-edits");
    repository.write("text.txt", b"first\npatched\n");
    let exported = repository.export("workingTree");
    let patch = exported["patch"].as_str().unwrap();
    repository.git(&["reset", "--hard", "HEAD"]);
    let preview = repository.data(
        "git.patchPreview",
        json!({"patch": patch, "target": "worktree"}),
    );
    repository.git(&["update-index", "--assume-unchanged", "text.txt"]);
    let changed_index = repository.call(
        "git.patchApply",
        json!({"patch": patch, "target": "worktree", "expectedState": preview["expectedState"]}),
    );
    assert_eq!(changed_index["ok"], false, "{changed_index}");
    let preview = repository.data(
        "git.patchPreview",
        json!({"patch": patch, "target": "worktree"}),
    );
    assert_eq!(preview["applicable"], true, "{preview}");
    repository.write("text.txt", b"first\nbase\nconcurrent outside hunk\n");
    // Git diff deliberately ignores this edit, but applying an old review must
    // still fail even if Git could relocate its hunk into the changed file.
    assert!(repository.git(&["diff"]).is_empty());
    let changed_file = repository.call(
        "git.patchApply",
        json!({"patch": patch, "target": "worktree", "expectedState": preview["expectedState"]}),
    );
    assert_eq!(changed_file["ok"], false, "{changed_file}");
    assert_eq!(
        fs::read(repository.0.join("text.txt")).unwrap(),
        b"first\nbase\nconcurrent outside hunk\n"
    );
}

#[test]
fn patch_exchange_roundtrips_renames_deletes_and_platform_file_modes() {
    let repository = PatchRepository::new("patch-exchange-file-kinds");
    repository.write("old name.txt", b"rename this file\n");
    repository.write("delete.txt", b"delete this file\n");
    repository.git(&["add", "--all"]);
    repository.git(&["commit", "-qm", "file kinds"]);
    fs::rename(
        repository.0.join("old name.txt"),
        repository.0.join("新 name.txt"),
    )
    .unwrap();
    fs::remove_file(repository.0.join("delete.txt")).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::{symlink, PermissionsExt};
        fs::set_permissions(
            repository.0.join("text.txt"),
            fs::Permissions::from_mode(0o755),
        )
        .unwrap();
        symlink("text.txt", repository.0.join("link.txt")).unwrap();
    }
    let exported = repository.export("workingTree");
    let patch = exported["patch"].as_str().unwrap();
    assert!(patch.contains("deleted file mode"));
    let renamed = exported["files"]
        .as_array()
        .unwrap()
        .iter()
        .find(|file| file["path"] == "新 name.txt")
        .unwrap();
    assert_eq!(renamed["originalPath"], "old name.txt");
    let selected = repository.data(
        "git.patchExport",
        json!({
            "source": "workingTree", "paths": [renamed["path"], renamed["originalPath"]],
        }),
    );
    assert_eq!(selected["files"].as_array().unwrap().len(), 1);
    assert_eq!(selected["files"][0]["originalPath"], "old name.txt");
    repository.git(&["reset", "--hard", "HEAD"]);
    fs::remove_file(repository.0.join("新 name.txt")).unwrap();
    #[cfg(unix)]
    fs::remove_file(repository.0.join("link.txt")).unwrap();
    let preview = repository.data(
        "git.patchPreview",
        json!({"patch": patch, "target": "indexAndWorktree"}),
    );
    assert_eq!(preview["applicable"], true, "{preview}");
    let result = repository.data("git.patchApply", json!({"patch": patch, "target": "indexAndWorktree", "expectedState": preview["expectedState"]}));
    assert_eq!(result["exitCode"], 0, "{result}");
    assert!(!repository.0.join("old name.txt").exists());
    assert!(!repository.0.join("delete.txt").exists());
    assert_eq!(
        fs::read(repository.0.join("新 name.txt")).unwrap(),
        b"rename this file\n"
    );
    assert!(repository.git(&["diff"]).is_empty());
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_ne!(
            fs::metadata(repository.0.join("text.txt"))
                .unwrap()
                .permissions()
                .mode()
                & 0o111,
            0
        );
        assert_eq!(
            fs::read_link(repository.0.join("link.txt")).unwrap(),
            Path::new("text.txt")
        );
    }
}

#[test]
fn patch_metadata_allows_selecting_utf8_files_without_decoding_unrelated_contents() {
    let repository = PatchRepository::new("patch-metadata-encoding");
    repository.write("legacy.txt", b"legacy\xff\n");
    repository.write("text.txt", b"valid change\n");
    repository.git(&["add", "legacy.txt"]);
    let index = fs::read(repository.0.join(".git/index")).unwrap();
    let metadata = repository.data(
        "git.patchExport",
        json!({"source": "workingTree", "metadataOnly": true}),
    );
    assert_eq!(metadata["patch"], "");
    assert_eq!(metadata["byteLength"], 0);
    assert_eq!(metadata["files"].as_array().unwrap().len(), 2);
    assert_eq!(
        repository.call("git.patchExport", json!({"source": "workingTree"}))["ok"],
        false
    );
    let selected = repository.data(
        "git.patchExport",
        json!({"source": "workingTree", "paths": ["text.txt"]}),
    );
    assert!(selected["patch"]
        .as_str()
        .unwrap()
        .contains("+valid change"));
    assert_eq!(fs::read(repository.0.join(".git/index")).unwrap(), index);
}

#[test]
fn patch_metadata_keeps_rename_paths_and_index_only_changes() {
    let repository = PatchRepository::new("patch-metadata-paths");
    repository.git(&["mv", "text.txt", "renamed space.txt"]);
    repository.write("index-only.txt", b"staged content\n");
    repository.git(&["add", "index-only.txt"]);
    fs::remove_file(repository.0.join("index-only.txt")).unwrap();
    let metadata = repository.data(
        "git.patchExport",
        json!({"source": "staged", "metadataOnly": true}),
    );
    let files = metadata["files"].as_array().unwrap();
    assert_eq!(files.len(), 2);
    assert_eq!(files[0]["path"], "index-only.txt");
    assert_eq!(files[1]["path"], "renamed space.txt");
    assert_eq!(files[1]["originalPath"], "text.txt");
    assert_eq!(metadata["patch"], "");
}

#[test]
fn patch_metadata_can_list_an_oversized_export_before_selecting_a_small_subset() {
    let repository = PatchRepository::new("patch-metadata-size");
    repository.write("large.txt", &vec![b'x'; 32 * 1024 * 1024 + 1]);
    repository.write("text.txt", b"small change\n");
    let metadata = repository.data(
        "git.patchExport",
        json!({"source": "workingTree", "metadataOnly": true}),
    );
    assert_eq!(metadata["files"].as_array().unwrap().len(), 2);
    assert_eq!(metadata["patch"], "");
    let selected = repository.data(
        "git.patchExport",
        json!({"source": "workingTree", "paths": ["text.txt"]}),
    );
    assert!(selected["patch"]
        .as_str()
        .unwrap()
        .contains("+small change"));
}

#[test]
fn saved_patch_metadata_is_read_only_during_merge_and_never_authorizes_apply() {
    let repository = PatchRepository::new("saved-patch-metadata");
    repository.write("text.txt", b"first\nsaved\n");
    repository.write("new file.txt", b"untracked\n");
    repository.git(&["stash", "push", "--include-untracked", "-m", "saved"]);
    let patch = repository.git(&[
        "stash",
        "show",
        "--include-untracked",
        "--patch",
        "--binary",
        "stash@{0}",
    ]);
    let head = repository.git(&["rev-parse", "HEAD"]);
    fs::write(repository.0.join(".git/MERGE_HEAD"), head).unwrap();
    let index = fs::read(repository.0.join(".git/index")).unwrap();
    let before = fs::read(repository.0.join("text.txt")).unwrap();
    let result = repository.data(
        "git.patchPreview",
        json!({
            "patch": patch, "target": "worktree", "metadataOnly": true
        }),
    );
    assert_eq!(result["files"].as_array().unwrap().len(), 2);
    assert!(result["files"]
        .as_array()
        .unwrap()
        .iter()
        .any(|f| f["path"] == "new file.txt"));
    assert_eq!(result["applicable"], false);
    assert!(result["expectedState"].is_null());
    assert_eq!(fs::read(repository.0.join(".git/index")).unwrap(), index);
    assert_eq!(fs::read(repository.0.join("text.txt")).unwrap(), before);
    assert!(!repository.0.join("new file.txt").exists());
    let normal = repository.call(
        "git.patchPreview",
        json!({"patch": patch, "target": "worktree"}),
    );
    assert_eq!(normal["ok"], false);
}

#[test]
fn shelf_clean_keeps_new_edits_after_capture_and_retains_both_layers() {
    let repository = PatchRepository::new("shelf-guard-new-edit");
    repository.write("text.txt", b"first\nstaged\n");
    repository.git(&["add", "text.txt"]);
    repository.write("text.txt", b"first\nworking\n");
    let snapshot = repository.data("git.shelf", json!({"action":"capture"}));
    repository.write("text.txt", b"first\nnew edit after saving\n");
    let clean = repository.call(
        "git.shelf",
        json!({"action":"clean", "layer":"working", "snapshot":snapshot}),
    );
    assert_eq!(clean["ok"], false, "{clean}");
    assert_eq!(
        fs::read(repository.0.join("text.txt")).unwrap(),
        b"first\nnew edit after saving\n"
    );
    assert_eq!(repository.git(&["show", ":text.txt"]), "first\nstaged\n");
}

#[test]
fn shelf_clean_and_retry_restore_preserve_staged_working_and_untracked() {
    let repository = PatchRepository::new("shelf-step-roundtrip");
    repository.write("text.txt", b"first\nstaged\n");
    repository.git(&["add", "text.txt"]);
    repository.write("text.txt", b"first\nworking\n");
    repository.write("new.txt", b"new content\n");
    let index_before_capture = fs::read(repository.0.join(".git/index")).unwrap();
    let snapshot = repository.data("git.shelf", json!({"action":"capture"}));
    assert_eq!(snapshot["paths"], json!(["new.txt", "text.txt"]));
    assert_eq!(
        fs::read(repository.0.join(".git/index")).unwrap(),
        index_before_capture,
        "capture must not refresh the real index"
    );
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/git/shelf-v1.json"
    ))
    .unwrap();
    assert_eq!(
        repository.data("git.shelf", json!({"action":"plan", "phase":"clean"})),
        fixture["cleanPlan"]
    );
    assert_eq!(
        repository.data("git.shelf", json!({"action":"plan", "phase":"restore"})),
        fixture["restorePlan"]
    );
    for layer in ["working", "staged"] {
        let result = repository.call(
            "git.shelf",
            json!({"action":"clean", "layer":layer, "snapshot":snapshot}),
        );
        assert_eq!(result["ok"], true, "clean {layer}: {result}");
        let before = fs::read(repository.0.join(".git/index")).unwrap();
        repository.data("git.shelf", json!({"action":"capture"}));
        assert_eq!(
            fs::read(repository.0.join(".git/index")).unwrap(),
            before,
            "capture after {layer} changed index"
        );
    }
    assert!(repository.git(&["status", "--porcelain"]).is_empty());
    repository.data(
        "git.shelf",
        json!({"action":"restore", "layer":"staged", "snapshot":snapshot}),
    );
    // A retry must recognise the restored index and continue with the worktree layer.
    repository.data(
        "git.shelf",
        json!({"action":"restore", "layer":"staged", "snapshot":snapshot}),
    );
    repository.data(
        "git.shelf",
        json!({"action":"restore", "layer":"working", "snapshot":snapshot}),
    );
    assert_eq!(repository.git(&["show", ":text.txt"]), "first\nstaged\n");
    assert_eq!(
        fs::read(repository.0.join("text.txt")).unwrap(),
        b"first\nworking\n"
    );
    assert_eq!(
        fs::read(repository.0.join("new.txt")).unwrap(),
        b"new content\n"
    );
    // Retry after a storage deletion failure must also recognise both layers.
    for layer in ["staged", "working"] {
        repository.data(
            "git.shelf",
            json!({"action":"restore", "layer":layer, "snapshot":snapshot}),
        );
    }
}

#[test]
fn shelf_staged_clean_refuses_new_worktree_edit_between_layers() {
    let repository = PatchRepository::new("shelf-edit-between-layers");
    repository.write("text.txt", b"first\nstaged\n");
    repository.git(&["add", "text.txt"]);
    repository.write("text.txt", b"first\nworking\n");
    let snapshot = repository.data("git.shelf", json!({"action":"capture"}));
    repository.data(
        "git.shelf",
        json!({"action":"clean", "layer":"working", "snapshot":snapshot}),
    );
    repository.write("late.txt", b"newly created\n");
    let clean = repository.call(
        "git.shelf",
        json!({"action":"clean", "layer":"staged", "snapshot":snapshot}),
    );
    assert_eq!(clean["ok"], false, "{clean}");
    assert_eq!(repository.git(&["show", ":text.txt"]), "first\nstaged\n");
    assert_eq!(
        fs::read(repository.0.join("late.txt")).unwrap(),
        b"newly created\n"
    );
}

#[test]
fn shelf_restore_conflict_preserves_worktree_and_allows_retry_after_resolution() {
    let repository = PatchRepository::new("shelf-retry-conflict");
    repository.write("text.txt", b"first\nstaged\n");
    repository.git(&["add", "text.txt"]);
    repository.write("text.txt", b"first\nworking\n");
    let snapshot = repository.data("git.shelf", json!({"action":"capture"}));
    for layer in ["working", "staged"] {
        repository.data(
            "git.shelf",
            json!({"action":"clean", "layer":layer, "snapshot":snapshot}),
        );
    }
    repository.data(
        "git.shelf",
        json!({"action":"restore", "layer":"staged", "snapshot":snapshot}),
    );
    repository.write("text.txt", b"first\nconflicting edit\n");
    let result = repository.call(
        "git.shelf",
        json!({"action":"restore", "layer":"working", "snapshot":snapshot}),
    );
    assert_eq!(result["ok"], false, "{result}");
    assert_eq!(
        fs::read(repository.0.join("text.txt")).unwrap(),
        b"first\nconflicting edit\n"
    );
    assert_eq!(repository.git(&["show", ":text.txt"]), "first\nstaged\n");
    repository.write("text.txt", b"first\nstaged\n");
    for layer in ["staged", "working"] {
        repository.data(
            "git.shelf",
            json!({"action":"restore", "layer":layer, "snapshot":snapshot}),
        );
    }
    assert_eq!(
        fs::read(repository.0.join("text.txt")).unwrap(),
        b"first\nworking\n"
    );
}

#[test]
fn commit_message_context_rejects_new_index_content_at_the_same_path() {
    let repository = PatchRepository::new("commit-message-stale-index");
    repository.write("text.txt", b"first\nstaged one\n");
    repository.git(&["add", "text.txt"]);
    let selection =
        json!([{ "root": repository.0, "files": [{"path":"text.txt", "changeKind":"modified"}] }]);
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/git/commit-message-context-v1.json"
    ))
    .unwrap();
    let mut request = fixture["captureRequest"].clone();
    request["repositories"] = selection.clone();
    let captured = repository.data("git.commitMessageContext", request);
    assert!(captured["files"][0]["diff"]
        .as_str()
        .unwrap()
        .contains("staged one"));
    repository.write("text.txt", b"first\nstaged two\n");
    repository.git(&["add", "text.txt"]);
    let checked = repository.data(
        "git.commitMessageContext",
        json!({
            "action":"check", "mode":"staged", "repositories":selection, "token":captured["token"]
        }),
    );
    assert_eq!(checked["isCurrent"], false);
}

#[test]
fn commit_message_context_checks_uncached_worktree_without_changing_index() {
    let repository = PatchRepository::new("commit-message-worktree");
    repository.write("text.txt", b"first\nworking one\n");
    let before = fs::read(repository.0.join(".git/index")).unwrap();
    let selection =
        json!([{ "root":repository.0, "files":[{"path":"text.txt", "changeKind":"modified"}]}]);
    let captured = repository.data("git.commitMessageContext", json!({"action":"capture", "mode":"worktree", "repositories":selection, "maximumDiffCharacters":8000}));
    assert!(captured["files"][0]["diff"]
        .as_str()
        .unwrap()
        .contains("working one"));
    assert_eq!(fs::read(repository.0.join(".git/index")).unwrap(), before);
    let unchanged = repository.data("git.commitMessageContext", json!({"action":"check", "mode":"worktree", "repositories":selection, "token":captured["token"]}));
    assert_eq!(unchanged["isCurrent"], true);
    assert_eq!(fs::read(repository.0.join(".git/index")).unwrap(), before);
    repository.write("text.txt", b"first\nworking two\n");
    let checked = repository.data("git.commitMessageContext", json!({"action":"check", "mode":"worktree", "repositories":selection, "token":captured["token"]}));
    assert_eq!(checked["isCurrent"], false);
    assert_eq!(fs::read(repository.0.join(".git/index")).unwrap(), before);
}

#[test]
fn commit_message_context_does_not_accept_partial_or_sensitive_evidence() {
    let repository = PatchRepository::new("commit-message-incomplete");
    repository.write("text.txt", b"first\nstaged\n");
    repository.git(&["add", "text.txt"]);
    let partial = repository.call("git.commitMessageContext", json!({"action":"capture", "mode":"staged", "maximumDiffCharacters":8000,
        "repositories":[{"root":repository.0,"files":[{"path":"text.txt","changeKind":"modified"},{"path":"missing.txt","changeKind":"modified"}]}]}));
    assert_eq!(partial["ok"], false, "{partial}");
    let sensitive = repository.call("git.commitMessageContext", json!({"action":"capture", "mode":"staged", "maximumDiffCharacters":8000,
        "repositories":[{"root":repository.0,"files":[{"path":"text.txt","originalPath":".env","changeKind":"renamed"}]}]}));
    assert_eq!(sensitive["ok"], false, "{sensitive}");
    assert_eq!(sensitive["error"]["message"], "AI_COMMIT_SENSITIVE_FILE");
}

#[test]
fn commit_message_context_token_covers_content_beyond_the_prompt_budget() {
    let repository = PatchRepository::new("commit-message-budget");
    repository.write(
        "text.txt",
        format!("{}old tail\n", "界".repeat(10000)).as_bytes(),
    );
    repository.git(&["add", "text.txt"]);
    let selection =
        json!([{ "root":repository.0, "files":[{"path":"text.txt", "changeKind":"modified"}]}]);
    let captured = repository.data("git.commitMessageContext", json!({"action":"capture", "mode":"staged", "repositories":selection, "maximumDiffCharacters":8000}));
    let file = &captured["files"][0];
    assert_eq!(file["truncated"], true);
    assert_eq!(file["diff"].as_str().unwrap().chars().count(), 8000);
    assert!(file["originalCharacters"].as_u64().unwrap() > 8000);
    repository.write(
        "text.txt",
        format!("{}new tail\n", "界".repeat(10000)).as_bytes(),
    );
    repository.git(&["add", "text.txt"]);
    let checked = repository.data("git.commitMessageContext", json!({"action":"check", "mode":"staged", "repositories":selection, "token":captured["token"]}));
    assert_eq!(checked["isCurrent"], false);
}

#[test]
fn commit_message_context_keeps_equal_names_from_different_repositories_distinct() {
    let first = PatchRepository::new("commit-message-multi-a");
    let second = PatchRepository::new("commit-message-multi-b");
    first.write("text.txt", b"first\none\n");
    first.git(&["add", "text.txt"]);
    second.write("text.txt", b"first\ntwo\n");
    second.git(&["add", "text.txt"]);
    let selection = json!([
        {"root":second.0, "files":[{"path":"text.txt","changeKind":"modified"}]},
        {"root":first.0, "files":[{"path":"text.txt","changeKind":"modified"}]}
    ]);
    let captured = first.data("git.commitMessageContext", json!({"action":"capture", "mode":"staged", "repositories":selection, "maximumDiffCharacters":8000}));
    assert_eq!(captured["files"].as_array().unwrap().len(), 2);
    assert_eq!(captured["files"][0]["path"], "repository-1/text.txt");
    assert_eq!(captured["files"][1]["path"], "repository-2/text.txt");
    let checked = first.data("git.commitMessageContext", json!({"action":"check", "mode":"staged", "repositories":selection, "token":captured["token"]}));
    assert_eq!(checked["isCurrent"], true);
}

#[test]
fn commit_message_context_expands_untracked_directories_and_rejects_sensitive_children() {
    let repository = PatchRepository::new("commit-message-directory");
    fs::create_dir(repository.0.join("generated")).unwrap();
    for index in 0..101 {
        repository.write(&format!("generated/{index}.txt"), b"new file\n");
    }
    let selection =
        json!([{ "root":repository.0, "files":[{"path":"generated/", "changeKind":"untracked"}]}]);
    let captured = repository.data("git.commitMessageContext", json!({"action":"capture", "mode":"worktree", "repositories":selection, "maximumDiffCharacters":8000}));
    assert_eq!(captured["files"].as_array().unwrap().len(), 101);
    repository.write("generated/.env", b"secret\n");
    let sensitive = repository.call("git.commitMessageContext", json!({"action":"capture", "mode":"worktree", "repositories":selection, "maximumDiffCharacters":8000}));
    assert_eq!(sensitive["ok"], false, "{sensitive}");
    assert_eq!(sensitive["error"]["message"], "AI_COMMIT_SENSITIVE_FILE");
}

#[test]
fn commit_message_context_ignores_index_stat_refresh_without_content_change() {
    let repository = PatchRepository::new("commit-message-index-stat");
    repository.write("text.txt", b"first\nstaged\n");
    repository.git(&["add", "text.txt"]);
    let selection =
        json!([{ "root":repository.0, "files":[{"path":"text.txt", "changeKind":"modified"}]}]);
    let captured = repository.data("git.commitMessageContext", json!({"action":"capture", "mode":"staged", "repositories":selection, "maximumDiffCharacters":8000}));
    repository.write("text.txt", b"first\nstaged\n");
    repository.git(&["update-index", "--refresh"]);
    let checked = repository.data("git.commitMessageContext", json!({"action":"check", "mode":"staged", "repositories":selection, "token":captured["token"]}));
    assert_eq!(
        checked["isCurrent"], true,
        "index stat refresh must not invalidate unchanged evidence"
    );
}

#[test]
fn commit_message_context_detects_index_flag_changes() {
    let repository = PatchRepository::new("commit-message-index-flags");
    repository.write("text.txt", b"first\nstaged\n");
    repository.git(&["add", "text.txt"]);
    let selection =
        json!([{ "root":repository.0, "files":[{"path":"text.txt", "changeKind":"modified"}]}]);
    let captured = repository.data("git.commitMessageContext", json!({"action":"capture", "mode":"staged", "repositories":selection, "maximumDiffCharacters":8000}));
    repository.git(&["update-index", "--assume-unchanged", "text.txt"]);
    let checked = repository.data("git.commitMessageContext", json!({"action":"check", "mode":"staged", "repositories":selection, "token":captured["token"]}));
    assert_eq!(
        checked["isCurrent"], false,
        "index flags belong to the reviewed state"
    );
}

#[test]
fn commit_message_context_handles_rename_and_binary_without_binary_payload() {
    let repository = PatchRepository::new("commit-message-rename-binary");
    repository.git(&["mv", "text.txt", "new 名称.txt"]);
    repository.write("binary.bin", &[0, 255, 128, 0]);
    repository.git(&["add", "binary.bin"]);
    let selection = json!([{ "root":repository.0, "files":[
        {"path":"new 名称.txt", "originalPath":"text.txt", "changeKind":"renamed"},
        {"path":"binary.bin", "changeKind":"added"}
    ]}]);
    let captured = repository.data("git.commitMessageContext", json!({"action":"capture", "mode":"staged", "repositories":selection, "maximumDiffCharacters":8000}));
    let files = captured["files"].as_array().unwrap();
    let binary = files.iter().find(|f| f["path"] == "binary.bin").unwrap();
    assert_eq!(binary["diff"], "[Binary file; content omitted.]");
    let rename = files.iter().find(|f| f["path"] == "new 名称.txt").unwrap();
    assert_eq!(rename["changeKind"], "renamed");
    assert!(rename["diff"]
        .as_str()
        .unwrap()
        .contains("rename from text.txt"));
}

#[test]
fn commit_message_context_does_not_generate_from_binary_only_evidence() {
    let repository = PatchRepository::new("commit-message-binary-only");
    repository.write("binary.bin", &[0, 255, 128, 0]);
    repository.git(&["add", "binary.bin"]);
    let selection =
        json!([{ "root":repository.0, "files":[{"path":"binary.bin", "changeKind":"added"}]}]);
    let result = repository.call("git.commitMessageContext", json!({"action":"capture", "mode":"staged", "repositories":selection, "maximumDiffCharacters":8000}));
    assert_eq!(result["ok"], false, "{result}");
    assert_eq!(result["error"]["message"], "AI_COMMIT_EMPTY_DIFF");
}

#[test]
fn commit_message_context_rejects_untracked_directory_above_file_limit() {
    let repository = PatchRepository::new("commit-message-directory-limit");
    fs::create_dir(repository.0.join("generated")).unwrap();
    for index in 0..1001 {
        repository.write(&format!("generated/{index}.txt"), b"x\n");
    }
    let selection =
        json!([{ "root":repository.0, "files":[{"path":"generated/", "changeKind":"untracked"}]}]);
    let result = repository.call("git.commitMessageContext", json!({"action":"capture", "mode":"worktree", "repositories":selection, "maximumDiffCharacters":8000}));
    assert_eq!(result["ok"], false, "{result}");
    assert_eq!(result["error"]["message"], "AI_COMMIT_TOO_MANY_FILES");
}

#[test]
fn commit_message_context_preserves_selected_delete_and_add_detected_as_rename() {
    let repository = PatchRepository::new("commit-message-detected-rename");
    fs::rename(
        repository.0.join("text.txt"),
        repository.0.join("renamed.txt"),
    )
    .unwrap();
    let selection = json!([{ "root":repository.0, "files":[
        {"path":"text.txt", "changeKind":"deleted"},
        {"path":"renamed.txt", "changeKind":"untracked"}
    ]}]);
    let captured = repository.data("git.commitMessageContext", json!({"action":"capture", "mode":"worktree", "repositories":selection, "maximumDiffCharacters":8000}));
    let files = captured["files"].as_array().unwrap();
    assert_eq!(files.len(), 1);
    assert_eq!(files[0]["path"], "renamed.txt");
    assert_eq!(files[0]["changeKind"], "renamed");
    assert!(files[0]["diff"]
        .as_str()
        .unwrap()
        .contains("rename from text.txt"));
}

#[test]
fn commit_message_context_rejects_more_than_1000_selected_paths() {
    let repository = PatchRepository::new("commit-message-selection-limit");
    let files: Vec<Value> = (0..1001)
        .map(|index| json!({"path":format!("f{index}.txt"), "changeKind":"modified"}))
        .collect();
    let response = repository.call("git.commitMessageContext", json!({"action":"capture", "mode":"staged", "repositories":[{"root":repository.0, "files":files}], "maximumDiffCharacters":8000}));
    assert_eq!(response["error"]["message"], "AI_COMMIT_TOO_MANY_FILES");
}

#[test]
fn commit_message_context_does_not_include_unselected_rename_source() {
    let repository = PatchRepository::new("commit-message-unselected-rename-source");
    fs::rename(
        repository.0.join("text.txt"),
        repository.0.join("renamed.txt"),
    )
    .unwrap();
    let selection =
        json!([{ "root":repository.0, "files":[{"path":"renamed.txt", "changeKind":"untracked"}]}]);
    let captured = repository.data("git.commitMessageContext", json!({"action":"capture", "mode":"worktree", "repositories":selection, "maximumDiffCharacters":8000}));
    let files = captured["files"].as_array().unwrap();
    assert_eq!(files.len(), 1);
    assert_eq!(files[0]["path"], "renamed.txt");
    assert!(!files[0]["diff"]
        .as_str()
        .unwrap()
        .contains("rename from text.txt"));
    assert!(repository.0.join("renamed.txt").exists());
}

#[test]
fn commit_message_context_invalidates_when_another_staged_file_changes() {
    let repository = PatchRepository::new("commit-message-other-index-change");
    repository.write("text.txt", b"first\nstaged\n");
    repository.git(&["add", "text.txt"]);
    let selection =
        json!([{ "root":repository.0, "files":[{"path":"text.txt", "changeKind":"modified"}]}]);
    let captured = repository.data("git.commitMessageContext", json!({"action":"capture", "mode":"staged", "repositories":selection, "maximumDiffCharacters":8000}));
    repository.write("other.txt", b"other staged change\n");
    repository.git(&["add", "other.txt"]);
    let checked = repository.data("git.commitMessageContext", json!({"action":"check", "mode":"staged", "repositories":selection, "token":captured["token"]}));
    assert_eq!(checked["isCurrent"], false);
}

#[test]
fn commit_message_context_uses_staged_kind_when_worktree_status_differs() {
    let repository = PatchRepository::new("commit-message-staged-kind");
    repository.write("text.txt", b"first\nstaged modification\n");
    repository.git(&["add", "text.txt"]);
    fs::remove_file(repository.0.join("text.txt")).unwrap();
    // The UI sees a worktree deletion, but the index contains a modification.
    let selection =
        json!([{ "root":repository.0, "files":[{"path":"text.txt", "changeKind":"deleted"}]}]);
    let captured = repository.data("git.commitMessageContext", json!({"action":"capture", "mode":"staged", "repositories":selection, "maximumDiffCharacters":8000}));
    assert_eq!(captured["files"][0]["changeKind"], "modified");
    assert!(captured["files"][0]["diff"]
        .as_str()
        .unwrap()
        .contains("staged modification"));
}

#[test]
fn commit_message_context_staged_mode_ignores_unstaged_only_edits() {
    let repository = PatchRepository::new("commit-message-unstaged-only");
    repository.write("text.txt", b"first\nstaged\n");
    repository.git(&["add", "text.txt"]);
    let selection =
        json!([{ "root":repository.0, "files":[{"path":"text.txt", "changeKind":"modified"}]}]);
    let captured = repository.data("git.commitMessageContext", json!({"action":"capture", "mode":"staged", "repositories":selection, "maximumDiffCharacters":8000}));
    repository.write("text.txt", b"first\nunstaged later\n");
    let checked = repository.data("git.commitMessageContext", json!({"action":"check", "mode":"staged", "repositories":selection, "token":captured["token"]}));
    assert_eq!(
        checked["isCurrent"], true,
        "unstaged bytes do not change a staged commit"
    );
}
