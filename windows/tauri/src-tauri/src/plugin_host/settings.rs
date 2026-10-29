//! Stored user values for declarative plugin settings.
//!
//! Core owns every setting semantic (validation, defaults, layering, effect
//! kinds); this module only persists the two value layers the host owns: the
//! user's global value per plugin, and per-workspace overrides of
//! project-scoped settings (`settings` 2, written to the workspace's
//! `.lithe/plugin-settings.json`, matching the macOS storage locations).

use serde_json::{Map, Value};
use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

// Serialize the complete read/modify/publish transaction, including deletion.
// A process-wide lock also covers aliases of the same workspace path.
static SETTINGS_TRANSACTION: Mutex<()> = Mutex::new(());
static TEMP_ID: AtomicU64 = AtomicU64::new(0);
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
    let bytes = serde_json::to_vec_pretty(&Value::Object(map.clone()))
        .map_err(|error| error.to_string())?;
    let temp = path.with_extension(format!(
        "json.{}.{}.tmp",
        std::process::id(),
        TEMP_ID.fetch_add(1, Ordering::Relaxed)
    ));
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temp)
        .map_err(|error| error.to_string())?;
    let cleanup = TemporaryWrite(temp.clone());
    let written = file.write_all(&bytes);
    drop(file);
    written.map_err(|error| error.to_string())?;
    let result = std::fs::rename(&temp, path).map_err(|error| error.to_string());
    drop(cleanup);
    result
}

struct TemporaryWrite(PathBuf);

impl Drop for TemporaryWrite {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

/// Reads the latest committed values under the same lock as publication.
fn update_object(
    path: &Path,
    remove_empty: bool,
    edit: impl FnOnce(&mut Map<String, Value>) -> Result<(), String>,
) -> Result<(), String> {
    let _transaction = SETTINGS_TRANSACTION
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    let mut store = read_object(path)?;
    edit(&mut store)?;
    if remove_empty && store.is_empty() {
        return match std::fs::remove_file(path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error.to_string()),
        };
    }
    write_object(path, &store)
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
    update_object(&path, false, |store| {
        match value {
            Some(value) => {
                store.insert(setting_id.to_string(), value);
            }
            None => {
                store.remove(setting_id);
            }
        }
        Ok(())
    })
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
    update_object(&path, true, |store| {
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
        Ok(())
    })
}

/// Tauri command: effective values of one plugin's settings.
#[tauri::command]
pub async fn declarative_plugins_resolve_settings(
    app: AppHandle,
    manifest: Value,
    workspace_path: String,
) -> Result<Value, String> {
    crate::blocking::run_blocking(move || {
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
    })
    .await
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
) -> Result<(), String> {
    crate::blocking::run_blocking(move || match scope.as_str() {
        "global" => store_global(&app, &plugin_id, &setting_id, value),
        "project" => store_project(&workspace_path, &plugin_id, &setting_id, value),
        other => Err(format!("unknown setting scope {other}")),
    })
    .await
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
    crate::blocking::run_blocking(move || {
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
    })
    .await
}

#[cfg(test)]
mod transaction_tests {
    use super::*;
    use std::sync::mpsc;
    use std::time::Duration;

    #[test]
    fn concurrent_edits_preserve_both_values_and_remove_temporary_files() {
        let root = std::env::temp_dir().join(format!(
            "lithe-settings-transaction-{}-{}",
            std::process::id(),
            TEMP_ID.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&root).unwrap();
        struct Cleanup(PathBuf);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
        let _cleanup = Cleanup(root.clone());
        let path = root.join("settings.json");
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let (started_tx, started_rx) = mpsc::channel();
        let (done_tx, done_rx) = mpsc::channel();
        let deadline = Duration::from_secs(3);
        std::thread::scope(|scope| {
            let first_path = &path;
            let first_done = done_tx.clone();
            let first = scope.spawn(move || {
                let result = update_object(first_path, false, |values| {
                    // Check the actual transaction boundary, not timing: a second
                    // transaction must not read until this edit is published.
                    assert!(SETTINGS_TRANSACTION.try_lock().is_err());
                    entered_tx.send(()).unwrap();
                    release_rx
                        .recv_timeout(deadline)
                        .expect("release first transaction");
                    values.insert("first".into(), Value::from(1));
                    Ok(())
                });
                first_done.send(result).unwrap();
            });
            entered_rx
                .recv_timeout(deadline)
                .expect("first transaction entered");
            let second_path = &path;
            let second = scope.spawn(move || {
                started_tx.send(()).unwrap();
                let result = update_object(second_path, false, |values| {
                    assert_eq!(values.get("first"), Some(&Value::from(1)));
                    values.insert("second".into(), Value::from(2));
                    Ok(())
                });
                done_tx.send(result).unwrap();
            });
            started_rx
                .recv_timeout(deadline)
                .expect("second transaction started");
            release_tx.send(()).unwrap();
            for _ in 0..2 {
                done_rx
                    .recv_timeout(deadline)
                    .expect("transaction completed")
                    .unwrap();
            }
            first.join().unwrap();
            second.join().unwrap();
        });
        let values = read_object(&path).unwrap();
        assert_eq!(values.get("first"), Some(&Value::from(1)));
        assert_eq!(values.get("second"), Some(&Value::from(2)));
        assert_eq!(std::fs::read_dir(&root).unwrap().count(), 1);
    }
}
