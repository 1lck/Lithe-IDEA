//! Plugin-started runs and debug sessions, tool-reference launches, and output links.
//!
//! The shared contract fixtures decide what every host must accept and reject; the tests
//! below them cover the limits that depend on the host's file system or are too large to
//! keep as fixtures.

use super::support::temporary_root;
use crate::build::run_decode_start_command;
use crate::debug::decode_backend_configuration_command;
use crate::plugins::declarative::{language_server_launch_plan_command, validate_manifest_value};
use crate::plugins::output_links::{decode_resolution, match_lines};
use crate::toolchain::instantiate_launch_command;
use serde_json::{json, Value};
use std::fs;
use std::path::PathBuf;

macro_rules! contract_file {
    ($path:literal) => {
        include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/contracts/plugins/v1/",
            $path
        ))
    };
}

const RUN_START: &str = contract_file!("fixtures/run/run-start.json");
const DEBUG_START: &str = contract_file!("fixtures/debug-adapters/debug-start.json");
const OUTPUT_LINK_MATCHERS: &str = contract_file!("fixtures/run/output-link-matchers.json");
const TOOL_REFERENCE_MANIFEST: &str =
    contract_file!("fixtures/run/tool-reference-launch.plugin.json");
const DEBUG_FEATURES_MANIFEST: &str =
    contract_file!("fixtures/debug-adapters/debug-adapter-features.plugin.json");

fn parse(source: &str) -> Value {
    serde_json::from_str(source).expect("contract fixture is JSON")
}

/// The manifest a fixture file names in its `manifest` member.
fn named_manifest(fixture: &Value) -> Value {
    match fixture["manifest"].as_str() {
        Some("tool-reference-launch.plugin.json") => parse(TOOL_REFERENCE_MANIFEST),
        Some("debug-adapter-features.plugin.json") => parse(DEBUG_FEATURES_MANIFEST),
        other => panic!("fixture names an unknown manifest: {other:?}"),
    }
}

/// A workspace directory that is removed when dropped, so a failed assertion cleans up too.
struct Workspace(PathBuf);

impl Workspace {
    fn new(label: &str, directories: &[&str]) -> Self {
        let root = temporary_root(label);
        fs::create_dir_all(&root).unwrap();
        for directory in directories {
            fs::create_dir_all(root.join(directory)).unwrap();
        }
        Self(root)
    }

    fn root(&self) -> String {
        self.0.to_string_lossy().into_owned()
    }
}

impl Drop for Workspace {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// Asserts a `{status:"rejected"}` outcome with the given code and field.
fn assert_rejected(outcome: &Value, code: &str, field: &str, context: &str) {
    assert_eq!(outcome["status"], "rejected", "{context}: {outcome}");
    assert_eq!(outcome["error"]["code"], code, "{context}: {outcome}");
    assert_eq!(outcome["error"]["field"], field, "{context}: {outcome}");
}

fn start_run(workspace: &Workspace, params: Value, temporary_directory: Option<&str>) -> Value {
    let mut payload = json!({
        "manifest": parse(TOOL_REFERENCE_MANIFEST),
        "workspaceRoot": workspace.root(),
        "params": params,
    });
    if let Some(directory) = temporary_directory {
        payload["temporaryDirectory"] = json!(directory);
    }
    run_decode_start_command(payload).expect("payload is well formed")
}

/// A start of the fixture's required tool with room to vary the rest.
fn tool_run(arguments: Value, environment: Value, temporary_files: Value) -> Value {
    json!({
        "label": "Run main.script",
        "process": {
            "executable": { "kind": "tool", "tool": "interpreter" },
            "arguments": arguments,
            "workingDirectory": ".",
            "environment": environment,
        },
        "temporaryFiles": temporary_files,
    })
}

#[test]
fn run_start_fixture_cases_decode_the_same_in_every_host() {
    let fixture = parse(RUN_START);
    let directories: Vec<&str> = fixture["workspaceDirectories"]
        .as_array()
        .unwrap()
        .iter()
        .map(|directory| directory.as_str().unwrap())
        .collect();
    let workspace = Workspace::new("run-start-fixture", &directories);
    let manifest = named_manifest(&fixture);
    for case in fixture["cases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let outcome = run_decode_start_command(json!({
            "manifest": manifest,
            "workspaceRoot": workspace.root(),
            "params": case["params"],
        }))
        .expect("payload is well formed");
        if let Some(start) = case.get("start") {
            assert_eq!(outcome["status"], "ok", "{name}: {outcome}");
            assert_eq!(&outcome["start"], start, "{name}");
        } else {
            let error = &case["error"];
            assert_rejected(
                &outcome,
                error["code"].as_str().unwrap(),
                error["field"].as_str().unwrap(),
                name,
            );
        }
    }
}

