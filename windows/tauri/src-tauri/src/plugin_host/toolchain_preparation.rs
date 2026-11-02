//! Window-scoped registration precedes blocking tool discovery. Cancellation
//! revokes the same native owner even when it arrives before worker dispatch.
use lithe_project::toolchain_operations::{Lease, Operations};
use tauri::{AppHandle, Manager, Window};

#[derive(Default)]
pub struct ToolPreparations(Operations);

#[tauri::command]
pub fn declarative_plugins_begin_tool_preparation(
    app: AppHandle,
    window: Window,
) -> Result<String, String> {
    if app.get_webview_window(window.label()).is_none() {
        return Err("toolchain.native.cancelled".into());
    }
    app.state::<ToolPreparations>().0.begin(window.label())
}

#[tauri::command]
pub fn declarative_plugins_cancel_tool_preparation(
    app: AppHandle,
    window: Window,
    operation_id: String,
) {
    app.state::<ToolPreparations>()
        .0
        .cancel(window.label(), &operation_id);
}

pub(super) fn claim(app: &AppHandle, window: &Window, operation: &str) -> Result<Lease, String> {
    app.state::<ToolPreparations>()
        .0
        .claim(window.label(), operation)
}

pub fn close_window(app: &AppHandle, label: &str) {
    app.state::<ToolPreparations>().0.close_window(label);
}
