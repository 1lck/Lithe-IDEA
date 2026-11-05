//! Verifies document path descriptors at the public navigation command boundary.

use lithe_core::execute_json;
use serde_json::{json, Value};

#[test]
fn navigation_commands_resolve_native_paths_before_decoding_requests() {
    let calls = [
        json!({"command":"java.navigationMarkers", "payload":{
            "sessionId":"missing-session", "uri":{"path":"/work/A#B.txt", "platform":"posix"}
        }}),
        json!({"command":"java.resolveNavigation", "payload":{
            "sessionId":"missing-session", "uri":{"path":"/work/A#B.txt", "platform":"posix"},
            "line":0, "utf16Column":0, "direction":"down", "relation":"interface"
        }}),
    ];
    for call in calls {
        let response: Value = serde_json::from_str(&execute_json(&call.to_string())).unwrap();
        assert_eq!(response["ok"], false);
        assert_eq!(
            response["error"]["message"],
            "Unknown language-server session."
        );
        assert_eq!(response["error"]["details"], "missing-session");
    }
}
