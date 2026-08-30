//! Deterministic Git inspection and mutation behind the shared command contract.

mod mutations;

use crate::protocol::{CoreError, ErrorCode};
use crate::protocol::{
    GitBlameLineResponse, GitBlameResponse, GitChange, GitCheckoutPreflightResponse,
    GitCommitLookupResponse, GitCommitResponse, GitComparisonResponse, GitConflictMarkerResponse,
    GitDiffHunkResponse, GitDiffResponse, GitDiffRowResponse, GitFileResponse, GitFilesResponse,
    GitHistoryResponse, GitIntegrationPreflightResponse, GitOperationStateResponse,
    GitPullPreflightResponse, GitReferenceResponse, GitStashResponse, GitStashesResponse,
    GitStatusResponse, GitWatchContextResponse,
};
use serde::{Deserialize, Serialize};
use std::cell::RefCell;
use std::io::Read;
use std::io::Write;
#[cfg(target_os = "windows")]
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::Duration;

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
    /// Reference category used by checkout: `local`, `remote`, or `tag`.
    #[serde(default)]
    pub reference_kind: Option<String>,
    #[serde(default)]
    pub revision: Option<String>,
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
    #[serde(default)]
    pub auto_stash: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request for a structured diff suitable for side-by-side rendering.
pub struct GitDiffRequest {
    pub root: String,
    pub pathspecs: Vec<String>,
    #[serde(default)]
    pub reference: Option<String>,
    #[serde(default)]
    pub commit: Option<String>,
    #[serde(default)]
    pub staged: bool,
    #[serde(default)]
    pub untracked: bool,
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
/// Request for bounded commit history from an optional reference.
pub struct GitHistoryRequest {
    pub root: String,
    #[serde(default)]
    pub reference: Option<String>,
    #[serde(default = "default_history_limit")]
    pub limit: usize,
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
    pub reference: String,
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
    pub reference: String,
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
    pub reference: String,
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

fn default_history_limit() -> usize {
    300
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
            arguments = ["add", "-A", "--"]
                .into_iter()
                .map(String::from)
                .chain(paths)
                .collect();
        }
        "unstage" => {
            let paths = validate_paths(&request.paths)?;
            let restore_arguments = ["restore", "--staged", "--"]
                .into_iter()
                .map(String::from)
                .chain(paths.clone())
                .collect::<Vec<_>>();
            let restore = execute_git(&root, &restore_arguments, None)?;
            if restore.exit_code == 0 {
                return Ok(restore);
            }
            arguments = ["reset", "HEAD", "--"]
                .into_iter()
                .map(String::from)
                .chain(paths)
                .collect();
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
            arguments = vec!["commit".into()];
            if request.amend {
                arguments.push("--amend".into());
            }
            arguments.extend(["-m".into(), message]);
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
        "createBranch" => {
            let name = validated_branch_name(&root, request.name.as_deref())?;
            let reference = validated_reference(request.reference.as_deref())?;
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
            let reference = validated_reference(request.reference.as_deref())?;
            let current = current_branch(&root)?;
            let current_reference = format!("refs/heads/{current}");
            arguments = if request.reference.as_deref() == Some(current.as_str())
                || request.reference.as_deref() == Some(current_reference.as_str())
            {
                vec!["branch".into(), "-m".into(), name]
            } else {
                vec!["branch".into(), "-m".into(), reference, name]
            };
        }
        "deleteBranch" => {
            let reference = validated_reference(request.reference.as_deref())?;
            let branch = local_branch_name(&reference)?;
            if current_branch(&root)?.as_str() == branch {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "The current branch cannot be deleted",
                ));
            }
            arguments = vec!["branch".into(), "-d".into(), "--".into(), branch];
        }
        "merge" => {
            let reference = validated_reference(request.reference.as_deref())?;
            if is_current_reference(&root, &reference)? {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "The current branch cannot be merged into itself",
                ));
            }
            arguments = vec!["merge".into(), "--no-edit".into(), reference];
        }
        "rebase" => {
            let reference = validated_reference(request.reference.as_deref())?;
            if is_current_reference(&root, &reference)? {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "The current branch cannot be rebased onto itself",
                ));
            }
            arguments = vec!["rebase".into(), reference];
        }
        "checkoutAndRebase" => return mutations::checkout_and_rebase(&root, request),
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
            if let Some(reference) = request.reference.as_deref() {
                if request.reference_kind.as_deref() != Some("remote") {
                    return Err(CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Explicit pull requires a remote Git reference",
                    ));
                }
                let reference = validated_reference(Some(reference))?;
                let (remote, branch) = mutations::remote_branch_components(&root, &reference)?;
                arguments.extend(["--".into(), remote, branch]);
            }
        }
        "push" => return push(&root, request.reference.as_deref()),
        "checkout" => return checkout(&root, request),
        "checkoutRevision" => {
            arguments = vec![
                "switch".into(),
                "--detach".into(),
                validated_revision(request.revision.as_deref())?,
            ];
        }
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

