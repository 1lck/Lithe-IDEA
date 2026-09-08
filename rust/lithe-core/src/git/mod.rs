//! Deterministic Git inspection and mutation behind the shared command contract.

// The initial projection/routing IR is deliberately not command- or host-facing
// until both native products can consume the same versioned contract.
#[allow(dead_code)]
pub(crate) mod graph;
mod history;
mod mutations;

pub use history::{
    close_history_cursor, history, history_page, references, GitHistoryCursorCloseRequest,
    GitHistoryPageRequest, GitHistoryRequest, GitReferencesRequest,
};

use crate::protocol::{CoreError, ErrorCode};
use crate::protocol::{
    GitBlameLineResponse, GitBlameResponse, GitChange, GitCheckoutPreflightResponse,
    GitCommitLookupResponse, GitCommitResponse, GitComparisonResponse, GitConflictMarkerResponse,
    GitDiffHunkResponse, GitDiffResponse, GitDiffRowResponse, GitFileResponse, GitFilesResponse,
    GitIntegrationPreflightResponse, GitOperationStateResponse, GitPullPreflightResponse,
    GitPushPreviewResponse, GitPushTagResponse, GitReferenceResponse, GitStashResponse,
    GitStashesResponse, GitStatusResponse, GitWatchContextResponse, GitWorktreeResponse,
    GitWorktreesResponse,
};
use serde::{Deserialize, Serialize};
use std::cell::RefCell;
use std::collections::HashSet;
use std::io::Read;
use std::io::Write;
#[cfg(target_os = "windows")]
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::Duration;

const DEFAULT_PUSH_PREVIEW_LIMIT: usize = 500;
static TEMPORARY_INDEX_SEQUENCE: AtomicU64 = AtomicU64::new(0);
static AUTO_STASH_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request for a deterministic porcelain status snapshot.
pub struct GitStatusRequest {
    pub root: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request for the directories and files a host watcher should observe.
pub struct GitWatchContextRequest {
    pub root: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request for all worktrees registered in the current repository.
pub struct GitWorktreesRequest {
    pub root: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request for branch and publication state used by pull request creation.
pub struct GitPullRequestContextRequest {
    pub root: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
/// Worktree-aware branch defaults and publication requirements for a pull request.
pub struct GitPullRequestContextResponse {
    /// Checked-out local branch, or `None` when HEAD is detached.
    pub current_branch: Option<String>,
    /// Best-effort branch that should receive the pull request.
    pub suggested_base_branch: Option<String>,
    /// Branch name shown when the current commit must be published first.
    pub suggested_publish_branch: Option<String>,
    /// Whether GitHub cannot yet see the current local HEAD.
    pub requires_publish: bool,
    /// Whether the worktree has no checked-out local branch.
    pub detached: bool,
    /// Whether tracked or untracked working-tree changes are not part of HEAD.
    pub has_uncommitted_changes: bool,
}

/// Executes one Git operation without invoking a shell.
///
/// The command boundary is intentionally argument-based. This keeps command
/// construction in the application layer while making process execution
/// available to every UI binding through the same Rust core.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitCommandRequest {
    pub root: String,
    #[serde(default)]
    pub arguments: Vec<String>,
    #[serde(default)]
    pub input: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// One Git subprocess executed while fulfilling a shared Git command.
pub struct GitCommandInvocation {
    /// Exact arguments passed to the Git executable, excluding the executable name.
    pub arguments: Vec<String>,
    /// Text captured from the Git process standard output stream.
    pub stdout: String,
    /// Text captured from the Git process standard error stream.
    pub stderr: String,
    /// Exit status returned by the Git process.
    pub exit_code: i32,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
/// Stable output returned by argument-based Git execution.
pub struct GitCommandResponse {
    /// Exact arguments for the final Git subprocess, retained for compatibility.
    pub arguments: Vec<String>,
    /// Backward-compatible concatenation of standard output followed by standard error.
    pub output: String,
    /// Text captured from the final Git process standard output stream.
    pub stdout: String,
    /// Text captured from the final Git process standard error stream.
    pub stderr: String,
    /// Exit status returned by the final Git process.
    pub exit_code: i32,
    /// Every Git subprocess executed for the operation, in execution order.
    pub invocations: Vec<GitCommandInvocation>,
    /// Failure discovered after one or more subprocesses were recorded.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub operation_error: Option<CoreError>,
    /// Present when a stash restore kept its entry because the working tree
    /// contains an unresolved merge. Keeping this out of the prose response
    /// lets bindings offer recovery actions without matching localized Git
    /// output.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stash_restore: Option<GitStashRestoreResponse>,
    /// Present when a tag deletion succeeded, carrying everything a host needs
    /// to offer a restore without re-querying the repository.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tag_deletion: Option<GitTagDeletionResponse>,
    /// Present when a local branch deletion succeeded, carrying the commit the
    /// branch pointed at so the host can offer to recreate it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub branch_deletion: Option<GitBranchDeletionResponse>,
    /// Non-fatal follow-up failures after the requested repository mutation succeeded.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub warnings: Vec<GitOperationWarning>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Stable non-fatal outcome emitted after a Git mutation has already succeeded.
pub struct GitOperationWarning {
    /// Machine-readable warning category interpreted by platform presentation.
    pub code: String,
    /// Safe English fallback for clients without a localized presentation.
    pub message: String,
    /// Optional Git diagnostic retained for troubleshooting.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<String>,
}

impl GitOperationWarning {
    fn new(code: &str, message: &str, details: Option<String>) -> Self {
        Self {
            code: code.to_string(),
            message: message.to_string(),
            details,
        }
    }
}

/// Raw Git process streams kept separate for machine-readable consumers.
struct GitProcessOutput {
    stdout: Vec<u8>,
    stderr: Vec<u8>,
    exit_code: i32,
}

impl GitProcessOutput {
    fn into_command_response(self, arguments: &[String]) -> GitCommandResponse {
        let stdout = String::from_utf8_lossy(&self.stdout).to_string();
        let stderr = String::from_utf8_lossy(&self.stderr).to_string();
        let invocation = GitCommandInvocation {
            arguments: arguments.to_vec(),
            stdout: stdout.clone(),
            stderr: stderr.clone(),
            exit_code: self.exit_code,
        };
        let output = format!("{stdout}{stderr}");
        GitCommandResponse {
            arguments: arguments.to_vec(),
            output,
            stdout,
            stderr,
            exit_code: self.exit_code,
            invocations: vec![invocation],
            operation_error: None,
            stash_restore: None,
            tag_deletion: None,
            branch_deletion: None,
            warnings: Vec::new(),
        }
    }
}

thread_local! {
    static GIT_INVOCATION_TRACE: RefCell<Option<Vec<GitCommandInvocation>>> = const {
        RefCell::new(None)
    };
}

fn with_git_invocation_trace(
    operation: impl FnOnce() -> Result<GitCommandResponse, CoreError>,
) -> Result<GitCommandResponse, CoreError> {
    let previous = GIT_INVOCATION_TRACE.with(|trace| trace.replace(Some(Vec::new())));
    let result = operation();
    let invocations = GIT_INVOCATION_TRACE
        .with(|trace| trace.replace(previous))
        .unwrap_or_default();

    match result {
        Ok(mut response) => {
            response.invocations = invocations;
            synchronize_final_invocation(&mut response);
            Ok(response)
        }
        Err(error) if !invocations.is_empty() => {
            // A composite Git operation may complete subprocesses before a
            // follow-up probe fails. Preserve those diagnostics as command data
            // instead of replacing them with an empty error result.
            let mut response = failed_git_result(error);
            response.invocations = invocations;
            synchronize_final_invocation(&mut response);
            Ok(response)
        }
        Err(error) => Err(error),
    }
}

fn synchronize_final_invocation(response: &mut GitCommandResponse) {
    if response.exit_code == 0 && !response.warnings.is_empty() {
        // The mutation already succeeded and a later reconciliation step only
        // produced a warning. Keep the authoritative success summary while the
        // failed follow-up remains available in `invocations` and `warnings`.
        return;
    }
    let Some(final_invocation) = response.invocations.last() else {
        return;
    };
    response.arguments = final_invocation.arguments.clone();
    response.stdout = final_invocation.stdout.clone();
    response.stderr = final_invocation.stderr.clone();
    response.output = format!("{}{}", response.stdout, response.stderr);
    response.exit_code = final_invocation.exit_code;
}

fn record_git_invocation(response: &GitCommandResponse) {
    let Some(invocation) = response.invocations.first().cloned() else {
        return;
    };
    GIT_INVOCATION_TRACE.with(|trace| {
        if let Some(invocations) = trace.borrow_mut().as_mut() {
            invocations.push(invocation);
        }
    });
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Recovery context when restoring a stash produces conflicts.
pub struct GitStashRestoreResponse {
    pub stash_reference: String,
    pub conflicted_paths: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Deletion record that lets a host rebuild the deleted tag later.
///
/// `deleted_target` is the commit the deleted ref resolved to (peeled for
/// annotated tags), so a restore can re-point a new tag at the same commit.
pub struct GitTagDeletionResponse {
    /// Short name of the deleted tag, without the `refs/tags/` prefix.
    pub name: String,
    pub deleted_target: String,
    /// `lightweight` or `annotated`, taken from the tag object type.
    pub kind: String,
    /// Annotation message; `None` only for lightweight tags. Empty annotated
    /// messages remain `Some` so a restore does not change the tag form.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Deletion record that lets a host recreate the deleted local branch later.
pub struct GitBranchDeletionResponse {
    /// Short branch name, without the `refs/heads/` prefix.
    pub name: String,
    /// Commit the deleted branch pointed at when it was removed.
    pub deleted_target: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Complete identity of a Git reference supplied by a platform client.
pub struct GitReferenceRequest {
    /// Fully qualified reference, such as `refs/remotes/origin/main`.
    pub full_name: String,
    /// User-facing short name, such as `origin/main`.
    pub short_name: String,
    /// Reference namespace: `local`, `remote`, or `tag`.
    pub kind: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Repository snapshot that a previously reviewed push preview was based on.
pub struct GitPushExpectationRequest {
    /// Local branch resolved when the preview was created.
    pub local_branch: String,
    /// Commit at the tip of the local branch when the preview was created.
    pub local_head: String,
    /// Push remote resolved from the repository configuration.
    pub remote: String,
    /// Destination branch name on the resolved remote.
    pub remote_branch: String,
    /// Locally observed destination OID, or `None` when the remote branch was absent.
    #[serde(default)]
    pub remote_tracking_oid: Option<String>,
    /// Exact reviewed tags that may be sent with the branch.
    #[serde(default)]
    pub tags: Vec<GitPushTagExpectationRequest>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// One tag identity copied from a push preview into the mutation request.
pub struct GitPushTagExpectationRequest {
    /// Fully qualified tag reference under `refs/tags/`.
    pub full_name: String,
    /// Tag object ID observed while the preview was created.
    pub object_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Typed mutation request translated into a controlled Git invocation.
pub struct GitWriteRequest {
    pub root: String,
    /// Stable mutation discriminator interpreted by [`write`].
    pub operation: String,
    #[serde(default)]
    pub paths: Vec<String>,
    #[serde(default)]
    pub reference: Option<String>,
    /// Preferred typed reference. Legacy callers may still use `reference` and
    /// `referenceKind`, but new cross-platform workflows send all identity fields.
    #[serde(default)]
    pub git_reference: Option<GitReferenceRequest>,
    /// Reference category used by checkout: `local`, `remote`, or `tag`.
    #[serde(default)]
    pub reference_kind: Option<String>,
    #[serde(default)]
    pub revision: Option<String>,
    /// Commit revisions selected by an operation that rewrites a contiguous range.
    #[serde(default)]
    pub revisions: Vec<String>,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub remote: Option<String>,
    #[serde(default)]
    pub destination: Option<String>,
    /// Operation-specific strategy, such as reset mode or pull reconciliation.
    #[serde(default)]
    pub mode: Option<String>,
    #[serde(default)]
    pub include_untracked: bool,
    #[serde(default)]
    pub checkout: bool,
    #[serde(default)]
    pub amend: bool,
    #[serde(default)]
    pub force: bool,
    /// Tag scope for push: `none`, `all`, or `reachable`.
    #[serde(default)]
    pub push_tags: Option<String>,
    /// Optional reviewed preview snapshot that must still match before pushing.
    #[serde(default)]
    pub expected_push: Option<GitPushExpectationRequest>,
    #[serde(default)]
    pub auto_stash: bool,
}

/// Isolated Git administration directory used to commit a reviewed snapshot.
struct TemporaryGitCommitContext {
    directory: PathBuf,
    index_path: PathBuf,
    temporary_reference: Option<String>,
}

impl TemporaryGitCommitContext {
    fn prepare(root: &str, head: Option<&str>) -> Result<Self, CoreError> {
        let common_directory = git_resolved_path(
            root,
            &["rev-parse", "--path-format=absolute", "--git-common-dir"],
            "Git common directory",
        )?;
        let (directory, sequence) = loop {
            let sequence = TEMPORARY_INDEX_SEQUENCE.fetch_add(1, Ordering::Relaxed);
            let candidate =
                common_directory.join(format!("lithe-commit-{}-{sequence}", std::process::id()));
            if !candidate.exists() {
                break (candidate, sequence);
            }
        };
        std::fs::create_dir(&directory).map_err(|error| {
            CoreError::new(
                ErrorCode::Unknown,
                "Could not create an isolated Git commit context",
            )
            .with_details(error.to_string())
        })?;
        let temporary_reference = head.is_none().then(|| {
            format!(
                "refs/lithe/selected-commit-{}-{sequence}",
                std::process::id()
            )
        });
        let head_contents = head.map(|head| format!("{head}\n")).unwrap_or_else(|| {
            format!(
                "ref: {}\n",
                temporary_reference
                    .as_deref()
                    .expect("an unborn repository needs a temporary reference")
            )
        });
        std::fs::write(directory.join("HEAD"), head_contents).map_err(|error| {
            CoreError::new(
                ErrorCode::Unknown,
                "Could not initialize an isolated Git commit context",
            )
            .with_details(error.to_string())
        })?;
        let index_path = directory.join("index");
        Ok(Self {
            directory,
            index_path,
            temporary_reference,
        })
    }

    fn environment(&self, root: &str, common_directory: &Path) -> Vec<(String, String)> {
        vec![
            (
                "GIT_DIR".to_string(),
                self.directory.to_string_lossy().into_owned(),
            ),
            (
                "GIT_COMMON_DIR".to_string(),
                common_directory.to_string_lossy().into_owned(),
            ),
            ("GIT_WORK_TREE".to_string(), root.to_string()),
            (
                "GIT_INDEX_FILE".to_string(),
                self.index_path.to_string_lossy().into_owned(),
            ),
        ]
    }

    fn cleanup_reference(&self, root: &str) -> Result<(), CoreError> {
        let Some(reference) = self.temporary_reference.as_ref() else {
            return Ok(());
        };
        let arguments = vec!["update-ref".into(), "-d".into(), reference.clone()];
        let removed = capture_git_with_options(root, &arguments, None, false)?;
        if removed.exit_code != 0 {
            return Err(CoreError::new(
                ErrorCode::ProcessFailed,
                "Could not remove temporary Git reference",
            )
            .with_details(String::from_utf8_lossy(&removed.stderr)));
        }
        Ok(())
    }
}

impl Drop for TemporaryGitCommitContext {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request to resolve the exact destination and commits for a branch push.
pub struct GitPushPreviewRequest {
    pub root: String,
    #[serde(default)]
    pub reference: Option<String>,
    /// Preferred complete local branch identity.
    #[serde(default)]
    pub git_reference: Option<GitReferenceRequest>,
    #[serde(default = "default_push_preview_limit")]
    pub limit: usize,
    /// Tag scope to resolve into an immutable preview: `none`, `all`, or `reachable`.
    #[serde(default)]
    pub push_tags: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request for a structured diff suitable for side-by-side rendering.
pub struct GitDiffRequest {
    pub root: String,
    pub pathspecs: Vec<String>,
    #[serde(default)]
    pub reference: Option<String>,
    /// Compare the supplied legacy `reference` target against Git's empty tree.
    /// This is used for cumulative review ranges that begin with a root commit.
    #[serde(default)]
    pub empty_tree_base: bool,
    #[serde(default)]
    pub git_reference: Option<GitReferenceRequest>,
    /// Optional typed comparison target. When present, `gitReference` is the
    /// base and Core constructs the validated two-reference range.
    #[serde(default)]
    pub target_git_reference: Option<GitReferenceRequest>,
    #[serde(default)]
    pub commit: Option<String>,
    #[serde(default)]
    pub staged: bool,
    #[serde(default)]
    pub untracked: bool,
    /// Compare HEAD with the complete worktree state that a selected-path
    /// commit would stage, independently of the real index.
    #[serde(default)]
    pub worktree_snapshot: bool,
    #[serde(default = "default_review_context_lines")]
    pub context_lines: usize,
    #[serde(default)]
    pub ignore_all_whitespace: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request to apply a patch to the index or working tree.
pub struct GitApplyRequest {
    pub root: String,
    pub patch: String,
    /// Patch target or validation mode, including `stage`, `unstage`, and `worktree`.
    pub mode: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request for metadata and parent information about one commit.
pub struct GitCommitRequest {
    pub root: String,
    pub commit: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request for the paths changed by one commit.
pub struct GitCommitFilesRequest {
    pub root: String,
    pub commit: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request to compare a reference with the current checkout.
pub struct GitComparisonRequest {
    pub root: String,
    #[serde(default)]
    pub reference: Option<String>,
    #[serde(default)]
    pub git_reference: Option<GitReferenceRequest>,
    /// Optional typed target for a comparison between two references.
    #[serde(default)]
    pub target_git_reference: Option<GitReferenceRequest>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request for the repository's ordered stash list.
pub struct GitStashesRequest {
    pub root: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request to identify local edits that would block switching references.
pub struct GitCheckoutPreflightRequest {
    pub root: String,
    #[serde(default)]
    pub reference: Option<String>,
    #[serde(default)]
    pub git_reference: Option<GitReferenceRequest>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request to find staged files that still contain conflict markers.
pub struct GitConflictMarkerRequest {
    pub root: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request to determine whether a merge or rebase can start safely.
pub struct GitIntegrationPreflightRequest {
    pub root: String,
    #[serde(default)]
    pub reference: Option<String>,
    #[serde(default)]
    pub git_reference: Option<GitReferenceRequest>,
    /// Either "merge" or "rebase"; the two have different tolerances for a dirty tree.
    pub operation: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request to determine whether the tracked branch can fast-forward.
pub struct GitPullPreflightRequest {
    pub root: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request to inspect an interrupted merge, rebase, cherry-pick, or revert.
pub struct GitOperationStateRequest {
    pub root: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request for line attribution on one workspace-relative file.
pub struct GitBlameRequest {
    pub root: String,
    pub path: String,
}

fn default_review_context_lines() -> usize {
    80
}

fn default_push_preview_limit() -> usize {
    DEFAULT_PUSH_PREVIEW_LIMIT
}

/// Executes an argument-based Git command after validating the workspace root.
pub fn command(request: GitCommandRequest) -> Result<GitCommandResponse, CoreError> {
    with_git_invocation_trace(|| {
        let root = validate_root(&request.root)?;
        execute_git(&root, &request.arguments, request.input)
    })
}

fn readonly_command(request: GitCommandRequest) -> Result<GitCommandResponse, CoreError> {
    let root = validate_root(&request.root)?;
    execute_git_readonly(&root, &request.arguments, request.input)
}

/// Executes one supported repository mutation without invoking a shell.
pub fn write(request: GitWriteRequest) -> Result<GitCommandResponse, CoreError> {
    with_git_invocation_trace(|| write_with_trace(request))
}

fn write_with_trace(request: GitWriteRequest) -> Result<GitCommandResponse, CoreError> {
    let root = validate_root(&request.root)?;
    let mut arguments: Vec<String>;

    match request.operation.as_str() {
        "stage" => {
            let paths = validate_paths(&request.paths)?;
            arguments = vec![
                "add".into(),
                "-A".into(),
                "--pathspec-from-file=-".into(),
                "--pathspec-file-nul".into(),
            ];
            return execute_git(&root, &arguments, Some(nul_pathspec_input(&paths)));
        }
        "unstage" => {
            let paths = validate_paths(&request.paths)?;
            let pathspec_input = nul_pathspec_input(&paths);
            let restore_arguments = vec![
                "restore".into(),
                "--staged".into(),
                "--pathspec-from-file=-".into(),
                "--pathspec-file-nul".into(),
            ];
            let restore = execute_git(&root, &restore_arguments, Some(pathspec_input.clone()))?;
            if restore.exit_code == 0 {
                return Ok(restore);
            }
            arguments = vec![
                "reset".into(),
                "HEAD".into(),
                "--pathspec-from-file=-".into(),
                "--pathspec-file-nul".into(),
            ];
            return execute_git(&root, &arguments, Some(pathspec_input));
        }
        "discard" => {
            let paths = validate_paths(&request.paths)?;
            let restore_arguments = ["restore", "--worktree", "--"]
                .into_iter()
                .map(String::from)
                .chain(paths.clone())
                .collect::<Vec<_>>();
            let restore = execute_git(&root, &restore_arguments, None)?;
            if restore.exit_code == 0 {
                return Ok(restore);
            }
            let mut status_arguments = vec![
                "status".to_string(),
                "--porcelain".to_string(),
                "--".to_string(),
            ];
            status_arguments.extend(paths.clone());
            let status = execute_git(&root, &status_arguments, None)?;
            let is_untracked = status.exit_code == 0
                && status
                    .output
                    .lines()
                    .any(|line| line.starts_with("??") || line.starts_with("!!"));
            if !is_untracked {
                return Ok(restore);
            }
            arguments = ["clean", "-f", "-d", "--"]
                .into_iter()
                .map(String::from)
                .chain(paths)
                .collect();
        }
        "discardAll" => {
            let paths = validate_paths(&request.paths)?;
            return discard_all(&root, &paths);
        }
        "stageAll" => arguments = vec!["add".into(), "--all".into()],
        "commit" => {
            let message = required_text(request.message.as_deref(), "commit message")?;
            if !request.paths.is_empty() {
                let paths = validate_paths(&request.paths)?;
                return commit_selected_paths(&root, paths, message, request.amend);
            }
            arguments = vec!["commit".into()];
            if request.amend {
                arguments.push("--amend".into());
            }
            arguments.extend(["-m".into(), message]);
        }
        "ignore" => {
            return append_git_ignore_patterns(&root, &request.paths, GitIgnoreTarget::Repository)
        }
        "exclude" => {
            return append_git_ignore_patterns(&root, &request.paths, GitIgnoreTarget::LocalExclude)
        }
        "cherryPick" => {
            arguments = vec![
                "cherry-pick".into(),
                validated_revision(request.revision.as_deref())?,
            ];
        }
        "revert" => {
            arguments = vec![
                "revert".into(),
                "--no-edit".into(),
                validated_revision(request.revision.as_deref())?,
            ];
        }
        "reset" => {
            let mode = request.mode.as_deref().unwrap_or("--mixed");
            if !["--soft", "--mixed", "--hard"].contains(&mode) {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Unsupported reset mode",
                ));
            }
            arguments = vec![
                mode.into(),
                validated_revision(request.revision.as_deref())?,
            ];
            arguments.insert(0, "reset".into());
        }
        "editCommitMessage" => {
            let revision = validated_revision(request.revision.as_deref())?;
            let message = required_text(request.message.as_deref(), "commit message")?;
            return edit_commit_message(&root, &revision, &message);
        }
        "deleteCommit" => {
            let revision = validated_revision(request.revision.as_deref())?;
            return delete_commit(&root, &revision);
        }
        "squashCommits" => {
            let message = required_text(request.message.as_deref(), "commit message")?;
            return squash_commits(&root, &request.revisions, &message);
        }
        "createBranch" => {
            let name = validated_branch_name(&root, request.name.as_deref())?;
            let reference = write_request_reference(&root, &request)?;
            arguments = if request.checkout {
                vec!["switch".into(), "-c".into(), name, reference]
            } else {
                vec!["branch".into(), name, reference]
            };
        }
        "publishBranch" => {
            return publish_branch(&root, request.name.as_deref());
        }
        "renameBranch" => {
            let name = validated_branch_name(&root, request.name.as_deref())?;
            let reference = write_request_reference(&root, &request)?;
            let current = current_branch(&root)?;
            let current_reference = format!("refs/heads/{current}");
            arguments = if reference == current || reference == current_reference {
                vec!["branch".into(), "-m".into(), name]
            } else {
                vec!["branch".into(), "-m".into(), reference, name]
            };
        }
        "setUpstream" => {
            let branch = validated_branch_name(&root, request.name.as_deref())?;
            let upstream = request
                .git_reference
                .as_ref()
                .ok_or_else(invalid_git_reference)
                .and_then(|reference| validated_git_reference(&root, reference))?;
            if upstream.kind != "remote" {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "A branch upstream must be a remote Git reference",
                ));
            }
            arguments = vec![
                "branch".into(),
                format!("--set-upstream-to={}", upstream.full_name),
                branch,
            ];
        }
        "unsetUpstream" => {
            let branch = validated_branch_name(&root, request.name.as_deref())?;
            arguments = vec!["branch".into(), "--unset-upstream".into(), branch];
        }
        "deleteBranch" => {
            let reference = write_request_reference(&root, &request)?;
            let branch = local_branch_name(&reference)?;
            if current_branch(&root)?.as_str() == branch {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "The current branch cannot be deleted",
                ));
            }
            return delete_branch(&root, &branch);
        }
        "merge" => {
            let reference = write_request_reference(&root, &request)?;
            if is_current_reference(&root, &reference)? {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "The current branch cannot be merged into itself",
                ));
            }
            arguments = vec!["merge".into(), "--no-edit".into(), reference];
        }
        "rebase" => {
            let reference = write_request_reference(&root, &request)?;
            if is_current_reference(&root, &reference)? {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "The current branch cannot be rebased onto itself",
                ));
            }
            arguments = vec!["rebase".into(), reference];
        }
        "checkoutAndRebase" => return mutations::checkout_and_rebase(&root, request),
        "createWorktree" => return create_worktree(&root, &request),
        "removeWorktree" | "lockWorktree" | "unlockWorktree" => {
            return mutate_worktree(&root, &request)
        }
        "pruneWorktrees" => {
            arguments = vec![
                "worktree".into(),
                "prune".into(),
                "--verbose".into(),
                "--expire=now".into(),
            ]
        }
        "repairWorktrees" => arguments = vec!["worktree".into(), "repair".into()],
        "fetch" => arguments = vec!["fetch".into(), "--all".into(), "--prune".into()],
        // Strategy comes from the caller because only the user can decide whether a
        // divergent history should be merged or replayed. Absent a choice we stay on
        // `--ff-only`, which refuses rather than inventing a merge commit.
        "pull" => {
            arguments = match request.mode.as_deref() {
                None | Some("ffOnly") => vec!["pull".into(), "--ff-only".into()],
                Some("merge") => vec!["pull".into(), "--no-rebase".into(), "--no-edit".into()],
                Some("rebase") => vec!["pull".into(), "--rebase".into()],
                Some(other) => {
                    return Err(CoreError::new(
                        ErrorCode::InvalidRequest,
                        format!("Unknown pull strategy '{other}'"),
                    ))
                }
            };
            let explicit_reference = if let Some(reference) = request.git_reference.as_ref() {
                let reference = validated_git_reference(&root, reference)?;
                if reference.kind != "remote" {
                    return Err(CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Explicit pull requires a remote Git reference",
                    ));
                }
                Some(reference.full_name)
            } else if let Some(reference) = request.reference.as_deref() {
                if request.reference_kind.as_deref() != Some("remote") {
                    return Err(CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Explicit pull requires a remote Git reference",
                    ));
                }
                Some(validated_reference(Some(reference))?)
            } else {
                None
            };
            if let Some(reference) = explicit_reference {
                let (remote, branch) = mutations::remote_branch_components(&root, &reference)?;
                arguments.extend(["--".into(), remote, branch]);
            }
            if request.auto_stash {
                return pull_with_auto_stash(&root, &arguments);
            }
        }
        "deleteRemoteBranch" => {
            let reference = request
                .git_reference
                .as_ref()
                .ok_or_else(|| invalid_git_reference())?;
            let reference = validated_git_reference(&root, reference)?;
            if reference.kind != "remote" {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Remote branch deletion requires a remote Git reference",
                ));
            }
            let (remote, branch) =
                mutations::remote_branch_components(&root, &reference.full_name)?;
            arguments = vec![
                "push".into(),
                "--delete".into(),
                "--".into(),
                remote,
                format!("refs/heads/{branch}"),
            ];
        }
        "push" => {
            let reference = optional_write_request_reference(&root, &request)?;
            return push(
                &root,
                reference.as_deref(),
                request.force,
                request.push_tags.as_deref(),
                request.expected_push.as_ref(),
            );
        }
        "checkout" => return checkout(&root, request),
        "checkoutRevision" => {
            arguments = vec![
                "switch".into(),
                "--detach".into(),
                validated_revision(request.revision.as_deref())?,
            ];
        }
        "createTag" => {
            let name = validated_tag_name(request.name.as_deref())?;
            let requested_target = validated_revision(request.revision.as_deref())?;
            // Existence and resolvability probes run before Git so a duplicate
            // or unresolvable target fails with a stable message instead of
            // leaving the caller to parse localized `git tag` stderr.
            if tag_exists(&root, &name)? {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    format!("A tag named '{name}' already exists"),
                ));
            }
            // Git can tag trees and blobs, but the deletion/restore contract
            // promises a commit target, so anything else is rejected here and
            // the tag is created against the resolved commit id.
            let Some(target) = resolved_commit_target(&root, &requested_target)? else {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    format!("Could not resolve tag target '{requested_target}'"),
                ));
            };
            // An explicit message field (even an empty one) selects the
            // annotated form. Verbatim cleanup keeps restored CRLF and trailing
            // blank lines intact; UIs trim newly entered messages before send.
            arguments = match request.message.as_deref() {
                Some(message) => vec![
                    "tag".into(),
                    "-a".into(),
                    "--cleanup=verbatim".into(),
                    name,
                    "-m".into(),
                    message.to_string(),
                    target,
                ],
                None => vec!["tag".into(), name, target],
            };
        }
        "deleteTag" => return delete_tag(&root, request.name.as_deref()),
        "clone" => {
            let remote = required_text(request.remote.as_deref(), "clone source")?;
            let destination = required_text(request.destination.as_deref(), "clone destination")?;
            if destination.starts_with('-') || destination.contains('\0') {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Invalid clone destination",
                ));
            }
            arguments = vec!["clone".into(), "--".into(), remote, destination];
        }
        "stashPush" => {
            arguments = vec!["stash".into(), "push".into()];
            if request.include_untracked {
                arguments.push("--include-untracked".into());
            }
            if let Some(message) = request.message.filter(|value| !value.trim().is_empty()) {
                arguments.extend(["-m".into(), message]);
            }
            if !request.paths.is_empty() {
                let paths = validate_paths(&request.paths)?;
                arguments.extend([
                    "--pathspec-from-file=-".into(),
                    "--pathspec-file-nul".into(),
                ]);
                return execute_git(&root, &arguments, Some(nul_pathspec_input(&paths)));
            }
        }
        "operationContinue" | "operationAbort" | "operationSkip" => {
            return resolve_operation(&root, &request.operation)
        }
        "stashApply" | "stashDrop" => {
            let reference = validated_stash_reference(request.reference.as_deref())?;
            if request.operation == "stashApply" {
                return apply_stash(&root, &reference);
            }
            let action = match request.operation.as_str() {
                _ => "drop",
            };
            arguments = vec!["stash".into(), action.into(), reference];
        }
        "stashPop" => {
            let reference = validated_stash_reference(request.reference.as_deref())?;
            return pop_stash(&root, &reference);
        }
        _ => {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Unsupported Git write operation",
            ))
        }
    }

