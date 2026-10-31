//! Provider routing for the existing build operation owner. Core produces the
//! request plan and decodes the reply; the native session owns all transport.

use super::super::provider as sessions;
use super::host::{verified_identity, HostGuard};
use super::operation::*;
use super::{BuildHostState, HostCoreExecutor};
use serde_json::{json, Value};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Manager};

pub(super) struct ProviderOperation {
    pub plan: Value,
    pub review: sessions::ProviderReview,
    plugin_directory: std::path::PathBuf,
    workspace_state_directory: std::path::PathBuf,
    app: AppHandle,
}
impl ProviderOperation {
    pub fn cancel_review(&self) {
        sessions::discard_review(&self.app, &self.review.context.window, self.review.token);
    }
}
impl Drop for ProviderOperation {
    fn drop(&mut self) {
        self.cancel_review();
    }
}

pub(super) async fn authorize_shared(
    app: AppHandle,
    window: String,
    id: String,
) -> Result<(), String> {
    blocking(move || {
        let operation = app.state::<BuildHostState>().operations.get(&window, &id)?;
        let provider = operation
            .provider
            .as_ref()
            .ok_or("plugin.build.invalidPlan")?;
        let guard = HostGuard {
            app: &app,
            operation: &operation,
            deadline: Instant::now() + Duration::from_secs(10),
        };
        guard.checkpoint()?;
        if operation.dependencies.is_some() {
            super::dependencies::DependencyGuard {
                base: HostGuard {
                    app: &app,
                    operation: &operation,
                    deadline: Instant::now() + Duration::from_secs(10),
                },
            }
            .checkpoint()?;
        }
        sessions::authorize_shared_language(&app, &window, provider.review.token, || {
            guard.checkpoint()
        })
        .map_err(failure)
    })
    .await
}

/// Called on the existing preparation worker. Resolving programs is passive;
/// version probes, initialization and project code wait for native confirm.
pub(super) fn prepare(
    app: &AppHandle,
    context: &super::super::build_registry::BuildModelContext,
    plan: Value,
    runtimes: std::collections::BTreeMap<
        String,
        super::super::build_resolver::RuntimeExecutableInput,
    >,
) -> Result<ProviderOperation, String> {
    let window = app
        .get_webview_window(&context.window_label)
        .ok_or("plugin.build.staleContext")?;
    tauri::async_runtime::block_on(sessions::set_workspace(
        app,
        &window,
        context.workspace_root.clone(),
        context.generation,
    ))
    .map_err(failure)?;
    let package = verified_identity(app, context)?;
    let state = super::store::plugin_state_directory(app, &context.plugin_id)?;
    let review = sessions::prepare(
        app,
        &window,
        context.workspace_root.clone(),
        context.generation,
        context.plugin_id.clone(),
        context.build_system_id.clone(),
        context.root.clone(),
        runtimes,
    )
    .map_err(failure)?;
    Ok(ProviderOperation {
        plan,
        review,
        app: app.clone(),
        plugin_directory: package.root,
        workspace_state_directory: state
            .join(super::store::workspace_state_key(&context.workspace_root)),
    })
}

pub(super) fn command(plan: &Value) -> Result<ModelCommandPlan, String> {
    if plan["provider"]["method"].as_str().is_none() || plan["provider"]["params"].is_null() {
        return Err("plugin.build.invalidPlan".into());
    }
    Ok(ModelCommandPlan {
        arguments: Vec::new(),
        environment: Default::default(),
        working_directory: plan["root"]
            .as_str()
            .ok_or("plugin.build.invalidPlan")?
            .into(),
        output: "provider".into(),
        executes_project_code: plan["executesProjectCode"].as_bool().unwrap_or(true),
        may_use_network: plan["mayUseNetwork"].as_bool().unwrap_or(true),
    })
}

fn failure(error: sessions::ProviderError) -> String {
    // Native diagnostic detail stays out of user-visible text; the frontend
    // translates these stable keys through the shared dictionary.
    match error.code {
        "provider.cancelled" => "plugin.build.cancelled",
        "provider.notNegotiated" | "provider.notReady" => "plugin.build.providerNotNegotiated",
        "provider.stopFailed" => "plugin.build.cleanupFailed",
        "provider.requestTimeout" | "provider.initializeTimeout" | "provider.transportTimeout" => {
            "plugin.build.timeout"
        }
        "provider.identityChanged" | "provider.invalidInstance" => "plugin.build.staleContext",
        _ => "plugin.build.providerFailed",
    }
    .into()
}

