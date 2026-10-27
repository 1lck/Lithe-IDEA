//! Guarded host-owned plugin preferences. These are the exact layers Core
//! consumes, never a copy of a tool's native configuration or a secret store.
use super::*;
use serde::Serialize;
use serde_json::json;
use sha2::{Digest, Sha256};
use std::sync::Mutex;

static WRITES: Mutex<()> = Mutex::new(());

#[derive(Clone)]
struct Store {
    values: Map<String, Value>,
    identity: Option<String>,
}

fn plain_source(path: &Path, writing: bool) -> Result<(), String> {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) => {
            #[cfg(windows)]
            {
                use std::os::windows::fs::MetadataExt;
                if metadata.file_attributes() & 0x400 != 0 {
                    return Err("plugin.settings.readOnlySource".into());
                }
            }
            if metadata.file_type().is_symlink() || (writing && metadata.permissions().readonly()) {
                return Err("plugin.settings.readOnlySource".into());
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(_) => return Err("plugin.settings.readFailed".into()),
    }
    Ok(())
}

fn read_store(path: &Path) -> Result<Store, String> {
    read_store_limited(path, None)
}
fn read_store_limited(path: &Path, limit: Option<u64>) -> Result<Store, String> {
    if let Some(parent) = path.parent() {
        plain_source(parent, false)?;
        match std::fs::read_dir(parent) {
            Ok(entries) => {
                let prefix = format!(
                    "{}.",
                    path.file_name()
                        .ok_or("plugin.settings.readFailed")?
                        .to_string_lossy()
                );
                for entry in entries {
                    let name = entry.map_err(|_| "plugin.settings.readFailed")?.file_name();
                    let name = name.to_string_lossy();
                    let recovery = name
                        .strip_prefix(&prefix)
                        .and_then(|name| name.strip_suffix(".backup"));
                    if recovery.and_then(|name| name.split_once('-')).is_some_and(
                        |(process, sequence)| {
                            !process.is_empty()
                                && !sequence.is_empty()
                                && process.bytes().all(|byte| byte.is_ascii_digit())
                                && sequence.bytes().all(|byte| byte.is_ascii_digit())
                        },
                    ) {
                        return Err("plugin.settings.recoveryRequired".into());
                    }
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err("plugin.settings.readFailed".into()),
        }
    }
    plain_source(path, false)?;
    let bytes = (|| {
        use std::io::Read;
        let mut bytes = Vec::new();
        let mut source = std::fs::File::open(path)?;
        if let Some(limit) = limit {
            source.take(limit + 1).read_to_end(&mut bytes)?;
        } else {
            source.read_to_end(&mut bytes)?;
        }
        if limit.is_some_and(|limit| bytes.len() as u64 > limit) {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "JSON store limit",
            ));
        }
        Ok(bytes)
    })();
    match bytes {
        Ok(bytes) => {
            let values = serde_json::from_slice::<Value>(&bytes)
                .map_err(|_| "plugin.settings.corruptStore")?
                .as_object()
                .cloned()
                .ok_or("plugin.settings.corruptStore")?;
            Ok(Store {
                values,
                identity: Some(format!("{:x}", Sha256::digest(bytes))),
            })
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Store {
            values: Map::new(),
            identity: None,
        }),
        Err(_) => Err("plugin.settings.readFailed".into()),
    }
}

pub(super) fn read_values(path: &Path) -> Result<Map<String, Value>, String> {
    read_store(path).map(|store| store.values)
}

/// Host-owned JSON consumers share the same conflict, ACL and recovery boundary.
pub(crate) fn read_object_snapshot(
    path: &Path,
    limit: u64,
) -> Result<(Map<String, Value>, Option<String>), String> {
    read_store_limited(path, Some(limit)).map(|store| (store.values, store.identity))
}

pub(crate) fn write_object_snapshot(
    path: &Path,
    values: &Map<String, Value>,
    revision: &Option<String>,
    limit: u64,
    preflight: impl Fn() -> Result<(), String>,
    current: impl FnOnce() -> Result<(), String>,
) -> Result<(), String> {
    let _write = WRITES.lock().map_err(|_| "plugin.settings.unavailable")?;
    let expected = read_store_limited(path, Some(limit))?;
    if &expected.identity != revision {
        return Err("plugin.settings.conflict".into());
    }
    write_guarded_checked(path, values, &expected, Some(limit), preflight, current)
}

