use crate::execute_json;
use serde_json::{json, Value};

fn execute(command: &str, payload: Value) -> Value {
    serde_json::from_str(&execute_json(
        &json!({"id": "directory-actions", "command": command, "payload": payload}).to_string(),
    ))
    .expect("core response should be JSON")
}

fn fixture() -> Value {
    serde_json::from_str(include_str!(
        "../../../../shared/fixtures/workspace/directory-rules-v1.json"
    ))
    .expect("directory rules fixture should be JSON")
}

/// Sorts include lists so the comparison does not depend on insertion order.
fn normalized(mut value: Value) -> Value {
    fn visit(value: &mut Value) {
        match value {
            Value::Object(map) => {
                if let Some(Value::Array(list)) = map.get_mut("includedDirectories") {
                    list.sort_by_key(|item| item.as_str().unwrap_or_default().to_owned());
                }
                map.values_mut().for_each(visit);
            }
            Value::Array(list) => list.iter_mut().for_each(visit),
            _ => {}
        }
    }
    visit(&mut value);
    value
}

#[test]
fn reduce_matches_the_shared_fixture() {
    for case in fixture()["reduce"].as_array().unwrap() {
        let response = execute("workspace.reduceDirectoryAction", case["request"].clone());
        assert_eq!(response["ok"], true, "{}: {response}", case["id"]);
        assert_eq!(
            normalized(response["data"].clone()),
            normalized(case["response"].clone()),
            "{}",
            case["id"]
        );
    }
}

#[test]
fn relocate_matches_the_shared_fixture() {
    for case in fixture()["relocate"].as_array().unwrap() {
        let response = execute("workspace.relocateDirectoryRules", case["request"].clone());
        assert_eq!(response["ok"], true, "{}: {response}", case["id"]);
        assert_eq!(
            normalized(response["data"].clone()),
            normalized(case["response"].clone()),
            "{}",
            case["id"]
        );
    }
}

#[test]
fn invalid_requests_are_rejected() {
    for case in fixture()["invalid"].as_array().unwrap() {
        let response = execute(case["command"].as_str().unwrap(), case["request"].clone());
        assert_eq!(response["ok"], false, "{case}");
        assert_eq!(response["error"]["code"], "invalid_request", "{case}");
    }
}

/// The action-sequence contract shared with the Git-ignore search tests: replaying every
/// step through Core must reach the role and include state the fixture lists.
#[test]
fn action_sequences_reach_the_documented_role_and_inclusion() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/workspace/directory-actions-v1.json"
    ))
    .unwrap();
    for case in fixture["cases"].as_array().unwrap() {
        let mut rules = json!({"marks": {}, "includedDirectories": [], "previousRoles": {}});
        for step in case["steps"].as_array().unwrap() {
            let response = execute(
                "workspace.reduceDirectoryAction",
                json!({"path": "archive", "action": step["action"], "rules": rules}),
            );
            assert_eq!(response["ok"], true, "{}: {response}", case["id"]);
            rules = response["data"]["rules"].clone();
            let role = rules["marks"]["archive"].as_str().unwrap_or("plain");
            let included = rules["includedDirectories"]
                .as_array()
                .unwrap()
                .iter()
                .any(|path| path == "archive");
            assert_eq!(role, step["role"], "{}", case["id"]);
            assert_eq!(included, step["included"], "{}", case["id"]);
        }
    }
}
