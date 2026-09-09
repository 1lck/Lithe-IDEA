//! Lossless UTF-8 patch exchange with forward checks and reviewed-state validation.

use super::{
    capture_git_with_environment, capture_git_with_options, git_resolved_path, is_safe_pathspec,
    operation_state, repository_root, resolve_commit_revision, validate_root, CoreError, ErrorCode,
    GitCommandResponse, GitOperationStateRequest, TemporaryGitCommitContext,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::path::Path;

/// Maximum patch transported through one JSON request, in bytes.
const MAX_PATCH_BYTES: usize = 32 * 1024 * 1024;

/// Source trees used to generate an exchange patch.
#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PatchSource {
    /// Final selected working files relative to HEAD, including untracked files.
    WorkingTree,
    /// Index relative to HEAD.
    Staged,
    /// Tracked working files relative to the index.
    Unstaged,
    /// Explicit base commit tree to explicit target commit tree.
    Commits,
}

/// Selected files and source for a patch that never changes the real index.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PatchExportRequest {
    pub root: String,
    pub source: PatchSource,
    /// Repository-relative literal paths; empty selects the entire repository.
    #[serde(default)]
    pub paths: Vec<String>,
    pub base_revision: Option<String>,
    pub target_revision: Option<String>,
    /// Enumerate counts and rename paths without decoding or transporting patch contents.
    #[serde(default)]
    pub metadata_only: bool,
}

/// Application target; importing a patch never creates a commit.
#[derive(Debug, Clone, Copy, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum PatchTarget {
    Worktree,
    /// Apply to both the index and the working files, as Git's --index mode does.
    IndexAndWorktree,
}

/// Imported UTF-8 patch and destination for a side-effect-free forward check.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PatchPreviewRequest {
    pub root: String,
    pub patch: String,
    pub target: PatchTarget,
}

/// A patch application tied to the exact content and repository state reviewed.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PatchApplyRequest {
    pub root: String,
    pub patch: String,
    pub target: PatchTarget,
    pub expected_state: String,
}

/// One path reported by Git's NUL-delimited patch statistics.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PatchFile {
    pub path: String,
    /// Original path for rename or copy changes, as parsed by Git.
    pub original_path: Option<String>,
    /// None for binary changes, which have no textual line count.
    pub additions: Option<u64>,
    pub deletions: Option<u64>,
}

/// Exact UTF-8 patch text and an ordered file summary for native save dialogs.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PatchExportResponse {
    pub patch: String,
    pub files: Vec<PatchFile>,
    pub byte_length: usize,
}

/// Forward-check result; the state token binds the patch and its destination.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PatchPreviewResponse {
    pub applicable: bool,
    pub files: Vec<PatchFile>,
    pub diagnostic: String,
    /// Absent on failure; clients must not offer Apply without a valid token.
    pub expected_state: Option<String>,
    pub byte_length: usize,
}

/// Exports raw Git patch output without passing through display-oriented decoding.
pub fn export(request: PatchExportRequest) -> Result<PatchExportResponse, CoreError> {
    let root = checkout_root(&request.root)?;
    let paths = literal_paths(&request.paths)?;
    if !matches!(request.source, PatchSource::Commits)
        && (request.base_revision.is_some() || request.target_revision.is_some())
    {
        return Err(invalid(
            "Commit revisions cannot be combined with local-change patch modes",
        ));
    }
    let mut arguments = vec![
        "--literal-pathspecs".into(),
        "diff".into(),
        "--no-ext-diff".into(),
        "--no-textconv".into(),
        "--no-color".into(),
        "--binary".into(),
        "--full-index".into(),
        "--src-prefix=a/".into(),
        "--dst-prefix=b/".into(),
    ];
    if request.metadata_only {
        arguments.retain(|argument| argument != "--binary");
        arguments.extend(["--numstat".into(), "-z".into()]);
    }
    let bytes = match request.source {
        PatchSource::WorkingTree => export_worktree(&root, &paths, arguments)?,
        PatchSource::Staged | PatchSource::Unstaged | PatchSource::Commits => {
            match request.source {
                PatchSource::Staged => arguments.push("--cached".into()),
                PatchSource::Commits => {
                    let base = request
                        .base_revision
                        .as_deref()
                        .ok_or_else(|| invalid("Select a base commit for the patch"))?;
                    let target = request
                        .target_revision
                        .as_deref()
                        .ok_or_else(|| invalid("Select a target commit for the patch"))?;
                    arguments.push(resolve_commit_revision(&root, base)?);
                    arguments.push(resolve_commit_revision(&root, target)?);
                }
                _ => {}
            }
            arguments.push("--".into());
            arguments.extend(paths);
            let output = capture_git_with_options(&root, &arguments, None, true)?;
            ensure_success(
                output.exit_code,
                &output.stderr,
                "Could not export the patch",
            )?;
            output.stdout
        }
    };
    if request.metadata_only {
        return Ok(PatchExportResponse {
            files: parse_export_statistics(&bytes)?,
            patch: String::new(),
            byte_length: 0,
        });
    }
    let patch = String::from_utf8(bytes).map_err(|_| {
        invalid(
        "This patch contains non-UTF-8 text and cannot be exported without changing its contents",
    )
    })?;
    validate_patch_size(&patch)?;
    let files = if patch.is_empty() {
        Vec::new()
    } else {
        patch_files(&root, &patch)?
    };
    Ok(PatchExportResponse {
        byte_length: patch.len(),
        patch,
        files,
    })
}