pub(super) fn decode(
    core: &dyn super::super::build_registry::BuildCoreExecutor,
    operation: &ModelOperation,
    result: Value,
    project: Option<&str>,
) -> Result<Value, String> {
    let dependencies = operation.dependencies.is_some();
    let response=core.execute(if dependencies {"build.decodeDependencies"} else {"build.decodeModel"},json!({
        "manifest":operation.context.package.manifest,"buildSystemID":operation.context.build_system_id,
        "request":{"workspaceRoot":operation.context.workspace_root,"root":operation.context.root,
            "options":operation.context.options,"project":project,"result":result},
    }))?;
    core_ok(&response)?;
    Ok(response[if dependencies {
        "dependencies"
    } else {
        "model"
    }]
    .clone())
}

/// Only failed automatic discovery permits the Provider's optional tool hint
/// to be omitted. Explicit selections and invalid/unsafe plans stay terminal.
pub(super) fn tool_hint(
    resolved: Result<super::super::build_resolver::ResolvedBuildTool, String>,
) -> Result<Option<std::path::PathBuf>, String> {
    match resolved {
        Ok(tool) => Ok(Some(tool.executable)),
        Err(error) if error.starts_with("plugin.build.toolUnavailable:") => {
            eprintln!("Build Provider will resolve its own tool: {error}");
            Ok(None)
        }
        Err(error) => Err(error),
    }
}

async fn request(app: &AppHandle, operation: &Arc<ModelOperation>) -> Result<Value, String> {
    let prepared = operation
        .provider
        .as_ref()
        .ok_or("plugin.build.invalidPlan")?;
    let window = app
        .get_webview_window(&operation.context.window_label)
        .ok_or("plugin.build.staleContext")?;
    let plan = {
        let app = app.clone();
        let operation = operation.clone();
        blocking(move || {
            let guard = HostGuard {
                app: &app,
                operation: &operation,
                deadline: Instant::now() + Duration::from_secs(180),
            };
            guard.checkpoint()?;
            let lease = app
                .state::<super::super::lifecycle::LifecycleState>()
                .acquire(&operation.context.plugin_id)?;
            let resolved = resolve_tool(
                &operation,
                &HostCoreExecutor,
                &super::process::NativeBuildExecutor,
                &guard,
            );
            if let Err(error) = &resolved {
                if error.starts_with("plugin.build.cleanupFailed") {
                    operation.retain_failed_cleanup(lease);
                    return Err(error.clone());
                }
            }
            guard.checkpoint()?;
            let tool = tool_hint(resolved)?;
            replan(&HostCoreExecutor, &operation, tool.as_deref())
        })
        .await?
    };
    let future = async {
        let binding = sessions::confirm(app, &window, prepared.review.token)
            .await
            .map_err(failure)?;
        binding
            .request(app, &window, plan, 180000)
            .await
            .map_err(failure)
    };
    let result = tokio::select! { biased;
        _=operation.wait_cancelled()=>Err("plugin.build.cancelled".into()),
        result=tokio::time::timeout(Duration::from_secs(200),future)=>result.unwrap_or_else(|_|Err("plugin.build.timeout".into())),
    };
    if result.is_err() {
        if let Err(error) =
            sessions::drain_initialization(app, window.label(), prepared.review.token).await
        {
            operation.retain_provider_session_cleanup();
            return Err(failure(error));
        }
    }
    if result
        .as_ref()
        .err()
        .is_some_and(|error| error.starts_with("plugin.build.cleanupFailed"))
    {
        operation.retain_provider_session_cleanup();
    }
    result
}

/// Optional host tool hints are produced by Core too. Failed discovery omits
/// the hint and lets the Provider use its own upstream tool discovery.
pub(super) fn replan(
    core: &dyn super::super::build_registry::BuildCoreExecutor,
    operation: &ModelOperation,
    tool: Option<&std::path::Path>,
) -> Result<Value, String> {
    let dependencies = operation.dependencies.as_ref();
    let project = dependencies
        .and_then(|prepared| prepared.project_id.as_ref())
        .and_then(|id| {
            operation.context.model["projects"]
                .as_array()
                .and_then(|projects| {
                    projects
                        .iter()
                        .find(|project| project["id"].as_str() == Some(id.as_str()))
                })
        })
        .cloned();
    let original = operation.provider.as_ref().map(|provider| &provider.plan);
    let response=core.execute(if dependencies.is_some(){"build.dependencyPlan"}else{"build.modelPlan"},json!({
        "manifest":operation.context.package.manifest,"buildSystemID":operation.context.build_system_id,
        "request":{"root":operation.context.root,"options":operation.context.options,"project":project,
            "pluginDirectory":operation.provider.as_ref().map(|provider|&provider.plugin_directory),
            "workspaceStateDirectory":operation.provider.as_ref().map(|provider|&provider.workspace_state_directory),
            "refresh":original.is_some_and(|plan|plan["provider"]["params"]["refresh"] == true),
            "tool":tool.map(|path|json!({"executable":path.to_string_lossy()}))},
    }))?;
    core_ok(&response)?;
    if !response["plan"]["provider"].is_object() {
        return Err("plugin.build.invalidPlan".into());
    }
    Ok(response["plan"].clone())
}

