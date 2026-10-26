//! Explicit build operation ownership and command-model orchestration.
//! Core owns plans and decoding; this module owns cancellation, frozen inputs,
//! budgets and the point at which an operation is allowed to publish a result.

use super::super::build_registry::{BuildCoreExecutor, BuildModelContext};
use super::super::build_resolver::{
    BuildResolutionStep, ResolvedBuildTool, VersionProbeOutcome, WindowsBuildToolResolver,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::sync::{
    atomic::{AtomicBool, AtomicU64, Ordering},
    Arc, Mutex,
};
use std::time::{Duration, Instant};
use tokio::sync::Notify;

pub(super) const MODEL_TIMEOUT: Duration = Duration::from_secs(120);
pub(super) const PROBE_TIMEOUT: Duration = Duration::from_secs(5);
pub(super) const MODEL_OUTPUT_LIMIT: usize = 32 * 1024 * 1024;
pub(super) const PROBE_OUTPUT_LIMIT: usize = 64 * 1024;
const REVIEW_TIMEOUT: Duration = Duration::from_secs(120);
static NEXT_OPERATION: AtomicU64 = AtomicU64::new(1);

pub(super) fn next_operation_id() -> String {
    format!(
        "build-{}-{}",
        std::process::id(),
        NEXT_OPERATION.fetch_add(1, Ordering::Relaxed)
    )
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ModelCommandPlan {
    pub arguments: Vec<String>,
    pub environment: BTreeMap<String, String>,
    pub working_directory: String,
    pub output: String,
    pub executes_project_code: bool,
    pub may_use_network: bool,
}

/// Host-side review. Accepting it authorizes only this operation, package and
/// workspace; it does not permanently mark the workspace or package trusted.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BuildModelReview {
    pub operation_id: String,
    pub plugin_id: String,
    pub build_system_id: String,
    pub workspace_root: String,
    pub root: String,
    pub generation: u64,
    pub executes_project_code: bool,
    pub may_use_network: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider: Option<super::super::provider::ProviderReview>,
}

pub(super) struct ModelOperation {
    pub id: String,
    pub context: BuildModelContext,
    pub plan: ModelCommandPlan,
    pub invocation: Value,
    pub resolver: WindowsBuildToolResolver,
    pub output_file: PathBuf,
    pub working_directory: PathBuf,
    pub run: Option<super::run::PreparedRun>,
    pub dependencies: Option<super::dependencies::PreparedDependencies>,
    pub provider: Option<super::provider::ProviderOperation>,
    created: Instant,
    cancelled: AtomicBool,
    running: AtomicBool,
    finished: AtomicBool,
    changed: Notify,
    publication: Mutex<()>,
    retained_cleanup: Mutex<Option<Box<dyn Send>>>,
    provider_session_cleanup: AtomicBool,
}

impl ModelOperation {
    pub fn new(
        id: String,
        context: BuildModelContext,
        plan: ModelCommandPlan,
        invocation: Value,
        resolver: WindowsBuildToolResolver,
        output_file: PathBuf,
        working_directory: PathBuf,
    ) -> Self {
        Self {
            id,
            context,
            plan,
            invocation,
            resolver,
            output_file,
            working_directory,
            run: None,
            dependencies: None,
            provider: None,
            created: Instant::now(),
            cancelled: AtomicBool::new(false),
            running: AtomicBool::new(false),
            finished: AtomicBool::new(false),
            changed: Notify::new(),
            publication: Mutex::new(()),
            retained_cleanup: Mutex::new(None),
            provider_session_cleanup: AtomicBool::new(false),
        }
    }

    pub fn review(&self) -> BuildModelReview {
        // Every project candidate can execute repository code, regardless of
        // its manifest flag. Consent must precede runtime and version probes.
        let project_candidate = self.invocation["executables"]
            .as_array()
            .into_iter()
            .flatten()
            .chain(
                self.invocation["runtimeDependencies"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .flat_map(|runtime| runtime["executables"].as_array().into_iter().flatten()),
            )
            .any(|candidate| candidate["kind"] == "projectFile");
        BuildModelReview {
            operation_id: self.id.clone(),
            plugin_id: self.context.plugin_id.clone(),
            build_system_id: self.context.build_system_id.clone(),
            workspace_root: self.context.workspace_root.clone(),
            root: self.context.root.clone(),
            generation: self.context.generation,
            executes_project_code: self.plan.executes_project_code || project_candidate,
            may_use_network: self.plan.may_use_network,
            provider: self.provider.as_ref().map(|provider| {
                let mut review = provider.review.clone();
                review.invocation_plan = Some(self.invocation.clone());
                review
            }),
        }
    }

    pub fn cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Acquire)
    }
    pub fn finished(&self) -> bool {
        self.finished.load(Ordering::Acquire)
    }

    pub fn cancel(&self) {
        let _publication = self.publication.lock().expect("build publication mutex");
        self.cancelled.store(true, Ordering::Release);
        if let Some(provider) = &self.provider {
            provider.cancel_review();
        }
        self.changed.notify_waiters();
        // A pending review owns no processes. A claimed operation is finished
        // only by its RAII owner after native tree cleanup has returned.
        if !self.running.load(Ordering::Acquire) {
            if let Some(events) = self.events() {
                // No native owner exists for a cancelled pending review.
                let _ = events.terminal(&super::output::BuildRunTerminal {
                    kind: "cancelled".into(),
                    exit_code: None,
                    message: Some("plugin.build.cancelled".into()),
                });
            }
            self.finish();
        }
    }

    pub fn publish<T>(&self, write: impl FnOnce() -> Result<T, String>) -> Result<T, String> {
        let _publication = self
            .publication
            .lock()
            .map_err(|_| "build publication mutex poisoned")?;
        if self.cancelled() {
            return Err("plugin.build.cancelled".into());
        }
        write()
    }

    /// The native owner calls this only after tree cleanup. Order its last
    /// checkpoint and terminal event with cancellation, so a cancel accepted
    /// before publication cannot be followed by a successful terminal.
    pub fn complete_run(
        &self,
        mut terminal: super::output::BuildRunTerminal,
        checkpoint: impl FnOnce() -> Result<(), String>,
    ) -> Result<super::output::BuildRunTerminal, String> {
        let _publication = self
            .publication
            .lock()
            .map_err(|_| "build publication mutex poisoned")?;
        let checked = if self.cancelled() {
            Err("plugin.build.cancelled".into())
        } else {
            checkpoint()
        };
        if let Err(error) = checked {
            terminal.kind = if super::run::error_terminal(&error).kind == "cancelled" {
                "cancelled"
            } else if terminal.kind == "failedToStart" {
                "failedToStart"
            } else {
                "failed"
            }
            .into();
            terminal.message = Some(error);
        }
        self.events()
            .ok_or("plugin.build.invalidPlan")?
            .terminal(&terminal)?;
        Ok(terminal)
    }

    fn events(&self) -> Option<&super::output::RunEvents> {
        self.run.as_ref().map(|run| &run.events).or_else(|| {
            self.dependencies
                .as_ref()
                .map(|dependencies| &dependencies.events)
        })
    }

    pub fn start_permit(&self) -> Result<std::sync::MutexGuard<'_, ()>, String> {
        let permit = self
            .publication
            .lock()
            .map_err(|_| "build publication mutex poisoned")?;
        if self.cancelled() {
            return Err("plugin.build.cancelled".into());
        }
        Ok(permit)
    }

    fn finish(&self) {
        // Fail closed when native cleanup cannot prove tree exit. Retaining
        // its lease blocks package mutation and keeps this instance busy.
        if self
            .retained_cleanup
            .lock()
            .expect("build cleanup lease")
            .is_some()
        {
            return;
        }
        self.finished.store(true, Ordering::Release);
        self.changed.notify_waiters();
    }

    pub fn retain_failed_cleanup(&self, lease: impl Send + 'static) {
        *self.retained_cleanup.lock().expect("build cleanup lease") = Some(Box::new(lease));
    }

    pub fn finish_provider_cleanup(&self) {
        if self.provider.is_none() || !self.provider_session_cleanup.swap(false, Ordering::AcqRel) {
            return;
        }
        let retained = self
            .retained_cleanup
            .lock()
            .expect("build cleanup lease")
            .take()
            .is_some();
        if retained {
            self.finish();
        }
    }

    pub fn retain_provider_session_cleanup(&self) {
        self.retain_failed_cleanup(());
        self.provider_session_cleanup.store(true, Ordering::Release);
    }

    pub async fn wait_finished(&self) -> Result<(), String> {
        tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                let notified = self.changed.notified();
                tokio::pin!(notified);
                notified.as_mut().enable();
                if self.finished() {
                    return;
                }
                notified.await;
            }
        })
        .await
        .map_err(|_| "plugin.build.cleanupTimeout: process owner has not drained".into())
    }

    pub async fn wait_cancelled(&self) {
        loop {
            let changed = self.changed.notified();
            tokio::pin!(changed);
            changed.as_mut().enable();
            if self.cancelled() {
                return;
            }
            changed.await;
        }
    }
}