// Git diff uses an empty third column followed by two NUL-delimited names for
// renames. Parse bytes so unrelated non-UTF-8 file contents never enter discovery.
fn parse_export_statistics(bytes: &[u8]) -> Result<Vec<PatchFile>, CoreError> {
    let mut fields = bytes.split(|byte| *byte == 0);
    let mut files = Vec::new();
    while let Some(field) = fields.next().filter(|field| !field.is_empty()) {
        let mut columns = field.splitn(3, |byte| *byte == b'\t');
        let additions = parse_count(columns.next())?;
        let deletions = parse_count(columns.next())?;
        let path = columns
            .next()
            .ok_or_else(|| invalid("Invalid patch file statistics"))?;
        let (path, original_path) = if path.is_empty() {
            let original = fields
                .next()
                .ok_or_else(|| invalid("Missing original patch path"))?;
            let destination = fields
                .next()
                .ok_or_else(|| invalid("Missing destination patch path"))?;
            (
                safe_patch_path(destination)?,
                Some(safe_patch_path(original)?),
            )
        } else {
            (safe_patch_path(path)?, None)
        };
        files.push(PatchFile {
            path,
            original_path,
            additions,
            deletions,
        });
    }
    files.sort_by(|left, right| left.path.cmp(&right.path));
    Ok(files)
}

fn export_worktree(
    root: &str,
    paths: &[String],
    mut arguments: Vec<String>,
) -> Result<Vec<u8>, CoreError> {
    let head_result = capture_git_with_options(
        root,
        &[
            "rev-parse".into(),
            "--verify".into(),
            "--quiet".into(),
            "HEAD".into(),
        ],
        None,
        true,
    )?;
    if head_result.exit_code > 1 {
        ensure_success(
            head_result.exit_code,
            &head_result.stderr,
            "Could not resolve Git HEAD",
        )?;
    }
    let head = (head_result.exit_code == 0).then(|| {
        String::from_utf8_lossy(&head_result.stdout)
            .trim()
            .to_string()
    });
    let common = git_resolved_path(
        root,
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
        "Git common directory",
    )?;
    // Staging into an isolated index produces one net patch even when the real
    // index and worktree both modify the same file or recreate a deleted path.
    let context = TemporaryGitCommitContext::prepare(root, head.as_deref())?;
    let environment = context.environment(root, &common);
    let initialize = vec!["read-tree".into(), head.unwrap_or_else(|| "--empty".into())];
    let output = capture_git_with_environment(root, &initialize, None, true, &environment)?;
    ensure_success(
        output.exit_code,
        &output.stderr,
        "Could not prepare the patch snapshot",
    )?;
    let input = paths
        .iter()
        .map(|path| format!("{path}\0"))
        .collect::<String>();
    let stage = vec![
        "--literal-pathspecs".into(),
        "add".into(),
        "-A".into(),
        "--pathspec-from-file=-".into(),
        "--pathspec-file-nul".into(),
    ];
    let output = capture_git_with_environment(root, &stage, Some(input), true, &environment)?;
    ensure_success(
        output.exit_code,
        &output.stderr,
        "Could not prepare selected patch files",
    )?;
    arguments.push("--cached".into());
    arguments.push("--".into());
    arguments.extend(paths.iter().cloned());
    let output = capture_git_with_environment(root, &arguments, None, true, &environment)?;
    ensure_success(
        output.exit_code,
        &output.stderr,
        "Could not export the patch snapshot",
    )?;
    Ok(output.stdout)
}

