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

/// The evidence frozen when the user's review was prepared, recorded beside
/// the snapshot: what the user installed, and exactly which bytes and which
/// review identity prepare showed. Confirm and staging must reach the same
/// answers, so nothing can change between review and install.
#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SnapshotSource {
    file_name: String,
    archive_sha256: Option<String>,
    /// Digest of the reviewed `plugin.json`.
    manifest_digest: String,
    /// Whole-package content digest of the reviewed snapshot.
    content_digest: String,
    /// Canonical JSON programs of the prepare-time review.
    approved_programs: Vec<String>,
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
    let temporary_root = snapshot_root(&app)?;
    std::fs::create_dir_all(&temporary_root).map_err(|error| error.to_string())?;
    let session_id = format!("{}{}", SNAPSHOT_PREFIX, uuid_like_suffix());
    prepare_disk_install_snapshot(&temporary_root, &session_id, &source_path)
}

/// The testable core of the prepare command: snapshot the source, review it,
/// and park the session under `temporary_root`. A failed prepare discards
/// its snapshot and session record.
pub(crate) fn prepare_disk_install_snapshot(
    temporary_root: &Path,
    session_id: &str,
    source_path: &str,
) -> Result<PreparedInstall, String> {
    let snapshot = validated_session_path(temporary_root, session_id)?;
    std::fs::create_dir_all(temporary_root).map_err(|error| error.to_string())?;
    let source = PathBuf::from(source_path);
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
        let plugin_id = manifest["id"]
            .as_str()
            .ok_or("manifest has no id")?
            .to_string();
        let version = manifest["version"]
            .as_str()
            .ok_or("manifest has no version")?
            .to_string();
        // Trust is verified before the review is offered: a signature
        // document must already verify here, and an unsigned package must be
        // community-installable, so the review cannot be offered for bytes
        // the host would refuse anyway.
        super::signature::verify_for_install(
            &snapshot,
            &plugin_id,
            &version,
            &manifest,
            super::signature::InstallOrigin::Community,
            None,
            &super::signature::trusted_keys(),
        )
        .map_err(|error| error.message())?;
        // The whole-package digest is frozen now: confirm and staging bind
        // the install to exactly these bytes.
        let frozen_digest =
            super::signature::content_digest(&snapshot).map_err(|error| error.message())?;
        let review = review_snapshot(&manifest, None)?;
        // Source facts live beside the snapshot, not inside it: every file
        // under the snapshot becomes an installed package file.
        std::fs::write(
            snapshot_source_path(temporary_root, session_id),
            serde_json::to_string(&SnapshotSource {
                file_name,
                archive_sha256,
                manifest_digest: manifest_replay_digest(&manifest),
                content_digest: frozen_digest,
                approved_programs: canonical_programs(&review.programs),
            })
            .map_err(|error| error.to_string())?,
        )
        .map_err(|error| error.to_string())?;
        Ok(PreparedInstall {
            session_id: session_id.to_string(),
            review,
            manifest_digest: manifest_replay_digest(&manifest),
            display_name: manifest["displayName"]
                .as_str()
                .unwrap_or("plugin")
                .to_string(),
        })
    })();
    if result.is_err() {
        discard_snapshot(&snapshot);
        discard_source_metadata(temporary_root, session_id);
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
    let install_root = store::install_root(&app)?;
    let snapshot = snapshot_path(&app, &session_id)?;
    let result = async {
        // The session identity is resolved once, inside the cleanup-guarded
        // block: a malformed session fails into the same release path as
        // everything else. This one value keys the real lifecycle barrier
        // and is passed to the orchestration as the expected identity, so
        // the pre-publish check compares against the barrier actually held.
        let session_plugin = session_plugin_id(&temporary_root, &session_id)?;
        // A version switch invalidates the page's package bytes and bridge
        // authorization, so destroy all owned webviews before staging starts.
        let mutation = super::lifecycle::begin(&app, &session_plugin).await?;
        // Inside the barrier: the session is re-verified and the install
        // record is read and built from the record state as it exists now,
        // so another mutation that committed during the drain is not
        // overwritten with a stale rollback chain.
        let confirmed = confirm_and_publish_in_barrier(
            &install_root,
            &temporary_root,
            &session_id,
            &manifest_digest,
            &snapshot,
            &session_plugin,
            &|| Ok(()),
        )?;
        rescan_after_change(&app)?;
        mutation.complete(true);
        Ok(catalog_entry_of(&app, &confirmed.plugin_id)
            .unwrap_or_else(|| accepted_entry_fallback(&confirmed.plugin_id, &confirmed.version)))
    }
    .await;
    // Every way out of the command - success, validation refusal, barrier
    // failure - releases the snapshot and the session record.
    discard_install_session(&temporary_root, &session_id, &snapshot);
    result
}