    execute_git(&root, &arguments, None)
}

pub(super) fn execute_git(
    root: &str,
    arguments: &[String],
    input: Option<String>,
) -> Result<GitCommandResponse, CoreError> {
    execute_git_with_options(root, arguments, input, false)
}

pub(super) fn execute_git_readonly(
    root: &str,
    arguments: &[String],
    input: Option<String>,
) -> Result<GitCommandResponse, CoreError> {
    execute_git_with_options(root, arguments, input, true)
}

fn execute_git_with_options(
    root: &str,
    arguments: &[String],
    input: Option<String>,
    disable_optional_locks: bool,
) -> Result<GitCommandResponse, CoreError> {
    capture_git_with_options(root, arguments, input, disable_optional_locks).map(|output| {
        let response = output.into_command_response(arguments);
        record_git_invocation(&response);
        response
    })
}

fn execute_git_with_environment(
    root: &str,
    arguments: &[String],
    input: Option<String>,
    disable_optional_locks: bool,
    environment: &[(String, String)],
) -> Result<GitCommandResponse, CoreError> {
    capture_git_with_environment(root, arguments, input, disable_optional_locks, environment).map(
        |output| {
            let response = output.into_command_response(arguments);
            record_git_invocation(&response);
            response
        },
    )
}

fn capture_git_with_options(
    root: &str,
    arguments: &[String],
    input: Option<String>,
    disable_optional_locks: bool,
) -> Result<GitProcessOutput, CoreError> {
    capture_git_with_environment(root, arguments, input, disable_optional_locks, &[])
}

fn capture_git_with_environment(
    root: &str,
    arguments: &[String],
    input: Option<String>,
    disable_optional_locks: bool,
    environment: &[(String, String)],
) -> Result<GitProcessOutput, CoreError> {
    crate::protocol::cancellation::check()?;
    let mut process = git_process();
    process
        .args(arguments)
        .current_dir(root)
        .envs(environment.iter().map(|(key, value)| (key, value)));
    if disable_optional_locks {
        process.env("GIT_OPTIONAL_LOCKS", "0");
    }
    process.stdin(if input.is_some() {
        std::process::Stdio::piped()
    } else {
        std::process::Stdio::null()
    });
    let mut child = process
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|error| {
            CoreError::new(ErrorCode::ProcessStartFailed, "Could not start Git")
                .with_details(error.to_string())
        })?;

    if let Some(input) = input {
        if let Some(mut stdin) = child.stdin.take() {
            stdin.write_all(input.as_bytes()).map_err(|error| {
                CoreError::new(ErrorCode::ProcessFailed, "Could not write to Git")
                    .with_details(error.to_string())
            })?;
        }
    }

    let mut stdout = child
        .stdout
        .take()
        .ok_or_else(|| CoreError::new(ErrorCode::ProcessFailed, "Git stdout was unavailable"))?;
    let mut stderr = child
        .stderr
        .take()
        .ok_or_else(|| CoreError::new(ErrorCode::ProcessFailed, "Git stderr was unavailable"))?;
    let stdout_reader = thread::spawn(move || {
        let mut bytes = Vec::new();
        let _ = stdout.read_to_end(&mut bytes);
        bytes
    });
    let stderr_reader = thread::spawn(move || {
        let mut bytes = Vec::new();
        let _ = stderr.read_to_end(&mut bytes);
        bytes
    });
    let status = loop {
        if let Some(status) = child.try_wait().map_err(|error| {
            CoreError::new(ErrorCode::ProcessFailed, "Could not read Git status")
                .with_details(error.to_string())
        })? {
            break status;
        }
        if let Err(error) = crate::protocol::cancellation::check() {
            let _ = child.kill();
            let _ = child.wait();
            let _ = stdout_reader.join();
            let _ = stderr_reader.join();
            return Err(error);
        }
        thread::sleep(Duration::from_millis(10));
    };
    let stdout = stdout_reader.join().unwrap_or_default();
    let stderr = stderr_reader.join().unwrap_or_default();
    Ok(GitProcessOutput {
        stdout,
        stderr,
        exit_code: status.code().unwrap_or(1),
    })
}

pub(super) fn git_process() -> Command {
    #[cfg(target_os = "windows")]
    {
        let mut process = Command::new("git");
        process.creation_flags(git_process_creation_flags());
        process
    }

    #[cfg(not(target_os = "windows"))]
    {
        Command::new("git")
    }
}

#[cfg(target_os = "windows")]
fn git_process_creation_flags() -> u32 {
    // Git runs as an IDE background task; attaching a console can briefly open
    // the user's default terminal whenever status or repository data refreshes.
    const CREATE_NO_WINDOW: u32 = 0x08000000;
    CREATE_NO_WINDOW
}

/// Builds a structured working-tree, staged, untracked, or commit diff.
pub fn diff(request: GitDiffRequest) -> Result<GitDiffResponse, CoreError> {
    if request.pathspecs.is_empty() || request.pathspecs.iter().any(|path| !is_safe_pathspec(path))
    {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Git diff contains an invalid path",
        ));
    }

    let root = validate_root(&request.root)?;
    if request.worktree_snapshot {
        if request.reference.is_some()
            || request.empty_tree_base
            || request.git_reference.is_some()
            || request.target_git_reference.is_some()
            || request.commit.is_some()
            || request.staged
            || request.untracked
        {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Git worktree snapshot diff cannot combine other diff modes",
            ));
        }
        return worktree_snapshot_diff(&root, &request);
    }
    let reference = if request.empty_tree_base {
        if request.git_reference.is_some()
            || request.target_git_reference.is_some()
            || request.commit.is_some()
        {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Git empty-tree diff cannot combine reference forms",
            ));
        }
        let target = request.reference.as_deref().ok_or_else(|| {
            CoreError::new(
                ErrorCode::InvalidRequest,
                "Git empty-tree diff requires a target reference",
            )
        })?;
        validate_revision(target)?;
        Some(format!("{}..{target}", empty_tree_oid(&root)?))
    } else {
        typed_reference_range(
            &root,
            request.git_reference.as_ref(),
            request.target_git_reference.as_ref(),
            request.reference.as_deref(),
        )?
    };
    if reference.is_some() && request.commit.is_some() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Git diff cannot combine a reference and a commit",
        ));
    }

    let include_untracked_with_reference = reference.is_some() && request.untracked;
    let mut arguments = if let Some(commit) = request.commit {
        validate_revision(&commit)?;
        vec![
            "show".to_string(),
            "--format=".to_string(),
            "--no-ext-diff".to_string(),
            "--binary".to_string(),
            format!("--unified={}", request.context_lines),
            commit,
        ]
    } else if let Some(reference) = reference {
        validate_revision(&reference)?;
        vec![
            "diff".to_string(),
            "--no-ext-diff".to_string(),
            "--binary".to_string(),
            format!("--unified={}", request.context_lines),
            reference,
        ]
    } else {
        let mut arguments = vec![
            "diff".to_string(),
            "--no-ext-diff".to_string(),
            "--binary".to_string(),
        ];
        if request.untracked {
            arguments.push("--no-index".to_string());
        }
        arguments.push(format!("--unified={}", request.context_lines));
        if request.staged && !request.untracked {
            arguments.push("--cached".to_string());
        }
        arguments
    };
    if request.ignore_all_whitespace {
        arguments.push("--ignore-all-space".to_string());
    }
    arguments.push("--".to_string());
    if request.untracked && !include_untracked_with_reference {
        arguments.push(null_device().to_string());
    }
    arguments.extend(request.pathspecs.clone());

    let root = validate_root(&request.root)?;
    let mut output = capture_git_with_options(&root, &arguments, None, true)?;
    if include_untracked_with_reference {
        let untracked_paths = readonly_command(GitCommandRequest {
            root: root.clone(),
            arguments: vec![
                "ls-files".into(),
                "--others".into(),
                "--exclude-standard".into(),
                "-z".into(),
                "--".into(),
            ]
            .into_iter()
            .chain(request.pathspecs.clone())
            .collect(),
            input: None,
        })?;
        if untracked_paths.exit_code != 0 {
            return Err(CoreError::new(
                ErrorCode::ProcessFailed,
                "Git untracked file lookup failed",
            )
            .with_details(untracked_paths.output));
        }
        for path in untracked_paths.stdout.split('\0') {
            if path.is_empty() || !is_safe_pathspec(path) {
                continue;
            }
            let mut untracked_arguments = vec![
                "diff".into(),
                "--no-ext-diff".into(),
                "--binary".into(),
                "--no-index".into(),
                format!("--unified={}", request.context_lines),
            ];
            if request.ignore_all_whitespace {
                untracked_arguments.push("--ignore-all-space".into());
            }
            untracked_arguments.extend(["--".into(), null_device().into(), path.into()]);
            let untracked = capture_git_with_options(&root, &untracked_arguments, None, true)?;
            output.stdout.extend(untracked.stdout);
            output.stderr.extend(untracked.stderr);
        }
    }
    Ok(structured_diff_from_output(output))
}

fn worktree_snapshot_diff(
    root: &str,
    request: &GitDiffRequest,
) -> Result<GitDiffResponse, CoreError> {
    let head = execute_git_readonly(
        root,
        &[
            "rev-parse".into(),
            "--verify".into(),
            "--quiet".into(),
            "HEAD".into(),
        ],
        None,
    )?;
    if head.exit_code > 1 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Could not resolve Git HEAD")
                .with_details(head.output),
        );
    }
    let head = (head.exit_code == 0).then(|| head.stdout.trim().to_string());
    let common_directory = git_resolved_path(
        root,
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
        "Git common directory",
    )?;
    let temporary_context = TemporaryGitCommitContext::prepare(root, head.as_deref())?;
    let environment = temporary_context.environment(root, &common_directory);
    let initialize_arguments = if let Some(head) = head.as_ref() {
        vec!["read-tree".to_string(), head.clone()]
    } else {
        vec!["read-tree".to_string(), "--empty".to_string()]
    };
    let initialized =
        execute_git_with_environment(root, &initialize_arguments, None, true, &environment)?;
    if initialized.exit_code != 0 {
        return Err(CoreError::new(
            ErrorCode::ProcessFailed,
            "Could not prepare Git snapshot diff",
        )
        .with_details(initialized.output));
    }

    let mut arguments = vec![
        "diff-files".to_string(),
        "--no-ext-diff".to_string(),
        "--binary".to_string(),
        format!("--unified={}", request.context_lines),
    ];
    if request.ignore_all_whitespace {
        arguments.push("--ignore-all-space".to_string());
    }
    arguments.push("--".to_string());
    arguments.extend(request.pathspecs.clone());
    let mut output = capture_git_with_environment(root, &arguments, None, true, &environment)?;
    if output.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Git snapshot diff failed")
                .with_details(String::from_utf8_lossy(&output.stderr)),
        );
    }

    let untracked_arguments = vec![
        "ls-files".into(),
        "--others".into(),
        "--exclude-standard".into(),
        "-z".into(),
        "--".into(),
    ]
    .into_iter()
    .chain(request.pathspecs.clone())
    .collect::<Vec<_>>();
    let untracked =
        capture_git_with_environment(root, &untracked_arguments, None, true, &environment)?;
    if untracked.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Git snapshot file lookup failed")
                .with_details(String::from_utf8_lossy(&untracked.stderr)),
        );
    }
    for path in untracked
        .stdout
        .split(|byte| *byte == 0)
        .filter(|path| !path.is_empty())
    {
        let path = String::from_utf8_lossy(path).to_string();
        if !is_safe_pathspec(&path) {
            continue;
        }
        let mut untracked_arguments = vec![
            "diff".into(),
            "--no-ext-diff".into(),
            "--binary".into(),
            "--no-index".into(),
            format!("--unified={}", request.context_lines),
        ];
        if request.ignore_all_whitespace {
            untracked_arguments.push("--ignore-all-space".into());
        }
        untracked_arguments.extend(["--".into(), null_device().into(), path]);
        let added =
            capture_git_with_environment(root, &untracked_arguments, None, true, &environment)?;
        output.stdout.extend(added.stdout);
        output.stderr.extend(added.stderr);
    }
    Ok(structured_diff_from_output(output))
}

fn structured_diff_from_output(output: GitProcessOutput) -> GitDiffResponse {
    // Diff is a machine-readable stdout protocol. Git diagnostics on stderr
    // must never become synthetic file lines in the parsed patch.
    let patch = String::from_utf8_lossy(&output.stdout).to_string();
    let document = parse_diff(&patch);
    GitDiffResponse {
        patch,
        rows: document.0,
        hunks: document.1,
    }
}

/// Applies a validated patch using the requested index or working-tree mode.
pub fn apply(request: GitApplyRequest) -> Result<GitCommandResponse, CoreError> {
    let arguments = match request.mode.as_str() {
        "stage" => vec![
            "apply".to_string(),
            "--cached".to_string(),
            "--whitespace=nowarn".to_string(),
        ],
        "unstage" => vec![
            "apply".to_string(),
            "--cached".to_string(),
            "--reverse".to_string(),
            "--whitespace=nowarn".to_string(),
        ],
        "discard" => vec![
            "apply".to_string(),
            "--reverse".to_string(),
            "--whitespace=nowarn".to_string(),
        ],
        // Reconstruct a saved index snapshot and its worktree in one step.
        // `--cached` alone would leave the worktree at HEAD, which makes a
        // subsequent unstaged patch fail for files with both staged and
        // unstaged edits.
        "restoreIndex" => vec![
            "apply".to_string(),
            "--index".to_string(),
            "--whitespace=nowarn".to_string(),
        ],
        "worktree" => vec!["apply".to_string(), "--whitespace=nowarn".to_string()],
        "restoreIndexCheck" => vec![
            "apply".to_string(),
            "--cached".to_string(),
            "--reverse".to_string(),
            "--check".to_string(),
            "--whitespace=nowarn".to_string(),
        ],
        "worktreeCheck" => vec![
            "apply".to_string(),
            "--reverse".to_string(),
            "--check".to_string(),
            "--whitespace=nowarn".to_string(),
        ],
        _ => {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Unsupported Git patch mode",
            ))
        }
    };
    command(GitCommandRequest {
        root: request.root,
        arguments,
        input: Some(request.patch),
    })
}

fn read_commit_log(
    root: &str,
    selectors: Vec<String>,
    limit: usize,
    failure_message: &str,
) -> Result<(Vec<GitCommitResponse>, bool), CoreError> {
    let mut arguments = vec!["log".to_string()];
    arguments.extend(selectors);
    arguments.extend([
        "--topo-order".to_string(),
        "--decorate=short".to_string(),
        "-n".to_string(),
        (limit.saturating_add(1)).to_string(),
        "--date=format:%Y/%m/%d %H:%M".to_string(),
        "--pretty=format:%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%ad%x1f%s%x1f%D".to_string(),
    ]);
    let commit_output = readonly_command(GitCommandRequest {
        root: root.to_string(),
        arguments,
        input: None,
    })?;
    if commit_output.exit_code != 0 {
        return Err(CoreError::new(ErrorCode::ProcessFailed, failure_message)
            .with_details(commit_output.output));
    }

    let all_commits = commit_output
        .output
        .lines()
        .filter_map(parse_commit)
        .collect::<Vec<_>>();
    let has_more = all_commits.len() > limit;
    Ok((all_commits.into_iter().take(limit).collect(), has_more))
}

/// Resolves one commit and its parent metadata.
pub fn commit(request: GitCommitRequest) -> Result<GitCommitLookupResponse, CoreError> {
    let root = validate_root(&request.root)?;
    validate_revision(&request.commit)?;
    let response = readonly_command(GitCommandRequest {
        root,
        arguments: vec![
            "show".to_string(),
            "-s".to_string(),
            "--date=format:%Y/%m/%d %H:%M".to_string(),
            "--pretty=format:%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%ad%x1f%s%x1f%D".to_string(),
            request.commit,
        ],
        input: None,
    })?;
    if response.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Git commit lookup failed")
                .with_details(response.output),
        );
    }
    let commit = response
        .output
        .lines()
        .find_map(parse_commit)
        .ok_or_else(|| CoreError::new(ErrorCode::ProcessFailed, "Git commit was not found"))?;
    Ok(GitCommitLookupResponse { commit })
}

