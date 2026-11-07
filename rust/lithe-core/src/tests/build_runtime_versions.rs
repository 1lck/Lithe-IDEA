//! Host runtimes keep Core's version probe; any other runtime names the tool
//! definition with the same ID, which checks the version itself.

use crate::build::{build_check_tool_version_command, build_invocation_plan_command};
use serde_json::{json, Value};

fn manifest() -> Value {
    serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../shared/contracts/plugins/v1/fixtures/build-systems/build-toolchains.plugin.json"
    )))
    .expect("Cargo fixture is valid JSON")
}

fn plan(manifest: Value, platform: &str) -> Value {
    build_invocation_plan_command(json!({
        "manifest": manifest,
        "buildSystemID": "cargo",
        "request": { "root": ".", "platform": platform }
    }))
    .expect("invocation request is valid")
}

fn check(manifest: Value, runtime: &str, output: &str) -> Value {
    build_check_tool_version_command(json!({
        "manifest": manifest,
        "buildSystemID": "cargo",
        "request": { "runtime": runtime, "output": output }
    }))
    .expect("version request is valid")
}

#[test]
fn host_runtime_probe_arguments_are_portable_across_platforms() {
    for platform in ["macos", "linux", "windows"] {
        let mut manifest = manifest();
        manifest["buildSystems"][0]["invocation"]["runtimeDependencies"] = json!([
            { "id": "node", "minimumVersion": "20" },
            { "id": "go", "minimumVersion": "1.22" }
        ]);
        let result = plan(manifest, platform);
        assert_eq!(result["status"], "ok", "{platform}: {result}");
        let runtimes = &result["invocation"]["runtimeDependencies"];
        for (index, arguments) in [json!(["--version"]), json!(["version"])]
            .into_iter()
            .enumerate()
        {
            assert_eq!(runtimes[index]["hostManaged"], true, "{platform}");
            assert_eq!(runtimes[index]["executables"], json!([]), "{platform}");
            assert_eq!(
                runtimes[index]["version"]["arguments"], arguments,
                "{platform}"
            );
        }
        // The build tool's own probe stays independent of its runtimes.
        assert_eq!(
            result["invocation"]["version"]["arguments"],
            json!(["--version"])
        );
    }
}

/// A published manifest that names `vm` without executables keeps
/// validating; the plan resolves it through the tool definition `vm`.
#[test]
fn runtime_without_executables_becomes_a_toolchain_candidate() {
    for platform in ["macos", "linux", "windows"] {
        let mut manifest = manifest();
        manifest["buildSystems"][0]["invocation"]["runtimeDependencies"] =
            json!([{ "id": "vm", "minimumVersion": "8" }]);
        let result = plan(manifest, platform);
        assert_eq!(result["status"], "ok", "{platform}: {result}");
        assert_eq!(
            result["invocation"]["runtimeDependencies"][0],
            json!({
                "id": "vm",
                "displayName": null,
                "hostManaged": false,
                "executables": [
                    { "kind": "toolchain", "toolchainID": "vm", "root": "." }
                ],
                "version": null,
                "minimumVersion": "8"
            }),
            "{platform}"
        );
    }
}

#[test]
fn runtime_named_by_tool_definition_has_no_core_probe() {
    let mut manifest = manifest();
    manifest["buildSystems"][0]["invocation"]["runtimeDependencies"] =
        json!([{ "id": "vm", "minimumVersion": "8" }]);
    let result = check(manifest, "vm", "21.0.4\n");
    assert_eq!(
        result,
        json!({
            "status": "rejected",
            "error": {
                "code": "plugin.build.unavailable",
                "message": "Cargo declares no version probe for vm; its tool definition checks the version."
            }
        })
    );
}

#[test]
fn host_runtime_output_reads_the_first_dotted_number() {
    for (runtime, minimum, output, satisfied, version) in [
        ("node", "20", "v20.11.0\n", true, "20.11.0"),
        (
            "node",
            "20",
            "warning: custom build\nv18.20.4\n",
            false,
            "18.20.4",
        ),
        (
            "go",
            "1.22",
            "go version go1.22.3 darwin/arm64\n",
            true,
            "1.22.3",
        ),
        (
            "go",
            "1.22",
            "go version go1.21.9 linux/amd64\n",
            false,
            "1.21.9",
        ),
    ] {
        let mut manifest = manifest();
        manifest["buildSystems"][0]["invocation"]["runtimeDependencies"] =
            json!([{ "id": runtime, "minimumVersion": minimum }]);
        let result = check(manifest, runtime, output);
        assert_eq!(result["status"], "ok", "{result}");
        assert_eq!(
            result["version"],
            json!({ "satisfied": satisfied, "version": version }),
            "{runtime} {output}"
        );
    }
}

/// Only a valid tool-definition ID can stand for a runtime the plugin does
/// not describe.
#[test]
fn runtime_without_executables_needs_a_tool_definition_id() {
    for id in ["Vm", "vm 17", "17-vm"] {
        let mut manifest = manifest();
        manifest["buildSystems"][0]["invocation"]["runtimeDependencies"] =
            json!([{ "id": id, "minimumVersion": "8" }]);
        let result = plan(manifest, "macos");
        assert_eq!(result["status"], "rejected", "{id}: {result}");
        assert_eq!(result["error"]["code"], "plugin.manifest.invalid", "{id}");
    }
}
