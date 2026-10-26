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
const CARGO_BUILD_FIXTURE: &str = contract_file!("fixtures/build-static-file.plugin.json");
const GO_BUILD_FIXTURE: &str = contract_file!("fixtures/build-command-stdout.plugin.json");
const GRADLE_BUILD_FIXTURE: &str = contract_file!("fixtures/build-command-output-file.plugin.json");
const MAVEN_BUILD_FIXTURE: &str = contract_file!("fixtures/build-host-integration.plugin.json");
const GRADLE_PROVIDER_FIXTURE: &str = contract_file!("fixtures/build-provider.plugin.json");
const MIX_PROVIDER_FIXTURE: &str =
    contract_file!("fixtures/build-provider-language-server.plugin.json");
const SETTINGS_V2_FIXTURE: &str = contract_file!("fixtures/settings-v2.plugin.json");
const BACKEND_FIXTURE: &str = contract_file!("fixtures/backend.plugin.json");
const DEBUG_ADAPTER_FIXTURE: &str = contract_file!("fixtures/debug-adapter.plugin.json");
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
        "debug-adapter.plugin.json" => DEBUG_ADAPTER_FIXTURE,
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
        BACKEND_FIXTURE,
        DEBUG_ADAPTER_FIXTURE,
        OFFICIAL_JAVA,
    ] {
        let outcome = validate(serde_json::from_str(source).unwrap());
        assert_eq!(outcome["status"], "ok", "{outcome}");
    }
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
            plan(&adapter, DebugRequest::Launch, &facts)
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
        other => panic!("{}: layer {other} accepted the manifest: {outcome}", case["id"]),
    };
    let rejection = rejection.expect_err("the case must be rejected");
    (rejection.code().into(), rejection.field().unwrap_or_default().into())
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
fn debug_adapter_fixture_is_accepted_with_normalized_requests() {
    let outcome = validate(fixture("debug-adapter.plugin.json"));
    assert_eq!(outcome["status"], "ok", "{outcome}");
    let adapter = &outcome["plugin"]["debugAdapters"][0];
    assert_eq!(adapter["requests"], json!(["launch", "attach"]));
    assert_eq!(adapter["launch"]["transport"], "stdio");
}
