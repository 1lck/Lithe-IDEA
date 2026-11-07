//! Drives the shared double-Shift fixture through the JSON envelope, exactly like the hosts do.

use lithe_core_rules::{execute_json, keymap::THRESHOLD_SECONDS};
use serde_json::{json, Value};

const FIXTURE: &str = include_str!("../../../shared/fixtures/keymap/modifier-gesture-v1.json");

fn step(state: &Value, event: Value, timestamp: f64) -> Value {
    let request = json!({
        "id": "fixture",
        "command": "keymap.modifierGestureStep",
        "payload": {"state": state, "event": event, "timestamp": timestamp},
    });
    let response: Value = serde_json::from_str(&execute_json(&request.to_string())).unwrap();
    assert_eq!(response["ok"], true, "{response}");
    assert_eq!(response["id"], "fixture");
    response["data"].clone()
}

#[test]
fn threshold_matches_the_fixture() {
    let fixture: Value = serde_json::from_str(FIXTURE).unwrap();
    assert_eq!(
        fixture["thresholdSeconds"].as_f64(),
        Some(THRESHOLD_SECONDS)
    );
}

#[test]
fn every_fixture_sequence_matches_step_by_step() {
    let fixture: Value = serde_json::from_str(FIXTURE).unwrap();
    for sequence in fixture["sequences"].as_array().unwrap() {
        let name = sequence["name"].as_str().unwrap();
        // The host owns the state; start from the idle default exactly as a host does.
        let mut state = json!({});
        for (index, entry) in sequence["steps"].as_array().unwrap().iter().enumerate() {
            let (event, timestamp) = match entry["event"].as_str().unwrap() {
                "keyDown" => (json!({"kind": "keyDown"}), 0.0),
                "reset" => (json!({"kind": "reset"}), 0.0),
                _ => (
                    json!({
                        "kind": "flags",
                        "shift": entry["shift"],
                        "otherModifiers": entry["otherModifiers"],
                    }),
                    entry["timestamp"].as_f64().unwrap(),
                ),
            };
            let data = step(&state, event, timestamp);
            if let Some(expected) = entry.get("expected") {
                assert_eq!(&data["triggered"], expected, "{name} step {index}");
            }
            state = data["state"].clone();
        }
    }
}

#[test]
fn malformed_requests_use_core_error_codes() {
    let unknown: Value = serde_json::from_str(&execute_json(
        r#"{"id":"a","command":"keymap.nope","payload":{}}"#,
    ))
    .unwrap();
    assert_eq!(unknown["ok"], false);
    assert_eq!(unknown["error"]["code"], "not_supported");

    let bad_payload: Value = serde_json::from_str(&execute_json(
        r#"{"id":"b","command":"keymap.modifierGestureStep","payload":{"event":{"kind":"flags"}}}"#,
    ))
    .unwrap();
    assert_eq!(bad_payload["ok"], false);
    assert_eq!(bad_payload["error"]["code"], "invalid_request");
    assert_eq!(bad_payload["id"], "b");

    let not_json: Value = serde_json::from_str(&execute_json("{")).unwrap();
    assert_eq!(not_json["error"]["code"], "invalid_request");
    assert!(not_json["id"].is_null());
}
