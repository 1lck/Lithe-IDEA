use crate::plugins::declarative::{
    check_runtime_version_command, discover_tests_command, language_server_launch_plan_command,
    resolve_settings_command, run_plan_command, test_plan_command, validate_command,
    workspace_configuration_command,
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

const PHP_FIXTURE: &str = contract_file!("fixtures/language-packaged-server.plugin.json");
const HELLO_FIXTURE: &str = contract_file!("fixtures/hello-lithe.plugin.json");
const WEB_PANEL_FIXTURE: &str = contract_file!("fixtures/web-panel.plugin.json");
const GO_FIXTURE: &str = contract_file!("fixtures/language-system-command.plugin.json");
const JAVA_FIXTURE: &str = contract_file!("fixtures/language-host-integration.plugin.json");
const NODE_RUNTIME_FIXTURE: &str = contract_file!("fixtures/node-runtime.plugin.json");
const PUBLISHER_BUNDLED_FIXTURE: &str = contract_file!("fixtures/publisher-bundled.plugin.json");
const CARGO_BUILD_FIXTURE: &str = contract_file!("fixtures/build-static-file.plugin.json");
const GO_BUILD_FIXTURE: &str = contract_file!("fixtures/build-command-stdout.plugin.json");
const GRADLE_BUILD_FIXTURE: &str = contract_file!("fixtures/build-command-output-file.plugin.json");
const MAVEN_BUILD_FIXTURE: &str = contract_file!("fixtures/build-host-integration.plugin.json");
const GRADLE_PROVIDER_FIXTURE: &str = contract_file!("fixtures/build-provider.plugin.json");
const MIX_PROVIDER_FIXTURE: &str =
    contract_file!("fixtures/build-provider-language-server.plugin.json");
const SETTINGS_V2_FIXTURE: &str = contract_file!("fixtures/settings-v2.plugin.json");
const BACKEND_FIXTURE: &str = contract_file!("fixtures/backend.plugin.json");
const WORKSPACE_BACKEND_FIXTURE: &str = contract_file!("fixtures/backend-workspace.plugin.json");
const DEBUG_ADAPTER_FIXTURE: &str = contract_file!("fixtures/debug-adapter.plugin.json");
const DEBUG_ADAPTER_LANGUAGE_SERVER_FIXTURE: &str =
    contract_file!("fixtures/debug-adapter-language-server.plugin.json");
const DEBUG_ADAPTER_REMOTE_ATTACH_FIXTURE: &str =
    contract_file!("fixtures/debug-adapter-remote-attach.plugin.json");
const DEBUG_ADAPTER_REJECTIONS: &str = contract_file!("fixtures/debug-adapter-rejections.json");
const INVALID_MANIFESTS: &str = contract_file!("fixtures/invalid-manifests.json");
const COMMAND_PLANS: &str = contract_file!("fixtures/command-plans.json");
const RUNTIME_VERSIONS: &str = contract_file!("fixtures/runtime-versions.json");
const OFFICIAL_JAVA: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../Plugins/mac/Official/JavaSupport/plugin.json"
));

fn fixture(name: &str) -> Value {
    let source = match name {
        "language-packaged-server.plugin.json" => PHP_FIXTURE,
        "language-system-command.plugin.json" => GO_FIXTURE,
        "hello-lithe.plugin.json" => HELLO_FIXTURE,
        "web-panel.plugin.json" => WEB_PANEL_FIXTURE,
        "language-host-integration.plugin.json" => JAVA_FIXTURE,
        "node-runtime.plugin.json" => NODE_RUNTIME_FIXTURE,
        "build-static-file.plugin.json" => CARGO_BUILD_FIXTURE,
        "build-command-stdout.plugin.json" => GO_BUILD_FIXTURE,
        "build-command-output-file.plugin.json" => GRADLE_BUILD_FIXTURE,
        "build-host-integration.plugin.json" => MAVEN_BUILD_FIXTURE,
        "build-provider.plugin.json" => GRADLE_PROVIDER_FIXTURE,
        "build-provider-language-server.plugin.json" => MIX_PROVIDER_FIXTURE,
        "settings-v2.plugin.json" => SETTINGS_V2_FIXTURE,
        "backend.plugin.json" => BACKEND_FIXTURE,
        "backend-workspace.plugin.json" => WORKSPACE_BACKEND_FIXTURE,
        "debug-adapter.plugin.json" => DEBUG_ADAPTER_FIXTURE,
        "debug-adapter-language-server.plugin.json" => DEBUG_ADAPTER_LANGUAGE_SERVER_FIXTURE,
        "debug-adapter-remote-attach.plugin.json" => DEBUG_ADAPTER_REMOTE_ATTACH_FIXTURE,
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
        HELLO_FIXTURE,
        WEB_PANEL_FIXTURE,
        JAVA_FIXTURE,
        NODE_RUNTIME_FIXTURE,
        PUBLISHER_BUNDLED_FIXTURE,
        BACKEND_FIXTURE,
        WORKSPACE_BACKEND_FIXTURE,
        DEBUG_ADAPTER_FIXTURE,
        DEBUG_ADAPTER_REMOTE_ATTACH_FIXTURE,
        OFFICIAL_JAVA,
    ] {
        let outcome = validate(serde_json::from_str(source).unwrap());
        assert_eq!(outcome["status"], "ok", "{outcome}");
    }
}

/// The package cannot grant itself host-seal trust on an older host or
/// downgrade independently installed copies to unsigned/local-only trust.
#[test]
fn bundled_publisher_trust_requires_an_explicit_host_capability() {
    let manifest: Value = serde_json::from_str(PUBLISHER_BUNDLED_FIXTURE).unwrap();
    let mut host = json!({"languages":[1], "languageServers":[1], "serverProcess":[1]});
    let refused =
        validate_command(json!({"manifest": manifest, "hostCapabilities": host})).unwrap();
    assert_eq!(refused["error"]["code"], "plugin.api.unsupported");
    assert_eq!(refused["error"]["field"], "requires.packageTrust");
    host["packageTrust"] = json!([1]);
    let accepted =
        validate_command(json!({"manifest": manifest, "hostCapabilities": host})).unwrap();
    assert_eq!(accepted["status"], "ok", "{accepted}");
    assert_eq!(
        accepted["plugin"]["vendor"]["bundledSignatureRequirement"],
        "sameTeamAsHost"
    );

    for (field, value) in [
        ("signatureRequirement", "none"),
        ("signatureRequirement", "sameTeamAsHost"),
        ("bundledSignatureRequirement", "publisherPackage"),
        ("bundledSignatureRequirement", "none"),
    ] {
        let mut bad = manifest.clone();
        bad["vendor"][field] = json!(value);
        assert_eq!(validate(bad)["status"], "rejected", "{field}: {value}");
    }
    let mut community = manifest.clone();
    community["id"] = json!("io.example.fixture");
    assert_eq!(validate(community)["status"], "rejected");
    let mut missing = manifest.clone();
    missing["requires"]
        .as_object_mut()
        .unwrap()
        .remove("packageTrust");
    assert_eq!(validate(missing)["error"]["field"], "requires");
    let mut legacy = manifest.clone();
    legacy["pluginAPIVersion"] = json!(2);
    legacy.as_object_mut().unwrap().remove("requires");
    assert_eq!(
        validate(legacy)["error"]["field"],
        "vendor.bundledSignatureRequirement"
    );
    let mut unused = manifest;
    unused["vendor"]
        .as_object_mut()
        .unwrap()
        .remove("bundledSignatureRequirement");
    assert_eq!(validate(unused)["error"]["field"], "requires.packageTrust");
}

#[test]
fn validation_normalizes_order_and_spelling_without_touching_arguments() {
    let mut manifest = fixture("language-packaged-server.plugin.json");
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
    let mut manifest = fixture("language-system-command.plugin.json");
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
    let mut manifest = fixture("language-host-integration.plugin.json");
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
        assert_eq!(
            outcome["error"]["code"], "plugin.manifest.invalid",
            "{outcome}"
        );
        outcome["error"]["field"].as_str().unwrap().to_string()
    };
    let field = "languageServers[0].hostIntegration.capabilities";

    let mut unknown = fixture("language-host-integration.plugin.json");
    *unknown.pointer_mut(capabilities).unwrap() = json!(["formatting"]);
    assert_eq!(rejected_field(unknown), field);

    // Debugging loads the debugger as a JDT LS extension bundle.
    let mut without_bundles = fixture("language-host-integration.plugin.json");
    *without_bundles.pointer_mut(capabilities).unwrap() = json!(["debug"]);
    let resources = "/languageServers/0/hostIntegration/resources";
    let resources = without_bundles.pointer_mut(resources).unwrap();
    resources
        .as_object_mut()
        .unwrap()
        .remove("extensionBundleDirectories");
    assert_eq!(rejected_field(without_bundles), field);

    let mut owned_twice = fixture("language-host-integration.plugin.json");
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
        let mut payload = json!({
            "manifest": fixture(case["plugin"].as_str().unwrap()),
            "request": case["request"],
        });
        // A launch plan selects its process by language or by build system.
        for key in ["languageID", "buildSystemID"] {
            if let Some(value) = case.get(key) {
                payload[key] = value.clone();
            }
        }
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
    let mut manifest = fixture("language-packaged-server.plugin.json");
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
        "manifest": fixture("language-host-integration.plugin.json"),
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

