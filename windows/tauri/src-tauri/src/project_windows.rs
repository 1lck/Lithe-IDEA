//! Tauri window ownership, activation, and lifecycle cleanup for local projects.

use crate::project_window_registry::{ProjectWindowOwner, ProjectWindowRegistry};
use std::path::Path;
use tauri::{AppHandle, Emitter, Manager, WebviewWindow};
use tokio::sync::Mutex;

#[derive(Default)]
pub struct ProjectWindows(pub Mutex<ProjectWindowRegistry>);

pub fn focus_project(app: &AppHandle, owner: &ProjectWindowOwner) -> Result<(), String> {
    let window = app
        .get_webview_window(&owner.label)
        .ok_or("Project window is no longer available")?;
    if let Some(id) = &owner.workspace_id {
        window
            .emit("activate_project_workspace", id)
            .map_err(|error| error.to_string())?;
    }
    window.show().map_err(|error| error.to_string())?;
    window.unminimize().map_err(|error| error.to_string())?;
    window.set_focus().map_err(|error| error.to_string())
}

#[tauri::command]
pub async fn claim_project_window(
    app: AppHandle,
    window: WebviewWindow,
    path: String,
    workspace_id: String,
    activate: bool,
) -> Result<ProjectWindowOwner, String> {
    let identity =
        crate::project_window_registry::ProjectWindowRegistry::identity(Path::new(&path))?;
    let state = app.state::<ProjectWindows>();
    let mut registry = state.0.lock().await;
    registry.retain_windows(|label| app.get_webview_window(label).is_some());
    let owner = registry.claim(identity, window.label(), Some(&workspace_id));
    // The owning frontend activates same-window tabs itself; emitting here would
    // re-enter its initialization while the original open is still pending.
    if activate && owner.label != window.label() {
        focus_project(&app, &owner)?;
    }
    Ok(owner)
}

#[tauri::command]
pub async fn release_project_window(
    app: AppHandle,
    window: WebviewWindow,
    workspace_id: String,
) -> Result<(), String> {
    app.state::<ProjectWindows>()
        .0
        .lock()
        .await
        .release(window.label(), Some(&workspace_id));
    Ok(())
}

#[tauri::command]
pub async fn release_pending_project_window(
    app: AppHandle,
    window: WebviewWindow,
) -> Result<(), String> {
    app.state::<ProjectWindows>()
        .0
        .lock()
        .await
        .release_pending(window.label());
    Ok(())
}

pub fn release_window(app: &AppHandle, label: String) {
    // Window destruction runs on the UI thread. Never block it while an async
    // create command holds the registry and waits for the native window builder.
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        if let Some(state) = app.try_state::<ProjectWindows>() {
            state.0.lock().await.release(&label, None);
        }
    });
}
