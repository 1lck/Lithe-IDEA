//! Tauri composition for declarative build detection and explicit model loads.
//!
//! Detection, static models, options and fingerprints remain passive.
//! Command and Provider models run after a window confirms a prepared operation.
//! The host still does not declare the
//! `buildSystems` capability, so no user-visible entry exists until the
//! remaining M4 batches land. Package trust is re-verified through M1's
//! launch gate (`verified_package_by_id`) on every call, the caller's window
//! label comes from the injected Tauri window (never from the frontend), and
//! the blocking Core/filesystem work runs on the async runtime instead of
//! the UI thread.

use super::build_registry::{
    BuildCoreExecutor, BuildOptionsPersistence, BuildPackageInput, BuildPackageSource,
    BuildRefreshTicket, BuildRegistry, StoredBuildOptions,
};
use super::store;
use serde::Serialize;
use serde_json::Value;
use std::sync::Mutex;
use tauri::{AppHandle, Manager, WebviewWindow};

mod dependencies;
#[cfg(test)]
mod dependencies_tests;
mod host;
pub(super) mod host_integration;
#[cfg(test)]
mod host_integration_tests;
mod language_import;
#[cfg(test)]
mod language_import_tests;
mod operation;
mod output;
#[path = "web_build_native.rs"]
pub(super) mod page;
mod process;
mod provider;
#[cfg(test)]
mod provider_tests;
mod run;
#[cfg(test)]
mod run_tests;
#[cfg(test)]
mod tests;

pub use dependencies::{
    BuildDependenciesResult, BuildDependenciesReview, BuildDependenciesSelection,
};
pub use host::BuildModelLoadResult;
pub use language_import::BuildLanguageImport;
pub use operation::BuildModelReview;
pub use output::BuildRunTerminal;
pub use run::{BuildRunReview, BuildRunSelection};

/// Registry shared by every window; entries are keyed per window label.
#[derive(Default)]
pub struct BuildHostState {
    registry: Mutex<BuildRegistry>,
    operations: operation::BuildOperations,
}

impl BuildHostState {
    /// VCS owns its own workspace admission and does not require a detected
    /// build model. It shares only settings-reload invalidation with builds.
    pub(crate) fn settings_scope_revision(
        &self,
        window: &str,
        root: &str,
        plugin: &str,
    ) -> Result<u64, String> {
        self.registry
            .try_lock()
            .map_err(|_| "plugin.settings.staleContext")?
            .settings_scope_revision(window, root, plugin)
    }

    /// Bind function preparation to one plugin's settings incarnation without
    /// invalidating other plugins or another window's workspace.
    pub(crate) fn function_scope_revision(
        &self,
        window: &str,
        root: &str,
        plugin: &str,
    ) -> Result<u64, String> {
        self.registry
            .try_lock()
            .map_err(|_| "plugin.function.staleContext")?
            .function_scope_revision(window, root, plugin)
    }

    /// Function consumers retain the same detected instance, including its
    /// option revision; they cannot grant themselves a workspace by IPC.
    pub(crate) fn function_context_is_current(
        &self,
        context: &super::build_registry::BuildModelContext,
    ) -> bool {
        self.registry
            .lock()
            .is_ok_and(|registry| registry.context_is_current(context))
    }
    /// Read the workspace incarnation already registered by the native build
    /// router. A settings action cannot create a scope by supplying a path.
    pub(crate) fn function_generation(&self, window: &str, root: &str) -> Result<u64, String> {
        let registry = self
            .registry
            .lock()
            .map_err(|_| "plugin.function.staleContext")?;
        registry.function_generation(window, root)
    }
}

/// Executes Core through the shared host envelope.
pub(super) struct HostCoreExecutor;

impl BuildCoreExecutor for HostCoreExecutor {
    fn execute(&self, command: &str, payload: Value) -> Result<Value, String> {
        super::scan::core_execute(command, payload)
    }
}

