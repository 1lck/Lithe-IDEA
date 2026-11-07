//! Native Build document storage syntax shared by macOS and Windows.

use crate::build::project_options_command;
use serde_json::{json, Value};

#[test]
fn local_option_edits_check_declarations_preserve_siblings_and_reset_to_team_values() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/build-project-options/local-edits.json"
    ))
    .unwrap();
    let mut manifest: Value = serde_json::from_str(include_str!(
        "../../../../shared/contracts/plugins/v1/fixtures/build-systems/build-instance-options.plugin.json"
    ))
    .unwrap();
    // Exercise a workspace option with model-owned choices as well as the
    // fixture's instance-scoped scalars; the storage rules do not depend on the tool.
    manifest["buildSystems"][0]["options"][1]["scope"] = json!("workspace");
    let edit = |local: &Value, root: &str, id: &str, value: Value, model: Value| {
        crate::build::build_edit_stored_option_command(json!({"manifest":manifest,"buildSystemID":"cargo","request":{
            "document":fixture["team"],"local":local,"root":root,"optionID":id,"value":value,"modelValues":model
        }})).unwrap()
    };
    for case in fixture["cases"].as_array().unwrap() {
        let result = edit(
            &fixture["emptyLocal"],
            case["root"].as_str().unwrap(),
            case["optionID"].as_str().unwrap(),
            case["value"].clone(),
            case["modelValues"].clone(),
        );
        assert_eq!(
            result["status"] == "ok",
            case["valid"].as_bool().unwrap(),
            "{}: {result}",
            case["name"]
        );
        if result["status"] == "ok" {
            let local = &result["edit"]["local"];
            let merged = crate::build::resolve_stored_options_command(
                json!({"document":fixture["team"],"local":local}),
            )
            .unwrap();
            assert_eq!(
                merged["storage"]["document"]["systems"]["dormant"]["options"]["label"],
                "keep"
            );
            assert_eq!(
                merged["storage"]["document"]["systems"]["cargo"]["instances"]["other"]["label"],
                "team other"
            );
            assert_eq!(
                merged["storage"]["document"]["systems"]["cargo"]["savedChoices"]["features"],
                json!(["remembered"])
            );
        }
    }
    let empty = edit(
        &fixture["emptyLocal"],
        "app",
        "features",
        json!([]),
        json!({"features":["alpha"]}),
    );
    let local = &empty["edit"]["local"];
    assert_eq!(
        local["document"]["systems"]["cargo"]["options"]["features"],
        json!(["beta"])
    );
    assert_eq!(
        local["emptySelections"]["cargo"]["app"],
        json!(["features"])
    );
    assert_eq!(
        empty["edit"]["options"]["options"]
            .as_array()
            .unwrap()
            .iter()
            .find(|o| o["id"] == "features")
            .unwrap()["value"],
        json!([])
    );
    let reset = edit(
        local,
        "app",
        "features",
        Value::Null,
        json!({"features":["alpha"]}),
    );
    assert_eq!(reset["edit"]["local"]["emptySelections"], json!({}));
    assert!(
        reset["edit"]["local"]["document"]["systems"]["cargo"]["options"]
            .get("features")
            .is_none()
    );
    let selected = edit(
        &fixture["emptyLocal"],
        "app",
        "release",
        json!(false),
        json!({}),
    );
    let reset = edit(
        &selected["edit"]["local"],
        "app",
        "release",
        Value::Null,
        json!({}),
    );
    assert_eq!(
        reset["edit"]["options"]["options"]
            .as_array()
            .unwrap()
            .iter()
            .find(|o| o["id"] == "release")
            .unwrap()["value"],
        true
    );
    let unchanged = edit(
        &fixture["emptyLocal"],
        "app",
        "release",
        Value::Null,
        json!({}),
    );
    assert_eq!(unchanged["edit"]["local"], fixture["emptyLocal"]);
}

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
