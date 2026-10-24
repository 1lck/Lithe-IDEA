//! Disk-package import, uninstall, enable/disable, and rollback for
//! declarative plugin packages.
//!
//! The install flow follows the macOS disk-import semantics recorded in
//! .agents/notes/implemented/architecture/2026-10-12-declarative-language-plugins.md:
//! the input is copied to a private snapshot first, Core's
//! `plugins.marketplace.installReview` produces the permission and program
//! summary the user confirms, and installation re-validates the staged bytes
//! before they replace the active version. Disk packages are community
//! origin: the installation record stores the content digest and the
//! approved programs of the confirmed review, and every later load rechecks
//! them. A publisher signature document is verified whenever one is present;
//! it never substitutes for the user's review.

use super::scan::{core_execute, validate_manifest};
use super::store::{self, DiskProvenance, InstallationRecord};
use super::{CatalogEntry, PluginHostState};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::io::Read;
use std::path::{Path, PathBuf};
use tauri::{AppHandle, Manager};

/// Maximum decompressed package size (16 MiB per file, 128 MiB total) and
/// entry count; a hostile ZIP cannot exhaust the user's disk before review.
const MAX_PACKAGE_FILE_BYTES: u64 = 16 * 1024 * 1024;
const MAX_PACKAGE_TOTAL_BYTES: u64 = 128 * 1024 * 1024;
const MAX_PACKAGE_ENTRIES: usize = 2_000;
/// Maximum snapshot lifetime is one review session; a session id ties prepare
/// and confirm calls together so abandoned snapshots are cleaned up.
const SNAPSHOT_PREFIX: &str = "lithe-plugin-disk-";

#[derive(Default)]
struct PackageBudget {
    entries: usize,
    bytes: u64,
}

impl PackageBudget {
    fn add(&mut self, bytes: u64) -> Result<(), String> {
        if bytes > MAX_PACKAGE_FILE_BYTES {
            return Err("a package file exceeds the per-file size limit".to_string());
        }
        self.entries += 1;
        if self.entries > MAX_PACKAGE_ENTRIES {
            return Err("the package contains too many entries".to_string());
        }
        self.bytes = self
            .bytes
            .checked_add(bytes)
            .ok_or("the package is too large")?;
        if self.bytes > MAX_PACKAGE_TOTAL_BYTES {
            return Err("the package exceeds the total size limit".to_string());
        }
        Ok(())
    }
}

/// A prepared disk import awaiting user confirmation.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PreparedInstall {
    pub session_id: String,
    pub review: InstallReview,
    /// SHA-256 of the snapshot `plugin.json`; the confirm call must still see
    /// the same package, so review answers cannot be replayed on new bytes.
    pub manifest_digest: String,
    /// Human-readable display name from the manifest.
    pub display_name: String,
}

/// Core's install review, reshaped for the frontend.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallReview {
    pub plugin_id: String,
    pub version: String,
    pub permissions: Vec<String>,
    pub programs: Vec<serde_json::Value>,
    pub new_programs: Vec<serde_json::Value>,
}

/// Source facts recorded beside the snapshot, so the installation record can
/// name what the user installed without changing the confirm-call contract.
#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SnapshotSource {
    file_name: String,
    archive_sha256: Option<String>,
}

