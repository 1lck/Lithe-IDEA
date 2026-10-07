//! Signed worker resource installation in platform-owned writable directories.
//! Installed application resources are read-only; package payloads are verified
//! before staging and on launch, and replacement is an atomic directory rename.

use lithe_core::plugins::{bundle, worker, PluginVersion};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use tauri::{AppHandle, Manager};

fn lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(Mutex::default)
}
fn error(error: impl std::fmt::Display) -> String {
    error.to_string()
}

fn roots(app: &AppHandle) -> Result<(PathBuf, PathBuf), String> {
    let installed = app
        .path()
        .app_data_dir()
        .map_err(error)?
        .join("worker-plugins");
    Ok((installed.clone(), installed.join(".staging")))
}

fn identity(id: &str, version: &str) -> Result<(), String> {
    if id.len() > 128
        || !id.contains('.')
        || !id
            .bytes()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || b".-".contains(&c))
        || id.starts_with('.')
        || id.ends_with('.')
        || PluginVersion::parse(version).is_none()
    {
        return Err("Invalid plugin identity or version".into());
    }
    Ok(())
}

fn staging_identity(id: &str) -> Result<(), String> {
    if id.len() != 36 || !id.bytes().all(|c| c.is_ascii_hexdigit() || c == b'-') {
        return Err("Invalid staging identity".into());
    }
    Ok(())
}

fn reject_links(path: &Path) -> Result<(), String> {
    for ancestor in path.ancestors() {
        let metadata = fs::symlink_metadata(ancestor).map_err(error)?;
        if metadata.file_type().is_symlink() {
            return Err("Plugin storage must not contain links".into());
        }
        #[cfg(windows)]
        {
            use std::os::windows::fs::MetadataExt;
            if metadata.file_attributes() & 0x400 != 0 {
                return Err("Plugin storage must not contain reparse points".into());
            }
        }
    }
    Ok(())
}

fn read_bounded(path: &Path, limit: usize) -> Result<Vec<u8>, String> {
    reject_links(path)?;
    let file = fs::File::open(path).map_err(error)?;
    if !file.metadata().map_err(error)?.is_file() {
        return Err("Plugin resource is not a regular file".into());
    }
    let mut bytes = Vec::new();
    file.take(limit as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(error)?;
    if bytes.len() > limit {
        return Err("Plugin resource exceeds its size limit".into());
    }
    Ok(bytes)
}

fn verify_inventory(
    payload: &Path,
    expected: &std::collections::BTreeMap<String, String>,
) -> Result<(), String> {
    let mut directories = vec![payload.to_path_buf()];
    let mut found = std::collections::BTreeSet::new();
    let mut entries = 0usize;
    while let Some(directory) = directories.pop() {
        reject_links(&directory)?;
        for item in fs::read_dir(&directory).map_err(error)? {
            let item = item.map_err(error)?;
            entries += 1;
            if entries > 16_384 {
                return Err("Plugin resource inventory is too large".into());
            }
            reject_links(&item.path())?;
            if item.file_type().map_err(error)?.is_dir() {
                directories.push(item.path());
            } else {
                let relative = item
                    .path()
                    .strip_prefix(payload)
                    .map_err(error)?
                    .to_string_lossy()
                    .replace('\\', "/");
                if !expected.contains_key(&relative) {
                    return Err("Unsigned plugin resource found".into());
                }
                found.insert(relative);
            }
        }
    }
    if found.len() != expected.len() {
        return Err("Signed plugin resource is missing".into());
    }
    Ok(())
}

fn checked_package(directory: &Path) -> Result<Value, String> {
    let receipt = String::from_utf8(read_bounded(
        &directory.join("receipt.json"),
        worker::MAX_WORKER_PACKAGE_BYTES,
    )?)
    .map_err(error)?;
    let package = worker::validate_package(&receipt).map_err(|error| error.message)?;
    let manifest: Value = serde_json::from_str(
        package["nativePackage"]["manifestJSON"]
            .as_str()
            .ok_or("Missing signed manifest")?,
    )
    .map_err(error)?;
    let expected_target = format!("windows-{}", std::env::consts::ARCH);
    if manifest["nativeTarget"] != expected_target {
        return Err("Plugin package targets a different processor architecture".into());
    }
    let document: bundle::PackageSignature =
        serde_json::from_value(package["nativePackage"]["signature"].clone()).map_err(error)?;
    let payload = directory.join("payload");
    verify_inventory(&payload, &document.files)?;
    let mut remaining = bundle::MAX_BUNDLE_BYTES;
    for (relative, expected) in document.files {
        let bytes = read_bounded(&payload.join(relative), remaining)?;
        remaining -= bytes.len();
        if format!("{:x}", Sha256::digest(bytes)) != expected {
            return Err(
                "Plugin resource changed after installation; import the signed package again"
                    .into(),
            );
        }
    }
    Ok(package)
}

fn checked_version(directory: &Path, plugin_id: &str, version: &str) -> Result<Value, String> {
    let package = checked_package(directory)?;
    if package["manifest"]["id"] != plugin_id || package["manifest"]["version"] != version {
        return Err(
            "Installed resource identity does not match the requested plugin version".into(),
        );
    }
    Ok(package)
}

/// Staging has no effect on an active version. Failed writes remove their owned
/// temporary directory; the caller commits only after Core accepts beginInstall.
#[tauri::command]
pub async fn stage_worker_resources(
    app: AppHandle,
    text: String,
    staging_id: String,
) -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(move || {
        staging_identity(&staging_id)?;
        let verified = bundle::verify_bundle(&text).map_err(|error| error.message)?;
        let (_, staging_root) = roots(&app)?;
        fs::create_dir_all(&staging_root).map_err(error)?;
        reject_links(&staging_root)?;
        let directory = staging_root.join(&staging_id);
        fs::create_dir(&directory).map_err(error)?;
        let outcome = (|| {
            for (relative, bytes) in verified.files {
                let destination = directory.join("payload").join(relative);
                fs::create_dir_all(destination.parent().ok_or("Missing resource parent")?)
                    .map_err(error)?;
                let mut file = OpenOptions::new()
                    .create_new(true)
                    .write(true)
                    .open(destination)
                    .map_err(error)?;
                file.write_all(&bytes).map_err(error)?;
            }
            fs::write(
                directory.join("receipt.json"),
                serde_json::to_vec(&verified.package).map_err(error)?,
            )
            .map_err(error)?;
            let mut package = checked_package(&directory)?;
            package["nativePackage"]["stagingId"] = json!(staging_id);
            Ok(package)
        })();
        if outcome.is_err() {
            if let Err(cleanup) = fs::remove_dir_all(&directory) {
                eprintln!("Could not clean plugin staging directory: {cleanup}");
            }
        }
        outcome
    })
    .await
    .map_err(error)?
}