#[test]
fn temporary_files_get_final_paths_that_arguments_and_environment_can_name() {
    let workspace = Workspace::new("run-start-files", &[]);
    let directory = temporary_root("run-start-files-directory");
    let directory_text = directory.to_string_lossy().into_owned();
    let path = format!("{directory_text}{}launch.cfg", std::path::MAIN_SEPARATOR);

    let outcome = start_run(
        &workspace,
        tool_run(
            json!(["--config=${temporaryFile:launch.cfg}", "${HOME}"]),
            json!({ "CONFIG": "${temporaryFile:launch.cfg}" }),
            json!([{ "name": "launch.cfg", "contents": "mode = 1\n" }]),
        ),
        // A trailing separator must not double up in the final path.
        Some(&format!("{directory_text}/")),
    );

    assert_eq!(outcome["status"], "ok", "{outcome}");
    let start = &outcome["start"];
    // Only the temporary file reference is replaced; any other `${...}` is data.
    assert_eq!(
        start["arguments"],
        json!([format!("--config={path}"), "${HOME}"])
    );
    assert_eq!(start["environment"], json!({ "CONFIG": path }));
    assert_eq!(
        start["temporaryFiles"],
        json!([{ "path": path, "contents": "mode = 1\n" }])
    );
    // Core plans the file; writing it is the host's job.
    assert!(!directory.exists());
}

#[test]
fn temporary_files_refuse_what_the_host_could_not_write_safely() {
    let workspace = Workspace::new("run-start-bad-files", &[]);
    let absolute = temporary_root("run-start-bad-files-directory")
        .to_string_lossy()
        .into_owned();
    let too_large = "x".repeat(4 * 1024 * 1024 + 1);
    let file = |name: &str| json!({ "name": name, "contents": "" });

    let cases = [
        (
            "the host gave no temporary directory",
            tool_run(json!([]), json!({}), json!([file("a")])),
            None,
            "temporaryDirectory",
        ),
        (
            "the temporary directory is relative",
            tool_run(json!([]), json!({}), json!([file("a")])),
            Some("relative/directory"),
            "temporaryDirectory",
        ),
        (
            "two files share a name",
            tool_run(json!([]), json!({}), json!([file("a"), file("a")])),
            Some(absolute.as_str()),
            "temporaryFiles[1].name",
        ),
        (
            "a name that leaves the directory",
            tool_run(json!([]), json!({}), json!([file("../a")])),
            Some(absolute.as_str()),
            "temporaryFiles[0].name",
        ),
        (
            "a name that starts with a dot",
            tool_run(json!([]), json!({}), json!([file(".a")])),
            Some(absolute.as_str()),
            "temporaryFiles[0].name",
        ),
        (
            "contents beyond 4 MiB",
            tool_run(
                json!([]),
                json!({}),
                json!([{ "name": "a", "contents": too_large }]),
            ),
            Some(absolute.as_str()),
            "temporaryFiles[0].contents",
        ),
        (
            "contents with a NUL",
            tool_run(
                json!([]),
                json!({}),
                json!([{ "name": "a", "contents": "a\u{0}b" }]),
            ),
            Some(absolute.as_str()),
            "temporaryFiles[0].contents",
        ),
        (
            "a reference to a file the start does not declare",
            tool_run(json!(["${temporaryFile:missing}"]), json!({}), json!([])),
            Some(absolute.as_str()),
            "process.arguments[0]",
        ),
        (
            "a reference that is not closed",
            tool_run(
                json!(["x", "${temporaryFile:a"]),
                json!({}),
                json!([file("a")]),
            ),
            Some(absolute.as_str()),
            "process.arguments[1]",
        ),
        (
            "an environment value naming an undeclared file",
            tool_run(
                json!([]),
                json!({ "CONFIG": "${temporaryFile:missing}" }),
                json!([]),
            ),
            Some(absolute.as_str()),
            "process.environment.CONFIG",
        ),
    ];
    for (name, params, directory, field) in cases {
        let outcome = start_run(&workspace, params, directory);
        assert_rejected(&outcome, "plugin.run.invalidStart", field, name);
    }
}