async fn blocking<T: Send + 'static>(
    task: impl FnOnce() -> Result<T, String> + Send + 'static,
) -> Result<T, String> {
    tauri::async_runtime::spawn_blocking(task)
        .await
        .map_err(|_| "plugin.build.processFailed".to_string())?
}

pub(super) async fn load_model(
    app: AppHandle,
    running: RunningModelOperation,
) -> Result<super::host::BuildModelLoadResult, String> {
    let operation = running.0.clone();
    let before = {
        let app = app.clone();
        let operation = operation.clone();
        blocking(move || {
            let guard = HostGuard {
                app: &app,
                operation: &operation,
                deadline: Instant::now() + Duration::from_secs(210),
            };
            guard.checkpoint()?;
            let fingerprint = app
                .state::<BuildHostState>()
                .registry
                .lock()
                .map_err(|_| "build registry mutex poisoned")?
                .model_fingerprint(&HostCoreExecutor, &operation.context)?;
            Ok(fingerprint)
        })
        .await?
    };
    let result = request(&app, &operation).await?;
    blocking(move || {
        let operation = &running.0;
        let guard = HostGuard {
            app: &app,
            operation,
            deadline: Instant::now() + Duration::from_secs(10),
        };
        guard.checkpoint()?;
        verified_identity(&app, &operation.context)?;
        let model = decode(&HostCoreExecutor, operation, result, None)?;
        let view = operation.publish(|| {
            guard.checkpoint()?;
            app.state::<BuildHostState>()
                .registry
                .lock()
                .map_err(|_| "build registry mutex poisoned")?
                .apply_command_model(&HostCoreExecutor, &operation.context, model, &before)
        })?;
        Ok(super::host::BuildModelLoadResult {
            operation_id: operation.id.clone(),
            view,
            stderr: String::new(),
        })
    })
    .await
}

pub(super) async fn load_dependencies(
    app: AppHandle,
    running: RunningModelOperation,
) -> Result<super::dependencies::BuildDependenciesResult, String> {
    let operation = running.0.clone();
    let checked = {
        let app = app.clone();
        let operation = operation.clone();
        blocking(move || {
            let guard = super::dependencies::DependencyGuard {
                base: HostGuard {
                    app: &app,
                    operation: &operation,
                    deadline: Instant::now() + Duration::from_secs(210),
                },
            };
            guard.checkpoint()
        })
        .await
    };
    let loaded = match checked {
        Ok(()) => request(&app, &operation).await,
        Err(error) => Err(error),
    };
    if loaded
        .as_ref()
        .err()
        .is_some_and(|error| error.starts_with("plugin.build.cleanupFailed"))
    {
        return Err(loaded.err().unwrap());
    }
    blocking(move || {
        let operation = &running.0;
        let guard = super::dependencies::DependencyGuard {
            base: HostGuard {
                app: &app,
                operation,
                deadline: Instant::now() + Duration::from_secs(10),
            },
        };
        let loaded = loaded.and_then(|reply| {
            guard.checkpoint()?;
            let decoded = decode(
                &HostCoreExecutor,
                operation,
                reply,
                operation
                    .dependencies
                    .as_ref()
                    .and_then(|dependencies| dependencies.project_path.as_deref()),
            )?;
            if !decoded["dependencies"].is_array() {
                return Err("plugin.build.invalidOutput".into());
            }
            Ok(decoded)
        });
        let terminal = operation.complete_run(
            match &loaded {
                Ok(_) => super::output::BuildRunTerminal {
                    kind: "succeeded".into(),
                    exit_code: None,
                    message: None,
                },
                Err(error) => super::run::error_terminal(error),
            },
            || guard.checkpoint(),
        )?;
        let decoded = loaded.ok().filter(|_| terminal.kind == "succeeded");
        Ok(super::dependencies::BuildDependenciesResult {
            review: super::dependencies::review(operation)?,
            terminal,
            truncated: decoded
                .as_ref()
                .is_some_and(|tree| tree["truncated"] == true),
            dependency_tree: decoded.clone(),
            dependencies: decoded.map(|tree| tree["dependencies"].clone()),
        })
    })
    .await
}
