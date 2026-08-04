mod cancellation;
mod command;
mod error;
mod event;
mod ffi;
mod git;
mod history;
mod java;
mod maven;
mod model;
mod runtime;
mod workspace;

pub use command::{CoreCommand, CoreRequest};
pub use error::{CoreError, ErrorCode};
pub use event::CoreEvent;
pub use model::{CoreResponse, ResponseData};

/// Executes one versioned application command and returns a JSON response.
pub fn execute_json(request: &str) -> String {
    runtime::execute_json(request)
}

#[cfg(test)]
mod tests {
    use super::execute_json;
    use serde_json::Value;
    use std::fs;
    use std::path::PathBuf;
    use std::process::Command;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn fixture() -> Value {
        let fixture_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../shared/fixtures/search/basic.json");
        serde_json::from_str(&fs::read_to_string(fixture_path).expect("fixture should be readable"))
            .expect("fixture should be valid JSON")
    }

    fn temporary_root(label: &str) -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock should be valid")
            .as_nanos();
        std::env::temp_dir().join(format!("lithe-core-{label}-{}-{nonce}", std::process::id()))
    }

    #[test]
    fn ping_exposes_protocol_version() {
        let response: Value = serde_json::from_str(&execute_json(
            r#"{"id":"test-1","command":"core.ping","payload":{}}"#,
        ))
        .expect("ping response should be JSON");

        assert_eq!(response["ok"], true);
        assert_eq!(response["data"]["protocolVersion"], 1);
        assert_eq!(response["data"]["coreVersion"], "0.1.0");
    }

    #[test]
    fn search_matches_shared_fixture_semantics() {
        let fixture = fixture();
        let root = temporary_root("search");
        let _ = fs::remove_dir_all(&root);
        for file in fixture["files"]
            .as_array()
            .expect("files should be an array")
        {
            let path = root.join(file["path"].as_str().expect("fixture path should be text"));
            fs::create_dir_all(path.parent().expect("fixture file should have a parent"))
                .expect("fixture parent should be creatable");
            fs::write(
                path,
                file["content"]
                    .as_str()
                    .expect("fixture content should be text"),
            )
            .expect("fixture file should be writable");
        }

        for case in fixture["cases"]
            .as_array()
            .expect("cases should be an array")
        {
            let request = serde_json::json!({
                "id": "fixture",
                "command": "workspace.search",
                "payload": {
                    "root": root.to_string_lossy(),
                    "query": case["request"]["query"],
                    "caseSensitive": case["request"]["caseSensitive"],
                    "wholeWords": case["request"]["wholeWords"],
                    "regularExpression": case["request"]["regularExpression"],
                    "maxResults": 200
                }
            });
            let response: Value = serde_json::from_str(&execute_json(
                &serde_json::to_string(&request).expect("request should encode"),
            ))
            .expect("search response should be JSON");
            assert_eq!(response["ok"], true, "case {} should succeed", case["name"]);

            let actual = response["data"]["matches"]
                .as_array()
                .expect("matches should be an array");
            let expected = case["expected"]
                .as_array()
                .expect("expected should be an array");
            assert_eq!(actual, expected, "fixture case {} changed", case["name"]);
        }

        let limited_request = serde_json::json!({
            "id": "limited",
            "command": "workspace.search",
            "payload": {
                "root": root,
                "query": "UserService",
                "maxResults": 100,
                "maxFileResults": 0,
                "maxContentResults": 1
            }
        });
        let limited_response: Value = serde_json::from_str(&execute_json(
            &serde_json::to_string(&limited_request).expect("limited request should encode"),
        ))
        .expect("limited response should be JSON");
        assert_eq!(limited_response["ok"], true);
        assert_eq!(
            limited_response["data"]["matches"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert_eq!(limited_response["data"]["matches"][0]["kind"], "content");

        fs::remove_dir_all(root).expect("temporary fixture should be removable");
    }

    #[test]
    fn search_everywhere_and_replacement_preview_are_shared() {
        let root = temporary_root("advanced-search");
        fs::create_dir_all(root.join("src/main/java/com/example"))
            .expect("fixture directory should be creatable");
        let source = "class UserService {\n    void loadUser() {}\n}\n";
        let relative = "src/main/java/com/example/UserService.java";
        fs::write(root.join(relative), source).expect("fixture source should be writable");

        let request = serde_json::json!({
            "id": "everywhere",
            "command": "workspace.searchEverywhere",
            "payload": {
                "root": root,
                "query": "UserService",
                "caseSensitive": true,
                "wholeWords": true,
                "regularExpression": false,
                "maxResults": 200,
                "maxFileResults": 50,
                "maxContentResults": 50,
                "maxSymbolResults": 50
            }
        });
        let response: Value = serde_json::from_str(&execute_json(
            &serde_json::to_string(&request).expect("search request should encode"),
        ))
        .expect("search response should be JSON");
        assert_eq!(response["ok"], true);
        let matches = response["data"]["matches"]
            .as_array()
            .expect("search matches should be an array");
        assert!(matches.iter().any(|value| value["kind"] == "file"));
        assert!(matches.iter().any(|value| value["kind"] == "type"));
        assert!(matches.iter().any(|value| value["kind"] == "content"));

        let replacement = serde_json::json!({
            "id": "replacement",
            "command": "workspace.replacePreview",
            "payload": {
                "root": root,
                "query": "load",
                "replacement": "fetch",
                "caseSensitive": false,
                "wholeWords": false,
                "regularExpression": false,
                "paths": [relative]
            }
        });
        let replacement_response: Value = serde_json::from_str(&execute_json(
            &serde_json::to_string(&replacement).expect("replacement request should encode"),
        ))
        .expect("replacement response should be JSON");
        assert_eq!(replacement_response["ok"], true);
        assert_eq!(
            replacement_response["data"]["files"][0]["matches"][0]["after"],
            "    void fetchUser() {}"
        );
        assert_eq!(
            replacement_response["data"]["files"][0]["replacementText"],
            "class UserService {\n    void fetchUser() {}\n}\n"
        );

        let mut override_request = serde_json::json!({
            "id": "override",
            "command": "workspace.replacePreview",
            "payload": {
                "root": root,
                "query": "fetch",
                "replacement": "load",
                "paths": [relative],
                "textOverrides": {}
            }
        });
        override_request["payload"]["textOverrides"][relative] =
            serde_json::json!("class UserService {\n    void fetchUser() {}\n}\n");
        let override_response: Value = serde_json::from_str(&execute_json(
            &serde_json::to_string(&override_request).expect("override request should encode"),
        ))
        .expect("override response should be JSON");
        assert_eq!(override_response["ok"], true);
        assert_eq!(
            override_response["data"]["files"][0]["matches"][0]["before"],
            "    void fetchUser() {}"
        );

        fs::remove_dir_all(root).expect("temporary fixture should be removable");
    }

    #[test]
    fn local_history_records_deduplicates_lists_and_relocates() {
        let root = temporary_root("history");
        fs::create_dir_all(&root).expect("history workspace should be creatable");
        let storage = root.join("history-storage");

        let request = |command: &str, payload: Value| -> Value {
            let request = serde_json::json!({
                "id": command,
                "command": command,
                "payload": payload
            });
            serde_json::from_str(&execute_json(
                &serde_json::to_string(&request).expect("history request should encode"),
            ))
            .expect("history response should be JSON")
        };

        let record_payload = |content: &str| {
            serde_json::json!({
                "workspaceRoot": root,
                "storageRoot": storage,
                "path": "src/Main.java",
                "reason": "saved",
                "content": content,
                "hiddenDirectoryNames": [],
                "hiddenFilePatterns": []
            })
        };
        let first = request("history.record", record_payload("one\n"));
        assert_eq!(first["ok"], true);
        assert!(first["data"]["id"].as_str().is_some());
        let duplicate = request("history.record", record_payload("one\n"));
        assert_eq!(duplicate["ok"], true);
        assert!(duplicate["data"].is_null());
        let mut invalid_reason = record_payload("invalid\n");
        invalid_reason["reason"] = serde_json::json!("not-a-history-reason");
        let invalid = request("history.record", invalid_reason);
        assert_eq!(invalid["ok"], false);
        assert_eq!(invalid["error"]["code"], "invalid_request");

        let second = request("history.record", record_payload("two\n"));
        assert_eq!(second["ok"], true);
        let listed = request(
            "history.entries",
            serde_json::json!({
                "workspaceRoot": root,
                "storageRoot": storage,
                "path": "src/Main.java"
            }),
        );
        assert_eq!(listed["ok"], true);
        assert_eq!(listed["data"]["entries"].as_array().unwrap().len(), 2);
        let content_path = listed["data"]["entries"][0]["contentPath"]
            .as_str()
            .unwrap();
        let content = request(
            "history.content",
            serde_json::json!({
                "storageRoot": storage,
                "contentPath": content_path
            }),
        );
        assert_eq!(content["data"]["text"], "two\n");

        let relocated = request(
            "history.relocate",
            serde_json::json!({
                "storageRoot": storage,
                "sourcePath": "src/Main.java",
                "destinationPath": "src/Renamed.java"
            }),
        );
        assert_eq!(relocated["ok"], true);
        let relocated_entries = request(
            "history.entries",
            serde_json::json!({
                "workspaceRoot": root,
                "storageRoot": storage,
                "path": "src/Renamed.java"
            }),
        );
        assert_eq!(
            relocated_entries["data"]["entries"]
                .as_array()
                .unwrap()
                .len(),
            2
        );

        let traversal = request(
            "history.content",
            serde_json::json!({
                "storageRoot": storage,
                "contentPath": "../outside.snapshot"
            }),
        );
        assert_eq!(traversal["ok"], false);
        assert_eq!(traversal["error"]["code"], "invalid_request");
        fs::remove_dir_all(root).expect("history workspace should be removable");
    }

    #[test]
    fn file_commands_round_trip_and_reject_traversal() {
        let root = temporary_root("file");
        let outside = temporary_root("outside");
        fs::create_dir_all(&root).expect("temporary workspace should be creatable");
        fs::create_dir_all(&outside).expect("outside directory should be creatable");

        let write = serde_json::json!({
            "id": "write",
            "command": "file.write",
            "payload": {"root": root, "path": "nested/example.txt", "text": "hello"}
        });
        let write_response: Value = serde_json::from_str(&execute_json(
            &serde_json::to_string(&write).expect("write request should encode"),
        ))
        .expect("write response should be JSON");
        assert_eq!(write_response["ok"], true);

        let read = serde_json::json!({
            "id": "read",
            "command": "file.read",
            "payload": {"root": root, "path": "nested/example.txt"}
        });
        let read_response: Value = serde_json::from_str(&execute_json(
            &serde_json::to_string(&read).expect("read request should encode"),
        ))
        .expect("read response should be JSON");
        assert_eq!(read_response["data"]["text"], "hello");

        let traversal = serde_json::json!({
            "id": "traversal",
            "command": "file.read",
            "payload": {"root": root, "path": "../outside.txt"}
        });
        let traversal_response: Value = serde_json::from_str(&execute_json(
            &serde_json::to_string(&traversal).expect("traversal request should encode"),
        ))
        .expect("traversal response should be JSON");
        assert_eq!(traversal_response["ok"], false);
        assert_eq!(traversal_response["error"]["code"], "invalid_request");

        for path in [
            "..\\outside.txt",
            "nested\\..\\outside.txt",
            "C:\\outside.txt",
        ] {
            let request = serde_json::json!({
                "id": "windows-path",
                "command": "file.read",
                "payload": {"root": root, "path": path}
            });
            let response: Value = serde_json::from_str(&execute_json(
                &serde_json::to_string(&request).expect("Windows path request should encode"),
            ))
            .expect("Windows path response should be JSON");
            assert_eq!(response["ok"], false, "path {path} should be rejected");
            assert_eq!(response["error"]["code"], "invalid_request");
        }

        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(&outside, root.join("link"))
                .expect("test symlink should be creatable");
            let symlink_write = serde_json::json!({
                "id": "symlink-write",
                "command": "file.write",
                "payload": {"root": root, "path": "link/escape.txt", "text": "outside"}
            });
            let symlink_response: Value = serde_json::from_str(&execute_json(
                &serde_json::to_string(&symlink_write).expect("symlink request should encode"),
            ))
            .expect("symlink response should be JSON");
            assert_eq!(symlink_response["ok"], false);
            assert_eq!(symlink_response["error"]["code"], "permission_denied");
            assert!(!outside.join("escape.txt").exists());
        }

        fs::remove_dir_all(root).expect("temporary workspace should be removable");
        fs::remove_dir_all(outside).expect("outside fixture should be removable");
    }

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
        assert_eq!(response["data"]["changes"][0]["path"], "new.txt");
        assert_eq!(response["data"]["changes"][0]["untracked"], true);

        fs::remove_dir_all(root).expect("temporary repository should be removable");
    }

    #[test]
    fn git_command_returns_combined_output_and_exit_code() {
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
        assert!(response["data"]["output"]
            .as_str()
            .expect("Git version output should be text")
            .contains("git version"));

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
    fn maven_scan_returns_recursive_shared_project_model() {
        let root = temporary_root("maven");
        fs::create_dir_all(root.join("module-a/module-b")).expect("modules should be creatable");
        fs::write(
            root.join("pom.xml"),
            r#"<project><groupId>com.example</groupId><artifactId>demo</artifactId><version>1</version><packaging>pom</packaging><modules><module>module-a</module></modules><profiles><profile><id>dev</id><activation><activeByDefault>true</activeByDefault></activation></profile></profiles></project>"#,
        )
        .expect("root pom should be writable");
        fs::write(
            root.join("module-a/pom.xml"),
            r#"<project><artifactId>one</artifactId><modules><module>module-b</module></modules></project>"#,
        )
        .expect("module pom should be writable");
        fs::write(
            root.join("module-a/module-b/pom.xml"),
            r#"<project><artifactId>two</artifactId></project>"#,
        )
        .expect("nested pom should be writable");
        fs::write(root.join("mvnw.cmd"), "@echo off\n").expect("wrapper should be writable");

        let request = serde_json::json!({
            "id": "maven",
            "command": "maven.scan",
            "payload": {"root": root}
        });
        let response: Value = serde_json::from_str(&execute_json(
            &serde_json::to_string(&request).expect("Maven request should encode"),
        ))
        .expect("Maven response should be JSON");
        assert_eq!(response["ok"], true);
        assert_eq!(response["data"]["artifactId"], "demo");
        assert_eq!(response["data"]["packaging"], "pom");
        assert_eq!(response["data"]["profiles"][0]["id"], "dev");
        assert_eq!(response["data"]["hasWrapper"], true);
        assert_eq!(response["data"]["modules"][0]["relativePath"], "module-a");
        assert_eq!(
            response["data"]["modules"][0]["modules"][0]["relativePath"],
            "module-a/module-b"
        );
        let diagnostics = serde_json::json!({
            "id": "maven-diagnostics",
            "command": "maven.diagnostics",
            "payload": {
                "root": root,
                "output": "[ERROR] src/App.java:[12,4] cannot find symbol\n[ERROR] src/App.java:[12,4] cannot find symbol\n[WARNING] src/App.java:[4] unused import\n"
            }
        });
        let diagnostics_response: Value = serde_json::from_str(&execute_json(
            &serde_json::to_string(&diagnostics).expect("diagnostics request should encode"),
        ))
        .expect("diagnostics response should be JSON");
        assert_eq!(diagnostics_response["ok"], true);
        assert_eq!(
            diagnostics_response["data"]["issues"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        assert_eq!(
            diagnostics_response["data"]["issues"][0]["severity"],
            "error"
        );
        fs::remove_dir_all(root).expect("Maven fixture should be removable");
    }

    #[test]
    fn java_core_commands_return_shared_runtime_and_structure_data() {
        let root = temporary_root("java");
        fs::create_dir_all(root.join("src/main/java/com/example"))
            .expect("Java source should be creatable");
        fs::write(
            root.join("src/main/java/com/example/App.java"),
            "package com.example;\n@SpringBootApplication\nclass App {\n    static void main(String[] args) {}\n}\n",
        )
        .expect("Java source should be writable");
        let configurations = serde_json::json!({
            "id": "java-config",
            "command": "java.runConfigurations",
            "payload": {
                "root": root,
                "paths": ["src/main/java/com/example/App.java"],
                "modulePaths": ["src"]
            }
        });
        let response: Value = serde_json::from_str(&execute_json(
            &serde_json::to_string(&configurations).expect("Java request should encode"),
        ))
        .expect("Java response should be JSON");
        assert_eq!(response["ok"], true);
        assert_eq!(
            response["data"]["mainClasses"][0]["qualifiedName"],
            "com.example.App"
        );
        assert_eq!(response["data"]["configurations"][0]["kind"], "springBoot");
        assert_eq!(response["data"]["configurations"][0]["modulePath"], "src");

        let structure = serde_json::json!({
            "id": "java-structure",
            "command": "java.structure",
            "payload": {
                "source": "import a.A;\nimport b.B;\ninterface Service {}\n"
            }
        });
        let structure_response: Value = serde_json::from_str(&execute_json(
            &serde_json::to_string(&structure).expect("Java structure request should encode"),
        ))
        .expect("Java structure response should be JSON");
        assert_eq!(structure_response["ok"], true);
        assert_eq!(
            structure_response["data"]["foldRegions"][0]["kind"],
            "imports"
        );
        assert_eq!(
            structure_response["data"]["implementationMarkers"][0]["direction"],
            "down"
        );
        let swift_structure = serde_json::json!({
            "id": "swift-structure",
            "command": "java.structure",
            "payload": {
                "source": "struct Demo {\n    func run() {\n        if ready {\n            work()\n        }\n    }\n}\n"
            }
        });
        let swift_structure_response: Value = serde_json::from_str(&execute_json(
            &serde_json::to_string(&swift_structure)
                .expect("Swift structure request should encode"),
        ))
        .expect("Swift structure response should be JSON");
        let swift_folds = swift_structure_response["data"]["foldRegions"]
            .as_array()
            .expect("Swift structure should return fold regions");
        assert!(swift_folds.iter().any(|fold| {
            fold["startLine"] == 0 && fold["endLine"] == 6 && fold["kind"] == "type"
        }));
        assert!(swift_folds.iter().any(|fold| {
            fold["startLine"] == 1 && fold["endLine"] == 5 && fold["kind"] == "method"
        }));
        let code_vision = serde_json::json!({
            "id": "java-vision",
            "command": "java.codeVision",
            "payload": {
                "root": root,
                "targetPath": "src/main/java/com/example/App.java",
                "paths": ["src/main/java/com/example/App.java"]
            }
        });
        let vision_response: Value = serde_json::from_str(&execute_json(
            &serde_json::to_string(&code_vision).expect("code vision request should encode"),
        ))
        .expect("code vision response should be JSON");
        assert_eq!(vision_response["ok"], true);
        assert!(vision_response["data"]["hints"]
            .as_array()
            .unwrap()
            .iter()
            .any(|hint| hint["symbol"] == "App"));
        let class_name = serde_json::json!({
            "id": "java-class",
            "command": "java.className",
            "payload": {"source": "package com.example;\nclass App {}", "simpleName": "App"}
        });
        let class_response: Value = serde_json::from_str(&execute_json(
            &serde_json::to_string(&class_name).expect("class name request should encode"),
        ))
        .expect("class name response should be JSON");
        assert_eq!(class_response["data"]["className"], "com.example.App");
        let definition = serde_json::json!({
            "id": "java-definition",
            "command": "java.sourceDefinition",
            "payload": {
                "source": "class App {\n    void run() {}\n}",
                "declarationName": "App",
                "memberName": "run"
            }
        });
        let definition_response: Value = serde_json::from_str(&execute_json(
            &serde_json::to_string(&definition).expect("definition request should encode"),
        ))
        .expect("definition response should be JSON");
        assert_eq!(definition_response["data"]["line"], 1);
        let server_port = serde_json::json!({
            "id": "java-port",
            "command": "java.serverPort",
            "payload": {"content": "server:\n  port: 8080\n", "fileExtension": "yml"}
        });
        let port_response: Value = serde_json::from_str(&execute_json(
            &serde_json::to_string(&server_port).expect("server port request should encode"),
        ))
        .expect("server port response should be JSON");
        assert_eq!(port_response["data"]["port"], 8080);
        fs::remove_dir_all(root).expect("Java fixture should be removable");
    }
}
