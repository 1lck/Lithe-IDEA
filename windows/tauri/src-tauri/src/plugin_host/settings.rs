//! Stored user values for declarative plugin settings.
//!
//! Core owns every setting semantic (validation, defaults, layering, effect
//! kinds); this module only persists the two value layers the host owns: the
//! user's global value per plugin, and per-workspace overrides of
//! project-scoped settings (`settings` 2, written to the workspace's
//! `.lithe/plugin-settings.json`, matching the macOS storage locations).

use serde_json::{Map, Value};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use tauri::{AppHandle, Manager};

mod snapshot;
pub use snapshot::SettingSnapshot;

#[tauri::command]
pub async fn declarative_plugins_setting_snapshot(
    app: AppHandle,
    plugin_id: String,
    workspace_path: String,
) -> Result<SettingSnapshot, String> {
    tauri::async_runtime::spawn_blocking(move || snapshot::read(&app, &plugin_id, &workspace_path))
        .await
        .map_err(|_| "plugin.settings.unavailable".to_string())?
}

/// Global values of one plugin, persisted as
/// `app_local_data_dir()/plugin-settings/<pluginID>.json`.
fn global_store_path(app: &AppHandle, plugin_id: &str) -> Result<PathBuf, String> {
    Ok(app
        .path()
        .app_local_data_dir()
        .map_err(|error| error.to_string())?
        .join("plugin-settings")
        .join(format!("{plugin_id}.json")))
}

/// Project overrides live in the workspace's `.lithe/plugin-settings.json`.
pub fn project_store_path(workspace_path: &str) -> PathBuf {
    PathBuf::from(workspace_path)
        .join(".lithe")
        .join("plugin-settings.json")
}

/// Reads a JSON object store; missing files read as empty. Corrupted files
/// surface as errors so a broken write is never silently reset.
fn read_object(path: &Path) -> Result<Map<String, Value>, String> {
    snapshot::read_values(path)
}

