//! Snapshot-bound writes. UI confirms an explicit selection; native code
//! consumes the status receipt once, re-reads it and proves Core ownership
//! again before dispatch. Cleanup retries never dispatch another mutation.
use super::{query, registry, session, Scope};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::Path;

#[derive(Clone, Debug, Deserialize)]
#[serde(tag = "operation", rename_all = "camelCase", deny_unknown_fields)]
pub enum WriteOperation {
    Checkin { paths: Vec<String>, message: String },
    Rollback { paths: Vec<String> },
    Update,
    Resolve { paths: Vec<String> },
    Add { paths: Vec<String> },
    Delete { paths: Vec<String> },
    // An empty struct makes deny_unknown_fields reject narrower path/revision
    // arguments; internally tagged unit variants would silently ignore them.
    Cleanup {},
}
impl WriteOperation {
    pub(super) fn name(&self) -> &'static str {
        match self {
            Self::Checkin { .. } => "checkin",
            Self::Rollback { .. } => "rollback",
            Self::Update => "update",
            Self::Resolve { .. } => "resolve",
            Self::Cleanup { .. } => "cleanup",
            Self::Add { .. } => "add",
            Self::Delete { .. } => "delete",
        }
    }
    pub(super) fn request_name(&self) -> &'static str {
        match self {
            Self::Add { .. } | Self::Delete { .. } => "fileOperation",
            _ => self.name(),
        }
    }
    pub(super) fn capability(&self) -> &'static str {
        match self {
            Self::Resolve { .. } => "conflicts",
            Self::Add { .. } | Self::Delete { .. } => "fileOperations",
            _ => self.name(),
        }
    }
    pub(super) fn arguments(&self) -> Value {
        match self {
            Self::Checkin { paths, message } => json!({"paths":paths,"message":message}),
            Self::Rollback { paths } | Self::Resolve { paths } => json!({"paths":paths}),
            Self::Update | Self::Cleanup { .. } => json!({}),
            Self::Add { paths } => json!({"kind":"add","paths":paths}),
            Self::Delete { paths } => json!({"kind":"delete","paths":paths}),
        }
    }
}

/// UI selection rules are intentionally narrower than v1: it offers neither
/// recursion control nor a keep-local switch. Disk metadata is checked later;
/// a status row alone never proves an ordinary file.
fn file_operation_row(operation: &WriteOperation, path: &str, row: &Value) -> bool {
    (match operation {
        // No parent can be implicitly scheduled when the file is directly in
        // the detected root. v1 cannot prove a clean-looking parent is tracked.
        WriteOperation::Add { .. } => {
            !path.contains('/') && row["status"] == "unversioned" && row["oldPath"].is_null()
        }
        WriteOperation::Delete { .. } => matches!(
            row["status"].as_str(),
            Some(
                "modified"
                    | "added"
                    | "renamed"
                    | "copied"
                    | "replaced"
                    | "typeChanged"
                    | "switched"
            )
        ),
        _ => return true,
    }) && !row["flags"].as_array().is_some_and(|flags| {
        flags.iter().any(|flag| {
            matches!(
                flag.as_str(),
                Some("external" | "submodule" | "treeConflict")
            )
        })
    })
}
#[derive(Clone)]
pub(super) struct Published {
    pub context: session::Context,
    pub raw: Value,
    pub projected: Value,
    pub capabilities: Value,
}
#[derive(Default)]
pub(super) struct Actions {
    statuses: HashMap<(String, String), (Published, usize)>,
    bytes: usize,
}
impl Actions {
    pub fn publish(&mut self, published: Published) {
        const MAX_BYTES: usize = 32 * 1024 * 1024;
        let context = &published.context;
        self.retire(|old| {
            old.host == context.host && old.scope == context.scope && old.root.id == context.root.id
        });
        let bytes = published.raw.to_string().len() + published.projected.to_string().len();
        if bytes > MAX_BYTES {
            return;
        }
        if self.statuses.len() >= 128 || self.bytes + bytes > MAX_BYTES {
            self.statuses.clear();
            self.bytes = 0;
        }
        self.bytes += bytes;
        self.statuses.insert(
            (context.host.clone(), context.request_id.clone()),
            (published, bytes),
        );
    }
    pub fn take(&mut self, host: &str, scope: &Scope, id: &str) -> Result<Published, String> {
        let key = (host.into(), id.into());
        if !self
            .statuses
            .get(&key)
            .is_some_and(|(status, _)| status.context.scope == *scope)
        {
            return Err(registry::STALE.into());
        }
        let (status, bytes) = self.statuses.remove(&key).ok_or(registry::STALE)?;
        self.bytes -= bytes;
        Ok(status)
    }
    pub fn retire(&mut self, predicate: impl Fn(&session::Context) -> bool) {
        self.statuses.retain(|_, (status, bytes)| {
            if predicate(&status.context) {
                self.bytes -= *bytes;
                false
            } else {
                true
            }
        });
    }
}