/// Prepares a disk import from a ZIP archive or an unpacked directory. The
/// source is copied to a private snapshot under the app's temporary
/// directory; nothing is installed and nothing outside the snapshot is
/// written.
#[tauri::command]
pub fn declarative_plugins_prepare_disk_install(
    app: AppHandle,
    source_path: String,
) -> Result<PreparedInstall, String> {
    let temporary_root = app
        .path()
        .app_local_data_dir()
        .map_err(|error| error.to_string())?
        .join("plugin-temp");
    std::fs::create_dir_all(&temporary_root).map_err(|error| error.to_string())?;
    let session_id = format!("{}{}", SNAPSHOT_PREFIX, uuid_like_suffix());
    let snapshot = temporary_root.join(&session_id);
    let source = PathBuf::from(&source_path);
    let result = (|| {
        let file_name = source
            .file_name()
            .map(|name| name.to_string_lossy().to_string())
            .ok_or("the source has no file name")?;
        let archive_sha256 =
            if source.extension().and_then(|extension| extension.to_str()) == Some("zip") {
                Some(archive_digest(&source)?)
            } else {
                None
            };
        if source.extension().and_then(|extension| extension.to_str()) == Some("zip") {
            extract_zip_snapshot(&source, &snapshot)?;
        } else if source.is_dir() {
            copy_directory_snapshot(&source, &snapshot)?;
        } else {
            return Err(format!(
                "{} is neither a .zip archive nor an unpacked package directory",
                source.display()
            ));
        }
        let manifest = read_package_manifest(&snapshot)?;
        // Source facts live beside the snapshot, not inside it: every file
        // under the snapshot becomes an installed package file.
        std::fs::write(
            snapshot_source_path(&temporary_root, &session_id),
            serde_json::to_string(&SnapshotSource {
                file_name,
                archive_sha256,
            })
            .map_err(|error| error.to_string())?,
        )
        .map_err(|error| error.to_string())?;
        Ok(PreparedInstall {
            session_id: session_id.clone(),
            review: review_snapshot(&manifest, None)?,
            manifest_digest: content_digest(&manifest),
            display_name: manifest["displayName"]
                .as_str()
                .unwrap_or("plugin")
                .to_string(),
        })
    })();
    if result.is_err() {
        discard_snapshot(&temporary_root.join(&session_id));
        discard_source_metadata(&temporary_root, &session_id);
    }
    result
}

/// Installs a previously prepared snapshot after the user confirmed the
/// review. The confirm call re-validates the snapshot bytes and re-runs the
/// review, so a snapshot swapped between prepare and confirm is rejected.
/// The staged copy is re-verified against the recorded content digest before
/// it becomes the active version, and the installation record is written in
/// the same transaction as the version swap: a failure at any point leaves
/// the previous version and its record untouched.
#[tauri::command]
pub async fn declarative_plugins_confirm_disk_install(
    app: AppHandle,
    session_id: String,
    manifest_digest: String,
) -> Result<CatalogEntry, String> {
    let temporary_root = snapshot_root(&app)?;
    let snapshot = snapshot_path(&app, &session_id)?;
    let source_record_path = snapshot_source_path(&temporary_root, &session_id);
    let result = async {
        let source: SnapshotSource = serde_json::from_str(
            &std::fs::read_to_string(&source_record_path)
                .map_err(|error| format!("the install session has no source record: {error}"))?,
        )
        .map_err(|error| format!("the install session source record is unreadable: {error}"))?;
        let manifest = read_package_manifest(&snapshot)?;
        if content_digest(&manifest) != manifest_digest {
            return Err("the package changed after review; the import was cancelled".to_string());
        }
        // Re-review with no previously approved programs: a disk install always
        // requires a fresh full confirmation, matching the macOS rule.
        let review = review_snapshot(&manifest, None)?;
        let plugin_id = manifest["id"]
            .as_str()
            .ok_or("manifest has no id")?
            .to_string();
        let version = manifest["version"]
            .as_str()
            .ok_or("manifest has no version")?
            .to_string();

        // Validate the final manifest against this host's capabilities before
        // anything is written into the install root.
        validate_manifest(&manifest).map_err(|rejection| rejection.message)?;
        // Disk installs are community origin. The pinned trust policy still
        // applies (an official ID cannot install as an unsigned community
        // package), and a signature document present in the package must
        // verify even though the community digest is the recorded evidence.
        super::signature::verify_for_install(
            &snapshot,
            &plugin_id,
            &version,
            &manifest,
            super::signature::InstallOrigin::Community,
            super::signature::trusted_keys(),
        )
        .map_err(|error| error.message())?;
        let approved_digest =
            super::signature::content_digest(&snapshot).map_err(|error| error.message())?;

        // A version switch invalidates the page's package bytes and bridge
        // authorization, so destroy all owned webviews before staging starts.
        let mutation = super::lifecycle::begin(&app, &plugin_id).await?;
        let install_root = store::install_root(&app)?;
        let existing = read_installation_record(&install_root, &plugin_id);
        let replaces_active = existing
            .as_ref()
            .map(|record| record.version == version)
            .unwrap_or(false);
        // The same-version rule keeps the previous chain intact: replacing
        // the active version in place does not overwrite what the user can
        // still roll back to.
        let (previous_version, previous_origin) = if replaces_active {
            (
                existing
                    .as_ref()
                    .and_then(|record| record.previous_version.clone()),
                existing.as_ref().and_then(|record| record.previous_origin),
            )
        } else {
            (
                existing.as_ref().map(|record| record.version.clone()),
                existing.as_ref().and_then(|record| record.origin),
            )
        };
        let (previous_marketplace, previous_disk) = if replaces_active {
            (
                existing
                    .as_ref()
                    .and_then(|record| record.previous_marketplace.clone()),
                existing
                    .as_ref()
                    .and_then(|record| record.previous_disk.clone()),
            )
        } else {
            (
                existing
                    .as_ref()
                    .and_then(|record| record.marketplace.clone()),
                existing.as_ref().and_then(|record| record.disk.clone()),
            )
        };
        let record = InstallationRecord {
            schema_version: 2,
            plugin_id: plugin_id.clone(),
            version: version.clone(),
            previous_version,
            enabled: true,
            origin: Some(super::signature::InstallOrigin::Community),
            previous_origin,
            marketplace: None,
            previous_marketplace,
            disk: Some(DiskProvenance {
                file_name: source.file_name,
                archive_sha256: source.archive_sha256,
                content_digest: approved_digest,
                approved_programs: canonical_programs(&review.programs),
            }),
            previous_disk,
        };
        publish_installed_version(&install_root, &plugin_id, &version, &snapshot, record)?;
        rescan_after_change(&app)?;
        mutation.complete(true);
        Ok(catalog_entry_of(&app, &plugin_id)
            .unwrap_or_else(|| accepted_entry_fallback(&plugin_id, &version)))
    }
    .await;
    discard_snapshot(&snapshot);
    discard_source_metadata(&temporary_root, &session_id);
    result
}

