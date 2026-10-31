//! Pure query validation with inert native filesystem facts and cross-platform paths.

use crate::toolchain::{paths, query};
use serde_json::{json, Value};

const HOME: &str = "/opt/lithe-fixtures/installs/java/21.0.4";
const WORKSPACE: &str = "/opt/lithe-fixtures/workspace";

fn contract(name: &str) -> Value {
    let source = match name {
        "java" => include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/contracts/plugins/v1/fixtures/tool-definition.plugin.json"
        )),
        "mise" => include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/contracts/plugins/v1/fixtures/toolchain-provider.plugin.json"
        )),
        "queries" => include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/contracts/plugins/v1/proposals/toolchains/fixtures/query-cases.json"
        )),
        _ => panic!("unknown contract fixture"),
    };
    serde_json::from_str(source).unwrap()
}

fn manifest(fragment: &Value) -> Value {
    fragment.clone()
}

fn fact(path: &str, kind: &str, executable: bool) -> Value {
    json!({"path":path,"canonicalPath":path,"kind":kind,"executable":executable})
}

fn input() -> Value {
    let fixture = contract("queries");
    json!({"registry":{"plugins":[{"manifest":manifest(&contract("java")),"verifiedOfficial":true},{"manifest":manifest(&contract("mise")),"verifiedOfficial":false}]},
        "pluginID":"dev.lithe.fixture.mise","request":fixture["cases"][0]["request"],"response":fixture["cases"][0]["response"],"currentGeneration":1,"platform":"macos",
        "filesystem":[fact(WORKSPACE,"directory",false),fact(HOME,"directory",false),fact(&format!("{HOME}/bin/java"),"file",true),fact(&format!("{WORKSPACE}/mise.toml"),"file",false)]})
}

#[test]
fn toolchain_queries_decode_installed_contract_reply_without_native_io() {
    let outcome = query::decode(&input()).unwrap();
    assert_eq!(outcome["installations"][0]["home"], HOME);
    assert_eq!(
        outcome["installations"][0]["executable"],
        format!("{HOME}/bin/java")
    );
    assert_eq!(
        outcome["installations"][0]["provider"],
        "dev.lithe.fixture.mise:mise"
    );
    assert_eq!(outcome["statements"][0]["request"], "21");
    assert_eq!(outcome["diagnostics"], json!([]));
}

#[test]
fn toolchain_queries_uninstalled_request_is_structured_unmet_data() {
    let mut value = input();
    value["response"]["result"]["installations"] = json!([]);
    value["response"]["result"]["statements"][0]["installation"] = Value::Null;
    value["response"]["result"]["statements"][0]["request"] = json!("99");
    let outcome = query::decode(&value).unwrap();
    assert_eq!(outcome["diagnostics"][0]["code"], "requestedNotInstalled");
    assert_eq!(outcome["diagnostics"][0]["request"], "99");
    assert!(outcome["statements"][0]["installation"].is_null());
}

#[test]
fn toolchain_queries_unknown_definitions_retain_no_path_or_execution_authority() {
    let mut value = input();
    value["registry"]["plugins"]
        .as_array_mut()
        .unwrap()
        .remove(0);
    value["response"]["result"]["installations"][0]["home"] = json!("unusable-relative-home");
    value["response"]["result"]["statements"][0]["installation"] = json!("unusable-relative-home");
    let outcome = query::decode(&value).unwrap();
    assert_eq!(outcome["installations"], json!([]));
    assert_eq!(outcome["statements"], json!([]));
    assert_eq!(outcome["diagnostics"][0]["code"], "definitionUnavailable");
    assert!(outcome["diagnostics"][0].get("installation").is_none());
    assert!(outcome["diagnostics"][0].get("home").is_none());
}

