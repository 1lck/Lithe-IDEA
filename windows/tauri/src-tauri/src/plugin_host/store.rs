//! Installed and bundled declarative plugin package locations.
//!
//! Installed packages live under the per-user application data directory,
//! never inside the installation directory: installed app resources are the
//! release baseline and must stay byte-identical for updater deltas. Bundled
//! packages are read-only inputs under the installation's resource directory.

use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::path::Path;
use std::path::PathBuf;
use tauri::{AppHandle, Manager};

/// Per-user root for installed declarative plugin packages.
pub fn install_root(app: &AppHandle) -> Result<PathBuf, String> {
    Ok(app
        .path()
        .app_local_data_dir()
        .map_err(|error| error.to_string())?
        .join("plugins"))
}

/// Read-only root of packages shipped with the application.
pub fn bundled_root(app: &AppHandle) -> Result<PathBuf, String> {
    Ok(app
        .path()
        .resource_dir()
        .map_err(|error| error.to_string())?
        .join("OfficialPlugins"))
}

/// Writable per-plugin state root (server caches, workspace state).
pub fn state_root(app: &AppHandle) -> Result<PathBuf, String> {
    Ok(app
        .path()
        .app_local_data_dir()
        .map_err(|error| error.to_string())?
        .join("plugin-state"))
}

/// Writable state directory of one plugin's language server.
pub fn plugin_state_directory(app: &AppHandle, plugin_id: &str) -> Result<PathBuf, String> {
    // Plugin IDs are reverse-DNS names Core validated before they reach this
    // call, so they are safe as a single path component.
    state_root(app).map(|root| root.join(plugin_id))
}

/// Stable per-workspace subdirectory name inside a plugin's state directory.
pub fn workspace_state_key(workspace_path: &str) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in workspace_path.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{hash:016x}")
}

/// Persistent install record of one installed plugin (schema 2). The record
/// is the only trust evidence for installed packages: which origin the
/// package came from, which byte digest the user approved, and which
/// programs were approved. Schema 1 records carry no provenance; the scan
/// quarantines them instead of reconstructing trust from `enabled` or the
/// manifest.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallationRecord {
    pub schema_version: u32,
    pub plugin_id: String,
    /// Active version directory name under the plugin directory.
    pub version: String,
    /// Version the user can roll back to; verified with its own provenance.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub previous_version: Option<String>,
    #[serde(default = "default_enabled")]
    pub enabled: bool,
    /// Where the active version came from. `None` marks a schema 1 record
    /// written before provenance existed; such records never load.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub origin: Option<super::signature::InstallOrigin>,
    /// Origin of `previousVersion`; rollback verifies the restored package
    /// by how it was installed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub previous_origin: Option<super::signature::InstallOrigin>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub marketplace: Option<MarketplaceProvenance>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub previous_marketplace: Option<MarketplaceProvenance>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub disk: Option<DiskProvenance>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub previous_disk: Option<DiskProvenance>,
}

impl InstallationRecord {
    /// Provenance of the active version: exactly one source owns an approval,
    /// so marketplace and disk provenance are mutually exclusive.
    pub fn active_content_digest(&self) -> Option<&str> {
        match (&self.marketplace, &self.disk) {
            (Some(_), Some(_)) | (None, None) => None,
            (Some(marketplace), None) => Some(&marketplace.content_digest),
            (None, Some(disk)) => Some(&disk.content_digest),
        }
    }

    /// Content digest recorded for `previousVersion`, for rollback checks.
    pub fn previous_content_digest(&self) -> Option<&str> {
        match (&self.previous_marketplace, &self.previous_disk) {
            (Some(_), Some(_)) | (None, None) => None,
            (Some(marketplace), None) => Some(&marketplace.content_digest),
            (None, Some(disk)) => Some(&disk.content_digest),
        }
    }
}

fn default_enabled() -> bool {
    true
}