/// The validation probe runs before the host has read the plugin's settings,
/// so it cannot depend on one.
#[test]
fn validation_probe_cannot_use_settings() {
    let mut manifest = fixture("language-system-command.plugin.json");
    manifest["pluginAPIVersion"] = json!(2);
    manifest["settings"] = json!([
        { "id": "verbose", "type": "boolean", "title": "Verbose", "default": false }
    ]);
    manifest["languageServers"][0]["validationArguments"] =
        json!(["version", "${setting:verbose}"]);
    let outcome = validate(manifest.clone());
    assert_eq!(outcome["status"], "rejected", "{outcome}");
    assert_eq!(outcome["error"]["code"], "plugin.template.invalid");

    // The same setting is fine where the server starts.
    manifest["languageServers"][0]["validationArguments"] = json!(["version"]);
    manifest["languageServers"][0]["arguments"] = json!(["-verbose=${setting:verbose}"]);
    assert_eq!(validate(manifest)["status"], "ok");
}

/// A setting declaration is part of the normalized manifest, ordered by ID so
/// two hosts show and store the same list.
#[test]
fn settings_are_normalized_in_identifier_order() {
    let outcome = validate(fixture("node-runtime.plugin.json"));
    let ids: Vec<&str> = outcome["plugin"]["settings"]
        .as_array()
        .expect("normalized manifest lists the settings")
        .iter()
        .map(|setting| setting["id"].as_str().unwrap())
        .collect();
    assert_eq!(ids, ["heapMB", "logLevel", "telemetry"]);
}

/// API level 3 versions each section on its own: a manifest lists exactly
/// the capabilities it uses, a missing one is named precisely, and a host
/// that sends its capabilities refuses only plugins that need one it lacks.
#[test]
fn level_3_manifests_list_exactly_the_capabilities_they_use() {
    let rejected = |outcome: Value| {
        assert_eq!(outcome["status"], "rejected", "{outcome}");
        (
            outcome["error"]["code"].as_str().unwrap().to_string(),
            outcome["error"]["field"].as_str().unwrap().to_string(),
        )
    };
    let mix = fixture("build-provider-language-server.plugin.json");
    let outcome = validate(mix.clone());
    assert_eq!(outcome["status"], "ok", "{outcome}");
    assert_eq!(
        outcome["plugin"]["requires"],
        json!({ "buildProviders": 1, "buildSystems": 1, "languageServers": 1, "languages": 1, "serverProcess": 1 })
    );
    let legacy = validate(fixture("language-packaged-server.plugin.json"));
    assert!(legacy["plugin"].get("requires").is_none(), "{legacy}");

    let mut future = mix.clone();
    future["requires"]["debuggers"] = json!(1);
    future["debuggers"] = json!([{ "id": "lldb" }]);
    assert_eq!(
        rejected(validate(future)),
        ("plugin.api.unsupported".into(), "requires.debuggers".into())
    );
    let mut missing = mix.clone();
    missing["requires"]
        .as_object_mut()
        .unwrap()
        .remove("serverProcess");
    assert_eq!(
        rejected(validate(missing)),
        ("plugin.manifest.invalid".into(), "requires".into())
    );
    let mut unused = mix.clone();
    unused["requires"]["settings"] = json!(1);
    assert_eq!(
        rejected(validate(unused)),
        ("plugin.manifest.invalid".into(), "requires.settings".into())
    );

    // A level 3 plugin without build systems never depends on them.
    let mut language_only = fixture("language-packaged-server.plugin.json");
    language_only["pluginAPIVersion"] = json!(3);
    language_only["requires"] = json!({
        "executionProviders": 1, "languageServers": 1, "languages": 1, "serverProcess": 1
    });
    let host_without_builds = json!({
        "executionProviders": [1], "languageServers": [1], "languages": [1], "serverProcess": [1]
    });
    let validate_on = |manifest: &Value, host: &Value| {
        validate_command(json!({ "manifest": manifest, "hostCapabilities": host }))
            .expect("payload is well formed")
    };
    assert_eq!(
        validate_on(&language_only, &host_without_builds)["status"],
        "ok"
    );
    assert_eq!(
        rejected(validate_on(&mix, &host_without_builds)),
        (
            "plugin.api.unsupported".into(),
            "requires.buildProviders".into()
        )
    );
    let mut host_with_builds = host_without_builds.clone();
    host_with_builds["buildSystems"] = json!([1]);
    host_with_builds["buildProviders"] = json!([1]);
    assert_eq!(validate_on(&mix, &host_with_builds)["status"], "ok");
    // Capability versions do not apply below level 3.
    assert_eq!(
        validate_on(&fixture("language-packaged-server.plugin.json"), &json!({}))["status"],
        "ok"
    );
}

