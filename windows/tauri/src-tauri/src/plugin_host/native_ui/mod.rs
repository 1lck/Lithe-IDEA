//! Read-only metadata for accepted native declarations. This does not admit ui 3
//! packages, open capabilities, or execute a plugin function.
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use tauri::{AppHandle, Manager};

#[tauri::command]
pub async fn declarative_plugins_native_windows(app: AppHandle) -> Result<Vec<Value>, String> {
    tauri::async_runtime::spawn_blocking(move || catalog(&app))
        .await
        .map_err(|error| error.to_string())?
}

pub(crate) fn catalog(app: &AppHandle) -> Result<Vec<Value>, String> {
    let mut windows = Vec::new();
    for candidate in app.state::<super::PluginHostState>().packages() {
        if candidate.entry.status != "accepted" || !candidate.entry.enabled {
            continue;
        }
        let declarations: Vec<_> = candidate.manifest["ui"]["toolWindows"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|window| window.get("native").is_some())
            .collect();
        if declarations.is_empty() {
            continue;
        }
        let _lease = app
            .state::<super::lifecycle::LifecycleState>()
            .acquire(&candidate.entry.plugin_id)?;
        let package = super::launch::verified_package_by_id(app, &candidate.entry.plugin_id)?;
        let details = super::details::build_details(
            &package,
            &super::store::install_root(app)?,
            &super::store::bundled_root(app)?,
        )
        .map_err(|error| error.message)?;
        if !details.enabled {
            continue;
        }
        let digest = super::signature::content_digest(&package.root)
            .map_err(|error| error.message().to_string())?;
        let package_identity = format!(
            "{:x}",
            Sha256::digest(
                json!({"root":package.root,"source":package.entry.source,
                    "version":package.entry.version,"digest":digest})
                .to_string()
                .as_bytes()
            )
        );
        for window in declarations {
            windows.push(json!({"pluginId":package.entry.plugin_id,
                "packageIdentity":package_identity,"windowId":window["id"],
                "title":window["title"],"placement":window["placement"],
                "order":window["order"],"native":window["native"]}));
        }
    }
    windows.sort_by_key(|window| {
        (
            window["order"].as_u64().unwrap_or(u64::MAX),
            window["pluginId"].as_str().unwrap_or_default().to_string(),
            window["windowId"].as_str().unwrap_or_default().to_string(),
        )
    });
    Ok(windows)
}