/// A user-selected local package, without any claim of repository
/// verification. The content digest binds the approval to the installed
/// files. Mirrors the macOS `PluginDiskProvenance`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiskProvenance {
    pub file_name: String,
    pub archive_sha256: Option<String>,
    pub content_digest: String,
    /// Canonical JSON of every approved program from the install review.
    pub approved_programs: Vec<String>,
}

/// Where a marketplace installation came from and what the user approved.
/// Reserved for the marketplace milestone (M2), which writes this record;
/// the scan already rechecks its digest for community origin. Mirrors the
/// macOS `PluginMarketplaceProvenance`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MarketplaceProvenance {
    pub source_id: String,
    pub source_name: String,
    pub repository: String,
    pub archive_sha256: String,
    pub content_digest: String,
    pub approved_programs: Vec<String>,
}

/// One package directory candidate found on disk.
pub struct DiscoveredPackage {
    /// Directory that directly contains `plugin.json`.
    pub root: PathBuf,
    pub source: &'static str,
    pub enabled: bool,
    /// Trust origin recorded for this package. Bundled packages carry
    /// `Bundled`; `None` marks a schema 1 record without provenance, which
    /// the scan quarantines.
    pub origin: Option<super::signature::InstallOrigin>,
    /// Provenance of the active version (digest of the approved bytes).
    pub content_digest: Option<String>,
    /// Set when the package was found but its install record is missing or
    /// invalid; scan quarantines the package with this reason.
    pub record_problem: Option<String>,
}

/// Enumerates installed packages under `install_root`:
/// `<pluginID>/installation.json` names the active `<pluginID>/<version>/`
/// directory.
pub fn discover_installed_in(install_root: &Path) -> Result<Vec<DiscoveredPackage>, String> {
    let mut packages = Vec::new();
    let entries = match std::fs::read_dir(install_root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(packages),
        Err(error) => {
            return Err(format!(
                "{} could not be read: {error}",
                install_root.display()
            ))
        }
    };
    for entry in entries.flatten() {
        let plugin_directory = entry.path();
        if !plugin_directory.is_dir() {
            continue;
        }
        let quarantined = |problem: String| DiscoveredPackage {
            root: plugin_directory.clone(),
            source: "installed",
            enabled: false,
            origin: None,
            content_digest: None,
            record_problem: Some(problem),
        };
        let record: InstallationRecord =
            match read_json_file(&plugin_directory.join("installation.json")) {
                Ok(Some(record)) => record,
                Ok(None) => {
                    packages.push(quarantined(
                        "installation.json is missing; the package was not installed through Lithe"
                            .to_string(),
                    ));
                    continue;
                }
                Err(error) => {
                    packages.push(quarantined(format!(
                        "installation.json could not be read: {error}"
                    )));
                    continue;
                }
            };
        if record.schema_version > 2 {
            packages.push(quarantined(format!(
                "unsupported installation record schema {}",
                record.schema_version
            )));
            continue;
        }
        if record.schema_version == 1 {
            // A schema 1 record predates provenance: the enabled flag and the
            // manifest say nothing about which bytes were approved, so the
            // package is quarantined until the user reinstalls it.
            packages.push(quarantined(
                "the install record predates content provenance; reinstall the plugin to \
                 approve it with the current trust rules"
                    .to_string(),
            ));
            continue;
        }
        if record.plugin_id
            != plugin_directory
                .file_name()
                .map(|name| name.to_string_lossy().to_string())
                .unwrap_or_default()
        {
            packages.push(quarantined(
                "the install record does not match its plugin directory".to_string(),
            ));
            continue;
        }
        let version_directory = plugin_directory.join(&record.version);
        if !version_directory.join("plugin.json").is_file() {
            packages.push(quarantined(format!(
                "recorded version {} has no plugin.json",
                record.version
            )));
            continue;
        }
        if record.active_content_digest().is_none()
            && record.origin == Some(super::signature::InstallOrigin::Community)
        {
            packages.push(quarantined(
                super::signature::TrustError::ProvenanceMissing.message(),
            ));
            continue;
        }
        packages.push(DiscoveredPackage {
            root: version_directory,
            source: "installed",
            enabled: record.enabled,
            origin: record.origin,
            content_digest: record.active_content_digest().map(str::to_string),
            record_problem: None,
        });
    }
    Ok(packages)
}

