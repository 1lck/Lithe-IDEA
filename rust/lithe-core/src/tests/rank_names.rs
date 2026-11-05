//! `workspace.rankNames` against the shared fixture, so macOS and Windows hosts see one ranking.

use crate::execute_json;
use serde_json::Value;

fn execute(payload: Value) -> Value {
    serde_json::from_str(&execute_json(
        &serde_json::json!({"id": "rank-names", "command": "workspace.rankNames", "payload": payload})
            .to_string(),
    ))
    .expect("core response should be JSON")
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
