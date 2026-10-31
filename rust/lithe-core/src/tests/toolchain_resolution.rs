//! Exercises shared tool selection through production commands and inert native facts.

use crate::toolchain::{check_version_command, discovery_plan_command, resolve_command};
use serde_json::{json, Value};

const WORKSPACE: &str = "/opt/lithe-fixtures/workspace";
const HOME: &str = "/opt/lithe-fixtures/installs/java/21.0.4";
const OLD: &str = "/opt/lithe-fixtures/installs/java/17.0.12";

/// Reads review data as test inputs, never as an installed plugin or live path.
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
        "query" => include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/contracts/plugins/v1/proposals/toolchains/fixtures/query-cases.json"
        )),
        "local" => include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/contracts/plugins/v1/proposals/toolchains/fixtures/local.json"
        )),
        _ => panic!("unknown fixture"),
    };
    serde_json::from_str(source).unwrap()
}

/// Retains the complete production manifest used by the shared contract fixture.
fn manifest(fragment: &Value) -> Value {
    fragment.clone()
}

/// Records only host-observed filesystem metadata; no native file is created.
fn fact(path: &str, kind: &str, executable: bool) -> Value {
    json!({"path":path,"canonicalPath":path,"kind":kind,"executable":executable})
}

/// Starts with a verified definition and provider but no selected installation.
fn input() -> Value {
    json!({"registry":{"plugins":[{"manifest":manifest(&contract("java")),"verifiedOfficial":true},{"manifest":manifest(&contract("mise")),"verifiedOfficial":false}]},
        "operationID":"resolve-1","generation":1,"context":{"contextID":"context-1","generation":1},"tool":"java","directory":".","platform":"macos","workspaceRoot":WORKSPACE,
        "filesystem":[fact(WORKSPACE,"directory",false)],"probes":[],"queries":[],"systemInstallations":[],"environment":{},"commandHomes":{}})
}

/// Adds a usable installation and its bounded version-probe result.
fn installation(input: &mut Value, home: &str, version: &str) {
    let facts = input["filesystem"].as_array_mut().unwrap();
    facts.extend([
        fact(home, "directory", false),
        fact(&format!("{home}/bin"), "directory", false),
        fact(&format!("{home}/bin/java"), "file", true),
    ]);
    input["probes"].as_array_mut().unwrap().push(json!({"executable":format!("{home}/bin/java"),"output":format!("openjdk version \"{version}\""),"exitCode":0}));
}

/// Resolves through the exported command envelope, preserving rejection diagnostics.
fn resolve(input: &Value) -> Value {
    let result = resolve_command(input.clone()).unwrap();
    assert_eq!(result["status"], "ok", "{result}");
    result["resolution"].clone()
}

/// Captures a fake backend exchange that the resolver must decode itself.
fn query(input: &Value) -> Value {
    let case = &contract("query")["cases"][0];
    json!({"registry":input["registry"],"pluginID":"dev.lithe.fixture.mise","request":case["request"],"response":case["response"],
        "currentGeneration":1,"platform":"macos","filesystem":input["filesystem"]})
}

#[test]
fn toolchain_resolution_pins_inherit_nearest_ancestor_without_sibling_prefixes() {
    let mut value = input();
    let manual = "/opt/lithe-fixtures/manual/java/17.0.12";
    installation(&mut value, HOME, "21.0.4");
    installation(&mut value, manual, "17.0.12");
    value["local"] = contract("local");
    value["directory"] = json!("apps/web/src");
    let result = resolve(&value);
    assert_eq!(result["outcome"]["selection"]["home"], manual);
    assert_eq!(result["outcome"]["selection"]["layer"], "pinned");
    assert_eq!(
        result["outcome"]["selection"]["environment"]["JAVA_HOME"],
        manual
    );
    value["directory"] = json!("apps/website");
    assert_eq!(resolve(&value)["outcome"]["selection"]["home"], HOME);
}

#[test]
fn toolchain_resolution_invalid_pin_stops_otherwise_usable_fallback() {
    let mut value = input();
    installation(&mut value, HOME, "21.0.4");
    value["local"] = json!({"version":1,"toolchains":{},"pins":{".":{"java":{"home":"/opt/lithe-fixtures/missing","version":"99","provider":"host:manual"}}}});
    value["commandHomes"]["java"] = json!(HOME);
    let result = resolve(&value);
    assert_eq!(result["outcome"]["kind"], "terminalFailure");
    assert!(result["outcome"].get("selection").is_none());
    assert!(result["trace"]
        .as_array()
        .unwrap()
        .iter()
        .skip(1)
        .all(|row| row["state"] == "shadowed"));
}