#[test]
fn a_start_with_four_temporary_files_is_accepted() {
    let workspace = Workspace::new("run-start-four-files", &[]);
    let directory = temporary_root("run-start-four-files-directory")
        .to_string_lossy()
        .into_owned();
    let files: Vec<Value> = ["a", "b", "c", "d"]
        .iter()
        .map(|name| json!({ "name": name, "contents": "x" }))
        .collect();

    let outcome = start_run(
        &workspace,
        tool_run(json!([]), json!({}), json!(files)),
        Some(&directory),
    );

    assert_eq!(outcome["status"], "ok", "{outcome}");
    assert_eq!(
        outcome["start"]["temporaryFiles"].as_array().unwrap().len(),
        4
    );
}

#[test]
fn debug_start_fixture_cases_decode_the_same_in_every_host() {
    let fixture = parse(DEBUG_START);
    let manifest = named_manifest(&fixture);
    for case in fixture["cases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let outcome = decode_backend_configuration_command(json!({
            "manifest": manifest,
            "params": case["params"],
        }))
        .expect("payload is well formed");
        if let Some(start) = case.get("start") {
            assert_eq!(outcome["status"], "ok", "{name}: {outcome}");
            assert_eq!(&outcome["start"], start, "{name}");
        } else {
            let error = &case["error"];
            assert_rejected(
                &outcome,
                error["code"].as_str().unwrap(),
                error["field"].as_str().unwrap(),
                name,
            );
        }
    }
}

#[test]
fn debug_start_configuration_is_limited_to_256_kib() {
    let start = |filler: usize| {
        decode_backend_configuration_command(json!({
            "manifest": parse(DEBUG_FEATURES_MANIFEST),
            "params": {
                "label": "Debug",
                "adapter": "script",
                "request": "launch",
                "configuration": { "program": "x".repeat(filler) },
            },
        }))
        .expect("payload is well formed")
    };
    // The serialized object also holds the member name and punctuation.
    let overhead = r#"{"program":""}"#.len();

    assert_eq!(start(256 * 1024 - overhead)["status"], "ok");
    assert_rejected(
        &start(256 * 1024 - overhead + 1),
        "plugin.debug.limitExceeded",
        "configuration",
        "one byte over the limit",
    );
}

#[test]
fn output_link_fixture_cases_match_the_same_in_every_host() {
    let fixture = parse(OUTPUT_LINK_MATCHERS);
    for case in fixture["match"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let reply = match_lines(case["request"].clone()).expect("request is well formed");
        assert_eq!(reply["links"], case["links"], "{name}");
    }
    for case in fixture["resolution"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let decoded = decode_resolution(json!({ "reply": case["reply"] }));
        if case["invalid"] == json!(true) {
            assert!(decoded.is_err(), "{name}");
        } else {
            assert_eq!(decoded.expect(name), case["location"], "{name}");
        }
    }
}

#[test]
fn output_link_matchers_alone_are_a_complete_plugin() {
    let manifest = json!({
        "schemaVersion": 2, "id": "dev.example.links", "displayName": "Script Links",
        "version": "1.0.0", "pluginAPIVersion": 4, "requires": {"outputLinkMatchers": 1},
        "vendor": {"id": "org.example", "displayName": "Example", "signatureRequirement": "publisherPackage"},
        "permissions": [], "activationEvents": [], "languages": [],
        "outputLinkMatchers": [
            {"id": "traceback", "pattern": "File \"(?P<path>[^\"]+)\", line (?P<line>\\d+)", "scope": "run"},
            {"id": "assertion", "pattern": "(?P<path>\\S+\\.script):(?P<line>\\d+)"}
        ]
    });
    let validated = validate_manifest_value(manifest).expect("matchers alone are a plugin");
    let ids: Vec<_> = serde_json::to_value(&validated).unwrap()["outputLinkMatchers"]
        .as_array()
        .unwrap()
        .iter()
        .map(|matcher| matcher["id"].clone())
        .collect();
    // Core sorts matchers by ID.
    assert_eq!(ids, [json!("assertion"), json!("traceback")]);
}

fn instantiate(tool_definition: Value, parts: Value) -> Value {
    let mut input = json!({
        "registry": { "plugins": [{ "manifest": tool_definition }] },
        "tool": "interpreter",
        "executable": "/opt/interpreter/bin/interpreter",
    });
    for (key, value) in parts.as_object().unwrap() {
        input[key] = value.clone();
    }
    instantiate_launch_command(input).expect("input is well formed")
}

