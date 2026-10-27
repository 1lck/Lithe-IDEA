//! Read-only operation selection and workspace projection. Provider paths are
//! data, never arbitrary native read targets; Core remains the ownership judge.
use super::{registry, session, status};
use serde::Deserialize;
use serde_json::{json, Value};
use std::io::Read;
use std::path::{Path, PathBuf};

pub(super) const MAX_PAGE: usize = 100;
const MAX_CONTENT: u64 = 32 * 1024 * 1024;

#[derive(Clone, Debug, Deserialize)]
#[serde(tag = "operation", rename_all = "camelCase", deny_unknown_fields)]
pub enum ReadOperation {
    Status,
    History {
        cursor: Option<String>,
        limit: usize,
    },
    FileHistory {
        path: String,
        cursor: Option<String>,
        limit: usize,
    },
    BaseContent {
        path: String,
        #[serde(rename = "currentPath")]
        current_path: String,
    },
}
impl ReadOperation {
    pub(super) fn name(&self) -> &'static str {
        match self {
            Self::Status => "status",
            Self::History { .. } => "history",
            Self::FileHistory { .. } => "fileHistory",
            Self::BaseContent { .. } => "baseContent",
        }
    }
    pub(super) fn arguments(&self) -> Value {
        match self {
            Self::Status => json!({"includeIgnored":false}),
            Self::History { cursor, limit } => json!({"cursor":cursor,"limit":limit}),
            Self::FileHistory {
                path,
                cursor,
                limit,
            } => json!({"path":path,"cursor":cursor,"limit":limit}),
            Self::BaseContent { path, .. } => json!({"path":path}),
        }
    }
    pub(super) fn validate(&self) -> Result<(), String> {
        match self {
            Self::History { cursor, limit } | Self::FileHistory { cursor, limit, .. } => {
                if !(1..=MAX_PAGE).contains(limit)
                    || cursor.as_ref().is_some_and(|cursor| {
                        cursor.is_empty()
                            || cursor.len() > 256
                            || cursor.chars().any(char::is_control)
                    })
                {
                    return Err("invalidRequest".into());
                }
            }
            _ => {}
        }
        for path in self.paths() {
            validate_path(path)?;
        }
        Ok(())
    }
    fn paths(&self) -> Vec<&str> {
        match self {
            Self::FileHistory { path, .. } => vec![path],
            Self::BaseContent { path, current_path } => vec![path, current_path],
            _ => Vec::new(),
        }
    }
}
fn validate_path(path: &str) -> Result<(), String> {
    if path.is_empty()
        || path.len() > 32768
        || path.contains(['\\', ':', '\0'])
        || path
            .split('/')
            .any(|part| part.is_empty() || part == "." || part == "..")
    {
        return Err("invalidRequest".into());
    }
    Ok(())
}
fn reparse(metadata: &std::fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        metadata.file_type().is_symlink() || metadata.file_attributes() & 0x400 != 0
    }
    #[cfg(not(windows))]
    {
        metadata.file_type().is_symlink()
    }
}
fn ordinary_chain(workspace: &Path, path: &Path) -> Result<(), String> {
    let relative = path
        .strip_prefix(workspace)
        .map_err(|_| "vcs.provider.pathUnavailable")?;
    let mut current = workspace.to_path_buf();
    for part in relative.components() {
        current.push(part);
        match std::fs::symlink_metadata(&current) {
            Ok(metadata) if reparse(&metadata) => return Err("vcs.provider.pathUnavailable".into()),
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => break,
            Err(_) => return Err("vcs.provider.pathUnavailable".into()),
        }
    }
    Ok(())
}
pub(super) fn paths(
    core: &dyn registry::VcsCore,
    snapshot: &registry::Snapshot,
    root: &registry::Root,
    operation: &ReadOperation,
) -> Result<Vec<PathBuf>, String> {
    operation.validate()?;
    if snapshot.detection.truncated {
        return Err("vcs.provider.incompleteRoots".into());
    }
    let workspace = Path::new(&snapshot.workspace_root)
        .canonicalize()
        .map_err(|_| registry::STALE)?;
    let mut targets = Vec::new();
    let mut relative = Vec::new();
    for path in operation.paths() {
        let target = Path::new(&root.path).join(path);
        let in_workspace = target
            .strip_prefix(&workspace)
            .map_err(|_| "vcs.provider.pathUnavailable")?;
        ordinary_chain(&workspace, &target)?;
        relative.push(
            in_workspace
                .to_str()
                .ok_or("invalidRequest")?
                .replace('\\', "/"),
        );
        targets.push(target);
    }
    if !relative.is_empty() {
        let owners = registry::owners(core, snapshot, &relative)?;
        if !owners.complete
            || owners
                .owners
                .iter()
                .any(|owner| owner.root.as_deref() != Some(root.id.as_str()))
        {
            return Err("vcs.provider.pathUnavailable".into());
        }
    }
    Ok(targets)
}

