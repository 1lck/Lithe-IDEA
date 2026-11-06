use crate::execute_json;
use serde_json::{json, Value};

fn execute(command: &str, payload: Value) -> Value {
    serde_json::from_str(&execute_json(
        &json!({"id": "file-operations", "command": command, "payload": payload}).to_string(),
    ))
    .expect("core response should be JSON")
}

fn fixture() -> Value {
    serde_json::from_str(include_str!(
        "../../../../shared/fixtures/workspace/file-copy-names-v1.json"
    ))
    .expect("file copy names fixture should be JSON")
}

#[test]
fn duplicate_names_match_the_shared_fixture() {
    for case in fixture()["duplicate"].as_array().unwrap() {
        let response = execute("workspace.planDuplicate", case["request"].clone());
        assert_eq!(response["ok"], true, "{}: {response}", case["id"]);
        assert_eq!(response["data"]["name"], case["name"], "{}", case["id"]);
    }
}

#[test]
fn paste_names_match_the_shared_fixture() {
    for case in fixture()["paste"].as_array().unwrap() {
        let response = execute("workspace.planPaste", case["request"].clone());
        assert_eq!(response["ok"], true, "{}: {response}", case["id"]);
        assert_eq!(response["data"]["names"], case["names"], "{}", case["id"]);
    }
}

#[test]
fn a_name_that_lost_a_race_is_planned_again_around_the_new_fact() {
    let first = json!({"name": "a.txt", "isDirectory": false, "existing": ["a.txt"]});
    assert_eq!(
        execute("workspace.planDuplicate", first)["data"]["name"],
        "a copy.txt"
    );
    let second = json!({
        "name": "a.txt", "isDirectory": false, "existing": ["a.txt", "a copy.txt"]
    });
    assert_eq!(
        execute("workspace.planDuplicate", second)["data"]["name"],
        "a copy 2.txt"
    );
}

#[test]
fn invalid_names_and_oversized_requests_are_rejected() {
    for name in fixture()["invalidNames"].as_array().unwrap() {
        let response = execute(
            "workspace.planPaste",
            json!({"items": [{"name": name, "isDirectory": false}]}),
        );
        assert_eq!(response["ok"], false, "{name}");
        assert_eq!(response["error"]["code"], "invalid_request", "{name}");
    }
    let existing = (0..100_001)
        .map(|index| index.to_string())
        .collect::<Vec<_>>();
    let response = execute(
        "workspace.planDuplicate",
        json!({"name": "a", "isDirectory": false, "existing": existing}),
    );
    assert_eq!(response["error"]["code"], "invalid_request");
}
