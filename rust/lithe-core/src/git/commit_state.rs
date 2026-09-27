//! Shared commit preconditions and exact submodule pointer updates.

use super::{execute_git, execute_git_readonly, validate_paths, validate_root, GitStatusRequest};
use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Immutable Git state reviewed before a workspace commit or retry.
pub struct GitCommitState {
    pub head: Option<String>,
    pub branch: Option<String>,
    /// Git's NUL-delimited index entries, including object IDs and conflict stages.
    pub index_entries: String,
    pub gitlinks: Vec<GitCommitGitlink>,
    pub staged_paths: Vec<String>,
    pub conflicted_paths: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
/// An exact submodule commit recorded at a parent-relative path.
pub struct GitCommitGitlink {
    pub path: String,
    pub revision: String,
}

fn read(root: &str, arguments: &[&str]) -> Result<String, CoreError> {
    let result = execute_git_readonly(
        root,
        &arguments.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
        None,
    )?;
    if result.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Could not inspect commit state")
                .with_details(result.output),
        );
    }
    Ok(result.stdout)
}

/// Reads HEAD and index through Git, without refreshing or modifying the index.
pub fn inspect(request: GitStatusRequest) -> Result<GitCommitState, CoreError> {
    let root = validate_root(&request.root)?;
    inspect_root(&root)
}

/// Confirms an unborn branch without treating corrupt refs as empty history.
pub(super) fn is_unborn(root: &str) -> Result<bool, CoreError> {
    head_state(root).map(|(head, _)| head.is_none())
}

fn head_state(root: &str) -> Result<(Option<String>, Option<String>), CoreError> {
    // `--verify HEAD` cannot distinguish an unborn branch from a corrupt ref.
    // show-ref's documented exit 1 means the symbolic branch does not exist.
    let symbolic = execute_git_readonly(
        root,
        &["symbolic-ref".into(), "--quiet".into(), "HEAD".into()],
        None,
    )?;
    let branch = if symbolic.exit_code == 0 {
        Some(symbolic.stdout.trim().to_string())
    } else if symbolic.exit_code == 1 {
        None
    } else {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Could not inspect HEAD")
                .with_details(symbolic.output),
        );
    };
    let head = if let Some(branch) = &branch {
        let exists = execute_git_readonly(
            root,
            &[
                "show-ref".into(),
                "--verify".into(),
                "--quiet".into(),
                branch.clone(),
            ],
            None,
        )?;
        match exists.exit_code {
            0 => Some(
                read(root, &["rev-parse", "--verify", "HEAD^{commit}"])?
                    .trim()
                    .to_string(),
            ),
            1 => None,
            _ => {
                return Err(
                    CoreError::new(ErrorCode::ProcessFailed, "Could not inspect branch")
                        .with_details(exists.output),
                )
            }
        }
    } else {
        Some(
            read(root, &["rev-parse", "--verify", "HEAD^{commit}"])?
                .trim()
                .to_string(),
        )
    };
    Ok((head, branch))
}

pub(super) fn inspect_root(root: &str) -> Result<GitCommitState, CoreError> {
    let (head, branch) = head_state(root)?;
    let index_entries = read(root, &["ls-files", "--stage", "-z"])?;
    let gitlinks = index_entries
        .split('\0')
        .filter_map(|record| {
            let (header, path) = record.split_once('\t')?;
            let mut fields = header.split_whitespace();
            if fields.next()? != "160000" {
                return None;
            }
            let revision = fields.next()?.to_string();
            if fields.next()? != "0" {
                return None;
            }
            Some(GitCommitGitlink {
                path: path.to_string(),
                revision,
            })
        })
        .collect();
    let conflicted_paths = index_entries
        .split('\0')
        .filter_map(|record| {
            let (header, path) = record.split_once('\t')?;
            let stage = header.split_whitespace().nth(2)?;
            (stage != "0").then(|| path.to_string())
        })
        .collect::<std::collections::BTreeSet<_>>()
        .into_iter()
        .collect();
    let staged_paths = read(
        root,
        &[
            "diff",
            "--cached",
            "--name-only",
            "--ignore-submodules=none",
            "-z",
        ],
    )?
    .split('\0')
    .filter(|path| !path.is_empty())
    .map(str::to_string)
    .collect();
    Ok(GitCommitState {
        head,
        branch,
        index_entries,
        gitlinks,
        staged_paths,
        conflicted_paths,
    })
}

/// Validates the reviewed state under the typed writer lease before changing
/// any parent pointers. Unrelated staged files retain their exact index content.
pub(super) fn prepare(
    root: &str,
    expected: &GitCommitState,
    updates: &[GitCommitGitlink],
) -> Result<(), CoreError> {
    if inspect_root(root)? != *expected {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Commit plan changed; review it again",
        ));
    }
    if !expected.conflicted_paths.is_empty() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Resolve repository conflicts before committing",
        ));
    }
    for update in updates {
        validate_paths(std::slice::from_ref(&update.path))?;
        if !expected
            .gitlinks
            .iter()
            .any(|entry| entry.path == update.path)
            || !matches!(update.revision.len(), 40 | 64)
            || !update.revision.bytes().all(|byte| byte.is_ascii_hexdigit())
        {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Invalid submodule pointer update",
            ));
        }
        let child = std::path::Path::new(root).join(&update.path);
        let actual = read(
            &child.to_string_lossy(),
            &["rev-parse", "--verify", "HEAD^{commit}"],
        )?;
        if actual.trim() != update.revision {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Submodule changed; review the commit plan again",
            ));
        }
    }
    if !updates.is_empty() {
        // One index transaction; use NUL records so spaces, tabs and newlines in
        // paths remain literal. Never run `git add` on unrelated parent files.
        let input = updates
            .iter()
            .map(|update| format!("160000 {}\t{}\0", update.revision, update.path))
            .collect::<String>();
        let result = execute_git(
            root,
            &["update-index".into(), "-z".into(), "--index-info".into()],
            Some(input),
        )?;
        if result.exit_code != 0 {
            return Err(CoreError::new(
                ErrorCode::ProcessFailed,
                "Could not update submodule references",
            )
            .with_details(result.output));
        }
    }
    Ok(())
}