/// Every build-visible package passes M1's production trust gate: accepted
/// in the scan, enabled, not lifecycle-blocked, and re-verified against the
/// live bytes (`verified_package_by_id`). While `hostCapabilities` keeps
/// `buildSystems` closed, Core's validate gate rejects such packages, so
/// this stays empty in production; tests inject fixture manifests instead.
fn verified_build_packages(app: &AppHandle) -> Vec<super::ScannedPackage> {
    let mut packages = Vec::new();
    for candidate in app.state::<super::PluginHostState>().packages() {
        if candidate.entry.status != "accepted"
            || !candidate.entry.enabled
            || app
                .state::<super::lifecycle::LifecycleState>()
                .blocked(&candidate.entry.plugin_id)
        {
            continue;
        }
        // Re-run the launch trust check per package; a quarantined or
        // tampered package is skipped here instead of surfacing later.
        if let Ok(package) = super::launch::verified_package_by_id(app, &candidate.entry.plugin_id)
        {
            if package.manifest["buildSystems"]
                .as_array()
                .is_some_and(|systems| !systems.is_empty())
            {
                packages.push(package);
            }
        }
    }
    packages
}

fn package_input(package: &super::ScannedPackage) -> Option<BuildPackageInput> {
    Some(BuildPackageInput {
        plugin_id: package.entry.plugin_id.clone(),
        version: package.entry.version.clone(),
        manifest: package.manifest.clone(),
        content_identity: format!(
            "{}:{}",
            package.root.canonicalize().ok()?.display(),
            super::signature::content_digest(&package.root).ok()?
        ),
    })
}

/// The verified build package source used by the registry.
struct HostPackageSource {
    app: AppHandle,
    /// A registry call keeps the package mutation barrier through model read,
    /// final identity checks and publication. No process or writable resource
    /// is acquired by a passive model.
    leases: Mutex<std::collections::HashMap<String, super::lifecycle::NativeLease>>,
}

impl BuildPackageSource for HostPackageSource {
    fn accepted_packages(&self) -> Vec<BuildPackageInput> {
        self.app
            .state::<super::PluginHostState>()
            .packages()
            .into_iter()
            .filter(|package| package.entry.status == "accepted" && package.entry.enabled)
            .filter_map(|package| self.package(&package.entry.plugin_id))
            .collect()
    }

    fn package(&self, plugin_id: &str) -> Option<BuildPackageInput> {
        {
            let mut leases = self.leases.lock().ok()?;
            if !leases.contains_key(plugin_id) {
                let lease = self
                    .app
                    .state::<super::lifecycle::LifecycleState>()
                    .acquire(plugin_id)
                    .ok()?;
                leases.insert(plugin_id.into(), lease);
            }
        }
        let package = super::launch::verified_package_by_id(&self.app, plugin_id).ok()?;
        if !package.manifest["buildSystems"]
            .as_array()
            .is_some_and(|systems| !systems.is_empty())
        {
            return None;
        }
        package_input(&package)
    }
}

/// Build option values per workspace under
/// `app_local_data_dir()/plugin-build-options/<workspace key>.json`, beside
/// the other plugin state; nothing is written into packages or the install
/// directory.
struct HostOptionsPersistence {
    app: AppHandle,
}

impl HostOptionsPersistence {
    fn store_path(&self, workspace_root: &str) -> Result<std::path::PathBuf, String> {
        Ok(self
            .app
            .path()
            .app_local_data_dir()
            .map_err(|error| error.to_string())?
            .join("plugin-build-options")
            .join(format!(
                "{}.json",
                store::workspace_state_key(workspace_root)
            )))
    }
}

