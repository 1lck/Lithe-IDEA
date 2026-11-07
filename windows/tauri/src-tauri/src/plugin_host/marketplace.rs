//! Native marketplace IPC. Only product windows can call these commands. Source
//! identities, platform, capabilities, filesystem roots and signing policy stay
//! native; the frontend supplies opaque operation and selected source/plugin IDs.

use super::marketplace_coordinator::{
    MarketplaceCoordinator, MarketplaceHost, MarketplaceReview, SourceIndex,
};
use super::marketplace_download::{FetchPolicy, ReqwestTransport};
use super::marketplace_sources::{self, MarketplaceSource};
use serde_json::Value;
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Manager, WebviewWindow};

#[derive(Default)]
pub struct MarketplaceState(
    Mutex<Option<Arc<MarketplaceCoordinator>>>,
    Mutex<std::collections::HashSet<String>>,
);

struct NativeHost(AppHandle);

impl MarketplaceHost for NativeHost {
    fn sources(&self) -> Result<Vec<MarketplaceSource>, String> {
        marketplace_sources::load_sources(&marketplace_sources::sources_path(&self.0)?)
            .map(|(sources, _)| sources)
    }
    fn platform(&self) -> String {
        match std::env::consts::ARCH {
            "aarch64" => "windows-arm64",
            "x86_64" => "windows-x64",
            _ => "windows-unsupported",
        }
        .into()
    }
    fn capabilities(&self) -> Value {
        super::host_capabilities()
    }
    fn ensure_window(&self, window: &str) -> Result<(), String> {
        if self
            .0
            .state::<MarketplaceState>()
            .1
            .lock()
            .map_err(|_| "marketplace window state poisoned")?
            .contains(window)
            || self.0.get_webview_window(window).is_none()
        {
            return Err("the marketplace window was closed".into());
        }
        Ok(())
    }
    fn ensure_installable(&self, plugin_id: &str) -> Result<(), String> {
        if self
            .0
            .state::<super::PluginHostState>()
            .packages()
            .iter()
            .any(|package| {
                package.entry.plugin_id == plugin_id && package.entry.source == "bundled"
            })
        {
            return Err("bundled plugins cannot be replaced through the marketplace".into());
        }
        Ok(())
    }
    fn with_source(
        &self,
        expected: &MarketplaceSource,
        publish: &mut dyn FnMut() -> Result<(), String>,
    ) -> Result<(), String> {
        let _guard = marketplace_sources::sources_lock()
            .lock()
            .map_err(|_| "marketplace sources poisoned")?;
        let (sources, _) = marketplace_sources::load_sources_unlocked(
            &marketplace_sources::sources_path(&self.0)?,
        )?;
        if !sources
            .iter()
            .any(|source| source == expected && source.is_enabled)
        {
            return Err("the marketplace source changed before confirmation".into());
        }
        publish()
    }
}

fn coordinator(app: &AppHandle) -> Result<Arc<MarketplaceCoordinator>, String> {
    let state = app.state::<MarketplaceState>();
    let mut coordinator = state.0.lock().map_err(|_| "marketplace state poisoned")?;
    if let Some(coordinator) = coordinator.as_ref() {
        return Ok(coordinator.clone());
    }
    // All mutable files use platform-owned app data. The index cache stays under
    // the source store's existing runtime root; downloads/snapshots reuse M1's
    // plugin-temp cleanup scope. There is no shared worktree cache or bundle IO.
    let root = marketplace_sources::sources_path(app)?
        .parent()
        .ok_or("source store root")?
        .to_path_buf();
    let created = Arc::new(MarketplaceCoordinator::new(
        Arc::new(NativeHost(app.clone())),
        Arc::new(ReqwestTransport::new()?),
        FetchPolicy::https_only(),
        root,
        super::install::snapshot_root(app)?,
        super::store::install_root(app)?,
    ));
    *coordinator = Some(created.clone());
    Ok(created)
}

fn existing(app: &AppHandle) -> Option<Arc<MarketplaceCoordinator>> {
    let state = app.try_state::<MarketplaceState>()?;
    let coordinator = state.0.lock().ok()?.clone();
    coordinator
}