/// Checks forward applicability without changing files or staging content.
pub fn preview(request: PatchPreviewRequest) -> Result<PatchPreviewResponse, CoreError> {
    let root = checkout_root(&request.root)?;
    validate_nonempty_patch(&request.patch)?;
    ensure_no_operation(&root)?;
    let files = patch_files(&root, &request.patch)?;
    let before = state_token(&root, &request.patch, request.target, &files)?;
    let output = capture_git_with_options(
        &root,
        &apply_arguments(request.target, true),
        Some(request.patch.clone()),
        true,
    )?;
    let after = state_token(&root, &request.patch, request.target, &files)?;
    let unchanged = before == after;
    let applicable = output.exit_code == 0 && unchanged;
    let diagnostic = if !unchanged {
        "The repository changed while checking the patch. Preview it again.".into()
    } else {
        String::from_utf8_lossy(&output.stderr).trim().to_string()
    };
    Ok(PatchPreviewResponse {
        applicable,
        files,
        diagnostic,
        expected_state: applicable.then_some(after),
        byte_length: request.patch.len(),
    })
}

/// Applies a reviewed patch using Git's default no-reject behavior.
pub fn apply_reviewed(request: PatchApplyRequest) -> Result<GitCommandResponse, CoreError> {
    let root = checkout_root(&request.root)?;
    let _lease = super::rewrite::RewriteLease::acquire(&root)?;
    validate_nonempty_patch(&request.patch)?;
    ensure_no_operation(&root)?;
    let files = patch_files(&root, &request.patch)?;
    if state_token(&root, &request.patch, request.target, &files)? != request.expected_state {
        return Err(invalid(
            "The patch or repository changed after preview. Preview it again.",
        ));
    }
    let check_arguments = apply_arguments(request.target, true);
    let checked =
        capture_git_with_options(&root, &check_arguments, Some(request.patch.clone()), true)?;
    if checked.exit_code != 0 {
        return Ok(checked.into_command_response(&check_arguments));
    }
    if state_token(&root, &request.patch, request.target, &files)? != request.expected_state {
        return Err(invalid(
            "The repository changed while checking the patch. Preview it again.",
        ));
    }
    // No --reject, --3way, --unsafe-paths or automatic whitespace repair: Git
    // performs its own final applicability check and does not silently apply
    // only a subset of the reviewed patch.
    let arguments = apply_arguments(request.target, false);
    let output = capture_git_with_options(&root, &arguments, Some(request.patch), false)?;
    let mut result = output.into_command_response(&arguments);
    result.invocations.insert(
        0,
        checked
            .into_command_response(&check_arguments)
            .invocations
            .remove(0),
    );
    Ok(result)
}

fn apply_arguments(target: PatchTarget, check: bool) -> Vec<String> {
    let mut arguments = vec![
        "-c".into(),
        "apply.ignorewhitespace=no".into(),
        "apply".into(),
        "--whitespace=nowarn".into(),
    ];
    if matches!(target, PatchTarget::IndexAndWorktree) {
        arguments.push("--index".into());
    }
    if check {
        arguments.push("--check".into());
    }
    arguments.push("-".into());
    arguments
}

fn patch_files(root: &str, patch: &str) -> Result<Vec<PatchFile>, CoreError> {
    let mut files = patch_stat_files(root, patch, false)?;
    // Unlike git diff --numstat -z, git apply emits only one name per patch.
    // Parsing the same input in reverse exposes rename/copy source paths with
    // Git's own filename parser, including C-quoted Unicode and tab/newline names.
    let mut original_files = patch_stat_files(root, patch, true)?;
    // Reverse application visits file patches in the opposite order as well.
    original_files.reverse();
    if files.len() != original_files.len() {
        return Err(invalid("The patch has inconsistent file statistics"));
    }
    for (file, original) in files.iter_mut().zip(original_files) {
        if file.path != original.path {
            file.original_path = Some(original.path);
        }
    }
    files.sort_by(|left, right| left.path.cmp(&right.path));
    if files.is_empty() {
        return Err(invalid("The patch contains no file changes"));
    }
    Ok(files)
}