impl BuildOptionsPersistence for HostOptionsPersistence {
    fn load(&self, workspace_root: &str) -> Result<StoredBuildOptions, String> {
        let path = self.store_path(workspace_root)?;
        let text = match std::fs::read_to_string(&path) {
            Ok(text) => text,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(StoredBuildOptions::default())
            }
            Err(error) => return Err(error.to_string()),
        };
        serde_json::from_str(&text)
            .map_err(|error| format!("{} is not valid JSON: {error}", path.display()))
    }

    fn save(&self, workspace_root: &str, options: &StoredBuildOptions) -> Result<(), String> {
        let path = self.store_path(workspace_root)?;
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
        }
        let temp = path.with_extension("json.tmp");
        std::fs::write(
            &temp,
            serde_json::to_string_pretty(options).map_err(|e| e.to_string())?,
        )
        .map_err(|error| error.to_string())?;
        std::fs::rename(&temp, &path).map_err(|error| error.to_string())
    }
}

/// One plugin's declared build systems, for tool-window registration only.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BuildCatalogEntry {
    pub plugin_id: String,
    pub plugin_display_name: String,
    pub build_system_id: String,
    pub build_system_display_name: String,
    /// Presentation icon path as declared; the host does not interpret it.
    pub icon: Option<String>,
}

/// Declared build systems of packages that pass the trust gate right now.
/// This is a structural listing for window registration; Core validates
/// every declaration again on the next `build.detect`.
#[tauri::command]
pub async fn declarative_plugins_build_catalog(
    app: AppHandle,
) -> Result<Vec<BuildCatalogEntry>, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let mut entries = Vec::new();
        for package in verified_build_packages(&app) {
            for system in package.manifest["buildSystems"]
                .as_array()
                .map(Vec::as_slice)
                .unwrap_or_default()
            {
                let id = system["id"].as_str().unwrap_or_default();
                if id.is_empty() {
                    continue;
                }
                entries.push(BuildCatalogEntry {
                    plugin_id: package.entry.plugin_id.clone(),
                    plugin_display_name: package.entry.display_name.clone(),
                    build_system_id: id.to_string(),
                    build_system_display_name: system["displayName"]
                        .as_str()
                        .unwrap_or(id)
                        .to_string(),
                    icon: system["icon"].as_str().map(str::to_string),
                });
            }
        }
        Ok(entries)
    })
    .await
    .map_err(|error| format!("build catalog task failed: {error}"))?
}

/// Passive Core import for one exact Java/build snapshot. No project code or
/// Wrapper is executed; the optional identity rechecks a prepared snapshot.
#[tauri::command]
pub async fn declarative_plugins_build_language_import(
    app: AppHandle,
    window: WebviewWindow,
    workspace_root: String,
    generation: u64,
    source_path: Option<String>,
    expected_identity: Option<String>,
) -> Result<BuildLanguageImport, String> {
    language_import::prepare(
        app,
        window.label().into(),
        workspace_root,
        generation,
        source_path,
        expected_identity,
    )
    .await
}

/// Re-detects build-system instances for the calling window and workspace.
/// The window label comes from the injected window, never the frontend.
#[tauri::command]
pub async fn declarative_plugins_build_refresh(
    app: AppHandle,
    window: WebviewWindow,
    workspace_root: String,
) -> Result<Value, String> {
    let window_label = window.label().to_string();
    let (_suspension, ticket) = suspend_build_refresh(&app, &window_label, &workspace_root)?;
    stop_build_operations(&app, |operation| {
        operation.context.window_label == window_label
    })
    .await?;
    let checkpoint_app = app.clone();
    run_build_task(app, move |registry, source, persistence| {
        let view =
            registry.refresh_reserved(&HostCoreExecutor, source, persistence, &ticket, &|| {
                live_build_window(&checkpoint_app, &window_label)
            })?;
        serde_json::to_value(view).map_err(|error| error.to_string())
    })
    .await
}

