use lithe_project::FileWatcher;
use lithe_project::git_watcher::{GitMetadataWatcher, GitWatchContext};
use serde_json::{Value, json};
use std::sync::Arc;
use tauri::State;

#[tauri::command]
pub async fn watch_git_repository(
    repo_path: String,
    watch_id: String,
    window: tauri::WebviewWindow,
    watcher: State<'_, Arc<GitMetadataWatcher>>,
) -> Result<(), String> {
    let owner = window.label().to_string();
    watcher
        .begin(&owner, &watch_id)
        .map_err(|error| error.to_string())?;
    let request = json!({ "id": watch_id, "command": "git.watchContext", "timeoutMilliseconds": 30_000, "payload": { "root": repo_path } }).to_string();
    let response = tauri::async_runtime::spawn_blocking(move || lithe_core::execute_json(&request))
        .await
        .map_err(|error| error.to_string())?;
    let response: Value = serde_json::from_str(&response).map_err(|error| error.to_string())?;
    if response.get("ok").and_then(Value::as_bool) != Some(true) {
        return Err(response["error"]["message"]
            .as_str()
            .unwrap_or("Could not resolve Git metadata")
            .to_string());
    }
    if !response["data"].is_null() {
        let context: GitWatchContext =
            serde_json::from_value(response["data"].clone()).map_err(|error| error.to_string())?;
        watcher
            .install(&owner, &watch_id, context)
            .map_err(|error| error.to_string())?;
    } else {
        watcher
            .remove(&owner, Some(&watch_id))
            .map_err(|error| error.to_string())?;
    }
    Ok(())
}

#[tauri::command]
pub fn unwatch_git_repository(
    watch_id: String,
    window: tauri::WebviewWindow,
    watcher: State<'_, Arc<GitMetadataWatcher>>,
) -> Result<(), String> {
    watcher
        .remove(window.label(), Some(&watch_id))
        .map_err(|error| error.to_string())
}

#[tauri::command]
pub async fn start_watching(
    path: String,
    file_watcher: State<'_, Arc<FileWatcher>>,
) -> Result<(), String> {
    file_watcher
        .watch_path(path)
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
pub fn stop_watching(
    path: String,
    file_watcher: State<'_, Arc<FileWatcher>>,
) -> Result<(), String> {
    file_watcher
        .stop_watching(path)
        .map_err(|error| error.to_string())
}

#[tauri::command]
pub async fn set_project_root(
    path: String,
    file_watcher: State<'_, Arc<FileWatcher>>,
) -> Result<(), String> {
    file_watcher
        .watch_project_root(path)
        .await
        .map_err(|error| error.to_string())
}
