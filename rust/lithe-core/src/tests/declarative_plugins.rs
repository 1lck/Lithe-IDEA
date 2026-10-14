use crate::plugins::declarative::{
    check_runtime_version_command, discover_tests_command, language_server_launch_plan_command,
    run_plan_command, test_plan_command, validate_command,
};
use serde_json::{json, Value};

macro_rules! contract_file {
    ($path:literal) => {
        include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/contracts/plugins/v1/",
            $path
        ))
    };
}

const PHP_FIXTURE: &str = contract_file!("fixtures/php-support.plugin.json");
const GO_FIXTURE: &str = contract_file!("fixtures/go-support.plugin.json");
const JAVA_FIXTURE: &str = contract_file!("fixtures/java-support.plugin.json");
const NODE_RUNTIME_FIXTURE: &str = contract_file!("fixtures/node-runtime.plugin.json");
const INVALID_MANIFESTS: &str = contract_file!("fixtures/invalid-manifests.json");
const COMMAND_PLANS: &str = contract_file!("fixtures/command-plans.json");
const RUNTIME_VERSIONS: &str = contract_file!("fixtures/runtime-versions.json");
const OFFICIAL_PHP: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../Plugins/mac/Official/PhpSupport/plugin.json"
));
const OFFICIAL_GO: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../Plugins/mac/Official/GoSupport/plugin.json"
));
const OFFICIAL_JAVA: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../Plugins/mac/Official/JavaSupport/plugin.json"
));

fn fixture(name: &str) -> Value {
    let source = match name {
        "php-support.plugin.json" => PHP_FIXTURE,
        "go-support.plugin.json" => GO_FIXTURE,
        "java-support.plugin.json" => JAVA_FIXTURE,
        "node-runtime.plugin.json" => NODE_RUNTIME_FIXTURE,
        other => panic!("unknown fixture {other}"),
    };
    serde_json::from_str(source).expect("fixture manifest is JSON")
}

fn validate(manifest: Value) -> Value {
    validate_command(json!({ "manifest": manifest })).expect("payload is well formed")
}

#[test]
fn contract_fixtures_and_official_plugins_validate() {
    for source in [
        PHP_FIXTURE,
        GO_FIXTURE,
        JAVA_FIXTURE,
        NODE_RUNTIME_FIXTURE,
        OFFICIAL_PHP,
        OFFICIAL_GO,
        OFFICIAL_JAVA,
    ] {
        let outcome = validate(serde_json::from_str(source).unwrap());
        assert_eq!(outcome["status"], "ok", "{outcome}");
    }
}

#[test]
fn validation_normalizes_order_and_spelling_without_touching_arguments() {
    let mut manifest = fixture("php-support.plugin.json");
    manifest["languages"][0]["fileExtensions"] = json!(["PHTML", ".php", "php"]);
    manifest["permissions"] = json!(["process.test", "process.run", "languageServer.launch"]);
    let outcome = validate(manifest);
    let plugin = &outcome["plugin"];
    assert_eq!(
        plugin["languages"][0]["fileExtensions"],
        json!(["php", "phtml"])
    );
    assert_eq!(
        plugin["permissions"],
        json!(["languageServer.launch", "process.run", "process.test"])
    );
    // Argument order is the command line and must survive normalization.
    assert_eq!(
        plugin["executionProviders"][0]["run"]["arguments"],
        json!(["${file}", "${userArguments}"])
    );
}

/// A leading `.` is optional notation only for extensions. In complete file
/// names and project markers it is part of the name, so hidden files such as
/// `.toolrc` keep matching after normalization.
#[test]
fn validation_keeps_the_leading_dot_of_hidden_file_names() {
    let mut manifest = fixture("go-support.plugin.json");
    manifest["languages"][0]["fileExtensions"] = json!([".go"]);
    manifest["languages"][0]["fileNames"] = json!([".toolrc"]);
    manifest["languages"][0]["projectFileNames"] = json!(["go.mod", ".env.example"]);
    manifest["executionProviders"][0]["test"]["projectMarkers"] = json!([".toolrc", "go.mod"]);
    let outcome = validate(manifest);
    assert_eq!(outcome["status"], "ok", "{outcome}");
    let language = &outcome["plugin"]["languages"][0];
    assert_eq!(language["fileExtensions"], json!(["go"]));
    assert_eq!(language["fileNames"], json!([".toolrc"]));
    assert_eq!(
        language["projectFileNames"],
        json!([".env.example", "go.mod"])
    );
    assert_eq!(
        outcome["plugin"]["executionProviders"][0]["test"]["projectMarkers"],
        json!([".toolrc", "go.mod"])
    );
}