/// Applies one option edit (or reset with `value: null`). The candidate is
/// validated through Core before anything is persisted.
#[tauri::command]
pub async fn declarative_plugins_build_set_option(
    app: AppHandle,
    window: WebviewWindow,
    workspace_root: String,
    plugin_id: String,
    build_system_id: String,
    root: String,
    option_id: String,
    value: Option<Value>,
) -> Result<Value, String> {
    let window_label = window.label().to_string();
    run_build_option_edit(
        app,
        window_label.clone(),
        move |registry, source, persistence| {
            let view = registry.set_option(
                &HostCoreExecutor,
                source,
                persistence,
                &window_label,
                &workspace_root,
                &plugin_id,
                &build_system_id,
                &root,
                &option_id,
                value,
            )?;
            serde_json::to_value(view).map_err(|error| error.to_string())
        },
    )
    .await
}

/// Recomputes one instance's sync fingerprint; the frontend debounces this
/// on workspace file changes.
#[tauri::command]
pub async fn declarative_plugins_build_sync_check(
    app: AppHandle,
    window: WebviewWindow,
    workspace_root: String,
    plugin_id: String,
    build_system_id: String,
    root: String,
) -> Result<Value, String> {
    let window_label = window.label().to_string();
    run_build_task(app, move |registry, source, persistence| {
        let view = registry.sync_check(
            &HostCoreExecutor,
            source,
            &window_label,
            &workspace_root,
            &plugin_id,
            &build_system_id,
            &root,
        )?;
        serde_json::to_value(view).map_err(|error| error.to_string())
    })
    .await
}

/// Revokes every session of one plugin across all windows. Called from the
/// frontend lifecycle listener when a plugin is disabled, replaced, rolled
/// back, or uninstalled, so stored sessions can never answer again.
#[tauri::command]
pub async fn declarative_plugins_build_plugins_changed(
    app: AppHandle,
    window: WebviewWindow,
    plugin_id: String,
) -> Result<(), String> {
    let window_label = window.label().to_string();
    app.state::<BuildHostState>()
        .registry
        .lock()
        .map_err(|_| "build registry mutex poisoned")?
        .drop_plugin(&plugin_id);
    stop_build_operations(&app, |operation| operation.context.plugin_id == plugin_id).await?;
    run_build_task(app, move |registry, _source, _persistence| {
        registry.drop_plugin(&plugin_id);
        let _ = window_label;
        Ok(())
    })
    .await
}

/// Clears the calling window's sessions when its workspace closed, so
/// reopening the same path cannot reuse the pre-close sessions.
#[tauri::command]
pub async fn declarative_plugins_build_close_workspace(
    app: AppHandle,
    window: WebviewWindow,
    workspace_root: String,
) -> Result<(), String> {
    let window_label = window.label().to_string();
    super::provider::close_workspace(&app, &window_label, &workspace_root)
        .await
        .map_err(|error| error.detail)?;
    // A late close for a detached workspace must not suspend a newer one.
    let _suspension = {
        let state = app.state::<BuildHostState>();
        let mut registry = state
            .registry
            .lock()
            .map_err(|_| "build registry mutex poisoned")?;
        if registry.view(&window_label).workspace_root == workspace_root {
            let generation = registry.suspend_execution(&window_label);
            Some(BuildExecutionSuspension {
                app: app.clone(),
                window: window_label.clone(),
                generation,
            })
        } else {
            None
        }
    };
    super::functions::close_workspace(&app, &window_label, &workspace_root).await?;
    stop_build_operations(&app, |operation| {
        operation.context.window_label == window_label
            && operation.context.workspace_root == workspace_root
    })
    .await?;
    run_build_task(app, move |registry, _source, _persistence| {
        registry.close_workspace(&window_label, &workspace_root);
        Ok(())
    })
    .await
}

#[tauri::command]
pub async fn declarative_plugins_build_prepare_model(
    app: AppHandle,
    window: WebviewWindow,
    workspace_root: String,
    plugin_id: String,
    build_system_id: String,
    root: String,
    runtime_executables: std::collections::BTreeMap<String, String>,
) -> Result<BuildModelReview, String> {
    host::prepare(
        app,
        window.label().to_string(),
        workspace_root,
        plugin_id,
        build_system_id,
        root,
        runtime_executables,
    )
    .await
}