#[test]
fn the_definition_decides_how_its_tool_starts_an_entry() {
    let outcome = instantiate(
        parse(TOOL_REFERENCE_MANIFEST),
        json!({
            "entry": "/plugins/script/language-server/server.script",
            "runtimeArguments": ["-X", "utf8"],
            "arguments": ["--stdio"],
        }),
    );

    assert_eq!(outcome["status"], "ok", "{outcome}");
    assert_eq!(
        outcome["launch"],
        json!({
            "executable": "/opt/interpreter/bin/interpreter",
            "arguments": ["-X", "utf8", "/plugins/script/language-server/server.script", "--stdio"],
            "versionArguments": ["--version"],
        })
    );
}

#[test]
fn a_launch_the_definition_cannot_express_is_a_mismatch() {
    // A tool whose launch has no place for runtime arguments.
    let mut without_runtime_arguments = parse(TOOL_REFERENCE_MANIFEST);
    without_runtime_arguments["toolDefinitions"][0]["launch"] =
        json!(["${executable}", "${entry}", "${arguments}"]);

    let cases = [
        (
            "the definition launches an entry and none is given",
            parse(TOOL_REFERENCE_MANIFEST),
            json!({ "arguments": ["--stdio"] }),
        ),
        (
            "runtime arguments the template cannot carry",
            without_runtime_arguments,
            json!({ "entry": "/plugins/script/server.script", "runtimeArguments": ["-X"] }),
        ),
    ];
    for (name, manifest, parts) in cases {
        let outcome = instantiate(manifest, parts);
        assert_eq!(outcome["status"], "rejected", "{name}: {outcome}");
        assert_eq!(
            outcome["error"]["code"], "plugin.toolchain.launchMismatch",
            "{name}: {outcome}"
        );
    }
}

#[test]
fn launching_a_tool_nobody_defined_is_refused() {
    let outcome = instantiate_launch_command(json!({
        "registry": { "plugins": [{
            "manifest": parse(TOOL_REFERENCE_MANIFEST),
        }] },
        "tool": "missing-tool",
        "executable": "/opt/missing/bin/tool",
    }))
    .expect("input is well formed");

    assert_rejected(
        &outcome,
        "plugin.toolchain.invalidParams",
        "tool",
        "unknown tool",
    );
}

#[test]
fn a_tool_reference_launch_plan_hands_the_host_the_parts_of_the_launch() {
    let plan = language_server_launch_plan_command(json!({
        "manifest": parse(TOOL_REFERENCE_MANIFEST),
        "languageID": "script",
        "request": {
            "pluginDirectory": "/plugins/script",
            "stateDirectory": "/state/script",
            "architecture": "arm64",
        },
    }))
    .expect("payload is well formed");

    assert_eq!(plan["status"], "ok", "{plan}");
    let plan = &plan["plan"];
    assert_eq!(
        plan["launch"],
        json!({
            "kind": "tool",
            "tool": "interpreter",
            "entry": "/plugins/script/language-server/server.script",
            "runtimeArguments": ["-X", "utf8"],
            "minimumVersion": "3.9",
        })
    );
    // The definition's launch template, not the plan, orders these with the entry.
    assert_eq!(plan["arguments"], json!(["--stdio"]));
    assert_eq!(
        plan["runtimeRequirements"],
        json!([{ "kind": "tool", "tool": "interpreter", "minimumVersion": "3.9" }])
    );
    assert_eq!(
        plan["requiredPackagePaths"],
        json!(["language-server/server.script"])
    );
}

#[test]
fn a_declared_debug_adapter_hands_its_features_and_defaults_to_the_host() {
    let plan = language_server_launch_plan_command(json!({
        "manifest": parse(DEBUG_FEATURES_MANIFEST),
        "debugAdapterID": "script",
        "request": {
            "pluginDirectory": "/plugins/script",
            "stateDirectory": "/state/script",
            "architecture": "arm64",
        },
    }))
    .expect("payload is well formed");

    assert_eq!(plan["status"], "ok", "{plan}");
    let descriptor = &plan["plan"]["debugAdapter"];
    assert_eq!(
        descriptor["features"]["hotCodeReplace"],
        json!({
            "request": "script.reload",
            "event": "script.reloaded",
            "changedField": "modules",
            "errorField": "error",
        })
    );
    assert_eq!(
        descriptor["features"]["stepFilters"],
        json!({ "argument": "stepFilters" })
    );
    assert!(descriptor["defaults"]["stepFilters"].is_object());
}