/// Cheap pre-barrier read of the session's plugin identity.
#[cfg(test)]
pub(crate) fn session_plugin_id_for_tests(
    temporary_root: &Path,
    session_id: &str,
) -> Result<String, String> {
    session_plugin_id(temporary_root, session_id)
}

fn session_plugin_id(temporary_root: &Path, session_id: &str) -> Result<String, String> {
    let snapshot = validated_session_path(temporary_root, session_id)?;
    let manifest = read_package_manifest(&snapshot)?;
    manifest["id"]
        .as_str()
        .map(str::to_string)
        .ok_or_else(|| "the install session has no plugin id".to_string())
}

/// Releases the snapshot directory and the session record of one review.
#[cfg(test)]
pub(crate) fn discard_install_session_for_tests(
    temporary_root: &Path,
    session_id: &str,
    snapshot: &Path,
) {
    discard_install_session(temporary_root, session_id, snapshot)
}

fn discard_install_session(temporary_root: &Path, session_id: &str, snapshot: &Path) {
    discard_snapshot(snapshot);
    discard_source_metadata(temporary_root, session_id);
}

/// Runs the barrier-guarded section of a disk-install confirm, the same
/// sequence the command drives. `expected_plugin_id` is the identity the
/// caller resolved when it took its real barrier — the command awaits
/// `lifecycle::begin` for exactly this ID and passes it here, so the check
/// below proves the published bytes belong to the plugin whose barrier is
/// actually held. The session is re-verified and the install record is read
/// and built from the record state as it exists now, the identity is
/// re-checked before anything is published, and only then are the staged
/// bytes published. `begin` is injected so tests drive the same sequence
/// without an AppHandle; the real command passes a no-op because its barrier
/// is already held. A failed section releases the snapshot and session
/// record: the session cannot be retried through this call.
pub(crate) fn confirm_and_publish_in_barrier(
    install_root: &Path,
    temporary_root: &Path,
    session_id: &str,
    manifest_digest: &str,
    snapshot: &Path,
    expected_plugin_id: &str,
    begin: &dyn Fn() -> Result<(), String>,
) -> Result<ConfirmedDiskInstall, String> {
    let result = (|| {
        begin()?;
        let confirmed = confirm_disk_install_snapshot(
            install_root,
            temporary_root,
            session_id,
            manifest_digest,
        )?;
        // The identity must still be the one the barrier was taken for:
        // publishing under another plugin's barrier would bypass its stop
        // guarantees, so this check happens before any bytes move. The
        // expected ID comes from the caller's own barrier acquisition, never
        // from a second read of the session.
        if confirmed.plugin_id != expected_plugin_id {
            return Err(format!(
                "the install session changed during confirmation; it now installs {} but the barrier was taken for {expected_plugin_id}",
                confirmed.plugin_id
            ));
        }
        publish_installed_version(
            install_root,
            &confirmed.plugin_id,
            &confirmed.version,
            snapshot,
            confirmed.record.clone(),
        )?;
        Ok(confirmed)
    })();
    if result.is_err() {
        discard_install_session(temporary_root, session_id, snapshot);
    }
    result
}

