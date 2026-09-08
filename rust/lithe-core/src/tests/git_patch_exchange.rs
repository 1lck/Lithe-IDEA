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
            "timeoutMilliseconds": 5000, "command": command, "payload": payload,
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