#[test]
fn toolchain_resolution_valid_pin_does_not_depend_on_provider_availability() {
    let mut value = input();
    installation(&mut value, HOME, "21.0.4");
    value["local"] = json!({"version":1,"toolchains":{},"pins":{".":{"java":{"home":HOME,"version":"21.0.4","provider":"host:manual"}}}});
    // A selected pin does not require querying, decoding or probing lower layers.
    value["queries"] = json!([{"response":{"error":{"code":-32072}}}]);
    let result = resolve(&value);
    assert_eq!(result["outcome"]["selection"]["home"], HOME);
    assert_eq!(result["outcome"]["selection"]["layer"], "pinned");
}

#[test]
fn toolchain_resolution_optional_provider_timeout_keeps_shell_fallback_visible() {
    let mut value = input();
    installation(&mut value, HOME, "21.0.4");
    value["commandHomes"]["java"] = json!(HOME);
    let mut backend = query(&value);
    backend["response"] = json!({"jsonrpc":"2.0","id":backend["request"]["id"],"error":{"code":-32072,"message":"Fixture timeout.","data":{"code":"plugin.toolchain.timeout","operationID":backend["request"]["params"]["operationID"],"providerID":"mise"}}});
    value["queries"] = json!([backend]);
    let result = resolve(&value);
    assert_eq!(result["outcome"]["selection"]["provider"], "host:shell");
    assert_eq!(result["unmet"][0]["code"], "providerUnavailable");
}

#[test]
fn toolchain_resolution_uninstalled_project_requirement_survives_shell_fallback() {
    let mut value = input();
    installation(&mut value, HOME, "21.0.4");
    value["filesystem"].as_array_mut().unwrap().push(fact(
        &format!("{WORKSPACE}/mise.toml"),
        "file",
        false,
    ));
    value["commandHomes"]["java"] = json!(HOME);
    let mut backend = query(&value);
    backend["response"]["result"]["installations"] = json!([]);
    backend["response"]["result"]["statements"][0]["installation"] = Value::Null;
    backend["response"]["result"]["statements"][0]["request"] = json!("99");
    value["queries"] = json!([backend]);
    let result = resolve(&value);
    assert_eq!(result["outcome"]["selection"]["home"], HOME);
    assert_eq!(result["outcome"]["selection"]["layer"], "global");
    assert!(result["unmet"]
        .as_array()
        .unwrap()
        .iter()
        .any(|reason| reason["code"] == "requestedNotInstalled" && reason["request"] == "99"));
}

#[test]
fn toolchain_resolution_provider_reply_goes_through_real_decoder() {
    let mut value = input();
    installation(&mut value, HOME, "21.0.4");
    value["filesystem"].as_array_mut().unwrap().push(fact(
        &format!("{WORKSPACE}/mise.toml"),
        "file",
        false,
    ));
    value["queries"] = json!([query(&value)]);
    let result = resolve(&value);
    assert_eq!(result["outcome"]["selection"]["home"], HOME);
    assert_eq!(result["outcome"]["selection"]["layer"], "project");
    assert_eq!(
        result["outcome"]["selection"]["provider"],
        "dev.lithe.fixture.mise:mise"
    );
    value["queries"][0]["response"]["result"]["operationID"] = json!("expired-query");
    let rejected = resolve_command(value).unwrap();
    assert_eq!(rejected["status"], "rejected");
    assert_eq!(
        rejected["error"]["code"],
        "plugin.toolchain.operationExpired"
    );
}

#[test]
fn toolchain_resolution_query_cannot_replace_outer_generation_or_context_policy() {
    let mut value = input();
    installation(&mut value, HOME, "21.0.4");
    value["filesystem"].as_array_mut().unwrap().push(fact(
        &format!("{WORKSPACE}/mise.toml"),
        "file",
        false,
    ));
    value["queries"] = json!([query(&value)]);
    value["generation"] = json!(2);
    let rejected = resolve_command(value.clone()).unwrap();
    assert_eq!(rejected["status"], "rejected");
    assert_eq!(rejected["error"]["code"], "plugin.toolchain.invalidParams");
    value["generation"] = json!(1);
    value["context"]["contextID"] = json!("replacement-context");
    let rejected = resolve_command(value).unwrap();
    assert_eq!(rejected["status"], "rejected");
    assert_eq!(rejected["error"]["code"], "plugin.toolchain.invalidParams");
}

