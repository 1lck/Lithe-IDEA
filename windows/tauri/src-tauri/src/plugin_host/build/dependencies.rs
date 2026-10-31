//! Explicit dependency loading through the existing native operation
//! owner. Core selects argv and decodes trees; the host owns consent, frozen
//! inputs, a fresh plugin-state output file, and guarded result publication.

use super::super::build_registry::{BuildCoreExecutor, BuildModelContext};
use super::super::build_resolver::WindowsBuildToolResolver;
use super::host::{verified_identity, HostGuard, WindowBuildOutput};
use super::operation::*;
use super::output::{BuildOutputSink, BuildRunTerminal, RunEvents, Utf8Stream, MAX_RUN_OUTPUT};
use super::process::{validate_output_file, ModelOutputFile, NativeBuildExecutor};
use super::{store, BuildHostState, HostCoreExecutor};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Manager};

/// Native entity ID only: paths, programs, env and output destinations cannot
/// be supplied by the webview. None selects the exact build instance root.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BuildDependenciesSelection {
    pub project_id: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BuildDependenciesReview {
    #[serde(flatten)]
    pub operation: BuildModelReview,
    pub project_id: Option<String>,
    pub title: String,
    pub kind: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BuildDependenciesResult {
    #[serde(flatten)]
    pub review: BuildDependenciesReview,
    pub terminal: BuildRunTerminal,
    /// None on failure/cancellation; an empty successful tree is Some([]).
    pub dependencies: Option<Value>,
    pub truncated: bool,
    /// Complete, unchanged Core tree for consumers of the public web contract.
    pub dependency_tree: Option<Value>,
}

pub(super) struct DecodedDependencies {
    pub nodes: Value,
    pub truncated: bool,
    pub tree: Value,
}

pub(super) struct PreparedDependencies {
    pub project_id: Option<String>,
    pub(super) project_path: Option<String>,
    pub provider_plan: Option<Value>,
    pub title: String,
    pub fingerprint: String,
    pub events: RunEvents,
}

/// Pure plan preparation. No output allocation, resolver advance or process
/// occurs until the operation is explicitly confirmed.
pub(super) fn plan(
    core: &dyn BuildCoreExecutor,
    context: &BuildModelContext,
    selection: &BuildDependenciesSelection,
    plugin_directory: &Path,
    state_directory: &Path,
    output_file: &Path,
    id: &str,
    fingerprint: String,
    sink: Arc<dyn BuildOutputSink>,
) -> Result<(ModelCommandPlan, PreparedDependencies), String> {
    let system = context.package.manifest["buildSystems"]
        .as_array()
        .and_then(|systems| {
            systems
                .iter()
                .find(|system| system["id"] == context.build_system_id)
        })
        .ok_or("plugin.build.invalidSelection")?;
    if !matches!(
        system["dependencies"]["source"].as_str(),
        Some("command" | "hostIntegration" | "provider")
    ) {
        return Err("plugin.build.unavailable".into());
    }
    if selection.project_id.is_some() && (context.model.is_null() || context.model_stale) {
        return Err("plugin.build.modelReloadRequired".into());
    }
    let project = selection
        .project_id
        .as_ref()
        .map(|id| {
            context.model["projects"]
                .as_array()
                .and_then(|projects| {
                    projects
                        .iter()
                        .find(|project| project["id"].as_str() == Some(id.as_str()))
                })
                .cloned()
                .ok_or("plugin.build.invalidSelection")
        })
        .transpose()?;
    let response = core.execute("build.dependencyPlan", json!({
        "manifest":context.package.manifest, "buildSystemID":context.build_system_id,
        "request":{"root":context.root,"options":context.options,"project":project,
            "pluginDirectory":plugin_directory,"workspaceStateDirectory":state_directory,"outputFile":output_file},
    }))?;
    core_ok(&response)?;
    let provider_plan = response["plan"]["provider"]
        .is_object()
        .then(|| response["plan"].clone());
    if provider_plan.is_none()
        && (response["plan"]["execution"] != "task"
            || response["plan"]["workingDirectory"] != context.root)
    {
        return Err("plugin.build.invalidPlan".into());
    }
    let mut command: ModelCommandPlan = if let Some(plan) = &provider_plan {
        super::provider::command(plan)?
    } else {
        serde_json::from_value(response["plan"].clone()).map_err(|_| "plugin.build.invalidPlan")?
    };
    if !matches!(
        command.output.as_str(),
        "stdout" | "outputFile" | "provider"
    ) {
        return Err("plugin.build.invalidPlan".into());
    }
    // Dependency resolution can run project extensions and fetch artifacts.
    // Keep review conservative even if a declaration understates these risks.
    command.executes_project_code = true;
    command.may_use_network = true;
    Ok((
        command,
        PreparedDependencies {
            project_id: selection.project_id.clone(),
            project_path: project
                .as_ref()
                .and_then(|project| project["path"].as_str())
                .map(str::to_string),
            title: context.build_system_id.clone(),
            fingerprint,
            provider_plan,
            events: RunEvents::new(context, id, sink),
        },
    ))
}

pub(super) fn review(operation: &ModelOperation) -> Result<BuildDependenciesReview, String> {
    let dependencies = operation
        .dependencies
        .as_ref()
        .ok_or("plugin.build.invalidPlan")?;
    Ok(BuildDependenciesReview {
        operation: operation.review(),
        project_id: dependencies.project_id.clone(),
        title: dependencies.title.clone(),
        kind: "dependencies".into(),
    })
}

/// A completed process returns data only after Core decoding. Cleanup failure
/// is propagated separately so the host can retain both lease and scratch file.
pub(super) fn execute(
    operation: &ModelOperation,
    core: &dyn BuildCoreExecutor,
    executor: &dyn BuildProcessExecutor,
    guard: &dyn ModelExecutionGuard,
) -> Result<(BuildRunTerminal, Option<DecodedDependencies>), String> {
    let dependencies = operation
        .dependencies
        .as_ref()
        .ok_or("plugin.build.invalidPlan")?;
    guard.checkpoint()?;
    let tool = resolve_tool(operation, core, executor, guard)?;
    guard.checkpoint()?;
    let mut stdout = Vec::new();
    let mut streams = [Utf8Stream::default(), Utf8Stream::default()];
    let mut bytes = 0usize;
    let process = executor.run_command(
        &BuildProcessPlan {
            executable: tool.executable,
            arguments: operation.plan.arguments.clone(),
            environment: tool.environment,
            directory: operation.working_directory.clone(),
            timeout: Duration::from_secs(600),
            output_limit: MODEL_OUTPUT_LIMIT,
            output_file: (operation.plan.output == "outputFile")
                .then(|| operation.output_file.clone()),
        },
        guard,
        &mut |stream, chunk| {
            operation.publish(|| {
                if guard.cancelled() {
                    return Err("plugin.build.cancelled".into());
                }
                bytes = bytes.saturating_add(chunk.len());
                if bytes > MAX_RUN_OUTPUT {
                    return Err("plugin.build.outputLimit".into());
                }
                let (index, name) = match stream {
                    lithe_git_host::Stream::Stdout => (0, "stdout"),
                    lithe_git_host::Stream::Stderr => (1, "stderr"),
                };
                if index == 0 && operation.plan.output == "stdout" {
                    stdout.extend_from_slice(chunk);
                }
                dependencies.events.chunk(name, &streams[index].push(chunk))
            })
        },
    );
    if process
        .failure
        .as_deref()
        .is_some_and(|error| error.starts_with("plugin.build.cleanupFailed"))
    {
        return Err(process.failure.unwrap());
    }
    let mut terminal = BuildRunTerminal {
        kind: if !process.started {
            "failedToStart"
        } else if process.failure.is_some() || process.exit_code != Some(0) {
            "failed"
        } else {
            "succeeded"
        }
        .into(),
        exit_code: process.exit_code,
        message: process.failure,
    };
    let decoded = (|| -> Result<Option<DecodedDependencies>, String> {
        guard.checkpoint()?;
        for (index, stream) in ["stdout", "stderr"].into_iter().enumerate() {
            let tail = streams[index].finish();
            operation.publish(|| {
                guard.checkpoint()?;
                dependencies.events.chunk(stream, &tail)
            })?;
        }
        if terminal.kind != "succeeded" {
            return Ok(None);
        }
        if operation.plan.output == "outputFile" {
            validate_output_file(&operation.output_file)?;
        }
        let output = String::from_utf8(stdout).map_err(|_| "plugin.build.invalidOutput")?;
        let response = core.execute("build.decodeDependencies", json!({
        "manifest":operation.context.package.manifest,"buildSystemID":operation.context.build_system_id,
        "request":{"workspaceRoot":operation.context.workspace_root,"root":operation.context.root,
            "project":dependencies.project_path,"output":(operation.plan.output == "stdout").then_some(output),
            "outputFile":(operation.plan.output == "outputFile").then(|| operation.output_file.to_string_lossy().into_owned())},
    }))?;
        core_ok(&response)?;
        guard.checkpoint()?;
        // The command envelope contains a decoded result with its project,
        // dependency nodes and truncation flag, rather than a bare tree.
        let decoded = &response["dependencies"];
        if !decoded["dependencies"].is_array() {
            return Err("plugin.build.invalidOutput".into());
        }
        Ok(Some(DecodedDependencies {
            nodes: decoded["dependencies"].clone(),
            truncated: decoded["truncated"] == true,
            tree: decoded.clone(),
        }))
    })();
    match decoded {
        Ok(tree) => Ok((terminal, tree)),
        Err(error) => {
            terminal.kind = if super::run::error_terminal(&error).kind == "cancelled" {
                "cancelled"
            } else if process.started {
                "failed"
            } else {
                "failedToStart"
            }
            .into();
            terminal.message = Some(error);
            Ok((terminal, None))
        }
    }
}

pub(super) struct DependencyGuard<'a> {
    pub base: HostGuard<'a>,
}
impl ModelExecutionGuard for DependencyGuard<'_> {
    fn checkpoint(&self) -> Result<(), String> {
        self.base.checkpoint()?;
        let state = self.base.app.state::<BuildHostState>();
        let registry = state
            .registry
            .lock()
            .map_err(|_| "build registry mutex poisoned")?;
        if registry.model_fingerprint(&HostCoreExecutor, &self.base.operation.context)?
            != self
                .base
                .operation
                .dependencies
                .as_ref()
                .ok_or("plugin.build.invalidPlan")?
                .fingerprint
        {
            return Err("plugin.build.staleContext".into());
        }
        Ok(())
    }
    fn cancelled(&self) -> bool {
        self.base.cancelled()
    }
    fn start_permit(&self) -> Result<Box<dyn StartPermit + '_>, String> {
        self.checkpoint()?;
        self.base.start_permit()
    }
}