/// Provider orchestration is independent of declarative build commands and
/// process launching, including when the provider shares a language server.
#[test]
fn build_providers_require_their_own_host_capability() {
    let mut host = json!({
        "buildSystems": [1], "languageServers": [1], "languages": [1],
        "serverProcess": [1], "settings": [1]
    });
    let template = validate_command(json!({
        "manifest": fixture("build-static-file.plugin.json"), "hostCapabilities": host
    }))
    .unwrap();
    assert_eq!(template["status"], "ok", "{template}");

    for (name, build_system_id) in [
        ("build-provider.plugin.json", "gradle"),
        ("build-provider-language-server.plugin.json", "mix"),
    ] {
        let manifest = fixture(name);
        for versions in [None, Some(json!([2])), Some(json!([1]))] {
            host.as_object_mut().unwrap().remove("buildProviders");
            if let Some(versions) = versions {
                host["buildProviders"] = versions;
            }
            let outcome = validate_command(json!({
                "manifest": manifest, "hostCapabilities": host
            }))
            .unwrap();
            if host["buildProviders"] == json!([1]) {
                assert_eq!(outcome["status"], "ok", "{name}: {outcome}");
            } else {
                assert_eq!(outcome["status"], "rejected", "{name}: {outcome}");
                assert_eq!(outcome["error"]["code"], "plugin.api.unsupported");
                assert_eq!(outcome["error"]["field"], "requires.buildProviders");
            }
        }
        // Tooling without a host table may validate and plan what Core supports.
        let outcome = validate(manifest.clone());
        assert_eq!(outcome["status"], "ok", "{name}: {outcome}");
        let launch = language_server_launch_plan_command(json!({
            "manifest": manifest,
            "buildSystemID": build_system_id,
            "request": {
                "pluginDirectory": "/plugins/provider",
                "stateDirectory": "/state/provider",
                "workspaceStateDirectory": "/state/provider/workspace",
                "architecture": "arm64"
            }
        }))
        .unwrap();
        assert_eq!(launch["status"], "ok", "{name}: {launch}");
        assert_eq!(
            launch["plan"]["buildProvider"]["buildSystemID"],
            build_system_id
        );
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

/// Data-only UI must activate by stable identity, normalize presentation order,
/// and stay unable to invoke a foreign window or inject executable content.
#[test]
fn ui_contributions_are_normalized_without_interpreting_text() {
    let mut manifest = fixture("hello-lithe.plugin.json");
    manifest["ui"]["commands"][0]["placements"] =
        json!(["menu", "toolbar", "menu", "commandPalette"]);
    manifest["ui"]["toolWindows"][0]["text"] = json!("<script>not executable</script>");
    let outcome = validate(manifest);
    assert_eq!(outcome["status"], "ok", "{outcome}");
    assert_eq!(
        outcome["plugin"]["ui"]["commands"][0]["placements"],
        json!(["commandPalette", "toolbar", "menu"])
    );
    assert_eq!(
        outcome["plugin"]["ui"]["toolWindows"][0]["text"],
        "<script>not executable</script>"
    );
    for placement in ["left", "bottom", "right"] {
        let mut manifest = fixture("hello-lithe.plugin.json");
        manifest["ui"]["toolWindows"][0]["placement"] = json!(placement);
        let result = validate(manifest);
        assert_eq!(result["status"], "ok", "{result}");
        assert_eq!(
            result["plugin"]["ui"]["toolWindows"][0]["placement"],
            placement
        );
    }
}

/// A plugin may bring its own page instead of literal text. The page is a
/// package file behind its own consent, and a host that runs only `ui` 1
/// never receives it, so it cannot fall back to showing the page as text.
#[test]
fn web_tool_windows_need_ui_2_their_permission_and_a_package_page() {
    let outcome = validate(fixture("web-panel.plugin.json"));
    assert_eq!(outcome["status"], "ok", "{outcome}");
    let windows = &outcome["plugin"]["ui"]["toolWindows"];
    assert_eq!(windows[0]["id"], "dev.lithe.fixture.web-panel.notes");
    assert!(windows[0].get("web").is_none());
    assert_eq!(windows[1]["web"], json!({ "entry": "ui/index.html" }));
    assert!(windows[1].get("text").is_none());
    assert_eq!(
        outcome["plugin"]["permissions"],
        json!(["ui.contribute", "ui.web"])
    );

    let validate_on = |host: Value| {
        validate_command(json!({
            "manifest": fixture("web-panel.plugin.json"),
            "hostCapabilities": host,
        }))
        .expect("payload is well formed")
    };
    let text_only = validate_on(json!({ "ui": [1] }));
    assert_eq!(text_only["status"], "rejected", "{text_only}");
    assert_eq!(text_only["error"]["code"], "plugin.api.unsupported");
    assert_eq!(text_only["error"]["field"], "requires.ui");
    assert_eq!(validate_on(json!({ "ui": [1, 2] }))["status"], "ok");

    for entry in [
        "index.html",
        "ui/pages/tree.html",
        "ui/index.htm",
        "../index.html",
        "/ui/index.html",
        "ui//index.html",
        "ui/./index.html",
        "https://example.com/index.html",
        "ui/index.html#x",
    ] {
        let mut manifest = fixture("web-panel.plugin.json");
        manifest["ui"]["toolWindows"][0]["web"]["entry"] = json!(entry);
        let accepted = validate(manifest)["status"] == "ok";
        let expected = matches!(entry, "index.html" | "ui/pages/tree.html");
        assert_eq!(accepted, expected, "{entry}");
    }
}

/// A plugin backend is a reviewed server process of the plugin itself. It is
/// planned without a workspace, its plan names exactly the host services its
/// permissions grant, and a host that does not run `backend` never gets it.
#[test]
fn plugin_backend_is_planned_without_a_workspace_and_names_its_host_services() {
    let outcome = validate(fixture("backend.plugin.json"));
    assert_eq!(outcome["status"], "ok", "{outcome}");
    assert_eq!(
        outcome["plugin"]["backend"]["launch"],
        json!({ "kind": "packaged", "path": "bin/backend" })
    );

    let plan_for = |manifest: Value, request: Value| {
        language_server_launch_plan_command(json!({
            "manifest": manifest,
            "backend": true,
            "request": request,
        }))
        .expect("payload is well formed")
    };
    let request = json!({
        "pluginDirectory": "/plugins/backend",
        "stateDirectory": "/state/backend",
        "architecture": "arm64"
    });
    let launch = plan_for(fixture("backend.plugin.json"), request.clone());
    assert_eq!(launch["status"], "ok", "{launch}");
    assert_eq!(
        launch["plan"]["launch"],
        json!({ "kind": "packaged", "path": "bin/backend" })
    );
    assert_eq!(
        launch["plan"]["arguments"],
        json!(["--state", "/state/backend"])
    );
    assert_eq!(launch["plan"]["requiredDirectories"], json!(["state"]));
    assert_eq!(
        launch["plan"]["backend"],
        json!({ "hostServices": ["credentials"] })
    );

    // Without credentials.store the session may request no host service.
    let mut manifest = fixture("backend.plugin.json");
    manifest["permissions"] = json!(["backend.launch", "ui.contribute", "ui.web"]);
    let launch = plan_for(manifest, request.clone());
    assert_eq!(launch["plan"]["backend"], json!({ "hostServices": [] }));

    // A plugin without a backend has nothing to start.
    let launch = plan_for(fixture("web-panel.plugin.json"), request.clone());
    assert_eq!(launch["error"]["code"], "plugin.launch.unavailable");

    // A selection names one process only.
    assert!(language_server_launch_plan_command(json!({
        "manifest": fixture("backend.plugin.json"),
        "backend": true,
        "languageID": "php",
        "request": request,
    }))
    .is_err());

    let review = crate::plugins::marketplace::install_review_command(json!({
        "manifest": fixture("backend.plugin.json"),
    }))
    .expect("payload is well formed");
    assert!(review["review"]["programs"]
        .as_array()
        .unwrap()
        .contains(&json!({
            "kind": "packagedBackend",
            "path": "bin/backend",
            "arguments": ["--state", "${stateDir}"],
            "validationArguments": [],
        })));

    let hosted = |host: Value| {
        validate_command(json!({
            "manifest": fixture("backend.plugin.json"),
            "hostCapabilities": host,
        }))
        .expect("payload is well formed")
    };
    let without_backend = hosted(json!({ "ui": [1, 2], "serverProcess": [1] }));
    assert_eq!(without_backend["error"]["code"], "plugin.api.unsupported");
    assert_eq!(without_backend["error"]["field"], "requires.backend");
    assert_eq!(
        hosted(json!({ "backend": [1], "ui": [1, 2], "serverProcess": [1] }))["status"],
        "ok"
    );
}

/// A `backend` 2 process starts without a page, its plan names its version
/// so the host may start it on `onWorkspaceOpen`, and `workspace.metadata`
/// grants the `workspace` host service. A host that only runs `backend` 1
/// refuses the manifest instead of starting a process it would misuse.
#[test]
fn workspace_backend_is_planned_with_its_version_and_workspace_service() {
    let outcome = validate(fixture("backend-workspace.plugin.json"));
    assert_eq!(outcome["status"], "ok", "{outcome}");
    let launch = language_server_launch_plan_command(json!({
        "manifest": fixture("backend-workspace.plugin.json"),
        "backend": true,
        "request": {
            "pluginDirectory": "/plugins/workspace-backend",
            "stateDirectory": "/state/workspace-backend",
            "architecture": "arm64"
        },
    }))
    .expect("payload is well formed");
    assert_eq!(launch["status"], "ok", "{launch}");
    assert_eq!(
        launch["plan"]["backend"],
        json!({ "hostServices": ["workspace"], "version": 2 })
    );

    let hosted = |host: Value| {
        validate_command(json!({
            "manifest": fixture("backend-workspace.plugin.json"),
            "hostCapabilities": host,
        }))
        .expect("payload is well formed")
    };
    let old_host = hosted(json!({ "backend": [1], "serverProcess": [1] }));
    assert_eq!(old_host["error"]["code"], "plugin.api.unsupported");
    assert_eq!(old_host["error"]["field"], "requires.backend");
    assert_eq!(
        hosted(json!({ "backend": [1, 2], "serverProcess": [1] }))["status"],
        "ok"
    );

    // A page-only backend 1 manifest stays valid as backend 2.
    let mut manifest = fixture("backend.plugin.json");
    manifest["requires"]["backend"] = json!(2);
    assert_eq!(validate(manifest)["status"], "ok");
}

/// Icon trust boundaries are shared; native decoding remains with the macOS host.
#[test]
fn ui_icon_declarations_validate_and_preserve_theme_resources() {
    for icon in [
        json!({"host":"database"}),
        json!({"path":"icons/mark.svg"}),
        json!({"path":"icons/mark.png", "darkPath":"icons/mark-dark.png", "mode":"original"}),
    ] {
        let mut manifest = fixture("hello-lithe.plugin.json");
        manifest["ui"]["toolWindows"][0]["icon"] = icon.clone();
        manifest["ui"]["commands"][0]["icon"] = icon.clone();
        let result = validate(manifest);
        assert_eq!(result["status"], "ok", "{result}");
        let mut expected = icon;
        if expected.get("mode").is_none() {
            expected["mode"] = json!("template");
        }
        assert_eq!(result["plugin"]["ui"]["toolWindows"][0]["icon"], expected);
        assert_eq!(result["plugin"]["ui"]["commands"][0]["icon"], expected);
    }
    for icon in [
        json!({}),
        json!({"host":"unknown"}),
        json!({"host":"run","path":"a.svg"}),
        json!({"host":"run","mode":"original"}),
        json!({"path":"../a.svg"}),
        json!({"path":"/a.svg"}),
        json!({"path":"https://host/a.svg"}),
        json!({"path":"a.gif"}),
        json!({"path":"a.svg","darkPath":"../dark.svg"}),
        json!({"path":"a.svg","size":48}),
        json!({"path":"a.svg","color":"red"}),
        json!({"path":"a.svg","mode":"script"}),
        json!({"path":"a//b.svg"}),
        json!({"path":"a/./b.svg"}),
    ] {
        for target in ["toolWindows", "commands"] {
            let mut manifest = fixture("hello-lithe.plugin.json");
            manifest["ui"][target][0]["icon"] = icon.clone();
            assert_eq!(validate(manifest)["status"], "rejected", "{target}: {icon}");
        }
    }
}

/// Validate the shipped acceptance plugin through the same boundary as installation.
#[test]
fn native_ui_lab_package_manifest_is_installable() {
    let manifest: Value = serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../macos/Tests/Fixtures/native-ui-lab/plugin.json"
    )))
    .unwrap();
    let result = validate(manifest);
    assert_eq!(result["status"], "ok", "{result}");
}

