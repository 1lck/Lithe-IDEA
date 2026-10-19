//! Runtime version probes keep Java 8 compatible without changing Node or Go.

use crate::build::{build_check_tool_version_command, build_invocation_plan_command};
use serde_json::{json, Value};

fn manifest() -> Value {
    serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../shared/contracts/plugins/v1/fixtures/maven-build.plugin.json"
    )))
    .expect("Maven fixture is valid JSON")
}

#[test]
fn host_runtime_probe_arguments_are_portable_across_platforms() {
    for platform in ["macos", "linux", "windows"] {
        let mut manifest = manifest();
        manifest["buildSystems"][0]["invocation"]["runtimeDependencies"] = json!([
            { "id": "java", "minimumVersion": "8" },
            { "id": "node", "minimumVersion": "20" },
            { "id": "go", "minimumVersion": "1.22" }
        ]);
        let result = build_invocation_plan_command(json!({
            "manifest": manifest,
            "buildSystemID": "maven",
            "request": { "root": ".", "platform": platform }
        }))
        .expect("invocation request is valid");
        assert_eq!(result["status"], "ok", "{platform}: {result}");
        let runtimes = &result["invocation"]["runtimeDependencies"];
        for (index, arguments) in [
            json!(["-version"]),
            json!(["--version"]),
            json!(["version"]),
        ]
        .into_iter()
        .enumerate()
        {
            assert_eq!(
                runtimes[index]["version"]["arguments"], arguments,
                "{platform}"
            );
        }
        // The build tool's own probe stays independent of its Java runtime.
        assert_eq!(
            result["invocation"]["version"]["arguments"],
            json!(["--version"])
        );
    }
}

#[test]
fn legacy_java_stderr_is_normalized_before_minimum_comparison() {
    for (minimum, output, satisfied, version) in [
        (
            "8",
            "Picked up JAVA_TOOL_OPTIONS: -Xmx512m\njava version \"1.8.0_452\"\n",
            true,
            "8.0",
        ),
        ("8", "openjdk version \"1.8.0_452\"\n", true, "8.0"),
        ("8", "java version \"1.7.0_80\"\n", false, "7.0"),
        ("17", "java version \"1.8.0_452\"\n", false, "8.0"),
        (
            "17",
            "openjdk version \"21.0.12\" 2026-07-15\n",
            true,
            "21.0.12",
        ),
    ] {
        let mut manifest = manifest();
        manifest["buildSystems"][0]["invocation"]["runtimeDependencies"][0]["minimumVersion"] =
            json!(minimum);
        let result = build_check_tool_version_command(json!({
            "manifest": manifest,
            "buildSystemID": "maven",
            "request": { "runtime": "java", "output": output }
        }))
        .expect("version request is valid");
        assert_eq!(result["status"], "ok", "{result}");
        assert_eq!(
            result["version"],
            json!({ "satisfied": satisfied, "version": version })
        );
    }
}