pub(super) async fn prepare(
    app: AppHandle,
    window_label: String,
    workspace_root: String,
    plugin_id: String,
    build_system_id: String,
    root: String,
    selection: BuildDependenciesSelection,
) -> Result<BuildDependenciesReview, String> {
    tauri::async_runtime::spawn_blocking(move || {
        if window_label != "main" && !window_label.starts_with("workspace-") {
            return Err("plugin.build.staleContext".into());
        }
        let state = app.state::<BuildHostState>();
        let (context, fingerprint) = {
            let registry = state
                .registry
                .lock()
                .map_err(|_| "build registry mutex poisoned")?;
            let context = registry.model_context(
                &window_label,
                &workspace_root,
                &plugin_id,
                &build_system_id,
                &root,
            )?;
            let fingerprint = registry.model_fingerprint(&HostCoreExecutor, &context)?;
            // A direct IPC caller cannot bypass the frontend's passive sync.
            // Model IDs must still describe the on-disk inputs, including a
            // POM edit whose watcher notification has not been delivered yet.
            if selection.project_id.is_some()
                && !registry
                    .view(&window_label)
                    .instances
                    .iter()
                    .any(|instance| {
                        instance["pluginID"] == plugin_id
                            && instance["buildSystemID"] == build_system_id
                            && instance["root"] == root
                            && instance["syncDigest"].as_str() == Some(fingerprint.as_str())
                    })
            {
                return Err("plugin.build.modelReloadRequired".into());
            }
            (context, fingerprint)
        };
        let _lease = app
            .state::<super::super::lifecycle::LifecycleState>()
            .acquire(&plugin_id)?;
        let package = verified_identity(&app, &context)?;
        let id = next_operation_id();
        let state_directory = store::plugin_state_directory(&app, &plugin_id)?;
        let output_file = state_directory.join(format!("{id}.dependencies.json"));
        let (command, dependencies) = plan(
            &HostCoreExecutor,
            &context,
            &selection,
            &package.root,
            &state_directory.join(store::workspace_state_key(&workspace_root)),
            &output_file,
            &id,
            fingerprint,
            Arc::new(WindowBuildOutput(app.clone())),
        )?;
        let settings = super::super::settings::load_layers(&app, &plugin_id, &workspace_root)?;
        let invocation = HostCoreExecutor.execute(
            "build.invocationPlan",
            json!({
                "manifest":context.package.manifest,"buildSystemID":build_system_id,
                "request":{"root":root,"platform":"windows","settings":settings.global},
            }),
        )?;
        core_ok(&invocation)?;
        let working_directory = WindowsBuildToolResolver::instance_directory(
            &invocation["invocation"],
            Path::new(&workspace_root),
        )
        .map_err(|error| format!("{}: {error}", error.code()))?;
        let resolver = WindowsBuildToolResolver::from_current_process(BTreeMap::new())
            .freeze_discovery()
            .map_err(|error| error.to_string())?;
        let prepared_provider = dependencies
            .provider_plan
            .clone()
            .map(|plan| super::provider::prepare(&app, &context, plan, BTreeMap::new()))
            .transpose()?;
        let mut operation = ModelOperation::new(
            id.clone(),
            context,
            command,
            invocation["invocation"].clone(),
            resolver,
            output_file,
            working_directory,
        );
        operation.dependencies = Some(dependencies);
        operation.provider = prepared_provider;
        let guard = DependencyGuard {
            base: HostGuard {
                app: &app,
                operation: &operation,
                deadline: Instant::now() + Duration::from_secs(660),
            },
        };
        guard.checkpoint()?;
        let result = review(&operation)?;
        state.operations.insert(operation)?;
        let operation = state.operations.get(&window_label, &id)?;
        let guard = DependencyGuard {
            base: HostGuard {
                app: &app,
                operation: &operation,
                deadline: Instant::now() + Duration::from_secs(660),
            },
        };
        if let Err(error) = guard.checkpoint() {
            operation.cancel();
            return Err(error);
        }
        Ok(result)
    })
    .await
    .map_err(|_| "plugin.build.processFailed".to_string())?
}

