//! Writable Equinox configuration areas for packaged JDT LS installations.
//!
//! Equinox writes its framework state (bundle caches, resolver state, locks,
//! and p2 data) into the directory passed as `-configuration`. Packaged JDT LS
//! ships its `config_<platform>` directory inside the installed product: the
//! signed macOS app bundle, whose exact bytes are the base of Sparkle delta
//! updates, and the Windows installation directory. Handing that directory to
//! Equinox turns every launch into a modification of the release.
//!
//! As vscode-java does, the only shipped input, `config.ini`, is copied into
//! the host cache under a directory named by the file's SHA-256. The file lists
//! every bundle with its version, so a JDT LS upgrade receives a fresh area
//! instead of reusing framework state recorded for other bundles, and Equinox
//! never reads or writes the installation's configuration directory.

use super::java_workspace::{jdt_cache_retention, JdtCacheEntry, JdtCacheRetentionRequest};
use crate::protocol::{CoreError, ErrorCode};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

/// Cache subdirectory holding one configuration area per `config.ini` digest.
///
/// It is a sibling of the `-data` directories under `jdtls/` so that the
/// workspace retention adapters, which scan `jdtls/`, never treat an area in
/// use by another installation as an expired workspace.
pub(crate) const CONFIGURATION_AREAS_DIRECTORY: &str = "jdtls-configuration";
/// The only file JDT LS ships in a platform configuration directory.
const CONFIG_INI: &str = "config.ini";
/// Directory passed as `-configuration`, one level below the area root because
/// JDT LS's `config.ini` sets `eclipse.p2.data.area=@config.dir/../p2`, which
/// must resolve inside the same area.
const EQUINOX_CONFIGURATION_DIRECTORY: &str = "configuration";
/// File in an area root recording the last launch that used it, as Unix seconds.
const LAST_USED_MARKER: &str = ".lithe-last-used";

static NEXT_TEMPORARY_FILE: AtomicU64 = AtomicU64::new(0);

/// Configuration area selected for one JDT LS launch.
#[derive(Debug, Eq, PartialEq)]
pub(crate) struct PreparedConfigurationArea {
    /// Writable directory passed to JDT LS as `-configuration`.
    pub directory: PathBuf,
    /// Digests of other areas removed because no launch used them within the
    /// shared JDT cache retention period, in ascending order.
    pub removed_keys: Vec<String>,
    /// Why expired areas could not be removed. Only disk space is at stake,
    /// so the launch proceeds and the engine reports this as a warning.
    pub cleanup_failure: Option<String>,
}

/// Returns the writable configuration area for the packaged configuration
/// directory `packaged_configuration`, creating or repairing it as needed.
///
/// The area lives under `cache_directory`, which must resolve outside the JDT
/// LS installation; a cache inside it, including through a symbolic link, is
/// rejected before anything is written. Areas of other `config.ini` digests
/// that no launch used within the retention period are removed afterwards.
pub(crate) fn prepare_configuration_area(
    cache_directory: &Path,
    packaged_configuration: &Path,
    now_unix_seconds: u64,
) -> Result<PreparedConfigurationArea, CoreError> {
    let packaged_configuration = fs::canonicalize(packaged_configuration).map_err(|error| {
        start_failure("The Java language-server configuration directory is unavailable.")
            .with_details(error.to_string())
    })?;
    let installation_root = packaged_configuration
        .parent()
        .unwrap_or(&packaged_configuration)
        .to_path_buf();
    let config_ini = fs::read(packaged_configuration.join(CONFIG_INI)).map_err(|error| {
        start_failure("The Java language-server configuration has no config.ini.")
            .with_details(error.to_string())
    })?;
    let key = format!("{:x}", Sha256::digest(&config_ini));
    let areas_root = cache_directory.join(CONFIGURATION_AREAS_DIRECTORY);
    let area_root = areas_root.join(&key);
    let directory = area_root.join(EQUINOX_CONFIGURATION_DIRECTORY);

    // Resolve through the deepest existing ancestor so that a symbolic link
    // anywhere in the cache path is followed before the first write.
    ensure_outside_installation(&directory, &installation_root)?;
    fs::create_dir_all(&directory).map_err(|error| {
        start_failure("Could not create the Java language-server configuration area.")
            .with_details(error.to_string())
    })?;
    ensure_outside_installation(&directory, &installation_root)?;
    write_if_changed(&directory.join(CONFIG_INI), &config_ini)?;
    fs::write(
        area_root.join(LAST_USED_MARKER),
        now_unix_seconds.to_string(),
    )
    .map_err(|error| {
        start_failure("Could not record the Java language-server configuration area use.")
            .with_details(error.to_string())
    })?;

    let (removed_keys, cleanup_failure) = remove_expired_areas(&areas_root, &key, now_unix_seconds);
    Ok(PreparedConfigurationArea {
        directory,
        removed_keys,
        cleanup_failure,
    })
}