/// Writes a JSON object store atomically via temp file + rename.
#[cfg(test)]
fn write_object(path: &Path, map: &Map<String, Value>) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    use std::io::Write;
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let temp = path.with_extension(format!(
        "json.{}-{}.tmp",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let text = serde_json::to_string_pretty(&Value::Object(map.clone()))
        .map_err(|error| error.to_string())?;
    let result = (|| {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)
            .map_err(|error| error.to_string())?;
        file.write_all(text.as_bytes())
            .map_err(|error| error.to_string())?;
        file.sync_all().map_err(|error| error.to_string())?;
        drop(file);
        crate::logging::replace_file_atomically(&temp, path)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    result
}

/// Both stored layers for one plugin.
pub struct SettingLayers {
    pub global: BTreeMap<String, Value>,
    pub project: BTreeMap<String, Value>,
}

/// Loads the stored values of one plugin for one workspace. Only entries
/// under the plugin's ID in the project store belong to it.
pub fn load_layers(
    app: &AppHandle,
    plugin_id: &str,
    workspace_path: &str,
) -> Result<SettingLayers, String> {
    let global: BTreeMap<String, Value> = read_object(&global_store_path(app, plugin_id)?)?
        .into_iter()
        .collect();
    let project_file = if workspace_path.is_empty() {
        Map::new()
    } else {
        read_object(&project_store_path(workspace_path))?
    };
    if project_file
        .get(plugin_id)
        .is_some_and(|value| !value.is_object())
    {
        return Err("plugin.settings.corruptStore".into());
    }
    let project: BTreeMap<String, Value> = project_file
        .get(plugin_id)
        .and_then(Value::as_object)
        .map(|values| {
            values
                .iter()
                .map(|(key, value)| (key.clone(), value.clone()))
                .collect()
        })
        .unwrap_or_default();
    Ok(SettingLayers { global, project })
}

/// Stores an explicit global override; only `None` erases the stored value.
#[cfg(test)]
pub fn store_global(
    app: &AppHandle,
    plugin_id: &str,
    setting_id: &str,
    value: Option<Value>,
) -> Result<(), String> {
    let path = global_store_path(app, plugin_id)?;
    let mut store = read_object(&path)?;
    match value {
        Some(value) => {
            store.insert(setting_id.to_string(), value);
        }
        None => {
            store.remove(setting_id);
        }
    }
    write_object(&path, &store)
}

/// Stores the workspace override of a project-scoped setting, or erases it
/// with `None`. When the last override of a plugin disappears from the
/// project store, the empty plugin entry is removed; an empty store file is
/// deleted entirely.
#[cfg(test)]
pub fn store_project(
    workspace_path: &str,
    plugin_id: &str,
    setting_id: &str,
    value: Option<Value>,
) -> Result<(), String> {
    let path = project_store_path(workspace_path);
    let mut store = read_object(&path)?;
    let entry = store
        .entry(plugin_id.to_string())
        .or_insert_with(|| Value::Object(Map::new()));
    let values = entry
        .as_object_mut()
        .ok_or_else(|| format!("{} has a corrupted plugin-settings entry", path.display()))?;
    match value {
        Some(value) => {
            values.insert(setting_id.to_string(), value);
        }
        None => {
            values.remove(setting_id);
        }
    }
    if values.is_empty() {
        store.remove(plugin_id);
    }
    if store.is_empty() {
        match std::fs::remove_file(&path) {
            Ok(()) => return Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(error) => return Err(error.to_string()),
        }
    }
    write_object(&path, &store)
}

/// Tauri command: effective values of one plugin's settings.
#[tauri::command]
pub async fn declarative_plugins_resolve_settings(
    app: AppHandle,
    manifest: Value,
    workspace_path: String,
) -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let Some(plugin_id) = manifest["id"].as_str().map(str::to_string) else {
            return Err("manifest has no id".to_string());
        };
        let _lease = app
            .state::<super::lifecycle::LifecycleState>()
            .acquire(&plugin_id)?;
        let manifest = super::launch::verified_package_by_id(&app, &plugin_id)?.manifest;
        let layers = load_layers(&app, &plugin_id, &workspace_path)?;
        super::scan::core_execute(
            "plugins.declarative.resolveSettings",
            serde_json::json!({
                "manifest": manifest,
                "settings": layers.global,
                "projectSettings": layers.project,
            }),
        )
    })
    .await
    .map_err(|_| "plugin.settings.unavailable".to_string())?
}

/// Tauri command: stores a setting value in the requested layer.
#[tauri::command]
pub async fn declarative_plugins_store_setting(
    app: AppHandle,
    plugin_id: String,
    setting_id: String,
    scope: String,
    workspace_path: String,
    value: Option<Value>,
    expected_identity: Option<String>,
) -> Result<SettingSnapshot, String> {
    tauri::async_runtime::spawn_blocking(move || {
        snapshot::store(
            &app,
            &plugin_id,
            &setting_id,
            &scope,
            &workspace_path,
            value,
            expected_identity
                .as_deref()
                .ok_or("plugin.settings.snapshotRequired")?,
        )
    })
    .await
    .map_err(|_| "plugin.settings.unavailable".to_string())?
}

/// Tauri command: a running language server's `workspaceConfiguration`
/// expanded with the current values, for `immediate` effect changes.
#[tauri::command]
pub async fn declarative_plugins_workspace_configuration(
    app: AppHandle,
    manifest: Value,
    language_id: String,
    workspace_path: String,
) -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let Some(plugin_id) = manifest["id"].as_str().map(str::to_string) else {
            return Err("manifest has no id".to_string());
        };
        let _lease = app
            .state::<super::lifecycle::LifecycleState>()
            .acquire(&plugin_id)?;
        let manifest = super::launch::verified_package_by_id(&app, &plugin_id)?.manifest;
        let layers = load_layers(&app, &plugin_id, &workspace_path)?;
        super::scan::core_execute(
            "plugins.declarative.workspaceConfiguration",
            serde_json::json!({
                "manifest": manifest,
                "languageID": language_id,
                "settings": layers.global,
                "projectSettings": layers.project,
            }),
        )
    })
    .await
    .map_err(|_| "plugin.settings.unavailable".to_string())?
}
