//! Classifies Git watcher paths without filesystem access or platform events.

use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

/// Upper bound for a page sent over the JSON bridge. Native hosts can classify
/// their already-coalesced events directly without allocating a JSON copy.
const MAX_PATHS_PER_PAGE: usize = 256;
const MAX_PATH_BYTES: usize = 131_068;
const TEMPORARY_COMMIT_PREFIX: &str = "lithe-commit-";

/// Platform-resolved paths for one repository and its owning workspace.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GitMetadataWatchContext {
    /// Open workspace root, if the watcher also observes its Git pointer.
    #[serde(default)]
    pub workspace_root: Option<PathBuf>,
    /// Root of this checkout.
    pub repository_root: PathBuf,
    /// Worktree-private Git administrative directory.
    pub git_directory: PathBuf,
    /// Git administrative directory shared with related worktrees.
    pub git_common_directory: PathBuf,
    /// Ancestors whose ignore files affect this workspace.
    #[serde(default)]
    pub rule_directories: Vec<PathBuf>,
}

/// Meaning of one observed path for a repository's Git metadata.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum GitMetadataChangeKind {
    /// A repository or workspace Git pointer may need a new watch context.
    Context,
    /// An ignore file can change tracked and visible membership.
    IgnoreRule,
    /// Relevant administrative state changed.
    Metadata,
    /// Administrative churn cannot affect this checkout's visible state.
    Ignored,
    /// The path is not Git metadata; the workspace watcher owns it.
    Other,
}

/// The classification and whether this event only rewrites this worktree's index.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitMetadataEventClassification {
    /// The event's shared Git meaning.
    pub kind: GitMetadataChangeKind,
    /// A plain `index` or `index.lock` write in this worktree only.
    pub index_only: bool,
}

fn classified(kind: GitMetadataChangeKind, index_only: bool) -> GitMetadataEventClassification {
    GitMetadataEventClassification { kind, index_only }
}

/// Classifies one path using platform-resolved identities; it performs no IO.
pub fn classify_git_metadata_change(
    context: &GitMetadataWatchContext,
    path: &Path,
) -> GitMetadataEventClassification {
    use GitMetadataChangeKind::{Context, IgnoreRule, Ignored, Metadata, Other};
    if path == context.repository_root.join(".git")
        || context
            .workspace_root
            .as_ref()
            .is_some_and(|root| path == root.join(".git"))
    {
        return classified(Context, false);
    }
    if path.file_name().is_some_and(|name| name == ".gitignore")
        && (path.starts_with(&context.repository_root)
            || context
                .rule_directories
                .iter()
                .any(|root| path == root.join(".gitignore")))
    {
        return classified(IgnoreRule, false);
    }
    if let Ok(relative) = path.strip_prefix(&context.git_directory) {
        let mut components = relative.components();
        let first = components
            .next()
            .map(|part| part.as_os_str().to_string_lossy());
        if first
            .as_deref()
            .is_some_and(|name| name.starts_with(TEMPORARY_COMMIT_PREFIX))
        {
            return classified(Ignored, false);
        }
        // A submodule's Git directory lives under `modules`. Its HEAD and
        // index affect the parent checkout's gitlink status, so retain those
        // events conservatively until submodule roots can be identified.
        if first.as_deref() == Some("modules") {
            return classified(Metadata, false);
        }
        if !matches!(first.as_deref(), Some("objects" | "lfs" | "worktrees")) {
            let index_only = first
                .as_deref()
                .is_some_and(|name| matches!(name, "index" | "index.lock"))
                && components.next().is_none();
            return classified(Metadata, index_only);
        }
    }
    if let Ok(relative) = path.strip_prefix(&context.git_common_directory) {
        let parts: Vec<_> = relative
            .components()
            .map(|part| part.as_os_str().to_string_lossy())
            .collect();
        let relevant = match parts.first().map(|part| part.as_ref()) {
            None | Some("refs" | "packed-refs" | "config" | "shallow" | "info" | "modules") => true,
            Some("logs") => parts.get(1).is_some_and(|part| part == "refs"),
            Some("worktrees") => {
                parts.len() <= 2
                    || parts.get(2).is_some_and(|part| {
                        matches!(part.as_ref(), "HEAD" | "locked" | "gitdir" | "commondir")
                    })
            }
            _ => false,
        };
        return classified(if relevant { Metadata } else { Ignored }, false);
    }
    classified(Other, false)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    context: GitMetadataWatchContext,
    paths: Vec<PathBuf>,
}

/// JSON boundary used once per bounded watcher batch or page.
pub(crate) fn classify_command(payload: Value) -> Result<Value, CoreError> {
    let request: Request = serde_json::from_value(payload).map_err(|_| invalid())?;
    let valid_path =
        |path: &Path| !path.as_os_str().is_empty() && path.as_os_str().len() <= MAX_PATH_BYTES;
    if request.paths.len() > MAX_PATHS_PER_PAGE
        || request.context.rule_directories.len() > MAX_PATHS_PER_PAGE
        || !valid_path(&request.context.repository_root)
        || !valid_path(&request.context.git_directory)
        || !valid_path(&request.context.git_common_directory)
        || request
            .context
            .workspace_root
            .as_ref()
            .is_some_and(|path| !valid_path(path))
        || request
            .context
            .rule_directories
            .iter()
            .any(|path| !valid_path(path))
        || request.paths.iter().any(|path| !valid_path(path))
    {
        return Err(invalid());
    }
    let events: Vec<_> = request
        .paths
        .iter()
        .map(|path| classify_git_metadata_change(&request.context, path))
        .collect();
    Ok(json!({"events":events}))
}

fn invalid() -> CoreError {
    CoreError::new(
        ErrorCode::InvalidRequest,
        "Invalid Git metadata change batch",
    )
}