fn capture_git_with_options(
    root: &str,
    arguments: &[String],
    input: Option<String>,
    disable_optional_locks: bool,
) -> Result<GitProcessOutput, CoreError> {
    crate::protocol::cancellation::check()?;
    let mut process = git_process();
    process.args(arguments).current_dir(root);
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

fn git_process() -> Command {
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

    if request.reference.is_some() && request.commit.is_some() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Git diff cannot combine a reference and a commit",
        ));
    }

    let include_untracked_with_reference = request.reference.is_some() && request.untracked;
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
    } else if let Some(reference) = request.reference {
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
    arguments.extend(request.pathspecs);

    let root = validate_root(&request.root)?;
    let mut output = capture_git_with_options(&root, &arguments, None, true)?;
    if include_untracked_with_reference {
        let status = readonly_command(GitCommandRequest {
            root: root.clone(),
            arguments: vec![
                "status".into(),
                "--porcelain".into(),
                "--untracked-files=all".into(),
            ],
            input: None,
        })?;
        if status.exit_code != 0 {
            return Err(
                CoreError::new(ErrorCode::ProcessFailed, "Git status failed")
                    .with_details(status.output),
            );
        }
        for line in status.output.lines().filter(|line| line.starts_with("?? ")) {
            let path = line[3..].trim();
            if path.is_empty() || !is_safe_pathspec(path) {
                continue;
            }
            let untracked = capture_git_with_options(
                &root,
                &[
                    "diff".into(),
                    "--no-ext-diff".into(),
                    "--binary".into(),
                    "--no-index".into(),
                    "--".into(),
                    null_device().into(),
                    path.into(),
                ],
                None,
                true,
            )?;
            output.stdout.extend(untracked.stdout);
            output.stderr.extend(untracked.stderr);
        }
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

/// Returns bounded commit history without relying on localized display output.
pub fn history(request: GitHistoryRequest) -> Result<GitHistoryResponse, CoreError> {
    let limit = request.limit.clamp(1, 5_000);
    let root = validate_root(&request.root)?;
    let user_name = git_config_value(&root, "user.name");
    let user_email = git_config_value(&root, "user.email");
    let reference_output = readonly_command(GitCommandRequest {
        root: root.clone(),
        arguments: vec![
            "for-each-ref".to_string(),
            "--sort=refname".to_string(),
            "--format=%(refname)\t%(refname:short)\t%(HEAD)\t%(upstream:short)".to_string(),
            "refs/heads".to_string(),
            "refs/remotes".to_string(),
            "refs/tags".to_string(),
        ],
        input: None,
    })?;
    if reference_output.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Git references failed")
                .with_details(reference_output.output),
        );
    }

    let references = reference_output
        .output
        .lines()
        .filter_map(parse_reference)
        .collect::<Vec<_>>();

    let mut arguments = vec!["log".to_string()];
    if let Some(reference) = request.reference {
        if reference.starts_with('-') || reference.contains('\0') {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Invalid Git reference",
            ));
        }
        arguments.push(reference);
    } else {
        arguments.push("--all".to_string());
    }
    arguments.extend([
        "--topo-order".to_string(),
        "--decorate=short".to_string(),
        "-n".to_string(),
        (limit.saturating_add(1)).to_string(),
        "--date=format:%Y/%m/%d %H:%M".to_string(),
        "--pretty=format:%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%ad%x1f%s%x1f%D".to_string(),
    ]);
    let commit_output = readonly_command(GitCommandRequest {
        root,
        arguments,
        input: None,
    })?;
    if commit_output.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Git history failed")
                .with_details(commit_output.output),
        );
    }

    let all_commits = commit_output
        .output
        .lines()
        .filter_map(parse_commit)
        .collect::<Vec<_>>();
    let has_more = all_commits.len() > limit;
    Ok(GitHistoryResponse {
        references,
        commits: all_commits.into_iter().take(limit).collect(),
        has_more,
        user_name,
        user_email,
    })
}

