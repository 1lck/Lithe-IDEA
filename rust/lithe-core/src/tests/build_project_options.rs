//! Native Build document storage syntax shared by macOS and Windows.

use crate::build::project_options_command;
use serde_json::{json, Value};

#[test]
fn native_build_options_validate_the_shared_cases_without_dropping_custom_values() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/build-project-options/validation.json"
    ))
    .unwrap();
    for case in fixture["cases"].as_array().unwrap() {
        let original = case["document"].clone();
        let result = project_options_command(json!({"document":original})).unwrap();
        assert_eq!(
            result["status"] == "ok",
            case["valid"].as_bool().unwrap(),
            "{}: {result}",
            case["name"]
        );
        if result["status"] == "ok" {
            assert_eq!(
                result["document"]["systems"],
                project_options_command(json!({"document":result["document"]})).unwrap()
                    ["document"]["systems"]
            );
        }
        assert_eq!(case["document"], original);
    }
    let defaults: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/build-project-options/shared-defaults.json"
    ))
    .unwrap();
    let result = project_options_command(json!({"document":defaults})).unwrap();
    assert_eq!(
        result["document"]["systems"]["maven"]["savedChoices"]["profiles"],
        json!(["ci", "manual"])
    );
    assert_eq!(
        result["document"]["systems"]["maven"]["instances"]["services/a"]["offline"],
        true
    );
}

#[test]
fn native_build_options_preserve_the_existing_document_bounds() {
    for document in [
        json!({"version":1,"systems":(0..33).map(|i|(format!("tool-{i}"),json!({}))).collect::<serde_json::Map<_,_>>()}),
        json!({"version":1,"systems":{"tool":{"options":(0..257).map(|i|(format!("option-{i}"),json!(true))).collect::<serde_json::Map<_,_>>()}}}),
        json!({"version":1,"systems":{"tool":{"instances":(0..257).map(|i|(format!("root-{i}"),json!({}))).collect::<serde_json::Map<_,_>>()}}}),
        json!({"version":1,"systems":{"tool":{"options":{"text":"x".repeat(2*1024*1024)}}}}),
    ] {
        let result = project_options_command(json!({"document":document})).unwrap();
        assert_eq!(
            result["error"]["code"],
            "plugin.build.invalidOptionsDocument"
        );
    }
}
