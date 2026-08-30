//! Shared Git mutation helpers kept outside the command facade.

use super::{capture_git_with_options, is_safe_pathspec};
use crate::protocol::{CoreError, ErrorCode};

use super::{
    current_branch, execute_git, switch_reference, validated_reference, GitCommandResponse,
    GitWriteRequest,
};

/// Checks out a branch and rebases it onto the branch that was current before the switch.
pub(super) fn checkout_and_rebase(
    root: &str,
    request: GitWriteRequest,
) -> Result<GitCommandResponse, CoreError> {
    if !matches!(request.reference_kind.as_deref(), Some("local" | "remote")) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Checkout and rebase requires a local or remote branch",
        ));
    }
    let original_branch = current_branch(root)?;
    let reference = validated_reference(request.reference.as_deref())?;
    if reference == original_branch || reference == format!("refs/heads/{original_branch}") {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "The current branch cannot be checked out and rebased onto itself",
        ));
    }
    let status = execute_git(
        root,
        &[
            "status".into(),
            "--porcelain".into(),
            "--untracked-files=normal".into(),
        ],
        None,
    )?;
    if status.exit_code != 0 {
        return Ok(status);
    }
    if !status.output.trim().is_empty() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Checkout and rebase requires a clean working tree",
        ));
    }
    let switched = switch_reference(root, &request)?;
    if switched.exit_code != 0 {
        return Ok(switched);
    }
    execute_git(
        root,
        &["rebase".into(), format!("refs/heads/{original_branch}")],
        None,
    )
}

pub(super) fn remote_branch_components(
    root: &str,
    reference: &str,
) -> Result<(String, String), CoreError> {
    let remote_path = reference
        .strip_prefix("refs/remotes/")
        .ok_or_else(|| CoreError::new(ErrorCode::InvalidRequest, "Invalid remote branch name"))?;
    let remotes = capture_git_with_options(root, &["remote".into()], None, true)?;
    let remote_output = String::from_utf8_lossy(&remotes.stdout).to_string();
    if remotes.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Git remote lookup failed")
                .with_details(String::from_utf8_lossy(&remotes.stderr).to_string()),
        );
    }
    let mut matches = remote_output
        .lines()
        .map(str::trim)
        .filter(|remote| !remote.is_empty() && remote_path.starts_with(&format!("{remote}/")))
        .collect::<Vec<_>>();
    matches.sort_by_key(|remote| std::cmp::Reverse(remote.len()));
    let Some(remote) = matches.first().copied() else {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid remote branch name",
        ));
    };
    let branch = remote_path
        .strip_prefix(&format!("{remote}/"))
        .unwrap_or_default();
    if branch.is_empty()
        || remote.starts_with('-')
        || branch.starts_with('-')
        || !is_safe_pathspec(remote)
        || !is_safe_pathspec(branch)
    {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid remote branch name",
        ));
    }
    Ok((remote.to_string(), branch.to_string()))
}