/// Every host must reject these manifests with the same stable code, so a
/// package refused on one platform is never accepted by the other.
#[test]
fn invalid_manifest_fixtures_report_their_stable_codes() {
    let fixtures: Value = serde_json::from_str(INVALID_MANIFESTS).unwrap();
    for case in fixtures["cases"].as_array().unwrap() {
        let mut manifest = fixture(case["base"].as_str().unwrap());
        for edit in case["edits"].as_array().unwrap() {
            apply_edit(&mut manifest, edit);
        }
        let outcome = validate(manifest);
        assert_eq!(outcome["status"], "rejected", "{}: {outcome}", case["name"]);
        assert_eq!(
            outcome["error"]["code"], case["expectedCode"],
            "{}: {outcome}",
            case["name"]
        );
    }
}

/// A plugin that owns a language keeps the host from running anything for it
/// by default. The integration's capabilities are how the plugin hands a
/// feature back to the host's own implementation, so each one must be a
/// feature that integration has, with its files, and with no second owner.
#[test]
fn host_integration_capabilities_are_normalized_and_checked_against_the_integration() {
    let mut manifest = fixture("java-support.plugin.json");
    let capabilities = "/languageServers/0/hostIntegration/capabilities";
    *manifest.pointer_mut(capabilities).unwrap() = json!(["testing", "debug", "testing"]);
    let outcome = validate(manifest.clone());
    assert_eq!(outcome["status"], "ok", "{outcome}");
    assert_eq!(
        outcome["plugin"].pointer(capabilities),
        Some(&json!(["debug", "testing"]))
    );

    // Omitting the list is valid and claims nothing.
    manifest["languageServers"][0]["hostIntegration"]
        .as_object_mut()
        .unwrap()
        .remove("capabilities");
    let outcome = validate(manifest.clone());
    assert_eq!(outcome["status"], "ok", "{outcome}");
    assert_eq!(outcome["plugin"].pointer(capabilities), None);

    let rejected_field = |manifest: Value| {
        let outcome = validate(manifest);
        assert_eq!(outcome["error"]["code"], "plugin.manifest.invalid", "{outcome}");
        outcome["error"]["field"].as_str().unwrap().to_string()
    };
    let field = "languageServers[0].hostIntegration.capabilities";

    let mut unknown = fixture("java-support.plugin.json");
    *unknown.pointer_mut(capabilities).unwrap() = json!(["formatting"]);
    assert_eq!(rejected_field(unknown), field);

    // Debugging loads the debugger as a JDT LS extension bundle.
    let mut without_bundles = fixture("java-support.plugin.json");
    *without_bundles.pointer_mut(capabilities).unwrap() = json!(["debug"]);
    let resources = "/languageServers/0/hostIntegration/resources";
    let resources = without_bundles.pointer_mut(resources).unwrap();
    resources
        .as_object_mut()
        .unwrap()
        .remove("extensionBundleDirectories");
    assert_eq!(rejected_field(without_bundles), field);

    let mut owned_twice = fixture("java-support.plugin.json");
    owned_twice["permissions"] = json!(["languageServer.launch", "process.run"]);
    owned_twice["activationEvents"] = json!(["onLanguage:java", "onRun:java"]);
    owned_twice["executionProviders"] = json!([{
        "languageID": "java",
        "run": { "executable": { "command": "java" }, "arguments": ["${file}"] }
    }]);
    // The same provider is accepted once the integration stops claiming run.
    let mut owned_once = owned_twice.clone();
    *owned_once.pointer_mut(capabilities).unwrap() = json!(["debug", "testing"]);
    assert_eq!(validate(owned_once)["status"], "ok");
    assert_eq!(rejected_field(owned_twice), field);
}

#[test]
fn command_plan_fixtures_match_golden_expansions() {
    let fixtures: Value = serde_json::from_str(COMMAND_PLANS).unwrap();
    for case in fixtures["cases"].as_array().unwrap() {
        let payload = json!({
            "manifest": fixture(case["plugin"].as_str().unwrap()),
            "languageID": case["languageID"],
            "request": case["request"],
        });
        let outcome = match case["operation"].as_str().unwrap() {
            "runPlan" => run_plan_command(payload),
            "discoverTests" => discover_tests_command(payload),
            "testPlan" => test_plan_command(payload),
            "languageServerLaunchPlan" => language_server_launch_plan_command(payload),
            other => panic!("unknown operation {other}"),
        }
        .expect("payload is well formed");
        let expected = &case["expected"];
        if expected["status"] == "rejected" {
            assert_eq!(outcome["status"], "rejected", "{}: {outcome}", case["name"]);
            assert_eq!(
                outcome["error"]["code"], expected["code"],
                "{}: {outcome}",
                case["name"]
            );
        } else {
            assert_eq!(&outcome, expected, "{}", case["name"]);
        }
    }
}