// Compare the exact bytes from discovery again after preparing the replacement.
// Internal writers are serialized; external edits are never merged from an old
// UI snapshot. Atomic replacement reuses the host's Windows adapter.
fn write_guarded(path: &Path, values: &Map<String, Value>, expected: &Store) -> Result<(), String> {
    write_guarded_checked(path, values, expected, None, || Ok(()), || Ok(()))
}
fn write_guarded_checked(
    path: &Path,
    values: &Map<String, Value>,
    expected: &Store,
    limit: Option<u64>,
    preflight: impl Fn() -> Result<(), String>,
    current: impl FnOnce() -> Result<(), String>,
) -> Result<(), String> {
    use std::io::Write;
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    preflight()?;
    if let Some(parent) = path.parent() {
        plain_source(parent, true)?;
    }
    plain_source(path, true)?;
    if read_store_limited(path, limit)?.identity != expected.identity {
        return Err("plugin.settings.conflict".into());
    }
    if let Some(parent) = path.parent() {
        preflight()?;
        std::fs::create_dir_all(parent).map_err(|_| "plugin.settings.writeFailed")?;
    }
    let temp = path.with_extension(format!(
        "json.{}-{}.tmp",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let mut owned_temporary = false;
    let result = (|| {
        preflight()?;
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)
            .map_err(|_| "plugin.settings.writeFailed")?;
        owned_temporary = true;
        serde_json::to_writer_pretty(&mut file, values)
            .map_err(|_| "plugin.settings.writeFailed")?;
        file.flush().map_err(|_| "plugin.settings.writeFailed")?;
        if let Ok(metadata) = std::fs::metadata(path) {
            file.set_permissions(metadata.permissions())
                .map_err(|_| "plugin.settings.writeFailed")?;
        }
        file.sync_all().map_err(|_| "plugin.settings.writeFailed")?;
        drop(file);
        current()?;
        if read_store_limited(path, limit)?.identity != expected.identity {
            return Err("plugin.settings.conflict".to_string());
        }
        plain_source(path, true)?;
        preflight()?;
        commit_replacement(&temp, path, expected.identity.is_some())
    })();
    if result.is_err() && owned_temporary {
        // A rejected preflight owns no file. If the storage path changed after
        // creation, retain evidence instead of deleting through that new path.
        preflight().map_err(|_| "plugin.settings.recoveryRequired")?;
        match std::fs::remove_file(&temp) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err("plugin.settings.recoveryRequired".into()),
        }
    }
    result
}

