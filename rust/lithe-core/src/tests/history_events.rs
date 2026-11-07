use crate::execute_json;
use serde_json::{json, Value};

fn execute(payload: Value) -> Value {
    serde_json::from_str(&execute_json(
        &json!({"id": "history-event", "command": "history.planEvent", "payload": payload})
            .to_string(),
    ))
    .expect("core response should be JSON")
}

fn fixture() -> Value {
    serde_json::from_str(include_str!(
        "../../../../shared/fixtures/history/event-plan-v1.json"
    ))
    .expect("history event fixture should be JSON")
}

#[test]
fn event_plans_match_the_shared_fixture() {
    for case in fixture()["events"].as_array().unwrap() {
        let response = execute(json!({"event": case["event"]}));
        assert_eq!(response["ok"], true, "{}: {response}", case["event"]);
        assert_eq!(
            response["data"]["snapshots"], case["snapshots"],
            "{}",
            case["event"]
        );
    }
}

#[test]
fn every_planned_reason_is_accepted_by_the_recorder() {
    for case in fixture()["events"].as_array().unwrap() {
        for snapshot in case["snapshots"].as_array().unwrap() {
            let reason = snapshot["reason"].as_str().unwrap();
            assert!(crate::project::is_valid_reason(reason), "{reason}");
        }
    }
}

#[test]
fn unknown_events_are_rejected() {
    for event in fixture()["unknownEvents"].as_array().unwrap() {
        let response = execute(json!({"event": event}));
        assert_eq!(response["ok"], false, "{event}");
        assert_eq!(response["error"]["code"], "invalid_request", "{event}");
    }
}