/// Abandons an installation review and removes its private snapshot.
#[tauri::command]
pub fn declarative_plugins_cancel_disk_install(
    app: AppHandle,
    session_id: String,
) -> Result<(), String> {
    let temporary_root = snapshot_root(&app)?;
    let snapshot = snapshot_path(&app, &session_id)?;
    if snapshot.exists() {
        std::fs::remove_dir_all(snapshot).map_err(|error| error.to_string())?;
    }
    discard_source_metadata(&temporary_root, &session_id);
    Ok(())
}

fn snapshot_path(app: &AppHandle, session_id: &str) -> Result<PathBuf, String> {
    if !session_id.starts_with(SNAPSHOT_PREFIX)
        || session_id.contains('/')
        || session_id.contains('\\')
        || session_id.contains("..")
    {
        return Err("invalid install session".to_string());
    }
    Ok(snapshot_root(app)?.join(session_id))
}

fn snapshot_root(app: &AppHandle) -> Result<PathBuf, String> {
    Ok(app
        .path()
        .app_local_data_dir()
        .map_err(|error| error.to_string())?
        .join("plugin-temp"))
}

fn snapshot_source_path(temporary_root: &Path, session_id: &str) -> PathBuf {
    temporary_root.join(format!("{session_id}.source.json"))
}

fn discard_source_metadata(temporary_root: &Path, session_id: &str) {
    let _ = std::fs::remove_file(snapshot_source_path(temporary_root, session_id));
}

