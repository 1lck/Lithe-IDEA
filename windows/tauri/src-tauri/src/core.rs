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