fn patch_stat_files(root: &str, patch: &str, reverse: bool) -> Result<Vec<PatchFile>, CoreError> {
    let mut arguments = vec!["apply".into(), "--numstat".into(), "-z".into()];
    if reverse {
        arguments.push("--reverse".into());
    }
    arguments.push("-".into());
    let output = capture_git_with_options(root, &arguments, Some(patch.into()), true)?;
    ensure_success(
        output.exit_code,
        &output.stderr,
        "The patch could not be read",
    )?;
    let mut files = Vec::new();
    for field in output.stdout.split(|byte| *byte == 0) {
        if field.is_empty() {
            continue;
        }
        let mut columns = field.splitn(3, |byte| *byte == b'\t');
        let additions = parse_count(columns.next())?;
        let deletions = parse_count(columns.next())?;
        let path = columns
            .next()
            .ok_or_else(|| invalid("Invalid patch file statistics"))?;
        files.push(PatchFile {
            path: safe_patch_path(path)?,
            original_path: None,
            additions,
            deletions,
        });
    }
    Ok(files)
}

fn parse_count(value: Option<&[u8]>) -> Result<Option<u64>, CoreError> {
    let value = value.ok_or_else(|| invalid("Invalid patch file statistics"))?;
    if value == b"-" {
        return Ok(None);
    }
    std::str::from_utf8(value)
        .ok()
        .and_then(|value| value.parse().ok())
        .map(Some)
        .ok_or_else(|| invalid("Invalid patch line count"))
}

fn safe_patch_path(bytes: &[u8]) -> Result<String, CoreError> {
    let path = std::str::from_utf8(bytes).map_err(|_| invalid("Patch paths must use UTF-8"))?;
    if !is_safe_pathspec(path)
        || path.contains('\0')
        || path
            .replace('\\', "/")
            .split('/')
            .any(|part| part.eq_ignore_ascii_case(".git"))
    {
        return Err(invalid(
            "The patch contains a path outside the working files",
        ));
    }
    Ok(path.into())
}

fn literal_paths(paths: &[String]) -> Result<Vec<String>, CoreError> {
    if paths.is_empty() {
        return Ok(vec![".".into()]);
    }
    let mut result = BTreeSet::new();
    for path in paths {
        result.insert(safe_patch_path(path.as_bytes())?);
    }
    Ok(result.into_iter().collect())
}

fn checkout_root(root: &str) -> Result<String, CoreError> {
    let root = validate_root(root)?;
    let path = repository_root(&root)?;
    path.to_str()
        .map(str::to_string)
        .ok_or_else(|| invalid("Repository paths must use UTF-8"))
}

fn ensure_no_operation(root: &str) -> Result<(), CoreError> {
    let state = operation_state(GitOperationStateRequest { root: root.into() })?;
    if !state.kind.is_empty() {
        return Err(invalid(
            "Finish or abort the current Git operation before applying a patch",
        ));
    }
    Ok(())
}

fn state_token(
    root: &str,
    patch: &str,
    target: PatchTarget,
    files: &[PatchFile],
) -> Result<String, CoreError> {
    let mut hash = Sha256::new();
    hash.update(b"lithe.patch.v1\0");
    add_hash_field(&mut hash, root.as_bytes());
    add_hash_field(&mut hash, patch.as_bytes());
    hash.update([u8::from(matches!(target, PatchTarget::IndexAndWorktree))]);
    // The index contains intent and flags that a content diff does not expose.
    let index = git_resolved_path(
        root,
        &["rev-parse", "--path-format=absolute", "--git-path", "index"],
        "Git index",
    )?;
    hash_optional_file(&mut hash, Path::new(&index))?;
    // Read the exact destinations as well: assume-unchanged, skip-worktree and
    // ignored files can hide concurrent content changes from porcelain/diff.
    let mut destinations = BTreeSet::new();
    for file in files {
        destinations.insert(file.path.as_str());
        if let Some(original) = &file.original_path {
            destinations.insert(original.as_str());
        }
    }
    for destination in destinations {
        add_hash_field(&mut hash, destination.as_bytes());
        let path = Path::new(root).join(destination);
        ensure_working_ancestors(Path::new(root), &path)?;
        hash_optional_file(&mut hash, &path)?;
    }
    // Content diffs, rather than porcelain status alone, detect a second edit
    // to an already-modified file. Read both sides to preserve staging intent.
    for arguments in [
        vec!["status", "--porcelain=v1", "-z", "--untracked-files=all"],
        vec![
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            "--no-color",
            "--binary",
            "--full-index",
        ],
        vec![
            "diff",
            "--cached",
            "--no-ext-diff",
            "--no-textconv",
            "--no-color",
            "--binary",
            "--full-index",
        ],
        vec!["rev-parse", "--verify", "--quiet", "HEAD"],
        vec!["symbolic-ref", "--quiet", "HEAD"],
    ] {
        let arguments = arguments
            .into_iter()
            .map(str::to_string)
            .collect::<Vec<_>>();
        let output = capture_git_with_options(root, &arguments, None, true)?;
        if output.exit_code != 0
            && !(output.exit_code == 1
                && matches!(arguments[0].as_str(), "rev-parse" | "symbolic-ref"))
        {
            ensure_success(
                output.exit_code,
                &output.stderr,
                "Could not read the patch destination",
            )?;
        }
        add_hash_field(&mut hash, &output.stdout);
    }
    let output = capture_git_with_options(
        root,
        &[
            "ls-files".into(),
            "--others".into(),
            "--exclude-standard".into(),
            "-z".into(),
        ],
        None,
        true,
    )?;
    ensure_success(
        output.exit_code,
        &output.stderr,
        "Could not inspect untracked files",
    )?;
    let mut paths = output
        .stdout
        .split(|byte| *byte == 0)
        .filter(|path| !path.is_empty())
        .map(safe_patch_path)
        .collect::<Result<Vec<_>, _>>()?;
    paths.sort();
    for path in paths {
        crate::protocol::cancellation::check()?;
        add_hash_field(&mut hash, path.as_bytes());
        hash_working_file(&mut hash, &Path::new(root).join(path))?;
    }
    Ok(format!("{:x}", hash.finalize()))
}

