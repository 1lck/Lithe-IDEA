use std::collections::{HashMap, HashSet};
use std::sync::{Mutex, OnceLock};

#[derive(Default)]
struct WindowIndexingOwners {
    closed: HashSet<String>,
    leases: HashMap<String, HashMap<(String, String), u64>>,
}

fn indexing_owners() -> &'static Mutex<WindowIndexingOwners> {
    static OWNERS: OnceLock<Mutex<WindowIndexingOwners>> = OnceLock::new();
    OWNERS.get_or_init(Mutex::default)
}

fn cancelled_indexing(id: serde_json::Value) -> String {
    serde_json::json!({"id":id,"ok":false,"error":{"code":"cancelled","message":"Workspace window closed"}}).to_string()
}

fn execute_for_window(owner: &str, request: &str, execute: impl Fn(&str) -> String) -> String {
    let Ok(mut value) = serde_json::from_str::<serde_json::Value>(request) else {
        return execute(request);
    };
    let configuring = value["command"] == "workspace.configureIndexing";
    let releasing = value["command"] == "workspace.releaseIndexing";
    if !configuring && !releasing {
        return execute(request);
    }
    let (Some(runtime), Some(root)) = (
        value["payload"]["ownerId"].as_str(),
        value["payload"]["root"].as_str(),
    ) else {
        return execute(request);
    };
    // The native label is trusted; a WebView cannot acquire another window's lease.
    let runtime = format!("{owner}/{runtime}");
    let root = root.to_owned();
    value["payload"]["ownerId"] = serde_json::json!(runtime);
    {
        let mut owners = indexing_owners()
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        if owners.closed.contains(owner) {
            return cancelled_indexing(value["id"].clone());
        }
        owners.leases.entry(owner.to_owned()).or_default();
    }
    let response = execute(&value.to_string());
    let Ok(result) = serde_json::from_str::<serde_json::Value>(&response) else {
        return response;
    };
    if result["ok"] != true {
        return response;
    }
    let revision = if configuring {
        result["data"]["revision"].as_u64()
    } else {
        value["payload"]["revision"].as_u64()
    };
    let Some(revision) = revision else {
        return response;
    };
    let closed = {
        let mut owners = indexing_owners()
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let closed = owners.closed.contains(owner);
        if !closed {
            let leases = owners.leases.entry(owner.to_owned()).or_default();
            let key = (root.clone(), runtime.clone());
            if configuring {
                leases.insert(key, revision);
            } else if leases.get(&key) == Some(&revision) {
                leases.remove(&key);
            }
        }
        closed
    };
    if closed && configuring {
        // Destruction may win while Core is installing the policy. Reclaim the
        // returned token here, after the destroy callback drained earlier tokens.
        execute(&serde_json::json!({"command":"workspace.releaseIndexing","payload":{"root":root,"ownerId":runtime,"revision":revision}}).to_string());
        return cancelled_indexing(value["id"].clone());
    }
    response
}

/// Native destruction is the fallback when a WebView cannot run workspace teardown.
pub fn close_window_indexing(owner: &str) {
    let leases = {
        let mut owners = indexing_owners()
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        owners.closed.insert(owner.to_owned());
        owners.leases.remove(owner).unwrap_or_default()
    };
    tauri::async_runtime::spawn_blocking(move || {
        for ((root, owner_id), revision) in leases {
            let response = lithe_core::execute_json(&serde_json::json!({"command":"workspace.releaseIndexing","payload":{"root":root,"ownerId":owner_id,"revision":revision}}).to_string());
            if let Ok(value) = serde_json::from_str::<serde_json::Value>(&response) {
                if value["ok"] != true {
                    eprintln!("Could not release window indexing: {}", value["error"]);
                }
            }
        }
    });
}

#[tauri::command]
pub async fn core_execute(window: tauri::WebviewWindow, request: String) -> String {
    let owner = window.label().to_owned();
    tauri::async_runtime::spawn_blocking(move || {
        execute_for_window(&owner, &request, lithe_core::execute_json)
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

#[cfg(test)]
mod indexing_tests {
    use super::*;
    use serde_json::{json, Value};
    use std::cell::RefCell;

    #[test]
    fn native_destruction_reclaims_an_installation_that_finishes_after_close() {
        let owner = "indexing-close-during-install";
        let calls = RefCell::new(Vec::<Value>::new());
        let response = execute_for_window(owner, &json!({"id":"late", "command":"workspace.configureIndexing", "payload":{"root":"C:/fixture", "ownerId":"workspace-one"}}).to_string(), |request| {
            let value: Value = serde_json::from_str(request).unwrap();
            calls.borrow_mut().push(value.clone());
            if value["command"] == "workspace.configureIndexing" {
                indexing_owners().lock().unwrap().closed.insert(owner.to_owned());
                json!({"ok":true,"data":{"revision":7}}).to_string()
            } else { json!({"ok":true,"data":{"released":true}}).to_string() }
        });
        let response: Value = serde_json::from_str(&response).unwrap();
        assert_eq!(response["error"]["code"], "cancelled");
        let calls = calls.borrow();
        assert_eq!(calls.len(), 2);
        assert_eq!(
            calls[0]["payload"]["ownerId"],
            format!("{owner}/workspace-one")
        );
        assert_eq!(calls[1]["command"], "workspace.releaseIndexing");
        assert_eq!(calls[1]["payload"]["revision"], 7);
        let mut owners = indexing_owners().lock().unwrap();
        owners.closed.remove(owner);
        owners.leases.remove(owner);
    }

    #[test]
    fn late_release_keeps_the_new_native_cleanup_token() {
        let owner = "indexing-late-release";
        let request = |command: &str, revision: u64| {
            json!({"command":command,"payload":{"root":"C:/fixture","ownerId":"workspace-one","revision":revision}}).to_string()
        };
        for revision in [1, 2] {
            execute_for_window(owner, &request("workspace.configureIndexing", 0), |_| {
                json!({"ok":true,"data":{"revision":revision}}).to_string()
            });
        }
        execute_for_window(owner, &request("workspace.releaseIndexing", 1), |_| {
            json!({"ok":true,"data":{"released":false}}).to_string()
        });
        let mut owners = indexing_owners().lock().unwrap();
        assert_eq!(
            owners.leases[owner][&("C:/fixture".into(), format!("{owner}/workspace-one"))],
            2
        );
        owners.leases.remove(owner);
    }
}
