//! Shared Git mutation helpers kept outside the command facade.

use super::{execute_git, is_safe_pathspec};
use crate::protocol::{CoreError, ErrorCode};

pub(super) fn remote_branch_components(
    root: &str,
    reference: &str,
) -> Result<(String, String), CoreError> {
    let remote_path = reference
        .strip_prefix("refs/remotes/")
        .ok_or_else(|| CoreError::new(ErrorCode::InvalidRequest, "Invalid remote branch name"))?;
    let remotes = execute_git(root, &["remote".into()], None)?;
    if remotes.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Git remote lookup failed")
                .with_details(remotes.output),
        );
    }
    let mut matches = remotes
        .output
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