fn commit_replacement(source: &Path, destination: &Path, replacing: bool) -> Result<(), String> {
    #[cfg(windows)]
    if replacing {
        use std::os::windows::ffi::OsStrExt;
        use windows_sys::Win32::Storage::FileSystem::{
            MoveFileExW, ReplaceFileW, MOVEFILE_WRITE_THROUGH,
        };
        let backup = source.with_extension("backup");
        if backup.exists() {
            return Err("plugin.settings.writeFailed".into());
        }
        let destination_wide: Vec<u16> = destination
            .as_os_str()
            .encode_wide()
            .chain(Some(0))
            .collect();
        let source_wide: Vec<u16> = source.as_os_str().encode_wide().chain(Some(0)).collect();
        let backup_wide: Vec<u16> = backup.as_os_str().encode_wide().chain(Some(0)).collect();
        // ReplaceFile retains the original file's ACL and other metadata. Do
        // not fall back to a rename that could discard those permissions.
        let result = unsafe {
            ReplaceFileW(
                destination_wide.as_ptr(),
                source_wide.as_ptr(),
                backup_wide.as_ptr(),
                0,
                std::ptr::null(),
                std::ptr::null(),
            )
        };
        if result != 0 {
            return std::fs::remove_file(&backup).map_err(|_| "plugin.settings.writeFailed".into());
        }
        // Windows can move the old file before reporting a replacement error.
        // Keep its backup unless the old source can be restored without
        // overwriting another writer. Never delete the only surviving bytes.
        if backup.exists() {
            // Omit REPLACE_EXISTING so recovery cannot overwrite a concurrent
            // writer that created the destination after the failed replace.
            if unsafe {
                MoveFileExW(
                    backup_wide.as_ptr(),
                    destination_wide.as_ptr(),
                    MOVEFILE_WRITE_THROUGH,
                )
            } != 0
            {
                return Err("plugin.settings.writeFailed".into());
            }
            return Err("plugin.settings.recoveryRequired".into());
        }
        return Err("plugin.settings.writeFailed".into());
    }
    #[cfg(not(windows))]
    let _ = replacing;
    crate::logging::replace_file_atomically(source, destination)
        .map_err(|_| "plugin.settings.writeFailed".into())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SettingSnapshot {
    pub manifest: Value,
    pub settings: Vec<Value>,
    pub setting_actions: Vec<Value>,
    pub global_values: BTreeMap<String, Value>,
    pub project_values: BTreeMap<String, Value>,
    pub resolved_global: Value,
    pub resolved_project: Value,
    pub global_path: String,
    pub project_path: Option<String>,
    pub identity: String,
    pub package_identity: String,
    #[serde(skip)]
    global_store: Store,
    #[serde(skip)]
    project_store: Store,
}

fn workspace(workspace: &str) -> Result<(), String> {
    if workspace.is_empty() {
        return Ok(());
    }
    let root = Path::new(workspace);
    if !root.is_absolute() || !root.is_dir() {
        return Err("plugin.settings.invalidWorkspace".into());
    }
    // Do not follow workspace state links into another project or installation.
    for path in [root.join(".lithe"), project_store_path(workspace)] {
        match std::fs::symlink_metadata(&path) {
            Ok(metadata) => {
                #[cfg(windows)]
                {
                    use std::os::windows::fs::MetadataExt;
                    if metadata.file_attributes() & 0x400 != 0 {
                        return Err("plugin.settings.readOnlySource".into());
                    }
                }
                #[cfg(not(windows))]
                if metadata.file_type().is_symlink() {
                    return Err("plugin.settings.readOnlySource".into());
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err("plugin.settings.readFailed".into()),
        }
    }
    Ok(())
}

fn resolved(
    manifest: &Value,
    global: &BTreeMap<String, Value>,
    project: &BTreeMap<String, Value>,
) -> Result<Value, String> {
    let response = super::super::scan::core_execute(
        "plugins.declarative.resolveSettings",
        json!({
            "manifest": manifest, "settings": global, "projectSettings": project,
        }),
    )?;
    if response["status"] != "ok" {
        return Err("plugin.settings.invalidDeclaration".into());
    }
    Ok(response["settings"].clone())
}

fn snapshot(app: &AppHandle, plugin: &str, root: &str) -> Result<SettingSnapshot, String> {
    let package = super::super::launch::verified_package_by_id(app, plugin)?;
    snapshot_package(app, plugin, root, package)
}

fn snapshot_package(
    app: &AppHandle,
    plugin: &str,
    root: &str,
    package: super::super::ScannedPackage,
) -> Result<SettingSnapshot, String> {
    workspace(root)?;
    let global_path = global_store_path(app, plugin)?;
    for path in [
        Some(global_path.as_path()),
        (!root.is_empty()).then(|| Path::new(root)),
    ]
    .into_iter()
    .flatten()
    {
        // Missing preference directories inherit their nearest existing
        // ancestor's location. This also catches redirected app-data roots.
        let existing = path
            .ancestors()
            .find(|ancestor| ancestor.exists())
            .ok_or("plugin.settings.readFailed")?;
        let canonical = existing
            .canonicalize()
            .map_err(|_| "plugin.settings.readFailed")?;
        if app
            .path()
            .resource_dir()
            .ok()
            .and_then(|path| path.canonicalize().ok())
            .is_some_and(|path| canonical.starts_with(path))
            || std::env::current_exe()
                .ok()
                .and_then(|path| path.parent().map(Path::to_path_buf))
                .and_then(|path| path.canonicalize().ok())
                .is_some_and(|path| canonical.starts_with(path))
        {
            return Err("plugin.settings.readOnlySource".into());
        }
    }
    let normalized = super::super::scan::validate_manifest_with(
        &package.manifest,
        Some(super::super::host_capabilities()),
    )
    .map_err(|_| "plugin.settings.invalidDeclaration")?;
    let settings = normalized["settings"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    let global_store = read_store(&global_path)?;
    let project_store = if root.is_empty() {
        Store {
            values: Map::new(),
            identity: None,
        }
    } else {
        read_store(&project_store_path(root))?
    };
    let global: BTreeMap<String, Value> = global_store.values.clone().into_iter().collect();
    let project: BTreeMap<String, Value> = match project_store.values.get(plugin) {
        Some(Value::Object(values)) => values.clone().into_iter().collect(),
        Some(_) => return Err("plugin.settings.corruptStore".into()),
        None => BTreeMap::new(),
    };
    let digest = super::super::signature::content_digest(&package.root)
        .map_err(|error| error.code().to_string())?;
    let package_identity = format!(
        "{:x}",
        Sha256::digest(
            serde_json::to_vec(&json!({
                "plugin": plugin, "manifest": normalized, "digest": digest,
            }))
            .map_err(|error| error.to_string())?
        )
    );
    let identity = format!(
        "{:x}",
        Sha256::digest(
            serde_json::to_vec(&json!({
                "plugin": plugin, "manifest": normalized, "digest": digest, "workspace": root,
                "globalBytes": global_store.identity, "projectBytes": project_store.identity,
            }))
            .map_err(|error| error.to_string())?
        )
    );
    // Unknown keys may belong to an older plugin version; preserve them on
    // disk, but never send unrelated values to ordinary settings controls.
    let declared = |id: &str| settings.iter().any(|setting| setting["id"] == id);
    Ok(SettingSnapshot {
        resolved_global: resolved(&normalized, &global, &BTreeMap::new())?,
        resolved_project: resolved(&normalized, &global, &project)?,
        global_values: global.into_iter().filter(|(id, _)| declared(id)).collect(),
        project_values: project.into_iter().filter(|(id, _)| declared(id)).collect(),
        settings,
        setting_actions: normalized["settingActions"]
            .as_array()
            .cloned()
            .unwrap_or_default(),
        manifest: normalized,
        global_path: global_store_path(app, plugin)?
            .to_string_lossy()
            .into_owned(),
        project_path: (!root.is_empty())
            .then(|| project_store_path(root).to_string_lossy().into_owned()),
        identity,
        package_identity,
        global_store,
        project_store,
    })
}

/// Only the owner of the mutation barrier may read while launches are
/// revoked. Discovery rechecks the acceptance record and live signature;
/// settings are read again without re-enabling the plugin to get a lease.
pub(super) fn reload(
    app: &AppHandle,
    mutation: &super::super::lifecycle::Mutation,
    root: &str,
    expected: &str,
    expected_package: &str,
) -> Result<SettingSnapshot, String> {
    let plugin = mutation.plugin_id();
    let _write = WRITES.lock().map_err(|_| "plugin.settings.unavailable")?;
    let host = app.state::<super::super::PluginHostState>();
    publish_reload(&host, plugin, expected, expected_package, || {
        let fresh = super::super::scan::build_catalog(app)?
            .into_iter()
            .find(|package| {
                package.entry.plugin_id == plugin
                    && package.entry.enabled
                    && package.entry.status == "accepted"
            })
            .ok_or("plugin.settings.reloadRejected")?;
        let next = snapshot_package(app, plugin, root, fresh.clone())?;
        Ok((fresh, next))
    })
}

// Publish only the reverified target, preserving concurrent changes to other
// plugins. Settings conflicts may resume after this fresh catalog is visible;
// changed package bytes must stay revoked until explicit package recovery.
fn publish_reload(
    host: &super::super::PluginHostState,
    plugin: &str,
    expected: &str,
    expected_package: &str,
    verified: impl FnOnce() -> Result<(super::super::ScannedPackage, SettingSnapshot), String>,
) -> Result<SettingSnapshot, String> {
    let mut result = None;
    host.refresh(|| {
        let (fresh, next) = verified()?;
        if fresh.entry.plugin_id != plugin
            || !fresh.entry.enabled
            || fresh.entry.status != "accepted"
        {
            return Err("plugin.settings.reloadRejected".into());
        }
        if next.package_identity != expected_package {
            return Err("plugin.settings.packageChanged".into());
        }
        let mut packages = host.packages();
        let entry = packages
            .iter_mut()
            .find(|package| package.entry.plugin_id == plugin)
            .ok_or("plugin.settings.reloadRejected")?;
        *entry = fresh;
        result = Some(if next.identity == expected {
            Ok(next)
        } else {
            Err("plugin.settings.conflict".into())
        });
        Ok(packages)
    })?;
    result.ok_or_else(|| "plugin.settings.reloadRejected".to_string())?
}

pub(crate) fn read(
    app: &AppHandle,
    plugin_id: &str,
    workspace_path: &str,
) -> Result<SettingSnapshot, String> {
    let _lease = app
        .state::<super::super::lifecycle::LifecycleState>()
        .acquire(plugin_id)?;
    let _write = WRITES.lock().map_err(|_| "plugin.settings.unavailable")?;
    snapshot(app, plugin_id, workspace_path)
}

pub(super) fn store(
    app: &AppHandle,
    plugin: &str,
    id: &str,
    scope: &str,
    root: &str,
    value: Option<Value>,
    expected: &str,
) -> Result<SettingSnapshot, String> {
    let _lease = app
        .state::<super::super::lifecycle::LifecycleState>()
        .acquire(plugin)?;
    let _write = WRITES.lock().map_err(|_| "plugin.settings.unavailable")?;
    let before = snapshot(app, plugin, root)?;
    if before.identity != expected {
        return Err("plugin.settings.conflict".into());
    }
    validate_change(
        &before.manifest,
        &before.settings,
        id,
        scope,
        root,
        value.as_ref(),
    )?;
    // Keep an explicit empty/default distinct from erasing an override.
    let (path, source) = if scope == "project" {
        (project_store_path(root), &before.project_store)
    } else {
        (global_store_path(app, plugin)?, &before.global_store)
    };
    let mut values = source.values.clone();
    let target = if scope == "project" {
        values
            .entry(plugin.to_string())
            .or_insert_with(|| json!({}))
            .as_object_mut()
            .ok_or("plugin.settings.corruptStore")?
    } else {
        &mut values
    };
    if let Some(value) = value {
        target.insert(id.to_string(), value);
    } else {
        target.remove(id);
    }
    if scope == "project"
        && values
            .get(plugin)
            .and_then(Value::as_object)
            .is_some_and(Map::is_empty)
    {
        values.remove(plugin);
    }
    write_guarded(&path, &values, source)?;
    snapshot(app, plugin, root)
}

fn validate_change(
    manifest: &Value,
    settings: &[Value],
    id: &str,
    scope: &str,
    root: &str,
    value: Option<&Value>,
) -> Result<(), String> {
    let declaration = settings
        .iter()
        .find(|setting| setting["id"] == id)
        .ok_or("plugin.settings.unknownSetting")?;
    if scope != "global"
        && (scope != "project" || root.is_empty() || declaration["scope"] != "project")
    {
        return Err("plugin.settings.invalidScope".into());
    }
    if let Some(value) = value {
        // Ask Core whether this explicit value is accepted; a fallback to a
        // default is not successful validation. No copied setting validator.
        let candidate = BTreeMap::from([(id.to_string(), value.clone())]);
        let empty = BTreeMap::new();
        let values = if scope == "project" {
            resolved(manifest, &empty, &candidate)?
        } else {
            resolved(manifest, &candidate, &empty)?
        };
        if !values.as_array().is_some_and(|values| {
            values
                .iter()
                .any(|item| item["id"] == id && item["source"] == scope && item["value"] == *value)
        }) {
            return Err("plugin.settings.invalidValue".into());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests;