/// The outcome of a confirmed review: everything the publish transaction
/// needs, validated against the snapshot as it existed at confirm time.
#[derive(Debug)]
pub(crate) struct ConfirmedDiskInstall {
    pub plugin_id: String,
    pub version: String,
    pub record: InstallationRecord,
}

/// The testable core of the confirm command: re-review the snapshot, verify
/// its trust, and build the installation record. Publishing happens later,
/// behind the lifecycle barrier, from the same validated record.
pub(crate) fn confirm_disk_install_snapshot(
    install_root: &Path,
    temporary_root: &Path,
    session_id: &str,
    manifest_digest: &str,
) -> Result<ConfirmedDiskInstall, String> {
    let snapshot = validated_session_path(temporary_root, session_id)?;
    let source: SnapshotSource = serde_json::from_str(
        &std::fs::read_to_string(snapshot_source_path(temporary_root, session_id))
            .map_err(|error| format!("the install session has no source record: {error}"))?,
    )
    .map_err(|error| format!("the install session source record is unreadable: {error}"))?;
    let manifest = read_package_manifest(&snapshot)?;
    // The caller echoes the manifest digest it reviewed; the session record
    // freezes it independently, so a tampered caller cannot bless new bytes.
    if manifest_replay_digest(&manifest) != manifest_digest
        || manifest_replay_digest(&manifest) != source.manifest_digest
    {
        return Err("the package changed after review; the import was cancelled".to_string());
    }
    // The whole package must still be exactly the bytes prepare froze: any
    // replaced, added, or removed file is a rejection before anything runs.
    let package_digest =
        super::signature::content_digest(&snapshot).map_err(|error| error.message())?;
    if package_digest != source.content_digest {
        return Err("the package changed after review; the import was cancelled".to_string());
    }
    // Re-review with no previously approved programs: a disk install always
    // requires a fresh full confirmation, matching the macOS rule. Its
    // identity must still be the one the user saw at prepare.
    let review = review_snapshot(&manifest, None)?;
    if canonical_programs(&review.programs) != source.approved_programs {
        return Err(
            "the reviewed programs changed after the package was prepared; the import was \
             cancelled"
                .to_string(),
        );
    }
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
        None,
        &super::signature::trusted_keys(),
    )
    .map_err(|error| error.message())?;

    let existing = read_installation_record(install_root, &plugin_id);
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
            // The approved bytes are the ones prepare froze, re-checked above.
            content_digest: package_digest,
            approved_programs: source.approved_programs,
        }),
        previous_disk,
    };
    Ok(ConfirmedDiskInstall {
        plugin_id,
        version,
        record,
    })
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
    validated_session_path(&snapshot_root(&app)?, session_id)
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

/// Resolves and validates the snapshot directory of one review session.
fn validated_session_path(temporary_root: &Path, session_id: &str) -> Result<PathBuf, String> {
    if !session_id.starts_with(SNAPSHOT_PREFIX)
        || session_id.contains('/')
        || session_id.contains('\\')
        || session_id.contains("..")
    {
        return Err("invalid install session".to_string());
    }
    Ok(temporary_root.join(session_id))
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
    verify_rollback_candidate(
        &previous_directory,
        &plugin_id,
        &previous,
        previous_origin,
        record.previous_content_digest(),
    )?;
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
    publish_installed_version_with_backup_cleanup(
        install_root,
        plugin_id,
        version,
        source,
        record,
        &|path| std::fs::remove_dir_all(path),
    )
}