/// Removes an installed package. Bundled packages cannot be uninstalled.
#[tauri::command]
pub async fn declarative_plugins_uninstall(
    app: AppHandle,
    plugin_id: String,
) -> Result<(), String> {
    let install_root = store::install_root(&app)?;
    let plugin_directory = install_root.join(&plugin_id);
    if !plugin_directory.is_dir() {
        return Err(format!("{plugin_id} is not an installed plugin"));
    }
    let mutation = super::lifecycle::begin(&app, &plugin_id).await?;
    std::fs::remove_dir_all(&plugin_directory)
        .map_err(|error| format!("{plugin_id} could not be removed: {error}"))?;
    let state_directory = store::plugin_state_directory(&app, &plugin_id)?;
    if state_directory.is_dir() {
        std::fs::remove_dir_all(&state_directory)
            .map_err(|error| format!("state directory could not be removed: {error}"))?;
    }
    rescan_after_change(&app)?;
    mutation.complete(false);
    Ok(())
}

/// Enables or disables an installed plugin; bundled packages are always
/// enabled and reject the call.
#[tauri::command]
pub async fn declarative_plugins_set_enabled(
    app: AppHandle,
    plugin_id: String,
    enabled: bool,
) -> Result<(), String> {
    let install_root = store::install_root(&app)?;
    let record_path = install_root.join(&plugin_id).join("installation.json");
    let mut record: InstallationRecord = serde_json::from_str(
        &std::fs::read_to_string(&record_path)
            .map_err(|error| format!("{plugin_id} has no readable install record: {error}"))?,
    )
    .map_err(|error| format!("{plugin_id} has a corrupted install record: {error}"))?;
    let mutation = super::lifecycle::begin(&app, &plugin_id).await?;
    record.enabled = enabled;
    // Write via temp + rename so a crash never leaves a truncated record.
    let temp_path = record_path.with_extension("json.tmp");
    std::fs::write(
        &temp_path,
        serde_json::to_string_pretty(&record).map_err(|error| error.to_string())?,
    )
    .map_err(|error| error.to_string())?;
    std::fs::rename(&temp_path, &record_path).map_err(|error| error.to_string())?;
    rescan_after_change(&app)?;
    mutation.complete(enabled);
    Ok(())
}

/// Restores the previous version of an installed package. The restored
/// package is verified with its own recorded provenance — a community
/// version is rechecked against the digest approved for it, and a signature
/// document present in it must still verify — before the record swaps, so a
/// rollback can never activate bytes the host would refuse to load.
/// Rollback requires a retained previous version and always re-enables the
/// package so a broken update cannot leave it disabled and forgotten.
#[tauri::command]
pub async fn declarative_plugins_rollback(app: AppHandle, plugin_id: String) -> Result<(), String> {
    let install_root = store::install_root(&app)?;
    let plugin_directory = install_root.join(&plugin_id);
    let record: InstallationRecord = serde_json::from_str(
        &std::fs::read_to_string(plugin_directory.join("installation.json"))
            .map_err(|error| format!("{plugin_id} has no readable install record: {error}"))?,
    )
    .map_err(|error| error.to_string())?;
    let Some(previous) = record.previous_version.clone() else {
        return Err(format!(
            "{plugin_id} has no previous version to roll back to"
        ));
    };
    let Some(previous_origin) = record.previous_origin.or(record.origin) else {
        return Err(format!(
            "{plugin_id} has no recorded origin to verify the previous version with"
        ));
    };
    let previous_directory = plugin_directory.join(&previous);
    let manifest = read_package_manifest(&previous_directory)?;
    if manifest["id"].as_str() != Some(plugin_id.as_str())
        || manifest["version"].as_str() != Some(previous.as_str())
    {
        return Err("the previous package does not match its installation record".to_string());
    }
    validate_manifest(&manifest).map_err(|rejection| rejection.message)?;
    super::signature::verify_for_origin(
        &previous_directory,
        &plugin_id,
        &previous,
        &manifest,
        previous_origin,
        record.previous_content_digest(),
        super::signature::trusted_keys(),
    )
    .map_err(|error| error.message())?;
    let mutation = super::lifecycle::begin(&app, &plugin_id).await?;
    let swapped = InstallationRecord {
        schema_version: 2,
        plugin_id: record.plugin_id.clone(),
        version: previous,
        previous_version: Some(record.version.clone()),
        enabled: true,
        origin: record.previous_origin,
        previous_origin: record.origin,
        marketplace: record.previous_marketplace.clone(),
        previous_marketplace: record.marketplace.clone(),
        disk: record.previous_disk.clone(),
        previous_disk: record.disk.clone(),
    };
    write_installation_record(&install_root, &swapped)?;
    rescan_after_change(&app)?;
    mutation.complete(true);
    Ok(())
}

