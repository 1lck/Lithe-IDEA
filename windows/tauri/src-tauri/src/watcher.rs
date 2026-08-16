use lithe_project::FileWatcher;
use std::sync::Arc;
use tauri::State;

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
