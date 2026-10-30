#[tauri::command]
pub async fn core_execute(
    app: tauri::AppHandle,
    window: tauri::WebviewWindow,
    request: String,
) -> String {
    let window_label = window.label().to_owned();
    tauri::async_runtime::spawn_blocking(move || {
        let parsed = serde_json::from_str::<serde_json::Value>(&request).ok();
        if let Some(parsed) = &parsed {
            if crate::plugin_host::vcs::private_core_request(&app, parsed["command"].as_str().unwrap_or_default(), &parsed["payload"]) {
                return serde_json::json!({"id":parsed["id"],"ok":false,"error":{
                    "code":"invalid_request","message":"VCS request requires its native owner","details":"vcs.provider.unavailable"
                }}).to_string();
            }
            if let Some(result) = crate::plugin_host::provider::core_preflight(
                &app,
                &window_label,
                parsed["command"].as_str().unwrap_or_default(),
                &parsed["payload"],
            ) {
                return match result {
                    Ok(data) => {
                        serde_json::json!({"id":parsed["id"],"ok":true,"data":data}).to_string()
                    }
                    Err(error) => serde_json::json!({"id":parsed["id"],"ok":false,"error":{
                        "code":"invalid_request","message":error.detail,"details":error.code,
                    }})
                    .to_string(),
                };
            }
            if parsed["command"] == "lsp.startServer" {
                if let Some(result) = crate::plugin_host::provider::language_start(
                    &app,
                    &window_label,
                    &parsed["payload"],
                ) {
                    return match result {
                        Ok(data) => {
                            serde_json::json!({"id":parsed["id"],"ok":true,"data":data}).to_string()
                        }
                        Err(error) => serde_json::json!({"id":parsed["id"],"ok":false,"error":{
                            "code":"process_failed","message":error.detail,"details":error.code,
                        }})
                        .to_string(),
                    };
                }
            }
        }
        let response = lithe_core::execute_json(&request);
        if let (Some(parsed), Ok(response_value)) = (parsed, serde_json::from_str(&response)) {
            crate::plugin_host::provider::observe_core(
                &app,
                &window_label,
                parsed["command"].as_str().unwrap_or_default(),
                &parsed["payload"],
                &response_value,
            );
        }
        response
    })
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
