//! Ends every process Lithe owns before the application goes away.
//!
//! Application exit and an update install both leave through here. The
//! updater exits the process directly after starting the installer, without an
//! exit event, so the update flow asks for this cleanup before it installs.

use crate::{agent, debug, language_tools, run};

/// Ends Run sessions, debug adapters, Agent connections and language tool
/// installs, waiting for each within its own bounded timeout.
pub fn shutdown() {
    language_tools::shutdown();
    run::shutdown();
    debug::shutdown();
    agent::shutdown();
}

/// Ends every owned process before the updater replaces the application.
///
/// The frontend has already confirmed and stopped the Run sessions, so this
/// only ends what remains. A crash or failed install skips nothing that
/// matters for Run, debug and language server trees: their Job Objects end
/// them when Windows closes Lithe's handles.
#[tauri::command]
pub async fn app_prepare_update_install() -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(shutdown)
        .await
        .map_err(|error| format!("Could not stop Lithe's processes before the update: {error}"))
}
