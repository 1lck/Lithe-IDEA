use crate::execute_json;
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
