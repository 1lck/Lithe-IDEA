use crate::execute_json;
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine as _;
use serde_json::Value;

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
fn debug_create_and_destroy_commands_cross_the_json_boundary() {
    let fixture: Value = serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../shared/fixtures/debug/dap-session-v1.json"
    )))
    .expect("debug fixture should be valid JSON");
    let session = &fixture["session"];
    let create_request = serde_json::json!({
        "id": "debug-create",
        "command": "debug.createSession",
        "payload": session
    });

    let created: Value = serde_json::from_str(&execute_json(&create_request.to_string()))
        .expect("debug create response should be JSON");

    assert_eq!(created["ok"], true);
    assert_eq!(created["data"]["state"], fixture["expected"]["createState"]);
    let frame = created["data"]["outboundFrames"][0]
        .as_str()
        .expect("initialize frame should be base64");
    let bytes = BASE64
        .decode(frame)
        .expect("initialize frame should decode");
    let body_start = bytes
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .expect("initialize frame should have a header")
        + 4;
    let message: Value =
        serde_json::from_slice(&bytes[body_start..]).expect("initialize body should be JSON");
    assert_eq!(message["command"], fixture["expected"]["createCommand"]);

    let destroy_request = serde_json::json!({
        "id": "debug-destroy",
        "command": "debug.destroySession",
        "payload": {"sessionId": session["sessionId"]}
    });
    let destroyed: Value = serde_json::from_str(&execute_json(&destroy_request.to_string()))
        .expect("debug destroy response should be JSON");
    assert_eq!(destroyed["ok"], true);
    assert_eq!(destroyed["data"]["destroyed"], true);
}

#[test]
fn debug_stepping_filters_match_the_shared_contract_fixture() {
    let fixture: Value = serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../shared/fixtures/debug/stepping-filters-v1.json"
    )))
    .expect("debug stepping-filter fixture should be valid JSON");

    for case in fixture["cases"]
        .as_array()
        .expect("debug stepping-filter fixture should contain cases")
    {
        let request = serde_json::json!({
            "id": case["name"],
            "command": "debug.steppingFilters",
            "payload": case["payload"]
        });
        let response: Value = serde_json::from_str(&execute_json(&request.to_string()))
            .expect("debug stepping-filter response should be JSON");

        assert_eq!(response["ok"], true, "fixture case {}", case["name"]);
        assert_eq!(
            response["data"], case["expected"],
            "fixture case {}",
            case["name"]
        );
    }
}

#[test]
fn java_test_debug_launch_matches_the_shared_contract_fixture() {
    let fixture: Value = serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../shared/fixtures/debug/java-test-launch-v1.json"
    )))
    .expect("Java test debug fixture should be valid JSON");

    for case in fixture["cases"]
        .as_array()
        .expect("Java test debug fixture should contain cases")
    {
        let request = serde_json::json!({
            "id": case["name"],
            "command": "debug.javaTestLaunch",
            "payload": case["payload"]
        });
        let response: Value = serde_json::from_str(&execute_json(&request.to_string()))
            .expect("Java test debug response should be JSON");

        assert_eq!(response["ok"], true, "fixture case {}", case["name"]);
        assert_eq!(
            response["data"], case["expected"],
            "fixture case {}",
            case["name"]
        );
    }
}