/// Native controls are opt-in; legacy hosts reject them before presentation.
#[test]
fn native_ui_validates_version_ownership_actions_and_budgets() {
    let manifest: Value =
        serde_json::from_str(contract_file!("fixtures/native-panel.plugin.json")).unwrap();
    let result = validate(manifest.clone());
    assert_eq!(result["status"], "ok", "{result}");
    for icon in [json!({"host":"search"}), json!({"host":"reset"})] {
        let mut with_icon = manifest.clone();
        with_icon["ui"]["toolWindows"][0]["native"]["actions"][1]["icon"] = icon;
        assert_eq!(validate(with_icon)["status"], "ok");
    }
    for icon in [
        json!({"host":"unknown"}),
        json!({"path":"icons/custom.svg"}),
        json!({"host":"reset","mode":"original"}),
    ] {
        let mut invalid = manifest.clone();
        invalid["ui"]["toolWindows"][0]["native"]["actions"][1]["icon"] = icon;
        assert_eq!(validate(invalid)["status"], "rejected");
    }
    let old_host = validate_command(json!({"manifest": manifest, "hostCapabilities": {"ui":[1,2], "buildSystems":[1], "buildProviders":[1], "serverProcess":[1]}})).unwrap();
    assert_eq!(old_host["error"]["code"], "plugin.api.unsupported");
    for (pointer, value) in [
        ("/ui/toolWindows/0/native/schemaVersion", json!(2)),
        (
            "/ui/toolWindows/0/native/source/buildSystemID",
            json!("foreign"),
        ),
        ("/ui/toolWindows/0/native/toolbar", json!(["missing"])),
        (
            "/ui/toolWindows/0/native/contextMenu",
            json!(["inspect", "inspect"]),
        ),
        (
            "/ui/toolWindows/0/native/nodes",
            json!([{"id":"same","label":"A"},{"id":"same","label":"B"}]),
        ),
        (
            "/ui/toolWindows/0/native/nodes",
            json!(vec![json!({"id":"row","label":"x"}); 2001]),
        ),
        ("/requires/ui", json!(2)),
    ] {
        let mut invalid = manifest.clone();
        *invalid.pointer_mut(pointer).unwrap() = value;
        assert_eq!(validate(invalid)["status"], "rejected", "{pointer}");
    }
    let mut styled = manifest.clone();
    styled["ui"]["toolWindows"][0]["native"]["color"] = json!("red");
    assert_eq!(validate(styled)["status"], "rejected");
    let mut mixed = manifest;
    mixed["ui"]["toolWindows"][0]["text"] = json!("cannot mix body types");
    assert_eq!(validate(mixed)["status"], "rejected");
}

#[test]
fn native_ui_forms_validate_controls_values_actions_and_budgets() {
    let manifest: Value =
        serde_json::from_str(contract_file!("fixtures/native-form.plugin.json")).unwrap();
    assert_eq!(validate(manifest.clone())["status"], "ok");
    for (pointer, value) in [
        ("/ui/toolWindows/0/native/kind", json!("list")),
        (
            "/ui/toolWindows/0/native/nodes",
            json!([{"id":"row","label":"Row"}]),
        ),
        ("/ui/toolWindows/0/native/controls", json!([])),
        (
            "/ui/toolWindows/0/native/controls",
            json!(vec![
                json!({"id":"field","kind":"input","label":"Field","value":""});
                33
            ]),
        ),
        ("/ui/toolWindows/0/native/controls/0/kind", json!("html")),
        ("/ui/toolWindows/0/native/controls/0/id", json!("form")),
        ("/ui/toolWindows/0/native/controls/0/value", json!(false)),
        (
            "/ui/toolWindows/0/native/controls/0/value",
            json!("😀".repeat(257)),
        ),
        (
            "/ui/toolWindows/0/native/controls/2/value",
            json!("missing"),
        ),
        ("/ui/toolWindows/0/native/controls/2/options", json!([])),
        (
            "/ui/toolWindows/0/native/controls/2/options",
            json!([{"id":"same","label":"A"},{"id":"same","label":"B"}]),
        ),
        (
            "/ui/toolWindows/0/native/controls/2/options",
            json!(vec![json!({"id":"option","label":"Option"}); 129]),
        ),
        ("/ui/toolWindows/0/native/controls/3/value", json!("true")),
    ] {
        let mut invalid = manifest.clone();
        *invalid.pointer_mut(pointer).unwrap() = value;
        assert_eq!(validate(invalid)["status"], "rejected", "{pointer}");
    }
    for (key, value) in [
        ("onCommit", json!("missing")),
        ("options", json!([])),
        ("color", json!("red")),
    ] {
        let mut invalid = manifest.clone();
        invalid["ui"]["toolWindows"][0]["native"]["controls"][0][key] = value;
        assert_eq!(validate(invalid)["status"], "rejected", "{key}");
    }
    let mut dynamic = manifest;
    let native = &mut dynamic["ui"]["toolWindows"][0]["native"];
    native["source"] = json!({"buildSystemID":"sample","function":"form.nodes"});
    native["actions"] = json!([{"id":"changed","title":"Changed","kind":"invoke","function":"form.changed","requiresSelection":false}]);
    native["controls"][0]["onCommit"] = json!("changed");
    assert_eq!(validate(dynamic.clone())["status"], "ok");
    dynamic["ui"]["toolWindows"][0]["native"]["actions"][0]["requiresSelection"] = json!(true);
    assert_eq!(validate(dynamic)["status"], "rejected");
}

#[test]
fn native_ui_form_grid_validates_columns_spans_and_scope() {
    let manifest: Value =
        serde_json::from_str(contract_file!("fixtures/native-form.plugin.json")).unwrap();
    assert_eq!(validate(manifest.clone())["status"], "ok");
    for (pointer, value) in [
        ("/ui/toolWindows/0/native/layout/columns", json!(0)),
        ("/ui/toolWindows/0/native/layout/columns", json!(13)),
        ("/ui/toolWindows/0/native/layout/columns", json!(1.5)),
        ("/ui/toolWindows/0/native/controls/0/span", json!(0)),
        ("/ui/toolWindows/0/native/controls/0/span", json!(13)),
        ("/ui/toolWindows/0/native/controls/0/span", json!("6")),
    ] {
        let mut invalid = manifest.clone();
        *invalid.pointer_mut(pointer).unwrap() = value;
        assert_eq!(validate(invalid)["status"], "rejected", "{pointer}");
    }
    let mut smaller_grid = manifest.clone();
    smaller_grid["ui"]["toolWindows"][0]["native"]["layout"]["columns"] = json!(4);
    assert_eq!(validate(smaller_grid)["status"], "rejected");
    let mut missing_grid = manifest.clone();
    missing_grid["ui"]["toolWindows"][0]["native"]
        .as_object_mut()
        .unwrap()
        .remove("layout");
    assert_eq!(validate(missing_grid.clone())["status"], "rejected");
    for control in missing_grid["ui"]["toolWindows"][0]["native"]["controls"]
        .as_array_mut()
        .unwrap()
    {
        control.as_object_mut().unwrap().remove("span");
    }
    assert_eq!(validate(missing_grid)["status"], "ok");
    let mut styled = manifest;
    styled["ui"]["toolWindows"][0]["native"]["layout"]["gap"] = json!(99);
    assert_eq!(validate(styled)["status"], "rejected");
    let mut tree: Value =
        serde_json::from_str(contract_file!("fixtures/native-panel.plugin.json")).unwrap();
    tree["ui"]["toolWindows"][0]["native"]["layout"] = json!({"columns":12});
    assert_eq!(validate(tree)["status"], "rejected");
}

#[test]
fn native_public_controls_validate_types_ranges_info_and_buttons() {
    let manifest: Value =
        serde_json::from_str(contract_file!("fixtures/native-controls.plugin.json")).unwrap();
    assert_eq!(validate(manifest.clone())["status"], "ok");
    for (pointer, value) in [
        ("/ui/toolWindows/0/native/controls/0/info", json!(" ")),
        (
            "/ui/toolWindows/0/native/controls/0/info",
            json!("x".repeat(1025)),
        ),
        ("/ui/toolWindows/0/native/controls/8/value", json!(true)),
        (
            "/ui/toolWindows/0/native/controls/9/value",
            json!("😀".repeat(2049)),
        ),
        ("/ui/toolWindows/0/native/controls/9/rows", json!(13)),
        (
            "/ui/toolWindows/0/native/controls/10/value",
            json!("unknown"),
        ),
        (
            "/ui/toolWindows/0/native/controls/10/options",
            json!(vec![json!({"id":"option","label":"Option"}); 9]),
        ),
        ("/ui/toolWindows/0/native/controls/11/value", json!("2")),
        ("/ui/toolWindows/0/native/controls/11/value", json!(9)),
        ("/ui/toolWindows/0/native/controls/11/minimum", json!(10)),
        ("/ui/toolWindows/0/native/controls/11/step", json!(0)),
        ("/ui/toolWindows/0/native/buttons/0/id", json!("name")),
        (
            "/ui/toolWindows/0/native/buttons/0/action",
            json!("unknown"),
        ),
        ("/ui/toolWindows/0/native/buttons/0/width", json!(200)),
        ("/ui/toolWindows/0/native/buttons/0/span", json!(13)),
        (
            "/ui/toolWindows/0/native/buttons",
            json!(vec![
                json!({"id":"button","label":"Button","action":"changed"});
                17
            ]),
        ),
    ] {
        let mut invalid = manifest.clone();
        *invalid.pointer_mut(pointer).unwrap() = value;
        assert_eq!(validate(invalid)["status"], "rejected", "{pointer}");
    }
    for (index, key, value) in [
        (0, "minimum", json!(0)),
        (0, "rows", json!(2)),
        (9, "onCommit", json!("changed")),
        (11, "placeholder", json!("hint")),
    ] {
        let mut invalid = manifest.clone();
        invalid["ui"]["toolWindows"][0]["native"]["controls"][index][key] = value;
        assert_eq!(validate(invalid)["status"], "rejected");
    }
    let mut styled = manifest.clone();
    styled["ui"]["toolWindows"][0]["native"]["buttons"][0]["color"] = json!("red");
    assert_eq!(validate(styled)["status"], "rejected");
    let mut button_only = manifest;
    button_only["ui"]["toolWindows"][0]["native"]["controls"] = json!([]);
    assert_eq!(validate(button_only)["status"], "ok");
}