/// Lists workspace-relative files changed by one commit.
pub fn commit_files(request: GitCommitFilesRequest) -> Result<GitFilesResponse, CoreError> {
    let root = validate_root(&request.root)?;
    validate_revision(&request.commit)?;
    let response = readonly_command(GitCommandRequest {
        root,
        arguments: vec![
            "-c".to_string(),
            "core.quotepath=false".to_string(),
            "show".to_string(),
            "--pretty=format:".to_string(),
            "--name-status".to_string(),
            "--find-renames".to_string(),
            request.commit,
        ],
        input: None,
    })?;
    if response.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Git commit files failed")
                .with_details(response.output),
        );
    }
    Ok(GitFilesResponse {
        files: parse_name_status(&response.output),
    })
}

/// Computes ahead/behind counts and changed files for a reference comparison.
pub fn comparison(request: GitComparisonRequest) -> Result<GitComparisonResponse, CoreError> {
    let root = validate_root(&request.root)?;
    let reference = typed_reference_range(
        &root,
        request.git_reference.as_ref(),
        request.target_git_reference.as_ref(),
        request.reference.as_deref(),
    )?
    .ok_or_else(|| CoreError::new(ErrorCode::InvalidRequest, "Missing Git reference"))?;
    validate_revision(&reference)?;
    let response = readonly_command(GitCommandRequest {
        root,
        arguments: vec![
            "-c".to_string(),
            "core.quotepath=false".to_string(),
            "diff".to_string(),
            "--name-status".to_string(),
            "--find-renames".to_string(),
            reference,
            "--".to_string(),
        ],
        input: None,
    })?;
    if response.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Git comparison failed")
                .with_details(response.output),
        );
    }
    Ok(GitComparisonResponse {
        files: parse_name_status(&response.output),
    })
}

/// Reports which files would block a checkout of `reference`.
///
/// A file blocks the switch when it has uncommitted changes *and* its content
/// differs between HEAD and the target ref. Files dirty in only one of those two
/// senses are carried across by Git without complaint.
pub fn checkout_preflight(
    request: GitCheckoutPreflightRequest,
) -> Result<GitCheckoutPreflightResponse, CoreError> {
    let root = validate_root(&request.root)?;
    let reference = request_reference(
        &root,
        request.git_reference.as_ref(),
        request.reference.as_deref(),
    )?;

    let dirty = readonly_command(GitCommandRequest {
        root: root.clone(),
        arguments: vec![
            "diff".to_string(),
            "HEAD".to_string(),
            "--name-only".to_string(),
        ],
        input: None,
    })?;
    if dirty.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Git diff failed").with_details(dirty.output)
        );
    }
    let dirty_paths = dirty
        .output
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect::<std::collections::HashSet<_>>();

    // Untracked files block a checkout too, whenever the target branch tracks the same
    // path: git refuses rather than overwrite them. These never appear in `diff HEAD`.
    let untracked = readonly_command(GitCommandRequest {
        root: root.clone(),
        arguments: vec![
            "ls-files".to_string(),
            "--others".to_string(),
            "--exclude-standard".to_string(),
        ],
        input: None,
    })?;
    if untracked.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Git ls-files failed")
                .with_details(untracked.output),
        );
    }
    let untracked_paths = untracked
        .output
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect::<std::collections::HashSet<_>>();

    if dirty_paths.is_empty() && untracked_paths.is_empty() {
        return Ok(GitCheckoutPreflightResponse {
            blocking_paths: Vec::new(),
        });
    }

    let mut blocking_paths = Vec::new();
    if !untracked_paths.is_empty() {
        let tracked_on_target = readonly_command(GitCommandRequest {
            root: root.clone(),
            arguments: vec![
                "ls-tree".to_string(),
                "-r".to_string(),
                "--name-only".to_string(),
                reference.clone(),
            ],
            input: None,
        })?;
        if tracked_on_target.exit_code != 0 {
            return Err(
                CoreError::new(ErrorCode::ProcessFailed, "Git ls-tree failed")
                    .with_details(tracked_on_target.output),
            );
        }
        blocking_paths.extend(
            tracked_on_target
                .output
                .lines()
                .map(str::trim)
                .filter(|line| !line.is_empty() && untracked_paths.contains(line))
                .map(str::to_string),
        );
    }

    if dirty_paths.is_empty() {
        blocking_paths.sort();
        blocking_paths.dedup();
        return Ok(GitCheckoutPreflightResponse { blocking_paths });
    }

    let divergent = readonly_command(GitCommandRequest {
        root,
        arguments: vec![
            "diff".to_string(),
            "HEAD".to_string(),
            reference,
            "--name-only".to_string(),
        ],
        input: None,
    })?;
    if divergent.exit_code != 0 {
        return Err(CoreError::new(ErrorCode::ProcessFailed, "Git diff failed")
            .with_details(divergent.output));
    }

    blocking_paths.extend(
        divergent
            .output
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty() && dirty_paths.contains(line))
            .map(str::to_string),
    );
    blocking_paths.sort();
    blocking_paths.dedup();
    Ok(GitCheckoutPreflightResponse { blocking_paths })
}

/// Lists staged files that still contain conflict markers.
///
/// Only `<<<<<<< ` and friends with their trailing space are matched: a bare
/// `=======` is also a Markdown heading underline, and matching it flags ordinary
/// documentation. `|||||||` covers the diff3 conflict style. Git skips binary
/// files itself, so a blob containing those bytes cannot trip this.
pub fn conflict_marker_paths(
    request: GitConflictMarkerRequest,
) -> Result<GitConflictMarkerResponse, CoreError> {
    let root = validate_root(&request.root)?;
    let paths = staged_conflict_marker_paths(&root)?;
    Ok(GitConflictMarkerResponse { paths })
}

fn staged_conflict_marker_paths(root: &str) -> Result<Vec<String>, CoreError> {
    staged_conflict_marker_paths_with_environment(root, &[], false)
}

fn staged_conflict_marker_paths_with_environment(
    root: &str,
    environment: &[(String, String)],
    changed_only: bool,
) -> Result<Vec<String>, CoreError> {
    // The alternate index starts at HEAD, so its staged diff is the authoritative
    // expansion of directory and glob pathspecs without repeating a long path list.
    let changed_paths = if changed_only {
        let changed = execute_git_with_environment(
            root,
            &[
                "diff".to_string(),
                "--cached".to_string(),
                "--no-ext-diff".to_string(),
                "--name-only".to_string(),
                "-z".to_string(),
            ],
            None,
            true,
            environment,
        )?;
        if changed.exit_code != 0 {
            return Err(
                CoreError::new(ErrorCode::ProcessFailed, "Git staged diff failed")
                    .with_details(changed.output),
            );
        }
        Some(
            changed
                .stdout
                .split('\0')
                .filter(|path| !path.is_empty())
                .map(str::to_string)
                .collect::<HashSet<_>>(),
        )
    } else {
        None
    };
    let arguments = vec![
        "grep".to_string(),
        "--cached".to_string(),
        "-l".to_string(),
        "-z".to_string(),
        "-E".to_string(),
        r"^(<<<<<<<|>>>>>>>|\|\|\|\|\|\|\|) ".to_string(),
    ];
    let found = execute_git_with_environment(root, &arguments, None, true, environment)?;
    // `git grep` exits 1 when nothing matches, which is not a failure here.
    if found.exit_code > 1 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Git grep failed").with_details(found.output)
        );
    }

    let mut paths: Vec<String> = found
        .stdout
        .split('\0')
        .filter(|path| {
            !path.is_empty()
                && changed_paths
                    .as_ref()
                    .map_or(true, |changed| changed.contains(*path))
        })
        .map(str::to_string)
        .collect();
    paths.sort();
    paths.dedup();
    Ok(paths)
}

fn commit_selected_paths(
    root: &str,
    paths: Vec<String>,
    message: String,
    amend: bool,
) -> Result<GitCommandResponse, CoreError> {
    let operation = operation_state(GitOperationStateRequest {
        root: root.to_string(),
    })?;
    if !operation.kind.is_empty() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Finish or abort the current Git operation before committing selected files",
        ));
    }

    let branch = execute_git_readonly(
        root,
        &["symbolic-ref".into(), "--quiet".into(), "HEAD".into()],
        None,
    )?;
    let branch_reference = branch.stdout.trim();
    if branch.exit_code != 0 || !branch_reference.starts_with("refs/heads/") {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Selected files can only be committed on a local branch",
        ));
    }

    let head = execute_git_readonly(
        root,
        &[
            "rev-parse".to_string(),
            "--verify".to_string(),
            "-q".to_string(),
            "HEAD".to_string(),
        ],
        None,
    )?;
    if head.exit_code > 1 {
        return Ok(head);
    }
    let original_head = (head.exit_code == 0).then(|| head.stdout.trim().to_string());
    if amend && original_head.is_none() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "An initial commit cannot be amended",
        ));
    }

    // Git's own commit command still runs hooks and signing, but its HEAD and
    // index live in an isolated administration directory. The reviewed branch
    // is updated only after the resulting snapshot passes validation.
    let common_directory = git_resolved_path(
        root,
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
        "Git common directory",
    )?;
    let temporary_context = TemporaryGitCommitContext::prepare(root, original_head.as_deref())?;
    let environment = temporary_context.environment(root, &common_directory);
    let pathspec_input = nul_pathspec_input(&paths);
    let initialize_arguments = if let Some(head) = original_head.as_ref() {
        vec!["read-tree".to_string(), head.clone()]
    } else {
        vec!["read-tree".to_string(), "--empty".to_string()]
    };
    let initialized =
        execute_git_with_environment(root, &initialize_arguments, None, false, &environment)?;
    if initialized.exit_code != 0 {
        return Ok(initialized);
    }
    let stage_arguments = vec![
        "add".to_string(),
        "-A".to_string(),
        "--pathspec-from-file=-".to_string(),
        "--pathspec-file-nul".to_string(),
    ];
    let staged = execute_git_with_environment(
        root,
        &stage_arguments,
        Some(pathspec_input.clone()),
        false,
        &environment,
    )?;
    if staged.exit_code != 0 {
        return Ok(staged);
    }

    let allowed_paths = staged_changed_paths(root, &environment)?;

    let marker_paths = staged_conflict_marker_paths_with_environment(root, &environment, true)?;
    if !marker_paths.is_empty() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Conflict markers remain in selected files",
        )
        .with_details(marker_paths.join(", ")));
    }

    let mut arguments = vec!["commit".into()];
    if amend {
        arguments.push("--amend".into());
    }
    arguments.extend(["-m".into(), message]);
    let committed = execute_git_with_environment(root, &arguments, None, false, &environment)?;
    if committed.exit_code != 0 {
        return Ok(committed);
    }

    let committed_head = execute_git_with_environment(
        root,
        &["rev-parse".into(), "--verify".into(), "HEAD".into()],
        None,
        true,
        &environment,
    )?;
    if committed_head.exit_code != 0 {
        let _ = temporary_context.cleanup_reference(root);
        return Ok(committed_head);
    }
    let committed_head = committed_head.stdout.trim().to_string();
    let committed_paths = commit_changed_paths(root, original_head.as_deref(), &committed_head)?;
    let unexpected_paths = committed_paths
        .difference(&allowed_paths)
        .cloned()
        .collect::<Vec<_>>();
    if !unexpected_paths.is_empty() {
        let _ = temporary_context.cleanup_reference(root);
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "A Git hook added files outside the selected commit",
        )
        .with_details(unexpected_paths.join(", ")));
    }

    let expected_old = match original_head.as_ref() {
        Some(head) => head.clone(),
        None => null_object_id(root)?,
    };
    let updated = execute_git(
        root,
        &[
            "update-ref".into(),
            "-m".into(),
            if amend {
                "commit (amend): selected files".into()
            } else {
                "commit: selected files".into()
            },
            branch_reference.to_string(),
            committed_head,
            expected_old,
        ],
        None,
    )?;
    if updated.exit_code != 0 {
        let _ = temporary_context.cleanup_reference(root);
        return Ok(updated);
    }

    // Reconcile only committed paths in the real index. Unrelated staging that
    // another Git process created while hooks ran remains intact.
    let mut reconciled = execute_git(
        root,
        &[
            "reset".to_string(),
            "-q".to_string(),
            "HEAD".to_string(),
            "--pathspec-from-file=-".to_string(),
            "--pathspec-file-nul".to_string(),
        ],
        Some(pathspec_input),
    )?;
    if reconciled.exit_code != 0 {
        reconciled.warnings.push(GitOperationWarning::new(
            "git_index_reconcile_failed",
            "The commit succeeded, but the Git index could not be reconciled",
            Some(reconciled.output.clone()),
        ));
        reconciled.exit_code = 0;
    }
    if let Err(error) = temporary_context.cleanup_reference(root) {
        reconciled.warnings.push(GitOperationWarning::new(
            "git_temporary_reference_cleanup_failed",
            "The commit succeeded, but its temporary Git reference could not be removed",
            error.details,
        ));
    }
    Ok(reconciled)
}

fn staged_changed_paths(
    root: &str,
    environment: &[(String, String)],
) -> Result<HashSet<String>, CoreError> {
    let changed = execute_git_with_environment(
        root,
        &[
            "diff".into(),
            "--cached".into(),
            "--name-only".into(),
            "-z".into(),
        ],
        None,
        true,
        environment,
    )?;
    if changed.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Git staged diff failed")
                .with_details(changed.output),
        );
    }
    Ok(changed
        .stdout
        .split('\0')
        .filter(|path| !path.is_empty())
        .map(str::to_string)
        .collect())
}

fn commit_changed_paths(
    root: &str,
    original_head: Option<&str>,
    committed_head: &str,
) -> Result<HashSet<String>, CoreError> {
    let arguments = if let Some(original_head) = original_head {
        vec![
            "diff".into(),
            "--name-only".into(),
            "-z".into(),
            original_head.into(),
            committed_head.into(),
        ]
    } else {
        vec![
            "diff-tree".into(),
            "--root".into(),
            "--no-commit-id".into(),
            "--name-only".into(),
            "-z".into(),
            committed_head.into(),
        ]
    };
    let changed = execute_git_readonly(root, &arguments, None)?;
    if changed.exit_code != 0 {
        return Err(CoreError::new(
            ErrorCode::ProcessFailed,
            "Could not validate the selected commit",
        )
        .with_details(changed.output));
    }
    Ok(changed
        .stdout
        .split('\0')
        .filter(|path| !path.is_empty())
        .map(str::to_string)
        .collect())
}

fn null_object_id(root: &str) -> Result<String, CoreError> {
    let format = execute_git_readonly(
        root,
        &["rev-parse".into(), "--show-object-format".into()],
        None,
    )?;
    if format.exit_code != 0 {
        return Err(CoreError::new(
            ErrorCode::ProcessFailed,
            "Could not determine Git object format",
        )
        .with_details(format.output));
    }
    Ok(match format.stdout.trim() {
        "sha256" => "0".repeat(64),
        _ => "0".repeat(40),
    })
}

/// How an operation decides whether a dirty working tree is in its way.
enum IntegrationShape {
    /// Refuses only over files differing between the merge base and the target.
    MergeBase,
    /// Refuses over any uncommitted change, however unrelated.
    AnyDirty,
    /// Refuses only over files the single replayed commit touches.
    SingleCommit,
}

/// Reports what would stop a merge, rebase, cherry-pick, or revert from starting.
///
/// The rules differ and were each checked against Git directly: merge, cherry-pick
/// and revert refuse only when a dirty file overlaps what they would write, while a
/// rebase refuses on any uncommitted change, staged or not, however unrelated.
/// Matching Git's stderr is not an option since it is localized.
pub fn integration_preflight(
    request: GitIntegrationPreflightRequest,
) -> Result<GitIntegrationPreflightResponse, CoreError> {
    let root = validate_root(&request.root)?;
    let reference = request_reference(
        &root,
        request.git_reference.as_ref(),
        request.reference.as_deref(),
    )?;
    let shape = match request.operation.as_str() {
        "merge" => IntegrationShape::MergeBase,
        "rebase" => IntegrationShape::AnyDirty,
        // Verified against Git: both refuse only when a dirty file overlaps what the
        // commit touches, exactly like a merge. The overlap set differs though, since
        // they replay one commit rather than joining two branches.
        "cherryPick" | "revert" => IntegrationShape::SingleCommit,
        other => {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                format!("Unknown integration operation '{other}'"),
            ))
        }
    };

    // Tracked files differing from HEAD, staged or not: `diff HEAD` covers both.
    let dirty = readonly_command(GitCommandRequest {
        root: root.clone(),
        arguments: vec![
            "diff".to_string(),
            "HEAD".to_string(),
            "--name-only".to_string(),
        ],
        input: None,
    })?;
    if dirty.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Git diff failed").with_details(dirty.output)
        );
    }
    let dirty_paths: Vec<String> = dirty
        .output
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(str::to_string)
        .collect();

    if dirty_paths.is_empty() {
        return Ok(GitIntegrationPreflightResponse {
            blocking_paths: Vec::new(),
            blocks_entirely: false,
        });
    }

    // A rebase stops for any uncommitted change, so every dirty path is blocking
    // and there is no overlap to compute.
    if matches!(shape, IntegrationShape::AnyDirty) {
        let mut blocking_paths = dirty_paths;
        blocking_paths.sort();
        blocking_paths.dedup();
        return Ok(GitIntegrationPreflightResponse {
            blocking_paths,
            blocks_entirely: true,
        });
    }

    // Everything else refuses only over files it would write. For a merge those are
    // the files differing since the merge base; for a single replayed commit they
    // are the files that commit changed against its own parent.
    let written = match shape {
        IntegrationShape::MergeBase => {
            let base = readonly_command(GitCommandRequest {
                root: root.clone(),
                arguments: vec![
                    "merge-base".to_string(),
                    "HEAD".to_string(),
                    reference.clone(),
                ],
                input: None,
            })?;
            if base.exit_code != 0 {
                return Err(
                    CoreError::new(ErrorCode::ProcessFailed, "Git merge-base failed")
                        .with_details(base.output),
                );
            }
            readonly_command(GitCommandRequest {
                root,
                arguments: vec![
                    "diff".to_string(),
                    base.output.trim().to_string(),
                    reference,
                    "--name-only".to_string(),
                ],
                input: None,
            })?
        }
        // `diff-tree` against the commit itself; the extra flags make a merge commit
        // and the root commit behave rather than print nothing.
        IntegrationShape::SingleCommit => readonly_command(GitCommandRequest {
            root,
            arguments: vec![
                "diff-tree".to_string(),
                "-r".to_string(),
                "-m".to_string(),
                "--root".to_string(),
                "--name-only".to_string(),
                "--no-commit-id".to_string(),
                reference,
            ],
            input: None,
        })?,
        IntegrationShape::AnyDirty => unreachable!("handled above"),
    };
    if written.exit_code != 0 {
        return Err(CoreError::new(ErrorCode::ProcessFailed, "Git diff failed")
            .with_details(written.output));
    }
    let written_paths = written
        .output
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect::<std::collections::HashSet<_>>();

    let mut blocking_paths: Vec<String> = dirty_paths
        .into_iter()
        .filter(|path| written_paths.contains(path.as_str()))
        .collect();
    blocking_paths.sort();
    blocking_paths.dedup();
    Ok(GitIntegrationPreflightResponse {
        blocking_paths,
        blocks_entirely: false,
    })
}

/// Reports whether a pull can fast-forward, so the UI can ask before it fails.
///
/// Git's own refusal for a divergent pull is a multi-line hint block that is
/// localized, so the counts are computed here instead. Fetching first would make
/// the numbers fresher, but this stays read-only: the caller decides when to hit
/// the network.
pub fn pull_preflight(
    request: GitPullPreflightRequest,
) -> Result<GitPullPreflightResponse, CoreError> {
    let root = validate_root(&request.root)?;

    let upstream = readonly_command(GitCommandRequest {
        root: root.clone(),
        arguments: vec![
            "rev-parse".to_string(),
            "--abbrev-ref".to_string(),
            "--symbolic-full-name".to_string(),
            "@{upstream}".to_string(),
        ],
        input: None,
    })?;
    // A non-zero exit here means "no upstream configured", not a failure.
    if upstream.exit_code != 0 {
        return Ok(GitPullPreflightResponse {
            upstream: None,
            ahead: 0,
            behind: 0,
            diverged: false,
            has_local_changes: false,
        });
    }
    let upstream = upstream.output.trim().to_string();

    let counts = readonly_command(GitCommandRequest {
        root: root.clone(),
        arguments: vec![
            "rev-list".to_string(),
            "--left-right".to_string(),
            "--count".to_string(),
            format!("{upstream}...HEAD"),
        ],
        input: None,
    })?;
    if counts.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Git rev-list failed")
                .with_details(counts.output),
        );
    }
    // `--left-right --count` prints "<behind>\t<ahead>" for `upstream...HEAD`.
    let mut fields = counts.output.split_whitespace();
    let behind = fields.next().and_then(|v| v.parse().ok()).unwrap_or(0);
    let ahead = fields.next().and_then(|v| v.parse().ok()).unwrap_or(0);

    let dirty = readonly_command(GitCommandRequest {
        root,
        arguments: vec![
            "status".to_string(),
            "--porcelain".to_string(),
            "--untracked-files=no".to_string(),
        ],
        input: None,
    })?;
    if dirty.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Git status failed")
                .with_details(dirty.output),
        );
    }

    Ok(GitPullPreflightResponse {
        upstream: Some(upstream),
        ahead,
        behind,
        diverged: ahead > 0 && behind > 0,
        has_local_changes: !dirty.output.trim().is_empty(),
    })
}

/// Resolves the Git directory once, honoring worktrees and submodules where
/// `.git` is a file pointing elsewhere rather than a directory.
fn git_directory(root: &str) -> Result<Option<PathBuf>, CoreError> {
    let response = execute_git_readonly(
        root,
        &["rev-parse".to_string(), "--absolute-git-dir".to_string()],
        None,
    )?;
    if response.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Git rev-parse failed")
                .with_details(response.output),
        );
    }
    let raw = response.output.trim();
    if raw.is_empty() {
        return Ok(None);
    }
    Ok(Some(PathBuf::from(raw)))
}

/// Reads a single-line numeric counter written by an in-progress rebase.
fn rebase_counter(directory: &std::path::Path, name: &str) -> Option<usize> {
    std::fs::read_to_string(directory.join(name))
        .ok()?
        .trim()
        .parse()
        .ok()
}

/// Reports whichever sequential operation Git has left half-finished.
///
/// Detection reads the marker files Git itself writes, so an operation stopped by
/// a conflict is reported the same way whether the user started it in Lithe or on
/// the command line.
pub fn operation_state(
    request: GitOperationStateRequest,
) -> Result<GitOperationStateResponse, CoreError> {
    let root = validate_root(&request.root)?;

    let mut kind = String::new();
    let mut reference = None;
    let mut step = None;
    let mut total = None;

    // Order matters: a conflicted rebase can carry a REVERT_HEAD from the commit
    // it is replaying, so the more specific rebase directories are checked first.
    if let Some(git_directory) = git_directory(&root)? {
        let rebase_merge = git_directory.join("rebase-merge");
        let rebase_apply = git_directory.join("rebase-apply");
        let operation_directory = [rebase_merge, rebase_apply]
            .into_iter()
            .find(|path| path.exists());
        if let Some(directory) = operation_directory {
            kind = "rebase".to_string();
            step = rebase_counter(&directory, "msgnum");
            total = rebase_counter(&directory, "end");
            reference = std::fs::read_to_string(directory.join("onto"))
                .ok()
                .map(|value| value.trim().to_string())
                .filter(|value| !value.is_empty());
        } else if git_directory.join("MERGE_HEAD").exists() {
            kind = "merge".to_string();
        } else if git_directory.join("CHERRY_PICK_HEAD").exists() {
            kind = "cherryPick".to_string();
        } else if git_directory.join("REVERT_HEAD").exists() {
            kind = "revert".to_string();
        }
    }

    let status = execute_git_readonly(
        &root,
        &["status".to_string(), "--porcelain".to_string()],
        None,
    )?;
    if status.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Git status failed")
                .with_details(status.output),
        );
    }

    let mut conflicted_paths = status
        .output
        .lines()
        .filter(|line| line.len() > 3 && is_conflicted_status(&line[..2]))
        .map(|line| line[3..].trim().to_string())
        .filter(|path| !path.is_empty())
        .collect::<Vec<_>>();
    conflicted_paths.sort();
    conflicted_paths.dedup();

    Ok(GitOperationStateResponse {
        kind,
        reference,
        step,
        total,
        conflicted_paths,
    })
}

