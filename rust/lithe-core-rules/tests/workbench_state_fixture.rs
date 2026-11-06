//! Drives the shared workbench-state fixture through the JSON envelope, exactly like the hosts do.

use lithe_core_rules::{execute_json, is_rule_command};
use serde_json::{json, Value};

const FIXTURE: &str = include_str!("../../../shared/fixtures/editor/workbench-state-v1.json");
const COMMAND: &str = "editor.workbenchState.reduce";

fn call(payload: Value) -> Value {
    let request = json!({"id": "fixture", "command": COMMAND, "payload": payload});
    serde_json::from_str(&execute_json(&request.to_string())).unwrap()
}

#[test]
fn command_is_owned_by_the_rules_crate() {
    assert!(is_rule_command(COMMAND));
}

#[test]
fn every_fixture_case_matches() {
    let fixture: Value = serde_json::from_str(FIXTURE).unwrap();
    assert_eq!(fixture["version"], 1);
    let cases = fixture["cases"].as_array().unwrap();
    assert!(cases.len() >= 40, "fixture should keep its coverage");
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let response = call(json!({"state": case["state"], "action": case["action"]}));
        assert_eq!(response["ok"], true, "{name}: {response}");
        assert_eq!(response["id"], "fixture");
        assert_eq!(
            response["data"]["state"], case["expected"]["state"],
            "{name}"
        );
        assert_eq!(
            response["data"]["removedGroupIds"], case["expected"]["removedGroupIds"],
            "{name}"
        );
    }
}

#[test]
fn reducing_a_result_again_changes_nothing_for_normalizing_actions() {
    let fixture: Value = serde_json::from_str(FIXTURE).unwrap();
    for case in fixture["cases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let again =
            call(json!({"state": case["expected"]["state"], "action": {"kind": "normalize"}}));
        // Re-normalizing a reducer result is idempotent: the reducer never emits a state it
        // would repair.
        assert_eq!(again["data"]["state"], case["expected"]["state"], "{name}");
        assert_eq!(again["data"]["removedGroupIds"], json!([]), "{name}");
    }
}

#[test]
fn malformed_requests_are_invalid() {
    for payload in [
        json!({}),
        json!({"action": {"kind": "teleport"}}),
        json!({"action": {"kind": "open", "group": "g"}}),
        json!({"action": {"kind": "open", "group": "g", "member": "a", "extra": 1}}),
        json!({"state": {"groups": [{"members": []}]}, "action": {"kind": "normalize"}}),
        json!({"action": {"kind": "close", "group": "g", "member": "a", "emptyGroups": "nope"}}),
    ] {
        let response = call(payload.clone());
        assert_eq!(response["ok"], false, "{payload}");
        assert_eq!(response["error"]["code"], "invalid_request", "{payload}");
    }
}