/// Uses the same publication transaction with a replaceable final cleanup
/// operation. Cleanup failure is deliberately non-fatal after the durable
/// record commits; injecting it lets tests retain the real backup without
/// relying on Windows file-attribute or antivirus timing behavior.
pub(crate) fn publish_installed_version_with_backup_cleanup(
    install_root: &Path,
    plugin_id: &str,
    version: &str,
    source: &Path,
    record: InstallationRecord,
    cleanup_backup: &dyn Fn(&Path) -> std::io::Result<()>,
) -> Result<(), String> {
    let plugin_directory = install_root.join(plugin_id);
    std::fs::create_dir_all(&plugin_directory).map_err(|error| error.to_string())?;
    // Leftover recovery backups of any version are judged before anything is
    // staged, directed by the durable record's approved digest.
    let stale_backups: Vec<PathBuf> = std::fs::read_dir(&plugin_directory)
        .map_err(|error| error.to_string())?
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path.is_dir()
                && path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .map(|name| name.ends_with(".previous-tmp"))
                    .unwrap_or(false)
        })
        .collect();
    for backup_directory in stale_backups {
        resolve_recovery_backup(install_root, plugin_id, &backup_directory)?;
    }
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
            None,
            &super::signature::trusted_keys(),
        )
        .map_err(|error| error.message())?;
        if let Some(expected) = record.active_content_digest() {
            let staged_digest = super::signature::content_digest(&staging_directory)
                .map_err(|error| error.message())?;
            if staged_digest != expected {
                return Err(super::signature::TrustError::ContentChanged.message());
            }
        }
        activate_staged_version_and_record(
            &staging_directory,
            &version_directory,
            install_root,
            version,
            &record,
            cleanup_backup,
        )
    })();
    if result.is_err() {
        let _ = std::fs::remove_dir_all(&staging_directory);
    }
    result
}

