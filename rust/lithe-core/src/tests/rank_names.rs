//! `workspace.rankNames` against the shared fixture, so macOS and Windows hosts see one ranking.

use crate::execute_json;
use serde_json::Value;

fn execute_command(command: &str, payload: Value) -> Value {
    serde_json::from_str(&execute_json(
        &serde_json::json!({"id": "rank-names", "command": command, "payload": payload})
            .to_string(),
    ))
    .expect("core response should be JSON")
}

fn execute(payload: Value) -> Value {
    execute_command("workspace.rankNames", payload)
}

#[test]
fn rank_names_matches_the_shared_fixture() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/search/rank-names-v1.json"
    ))
    .expect("rank-names fixture should be JSON");
    for case in fixture["cases"].as_array().unwrap() {
        let response = execute(case["request"].clone());
        assert_eq!(response["ok"], true, "{}: {response}", case["id"]);
        let actual = response["data"]["matches"]
            .as_array()
            .unwrap()
            .iter()
            .map(|hit| {
                serde_json::json!({
                    "index": hit["index"],
                    "tier": hit["tier"],
                    "ranges": hit["nameMatchRanges"],
                })
            })
            .collect::<Vec<_>>();
        assert_eq!(Value::Array(actual), case["expected"], "{}", case["id"]);
    }
}

#[test]
fn rank_names_rejects_oversized_input_instead_of_truncating() {
    let response = execute(serde_json::json!({
        "query": "a",
        "candidates": [{"name": "a".repeat(4097)}],
    }));
    assert_eq!(response["ok"], false);
    assert_eq!(response["error"]["code"], "invalid_request");
    let response = execute(serde_json::json!({"query": "a", "candidates": [], "bogus": 1}));
    assert_eq!(response["error"]["code"], "invalid_request");
}

#[test]
fn search_everywhere_context_matches_the_shared_fixture() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/search/search-everywhere-context-v1.json"
    ))
    .expect("search context fixture should be JSON");
    for case in fixture["cases"].as_array().unwrap() {
        let root = super::support::temporary_root("search-context");
        for file in case["files"].as_array().unwrap() {
            let path = root.join(file.as_str().unwrap());
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, "x").unwrap();
        }
        let mut payload = serde_json::json!({
            "root": root.to_string_lossy(),
            "query": case["query"],
            "resultKinds": ["file"],
            "maxFileResults": 20,
            "maxSymbolResults": 0,
            "maxContentResults": 0,
        });
        if !case["context"].is_null() {
            payload["context"] = case["context"].clone();
        }
        let response = execute_command("workspace.searchEverywhere", payload);
        assert_eq!(response["ok"], true, "{}: {response}", case["id"]);
        let paths: Vec<Value> = response["data"]["matches"]
            .as_array()
            .unwrap()
            .iter()
            .map(|hit| hit["path"].clone())
            .collect();
        assert_eq!(Value::Array(paths), case["expectedPaths"], "{}", case["id"]);
        let _ = std::fs::remove_dir_all(root);
    }
}