#[test]
fn toolchain_resolution_conflicting_global_providers_follow_shell_not_plugin_id() {
    let mut value = input();
    installation(&mut value, HOME, "21.0.4");
    installation(&mut value, OLD, "17.0.12");
    let mut second = manifest(&contract("mise"));
    second["id"] = json!("dev.lithe.fixture.alternative");
    value["registry"]["plugins"]
        .as_array_mut()
        .unwrap()
        .push(json!({"manifest":second,"verifiedOfficial":false}));
    for source in [
        "/opt/lithe-fixtures/global/mise.toml",
        "/opt/lithe-fixtures/alternative/mise.toml",
    ] {
        value["filesystem"]
            .as_array_mut()
            .unwrap()
            .push(fact(source, "file", false));
    }
    let mut first = query(&value);
    first["response"]["result"]["statements"][0]["scope"] = json!("global");
    first["response"]["result"]["statements"][0]["source"] =
        json!("/opt/lithe-fixtures/global/mise.toml");
    let mut second = first.clone();
    second["pluginID"] = json!("dev.lithe.fixture.alternative");
    second["response"]["result"]["installations"][0]["home"] = json!(OLD);
    second["response"]["result"]["statements"][0]["installation"] = json!(OLD);
    second["response"]["result"]["statements"][0]["source"] =
        json!("/opt/lithe-fixtures/alternative/mise.toml");
    value["queries"] = json!([first, second]);
    value["commandHomes"]["java"] = json!(HOME);
    let result = resolve(&value);
    assert_eq!(result["outcome"]["selection"]["provider"], "host:shell");
    assert_eq!(result["conflicts"][0]["scope"], "global");
    assert_eq!(result["conflicts"][0]["action"], "chooseProvider");
    value["providerChoices"]["global"] = json!("dev.lithe.fixture.alternative:mise");
    let chosen = resolve(&value);
    assert_eq!(chosen["outcome"]["selection"]["home"], OLD);
    assert_eq!(chosen["conflicts"], json!([]));
}

#[test]
fn toolchain_commands_cross_the_json_dispatch_boundary() {
    for (command, payload, key) in [
        (
            "toolchains.registry",
            input()["registry"].clone(),
            "registry",
        ),
        (
            "toolchains.resolvePins",
            json!({"document":contract("local"),"directory":"apps/web/src","tool":"java"}),
            "resolution",
        ),
        (
            "toolchains.checkVersion",
            json!({"registry":input()["registry"],"tool":"java","output":"openjdk version \"21.0.4\""}),
            "version",
        ),
        (
            "toolchains.discoveryPlan",
            json!({"registry":input()["registry"],"platform":"macos"}),
            "plan",
        ),
        ("toolchains.resolve", input(), "resolution"),
    ] {
        let response: Value = serde_json::from_str(&crate::execute_json(
            &json!({"id":"toolchains","command":command,"payload":payload}).to_string(),
        ))
        .unwrap();
        assert_eq!(response["ok"], true, "{response}");
        assert_eq!(response["data"]["status"], "ok", "{response}");
        assert!(response["data"].get(key).is_some(), "{response}");
    }
}

#[test]
fn toolchain_resolution_automatic_uses_numeric_probe_not_display_order() {
    let mut value = input();
    installation(&mut value, HOME, "21.0.4");
    installation(&mut value, OLD, "9.0.99");
    value["systemInstallations"] = json!([{"tool":"java","home":OLD},{"tool":"java","home":HOME}]);
    let result = resolve(&value);
    assert_eq!(result["outcome"]["selection"]["home"], HOME);
    assert_eq!(result["outcome"]["selection"]["layer"], "automatic");
    value["minimumVersion"] = json!("22");
    assert_eq!(resolve(&value)["outcome"]["kind"], "skip");
}