// MARK: helpers

fn review_snapshot(
    manifest: &serde_json::Value,
    approved_programs: Option<&[serde_json::Value]>,
) -> Result<InstallReview, String> {
    let outcome = core_execute(
        "plugins.marketplace.installReview",
        serde_json::json!({
            "manifest": manifest,
            "hostCapabilities": super::host_capabilities(),
            "approvedPrograms": approved_programs,
        }),
    )?;
    if outcome["status"] == serde_json::json!("rejected") {
        return Err(format!(
            "install review rejected: {}",
            outcome["error"]["message"].as_str().unwrap_or("unknown")
        ));
    }
    let review = &outcome["review"];
    Ok(InstallReview {
        plugin_id: review["id"].as_str().unwrap_or_default().to_string(),
        version: review["version"].as_str().unwrap_or_default().to_string(),
        permissions: string_list(&review["permissions"]),
        programs: review["programs"].as_array().cloned().unwrap_or_default(),
        new_programs: review["newPrograms"]
            .as_array()
            .cloned()
            .unwrap_or_default(),
    })
}

/// Publishes a validated package as the active version of an installed
/// plugin. The staged copy is verified against the recorded provenance
/// before it replaces the active version, and the installation record is
/// written in the same transaction: a failure at any point restores the
/// previous version directory and leaves the old record readable.
pub(crate) fn publish_installed_version(
    install_root: &Path,
    plugin_id: &str,
    version: &str,
    source: &Path,
    record: InstallationRecord,
) -> Result<(), String> {
    let plugin_directory = install_root.join(plugin_id);
    std::fs::create_dir_all(&plugin_directory).map_err(|error| error.to_string())?;
    let version_directory = plugin_directory.join(version);
    let staging_directory = plugin_directory.join(format!(".staging-{version}"));
    if staging_directory.exists() {
        std::fs::remove_dir_all(&staging_directory).map_err(|error| error.to_string())?;
    }
    let result = (|| {
        copy_directory_snapshot(source, &staging_directory)?;
        // The staged bytes are what gets installed: re-validate the copy,
        // then bind it to the digest recorded for the approved snapshot.
        let staged_manifest = read_package_manifest(&staging_directory)?;
        validate_manifest(&staged_manifest).map_err(|rejection| rejection.message)?;
        let origin = record
            .origin
            .ok_or("the installation record has no origin")?;
        super::signature::verify_for_install(
            &staging_directory,
            plugin_id,
            version,
            &staged_manifest,
            origin,
            super::signature::trusted_keys(),
        )
        .map_err(|error| error.message())?;
        if let Some(expected) = record.active_content_digest() {
            let staged_digest = super::signature::content_digest(&staging_directory)
                .map_err(|error| error.message())?;
            if staged_digest != expected {
                return Err(super::signature::TrustError::ContentChanged.message());
            }
        }
        activate_staged_version(&staging_directory, &version_directory)?;
        // The record only ever points at bytes that are already in place; if
        // this write fails, the backup restore below keeps the old version
        // and the old record consistent.
        write_installation_record(install_root, &record)
    })();
    if result.is_err() {
        let _ = std::fs::remove_dir_all(&staging_directory);
    }
    result
}

