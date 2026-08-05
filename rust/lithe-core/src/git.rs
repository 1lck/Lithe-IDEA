use crate::error::{CoreError, ErrorCode};
use crate::model::{
    GitBlameLineResponse, GitBlameResponse, GitChange, GitCommitLookupResponse, GitCommitResponse,
    GitComparisonResponse, GitDiffHunkResponse, GitDiffResponse, GitDiffRowResponse,
    GitFileResponse, GitFilesResponse, GitHistoryResponse, GitReferenceResponse, GitStashResponse,
    GitStashesResponse, GitStatusResponse,
};
use serde::{Deserialize, Serialize};
use std::io::Read;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::Duration;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitStatusRequest {
    pub root: String,
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

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitCommandResponse {
    pub output: String,
    pub exit_code: i32,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitWriteRequest {
    pub root: String,
    pub operation: String,
    #[serde(default)]
    pub paths: Vec<String>,
    #[serde(default)]
    pub reference: Option<String>,
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
    #[serde(default)]
    pub mode: Option<String>,
    #[serde(default)]
    pub include_untracked: bool,
    #[serde(default)]
    pub checkout: bool,
    #[serde(default)]
    pub amend: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
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
pub struct GitApplyRequest {
    pub root: String,
    pub patch: String,
    pub mode: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitHistoryRequest {
    pub root: String,
    #[serde(default)]
    pub reference: Option<String>,
    #[serde(default = "default_history_limit")]
    pub limit: usize,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitCommitRequest {
    pub root: String,
    pub commit: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitCommitFilesRequest {
    pub root: String,
    pub commit: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitComparisonRequest {
    pub root: String,
    pub reference: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitStashesRequest {
    pub root: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
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

pub fn command(request: GitCommandRequest) -> Result<GitCommandResponse, CoreError> {
    let root = validate_root(&request.root)?;
    execute_git(&root, &request.arguments, request.input)
}

pub fn write(request: GitWriteRequest) -> Result<GitCommandResponse, CoreError> {
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
        "fetch" => arguments = vec!["fetch".into(), "--all".into(), "--prune".into()],
        "pull" => arguments = vec!["pull".into(), "--ff-only".into()],
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
        "stashApply" | "stashPop" | "stashDrop" => {
            let reference = validated_stash_reference(request.reference.as_deref())?;
            let action = match request.operation.as_str() {
                "stashApply" => "apply",
                "stashPop" => "pop",
                _ => "drop",
            };
            arguments = vec!["stash".into(), action.into(), reference];
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

fn execute_git(
    root: &str,
    arguments: &[String],
    input: Option<String>,
) -> Result<GitCommandResponse, CoreError> {
    crate::cancellation::check()?;
    let mut process = Command::new("git");
    process.args(arguments).current_dir(root);
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
        if let Err(error) = crate::cancellation::check() {
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
    let mut text = String::from_utf8_lossy(&stdout).to_string();
    text.push_str(&String::from_utf8_lossy(&stderr));
    Ok(GitCommandResponse {
        output: text,
        exit_code: status.code().unwrap_or(1),
    })
}

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

    let mut arguments = if let Some(commit) = request.commit {
        validate_revision(&commit)?;
        vec![
            "show".to_string(),
            "--format=".to_string(),
            "--no-ext-diff".to_string(),
            format!("--unified={}", request.context_lines),
            commit,
        ]
    } else if let Some(reference) = request.reference {
        validate_revision(&reference)?;
        vec![
            "diff".to_string(),
            "--no-ext-diff".to_string(),
            format!("--unified={}", request.context_lines),
            reference,
        ]
    } else {
        let mut arguments = vec!["diff".to_string(), "--no-ext-diff".to_string()];
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
    if request.untracked {
        arguments.push(null_device().to_string());
    }
    arguments.extend(request.pathspecs);

    let command_response = command(GitCommandRequest {
        root: request.root,
        arguments,
        input: None,
    })?;
    let patch = command_response.output;
    let document = parse_diff(&patch);
    Ok(GitDiffResponse {
        patch,
        rows: document.0,
        hunks: document.1,
    })
}

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

pub fn history(request: GitHistoryRequest) -> Result<GitHistoryResponse, CoreError> {
    let limit = request.limit.clamp(1, 5_000);
    let root = validate_root(&request.root)?;
    let reference_output = command(GitCommandRequest {
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
    let commit_output = command(GitCommandRequest {
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
    })
}

pub fn commit(request: GitCommitRequest) -> Result<GitCommitLookupResponse, CoreError> {
    let root = validate_root(&request.root)?;
    validate_revision(&request.commit)?;
    let response = command(GitCommandRequest {
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

pub fn commit_files(request: GitCommitFilesRequest) -> Result<GitFilesResponse, CoreError> {
    let root = validate_root(&request.root)?;
    validate_revision(&request.commit)?;
    let response = command(GitCommandRequest {
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

pub fn comparison(request: GitComparisonRequest) -> Result<GitComparisonResponse, CoreError> {
    let root = validate_root(&request.root)?;
    validate_revision(&request.reference)?;
    let response = command(GitCommandRequest {
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

pub fn stashes(request: GitStashesRequest) -> Result<GitStashesResponse, CoreError> {
    let root = validate_root(&request.root)?;
    let response = command(GitCommandRequest {
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

pub fn blame(request: GitBlameRequest) -> Result<GitBlameResponse, CoreError> {
    if !is_safe_pathspec(&request.path) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Git blame contains an invalid path",
        ));
    }
    let response = command(GitCommandRequest {
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

fn validated_reference(value: Option<&str>) -> Result<String, CoreError> {
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

fn current_branch(root: &str) -> Result<String, CoreError> {
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

fn is_current_reference(root: &str, reference: &str) -> Result<bool, CoreError> {
    let current = current_branch(root)?;
    Ok(reference == current || reference == format!("refs/heads/{current}"))
}

fn failed_git_result(message: impl Into<String>) -> GitCommandResponse {
    GitCommandResponse {
        output: message.into(),
        exit_code: 1,
    }
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
        None => Ok(failed_git_result("No Git remote is configured")),
    }
}

fn checkout(root: &str, request: GitWriteRequest) -> Result<GitCommandResponse, CoreError> {
    let reference = validated_reference(request.reference.as_deref())?;
    match request.reference_kind.as_deref() {
        Some("local") => execute_git(root, &["switch".into(), reference], None),
        Some("tag") => execute_git(root, &["switch".into(), "--detach".into(), reference], None),
        Some("remote") => {
            let remote_path = reference.strip_prefix("refs/remotes/").ok_or_else(|| {
                CoreError::new(ErrorCode::InvalidRequest, "Invalid remote branch name")
            })?;
            let (_, local_name) = remote_path.split_once('/').ok_or_else(|| {
                CoreError::new(ErrorCode::InvalidRequest, "Invalid remote branch name")
            })?;
            if !is_safe_pathspec(local_name) {
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
                execute_git(root, &["switch".into(), local_name.to_string()], None)
            } else {
                execute_git(
                    root,
                    &[
                        "switch".into(),
                        "--track".into(),
                        "-c".into(),
                        local_name.to_string(),
                        reference,
                    ],
                    None,
                )
            }
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

fn is_safe_pathspec(path: &str) -> bool {
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

struct DiffEntry {
    number: usize,
    text: String,
}

struct DiffHunkRecord {
    id: String,
    header: String,
    lines: Vec<String>,
}

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
fn pair_diff_entries(removed: &[DiffEntry], added: &[DiffEntry]) -> Vec<(Option<usize>, Option<usize>)> {
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
            changes: Vec::new(),
        });
    }
    let repository_root =
        PathBuf::from(String::from_utf8_lossy(&repository_root_output.stdout).trim());
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
    Ok(GitStatusResponse {
        repository_root: Some(relative_or_absolute(&repository_root, &root)),
        branch,
        changes,
    })
}

fn run_git(directory: &Path, arguments: &[&str]) -> Result<std::process::Output, CoreError> {
    Command::new("git")
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
    use super::{line_similarity, pair_diff_entries, parse_diff, DiffEntry, MAX_ALIGNMENT_CELLS};
    use serde_json::Value;

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
        let added = entries(&[
            "// recompute the total",
            "let total = compute(a, b, c);",
        ]);

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
        assert!(matched.windows(2).all(|pair| pair[0].0 < pair[1].0 && pair[0].1 < pair[1].1));
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
    fn structured_diff_matches_shared_fixture() {
        let fixture: Value =
            serde_json::from_str(include_str!("../../../shared/fixtures/git/diff.json"))
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
