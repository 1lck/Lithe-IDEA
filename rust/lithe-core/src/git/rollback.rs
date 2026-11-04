//! Plans explicit whole-file rollback without inspecting or mutating the worktree.

use super::{
    execute_git_with_environment, is_safe_pathspec, parse_status, validate_root,
    LS_FILES_PATHSPEC_BUDGET,
};
use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeSet, HashSet};

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
    plan(request)
}

fn plan(request: Request) -> Result<Value, CoreError> {
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
    rollback_plan_command(
        json!({"changes": request.changes, "deleteAddedFiles": request.delete_added_files}),
    )?;
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
            "--untracked-files=all".into(),
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
    let stale = || CoreError::new(ErrorCode::InvalidRequest, "GIT_ROLLBACK_STALE_SELECTION");
    let mut untracked = BTreeSet::new();
    let mut tracked = BTreeSet::new();
    for (path, original, status) in &actual {
        if status == "??" {
            untracked.insert(path.clone());
        } else {
            tracked.insert(path.clone());
            if let Some(source) = original {
                tracked.insert(source.clone());
            }
        }
    }
    let mut verified = Vec::new();
    for change in request.changes {
        if change.status != "??" {
            if !actual.contains(&(
                change.path.clone(),
                change.original_path.clone(),
                change.status.clone(),
            )) {
                return Err(stale());
            }
            verified.push(change);
        } else if change.path.ends_with('/') {
            // Expand a directory to the observed files so files created after
            // preparation cannot be swept up by a later directory clean.
            if tracked
                .range(change.path.clone()..)
                .next()
                .is_some_and(|p| p.starts_with(&change.path))
            {
                return Err(stale());
            }
            let files: Vec<_> = untracked
                .range(change.path.clone()..)
                .take_while(|p| p.starts_with(&change.path))
                .cloned()
                .collect();
            if files.is_empty() {
                return Err(stale());
            }
            verified.extend(files.into_iter().map(|path| Change {
                path,
                original_path: None,
                status: "??".into(),
            }));
        } else {
            if !untracked.contains(&change.path) || tracked.contains(&change.path) {
                return Err(stale());
            }
            verified.push(change);
        }
    }
    // The client selection is bounded above; a single reviewed directory may
    // legitimately expand to more files than that selection limit.
    plan(Request {
        changes: verified,
        delete_added_files: request.delete_added_files,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn expanded_directory_is_not_limited_by_client_selection_count() {
        let changes = (0..=MAX_CHANGES)
            .map(|index| Change {
                path: format!("directory/file-{index}"),
                original_path: None,
                status: "??".into(),
            })
            .collect();
        let result = plan(Request {
            changes,
            delete_added_files: true,
        })
        .unwrap();
        assert_eq!(
            result["steps"][0]["paths"].as_array().unwrap().len(),
            MAX_CHANGES + 1
        );
    }
}