/// Replaces `version_directory` with the staged copy and commits the
/// installation record as one transaction. The record is staged to its temp
/// path before any version byte moves, so a record that cannot be written
/// fails while the old version is still intact; if the record commit fails
/// after the swap, the previous bytes are restored and both failures are
/// reported instead of leaving new bytes under the old record.
/// Judges a recovery backup left by an interrupted transaction, directed by
/// the durable installation record's approved digest: restore the backup
/// only when it provably holds the approved bytes, remove it only when the
/// approved bytes are provably intact elsewhere, and refuse an ambiguous
/// state with every byte kept. Restore failures are reported, never
/// swallowed.
fn resolve_recovery_backup(
    install_root: &Path,
    plugin_id: &str,
    backup_directory: &Path,
) -> Result<(), String> {
    let refuse = |message: String| -> Result<(), String> { Err(message) };
    let backup_version = backup_directory
        .file_name()
        .and_then(|name| name.to_str())
        .and_then(|name| name.strip_suffix(".previous-tmp"))
        .ok_or("a recovery backup without a version name")?
        .to_string();
    let durable = match read_installation_record(install_root, plugin_id) {
        Some(record) if record.schema_version == 2 => record,
        _ => {
            return refuse(
                "a recovery backup exists and the installation record cannot prove which bytes \
                 are approved; the backup and any interrupted bytes were kept"
                    .to_string(),
            );
        }
    };
    // A user-writable record cannot choose another plugin or a path outside
    // its version directory while recovery moves package bytes.
    let is_version_component = |value: &str| {
        !value.is_empty()
            && !matches!(value, "." | "..")
            && !value.contains(['/', '\\', ':'])
            && !value.ends_with(['.', ' '])
    };
    if durable.plugin_id != plugin_id
        || !is_version_component(&durable.version)
        || !is_version_component(&backup_version)
    {
        return refuse(
            "the recovery record does not name a valid version of this plugin; all bytes were kept"
                .to_string(),
        );
    }
    let backup_version_directory = install_root.join(plugin_id).join(&backup_version);
    let Some(approved_digest) = durable.active_content_digest() else {
        return refuse(
            "a recovery backup exists and the installation record carries no approved digest; \
             the backup and any interrupted bytes were kept"
                .to_string(),
        );
    };
    let backup_digest = super::signature::content_digest(backup_directory)
        .map_err(|error| format!("the recovery backup is unreadable: {}", error.message()))?;
    if durable.version == backup_version {
        let version_digest = if backup_version_directory.exists() {
            Some(
                super::signature::content_digest(&backup_version_directory).map_err(|error| {
                    format!("the interrupted version is unreadable: {}", error.message())
                })?,
            )
        } else {
            None
        };
        if version_digest.as_deref() == Some(approved_digest) {
            // The version directory already holds the approved bytes; the
            // backup is a stale leftover and safe to remove.
            std::fs::remove_dir_all(backup_directory).map_err(|error| {
                format!("a stale recovery backup could not be removed: {error}")
            })?;
            return Ok(());
        }
        if backup_digest == approved_digest {
            // Restore the approved bytes over the interrupted ones.
            if backup_version_directory.exists() {
                if let Err(error) = std::fs::remove_dir_all(&backup_version_directory) {
                    return refuse(format!(
                        "a recovery backup exists but the interrupted version could not be removed: {error}"
                    ));
                }
            }
            if let Err(error) = std::fs::rename(backup_directory, &backup_version_directory) {
                return refuse(format!(
                    "the recovery backup could not be restored: {error}"
                ));
            }
            return Ok(());
        }
        return refuse(format!(
            "an interrupted install left an ambiguous state: neither the version directory nor \
             its recovery backup matches the approved digest recorded in the installation \
             record; the backup at {} and any interrupted bytes were kept",
            backup_directory.display()
        ));
    }
    // The durable record approves a different version: this backup is an
    // orphan. It may only be cleared once the approved bytes are provably
    // intact in their own directory, and it is restored there instead when
    // it provably holds them.
    let approved_directory = install_root.join(&durable.plugin_id).join(&durable.version);
    let approved_digest_matches = approved_directory.exists()
        && super::signature::content_digest(&approved_directory)
            .map(|digest| digest == approved_digest)
            .unwrap_or(false);
    if !approved_digest_matches && backup_digest == approved_digest {
        // The approved bytes only exist in this backup: restore them to
        // their own directory before publishing another version.
        std::fs::rename(backup_directory, &approved_directory).map_err(|error| {
            format!(
                "the recovery backup could not be restored to {}: {error}",
                approved_directory.display()
            )
        })?;
    } else if !approved_digest_matches {
        return refuse(format!(
            "an interrupted install left an ambiguous state: the approved version {} is missing \
             or does not match its record digest, so the recovery backup cannot be judged; the \
             backup at {} was kept",
            durable.version,
            backup_directory.display()
        ));
    }
    if backup_directory.exists() {
        std::fs::remove_dir_all(backup_directory)
            .map_err(|error| format!("a stale recovery backup could not be removed: {error}"))?;
    }
    Ok(())
}