/// A level 3 manifest using settings v2: scoped, page-placed settings with an
/// `immediate` one that only the server's `workspaceConfiguration` may read.
/// The shared settings v2 fixture: project and immediate settings on a
/// language page, a multi-select on a build-system page, and a page button.
fn settings_v2_manifest() -> Value {
    fixture("settings-v2.plugin.json")
}

#[test]
fn immediate_settings_must_be_used_by_workspace_configuration() {
    let mut manifest = settings_v2_manifest();
    manifest["languageServers"][0]["workspaceConfiguration"] = json!({
        "elixirLS": { "dialyzerEnabled": true }
    });
    let rejection = validate(manifest);
    assert_eq!(rejection["status"], "rejected");
    assert!(rejection.to_string().contains("immediate setting dialyzer"));
}
#[test]
fn settings_v2_manifests_validate_and_resolve_by_layer() {
    let manifest = settings_v2_manifest();
    assert_eq!(
        validate(manifest.clone())["status"],
        "ok",
        "{}",
        validate(manifest.clone())
    );

    let resolved = resolve_settings_command(json!({
        "manifest": manifest,
        "settings": { "dialyzer": false, "mixEnv": "test" },
        "projectSettings": { "mixEnv": "prod", "checks": ["credo"] }
    }))
    .unwrap();
    assert_eq!(resolved["status"], "ok", "{resolved}");
    let by_id = |id: &str| {
        resolved["settings"]
            .as_array()
            .unwrap()
            .iter()
            .find(|setting| setting["id"] == id)
            .cloned()
            .unwrap()
    };
    assert_eq!(by_id("mixEnv")["value"], "prod");
    assert_eq!(by_id("mixEnv")["source"], "project");
    assert_eq!(by_id("dialyzer")["value"], false);
    assert_eq!(by_id("dialyzer")["source"], "global");
    // A global-scope setting ignores the project layer.
    assert_eq!(by_id("checks")["value"], json!(["format"]));
    assert_eq!(by_id("checks")["source"], "default");

    let configuration = workspace_configuration_command(json!({
        "manifest": manifest,
        "settings": { "dialyzer": false },
        "projectSettings": {},
        "languageID": "elixir"
    }))
    .unwrap();
    assert_eq!(
        configuration["configuration"],
        json!({ "elixirLS": { "dialyzerEnabled": false } })
    );
}

#[test]
fn settings_v2_rejects_unsafe_setting_use() {
    let rejected = |manifest: Value| {
        let outcome = validate(manifest);
        assert_eq!(outcome["status"], "rejected", "{outcome}");
    };
    // An immediate setting cannot reach the process command line.
    let mut immediate_argument = settings_v2_manifest();
    immediate_argument["languageServers"][0]["arguments"] =
        json!(["--stdio", "--dialyzer=${setting:dialyzer}"]);
    rejected(immediate_argument);
    // Free text must be a whole value or follow a `name=` prefix.
    let mut spliced_text = settings_v2_manifest();
    spliced_text["languageServers"][0]["arguments"] = json!(["--stdio", "x${setting:mixEnv}y"]);
    rejected(spliced_text);
    // Text settings need a pattern.
    let mut unpatterned = settings_v2_manifest();
    unpatterned["settings"][1]
        .as_object_mut()
        .unwrap()
        .remove("pattern");
    rejected(unpatterned);
    // An action names a plugin function.
    let mut bad_action = settings_v2_manifest();
    bad_action["settingActions"][0]["function"] = json!("Not A Function");
    rejected(bad_action);
    // v2 fields need v2.
    let mut v1 = settings_v2_manifest();
    v1["requires"]["settings"] = json!(1);
    rejected(v1);
}

/// Runs one case of the shared debug adapter rejection fixture through the
/// layer it names, so every host reports the same code and location.
fn debug_rejection(baseline: &Value, case: &Value) -> (String, String) {
    use crate::debug::adapters::{
        check_package_resources, plan, DebugAdapterDeclaration, DebugRequest, PackageResource,
        StartFacts,
    };
    let mut input = baseline.clone();
    for edit in case["edits"].as_array().unwrap() {
        apply_edit(&mut input, edit);
    }
    let metadata = &input["context"]["manifestMetadata"];
    let adapters = input["block"]["debugAdapters"].clone();
    let events: Vec<String> = adapters
        .as_array()
        .unwrap()
        .iter()
        .map(|adapter| format!("onDebug:{}", adapter["id"].as_str().unwrap()))
        .collect();
    let mut manifest = fixture("debug-adapter.plugin.json");
    manifest["pluginAPIVersion"] = metadata["pluginAPIVersion"].clone();
    match metadata.get("requires") {
        Some(requires) => manifest["requires"] = requires.clone(),
        None => {
            manifest.as_object_mut().unwrap().remove("requires");
        }
    }
    manifest["permissions"] = metadata["permissions"].clone();
    manifest["activationEvents"] = json!(events);
    // The fixture's own settings belong to its own adapters; a case declares the
    // settings it needs in `block`.
    manifest.as_object_mut().unwrap().remove("settings");
    for (key, value) in input["block"].as_object().unwrap() {
        manifest[key] = value.clone();
    }
    let outcome = validate_command(
        json!({ "manifest": manifest, "hostCapabilities": input["context"]["hostCapabilities"] }),
    )
    .expect("payload is well formed");
    let layer = case["layer"].as_str().unwrap();
    if outcome["status"] == "rejected" {
        assert!(
            matches!(layer, "schema" | "coreManifest"),
            "{}: manifest rejected in layer {layer}: {outcome}",
            case["id"]
        );
        let error = &outcome["error"];
        return (
            error["code"].as_str().unwrap().into(),
            error["field"].as_str().unwrap_or_default().into(),
        );
    }
    let plugin = &outcome["plugin"];
    let adapter: DebugAdapterDeclaration =
        serde_json::from_value(plugin["debugAdapters"][0].clone()).unwrap();
    let rejection = match layer {
        "corePlan" => {
            let facts: StartFacts = serde_json::from_value(json!({
                "registration": input["context"]["registration"],
                "runtimeSelection": input["context"]["runtimeSelection"],
                "target": input["context"]["target"],
            }))
            .unwrap();
            let request = match input["context"].get("request") {
                Some(request) => serde_json::from_value(request.clone()).unwrap(),
                None => DebugRequest::Launch,
            };
            plan(&adapter, request, &facts)
        }
        "coreInstall" => {
            let resources: Vec<PackageResource> =
                serde_json::from_value(input["context"]["packageResources"].clone()).unwrap();
            check_package_resources(
                &serde_json::from_value::<Vec<DebugAdapterDeclaration>>(
                    plugin["debugAdapters"].clone(),
                )
                .unwrap(),
                &resources,
            )
        }
        other => panic!(
            "{}: layer {other} accepted the manifest: {outcome}",
            case["id"]
        ),
    };
    let rejection = rejection.expect_err("the case must be rejected");
    (
        rejection.code().into(),
        rejection.field().unwrap_or_default().into(),
    )
}

#[test]
fn debug_adapter_rejection_fixtures_report_their_code_and_field() {
    let fixtures: Value = serde_json::from_str(DEBUG_ADAPTER_REJECTIONS).unwrap();
    for case in fixtures["cases"].as_array().unwrap() {
        let (code, field) = debug_rejection(&fixtures["baseline"], case);
        assert_eq!(code, case["expected"]["code"], "{}", case["id"]);
        // Serde decode errors name the field only in their message.
        if case["layer"] != "schema" {
            assert_eq!(field, case["expected"]["field"], "{}", case["id"]);
        }
    }
}

#[test]
fn debug_adapter_executable_may_be_a_link_to_a_file_inside_the_package() {
    use crate::debug::adapters::{
        check_package_resources, DebugAdapterDeclaration, PackageResource,
    };
    let outcome = validate(fixture("debug-adapter.plugin.json"));
    let adapters: Vec<DebugAdapterDeclaration> =
        serde_json::from_value(outcome["plugin"]["debugAdapters"].clone()).unwrap();
    let resources: Vec<PackageResource> = serde_json::from_value(json!([
        {"path": "bin/example-dap", "kind": "symlink", "target": "../libexec/dap"},
        {"path": "libexec/dap", "kind": "file"},
        {"path": "schemas/launch.json", "kind": "file"},
    ]))
    .unwrap();
    check_package_resources(&adapters, &resources)
        .expect("a link to a packaged file is installable");

    // The same file declared in a non-canonical form is still the same file.
    let mut plain = serde_json::to_value(&adapters).unwrap();
    plain[0]["launch"]["process"]["launch"]["path"] = json!("./bin//example-dap");
    let adapters: Vec<DebugAdapterDeclaration> = serde_json::from_value(plain).unwrap();
    check_package_resources(&adapters, &resources).expect("path forms name one file");
}