/// Continues, aborts, or skips whichever operation is currently in progress.
///
/// The subcommand depends on what Git left behind, so the state is read first
/// rather than trusted from the caller: the UI's view of it may be a refresh
/// behind, and issuing `rebase --continue` during a merge would just fail.
fn resolve_operation(root: &str, operation: &str) -> Result<GitCommandResponse, CoreError> {
    let state = operation_state(GitOperationStateRequest {
        root: root.to_string(),
    })?;
    if state.kind.is_empty() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "No Git operation is in progress",
        ));
    }

    let subcommand = match state.kind.as_str() {
        "rebase" => "rebase",
        "merge" => "merge",
        "cherryPick" => "cherry-pick",
        "revert" => "revert",
        _ => {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Unsupported Git operation state",
            ))
        }
    };

    let action = match operation {
        "operationContinue" => "--continue",
        "operationAbort" => "--abort",
        _ => "--skip",
    };

    // Only a rebase can skip a step; merge and cherry-pick have no equivalent.
    if action == "--skip" && subcommand != "rebase" {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Only a rebase can skip a step",
        ));
    }

    if action == "--continue" && !state.conflicted_paths.is_empty() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Resolve the conflicted files before continuing",
        )
        .with_details(state.conflicted_paths.join("\n")));
    }

    // `--continue` opens an editor for the commit message by default, which would
    // hang a process launched from the GUI with no terminal attached. Pointing the
    // editor at `true` makes Git accept the message it already prepared and exit.
    // `merge --continue` rejects extra arguments, so this must stay a config
    // override rather than a `--no-edit` flag.
    let arguments = vec![
        "-c".to_string(),
        "core.editor=true".to_string(),
        subcommand.to_string(),
        action.to_string(),
    ];

    execute_git(root, &arguments, None)
}

/// The porcelain status pairs Git uses for an unresolved merge conflict.
fn is_conflicted_status(code: &str) -> bool {
    matches!(code, "UU" | "AA" | "DD" | "DU" | "UD" | "AU" | "UA")
}

/// Lists stashes with stable references and parsed metadata.
pub fn stashes(request: GitStashesRequest) -> Result<GitStashesResponse, CoreError> {
    let root = validate_root(&request.root)?;
    let response = readonly_command(GitCommandRequest {
        root,
        arguments: vec![
            "stash".to_string(),
            "list".to_string(),
            "--date=iso".to_string(),
            "--pretty=format:%gd%x1f%gs%x1f%ad".to_string(),
        ],
        input: None,
    })?;
    if response.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Git stash list failed")
                .with_details(response.output),
        );
    }
    Ok(GitStashesResponse {
        stashes: response.output.lines().filter_map(parse_stash).collect(),
    })
}

/// Returns line attribution parsed from Git's machine-readable porcelain form.
pub fn blame(request: GitBlameRequest) -> Result<GitBlameResponse, CoreError> {
    if !is_safe_pathspec(&request.path) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Git blame contains an invalid path",
        ));
    }
    let response = readonly_command(GitCommandRequest {
        root: request.root,
        arguments: vec![
            "blame".to_string(),
            "--line-porcelain".to_string(),
            "--".to_string(),
            request.path,
        ],
        input: None,
    })?;
    if response.exit_code != 0 {
        return Err(CoreError::new(ErrorCode::ProcessFailed, "Git blame failed")
            .with_details(response.output));
    }

    let mut lines = Vec::new();
    let mut commit_hash = String::new();
    let mut author_name = "Unknown".to_string();
    let mut author_time = 0;
    let mut final_line = 0;
    for line in response.output.lines() {
        let columns = line.split_whitespace().collect::<Vec<_>>();
        if columns.len() >= 3 && columns[0].len() == 40 {
            if let Ok(parsed_line) = columns[2].parse::<usize>() {
                commit_hash = columns[0].to_string();
                final_line = parsed_line;
            }
        } else if let Some(value) = line.strip_prefix("author ") {
            author_name = value.to_string();
        } else if let Some(value) = line.strip_prefix("author-time ") {
            author_time = value.parse::<i64>().unwrap_or_default();
        } else if line.starts_with('\t') && final_line > 0 {
            lines.push(GitBlameLineResponse {
                line: final_line,
                commit_hash: commit_hash.clone(),
                author_name: author_name.clone(),
                author_time,
            });
            final_line += 1;
        }
    }
    Ok(GitBlameResponse { lines })
}

fn validate_root(raw_root: &str) -> Result<String, CoreError> {
    let root = PathBuf::from(raw_root)
        .canonicalize()
        .map_err(|_| CoreError::new(ErrorCode::WorkspaceNotFound, "Workspace does not exist"))?;
    if !root.is_dir() {
        return Err(CoreError::new(
            ErrorCode::WorkspaceNotFound,
            "Workspace does not exist",
        ));
    }
    Ok(root.to_string_lossy().to_string())
}

fn required_text(value: Option<&str>, label: &str) -> Result<String, CoreError> {
    let value = value.map(str::trim).filter(|value| !value.is_empty());
    match value {
        Some(value) if !value.contains('\0') => Ok(value.to_string()),
        _ => Err(CoreError::new(
            ErrorCode::InvalidRequest,
            format!("Missing or invalid Git {label}"),
        )),
    }
}

#[derive(Clone)]
struct ValidatedGitReference {
    full_name: String,
    short_name: String,
    kind: String,
}

fn invalid_git_reference() -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, "Invalid Git reference")
}

fn validated_git_reference(
    root: &str,
    reference: &GitReferenceRequest,
) -> Result<ValidatedGitReference, CoreError> {
    if reference.full_name.contains(['\0', '\n', '\r'])
        || reference.short_name.contains(['\0', '\n', '\r'])
        || reference.full_name.chars().any(char::is_whitespace)
        || reference.short_name.trim() != reference.short_name
    {
        return Err(invalid_git_reference());
    }

    let prefix = match reference.kind.as_str() {
        "local" => "refs/heads/",
        "remote" => "refs/remotes/",
        "tag" => "refs/tags/",
        _ => return Err(invalid_git_reference()),
    };
    let expected_short_name = reference
        .full_name
        .strip_prefix(prefix)
        .filter(|value| !value.is_empty())
        .ok_or_else(invalid_git_reference)?;
    if expected_short_name != reference.short_name {
        return Err(invalid_git_reference());
    }

    let checked = execute_git_readonly(
        root,
        &["check-ref-format".into(), reference.full_name.clone()],
        None,
    )?;
    if checked.exit_code != 0 {
        return Err(invalid_git_reference());
    }
    if reference.kind == "remote" {
        let (_, branch) = mutations::remote_branch_components(root, &reference.full_name)?;
        if branch == "HEAD" {
            return Err(invalid_git_reference());
        }
    }

    Ok(ValidatedGitReference {
        full_name: reference.full_name.clone(),
        short_name: reference.short_name.clone(),
        kind: reference.kind.clone(),
    })
}

fn legacy_checkout_reference(
    root: &str,
    reference: &str,
    kind: &str,
) -> Result<ValidatedGitReference, CoreError> {
    let (full_name, short_name) = match kind {
        "local" => {
            let short_name = reference.strip_prefix("refs/heads/").unwrap_or(reference);
            (format!("refs/heads/{short_name}"), short_name.to_string())
        }
        "remote" => {
            let short_name = reference
                .strip_prefix("refs/remotes/")
                .ok_or_else(invalid_git_reference)?;
            (reference.to_string(), short_name.to_string())
        }
        "tag" => {
            let short_name = reference.strip_prefix("refs/tags/").unwrap_or(reference);
            (format!("refs/tags/{short_name}"), short_name.to_string())
        }
        _ => return Err(invalid_git_reference()),
    };
    validated_git_reference(
        root,
        &GitReferenceRequest {
            full_name,
            short_name,
            kind: kind.to_string(),
        },
    )
}

fn optional_write_request_reference(
    root: &str,
    request: &GitWriteRequest,
) -> Result<Option<String>, CoreError> {
    if let Some(reference) = request.git_reference.as_ref() {
        return validated_git_reference(root, reference).map(|value| Some(value.full_name));
    }
    request
        .reference
        .as_deref()
        .map(|reference| validated_reference(Some(reference)))
        .transpose()
}

pub(super) fn write_request_reference(
    root: &str,
    request: &GitWriteRequest,
) -> Result<String, CoreError> {
    // Branch restore records carry the deleted commit object ID rather than a
    // live ref. Accept that exact revision only for createBranch; every other
    // mutation continues to require a typed, existing Git reference.
    if request.operation == "createBranch" {
        if let Some(reference) = request.git_reference.as_ref() {
            if reference.full_name == reference.short_name {
                if let Ok(revision) = validated_revision(Some(&reference.full_name)) {
                    return Ok(revision);
                }
            }
        }
    }
    optional_write_request_reference(root, request)?
        .ok_or_else(|| CoreError::new(ErrorCode::InvalidRequest, "Missing Git reference"))
}

fn checkout_request_reference(
    root: &str,
    request: &GitWriteRequest,
) -> Result<ValidatedGitReference, CoreError> {
    if let Some(reference) = request.git_reference.as_ref() {
        return validated_git_reference(root, reference);
    }
    let reference = validated_reference(request.reference.as_deref())?;
    let kind = required_text(request.reference_kind.as_deref(), "reference kind")?;
    legacy_checkout_reference(root, &reference, &kind)
}

fn request_reference(
    root: &str,
    typed: Option<&GitReferenceRequest>,
    legacy: Option<&str>,
) -> Result<String, CoreError> {
    if let Some(reference) = typed {
        return validated_git_reference(root, reference).map(|value| value.full_name);
    }
    validated_reference(legacy)
}

fn typed_reference_range(
    root: &str,
    base: Option<&GitReferenceRequest>,
    target: Option<&GitReferenceRequest>,
    legacy: Option<&str>,
) -> Result<Option<String>, CoreError> {
    match (base, target) {
        (Some(base), Some(target)) => {
            if legacy.is_some() {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Git comparison cannot combine typed and legacy references",
                ));
            }
            let base = validated_git_reference(root, base)?;
            let target = validated_git_reference(root, target)?;
            Ok(Some(format!("{}..{}", base.full_name, target.full_name)))
        }
        (None, Some(_)) => Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Git comparison target requires a base reference",
        )),
        (Some(base), None) => {
            if legacy.is_some() {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Git comparison cannot combine typed and legacy references",
                ));
            }
            Ok(Some(validated_git_reference(root, base)?.full_name))
        }
        (None, None) => legacy
            .map(|value| validated_reference(Some(value)))
            .transpose(),
    }
}

fn validate_paths(paths: &[String]) -> Result<Vec<String>, CoreError> {
    if paths.is_empty() || paths.iter().any(|path| !is_safe_pathspec(path)) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Git operation contains an invalid path",
        ));
    }
    Ok(paths.to_vec())
}

/// Chooses whether ignore patterns belong to the shared repository file or the
/// current checkout's local Git metadata.
enum GitIgnoreTarget {
    Repository,
    LocalExclude,
}

fn append_git_ignore_patterns(
    root: &str,
    paths: &[String],
    target: GitIgnoreTarget,
) -> Result<GitCommandResponse, CoreError> {
    let patterns = git_ignore_patterns(paths)?;
    let target_path = match target {
        GitIgnoreTarget::Repository => repository_root(root)?.join(".gitignore"),
        GitIgnoreTarget::LocalExclude => git_path(root, "info/exclude")?,
    };
    let existing = match std::fs::read(&target_path) {
        Ok(content) => content,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Vec::new(),
        Err(error) => return Err(git_ignore_io_error("read", error)),
    };
    let existing_text = String::from_utf8_lossy(&existing);
    let additions = patterns
        .into_iter()
        .filter(|pattern| !existing_text.lines().any(|line| line == pattern))
        .collect::<Vec<_>>();
    if additions.is_empty() {
        return Ok(successful_git_result());
    }

    if let Some(parent) = target_path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| git_ignore_io_error("create", error))?;
    }
    let mut appended = String::new();
    if !existing.is_empty() && !existing.ends_with(b"\n") {
        appended.push('\n');
    }
    for pattern in additions {
        appended.push_str(&pattern);
        appended.push('\n');
    }
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(target_path)
        .map_err(|error| git_ignore_io_error("open", error))?;
    file.write_all(appended.as_bytes())
        .map_err(|error| git_ignore_io_error("write", error))?;
    Ok(successful_git_result())
}

fn git_ignore_patterns(paths: &[String]) -> Result<Vec<String>, CoreError> {
    let mut patterns = Vec::with_capacity(paths.len());
    for path in paths {
        if path.contains(['\0', '\n', '\r']) {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Git ignore operation contains an invalid path",
            ));
        }
        let normalized = path.replace('\\', "/");
        let is_directory = normalized.ends_with('/');
        let normalized = normalized.trim_end_matches('/');
        if !is_safe_pathspec(normalized) {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Git ignore operation contains an invalid path",
            ));
        }

        let mut escaped = String::with_capacity(normalized.len() + 2);
        escaped.push('/');
        for character in normalized.chars() {
            if matches!(character, '*' | '?' | '[' | ']' | '#' | '!' | ' ') {
                escaped.push('\\');
            }
            escaped.push(character);
        }
        if is_directory {
            escaped.push('/');
        }
        patterns.push(escaped);
    }
    patterns.sort();
    patterns.dedup();
    if patterns.is_empty() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Git ignore operation contains an invalid path",
        ));
    }
    Ok(patterns)
}

fn repository_root(root: &str) -> Result<PathBuf, CoreError> {
    git_resolved_path(root, &["rev-parse", "--show-toplevel"], "repository root")
}

fn git_path(root: &str, path: &str) -> Result<PathBuf, CoreError> {
    git_resolved_path(
        root,
        &["rev-parse", "--path-format=absolute", "--git-path", path],
        "Git metadata path",
    )
}

fn git_resolved_path(root: &str, arguments: &[&str], label: &str) -> Result<PathBuf, CoreError> {
    let arguments = arguments
        .iter()
        .map(|value| value.to_string())
        .collect::<Vec<_>>();
    let response = execute_git_readonly(root, &arguments, None)?;
    if response.exit_code != 0 {
        return Err(CoreError::new(
            ErrorCode::ProcessFailed,
            format!("Could not resolve {label}"),
        )
        .with_details(response.output));
    }
    let path = response.output.trim();
    if path.is_empty() {
        return Err(CoreError::new(
            ErrorCode::ProcessFailed,
            format!("Could not resolve {label}"),
        ));
    }
    Ok(PathBuf::from(path))
}

fn git_ignore_io_error(action: &str, error: std::io::Error) -> CoreError {
    let code = if error.kind() == std::io::ErrorKind::PermissionDenied {
        ErrorCode::PermissionDenied
    } else {
        ErrorCode::Unknown
    };
    CoreError::new(code, format!("Could not {action} Git ignore file"))
        .with_details(error.to_string())
}

fn successful_git_result() -> GitCommandResponse {
    GitCommandResponse {
        arguments: Vec::new(),
        output: String::new(),
        stdout: String::new(),
        stderr: String::new(),
        exit_code: 0,
        invocations: Vec::new(),
        operation_error: None,
        stash_restore: None,
        tag_deletion: None,
        branch_deletion: None,
        warnings: Vec::new(),
    }
}

/// Immutable commit fields needed to rebuild a linear history without invoking
/// an editor or losing author and committer attribution.
#[derive(Clone)]
struct RewriteCommit {
    /// Original commit object used to derive the patch during history replay.
    hash: String,
    tree: String,
    parents: Vec<String>,
    author_name: String,
    author_email: String,
    author_date: String,
    committer_name: String,
    committer_email: String,
    committer_date: String,
    message: String,
}

/// Current local branch context and its first-parent chain, ordered from HEAD
/// toward the root commit.
struct HistoryRewriteContext {
    branch_reference: String,
    original_head: String,
    first_parent_chain: Vec<String>,
    published_commits: HashSet<String>,
}

fn edit_commit_message(
    root: &str,
    revision: &str,
    message: &str,
) -> Result<GitCommandResponse, CoreError> {
    let context = history_rewrite_context(root)?;
    let target = resolve_commit_revision(root, revision)?;
    let target_index = history_commit_index(&context, &target)?;
    let commits = checked_rewrite_range(root, &context, target_index)?;
    let mut parent = commits[0].parents.first().cloned();

    for (index, commit) in commits.iter().enumerate() {
        let commit_message = if index == 0 { message } else { &commit.message };
        parent = Some(write_commit_tree(
            root,
            commit,
            parent.as_deref(),
            commit_message,
        )?);
    }

    update_history_reference(
        root,
        &context,
        parent.as_deref().expect("rewrite range contains a commit"),
        "lithe: edit commit message",
    )
}

fn delete_commit(root: &str, revision: &str) -> Result<GitCommandResponse, CoreError> {
    let context = history_rewrite_context(root)?;
    let target = resolve_commit_revision(root, revision)?;
    let target_index = history_commit_index(&context, &target)?;
    let commits = checked_rewrite_range(root, &context, target_index)?;
    let target_commit = &commits[0];
    let parent = target_commit.parents.first().ok_or_else(|| {
        CoreError::new(
            ErrorCode::InvalidRequest,
            "The root commit cannot be deleted",
        )
    })?;

    let mut rewritten_head = parent.clone();
    for commit in commits.iter().skip(1) {
        let mut replayed_commit = commit.clone();
        replayed_commit.tree = replay_commit_tree(root, commit, &rewritten_head)?;
        rewritten_head = write_commit_tree(
            root,
            &replayed_commit,
            Some(&rewritten_head),
            &commit.message,
        )?;
    }

    let updated =
        update_history_reference(root, &context, &rewritten_head, "lithe: delete commit")?;
    if updated.exit_code != 0 {
        return Ok(updated);
    }

    // The branch move is CAS-protected above. A merge reset refreshes the clean
    // index and worktree but refuses to overwrite edits created concurrently
    // after the initial clean-tree check.
    let mut refreshed = execute_git(
        root,
        &["reset".into(), "--merge".into(), "HEAD".into()],
        None,
    )?;
    if refreshed.exit_code != 0 {
        refreshed.warnings.push(GitOperationWarning::new(
            "git_worktree_refresh_failed",
            "The commit was deleted, but the working tree could not be refreshed",
            Some(refreshed.output.clone()),
        ));
        refreshed.exit_code = 0;
    }
    Ok(refreshed)
}

fn squash_commits(
    root: &str,
    revisions: &[String],
    message: &str,
) -> Result<GitCommandResponse, CoreError> {
    if revisions.len() < 2 {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Select at least two commits to squash",
        ));
    }

    let context = history_rewrite_context(root)?;
    let mut selected = Vec::with_capacity(revisions.len());
    for revision in revisions {
        validate_revision(revision)?;
        selected.push(resolve_commit_revision(root, revision)?);
    }
    selected.sort();
    selected.dedup();
    if selected.len() != revisions.len() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Select distinct commits to squash",
        ));
    }

    let mut selected_indices = selected
        .iter()
        .map(|commit| history_commit_index(&context, commit))
        .collect::<Result<Vec<_>, _>>()?;
    selected_indices.sort_unstable();
    let newest_index = selected_indices[0];
    let oldest_index = *selected_indices
        .last()
        .expect("at least two commits were selected");
    if oldest_index - newest_index + 1 != selected_indices.len() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Only a contiguous range of commits can be squashed",
        ));
    }

    let commits = checked_rewrite_range(root, &context, oldest_index)?;
    let selected_count = oldest_index - newest_index + 1;
    let oldest = &commits[0];
    let newest = &commits[selected_count - 1];
    let mut squashed = oldest.clone();
    squashed.tree.clone_from(&newest.tree);
    squashed.committer_name.clone_from(&newest.committer_name);
    squashed.committer_email.clone_from(&newest.committer_email);
    squashed.committer_date.clone_from(&newest.committer_date);

    let mut parent = Some(write_commit_tree(
        root,
        &squashed,
        oldest.parents.first().map(String::as_str),
        message,
    )?);
    for commit in commits.iter().skip(selected_count) {
        parent = Some(write_commit_tree(
            root,
            commit,
            parent.as_deref(),
            &commit.message,
        )?);
    }

    update_history_reference(
        root,
        &context,
        parent.as_deref().expect("squash produces a commit"),
        "lithe: squash commits",
    )
}

fn history_rewrite_context(root: &str) -> Result<HistoryRewriteContext, CoreError> {
    let operation = operation_state(GitOperationStateRequest {
        root: root.to_string(),
    })?;
    if !operation.kind.is_empty() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Finish or abort the current Git operation before rewriting history",
        ));
    }

    let status = execute_git_readonly(
        root,
        &[
            "status".into(),
            "--porcelain=v1".into(),
            "--untracked-files=all".into(),
        ],
        None,
    )?;
    if status.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Git status failed")
                .with_details(status.output),
        );
    }
    if !status.output.trim().is_empty() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Commit history can only be rewritten with a clean working tree",
        ));
    }

    let branch = execute_git_readonly(
        root,
        &["symbolic-ref".into(), "--quiet".into(), "HEAD".into()],
        None,
    )?;
    let branch_reference = branch.output.trim();
    if branch.exit_code != 0 || !branch_reference.starts_with("refs/heads/") {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Commit history can only be rewritten on a checked out local branch",
        ));
    }

    let chain = execute_git_readonly(
        root,
        &["rev-list".into(), "--first-parent".into(), "HEAD".into()],
        None,
    )?;
    if chain.exit_code != 0 {
        return Err(CoreError::new(
            ErrorCode::ProcessFailed,
            "Could not read the current branch history",
        )
        .with_details(chain.output));
    }
    let first_parent_chain = chain
        .output
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(String::from)
        .collect::<Vec<_>>();
    let original_head = first_parent_chain.first().cloned().ok_or_else(|| {
        CoreError::new(
            ErrorCode::InvalidRequest,
            "The current branch does not contain any commits",
        )
    })?;

    let remote_commits =
        execute_git_readonly(root, &["rev-list".into(), "--remotes".into()], None)?;
    if remote_commits.exit_code != 0 {
        return Err(CoreError::new(
            ErrorCode::ProcessFailed,
            "Could not inspect remote Git history",
        )
        .with_details(remote_commits.output));
    }

    Ok(HistoryRewriteContext {
        branch_reference: branch_reference.to_string(),
        original_head,
        first_parent_chain,
        published_commits: remote_commits
            .output
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .map(String::from)
            .collect(),
    })
}

fn resolve_commit_revision(root: &str, revision: &str) -> Result<String, CoreError> {
    let response = execute_git_readonly(
        root,
        &[
            "rev-parse".into(),
            "--verify".into(),
            "--quiet".into(),
            "--end-of-options".into(),
            format!("{revision}^{{commit}}"),
        ],
        None,
    )?;
    let commit = response.output.trim();
    if response.exit_code != 0 || commit.is_empty() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "The selected Git commit does not exist",
        ));
    }
    Ok(commit.to_string())
}

fn history_commit_index(context: &HistoryRewriteContext, commit: &str) -> Result<usize, CoreError> {
    context
        .first_parent_chain
        .iter()
        .position(|candidate| candidate == commit)
        .ok_or_else(|| {
            CoreError::new(
                ErrorCode::InvalidRequest,
                "Only commits on the current branch first-parent history can be rewritten",
            )
        })
}