fn start_failure(message: &str) -> CoreError {
    CoreError::new(ErrorCode::ProcessStartFailed, message)
}

fn ensure_outside_installation(path: &Path, installation_root: &Path) -> Result<(), CoreError> {
    let resolved = resolve_existing_prefix(path).map_err(|error| {
        start_failure("Could not resolve the Java language-server cache directory.")
            .with_details(error.to_string())
    })?;
    if resolved.starts_with(installation_root) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "The Java language-server cache must be outside the JDT LS installation.",
        ));
    }
    Ok(())
}

/// Canonicalizes the deepest existing ancestor of `path` and appends the
/// components that do not exist yet, which cannot be symbolic links.
fn resolve_existing_prefix(path: &Path) -> std::io::Result<PathBuf> {
    let mut missing = Vec::new();
    let mut current = path;
    loop {
        match fs::canonicalize(current) {
            Ok(resolved) => {
                return Ok(missing
                    .iter()
                    .rev()
                    .fold(resolved, |resolved, component| resolved.join(component)))
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                let (Some(parent), Some(name)) = (current.parent(), current.file_name()) else {
                    return Err(error);
                };
                missing.push(name.to_os_string());
                current = parent;
            }
            Err(error) => return Err(error),
        }
    }
}

/// Replaces `path` atomically unless it already holds `contents`, so a damaged
/// or truncated copy is repaired and concurrent launches never observe a
/// partially written file.
fn write_if_changed(path: &Path, contents: &[u8]) -> Result<(), CoreError> {
    if fs::read(path).is_ok_and(|current| current == contents) {
        return Ok(());
    }
    let temporary = path.with_file_name(format!(
        ".{CONFIG_INI}.{}-{}.tmp",
        std::process::id(),
        NEXT_TEMPORARY_FILE.fetch_add(1, Ordering::Relaxed)
    ));
    let result = fs::write(&temporary, contents).and_then(|()| fs::rename(&temporary, path));
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result.map_err(|error| {
        start_failure("Could not write the Java language-server configuration.")
            .with_details(error.to_string())
    })
}