#[derive(Default)]
pub(super) struct BuildOperations {
    entries: Mutex<HashMap<String, Arc<ModelOperation>>>,
}

impl BuildOperations {
    pub fn insert(&self, operation: ModelOperation) -> Result<BuildModelReview, String> {
        let mut entries = self
            .entries
            .lock()
            .map_err(|_| "build operation mutex poisoned")?;
        entries.retain(|_, old| {
            if !old.running.load(Ordering::Acquire) && old.created.elapsed() >= REVIEW_TIMEOUT {
                old.cancel();
            }
            !old.finished()
        });
        if entries.values().any(|old| {
            old.context.window_label == operation.context.window_label
                && old.context.workspace_root == operation.context.workspace_root
                && old.context.plugin_id == operation.context.plugin_id
                && old.context.build_system_id == operation.context.build_system_id
                && old.context.root == operation.context.root
        }) {
            return Err("plugin.build.busy".into());
        }
        if entries.len() >= 64 {
            return Err("plugin.build.busy: operation budget exhausted".into());
        }
        let review = operation.review();
        entries.insert(operation.id.clone(), Arc::new(operation));
        Ok(review)
    }

    pub fn get(&self, window: &str, id: &str) -> Result<Arc<ModelOperation>, String> {
        self.entries
            .lock()
            .map_err(|_| "build operation mutex poisoned")?
            .get(id)
            .filter(|operation| operation.context.window_label == window)
            .cloned()
            .ok_or_else(|| "plugin.build.unknownOperation".into())
    }

