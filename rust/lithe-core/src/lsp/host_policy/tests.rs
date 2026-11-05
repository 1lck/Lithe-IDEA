//! Shared-fixture coverage for the host policy commands. Both platforms
//! consume these fixtures, so a divergence here is a cross-platform bug.

use serde_json::{json, Value};

fn run_fixture(command: &str, fixture: &str) {
    let fixture: Value = serde_json::from_str(fixture).expect("fixture should be JSON");
    let cases = fixture["cases"]
        .as_array()
        .expect("fixture should list cases");
    assert!(!cases.is_empty(), "{command} fixture has no cases");
    for case in cases {
        let response: Value = serde_json::from_str(&crate::execute_json(
            &json!({"command": command, "payload": case["request"]}).to_string(),
        ))
        .expect("Core should return JSON");
        assert_eq!(response["ok"], true, "{}: {response}", case["name"]);
        assert_eq!(response["data"], case["response"], "{}", case["name"]);
    }
}

#[test]
fn problems_query_matches_shared_fixture() {
    run_fixture(
        "lsp.problems.query",
        include_str!("../../../../../shared/fixtures/lsp/problems-query-v1.json"),
    );
}

#[test]
fn activation_policy_matches_shared_fixture() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../../shared/fixtures/lsp/activation-policy-v1.json"
    ))
    .unwrap();
    // The fixture documents the budget; keep it pinned to the constants.
    assert_eq!(
        fixture["maxConsecutiveFailures"],
        super::activation::MAX_CONSECUTIVE_FAILURES
    );
    assert_eq!(
        fixture["failureCooldownMs"],
        super::activation::FAILURE_COOLDOWN_MS
    );
    run_fixture(
        "lsp.activationPolicy",
        include_str!("../../../../../shared/fixtures/lsp/activation-policy-v1.json"),
    );
}

#[test]
fn completion_merge_matches_shared_fixture() {
    run_fixture(
        "lsp.mergeCompletions",
        include_str!("../../../../../shared/fixtures/lsp/completion-merge-v1.json"),
    );
}

#[test]
fn malformed_requests_fail_with_invalid_request() {
    for (command, payload) in [
        (
            "lsp.problems.query",
            json!({"diagnostics": [{"fileKey": "a"}]}),
        ),
        (
            "lsp.problems.query",
            json!({"diagnostics": [], "groupBy": "type"}),
        ),
        ("lsp.activationPolicy", json!({"event": "automaticStart"})),
        (
            "lsp.activationPolicy",
            json!({"event": "crashed", "nowMs": 1}),
        ),
        ("lsp.mergeCompletions", json!({"lists": [{"items": []}]})),
    ] {
        let response: Value = serde_json::from_str(&crate::execute_json(
            &json!({"command": command, "payload": payload}).to_string(),
        ))
        .unwrap();
        assert_eq!(response["ok"], false, "{command}: {response}");
        assert_eq!(response["error"]["code"], "invalid_request", "{command}");
    }
}
