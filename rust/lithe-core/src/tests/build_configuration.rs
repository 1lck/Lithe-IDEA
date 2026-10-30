//! Native configuration protocol and deterministic host-only XML edit boundary.

use crate::build::{
    build_configuration_plan_command, build_decode_configuration_command,
    build_edit_configuration_document_command,
};
use crate::plugins::declarative::validate_command;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

fn manifest() -> Value {
    serde_json::from_str(include_str!(
        "../../../../shared/contracts/plugins/v1/fixtures/build-provider-configuration.plugin.json"
    ))
    .unwrap()
}

fn snapshot(document: Option<&str>) -> Value {
    let mut snapshot: Value = serde_json::from_str(include_str!(
        "../../../../shared/contracts/plugins/v1/fixtures/build-configuration.json"
    ))
    .unwrap();
    snapshot["sources"][0]["rootElement"]["namespace"] = json!("");
    snapshot["sources"][0]["revision"] = json!(document
        .map(|text| format!("sha256:{:x}", Sha256::digest(text.as_bytes())))
        .unwrap_or("missing".into()));
    snapshot
}

fn call(command: fn(Value) -> Result<Value, crate::protocol::CoreError>, request: Value) -> Value {
    let manifest = manifest();
    let id = manifest["buildSystems"][0]["id"].clone();
    command(json!({"manifest":manifest,"buildSystemID":id,"request":request})).unwrap()
}

fn edit(document: Option<&str>, mut snapshot: Value, values: Value) -> Value {
    let revision = snapshot["sources"][0]["revision"].clone();
    // This field's source value is distinct from the inherited display value.
    if document.is_some() {
        snapshot["sources"][0]["fields"][0]["value"] = json!("/old");
    }
    call(
        build_edit_configuration_document_command,
        json!({"snapshot":snapshot,
        "edits":{"sourceID":"user","revision":revision,"values":values},"document":document}),
    )
}

