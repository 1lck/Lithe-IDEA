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
const HELLO_FIXTURE: &str = contract_file!("fixtures/hello-lithe.plugin.json");
const WEB_PANEL_FIXTURE: &str = contract_file!("fixtures/web-panel.plugin.json");
const GO_FIXTURE: &str = contract_file!("fixtures/go-support.plugin.json");
const JAVA_FIXTURE: &str = contract_file!("fixtures/java-support.plugin.json");
const NODE_RUNTIME_FIXTURE: &str = contract_file!("fixtures/node-runtime.plugin.json");
const CARGO_BUILD_FIXTURE: &str = contract_file!("fixtures/cargo-build.plugin.json");
const GO_BUILD_FIXTURE: &str = contract_file!("fixtures/go-build.plugin.json");
const GRADLE_BUILD_FIXTURE: &str = contract_file!("fixtures/gradle-build.plugin.json");
const MAVEN_BUILD_FIXTURE: &str = contract_file!("fixtures/maven-build.plugin.json");
const GRADLE_PROVIDER_FIXTURE: &str = contract_file!("fixtures/gradle-provider.plugin.json");
const MIX_PROVIDER_FIXTURE: &str = contract_file!("fixtures/mix-provider.plugin.json");
const INVALID_MANIFESTS: &str = contract_file!("fixtures/invalid-manifests.json");
const COMMAND_PLANS: &str = contract_file!("fixtures/command-plans.json");
const RUNTIME_VERSIONS: &str = contract_file!("fixtures/runtime-versions.json");
const OFFICIAL_JAVA: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../Plugins/mac/Official/JavaSupport/plugin.json"
));

fn fixture(name: &str) -> Value {
    let source = match name {
        "php-support.plugin.json" => PHP_FIXTURE,
        "go-support.plugin.json" => GO_FIXTURE,
        "hello-lithe.plugin.json" => HELLO_FIXTURE,
        "web-panel.plugin.json" => WEB_PANEL_FIXTURE,
        "java-support.plugin.json" => JAVA_FIXTURE,
        "node-runtime.plugin.json" => NODE_RUNTIME_FIXTURE,
        "cargo-build.plugin.json" => CARGO_BUILD_FIXTURE,
        "go-build.plugin.json" => GO_BUILD_FIXTURE,
        "gradle-build.plugin.json" => GRADLE_BUILD_FIXTURE,
        "maven-build.plugin.json" => MAVEN_BUILD_FIXTURE,
        "gradle-provider.plugin.json" => GRADLE_PROVIDER_FIXTURE,
        "mix-provider.plugin.json" => MIX_PROVIDER_FIXTURE,
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
        assert_eq!(
            outcome["error"]["code"], "plugin.manifest.invalid",
            "{outcome}"
        );
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

/// The validation probe runs before the host has read the plugin's settings,
/// so it cannot depend on one.
#[test]
fn validation_probe_cannot_use_settings() {
    let mut manifest = fixture("go-support.plugin.json");
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
    let mix = fixture("mix-provider.plugin.json");
    let outcome = validate(mix.clone());
    assert_eq!(outcome["status"], "ok", "{outcome}");
    assert_eq!(
        outcome["plugin"]["requires"],
        json!({ "buildProviders": 1, "buildSystems": 1, "languageServers": 1, "languages": 1, "serverProcess": 1 })
    );
    let legacy = validate(fixture("php-support.plugin.json"));
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
    let mut language_only = fixture("php-support.plugin.json");
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
        validate_on(&fixture("php-support.plugin.json"), &json!({}))["status"],
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
        "manifest": fixture("cargo-build.plugin.json"), "hostCapabilities": host
    }))
    .unwrap();
    assert_eq!(template["status"], "ok", "{template}");

    for (name, build_system_id) in [
        ("gradle-provider.plugin.json", "gradle"),
        ("mix-provider.plugin.json", "mix"),
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