fn checked_rewrite_range(
    root: &str,
    context: &HistoryRewriteContext,
    oldest_index: usize,
) -> Result<Vec<RewriteCommit>, CoreError> {
    let hashes = &context.first_parent_chain[..=oldest_index];
    if hashes
        .iter()
        .any(|commit| context.published_commits.contains(commit))
    {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Commits published to a remote cannot be rewritten",
        ));
    }

    let mut commits = hashes
        .iter()
        .rev()
        .map(|hash| read_rewrite_commit(root, hash))
        .collect::<Result<Vec<_>, _>>()?;
    if commits.iter().any(|commit| commit.parents.len() > 1) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "A history range containing merge commits cannot be rewritten",
        ));
    }
    commits.shrink_to_fit();
    Ok(commits)
}

fn read_rewrite_commit(root: &str, hash: &str) -> Result<RewriteCommit, CoreError> {
    let format = "%T%x00%P%x00%an%x00%ae%x00%aI%x00%cn%x00%ce%x00%cI%x00%B%x00";
    let response = execute_git_readonly(
        root,
        &[
            "show".into(),
            "--no-patch".into(),
            "--no-show-signature".into(),
            format!("--format={format}"),
            hash.to_string(),
        ],
        None,
    )?;
    if response.exit_code != 0 {
        return Err(CoreError::new(
            ErrorCode::ProcessFailed,
            "Could not read a commit selected for history rewrite",
        )
        .with_details(response.output));
    }

    let output = response
        .output
        .strip_suffix("\0\n")
        .or_else(|| response.output.strip_suffix('\0'))
        .unwrap_or(&response.output);
    let fields = output.splitn(9, '\0').collect::<Vec<_>>();
    if fields.len() != 9 {
        return Err(CoreError::new(
            ErrorCode::ParseFailed,
            "Could not decode a commit selected for history rewrite",
        ));
    }
    Ok(RewriteCommit {
        hash: hash.to_string(),
        tree: fields[0].to_string(),
        parents: fields[1].split_whitespace().map(String::from).collect(),
        author_name: fields[2].to_string(),
        author_email: fields[3].to_string(),
        author_date: fields[4].to_string(),
        committer_name: fields[5].to_string(),
        committer_email: fields[6].to_string(),
        committer_date: fields[7].to_string(),
        message: fields[8].to_string(),
    })
}

fn replay_commit_tree(
    root: &str,
    commit: &RewriteCommit,
    rewritten_parent: &str,
) -> Result<String, CoreError> {
    let original_parent = commit.parents.first().ok_or_else(|| {
        CoreError::new(
            ErrorCode::InvalidRequest,
            "A root commit cannot be replayed after deleting its parent",
        )
    })?;
    let patch_arguments = vec![
        "diff-tree".to_string(),
        "--binary".to_string(),
        "--full-index".to_string(),
        "--no-ext-diff".to_string(),
        "--no-renames".to_string(),
        "--no-commit-id".to_string(),
        "-p".to_string(),
        original_parent.clone(),
        commit.hash.clone(),
    ];
    let patch = execute_git_readonly(root, &patch_arguments, None)?;
    if patch.exit_code != 0 {
        return Err(CoreError::new(
            ErrorCode::ProcessFailed,
            "Could not read changes after the deleted commit",
        )
        .with_details(patch.output));
    }

    let common_directory = git_resolved_path(
        root,
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
        "Git common directory",
    )?;
    let temporary_context = TemporaryGitCommitContext::prepare(root, Some(rewritten_parent))?;
    let environment = temporary_context.environment(root, &common_directory);
    let initialized = execute_git_with_environment(
        root,
        &["read-tree".to_string(), rewritten_parent.to_string()],
        None,
        false,
        &environment,
    )?;
    if initialized.exit_code != 0 {
        return Err(CoreError::new(
            ErrorCode::ProcessFailed,
            "Could not initialize history replay",
        )
        .with_details(initialized.output));
    }

    if !patch.stdout.is_empty() {
        let applied = execute_git_with_environment(
            root,
            &[
                "apply".to_string(),
                "--cached".to_string(),
                "--whitespace=nowarn".to_string(),
                "-".to_string(),
            ],
            Some(patch.stdout),
            false,
            &environment,
        )?;
        if applied.exit_code != 0 {
            return Err(CoreError::new(
                ErrorCode::ProcessFailed,
                "Could not replay changes after the deleted commit",
            )
            .with_details(applied.output));
        }
    }

    let tree =
        execute_git_with_environment(root, &["write-tree".to_string()], None, false, &environment)?;
    if tree.exit_code != 0 {
        return Err(CoreError::new(
            ErrorCode::ProcessFailed,
            "Could not write replayed Git tree",
        )
        .with_details(tree.output));
    }
    let tree_hash = tree.stdout.trim();
    if tree_hash.is_empty() {
        return Err(CoreError::new(
            ErrorCode::ParseFailed,
            "Git did not return a replayed tree identifier",
        ));
    }
    Ok(tree_hash.to_string())
}

fn write_commit_tree(
    root: &str,
    commit: &RewriteCommit,
    parent: Option<&str>,
    message: &str,
) -> Result<String, CoreError> {
    let mut arguments = vec![
        "-c".into(),
        "commit.gpgSign=false".into(),
        "commit-tree".into(),
        commit.tree.clone(),
    ];
    if let Some(parent) = parent {
        arguments.extend(["-p".into(), parent.to_string()]);
    }
    arguments.extend(["-F".into(), "-".into()]);
    let environment = vec![
        ("GIT_AUTHOR_NAME".into(), commit.author_name.clone()),
        ("GIT_AUTHOR_EMAIL".into(), commit.author_email.clone()),
        ("GIT_AUTHOR_DATE".into(), commit.author_date.clone()),
        ("GIT_COMMITTER_NAME".into(), commit.committer_name.clone()),
        ("GIT_COMMITTER_EMAIL".into(), commit.committer_email.clone()),
        ("GIT_COMMITTER_DATE".into(), commit.committer_date.clone()),
    ];
    let output = capture_git_with_environment(
        root,
        &arguments,
        Some(message.to_string()),
        false,
        &environment,
    )?;
    if output.exit_code != 0 {
        return Err(CoreError::new(
            ErrorCode::ProcessFailed,
            "Could not rebuild Git commit history",
        )
        .with_details(output.into_command_response(&arguments).output));
    }
    let hash = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if hash.is_empty() {
        return Err(CoreError::new(
            ErrorCode::ParseFailed,
            "Git did not return a rebuilt commit identifier",
        ));
    }
    Ok(hash)
}

fn update_history_reference(
    root: &str,
    context: &HistoryRewriteContext,
    new_head: &str,
    reflog_message: &str,
) -> Result<GitCommandResponse, CoreError> {
    execute_git(
        root,
        &[
            "update-ref".into(),
            "-m".into(),
            reflog_message.into(),
            context.branch_reference.clone(),
            new_head.into(),
            context.original_head.clone(),
        ],
        None,
    )
}

fn validated_revision(value: Option<&str>) -> Result<String, CoreError> {
    let value = required_text(value, "revision")?;
    validate_revision(&value)?;
    Ok(value)
}

pub(super) fn validated_reference(value: Option<&str>) -> Result<String, CoreError> {
    let value = required_text(value, "reference")?;
    if value.starts_with('-') || value.chars().any(char::is_whitespace) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid Git reference",
        ));
    }
    Ok(value)
}

fn validated_stash_reference(value: Option<&str>) -> Result<String, CoreError> {
    let value = required_text(value, "stash reference")?;
    if value.starts_with('-') || value.contains(char::is_whitespace) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid Git stash reference",
        ));
    }
    Ok(value)
}

fn validated_branch_name(root: &str, value: Option<&str>) -> Result<String, CoreError> {
    let value = required_text(value, "branch name")?;
    let validation = execute_git(
        root,
        &["check-ref-format".into(), "--branch".into(), value.clone()],
        None,
    )?;
    if validation.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::InvalidRequest, "Invalid Git branch name")
                .with_details(validation.output),
        );
    }
    Ok(value)
}

/// Validates a tag name against the same refname rules `git check-ref-format`
/// enforces, so an invalid name fails before any subprocess with a stable
/// message instead of depending on localized `git tag` output.
fn validated_tag_name(value: Option<&str>) -> Result<String, CoreError> {
    let value = required_text(value, "tag name")?;
    if is_invalid_tag_name(&value) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid Git tag name",
        ));
    }
    Ok(value)
}

/// Refname rules from `git check-ref-format` plus command-line safety guards
/// (no leading dash) shared by every Git mutation argument.
fn is_invalid_tag_name(value: &str) -> bool {
    if value.starts_with('-')
        || value == "@"
        || value.starts_with('/')
        || value.ends_with('/')
        || value.ends_with('.')
        || value.contains("..")
        || value.contains("@{")
        || value.contains("//")
    {
        return true;
    }
    if value.chars().any(|character| {
        character.is_control()
            || matches!(character, ' ' | '~' | '^' | ':' | '?' | '*' | '[' | '\\')
    }) {
        return true;
    }
    value
        .split('/')
        .any(|component| component.starts_with('.') || component.ends_with(".lock"))
}

/// Reports whether `refs/tags/<name>` already resolves, using `--verify` so
/// the probe matches the exact ref instead of any revision expression.
fn tag_exists(root: &str, name: &str) -> Result<bool, CoreError> {
    let probe = execute_git(
        root,
        &[
            "rev-parse".into(),
            "--verify".into(),
            "--quiet".into(),
            format!("refs/tags/{name}"),
        ],
        None,
    )?;
    Ok(probe.exit_code == 0)
}

/// Resolves a tag target revision to a commit and returns its object id.
/// Git allows tagging trees and blobs; the tag contract only promises commit
/// targets, so `<revision>^{commit}` both validates and yields the id the
/// mutation should point at.
fn resolved_commit_target(root: &str, target: &str) -> Result<Option<String>, CoreError> {
    let probe = execute_git(
        root,
        &[
            "rev-parse".into(),
            "--verify".into(),
            "--quiet".into(),
            format!("{target}^{{commit}}"),
        ],
        None,
    )?;
    Ok((probe.exit_code == 0).then(|| probe.stdout.trim().to_string()))
}

/// Deletes one tag and returns a structured deletion record so the host can
/// offer a restore. The probes run before the deletion because `git tag -d`
/// diagnostics are localized prose that cannot be mapped to stable errors.
fn delete_tag(root: &str, value: Option<&str>) -> Result<GitCommandResponse, CoreError> {
    let name = validated_tag_name(value)?;
    let reference = format!("refs/tags/{name}");
    let expected_object = resolve_ref_object(root, &reference)?.ok_or_else(|| {
        CoreError::new(
            ErrorCode::InvalidRequest,
            format!("The tag '{name}' does not exist"),
        )
    })?;
    let object_type = execute_git(
        root,
        &["cat-file".into(), "-t".into(), expected_object.clone()],
        None,
    )?;
    if object_type.exit_code != 0 {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            format!("The tag '{name}' does not exist"),
        ));
    }
    let is_annotated = object_type.stdout.trim() == "tag";
    let mut message = None;
    if is_annotated {
        let tag_object = execute_git(
            root,
            &["cat-file".into(), "tag".into(), expected_object.clone()],
            None,
        )?;
        if tag_object.exit_code == 0 {
            message = annotation_message_from_tag_object(&tag_object.stdout);
        }
    }
    // Peel the ref to a commit so pre-existing tree/blob tags cannot produce
    // a recovery record that violates the restore contract.
    let peeled = execute_git(
        root,
        &[
            "rev-parse".into(),
            "--verify".into(),
            format!("{expected_object}^{{commit}}"),
        ],
        None,
    )?;
    if peeled.exit_code != 0 {
        return Err(CoreError::new(
            ErrorCode::ProcessFailed,
            format!("Could not resolve tag target '{name}'"),
        )
        .with_details(peeled.output));
    }
    let mut result = delete_ref_if_unchanged(root, &reference, &expected_object)?;
    if result.exit_code == 0 {
        result.tag_deletion = Some(GitTagDeletionResponse {
            name,
            deleted_target: peeled.stdout.trim().to_string(),
            kind: if is_annotated {
                "annotated"
            } else {
                "lightweight"
            }
            .to_string(),
            message,
        });
    }
    Ok(result)
}

/// Deletes one local branch and returns a structured deletion record so the
/// host can offer a restore. The commit is resolved before the deletion
/// because `git branch -d` diagnostics are localized prose.
fn delete_branch(root: &str, branch: &str) -> Result<GitCommandResponse, CoreError> {
    let reference = format!("refs/heads/{branch}");
    let target = resolve_ref_object(root, &reference)?.ok_or_else(|| {
        CoreError::new(
            ErrorCode::InvalidRequest,
            format!("The branch '{branch}' does not exist"),
        )
    })?;
    ensure_branch_is_safely_deletable(root, branch, &reference, &target)?;
    let mut result = delete_ref_if_unchanged(root, &reference, &target)?;
    if result.exit_code == 0 {
        result.branch_deletion = Some(GitBranchDeletionResponse {
            name: branch.to_string(),
            deleted_target: target,
        });
        if let Err(error) = remove_branch_config(root, branch) {
            // The ref mutation already committed. Preserve recovery data and
            // report configuration cleanup as a diagnosable partial success.
            result.warnings.push(GitOperationWarning::new(
                "branch_config_cleanup_failed",
                &error.message,
                error.details,
            ));
        }
    }
    Ok(result)
}

/// Resolves an exact refname to its current unpeeled object id.
fn resolve_ref_object(root: &str, reference: &str) -> Result<Option<String>, CoreError> {
    let probe = execute_git(
        root,
        &[
            "rev-parse".into(),
            "--verify".into(),
            "--quiet".into(),
            reference.to_string(),
        ],
        None,
    )?;
    Ok((probe.exit_code == 0).then(|| probe.stdout.trim().to_string()))
}

/// Deletes a ref only when it still points at the object observed by the
/// caller. `update-ref` performs the comparison and mutation under the same
/// ref lock, closing the probe-then-mutate race.
fn delete_ref_if_unchanged(
    root: &str,
    reference: &str,
    expected_object: &str,
) -> Result<GitCommandResponse, CoreError> {
    let mut result = execute_git(
        root,
        &[
            "update-ref".into(),
            "-d".into(),
            reference.to_string(),
            expected_object.to_string(),
        ],
        None,
    )?;
    if result.exit_code != 0 {
        result.operation_error = Some(
            CoreError::new(
                ErrorCode::InvalidRequest,
                format!("The Git reference '{reference}' changed before it could be deleted"),
            )
            .with_details(result.output.clone()),
        );
    }
    Ok(result)
}

/// Preserves `git branch -d` safety before the atomic ref mutation: a branch
/// must not be checked out in any worktree and must be merged into its valid
/// upstream, or into HEAD when it has no usable upstream.
fn ensure_branch_is_safely_deletable(
    root: &str,
    branch: &str,
    reference: &str,
    target: &str,
) -> Result<(), CoreError> {
    let worktrees = execute_git(
        root,
        &["worktree".into(), "list".into(), "--porcelain".into()],
        None,
    )?;
    if worktrees.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Could not inspect Git worktrees")
                .with_details(worktrees.output),
        );
    }
    if worktrees
        .stdout
        .lines()
        .any(|line| line == format!("branch {reference}"))
    {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            format!("The branch '{branch}' is checked out in a worktree"),
        ));
    }

    let upstream = execute_git(
        root,
        &[
            "for-each-ref".into(),
            "--format=%(upstream)".into(),
            reference.to_string(),
        ],
        None,
    )?;
    if upstream.exit_code != 0 {
        return Err(CoreError::new(
            ErrorCode::ProcessFailed,
            "Could not inspect the branch upstream",
        )
        .with_details(upstream.output));
    }
    let upstream = upstream.stdout.trim();
    let merge_target = if !upstream.is_empty() && resolved_commit_target(root, upstream)?.is_some()
    {
        upstream
    } else {
        "HEAD"
    };
    let merged = execute_git(
        root,
        &[
            "merge-base".into(),
            "--is-ancestor".into(),
            target.to_string(),
            merge_target.to_string(),
        ],
        None,
    )?;
    match merged.exit_code {
        0 => Ok(()),
        1 => Err(CoreError::new(
            ErrorCode::InvalidRequest,
            format!("The branch '{branch}' is not fully merged"),
        )),
        _ => Err(CoreError::new(
            ErrorCode::ProcessFailed,
            format!("Could not verify whether branch '{branch}' is merged"),
        )
        .with_details(merged.output)),
    }
}

/// Removes branch-local configuration after the ref has been deleted, matching
/// the metadata cleanup performed by `git branch -d`.
fn remove_branch_config(root: &str, branch: &str) -> Result<(), CoreError> {
    let listing = capture_git_with_options(
        root,
        &[
            "config".into(),
            "--name-only".into(),
            "--get-regexp".into(),
            "^branch\\.".into(),
        ],
        None,
        false,
    )?;
    if listing.exit_code == 1 {
        return Ok(());
    }
    if listing.exit_code != 0 {
        return Err(CoreError::new(
            ErrorCode::ProcessFailed,
            "Could not inspect branch configuration",
        )
        .with_details(String::from_utf8_lossy(&listing.stderr)));
    }
    let prefix = format!("branch.{branch}.");
    if !String::from_utf8_lossy(&listing.stdout)
        .lines()
        .any(|key| key.starts_with(&prefix))
    {
        return Ok(());
    }
    let cleanup = capture_git_with_options(
        root,
        &[
            "config".into(),
            "--remove-section".into(),
            format!("branch.{branch}"),
        ],
        None,
        false,
    )?;
    if cleanup.exit_code == 0 {
        return Ok(());
    }
    Err(CoreError::new(
        ErrorCode::ProcessFailed,
        format!("Could not remove configuration for deleted branch '{branch}'"),
    )
    .with_details(String::from_utf8_lossy(&cleanup.stderr)))
}

/// Extracts the annotation message from a raw tag object byte-for-byte, so a
/// restored tag keeps the original message including CRLF line endings and
/// trailing newlines. Only the signature block is cut, by locating its first
/// line in the raw content; the signature belongs to the previous tagger and
/// a restored tag would be signed separately.
fn annotation_message_from_tag_object(raw: &str) -> Option<String> {
    let (_, message) = raw.split_once("\n\n")?;
    let mut offset = 0;
    for line in message.split_inclusive('\n') {
        let without_eol = line.trim_end_matches(['\r', '\n']);
        if without_eol.starts_with("-----BEGIN ") && without_eol.ends_with("SIGNATURE-----") {
            return Some(message[..offset].to_string());
        }
        offset += line.len();
    }
    Some(message.to_string())
}

fn local_branch_name(reference: &str) -> Result<String, CoreError> {
    let branch = reference
        .strip_prefix("refs/heads/")
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            CoreError::new(
                ErrorCode::InvalidRequest,
                "Only local branches support this Git operation",
            )
        })?;
    if !is_safe_pathspec(branch) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid Git branch name",
        ));
    }
    Ok(branch.to_string())
}

pub(super) fn current_branch(root: &str) -> Result<String, CoreError> {
    let response = execute_git(root, &["branch".into(), "--show-current".into()], None)?;
    if response.exit_code != 0 {
        return Err(CoreError::new(
            ErrorCode::ProcessFailed,
            "Could not determine current branch",
        )
        .with_details(response.output));
    }
    let branch = response.output.trim();
    if branch.is_empty() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Git operation requires a checked out branch",
        ));
    }
    Ok(branch.to_string())
}

fn optional_current_branch(root: &str) -> Result<Option<String>, CoreError> {
    let response = execute_git_readonly(root, &["branch".into(), "--show-current".into()], None)?;
    if response.exit_code != 0 {
        return Err(CoreError::new(
            ErrorCode::ProcessFailed,
            "Could not determine current branch",
        )
        .with_details(response.output));
    }
    Ok(match response.output.trim() {
        "" => None,
        branch => Some(branch.to_string()),
    })
}

fn is_current_reference(root: &str, reference: &str) -> Result<bool, CoreError> {
    let current = current_branch(root)?;
    Ok(reference == current || reference == format!("refs/heads/{current}"))
}

fn failed_git_result(error: CoreError) -> GitCommandResponse {
    GitCommandResponse {
        arguments: Vec::new(),
        output: String::new(),
        stdout: String::new(),
        stderr: String::new(),
        exit_code: 1,
        invocations: Vec::new(),
        operation_error: Some(error),
        stash_restore: None,
        tag_deletion: None,
        branch_deletion: None,
        warnings: Vec::new(),
    }
}

/// Discards both index and working-tree content for an explicitly confirmed rollback.
/// The normal `discard` operation deliberately preserves staged content, while
/// this explicit operation is destructive for the whole path.
fn discard_all(root: &str, paths: &[String]) -> Result<GitCommandResponse, CoreError> {
    let mut tracked = Vec::new();
    let mut untracked = Vec::new();
    let status_arguments = vec![
        "status".to_string(),
        "--porcelain=v1".to_string(),
        "-z".to_string(),
        "--untracked-files=all".to_string(),
    ];
    let status = execute_git(root, &status_arguments, None)?;
    if status.exit_code != 0 {
        return Ok(status);
    }
    let untracked_paths = status
        .output
        .split('\0')
        .filter_map(|record| record.strip_prefix("?? "))
        .collect::<HashSet<_>>();
    for path in paths {
        if untracked_paths.contains(path.as_str()) {
            untracked.push(path.clone());
        } else {
            tracked.push(path.clone());
        }
    }

    let mut final_response = status;
    if !tracked.is_empty() {
        let arguments = vec![
            "restore".to_string(),
            "--source=HEAD".to_string(),
            "--staged".to_string(),
            "--worktree".to_string(),
            "--pathspec-from-file=-".to_string(),
            "--pathspec-file-nul".to_string(),
        ];
        // Passing pathspecs over stdin avoids the Windows command-line limit for
        // large source-control selections and preserves unusual path characters.
        let pathspec_input = tracked
            .iter()
            .flat_map(|path| [path.as_str(), "\0"])
            .collect::<String>();
        let restored = execute_git(root, &arguments, Some(pathspec_input))?;
        if restored.exit_code != 0 {
            return Ok(restored);
        }
        final_response = restored;
    }
    if !untracked.is_empty() {
        let mut arguments = vec![
            "clean".to_string(),
            "-f".to_string(),
            "-d".to_string(),
            "--".to_string(),
        ];
        arguments.extend(untracked);
        return execute_git(root, &arguments, None);
    }
    Ok(final_response)
}

fn pop_stash(root: &str, reference: &str) -> Result<GitCommandResponse, CoreError> {
    let mut result = execute_git(
        root,
        &["stash".into(), "pop".into(), reference.to_string()],
        None,
    )?;
    let conflicted_paths = conflicted_paths(root)?;
    let entry_was_kept = stash_reference_exists(root, reference)?;
    if entry_was_kept && (!conflicted_paths.is_empty() || result.exit_code == 0) {
        result.stash_restore = Some(GitStashRestoreResponse {
            stash_reference: reference.to_string(),
            conflicted_paths,
        });
    }
    Ok(result)
}

fn apply_stash(root: &str, reference: &str) -> Result<GitCommandResponse, CoreError> {
    let mut result = execute_git(
        root,
        &["stash".into(), "apply".into(), reference.to_string()],
        None,
    )?;
    let conflicted_paths = conflicted_paths(root)?;
    if !conflicted_paths.is_empty() {
        result.exit_code = 1;
        result.stash_restore = Some(GitStashRestoreResponse {
            stash_reference: reference.to_string(),
            conflicted_paths,
        });
    }
    Ok(result)
}

