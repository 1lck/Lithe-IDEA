//! Format-independent native facts, edit plans and bounded receipt validation.

use crate::build::{
    build_configuration_edit_plan_command, build_configuration_plan_command,
    build_decode_configuration_command, build_decode_configuration_edit_command,
};
use crate::plugins::declarative::validate_command;
use serde_json::{json, Value};

fn manifest() -> Value {
    serde_json::from_str(include_str!(
        "../../../../shared/contracts/plugins/v1/fixtures/build-providers/build-provider-configuration.plugin.json"
    ))
    .unwrap()
}
fn snapshot() -> Value {
    let mut value: Value = serde_json::from_str(include_str!(
        "../../../../shared/contracts/plugins/v1/fixtures/build-providers/build-configuration.json"
    ))
    .unwrap();
    if cfg!(windows) {
        value["sources"][0]["uri"] = json!("file:///C:/fixture/user/settings.xml");
    }
    value
}
fn native_fixture_path(path: &str) -> String {
    if cfg!(windows) {
        format!("C:{path}")
    } else {
        path.into()
    }
}
fn call(command: fn(Value) -> Result<Value, crate::protocol::CoreError>, request: Value) -> Value {
    let manifest = manifest();
    let id = manifest["buildSystems"][0]["id"].clone();
    command(json!({"manifest":manifest,"buildSystemID":id,"request":request})).unwrap()
}
fn edit_request() -> Value {
    json!({"root":".", "workspaceStateDirectory":native_fixture_path("/fixture/state"), "outputFile":native_fixture_path("/fixture/state/outputs/edit.json"),
        "snapshot":snapshot(), "edits":{"sourceID":"user", "revision":snapshot()["sources"][0]["revision"],
            "values":{"localRepository":"/new"}}})
}

#[test]
fn native_configuration_requires_capability_seven_and_preserves_option_arguments() {
    let executable = if cfg!(windows) {
        "C:/fixture/mvn.cmd"
    } else {
        "/fixture/mvn"
    };
    let plan = call(
        build_configuration_plan_command,
        json!({"root":".","options":{"offline":true},"tool":{"executable":executable}}),
    );
    assert_eq!(plan["status"], "ok", "{plan}");
    assert_eq!(
        plan["plan"]["provider"]["method"],
        "lithe/build/configuration"
    );
    assert_eq!(
        plan["plan"]["provider"]["params"]["tool"]["executable"],
        executable
    );
    assert_eq!(
        call(
            build_configuration_plan_command,
            json!({"root":".","tool":{"executable":"relative/mvn"}})
        )["status"],
        "rejected"
    );
    for version in 1..7 {
        let mut old = manifest();
        old["requires"]["buildProviders"] = json!(version);
        assert_eq!(
            validate_command(json!({"manifest":old})).unwrap()["status"],
            "rejected"
        );
    }
}

#[test]
fn native_configuration_rejects_sensitive_duplicate_and_unsafe_sources() {
    assert_eq!(
        call(
            build_decode_configuration_command,
            json!({"result":snapshot()})
        )["status"],
        "ok"
    );
    for variant in [
        "credentials",
        "duplicate",
        "uri",
        "revision",
        "installation",
        "kind",
        "xmlBinding",
    ] {
        let mut value = snapshot();
        let source = &mut value["sources"][0];
        match variant {
            "credentials" => source["fields"][0]["id"] = json!("password"),
            "duplicate" => {
                let field = source["fields"][0].clone();
                source["fields"].as_array_mut().unwrap().push(field);
            }
            "uri" => source["uri"] = json!("https://example.invalid/settings.json"),
            "revision" => source["revision"] = json!("unknown"),
            "installation" => source["scope"] = json!("installation"),
            "kind" => source["fields"][0]["kind"] = json!("password"),
            "xmlBinding" => source["rootElement"] = json!({"name":"settings","namespace":""}),
            _ => unreachable!(),
        }
        assert_eq!(
            call(build_decode_configuration_command, json!({"result":value}))["status"],
            "rejected",
            "{variant}"
        );
    }
}

