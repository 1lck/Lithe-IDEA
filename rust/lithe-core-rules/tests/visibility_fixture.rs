//! Drives the shared hidden-path fixture through the JSON envelope, exactly like the hosts do.

use lithe_core_rules::execute_json;
use serde_json::{json, Value};

const FIXTURE: &str = include_str!("../../../shared/fixtures/workspace/visibility-v1.json");

fn call(command: &str, payload: Value) -> Value {
    let request = json!({"id": "fixture", "command": command, "payload": payload});
    let response: Value = serde_json::from_str(&execute_json(&request.to_string())).unwrap();
    assert_eq!(response["ok"], true, "{response}");
    response["data"].clone()
}

#[test]
fn defaults_match_the_fixture() {
    let fixture: Value = serde_json::from_str(FIXTURE).unwrap();
    assert_eq!(
        call("workspace.visibilityDefaults", json!({})),
        fixture["defaults"]
    );
}

#[test]
fn every_case_is_classified_in_one_batch() {
    let fixture: Value = serde_json::from_str(FIXTURE).unwrap();
    for case in fixture["cases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let entries = case["entries"].as_array().unwrap();
        let data = call(
            "workspace.classifyVisibility",
            json!({
                "hiddenDirectoryNames": case["hiddenDirectoryNames"],
                "hiddenFilePatterns": case["hiddenFilePatterns"],
                "entries": entries
                    .iter()
                    .map(|entry| json!({"path": entry["path"], "isDirectory": entry["isDirectory"]}))
                    .collect::<Vec<_>>(),
            }),
        );
        for (index, entry) in entries.iter().enumerate() {
            let label = format!("{name}: {}", entry["path"]);
            assert_eq!(data["hidden"][index], entry["hidden"], "{label}");
            let watched = entry
                .get("watchedDespiteHiding")
                .cloned()
                .unwrap_or(json!(false));
            assert_eq!(data["watchedDespiteHiding"][index], watched, "{label}");
        }
    }
}

#[test]
fn malformed_requests_use_core_error_codes() {
    let response: Value = serde_json::from_str(&execute_json(
        r#"{"id":"a","command":"workspace.classifyVisibility","payload":{"entries":[{"path":1}]}}"#,
    ))
    .unwrap();
    assert_eq!(response["ok"], false);
    assert_eq!(response["error"]["code"], "invalid_request");
}