fn remove_expired_areas(
    areas_root: &Path,
    active_key: &str,
    now_unix_seconds: u64,
) -> (Vec<String>, Option<String>) {
    let entries = match fs::read_dir(areas_root) {
        Ok(entries) => entries,
        Err(error) => return (Vec::new(), Some(error.to_string())),
    };
    let mut candidates = Vec::new();
    for entry in entries.flatten() {
        let Ok(metadata) = fs::symlink_metadata(entry.path()) else {
            continue;
        };
        // A link is never followed: removing through it could delete data
        // that does not belong to the cache.
        if !metadata.is_dir() {
            continue;
        }
        let Some(key) = entry.file_name().to_str().map(str::to_string) else {
            continue;
        };
        let last_used = fs::read_to_string(entry.path().join(LAST_USED_MARKER))
            .ok()
            .and_then(|marker| marker.trim().parse::<u64>().ok())
            .or_else(|| {
                metadata
                    .modified()
                    .ok()
                    .and_then(|modified| modified.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|elapsed| elapsed.as_secs())
            })
            .unwrap_or(0);
        candidates.push(JdtCacheEntry {
            workspace_key: key,
            last_modified_unix_seconds: last_used,
        });
    }
    // The workspace retention policy only accepts SHA-256 names and never
    // selects the active one, which are exactly the rules for areas too.
    let plan = match jdt_cache_retention(JdtCacheRetentionRequest {
        now_unix_seconds,
        active_workspace_key: Some(active_key.to_string()),
        entries: candidates,
    }) {
        Ok(plan) => plan,
        Err(error) => return (Vec::new(), Some(error.message)),
    };
    let mut removed = Vec::new();
    let mut failures = Vec::new();
    for key in plan.expired_workspace_keys {
        match fs::remove_dir_all(areas_root.join(&key)) {
            Ok(()) => removed.push(key),
            Err(error) => failures.push(format!("{key}: {error}")),
        }
    }
    let failure = (!failures.is_empty()).then(|| failures.join("; "));
    (removed, failure)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    static NEXT_SCRATCH: AtomicU64 = AtomicU64::new(0);
    const DAY: u64 = 24 * 60 * 60;
    const NOW: u64 = 1_800_000_000;
    const CONFIG: &[u8] =
        b"osgi.bundles=reference\\:file\\:org.eclipse.jdt.ls.core_1.61.0.jar@4\\:start\n";

    /// A packaged JDT LS installation and a separate host cache, removed on
    /// drop so a failed assertion does not leak them.
    struct Scratch {
        root: PathBuf,
    }

    impl Scratch {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "lithe-jdt-configuration-{}-{}",
                std::process::id(),
                NEXT_SCRATCH.fetch_add(1, Ordering::Relaxed)
            ));
            let _ = fs::remove_dir_all(&root);
            let configuration = root.join("installation/jdtls/config_mac");
            fs::create_dir_all(&configuration).expect("configuration should be created");
            fs::write(configuration.join(CONFIG_INI), CONFIG)
                .expect("config.ini should be written");
            fs::create_dir_all(root.join("installation/jdtls/plugins")).expect("plugins");
            fs::write(root.join("installation/jdtls/plugins/equinox.jar"), b"jar").expect("jar");
            Self { root }
        }

        fn installation(&self) -> PathBuf {
            self.root.join("installation")
        }

        fn packaged_configuration(&self) -> PathBuf {
            self.installation().join("jdtls/config_mac")
        }

        fn cache(&self) -> PathBuf {
            self.root.join("cache")
        }

        fn prepare(&self, now: u64) -> Result<PreparedConfigurationArea, CoreError> {
            prepare_configuration_area(&self.cache(), &self.packaged_configuration(), now)
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    /// Relative path and contents of every file below `root`.
    fn snapshot(root: &Path) -> BTreeMap<PathBuf, Vec<u8>> {
        let mut files = BTreeMap::new();
        let mut pending = vec![root.to_path_buf()];
        while let Some(directory) = pending.pop() {
            for entry in fs::read_dir(&directory).expect("directory should be readable") {
                let path = entry.expect("entry should be readable").path();
                if path.is_dir() {
                    pending.push(path);
                } else {
                    let contents = fs::read(&path).expect("file should be readable");
                    files.insert(path.strip_prefix(root).unwrap().to_path_buf(), contents);
                }
            }
        }
        files
    }

    fn key() -> String {
        format!("{:x}", Sha256::digest(CONFIG))
    }

    #[test]
    fn equinox_state_lands_in_the_cache_and_the_installation_stays_byte_identical() {
        let scratch = Scratch::new();
        let before = snapshot(&scratch.installation());

        let area = scratch.prepare(NOW).expect("the area should be prepared");
        // Equinox writes its framework state into the -configuration directory.
        fs::create_dir_all(area.directory.join("org.eclipse.osgi")).expect("state directory");
        fs::write(area.directory.join("org.eclipse.osgi/.manager"), b"lock").expect("state");

        assert_eq!(
            area.directory,
            scratch
                .cache()
                .join(CONFIGURATION_AREAS_DIRECTORY)
                .join(key())
                .join(EQUINOX_CONFIGURATION_DIRECTORY)
        );
        assert_eq!(fs::read(area.directory.join(CONFIG_INI)).unwrap(), CONFIG);
        assert_eq!(snapshot(&scratch.installation()), before);
    }

    #[test]
    fn a_damaged_copy_is_repaired_and_equinox_state_is_kept() {
        let scratch = Scratch::new();
        let first = scratch.prepare(NOW).expect("the area should be prepared");
        fs::create_dir_all(first.directory.join("org.eclipse.osgi")).expect("state directory");
        fs::write(first.directory.join(CONFIG_INI), b"truncat").expect("damage");

        let second = scratch
            .prepare(NOW)
            .expect("a damaged copy should be repaired");
        assert_eq!(second.directory, first.directory);
        assert_eq!(fs::read(second.directory.join(CONFIG_INI)).unwrap(), CONFIG);
        assert!(second.directory.join("org.eclipse.osgi").is_dir());

        fs::remove_file(second.directory.join(CONFIG_INI)).expect("delete the copy");
        let third = scratch
            .prepare(NOW)
            .expect("a missing copy should be restored");
        assert_eq!(fs::read(third.directory.join(CONFIG_INI)).unwrap(), CONFIG);
    }

    #[test]
    fn a_new_config_ini_selects_a_fresh_area() {
        let scratch = Scratch::new();
        let first = scratch.prepare(NOW).expect("the area should be prepared");
        fs::write(
            scratch.packaged_configuration().join(CONFIG_INI),
            b"osgi.bundles=reference\\:file\\:org.eclipse.jdt.ls.core_1.62.0.jar@4\\:start\n",
        )
        .expect("upgrade");

        let upgraded = scratch
            .prepare(NOW)
            .expect("the upgraded area should be prepared");
        assert_ne!(upgraded.directory, first.directory);
        assert!(first.directory.is_dir(), "a recently used area is retained");
    }

    #[test]
    fn a_cache_inside_the_installation_is_rejected_before_anything_is_written() {
        let scratch = Scratch::new();
        let before = snapshot(&scratch.installation());

        let error = prepare_configuration_area(
            &scratch.installation().join("jdtls/cache"),
            &scratch.packaged_configuration(),
            NOW,
        )
        .expect_err("a cache inside the installation must be rejected");

        assert!(matches!(error.code, ErrorCode::InvalidRequest));
        assert_eq!(snapshot(&scratch.installation()), before);
        assert!(!scratch.installation().join("jdtls/cache").exists());
    }

    #[cfg(unix)]
    #[test]
    fn a_cache_linked_into_the_installation_is_rejected_before_anything_is_written() {
        let scratch = Scratch::new();
        let before = snapshot(&scratch.installation());
        fs::create_dir_all(scratch.cache()).expect("cache");
        std::os::unix::fs::symlink(
            scratch.installation().join("jdtls"),
            scratch.cache().join(CONFIGURATION_AREAS_DIRECTORY),
        )
        .expect("link");

        let error = scratch
            .prepare(NOW)
            .expect_err("a cache linked into the installation must be rejected");

        assert!(matches!(error.code, ErrorCode::InvalidRequest));
        assert_eq!(snapshot(&scratch.installation()), before);
    }

    #[test]
    fn a_missing_config_ini_fails_the_start() {
        let scratch = Scratch::new();
        fs::remove_file(scratch.packaged_configuration().join(CONFIG_INI)).expect("remove");

        let error = scratch.prepare(NOW).expect_err("config.ini is required");

        assert!(matches!(error.code, ErrorCode::ProcessStartFailed));
        assert!(!scratch.cache().exists());
    }

    #[test]
    fn areas_unused_for_the_retention_period_are_removed() {
        let scratch = Scratch::new();
        let areas = scratch.cache().join(CONFIGURATION_AREAS_DIRECTORY);
        let expired = "a".repeat(64);
        let recent = "b".repeat(64);
        for (name, last_used) in [(&expired, NOW - 31 * DAY), (&recent, NOW - 29 * DAY)] {
            fs::create_dir_all(areas.join(name).join(EQUINOX_CONFIGURATION_DIRECTORY))
                .expect("area");
            fs::write(
                areas.join(name).join(LAST_USED_MARKER),
                last_used.to_string(),
            )
            .expect("marker");
        }
        // A directory that is not an area is never removed.
        fs::create_dir_all(areas.join("p2")).expect("foreign directory");

        let area = scratch.prepare(NOW).expect("the area should be prepared");

        assert_eq!(area.removed_keys, vec![expired.clone()]);
        assert_eq!(area.cleanup_failure, None);
        assert!(!areas.join(&expired).exists());
        assert!(areas.join(&recent).is_dir());
        assert!(areas.join("p2").is_dir());
        assert_eq!(
            fs::read_to_string(areas.join(key()).join(LAST_USED_MARKER)).unwrap(),
            NOW.to_string()
        );
    }
}
