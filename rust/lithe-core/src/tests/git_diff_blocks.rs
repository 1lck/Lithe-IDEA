//! Shared fixtures and real-Git round trips for Core-owned diff block writes.

use super::support::temporary_root;
use crate::execute_json;
use crate::git::diff_blocks_fixture as fixture_support;
use serde_json::{json, Value};
use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn fixture() -> Value {
    serde_json::from_str(include_str!(
        "../../../../shared/fixtures/git/diff-blocks-v1.json"
    ))
    .expect("diff block fixture should be JSON")
}

fn side(value: &Value) -> (&str, &str) {
    (
        value["status"].as_str().unwrap(),
        value["patch"].as_str().unwrap(),
    )
}

#[test]
fn diff_blocks_match_the_shared_fixture() {
    for case in fixture()["blockCases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let blocks = fixture_support::plan(
            side(&case["worktree"]),
            case["index"].is_object().then(|| side(&case["index"])),
            case["writable"].as_bool().unwrap_or(true),
            case["rollbackSafe"].as_bool().unwrap_or(true),
        );
        let Some(expected) = case["blocks"].as_array() else {
            assert!(blocks.is_none(), "{name}: {blocks:?}");
            continue;
        };
        let blocks = blocks.unwrap_or_else(|| panic!("{name}: expected blocks"));
        assert_eq!(blocks.len(), expected.len(), "{name}: {blocks:?}");
        for (block, expected) in blocks.iter().zip(expected) {
            // Only the fields a case names are part of its contract.
            for (field, value) in expected.as_object().unwrap() {
                assert_eq!(&block[field], value, "{name}: {field} of {block}");
            }
            if expected.get("wholeFile").is_none() {
                assert!(block.get("wholeFile").is_none(), "{name}: {block}");
            }
        }
    }
}

#[test]
fn complete_file_hunks_match_the_shared_fixture() {
    for case in fixture()["hunkCases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let hunks = fixture_support::hunks(case["patch"].as_str().unwrap())
            .map(|hunks| serde_json::to_value(hunks).unwrap());
        match case["hunks"].as_array() {
            None => assert!(hunks.is_none(), "{name}: {hunks:?}"),
            Some(expected) => assert_eq!(hunks.as_ref(), Some(&json!(expected)), "{name}"),
        }
    }
}

/// A temporary repository with no user configuration; Drop removes it even
/// when an assertion unwinds. Every Git call is a short local command.
struct Repository(PathBuf);

impl Repository {
    fn new(label: &str) -> Self {
        let root = temporary_root(label);
        fs::create_dir_all(&root).unwrap();
        let repository = Self(root);
        repository.git(&["init", "-q"]);
        repository.git(&["config", "user.name", "Diff Blocks"]);
        repository.git(&["config", "user.email", "blocks@example.invalid"]);
        repository.git(&["config", "commit.gpgSign", "false"]);
        repository.git(&["config", "core.autocrlf", "false"]);
        repository
    }

    fn git_output(&self, arguments: &[&str]) -> std::process::Output {
        Command::new("git")
            .args(["-c", "core.hooksPath=", "-c", "core.attributesFile="])
            .args(arguments)
            .current_dir(&self.0)
            .output()
            .expect("git should run")
    }