fn activate_staged_version_and_record(
    staging_directory: &Path,
    version_directory: &Path,
    install_root: &Path,
    version: &str,
    record: &InstallationRecord,
    cleanup_backup: &dyn Fn(&Path) -> std::io::Result<()>,
) -> Result<(), String> {
    let record_path = install_root
        .join(&record.plugin_id)
        .join("installation.json");
    let temp_path = record_path.with_extension("json.tmp");
    std::fs::write(
        &temp_path,
        serde_json::to_string_pretty(record).map_err(|error| error.to_string())?,
    )
    .map_err(|error| format!("could not stage the installation record: {error}"))?;
    // The backup carries the full version name: adjacent patch versions
    // (1.0.0 and 1.0.1) must never share one recovery path. Leftovers were
    // already resolved before staging; a backup appearing here would mean a
    // concurrent writer and is refused instead of deleted or restored.
    let plugin_directory = install_root.join(&record.plugin_id);
    let backup_directory = plugin_directory.join(format!("{version}.previous-tmp"));
    if backup_directory.exists() {
        let _ = std::fs::remove_file(&temp_path);
        return Err(format!(
            "a recovery backup for {version} appeared during the transaction; the state was kept"
        ));
    }
    if !version_directory.exists() {
        // First install: activate, then commit. No previous version exists,
        // so a failed commit removes the new bytes again.
        if let Err(activation_error) = std::fs::rename(staging_directory, version_directory) {
            let _ = std::fs::remove_file(&temp_path);
            return Err(format!("activation failed: {activation_error}"));
        }
        if let Err(record_error) = std::fs::rename(&temp_path, &record_path) {
            let removal_error = std::fs::remove_dir_all(version_directory).err();
            let _ = std::fs::remove_file(&temp_path);
            return Err(match removal_error {
                None => format!(
                    "could not write the installation record ({record_error}); the new version was removed"
                ),
                Some(removal_error) => format!(
                    "could not write the installation record ({record_error}) and the new version could not be removed ({removal_error}); the record still names no installed version"
                ),
            });
        }
        return Ok(());
    }
    // Replacing an existing version: move the current directory aside first
    // and keep it until the record has committed.
    if let Err(backup_error) = std::fs::rename(version_directory, &backup_directory) {
        let _ = std::fs::remove_file(&temp_path);
        return Err(format!(
            "could not back up the current version: {backup_error}"
        ));
    }
    if let Err(activation_error) = std::fs::rename(staging_directory, version_directory) {
        let restore_error = std::fs::rename(&backup_directory, version_directory).err();
        let _ = std::fs::remove_file(&temp_path);
        return Err(match restore_error {
            Some(restore_error) => format!(
                "activation failed ({activation_error}) and the previous version could not be restored ({restore_error})"
            ),
            None => format!("activation failed: {activation_error}"),
        });
    }
    if let Err(record_error) = std::fs::rename(&temp_path, &record_path) {
        // The old record still names the old version, so the old bytes must
        // come back; a failed restore is reported, never swallowed.
        let restore_result = (|| {
            std::fs::remove_dir_all(version_directory)?;
            std::fs::rename(&backup_directory, version_directory)?;
            Ok::<(), std::io::Error>(())
        })();
        let _ = std::fs::remove_file(&temp_path);
        return Err(match restore_result {
            Ok(()) => format!(
                "could not write the installation record ({record_error}); the previous version was restored"
            ),
            Err(restore_error) => format!(
                "could not write the installation record ({record_error}) and the previous version could not be restored ({restore_error}); the recovery backup at {} was kept for the next attempt",
                backup_directory.display()
            ),
        });
    }
    // Transaction committed: the backup is best-effort cleanup from here.
    let _ = cleanup_backup(&backup_directory);
    Ok(())
}

/// Verifies a rollback candidate the way it was originally installed: the
/// restored package must match its record, validate, and satisfy the trust
/// policy with its own provenance. The candidate lives in the install root,
/// so a bundled claim can never be honored here.
pub(crate) fn verify_rollback_candidate(
    previous_directory: &Path,
    plugin_id: &str,
    previous_version: &str,
    origin: super::signature::InstallOrigin,
    expected_content_digest: Option<&str>,
) -> Result<(), String> {
    let manifest = read_package_manifest(previous_directory)?;
    if manifest["id"].as_str() != Some(plugin_id)
        || manifest["version"].as_str() != Some(previous_version)
    {
        return Err("the previous package does not match its installation record".to_string());
    }
    validate_manifest(&manifest).map_err(|rejection| rejection.message)?;
    super::signature::verify_for_origin(
        previous_directory,
        plugin_id,
        previous_version,
        &manifest,
        origin,
        expected_content_digest,
        None,
        &super::signature::trusted_keys(),
    )
    .map_err(|error| error.message())
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

fn manifest_replay_digest(manifest: &serde_json::Value) -> String {
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