fn pull_with_auto_stash(
    root: &str,
    pull_arguments: &[String],
) -> Result<GitCommandResponse, CoreError> {
    let status = execute_git_readonly(
        root,
        &[
            "status".into(),
            "--porcelain=v1".into(),
            "-z".into(),
            "--untracked-files=all".into(),
        ],
        None,
    )?;
    if status.exit_code != 0 {
        return Ok(status);
    }
    if status.stdout.is_empty() {
        return execute_git(root, pull_arguments, None);
    }

    let stash_marker = format!(
        "lithe: auto-stash before pull:{}:{}",
        std::process::id(),
        AUTO_STASH_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    );
    let stashed = execute_git(
        root,
        &[
            "stash".into(),
            "push".into(),
            "--include-untracked".into(),
            "--message".into(),
            stash_marker.clone(),
        ],
        None,
    )?;
    if stashed.exit_code != 0 {
        return Ok(stashed);
    }
    let stash_oid = find_stash_oid_by_message(root, &stash_marker)?.ok_or_else(|| {
        CoreError::new(
            ErrorCode::ProcessFailed,
            "Pull created a temporary stash but could not identify it",
        )
    })?;

    let pulled = execute_git(root, pull_arguments, None)?;
    if pulled.exit_code != 0 {
        return Ok(pulled);
    }

    let mut restored = execute_git(
        root,
        &["stash".into(), "apply".into(), stash_oid.clone()],
        None,
    )?;
    let conflicted_paths = conflicted_paths(root)?;
    let stash_reference = stash_reference_for_oid(root, &stash_oid)?;
    if restored.exit_code != 0 || !conflicted_paths.is_empty() {
        restored.exit_code = 1;
        restored.stash_restore = Some(GitStashRestoreResponse {
            stash_reference: stash_reference.unwrap_or(stash_oid),
            conflicted_paths,
        });
        return Ok(restored);
    }

    let Some(stash_reference) = stash_reference else {
        restored.warnings.push(GitOperationWarning::new(
            "git_stash_drop_failed",
            "The pull and stash restore succeeded, but the saved stash could not be located for removal",
            None,
        ));
        return Ok(restored);
    };
    let dropped = execute_git(
        root,
        &["stash".into(), "drop".into(), stash_reference],
        None,
    )?;
    if dropped.exit_code != 0 {
        restored.warnings.push(GitOperationWarning::new(
            "git_stash_drop_failed",
            "The pull and stash restore succeeded, but the saved stash could not be removed",
            Some(dropped.output),
        ));
    }
    Ok(restored)
}

fn find_stash_oid_by_message(root: &str, message: &str) -> Result<Option<String>, CoreError> {
    let list = execute_git_readonly(
        root,
        &["stash".into(), "list".into(), "--format=%H%x09%gs".into()],
        None,
    )?;
    if list.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Could not inspect Git stashes")
                .with_details(list.output),
        );
    }
    Ok(list.stdout.lines().find_map(|line| {
        let (oid, subject) = line.split_once('\t')?;
        subject.contains(message).then(|| oid.to_string())
    }))
}

fn stash_reference_for_oid(root: &str, oid: &str) -> Result<Option<String>, CoreError> {
    let list = execute_git_readonly(
        root,
        &["stash".into(), "list".into(), "--format=%gd%x09%H".into()],
        None,
    )?;
    if list.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Could not inspect Git stashes")
                .with_details(list.output),
        );
    }
    Ok(list.stdout.lines().find_map(|line| {
        let (reference, commit) = line.split_once('\t')?;
        (commit == oid).then(|| reference.to_string())
    }))
}

fn conflicted_paths(root: &str) -> Result<Vec<String>, CoreError> {
    let response = execute_git(
        root,
        &[
            "diff".into(),
            "--name-only".into(),
            "--diff-filter=U".into(),
            "--".into(),
        ],
        None,
    )?;
    if response.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Git conflict status failed")
                .with_details(response.output),
        );
    }
    let mut paths = response
        .output
        .lines()
        .map(str::trim)
        .filter(|path| !path.is_empty())
        .map(String::from)
        .collect::<Vec<_>>();
    paths.sort();
    paths.dedup();
    Ok(paths)
}

fn stash_reference_exists(root: &str, reference: &str) -> Result<bool, CoreError> {
    let list = execute_git(
        root,
        &["stash".into(), "list".into(), "--format=%gd".into()],
        None,
    )?;
    if list.exit_code != 0 {
        return Ok(false);
    }
    Ok(list.output.lines().any(|line| line.trim() == reference))
}

fn find_stash_reference(root: &str, message: &str) -> Result<Option<String>, CoreError> {
    let list = execute_git(
        root,
        &["stash".into(), "list".into(), "--format=%gd%x09%gs".into()],
        None,
    )?;
    if list.exit_code != 0 {
        return Ok(None);
    }
    Ok(list.output.lines().find_map(|line| {
        let (reference, subject) = line.split_once('\t')?;
        subject
            .contains(message)
            .then(|| reference.trim().to_string())
    }))
}

#[derive(Clone)]
struct PushTarget {
    local_branch: String,
    remote: String,
    remote_branch: String,
    upstream: Option<String>,
    comparison_reference: Option<String>,
}

/// Resolves the remote destination and commits that a subsequent push will use.
pub fn push_preview(request: GitPushPreviewRequest) -> Result<GitPushPreviewResponse, CoreError> {
    let root = validate_root(&request.root)?;
    let reference = if let Some(reference) = request.git_reference.as_ref() {
        let reference = validated_git_reference(&root, reference)?;
        if reference.kind != "local" {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Only local branches can be pushed",
            ));
        }
        Some(reference.full_name)
    } else {
        request
            .reference
            .as_deref()
            .map(|reference| validated_reference(Some(reference)))
            .transpose()?
    };
    let target = resolve_push_target(&root, reference.as_deref())?;
    let limit = request.limit.clamp(1, 5_000);
    let local_reference = format!("refs/heads/{}", target.local_branch);
    let local_head = resolve_commit_revision(&root, &local_reference)?;
    let tags = resolve_push_tags(
        &root,
        request.push_tags.as_deref().unwrap_or("none"),
        &local_head,
    )?;
    let remote_tracking_oid = target
        .comparison_reference
        .as_deref()
        .map(|reference| resolve_commit_revision(&root, reference))
        .transpose()?;
    let selectors = if let Some(comparison_reference) = target.comparison_reference.as_ref() {
        vec![format!("{comparison_reference}..{local_reference}")]
    } else {
        // A branch without an upstream may still be based on another remote branch.
        // Excluding every commit reachable from the selected remote keeps the preview
        // focused on commits that publication would introduce.
        vec![
            local_reference,
            "--not".to_string(),
            format!("--remotes={}", target.remote),
        ]
    };
    let (commits, has_more) = read_commit_log(&root, selectors, limit, "Git push preview failed")?;

    Ok(GitPushPreviewResponse {
        local_branch: target.local_branch,
        local_head,
        remote: target.remote,
        remote_branch: target.remote_branch,
        remote_tracking_oid,
        upstream: target.upstream,
        tags,
        commits,
        has_more,
    })
}

fn push(
    root: &str,
    reference: Option<&str>,
    force: bool,
    push_tags: Option<&str>,
    expected_push: Option<&GitPushExpectationRequest>,
) -> Result<GitCommandResponse, CoreError> {
    let tag_scope = push_tags.unwrap_or("none");
    let tag_argument = match tag_scope {
        "none" => None,
        "all" => Some("--tags"),
        "reachable" => Some("--follow-tags"),
        _ => {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Unsupported Git push tag scope",
            ))
        }
    };
    let target = resolve_push_target(root, reference)?;
    let should_set_upstream = target.upstream.is_none();
    if let Some(expected_push) = expected_push {
        validate_push_expectation(root, &target, tag_scope, expected_push)?;
    }
    let mut arguments = vec!["push".to_string()];
    if force {
        // Bind reviewed pushes to the observed remote OID so an unseen remote update is rejected.
        arguments.push(match expected_push {
            Some(expected) => format!(
                "--force-with-lease=refs/heads/{}:{}",
                target.remote_branch,
                expected.remote_tracking_oid.as_deref().unwrap_or_default()
            ),
            None => "--force-with-lease".into(),
        });
    }
    if expected_push.is_none() {
        if let Some(tag_argument) = tag_argument {
            arguments.push(tag_argument.into());
        }
    }
    if should_set_upstream && expected_push.is_none() {
        arguments.push("--set-upstream".into());
    }
    let source = expected_push
        .map(|expected| expected.local_head.clone())
        .unwrap_or_else(|| format!("refs/heads/{}", target.local_branch));
    let remote = target.remote;
    let remote_branch = target.remote_branch;
    let local_branch = target.local_branch;
    arguments.extend([
        remote.clone(),
        format!("{source}:refs/heads/{remote_branch}"),
    ]);
    if let Some(expected) = expected_push {
        arguments.extend(
            expected
                .tags
                .iter()
                .map(|tag| format!("{}:{}", tag.object_id, tag.full_name)),
        );
    }
    let pushed = execute_git(root, &arguments, None)?;
    if pushed.exit_code != 0 || !should_set_upstream || expected_push.is_none() {
        return Ok(pushed);
    }

    if let Some(configuration) =
        configure_branch_upstream(root, &local_branch, &remote, &remote_branch)?
    {
        return Ok(push_with_upstream_warning(pushed, configuration));
    }
    Ok(pushed)
}

fn push_with_upstream_warning(
    mut pushed: GitCommandResponse,
    configuration: GitCommandResponse,
) -> GitCommandResponse {
    pushed.warnings.push(GitOperationWarning::new(
        "git_upstream_configuration_failed",
        "The push succeeded, but the branch upstream could not be configured",
        Some(configuration.output),
    ));
    pushed
}

/// Returns one metadata-only snapshot for every registered worktree.
pub fn worktrees(request: GitWorktreesRequest) -> Result<GitWorktreesResponse, CoreError> {
    let root = validate_root(&request.root)?;
    Ok(GitWorktreesResponse {
        worktrees: list_worktrees(&root)?,
    })
}

fn list_worktrees(root: &str) -> Result<Vec<GitWorktreeResponse>, CoreError> {
    let arguments = vec![
        "worktree".to_string(),
        "list".to_string(),
        "--porcelain".to_string(),
        "-z".to_string(),
    ];
    let response = execute_git_readonly(root, &arguments, None)?;
    if response.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Git worktree listing failed")
                .with_details(response.output),
        );
    }
    let current_root = repository_root(root)?
        .canonicalize()
        .unwrap_or_else(|_| PathBuf::from(root));
    let mut records = Vec::new();
    let mut fields = Vec::new();
    for field in response.stdout.split('\0') {
        if field.is_empty() {
            if !fields.is_empty() {
                records.push(parse_worktree_record(
                    &fields,
                    records.is_empty(),
                    &current_root,
                )?);
                fields.clear();
            }
        } else {
            fields.push(field);
        }
    }
    if !fields.is_empty() {
        records.push(parse_worktree_record(
            &fields,
            records.is_empty(),
            &current_root,
        )?);
    }
    // Git currently emits the primary worktree first, but sorting here makes
    // that display contract explicit and stable across Git versions.
    records.sort_by(|left, right| {
        right
            .is_primary
            .cmp(&left.is_primary)
            .then_with(|| left.path.cmp(&right.path))
    });
    Ok(records)
}

fn worktree_paths_match(left: &str, right: &str) -> bool {
    let left_path = PathBuf::from(left);
    let right_path = PathBuf::from(right);
    if left_path == right_path {
        return true;
    }
    match (left_path.canonicalize(), right_path.canonicalize()) {
        (Ok(left), Ok(right)) => left == right,
        _ => false,
    }
}

fn parse_worktree_record(
    fields: &[&str],
    is_primary: bool,
    current_root: &Path,
) -> Result<GitWorktreeResponse, CoreError> {
    let path = fields
        .iter()
        .find_map(|field| field.strip_prefix("worktree "))
        .filter(|path| !path.is_empty())
        .ok_or_else(|| {
            CoreError::new(
                ErrorCode::ProcessFailed,
                "Git returned an invalid worktree record",
            )
        })?;
    let head = fields
        .iter()
        .find_map(|field| field.strip_prefix("HEAD "))
        .unwrap_or_default()
        .to_string();
    let branch = fields
        .iter()
        .find_map(|field| field.strip_prefix("branch "))
        .map(str::to_string);
    let value_after_marker = |marker: &str| {
        fields.iter().find_map(|field| {
            if *field == marker {
                Some(None)
            } else {
                field
                    .strip_prefix(&format!("{marker} "))
                    .map(|value| Some(value.to_string()))
            }
        })
    };
    let lock = value_after_marker("locked");
    let prunable = value_after_marker("prunable");
    let reported_path = PathBuf::from(path);
    let normalized_path = reported_path
        .canonicalize()
        .unwrap_or_else(|_| reported_path.clone());
    Ok(GitWorktreeResponse {
        path: normalized_path.to_string_lossy().to_string(),
        head,
        branch,
        is_current: normalized_path == current_root,
        is_primary,
        is_bare: fields.contains(&"bare"),
        is_detached: fields.contains(&"detached"),
        is_locked: lock.is_some(),
        lock_reason: lock.flatten(),
        is_prunable: prunable.is_some(),
        prune_reason: prunable.flatten(),
    })
}

fn create_worktree(root: &str, request: &GitWriteRequest) -> Result<GitCommandResponse, CoreError> {
    let branch = validated_branch_name(root, request.name.as_deref())?;
    let destination = required_text(request.destination.as_deref(), "worktree destination")?;
    if destination.starts_with('-') || destination.contains(['\0', '\n', '\r']) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid Git worktree destination",
        ));
    }
    let reference = request
        .git_reference
        .as_ref()
        .ok_or_else(invalid_git_reference)
        .and_then(|reference| validated_git_reference(root, reference))?;
    let mut arguments = vec!["worktree".into(), "add".into()];
    if reference.kind == "remote" {
        // Let Git create the branch and its tracking configuration in one
        // mutation. The complete ref keeps a same-named local branch from
        // making the selected remote-tracking branch ambiguous.
        arguments.push("--track".into());
    }
    let source = if let Some(revision) = request.revision.as_deref() {
        validated_revision(Some(revision))?
    } else {
        reference.full_name.clone()
    };
    arguments.extend(["-b".into(), branch, "--".into(), destination, source]);
    execute_git(root, &arguments, None)
}

fn mutate_worktree(root: &str, request: &GitWriteRequest) -> Result<GitCommandResponse, CoreError> {
    let destination = required_text(request.destination.as_deref(), "worktree destination")?;
    if destination.starts_with('-') || destination.contains(['\0', '\n', '\r']) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid Git worktree destination",
        ));
    }
    let entries = list_worktrees(root)?;
    let target = entries
        .iter()
        .find(|entry| worktree_paths_match(&entry.path, &destination))
        .ok_or_else(|| {
            CoreError::new(
                ErrorCode::InvalidRequest,
                "The selected path is not a registered Git worktree",
            )
        })?;
    if request.operation == "removeWorktree" && (target.is_current || target.is_primary) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "The current or primary Git worktree cannot be removed",
        ));
    }
    if request.operation == "removeWorktree" && target.is_locked {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Unlock the Git worktree before removing it",
        ));
    }

    let mut arguments = vec!["worktree".to_string()];
    match request.operation.as_str() {
        "removeWorktree" => {
            arguments.push("remove".into());
            if request.force {
                arguments.push("--force".into());
            }
        }
        "lockWorktree" => arguments.push("lock".into()),
        "unlockWorktree" => arguments.push("unlock".into()),
        _ => unreachable!("caller restricts worktree mutations"),
    }
    arguments.extend(["--".into(), destination]);
    execute_git(root, &arguments, None)
}

fn configure_branch_upstream(
    root: &str,
    local_branch: &str,
    remote: &str,
    remote_branch: &str,
) -> Result<Option<GitCommandResponse>, CoreError> {
    let remote_config = execute_git(
        root,
        &[
            "config".to_string(),
            "--local".to_string(),
            "--replace-all".to_string(),
            format!("branch.{local_branch}.remote"),
            remote.to_string(),
        ],
        None,
    )?;
    if remote_config.exit_code != 0 {
        return Ok(Some(remote_config));
    }
    let merge_config = execute_git(
        root,
        &[
            "config".to_string(),
            "--local".to_string(),
            "--replace-all".to_string(),
            format!("branch.{local_branch}.merge"),
            format!("refs/heads/{remote_branch}"),
        ],
        None,
    )?;
    Ok((merge_config.exit_code != 0).then_some(merge_config))
}

fn nul_pathspec_input(paths: &[String]) -> String {
    paths
        .iter()
        .flat_map(|path| [path.as_str(), "\0"])
        .collect()
}

fn empty_tree_oid(root: &str) -> Result<String, CoreError> {
    let hashed = execute_git_readonly(
        root,
        &[
            "hash-object".to_string(),
            "-t".to_string(),
            "tree".to_string(),
            "--stdin".to_string(),
        ],
        Some(String::new()),
    )?;
    if hashed.exit_code != 0 {
        return Err(CoreError::new(
            ErrorCode::ProcessFailed,
            "Could not resolve Git's empty tree",
        )
        .with_details(hashed.output));
    }
    let oid = hashed.stdout.trim();
    validate_revision(oid)?;
    Ok(oid.to_string())
}

fn validate_push_expectation(
    root: &str,
    target: &PushTarget,
    tag_scope: &str,
    expected: &GitPushExpectationRequest,
) -> Result<(), CoreError> {
    let local_reference = format!("refs/heads/{}", target.local_branch);
    let local_head = resolve_commit_revision(root, &local_reference)?;
    let remote_tracking_oid = target
        .comparison_reference
        .as_deref()
        .map(|reference| resolve_commit_revision(root, reference))
        .transpose()?;
    let tags = resolve_push_tags(root, tag_scope, &local_head)?;
    let expected_tags = expected
        .tags
        .iter()
        .map(|tag| (&tag.full_name, &tag.object_id))
        .collect::<Vec<_>>();
    let actual_tags = tags
        .iter()
        .map(|tag| (&tag.full_name, &tag.object_id))
        .collect::<Vec<_>>();
    if expected.local_branch != target.local_branch
        || expected.local_head != local_head
        || expected.remote != target.remote
        || expected.remote_branch != target.remote_branch
        || expected.remote_tracking_oid != remote_tracking_oid
        || expected_tags != actual_tags
    {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Git push preview is stale; refresh and try again.",
        ));
    }
    Ok(())
}

fn resolve_push_tags(
    root: &str,
    scope: &str,
    local_head: &str,
) -> Result<Vec<GitPushTagResponse>, CoreError> {
    if scope == "none" {
        return Ok(Vec::new());
    }
    if !matches!(scope, "all" | "reachable") {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Unsupported Git push tag scope",
        ));
    }
    let listed = execute_git_readonly(
        root,
        &[
            "for-each-ref".into(),
            "--sort=refname".into(),
            "--format=%(refname)%09%(objectname)%09%(objecttype)%09%(*objectname)".into(),
            "refs/tags".into(),
        ],
        None,
    )?;
    if listed.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Could not inspect Git tags")
                .with_details(listed.output),
        );
    }

    let mut tags = Vec::new();
    for line in listed.stdout.lines() {
        let columns = line.split('\t').collect::<Vec<_>>();
        if columns.len() != 4 || !columns[0].starts_with("refs/tags/") || columns[1].is_empty() {
            return Err(CoreError::new(
                ErrorCode::ParseFailed,
                "Could not decode Git tag metadata",
            ));
        }
        if scope == "reachable" {
            if columns[2] != "tag" || columns[3].is_empty() {
                continue;
            }
            let reachable = execute_git_readonly(
                root,
                &[
                    "merge-base".into(),
                    "--is-ancestor".into(),
                    columns[3].into(),
                    local_head.into(),
                ],
                None,
            )?;
            if reachable.exit_code == 1 {
                continue;
            }
            if reachable.exit_code != 0 {
                return Err(CoreError::new(
                    ErrorCode::ProcessFailed,
                    "Could not inspect Git tag reachability",
                )
                .with_details(reachable.output));
            }
        }
        tags.push(GitPushTagResponse {
            full_name: columns[0].to_string(),
            object_id: columns[1].to_string(),
        });
    }
    Ok(tags)
}

fn resolve_push_target(root: &str, reference: Option<&str>) -> Result<PushTarget, CoreError> {
    let local_branch = match reference {
        Some(reference) => local_branch_name(&validated_reference(Some(reference))?)?,
        None => current_branch(root)?,
    };
    let upstream_lookup = execute_git_readonly(
        root,
        &[
            "rev-parse".into(),
            "--abbrev-ref".into(),
            format!("{local_branch}@{{upstream}}"),
        ],
        None,
    )?;
    let (upstream, upstream_components) = if upstream_lookup.exit_code == 0 {
        let upstream = upstream_lookup.output.trim().to_string();
        let components =
            mutations::remote_branch_components(root, &format!("refs/remotes/{upstream}"))?;
        (Some(upstream), Some(components))
    } else {
        (None, None)
    };

    let branch_push_remote =
        read_git_config_value(root, &format!("branch.{local_branch}.pushRemote"))?;
    let default_push_remote = read_git_config_value(root, "remote.pushDefault")?;
    let branch_remote = read_git_config_value(root, &format!("branch.{local_branch}.remote"))?
        .filter(|remote| remote != ".");
    let remote = branch_push_remote
        .or(default_push_remote)
        .or_else(|| {
            upstream_components
                .as_ref()
                .map(|(remote, _)| remote.clone())
        })
        .or(branch_remote)
        .map(Ok)
        .unwrap_or_else(|| default_push_remote_name(root))?;
    validate_push_component(&remote)?;

    let remote_branch = upstream_components
        .as_ref()
        .filter(|(upstream_remote, _)| upstream_remote == &remote)
        .map(|(_, branch)| branch.clone())
        .unwrap_or_else(|| local_branch.clone());
    let target_reference = format!("refs/remotes/{remote}/{remote_branch}");
    let comparison_reference = if reference_exists(root, &target_reference)? {
        Some(target_reference)
    } else {
        None
    };

    Ok(PushTarget {
        local_branch,
        remote,
        remote_branch,
        upstream,
        comparison_reference,
    })
}

fn read_git_config_value(root: &str, key: &str) -> Result<Option<String>, CoreError> {
    let configured = execute_git_readonly(
        root,
        &["config".into(), "--get".into(), key.to_string()],
        None,
    )?;
    if configured.exit_code == 1 {
        return Ok(None);
    }
    if configured.exit_code != 0 {
        return Err(CoreError::new(
            ErrorCode::ProcessFailed,
            "Could not read Git push configuration",
        )
        .with_details(configured.output));
    }
    let value = configured.output.trim();
    if value.is_empty() {
        return Ok(None);
    }
    validate_push_component(value)?;
    Ok(Some(value.to_string()))
}

fn reference_exists(root: &str, reference: &str) -> Result<bool, CoreError> {
    let result = execute_git_readonly(
        root,
        &[
            "show-ref".into(),
            "--verify".into(),
            "--quiet".into(),
            reference.to_string(),
        ],
        None,
    )?;
    if result.exit_code > 1 {
        return Err(CoreError::new(
            ErrorCode::ProcessFailed,
            "Could not inspect Git push destination",
        )
        .with_details(result.output));
    }
    Ok(result.exit_code == 0)
}

fn default_push_remote_name(root: &str) -> Result<String, CoreError> {
    let remotes = execute_git_readonly(root, &["remote".into()], None)?;
    if remotes.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Could not list Git remotes")
                .with_details(remotes.output),
        );
    }
    let remote = remotes
        .output
        .lines()
        .map(str::trim)
        .find(|remote| *remote == "origin")
        .or_else(|| {
            remotes
                .output
                .lines()
                .map(str::trim)
                .find(|remote| !remote.is_empty())
        })
        .ok_or_else(|| CoreError::new(ErrorCode::InvalidRequest, "No Git remote is configured"))?;
    validate_push_component(remote)?;
    Ok(remote.to_string())
}

fn validate_push_component(value: &str) -> Result<(), CoreError> {
    if value.is_empty()
        || value.starts_with('-')
        || value.contains(['\0', '\n', '\r'])
        || value.chars().any(char::is_whitespace)
    {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid Git push destination",
        ));
    }
    Ok(())
}

