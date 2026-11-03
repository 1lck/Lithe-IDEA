//! The production package uses only the generic Core provider contract.
use lithe_core::execute_json;
use serde_json::{json, Value};

#[test]
fn official_manifest_is_accepted_and_plans_each_source() {
    let manifest: Value = serde_json::from_str(include_str!("../plugin.json")).unwrap();
    let request = json!({"id":"manifest", "command":"plugins.declarative.validate", "payload": {
        "manifest":manifest, "hostCapabilities": {
            "backend":[1,2], "serverProcess":[1], "packageTrust":[1], "keymapImportProviders":[1]
        }
    }});
    let response: Value = serde_json::from_str(&execute_json(&request.to_string())).unwrap();
    assert_eq!(response["ok"], true, "{response}");
    assert_eq!(response["data"]["status"], "ok", "{response}");
    for provider in ["vscode", "idea"] {
        let request = json!({"id":"plan", "command":"keymap.planImportSources", "payload": {
            "manifest":manifest, "providerID":provider
        }});
        let plan: Value = serde_json::from_str(&execute_json(&request.to_string())).unwrap();
        assert_eq!(plan["ok"], true, "{plan}");
        assert!(!plan["data"]["recognition"].as_array().unwrap().is_empty());
        assert!(!plan["data"]["inputs"].as_array().unwrap().is_empty());
    }
}