    pub fn claim(&self, window: &str, id: &str) -> Result<RunningModelOperation, String> {
        let operation = self.get(window, id)?;
        // Linearize claim with pending-review cancellation. A cancellation
        // that wins cannot emit terminal and then have this owner start work.
        let permit = operation
            .publication
            .lock()
            .map_err(|_| "build publication mutex poisoned")?;
        if operation.created.elapsed() >= REVIEW_TIMEOUT {
            drop(permit);
            operation.cancel();
            return Err("plugin.build.cancelled".into());
        }
        if operation.cancelled() || operation.finished() {
            return Err("plugin.build.cancelled".into());
        }
        if operation
            .running
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Err("plugin.build.busy".into());
        }
        // Cancellation may race with the claim. The executor checks it before
        // any side effect; waiters must now wait for this owner's Drop.
        operation.finished.store(false, Ordering::Release);
        drop(permit);
        Ok(RunningModelOperation(operation))
    }

    pub fn cancel_matching(
        &self,
        predicate: impl Fn(&ModelOperation) -> bool,
    ) -> Vec<Arc<ModelOperation>> {
        let entries = self.entries.lock().expect("build operation mutex");
        entries
            .values()
            .filter(|operation| predicate(operation))
            .map(|operation| {
                operation.cancel();
                operation.clone()
            })
            .collect()
    }
}