/// Packages that already ship declare API level 1, where `${...}` in a
/// language-server argument is literal text. Expanding or rejecting it there
/// would change the command line of an installed plugin.
#[test]
fn api_level_1_language_server_arguments_stay_literal() {
    let mut manifest = fixture("php-support.plugin.json");
    manifest["languageServers"][0]["arguments"] = json!(["--stdio", "--log=${pluginDir}"]);
    assert_eq!(validate(manifest.clone())["status"], "ok");
    let outcome = language_server_launch_plan_command(json!({
        "manifest": manifest,
        "languageID": "php",
        "request": {
            "pluginDirectory": "/plugins/php",
            "stateDirectory": "/state/php",
            "workspaceStateDirectory": "/state/php/workspace",
            "architecture": "arm64"
        }
    }))
    .expect("payload is well formed");
    assert_eq!(
        outcome["plan"]["arguments"],
        json!(["--stdio", "--log=${pluginDir}"])
    );
}

/// The install review must show a change to anything that decides what a
/// runtime-launched server executes, including the code it is told to load
/// through its initialization options.
#[test]
fn runtime_launch_and_initialization_options_are_reviewed_programs() {
    let outcome = crate::plugins::marketplace::install_review_command(json!({
        "manifest": fixture("java-support.plugin.json"),
    }))
    .expect("payload is well formed");
    let programs = outcome["review"]["programs"].as_array().unwrap();
    let server = programs
        .iter()
        .find(|program| program["kind"] == "runtimeLanguageServer")
        .expect("the runtime launch is listed");
    assert_eq!(
        server["entry"],
        "language-server/plugins/org.eclipse.equinox.launcher.jar"
    );
    assert!(server["initializationOptions"].is_object());
    // The runtime the plugin ships is reviewed as part of its program; it is
    // not a runtime the host is asked to provide.
    assert_eq!(server["packagedRuntime"], "runtime/${arch}/bin/java");
    assert_eq!(server["hostIntegration"]["id"], "jdt");
    assert!(programs.iter().all(|program| program["kind"] != "runtime"));

    let outcome = crate::plugins::marketplace::install_review_command(json!({
        "manifest": fixture("node-runtime.plugin.json"),
    }))
    .expect("payload is well formed");
    assert!(outcome["review"]["programs"]
        .as_array()
        .unwrap()
        .contains(&json!({
            "kind": "runtime", "tool": "node", "minimumVersion": "18.17"
        })));
}

/// Hosts filter runtime candidates with this outcome, so both products must
/// read the same version from the same probe output.
#[test]
fn runtime_version_fixtures_match_golden_outcomes() {
    let fixtures: Value = serde_json::from_str(RUNTIME_VERSIONS).unwrap();
    for case in fixtures["cases"].as_array().unwrap() {
        let outcome =
            check_runtime_version_command(case["request"].clone()).expect("payload is well formed");
        if let Some(code) = case.get("expectedCode") {
            assert_eq!(outcome["status"], "rejected", "{}: {outcome}", case["name"]);
            assert_eq!(&outcome["error"]["code"], code, "{}", case["name"]);
        } else {
            assert_eq!(outcome["status"], "ok", "{}: {outcome}", case["name"]);
            assert_eq!(outcome["check"], case["expected"], "{}", case["name"]);
        }
    }
}

#[test]
fn malformed_payload_is_a_core_failure_not_a_rejection() {
    assert!(run_plan_command(json!({ "manifest": {} })).is_err());
    assert!(validate_command(json!("plugin.json")).is_err());
    assert!(language_server_launch_plan_command(json!({ "manifest": {} })).is_err());
    assert!(check_runtime_version_command(json!({ "tool": "java" })).is_err());
}

fn apply_edit(manifest: &mut Value, edit: &Value) {
    let path = edit["path"].as_str().unwrap();
    let (parent_path, key) = path.rsplit_once('/').unwrap();
    let parent = manifest
        .pointer_mut(parent_path)
        .unwrap_or_else(|| panic!("missing edit parent {parent_path}"));
    match edit["op"].as_str().unwrap() {
        "set" => match parent {
            Value::Object(object) => {
                object.insert(key.to_string(), edit["value"].clone());
            }
            Value::Array(array) => array[key.parse::<usize>().unwrap()] = edit["value"].clone(),
            _ => panic!("edit parent {parent_path} is not a container"),
        },
        "remove" => {
            parent.as_object_mut().unwrap().remove(key);
        }
        other => panic!("unknown edit op {other}"),
    }
}
