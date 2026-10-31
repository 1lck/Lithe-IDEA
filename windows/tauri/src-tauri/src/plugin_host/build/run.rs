//! Declared task/test selection and execution. Requests name native model IDs;
//! Core alone expands argv, chooses report globs and decodes tool output.

use super::super::build_registry::{BuildCoreExecutor, BuildModelContext};
use super::operation::*;
use super::output::*;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum BuildRunKind {
    Task,
    Test,
}

/// Only selection IDs and declared user arguments cross the IPC boundary.
/// Executables, entity properties, cwd, env, reports and permissions never do.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BuildRunSelection {
    pub kind: BuildRunKind,
    pub task_id: Option<String>,
    pub project_id: Option<String>,
    pub target_id: Option<String>,
    pub model_task_id: Option<String>,
    pub suite: Option<String>,
    pub case: Option<String>,
    #[serde(default)]
    pub user_arguments: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct RunCommandPlan {
    pub arguments: Vec<String>,
    pub environment: BTreeMap<String, String>,
    pub working_directory: String,
    pub execution: String,
    #[serde(default)]
    pub results: Value,
}

pub(super) struct PreparedRun {
    pub kind: BuildRunKind,
    pub plan: RunCommandPlan,
    pub title: String,
    pub decode_request: Value,
    pub diagnostics: bool,
    pub events: RunEvents,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BuildRunReview {
    #[serde(flatten)]
    pub operation: BuildModelReview,
    pub title: String,
    pub kind: String,
}

fn entity(model: &Value, collection: &str, id: &Option<String>) -> Result<Option<Value>, String> {
    id.as_ref()
        .map(|id| {
            model[collection]
                .as_array()
                .and_then(|items| {
                    items
                        .iter()
                        .find(|item| item["id"].as_str() == Some(id.as_str()))
                })
                .cloned()
                .ok_or_else(|| "plugin.build.invalidSelection".into())
        })
        .transpose()
}

/// Pure selection/plan construction; package/state paths are native inputs.
pub(super) fn prepare_run_plan(
    core: &dyn BuildCoreExecutor,
    context: &BuildModelContext,
    selection: &BuildRunSelection,
    plugin_directory: &Path,
    state_directory: &Path,
    id: &str,
    sink: Arc<dyn BuildOutputSink>,
) -> Result<PreparedRun, String> {
    let system = context.package.manifest["buildSystems"]
        .as_array()
        .and_then(|systems| {
            systems
                .iter()
                .find(|system| system["id"] == context.build_system_id)
        })
        .ok_or("plugin.build.invalidSelection")?;
    // A model-derived selection must not use an old project/target/task. A
    // workspace test with reports also needs every current model project:
    // report globs are project-relative, so missing projects can hide failures.
    // Workspace commands that do not depend on a model remain available.
    let needs_model = selection.project_id.is_some()
        || selection.target_id.is_some()
        || selection.model_task_id.is_some()
        || (selection.kind == BuildRunKind::Test
            && !system["test"]["results"].is_null()
            && selection.project_id.is_none());
    if needs_model && !system["model"].is_null() && (context.model.is_null() || context.model_stale)
    {
        return Err("plugin.build.modelReloadRequired".into());
    }
    let project = entity(&context.model, "projects", &selection.project_id)?;
    let target = entity(&context.model, "targets", &selection.target_id)?;
    let model_task = entity(&context.model, "tasks", &selection.model_task_id)?;
    for child in [&target, &model_task].into_iter().flatten() {
        if project
            .as_ref()
            .is_none_or(|project| child["projectID"] != project["id"])
        {
            return Err("plugin.build.invalidSelection".into());
        }
    }
    let projects: Vec<_> = context.model["projects"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|project| project["path"].as_str())
        .collect();
    let mut request = json!({"root":context.root, "options":context.options,
        "pluginDirectory":plugin_directory, "workspaceStateDirectory":state_directory,
        "project":project, "target":target, "userArguments":selection.user_arguments});
    let (command, title) = match selection.kind {
        BuildRunKind::Task => {
            if selection.suite.is_some() || selection.case.is_some() {
                return Err("plugin.build.invalidSelection".into());
            }
            let task_id = selection
                .task_id
                .as_ref()
                .ok_or("plugin.build.invalidSelection")?;
            let task = system["tasks"]
                .as_array()
                .and_then(|tasks| {
                    tasks
                        .iter()
                        .find(|task| task["id"].as_str() == Some(task_id.as_str()))
                })
                .ok_or("plugin.build.invalidSelection")?;
            if model_task
                .as_ref()
                .is_some_and(|model_task| model_task["template"].as_str() != Some(task_id.as_str()))
            {
                return Err("plugin.build.invalidSelection".into());
            }
            request["task"] = json!(task_id);
            request["modelTask"] = json!(model_task);
            (
                "build.taskPlan",
                task["displayName"].as_str().unwrap_or(task_id).to_string(),
            )
        }
        BuildRunKind::Test => {
            if selection.task_id.is_some() || selection.model_task_id.is_some() {
                return Err("plugin.build.invalidSelection".into());
            }
            request["suite"] = json!(selection.suite);
            request["case"] = json!(selection.case);
            request["projects"] = json!(projects);
            ("build.testPlan", context.build_system_id.clone())
        }
    };
    let response = core.execute(
        command,
        json!({"manifest":context.package.manifest,
        "buildSystemID":context.build_system_id, "request":request}),
    )?;
    core_ok(&response)?;
    let plan: RunCommandPlan =
        serde_json::from_value(response["plan"].clone()).map_err(|_| "plugin.build.invalidPlan")?;
    // Long-running service/application plans require Run ownership and are not
    // allowed to become an unbounded background task in this batch.
    if plan.execution != "task" || plan.working_directory != context.root {
        return Err("plugin.build.unavailable".into());
    }
    let decode_request = json!({"workspaceRoot":context.workspace_root, "root":context.root,
        "project":project.as_ref().map(|project| &project["path"]), "projects":projects, "suite":selection.suite});
    Ok(PreparedRun {
        kind: selection.kind.clone(),
        plan,
        title,
        decode_request,
        diagnostics: !system["diagnostics"].is_null(),
        events: RunEvents::new(context, id, sink),
    })
}

pub(super) fn run_review(operation: &ModelOperation) -> Result<BuildRunReview, String> {
    let run = operation.run.as_ref().ok_or("plugin.build.invalidPlan")?;
    Ok(BuildRunReview {
        operation: operation.review(),
        title: run.title.clone(),
        kind: match run.kind {
            BuildRunKind::Task => "task",
            BuildRunKind::Test => "test",
        }
        .into(),
    })
}

pub(super) fn error_terminal(error: &str) -> BuildRunTerminal {
    let cancelled = [
        "plugin.build.cancelled",
        "plugin.build.staleContext",
        "plugin.build.packageChanged",
    ]
    .iter()
    .any(|prefix| error.starts_with(prefix));
    BuildRunTerminal {
        kind: if cancelled {
            "cancelled"
        } else {
            "failedToStart"
        }
        .into(),
        exit_code: None,
        message: Some(error.to_string()),
    }
}

/// Returns one terminal only after native cleanup and Core decoding. Failure
/// to confirm cleanup is an error, not a terminal claiming the process ended.
pub(super) fn execute_run(
    operation: &ModelOperation,
    core: &dyn BuildCoreExecutor,
    executor: &dyn BuildProcessExecutor,
    guard: &dyn ModelExecutionGuard,
) -> Result<BuildRunTerminal, String> {
    let run = operation.run.as_ref().ok_or("plugin.build.invalidPlan")?;
    guard.checkpoint()?;
    let tool = resolve_tool(operation, core, executor, guard)?;
    guard.checkpoint()?;
    let mut stdout = Utf8Stream::default();
    let mut stderr = Utf8Stream::default();
    let mut diagnostic_stdout = String::new();
    let mut diagnostic_stderr = String::new();
    let mut bytes = 0usize;
    let mut on_output = |stream: lithe_git_host::Stream, chunk: &[u8]| -> Result<(), String> {
        bytes = bytes.saturating_add(chunk.len());
        if bytes > MAX_RUN_OUTPUT {
            return Err("plugin.build.outputLimit".into());
        }
        let (decoder, text, name) = match stream {
            lithe_git_host::Stream::Stdout => (&mut stdout, &mut diagnostic_stdout, "stdout"),
            lithe_git_host::Stream::Stderr => (&mut stderr, &mut diagnostic_stderr, "stderr"),
        };
        let decoded = decoder.push(chunk);
        text.push_str(&decoded);
        operation.publish(|| {
            if guard.cancelled() {
                return Err("plugin.build.cancelled".into());
            }
            run.events.chunk(name, &decoded)
        })
    };
    let process = executor.run_command(
        &BuildProcessPlan {
            executable: tool.executable,
            arguments: run.plan.arguments.clone(),
            environment: tool.environment,
            directory: operation.working_directory.clone(),
            timeout: Duration::from_secs(600),
            output_limit: MAX_RUN_OUTPUT,
            output_file: None,
        },
        guard,
        &mut on_output,
    );
    drop(on_output);
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
    let decoded = (|| -> Result<(), String> {
        guard.checkpoint()?;
        if !guard.cancelled() {
            for (name, decoder, text) in [
                ("stdout", &mut stdout, &mut diagnostic_stdout),
                ("stderr", &mut stderr, &mut diagnostic_stderr),
            ] {
                let tail = decoder.finish();
                text.push_str(&tail);
                operation.publish(|| {
                    guard.checkpoint()?;
                    run.events.chunk(name, &tail)
                })?;
            }
        }
        guard.checkpoint()?;
        // Keep independent streams separate so a partial stdout line cannot
        // splice into a stderr diagnostic. Both streams remain in arrival order
        // in chunk events; Core sees complete per-stream diagnostic lines.
        let output = format!("{diagnostic_stdout}\n{diagnostic_stderr}");
        let decode = |command: &str, request: Value| -> Result<Value, String> {
            guard.checkpoint()?;
            let response = core.execute(
                command,
                json!({"manifest":operation.context.package.manifest,
            "buildSystemID":operation.context.build_system_id, "request":request}),
            )?;
            core_ok(&response)?;
            guard.checkpoint()?;
            Ok(response)
        };
        if run.diagnostics {
            let response = decode(
                "build.decodeDiagnostics",
                json!({"workspaceRoot":operation.context.workspace_root,
            "root":operation.context.root, "output":output}),
            )?;
            operation.publish(|| {
                guard.checkpoint()?;
                run.events.decoded(
                    "diagnostics",
                    "diagnostics",
                    response["diagnostics"].clone(),
                )
            })?;
        }
        if run.kind == BuildRunKind::Test && !run.plan.results.is_null() && process.started {
            let mut request = run.decode_request.clone();
            request["output"] = json!(output);
            request["notBeforeMillis"] = json!(process
                .started_at_millis
                .ok_or("plugin.build.invalidPlan")?);
            let response = decode("build.decodeTestResults", request)?;
            if response["results"]["success"] == false {
                terminal.kind = "failed".into();
            }
            operation.publish(|| {
                guard.checkpoint()?;
                run.events
                    .decoded("testResults", "results", response["results"].clone())
            })?;
        }
        guard.checkpoint()?;
        Ok(())
    })();
    if let Err(error) = decoded {
        terminal.kind = if error_terminal(&error).kind == "cancelled" {
            "cancelled"
        } else if process.started {
            "failed"
        } else {
            "failedToStart"
        }
        .into();
        terminal.message = Some(error);
    }
    Ok(terminal)
}
