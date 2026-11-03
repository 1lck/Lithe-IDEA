//! Reconciles selected staged additions after filesystem deletion.

use super::{
    execute_git_readonly_with_environment, is_safe_pathspec, parse_status, pathspec_batches,
    rewrite::RewriteLease, unstage_paths, validate_root, LS_FILES_PATHSPEC_BUDGET,
};
use crate::protocol::{CoreError, ErrorCode};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::BTreeSet;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Request {
    root: String,
    changes: Vec<Change>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Change {
    path: String,
    status: String,
}

fn invalid() -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, "Invalid deleted Git selection")
}

/// Read actual status and remove only explicitly selected, now missing staged additions.
pub(crate) fn reconcile_deleted_selection_command(payload: Value) -> Result<Value, CoreError> {
    let request: Request = serde_json::from_value(payload).map_err(|_| invalid())?;
    if request.changes.len() > 10_000 {
        return Err(invalid());
    }
    let mut candidates = BTreeSet::new();
    for change in request.changes {
        if change.path.len() > LS_FILES_PATHSPEC_BUDGET
            || !is_safe_pathspec(&change.path)
            || change.path.contains('\0')
            || change.status.len() != 2
            || !change.status.is_ascii()
        {
            return Err(invalid());
        }
        let bytes = change.status.as_bytes();
        // Copies are owned by their destination only. Conflicted additions and
        // directories are never expanded into an index write.
        if matches!(bytes[0], b'A' | b'C')
            && !matches!(bytes[1], b'A' | b'U')
            && !change.path.ends_with('/')
        {
            candidates.insert(change.path);
        }
    }
    if candidates.is_empty() {
        return Ok(json!({"unstaged": []}));
    }
    let root = validate_root(&request.root)?;
    let _lease = RewriteLease::acquire(&root)?;
    let literal = [("GIT_LITERAL_PATHSPECS".to_string(), "1".to_string())];
    let paths: Vec<_> = candidates.iter().cloned().collect();
    let mut missing = BTreeSet::new();
    for batch in pathspec_batches(&paths, LS_FILES_PATHSPEC_BUDGET) {
        crate::protocol::cancellation::check()?;
        let mut args = [
            "status",
            "--porcelain=v2",
            "--ignore-submodules=none",
            "--untracked-files=no",
            "-z",
            "--",
        ]
        .map(str::to_string)
        .to_vec();
        args.extend_from_slice(batch);
        let output = execute_git_readonly_with_environment(&root, &args, None, &literal)?;
        if output.exit_code != 0 {
            return Err(CoreError::new(
                ErrorCode::ProcessFailed,
                "Could not inspect deleted Git files",
            )
            .with_details(output.output));
        }
        for change in parse_status(output.stdout.as_bytes(), true) {
            let status = change.status.as_bytes();
            if candidates.contains(&change.path)
                && status.len() == 2
                && matches!(status[0], b'A' | b'C')
                && status[1] == b'D'
            {
                missing.insert(change.path);
            }
        }
    }
    let paths: Vec<_> = missing.into_iter().collect();
    if !paths.is_empty() {
        crate::protocol::cancellation::check()?;
        let output = unstage_paths(&root, &paths)?;
        if output.exit_code != 0 {
            return Err(CoreError::new(
                ErrorCode::ProcessFailed,
                "Could not unstage deleted Git additions",
            )
            .with_details(output.output));
        }
    }
    Ok(json!({"unstaged": paths}))
}
