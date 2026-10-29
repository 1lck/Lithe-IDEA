//! Real Core Provider plans and decoders through the native build route.
use super::super::build_registry::{BuildCoreExecutor, BuildModelContext, BuildPackageInput};
use super::super::build_resolver::RuntimeExecutableInput;
use super::super::build_resolver::WindowsBuildToolResolver;
use super::operation::*;
use super::provider::*;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Arc;

struct Core;
impl BuildCoreExecutor for Core {
    fn execute(&self, command: &str, payload: Value) -> Result<Value, String> {
        super::super::scan::core_execute(command, payload)
    }
}
struct Workspace(PathBuf);
impl Workspace {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "lithe-provider-route-{}-{}",
            std::process::id(),
            next_operation_id()
        ));
        std::fs::create_dir_all(root.join("app")).unwrap();
        Self(root)
    }
}
impl Drop for Workspace {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.0).unwrap();
    }
}
struct Sink;
impl super::output::BuildOutputSink for Sink {
    fn emit(&self, _: &str, _: Value) -> Result<(), String> {
        Ok(())
    }
}

fn manifest(shared: bool) -> Value {
    serde_json::from_str(if shared {include_str!(concat!(env!("CARGO_MANIFEST_DIR"),"/../../../shared/contracts/plugins/v1/fixtures/build-provider-language-server.plugin.json"))}
        else {include_str!(concat!(env!("CARGO_MANIFEST_DIR"),"/../../../shared/contracts/plugins/v1/fixtures/build-provider.plugin.json"))}).unwrap()
}
fn context(workspace: &Workspace, manifest: Value) -> BuildModelContext {
    BuildModelContext {
        window_label: "main".into(),
        workspace_root: workspace.0.to_string_lossy().into_owned(),
        generation: 9,
        plugin_id: manifest["id"].as_str().unwrap().into(),
        build_system_id: manifest["buildSystems"][0]["id"].as_str().unwrap().into(),
        root: ".".into(),
        package: BuildPackageInput {
            plugin_id: manifest["id"].as_str().unwrap().into(),
            version: "0.1.0".into(),
            manifest,
            content_identity: "whole-package-digest".into(),
        },
        options: BTreeMap::new(),
        model: Value::Null,
        model_stale: false,
        revision: 1,
    }
}

#[test]
fn both_provider_sources_plan_and_decode_real_models_through_the_build_route() {
    let workspace = Workspace::new();
    for shared in [false, true] {
        let context = context(&workspace, manifest(shared));
        let planned=Core.execute("build.modelPlan",json!({"manifest":context.package.manifest,"buildSystemID":context.build_system_id,"request":{"root":"."}})).unwrap();
        core_ok(&planned).unwrap();
        let plan = command(&planned["plan"]).unwrap();
        assert_eq!(plan.output, "provider");
        assert!(plan.arguments.is_empty());
        assert_eq!(planned["plan"]["provider"]["method"], "lithe/build/model");
        let operation = ModelOperation::new(
            next_operation_id(),
            context,
            plan,
            json!({}),
            WindowsBuildToolResolver::with_environment(BTreeMap::new(), BTreeMap::new()),
            workspace.0.join("unused"),
            workspace.0.clone(),
        );
        let hinted = replan(&Core, &operation, Some(&workspace.0.join("tool.exe"))).unwrap();
        assert_eq!(
            hinted["provider"]["params"]["tool"]["executable"],
            workspace.0.join("tool.exe").to_string_lossy().as_ref()
        );
        assert!(
            replan(&Core, &operation, None).unwrap()["provider"]["params"]
                .get("tool")
                .is_none()
        );
        let model=decode(&Core,&operation,json!({"format":"litheBuildModel","version":1,"projects":[{"path":".","name":"fixture"}],"tasks":[]}),None).unwrap();
        assert_eq!(model["projects"][0]["name"], "fixture");
        assert!(decode(
            &Core,
            &operation,
            json!({"format":"litheBuildModel","version":99}),
            None
        )
        .is_err());
    }
}