#[test]
fn toolchain_resolution_equal_versions_are_ambiguous_and_manual_facts_not_automatic() {
    let mut value = input();
    installation(&mut value, HOME, "21.0.4");
    installation(&mut value, OLD, "21.0.4");
    assert_eq!(resolve(&value)["outcome"]["kind"], "skip");
    value["systemInstallations"] = json!([{"tool":"java","home":OLD},{"tool":"java","home":HOME}]);
    let result = resolve(&value);
    assert_eq!(result["outcome"]["kind"], "skip");
    assert_eq!(result["conflicts"][0]["scope"], "automatic");
    assert_eq!(result["conflicts"][0]["action"], "chooseInstallation");
    assert_eq!(
        result["conflicts"][0]["installations"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
}

#[test]
fn toolchain_resolution_version_capture_is_definition_driven_for_java8_and_custom_tool() {
    let value = input();
    let checked=check_version_command(json!({"registry":value["registry"],"tool":"java","output":"java version \"1.8.0_422\"","minimumVersion":"8"})).unwrap();
    assert_eq!(checked["status"], "ok", "{checked}");
    assert_eq!(checked["version"]["version"], "8.0");
    assert_eq!(checked["version"]["satisfied"], true);
    let mut registry = value["registry"].clone();
    registry["plugins"].as_array_mut().unwrap().truncate(1);
    let definition = &mut registry["plugins"][0]["manifest"]["toolDefinitions"][0];
    definition["id"] = json!("dev.lithe.fixture.java-support:renderer");
    definition["version"]["pattern"] = json!("release=([0-9]+(?:\\.[0-9]+)*)");
    let checked=check_version_command(json!({"registry":registry,"tool":"dev.lithe.fixture.java-support:renderer","output":"render release=10.2","minimumVersion":"9.99"})).unwrap();
    assert_eq!(checked["status"], "ok", "{checked}");
    assert_eq!(checked["version"]["version"], "10.2");
    assert_eq!(checked["version"]["satisfied"], true);
}

#[test]
fn toolchain_resolution_discovery_comes_only_from_enabled_definition_data() {
    let mut value = input();
    let scans = json!([{"root":{"kind":"home"},"pattern":"runtimes/*.fixture","platforms":["macos"]},{"root":{"kind":"home"},"pattern":"other/*.fixture","platforms":["windows"]}]);
    value["registry"]["plugins"][0]["manifest"]["toolDefinitions"][0]["discovery"] = scans.clone();
    let result =
        discovery_plan_command(json!({"registry":value["registry"],"platform":"macos"})).unwrap();
    assert_eq!(result["status"], "ok", "{result}");
    assert_eq!(result["plan"]["tools"][0]["scans"], json!([scans[0]]));
    value["registry"]["plugins"]
        .as_array_mut()
        .unwrap()
        .remove(0);
    let result =
        discovery_plan_command(json!({"registry":value["registry"],"platform":"macos"})).unwrap();
    assert_eq!(result["plan"]["tools"], json!([]));
}

#[test]
fn toolchain_resolution_disabled_definition_cannot_reactivate_a_saved_pin() {
    let mut value = input();
    installation(&mut value, HOME, "21.0.4");
    value["local"] = contract("local");
    value["registry"]["plugins"]
        .as_array_mut()
        .unwrap()
        .remove(0);
    value["commandHomes"]["java"] = json!(HOME);
    let before = value["local"].clone();
    let result = resolve(&value);
    assert_eq!(result["outcome"]["kind"], "skip");
    assert_eq!(result["outcome"]["reason"]["code"], "definitionUnavailable");
    assert!(result["outcome"].get("selection").is_none());
    assert_eq!(value["local"], before);
}

#[test]
fn toolchain_resolution_nearest_unmet_project_source_masks_parent_requirement() {
    let mut value = input();
    installation(&mut value, HOME, "21.0.4");
    installation(&mut value, OLD, "17.0.12");
    value["directory"] = json!("apps/web");
    for (path, kind) in [
        (format!("{WORKSPACE}/apps/web"), "directory"),
        (format!("{WORKSPACE}/apps/web/mise.toml"), "file"),
        (format!("{WORKSPACE}/mise.toml"), "file"),
    ] {
        value["filesystem"]
            .as_array_mut()
            .unwrap()
            .push(fact(&path, kind, false));
    }
    let mut backend = query(&value);
    backend["request"]["params"]["workspace"]["directory"] = json!("apps/web");
    backend["response"]["result"]["statements"][0]["installation"] = json!(OLD);
    backend["response"]["result"]["installations"][0]["home"] = json!(OLD);
    backend["response"]["result"]["statements"]
        .as_array_mut()
        .unwrap()
        .push(json!({"tool":"java","scope":"project","source":format!("{WORKSPACE}/apps/web/mise.toml"),
            "request":"99","installation":null,"kind":"declaration","reader":"native"}));
    value["queries"] = json!([backend]);
    value["commandHomes"]["java"] = json!(HOME);
    let result = resolve(&value);
    assert_eq!(result["outcome"]["selection"]["home"], HOME);
    assert_eq!(result["outcome"]["selection"]["layer"], "global");
    assert!(result["unmet"]
        .as_array()
        .unwrap()
        .iter()
        .any(|reason| reason["request"] == "99"));
}

#[test]
fn toolchain_resolution_definition_cannot_omit_away_an_explicit_invalid_pin() {
    let mut value = input();
    value["registry"]["plugins"][0]["manifest"]["toolDefinitions"][0]["executables"]
        .as_array_mut()
        .unwrap()
        .remove(0);
    installation(&mut value, HOME, "21.0.4");
    value["local"] = json!({"version":1,"toolchains":{},"pins":{".":{"java":{
        "home":"/opt/lithe-fixtures/unavailable","version":"99","provider":"host:manual"}}}});
    value["commandHomes"]["java"] = json!(HOME);
    let result = resolve(&value);
    assert_eq!(result["outcome"]["kind"], "terminalFailure");
    assert!(result["outcome"].get("selection").is_none());
}

#[test]
fn toolchain_resolution_wrapper_requires_action_and_never_invents_installation_home() {
    let mut value = input();
    let definition = &mut value["registry"]["plugins"][0]["manifest"]["toolDefinitions"][0];
    definition["wrappers"] = json!([{"path":"fixture-wrapper","platforms":["macos"]}]);
    definition["executables"].as_array_mut().unwrap().insert(
        1,
        json!({"id":"wrapper","kind":"projectFile","path":"fixture-wrapper","platforms":["macos"]}),
    );
    let wrapper = format!("{WORKSPACE}/fixture-wrapper");
    value["filesystem"]
        .as_array_mut()
        .unwrap()
        .push(fact(&wrapper, "file", true));
    let blocked = resolve(&value);
    assert_eq!(blocked["outcome"]["kind"], "skip");
    assert!(blocked["trace"]
        .as_array()
        .unwrap()
        .iter()
        .any(|row| row["reason"]["code"] == "projectCodeRequiresAction"));
    // No probe observation is supplied: passive resolution cannot require running it.
    assert_eq!(value["probes"], json!([]));
    value["projectCodeAllowed"] = json!(true);
    let allowed = resolve(&value);
    let selection = &allowed["outcome"]["selection"];
    assert_eq!(allowed["outcome"]["kind"], "resolved");
    assert_eq!(selection["home"], Value::Null);
    assert_eq!(selection["version"], Value::Null);
    assert_eq!(selection["projectCode"], true);
    assert!(selection["environment"].get("JAVA_HOME").is_none());
    assert_eq!(selection["environment"]["LITHE_JAVA_PATH"], wrapper);
    assert_eq!(selection["pathPrepend"], json!([]));
}

#[test]
fn toolchain_resolution_project_environment_home_cannot_symlink_out_of_workspace() {
    let mut value = input();
    let definition = &mut value["registry"]["plugins"][0]["manifest"]["toolDefinitions"][0];
    definition["executables"].as_array_mut().unwrap().insert(
        1,
        json!({"id":"project-env","kind":"projectFile","projectKind":"environment","home":".venv","path":".venv/bin/java","platforms":["macos","linux"]}),
    );
    let home = format!("{WORKSPACE}/.venv");
    let executable = format!("{home}/bin/java");
    value["filesystem"].as_array_mut().unwrap().extend([
        json!({"path":home,"canonicalPath":"/opt/lithe-fixtures/outside-environment","kind":"directory","executable":false}),
        fact(&executable,"file",true),
    ]);
    value["projectCodeAllowed"] = json!(true);
    let result = resolve(&value);
    assert_eq!(result["outcome"]["kind"], "skip");
    assert!(result["outcome"].get("selection").is_none());
    assert!(result["trace"]
        .as_array()
        .unwrap()
        .iter()
        .any(|row| row["reason"]["code"] == "unsafePath"));
}