pub(super) async fn load(
    app: AppHandle,
    window_label: String,
    operation_id: String,
) -> Result<BuildDependenciesResult, String> {
    let operation = app
        .state::<BuildHostState>()
        .operations
        .get(&window_label, &operation_id)?;
    if operation.dependencies.is_none() {
        return Err("plugin.build.invalidPlan".into());
    }
    let running = app
        .state::<BuildHostState>()
        .operations
        .claim(&window_label, &operation_id)?;
    if running.0.provider.is_some() {
        return super::provider::load_dependencies(app, running).await;
    }
    tauri::async_runtime::spawn_blocking(move || {
        let operation = &running.0;
        let guard = DependencyGuard {
            base: HostGuard {
                app: &app,
                operation,
                deadline: Instant::now() + Duration::from_secs(660),
            },
        };
        let mut lease = None;
        let mut output = None;
        let loaded = (|| {
            guard.checkpoint()?;
            lease = Some(
                app.state::<super::super::lifecycle::LifecycleState>()
                    .acquire(&operation.context.plugin_id)?,
            );
            if operation.plan.output == "outputFile" {
                output = Some(ModelOutputFile::create(&operation.output_file)?);
            }
            execute(operation, &HostCoreExecutor, &NativeBuildExecutor, &guard)
        })();
        if loaded
            .as_ref()
            .err()
            .is_some_and(|error| error.starts_with("plugin.build.cleanupFailed"))
        {
            // Keep the scratch file and package barrier until tree exit is
            // proven. The shared owner remains occupied and emits no terminal.
            operation.retain_failed_cleanup((lease.take(), output.take()));
            return Err(loaded.err().unwrap());
        }
        let (terminal, dependencies) =
            loaded.unwrap_or_else(|error| (super::run::error_terminal(&error), None));
        let terminal = operation.complete_run(terminal, || guard.checkpoint())?;
        let dependencies = (terminal.kind == "succeeded")
            .then_some(dependencies)
            .flatten();
        let result = BuildDependenciesResult {
            review: review(operation)?,
            truncated: dependencies.as_ref().is_some_and(|tree| tree.truncated),
            dependency_tree: dependencies.as_ref().map(|tree| tree.tree.clone()),
            dependencies: dependencies.map(|tree| tree.nodes),
            terminal,
        };
        drop(output);
        drop(lease);
        Ok(result)
    })
    .await
    .map_err(|_| "plugin.build.processFailed".to_string())?
}
