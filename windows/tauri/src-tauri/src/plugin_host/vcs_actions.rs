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
}
impl WriteOperation {
    pub(super) fn name(&self) -> &'static str {
        match self {
            Self::Checkin { .. } => "checkin",
            Self::Rollback { .. } => "rollback",
            Self::Update => "update",
        }
    }
    pub(super) fn arguments(&self) -> Value {
        match self {
            Self::Checkin { paths, message } => json!({"paths":paths,"message":message}),
            Self::Rollback { paths } => json!({"paths":paths}),
            Self::Update => json!({}),
        }
    }
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
    if snapshot.detection.truncated || status.projected["truncated"] != false {
        return Err("vcs.provider.incompleteRoots".into());
    }
    if status.capabilities[operation.name()] != 1 {
        return Err("vcs.capability.unsupported".into());
    }
    let workspace = Path::new(&snapshot.workspace_root)
        .canonicalize()
        .map_err(|_| registry::STALE)?;
    let root_path = Path::new(&root.path)
        .canonicalize()
        .map_err(|_| registry::STALE)?;
    if matches!(operation, WriteOperation::Update) {
        // v1 update has no path scope. Never update an enclosing working copy
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
        WriteOperation::Rollback { paths } => (paths, None),
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
        if row["status"] == "ignored" || (message.is_none() && row["status"] == "unversioned") {
            return Err("invalidRequest".into());
        }
        paths.insert(path.clone());
        if let Some(old) = row["oldPath"].as_str() {
            paths.insert(old.into());
        }
    }
    if paths.len() > 10000 {
        return Err("invalidRequest".into());
    }
    let paths: Vec<String> = paths.into_iter().collect();
    for path in &paths {
        query::validate_path(path)?;
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
        if message.is_some() {
            let mut ancestor = path.as_str();
            while let Some((parent, _)) = ancestor.rsplit_once('/') {
                // Providers may include scheduled parent additions/replacements
                // implicitly. A selected child must not commit an unseen parent.
                if rows.get(parent).is_some_and(|row| {
                    matches!(
                        row["status"].as_str(),
                        Some("added" | "replaced" | "renamed" | "copied")
                    )
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