/// Reads one effective repository configuration value without making a missing
/// optional value fail the surrounding history request.
fn git_config_value(root: &str, key: &str) -> Option<String> {
    let response = readonly_command(GitCommandRequest {
        root: root.to_string(),
        arguments: vec!["config".to_string(), "--get".to_string(), key.to_string()],
        input: None,
    })
    .ok()?;
    if response.exit_code != 0 {
        return None;
    }
    let value = response.output.trim();
    (!value.is_empty()).then(|| value.to_string())
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
    validate_revision(&request.reference)?;
    let response = readonly_command(GitCommandRequest {
        root,
        arguments: vec![
            "-c".to_string(),
            "core.quotepath=false".to_string(),
            "diff".to_string(),
            "--name-status".to_string(),
            "--find-renames".to_string(),
            request.reference,
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
    let reference = validated_reference(Some(&request.reference))?;

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

    let found = readonly_command(GitCommandRequest {
        root,
        arguments: vec![
            "grep".to_string(),
            "--cached".to_string(),
            "-l".to_string(),
            "-E".to_string(),
            r"^(<<<<<<<|>>>>>>>|\|\|\|\|\|\|\|) ".to_string(),
        ],
        input: None,
    })?;
    // `git grep` exits 1 when nothing matches, which is not a failure here.
    if found.exit_code > 1 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Git grep failed").with_details(found.output)
        );
    }

    let mut paths: Vec<String> = found
        .output
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(str::to_string)
        .collect();
    paths.sort();
    paths.dedup();
    Ok(GitConflictMarkerResponse { paths })
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
    let reference = validated_reference(Some(&request.reference))?;
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

fn validate_paths(paths: &[String]) -> Result<Vec<String>, CoreError> {
    if paths.is_empty() || paths.iter().any(|path| !is_safe_pathspec(path)) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Git operation contains an invalid path",
        ));
    }
    Ok(paths.to_vec())
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
    }
}