#[tauri::command]
pub async fn install_worker_resources(
    app: AppHandle,
    plugin_id: String,
    version: String,
    staging_id: Option<String>,
) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || {
        identity(&plugin_id, &version)?;
        let _guard = lock().lock().map_err(error)?;
        let (installed, staging_root) = roots(&app)?;
        let destination = installed.join(&plugin_id).join(&version);
        let Some(staging_id) = staging_id else {
            checked_version(&destination, &plugin_id, &version)?;
            return Ok(());
        };
        staging_identity(&staging_id)?;
        let staged = staging_root.join(&staging_id);
        let package = checked_package(&staged)?;
        if package["manifest"]["id"] != plugin_id || package["manifest"]["version"] != version {
            return Err("Staged package identity does not match installation".into());
        }
        fs::create_dir_all(destination.parent().ok_or("Missing plugin parent")?).map_err(error)?;
        // A signed version is immutable. Reinstalling identical bytes is safe;
        // different bytes require a new version so rollback can retain the old one.
        if destination.exists() {
            reject_links(&destination)?;
            let previous = read_bounded(
                &destination.join("receipt.json"),
                worker::MAX_WORKER_PACKAGE_BYTES,
            )
            .ok()
            .and_then(|bytes| String::from_utf8(bytes).ok())
            .and_then(|text| worker::validate_package(&text).ok());
            if previous.as_ref().is_some_and(|previous| {
                previous["nativePackage"]["signature"] != package["nativePackage"]["signature"]
            }) {
                return Err(
                    "A different package already uses this version; import a new version".into(),
                );
            }
            if checked_version(&destination, &plugin_id, &version).is_ok() {
                fs::remove_dir_all(&staged).map_err(error)?;
                return Ok(());
            }
            // Reimporting authenticated bytes repairs a corrupt installation.
            // Keep the old directory until same-volume publication succeeds.
            let backup = staging_root.join(format!("repair-{staging_id}"));
            fs::rename(&destination, &backup).map_err(error)?;
            if let Err(failure) = fs::rename(&staged, &destination) {
                fs::rename(&backup, &destination).map_err(error)?;
                return Err(error(failure));
            }
            if let Err(cleanup) = fs::remove_dir_all(backup) {
                eprintln!("Could not remove repaired plugin backup: {cleanup}");
            }
        } else {
            reject_links(destination.parent().ok_or("Missing plugin parent")?)?;
            fs::rename(&staged, &destination).map_err(error)?;
        }
        Ok(())
    })
    .await
    .map_err(error)?
}

