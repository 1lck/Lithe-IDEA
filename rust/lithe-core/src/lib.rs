mod command;
mod error;
mod event;
mod ffi;
mod git;
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
}