pub(super) struct RunningModelOperation(pub Arc<ModelOperation>);
impl Drop for RunningModelOperation {
    fn drop(&mut self) {
        self.0.finish();
    }
}

/// Production checkpoints verify live package bytes; cheap cancellation polls
/// inspect lifecycle/context only, without repeatedly hashing package files.
pub(super) trait ModelExecutionGuard {
    fn checkpoint(&self) -> Result<(), String>;
    fn cancelled(&self) -> bool;
    /// Keep cancellation ordered with the shared executor's synchronous
    /// spawn. The permit is released as soon as its `started` hook fires.
    fn start_permit(&self) -> Result<Box<dyn StartPermit + '_>, String> {
        self.checkpoint()?;
        Ok(Box::new(()))
    }
}

pub(super) trait StartPermit {}
impl<T> StartPermit for T {}

#[derive(Debug, Clone)]
pub(super) struct BuildProcessPlan {
    pub executable: PathBuf,
    pub arguments: Vec<String>,
    pub environment: BTreeMap<String, String>,
    pub directory: PathBuf,
    pub timeout: Duration,
    pub output_limit: usize,
    pub output_file: Option<PathBuf>,
}

pub(super) struct BuildProcessOutput {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}
pub(super) struct ExecutedModel {
    pub model: Value,
    pub stderr: String,
}
pub(super) struct BuildRunProcessOutput {
    pub exit_code: Option<i32>,
    pub started: bool,
    pub failure: Option<String>,
    pub started_at_millis: Option<u64>,
}
pub(super) trait BuildProcessExecutor {
    fn run(
        &self,
        plan: &BuildProcessPlan,
        guard: &dyn ModelExecutionGuard,
    ) -> Result<BuildProcessOutput, String>;
    fn run_command(
        &self,
        plan: &BuildProcessPlan,
        guard: &dyn ModelExecutionGuard,
        output: &mut dyn FnMut(lithe_git_host::Stream, &[u8]) -> Result<(), String>,
    ) -> BuildRunProcessOutput {
        let started_at_millis = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .ok()
            .and_then(|time| u64::try_from(time.as_millis()).ok());
        match self.run(plan, guard) {
            Ok(result) => {
                let failure = output(lithe_git_host::Stream::Stdout, &result.stdout)
                    .and_then(|_| output(lithe_git_host::Stream::Stderr, &result.stderr))
                    .err();
                BuildRunProcessOutput {
                    exit_code: Some(0),
                    started: true,
                    failure,
                    started_at_millis,
                }
            }
            Err(error) => BuildRunProcessOutput {
                exit_code: None,
                started: false,
                failure: Some(error),
                started_at_millis: None,
            },
        }
    }
}