#[tauri::command]
pub async fn declarative_plugins_build_load_model(
    app: AppHandle,
    window: WebviewWindow,
    operation_id: String,
) -> Result<BuildModelLoadResult, String> {
    let result = host::load(app.clone(), window.label().to_string(), operation_id).await?;
    run_build_task(app, |_, _, _| Ok(())).await?;
    Ok(result)
}

/// Confirms only the reviewed shared-language start. The following model or
/// dependency command still claims and verifies the same native operation.
#[tauri::command]
pub async fn declarative_plugins_build_authorize_provider_language(
    app: AppHandle,
    window: WebviewWindow,
    operation_id: String,
) -> Result<(), String> {
    provider::authorize_shared(app, window.label().to_owned(), operation_id).await
}

#[tauri::command]
pub async fn declarative_plugins_build_cancel_operation(
    app: AppHandle,
    window: WebviewWindow,
    operation_id: String,
) -> Result<(), String> {
    host::cancel(app, window.label().to_string(), operation_id).await
}

/// Prepares a declared task/test against the current native model. This call
/// never probes a wrapper or starts a project process.
#[tauri::command]
pub async fn declarative_plugins_build_prepare_run(
    app: AppHandle,
    window: WebviewWindow,
    workspace_root: String,
    plugin_id: String,
    build_system_id: String,
    root: String,
    selection: BuildRunSelection,
) -> Result<BuildRunReview, String> {
    host::prepare_run(
        app,
        window.label().to_string(),
        workspace_root,
        plugin_id,
        build_system_id,
        root,
        selection,
    )
    .await
}

/// Confirms exactly one prepared operation. Subscribe to this window's
/// `declarative-build-output` before calling; terminal is the last event.
#[tauri::command]
pub async fn declarative_plugins_build_execute_run(
    app: AppHandle,
    window: WebviewWindow,
    operation_id: String,
) -> Result<BuildRunTerminal, String> {
    host::execute_run(app, window.label().to_string(), operation_id).await
}

/// Prepares Core dependency argv with native model IDs, without probing tools.
#[tauri::command]
pub async fn declarative_plugins_build_prepare_dependencies(
    app: AppHandle,
    window: WebviewWindow,
    workspace_root: String,
    plugin_id: String,
    build_system_id: String,
    root: String,
    selection: BuildDependenciesSelection,
) -> Result<BuildDependenciesReview, String> {
    dependencies::prepare(
        app,
        window.label().to_string(),
        workspace_root,
        plugin_id,
        build_system_id,
        root,
        selection,
    )
    .await
}

/// Confirms the shared single-use operation; Core trees return after cleanup.
#[tauri::command]
pub async fn declarative_plugins_build_load_dependencies(
    app: AppHandle,
    window: WebviewWindow,
    operation_id: String,
) -> Result<BuildDependenciesResult, String> {
    dependencies::load(app, window.label().to_string(), operation_id).await
}

async fn stop_build_operations(
    app: &AppHandle,
    predicate: impl Fn(&operation::ModelOperation) -> bool,
) -> Result<(), String> {
    let operations = app
        .state::<BuildHostState>()
        .operations
        .cancel_matching(predicate);
    host::drain(app, operations).await
}