/// Discards both index and working-tree content for a conflict-dialog rollback.
/// The normal `discard` operation deliberately preserves staged content, while
/// this explicit operation is destructive for the whole path and therefore only
/// used after the UI's second confirmation.
fn discard_all(root: &str, paths: &[String]) -> Result<GitCommandResponse, CoreError> {
    let mut tracked = Vec::new();
    let mut untracked = Vec::new();
    let mut status_arguments = vec![
        "status".to_string(),
        "--porcelain".to_string(),
        "--untracked-files=all".to_string(),
        "--".to_string(),
    ];
    status_arguments.extend(paths.iter().cloned());
    let status = execute_git(root, &status_arguments, None)?;
    if status.exit_code != 0 {
        return Ok(status);
    }
    for path in paths {
        let is_untracked = status.output.lines().any(|line| {
            (line.starts_with("??") || line.starts_with("!!")) && line[3..].trim() == path
        });
        if is_untracked {
            untracked.push(path.clone());
        } else {
            tracked.push(path.clone());
        }
    }

    let mut final_response = status;
    if !tracked.is_empty() {
        let mut arguments = vec!["checkout".to_string(), "HEAD".to_string(), "--".to_string()];
        arguments.extend(tracked);
        final_response = execute_git(root, &arguments, None)?;
        if final_response.exit_code != 0 {
            return Ok(final_response);
        }
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

fn push(root: &str, reference: Option<&str>) -> Result<GitCommandResponse, CoreError> {
    let current = current_branch(root)?;
    let branch = match reference {
        Some(reference) => local_branch_name(&validated_reference(Some(reference))?)?,
        None => current.clone(),
    };
    let upstream = execute_git(
        root,
        &[
            "rev-parse".into(),
            "--abbrev-ref".into(),
            format!("{branch}@{{upstream}}"),
        ],
        None,
    )?;
    if upstream.exit_code == 0 {
        let tracking_name = upstream.output.trim();
        if branch == current {
            return execute_git(root, &["push".into()], None);
        }
        if let Some((remote, remote_branch)) = tracking_name.split_once('/') {
            return execute_git(
                root,
                &[
                    "push".into(),
                    remote.to_string(),
                    format!("{branch}:{remote_branch}"),
                ],
                None,
            );
        }
    }

    let remotes = execute_git(root, &["remote".into()], None)?;
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
        });
    match remote {
        Some(remote) => execute_git(
            root,
            &[
                "push".into(),
                "--set-upstream".into(),
                remote.to_string(),
                branch,
            ],
            None,
        ),
        None => Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "No Git remote is configured",
        )),
    }
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
    let reference = validated_reference(request.reference.as_deref())?;
    let mut base: Vec<String> = vec!["switch".into()];
    if request.force {
        base.push("--discard-changes".into());
    }
    match request.reference_kind.as_deref() {
        Some("local") => {
            // `git switch` rejects fully qualified refs ("refs/heads/foo"), so pass the
            // short branch name. Tags still need the full ref for the --detach form.
            let branch = local_branch_name(&reference)?;
            base.push(branch);
            execute_git(root, &base, None)
        }
        Some("tag") => {
            base.push("--detach".into());
            base.push(reference);
            execute_git(root, &base, None)
        }
        Some("remote") => {
            let (_, local_name) = mutations::remote_branch_components(root, &reference)?;
            if !is_safe_pathspec(&local_name) {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Invalid remote branch name",
                ));
            }
            let local_ref = format!("refs/heads/{local_name}");
            let existing = execute_git(
                root,
                &[
                    "show-ref".into(),
                    "--verify".into(),
                    "--quiet".into(),
                    local_ref,
                ],
                None,
            )?;
            if existing.exit_code == 0 {
                base.push(local_name.to_string());
            } else {
                base.push("--track".into());
                base.push("-c".into());
                base.push(local_name.to_string());
                base.push(reference);
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
    if columns.len() < 4 || columns[1].ends_with("/HEAD") {
        return None;
    }
    let kind = if columns[0].starts_with("refs/heads/") {
        "local"
    } else if columns[0].starts_with("refs/remotes/") {
        "remote"
    } else {
        "tag"
    };
    Some(GitReferenceResponse {
        full_name: columns[0].to_string(),
        short_name: columns[1].to_string(),
        kind: kind.to_string(),
        is_current: columns[2].trim() == "*",
        upstream_short_name: (!columns[3].is_empty()).then(|| columns[3].to_string()),
    })
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
        let mut path = record[3..].to_string();
        let mut original_path = None;
        if matches!(x, 'R' | 'C') && index + 1 < records.len() {
            original_path = Some(path);
            path = String::from_utf8_lossy(records[index + 1]).to_string();
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
        line_similarity, pair_diff_entries, parse_diff, structured_diff_from_output, DiffEntry,
        GitCommandInvocation, GitCommandResponse, GitProcessOutput, MAX_ALIGNMENT_CELLS,
    };
    use crate::protocol::{CoreError, ErrorCode};
    use serde_json::Value;

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
        };

        assert_eq!(
            serde_json::to_value(response).expect("Git response should serialize"),
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
