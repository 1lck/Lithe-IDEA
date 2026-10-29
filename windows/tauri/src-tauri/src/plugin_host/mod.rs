//! Windows host for contract v1 declarative plugin packages.
//!
//! Package validation, launch-plan expansion, and install review are shared
//! deterministic logic that lives only in `lithe-core`; this module owns the
//! platform side: where packages are installed, which packages the host
//! currently accepts, and how a Core launch plan becomes a process command
//! line. The boundary with the Worker extension model and the staged
//! capability rollout are recorded in
//! .agents/notes/implemented/architecture/2026-10-22-windows-declarative-plugin-host.md

pub mod install;
#[cfg(test)]
mod install_tests;
pub mod launch;
pub mod lifecycle;
pub mod run_plans;
pub mod scan;
pub mod settings;
pub mod store;
#[cfg(test)]
mod tests;
pub mod web;

use serde::Serialize;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Mutex;
use tauri::{AppHandle, Manager};

/// Capability versions this host implements. `plugins.declarative.validate`
/// rejects any package that requires a capability or version beyond this map,
/// so the host never registers a manifest section it cannot run. The set
/// grows per milestone of the declarative plugin host work. `languageServers`
/// 2 and `settings` 2 add workspace configuration push and scoped settings
/// (M3); `ui` 2 adds package web pages in host windows (M4);
/// `executionProviders`, `buildProviders` and `buildSystems` remain unhosted.
pub fn host_capabilities() -> Value {
    json!({
        "languages": [1],
        "languageServers": [1, 2],
        "serverProcess": [1],
        "settings": [1, 2],
        "ui": [1, 2],
    })
}

/// Host CPU architecture in the vocabulary Core launch templates expect
/// (`arm64` / `x86_64`); Rust spells aarch64 differently.
pub fn host_architecture() -> &'static str {
    match std::env::consts::ARCH {
        "aarch64" => "arm64",
        other => other,
    }
}

/// Frontend-facing summary of one scanned declarative plugin.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogEntry {
    pub plugin_id: String,
    pub display_name: String,
    pub version: String,
    pub api_version: u32,
    /// `bundled` packages ship inside the installation directory and load
    /// read-only; `installed` packages live under the per-user plugin store.
    pub source: &'static str,
    pub enabled: bool,
    /// `accepted` packages are registered language owners; `rejected`
    /// packages are quarantined with Core's stable rejection code.
    pub status: &'static str,
    pub languages: Vec<CatalogLanguage>,
    /// Declared settings (settings capability), as Core normalizes them.
    pub declared_settings: Vec<Value>,
    /// Whether any execution provider declares a test template.
    pub declares_tests: bool,
    /// First language with a language server, for workspace configuration.
    pub primary_language_id: Option<String>,
    pub rejection: Option<CatalogRejection>,
}

/// Language declaration of a scanned package.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogLanguage {
    pub id: String,
    pub display_name: String,
    pub file_extensions: Vec<String>,
    pub file_names: Vec<String>,
}

/// Why a package was quarantined. Manifest problems carry Core's stable
/// `plugin.*` code; store problems (missing or invalid installation record)
/// use the host-owned `plugin.store.*` namespace.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogRejection {
    pub code: String,
    pub message: String,
    pub path: Option<String>,
}

/// One scanned package with everything launch resolution needs but the
/// frontend does not.
#[derive(Debug, Clone)]
pub struct ScannedPackage {
    pub entry: CatalogEntry,
    /// Directory that directly contains `plugin.json`.
    pub root: PathBuf,
    /// Raw manifest; plan commands are pure functions and take it every time.
    pub manifest: Value,
}

/// Cached scan result. The frontend rescans at startup and after installs,
/// then reads this state for registration and launch queries.
#[derive(Default)]
pub struct PluginHostState {
    scan_lock: Mutex<()>,
    packages: Mutex<Vec<ScannedPackage>>,
}

impl PluginHostState {
    /// Serialize discovery through publication. Independent package mutations
    /// may overlap, but an older full scan must never overwrite a newer scan.
    pub(crate) fn refresh(
        &self,
        discover: impl FnOnce() -> Result<Vec<ScannedPackage>, String>,
    ) -> Result<usize, String> {
        let _scan = self
            .scan_lock
            .lock()
            .map_err(|_| "plugin catalog scan lock poisoned")?;
        let packages = discover()?;
        let count = packages.len();
        self.set_packages(packages);
        Ok(count)
    }

    pub fn set_packages(&self, packages: Vec<ScannedPackage>) {
        *self.packages.lock().expect("plugin host catalog mutex") = packages;
    }

    pub fn packages(&self) -> Vec<ScannedPackage> {
        self.packages
            .lock()
            .expect("plugin host catalog mutex")
            .clone()
    }
}

/// Rescans bundled and installed packages and replaces the cached catalog.
#[tauri::command]
pub async fn declarative_plugins_rescan(app: AppHandle) -> Result<usize, String> {
    crate::blocking::run_blocking(move || {
        app.state::<PluginHostState>()
            .refresh(|| scan::build_catalog(&app))
    })
    .await
}

/// Returns the cached scan result. Call `declarative_plugins_rescan` first;
/// this command never triggers filesystem work.
#[tauri::command]
pub fn declarative_plugins_state(app: AppHandle) -> Vec<CatalogEntry> {
    app.state::<PluginHostState>()
        .packages()
        .into_iter()
        .map(|package| package.entry)
        .collect()
}

/// Returns the raw manifest of one accepted, enabled plugin; settings pages
/// must pass the full manifest to Core's resolve commands, which re-validate
/// it. `None` when the ID does not name an accepted, enabled plugin.
#[tauri::command]
pub fn declarative_plugins_manifest(app: AppHandle, plugin_id: String) -> Option<Value> {
    app.state::<PluginHostState>()
        .packages()
        .into_iter()
        .find(|package| {
            package.entry.status == "accepted"
                && package.entry.enabled
                && package.entry.plugin_id == plugin_id
        })
        .map(|package| package.manifest)
}