/// Shared pipeline for real native execution and deterministic executor tests.
/// No operation mutates the registry until the caller's final checkpoint.
pub(super) fn resolve_tool(
    operation: &ModelOperation,
    core: &dyn BuildCoreExecutor,
    executor: &dyn BuildProcessExecutor,
    guard: &dyn ModelExecutionGuard,
) -> Result<ResolvedBuildTool, String> {
    guard.checkpoint()?; // consent returned; before runtime preparation
    let resolver = operation
        .resolver
        .clone()
        .with_overrides(operation.plan.environment.clone());
    let mut resolution = resolver
        .start(
            &operation.invocation,
            &PathBuf::from(&operation.context.workspace_root),
        )
        .map_err(|error| error.to_string())?;
    guard.checkpoint()?; // runtime preparation finished
    let mut outcome = None;
    let tool = loop {
        guard.checkpoint()?;
        match resolver
            .advance(&mut resolution, outcome.take())
            .map_err(|error| format!("{}: {error}", error.code()))?
        {
            BuildResolutionStep::Resolved(tool) => break tool,
            BuildResolutionStep::Probe(probe) => {
                let result = executor.run(
                    &BuildProcessPlan {
                        executable: probe.executable,
                        arguments: probe.arguments.clone(),
                        environment: probe.environment.clone(),
                        directory: operation.working_directory.clone(),
                        timeout: PROBE_TIMEOUT,
                        output_limit: PROBE_OUTPUT_LIMIT,
                        output_file: None,
                    },
                    guard,
                );
                // Cleanup failure takes precedence over a concurrent revoke:
                // the host must retain the NativeLease until exit is proven.
                if let Err(message) = &result {
                    if message.starts_with("plugin.build.cleanupFailed") {
                        return Err(message.clone());
                    }
                }
                guard.checkpoint()?;
                outcome = Some(match result {
                    Ok(output) => {
                        let mut combined = String::from_utf8_lossy(&output.stdout).into_owned();
                        combined.push('\n');
                        combined.push_str(&String::from_utf8_lossy(&output.stderr));
                        let mut request = json!({"output": combined});
                        if let Some(runtime) = &probe.runtime {
                            request["runtime"] = json!(runtime);
                        }
                        let response = core.execute("build.checkToolVersion", json!({
                            "manifest": operation.context.package.manifest, "buildSystemID": operation.context.build_system_id,
                            "request": request,
                        }))?;
                        core_ok(&response)?;
                        VersionProbeOutcome::from_core(&response)
                            .map_err(|error| error.to_string())?
                    }
                    Err(message) => VersionProbeOutcome::Failed { message },
                });
            }
        }
    };
    Ok(tool)
}

pub(super) fn execute_model(
    operation: &ModelOperation,
    core: &dyn BuildCoreExecutor,
    executor: &dyn BuildProcessExecutor,
    guard: &dyn ModelExecutionGuard,
) -> Result<ExecutedModel, String> {
    let tool = resolve_tool(operation, core, executor, guard)?;
    guard.checkpoint()?; // immediately before model command start
    let output = executor.run(
        &BuildProcessPlan {
            executable: tool.executable,
            arguments: operation.plan.arguments.clone(),
            environment: tool.environment,
            directory: operation.working_directory.clone(),
            timeout: MODEL_TIMEOUT,
            output_limit: MODEL_OUTPUT_LIMIT,
            output_file: (operation.plan.output == "outputFile")
                .then(|| operation.output_file.clone()),
        },
        guard,
    )?;
    guard.checkpoint()?;
    let stdout = if operation.plan.output == "stdout" {
        String::from_utf8(output.stdout)
            .map_err(|_| "plugin.build.invalidOutput: stdout is not UTF-8")?
    } else {
        String::new()
    };
    let response = core.execute("build.decodeModel", json!({
        "manifest": operation.context.package.manifest, "buildSystemID": operation.context.build_system_id,
        "request": {"workspaceRoot": operation.context.workspace_root, "root": operation.context.root,
            "options": operation.context.options, "output": stdout,
            "outputFile": (operation.plan.output == "outputFile").then(|| operation.output_file.to_string_lossy().into_owned())},
    }))?;
    core_ok(&response)?;
    guard.checkpoint()?;
    Ok(ExecutedModel {
        model: response["model"].clone(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
    })
}

pub(super) fn core_ok(response: &Value) -> Result<(), String> {
    if response["status"] == "ok" {
        Ok(())
    } else {
        Err(format!(
            "{}: {}",
            response["error"]["code"]
                .as_str()
                .unwrap_or("plugin.build.invalidPlan"),
            response["error"]["message"]
                .as_str()
                .unwrap_or("Core rejected the build operation")
        ))
    }
}