    fn git(&self, arguments: &[&str]) -> Vec<u8> {
        let output = self.git_output(arguments);
        assert!(
            output.status.success(),
            "git {arguments:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        output.stdout
    }

    fn write(&self, path: &str, bytes: &[u8]) {
        fs::write(self.0.join(path), bytes).unwrap();
    }

    fn read(&self, path: &str) -> Vec<u8> {
        fs::read(self.0.join(path)).unwrap()
    }

    fn commit(&self, path: &str, bytes: &[u8]) {
        self.write(path, bytes);
        self.git(&["add", "--", path]);
        self.git(&["commit", "-qm", "base"]);
    }

    fn index(&self, path: &str) -> Vec<u8> {
        self.git(&["show", &format!(":{path}")])
    }

    fn request(&self, command: &str, payload: Value) -> Value {
        let mut payload = payload;
        payload["root"] = json!(self.0);
        serde_json::from_str(&execute_json(
            &json!({ "id": command, "command": command, "payload": payload }).to_string(),
        ))
        .unwrap()
    }

    fn plan(&self, path: &str) -> Value {
        let response = self.request("git.planDiffBlocks", json!({ "path": path }));
        assert_eq!(response["ok"], true, "{response}");
        response["data"].clone()
    }

    fn apply(&self, path: &str, plan: &Value, block: usize, action: &str) -> Value {
        self.request(
            "git.applyDiffBlock",
            json!({
                "path": path,
                "blockId": plan["blocks"][block]["id"],
                "action": action,
                "token": plan["token"],
            }),
        )
    }
}

impl Drop for Repository {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn applied(response: &Value) {
    assert_eq!(response["ok"], true, "{response}");
    assert_eq!(response["data"]["exitCode"], 0, "{response}");
}

fn failure(response: &Value) -> &str {
    assert_eq!(response["ok"], false, "{response}");
    response["error"]["message"].as_str().unwrap()
}

#[test]
fn planned_blocks_include_exclude_and_roll_back_through_real_git() {
    let repository = Repository::new("diff-blocks-round-trip");
    repository.commit("file.txt", b"a\nb\nc\nd\ne\n");
    repository.write("file.txt", b"a\nnew\nb\nc\nD\ne\n");

    let plan = repository.plan("file.txt");
    assert_eq!(plan["blocks"].as_array().unwrap().len(), 2, "{plan}");
    assert!(plan["worktree"]["files"][0]["patch"]
        .as_str()
        .unwrap()
        .is_empty());
    applied(&repository.apply("file.txt", &plan, 0, "include"));
    assert_eq!(repository.index("file.txt"), b"a\nnew\nb\nc\nd\ne\n");

    let plan = repository.plan("file.txt");
    let checked = |plan: &Value| {
        plan["blocks"]
            .as_array()
            .unwrap()
            .iter()
            .map(|block| block["checked"].as_bool().unwrap())
            .collect::<Vec<_>>()
    };
    assert_eq!(checked(&plan), [true, false]);
    applied(&repository.apply("file.txt", &plan, 1, "include"));
    let plan = repository.plan("file.txt");
    assert_eq!(checked(&plan), [true, true]);
    applied(&repository.apply("file.txt", &plan, 0, "exclude"));
    assert_eq!(repository.index("file.txt"), b"a\nb\nc\nD\ne\n");

    // Rollback restores the index text for the block and leaves the index alone.
    let plan = repository.plan("file.txt");
    assert_eq!(checked(&plan), [false, true]);
    applied(&repository.apply("file.txt", &plan, 0, "rollback"));
    assert_eq!(repository.read("file.txt"), b"a\nb\nc\nD\ne\n");
    assert_eq!(repository.index("file.txt"), b"a\nb\nc\nD\ne\n");
}

#[test]
fn a_block_write_is_refused_when_the_file_changed_after_planning() {
    let repository = Repository::new("diff-blocks-stale");
    repository.commit("file.txt", b"a\nb\nc\n");
    repository.write("file.txt", b"a\nB\nc\n");
    let plan = repository.plan("file.txt");
    repository.write("file.txt", b"a\nB\nc\nlater\n");

    for action in ["include", "rollback"] {
        let response = repository.apply("file.txt", &plan, 0, action);
        assert_eq!(failure(&response), "GIT_DIFF_BLOCK_STALE");
    }
    assert_eq!(repository.index("file.txt"), b"a\nb\nc\n");
    assert_eq!(repository.read("file.txt"), b"a\nB\nc\nlater\n");
}

#[test]
fn lossy_line_endings_round_trip_byte_for_byte() {
    // (label, configuration, committed bytes, edited bytes, bytes after rollback)
    for (label, configure, committed, edited, restored) in [
        (
            "crlf",
            vec![],
            &b"one\r\ntwo\r\nthree\r\n"[..],
            &b"one\r\nTWO\r\nthree\r\n"[..],
            &b"one\r\ntwo\r\nthree\r\n"[..],
        ),
        (
            "crlf-only",
            vec![],
            b"one\ntwo\n",
            b"one\r\ntwo\n",
            b"one\ntwo\n",
        ),
        (
            "no-final-newline",
            vec![],
            b"one\ntwo",
            b"one\nTWO",
            b"one\ntwo",
        ),
        (
            // Git converts the worktree to its clean form and back, so the
            // restored line keeps the worktree's CRLF convention.
            "autocrlf",
            vec![("core.autocrlf", "true")],
            b"one\ntwo\nthree\n",
            b"one\r\nTWO\r\nthree\r\n",
            b"one\r\ntwo\r\nthree\r\n",
        ),
    ] {
        let repository = Repository::new(&format!("diff-blocks-{label}"));
        repository.commit("file.txt", committed);
        for (key, value) in &configure {
            repository.git(&["config", key, value]);
        }
        repository.write("file.txt", edited);
        let index_before = repository.index("file.txt");

        let plan = repository.plan("file.txt");
        let block = &plan["blocks"][0];
        assert_eq!(block["canToggle"], true, "{label}: {plan}");
        assert_eq!(block["canRollback"], true, "{label}: {plan}");
        applied(&repository.apply("file.txt", &plan, 0, "rollback"));
        assert_eq!(repository.read("file.txt"), restored, "{label}");
        assert_eq!(repository.index("file.txt"), index_before, "{label}");

        repository.write("file.txt", edited);
        let plan = repository.plan("file.txt");
        applied(&repository.apply("file.txt", &plan, 0, "include"));
        repository.git(&["commit", "-qm", "block"]);
        let status = repository.git(&["status", "--porcelain"]);
        assert!(
            status.is_empty(),
            "{label}: {}",
            String::from_utf8_lossy(&status)
        );
    }
}

#[test]
fn eol_attribute_rollback_restores_worktree_bytes() {
    let repository = Repository::new("diff-blocks-eol-attribute");
    repository.commit(".gitattributes", b"*.txt text eol=crlf\n");
    repository.write("file.txt", b"one\r\ntwo\r\nthree\r\n");
    repository.git(&["add", "file.txt"]);
    repository.git(&["commit", "-qm", "crlf"]);
    repository.write("file.txt", b"one\r\nTWO\r\nthree\r\n");

    let plan = repository.plan("file.txt");
    applied(&repository.apply("file.txt", &plan, 0, "rollback"));
    assert_eq!(repository.read("file.txt"), b"one\r\ntwo\r\nthree\r\n");
}

#[test]
fn filtered_files_keep_inclusion_but_refuse_hunk_rollback() {
    let repository = Repository::new("diff-blocks-filter");
    repository.git(&["config", "filter.lithe.clean", "cat"]);
    repository.git(&["config", "filter.lithe.smudge", "cat"]);
    repository.commit(".gitattributes", b"*.txt filter=lithe\n");
    repository.commit("file.txt", b"a\nb\nc\n");
    repository.write("file.txt", b"a\nB\nc\n");

    let plan = repository.plan("file.txt");
    assert_eq!(plan["blocks"][0]["canToggle"], true, "{plan}");
    assert_eq!(plan["blocks"][0]["canRollback"], false, "{plan}");
    let response = repository.apply("file.txt", &plan, 0, "rollback");
    assert_eq!(failure(&response), "GIT_HUNK_ROLLBACK_UNSAFE");
    assert_eq!(repository.read("file.txt"), b"a\nB\nc\n");

    // The ordinary hunk discard of other surfaces applies the same rule.
    let diff = repository.request(
        "git.diff",
        json!({ "pathspecs": ["file.txt"], "includeFileSections": true }),
    );
    let patch = diff["data"]["files"][0]["hunks"][0]["patch"].clone();
    let response = repository.request("git.apply", json!({ "patch": patch, "mode": "discard" }));
    assert_eq!(failure(&response), "GIT_HUNK_ROLLBACK_UNSAFE");
    assert_eq!(repository.read("file.txt"), b"a\nB\nc\n");
}

#[test]
fn complete_file_diff_hunks_equal_git_default_hunks_and_stage_alone() {
    let repository = Repository::new("diff-blocks-complete-hunks");
    let before = (1..=40)
        .map(|line| format!("line {line}\n"))
        .collect::<String>();
    let mut after = before.lines().map(str::to_string).collect::<Vec<_>>();
    after[5] = "first".into();
    after[19] = "second\r".into();
    after[33] = "third".into();
    let after = after.join("\n") + "\n";
    repository.commit("file.txt", before.as_bytes());
    repository.write("file.txt", after.as_bytes());

    let response = repository.request(
        "git.diff",
        json!({ "pathspecs": ["file.txt"], "includeFileSections": true,
                "contextLines": 1_073_741_823usize }),
    );
    assert_eq!(response["ok"], true, "{response}");
    let file = &response["data"]["files"][0];
    let hunks = file["hunks"].as_array().unwrap();
    let default =
        String::from_utf8(repository.git(&["diff", "--no-color", "--", "file.txt"])).unwrap();
    // Default hunks carry Git's function-name hint after the range; compare
    // the range and every body byte.
    let default_hunks = default
        .split("\n@@")
        .skip(1)
        .map(|hunk| {
            let (header, body) = hunk.split_once('\n').unwrap();
            let range = &header[..header[1..].find(" @@").unwrap() + 4];
            (format!("@@{range}"), body.to_string())
        })
        .collect::<Vec<_>>();
    assert_eq!(hunks.len(), default_hunks.len(), "{default}");
    for (hunk, (range, expected)) in hunks.iter().zip(&default_hunks) {
        let patch = hunk["patch"].as_str().unwrap();
        let (header, body) = patch[patch.find("\n@@").unwrap() + 1..]
            .split_once('\n')
            .unwrap();
        assert_eq!(header, range);
        assert_eq!(body.trim_end_matches('\n'), expected.trim_end_matches('\n'));
        let lines = &file["lines"].as_array().unwrap()[hunk["lineStart"].as_u64().unwrap() as usize
            ..hunk["lineEnd"].as_u64().unwrap() as usize];
        assert!(lines.iter().all(|line| line["lineType"] != "header"));
    }

    let response = repository.request(
        "git.apply",
        json!({ "patch": hunks[1]["patch"], "mode": "stage" }),
    );
    applied(&response);
    let mut expected = before.lines().map(str::to_string).collect::<Vec<_>>();
    expected[19] = "second\r".into();
    assert_eq!(
        repository.index("file.txt"),
        (expected.join("\n") + "\n").into_bytes()
    );
}

#[test]
fn gutter_changes_stage_original_bytes_and_refuse_moved_lines() {
    let repository = Repository::new("diff-blocks-gutter");
    repository.commit("file.txt", b"one\r\ntwo\r\nthree\r\nfour\r\n");
    repository.write("file.txt", b"ONE\r\ntwo\r\nthree\r\nFOUR\r\n");
    let change = |original: &str, modified: &str, line: usize| {
        json!({
            "path": "file.txt",
            "originalStart": line, "originalEnd": line + 1,
            "modifiedStart": line, "modifiedEnd": line + 1,
            "originalLines": [original], "modifiedLines": [modified],
        })
    };

    let response = repository.request("git.stageGutterChange", change("four", "FOUR", 4));
    applied(&response);
    assert_eq!(
        repository.index("file.txt"),
        b"one\r\ntwo\r\nthree\r\nFOUR\r\n"
    );

    // The editor still shows a line the file no longer has.
    repository.write("file.txt", b"Uno\r\ntwo\r\nthree\r\nFOUR\r\n");
    let response = repository.request("git.stageGutterChange", change("one", "ONE", 1));
    assert_eq!(failure(&response), "GIT_GUTTER_CHANGE_STALE");
    assert_eq!(
        repository.index("file.txt"),
        b"one\r\ntwo\r\nthree\r\nFOUR\r\n"
    );
}

#[test]
fn whole_file_inclusion_is_bound_to_the_planned_token() {
    for case in fixture()["wholeFileWriteCases"].as_array().unwrap() {
        let text = |field: &str| case[field].as_str().unwrap().as_bytes().to_vec();
        let stale = case["staleError"].as_str().unwrap();
        let repository = Repository::new("diff-blocks-file");
        repository.commit("file.txt", &text("head"));
        repository.write("file.txt", &text("worktree"));
        let plan = repository.plan("file.txt");
        let file = |action: &str, token: &Value| {
            repository.request(
                "git.applyDiffBlock",
                json!({ "path": "file.txt", "action": action, "token": token }),
            )
        };

        // The file moved after planning: neither direction writes anything.
        repository.write("file.txt", &text("movedWorktree"));
        for action in case["actions"].as_array().unwrap() {
            assert_eq!(
                failure(&file(action.as_str().unwrap(), &plan["token"])),
                stale
            );
        }
        assert_eq!(repository.index("file.txt"), text("head"));

        let fresh = repository.plan("file.txt");
        applied(&file("includeFile", &fresh["token"]));
        assert_eq!(repository.index("file.txt"), text("indexAfterInclude"));
        // Staging moved the index, so the old token no longer describes it.
        assert_eq!(failure(&file("excludeFile", &fresh["token"])), stale);
        let staged = repository.plan("file.txt");
        applied(&file("excludeFile", &staged["token"]));
        assert_eq!(repository.index("file.txt"), text("indexAfterExclude"));
    }
}
