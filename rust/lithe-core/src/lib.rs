mod cancellation;
mod command;
mod error;
mod event;
mod ffi;
mod git;
mod history;
mod java;
mod markdown;
mod maven;
mod model;
mod runtime;
mod shelf;
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

    fn core_request(command: &str, payload: Value) -> Value {
        let request = serde_json::json!({
            "id": command,
            "command": command,
            "payload": payload
        });
        serde_json::from_str(&execute_json(
            &serde_json::to_string(&request).expect("core request should encode"),
        ))
        .expect("core response should be JSON")
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
    fn markdown_render_command_returns_sanitized_html() {
        let request = serde_json::json!({
            "id": "markdown-1",
            "command": "markdown.render",
            "payload": {
                "source": "# Preview\n\n| A | B |\n| - | - |\n| 1 | 2 |\n\n```plantuml\nAlice -> Bob\n```\n\n<script>alert(1)</script>"
            }
        });
        let response: Value = serde_json::from_str(&execute_json(
            &serde_json::to_string(&request).expect("Markdown request should encode"),
        ))
        .expect("Markdown response should be JSON");

        assert_eq!(response["id"], "markdown-1");
        assert_eq!(response["ok"], true);
        let html = response["data"]["html"]
            .as_str()
            .expect("Markdown response should contain HTML");
        assert!(html.contains("<table"));
        assert!(html.contains("language-plantuml"));
        assert!(html.contains("Alice -&gt; Bob"));
        assert!(!html.contains("<script"));
        assert!(!html.contains("alert(1)"));
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
    fn file_mask_limits_search_to_matching_extensions() {
        let root = temporary_root("file-mask");
        fs::create_dir_all(root.join("src")).expect("fixture directory should be creatable");
        fs::write(root.join("src/Service.java"), "int total = 1;\n")
            .expect("java fixture should be writable");
        fs::write(root.join("src/notes.txt"), "int total = 2;\n")
            .expect("text fixture should be writable");

        let search = |mask: &str| -> Vec<String> {
            let request = serde_json::json!({
                "id": "mask",
                "command": "workspace.search",
                "payload": {
                    "root": root,
                    "query": "total",
                    "fileMask": mask
                }
            });
            let response: Value = serde_json::from_str(&execute_json(
                &serde_json::to_string(&request).expect("search request should encode"),
            ))
            .expect("search response should be JSON");
            assert_eq!(response["ok"], true);
            response["data"]["matches"]
                .as_array()
                .expect("matches should be an array")
                .iter()
                .map(|value| value["path"].as_str().unwrap_or_default().to_string())
                .collect()
        };

        let unfiltered = search("");
        assert!(unfiltered.iter().any(|path| path.ends_with("Service.java")));
        assert!(unfiltered.iter().any(|path| path.ends_with("notes.txt")));

        let java_only = search("*.java");
        assert!(java_only.iter().any(|path| path.ends_with("Service.java")));
        assert!(!java_only.iter().any(|path| path.ends_with("notes.txt")));

        // 多个掩码取并集，且容忍逗号后的空格。
        let both = search("*.java, *.txt");
        assert!(both.iter().any(|path| path.ends_with("Service.java")));
        assert!(both.iter().any(|path| path.ends_with("notes.txt")));

        fs::remove_dir_all(root).expect("temporary fixture should be removable");
    }

    #[test]
    fn preserve_case_matches_original_occurrence_shape() {
        let root = temporary_root("preserve-case");
        fs::create_dir_all(&root).expect("fixture directory should be creatable");
        let relative = "Sample.java";
        fs::write(root.join(relative), "fooBar FooBar FOOBAR fooBar();\n")
            .expect("fixture should be writable");

        let replace = |preserve_case: bool| -> String {
            let request = serde_json::json!({
                "id": "preserve",
                "command": "workspace.replacePreview",
                "payload": {
                    "root": root,
                    "query": "fooBar",
                    "replacement": "bazQux",
                    "caseSensitive": false,
                    "preserveCase": preserve_case,
                    "paths": [relative]
                }
            });
            let response: Value = serde_json::from_str(&execute_json(
                &serde_json::to_string(&request).expect("replace request should encode"),
            ))
            .expect("replace response should be JSON");
            assert_eq!(response["ok"], true);
            response["data"]["files"][0]["matches"][0]["after"]
                .as_str()
                .expect("after text should be a string")
                .to_string()
        };

        assert_eq!(replace(false), "bazQux bazQux bazQux bazQux();");
        assert_eq!(replace(true), "bazQux BazQux BAZQUX bazQux();");

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
        assert_eq!(write_response["data"]["bytesWritten"], 5);
        assert!(write_response["data"]["newVersion"]
            .as_str()
            .is_some_and(|value| value.starts_with("sha256:")));
        assert_eq!(
            write_response["data"]["newVersion"],
            "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        );

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
        assert_eq!(read_response["data"]["lineEnding"], "lf");
        assert_eq!(read_response["data"]["hasUtf8Bom"], false);

        fs::write(root.join("legacy.txt"), b"\xEF\xBB\xBFlegacy\r\n")
            .expect("legacy file should be writable");
        let legacy_read = core_request(
            "file.read",
            serde_json::json!({"root": root, "path": "legacy.txt"}),
        );
        assert_eq!(legacy_read["data"]["text"], "\u{feff}legacy\r\n");
        let legacy_write = core_request(
            "file.write",
            serde_json::json!({
                "root": root,
                "path": "legacy.txt",
                "text": legacy_read["data"]["text"]
            }),
        );
        assert_eq!(legacy_write["ok"], true);
        assert_eq!(
            fs::read(root.join("legacy.txt")).expect("legacy file should be readable"),
            b"\xEF\xBB\xBFlegacy\r\n"
        );

        let version = read_response["data"]["version"]
            .as_str()
            .expect("read response should contain a version")
            .to_string();
        let guarded_write = core_request(
            "file.write",
            serde_json::json!({
                "root": root,
                "path": "nested/example.txt",
                "text": "first\nsecond\n",
                "expectedVersion": version,
                "lineEnding": "crlf",
                "hasUtf8Bom": true,
                "formatAware": true
            }),
        );
        assert_eq!(guarded_write["ok"], true);
        assert_eq!(
            fs::read(root.join("nested/example.txt")).expect("saved file should be readable"),
            b"\xEF\xBB\xBFfirst\r\nsecond\r\n"
        );

        let formatted_read = core_request(
            "file.read",
            serde_json::json!({
                "root": root,
                "path": "nested/example.txt",
                "formatAware": true
            }),
        );
        assert_eq!(formatted_read["data"]["text"], "first\nsecond\n");
        assert_eq!(formatted_read["data"]["lineEnding"], "crlf");
        assert_eq!(formatted_read["data"]["hasUtf8Bom"], true);

        fs::write(root.join("nested/example.txt"), b"external\n")
            .expect("external edit should succeed");
        let conflict = core_request(
            "file.write",
            serde_json::json!({
                "root": root,
                "path": "nested/example.txt",
                "text": "editor",
                "expectedVersion": formatted_read["data"]["version"],
                "lineEnding": "lf",
                "hasUtf8Bom": false,
                "formatAware": true
            }),
        );
        assert_eq!(conflict["ok"], false);
        assert_eq!(conflict["error"]["code"], "external_conflict");
        assert_eq!(
            fs::read(root.join("nested/example.txt")).expect("conflict must preserve disk file"),
            b"external\n"
        );

        let create = core_request(
            "file.write",
            serde_json::json!({
                "root": root,
                "path": "recreated.txt",
                "text": "restored",
                "createOnly": true,
                "formatAware": true
            }),
        );
        assert_eq!(create["ok"], true);
        let create_conflict = core_request(
            "file.write",
            serde_json::json!({
                "root": root,
                "path": "recreated.txt",
                "text": "overwrite",
                "createOnly": true,
                "formatAware": true
            }),
        );
        assert_eq!(create_conflict["error"]["code"], "external_conflict");
        assert_eq!(
            fs::read(root.join("recreated.txt")).expect("create conflict must preserve file"),
            b"restored"
        );

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
            fs::read_to_string(root.join("example.txt")).expect("file should be readable"),
            "initial\n"
        );
        assert_eq!(
            String::from_utf8_lossy(&run(&["status", "--porcelain"]).stdout),
            ""
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
        let stash_reference =
            String::from_utf8_lossy(&run(&["stash", "list", "--format=%gd"]).stdout)
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
        assert_eq!(applied["data"]["exitCode"], 1, "{applied:?}");
        assert_eq!(
            applied["data"]["stashRestore"]["stashReference"], stash_reference,
            "{applied:?}"
        );
        assert_eq!(
            applied["data"]["stashRestore"]["conflictedPaths"],
            serde_json::json!(["shared.txt"]),
            "{applied:?}"
        );

        // Clear the index conflict without dropping the saved entry, then verify
        // `pop` reports the same structured recovery data.
        assert!(run(&["reset", "--hard", "HEAD"]).status.success());
        let popped = write("stashPop");
        assert_eq!(popped["ok"], true, "{popped:?}");
        assert_eq!(popped["data"]["exitCode"], 1, "{popped:?}");
        assert_eq!(
            popped["data"]["stashRestore"]["stashReference"], stash_reference,
            "{popped:?}"
        );
        assert_eq!(
            popped["data"]["stashRestore"]["conflictedPaths"],
            serde_json::json!(["shared.txt"]),
            "{popped:?}"
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

        // Continuing when nothing is in progress is rejected rather than run blindly.
        let nothing = write("operationContinue");
        assert_eq!(nothing["ok"], false, "{nothing:?}");
        assert_eq!(nothing["error"]["code"], "invalid_request");

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
        assert_eq!(premature["ok"], false, "{premature:?}");
        assert_eq!(premature["error"]["code"], "invalid_request");

        // A merge has no skip step.
        let skip = write("operationSkip");
        assert_eq!(skip["ok"], false, "{skip:?}");

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

        let shelf_patches = serde_json::json!({
            "id": "shelf-patches",
            "command": "git.shelfPatches",
            "payload": {"root": root}
        });
        let shelf_response: Value = serde_json::from_str(&execute_json(
            &serde_json::to_string(&shelf_patches).expect("Shelf patches request should encode"),
        ))
        .expect("Shelf patches response should be JSON");
        assert_eq!(shelf_response["ok"], true, "{shelf_response:?}");
        assert_eq!(shelf_response["data"]["stagedPatch"], staged_patch);
        assert_eq!(shelf_response["data"]["workingTreePatch"], working_patch);
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
            &serde_json::to_string(&untracked_apply)
                .expect("untracked apply request should encode"),
        ))
        .expect("untracked apply response should be JSON");
        assert_eq!(untracked_apply_response["ok"], true);
        assert_eq!(untracked_apply_response["data"]["exitCode"], 0);
        assert_eq!(
            fs::read_to_string(root.join("new.txt")).expect("file should be readable"),
            "untracked\n"
        );
        fs::remove_file(root.join("new.txt"))
            .expect("temporary untracked file should be removable");
        let module = root.join("module");
        fs::create_dir_all(&module).expect("module workspace should be creatable");
        fs::write(module.join("nested.txt"), "nested\n").expect("nested file should be writable");
        let nested_shelf_request = serde_json::json!({
            "id": "nested-shelf-patches",
            "command": "git.shelfPatches",
            "payload": {"root": module}
        });
        let nested_shelf_response: Value = serde_json::from_str(&execute_json(
            &serde_json::to_string(&nested_shelf_request)
                .expect("nested Shelf patches request should encode"),
        ))
        .expect("nested Shelf patches response should be JSON");
        assert_eq!(
            nested_shelf_response["ok"], true,
            "{nested_shelf_response:?}"
        );
        assert!(nested_shelf_response["data"]["workingTreePatch"]
            .as_str()
            .expect("nested working patch should be text")
            .contains("module/nested.txt"));

        // Subdirectory requests collect staged and worktree edits from the
        // repository root, not the module root.
        fs::write(module.join("tracked.txt"), "tracked\n")
            .expect("tracked file should be writable");
        assert!(run(&["add", "module/tracked.txt"]).status.success());
        assert!(run(&["commit", "-qm", "nested fixture"]).status.success());
        fs::write(module.join("tracked.txt"), "tracked changed\n")
            .expect("tracked file should be writable");
        fs::write(module.join("staged.txt"), "staged nested\n")
            .expect("staged file should be writable");
        assert!(run(&["add", "module/staged.txt"]).status.success());
        let nested_shelf_full = serde_json::from_str::<Value>(&execute_json(
            &serde_json::to_string(&serde_json::json!({
                "id": "nested-shelf-full",
                "command": "git.shelfPatches",
                "payload": {"root": module}
            }))
            .expect("nested Shelf request should encode"),
        ))
        .expect("nested Shelf response should be JSON");
        assert_eq!(nested_shelf_full["ok"], true, "{nested_shelf_full:?}");
        assert!(nested_shelf_full["data"]["stagedPatch"]
            .as_str()
            .expect("nested staged patch should be text")
            .contains("module/staged.txt"));
        let nested_working = nested_shelf_full["data"]["workingTreePatch"]
            .as_str()
            .expect("nested working patch should be text");
        assert!(nested_working.contains("module/tracked.txt"));
        assert!(nested_working.contains("module/nested.txt"));
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
        let stash_reference = stashes_response["data"]["stashes"][0]["reference"]
            .as_str()
            .expect("stash reference should be text");
        assert!(
            stash_reference.starts_with("stash@{") && !stash_reference.contains(' '),
            "stash list must return index refs like stash@{{0}}, got {stash_reference}"
        );

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
        fs::write(root.join("doc.md"), "Title\n=======\n\nbody\n")
            .expect("file should be writable");
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
        let pick = String::from_utf8(run(&["rev-parse", "HEAD"]).stdout)
            .expect("a revision should be UTF-8");
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
    fn shelves_keep_staged_and_worktree_patches_separate() {
        let root = temporary_root("shelf");
        let storage = root.join("storage");
        fs::create_dir_all(&root).expect("Shelf workspace should be creatable");
        let create = serde_json::from_str::<Value>(&execute_json(
            &serde_json::to_string(&serde_json::json!({
                "id": "shelf-create",
                "command": "shelf.create",
                "payload": {
                    "workspaceRoot": root,
                    "storageRoot": storage,
                    "label": "before checkout\n",
                    "stagedPatch": "staged",
                    "workingTreePatch": "working"
                }
            }))
            .expect("Shelf request should encode"),
        ))
        .expect("Shelf create response should be JSON");
        assert_eq!(create["ok"], true);
        let id = create["data"]["id"]
            .as_str()
            .expect("Shelf id should exist");

        let list = serde_json::from_str::<Value>(&execute_json(
            &serde_json::to_string(&serde_json::json!({
                "id": "shelf-list",
                "command": "shelf.list",
                "payload": {"workspaceRoot": root, "storageRoot": storage}
            }))
            .expect("Shelf list request should encode"),
        ))
        .expect("Shelf list response should be JSON");
        assert_eq!(list["data"]["shelves"].as_array().map(Vec::len), Some(1));
        assert_eq!(list["data"]["shelves"][0]["stagedByteCount"], 6);
        assert_eq!(list["data"]["shelves"][0]["workingTreeByteCount"], 7);

        let restore = serde_json::from_str::<Value>(&execute_json(
            &serde_json::to_string(&serde_json::json!({
                "id": "shelf-restore",
                "command": "shelf.restore",
                "payload": {"workspaceRoot": root, "storageRoot": storage, "id": id}
            }))
            .expect("Shelf restore request should encode"),
        ))
        .expect("Shelf restore response should be JSON");
        assert_eq!(restore["data"]["stagedPatch"], "staged");
        assert_eq!(restore["data"]["workingTreePatch"], "working");

        let delete = serde_json::from_str::<Value>(&execute_json(
            &serde_json::to_string(&serde_json::json!({
                "id": "shelf-delete",
                "command": "shelf.delete",
                "payload": {"workspaceRoot": root, "storageRoot": storage, "id": id}
            }))
            .expect("Shelf delete request should encode"),
        ))
        .expect("Shelf delete response should be JSON");
        assert_eq!(delete["data"]["deleted"], true);

        let missing = serde_json::from_str::<Value>(&execute_json(
            &serde_json::to_string(&serde_json::json!({
                "id": "shelf-missing",
                "command": "shelf.restore",
                "payload": {"workspaceRoot": root, "storageRoot": storage, "id": id}
            }))
            .expect("Shelf missing request should encode"),
        ))
        .expect("Shelf missing response should be JSON");
        assert_eq!(missing["ok"], false);
        fs::remove_dir_all(root).expect("Shelf fixture should be removable");
    }
}