/// Replaces `version_directory` with the staged copy, keeping a backup so a
/// failed rename never leaves the install record pointing at missing bytes.
fn activate_staged_version(
    staging_directory: &Path,
    version_directory: &Path,
) -> Result<(), String> {
    if !version_directory.exists() {
        return std::fs::rename(staging_directory, version_directory)
            .map_err(|error| format!("activation failed: {error}"));
    }
    // Replacing an existing version: move the current directory aside first,
    // and restore it if activation fails, so a failed same-version reinstall
    // never leaves the install record pointing at missing bytes.
    let backup_directory = version_directory.with_extension("previous-tmp");
    if backup_directory.exists() {
        std::fs::remove_dir_all(&backup_directory).map_err(|error| error.to_string())?;
    }
    std::fs::rename(version_directory, &backup_directory)
        .map_err(|error| format!("could not back up the current version: {error}"))?;
    if let Err(activation_error) = std::fs::rename(staging_directory, version_directory) {
        if let Err(restore_error) = std::fs::rename(&backup_directory, version_directory) {
            return Err(format!(
                "activation failed ({activation_error}) and the previous version could not be restored ({restore_error})"
            ));
        }
        return Err(format!("activation failed: {activation_error}"));
    }
    let _ = std::fs::remove_dir_all(&backup_directory);
    Ok(())
}

/// Reads the current install record of a plugin; `None` when the plugin has
/// no record yet or the record is unreadable, which a fresh install then
/// replaces with a complete record.
fn read_installation_record(install_root: &Path, plugin_id: &str) -> Option<InstallationRecord> {
    let text =
        std::fs::read_to_string(install_root.join(plugin_id).join("installation.json")).ok()?;
    serde_json::from_str(&text).ok()
}

/// Writes an installation record through temp + rename so a crash never
/// leaves a truncated record.
pub(crate) fn write_installation_record(
    install_root: &Path,
    record: &InstallationRecord,
) -> Result<(), String> {
    let record_path = install_root
        .join(&record.plugin_id)
        .join("installation.json");
    std::fs::create_dir_all(record_path.parent().ok_or("record path")?)
        .map_err(|error| error.to_string())?;
    let temp_path = record_path.with_extension("json.tmp");
    std::fs::write(
        &temp_path,
        serde_json::to_string_pretty(record).map_err(|error| error.to_string())?,
    )
    .map_err(|error| error.to_string())?;
    std::fs::rename(&temp_path, &record_path).map_err(|error| error.to_string())?;
    Ok(())
}

/// Serializes every approved program of the review into its canonical JSON
/// text, the same evidence the macOS record keeps for re-approval checks.
fn canonical_programs(programs: &[serde_json::Value]) -> Vec<String> {
    programs
        .iter()
        .map(|program| serde_json::to_string(program).unwrap_or_default())
        .collect()
}

