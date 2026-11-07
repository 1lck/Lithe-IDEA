//! Shared Shelf capture, guarded cleanup, and retryable restoration steps.

use super::patch_exchange::{
    self, PatchApplyRequest, PatchExportRequest, PatchPreviewRequest, PatchSource, PatchTarget,
};
use super::{apply, execute_git_readonly, GitApplyRequest};
use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeSet;

/// Both patches are owned by the platform's durable Shelf record until deletion.
#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Snapshot {
    staged_patch: String,
    working_patch: String,
    paths: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Request {
    root: String,
    action: Action,
    layer: Option<Layer>,
    snapshot: Option<Snapshot>,
    phase: Option<Phase>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
enum Action {
    Capture,
    Plan,
    Clean,
    Restore,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
enum Phase {
    Clean,
    Restore,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
enum Layer {
    Staged,
    Working,
}

fn failure(message: &'static str) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, message)
}

fn capture(root: &str) -> Result<Snapshot, CoreError> {
    // `diff --quiet` can refresh index stat data even with optional locks
    // disabled. Listing unmerged index entries is read-only and includes every
    // conflict kind without touching the state token.
    let conflicts = execute_git_readonly(
        root,
        &["ls-files".into(), "--unmerged".into(), "-z".into()],
        None,
    )?;
    if conflicts.exit_code != 0 {
        return Err(failure("Could not inspect Shelf conflicts"));
    }
    if !conflicts.stdout.is_empty() {
        return Err(failure("SHELF_CONFLICTS"));
    }
    let export = |source, include_untracked| {
        patch_exchange::export(PatchExportRequest {
            root: root.to_string(),
            source,
            paths: Vec::new(),
            base_revision: None,
            target_revision: None,
            metadata_only: false,
            include_untracked,
        })
    };
    let staged = export(PatchSource::Staged, false)?;
    let working = export(PatchSource::Unstaged, true)?;
    let mut paths = BTreeSet::new();
    for file in staged.files.into_iter().chain(working.files) {
        paths.insert(file.path);
        if let Some(original) = file.original_path {
            paths.insert(original);
        }
    }
    Ok(Snapshot {
        staged_patch: staged.patch,
        working_patch: working.patch,
        paths: paths.into_iter().collect(),
    })
}

fn reviewed_apply(
    root: &str,
    patch: &str,
    target: PatchTarget,
    reverse: bool,
    clean_guard: Option<(&Snapshot, &Layer)>,
) -> Result<(), CoreError> {
    let preview = patch_exchange::preview(PatchPreviewRequest {
        root: root.to_string(),
        patch: patch.to_string(),
        target,
        reverse,
        metadata_only: false,
    })?;
    let Some(expected_state) = preview.expected_state else {
        return Err(failure("SHELF_CHANGED"));
    };
    // Verify after obtaining the token: edits during verification invalidate the
    // token, and edits before the token must appear in this fresh snapshot.
    if let Some((snapshot, layer)) = clean_guard {
        verify_clean(root, snapshot, layer)?;
    }
    let result = patch_exchange::apply_reviewed(PatchApplyRequest {
        root: root.to_string(),
        patch: patch.to_string(),
        target,
        reverse,
        expected_state,
    })
    .map_err(|error| {
        if error.message == "The patch or repository changed after preview. Preview it again."
            || error.message == "The repository changed while checking the patch. Preview it again."
        {
            failure("SHELF_CHANGED")
        } else {
            error
        }
    })?;
    if result.exit_code != 0 || result.operation_error.is_some() {
        return Err(failure("SHELF_CHANGED"));
    }
    Ok(())
}

fn verify_clean(root: &str, snapshot: &Snapshot, layer: &Layer) -> Result<(), CoreError> {
    let current = capture(root)?;
    if current.staged_patch != snapshot.staged_patch
        || match layer {
            Layer::Working => current.working_patch != snapshot.working_patch,
            Layer::Staged => !current.working_patch.is_empty(),
        }
    {
        return Err(failure("SHELF_CHANGED"));
    }
    Ok(())
}

fn execute(request: Request) -> Result<Value, CoreError> {
    if matches!(request.action, Action::Plan) {
        if request.layer.is_some() || request.snapshot.is_some() {
            return Err(failure("Invalid Shelf request"));
        }
        let layers = match request
            .phase
            .ok_or_else(|| failure("Invalid Shelf request"))?
        {
            Phase::Clean => ["working", "staged"],
            Phase::Restore => ["staged", "working"],
        };
        return Ok(json!({"layers": layers}));
    }
    if request.phase.is_some() {
        return Err(failure("Invalid Shelf request"));
    }
    if matches!(request.action, Action::Capture) {
        if request.layer.is_some() || request.snapshot.is_some() {
            return Err(failure("Invalid Shelf request"));
        }
        return serde_json::to_value(capture(&request.root)?)
            .map_err(|_| failure("Invalid Shelf snapshot"));
    }
    let layer = request
        .layer
        .ok_or_else(|| failure("Invalid Shelf request"))?;
    let snapshot = request
        .snapshot
        .ok_or_else(|| failure("Invalid Shelf request"))?;
    let (patch, target) = match layer {
        Layer::Working => (&snapshot.working_patch, PatchTarget::Worktree),
        Layer::Staged => (&snapshot.staged_patch, PatchTarget::IndexAndWorktree),
    };
    match request.action {
        Action::Clean => {
            if patch.is_empty() {
                verify_clean(&request.root, &snapshot, &layer)?;
            } else {
                reviewed_apply(
                    &request.root,
                    patch,
                    target,
                    true,
                    Some((&snapshot, &layer)),
                )?;
            }
        }
        Action::Restore => {
            if !patch.is_empty() {
                if let Err(original) = reviewed_apply(&request.root, patch, target, false, None) {
                    // A prior attempt may already have restored this layer. The
                    // staged check must ignore worktree edits from the next layer.
                    let check = apply(GitApplyRequest {
                        root: request.root,
                        patch: patch.to_string(),
                        mode: match layer {
                            Layer::Staged => "restoreIndexCheck",
                            Layer::Working => "worktreeCheck",
                        }
                        .into(),
                    })?;
                    if check.exit_code != 0 || check.operation_error.is_some() {
                        return Err(original);
                    }
                }
            }
        }
        Action::Capture | Action::Plan => unreachable!(),
    }
    Ok(json!({}))
}

/// Executes one Shelf step; hosts persist the snapshot and guard each call's session.
pub(crate) fn shelf_command(value: Value) -> Result<Value, CoreError> {
    let request = serde_json::from_value(value).map_err(|_| failure("Invalid Shelf request"))?;
    execute(request)
}
