//! Tauri composition for the operation coordinator. Never hold the registry
//! lock while waiting for consent, preparing runtimes or executing a process.

use super::super::build_registry::BuildModelContext;
use super::super::build_resolver::{RuntimeExecutableInput, WindowsBuildToolResolver};
use super::{operation::*, process::*, *};
use serde_json::json;
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

const OPERATION_TIMEOUT: Duration = Duration::from_secs(180);

/// Capture a configured runtime without executing it before the review. The
/// Java launch adapter validates the candidate JDK, then a round-trip identity
/// check ensures its JAVA_HOME refers to the exact selected executable.
pub(super) fn explicit_runtime_input(
    id: &str,
    executable: PathBuf,
) -> Result<RuntimeExecutableInput, String> {
    if !executable.is_absolute() {
        return Err("plugin.build.invalidPlan: runtime paths must be absolute".into());
    }
    let mut environment = BTreeMap::new();
    if id.eq_ignore_ascii_case("java") {
        let candidate = executable
            .parent()
            .and_then(std::path::Path::parent)
            .ok_or("plugin.build.configuredToolUnavailable: Java must belong to a JDK")?;
        let home = crate::run::resolve_java_home(candidate, &candidate.to_string_lossy())
            .map_err(|_| "plugin.build.configuredToolUnavailable: Java must belong to a JDK")?
            .ok_or("plugin.build.configuredToolUnavailable: Java must belong to a JDK")?;
        let selected = executable.canonicalize().map_err(|_| {
            "plugin.build.configuredToolUnavailable: configured Java is unavailable"
        })?;
        let resolved = crate::run::java_executable(std::path::Path::new(&home))
            .and_then(|path| path.canonicalize().ok());
        if resolved.as_ref() != Some(&selected) {
            return Err(
                "plugin.build.configuredToolUnavailable: Java does not match its JDK home".into(),
            );
        }
        environment.insert("JAVA_HOME".into(), home);
    }
    Ok(RuntimeExecutableInput {
        executable,
        environment,
        explicit: true,
    })
}

fn verified_identity(
    app: &AppHandle,
    context: &BuildModelContext,
) -> Result<super::super::ScannedPackage, String> {
    let package = super::super::launch::verified_package_by_id(app, &context.plugin_id)?;
    if package_input(&package).as_ref() != Some(&context.package) {
        return Err("plugin.build.packageChanged: reload the build instance".into());
    }
    Ok(package)
}

struct HostGuard<'a> {
    app: &'a AppHandle,
    operation: &'a ModelOperation,
    deadline: Instant,
}
impl ModelExecutionGuard for HostGuard<'_> {
    fn start_permit(&self) -> Result<Box<dyn StartPermit + '_>, String> {
        self.checkpoint()?;
        let permit = self.operation.start_permit()?;
        if self.cancelled() {
            return Err("plugin.build.cancelled".into());
        }
        Ok(Box::new(permit))
    }
    fn checkpoint(&self) -> Result<(), String> {
        if self.operation.cancelled() {
            return Err("plugin.build.cancelled".into());
        }
        if Instant::now() >= self.deadline {
            return Err("plugin.build.timeout".into());
        }
        if self.cancelled() {
            return Err("plugin.build.staleContext".into());
        }
        if !self
            .app
            .state::<BuildHostState>()
            .registry
            .lock()
            .map_err(|_| "build registry mutex poisoned")?
            .context_is_current(&self.operation.context)
        {
            return Err("plugin.build.staleContext".into());
        }
        verified_identity(self.app, &self.operation.context)?;
        let directory = WindowsBuildToolResolver::instance_directory(
            &self.operation.invocation,
            &PathBuf::from(&self.operation.context.workspace_root),
        )
        .map_err(|error| error.to_string())?;
        if directory != self.operation.working_directory {
            return Err("plugin.build.staleContext: workspace path changed".into());
        }
        Ok(())
    }
    fn cancelled(&self) -> bool {
        self.operation.cancelled()
            || Instant::now() >= self.deadline
            || self
                .app
                .get_webview_window(&self.operation.context.window_label)
                .is_none()
            || self
                .app
                .state::<super::super::lifecycle::LifecycleState>()
                .blocked(&self.operation.context.plugin_id)
            || self
                .app
                .state::<BuildHostState>()
                .registry
                .try_lock()
                .map(|registry| !registry.context_is_current(&self.operation.context))
                .unwrap_or_else(|error| matches!(error, std::sync::TryLockError::Poisoned(_)))
    }
}