pub(super) fn same_source(published: &Published, context: &session::Context) -> bool {
    let mut original = published.context.clone();
    original.request_id = context.request_id.clone();
    original == *context
}

/// Expand a selected rename/copy to both paths, then ask Core about every
/// endpoint. Only existing ordinary files prove a non-recursive selection;
/// version 1 status cannot distinguish a missing file from a missing directory.
pub(super) fn targets(
    core: &dyn registry::VcsCore,
    snapshot: &registry::Snapshot,
    root: &registry::Root,
    status: &Published,
    operation: &WriteOperation,
) -> Result<WriteOperation, String> {
    if snapshot.detection.truncated
        || status.raw["truncated"] != false
        || status.projected["truncated"] != false
    {
        return Err("vcs.provider.incompleteRoots".into());
    }
    if status.capabilities[operation.capability()] != 1 {
        return Err("vcs.capability.unsupported".into());
    }
    let workspace = Path::new(&snapshot.workspace_root)
        .canonicalize()
        .map_err(|_| registry::STALE)?;
    let root_path = Path::new(&root.path)
        .canonicalize()
        .map_err(|_| registry::STALE)?;
    if matches!(
        operation,
        WriteOperation::Update | WriteOperation::Cleanup { .. }
    ) {
        // v1 update/cleanup have no path scope. Never mutate an enclosing working copy
        // or one containing nested/ambiguous roots from a narrower window.
        if root_path != workspace
            || snapshot.detection.roots.len() != 1
            || !snapshot.detection.ambiguous.is_empty()
        {
            return Err("vcs.provider.pathUnavailable".into());
        }
        let owners = registry::owners(core, snapshot, &[String::new()])?;
        if !owners.complete
            || owners.owners.len() != 1
            || owners.owners[0].root.as_deref() != Some(root.id.as_str())
        {
            return Err("vcs.provider.pathUnavailable".into());
        }
        return Ok(operation.clone());
    }
    let (selected, message) = match operation {
        WriteOperation::Checkin { paths, message } => {
            if message.trim().is_empty() || message.len() > 1024 * 1024 || message.contains('\0') {
                return Err("invalidRequest".into());
            }
            (paths, Some(message))
        }
        WriteOperation::Rollback { paths }
        | WriteOperation::Resolve { paths }
        | WriteOperation::Add { paths }
        | WriteOperation::Delete { paths } => (paths, None),
        _ => unreachable!(),
    };
    if selected.is_empty() || selected.len() > 10000 {
        return Err("invalidRequest".into());
    }
    let changes = status.projected["changes"]
        .as_array()
        .ok_or("invalidResponse")?;
    let rows: BTreeMap<&str, &Value> = changes
        .iter()
        .filter_map(|change| change["path"].as_str().map(|path| (path, change)))
        .collect();
    let mut paths = BTreeSet::new();
    for path in selected {
        query::validate_path(path)?;
        let row = rows.get(path.as_str()).ok_or(registry::STALE)?;
        if !file_operation_row(operation, path, row) {
            return Err("vcs.provider.pathUnavailable".into());
        }
        if row["status"] == "ignored"
            || (matches!(operation, WriteOperation::Rollback { .. })
                && row["status"] == "unversioned")
        {
            return Err("invalidRequest".into());
        }
        if matches!(operation, WriteOperation::Resolve { .. })
            && row["status"] != "conflicted"
            && !row["flags"]
                .as_array()
                .is_some_and(|flags| flags.iter().any(|flag| flag == "treeConflict"))
        {
            return Err("invalidRequest".into());
        }
        paths.insert(path.clone());
        // macOS resolve marks the selected conflict path, never its oldPath.
        if !matches!(operation, WriteOperation::Resolve { .. }) {
            if let Some(old) = row["oldPath"].as_str() {
                paths.insert(old.into());
            }
        }
    }
    if paths.len() > 10000 {
        return Err("invalidRequest".into());
    }
    let paths: Vec<String> = paths.into_iter().collect();
    for path in &paths {
        query::validate_path(path)?;
        // A rename/copy's old endpoint may also have an independent status row
        // (for example, a recreated unversioned file). Expansion must not bypass
        // the same delete eligibility applied to explicitly selected rows.
        if matches!(operation, WriteOperation::Delete { .. })
            && rows
                .get(path.as_str())
                .is_some_and(|row| !file_operation_row(operation, path, row))
        {
            return Err("vcs.provider.pathUnavailable".into());
        }
        let target = root_path.join(path);
        query::ordinary_chain(&workspace, &target)?;
        let canonical = target
            .canonicalize()
            .map_err(|_| "vcs.provider.pathUnavailable")?;
        // A removed directory may be represented by a single status row. Its
        // provider rollback can recurse into children absent from confirmation.
        // Core IDs are lexical. Windows case/short-name aliases must not hide
        // a nested working copy or a scheduled parent from the ownership check.
        if canonical != target
            || !std::fs::symlink_metadata(&target).is_ok_and(|metadata| metadata.is_file())
            || rows
                .range(format!("{path}/").as_str()..)
                .next()
                .is_some_and(|(other, _)| other.starts_with(&format!("{path}/")))
            || snapshot
                .detection
                .roots
                .iter()
                .any(|nested| nested.id != root.id && Path::new(&nested.path).starts_with(&target))
            || snapshot.detection.ambiguous.iter().any(|ambiguous| {
                ambiguous["id"]
                    .as_str()
                    .is_some_and(|id| workspace.join(id).starts_with(&target))
            })
        {
            return Err("vcs.provider.pathUnavailable".into());
        }
        if message.is_some()
            || matches!(
                operation,
                WriteOperation::Resolve { .. } | WriteOperation::Delete { .. }
            )
        {
            let mut ancestor = path.as_str();
            while let Some((parent, _)) = ancestor.rsplit_once('/') {
                // Providers may include scheduled parent additions/replacements
                // implicitly. A selected child must not commit an unseen parent.
                if rows.get(parent).is_some_and(|row| {
                    matches!(
                        row["status"].as_str(),
                        Some("added" | "replaced" | "renamed" | "copied")
                    ) || (matches!(operation, WriteOperation::Delete { .. })
                        && (row["status"] == "unversioned"
                            || row["status"] == "ignored"
                            || row["flags"].as_array().is_some_and(|flags| {
                                flags.iter().any(|flag| {
                                    matches!(
                                        flag.as_str(),
                                        Some("external" | "submodule" | "treeConflict")
                                    )
                                })
                            })))
                }) {
                    return Err("vcs.provider.pathUnavailable".into());
                }
                ancestor = parent;
            }
        }
    }
    let relative: Vec<_> = paths
        .iter()
        .map(|path| {
            root_path
                .join(path)
                .strip_prefix(&workspace)
                .ok()
                .and_then(|path| path.to_str())
                .map(|path| path.replace('\\', "/"))
                .ok_or_else(|| "vcs.provider.pathUnavailable".to_string())
        })
        .collect::<Result<_, _>>()?;
    let owners = registry::owners(core, snapshot, &relative)?;
    if !owners.complete
        || owners.owners.len() != relative.len()
        || owners
            .owners
            .iter()
            .any(|owner| owner.root.as_deref() != Some(root.id.as_str()))
    {
        return Err("vcs.provider.pathUnavailable".into());
    }
    Ok(match message {
        Some(message) => WriteOperation::Checkin {
            paths,
            message: message.clone(),
        },
        None if matches!(operation, WriteOperation::Resolve { .. }) => {
            WriteOperation::Resolve { paths }
        }
        None if matches!(operation, WriteOperation::Add { .. }) => WriteOperation::Add { paths },
        None if matches!(operation, WriteOperation::Delete { .. }) => {
            WriteOperation::Delete { paths }
        }
        None => WriteOperation::Rollback { paths },
    })
}

#[tauri::command]
pub async fn declarative_plugins_vcs_write(
    app: tauri::AppHandle,
    caller: tauri::WebviewWindow,
    scope: Scope,
    generation: u64,
    root_id: String,
    request_id: String,
    status_id: String,
    action: WriteOperation,
) -> Result<super::status::StatusSnapshot, String> {
    super::status::run(
        app,
        caller,
        scope,
        generation,
        root_id,
        request_id,
        query::ReadOperation::Status,
        Some((status_id, action)),
    )
    .await
}

#[cfg(test)]
#[path = "vcs_actions_tests.rs"]
mod tests;