/// Settings use the existing model owner and its retryable cleanup. No
/// package-wide lifecycle event or persistent enable-state change is needed.
pub(crate) async fn reload_settings_models(
    app: AppHandle,
    label: String,
    receipt: super::settings::reload::Receipt,
) -> Result<super::build_registry::BuildView, String> {
    let preflight_app = app.clone();
    let preflight_label = label.clone();
    let preflight = receipt.clone();
    let (generation, operations) = tauri::async_runtime::spawn_blocking(move || {
        super::settings::reload::check_owner(&preflight_app, &preflight_label, &preflight)?;
        let state = preflight_app.state::<BuildHostState>();
        let mut registry = state
            .registry
            .lock()
            .map_err(|_| "plugin.settings.unavailable")?;
        // A failed drain still owns the original operations. Reclaim them
        // before checking a later settings conflict, as the global barrier does.
        if !registry.settings_reload_pending(
            &preflight_label,
            &preflight.workspace_path,
            &preflight.plugin_id,
        ) {
            super::settings::reload::check(&preflight_app, &preflight_label, &preflight)?;
        }
        let generation = registry.begin_settings_reload(
            &preflight_label,
            &preflight.workspace_path,
            &preflight.plugin_id,
        )?;
        // Capture original owners while admission is still locked. A delayed
        // drain must never select a replacement workspace by its reused label.
        let operations = state.operations.matching(|operation| {
            operation.context.window_label == preflight_label
                && operation.context.workspace_root == preflight.workspace_path
                && operation.context.plugin_id == preflight.plugin_id
        });
        Ok::<_, String>((generation, operations))
    })
    .await
    .map_err(|_| "plugin.settings.unavailable")??;
    for operation in &operations {
        operation.cancel();
    }
    let function_cleanup =
        super::functions::close_scope(&app, &label, &receipt.workspace_path, &receipt.plugin_id)
            .await;
    let vcs_cleanup =
        super::vcs::close_scope(&app, &label, &receipt.workspace_path, &receipt.plugin_id).await;
    let build_cleanup = host::drain(&app, operations).await;
    function_cleanup
        .and(vcs_cleanup)
        .and(build_cleanup)
        .map_err(|error| format!("plugin.settings.reloadStopFailed: {error}"))?;
    let checkpoint_app = app.clone();
    run_build_task(app, move |registry, packages, persistence| {
        let checkpoint =
            || super::settings::reload::check(&checkpoint_app, &label, &receipt).map(|_| ());
        let result = registry.reload_settings(
            &HostCoreExecutor,
            packages,
            persistence,
            &label,
            &receipt.workspace_path,
            generation,
            &receipt.plugin_id,
            &checkpoint,
        );
        if result.as_ref().is_err_and(|error| {
            error == "plugin.settings.conflict" || error == "plugin.settings.staleContext"
        }) {
            registry.finish_settings_reload(&label, generation, &receipt.plugin_id);
        }
        result
    })
    .await
}

/// Bind the ordinary explicit model preparation to the original saved receipt.
/// Its normal execution guard rechecks this binding before start/publication.
pub(crate) async fn prepare_settings_reload_model(
    app: AppHandle,
    label: String,
    receipt: super::settings::reload::Receipt,
    system: String,
    root: String,
    runtimes: std::collections::BTreeMap<String, String>,
) -> Result<BuildModelReview, String> {
    let check_app = app.clone();
    let check_label = label.clone();
    let expected = receipt.clone();
    tauri::async_runtime::spawn_blocking(move || {
        super::settings::reload::check(&check_app, &check_label, &expected)
    })
    .await
    .map_err(|_| "plugin.settings.unavailable")??;
    let review = host::prepare_with_refresh(
        app.clone(),
        label.clone(),
        receipt.workspace_path.clone(),
        receipt.plugin_id.clone(),
        system,
        root,
        runtimes,
        true,
    )
    .await?;
    let operation = app
        .state::<BuildHostState>()
        .operations
        .get(&label, &review.operation_id)?;
    *operation
        .settings_reload
        .lock()
        .map_err(|_| "plugin.settings.unavailable")? = Some(receipt);
    Ok(review)
}

struct BuildExecutionSuspension {
    app: AppHandle,
    window: String,
    generation: u64,
}
impl Drop for BuildExecutionSuspension {
    fn drop(&mut self) {
        let state = self.app.state::<BuildHostState>();
        if let Ok(mut registry) = state.registry.lock() {
            registry.resume_execution(&self.window);
        };
        super::web::build::workflow::queue_instance_changes(self.app.clone());
    }
}