#[test]
fn toolchain_queries_filter_unsolicited_tools_before_native_path_validation() {
    let mut value = input();
    value["response"]["result"]["installations"]
        .as_array_mut()
        .unwrap()
        .push(json!({"tool":"git","version":"1","home":"unusable-relative-home"}));
    value["response"]["result"]["statements"].as_array_mut().unwrap().push(json!({"tool":"git","scope":"project","source":"unusable-relative-source","request":"1","installation":null,"kind":"declaration","reader":"native"}));
    assert_eq!(
        query::decode(&value).unwrap()["installations"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn toolchain_queries_refuse_workspace_homes_and_canonical_symlink_targets() {
    for target in [format!("{WORKSPACE}/vendor/jdk"), WORKSPACE.to_owned()] {
        let mut value = input();
        value["filesystem"][1]["canonicalPath"] = json!(target);
        assert_eq!(
            query::decode(&value).unwrap_err().code(),
            "plugin.toolchain.unsafePath"
        );
    }
    let mut value = input();
    value["filesystem"][2]["canonicalPath"] = json!(format!("{WORKSPACE}/malicious-java"));
    assert_eq!(
        query::decode(&value).unwrap_err().code(),
        "plugin.toolchain.unsafePath"
    );
}

#[test]
fn toolchain_queries_require_executable_and_same_tool_installation_reference() {
    let mut value = input();
    value["filesystem"][2]["executable"] = json!(false);
    assert_eq!(
        query::decode(&value).unwrap_err().code(),
        "plugin.toolchain.unsafePath"
    );
    value = input();
    value["response"]["result"]["statements"][0]["installation"] =
        json!("/opt/lithe-fixtures/unlisted");
    assert_eq!(
        query::decode(&value).unwrap_err().code(),
        "plugin.toolchain.invalidReply"
    );
}

#[test]
fn toolchain_queries_deduplicate_identical_source_facts_but_reject_conflicting_choices() {
    let mut value = input();
    let duplicate = value["response"]["result"]["statements"][0].clone();
    value["response"]["result"]["statements"] = json!([duplicate.clone(), duplicate]);
    assert_eq!(
        query::decode(&value).unwrap()["statements"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    for (field, conflicting) in [("request", json!("17")), ("installation", Value::Null)] {
        let mut conflict = value.clone();
        conflict["response"]["result"]["statements"][1][field] = conflicting;
        assert_eq!(
            query::decode(&conflict).unwrap_err().code(),
            "plugin.toolchain.invalidReply",
            "{field}"
        );
    }
}

#[test]
fn toolchain_queries_refuse_mismatched_rpc_and_operation_generations() {
    for path in ["operationID", "providerID", "generation"] {
        let mut value = input();
        value["response"]["result"][path] = if path == "generation" {
            json!(2)
        } else {
            json!("other")
        };
        assert_eq!(
            query::decode(&value).unwrap_err().code(),
            "plugin.toolchain.operationExpired"
        );
    }
    let mut value = input();
    value["response"]["id"] = json!(2);
    assert_eq!(
        query::decode(&value).unwrap_err().code(),
        "plugin.toolchain.invalidReply"
    );
    value = input();
    value["request"]["params"]["workspace"] = Value::Null;
    value["request"]["params"]["context"] = Value::Null;
    value["currentGeneration"] = json!(2);
    assert_eq!(
        query::decode(&value).unwrap_err().code(),
        "plugin.toolchain.operationExpired"
    );
}

#[test]
fn toolchain_queries_keep_every_error_mapping_unique_and_validate_the_pair() {
    let mut numbers = std::collections::BTreeSet::new();
    for response in contract("queries")["errorResponses"].as_array().unwrap() {
        let mut value = input();
        let mut response = response.clone();
        response["id"] = value["request"]["id"].clone();
        response["error"]["data"]["operationID"] =
            value["request"]["params"]["operationID"].clone();
        value["response"] = response;
        let error = query::decode(&value).unwrap_err();
        assert_eq!(
            Some(error.code()),
            value["response"]["error"]["data"]["code"].as_str()
        );
        let number = query::rpc_code(error.code()).unwrap();
        assert!(numbers.insert(number));
        value["response"]["error"]["code"] = json!(-1);
        assert_eq!(
            query::decode(&value).unwrap_err().code(),
            "plugin.toolchain.invalidReply"
        );
    }
}

#[test]
fn toolchain_queries_validate_declared_reader_and_project_ancestor() {
    let mut value = input();
    value["response"]["result"]["statements"][0]["reader"] = json!("compatible");
    assert_eq!(
        query::decode(&value).unwrap_err().code(),
        "plugin.toolchain.invalidReply"
    );
    value = input();
    value["filesystem"].as_array_mut().unwrap().push(fact(
        "/opt/lithe-fixtures/sibling/mise.toml",
        "file",
        false,
    ));
    value["response"]["result"]["statements"][0]["source"] =
        json!("/opt/lithe-fixtures/sibling/mise.toml");
    assert_eq!(
        query::decode(&value).unwrap_err().code(),
        "plugin.toolchain.unsafePath"
    );
    value = input();
    value["request"]["params"]["workspace"] = Value::Null;
    value["request"]["params"]["context"] = Value::Null;
    assert_eq!(
        query::decode(&value).unwrap_err().code(),
        "plugin.toolchain.invalidReply"
    );
}

#[test]
fn toolchain_queries_nested_source_pattern_uses_declared_anchor_not_parent() {
    let mut value = input();
    let source = format!("{WORKSPACE}/.mise/config.toml");
    value["filesystem"]
        .as_array_mut()
        .unwrap()
        .push(fact(&source, "file", false));
    value["response"]["result"]["statements"][0]["source"] = json!(source);
    let result = query::decode(&value).unwrap();
    assert_eq!(result["statements"][0]["sourceDirectory"], WORKSPACE);
}

#[test]
fn toolchain_queries_reject_unknown_fields_missing_null_and_duplicate_identities() {
    let mut value = input();
    value["request"]["params"]["arbitrary"] = json!(true);
    assert_eq!(
        query::decode(&value).unwrap_err().code(),
        "plugin.toolchain.invalidParams"
    );
    value = input();
    value["response"]["result"]["statements"][0]
        .as_object_mut()
        .unwrap()
        .remove("installation");
    assert_eq!(
        query::decode(&value).unwrap_err().code(),
        "plugin.toolchain.invalidReply"
    );
    value = input();
    value["request"]["params"]["tools"] = json!(["java", "java"]);
    assert_eq!(
        query::decode(&value).unwrap_err().code(),
        "plugin.toolchain.invalidParams"
    );
    value = input();
    let duplicate = value["filesystem"][0].clone();
    value["filesystem"].as_array_mut().unwrap().push(duplicate);
    assert_eq!(
        query::decode(&value).unwrap_err().code(),
        "plugin.toolchain.invalidParams"
    );
}

#[test]
fn toolchain_queries_refuse_remote_authority_without_local_fallback() {
    let mut value = input();
    value["request"]["params"]["authority"] = json!({"kind":"remote","id":"ssh-1"});
    assert_eq!(
        query::decode(&value).unwrap_err().code(),
        "plugin.toolchain.authorityUnsupported"
    );
}

#[test]
fn toolchain_queries_keep_missing_watch_inputs_and_enforce_reply_limits() {
    let mut value = input();
    value["response"]["result"]["watch"] = json!(["/opt/lithe-fixtures/missing.toml"]);
    assert_eq!(
        query::decode(&value).unwrap()["watch"],
        value["response"]["result"]["watch"]
    );
    value["response"]["result"]["watch"] = json!(vec!["/opt/lithe-fixtures/missing.toml"; 257]);
    assert_eq!(
        query::decode(&value).unwrap_err().code(),
        "plugin.toolchain.limitExceeded"
    );
}

#[test]
fn toolchain_queries_apply_windows_drive_unc_and_case_rules_without_host_paths() {
    assert!(paths::path_within(
        r"C:\Workspace\bin\java.exe",
        "c:/workspace",
        "windows"
    ));
    assert!(!paths::path_within(
        r"C:\WorkspaceOther\java.exe",
        "c:/workspace",
        "windows"
    ));
    assert!(paths::path_within(
        r"\\server\share\workspace\java.exe",
        "//SERVER/share/workspace",
        "windows"
    ));
    for path in [
        r"C:relative",
        r"C:\root\..\jdk",
        r"\\?\C:\jdk",
        r"C:\jdk\java.exe:stream",
    ] {
        assert!(paths::normalize(path, "windows", false).is_none(), "{path}");
    }
    assert!(!paths::within("C:/Work/java", "C:/work", "windows", true));
    let definition = contract("java")["toolDefinitions"][0].clone();
    let filesystem = vec![
        fact("C:/Tools/Jdk", "directory", false),
        fact("C:/Tools/Jdk/bin/java.exe", "file", true),
        fact("C:/Workspace", "directory", false),
    ];
    let selected = query::validate_installation(
        "c:/tools/jdk",
        &definition,
        &filesystem,
        &["C:/Workspace".to_owned()],
        "windows",
        false,
    )
    .unwrap();
    assert_eq!(selected["executable"], "C:/Tools/Jdk/bin/java.exe");
}
