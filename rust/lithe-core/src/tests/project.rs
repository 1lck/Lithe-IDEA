use super::support::{fixture, temporary_root};
use crate::execute_json;
use serde_json::Value;
use std::fs;

#[test]
fn workspace_snapshot_hides_nested_worktree_checkouts() {
    let root = temporary_root("snapshot-worktree");
    fs::create_dir_all(root.join("src")).expect("source directory should be creatable");
    fs::create_dir_all(root.join(".worktree/feature/src"))
        .expect("worktree directory should be creatable");
    fs::create_dir_all(root.join(".worktrees/bugfix/src"))
        .expect("worktrees directory should be creatable");
    fs::write(root.join("src/App.java"), "class App {}").expect("source should be writable");
    fs::write(root.join(".worktree/feature/src/App.java"), "class App {}")
        .expect("worktree source should be writable");
    fs::write(root.join(".worktrees/bugfix/src/App.java"), "class App {}")
        .expect("worktrees source should be writable");

    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "snapshot-worktree",
            "command": "workspace.snapshot",
            "payload": {"root": root}
        })
        .to_string(),
    ))
    .expect("snapshot response should be JSON");

    assert_eq!(response["ok"], true, "{response}");
    assert_eq!(
        response["data"]["files"],
        serde_json::json!(["src/App.java"])
    );

    fs::remove_dir_all(root).expect("temporary fixture should be removable");
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
