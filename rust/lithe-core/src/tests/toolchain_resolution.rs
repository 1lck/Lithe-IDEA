//! Exercises shared tool selection through production commands and inert native facts.

use crate::toolchain::{
    candidates_command, check_version_command, discovery_plan_command, failure_reply_command,
    resolve_command,
};
use serde_json::{json, Value};

const WORKSPACE: &str = "/opt/lithe-fixtures/workspace";
const HOME: &str = "/opt/lithe-fixtures/installs/java/21.0.4";
const OLD: &str = "/opt/lithe-fixtures/installs/java/17.0.12";

/// Reads review data as test inputs, never as an installed plugin or live path.
fn contract(name: &str) -> Value {
    let source = match name {
        "java" => include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/contracts/plugins/v1/fixtures/toolchains/tool-definition.plugin.json"
        )),
        "mise" => include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/contracts/plugins/v1/fixtures/toolchains/toolchain-provider.plugin.json"
        )),
        "query" => include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/contracts/plugins/v1/fixtures/toolchains/proposal/query-cases.json"
        )),
        "local" => include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/contracts/plugins/v1/fixtures/toolchains/proposal/local.json"
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
fn consumer_fixed_installation_precedes_directory_pins_without_granting_a_fallback() {
    let mut value = input();
    installation(&mut value, HOME, "21.0.4");
    installation(&mut value, OLD, "17.0.12");
    value["local"] = json!({"version":1,"toolchains":{},"pins":{".":{"java":{"home":HOME,"version":"21","provider":"host:manual"}}}});
    value["fixed"] = json!({"home":OLD});
    // Broken lower-layer answers have no authority over this explicit choice.
    value["queries"] = json!([{"invalid":"lower layer"}]);
    let selected = resolve(&value);
    assert_eq!(selected["outcome"]["selection"]["home"], OLD);
    assert_eq!(selected["trace"][0]["candidateID"], "consumerFixed");
    value["fixed"] = json!({"home":"/opt/lithe-fixtures/missing"});
    assert_eq!(resolve(&value)["outcome"]["kind"], "terminalFailure");
}

#[test]
fn consumer_fixed_executable_preserves_its_argv_identity_and_has_no_invented_home() {
    let mut value = input();
    let executable = "/opt/lithe-fixtures/custom tools/launcher";
    value["fixed"] = json!({"executable":executable});
    value["filesystem"]
        .as_array_mut()
        .unwrap()
        .push(fact(executable, "file", true));
    let candidates = candidates_command(value_for_candidates(&value)).unwrap();
    assert_eq!(candidates["status"], "ok", "{candidates}");
    assert!(candidates["candidates"]["skipped"]
        .as_array()
        .unwrap()
        .iter()
        .any(|value| value["reason"] == "probeFailed" && value["executable"] == executable));
    value["probes"] =
        json!([{"executable":executable,"output":"openjdk version \"21.0.4\"","exitCode":0}]);
    let result = resolve(&value);
    let selected = &result["outcome"]["selection"];
    assert_eq!(selected["executable"], executable);
    assert_eq!(selected["version"], "21.0.4");
    assert!(selected["home"].is_null());
    assert_eq!(
        selected["environment"],
        json!({"LITHE_JAVA_PATH":executable})
    );
    assert_eq!(selected["pathPrepend"], json!([]));
    value["minimumVersion"] = json!("23");
    assert_eq!(
        resolve(&value)["outcome"]["reason"]["code"],
        "versionUnsatisfied"
    );
}

fn value_for_candidates(value: &Value) -> Value {
    let mut result = json!({});
    for key in [
        "registry",
        "tool",
        "platform",
        "filesystemCaseSensitive",
        "workspaceRoot",
        "workspaceRoots",
        "filesystem",
        "minimumVersion",
        "probes",
        "systemInstallations",
        "environment",
        "fixed",
        "projectCodeAllowed",
    ] {
        if let Some(value) = value.get(key) {
            result[key] = value.clone();
        }
    }
    result
}