fn publish_branch(root: &str, name: Option<&str>) -> Result<GitCommandResponse, CoreError> {
    let name = validated_branch_name(root, name)?;
    match optional_current_branch(root)? {
        Some(current) if current != name => {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Publish the currently checked out branch",
            ));
        }
        Some(_) => {}
        None => {
            let created = execute_git(
                root,
                &["switch".into(), "-c".into(), name.clone(), "HEAD".into()],
                None,
            )?;
            if created.exit_code != 0 {
                return Ok(created);
            }
        }
    }
    execute_git(
        root,
        &[
            "push".into(),
            "--set-upstream".into(),
            "origin".into(),
            name,
        ],
        None,
    )
}

/// Checks out `request.reference`, honouring the conflict-resolution strategy the user
/// picked in the checkout dialog.
///
/// Three strategies, mirroring IntelliJ IDEA:
/// - default: plain switch. Git refuses when local changes would be overwritten.
/// - `force`: `--discard-changes`, throwing the local edits away.
/// - `auto_stash`: stash, switch, then restore the stash ("smart checkout").
fn checkout(root: &str, request: GitWriteRequest) -> Result<GitCommandResponse, CoreError> {
    if request.reference_kind.as_deref() == Some("local") {
        if let Some(reference) = request
            .reference
            .as_deref()
            .filter(|value| !value.starts_with('-') && !value.chars().any(char::is_whitespace))
        {
            if is_current_reference(root, reference)? {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "The current branch is already checked out",
                ));
            }
        }
    }
    if request.auto_stash {
        return checkout_with_auto_stash(root, request);
    }
    switch_reference(root, &request)
}

/// Checks out a local or remote branch, then rebases it onto the branch that
/// was current before the switch. A dirty tree is rejected before checkout so
/// the composite operation cannot leave the repository half-switched.
/// Stash, switch, restore. A failed switch leaves the stash untouched so the caller can
/// recover it, and a conflicting restore is reported as a failure rather than silently
/// leaving the entry behind.
fn checkout_with_auto_stash(
    root: &str,
    request: GitWriteRequest,
) -> Result<GitCommandResponse, CoreError> {
    let stash = execute_git(
        root,
        &[
            "stash".into(),
            "push".into(),
            "--include-untracked".into(),
            "--message".into(),
            AUTO_STASH_MESSAGE.into(),
        ],
        None,
    )?;
    if stash.exit_code != 0 {
        return Ok(stash);
    }

    let switched = switch_reference(root, &request)?;
    if switched.exit_code != 0 {
        // Leave the stash in place; the working tree is still on the original branch.
        return Ok(switched);
    }

    let Some(stash_reference) = find_stash_reference(root, AUTO_STASH_MESSAGE)? else {
        return Err(CoreError::new(
            ErrorCode::ProcessFailed,
            "Smart Checkout created a stash but could not locate it for restore.",
        ));
    };
    let mut restored = execute_git(
        root,
        &["stash".into(), "pop".into(), stash_reference.clone()],
        None,
    )?;
    let conflicted_paths = conflicted_paths(root)?;
    let entry_was_kept = stash_reference_exists(root, &stash_reference)?;
    if entry_was_kept && (restored.exit_code == 0 || !conflicted_paths.is_empty()) {
        restored.exit_code = 1;
        restored.stash_restore = Some(GitStashRestoreResponse {
            stash_reference,
            conflicted_paths,
        });
    }
    Ok(restored)
}

pub(super) fn switch_reference(
    root: &str,
    request: &GitWriteRequest,
) -> Result<GitCommandResponse, CoreError> {
    let reference = checkout_request_reference(root, request)?;
    switch_validated_reference(root, &reference, request.force)
}

fn switch_validated_reference(
    root: &str,
    reference: &ValidatedGitReference,
    force: bool,
) -> Result<GitCommandResponse, CoreError> {
    let mut base: Vec<String> = vec!["switch".into()];
    if force {
        base.push("--discard-changes".into());
    }
    match reference.kind.as_str() {
        "local" => {
            if current_branch(root)? == reference.short_name {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "The current branch is already checked out",
                ));
            }
            // `git switch` rejects fully qualified refs ("refs/heads/foo"), so pass the
            // short branch name. Tags still need the full ref for the --detach form.
            base.push(reference.short_name.clone());
            execute_git(root, &base, None)
        }
        "tag" => {
            base.push("--detach".into());
            base.push(reference.full_name.clone());
            execute_git(root, &base, None)
        }
        "remote" => {
            let (_, local_name) = mutations::remote_branch_components(root, &reference.full_name)?;
            let local_ref = format!("refs/heads/{local_name}");
            let existing = execute_git(
                root,
                &[
                    "show-ref".into(),
                    "--verify".into(),
                    "--quiet".into(),
                    local_ref.clone(),
                ],
                None,
            )?;
            if existing.exit_code == 0 {
                let upstream = execute_git_readonly(
                    root,
                    &[
                        "for-each-ref".into(),
                        "--format=%(upstream)".into(),
                        "--count=1".into(),
                        local_ref,
                    ],
                    None,
                )?;
                if upstream.exit_code != 0 {
                    return Err(CoreError::new(
                        ErrorCode::ProcessFailed,
                        "Could not inspect the local branch upstream",
                    )
                    .with_details(upstream.output));
                }
                if upstream.stdout.trim() != reference.full_name {
                    return Err(CoreError::new(
                        ErrorCode::InvalidRequest,
                        "A same-named local branch tracks a different Git reference",
                    ));
                }
                if current_branch(root)? == local_name {
                    return Err(CoreError::new(
                        ErrorCode::InvalidRequest,
                        "The current branch is already checked out",
                    ));
                }
                base.push(local_name);
            } else {
                base.push("--track".into());
                base.push("-c".into());
                base.push(local_name);
                base.push(reference.full_name.clone());
            }
            execute_git(root, &base, None)
        }
        _ => Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid Git reference kind",
        )),
    }
}

fn parse_reference(line: &str) -> Option<GitReferenceResponse> {
    let columns = line.split('\t').collect::<Vec<_>>();
    if columns.len() < 8 || columns[1].ends_with("/HEAD") {
        return None;
    }
    let kind = if columns[0].starts_with("refs/heads/") {
        "local"
    } else if columns[0].starts_with("refs/remotes/") {
        "remote"
    } else {
        "tag"
    };
    let short_name = match kind {
        "local" => columns[0].strip_prefix("refs/heads/"),
        "remote" => columns[0].strip_prefix("refs/remotes/"),
        "tag" => columns[0].strip_prefix("refs/tags/"),
        _ => None,
    }?;
    let upstream_short_name = (!columns[3].is_empty()).then(|| columns[3].to_string());
    let (ahead, behind) = if kind == "local" && upstream_short_name.is_some() {
        parse_tracking_counts(columns.get(5).copied().unwrap_or_default())
    } else {
        (0, 0)
    };
    Some(GitReferenceResponse {
        full_name: columns[0].to_string(),
        // `%(refname:short)` deliberately adds `heads/` or `tags/` when
        // namespaces collide. The typed contract keeps identity in
        // `fullName` and always exposes the namespace-relative short name.
        short_name: short_name.to_string(),
        kind: kind.to_string(),
        peels_to_commit: kind != "tag" || columns[6] == "commit" || columns[7] == "commit",
        is_current: columns[2].trim() == "*",
        upstream_short_name,
        ahead,
        behind,
    })
}

fn parse_tracking_counts(value: &str) -> (usize, usize) {
    let mut ahead = 0;
    let mut behind = 0;
    for component in value.split(',').map(str::trim) {
        if let Some(value) = component.strip_prefix("ahead ") {
            ahead = value.parse().unwrap_or(0);
        } else if let Some(value) = component.strip_prefix("behind ") {
            behind = value.parse().unwrap_or(0);
        }
    }
    (ahead, behind)
}

fn parse_commit(line: &str) -> Option<GitCommitResponse> {
    let columns = line.split('\u{1f}').collect::<Vec<_>>();
    if columns.len() < 8 {
        return None;
    }
    Some(GitCommitResponse {
        hash: columns[0].to_string(),
        short_hash: columns[1].to_string(),
        parent_hashes: columns[2].split_whitespace().map(String::from).collect(),
        author_name: columns[3].to_string(),
        author_email: columns[4].to_string(),
        date: columns[5].to_string(),
        subject: columns[6].to_string(),
        decorations: columns[7].to_string(),
    })
}

fn validate_revision(value: &str) -> Result<(), CoreError> {
    if value.trim().is_empty() || value.starts_with('-') || value.contains('\0') {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid Git revision",
        ));
    }
    Ok(())
}

fn parse_name_status(output: &str) -> Vec<GitFileResponse> {
    output
        .lines()
        .filter_map(|line| {
            let columns = line.split('\t').collect::<Vec<_>>();
            if columns.len() < 2 || columns.last().is_some_and(|path| path.is_empty()) {
                return None;
            }
            Some(GitFileResponse {
                status: columns[0].to_string(),
                path: columns.last().unwrap_or(&"").to_string(),
            })
        })
        .collect()
}

fn parse_stash(line: &str) -> Option<GitStashResponse> {
    let columns = line.split('\u{1f}').collect::<Vec<_>>();
    if columns.len() < 3 {
        return None;
    }
    let reference = columns[0].trim();
    if reference.is_empty() {
        return None;
    }
    let subject = columns[1].trim();
    let lower = subject.to_ascii_lowercase();
    let marker = lower.find("on ").or_else(|| lower.find(" on "));
    let branch = marker.and_then(|index| {
        let raw = &subject[index + 3..];
        raw.split_once(':')
            .or_else(|| raw.split_once(','))
            .map(|(branch, _)| branch.trim().to_string())
            .filter(|branch| !branch.is_empty())
    });
    let message = marker
        .and_then(|index| {
            subject[index + 3..]
                .split_once(':')
                .map(|(_, message)| message)
        })
        .or_else(|| subject.split_once(':').map(|(_, message)| message))
        .unwrap_or(subject)
        .trim()
        .to_string();
    Some(GitStashResponse {
        reference: reference.to_string(),
        message,
        branch,
        date: columns[2].trim().to_string(),
    })
}

pub(super) fn is_safe_pathspec(path: &str) -> bool {
    let normalized = path.replace('\\', "/");
    !normalized.is_empty()
        && !normalized.starts_with('/')
        && !normalized.split('/').any(|component| component == "..")
        && !normalized.contains(':')
}

fn null_device() -> &'static str {
    #[cfg(windows)]
    {
        "NUL"
    }
    #[cfg(not(windows))]
    {
        "/dev/null"
    }
}

/// One removed or added line retained with its original side's line number.
struct DiffEntry {
    number: usize,
    text: String,
}

/// Parsed patch hunk before it is aligned into side-by-side rows.
struct DiffHunkRecord {
    id: String,
    header: String,
    lines: Vec<String>,
}

/// Marker on stashes created by smart checkout, so the restore step can tell whether
/// `git stash pop` consumed its entry or kept it after a conflict.
const AUTO_STASH_MESSAGE: &str = "lithe: auto-stash before checkout";

/// Largest `removed.len() * added.len()` product we will align. Beyond this the
/// quadratic table costs more than the pairing is worth, so we fall back to
/// positional pairing.
const MAX_ALIGNMENT_CELLS: usize = 4096;

/// Minimum Dice coefficient for two lines to be considered a modification of
/// each other rather than an unrelated delete plus insert.
const MIN_PAIR_SIMILARITY: f32 = 0.5;

/// Character-bigram Dice coefficient over the trimmed lines, in [0, 1].
///
/// Bigrams tolerate the reindentation and small edits that dominate real diffs,
/// where a prefix/suffix comparison would score a mid-line change at zero.
fn line_similarity(left: &str, right: &str) -> f32 {
    let left = left.trim();
    let right = right.trim();
    if left == right {
        return 1.0;
    }
    if left.is_empty() || right.is_empty() {
        return 0.0;
    }

    let bigrams = |text: &str| -> Vec<[char; 2]> {
        let chars: Vec<char> = text.chars().collect();
        if chars.len() < 2 {
            // Treat a single character as one bigram against itself so short
            // lines can still match rather than always scoring zero.
            return vec![[chars[0], chars[0]]];
        }
        chars.windows(2).map(|pair| [pair[0], pair[1]]).collect()
    };

    let left_bigrams = bigrams(left);
    let mut right_bigrams = bigrams(right);
    let total = left_bigrams.len() + right_bigrams.len();

    // Multiset intersection: each right bigram is consumed by at most one match.
    let mut shared = 0usize;
    for bigram in &left_bigrams {
        if let Some(position) = right_bigrams.iter().position(|other| other == bigram) {
            right_bigrams.swap_remove(position);
            shared += 1;
        }
    }

    (2 * shared) as f32 / total as f32
}

/// Pairs removals with additions, then emits one row per pair.
///
/// Positional pairing forced `removed[i]` onto `added[i]` regardless of content,
/// so deleting 3 lines and adding 5 unrelated ones produced three bogus
/// "changed" rows. This aligns the two blocks by similarity instead, keeping the
/// matching non-crossing so line numbers stay monotonic in the rendered list.
fn pair_diff_entries(
    removed: &[DiffEntry],
    added: &[DiffEntry],
) -> Vec<(Option<usize>, Option<usize>)> {
    let rows = removed.len();
    let columns = added.len();

    // A lone removal against a lone addition has no competing alignment, so it
    // reads as a modification however dissimilar the two lines are. Applying the
    // similarity floor here would split every single-line edit into a delete
    // plus an insert.
    if rows == 1 && columns == 1 {
        return vec![(Some(0), Some(0))];
    }

    if rows == 0 || columns == 0 || rows * columns > MAX_ALIGNMENT_CELLS {
        return (0..rows.max(columns))
            .map(|index| {
                (
                    if index < rows { Some(index) } else { None },
                    if index < columns { Some(index) } else { None },
                )
            })
            .collect();
    }

    // score[i][j] = best total similarity aligning removed[i..] with added[j..].
    let mut score = vec![vec![0f32; columns + 1]; rows + 1];
    for i in (0..rows).rev() {
        for j in (0..columns).rev() {
            let skip_removal = score[i + 1][j];
            let skip_addition = score[i][j + 1];
            let best_skip = skip_removal.max(skip_addition);

            let similarity = line_similarity(&removed[i].text, &added[j].text);
            let paired = if similarity >= MIN_PAIR_SIMILARITY {
                similarity + score[i + 1][j + 1]
            } else {
                f32::NEG_INFINITY
            };

            score[i][j] = paired.max(best_skip);
        }
    }

    let mut pairs = Vec::with_capacity(rows.max(columns));
    let (mut i, mut j) = (0usize, 0usize);
    while i < rows && j < columns {
        let similarity = line_similarity(&removed[i].text, &added[j].text);
        let paired = if similarity >= MIN_PAIR_SIMILARITY {
            similarity + score[i + 1][j + 1]
        } else {
            f32::NEG_INFINITY
        };

        if paired >= score[i + 1][j] && paired >= score[i][j + 1] {
            pairs.push((Some(i), Some(j)));
            i += 1;
            j += 1;
        } else if score[i + 1][j] >= score[i][j + 1] {
            pairs.push((Some(i), None));
            i += 1;
        } else {
            pairs.push((None, Some(j)));
            j += 1;
        }
    }
    while i < rows {
        pairs.push((Some(i), None));
        i += 1;
    }
    while j < columns {
        pairs.push((None, Some(j)));
        j += 1;
    }

    pairs
}

fn flush_diff_changes(
    rows: &mut Vec<GitDiffRowResponse>,
    removed: &mut Vec<DiffEntry>,
    added: &mut Vec<DiffEntry>,
    hunk_id: Option<&str>,
) {
    for (left_index, right_index) in pair_diff_entries(removed, added) {
        let left = left_index.map(|index| &removed[index]);
        let right = right_index.map(|index| &added[index]);
        let kind = match (left.is_some(), right.is_some()) {
            (true, true) => "changed",
            (true, false) => "removal",
            (false, true) => "addition",
            (false, false) => continue,
        };
        rows.push(GitDiffRowResponse {
            old_line: left.map(|entry| entry.number),
            new_line: right.map(|entry| entry.number),
            left: left.map(|entry| entry.text.clone()),
            right: right.map(|entry| entry.text.clone()),
            kind: kind.to_string(),
            hunk_id: hunk_id.map(String::from),
        });
    }
    removed.clear();
    added.clear();
}

fn parse_hunk_header(header: &str) -> Option<(usize, usize)> {
    let mut columns = header.split_whitespace();
    if columns.next()? != "@@" {
        return None;
    }
    let old_range = columns.next()?.strip_prefix('-')?;
    let new_range = columns.next()?.strip_prefix('+')?;
    let old_line = old_range.split(',').next()?.parse().ok()?;
    let new_line = new_range.split(',').next()?.parse().ok()?;
    Some((old_line, new_line))
}

fn parse_diff(patch: &str) -> (Vec<GitDiffRowResponse>, Vec<GitDiffHunkResponse>) {
    let has_trailing_newline = patch.ends_with('\n');
    let lines = patch.split('\n').enumerate().filter_map(|(index, line)| {
        if has_trailing_newline && index == patch.split('\n').count() - 1 {
            None
        } else {
            Some(line)
        }
    });

    let mut rows = Vec::new();
    let mut old_line = 0;
    let mut new_line = 0;
    let mut removed = Vec::new();
    let mut added = Vec::new();
    let mut current_hunk_id: Option<String> = None;
    let mut current_hunk_header = String::new();
    let mut current_hunk_lines: Vec<String> = Vec::new();
    let mut file_header_lines: Vec<String> = Vec::new();
    let mut hunk_records = Vec::new();
    let mut hunk_index = 0;

    for line in lines {
        if line.starts_with("@@") {
            if let Some(hunk_id) = current_hunk_id.take() {
                flush_diff_changes(&mut rows, &mut removed, &mut added, Some(&hunk_id));
                hunk_records.push(DiffHunkRecord {
                    id: hunk_id,
                    header: std::mem::take(&mut current_hunk_header),
                    lines: std::mem::take(&mut current_hunk_lines),
                });
            }

            let hunk_id = format!("hunk-{hunk_index}");
            hunk_index += 1;
            current_hunk_id = Some(hunk_id.clone());
            current_hunk_header = line.to_string();
            current_hunk_lines = file_header_lines.clone();
            current_hunk_lines.push(line.to_string());
            if let Some((old, new)) = parse_hunk_header(line) {
                old_line = old;
                new_line = new;
            }
            rows.push(GitDiffRowResponse {
                old_line: None,
                new_line: None,
                left: Some(line.to_string()),
                right: None,
                kind: "information".to_string(),
                hunk_id: Some(hunk_id),
            });
        } else if line.starts_with("diff --git") && current_hunk_id.is_some() {
            let hunk_id = current_hunk_id.take().expect("hunk should exist");
            flush_diff_changes(&mut rows, &mut removed, &mut added, Some(&hunk_id));
            hunk_records.push(DiffHunkRecord {
                id: hunk_id,
                header: std::mem::take(&mut current_hunk_header),
                lines: std::mem::take(&mut current_hunk_lines),
            });
            file_header_lines = vec![line.to_string()];
        } else if current_hunk_id.is_none() {
            file_header_lines.push(line.to_string());
        } else if line.starts_with('-') {
            current_hunk_lines.push(line.to_string());
            removed.push(DiffEntry {
                number: old_line,
                text: line.chars().skip(1).collect(),
            });
            old_line += 1;
        } else if line.starts_with('+') {
            current_hunk_lines.push(line.to_string());
            added.push(DiffEntry {
                number: new_line,
                text: line.chars().skip(1).collect(),
            });
            new_line += 1;
        } else if line.starts_with(' ') {
            let hunk_id = current_hunk_id.as_deref();
            flush_diff_changes(&mut rows, &mut removed, &mut added, hunk_id);
            current_hunk_lines.push(line.to_string());
            rows.push(GitDiffRowResponse {
                old_line: Some(old_line),
                new_line: Some(new_line),
                left: Some(line.chars().skip(1).collect::<String>()),
                right: None,
                kind: "context".to_string(),
                hunk_id: current_hunk_id.clone(),
            });
            old_line += 1;
            new_line += 1;
        } else if line.starts_with("\\ No newline") {
            current_hunk_lines.push(line.to_string());
        } else {
            current_hunk_lines.push(line.to_string());
        }
    }

    if let Some(hunk_id) = current_hunk_id.take() {
        flush_diff_changes(&mut rows, &mut removed, &mut added, Some(&hunk_id));
        hunk_records.push(DiffHunkRecord {
            id: hunk_id,
            header: current_hunk_header,
            lines: current_hunk_lines,
        });
    }

    let hunks = hunk_records
        .into_iter()
        .map(|record| {
            let patch = record.lines.join("\n") + if has_trailing_newline { "\n" } else { "" };
            GitDiffHunkResponse {
                id: record.id,
                header: record.header,
                patch,
            }
        })
        .collect();
    (rows, hunks)
}

/// Resolves the Git administrative paths and references a watcher must observe.
pub fn watch_context(
    request: GitWatchContextRequest,
) -> Result<Option<GitWatchContextResponse>, CoreError> {
    let root = PathBuf::from(&request.root)
        .canonicalize()
        .map_err(|_| CoreError::new(ErrorCode::WorkspaceNotFound, "Workspace does not exist"))?;
    if !root.is_dir() {
        return Err(CoreError::new(
            ErrorCode::WorkspaceNotFound,
            "Workspace does not exist",
        ));
    }

    let repository_root = run_git(&root, &["rev-parse", "--show-toplevel"])?;
    if !repository_root.status.success() {
        return Ok(None);
    }
    let git_directory = run_git(&root, &["rev-parse", "--absolute-git-dir"])?;
    let git_common_directory = run_git(
        &root,
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
    )?;

    Ok(Some(GitWatchContextResponse {
        repository_root: canonical_git_output(repository_root, "repository root")?,
        git_directory: canonical_git_output(git_directory, "Git directory")?,
        git_common_directory: canonical_git_output(git_common_directory, "Git common directory")?,
    }))
}

fn canonical_git_output(output: std::process::Output, label: &str) -> Result<String, CoreError> {
    if !output.status.success() {
        return Err(CoreError::new(
            ErrorCode::ProcessFailed,
            format!("Could not resolve {label}"),
        )
        .with_details(String::from_utf8_lossy(&output.stderr)));
    }
    let raw_path = String::from_utf8_lossy(&output.stdout);
    let path = PathBuf::from(raw_path.trim());
    path.canonicalize()
        .map(|path| path.to_string_lossy().into_owned())
        .map_err(|error| {
            CoreError::new(
                ErrorCode::ProcessFailed,
                format!("Could not resolve {label}"),
            )
            .with_details(error.to_string())
        })
}

/// Returns the checked-out branch and whether its HEAD must be pushed before a PR.
pub fn pull_request_context(
    request: GitPullRequestContextRequest,
) -> Result<GitPullRequestContextResponse, CoreError> {
    let root = validate_root(&request.root)?;
    let current_branch = optional_current_branch(&root)?;
    let detached = current_branch.is_none();
    let remote_default = command_value(
        &root,
        &[
            "symbolic-ref",
            "--quiet",
            "--short",
            "refs/remotes/origin/HEAD",
        ],
    )
    .map(|value| value.trim_start_matches("origin/").to_string());

    let suggested_base_branch = if let Some(branch) = current_branch.as_deref() {
        created_from_branch(&root, branch).or(remote_default)
    } else {
        detached_start_branch(&root).or(remote_default)
    };
    let requires_publish = current_branch
        .as_deref()
        .map_or(true, |branch| branch_requires_publish(&root, branch));
    let suggested_publish_branch = if requires_publish {
        current_branch.clone().or_else(|| {
            command_value(&root, &["rev-parse", "--short=8", "HEAD"])
                .map(|short_hash| format!("codex/pr-{short_hash}"))
        })
    } else {
        None
    };
    let has_uncommitted_changes = command_value(
        &root,
        &["status", "--porcelain", "--untracked-files=normal"],
    )
    .is_some();

    Ok(GitPullRequestContextResponse {
        current_branch,
        suggested_base_branch,
        suggested_publish_branch,
        requires_publish,
        detached,
        has_uncommitted_changes,
    })
}