fn suspend_build_execution(
    app: &AppHandle,
    window_label: &str,
) -> Result<BuildExecutionSuspension, String> {
    let generation = app
        .state::<BuildHostState>()
        .registry
        .lock()
        .map_err(|_| "build registry mutex poisoned")?
        .suspend_execution(window_label);
    Ok(BuildExecutionSuspension {
        app: app.clone(),
        window: window_label.into(),
        generation,
    })
}

fn live_build_window(app: &AppHandle, window_label: &str) -> Result<(), String> {
    if (window_label == "main" || window_label.starts_with("workspace-"))
        && app.get_webview_window(window_label).is_some()
    {
        Ok(())
    } else {
        Err("plugin.build.staleContext".into())
    }
}

fn suspend_build_refresh(
    app: &AppHandle,
    window_label: &str,
    workspace_root: &str,
) -> Result<(BuildExecutionSuspension, BuildRefreshTicket), String> {
    live_build_window(app, window_label)?;
    let state = app.state::<BuildHostState>();
    let mut registry = state
        .registry
        .lock()
        .map_err(|_| "build registry mutex poisoned")?;
    let generation = registry.suspend_execution(window_label);
    let ticket = registry.reserve_refresh(window_label, workspace_root);
    Ok((
        BuildExecutionSuspension {
            app: app.clone(),
            window: window_label.into(),
            generation,
        },
        ticket,
    ))
}

/// Main's native window-destruction hook must call this even when pagehide
/// cannot run. Native cancellation also observes a missing host window.
pub async fn close_build_window(app: AppHandle, window_label: String) -> Result<(), String> {
    let _suspension = suspend_build_execution(&app, &window_label)?;
    stop_build_operations(&app, |operation| {
        operation.context.window_label == window_label
    })
    .await?;
    app.state::<BuildHostState>()
        .registry
        .lock()
        .map_err(|_| "build registry mutex poisoned")?
        .close_window(&window_label);
    Ok(())
}

/// Runs one registry operation on the async runtime's blocking pool: Core
/// calls and file I/O must never occupy the UI thread, and the registry
/// mutex is only held inside the spawned task.
pub(super) async fn run_build_task<T, F>(app: AppHandle, operation: F) -> Result<T, String>
where
    T: Send + 'static,
    F: FnOnce(
            &mut BuildRegistry,
            &dyn BuildPackageSource,
            &dyn BuildOptionsPersistence,
        ) -> Result<T, String>
        + Send
        + 'static,
{
    tauri::async_runtime::spawn_blocking(move || {
        let source = HostPackageSource {
            app: app.clone(),
            leases: Mutex::new(Default::default()),
        };
        let persistence = HostOptionsPersistence { app: app.clone() };
        let state = app.state::<BuildHostState>();
        let mut registry = state
            .registry
            .lock()
            .map_err(|_| "build registry mutex poisoned")?;
        let result = operation(&mut registry, &source, &persistence);
        if result.is_ok() {
            super::web::build::workflow::publish_instance_changes(&app, &registry, &source);
        }
        result
    })
    .await
    .map_err(|error| format!("build task failed: {error}"))?
}

/// Web option edits share the native suspension and cleanup barrier. Their
/// page checkpoint runs inside the same registry task before any persistence.
pub(super) async fn run_build_option_edit<T, F>(
    app: AppHandle,
    window_label: String,
    operation: F,
) -> Result<T, String>
where
    T: Send + 'static,
    F: FnOnce(
            &mut BuildRegistry,
            &dyn BuildPackageSource,
            &dyn BuildOptionsPersistence,
        ) -> Result<T, String>
        + Send
        + 'static,
{
    let suspension = suspend_build_execution(&app, &window_label)?;
    let generation = suspension.generation;
    stop_build_operations(&app, |operation| {
        operation.context.window_label == window_label
    })
    .await?;
    run_build_task(app, move |registry, source, persistence| {
        registry.check_generation(&window_label, generation)?;
        operation(registry, source, persistence)
    })
    .await
}
