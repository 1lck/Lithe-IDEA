//! Explicit placeholders for the Worker extension model's disk-installed
//! package commands.
//!
//! The frontend invokes these for non-language marketplace extensions, but
//! the Rust backend was never registered, so every call failed with Tauri's
//! "command not found" and the extension store stayed silently broken
//! (gated by `platform/tauri-core.ts` as `extensions`). Registering structured
//! errors makes the failure diagnosable; a full disk-install backend for
//! Worker packages is a separate work item and must not be confused with the
//! declarative contract host in `plugin_host`.

use serde_json::json;

fn not_yet_available<T>(operation: &str) -> Result<T, String> {
    // Structured payload rather than a plain message so the dispatcher can
    // surface a stable code once the backend lands.
    Err(json!({
        "code": "extensionStore.notAvailable",
        "message": format!("{operation} requires a package backend that is not available yet"),
    })
    .to_string())
}

#[tauri::command]
pub fn install_extension_from_url(
    _extension_id: String,
    _url: String,
    _checksum: String,
    _size: i64,
) -> Result<(), String> {
    not_yet_available("install_extension_from_url")
}

#[tauri::command]
pub fn uninstall_extension_new(_extension_id: String) -> Result<(), String> {
    not_yet_available("uninstall_extension_new")
}

#[tauri::command]
pub fn get_extension_path(_extension_id: String) -> Result<String, String> {
    not_yet_available::<String>("get_extension_path")
}

#[tauri::command]
pub fn read_extension_entrypoint(_extension_id: String, _entry: String) -> Result<String, String> {
    not_yet_available::<String>("read_extension_entrypoint")
}

#[tauri::command]
pub fn get_importable_ide_projects() -> Result<Vec<String>, String> {
    not_yet_available::<Vec<String>>("get_importable_ide_projects")
}
