//! Plans explicit whole-file rollback without inspecting or mutating the worktree.

use super::{
    execute_git_with_environment, is_safe_pathspec, parse_status, validate_root,
    LS_FILES_PATHSPEC_BUDGET,
};
use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashSet;

const MAX_CHANGES: usize = 10_000;

#[derive(Deserialize, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct Request {
    changes: Vec<Change>,
    #[serde(default)]
    delete_added_files: bool,
}

#[derive(Deserialize, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct Change {
    path: String,
    #[serde(default)]
    original_path: Option<String>,
    status: String,
}

#[derive(Serialize)]
struct Step {
    operation: &'static str,
    paths: Vec<String>,
}

fn push_step(steps: &mut Vec<Step>, operation: &'static str, paths: Vec<String>) {
    // Batch the stdin-backed operations so large selections do not spawn Git
    // once per file. Discard uses argv and must retain its bounded path count.
    if operation != "discard" {
        if let Some(last) = steps.last_mut().filter(|last| last.operation == operation) {
            last.paths.extend(paths);
            return;
        }
    }
    steps.push(Step { operation, paths });
}

fn invalid() -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, "Invalid Git rollback selection")
}

fn safe_path(path: &str) -> bool {
    is_safe_pathspec(path) && !path.contains('\0')
}

pub(crate) fn rollback_plan_command(payload: Value) -> Result<Value, CoreError> {
    let request: Request = serde_json::from_value(payload).map_err(|_| invalid())?;
    if request.changes.len() > MAX_CHANGES {
        return Err(invalid());
    }
    let mut identities = HashSet::new();
    let mut claimed = HashSet::new();
    let mut steps = Vec::new();
    for change in request.changes {
        if !safe_path(&change.path)
            || change
                .original_path
                .as_deref()
                .is_some_and(|path| !safe_path(path))
        {
            return Err(invalid());
        }
        let status = change.status.as_bytes();
        if status.len() != 2
            || status.iter().any(|ch| !b" MADRCUT?".contains(ch))
            || (status.contains(&b'?') && status != b"??")
            || status == b"  "
        {
            return Err(invalid());
        }
        if !identities.insert((
            change.path.clone(),
            change.original_path.clone(),
            change.status.clone(),
        )) {
            continue;
        }
        let (index, worktree) = (status[0], status[1]);
        let conflicted = index == b'U' || worktree == b'U' || status == b"AA" || status == b"DD";
        let untracked = status == b"??";
        let copied = index == b'C' || worktree == b'C';
        let renamed = index == b'R' || worktree == b'R';
        if copied && renamed {
            return Err(invalid());
        }
        if change.original_path.is_some() && !copied && !renamed {
            return Err(invalid());
        }
        let mut paths = vec![change.path.clone()];
        if renamed && !copied {
            let source = change.original_path.ok_or_else(invalid)?;
            if source == change.path {
                return Err(invalid());
            }
            paths.insert(0, source);
        }
        if paths.iter().any(|path| !claimed.insert(path.clone())) {
            return Err(invalid());
        }
        if untracked {
            if request.delete_added_files {
                push_step(&mut steps, "discardAll", paths);
            }
        } else if !conflicted && (index == b'A' || worktree == b'A' || copied) {
            if index != b' ' || worktree == b'A' || copied {
                push_step(&mut steps, "unstage", paths.clone());
            }
            if request.delete_added_files {
                push_step(&mut steps, "discard", paths);
            }
        } else {
            push_step(&mut steps, "discardAll", paths);
        }
    }
    Ok(json!({"steps": steps}))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PrepareRequest {
    root: String,
    changes: Vec<Change>,
    #[serde(default)]
    delete_added_files: bool,
}

// Recheck the selected identities after confirmation, without enumerating an
// entire repository. Keep both sides of a rename in the same bounded Git call.
pub(crate) fn rollback_prepare_command(payload: Value) -> Result<Value, CoreError> {
    let request: PrepareRequest = serde_json::from_value(payload).map_err(|_| invalid())?;
    let plan = rollback_plan_command(
        json!({"changes": request.changes, "deleteAddedFiles": request.delete_added_files}),
    )?;
    if request.changes.iter().any(|change| change.status == "??") {
        return Err(invalid());
    }
    let root = validate_root(&request.root)?;
    let literal = [("GIT_LITERAL_PATHSPECS".to_string(), "1".to_string())];
    let mut actual = HashSet::new();
    let mut batch = Vec::new();
    let mut bytes = 0usize;
    let collect = |paths: &mut Vec<String>,
                   actual: &mut HashSet<(String, Option<String>, String)>|
     -> Result<(), CoreError> {
        if paths.is_empty() {
            return Ok(());
        }
        let mut args = vec![
            "status".into(),
            "--porcelain=v2".into(),
            "-z".into(),
            "--untracked-files=no".into(),
            "--".into(),
        ];
        args.append(paths);
        let output = execute_git_with_environment(&root, &args, None, true, &literal)?;
        if output.exit_code != 0 {
            return Err(CoreError::new(
                ErrorCode::ProcessFailed,
                "Git rollback status check failed",
            ));
        }
        actual.extend(
            parse_status(output.stdout.as_bytes(), true)
                .into_iter()
                .map(|change| (change.path, change.original_path, change.status)),
        );
        Ok(())
    };
    for change in &request.changes {
        let group = std::iter::once(&change.path)
            .chain(change.original_path.iter())
            .collect::<Vec<_>>();
        let size = group.iter().map(|path| path.len() + 1).sum::<usize>();
        if size > LS_FILES_PATHSPEC_BUDGET {
            return Err(invalid());
        }
        if bytes + size > LS_FILES_PATHSPEC_BUDGET {
            collect(&mut batch, &mut actual)?;
            bytes = 0;
        }
        batch.extend(group.into_iter().cloned());
        bytes += size;
    }
    collect(&mut batch, &mut actual)?;
    for change in request.changes {
        if !actual.contains(&(change.path, change.original_path, change.status)) {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "GIT_ROLLBACK_STALE_SELECTION",
            ));
        }
    }
    Ok(plan)
}