fn current_content(workspace: &Path, target: &Path) -> session::Reply {
    ordinary_chain(workspace, target)?;
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(windows_sys::Win32::Storage::FileSystem::FILE_FLAG_OPEN_REPARSE_POINT);
    }
    let mut file = match options.open(target) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(json!({"currentContent":null,"currentBinary":false}))
        }
        Err(_) => return Err("vcs.provider.pathUnavailable".into()),
    };
    let metadata = file
        .metadata()
        .map_err(|_| "vcs.provider.pathUnavailable")?;
    if !metadata.is_file() || reparse(&metadata) || metadata.len() > MAX_CONTENT {
        return Err("vcs.provider.contentUnavailable".into());
    }
    let identity = same_file::Handle::from_file(
        file.try_clone()
            .map_err(|_| "vcs.provider.pathUnavailable")?,
    )
    .map_err(|_| "vcs.provider.pathUnavailable")?;
    let mut bytes = Vec::new();
    file.by_ref()
        .take(MAX_CONTENT + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "vcs.provider.contentUnavailable")?;
    ordinary_chain(workspace, target)?;
    let canonical = target
        .canonicalize()
        .map_err(|_| "vcs.provider.pathUnavailable")?;
    if !canonical.starts_with(workspace)
        || bytes.len() as u64 > MAX_CONTENT
        || identity
            != same_file::Handle::from_path(target).map_err(|_| "vcs.provider.pathUnavailable")?
    {
        return Err("vcs.provider.pathUnavailable".into());
    }
    match String::from_utf8(bytes) {
        Ok(text) if !text.contains('\0') => {
            Ok(json!({"currentContent":text,"currentBinary":false}))
        }
        _ => Ok(json!({"currentContent":null,"currentBinary":true})),
    }
}

pub(super) fn project(
    core: &dyn registry::VcsCore,
    snapshot: &registry::Snapshot,
    root: &registry::Root,
    operation: &ReadOperation,
    mut result: Value,
) -> session::Reply {
    let targets = paths(core, snapshot, root, operation)?;
    match operation {
        ReadOperation::Status => status::project_status(core, snapshot, root, result),
        ReadOperation::History { .. } | ReadOperation::FileHistory { .. } => {
            for entry in result["entries"]
                .as_array_mut()
                .ok_or("plugin.vcs.invalidOutput")?
            {
                let count = entry["changes"]
                    .as_array()
                    .ok_or("plugin.vcs.invalidOutput")?
                    .len();
                let projected = status::project_status(
                    core,
                    snapshot,
                    root,
                    json!({"changes":entry["changes"]}),
                )?;
                entry["changes"] = projected["changes"].clone();
                if entry["changes"].as_array().unwrap().len() != count {
                    entry["changesTruncated"] = json!(true);
                }
            }
            Ok(result)
        }
        ReadOperation::BaseContent { path, current_path } => {
            let workspace = Path::new(&snapshot.workspace_root)
                .canonicalize()
                .map_err(|_| registry::STALE)?;
            let current = current_content(&workspace, &targets[1])?;
            result["currentContent"] = current["currentContent"].clone();
            result["currentBinary"] = current["currentBinary"].clone();
            result["path"] = json!(path);
            result["currentPath"] = json!(current_path);
            Ok(result)
        }
    }
}

#[tauri::command]
pub async fn declarative_plugins_vcs_query(
    app: tauri::AppHandle,
    caller: tauri::WebviewWindow,
    scope: super::Scope,
    generation: u64,
    root_id: String,
    request_id: String,
    query: ReadOperation,
) -> Result<status::StatusSnapshot, String> {
    // This endpoint accepts only the typed read operations above. In particular
    // it is not a generic lsp.vcsRequest or a provider method/command tunnel.
    if matches!(query, ReadOperation::Status) {
        return Err("invalidRequest".into());
    }
    status::read(app, caller, scope, generation, root_id, request_id, query).await
}

#[cfg(test)]
#[path = "vcs_query_tests.rs"]
mod tests;
