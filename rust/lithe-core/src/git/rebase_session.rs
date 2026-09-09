//! Reviewed local interactive rebases backed by Git's native, restartable sequencer.

use super::rewrite::{GitHistoryRewriteBlocker, GitHistoryRewriteCommit, RewriteLease};
use super::*;
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, OpenOptions};

const SESSION_DIRECTORY: &str = "lithe-rebase-session";
const SESSION_MANIFEST: &str = "session.json";
const SESSION_MARKER: &str = "lithe-session-id";
const MAX_MESSAGE_BYTES: usize = 8 * 1024 * 1024;
const MAX_SESSION_STEPS: usize = 1_000;
const MAX_MANIFEST_BYTES: u64 = (MAX_MESSAGE_BYTES + 1024 * 1024) as u64;
const FIXED_CONFIG: &[&str] = &[
    "rebase.updateRefs=false",
    "rebase.autoSquash=false",
    "rebase.autoStash=false",
    "rebase.abbreviateCommands=false",
    "rebase.missingCommitsCheck=error",
    "rebase.instructionFormat=%s",
    "commit.cleanup=verbatim",
];

// Git invokes editors through its platform shell. These templates contain no
// caller-supplied shell text: paths travel in the environment and messages in
// files. The todo contains only validated actions and complete hexadecimal OIDs.
const SEQUENCE_EDITOR: &str = r#"sh -c 'set -eu; native="$LITHE_REBASE_DIR/rebase-merge"; test "$(cat "$native/orig-head")" = "$LITHE_REBASE_ORIGINAL_HEAD"; test "$(cat "$native/head-name")" = "$LITHE_REBASE_BRANCH"; test "$(cat "$native/onto")" = "$LITHE_REBASE_BASE"; cp -- "$LITHE_REBASE_TODO" "$1"; printf "%s\n" "$LITHE_REBASE_ID" > "$native/lithe-session-id"' -"#;
const MESSAGE_EDITOR: &str = r#"sh -c 'set -eu; target=$1; row=$(tail -n 1 "$LITHE_REBASE_DIR/rebase-merge/done"); set -- $row; test "$#" -eq 2; action=$1; oid=$2; case "$action" in pick|reword|edit|squash|fixup) ;; *) exit 1;; esac; case "$oid" in *[!0-9a-f]*|"") exit 1;; esac; case ${#oid} in 40|64) ;; *) exit 1;; esac; cp -- "$LITHE_REBASE_MESSAGES/$oid" "$target"' -"#;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Unchanged base commit; only its successors through HEAD are rewritten.
pub struct GitRebasePreviewRequest {
    pub root: String,
    pub revision: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
/// Authoritative complete range before the user changes its order and actions.
pub struct GitRebasePreviewResponse {
    pub allowed: bool,
    pub blockers: Vec<GitHistoryRewriteBlocker>,
    pub branch: Option<String>,
    pub head: Option<String>,
    /// Fixed parent of the oldest selected commit; root rebases are unsupported.
    pub base: Option<String>,
    pub commits: Vec<GitHistoryRewriteCommit>,
    pub expected_state: Option<GitHistoryRewriteExpectation>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
/// One native sequencer action; no arbitrary exec or todo text is accepted.
pub struct GitRebaseStep {
    pub hash: String,
    /// `pick`, `reword`, `edit`, `squash`, `fixup`, or `drop`.
    pub action: String,
    /// Required for reword; optional final combined message for squash.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Complete reviewed range, with each commit represented exactly once.
pub struct GitRebaseStartRequest {
    pub root: String,
    pub expected_state: GitHistoryRewriteExpectation,
    pub steps: Vec<GitRebaseStep>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Query the last Lithe-owned session in this checkout's Git directory.
pub struct GitRebaseSessionRequest {
    pub root: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Resume an identified session, keeping process cancellation separate from abort.
pub struct GitRebaseControlRequest {
    pub root: String,
    pub session_id: String,
    /// `continue`, `skip`, or `abort`.
    pub action: String,
    /// At an edit pause only: amend HEAD with staged content and this full message.
    pub amend_message: Option<String>,
    /// HEAD reviewed by the amendment editor; required whenever amend_message is present.
    pub expected_head: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Restart-safe presentation of a native rebase, including successful edit pauses.
pub struct GitRebaseSessionResponse {
    pub session_id: String,
    /// `starting`, `conflict`, `edit`, `paused`, `completed`, `aborted`, `failed`, or `interrupted`.
    pub status: String,
    pub branch: String,
    pub original_head: String,
    pub head: Option<String>,
    pub recovery_reference: String,
    pub steps: Vec<GitRebaseStep>,
    /// Native done entries; the last entry may currently be paused or conflicted.
    pub completed_steps: usize,
    pub current_commit: Option<String>,
    /// Complete current HEAD message at an edit pause, including after restart.
    pub current_message: Option<String>,
    pub conflicted_paths: Vec<String>,
    pub can_continue: bool,
    pub can_skip: bool,
    pub can_abort: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
/// Process diagnostics plus the session state that determines completion or pause.
pub struct GitRebaseMutationResponse {
    pub command: GitCommandResponse,
    pub session: GitRebaseSessionResponse,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct SessionRecord {
    session_id: String,
    branch: String,
    original_head: String,
    base: String,
    recovery_reference: String,
    steps: Vec<GitRebaseStep>,
    // Persist only observations made after an owned Git process. A restart
    // with no matching native metadata must never guess that mutation completed.
    status: String,
}

fn invalid(message: &str) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, message)
}

fn io_error(error: std::io::Error) -> CoreError {
    CoreError::new(
        ErrorCode::ProcessFailed,
        "Could not persist the Git rebase session",
    )
    .with_details(error.to_string())
}

fn normalized_root(root: &str) -> Result<String, CoreError> {
    Ok(repository_root(&validate_root(root)?)?
        .to_string_lossy()
        .into_owned())
}

fn metadata_directory(root: &str) -> Result<PathBuf, CoreError> {
    git_directory(root)?.ok_or_else(|| invalid("Git metadata is unavailable"))
}

fn configured_arguments(arguments: &[&str]) -> Vec<String> {
    FIXED_CONFIG
        .iter()
        .flat_map(|value| ["-c", *value])
        .chain(arguments.iter().copied())
        .map(str::to_string)
        .collect()
}

fn session_directory(root: &str) -> Result<PathBuf, CoreError> {
    let directory = metadata_directory(root)?.join(SESSION_DIRECTORY);
    match fs::symlink_metadata(&directory) {
        Ok(metadata) if !metadata.is_dir() || metadata.file_type().is_symlink() => {
            Err(invalid("The Git rebase session directory is unsafe"))
        }
        Ok(_) => Ok(directory),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(directory),
        Err(error) => Err(io_error(error)),
    }
}

/// Reuses the guarded history range while reserving native rebase semantics.
pub fn preview(request: GitRebasePreviewRequest) -> Result<GitRebasePreviewResponse, CoreError> {
    let root = normalized_root(&request.root)?;
    let base = resolve_commit_revision(&root, &request.revision)?;
    let chain = capture_git_with_options(
        &root,
        &[
            "rev-list".into(),
            "--first-parent".into(),
            "--max-count=1001".into(),
            "HEAD".into(),
        ],
        None,
        true,
    )?;
    let chain_text = String::from_utf8_lossy(&chain.stdout);
    let chain = chain_text.lines().collect::<Vec<_>>();
    let position = chain.iter().position(|hash| *hash == base);
    let first = position
        .filter(|position| *position > 0)
        .and_then(|position| chain.get(position - 1));
    let Some(first) = first else {
        let branch = capture_git_with_options(
            &root,
            &["symbolic-ref".into(), "--quiet".into(), "HEAD".into()],
            None,
            true,
        )?;
        return Ok(GitRebasePreviewResponse {
            allowed: false,
            blockers: vec![GitHistoryRewriteBlocker {
                code: if position == Some(0) { "empty_rebase_range" } else { "outside_rewrite_range" }.into(),
                message: if position == Some(0) { "Select an earlier base commit; HEAD has no commits after it" } else { "Select a base on the current first-parent history with at most 1000 later commits" }.into(),
            }],
            branch: (branch.exit_code == 0).then(|| String::from_utf8_lossy(&branch.stdout).trim().to_string()),
            head: chain.first().map(|hash| (*hash).to_string()), base: Some(base), commits: Vec::new(), expected_state: None,
        });
    };
    let mut history = history_rewrite_preview(GitHistoryRewritePreviewRequest {
        root: root.clone(),
        operation: "interactiveRebase".into(),
        revisions: vec![(*first).into()],
    })?;
    let version = capture_git_with_options(&root, &["--version".into()], None, true)?;
    let supported = String::from_utf8_lossy(&version.stdout)
        .split_whitespace()
        .nth(2)
        .and_then(|version| {
            let mut parts = version.split('.');
            Some((
                parts.next()?.parse::<u32>().ok()?,
                parts.next()?.parse::<u32>().ok()?,
            ))
        })
        .is_some_and(|version| version >= (2, 38));
    if !supported {
        history.allowed = false;
        history.expected_state = None;
        history.blockers.push(GitHistoryRewriteBlocker {
            code: "unsupported_git_version".into(),
            message: "Interactive history editing requires Git 2.38 or newer".into(),
        });
    }
    Ok(GitRebasePreviewResponse {
        allowed: history.allowed,
        blockers: history.blockers,
        branch: history.branch,
        head: history.head,
        base: history
            .affected_commits
            .first()
            .and_then(|commit| commit.parents.first())
            .cloned(),
        commits: history.affected_commits,
        expected_state: history.expected_state,
    })
}

fn valid_message(message: &str) -> bool {
    !message.trim().is_empty() && !message.contains('\0') && message.len() <= MAX_MESSAGE_BYTES
}

fn planned_messages(
    steps: &[GitRebaseStep],
    commits: &[GitHistoryRewriteCommit],
) -> Result<BTreeMap<String, String>, CoreError> {
    let originals = commits
        .iter()
        .map(|commit| (commit.hash.as_str(), commit.message.as_str()))
        .collect::<BTreeMap<_, _>>();
    let mut seen = BTreeSet::new();
    let mut messages = BTreeMap::new();
    let mut combined: Option<String> = None;
    for step in steps {
        let original = originals
            .get(step.hash.as_str())
            .ok_or_else(|| invalid("Every planned commit must belong to the reviewed range"))?;
        if !seen.insert(step.hash.as_str()) {
            return Err(invalid(
                "Every reviewed commit must appear exactly once in the rebase plan",
            ));
        }
        if step
            .message
            .as_deref()
            .is_some_and(|message| !valid_message(message))
        {
            return Err(invalid(
                "A replacement commit message is empty, too large, or contains NUL",
            ));
        }
        if step.message.is_some() && !matches!(step.action.as_str(), "reword" | "squash") {
            return Err(invalid(
                "Only reword and squash plan steps accept a replacement message",
            ));
        }
        match step.action.as_str() {
            "pick" | "edit" => combined = Some((*original).to_string()),
            "reword" => {
                combined = Some(
                    step.message
                        .clone()
                        .ok_or_else(|| invalid("Reword requires a complete replacement message"))?,
                )
            }
            "squash" => {
                let previous = combined.as_ref().ok_or_else(|| {
                    invalid("Squash and fixup require an earlier surviving commit")
                })?;
                combined = Some(step.message.clone().unwrap_or_else(|| {
                    format!("{}\n\n{}", previous.trim_end_matches('\n'), original)
                }));
            }
            "fixup" => {
                if combined.is_none() {
                    return Err(invalid(
                        "Squash and fixup require an earlier surviving commit",
                    ));
                }
            }
            "drop" => {}
            _ => return Err(invalid("Unsupported interactive rebase action")),
        }
        // Git opens the final squash editor on the last squash OR fixup row.
        // Carry the combined message forward through fixups instead of losing
        // earlier reword or squash edits when the group's last row is a fixup.
        messages.insert(
            step.hash.clone(),
            combined.clone().unwrap_or_else(|| (*original).to_string()),
        );
    }
    if seen.len() != originals.len() || steps.len() != commits.len() {
        return Err(invalid(
            "Every reviewed commit must appear exactly once in the rebase plan",
        ));
    }
    if messages.values().map(String::len).sum::<usize>() > MAX_MESSAGE_BYTES {
        return Err(invalid(
            "The complete rebase plan messages exceed the supported size",
        ));
    }
    Ok(messages)
}

fn ensure_owned_file(path: &Path) -> Result<(), CoreError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if !metadata.is_file() || metadata.file_type().is_symlink() => {
            Err(invalid("Git rebase session files must be regular files"))
        }
        Ok(_) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(io_error(error)),
    }
}

fn write_file(path: &Path, bytes: &[u8]) -> Result<(), CoreError> {
    ensure_owned_file(path)?;
    let mut file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(path)
        .map_err(io_error)?;
    file.write_all(bytes).map_err(io_error)?;
    file.sync_all().map_err(io_error)
}

// Status is the only persisted field that changes during a session. Reserve
// its longest value so every accepted plan remains readable after transitions.
fn encode_record(record: &SessionRecord) -> Result<Vec<u8>, CoreError> {
    let bytes = serde_json::to_vec(record)
        .map_err(|_| invalid("Could not encode the Git rebase session"))?;
    let status_growth = "interrupted".len().saturating_sub(record.status.len());
    if bytes.len() as u64 + status_growth as u64 > MAX_MANIFEST_BYTES {
        return Err(invalid(
            "The encoded Git rebase plan is too large; shorten its messages",
        ));
    }
    Ok(bytes)
}

fn save_record(root: &str, record: &SessionRecord) -> Result<(), CoreError> {
    let bytes = encode_record(record)?;
    let directory = session_directory(root)?;
    let target = directory.join(SESSION_MANIFEST);
    ensure_owned_file(&target)?;
    let temporary = directory.join(format!("{}.tmp", record.session_id));
    write_file(&temporary, &bytes)?;
    fs::rename(temporary, target).map_err(io_error)
}

fn load_record(root: &str) -> Result<Option<SessionRecord>, CoreError> {
    let path = session_directory(root)?.join(SESSION_MANIFEST);
    ensure_owned_file(&path)?;
    if fs::metadata(&path).is_ok_and(|metadata| metadata.len() > MAX_MANIFEST_BYTES) {
        return Err(invalid("The stored Git rebase session is too large"));
    }
    match fs::read(path) {
        Ok(bytes) => {
            let record: SessionRecord = serde_json::from_slice(&bytes)
                .map_err(|_| invalid("The stored Git rebase session is invalid"))?;
            validate_record(root, &record)?;
            Ok(Some(record))
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(io_error(error)),
    }
}

fn valid_oid(hash: &str) -> bool {
    matches!(hash.len(), 40 | 64) && hash.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn validate_record(root: &str, record: &SessionRecord) -> Result<(), CoreError> {
    let invalid_record = || invalid("The stored Git rebase session is invalid");
    if record.session_id.len() != 32
        || !record
            .session_id
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit())
        || !valid_oid(&record.original_head)
        || !valid_oid(&record.base)
        || record.steps.is_empty()
        || record.steps.len() > MAX_SESSION_STEPS
        || !record
            .recovery_reference
            .starts_with(&format!("{INTERNAL_REF_PREFIX}history-recovery/"))
        || record.recovery_reference.contains(['\0', '\n', '\r', ' '])
        || !matches!(
            record.status.as_str(),
            "starting"
                | "conflict"
                | "edit"
                | "paused"
                | "completed"
                | "aborted"
                | "failed"
                | "interrupted"
        )
    {
        return Err(invalid_record());
    }
    let branch = record
        .branch
        .strip_prefix("refs/heads/")
        .ok_or_else(invalid_record)?;
    validated_branch_name(root, Some(branch)).map_err(|_| invalid_record())?;
    let mut seen = BTreeSet::new();
    let mut message_bytes = 0;
    for step in &record.steps {
        if !valid_oid(&step.hash)
            || !seen.insert(&step.hash)
            || !matches!(
                step.action.as_str(),
                "pick" | "reword" | "edit" | "squash" | "fixup" | "drop"
            )
            || (step.action == "reword" && step.message.is_none())
            || (step.message.is_some() && !matches!(step.action.as_str(), "reword" | "squash"))
        {
            return Err(invalid_record());
        }
        if let Some(message) = &step.message {
            if !valid_message(message) {
                return Err(invalid_record());
            }
            message_bytes += message.len();
        }
    }
    if message_bytes > MAX_MESSAGE_BYTES {
        return Err(invalid_record());
    }
    Ok(())
}

fn environment(root: &str, record: &SessionRecord) -> Result<Vec<(String, String)>, CoreError> {
    let metadata = metadata_directory(root)?;
    let directory = metadata.join(SESSION_DIRECTORY);
    let utf8 = |path: PathBuf| {
        let path = path
            .into_os_string()
            .into_string()
            .map_err(|_| invalid("Git rebase session paths must support UTF-8"))?;
        // Git for Windows runs editors with its MSYS shell, whose utilities
        // consume slash-separated drive paths reliably through environment vars.
        #[cfg(windows)]
        let path = path.replace('\\', "/");
        Ok::<_, CoreError>(path)
    };
    Ok(vec![
        ("GIT_SEQUENCE_EDITOR".into(), SEQUENCE_EDITOR.into()),
        ("GIT_EDITOR".into(), MESSAGE_EDITOR.into()),
        ("LITHE_REBASE_ID".into(), record.session_id.clone()),
        (
            "LITHE_REBASE_ORIGINAL_HEAD".into(),
            record.original_head.clone(),
        ),
        ("LITHE_REBASE_BRANCH".into(), record.branch.clone()),
        ("LITHE_REBASE_BASE".into(), record.base.clone()),
        ("LITHE_REBASE_DIR".into(), utf8(metadata)?),
        ("LITHE_REBASE_TODO".into(), utf8(directory.join("todo"))?),
        (
            "LITHE_REBASE_MESSAGES".into(),
            utf8(directory.join("messages"))?,
        ),
    ])
}

fn native_owned(root: &str, record: &SessionRecord) -> Result<bool, CoreError> {
    let native = metadata_directory(root)?.join("rebase-merge");
    if !native.exists() {
        return Ok(false);
    }
    let read = |name: &str| {
        fs::read_to_string(native.join(name))
            .ok()
            .map(|value| value.trim().to_string())
    };
    Ok(read(SESSION_MARKER).as_deref() == Some(&record.session_id)
        && read("orig-head").as_deref() == Some(&record.original_head)
        && read("head-name").as_deref() == Some(&record.branch)
        && read("onto").as_deref() == Some(&record.base))
}

fn parse_native_steps(path: &Path) -> Result<Vec<GitRebaseStep>, CoreError> {
    let text = match fs::read_to_string(path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(io_error(error)),
    };
    text.lines()
        .filter(|line| {
            !line.trim().is_empty() && !line.trim_start().starts_with('#') && line.trim() != "noop"
        })
        .map(|line| {
            let fields = line.split_whitespace().collect::<Vec<_>>();
            if fields.len() != 2 {
                return Err(invalid(
                    "The native rebase plan changed outside Lithe; abort or finish it externally",
                ));
            }
            Ok(GitRebaseStep {
                action: fields[0].into(),
                hash: fields[1].into(),
                message: None,
            })
        })
        .collect()
}

fn validate_native_plan(root: &str, record: &SessionRecord) -> Result<(), CoreError> {
    let native = metadata_directory(root)?.join("rebase-merge");
    let mut actual = parse_native_steps(&native.join("done"))?;
    actual.extend(parse_native_steps(&native.join("git-rebase-todo"))?);
    if actual.len() != record.steps.len()
        || actual
            .iter()
            .zip(&record.steps)
            .any(|(actual, planned)| actual.hash != planned.hash || actual.action != planned.action)
    {
        return Err(invalid(
            "The native rebase plan changed outside Lithe; abort or finish it externally",
        ));
    }
    Ok(())
}

fn project_session(
    root: &str,
    record: &SessionRecord,
) -> Result<GitRebaseSessionResponse, CoreError> {
    let owned = native_owned(root, record)?;
    let operation = operation_state(GitOperationStateRequest { root: root.into() })?;
    let native = metadata_directory(root)?.join("rebase-merge");
    let done = if owned {
        parse_native_steps(&native.join("done")).unwrap_or_default()
    } else {
        Vec::new()
    };
    let status = if owned {
        if !operation.conflicted_paths.is_empty() {
            "conflict"
        } else if native.join("amend").exists()
            && done.last().is_some_and(|step| step.action == "edit")
        {
            "edit"
        } else {
            "paused"
        }
    } else if matches!(record.status.as_str(), "completed" | "aborted" | "failed") {
        &record.status
    } else {
        "interrupted"
    };
    let head = capture_git_with_options(
        root,
        &["rev-parse".into(), "--verify".into(), "HEAD".into()],
        None,
        true,
    )?;
    let head_oid =
        (head.exit_code == 0).then(|| String::from_utf8_lossy(&head.stdout).trim().to_string());
    let current_message = if status == "edit" {
        head_oid
            .as_deref()
            .map(|hash| read_rewrite_commit(root, hash).map(|commit| commit.message))
            .transpose()?
    } else {
        None
    };
    Ok(GitRebaseSessionResponse {
        session_id: record.session_id.clone(),
        status: status.into(),
        branch: record.branch.clone(),
        original_head: record.original_head.clone(),
        head: head_oid,
        recovery_reference: record.recovery_reference.clone(),
        steps: record.steps.clone(),
        completed_steps: if status == "completed" {
            record.steps.len()
        } else {
            done.len()
        },
        current_commit: done.last().map(|step| step.hash.clone()),
        current_message,
        can_continue: owned
            && operation.conflicted_paths.is_empty()
            && validate_native_plan(root, record).is_ok(),
        // A successful edit stop has already created its commit. Native skip
        // would discard edits and continue, not omit that commit as the UI says.
        can_skip: owned && status == "conflict" && validate_native_plan(root, record).is_ok(),
        can_abort: owned,
        conflicted_paths: if owned {
            operation.conflicted_paths
        } else {
            Vec::new()
        },
    })
}

/// Reads durable session identity and matches it to the actual native sequencer.
pub fn session(
    request: GitRebaseSessionRequest,
) -> Result<Option<GitRebaseSessionResponse>, CoreError> {
    let root = normalized_root(&request.root)?;
    load_record(&root)?
        .map(|record| project_session(&root, &record))
        .transpose()
}

fn finish_mutation(
    root: &str,
    mut record: SessionRecord,
    mut command: GitCommandResponse,
    action: &str,
) -> Result<GitRebaseMutationResponse, CoreError> {
    command.outcome_authoritative = true;
    // Cancellation stops the request; it is never an implicit rebase --abort.
    // A separate bounded inspection reports surviving state without relaunching Git.
    let refreshed =
        crate::protocol::cancellation::with_cleanup_deadline(Duration::from_secs(2), || {
            if !native_owned(root, &record)? {
                record.status = if command.operation_error.is_some() {
                    "interrupted"
                } else if command.exit_code != 0 {
                    "failed"
                } else if action == "abort" {
                    "aborted"
                } else {
                    "completed"
                }
                .into();
            }
            let projected = project_session(root, &record)?;
            record.status = projected.status.clone();
            if let Err(error) = save_record(root, &record) {
                command.warnings.push(GitOperationWarning::new(
                    "rebase_session_persistence_failed",
                    "Git returned, but its latest session state could not be persisted",
                    Some(error.message),
                ));
            }
            Ok::<_, CoreError>(projected)
        });
    let session = match refreshed {
        Ok(session) => session,
        Err(error) => {
            command.warnings.push(GitOperationWarning::new(
                "rebase_session_inspection_failed",
                "Refresh the Git rebase session to determine its current state",
                Some(error.message),
            ));
            GitRebaseSessionResponse {
                session_id: record.session_id,
                status: "interrupted".into(),
                branch: record.branch,
                original_head: record.original_head,
                head: None,
                recovery_reference: record.recovery_reference,
                steps: record.steps,
                completed_steps: 0,
                current_commit: None,
                current_message: None,
                conflicted_paths: Vec::new(),
                can_continue: false,
                can_skip: false,
                can_abort: false,
            }
        }
    };
    Ok(GitRebaseMutationResponse { command, session })
}

/// Persists reviewed todo/messages and recovery before starting the native rebase.
pub fn start(request: GitRebaseStartRequest) -> Result<GitRebaseMutationResponse, CoreError> {
    let root = normalized_root(&request.root)?;
    let _lease = RewriteLease::acquire(&root)?;
    if request.expected_state.operation != "interactiveRebase"
        || request.expected_state.revisions.len() != 1
        || !request.expected_state.revisions.iter().all(|hash| {
            matches!(hash.len(), 40 | 64) && hash.bytes().all(|byte| byte.is_ascii_hexdigit())
        })
    {
        return Err(invalid(
            "Review a valid native rebase range before starting",
        ));
    }
    let first = request
        .expected_state
        .revisions
        .first()
        .ok_or_else(|| invalid("Review a rebase range before starting"))?;
    let revision = read_rewrite_commit(&root, first)?
        .parents
        .first()
        .cloned()
        .ok_or_else(|| invalid("The rebase range requires a parent base"))?;
    let preview = preview(GitRebasePreviewRequest {
        root: root.clone(),
        revision,
    })?;
    if !preview.allowed {
        return Err(invalid(
            &preview
                .blockers
                .first()
                .map(|blocker| blocker.message.as_str())
                .unwrap_or("This rebase range is unsupported"),
        ));
    }
    if preview.expected_state.as_ref() != Some(&request.expected_state) {
        return Err(invalid(
            "The rebase preview is stale; refresh and review it again",
        ));
    }
    let messages = planned_messages(&request.steps, &preview.commits)?;
    let recovery = rewrite::create_recovery(
        &root,
        &request.expected_state.head,
        &request.expected_state.branch,
        "interactiveRebase",
    )?;
    let record = SessionRecord {
        session_id: format!("{:032x}", rand::random::<u128>()),
        branch: request.expected_state.branch.clone(),
        original_head: request.expected_state.head.clone(),
        base: preview.base.expect("eligible rebase has a base"),
        recovery_reference: recovery,
        steps: request.steps,
        status: "starting".into(),
    };
    // Reject before replacing the previous session or starting Git. JSON
    // escaping can exceed the storage budget even when raw messages fit.
    encode_record(&record)?;
    let directory = session_directory(&root)?;
    if let Ok(metadata) = fs::symlink_metadata(&directory) {
        if !metadata.is_dir() || metadata.file_type().is_symlink() {
            return Err(invalid("The Git rebase session directory is unsafe"));
        }
        fs::remove_dir_all(&directory).map_err(io_error)?;
    }
    fs::create_dir(&directory).map_err(io_error)?;
    fs::create_dir(directory.join("messages")).map_err(io_error)?;
    let prepared = (|| {
        save_record(&root, &record)?;
        let todo = record
            .steps
            .iter()
            .map(|step| format!("{} {}\n", step.action, step.hash))
            .collect::<String>();
        write_file(&directory.join("todo"), todo.as_bytes())?;
        for (hash, message) in messages {
            write_file(&directory.join("messages").join(hash), message.as_bytes())?;
        }
        rewrite::prune_recoveries(&root)?;
        rewrite::validate_expected(&root, &request.expected_state)?;
        let arguments = configured_arguments(&[
            "rebase",
            "--interactive",
            "--no-autostash",
            "--no-update-refs",
            "--no-autosquash",
            "--no-fork-point",
            "--no-rebase-merges",
            "--reapply-cherry-picks",
            "--keep-empty",
            "--empty=keep",
            "--onto",
            &record.base,
            &record.base,
        ]);
        let environment = environment(&root, &record)?;
        with_git_invocation_trace(|| {
            execute_git_with_environment(&root, &arguments, None, false, &environment)
        })
    })();
    finish_mutation(
        &root,
        record,
        prepared.unwrap_or_else(failed_git_result),
        "start",
    )
}

/// Continues, skips, or explicitly aborts one matching persisted native session.
pub fn control(request: GitRebaseControlRequest) -> Result<GitRebaseMutationResponse, CoreError> {
    let root = normalized_root(&request.root)?;
    let _lease = RewriteLease::acquire(&root)?;
    let record =
        load_record(&root)?.ok_or_else(|| invalid("No Lithe rebase session is available"))?;
    if record.session_id != request.session_id || !native_owned(&root, &record)? {
        return Err(invalid(
            "The active Git operation does not match this Lithe rebase session",
        ));
    }
    let action = match request.action.as_str() {
        "continue" => "--continue",
        "skip" => "--skip",
        "abort" => "--abort",
        _ => return Err(invalid("Unsupported rebase session control")),
    };
    let current = project_session(&root, &record)?;
    if action == "--skip" && current.status != "conflict" {
        return Err(invalid("Only a conflicted rebase step can be skipped"));
    }
    if action != "--abort" {
        validate_native_plan(&root, &record)?;
    }
    if action == "--continue" && !current.conflicted_paths.is_empty() {
        return Err(invalid(
            "Resolve and stage conflicted files before continuing the rebase",
        ));
    }
    if request.amend_message.is_some() && (request.action != "continue" || current.status != "edit")
    {
        return Err(invalid(
            "Amend is available only when continuing an edit pause",
        ));
    }
    if request
        .amend_message
        .as_deref()
        .is_some_and(|message| !valid_message(message))
    {
        return Err(invalid(
            "The amended commit message is empty, too large, or contains NUL",
        ));
    }
    if action == "--continue" && current.status == "edit" && request.amend_message.is_none() {
        // Native --continue can implicitly amend an edit stop with staged
        // changes. The GUI promises an explicit amendment decision instead.
        let staged = capture_git_with_options(
            &root,
            &[
                "diff".into(),
                "--cached".into(),
                "--quiet".into(),
                "--no-ext-diff".into(),
                "--no-textconv".into(),
                "HEAD".into(),
                "--".into(),
            ],
            None,
            true,
        )?;
        if staged.exit_code == 1 {
            return Err(invalid(
                "Amend the staged changes explicitly before continuing this edit pause",
            ));
        }
        if staged.exit_code != 0 {
            return Err(CoreError::new(
                ErrorCode::ProcessFailed,
                "Could not inspect staged changes at the edit pause",
            ));
        }
    }
    if request.amend_message.is_some()
        && (request.expected_head.is_none() || request.expected_head != current.head)
    {
        return Err(invalid(
            "The edit HEAD changed; refresh and review the amendment again",
        ));
    }
    let environment = environment(&root, &record)?;
    let mutation = with_git_invocation_trace(|| {
        if let Some(message) = request.amend_message {
            let amended = execute_git_with_environment(
                &root,
                &configured_arguments(&["commit", "--amend", "--allow-empty", "--file=-"]),
                Some(message),
                false,
                &environment,
            )?;
            if amended.exit_code != 0 {
                return Ok(amended);
            }
        }
        if (action == "--continue" && current.status == "edit") || action == "--skip" {
            // A skipped conflict must not leave its message in a later squash.
            // HEAD still contains the preceding successful commit at this point.
            refresh_continuation_group_messages(
                &root,
                &record,
                current.current_commit.as_deref(),
                action == "--skip",
            )?;
        }
        execute_git_with_environment(
            &root,
            &configured_arguments(&["rebase", action]),
            None,
            false,
            &environment,
        )
    });
    finish_mutation(
        &root,
        record,
        mutation.unwrap_or_else(failed_git_result),
        &request.action,
    )
}

fn refresh_continuation_group_messages(
    root: &str,
    record: &SessionRecord,
    current_commit: Option<&str>,
    skipping: bool,
) -> Result<(), CoreError> {
    let current_commit =
        current_commit.ok_or_else(|| invalid("The rebase pause has no current commit"))?;
    let index = record
        .steps
        .iter()
        .position(|step| step.hash == current_commit)
        .ok_or_else(|| invalid("The rebase pause no longer belongs to this rebase plan"))?;
    let directory = session_directory(root)?.join("messages");
    let previous = record.steps[..index]
        .iter()
        .rev()
        .find(|step| step.action != "drop");
    let mut combined = if skipping
        && previous.is_some_and(|step| matches!(step.action.as_str(), "squash" | "fixup"))
    {
        // Git's intermediate squash HEAD contains generated comment scaffolding.
        // The persisted message holds the reviewed logical group without that
        // scaffolding, including edits refreshed during earlier continuations.
        let path = directory.join(&previous.expect("a preceding squash group exists").hash);
        ensure_owned_file(&path)?;
        fs::read_to_string(path).map_err(io_error)?
    } else {
        read_rewrite_commit(root, "HEAD")?.message
    };
    write_file(&directory.join(current_commit), combined.as_bytes())?;
    for step in &record.steps[index + 1..] {
        match step.action.as_str() {
            "squash" => {
                combined = match &step.message {
                    Some(message) => message.clone(),
                    None => format!(
                        "{}\n\n{}",
                        combined.trim_end_matches('\n'),
                        read_rewrite_commit(root, &step.hash)?.message
                    ),
                };
            }
            "fixup" => {}
            "drop" => continue,
            _ => break,
        }
        if combined.len() > MAX_MESSAGE_BYTES {
            return Err(invalid(
                "The combined rebase message exceeds the supported size",
            ));
        }
        write_file(&directory.join(&step.hash), combined.as_bytes())?;
    }
    Ok(())
}

/// Restores the editor environment when legacy operation banners control an owned rebase.
pub(super) fn resolve_owned_operation(
    root: &str,
    operation: &str,
) -> Result<Option<GitCommandResponse>, CoreError> {
    let Some(record) = load_record(root)? else {
        return Ok(None);
    };
    if !native_owned(root, &record)? {
        return Ok(None);
    }
    let action = match operation {
        "operationContinue" => "continue",
        "operationAbort" => "abort",
        _ => "skip",
    };
    control(GitRebaseControlRequest {
        root: root.into(),
        session_id: record.session_id,
        action: action.into(),
        amend_message: None,
        expected_head: None,
    })
    .map(|response| Some(response.command))
}