/// SHA-256 of the source archive, recorded with the disk provenance.
fn archive_digest(source: &Path) -> Result<String, String> {
    let mut file = std::fs::File::open(source)
        .map_err(|error| format!("{} could not be opened: {error}", source.display()))?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let read = file
            .read(&mut buffer)
            .map_err(|error| format!("{} could not be read: {error}", source.display()))?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn read_package_manifest(package_root: &Path) -> Result<serde_json::Value, String> {
    let text = std::fs::read_to_string(package_root.join("plugin.json"))
        .map_err(|error| format!("the package has no readable plugin.json: {error}"))?;
    serde_json::from_str(&text).map_err(|error| format!("plugin.json is not valid JSON: {error}"))
}

fn content_digest(manifest: &serde_json::Value) -> String {
    let mut hasher = Sha256::new();
    hasher.update(manifest.to_string().as_bytes());
    format!("{:x}", hasher.finalize())
}

/// Copies a directory tree, refusing reparse points and files beyond the
/// package budgets. The copy is the safety boundary: everything reviewed and
/// installed afterwards comes from this snapshot, not the mutable source.
pub(crate) fn copy_directory_snapshot(source: &Path, snapshot: &Path) -> Result<(), String> {
    let mut budget = PackageBudget::default();
    let result = copy_tree_bounded(source, source, snapshot, 0, &mut budget);
    if result.is_err() {
        discard_snapshot(snapshot);
    }
    result
}

fn copy_tree_bounded(
    root: &Path,
    directory: &Path,
    snapshot: &Path,
    depth: usize,
    budget: &mut PackageBudget,
) -> Result<(), String> {
    if depth > 64 {
        return Err("the package directory nesting exceeds 64 levels".to_string());
    }
    let relative = directory
        .strip_prefix(root)
        .map_err(|error| error.to_string())?;
    let target = snapshot.join(relative);
    std::fs::create_dir_all(&target).map_err(|error| error.to_string())?;
    for entry in std::fs::read_dir(directory).map_err(|error| error.to_string())? {
        let entry = entry.map_err(|error| error.to_string())?;
        let entry_path = entry.path();
        let metadata = std::fs::symlink_metadata(&entry_path)
            .map_err(|error| format!("{} is unreadable: {error}", entry_path.display()))?;
        #[cfg(windows)]
        {
            use std::os::windows::fs::MetadataExt;
            if metadata.file_attributes() & 0x0400 != 0 {
                return Err(format!(
                    "{} is a reparse point; package entries must be regular files",
                    entry_path.display()
                ));
            }
        }
        #[cfg(not(windows))]
        if metadata.file_type().is_symlink() {
            return Err(format!(
                "{} is a symbolic link; package entries must be regular files",
                entry_path.display()
            ));
        }
        if metadata.is_dir() {
            budget.add(0)?;
            copy_tree_bounded(root, &entry_path, snapshot, depth + 1, budget)?;
        } else if metadata.is_file() {
            budget.add(metadata.len())?;
            let mut input = std::fs::File::open(&entry_path).map_err(|error| error.to_string())?;
            let mut output = std::fs::File::create(target.join(entry.file_name()))
                .map_err(|error| error.to_string())?;
            let copied = std::io::copy(&mut input.by_ref().take(metadata.len() + 1), &mut output)
                .map_err(|error| error.to_string())?;
            if copied != metadata.len() {
                return Err(format!(
                    "{} changed while being copied",
                    entry_path.display()
                ));
            }
        }
    }
    Ok(())
}

pub(crate) fn extract_zip_snapshot(source: &Path, snapshot: &Path) -> Result<(), String> {
    let result = extract_zip_snapshot_inner(source, snapshot);
    if result.is_err() {
        discard_snapshot(snapshot);
    }
    result
}

fn extract_zip_snapshot_inner(source: &Path, snapshot: &Path) -> Result<(), String> {
    let file = std::fs::File::open(source)
        .map_err(|error| format!("{} could not be opened: {error}", source.display()))?;
    let mut archive = zip::ZipArchive::new(file).map_err(|error| {
        format!(
            "{} is not a readable ZIP archive: {error}",
            source.display()
        )
    })?;
    if archive.len() > MAX_PACKAGE_ENTRIES {
        return Err("the archive contains too many entries".to_string());
    }
    let mut budget = PackageBudget::default();
    for index in 0..archive.len() {
        let mut entry = archive
            .by_index(index)
            .map_err(|error| format!("archive entry {index} is unreadable: {error}"))?;
        let Some(name) = entry.enclosed_name().map(|path| path.to_path_buf()) else {
            return Err(format!("archive entry {index} has an unsafe path"));
        };
        budget.add(if entry.is_dir() { 0 } else { entry.size() })?;
        if entry.is_dir() {
            std::fs::create_dir_all(snapshot.join(&name)).map_err(|error| error.to_string())?;
            continue;
        }
        let target = snapshot.join(&name);
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
        }
        // Windows paths are case-insensitive: two entries that differ only in
        // case (or a duplicated name) would silently overwrite each other and
        // break the approved file set, so the second one is a rejection.
        if target.exists() {
            return Err(format!(
                "archive entry {} conflicts with an earlier entry",
                name.display()
            ));
        }
        let mut output = std::fs::File::create(&target).map_err(|error| error.to_string())?;
        let declared_size = entry.size();
        let copied = std::io::copy(&mut entry.by_ref().take(declared_size + 1), &mut output)
            .map_err(|error| error.to_string())?;
        if copied != declared_size {
            return Err(format!(
                "archive entry {} has an invalid size",
                name.display()
            ));
        }
    }
    // A ZIP that unpacked into a single wrapper directory still yields a
    // package root containing plugin.json directly.
    unwrap_single_directory(snapshot);
    read_package_manifest(snapshot)?;
    Ok(())
}