/// Returns argv from the signed manifest; caller-supplied launch paths and
/// arguments never change the native code authorized by the publisher.
#[tauri::command]
pub async fn resolve_worker_resources(
    app: AppHandle,
    plugin_id: String,
    version: String,
) -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(move || {
        identity(&plugin_id, &version)?;
        let _guard = lock().lock().map_err(error)?;
        let (installed, _) = roots(&app)?;
        let directory = installed.join(&plugin_id).join(&version);
        let package = checked_version(&directory, &plugin_id, &version)?;
        let lsp = &package["manifest"]["lsp"];
        let entry = directory.join("payload").join(
            lsp["server"]["default"]
                .as_str()
                .ok_or("Missing packaged entrypoint")?,
        );
        let mut arguments: Vec<String> =
            serde_json::from_value(lsp["args"].clone()).map_err(error)?;
        let executable = if lsp["runtimeExecutable"] == "node" {
            let node = crate::language_tools::find_system_tool(
                std::env::var_os("PATH").as_deref(),
                "node",
            )
            .ok_or("Node.js is required by this plugin. Install Node.js and retry.")?;
            arguments.insert(0, entry.to_string_lossy().into_owned());
            node
        } else {
            entry
        };
        Ok(json!({"serverPath":executable.to_string_lossy(),"serverArgs":arguments}))
    })
    .await
    .map_err(error)?
}

#[tauri::command]
pub async fn remove_worker_resources(
    app: AppHandle,
    plugin_id: String,
    version: String,
    staging_id: Option<String>,
    all_versions: Option<bool>,
) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || {
        identity(&plugin_id, &version)?;
        let _guard = lock().lock().map_err(error)?;
        let (installed, staging) = roots(&app)?;
        let directory = if all_versions == Some(true) {
            installed.join(plugin_id)
        } else {
            installed.join(plugin_id).join(version)
        };
        if directory.exists() {
            reject_links(&directory)?;
            fs::remove_dir_all(directory).map_err(error)?;
        }
        if let Some(id) = staging_id {
            staging_identity(&id)?;
            let directory = staging.join(id);
            if directory.exists() {
                reject_links(&directory)?;
                fs::remove_dir_all(directory).map_err(error)?;
            }
        }
        Ok(())
    })
    .await
    .map_err(error)?
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;
    use std::sync::atomic::{AtomicU64, Ordering};

    struct OwnedDirectory(PathBuf);
    impl OwnedDirectory {
        fn new() -> Self {
            static NEXT: AtomicU64 = AtomicU64::new(0);
            let path = std::env::temp_dir().join(format!(
                "lithe-plugin-inventory-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for OwnedDirectory {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }

    #[test]
    fn installed_inventory_rejects_missing_and_unsigned_resources() {
        let directory = OwnedDirectory::new();
        fs::create_dir(directory.0.join("bin")).unwrap();
        fs::write(directory.0.join("bin/server.exe"), b"signed server").unwrap();
        let expected =
            BTreeMap::from([("bin/server.exe".into(), "hash checked separately".into())]);
        assert!(verify_inventory(&directory.0, &expected).is_ok());
        // An unsigned sibling can change native DLL or JavaScript resolution.
        fs::write(directory.0.join("bin/unsigned.dll"), b"unexpected").unwrap();
        assert_eq!(
            verify_inventory(&directory.0, &expected).unwrap_err(),
            "Unsigned plugin resource found"
        );
        fs::remove_file(directory.0.join("bin/unsigned.dll")).unwrap();
        fs::remove_file(directory.0.join("bin/server.exe")).unwrap();
        assert_eq!(
            verify_inventory(&directory.0, &expected).unwrap_err(),
            "Signed plugin resource is missing"
        );
    }

    #[test]
    fn resource_reads_enforce_limit_and_regular_files() {
        let directory = OwnedDirectory::new();
        let file = directory.0.join("resource");
        fs::write(&file, b"1234").unwrap();
        assert_eq!(read_bounded(&file, 4).unwrap(), b"1234");
        assert!(read_bounded(&file, 3).is_err());
        assert!(read_bounded(&directory.0, 4).is_err());
    }
}

#[tauri::command]
pub async fn discard_worker_staging(app: AppHandle, staging_id: String) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || {
        staging_identity(&staging_id)?;
        let (_, staging) = roots(&app)?;
        let directory = staging.join(staging_id);
        if directory.exists() {
            reject_links(&directory)?;
            fs::remove_dir_all(directory).map_err(error)?;
        }
        Ok(())
    })
    .await
    .map_err(error)?
}
