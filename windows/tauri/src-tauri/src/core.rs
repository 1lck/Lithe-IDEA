#[tauri::command]
pub async fn core_execute(request: String) -> String {
    tauri::async_runtime::spawn_blocking(move || lithe_core::execute_json(&request))
        .await
        .unwrap_or_else(|error| {
            serde_json::json!({
                "id": null,
                "ok": false,
                "error": {
                    "code": "unknown",
                    "message": "The shared core operation could not complete",
                    "details": error.to_string()
                }
            })
            .to_string()
        })
}

#[tauri::command]
pub fn core_cancel(operation_id: String) -> bool {
    lithe_core::cancel_operation(&operation_id)
}

/// Resolves MCP's read-only helper and writable connection storage in the native host.
#[tauri::command]
pub fn ide_host_paths(app: tauri::AppHandle) -> Result<serde_json::Value, String> {
    use tauri::Manager;
    let directory = app
        .path()
        .app_local_data_dir()
        .map_err(|e| e.to_string())?
        .join("mcp");
    let helper = app
        .path()
        .resource_dir()
        .map_err(|e| e.to_string())?
        .join("helpers")
        .join("lithe-mcp.exe");
    Ok(serde_json::json!({ "directory":directory, "helperPath":helper }))
}

/// Native window destruction also revokes access when WebView cleanup could not run.
pub fn close_ide_hosts(owner: &str) {
    let response = lithe_core::execute_json(&serde_json::json!({
        "command":"ideHost.control", "payload":{"action":"closeOwner","arguments":{"ownerID":owner}}
    }).to_string());
    if let Ok(value) = serde_json::from_str::<serde_json::Value>(&response) {
        if value["ok"] != true {
            eprintln!("Could not close IDE connections: {}", value["error"]);
        }
    }
}