#[test]
fn provider_dependencies_keep_scope_and_pass_raw_reply_to_core_decoder() {
    let workspace = Workspace::new();
    for shared in [false, true] {
        let context = context(&workspace, manifest(shared));
        let (plan, prepared) = super::dependencies::plan(
            &Core,
            &context,
            &super::dependencies::BuildDependenciesSelection { project_id: None },
            &workspace.0,
            &workspace.0,
            &workspace.0.join("unused"),
            "provider-dependencies",
            "fingerprint".into(),
            Arc::new(Sink),
        )
        .unwrap();
        assert_eq!(
            prepared.provider_plan.as_ref().unwrap()["provider"]["method"],
            "lithe/build/dependencies"
        );
        let mut operation = ModelOperation::new(
            next_operation_id(),
            context,
            plan,
            json!({}),
            WindowsBuildToolResolver::with_environment(BTreeMap::new(), BTreeMap::new()),
            workspace.0.join("unused"),
            workspace.0.clone(),
        );
        operation.dependencies = Some(prepared);
        let result=decode(&Core,&operation,json!({"format":"litheDependencies","version":1,"dependencies":[{"name":"fixture-dependency","version":"1.0","children":[]}]}),None).unwrap();
        assert_eq!(result["dependencies"][0]["name"], "fixture-dependency");
        assert!(decode(
            &Core,
            &operation,
            json!({"format":"litheDependencies","version":99,"dependencies":[]}),
            None
        )
        .is_err());
    }
}

struct NoProcess;
impl BuildProcessExecutor for NoProcess {
    fn run(
        &self,
        _: &BuildProcessPlan,
        _: &dyn ModelExecutionGuard,
    ) -> Result<BuildProcessOutput, String> {
        panic!("Missing or invalid paths must not run a version probe");
    }
}
struct Current;
impl ModelExecutionGuard for Current {
    fn checkpoint(&self) -> Result<(), String> {
        Ok(())
    }
    fn cancelled(&self) -> bool {
        false
    }
}

#[test]
fn provider_tool_fallback_keeps_explicit_tool_and_runtime_failures_terminal() {
    let workspace = Workspace::new();
    for (configured_tool, runtime, explicit_runtime, expected_code) in [
        (true, false, false, "plugin.build.configuredToolUnavailable"),
        // Runtime is resolved before the user's tool. That earlier failure must
        // not silently drop the later explicit tool selection.
        (true, true, false, "plugin.build.configuredToolUnavailable"),
        (false, true, true, "plugin.build.configuredToolUnavailable"),
        (false, true, false, "plugin.build.toolUnavailable"),
        (false, false, false, "plugin.build.toolUnavailable"),
    ] {
        let mut manifest: Value = serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../shared/contracts/plugins/v1/fixtures/build-tool-path.plugin.json"
        )))
        .unwrap();
        if runtime {
            manifest["buildSystems"][0]["invocation"]["runtimeDependencies"] =
                json!([{ "id":"java", "minimumVersion":"17" }]);
        }
        let context = context(&workspace, manifest);
        let response = Core.execute("build.invocationPlan", json!({
            "manifest": context.package.manifest, "buildSystemID": context.build_system_id,
            "request": {"root":".", "platform":"windows", "settings":{
                "toolPath": if configured_tool { workspace.0.join("missing-tool.exe").to_string_lossy().into_owned() } else { String::new() }
            }},
        })).unwrap();
        core_ok(&response).unwrap();
        let runtimes = if explicit_runtime {
            BTreeMap::from([(
                "java".into(),
                RuntimeExecutableInput {
                    executable: workspace.0.join("missing-runtime.exe"),
                    environment: BTreeMap::new(),
                    explicit: true,
                },
            )])
        } else {
            BTreeMap::new()
        };
        let operation = ModelOperation::new(
            next_operation_id(),
            context,
            ModelCommandPlan {
                arguments: vec![],
                environment: BTreeMap::new(),
                working_directory: ".".into(),
                output: "provider".into(),
                executes_project_code: true,
                may_use_network: true,
            },
            response["invocation"].clone(),
            WindowsBuildToolResolver::with_environment(BTreeMap::new(), runtimes),
            workspace.0.join("unused"),
            workspace.0.clone(),
        );
        let resolved = resolve_tool(&operation, &Core, &NoProcess, &Current);
        assert!(
            resolved.as_ref().err().unwrap().starts_with(expected_code),
            "{:?}",
            resolved.as_ref().err()
        );
        let hint = tool_hint(resolved);
        if expected_code == "plugin.build.toolUnavailable" {
            assert!(
                hint.unwrap().is_none(),
                "Only automatic discovery can omit the hint"
            );
        } else {
            assert!(
                hint.unwrap_err().starts_with(expected_code),
                "Explicit selection must abort the Provider request"
            );
        }
    }
}

#[test]
fn provider_tool_fallback_does_not_swallow_cleanup_or_unsafe_plan_failures() {
    for error in [
        "plugin.build.cleanupFailed: live process",
        "plugin.build.projectPathEscape: outside workspace",
        "plugin.build.invalidPlan: malformed",
        "plugin.build.cancelled",
        "plugin.build.timeout",
    ] {
        assert_eq!(tool_hint(Err(error.into())).unwrap_err(), error);
    }
}