#[test]
fn consumer_fixed_project_files_require_the_current_action_before_any_version_probe() {
    for alias in [false, true] {
        let mut value = input();
        let inside = format!("{WORKSPACE}/scripts/launcher");
        let executable = if alias {
            "/opt/lithe-fixtures/alias"
        } else {
            &inside
        };
        value["fixed"] = json!({"executable":executable});
        value["filesystem"].as_array_mut().unwrap().push(
            json!({"path":executable,"canonicalPath":inside,"kind":"file","executable":true}),
        );
        let candidates = candidates_command(value_for_candidates(&value)).unwrap();
        assert_eq!(candidates["status"], "ok", "{candidates}");
        assert!(!candidates["candidates"]["skipped"]
            .as_array()
            .unwrap()
            .iter()
            .any(|row| row["executable"] == executable));
        assert_eq!(
            resolve(&value)["outcome"]["reason"]["code"],
            "projectCodeRequiresAction"
        );
        value["projectCodeAllowed"] = json!(true);
        value["probes"] =
            json!([{"executable":executable,"output":"openjdk version \"21.0.4\"","exitCode":0}]);
        assert_eq!(resolve(&value)["outcome"]["selection"]["projectCode"], true);
    }
}

#[test]
fn consumer_fixed_choices_reject_ambiguous_relative_and_authority_smuggling_fields() {
    for fixed in [
        Value::Null,
        json!({}),
        json!({"home":HOME,"executable":"/opt/tool"}),
        json!({"executable":"relative/tool"}),
        json!({"home":"/opt/../tool"}),
        json!({"executable":"/opt/tool","version":"21"}),
        json!({"home":HOME,"provider":"host:official"}),
    ] {
        let mut value = input();
        value["fixed"] = fixed.clone();
        assert_eq!(
            resolve_command(value.clone()).unwrap()["status"],
            "rejected",
            "{fixed}"
        );
        assert_eq!(
            candidates_command(value_for_candidates(&value)).unwrap()["status"],
            "rejected",
            "{fixed}"
        );
    }
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
fn toolchain_resolution_host_failure_reply_names_the_provider_and_its_cause() {
    let mut value = input();
    installation(&mut value, HOME, "21.0.4");
    value["commandHomes"]["java"] = json!(HOME);
    for code in [
        "plugin.toolchain.timeout",
        "plugin.toolchain.providerUnavailable",
    ] {
        let mut backend = query(&value);
        let reply =
            failure_reply_command(json!({"params":backend["request"]["params"],"code":code}))
                .unwrap();
        assert_eq!(reply["status"], "ok", "{reply}");
        backend["request"]["id"] = reply["reply"]["id"].clone();
        backend["response"] = reply["reply"]["response"].clone();
        value["queries"] = json!([backend]);
        let result = resolve(&value);
        assert_eq!(result["outcome"]["selection"]["provider"], "host:shell");
        assert_eq!(
            result["unmet"],
            json!([{"code":"providerUnavailable","tool":"java",
                "provider":"dev.lithe.fixture.mise:mise","cause":code}])
        );
        // A provider that was not asked about this tool leaves it nothing to report.
        backend["request"]["params"]["tools"] = json!(["node"]);
        value["queries"] = json!([backend]);
        assert_eq!(resolve(&value)["unmet"], json!([]));
    }
    let params = query(&value)["request"]["params"].clone();
    let mut nameless = params.clone();
    nameless["providerID"] = json!("");
    // Cancellation is not a provider that could not answer, and an identity is required.
    for input in [
        json!({"params":params,"code":"plugin.toolchain.cancelled"}),
        json!({"params":nameless,"code":"plugin.toolchain.timeout"}),
        json!({"params":params,"code":"plugin.toolchain.timeout","message":"extra"}),
    ] {
        let rejected = failure_reply_command(input).unwrap();
        assert_eq!(rejected["status"], "rejected");
        assert_eq!(rejected["error"]["code"], "plugin.toolchain.invalidParams");
    }
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
        ("toolchains.candidates", listing(&input()), "candidates"),
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
    assert_eq!(
        result["plan"]["tools"][0]["providers"],
        json!(["dev.lithe.fixture.mise:mise"])
    );
    value["registry"]["plugins"]
        .as_array_mut()
        .unwrap()
        .remove(0);
    let result =
        discovery_plan_command(json!({"registry":value["registry"],"platform":"macos"})).unwrap();
    assert_eq!(result["plan"]["tools"], json!([]));
}

#[test]
fn toolchain_discovery_plan_carries_path_entries_and_platform_home_variables() {
    let result =
        discovery_plan_command(json!({"registry":input()["registry"],"platform":"macos"})).unwrap();
    let tool = &result["plan"]["tools"][0];
    assert_eq!(tool["pathPrepend"], json!(["${home}/bin"]));
    assert_eq!(
        tool["environment"],
        json!([{"variable":"JAVA_HOME","path":"bin/java"}])
    );
    let result =
        discovery_plan_command(json!({"registry":input()["registry"],"platform":"windows"}))
            .unwrap();
    assert_eq!(
        result["plan"]["tools"][0]["environment"],
        json!([{"variable":"JAVA_HOME","path":"bin/java.exe"}])
    );
}

/// Narrows a resolver input to the settings listing's directory-free fields.
fn listing(input: &Value) -> Value {
    let mut value = json!({"tool":"java"});
    for key in [
        "registry",
        "platform",
        "workspaceRoot",
        "filesystem",
        "probes",
        "systemInstallations",
        "environment",
    ] {
        value[key] = input[key].clone();
    }
    if let Some(reported) = input.get("providerInstallations") {
        value["providerInstallations"] = reported.clone();
    }
    value
}

fn candidates(input: &Value) -> Value {
    let result = candidates_command(listing(input)).unwrap();
    assert_eq!(result["status"], "ok", "{result}");
    result["candidates"].clone()
}

#[test]
fn toolchain_candidates_return_probe_targets_before_versions_are_known() {
    let mut value = input();
    installation(&mut value, HOME, "21.0.4");
    installation(&mut value, OLD, "17.0.12");
    value["systemInstallations"] = json!([{"tool":"java","home":OLD},{"tool":"java","home":HOME},
        {"tool":"java","home":"/opt/lithe-fixtures/missing"}]);
    value["environment"]["JAVA_HOME"] = json!(OLD);
    value["probes"] = json!([]);
    let listed = candidates(&value);
    assert_eq!(listed["installations"], json!([]));
    assert_eq!(listed["selected"], Value::Null);
    let skipped = listed["skipped"].as_array().unwrap();
    assert_eq!(skipped.len(), 3);
    let probe_targets: Vec<_> = skipped
        .iter()
        .filter(|row| row["reason"] == "probeFailed")
        .map(|row| row["executable"].clone())
        .collect();
    assert_eq!(
        probe_targets,
        vec![
            json!(format!("{OLD}/bin/java")),
            json!(format!("{HOME}/bin/java"))
        ]
    );
    let missing = skipped
        .iter()
        .find(|row| row["reason"] == "unsafePath")
        .unwrap();
    assert!(missing.get("executable").is_none());
    assert_eq!(listed["shell"][0]["executable"], format!("{OLD}/bin/java"));
    assert_eq!(listed["shell"][0]["reason"], "probeFailed");
}

#[test]
fn toolchain_candidates_list_versions_and_share_the_resolver_choice() {
    let mut value = input();
    installation(&mut value, HOME, "21.0.4");
    installation(&mut value, OLD, "17.0.12");
    value["systemInstallations"] = json!([{"tool":"java","home":OLD},{"tool":"java","home":HOME}]);
    value["environment"]["JAVA_HOME"] = json!(OLD);
    let listed = candidates(&value);
    assert_eq!(
        listed["installations"],
        json!([
            {"home":HOME,"executable":format!("{HOME}/bin/java"),"version":"21.0.4","provider":"host:system"},
            {"home":OLD,"executable":format!("{OLD}/bin/java"),"version":"17.0.12","provider":"host:system"}
        ])
    );
    assert_eq!(listed["selected"], HOME);
    assert_eq!(listed["skipped"], json!([]));
    assert_eq!(
        listed["shell"],
        json!([{"candidateID":"home","variable":"JAVA_HOME","home":OLD,
            "executable":format!("{OLD}/bin/java"),"version":"17.0.12"}])
    );
    // The login shell wins in resolution; the listing still reports the automatic choice.
    assert_eq!(resolve(&value)["outcome"]["selection"]["home"], OLD);
    value["environment"] = json!({});
    assert_eq!(resolve(&value)["outcome"]["selection"]["home"], HOME);
}

#[test]
fn toolchain_candidates_keep_provider_attribution_and_count_one_home_once() {
    let mut value = input();
    self_provided(&mut value);
    installation(&mut value, HOME, "21.0.4");
    installation(&mut value, OLD, "17.0.12");
    let provider = "dev.lithe.fixture.java-support:installs";
    value["providerInstallations"] = json!([{"tool":"java","home":HOME,"provider":provider}]);
    value["systemInstallations"] = json!([{"tool":"java","home":HOME},{"tool":"java","home":OLD}]);
    let listed = candidates(&value);
    let installations = listed["installations"].as_array().unwrap();
    assert_eq!(installations.len(), 2);
    assert_eq!(installations[0]["home"], HOME);
    assert_eq!(installations[0]["provider"], provider);
    assert_eq!(installations[1]["provider"], "host:system");
    assert_eq!(listed["selected"], HOME);
}

#[test]
fn toolchain_candidates_refuse_a_provider_outside_the_registry() {
    let mut value = input();
    self_provided(&mut value);
    for provider in ["dev.example.other:installs", "installs", "host:system"] {
        value["providerInstallations"] = json!([{"tool":"java","home":HOME,"provider":provider}]);
        let result = candidates_command(listing(&value)).unwrap();
        assert_eq!(result["status"], "rejected", "{provider}");
    }
}

#[test]
fn toolchain_candidates_report_equal_versions_as_a_conflict() {
    let mut value = input();
    installation(&mut value, HOME, "21.0.4");
    installation(&mut value, OLD, "21.0.4");
    value["systemInstallations"] = json!([{"tool":"java","home":OLD},{"tool":"java","home":HOME}]);
    let listed = candidates(&value);
    assert_eq!(listed["selected"], Value::Null);
    assert_eq!(listed["conflicts"][0]["action"], "chooseInstallation");
    assert_eq!(listed["installations"].as_array().unwrap().len(), 2);
    let mut unknown = listing(&value);
    unknown["tool"] = json!("dev.lithe.fixture.java-support:missing");
    assert_eq!(candidates_command(unknown).unwrap()["status"], "rejected");
    let mut directory = listing(&value);
    directory["directory"] = json!(".");
    assert_eq!(candidates_command(directory).unwrap()["status"], "rejected");
}

/// Turns the definition plugin into its own installation-only provider, without scans.
fn self_provided(input: &mut Value) {
    let manifest = &mut input["registry"]["plugins"][0]["manifest"];
    manifest["toolDefinitions"][0]
        .as_object_mut()
        .unwrap()
        .remove("discovery");
    manifest["requires"] = json!({"toolDefinitions":1,"executableResolution":2,
        "toolchainProviders":1,"backend":2,"serverProcess":1});
    manifest["permissions"] = json!(["backend.launch", "toolchains.provide"]);
    manifest["toolchainProviders"] =
        json!([{"id":"installs","displayName":"Installed releases","tools":["java"]}]);
    manifest["backend"] = json!({"launch":{"kind":"packaged","path":"bin/installs"}});
    input["registry"]["plugins"]
        .as_array_mut()
        .unwrap()
        .truncate(1);
}

/// Captures an installation-only answer from the self-provider for `homes`.
fn installs_query(input: &Value, homes: &[(&str, &str)]) -> Value {
    let mut value = query(input);
    value["pluginID"] = json!("dev.lithe.fixture.java-support");
    value["request"]["params"]["providerID"] = json!("installs");
    let result = &mut value["response"]["result"];
    result["providerID"] = json!("installs");
    result["installations"] = json!(homes
        .iter()
        .map(|(home, version)| json!({"tool":"java","version":version,"home":home}))
        .collect::<Vec<_>>());
    result["statements"] = json!([]);
    result["watch"] = json!([]);
    value
}

/// A provider may name a version manager's alias link. The host reads only the paths the
/// reply and definition name, under the link; Core derives the canonical target facts.
#[test]
fn toolchain_resolution_accepts_a_provider_home_reached_through_an_alias_link() {
    let mut value = input();
    self_provided(&mut value);
    installation(&mut value, HOME, "21.0.4");
    let alias = "/opt/lithe-fixtures/installs/java/latest";
    let facts = value["filesystem"].as_array_mut().unwrap();
    facts.retain(|fact| !fact["path"].as_str().unwrap().starts_with(HOME));
    facts.push(json!({"path":alias,"canonicalPath":HOME,"kind":"directory"}));
    facts.push(json!({"path":format!("{alias}/bin"),"canonicalPath":format!("{HOME}/bin"),"kind":"directory"}));
    facts.push(
        json!({"path":format!("{alias}/bin/java"),"canonicalPath":format!("{HOME}/bin/java"),
        "kind":"file","executable":true}),
    );
    value["queries"] = json!([installs_query(&value, &[(alias, "21.0.4")])]);
    let result = resolve(&value);
    assert_eq!(result["outcome"]["selection"]["home"], HOME, "{result}");
    assert_eq!(
        result["outcome"]["selection"]["executable"],
        format!("{HOME}/bin/java")
    );
}

#[test]
fn toolchain_resolution_definition_plugin_can_be_its_own_installation_provider() {
    let mut value = input();
    self_provided(&mut value);
    installation(&mut value, HOME, "21.0.4");
    let plan =
        discovery_plan_command(json!({"registry":value["registry"],"platform":"macos"})).unwrap();
    assert_eq!(plan["plan"]["tools"][0]["scans"], json!([]));
    assert_eq!(
        plan["plan"]["tools"][0]["providers"],
        json!(["dev.lithe.fixture.java-support:installs"])
    );
    value["queries"] = json!([installs_query(&value, &[(HOME, "21.0.4")])]);
    let result = resolve(&value);
    assert_eq!(result["outcome"]["selection"]["home"], HOME);
    assert_eq!(result["outcome"]["selection"]["layer"], "automatic");
    assert_eq!(
        result["outcome"]["selection"]["provider"],
        "dev.lithe.fixture.java-support:installs"
    );
    // Without watched files no reader can anchor a requirement statement.
    value["filesystem"].as_array_mut().unwrap().push(fact(
        &format!("{WORKSPACE}/mise.toml"),
        "file",
        false,
    ));
    value["queries"][0]["filesystem"] = value["filesystem"].clone();
    value["queries"][0]["response"]["result"]["statements"] =
        query(&value)["response"]["result"]["statements"].clone();
    let rejected = resolve_command(value).unwrap();
    assert_eq!(rejected["status"], "rejected");
    assert_eq!(rejected["error"]["code"], "plugin.toolchain.invalidReply");
    assert_eq!(
        rejected["error"]["field"],
        "response.result.statements.reader"
    );
}

#[test]
fn toolchain_resolution_scan_and_provider_routes_merge_by_canonical_home() {
    let mut value = input();
    self_provided(&mut value);
    installation(&mut value, HOME, "21.0.4");
    installation(&mut value, OLD, "21.0.4");
    value["queries"] = json!([installs_query(&value, &[(HOME, "21.0.4")])]);
    value["systemInstallations"] = json!([{"tool":"java","home":HOME}]);
    let result = resolve(&value);
    assert_eq!(result["outcome"]["selection"]["home"], HOME);
    assert_eq!(
        result["outcome"]["selection"]["provider"],
        "dev.lithe.fixture.java-support:installs"
    );
    assert_eq!(result["conflicts"], json!([]));
    value["systemInstallations"] = json!([{"tool":"java","home":OLD},{"tool":"java","home":HOME}]);
    let result = resolve(&value);
    assert_eq!(result["outcome"]["kind"], "skip");
    assert_eq!(
        result["conflicts"][0]["providers"],
        json!(["dev.lithe.fixture.java-support:installs", "host:system"])
    );
    value["providerChoices"]["automatic"] = json!(OLD);
    let chosen = resolve(&value);
    assert_eq!(chosen["outcome"]["selection"]["home"], OLD);
    assert_eq!(chosen["outcome"]["selection"]["provider"], "host:system");
}

#[test]
fn toolchain_resolution_linked_provider_home_resolves_against_the_same_snapshot() {
    let mut value = input();
    self_provided(&mut value);
    let link = "/opt/lithe-fixtures/installs/java/latest";
    let alias = |path: &str, target: &str, kind: &str, executable: bool| json!({"path":path,"canonicalPath":target,"kind":kind,"executable":executable});
    // Only the link spellings are observed; the resolved target has no fact of its own.
    value["filesystem"].as_array_mut().unwrap().extend([
        alias(link, HOME, "directory", false),
        alias(
            &format!("{link}/bin"),
            &format!("{HOME}/bin"),
            "directory",
            false,
        ),
        alias(
            &format!("{link}/bin/java"),
            &format!("{HOME}/bin/java"),
            "file",
            true,
        ),
    ]);
    value["probes"] = json!([{"executable":format!("{HOME}/bin/java"),"output":"openjdk version \"21.0.4\"","exitCode":0}]);
    value["queries"] = json!([installs_query(&value, &[(link, "21.0.4")])]);
    let result = resolve(&value);
    let selection = &result["outcome"]["selection"];
    assert_eq!(selection["home"], HOME);
    assert_eq!(selection["executable"], format!("{HOME}/bin/java"));
    assert_eq!(selection["pathPrepend"], json!([format!("{HOME}/bin")]));
    // Facts that disagree about the resolved target are not reconciled.
    value["filesystem"]
        .as_array_mut()
        .unwrap()
        .push(fact(HOME, "file", false));
    value["queries"][0]["filesystem"] = value["filesystem"].clone();
    assert_eq!(resolve_command(value).unwrap()["status"], "rejected");
}

#[test]
fn toolchain_resolution_environment_candidate_uses_its_declared_layout() {
    let mut value = input();
    let definition = &mut value["registry"]["plugins"][0]["manifest"]["toolDefinitions"][0];
    definition["executableLayouts"]
        .as_array_mut()
        .unwrap()
        .push(json!({"path":"alt/bin/java","platforms":["macos","linux"]}));
    definition["executables"][4]["path"] = json!("alt/bin/java");
    installation(&mut value, HOME, "21.0.4");
    value["filesystem"].as_array_mut().unwrap().extend([
        fact(&format!("{HOME}/alt"), "directory", false),
        fact(&format!("{HOME}/alt/bin"), "directory", false),
        fact(&format!("{HOME}/alt/bin/java"), "file", true),
    ]);
    value["probes"].as_array_mut().unwrap().push(json!({"executable":format!("{HOME}/alt/bin/java"),"output":"openjdk version \"17.0.12\"","exitCode":0}));
    value["environment"]["JAVA_HOME"] = json!(HOME);
    let result = resolve(&value);
    let selection = &result["outcome"]["selection"];
    assert_eq!(selection["provider"], "host:shell");
    assert_eq!(selection["executable"], format!("{HOME}/alt/bin/java"));
    assert_eq!(selection["version"], "17.0.12");
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