/// If the archive wrapped everything in one directory, treat that directory
/// as the package root.
fn unwrap_single_directory(snapshot: &Path) {
    let Ok(entries) = std::fs::read_dir(snapshot) else {
        return;
    };
    let entries: Vec<_> = entries.flatten().collect();
    if entries.len() == 1 && entries[0].path().is_dir() {
        let inner = entries[0].path();
        if inner.join("plugin.json").is_file() {
            let _ = move_directory_contents(&inner, snapshot);
        }
    }
}

fn move_directory_contents(from: &Path, to: &Path) -> std::io::Result<()> {
    for entry in std::fs::read_dir(from)? {
        let entry = entry?;
        let target = to.join(entry.file_name());
        if entry.path().is_dir() {
            if std::fs::rename(entry.path(), &target).is_err() {
                copy_directory_snapshot(&entry.path(), &target).map_err(std::io::Error::other)?;
            }
        } else {
            std::fs::rename(entry.path(), &target)?;
        }
    }
    std::fs::remove_dir_all(from)
}

fn string_list(value: &serde_json::Value) -> Vec<String> {
    value
        .as_array()
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

fn rescan_after_change(app: &AppHandle) -> Result<(), String> {
    app.state::<PluginHostState>()
        .refresh(|| super::scan::build_catalog(app))
        .map(|_| ())
}

fn catalog_entry_of(app: &AppHandle, plugin_id: &str) -> Option<CatalogEntry> {
    app.state::<PluginHostState>()
        .packages()
        .into_iter()
        .find(|package| package.entry.plugin_id == plugin_id)
        .map(|package| package.entry)
}

fn accepted_entry_fallback(plugin_id: &str, version: &str) -> CatalogEntry {
    CatalogEntry {
        plugin_id: plugin_id.to_string(),
        display_name: plugin_id.to_string(),
        version: version.to_string(),
        api_version: 0,
        source: "installed",
        enabled: true,
        status: "accepted",
        languages: Vec::new(),
        declared_settings: Vec::new(),
        declares_tests: false,
        primary_language_id: None,
        rejection: None,
    }
}

fn discard_snapshot(snapshot: &Path) {
    let _ = std::fs::remove_dir_all(snapshot);
}

/// Time- and process-derived suffix; uniqueness across sessions is what the
/// snapshot directory needs, not cryptographic randomness.
fn uuid_like_suffix() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or_default();
    format!("{}-{:x}", std::process::id(), nanos)
}

/// Removes snapshots left behind by a crashed review session at startup.
pub fn cleanup_stale_snapshots(app: &AppHandle) {
    let Ok(temporary_root) = app
        .path()
        .app_local_data_dir()
        .map(|root| root.join("plugin-temp"))
    else {
        return;
    };
    let Ok(entries) = std::fs::read_dir(&temporary_root) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        if name.starts_with(SNAPSHOT_PREFIX) {
            // Snapshot directories and their `.source.json` sidecar records
            // share the session-id prefix.
            if entry.path().is_dir() {
                let _ = std::fs::remove_dir_all(entry.path());
            } else {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }
}

#[cfg(test)]
mod budget_tests {
    use super::*;

    #[test]
    fn package_budget_enforces_total_bytes_and_entry_count_for_both_import_formats() {
        let mut bytes = PackageBudget::default();
        for _ in 0..8 {
            bytes
                .add(MAX_PACKAGE_FILE_BYTES)
                .expect("within total limit");
        }
        assert!(bytes.add(1).is_err());

        let mut entries = PackageBudget::default();
        for _ in 0..MAX_PACKAGE_ENTRIES {
            entries.add(0).expect("within entry limit");
        }
        assert!(entries.add(0).is_err());
    }
}
