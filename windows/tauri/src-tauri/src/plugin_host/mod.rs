//! Windows host for contract v1 declarative plugin packages.
//!
//! Package validation, launch-plan expansion, and install review are shared
//! deterministic logic that lives only in `lithe-core`; this module owns the
//! platform side: where packages are installed, which packages the host
//! currently accepts, and how a Core launch plan becomes a process command
//! line. The boundary with the Worker extension model and the staged
//! capability rollout are recorded in
//! .agents/notes/proposed/architecture/2026-10-22-windows-declarative-plugin-host.md

pub mod launch;
pub mod scan;
pub mod store;
#[cfg(test)]
mod tests;

use serde::Serialize;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Mutex;
use tauri::{AppHandle, Manager};

/// Capability versions this host implements. `plugins.declarative.validate`
/// rejects any package that requires a capability or version beyond this map,
/// so the host never registers a manifest section it cannot run. The set
/// grows per milestone of the declarative plugin host work.
pub fn host_capabilities() -> Value {
    json!({
        "languages": [1],
        "languageServers": [1],
        "serverProcess": [1],
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
    packages: Mutex<Vec<ScannedPackage>>,
}

impl PluginHostState {
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
pub fn declarative_plugins_rescan(app: AppHandle) -> Result<usize, String> {
    let packages = scan::build_catalog(&app)?;
    let count = packages.len();
    app.state::<PluginHostState>().set_packages(packages);
    Ok(count)
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