#[test]
fn debug_adapter_fixture_is_accepted_with_normalized_requests() {
    let outcome = validate(fixture("debug-adapter.plugin.json"));
    assert_eq!(outcome["status"], "ok", "{outcome}");
    let adapter = &outcome["plugin"]["debugAdapters"][0];
    assert_eq!(adapter["requests"], json!(["launch", "attach"]));
    assert_eq!(adapter["launch"]["transport"], "stdio");
}

#[test]
fn debug_adapter_console_commands_are_sorted_for_the_host() {
    let outcome = validate(fixture("debug-adapter.plugin.json"));
    assert_eq!(outcome["status"], "ok", "{outcome}");
    let console = &outcome["plugin"]["debugAdapters"][0]["console"];
    assert_eq!(
        console["commands"],
        json!([
            { "name": "breakpoint set", "description": "Set a breakpoint" },
            { "name": "frame variable" },
        ])
    );
    assert_eq!(console["commandPrefix"], "`");
}

fn debug_start(request: &str, target: Value) -> Value {
    crate::plugins::declarative::debug_start_arguments_command(json!({
        "manifest": fixture("debug-adapter.plugin.json"),
        "adapterID": "example",
        "request": request,
        "facts": {
            "registration": { "generation": 3, "currentGeneration": 3 },
            "target": target,
        },
    }))
    .expect("payload is well formed")
}

#[test]
fn debug_adapter_launch_plan_carries_the_process_and_the_descriptor() {
    let plan = language_server_launch_plan_command(json!({
        "manifest": fixture("debug-adapter.plugin.json"),
        "debugAdapterID": "example",
        "request": {
            "pluginDirectory": "/plugins/example",
            "stateDirectory": "/state/example",
            "architecture": "arm64"
        },
    }))
    .expect("payload is well formed");
    assert_eq!(plan["status"], "ok", "{plan}");
    assert_eq!(
        plan["plan"]["launch"],
        json!({ "kind": "packaged", "path": "bin/example-dap" })
    );
    assert_eq!(plan["plan"]["arguments"], json!(["--stdio"]));
    let descriptor = &plan["plan"]["debugAdapter"];
    assert_eq!(
        descriptor["providerID"],
        "dev.lithe.fixture.debug-adapter/example"
    );
    assert_eq!(descriptor["adapterID"], "example-dap");
    assert_eq!(descriptor["transport"], "stdio");
    assert_eq!(
        descriptor["disabledCapabilities"],
        json!(["supportsStepBack"])
    );
}

#[test]
fn debug_adapter_launch_plan_refuses_unknown_adapters_and_mixed_selectors() {
    let request = json!({
        "pluginDirectory": "/plugins/example",
        "stateDirectory": "/state/example",
        "architecture": "arm64"
    });
    let missing = language_server_launch_plan_command(json!({
        "manifest": fixture("debug-adapter.plugin.json"),
        "debugAdapterID": "missing",
        "request": request,
    }))
    .expect("payload is well formed");
    assert_eq!(missing["error"]["code"], "plugin.launch.unavailable");
    assert!(language_server_launch_plan_command(json!({
        "manifest": fixture("debug-adapter.plugin.json"),
        "debugAdapterID": "example",
        "backend": true,
        "request": request,
    }))
    .is_err());
}

#[test]
fn debug_adapter_inside_the_language_server_has_no_process_of_its_own() {
    let outcome = validate(fixture("debug-adapter-language-server.plugin.json"));
    assert_eq!(outcome["status"], "ok", "{outcome}");
    let launch = &outcome["plugin"]["debugAdapters"][0]["launch"];
    assert_eq!(
        launch,
        &json!({
            "transport": "tcpLanguageServer",
            "endpoint": { "languageID": "example", "command": "example.startDebugSession" },
        })
    );

    // The adapter plans the plugin's language server, and the descriptor tells
    // the host which command to ask it for the port.
    let plan = language_server_launch_plan_command(json!({
        "manifest": fixture("debug-adapter-language-server.plugin.json"),
        "debugAdapterID": "example",
        "request": {
            "pluginDirectory": "/plugins/example",
            "stateDirectory": "/state/example",
            "architecture": "arm64"
        },
    }))
    .expect("payload is well formed");
    assert_eq!(plan["status"], "ok", "{plan}");
    assert_eq!(
        plan["plan"]["launch"],
        json!({ "kind": "systemCommand", "commands": ["example-ls"] })
    );
    let descriptor = &plan["plan"]["debugAdapter"];
    assert_eq!(
        descriptor["providerID"],
        "dev.lithe.fixture.debug-adapter-language-server/example"
    );
    assert_eq!(descriptor["transport"], "tcpLanguageServer");
    assert_eq!(
        descriptor["endpoint"],
        json!({ "languageID": "example", "command": "example.startDebugSession" })
    );
}

#[test]
fn debug_adapter_inside_the_language_server_is_a_reviewed_program() {
    let review = crate::plugins::marketplace::install_review_command(json!({
        "manifest": fixture("debug-adapter-language-server.plugin.json"),
    }))
    .expect("payload is well formed");
    let programs = review["review"]["programs"].as_array().unwrap();
    let adapter = programs
        .iter()
        .find(|program| program["debugAdapter"] == "example")
        .expect("the adapter is listed");
    assert_eq!(adapter["kind"], "languageServerDebugAdapter");
    assert_eq!(adapter["transport"], "tcpLanguageServer");
    // Pointing the adapter at another command is a new program to approve.
    assert_eq!(adapter["endpoint"]["command"], "example.startDebugSession");
    // The server itself stays a program of its own, reviewed once.
    assert!(programs
        .iter()
        .any(|program| program["languageID"] == "example"));
}

#[test]
fn debug_adapter_inside_the_language_server_rejects_inconsistent_launches() {
    let cases = [
        (
            "a process beside the language server",
            json!({
                "process": { "launch": { "kind": "systemCommand", "commands": ["x"] } },
                "transport": "tcpLanguageServer",
                "endpoint": { "languageID": "example", "command": "example.start" },
            }),
            "debugAdapters[0].launch.process",
        ),
        (
            "no endpoint",
            json!({ "transport": "tcpLanguageServer" }),
            "debugAdapters[0].launch.endpoint",
        ),
        (
            "a language server the plugin does not declare",
            json!({
                "transport": "tcpLanguageServer",
                "endpoint": { "languageID": "absent", "command": "example.start" },
            }),
            "debugAdapters[0].launch.endpoint.languageID",
        ),
        (
            "no language",
            json!({
                "transport": "tcpLanguageServer",
                "endpoint": { "command": "example.start" },
            }),
            "debugAdapters[0].launch.endpoint.languageID",
        ),
        (
            "a command with whitespace",
            json!({
                "transport": "tcpLanguageServer",
                "endpoint": { "languageID": "example", "command": "example start" },
            }),
            "debugAdapters[0].launch.endpoint.command",
        ),
        (
            "no command",
            json!({
                "transport": "tcpLanguageServer",
                "endpoint": { "languageID": "example" },
            }),
            "debugAdapters[0].launch.endpoint.command",
        ),
        (
            "a fixed port as well",
            json!({
                "transport": "tcpLanguageServer",
                "endpoint": { "languageID": "example", "command": "example.start", "port": 5005 },
            }),
            "debugAdapters[0].launch.endpoint",
        ),
        (
            "no process on stdio",
            json!({ "transport": "stdio" }),
            "debugAdapters[0].launch.process",
        ),
        (
            "language server fields on a fixed port",
            json!({
                "process": { "launch": { "kind": "systemCommand", "commands": ["x"] } },
                "transport": "tcpPort",
                "endpoint": { "port": 5005, "command": "example.start" },
            }),
            "debugAdapters[0].launch.endpoint",
        ),
    ];
    for (name, launch, field) in cases {
        let mut manifest = fixture("debug-adapter-language-server.plugin.json");
        manifest["debugAdapters"][0]["launch"] = launch;
        let outcome = validate(manifest);
        assert_eq!(outcome["status"], "rejected", "{name}: {outcome}");
        assert_eq!(
            outcome["error"]["code"], "plugin.manifest.invalid",
            "{name}: {outcome}"
        );
        assert_eq!(outcome["error"]["field"], field, "{name}: {outcome}");
    }
}

#[test]
fn debug_start_arguments_fill_bindings_without_overriding_defaults() {
    let launch = debug_start(
        "launch",
        json!({ "kind": "file", "path": "/work/main.ex", "workingDirectory": "/work" }),
    );
    assert_eq!(launch["status"], "ok", "{launch}");
    assert_eq!(
        launch["arguments"],
        json!({ "stopOnEntry": false, "program": "/work/main.ex", "cwd": "/work" })
    );
    let attach = debug_start("attach", json!({ "kind": "process", "processID": 42 }));
    assert_eq!(attach["arguments"], json!({ "processId": 42 }));
}

fn remote_start_with(manifest: Value, adapter: &str, request: &str, target: Value) -> Value {
    crate::plugins::declarative::debug_start_arguments_command(json!({
        "manifest": manifest,
        "adapterID": adapter,
        "request": request,
        "facts": {
            "registration": { "generation": 3, "currentGeneration": 3 },
            "target": target,
        },
    }))
    .expect("payload is well formed")
}

fn remote_start(adapter: &str, target: Value) -> Value {
    remote_start_with(
        fixture("debug-adapter-remote-attach.plugin.json"),
        adapter,
        "attach",
        target,
    )
}