#[test]
fn native_configuration_requires_capability_seven_and_preserves_option_arguments() {
    let planned = call(
        build_configuration_plan_command,
        json!({"root":".","options":{"offline":true},"tool":{"executable":"/fixture/mvn"}}),
    );
    assert_eq!(planned["status"], "ok", "{planned}");
    assert_eq!(
        planned["plan"]["provider"]["method"],
        "lithe/build/configuration"
    );
    assert_eq!(
        planned["plan"]["provider"]["params"]["tool"]["executable"],
        "/fixture/mvn"
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
fn native_configuration_rejects_sensitive_or_overlapping_bindings_and_unsafe_sources() {
    let valid = snapshot(None);
    assert_eq!(
        call(build_decode_configuration_command, json!({"result":valid}))["status"],
        "ok"
    );
    for variant in [
        "credentials",
        "duplicate",
        "overlap",
        "uri",
        "revision",
        "installation",
        "kind",
    ] {
        let mut value = valid.clone();
        match variant {
            "credentials" => {
                value["sources"][0]["fields"][0]["path"] = json!(["servers", "password"])
            }
            "duplicate" => {
                let field = value["sources"][0]["fields"][0].clone();
                value["sources"][0]["fields"]
                    .as_array_mut()
                    .unwrap()
                    .push(field);
            }
            "overlap" => {
                value["sources"][0]["fields"][1]["path"] = json!(["localRepository", "nested"])
            }
            "uri" => {
                value["sources"][0]["uri"] = json!("https://user:secret@example.test/settings.xml")
            }
            "revision" => value["sources"][0]["revision"] = json!("unversioned"),
            "installation" => value["sources"][0]["scope"] = json!("installation"),
            "kind" => value["sources"][0]["fields"][0]["value"] = json!(true),
            _ => unreachable!(),
        }
        let decoded = call(build_decode_configuration_command, json!({"result":value}));
        assert_eq!(decoded["status"], "rejected", "{variant}: {decoded}");
    }
}

#[test]
fn native_configuration_allows_exact_read_only_scope_aliases_without_making_installation_writable()
{
    let mut value = snapshot(None);
    value["sources"][0]["writable"] = json!(false);
    let mut installation = value["sources"][0].clone();
    installation["id"] = json!("installation");
    installation["scope"] = json!("installation");
    value["sources"].as_array_mut().unwrap().push(installation);
    assert_eq!(
        call(build_decode_configuration_command, json!({"result": value}))["status"],
        "ok"
    );
    for writable in [0, 1] {
        let mut unsafe_alias = value.clone();
        unsafe_alias["sources"][writable]["writable"] = json!(true);
        assert_eq!(
            call(
                build_decode_configuration_command,
                json!({"result": unsafe_alias})
            )["status"],
            "rejected"
        );
    }
    value["sources"][1]["revision"] =
        json!("sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    assert_eq!(
        call(build_decode_configuration_command, json!({"result": value}))["status"],
        "rejected"
    );
}

#[test]
fn native_xml_edits_preserve_credentials_comments_and_unrelated_bytes() {
    let original = "<?xml version='1.0'?><settings><!--keep--><localRepository><!--note--><![CDATA[/old]]></localRepository><servers><server><password>fixture-secret-sentinel</password></server></servers><mirrors enabled='yes'/></settings>";
    let snapshot = snapshot(Some(original));
    assert!(!snapshot.to_string().contains("fixture-secret-sentinel"));
    let result = edit(
        Some(original),
        snapshot,
        json!({"localRepository":"/new & <repository>"}),
    );
    assert_eq!(result["status"], "ok", "{result}");
    let changed = result["edit"]["document"].as_str().unwrap();
    assert!(changed.contains("<!--note-->/new &amp; &lt;repository&gt;"));
    assert!(changed.contains(
        "<servers><server><password>fixture-secret-sentinel</password></server></servers>"
    ));
    assert!(changed.contains("<!--keep-->"));
    assert!(changed.contains("<mirrors enabled='yes'/>"));
}

#[test]
fn native_xml_list_edits_keep_comments_and_ignore_foreign_namespaces() {
    let original = "<s:settings xmlns:s='urn:test' xmlns:x='urn:foreign'><x:localRepository>/foreign</x:localRepository><s:activeProfiles><!--keep--><s:activeProfile>ci</s:activeProfile><s:activeProfile>old</s:activeProfile></s:activeProfiles></s:settings>";
    let mut snapshot = snapshot(Some(original));
    snapshot["sources"][0]["rootElement"]["namespace"] = json!("urn:test");
    let result = edit(
        Some(original),
        snapshot,
        json!({"activeProfiles":["new","a&b"],"localRepository":"/new"}),
    );
    assert_eq!(result["status"], "ok", "{result}");
    let changed = result["edit"]["document"].as_str().unwrap();
    assert!(changed.contains("<x:localRepository>/foreign</x:localRepository>"));
    assert!(changed.contains("<s:localRepository>/new</s:localRepository>"));
    assert!(changed.contains("<!--keep--><s:activeProfile>new</s:activeProfile><s:activeProfile>a&amp;b</s:activeProfile>"));
    assert!(!changed.contains(">old<"));
}

#[test]
fn native_xml_missing_and_empty_elements_expand_without_losing_their_attributes() {
    for original in [
        "<settings/>",
        "<settings><localRepository marker='keep'/></settings>",
    ] {
        let result = edit(
            Some(original),
            snapshot(Some(original)),
            json!({"localRepository":"/new"}),
        );
        assert_eq!(result["status"], "ok", "{result}");
        let changed = result["edit"]["document"].as_str().unwrap();
        assert!(changed.contains(">/new</localRepository>"));
        if original.contains("marker") {
            assert!(changed.contains("marker='keep'"));
        }
    }
    let result = edit(None, snapshot(None), json!({"localRepository":"/new"}));
    assert_eq!(result["status"], "ok", "{result}");
    assert!(result["edit"]["document"]
        .as_str()
        .unwrap()
        .contains("<settings><localRepository>/new</localRepository></settings>"));
}

#[test]
fn native_xml_reset_removes_the_override_and_unchanged_drafts_create_nothing() {
    let original =
        "<settings><localRepository>/old</localRepository><!--keep--><servers/></settings>";
    let result = edit(
        Some(original),
        snapshot(Some(original)),
        json!({"localRepository":null}),
    );
    assert_eq!(
        result["edit"]["document"],
        "<settings><!--keep--><servers/></settings>"
    );
    let result = edit(None, snapshot(None), json!({}));
    assert_eq!(result["edit"]["document"], Value::Null);
    assert_eq!(result["edit"]["changed"], false);
}

#[test]
fn native_xml_conflicts_and_invalid_structures_never_produce_replacement_bytes() {
    let stale = snapshot(Some("<settings/>"));
    let result = edit(
        Some("<settings><!--external--></settings>"),
        stale,
        json!({"localRepository":"/new"}),
    );
    assert_eq!(
        result["error"]["code"],
        "plugin.build.configurationConflict"
    );
    for original in ["<!DOCTYPE settings [<!ENTITY bad SYSTEM 'file:///fixture/secret'>]><settings/>",
        "<settings><localRepository>a</localRepository><localRepository>b</localRepository></settings>",
        "<settings>", "garbage<settings/>", "<foreign/>", "<?xml version='1.0' encoding='UTF-16'?><settings/>"] {
        let result = edit(Some(original), snapshot(Some(original)), json!({"localRepository":"/new"}));
        assert_eq!(result["status"], "rejected", "{original}: {result}");
        assert!(result.get("edit").is_none());
    }
}
