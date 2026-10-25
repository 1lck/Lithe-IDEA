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
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Map::new()),
        Err(error) => return Err(error.to_string()),
    };
    let value: Value = serde_json::from_str(&text)
        .map_err(|error| format!("{} is not valid JSON: {error}", path.display()))?;
    match value {
        Value::Object(map) => Ok(map),
        _ => Err(format!("{} is not a JSON object", path.display())),
    }
}

/// Writes a JSON object store atomically via temp file + rename.
fn write_object(path: &Path, map: &Map<String, Value>) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let temp = path.with_extension("json.tmp");
    std::fs::write(
        &temp,
        serde_json::to_string_pretty(&Value::Object(map.clone()))
            .map_err(|error| error.to_string())?,
    )
    .map_err(|error| error.to_string())?;
    std::fs::rename(&temp, path).map_err(|error| error.to_string())
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
    let project_file = read_object(&project_store_path(workspace_path))?;
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

/// Stores the user's global value of one setting. A value equal to the
/// declared default is forgotten so default changes flow through (macOS
/// rule); `None` erases the stored value.
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
pub fn declarative_plugins_resolve_settings(
    app: AppHandle,
    manifest: Value,
    workspace_path: String,
) -> Result<Value, String> {
    let Some(plugin_id) = manifest["id"].as_str().map(str::to_string) else {
        return Err("manifest has no id".to_string());
    };
    let layers = load_layers(&app, &plugin_id, &workspace_path)?;
    super::scan::core_execute(
        "plugins.declarative.resolveSettings",
        serde_json::json!({
            "manifest": manifest,
            "settings": layers.global,
            "projectSettings": layers.project,
        }),
    )
}

/// Tauri command: stores a setting value in the requested layer.
#[tauri::command]
pub fn declarative_plugins_store_setting(
    app: AppHandle,
    plugin_id: String,
    setting_id: String,
    scope: String,
    workspace_path: String,
    value: Option<Value>,
) -> Result<(), String> {
    match scope.as_str() {
        "global" => store_global(&app, &plugin_id, &setting_id, value),
        "project" => store_project(&workspace_path, &plugin_id, &setting_id, value),
        other => Err(format!("unknown setting scope {other}")),
    }
}

/// Tauri command: a running language server's `workspaceConfiguration`
/// expanded with the current values, for `immediate` effect changes.
#[tauri::command]
pub fn declarative_plugins_workspace_configuration(
    app: AppHandle,
    manifest: Value,
    language_id: String,
    workspace_path: String,
) -> Result<Value, String> {
    let Some(plugin_id) = manifest["id"].as_str().map(str::to_string) else {
        return Err("manifest has no id".to_string());
    };
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
}