/// A local source root, absolute on the platform the test runs on.
fn local_root() -> &'static str {
    if cfg!(windows) {
        r"C:\work\src"
    } else {
        "/work/src"
    }
}

fn connection_target(host: &str, port: u64) -> Value {
    json!({ "kind": "connection", "host": host, "port": port })
}

#[test]
fn debug_adapter_remote_attach_fixture_validates_and_keeps_its_bindings() {
    let outcome = validate(fixture("debug-adapter-remote-attach.plugin.json"));
    assert_eq!(outcome["status"], "ok", "{outcome}");
    let nested = outcome["plugin"]["debugAdapters"]
        .as_array()
        .unwrap()
        .iter()
        .find(|adapter| adapter["id"] == "nested")
        .expect("the fixture declares the nested adapter");
    assert_eq!(
        nested["configurations"]["attach"]["targetBindings"]["connection"],
        json!({
            "host": "connect.host",
            "port": "connect.port",
            "pathMappings": {
                "shape": "objects",
                "argument": "pathMappings",
                "localKey": "localRoot",
                "remoteKey": "remoteRoot",
            },
        })
    );
}

#[test]
fn debug_start_arguments_put_a_remote_endpoint_where_each_adapter_reads_it() {
    let flat = remote_start("flat", connection_target("build.example.org", 5005));
    assert_eq!(flat["status"], "ok", "{flat}");
    // Defaults stay and the endpoint joins them.
    assert_eq!(
        flat["arguments"],
        json!({ "timeout": 5000, "hostName": "build.example.org", "port": 5005 })
    );
    assert_eq!(
        flat["connection"],
        json!({ "host": "build.example.org", "port": 5005, "remote": true })
    );
    let nested = remote_start("nested", connection_target("build.example.org", 5678));
    assert_eq!(
        nested["arguments"],
        json!({
            "justMyCode": false,
            "connect": { "host": "build.example.org", "port": 5678 },
        })
    );
    let joined = remote_start("joined", connection_target("build.example.org", 2345));
    assert_eq!(
        joined["arguments"],
        json!({ "request": "attach", "target": "build.example.org:2345" })
    );
}

#[test]
fn debug_start_arguments_bracket_an_ipv6_host_only_in_a_joined_address() {
    let joined = remote_start("joined", connection_target("2001:db8::1", 2345));
    assert_eq!(joined["arguments"]["target"], "[2001:db8::1]:2345");
    let flat = remote_start("flat", connection_target("2001:db8::1", 2345));
    assert_eq!(flat["arguments"]["hostName"], "2001:db8::1");
    assert_eq!(flat["connection"]["host"], "2001:db8::1");
}

#[test]
fn debug_start_arguments_map_source_roots_in_the_shape_the_adapter_takes() {
    let local = local_root();
    let mut target = connection_target("build.example.org", 5678);
    target["pathMappings"] = json!([
        { "local": local, "remote": "/srv/app" },
        { "local": local, "remote": "/opt/lib" },
    ]);
    let nested = remote_start("nested", target.clone());
    assert_eq!(nested["status"], "ok", "{nested}");
    assert_eq!(
        nested["arguments"]["pathMappings"],
        json!([
            { "localRoot": local, "remoteRoot": "/srv/app" },
            { "localRoot": local, "remoteRoot": "/opt/lib" },
        ])
    );
    // An adapter with one local and one remote root takes one mapping.
    let mut single = connection_target("build.example.org", 5678);
    single["pathMappings"] = json!([{ "local": local, "remote": "/srv/app" }]);
    let scalar = remote_start("scalar", single);
    assert_eq!(
        scalar["arguments"],
        json!({
            "address": "build.example.org",
            "port": 5678,
            "localRoot": local,
            "remoteRoot": "/srv/app",
        })
    );
    // A dictionary is keyed by the side the binding names; the other root is
    // the value.
    let keyed = remote_start("keyed", target.clone());
    assert_eq!(keyed["status"], "ok", "{keyed}");
    assert_eq!(
        keyed["arguments"]["sourceMap"],
        json!({ "/srv/app": local, "/opt/lib": local })
    );
    // Pairs keep the order of the mappings and the roots within each pair.
    let paired = remote_start("paired", target);
    assert_eq!(paired["status"], "ok", "{paired}");
    assert_eq!(
        paired["arguments"]["sourceMap"],
        json!([["/srv/app", local], ["/opt/lib", local]])
    );
    // No mapping means no argument, not an empty one.
    for adapter in ["nested", "keyed", "paired"] {
        let none = remote_start(adapter, connection_target("build.example.org", 5678));
        assert_eq!(none["status"], "ok", "{adapter}: {none}");
        for name in ["pathMappings", "sourceMap"] {
            assert!(none["arguments"].get(name).is_none(), "{adapter}: {none}");
        }
    }
}

#[test]
fn debug_start_arguments_tell_the_host_which_endpoints_may_leave_this_machine() {
    for (host, remote) in [
        ("localhost", false),
        ("LocalHost", false),
        ("127.0.0.1", false),
        ("127.8.9.10", false),
        ("::1", false),
        ("10.0.0.5", true),
        ("0.0.0.0", true),
        ("build.example.org", true),
        // A name is never proven local from its text.
        ("localhost.example.org", true),
        ("::ffff:127.0.0.1", true),
    ] {
        let started = remote_start("flat", connection_target(host, 5005));
        assert_eq!(started["status"], "ok", "{host}: {started}");
        assert_eq!(started["connection"]["remote"], remote, "{host}");
    }
}

#[test]
fn debug_start_arguments_refuse_a_remote_target_without_a_usable_endpoint() {
    let too_long = format!("{}.example", "a".repeat(250));
    for host in [
        "",
        "http://build.example.org",
        "build.example.org:5005",
        "[::1]",
        "build example",
        "user@build.example.org",
        "build.example.org/path",
        "-build.example.org",
        "build..example.org",
        "1.2.3",
        "300.1.1.1.1",
        too_long.as_str(),
    ] {
        let refused = remote_start("flat", connection_target(host, 5005));
        assert_eq!(
            refused["error"]["code"], "debug.target.invalid",
            "{host}: {refused}"
        );
        assert_eq!(refused["error"]["field"], "target.host", "{host}");
    }
    let no_host = remote_start("flat", json!({ "kind": "connection", "port": 5005 }));
    assert_eq!(no_host["error"]["field"], "target.host", "{no_host}");
    let no_port = remote_start(
        "flat",
        json!({ "kind": "connection", "host": "build.example.org" }),
    );
    assert_eq!(no_port["error"]["field"], "target.port", "{no_port}");
    for port in [0_u64, 65_536, 4_294_967_296] {
        let refused = remote_start("flat", connection_target("build.example.org", port));
        assert_eq!(
            refused["error"]["code"], "debug.target.invalid",
            "{port}: {refused}"
        );
        assert_eq!(refused["error"]["field"], "target.port", "{port}");
    }
}

#[test]
fn debug_start_arguments_refuse_path_mappings_the_adapter_cannot_use() {
    let local = local_root();
    let with = |mappings: Value| {
        let mut target = connection_target("build.example.org", 5678);
        target["pathMappings"] = mappings;
        remote_start("nested", target)
    };
    let too_many: Vec<Value> = (0..17)
        .map(|index| json!({ "local": local, "remote": format!("/srv/{index}") }))
        .collect();
    for (name, mappings) in [
        ("too many", Value::Array(too_many)),
        ("empty remote", json!([{ "local": local, "remote": "" }])),
        ("empty local", json!([{ "local": "", "remote": "/srv" }])),
        (
            "multi-line remote",
            json!([{ "local": local, "remote": "/srv\n/etc" }]),
        ),
        (
            "relative local",
            json!([{ "local": "src", "remote": "/srv" }]),
        ),
    ] {
        let refused = with(mappings);
        assert_eq!(
            refused["error"]["code"], "debug.target.invalid",
            "{name}: {refused}"
        );
        assert_eq!(refused["error"]["field"], "target.pathMappings", "{name}");
    }
    // A shape that cannot hold everything the user gave is refused, not
    // trimmed: `scalar` takes one mapping, and a dictionary keyed by the remote
    // root has no room for two mappings from the same remote root.
    let mut two = connection_target("build.example.org", 5678);
    two["pathMappings"] = json!([
        { "local": local, "remote": "/srv/app" },
        { "local": local, "remote": "/opt/lib" },
    ]);
    let refused = remote_start("scalar", two);
    assert_eq!(
        refused["error"]["code"], "debug.target.invalid",
        "{refused}"
    );
    assert_eq!(
        refused["error"]["field"], "target.pathMappings",
        "{refused}"
    );
    let mut same_remote = connection_target("build.example.org", 5678);
    same_remote["pathMappings"] = json!([
        { "local": local, "remote": "/srv/app" },
        { "local": format!("{local}/other"), "remote": "/srv/app" },
    ]);
    let refused = remote_start("keyed", same_remote.clone());
    assert_eq!(
        refused["error"]["code"], "debug.target.invalid",
        "{refused}"
    );
    assert_eq!(
        refused["error"]["field"], "target.pathMappings",
        "{refused}"
    );
    // Pairs and objects hold the same root twice without loss.
    for adapter in ["paired", "nested"] {
        let kept = remote_start(adapter, same_remote.clone());
        assert_eq!(kept["status"], "ok", "{adapter}: {kept}");
    }
    // `flat` declares no mapping argument: dropping the mapping silently would
    // start a session whose breakpoints do not line up.
    let mut target = connection_target("build.example.org", 5005);
    target["pathMappings"] = json!([{ "local": local, "remote": "/srv" }]);
    let refused = remote_start("flat", target);
    assert_eq!(
        refused["error"]["field"], "target.pathMappings",
        "{refused}"
    );
}