fn command_value(root: &str, arguments: &[&str]) -> Option<String> {
    let arguments = arguments
        .iter()
        .map(|value| value.to_string())
        .collect::<Vec<_>>();
    let response = execute_git_readonly(root, &arguments, None).ok()?;
    let value = response.output.trim();
    (response.exit_code == 0 && !value.is_empty()).then(|| value.to_string())
}

fn created_from_branch(root: &str, branch: &str) -> Option<String> {
    let reference = format!("refs/heads/{branch}");
    let response = command_value(root, &["reflog", "show", "--format=%gs", &reference])?;
    let prefix = "branch: Created from ";
    response.lines().find_map(|line| {
        let source = line.strip_prefix(prefix)?;
        if matches!(source, "HEAD" | "FETCH_HEAD" | "ORIG_HEAD") {
            // Publishing a detached worktree creates its branch from HEAD.
            // Preserve the worktree's original branch as the PR base instead
            // of falling back to origin/HEAD after the branch is published.
            detached_start_branch(root)
        } else {
            Some(source.trim_start_matches("origin/").to_string())
        }
    })
}

fn detached_start_branch(root: &str) -> Option<String> {
    let reflog = command_value(root, &["reflog", "show", "--format=%H", "HEAD"])?;
    // Reflog output is newest-first; the final entry is the commit at which
    // this worktree's HEAD was initialized.
    let starting_commit = reflog.lines().last()?.trim();
    let references = command_value(
        root,
        &[
            "for-each-ref",
            "--sort=refname",
            "--format=%(refname)",
            "--points-at",
            starting_commit,
            "refs/heads",
            "refs/remotes/origin",
        ],
    )?;
    references
        .lines()
        .find_map(|reference| reference.strip_prefix("refs/heads/").map(str::to_string))
        .or_else(|| {
            references.lines().find_map(|reference| {
                reference
                    .strip_prefix("refs/remotes/origin/")
                    .filter(|branch| *branch != "HEAD")
                    .map(str::to_string)
            })
        })
}

fn branch_requires_publish(root: &str, branch: &str) -> bool {
    let origin_branch = format!("refs/remotes/origin/{branch}");
    if command_value(root, &["rev-parse", "--verify", &origin_branch]).is_none() {
        return true;
    }
    let comparison = format!("{origin_branch}..HEAD");
    match command_value(root, &["rev-list", "--count", &comparison])
        .and_then(|count| count.parse::<usize>().ok())
    {
        Some(0) => false,
        Some(_) | None => true,
    }
}

/// Returns the normalized repository status and branch context.
pub fn status(request: GitStatusRequest) -> Result<GitStatusResponse, CoreError> {
    let root = PathBuf::from(&request.root)
        .canonicalize()
        .map_err(|_| CoreError::new(ErrorCode::WorkspaceNotFound, "Workspace does not exist"))?;
    if !root.is_dir() {
        return Err(CoreError::new(
            ErrorCode::WorkspaceNotFound,
            "Workspace does not exist",
        ));
    }
    let repository_root_output = run_git(&root, &["rev-parse", "--show-toplevel"])?;
    if !repository_root_output.status.success() {
        return Ok(GitStatusResponse {
            repository_root: None,
            branch: None,
            ahead: 0,
            behind: 0,
            changes: Vec::new(),
        });
    }
    let repository_root_text = String::from_utf8_lossy(&repository_root_output.stdout);
    let repository_root_path = PathBuf::from(repository_root_text.trim());
    let repository_root = repository_root_path
        .canonicalize()
        .unwrap_or(repository_root_path);
    let branch = run_git(&repository_root, &["branch", "--show-current"])
        .ok()
        .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_string())
        .filter(|branch| !branch.is_empty())
        .or_else(|| Some("detached".to_string()));
    let status_output = run_git(
        &repository_root,
        &[
            "-c",
            "core.quotepath=false",
            "status",
            "--porcelain=v1",
            "-z",
            "--untracked-files=all",
        ],
    )?;
    if !status_output.status.success() {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Git status failed")
                .with_details(String::from_utf8_lossy(&status_output.stderr)),
        );
    }
    let changes = parse_status(&status_output.stdout);
    let (ahead, behind) = tracking_counts(&repository_root);
    Ok(GitStatusResponse {
        repository_root: Some(relative_or_absolute(&repository_root, &root)),
        branch,
        ahead,
        behind,
        changes,
    })
}

fn tracking_counts(repository_root: &Path) -> (usize, usize) {
    let Ok(output) = run_git(
        repository_root,
        &["rev-list", "--left-right", "--count", "@{upstream}...HEAD"],
    ) else {
        return (0, 0);
    };
    if !output.status.success() {
        return (0, 0);
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let mut values = text
        .split_whitespace()
        .filter_map(|value| value.parse().ok());
    let behind = values.next().unwrap_or(0);
    let ahead = values.next().unwrap_or(0);
    (ahead, behind)
}

fn run_git(directory: &Path, arguments: &[&str]) -> Result<std::process::Output, CoreError> {
    // Status and path discovery are read-only from Lithe's point of view. Git
    // may otherwise refresh its optional index data while answering a query,
    // which emits `.git/index` events into the native watcher and can trigger
    // another status refresh.
    git_process()
        .env("GIT_OPTIONAL_LOCKS", "0")
        .args(arguments)
        .current_dir(directory)
        .output()
        .map_err(|error| {
            CoreError::new(ErrorCode::ProcessStartFailed, "Could not start Git")
                .with_details(error.to_string())
        })
}

fn parse_status(output: &[u8]) -> Vec<GitChange> {
    let mut changes = Vec::new();
    let records = output
        .split(|byte| *byte == 0)
        .filter(|record| !record.is_empty())
        .collect::<Vec<_>>();
    let mut index = 0;
    while index < records.len() {
        let record = String::from_utf8_lossy(records[index]).to_string();
        let bytes = record.as_bytes();
        if bytes.len() < 3 {
            index += 1;
            continue;
        }
        let x = bytes[0] as char;
        let y = bytes[1] as char;
        // The commit checkbox represents the final worktree snapshot. A path
        // added only to the index and then deleted is identical to HEAD.
        if x == 'A' && y == 'D' {
            index += 1;
            continue;
        }
        let path = record[3..].to_string();
        let mut original_path = None;
        if (matches!(x, 'R' | 'C') || matches!(y, 'R' | 'C')) && index + 1 < records.len() {
            original_path = Some(String::from_utf8_lossy(records[index + 1]).to_string());
            index += 1;
        }
        changes.push(GitChange {
            path,
            original_path,
            status: format!("{}{}", x, y),
            staged: x != ' ' && x != '?',
            worktree: y != ' ' && y != '?',
            untracked: x == '?' && y == '?',
        });
        index += 1;
    }
    changes.sort_by(|left, right| left.path.cmp(&right.path));
    changes
}

fn relative_or_absolute(path: &Path, root: &Path) -> String {
    path.strip_prefix(root)
        .map(|relative| {
            let value = relative.to_string_lossy().replace('\\', "/");
            if value.is_empty() {
                ".".to_string()
            } else {
                value
            }
        })
        .unwrap_or_else(|_| path.to_string_lossy().replace('\\', "/"))
}

#[cfg(test)]
mod tests {
    use super::{
        annotation_message_from_tag_object, line_similarity, pair_diff_entries, parse_diff,
        structured_diff_from_output, DiffEntry, GitCommandInvocation, GitCommandResponse,
        GitProcessOutput, MAX_ALIGNMENT_CELLS,
    };
    use crate::protocol::{
        CoreError, ErrorCode, GitCommitResponse, GitHistoryPageResponse, GitHistoryResponse,
        GitPushPreviewResponse, GitPushTagResponse, GitReferenceResponse, GitReferencesResponse,
    };
    use serde_json::Value;

    #[test]
    fn tag_annotation_parser_preserves_crlf_and_trailing_blank_lines() {
        let raw = concat!(
            "object abc123\n",
            "type commit\n",
            "tag v1.0\n",
            "tagger Lithe Test <test@example.com> 0 +0000\n",
            "\n",
            "release\r\n",
            "\r\n",
            "details\r\n",
            "\r\n"
        );

        assert_eq!(
            annotation_message_from_tag_object(raw).as_deref(),
            Some("release\r\n\r\ndetails\r\n\r\n")
        );
    }

    #[test]
    fn tag_annotation_parser_removes_only_the_signature_block() {
        let raw = concat!(
            "object abc123\n",
            "type commit\n",
            "tag v1.0\n",
            "tagger Lithe Test <test@example.com> 0 +0000\n",
            "\n",
            "release\r\n",
            "\r\n",
            "-----BEGIN PGP SIGNATURE-----\r\n",
            "signature-data\r\n",
            "-----END PGP SIGNATURE-----\r\n"
        );

        assert_eq!(
            annotation_message_from_tag_object(raw).as_deref(),
            Some("release\r\n\r\n")
        );
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn background_git_processes_do_not_create_windows_console() {
        assert_eq!(super::git_process_creation_flags(), 0x08000000);
    }

    #[test]
    fn structured_diff_does_not_parse_git_stderr_as_file_content() {
        let output = GitProcessOutput {
            stdout: b"diff --git a/c.txt b/c.txt\n--- /dev/null\n+++ b/c.txt\n@@ -0,0 +1,3 @@\n+c\n+cc\n+ccc\n".to_vec(),
            stderr: b"warning: CRLF will be replaced by LF\n".to_vec(),
            exit_code: 1,
        };

        let diff = structured_diff_from_output(output);

        assert!(!diff.patch.contains("warning:"));
        assert!(diff
            .rows
            .iter()
            .any(|row| row.right.as_deref() == Some("ccc")));
        assert!(!diff.rows.iter().any(|row| row
            .right
            .as_deref()
            .is_some_and(|line| line.contains("warning:"))));
    }

    #[test]
    fn traced_response_uses_the_final_invocation_for_compatibility_fields() {
        let mut response = GitCommandResponse {
            arguments: vec!["status".into()],
            output: "stale".into(),
            stdout: "stale".into(),
            stderr: String::new(),
            exit_code: 0,
            invocations: vec![
                GitCommandInvocation {
                    arguments: vec!["status".into()],
                    stdout: "status\n".into(),
                    stderr: String::new(),
                    exit_code: 0,
                },
                GitCommandInvocation {
                    arguments: vec!["stash".into(), "list".into()],
                    stdout: "stash@{0}\n".into(),
                    stderr: String::new(),
                    exit_code: 0,
                },
            ],
            operation_error: None,
            stash_restore: None,
            tag_deletion: None,
            branch_deletion: None,
            warnings: Vec::new(),
        };

        super::synchronize_final_invocation(&mut response);

        assert_eq!(response.arguments, vec!["stash", "list"]);
        assert_eq!(response.stdout, "stash@{0}\n");
        assert_eq!(response.stderr, "");
        assert_eq!(response.output, "stash@{0}\n");
        assert_eq!(response.exit_code, 0);
    }

    #[test]
    fn traced_core_error_becomes_a_failed_response_with_invocations() {
        let result = super::with_git_invocation_trace(|| {
            let response = GitProcessOutput {
                stdout: b"prepared\n".to_vec(),
                stderr: Vec::new(),
                exit_code: 0,
            }
            .into_command_response(&["stash".into(), "push".into()]);
            super::record_git_invocation(&response);
            Err(CoreError::new(
                ErrorCode::ProcessFailed,
                "Follow-up probe failed",
            ))
        });

        let response = result.expect("a partial Git failure should retain command data");
        assert_eq!(response.exit_code, 0);
        assert_eq!(response.arguments, vec!["stash", "push"]);
        assert_eq!(response.output, "prepared\n");
        assert_eq!(response.invocations.len(), 1);
        assert_eq!(
            response
                .operation_error
                .as_ref()
                .map(|error| &error.message),
            Some(&"Follow-up probe failed".to_string())
        );
    }

    #[test]
    fn git_process_response_preserves_executed_arguments() {
        let arguments = vec!["status".to_string(), "--short".to_string()];
        let response = GitProcessOutput {
            stdout: b" M README.md\n".to_vec(),
            stderr: Vec::new(),
            exit_code: 0,
        }
        .into_command_response(&arguments);

        assert_eq!(response.arguments, arguments);
        assert_eq!(response.output, " M README.md\n");
        assert_eq!(response.stdout, " M README.md\n");
        assert_eq!(response.stderr, "");
        assert_eq!(response.exit_code, 0);
    }

    fn entries(texts: &[&str]) -> Vec<DiffEntry> {
        texts
            .iter()
            .enumerate()
            .map(|(index, text)| DiffEntry {
                number: index + 1,
                text: (*text).to_string(),
            })
            .collect()
    }

    #[test]
    fn similar_lines_pair_even_when_positions_differ() {
        let removed = entries(&["let total = compute(a, b);"]);
        let added = entries(&["// recompute the total", "let total = compute(a, b, c);"]);

        // Positional pairing would have matched the comment to the statement.
        assert_eq!(
            pair_diff_entries(&removed, &added),
            vec![(None, Some(0)), (Some(0), Some(1))]
        );
    }

    #[test]
    fn unrelated_lines_stay_separate_deletions_and_insertions() {
        let removed = entries(&["import Foundation", "import AppKit"]);
        let added = entries(&["let x = 1", "let y = 2", "let z = 3"]);

        // Nothing clears the similarity floor, so no row is labelled "changed".
        let pairs = pair_diff_entries(&removed, &added);
        assert!(pairs
            .iter()
            .all(|(left, right)| left.is_none() || right.is_none()));
        assert_eq!(pairs.len(), 5);
    }

    #[test]
    fn pairing_keeps_line_numbers_monotonic() {
        let removed = entries(&["alpha one", "beta two", "gamma three"]);
        let added = entries(&["gamma three!", "alpha one!", "beta two!"]);

        // A crossing match would scramble line numbers in the rendered list.
        let pairs = pair_diff_entries(&removed, &added);
        let matched: Vec<(usize, usize)> = pairs
            .iter()
            .filter_map(|(left, right)| left.zip(*right))
            .collect();
        assert!(matched
            .windows(2)
            .all(|pair| pair[0].0 < pair[1].0 && pair[0].1 < pair[1].1));
    }

    #[test]
    fn oversized_blocks_fall_back_to_positional_pairing() {
        let text: Vec<String> = (0..(MAX_ALIGNMENT_CELLS + 1))
            .map(|index| format!("line {index}"))
            .collect();
        let refs: Vec<&str> = text.iter().map(String::as_str).collect();
        let removed = entries(&refs);
        let added = entries(&refs[..2]);

        let pairs = pair_diff_entries(&removed, &added);
        assert_eq!(pairs.len(), removed.len());
        assert_eq!(pairs[0], (Some(0), Some(0)));
        assert_eq!(pairs[1], (Some(1), Some(1)));
        assert_eq!(pairs[2], (Some(2), None));
    }

    #[test]
    fn similarity_scores_reindentation_as_a_near_match() {
        let score = line_similarity("    return value", "\t\treturn value");
        assert_eq!(score, 1.0);
        assert_eq!(line_similarity("abc", ""), 0.0);
    }

    #[test]
    fn command_response_matches_shared_fixture() {
        let fixture: Value = serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/fixtures/git/command-response-v1.json"
        )))
        .expect("Git command response fixture should be valid JSON");
        let response = GitCommandResponse {
            arguments: vec![
                "checkout".into(),
                "HEAD".into(),
                "--".into(),
                "README.md".into(),
            ],
            output: String::new(),
            stdout: String::new(),
            stderr: String::new(),
            exit_code: 0,
            invocations: vec![
                GitCommandInvocation {
                    arguments: vec![
                        "status".into(),
                        "--porcelain".into(),
                        "--untracked-files=all".into(),
                        "--".into(),
                        "README.md".into(),
                    ],
                    stdout: " M README.md\n".into(),
                    stderr: String::new(),
                    exit_code: 0,
                },
                GitCommandInvocation {
                    arguments: vec![
                        "checkout".into(),
                        "HEAD".into(),
                        "--".into(),
                        "README.md".into(),
                    ],
                    stdout: String::new(),
                    stderr: String::new(),
                    exit_code: 0,
                },
            ],
            operation_error: None,
            stash_restore: None,
            tag_deletion: None,
            branch_deletion: None,
            warnings: Vec::new(),
        };

        assert_eq!(
            serde_json::to_value(response).expect("Git response should serialize"),
            fixture
        );
    }

    #[test]
    fn history_response_matches_shared_fixture() {
        let fixture: Value = serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/fixtures/git/history-response-v1.json"
        )))
        .expect("Git history response fixture should be valid JSON");
        let feature = GitReferenceResponse {
            full_name: "refs/heads/feature/recent".into(),
            short_name: "feature/recent".into(),
            kind: "local".into(),
            peels_to_commit: true,
            is_current: true,
            upstream_short_name: None,
            ahead: 0,
            behind: 0,
        };
        let main = GitReferenceResponse {
            full_name: "refs/heads/main".into(),
            short_name: "main".into(),
            kind: "local".into(),
            peels_to_commit: true,
            is_current: false,
            upstream_short_name: Some("origin/main".into()),
            ahead: 2,
            behind: 1,
        };
        let response = GitHistoryResponse {
            references: vec![feature.clone(), main.clone()],
            recent_references: vec![feature, main],
            commits: vec![GitCommitResponse {
                hash: "0123456789abcdef0123456789abcdef01234567".into(),
                short_hash: "0123456".into(),
                parent_hashes: Vec::new(),
                author_name: "Lithe Test".into(),
                author_email: "test@example.invalid".into(),
                date: "2026/08/30 12:00".into(),
                subject: "Initial commit".into(),
                decorations: "HEAD -> feature/recent".into(),
            }],
            has_more: false,
            user_name: Some("Lithe Test".into()),
            user_email: Some("test@example.invalid".into()),
        };

        assert_eq!(
            serde_json::to_value(response).expect("Git history response should serialize"),
            fixture
        );
    }

    #[test]
    fn references_response_matches_shared_fixture() {
        let fixture: Value = serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/fixtures/git/references-response-v1.json"
        )))
        .expect("Git references response fixture should be valid JSON");
        let feature = GitReferenceResponse {
            full_name: "refs/heads/feature/recent".into(),
            short_name: "feature/recent".into(),
            kind: "local".into(),
            peels_to_commit: true,
            is_current: true,
            upstream_short_name: None,
            ahead: 0,
            behind: 0,
        };
        let main = GitReferenceResponse {
            full_name: "refs/heads/main".into(),
            short_name: "main".into(),
            kind: "local".into(),
            peels_to_commit: true,
            is_current: false,
            upstream_short_name: Some("origin/main".into()),
            ahead: 2,
            behind: 1,
        };
        let response = GitReferencesResponse {
            references: vec![feature.clone(), main.clone()],
            recent_references: vec![feature, main],
            user_name: Some("Lithe Test".into()),
            user_email: Some("test@example.invalid".into()),
        };

        assert_eq!(
            serde_json::to_value(response).expect("Git references response should serialize"),
            fixture
        );
    }

    #[test]
    fn history_page_response_matches_shared_fixture() {
        let fixture: Value = serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/fixtures/git/history-page-response-v1.json"
        )))
        .expect("Git history page response fixture should be valid JSON");
        let response = GitHistoryPageResponse {
            commits: vec![GitCommitResponse {
                hash: "0123456789abcdef0123456789abcdef01234567".into(),
                short_hash: "0123456".into(),
                parent_hashes: Vec::new(),
                author_name: "Lithe Test".into(),
                author_email: "test@example.invalid".into(),
                date: "2026/08/30 12:00".into(),
                subject: "Initial commit".into(),
                decorations: "HEAD -> feature/recent".into(),
            }],
            next_cursor: Some("git-history-cursor-fixture".into()),
            next_offset: None,
            has_more: true,
        };

        assert_eq!(
            serde_json::to_value(response).expect("Git history page response should serialize"),
            fixture
        );
    }

    #[test]
    fn push_preview_response_matches_shared_fixture() {
        let fixture: Value = serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/fixtures/git/push-preview-v1.json"
        )))
        .expect("Git push preview fixture should be valid JSON");
        let response = GitPushPreviewResponse {
            local_branch: "feature/core".into(),
            local_head: "2222222222222222222222222222222222222222".into(),
            remote: "origin".into(),
            remote_branch: "feature/core".into(),
            remote_tracking_oid: Some("1111111111111111111111111111111111111111".into()),
            upstream: Some("origin/feature/core".into()),
            tags: vec![GitPushTagResponse {
                full_name: "refs/tags/v1.0.0".into(),
                object_id: "3333333333333333333333333333333333333333".into(),
            }],
            commits: vec![GitCommitResponse {
                hash: "2222222222222222222222222222222222222222".into(),
                short_hash: "2222222".into(),
                parent_hashes: vec!["1111111111111111111111111111111111111111".into()],
                author_name: "Lithe Developer".into(),
                author_email: "developer@lithe.local".into(),
                date: "2026/08/31 10:30".into(),
                subject: "Add push preview".into(),
                decorations: "HEAD -> feature/core".into(),
            }],
            has_more: false,
        };

        assert_eq!(
            serde_json::to_value(response).expect("Git push preview should serialize"),
            fixture
        );
    }

    #[test]
    fn command_error_response_matches_shared_fixture() {
        let fixture: Value = serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/fixtures/git/command-error-response-v1.json"
        )))
        .expect("Git command error response fixture should be valid JSON");
        let response = GitCommandResponse {
            arguments: vec![
                "stash".into(),
                "push".into(),
                "--include-untracked".into(),
                "--message".into(),
                "Lithe Smart Checkout".into(),
            ],
            output: "No local changes to save\n".into(),
            stdout: "No local changes to save\n".into(),
            stderr: String::new(),
            exit_code: 0,
            invocations: vec![GitCommandInvocation {
                arguments: vec![
                    "stash".into(),
                    "push".into(),
                    "--include-untracked".into(),
                    "--message".into(),
                    "Lithe Smart Checkout".into(),
                ],
                stdout: "No local changes to save\n".into(),
                stderr: String::new(),
                exit_code: 0,
            }],
            operation_error: Some(CoreError::new(
                ErrorCode::InvalidRequest,
                "Invalid Git reference",
            )),
            stash_restore: None,
            tag_deletion: None,
            branch_deletion: None,
            warnings: Vec::new(),
        };

        assert_eq!(
            serde_json::to_value(response).expect("Git error response should serialize"),
            fixture
        );
    }

    #[test]
    fn structured_diff_matches_shared_fixture() {
        let fixture: Value = serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/fixtures/git/diff.json"
        )))
        .expect("diff fixture should be valid JSON");
        let patch = fixture["patch"]
            .as_str()
            .expect("fixture patch should be text");
        let (rows, hunks) = parse_diff(patch);
        let expected = &fixture["expected"];
        let kinds = rows.iter().map(|row| row.kind.as_str()).collect::<Vec<_>>();
        let old_lines = rows
            .iter()
            .map(|row| row.old_line.map(|line| line as u64))
            .collect::<Vec<_>>();
        let new_lines = rows
            .iter()
            .map(|row| row.new_line.map(|line| line as u64))
            .collect::<Vec<_>>();
        let expected_kinds = expected["rowKinds"]
            .as_array()
            .expect("fixture kinds should be an array")
            .iter()
            .map(|kind| kind.as_str().expect("fixture kind should be text"))
            .collect::<Vec<_>>();
        let expected_old_lines = expected["oldLines"]
            .as_array()
            .expect("fixture old lines should be an array")
            .iter()
            .map(Value::as_u64)
            .collect::<Vec<_>>();
        let expected_new_lines = expected["newLines"]
            .as_array()
            .expect("fixture new lines should be an array")
            .iter()
            .map(Value::as_u64)
            .collect::<Vec<_>>();
        assert_eq!(kinds, expected_kinds);
        assert_eq!(old_lines, expected_old_lines);
        assert_eq!(new_lines, expected_new_lines);
        assert_eq!(
            hunks.len(),
            expected["hunkCount"]
                .as_u64()
                .expect("fixture count should be a number") as usize
        );
    }
}