/// Enumerates bundled packages under `bundled_root`: either
/// `<name>/plugin.json` or `<name>/<version>/plugin.json`, where the highest
/// version wins.
pub fn discover_bundled_in(bundled_root: &Path) -> Result<Vec<DiscoveredPackage>, String> {
    let mut packages = Vec::new();
    let entries = match std::fs::read_dir(bundled_root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(packages),
        Err(error) => {
            return Err(format!(
                "{} could not be read: {error}",
                bundled_root.display()
            ))
        }
    };
    for entry in entries.flatten() {
        let package_directory = entry.path();
        if !package_directory.is_dir() {
            continue;
        }
        if package_directory.join("plugin.json").is_file() {
            packages.push(bundled_package(package_directory));
            continue;
        }
        let mut versions: Vec<(String, PathBuf)> = Vec::new();
        if let Ok(version_entries) = std::fs::read_dir(&package_directory) {
            for version_entry in version_entries.flatten() {
                let version_directory = version_entry.path();
                if version_directory.is_dir() && version_directory.join("plugin.json").is_file() {
                    versions.push((
                        version_directory
                            .file_name()
                            .map(|name| name.to_string_lossy().to_string())
                            .unwrap_or_default(),
                        version_directory,
                    ));
                }
            }
        }
        let Some((_, best)) = versions
            .into_iter()
            .max_by(|(left, _), (right, _)| compare_versions(left, right))
        else {
            continue;
        };
        packages.push(bundled_package(best));
    }
    Ok(packages)
}

/// A bundled package discovered inside the host installation. Bundled
/// packages carry no install record: they ship with the app and are trusted
/// through their location, subject to the pinned signature policy.
fn bundled_package(root: PathBuf) -> DiscoveredPackage {
    DiscoveredPackage {
        root,
        source: "bundled",
        enabled: true,
        origin: Some(super::signature::InstallOrigin::Bundled),
        content_digest: None,
        record_problem: None,
    }
}

/// Dot-separated version comparison with numeric-aware chunks, so `1.10`
/// sorts after `1.9` without pulling in a semver dependency.
pub fn compare_versions(left: &str, right: &str) -> Ordering {
    let mut left_chunks = split_version_chunks(left);
    let mut right_chunks = split_version_chunks(right);
    loop {
        match (left_chunks.next(), right_chunks.next()) {
            (None, None) => return Ordering::Equal,
            (None, Some(_)) => return Ordering::Less,
            // A non-numeric tail is a pre-release suffix (`1.0.0-rc1`), which
            // sorts before the plain release.
            (Some(remaining), None) => {
                return if remaining.1.parse::<u64>().is_err() {
                    Ordering::Less
                } else {
                    Ordering::Greater
                };
            }
            (Some(left_chunk), Some(right_chunk)) => {
                let ordering = left_chunk.cmp(&right_chunk);
                if ordering != Ordering::Equal {
                    return ordering;
                }
            }
        }
    }
}

fn split_version_chunks(version: &str) -> impl Iterator<Item = (u64, &str)> {
    version
        .split(['.', '-', '+'])
        .map(|chunk| (chunk.parse::<u64>().unwrap_or(0), chunk))
}

/// Reads a JSON file; `Ok(None)` marks a missing file so callers can
/// distinguish "absent" from "present but unreadable".
fn read_json_file<T: for<'de> Deserialize<'de>>(path: &Path) -> Result<Option<T>, String> {
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.to_string()),
    };
    serde_json::from_str(&text)
        .map(Some)
        .map_err(|error| error.to_string())
}