pub(super) async fn prepare(
    app: AppHandle,
    window_label: String,
    workspace_root: String,
    plugin_id: String,
    build_system_id: String,
    root: String,
    runtime_executables: BTreeMap<String, String>,
) -> Result<BuildModelReview, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<BuildHostState>();
        let context = state.registry.lock().map_err(|_| "build registry mutex poisoned")?
            .model_context(&window_label, &workspace_root, &plugin_id, &build_system_id, &root)?;
        let _lease = app.state::<super::super::lifecycle::LifecycleState>().acquire(&plugin_id)?;
        let package = verified_identity(&app, &context)?;
        let id = next_operation_id();
        let state_directory = store::plugin_state_directory(&app, &plugin_id)?;
        let output_file = state_directory.join(format!("{id}.model.json"));
        let response = HostCoreExecutor.execute("build.modelPlan", json!({
            "manifest": context.package.manifest, "buildSystemID": build_system_id,
            "request": {"root": root, "options": context.options,
                "pluginDirectory": package.root, "workspaceStateDirectory": state_directory.join(store::workspace_state_key(&workspace_root)),
                "outputFile": output_file},
        }))?;
        core_ok(&response)?;
        let plan: ModelCommandPlan = serde_json::from_value(response["plan"].clone()).map_err(|error| format!("plugin.build.invalidPlan: {error}"))?;
        if plan.working_directory != context.root || !matches!(plan.output.as_str(), "stdout" | "outputFile") {
            return Err("plugin.build.invalidPlan: unsupported model command".into());
        }
        // Core invocation settings are global only: project files cannot
        // select an executable. Values and runtime preferences are frozen
        // before the review, never re-read after it has been accepted.
        let settings = super::super::settings::load_layers(&app, &plugin_id, &workspace_root)?;
        let invocation = HostCoreExecutor.execute("build.invocationPlan", json!({
            "manifest": context.package.manifest, "buildSystemID": build_system_id,
            "request": {"root": root, "platform": "windows", "settings": settings.global},
        }))?;
        core_ok(&invocation)?;
        let runtimes = runtime_executables.into_iter().filter(|(_, path)| !path.is_empty()).map(|(id, path)| {
            let input = explicit_runtime_input(&id, PathBuf::from(path))?;
            Ok((id, input))
        }).collect::<Result<BTreeMap<_, _>, String>>()?;
        let working_directory = WindowsBuildToolResolver::instance_directory(&invocation["invocation"], &PathBuf::from(&workspace_root))
            .map_err(|error| format!("{}: {error}", error.code()))?;
        verified_identity(&app, &context)?;
        let resolver = WindowsBuildToolResolver::from_current_process(runtimes).freeze_discovery()
            .map_err(|error| error.to_string())?;
        let operation = ModelOperation::new(id.clone(), context, plan, invocation["invocation"].clone(),
            resolver, output_file, working_directory);
        let review = state.operations.insert(operation)?;
        let operation = state.operations.get(&window_label, &id)?;
        if !state.registry.lock().map_err(|_| "build registry mutex poisoned")?.context_is_current(&operation.context) {
            operation.cancel(); return Err("plugin.build.staleContext".into());
        }
        Ok(review)
    }).await.map_err(|error| format!("build preparation task failed: {error}"))?
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BuildModelLoadResult {
    pub operation_id: String,
    pub view: super::super::build_registry::BuildView,
    /// Separate from model stdout; the caller may present it in Build Output.
    pub stderr: String,
}

pub(super) async fn load(
    app: AppHandle,
    window_label: String,
    operation_id: String,
) -> Result<BuildModelLoadResult, String> {
    // Claim before spawning so duplicate confirmations cannot start two jobs.
    let running = app
        .state::<BuildHostState>()
        .operations
        .claim(&window_label, &operation_id)?;
    tauri::async_runtime::spawn_blocking(move || {
        let operation = &running.0;
        let guard = HostGuard {
            app: &app,
            operation,
            deadline: Instant::now() + OPERATION_TIMEOUT,
        };
        guard.checkpoint()?;
        let _lease = app
            .state::<super::super::lifecycle::LifecycleState>()
            .acquire(&operation.context.plugin_id)?;
        guard.checkpoint()?;
        let _output = if operation.plan.output == "outputFile" {
            Some(ModelOutputFile::create(&operation.output_file)?)
        } else {
            None
        };
        let before = app
            .state::<BuildHostState>()
            .registry
            .lock()
            .map_err(|_| "build registry mutex poisoned")?
            .model_fingerprint(&HostCoreExecutor, &operation.context)?;
        let loaded = match execute_model(operation, &HostCoreExecutor, &NativeBuildExecutor, &guard)
        {
            Ok(loaded) => loaded,
            Err(error) if error.starts_with("plugin.build.cleanupFailed") => {
                operation.retain_failed_cleanup(_lease);
                return Err(error);
            }
            Err(error) => return Err(error),
        };
        let view = operation.publish(|| {
            guard.checkpoint()?;
            app.state::<BuildHostState>()
                .registry
                .lock()
                .map_err(|_| "build registry mutex poisoned")?
                .apply_command_model(&HostCoreExecutor, &operation.context, loaded.model, &before)
        })?;
        Ok(BuildModelLoadResult {
            operation_id,
            view,
            stderr: loaded.stderr,
        })
        // `running` drops after output-file cleanup and NativeLease release.
    })
    .await
    .map_err(|error| format!("build model task failed: {error}"))?
}

pub(super) async fn cancel(
    app: AppHandle,
    window_label: String,
    operation_id: String,
) -> Result<(), String> {
    let Ok(operation) = app
        .state::<BuildHostState>()
        .operations
        .get(&window_label, &operation_id)
    else {
        // A completed operation may already have been pruned. Cancellation
        // is idempotent and never operates on another window's process owner.
        return Ok(());
    };
    operation.cancel();
    operation.wait_finished().await
}

pub(super) async fn drain(operations: Vec<Arc<ModelOperation>>) -> Result<(), String> {
    for operation in operations {
        operation.wait_finished().await?;
    }
    Ok(())
}
