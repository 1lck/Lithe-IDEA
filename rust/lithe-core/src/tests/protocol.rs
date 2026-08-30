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
fn debug_run_in_terminal_response_crosses_the_json_boundary() {
    let fixture: Value = serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../shared/fixtures/debug/run-in-terminal-v1.json"
    )))
    .expect("debug run-in-terminal fixture should be valid JSON");
    let session_id = "debug-terminal-protocol-boundary";
    let create_request = serde_json::json!({
        "id": "debug-terminal-create",
        "command": "debug.createSession",
        "payload": {
            "sessionId": session_id,
            "adapterId": "java",
            "rootPath": "/workspace",
            "supportsRunInTerminalRequest": true
        }
    });
    let created: Value = serde_json::from_str(&execute_json(&create_request.to_string()))
        .expect("debug create response should be JSON");
    assert_eq!(created["ok"], true);

    let adapter_message =
        serde_json::to_vec(&fixture["adapterRequest"]).expect("adapter request should encode");
    let mut framed = format!("Content-Length: {}\r\n\r\n", adapter_message.len()).into_bytes();
    framed.extend(adapter_message);
    let receive_request = serde_json::json!({
        "id": "debug-terminal-receive",
        "command": "debug.receive",
        "payload": {
            "sessionId": session_id,
            "dataBase64": BASE64.encode(framed)
        }
    });
    let received: Value = serde_json::from_str(&execute_json(&receive_request.to_string()))
        .expect("debug receive response should be JSON");
    assert_eq!(received["ok"], true);
    let terminal_event = received["data"]["events"]
        .as_array()
        .expect("debug update should contain events")
        .iter()
        .find(|event| event["type"] == "runInTerminalRequested")
        .expect("debug update should request an integrated terminal");
    assert_eq!(terminal_event["request"], fixture["expectedRequest"]);
    let request_id = terminal_event["requestId"]
        .as_str()
        .expect("terminal request should have a correlation ID");

    let response_request = serde_json::json!({
        "id": "debug-terminal-response",
        "command": "debug.runInTerminalResponse",
        "payload": {
            "sessionId": session_id,
            "requestId": request_id,
            "success": true,
            "processId": fixture["successResponse"]["processId"],
            "shellProcessId": fixture["successResponse"]["shellProcessId"]
        }
    });
    let completed: Value = serde_json::from_str(&execute_json(&response_request.to_string()))
        .expect("debug run-in-terminal response should be JSON");
    assert_eq!(completed["ok"], true);
    let response_frame = completed["data"]["outboundFrames"][0]
        .as_str()
        .expect("terminal response frame should be base64");
    let response_bytes = BASE64
        .decode(response_frame)
        .expect("terminal response frame should decode");
    let body_start = response_bytes
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .expect("terminal response frame should have a header")
        + 4;
    let response_message: Value = serde_json::from_slice(&response_bytes[body_start..])
        .expect("terminal response body should be JSON");
    assert_eq!(
        response_message["request_seq"],
        fixture["adapterRequest"]["seq"]
    );
    assert_eq!(response_message["success"], true);
    assert_eq!(response_message["body"], fixture["expectedSuccessBody"]);

    let destroy_request = serde_json::json!({
        "id": "debug-terminal-destroy",
        "command": "debug.destroySession",
        "payload": {"sessionId": session_id}
    });
    let destroyed: Value = serde_json::from_str(&execute_json(&destroy_request.to_string()))
        .expect("debug destroy response should be JSON");
    assert_eq!(destroyed["ok"], true);
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
fn debug_breakpoint_relocation_matches_the_shared_contract_fixture() {
    let fixture: Value = serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../shared/fixtures/debug/breakpoint-relocation-v1.json"
    )))
    .expect("debug breakpoint-relocation fixture should be valid JSON");

    for case in fixture["cases"]
        .as_array()
        .expect("debug breakpoint-relocation fixture should contain cases")
    {
        let request = serde_json::json!({
            "id": case["name"],
            "command": "debug.relocateBreakpoints",
            "payload": case["payload"]
        });
        let response: Value = serde_json::from_str(&execute_json(&request.to_string()))
            .expect("debug breakpoint-relocation response should be JSON");

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