fn product_window(window: &WebviewWindow) -> Result<String, String> {
    let label = window.label();
    if label != "main" && !label.starts_with("workspace-") {
        return Err("marketplace commands are restricted to product windows".into());
    }
    if window.app_handle().get_webview_window(label).is_none() {
        return Err("the marketplace window was closed".into());
    }
    Ok(label.into())
}

#[tauri::command]
pub async fn declarative_marketplace_list(
    window: WebviewWindow,
) -> Result<Vec<SourceIndex>, String> {
    product_window(&window)?;
    let coordinator = coordinator(window.app_handle())?;
    tauri::async_runtime::spawn_blocking(move || coordinator.list())
        .await
        .map_err(|error| error.to_string())?
}

#[tauri::command]
pub async fn declarative_marketplace_refresh(
    window: WebviewWindow,
    operation_id: String,
    source_id: String,
) -> Result<Value, String> {
    let owner = product_window(&window)?;
    coordinator(window.app_handle())?
        .refresh(&owner, &operation_id, &source_id)
        .await
}

#[tauri::command]
pub async fn declarative_marketplace_prepare(
    window: WebviewWindow,
    operation_id: String,
    source_id: String,
    plugin_id: String,
) -> Result<MarketplaceReview, String> {
    let owner = product_window(&window)?;
    coordinator(window.app_handle())?
        .prepare(&owner, &operation_id, &source_id, &plugin_id)
        .await
}

#[tauri::command]
pub async fn declarative_marketplace_confirm(
    window: WebviewWindow,
    operation_id: String,
    manifest_digest: String,
    approved: bool,
) -> Result<Value, String> {
    let owner = product_window(&window)?;
    let app = window.app_handle().clone();
    let coordinator = coordinator(&app)?;
    let confirmation = coordinator.claim_confirmation(&owner, &operation_id)?;
    confirmation.check_review(&manifest_digest, approved)?;
    let plugin_id = confirmation.plugin_id().to_string();
    async move {
        // Reuse the same process/webview drain barrier as every M1 mutation.
        let mutation = super::lifecycle::begin(&app, &plugin_id).await?;
        let worker_app = app.clone();
        // The worker owns the barrier until publication and rescan finish. If an
        // IPC future is dropped, another mutation must not overlap that worker.
        tauri::async_runtime::spawn_blocking(move || {
            let confirmed = confirmation.publish(&manifest_digest, approved)?;
            super::install::rescan_after_change(&worker_app)?;
            let enabled = confirmed.record.enabled;
            mutation.complete(enabled);
            Ok::<_, String>(serde_json::json!({"pluginId": confirmed.plugin_id, "version": confirmed.version, "enabled": enabled}))
        }).await.map_err(|error| error.to_string())?
    }.await
}

#[tauri::command]
pub fn declarative_marketplace_cancel(
    window: WebviewWindow,
    operation_id: String,
) -> Result<(), String> {
    let owner = product_window(&window)?;
    // Cancellation may be the first IPC polled. Create the owner now so its
    // cancellation history also rejects a prepare that has not registered yet.
    coordinator(window.app_handle())?.cancel(&owner, &operation_id);
    Ok(())
}

pub(crate) fn window_destroyed(app: &AppHandle, window: &str) {
    if window != "main" && !window.starts_with("workspace-") {
        return;
    }
    if let Some(state) = app.try_state::<MarketplaceState>() {
        state
            .1
            .lock()
            .expect("marketplace windows")
            .insert(window.into());
    }
    if let Some(coordinator) = existing(app) {
        coordinator.cancel_window(window);
    }
}
pub(crate) fn cancel_source(app: &AppHandle, source: &str) {
    if let Some(coordinator) = existing(app) {
        coordinator.cancel_source(source);
    }
}
pub(crate) fn cancel_plugin(app: &AppHandle, plugin: &str) {
    if let Some(coordinator) = existing(app) {
        coordinator.cancel_plugin(plugin);
    }
}
