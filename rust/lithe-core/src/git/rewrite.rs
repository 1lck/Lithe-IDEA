//! Reviewed local history mutations with immutable snapshots and durable recovery refs.

use super::*;
use sha2::{Digest, Sha256};
use std::collections::{BTreeSet, HashMap};
use std::fs::{self, File};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

const RECOVERY_PREFIX: &str = "refs/lithe/history-recovery/";
const MAX_RECOVERY_REFERENCES: usize = 20;
const MAX_REWRITE_COMMITS: usize = 1_000;
static ACTIVE_REWRITES: OnceLock<Mutex<HashMap<PathBuf, thread::ThreadId>>> = OnceLock::new();
static RECOVERY_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Read-only eligibility and complete-message request for one history action.
pub struct GitHistoryRewritePreviewRequest {
    pub root: String,
    /// One of the four history actions, or the native rebase adapter's `interactiveRebase`.
    pub operation: String,
    /// Selected commits; Core resolves revisions and orders them oldest first.
    pub revisions: Vec<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
/// Immutable checkout and selection reviewed before a history mutation.
pub struct GitHistoryRewriteExpectation {
    /// Full checked-out local branch reference.
    pub branch: String,
    pub head: String,
    /// Opaque digest of checkout identity, refs, index, and working-file contents.
    pub state_token: String,
    pub operation: String,
    /// Full selected OIDs in oldest-to-newest order.
    pub revisions: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// A selected or affected commit with its complete, untrimmed message.
pub struct GitHistoryRewriteCommit {
    pub hash: String,
    pub parents: Vec<String>,
    pub message: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
/// Stable reason why a history action cannot execute against the current checkout.
pub struct GitHistoryRewriteBlocker {
    pub code: String,
    pub message: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
/// Read-only history preview shared by both platform products.
pub struct GitHistoryRewritePreviewResponse {
    pub operation: String,
    pub allowed: bool,
    pub blockers: Vec<GitHistoryRewriteBlocker>,
    pub branch: Option<String>,
    pub head: Option<String>,
    /// Oldest-to-newest selection, independent of the UI's filters and pagination.
    pub selected_commits: Vec<GitHistoryRewriteCommit>,
    /// Every commit whose identity or reachability changes, oldest first.
    pub affected_commits: Vec<GitHistoryRewriteCommit>,
    pub suggested_message: String,
    /// Only actionable, stable previews carry an execution expectation.
    pub expected_state: Option<GitHistoryRewriteExpectation>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Durable recovery identity and authoritative mutation outcome, including partial success.
pub struct GitHistoryRewriteResult {
    pub operation: String,
    pub branch: String,
    pub original_head: String,
    /// Prepared replacement OID, even when its installation could not be confirmed.
    pub new_head: Option<String>,
    pub recovery_reference: String,
    /// True only after the replacement branch OID was installed or observed.
    pub mutation_applied: bool,
    /// False if interruption also prevented determining the branch's final state.
    pub outcome_known: bool,
    /// `notNeeded`, `ready`, or `failed`; ref success does not imply worktree refresh success.
    pub worktree_refresh: String,
}

impl GitHistoryRewritePreviewResponse {
    fn block(&mut self, code: &str, message: &str) {
        self.blockers.push(GitHistoryRewriteBlocker {
            code: code.to_string(),
            message: message.to_string(),
        });
    }
}

/// Prevents overlapping history rewrite preparation in one shared repository.
/// External Git writers are still checked by the snapshot and final OID comparison.
pub(super) struct RewriteLease {
    common: PathBuf,
    owns_lease: bool,
}

impl RewriteLease {
    pub(super) fn acquire(root: &str) -> Result<Self, CoreError> {
        // Keep coordination probes outside the command trace: pre-Git argument
        // errors must retain their existing standard invalid_request envelope.
        let resolved = capture_git_with_options(
            root,
            &[
                "rev-parse".into(),
                "--path-format=absolute".into(),
                "--git-common-dir".into(),
            ],
            None,
            true,
        )?;
        if resolved.exit_code != 0 {
            // An uninitialized directory has no shared state to coordinate.
            // The owning command still validates and reports its normal error.
            return Ok(Self {
                common: PathBuf::new(),
                owns_lease: false,
            });
        }
        let common = PathBuf::from(
            std::str::from_utf8(&resolved.stdout)
                .map_err(|_| invalid("Unsupported Git metadata path encoding"))?
                .trim(),
        );
        let common = common.canonicalize().map_err(snapshot_io_error)?;
        let mut active = ACTIVE_REWRITES
            .get_or_init(|| Mutex::new(HashMap::new()))
            .lock()
            .map_err(|_| invalid("Git history operation coordination failed"))?;
        let owner = thread::current().id();
        if let Some(existing) = active.get(&common) {
            if *existing == owner {
                return Ok(Self {
                    common,
                    owns_lease: false,
                });
            }
            return Err(invalid(
                "Another Git write operation is running in this repository",
            ));
        }
        active.insert(common.clone(), owner);
        Ok(Self {
            common,
            owns_lease: true,
        })
    }
}

impl Drop for RewriteLease {
    fn drop(&mut self) {
        if !self.owns_lease {
            return;
        }
        if let Some(active) = ACTIVE_REWRITES.get() {
            if let Ok(mut active) = active.lock() {
                active.remove(&self.common);
            }
        }
    }
}

/// Resolves a real first-parent range and rejects unsupported history before UI confirmation.
pub fn history_rewrite_preview(
    request: GitHistoryRewritePreviewRequest,
) -> Result<GitHistoryRewritePreviewResponse, CoreError> {
    let root = repository_root(&validate_root(&request.root)?)?
        .to_string_lossy()
        .into_owned();
    validate_selection(&request.operation, &request.revisions)?;
    let mut result = GitHistoryRewritePreviewResponse {
        operation: request.operation.clone(),
        allowed: false,
        blockers: Vec::new(),
        branch: None,
        head: None,
        selected_commits: Vec::new(),
        affected_commits: Vec::new(),
        suggested_message: String::new(),
        expected_state: None,
    };
    let branch = execute_git_readonly(
        &root,
        &["symbolic-ref".into(), "--quiet".into(), "HEAD".into()],
        None,
    )?;
    if branch.exit_code == 0 && branch.stdout.trim().starts_with("refs/heads/") {
        result.branch = Some(branch.stdout.trim().to_string());
    } else {
        result.block(
            "detached_head",
            "Commit history can only be rewritten on a checked out local branch",
        );
    }
    let head = execute_git_readonly(
        &root,
        &[
            "rev-parse".into(),
            "--verify".into(),
            "--quiet".into(),
            "HEAD".into(),
        ],
        None,
    )?;
    if head.exit_code != 0 {
        result.block(
            "empty_history",
            "The current branch does not contain any commits",
        );
        return Ok(result);
    }
    result.head = Some(head.stdout.trim().to_string());
    let initial_snapshot = snapshot(&root)?;
    let operation = operation_state(GitOperationStateRequest { root: root.clone() })?;
    if !operation.kind.is_empty() || !operation.conflicted_paths.is_empty() {
        result.block(
            "active_operation",
            "Finish or abort the current Git operation before rewriting history",
        );
    }
    let status = checked_output(
        &root,
        &["status", "--porcelain=v1", "-z", "--untracked-files=all"],
    )?;
    if request.operation != "undoCommit" && !status.is_empty() {
        result.block(
            "dirty_worktree",
            "Commit history can only be rewritten with a clean working tree",
        );
    }
    if matches!(
        request.operation.as_str(),
        "deleteCommit" | "interactiveRebase"
    ) {
        let index_entries = checked_output(&root, &["ls-files", "-v", "-z"])?;
        if index_entries.split(|byte| *byte == 0).any(|entry| {
            entry
                .first()
                .is_some_and(|flag| *flag == b'S' || flag.is_ascii_lowercase())
        }) {
            // Git deliberately hides working-file edits behind these index flags.
            // Drop changes checkout trees, so its clean-tree check cannot rely
            // on the filtered diff while those flags are present.
            result.block("hidden_index_entries", "Replaying history requires clearing assume-unchanged and skip-worktree index flags first");
        }
    }
    let chain = checked_output(
        &root,
        &[
            "rev-list",
            "--first-parent",
            &format!("--max-count={}", MAX_REWRITE_COMMITS + 1),
            "HEAD",
        ],
    )?;
    let chain = std::str::from_utf8(&chain)
        .map_err(|_| invalid("Git returned an invalid commit identifier"))?
        .lines()
        .map(str::to_string)
        .collect::<Vec<_>>();
    let mut indices = Vec::new();
    let mut selected = BTreeSet::new();
    for revision in &request.revisions {
        let hash = resolve_commit_revision(&root, revision)?;
        if !selected.insert(hash.clone()) {
            result.block("duplicate_commits", "Select distinct commits to squash");
        }
        match chain.iter().position(|candidate| candidate == &hash) {
            Some(index) => indices.push(index),
            None => result.block("outside_rewrite_range", "Select commits on the current branch first-parent history within the latest 1000 commits"),
        }
    }
    indices.sort_unstable();
    indices.dedup();
    let Some(oldest) = indices.last().copied() else {
        return Ok(result);
    };
    if oldest >= MAX_REWRITE_COMMITS {
        result.block(
            "rewrite_range_too_large",
            "At most 1000 commits can be rewritten in one operation",
        );
        return Ok(result);
    }
    if request.operation == "squashCommits" && oldest - indices[0] + 1 != indices.len() {
        result.block(
            "non_contiguous_commits",
            "Only a contiguous range of commits can be squashed",
        );
    }
    if request.operation == "undoCommit"
        && (selected.len() != 1 || !selected.contains(head.stdout.trim()))
    {
        result.block("not_head", "Only the current branch HEAD can be undone");
    }
    let affected = if request.operation == "undoCommit" {
        &chain[..1]
    } else {
        &chain[..=oldest]
    };
    // A remote containing any later commit in this first-parent range must
    // also contain its oldest commit. Avoid materializing all remote history.
    let remote_contains_range = !checked_output(
        &root,
        &[
            "for-each-ref",
            "--count=1",
            "--format=%(refname)",
            "--contains",
            affected.last().expect("the affected range is nonempty"),
            "refs/remotes/",
        ],
    )?
    .is_empty();
    if remote_contains_range {
        result.block(
            "published_history",
            "Commits published to a remote cannot be rewritten",
        );
    }
    for hash in affected.iter().rev() {
        crate::protocol::cancellation::check()?;
        let commit = read_rewrite_commit(&root, hash)?;
        let raw_commit = checked_output(&root, &["cat-file", "commit", hash])?;
        let raw_commit = std::str::from_utf8(&raw_commit);
        if raw_commit.is_err() {
            result.block(
                "unsupported_commit_encoding",
                "History rewriting requires UTF-8 commit messages",
            );
        }
        let signed = raw_commit.ok().is_some_and(|raw| {
            raw.split("\n\n")
                .next()
                .unwrap_or_default()
                .lines()
                .any(|line| line.starts_with("gpgsig ") || line.starts_with("gpgsig-sha256 "))
        });
        if request.operation != "undoCommit" && signed {
            result.block(
                "signed_commit",
                "Signed commits cannot be rewritten without a supported re-signing policy",
            );
        }
        if commit.parents.len() > 1 {
            result.block(
                "merge_commit",
                "A history range containing merge commits cannot be rewritten",
            );
        }
        if commit.parents.is_empty()
            && matches!(
                request.operation.as_str(),
                "undoCommit" | "deleteCommit" | "interactiveRebase"
            )
            && selected.contains(hash)
        {
            result.block(
                "root_commit",
                "This operation requires a commit with one parent",
            );
        }
        let projected = GitHistoryRewriteCommit {
            hash: hash.clone(),
            parents: commit.parents,
            message: commit.message,
        };
        if selected.contains(hash) {
            result.selected_commits.push(projected.clone());
        }
        result.affected_commits.push(projected);
    }
    result.suggested_message = if request.operation == "squashCommits" {
        result
            .selected_commits
            .iter()
            .map(|commit| commit.message.trim_end_matches('\n'))
            .collect::<Vec<_>>()
            .join("\n\n")
    } else {
        result
            .selected_commits
            .first()
            .map(|commit| commit.message.clone())
            .unwrap_or_default()
    };
    let final_snapshot = snapshot(&root)?;
    if initial_snapshot != final_snapshot {
        result.block(
            "stale_preview",
            "Git history changed while preparing the preview; refresh and try again",
        );
    }
    result.allowed = result.blockers.is_empty();
    if result.allowed {
        let revisions = result
            .selected_commits
            .iter()
            .map(|commit| commit.hash.clone())
            .collect::<Vec<_>>();
        result.expected_state = Some(GitHistoryRewriteExpectation {
            branch: result
                .branch
                .clone()
                .expect("an eligible preview has a branch"),
            head: result.head.clone().expect("an eligible preview has a HEAD"),
            state_token: selection_token(&final_snapshot, &request.operation, &revisions),
            operation: request.operation,
            revisions,
        });
    }
    Ok(result)
}

fn validate_selection(operation: &str, revisions: &[String]) -> Result<(), CoreError> {
    if !matches!(
        operation,
        "undoCommit" | "editCommitMessage" | "squashCommits" | "deleteCommit" | "interactiveRebase"
    ) {
        return Err(invalid("Unsupported history rewrite operation"));
    }
    if (operation == "squashCommits" && revisions.len() < 2)
        || (operation != "squashCommits" && revisions.len() != 1)
        || revisions.len() > MAX_REWRITE_COMMITS
    {
        return Err(invalid(
            "Select one commit, or at least two commits to squash (maximum 1000)",
        ));
    }
    for revision in revisions {
        validate_revision(revision)?;
    }
    Ok(())
}

fn invalid(message: &str) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, message)
}

fn checked_output(root: &str, arguments: &[&str]) -> Result<Vec<u8>, CoreError> {
    let arguments = arguments
        .iter()
        .map(|argument| argument.to_string())
        .collect::<Vec<_>>();
    let output = capture_git_with_options(root, &arguments, None, true)?;
    if output.exit_code != 0 {
        return Err(CoreError::new(
            ErrorCode::ProcessFailed,
            "Could not inspect Git history state",
        )
        .with_details(String::from_utf8_lossy(&output.stderr)));
    }
    Ok(output.stdout)
}

fn snapshot_io_error(error: std::io::Error) -> CoreError {
    CoreError::new(ErrorCode::ProcessFailed, "Could not read Git history state")
        .with_details(error.to_string())
}

/// Adds length prefixes so different byte sequences cannot share a concatenated snapshot.
fn hash_part(hasher: &mut Sha256, bytes: &[u8]) {
    hasher.update((bytes.len() as u64).to_le_bytes());
    hasher.update(bytes);
}

fn workspace_snapshot(root: &str) -> Result<String, CoreError> {
    let mut hasher = Sha256::new();
    let index_path = git_path(root, "index")?;
    match fs::read(index_path) {
        Ok(index) => hash_part(&mut hasher, &index),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => hash_part(&mut hasher, &[]),
        Err(error) => return Err(snapshot_io_error(error)),
    }
    // This comparison is against the unchanged index, independent of a moved HEAD.
    hash_part(
        &mut hasher,
        &checked_output(
            root,
            &[
                "-c",
                "diff.relative=false",
                "diff",
                "--binary",
                "--no-color",
                "--src-prefix=a/",
                "--dst-prefix=b/",
                "--no-renames",
                "--no-ext-diff",
                "--no-textconv",
                "--ignore-submodules=none",
                "--",
            ],
        )?,
    );
    let untracked = checked_output(root, &["ls-files", "--others", "--exclude-standard", "-z"])?;
    hash_part(&mut hasher, &untracked);
    for path in untracked
        .split(|byte| *byte == 0)
        .filter(|path| !path.is_empty())
    {
        crate::protocol::cancellation::check()?;
        #[cfg(unix)]
        let relative = {
            use std::os::unix::ffi::OsStrExt;
            Path::new(std::ffi::OsStr::from_bytes(path))
        };
        #[cfg(not(unix))]
        let relative = Path::new(
            std::str::from_utf8(path).map_err(|_| invalid("Unsupported Git path encoding"))?,
        );
        let file_path = Path::new(root).join(relative);
        let metadata = fs::symlink_metadata(&file_path).map_err(snapshot_io_error)?;
        if metadata.file_type().is_symlink() {
            let target = fs::read_link(&file_path).map_err(snapshot_io_error)?;
            hash_part(&mut hasher, target.as_os_str().as_encoded_bytes());
        } else if metadata.is_file() {
            let mut file = File::open(&file_path).map_err(snapshot_io_error)?;
            let mut content_hasher = Sha256::new();
            let mut buffer = [0_u8; 64 * 1024];
            loop {
                crate::protocol::cancellation::check()?;
                let count = file.read(&mut buffer).map_err(snapshot_io_error)?;
                if count == 0 {
                    break;
                }
                content_hasher.update(&buffer[..count]);
            }
            hash_part(&mut hasher, &content_hasher.finalize());
        } else {
            return Err(invalid(
                "Unsupported untracked file type in history preview",
            ));
        }
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn snapshot(root: &str) -> Result<String, CoreError> {
    let mut hasher = Sha256::new();
    hash_part(
        &mut hasher,
        repository_root(root)?.as_os_str().as_encoded_bytes(),
    );
    hash_part(
        &mut hasher,
        &checked_output(root, &["rev-parse", "--path-format=absolute", "--git-dir"])?,
    );
    hash_part(
        &mut hasher,
        &checked_output(root, &["rev-parse", "--verify", "HEAD"])?,
    );
    let branch = capture_git_with_options(
        root,
        &["symbolic-ref".into(), "--quiet".into(), "HEAD".into()],
        None,
        true,
    )?;
    hash_part(&mut hasher, &branch.stdout);
    hash_part(
        &mut hasher,
        &checked_output(
            root,
            &[
                "for-each-ref",
                "--sort=refname",
                "--format=%(refname)%00%(objectname)%00%(symref)",
                "refs/heads",
                "refs/remotes",
                "refs/tags",
            ],
        )?,
    );
    hash_part(&mut hasher, workspace_snapshot(root)?.as_bytes());
    // Sequential Git operations can appear without changing HEAD or index yet.
    let operation = operation_state(GitOperationStateRequest {
        root: root.to_string(),
    })?;
    hash_part(
        &mut hasher,
        &serde_json::to_vec(&operation)
            .map_err(|_| invalid("Could not encode Git operation state"))?,
    );
    Ok(format!("{:x}", hasher.finalize()))
}

/// Checks the current checkout against the reviewed operation and selection.
pub(super) fn validate_expected(
    root: &str,
    expected: &GitHistoryRewriteExpectation,
) -> Result<(), CoreError> {
    if selection_token(&snapshot(root)?, &expected.operation, &expected.revisions)
        != expected.state_token
    {
        return Err(invalid(
            "Git history preview is stale; refresh and try again",
        ));
    }
    Ok(())
}

fn selection_token(snapshot: &str, operation: &str, revisions: &[String]) -> String {
    let mut hasher = Sha256::new();
    hash_part(&mut hasher, snapshot.as_bytes());
    hash_part(&mut hasher, operation.as_bytes());
    for revision in revisions {
        hash_part(&mut hasher, revision.as_bytes());
    }
    format!("{:x}", hasher.finalize())
}

/// Persists the old OID and attributable reflog before any branch mutation.
pub(super) fn create_recovery(
    root: &str,
    head: &str,
    branch: &str,
    operation: &str,
) -> Result<String, CoreError> {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| invalid("Could not timestamp the history recovery point"))?
        .as_millis();
    let sequence = RECOVERY_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let reference = format!(
        "{RECOVERY_PREFIX}{timestamp:020}-{}-{sequence}",
        std::process::id()
    );
    // The reflog is persisted with the ref, so recovery remains attributable
    // after a crash before the platform receives the mutation result.
    let description =
        serde_json::json!({"operation":operation,"branch":branch,"originalHead":head}).to_string();
    let response = execute_git(
        root,
        &[
            "update-ref".into(),
            "--create-reflog".into(),
            "-m".into(),
            format!("lithe history recovery: {description}"),
            reference.clone(),
            head.into(),
            "0".repeat(head.len()),
        ],
        None,
    )?;
    if response.exit_code != 0 {
        return Err(CoreError::new(
            ErrorCode::ProcessFailed,
            "Could not preserve history before rewriting",
        )
        .with_details(response.output));
    }
    Ok(reference)
}

/// Bounds retained recovery refs independently of ordinary branch and tag lists.
pub(super) fn prune_recoveries(root: &str) -> Result<(), CoreError> {
    let refs = checked_output(
        root,
        &[
            "for-each-ref",
            "--sort=-refname",
            "--format=%(refname) %(objectname)",
            RECOVERY_PREFIX,
        ],
    )?;
    let refs = std::str::from_utf8(&refs).map_err(|_| invalid("Invalid recovery reference"))?;
    for reference in refs.lines().skip(MAX_RECOVERY_REFERENCES) {
        if let Some((name, oid)) = reference.split_once(' ') {
            let deleted = execute_git(
                root,
                &["update-ref".into(), "-d".into(), name.into(), oid.into()],
                None,
            )?;
            if deleted.exit_code != 0 {
                return Err(CoreError::new(
                    ErrorCode::ProcessFailed,
                    "Could not expire an older history recovery point",
                )
                .with_details(deleted.output));
            }
        }
    }
    Ok(())
}

/// Executes only a freshly reviewed action, preserving an old-history ref before mutation.
pub(super) fn execute(
    root: &str,
    request: &GitWriteRequest,
) -> Result<GitCommandResponse, CoreError> {
    let root = repository_root(root)?.to_string_lossy().into_owned();
    let root = root.as_str();
    let revisions = if request.operation == "squashCommits" {
        request.revisions.clone()
    } else {
        vec![validated_revision(request.revision.as_deref())?]
    };
    let preview = history_rewrite_preview(GitHistoryRewritePreviewRequest {
        root: root.to_string(),
        operation: request.operation.clone(),
        revisions,
    })?;
    if let Some(blocker) = preview.blockers.first() {
        return Err(invalid(&blocker.message).with_details(&blocker.code));
    }
    let expected = request
        .expected_state
        .as_ref()
        .ok_or_else(|| invalid("Review a Git history preview before executing this operation"))?;
    if preview.expected_state.as_ref() != Some(expected) {
        return Err(invalid(
            "Git history preview is stale; refresh and try again",
        ));
    }
    let message = if matches!(
        request.operation.as_str(),
        "editCommitMessage" | "squashCommits"
    ) {
        request
            .message
            .as_deref()
            .filter(|message| !message.trim().is_empty() && !message.contains('\0'))
            .ok_or_else(|| invalid("Missing or invalid Git commit message"))?
    } else {
        ""
    };
    let original_workspace = workspace_snapshot(root)?;
    let context = HistoryRewriteContext {
        branch_reference: expected.branch.clone(),
        original_head: expected.head.clone(),
        first_parent_chain: preview
            .affected_commits
            .iter()
            .rev()
            .map(|commit| commit.hash.clone())
            .collect(),
        // The immutable preview checked remote reachability for the entire range.
        published_commits: HashSet::new(),
    };
    validate_expected(root, expected)?;
    let recovery_reference =
        create_recovery(root, &expected.head, &expected.branch, &request.operation)?;
    let mut record = GitHistoryRewriteResult {
        operation: request.operation.clone(),
        branch: expected.branch.clone(),
        original_head: expected.head.clone(),
        new_head: None,
        recovery_reference,
        mutation_applied: false,
        outcome_known: true,
        worktree_refresh: "notNeeded".into(),
    };
    if let Err(error) = prune_recoveries(root) {
        return Ok(failed_with_recovery(error, record));
    }
    let prepared = match request.operation.as_str() {
        "undoCommit" => Ok(preview.selected_commits[0].parents[0].clone()),
        "editCommitMessage" => edited_history_head(root, &context, &expected.revisions[0], message),
        "deleteCommit" => deleted_history_head(root, &context, &expected.revisions[0]),
        "squashCommits" => squashed_history_head(root, &context, &expected.revisions, message),
        _ => unreachable!("preview validates the supported operations"),
    };
    let new_head = match prepared {
        Ok(head) => head,
        Err(error) => return Ok(failed_with_recovery(error, record)),
    };
    record.new_head = Some(new_head.clone());
    if let Err(error) = validate_expected(root, expected) {
        return Ok(failed_with_recovery(error, record));
    }
    let mutation = update_history_reference(
        root,
        &context,
        &new_head,
        &format!("lithe: {}", request.operation),
    );
    let mut response = match mutation {
        Ok(response) if response.exit_code == 0 => {
            record.mutation_applied = true;
            response
        }
        result => {
            let mut response = match result {
                Ok(response) => response,
                Err(error) => failed_git_result(error),
            };
            // Cancellation can race Git's successful ref write. Probe with a short,
            // independent cleanup deadline before describing the mutation as absent.
            let observed = crate::protocol::cancellation::with_cleanup_deadline(
                Duration::from_secs(2),
                || checked_output(root, &["rev-parse", "--verify", &expected.branch]),
            );
            match observed {
                Ok(oid) => {
                    let oid = String::from_utf8_lossy(&oid);
                    record.mutation_applied = oid.trim() == new_head;
                    record.outcome_known = record.mutation_applied || oid.trim() == expected.head;
                }
                Err(_) => record.outcome_known = false,
            }
            if !record.outcome_known || record.mutation_applied {
                response.warnings.push(GitOperationWarning::new(
                    "history_rewrite_interrupted",
                    "The operation was interrupted after a possible history change; inspect the recovery point before retrying",
                    None,
                ));
            }
            response.history_rewrite = Some(record);
            return Ok(response);
        }
    };
    if request.operation == "deleteCommit" {
        let refreshed = (|| {
            let branch = checked_output(root, &["symbolic-ref", "--quiet", "HEAD"])?;
            let head = checked_output(root, &["rev-parse", "--verify", "HEAD"])?;
            if String::from_utf8_lossy(&branch).trim() != expected.branch
                || String::from_utf8_lossy(&head).trim() != new_head
                || workspace_snapshot(root)? != original_workspace
            {
                return Err(invalid(
                    "The checkout changed after the history update; working files were preserved",
                ));
            }
            // A two-tree checkout refresh cannot move a different branch if another
            // writer changes symbolic HEAD after the identity check above.
            let result = execute_git(
                root,
                &[
                    "read-tree".into(),
                    "-u".into(),
                    "-m".into(),
                    expected.head.clone(),
                    new_head.clone(),
                ],
                None,
            )?;
            if result.exit_code != 0 {
                return Err(CoreError::new(
                    ErrorCode::ProcessFailed,
                    "Could not refresh the working tree after deleting a commit",
                )
                .with_details(result.output));
            }
            Ok(())
        })();
        match refreshed {
            Ok(()) => record.worktree_refresh = "ready".into(),
            Err(error) => {
                record.worktree_refresh = "failed".into();
                response.warnings.push(GitOperationWarning::new(
                    "git_worktree_refresh_failed",
                    "The commit was deleted, but the working tree could not be refreshed",
                    Some(error.message),
                ));
            }
        }
    }
    if let Err(error) = prune_recoveries(root) {
        response.warnings.push(GitOperationWarning::new(
            "history_recovery_cleanup_failed",
            "History changed successfully, but older recovery points could not be expired",
            Some(error.message),
        ));
    }
    response.history_rewrite = Some(record);
    Ok(response)
}

fn failed_with_recovery(error: CoreError, record: GitHistoryRewriteResult) -> GitCommandResponse {
    let mut response = failed_git_result(error);
    response.history_rewrite = Some(record);
    response
}