#[test]
fn native_configuration_allows_exact_read_only_aliases_but_no_editable_alias() {
    let mut value = snapshot();
    value["sources"][0]["writable"] = json!(false);
    let mut second = value["sources"][0].clone();
    second["id"] = json!("installation");
    second["scope"] = json!("installation");
    value["sources"].as_array_mut().unwrap().push(second);
    assert_eq!(
        call(build_decode_configuration_command, json!({"result":value}))["status"],
        "ok"
    );
    value["sources"][0]["writable"] = json!(true);
    assert_eq!(
        call(build_decode_configuration_command, json!({"result":value}))["status"],
        "rejected"
    );
}

#[test]
fn native_editing_passes_opaque_fields_and_private_staging_without_document_bytes() {
    let mut request = edit_request();
    request["snapshot"]["sources"][0]["uri"] = json!("file:///fixture/config.json");
    request["snapshot"]["sources"][0]["fields"][0]["id"] = json!("cacheLocation");
    request["edits"]["values"] = json!({"cacheLocation":"/new"});
    let result = call(build_configuration_edit_plan_command, request);
    assert_eq!(result["status"], "ok", "{result}");
    assert_eq!(
        result["plan"]["provider"]["method"],
        "lithe/build/editConfiguration"
    );
    let params = &result["plan"]["provider"]["params"];
    assert_eq!(
        params["outputFile"],
        native_fixture_path("/fixture/state/outputs/edit.json")
    );
    assert_eq!(params["edits"]["values"], json!({"cacheLocation":"/new"}));
    for key in ["document", "rootElement", "path", "itemElement"] {
        assert!(!params.to_string().contains(&format!("\"{key}\":")));
    }
}

#[test]
fn native_editing_rejects_stale_unknown_read_only_and_escaping_requests() {
    for variant in [
        "stale",
        "unknown",
        "readonly",
        "type",
        "escape",
        "sameSource",
        "noState",
        "relativeOutput",
    ] {
        let mut request = edit_request();
        match variant {
            "stale" => request["edits"]["revision"] = json!("missing"),
            "unknown" => request["edits"]["values"] = json!({"unavailable":true}),
            "readonly" => request["snapshot"]["sources"][0]["writable"] = json!(false),
            "type" => request["edits"]["values"]["localRepository"] = json!(true),
            "escape" => {
                request["outputFile"] =
                    json!(native_fixture_path("/fixture/state/../settings.json"))
            }
            "sameSource" => {
                request["workspaceStateDirectory"] = json!(native_fixture_path("/fixture"));
                request["outputFile"] = json!(native_fixture_path("/fixture/user/settings.xml"));
            }
            "noState" => {
                request
                    .as_object_mut()
                    .unwrap()
                    .remove("workspaceStateDirectory");
            }
            "relativeOutput" => request["outputFile"] = json!("state/outputs/edit.json"),
            _ => unreachable!(),
        }
        assert_eq!(
            call(build_configuration_edit_plan_command, request)["status"],
            "rejected",
            "{variant}"
        );
    }
}

#[test]
fn native_edit_receipt_is_bound_to_confirmed_source_and_contains_no_document() {
    let request = edit_request();
    let receipt = json!({"format":"litheConfigurationEdit","version":1,"sourceID":"user", "revision":format!("sha256:{}", "b".repeat(64)),"changed":true});
    let payload = |result: Value| json!({"snapshot":request["snapshot"],"edits":request["edits"],"result":result});
    assert_eq!(
        call(
            build_decode_configuration_edit_command,
            payload(receipt.clone())
        )["status"],
        "ok"
    );
    for (field, value) in [
        ("sourceID", json!("installation")),
        ("revision", json!("missing")),
        ("document", json!("private")),
        ("format", json!("xml")),
        ("changed", json!(false)),
    ] {
        let mut invalid = receipt.clone();
        invalid[field] = value;
        assert_eq!(
            call(build_decode_configuration_edit_command, payload(invalid))["status"],
            "rejected"
        );
    }
    let unchanged = json!({"format":"litheConfigurationEdit","version":1,"sourceID":"user","revision":request["edits"]["revision"],"changed":false});
    assert_eq!(
        call(build_decode_configuration_edit_command, payload(unchanged))["status"],
        "ok"
    );
}
