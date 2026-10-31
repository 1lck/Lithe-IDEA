use lithe_project::FileWatcher;
use lithe_project::git_watcher::{GitMetadataWatcher, GitWatchContext};
use serde_json::{Value, json};
use std::sync::Arc;
use tauri::State;

fn registration(window: &str, runtime: &str, watch: &str) -> Result<String, String> {
    if runtime.is_empty() || watch.is_empty() || runtime.contains('\0') || watch.contains('\0') {
        return Err("Invalid watch identity".into());
    }
    Ok(format!("{window}\0{runtime}\0{watch}"))
}

#[tauri::command]
pub async fn watch_git_repository(
    repo_path: String,
    runtime_id: String,
    watch_id: String,
    window: tauri::WebviewWindow,
    watcher: State<'_, Arc<GitMetadataWatcher>>,
) -> Result<(), String> {
    let owner = registration(window.label(), &runtime_id, &watch_id)?;
    let watcher = Arc::clone(&watcher);
    // Reserve before yielding, so unwatch can revoke an in-flight discovery.
    watcher
        .begin(&owner, &watch_id)
        .map_err(|error| error.to_string())?;
    crate::blocking::run_blocking(move || {
        let result = (|| {
            let request = json!({ "id": watch_id, "command": "git.watchContext",
                "timeoutMilliseconds": 30_000, "payload": { "root": repo_path } });
            let response: Value =
                serde_json::from_str(&lithe_core::execute_json(&request.to_string()))
                    .map_err(|error| error.to_string())?;
            if response["ok"] != true {
                return Err(response["error"].to_string());
            }
            if response["data"].is_null() {
                watcher
                    .remove(&owner, Some(&watch_id))
                    .map_err(|error| error.to_string())
            } else {
                let mut context: GitWatchContext = serde_json::from_value(response["data"].clone())
                    .map_err(|error| error.to_string())?;
                // Git rules in ancestors of an opened repository subdirectory still apply.
                if let Ok(mut directory) = std::fs::canonicalize(&repo_path) {
                    while directory.starts_with(&context.repository_root) {
                        context.rule_directories.push(directory.clone());
                        if !directory.pop() {
                            break;
                        }
                    }
                }
                watcher
                    .install(&owner, &watch_id, context)
                    .map_err(|error| error.to_string())
            }
        })();
        if result.is_err() {
            let _ = watcher.remove(&owner, Some(&watch_id));
        }
        result
    })
    .await
}

#[tauri::command]
pub async fn unwatch_git_repository(
    runtime_id: String,
    watch_id: String,
    window: tauri::WebviewWindow,
    watcher: State<'_, Arc<GitMetadataWatcher>>,
) -> Result<(), String> {
    let owner = registration(window.label(), &runtime_id, &watch_id)?;
    let watcher = Arc::clone(&watcher);
    crate::blocking::run_blocking(move || {
        watcher
            .remove(&owner, Some(&watch_id))
            .map_err(|error| error.to_string())
    })
    .await
}

#[tauri::command]
pub async fn start_watching(
    path: String,
    runtime_id: String,
    watch_id: String,
    window: tauri::WebviewWindow,
    file_watcher: State<'_, Arc<FileWatcher>>,
) -> Result<(), String> {
    let owner = registration(window.label(), &runtime_id, &watch_id)?;
    let watcher = Arc::clone(&file_watcher);
    crate::blocking::run_blocking(move || {
        watcher
            .watch_owned(owner, path, false)
            .map_err(|error| error.to_string())
    })
    .await
}

#[tauri::command]
pub async fn stop_watching(
    runtime_id: String,
    watch_id: String,
    window: tauri::WebviewWindow,
    file_watcher: State<'_, Arc<FileWatcher>>,
) -> Result<(), String> {
    let owner = registration(window.label(), &runtime_id, &watch_id)?;
    let watcher = Arc::clone(&file_watcher);
    crate::blocking::run_blocking(move || {
        watcher
            .unwatch_owned(&owner)
            .map_err(|error| error.to_string())
    })
    .await
}

#[tauri::command]
pub async fn set_project_root(
    path: String,
    runtime_id: String,
    watch_id: String,
    window: tauri::WebviewWindow,
    file_watcher: State<'_, Arc<FileWatcher>>,
) -> Result<(), String> {
    let owner = registration(window.label(), &runtime_id, &watch_id)?;
    let watcher = Arc::clone(&file_watcher);
    crate::blocking::run_blocking(move || {
        watcher
            .watch_owned(owner, path, true)
            .map_err(|error| error.to_string())
    })
    .await
}
