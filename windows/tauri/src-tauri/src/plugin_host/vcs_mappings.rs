//! Lithe-owned root choices, never SVN/Git configuration. Reads do not create
//! storage. Confirmed writes reuse the platform JSON conflict/ACL/recovery
//! adapter; mutable records and its temporaries never enter installed resources.
use super::{registry, Core, Scope};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use std::path::{Component, Path, PathBuf};
use tauri::{AppHandle, Manager};

const MAX_BYTES: u64 = 1024 * 1024;
pub(super) const MAX_MAPPINGS: usize = 64;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Mapping {
    pub id: String,
    pub vcs: String,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MappingSnapshot {
    pub source: String,
    pub revision: Option<String>,
    pub entries: Vec<Mapping>,
}

/// File IDs plus creation identity distinguish replacement directories, even
/// at the same path. The project registry retains its native Handle while open.
pub(super) fn directory_identity(path: &Path) -> Result<String, String> {
    let handle = same_file::Handle::from_path(path).map_err(|_| registry::STALE)?;
    #[cfg(windows)]
    {
        use std::os::windows::io::AsRawHandle;
        use windows_sys::Win32::Storage::FileSystem::{
            GetFileInformationByHandle, BY_HANDLE_FILE_INFORMATION,
        };
        let mut info: BY_HANDLE_FILE_INFORMATION = unsafe { std::mem::zeroed() };
        if unsafe { GetFileInformationByHandle(handle.as_raw_handle() as _, &mut info) } == 0 {
            return Err(registry::STALE.into());
        }
        Ok(format!(
            "{:x}-{:x}-{:x}-{:x}-{:x}",
            info.dwVolumeSerialNumber,
            info.nFileIndexHigh,
            info.nFileIndexLow,
            info.ftCreationTime.dwHighDateTime,
            info.ftCreationTime.dwLowDateTime
        ))
    }
    #[cfg(not(windows))]
    {
        use std::os::unix::fs::MetadataExt;
        let _handle = handle;
        let metadata = std::fs::metadata(path).map_err(|_| registry::STALE)?;
        Ok(format!("{}-{}", metadata.dev(), metadata.ino()))
    }
}
fn source(app: &AppHandle, scope: &Scope) -> Result<PathBuf, String> {
    let identity = directory_identity(Path::new(&scope.workspace_root))?;
    let path = app
        .path()
        .app_local_data_dir()
        .map_err(|_| "vcs.mapping.readFailed")?
        .join("vcs-roots")
        .join(format!("{:x}.json", Sha256::digest(identity.as_bytes())));
    // Do not follow an application-data junction into an installed package.
    // Missing directories remain missing until an explicit confirmed Save.
    storage_path(&path)?;
    Ok(path)
}
fn storage_path(path: &Path) -> Result<(), String> {
    for ancestor in path.ancestors() {
        match std::fs::symlink_metadata(ancestor) {
            Ok(metadata) => {
                #[cfg(windows)]
                {
                    use std::os::windows::fs::MetadataExt;
                    if metadata.file_attributes() & 0x400 != 0 {
                        return Err("vcs.mapping.readOnly".into());
                    }
                }
                if metadata.file_type().is_symlink() {
                    return Err("vcs.mapping.readOnly".into());
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err("vcs.mapping.readFailed".into()),
        }
    }
    Ok(())
}
fn store_error(error: String) -> String {
    if error.starts_with("vcs.mapping.") {
        return error;
    }
    if matches!(
        error.as_str(),
        "requestCancelled" | "requestTimeout" | "invalidRequest"
    ) {
        return error;
    }
    if error == "plugin.settings.conflict" {
        "vcs.mapping.conflict".into()
    } else if error == "plugin.settings.readOnlySource" {
        "vcs.mapping.readOnly".into()
    } else {
        "vcs.mapping.readFailed".into()
    }
}
fn values(path: &Path) -> Result<(Map<String, Value>, Option<String>), String> {
    if std::fs::metadata(path).is_ok_and(|metadata| metadata.len() > MAX_BYTES) {
        return Err("vcs.mapping.readFailed".into());
    }
    let result =
        super::super::settings::read_object_snapshot(path, MAX_BYTES).map_err(store_error)?;
    if !result.0.is_empty() && result.0.get("version") != Some(&json!(1)) {
        return Err("vcs.mapping.readOnly".into());
    }
    if let Some(rows) = result.0.get("mappings") {
        if !rows
            .as_array()
            .is_some_and(|rows| rows.len() <= MAX_MAPPINGS)
        {
            return Err("vcs.mapping.readFailed".into());
        }
    }
    Ok(result)
}
fn root_path(workspace: &Path, id: &str) -> Result<PathBuf, String> {
    // Enclosing Core IDs contain only '..' components. Normal IDs never climb
    // out and then back in. Reject absolute/drive/UNC aliases and reparse hops.
    if id.len() > 32768 || id.contains('\\') || id.contains(':') || id.contains('\0') {
        return Err("invalidRequest".into());
    }
    let mut path = workspace.canonicalize().map_err(|_| registry::STALE)?;
    let enclosing = !id.is_empty() && id.split('/').all(|part| part == "..");
    if !id.is_empty() {
        for part in Path::new(id).components() {
            match part {
                Component::ParentDir if enclosing => {
                    if !path.pop() {
                        return Err("invalidRequest".into());
                    }
                }
                Component::Normal(name) if !enclosing => {
                    path.push(name);
                    let metadata = std::fs::symlink_metadata(&path).map_err(|_| registry::STALE)?;
                    #[cfg(windows)]
                    {
                        use std::os::windows::fs::MetadataExt;
                        if metadata.file_attributes() & 0x400 != 0 {
                            return Err(registry::STALE.into());
                        }
                    }
                    if metadata.file_type().is_symlink() {
                        return Err(registry::STALE.into());
                    }
                }
                _ => return Err("invalidRequest".into()),
            }
        }
        if !enclosing
            && id
                .split('/')
                .any(|part| part.is_empty() || part == "." || part == "..")
        {
            return Err("invalidRequest".into());
        }
    }
    Ok(path)
}
pub(super) fn read_at(path: &Path, workspace: &Path) -> Result<MappingSnapshot, String> {
    let (values, revision) = values(path)?;
    let mut entries = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for row in values
        .get("mappings")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        // Unknown fields/rows survive saves. Only rows bound to the current
        // directory object are input to Core; stale choices cannot claim paths.
        let Some(id) = row["id"].as_str() else {
            continue;
        };
        if !seen.insert(id) {
            return Err("vcs.mapping.readFailed".into());
        }
        let Some(vcs) = row["vcs"].as_str() else {
            continue;
        };
        let Ok(root) = root_path(workspace, id) else {
            continue;
        };
        let Ok(identity) = directory_identity(&root) else {
            continue;
        };
        if row["directoryIdentity"] == identity {
            entries.push(Mapping {
                id: id.into(),
                vcs: vcs.into(),
            });
        }
    }
    entries.sort_by(|left, right| left.id.cmp(&right.id));
    Ok(MappingSnapshot {
        source: path.to_string_lossy().into_owned(),
        revision,
        entries,
    })
}
pub(super) fn read(app: &AppHandle, scope: &Scope) -> Result<MappingSnapshot, String> {
    read_at(&source(app, scope)?, Path::new(&scope.workspace_root))
}
pub(super) fn save_at(
    path: &Path,
    workspace: &Path,
    expected: &MappingSnapshot,
    id: &str,
    vcs: Option<&str>,
    current: impl FnOnce() -> Result<(), String>,
) -> Result<MappingSnapshot, String> {
    let (mut object, revision) = values(path)?;
    if revision != expected.revision || read_at(path, workspace)? != *expected {
        return Err("vcs.mapping.conflict".into());
    }
    let root = root_path(workspace, id)?;
    let identity = directory_identity(&root)?;
    if expected
        .entries
        .iter()
        .find(|entry| entry.id == id)
        .map(|entry| entry.vcs.as_str())
        == vcs
    {
        current()?;
        return Ok(expected.clone());
    }
    let rows = object
        .entry("mappings")
        .or_insert(json!([]))
        .as_array_mut()
        .ok_or("vcs.mapping.readFailed")?;
    if let Some(vcs) = vcs {
        if let Some(row) = rows.iter_mut().find(|row| row["id"] == id) {
            if !row["vcs"].is_string() || !row["directoryIdentity"].is_string() {
                return Err("vcs.mapping.readOnly".into());
            }
            let fields = row.as_object_mut().ok_or("vcs.mapping.readFailed")?;
            fields.insert("vcs".into(), json!(vcs));
            fields.insert("directoryIdentity".into(), json!(identity));
        } else {
            if rows.len() >= MAX_MAPPINGS {
                return Err("requestLimitExceeded".into());
            }
            rows.push(json!({"id":id,"vcs":vcs,"directoryIdentity":identity}));
        }
    } else {
        rows.retain(|row| row["id"] != id || row["directoryIdentity"] != identity);
    }
    object.insert("version".into(), json!(1));
    if serde_json::to_vec_pretty(&object)
        .map_err(|_| "vcs.mapping.readFailed")?
        .len() as u64
        > MAX_BYTES
    {
        return Err("requestLimitExceeded".into());
    }
    super::super::settings::write_object_snapshot(
        path,
        &object,
        &revision,
        MAX_BYTES,
        || storage_path(path),
        || {
            if directory_identity(&root)? != identity {
                return Err(registry::STALE.into());
            }
            current()
        },
    )
    .map_err(store_error)?;
    read_at(path, workspace)
}

#[tauri::command]
pub async fn declarative_plugins_vcs_save_mapping(
    app: AppHandle,
    caller: tauri::WebviewWindow,
    scope: Scope,
    generation: u64,
    revision: Option<String>,
    id: String,
    vcs: Option<String>,
) -> Result<(), String> {
    super::live(&app, caller.label())?;
    super::validate(&scope)?;
    if id.len() > 32768
        || vcs.as_ref().is_some_and(|vcs| vcs.len() > 32)
        || revision.as_ref().is_some_and(|revision| {
            revision.len() != 64 || !revision.bytes().all(|byte| byte.is_ascii_hexdigit())
        })
    {
        return Err("invalidRequest".into());
    }
    let host = caller.label().to_string();
    let deadline = std::time::Instant::now() + registry::READ_TIMEOUT;
    let permit = tokio::time::timeout(
        registry::READ_TIMEOUT,
        app.state::<super::VcsHostState>()
            .reads
            .clone()
            .acquire_owned(),
    )
    .await
    .map_err(|_| "requestTimeout")?
    .map_err(|_| registry::STALE)?;
    tokio::time::timeout_at(
        tokio::time::Instant::from_std(deadline),
        tauri::async_runtime::spawn_blocking(move || {
            let _permit = permit;
            let state = app.state::<super::VcsHostState>();
            let (snapshot, expected, registration) = state
                .registry
                .lock()
                .map_err(|_| "internalError")?
                .capture(&host, &scope, generation)?;
            let mapping = snapshot.mappings.as_ref().ok_or(registry::STALE)?;
            if mapping.revision != revision {
                return Err("vcs.mapping.conflict".into());
            }
            let (packages, _leases) = super::packages(&app)?;
            if packages != expected {
                return Err(registry::STALE.into());
            }
            let current = super::redetect(&app, &scope, &packages, &snapshot)?;
            if current.truncated || !registry::same_roots(&snapshot.detection, &current) {
                return Err(registry::STALE.into());
            }
            let unmapped = registry::detect(&Core, &scope, &packages)?;
            let candidates = unmapped.ambiguous.iter().find(|row| row["id"] == id);
            if candidates.is_none()
                && (vcs.is_some() || !mapping.entries.iter().any(|entry| entry.id == id))
            {
                return Err("invalidRequest".into());
            }
            if vcs.as_ref().is_some_and(|vcs| {
                !candidates
                    .map(|candidate| &candidate["vcs"])
                    .and_then(Value::as_array)
                    .is_some_and(|all| all.iter().any(|value| value == vcs))
            }) {
                return Err("invalidRequest".into());
            }
            save_at(
                Path::new(&mapping.source),
                Path::new(&scope.workspace_root),
                mapping,
                &id,
                vcs.as_deref(),
                || {
                    if std::time::Instant::now() >= deadline {
                        return Err("requestTimeout".into());
                    }
                    super::live(&app, &host)?;
                    if source(&app, &scope)?.to_string_lossy() != mapping.source {
                        return Err(registry::STALE.into());
                    }
                    if super::project_registration(&app, &host, &scope)? != registration {
                        return Err(registry::STALE.into());
                    }
                    state
                        .registry
                        .lock()
                        .map_err(|_| "internalError")?
                        .capture(&host, &scope, generation)?;
                    Ok(())
                },
            )?;
            super::metadata_changed(&app, &host, &scope, generation);
            Ok(())
        }),
    )
    .await
    .map_err(|_| "requestTimeout")?
    .map_err(|_| "internalError")?
}

#[cfg(test)]
#[path = "vcs_mappings_tests.rs"]
mod tests;