#[test]
fn debug_start_arguments_keep_a_remote_target_to_adapters_that_attach_to_one() {
    // The fixture's adapters attach only, so a launch is refused as before.
    let launch = remote_start_with(
        fixture("debug-adapter-remote-attach.plugin.json"),
        "flat",
        "launch",
        connection_target("build.example.org", 5005),
    );
    assert_eq!(launch["error"]["code"], "debug.request.unsupported");
    // An adapter that attaches to a process has nowhere to put host and port,
    // and one that also launches may not be handed a connection to launch.
    for request in ["attach", "launch"] {
        let refused = remote_start_with(
            fixture("debug-adapter.plugin.json"),
            "example",
            request,
            connection_target("build.example.org", 5005),
        );
        assert_eq!(
            refused["error"]["code"], "debug.target.invalid",
            "{request}: {refused}"
        );
        assert_eq!(refused["error"]["field"], "target.kind", "{request}");
    }
}

#[test]
fn debug_adapter_launch_plan_says_which_adapters_attach_to_a_remote_endpoint() {
    let descriptor = |manifest: &str, adapter: &str| {
        let plan = language_server_launch_plan_command(json!({
            "manifest": fixture(manifest),
            "debugAdapterID": adapter,
            "request": {
                "pluginDirectory": "/plugins/example",
                "stateDirectory": "/state/example",
                "architecture": "arm64"
            },
        }))
        .expect("payload is well formed");
        assert_eq!(plan["status"], "ok", "{plan}");
        plan["plan"]["debugAdapter"]["remoteAttach"].clone()
    };
    let remote = "debug-adapter-remote-attach.plugin.json";
    // The host offers as many mapping rows as the adapter can hold.
    for (adapter, mappings, limit) in [
        ("flat", false, 0),
        ("joined", false, 0),
        ("nested", true, 16),
        ("scalar", true, 1),
        ("keyed", true, 16),
        ("paired", true, 16),
    ] {
        assert_eq!(
            descriptor(remote, adapter),
            json!({ "pathMappings": mappings, "maxPathMappings": limit }),
            "{adapter}"
        );
    }
    assert_eq!(
        descriptor("debug-adapter.plugin.json", "example"),
        Value::Null
    );
}

fn debug_start_native(target: Value) -> Value {
    crate::plugins::declarative::debug_start_arguments_command(json!({
        "manifest": fixture("debug-adapter.plugin.json"),
        "adapterID": "native",
        "request": "launch",
        "facts": {
            "registration": { "generation": 3, "currentGeneration": 3 },
            "target": target,
        },
    }))
    .expect("payload is well formed")
}

fn debug_executable_plan(adapter: &str, extra: Value) -> Value {
    let mut payload = json!({
        "manifest": fixture("debug-adapter.plugin.json"),
        "adapterID": adapter,
    });
    for (key, value) in extra.as_object().unwrap() {
        payload[key] = value.clone();
    }
    crate::plugins::declarative::debug_executable_plan_command(payload)
        .expect("payload is well formed")
}

#[test]
fn debug_start_arguments_bind_program_to_the_resolved_executable() {
    // The host resolves a native path, and "absolute" depends on the platform.
    let executable = if cfg!(windows) {
        r"C:\work\main"
    } else {
        "/work/main"
    };
    let launch = debug_start_native(json!({
        "kind": "file",
        "path": "/work/main.c",
        "workingDirectory": "/work",
        "executable": executable,
    }));
    assert_eq!(launch["status"], "ok", "{launch}");
    // The source file is never the program: the host resolved the binary.
    assert_eq!(
        launch["arguments"],
        json!({ "stopOnEntry": false, "program": executable, "cwd": "/work" })
    );
}

#[test]
fn debug_start_arguments_need_an_absolute_resolved_executable() {
    for executable in [None, Some(""), Some("main"), Some("./main")] {
        let mut target = json!({
            "kind": "file",
            "path": "/work/main.c",
            "workingDirectory": "/work",
        });
        if let Some(executable) = executable {
            target["executable"] = json!(executable);
        }
        let refused = debug_start_native(target);
        assert_eq!(
            refused["error"]["code"], "debug.target.invalid",
            "{refused}"
        );
        assert_eq!(refused["error"]["field"], "target.executable", "{refused}");
    }
}

#[test]
fn debug_executable_plan_lists_the_configured_path_and_ordered_candidates() {
    let plan = debug_executable_plan(
        "native",
        json!({
            "workspace": "/work/",
            "targetPath": "/work/src/main.c",
            "settings": { "program": "/global/app" },
            "projectSettings": { "program": "/work/out/app" },
        }),
    );
    assert_eq!(plan["status"], "ok", "{plan}");
    assert_eq!(
        plan["plan"],
        json!({
            "setting": "program",
            // A project value wins over the global one and says where it came from.
            "configured": { "path": "/work/out/app", "source": "project" },
            "candidates": ["/work/src/main", "/work/build/main"],
        })
    );
}

#[test]
fn debug_executable_plan_reports_no_configured_path_when_the_setting_is_empty() {
    let plan = debug_executable_plan(
        "native",
        json!({ "workspace": "/work", "targetPath": "/work/main.c" }),
    );
    assert_eq!(plan["plan"]["configured"], Value::Null, "{plan}");
    let global = debug_executable_plan(
        "native",
        json!({
            "workspace": "/work",
            "targetPath": "/work/main.c",
            "settings": { "program": "/opt/app" },
        }),
    );
    assert_eq!(
        global["plan"]["configured"],
        json!({ "path": "/opt/app", "source": "global" })
    );
}

#[test]
fn debug_executable_plan_skips_candidates_it_has_no_facts_for() {
    // The settings page has a project but no source file: a candidate named
    // after the file cannot be looked for, so it is left out, not guessed.
    let plan = debug_executable_plan("native", json!({ "workspace": "/work" }));
    assert_eq!(plan["plan"]["candidates"], json!([]), "{plan}");
    let no_project = debug_executable_plan("native", json!({ "targetPath": "/work/main.c" }));
    assert_eq!(
        no_project["plan"]["candidates"],
        json!(["/work/main"]),
        "{no_project}"
    );
}

#[test]
fn debug_executable_plan_is_empty_for_an_adapter_without_a_lookup() {
    let plan = debug_executable_plan("example", json!({ "workspace": "/work" }));
    assert_eq!(plan["status"], "ok", "{plan}");
    assert_eq!(plan["plan"], Value::Null);
    let missing = debug_executable_plan("absent", json!({}));
    assert_eq!(missing["error"]["code"], "plugin.launch.unavailable");
}

#[test]
fn debug_start_arguments_refuse_stale_registrations_and_missing_target_facts() {
    let missing = debug_start("launch", json!({ "kind": "file" }));
    assert_eq!(missing["error"]["code"], "debug.target.invalid");
    let stale = crate::plugins::declarative::debug_start_arguments_command(json!({
        "manifest": fixture("debug-adapter.plugin.json"),
        "adapterID": "example",
        "request": "launch",
        "facts": {
            "registration": { "generation": 2, "currentGeneration": 3 },
            "target": { "kind": "file", "path": "/work/main.ex" },
        },
    }))
    .expect("payload is well formed");
    assert_eq!(stale["error"]["code"], "debug.provider.stale");
}

/// Backend commands are install-time gated by ui 4, and read permissions grant
/// only their own methods rather than an entire growing service namespace.
#[test]
fn pure_backend_commands_require_ui_4_and_grant_methods_individually() {
    let manifest: Value =
        serde_json::from_str(contract_file!("fixtures/command-backend.plugin.json")).unwrap();
    assert_eq!(validate(manifest.clone())["status"], "ok");
    let mut old = manifest.clone();
    old["requires"]["ui"] = json!(3);
    assert_ne!(validate(old)["status"], "ok");
    let hosted = validate_command(json!({"manifest": manifest, "hostCapabilities": {"backend":[2],"serverProcess":[1],"ui":[1,2,3]}})).unwrap();
    assert_eq!(hosted["error"]["code"], "plugin.api.unsupported");
    let plan = language_server_launch_plan_command(json!({
        "manifest": manifest, "backend": true,
        "request": {"pluginDirectory":"/plugins/example","stateDirectory":"/state/example","architecture":"arm64"}
    })).unwrap();
    let grants = plan["plan"]["backend"]["hostServices"].as_array().unwrap();
    assert!(grants.contains(&json!("lithe/host/editor/getSelections")));
    assert!(grants.contains(&json!("lithe/host/editor/applyEdits")));
    assert!(!grants.contains(&json!("editor")));
    assert!(!grants.contains(&json!("lithe/host/workspace/readFile")));
}