fn ensure_working_ancestors(root: &Path, path: &Path) -> Result<(), CoreError> {
    let mut parent = path.parent();
    while let Some(directory) = parent.filter(|directory| *directory != root) {
        match std::fs::symlink_metadata(directory) {
            Ok(metadata) if !metadata.is_dir() || metadata.file_type().is_symlink() => {
                return Err(invalid(
                    "Patch paths cannot traverse symbolic links or files",
                ));
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(patch_io_error(error)),
        }
        parent = directory.parent();
    }
    Ok(())
}

fn hash_optional_file(hash: &mut Sha256, path: &Path) -> Result<(), CoreError> {
    match std::fs::symlink_metadata(path) {
        Ok(_) => {
            hash.update([1]);
            hash_working_file(hash, path)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            hash.update([0]);
            Ok(())
        }
        Err(error) => Err(patch_io_error(error)),
    }
}

fn hash_working_file(hash: &mut Sha256, path: &Path) -> Result<(), CoreError> {
    use std::io::Read;
    let metadata = std::fs::symlink_metadata(path).map_err(patch_io_error)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        hash.update(metadata.permissions().mode().to_le_bytes());
    }
    hash.update([u8::from(metadata.file_type().is_symlink())]);
    if metadata.file_type().is_symlink() {
        let target = std::fs::read_link(path).map_err(patch_io_error)?;
        add_hash_field(hash, target.as_os_str().as_encoded_bytes());
        return Ok(());
    }
    if !metadata.is_file() {
        return Err(invalid(
            "The patch destination contains an unsupported file type",
        ));
    }
    hash.update(metadata.len().to_le_bytes());
    let mut file = std::fs::File::open(path).map_err(patch_io_error)?;
    let mut buffer = [0; 65536];
    loop {
        crate::protocol::cancellation::check()?;
        let length = file.read(&mut buffer).map_err(patch_io_error)?;
        if length == 0 {
            break;
        }
        hash.update(&buffer[..length]);
    }
    Ok(())
}

fn add_hash_field(hash: &mut Sha256, value: &[u8]) {
    hash.update((value.len() as u64).to_le_bytes());
    hash.update(value);
}

fn validate_patch_size(patch: &str) -> Result<(), CoreError> {
    if patch.len() > MAX_PATCH_BYTES {
        return Err(invalid("The patch exceeds the 32 MiB exchange limit"));
    }
    if patch.contains('\0') {
        return Err(invalid(
            "The patch must be UTF-8 text; use Git binary patch encoding for binary files",
        ));
    }
    Ok(())
}

fn validate_nonempty_patch(patch: &str) -> Result<(), CoreError> {
    validate_patch_size(patch)?;
    if patch.trim().is_empty() {
        return Err(invalid("The patch is empty"));
    }
    Ok(())
}

fn ensure_success(exit_code: i32, stderr: &[u8], message: &str) -> Result<(), CoreError> {
    if exit_code == 0 {
        return Ok(());
    }
    Err(CoreError::new(ErrorCode::ProcessFailed, message)
        .with_details(String::from_utf8_lossy(stderr)))
}

fn patch_io_error(error: std::io::Error) -> CoreError {
    CoreError::new(
        ErrorCode::ProcessFailed,
        "Could not inspect the patch destination",
    )
    .with_details(error.to_string())
}

fn invalid(message: &str) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, message)
}
