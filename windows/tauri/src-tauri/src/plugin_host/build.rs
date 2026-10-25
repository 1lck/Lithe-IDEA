//! Tauri commands for the declarative build-system registry (M4-A).
//!
//! This batch wires the read-only path only: detection, static models,
//! option resolution and persistence, and sync fingerprints. No plugin
//! process runs from here, and the host still does not declare the
//! `buildSystems` capability, so no user-visible entry exists until the
//! remaining M4 batches land. Package trust is re-verified through M1's
//! launch gate (`verified_package_by_id`) on every call, the caller's window
//! label comes from the injected Tauri window (never from the frontend), and
//! the blocking Core/filesystem work runs on the async runtime instead of
//! the UI thread.

use super::build_registry::{
    BuildCoreExecutor, BuildOptionsPersistence, BuildPackageInput, BuildPackageSource,
    BuildRegistry, StoredBuildOptions,
};
use super::store;
use serde::Serialize;
use serde_json::Value;
use std::sync::Mutex;
use tauri::{AppHandle, Manager, WebviewWindow};

/// Registry shared by every window; entries are keyed per window label.
#[derive(Default)]
pub struct BuildHostState {
    registry: Mutex<BuildRegistry>,
}

/// Executes Core through the shared host envelope.
struct HostCoreExecutor;

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

fn package_input(package: &super::ScannedPackage) -> BuildPackageInput {
    BuildPackageInput {
        plugin_id: package.entry.plugin_id.clone(),
        version: package.entry.version.clone(),
        manifest: package.manifest.clone(),
    }
}

/// The verified build package source used by the registry.
struct HostPackageSource {
    app: AppHandle,
}

impl BuildPackageSource for HostPackageSource {
    fn accepted_packages(&self) -> Vec<BuildPackageInput> {
        verified_build_packages(&self.app)
            .iter()
            .map(package_input)
            .collect()
    }

    fn package(&self, plugin_id: &str) -> Option<BuildPackageInput> {
        verified_build_packages(&self.app)
            .iter()
            .find(|package| package.entry.plugin_id == plugin_id)
            .map(package_input)
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

/// Re-detects build-system instances for the calling window and workspace.
/// The window label comes from the injected window, never the frontend.
#[tauri::command]
pub async fn declarative_plugins_build_refresh(
    app: AppHandle,
    window: WebviewWindow,
    workspace_root: String,
) -> Result<Value, String> {
    let window_label = window.label().to_string();
    run_build_task(app, move |registry, source, persistence| {
        let view = registry.refresh(
            &HostCoreExecutor,
            source,
            persistence,
            &window_label,
            &workspace_root,
        )?;
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
    run_build_task(app, move |registry, source, persistence| {
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
    })
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
    run_build_task(app, move |registry, _source, _persistence| {
        registry.close_workspace(&window_label, &workspace_root);
        Ok(())
    })
    .await
}

/// Runs one registry operation on the async runtime's blocking pool: Core
/// calls and file I/O must never occupy the UI thread, and the registry
/// mutex is only held inside the spawned task.
async fn run_build_task<T, F>(app: AppHandle, operation: F) -> Result<T, String>
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
        let source = HostPackageSource { app: app.clone() };
        let persistence = HostOptionsPersistence { app: app.clone() };
        let state = app.state::<BuildHostState>();
        let mut registry = state
            .registry
            .lock()
            .map_err(|_| "build registry mutex poisoned")?;
        operation(&mut registry, &source, &persistence)
    })
    .await
    .map_err(|error| format!("build task failed: {error}"))?
}
