//! Bounded Git reference snapshots and incrementally consumable history pages.

use super::{
    command_value, execute_git_with_environment, git_process, parse_commit, parse_reference,
    readonly_command, validate_root, GitCommandRequest,
};
use crate::protocol::{
    cancellation, CoreError, ErrorCode, GitCommitResponse, GitHistoryCursorCloseResponse,
    GitHistoryPageResponse, GitHistoryResponse, GitReferenceResponse, GitReferencesResponse,
};
use serde::Deserialize;
use std::io::{BufRead, BufReader, Read};
use std::process::{Child, ExitStatus, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, SyncSender};
use std::sync::{Mutex, OnceLock};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

const DEFAULT_HISTORY_LIMIT: usize = 300;
const MAX_HISTORY_COMMITS: usize = 5_000;
const RECENT_BRANCH_LIMIT: usize = 5;
const RECENT_BRANCH_REFLOG_LIMIT: &str = "100";
const DEFAULT_BRANCH_FALLBACKS: [&str; 2] = ["main", "master"];
const HISTORY_CURSOR_IDLE_TTL: Duration = Duration::from_secs(120);
const HISTORY_CURSOR_REAPER_INTERVAL: Duration = Duration::from_secs(1);
const HISTORY_PAGE_DEADLINE: Duration = Duration::from_secs(30);
const HISTORY_STREAM_POLL_INTERVAL: Duration = Duration::from_millis(10);
const MAX_HISTORY_SESSIONS: usize = 8;

static HISTORY_SESSIONS: OnceLock<Mutex<HistorySessionRegistry>> = OnceLock::new();
static HISTORY_REAPER: OnceLock<()> = OnceLock::new();
static NEXT_HISTORY_CURSOR: AtomicU64 = AtomicU64::new(1);

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Backward-compatible request for references and the first bounded history page.
pub struct GitHistoryRequest {
    pub root: String,
    #[serde(default)]
    pub reference: Option<String>,
    #[serde(default = "default_history_limit")]
    pub limit: usize,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request for repository references and identity metadata.
pub struct GitReferencesRequest {
    pub root: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request for one bounded page of commit history from an optional reference.
pub struct GitHistoryPageRequest {
    pub root: String,
    #[serde(default)]
    pub reference: Option<String>,
    #[serde(default)]
    pub cursor: Option<String>,
    /// Deprecated compatibility field; new callers omit it and continue with `cursor`.
    #[serde(default)]
    pub offset: Option<usize>,
    #[serde(default = "default_history_limit")]
    pub limit: usize,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request to release an incremental history cursor that will not be consumed further.
pub struct GitHistoryCursorCloseRequest {
    pub root: String,
    pub cursor: String,
}

fn default_history_limit() -> usize {
    DEFAULT_HISTORY_LIMIT
}

/// Returns the legacy combined history snapshot while newer clients migrate to pages.
pub fn history(request: GitHistoryRequest) -> Result<GitHistoryResponse, CoreError> {
    let references = references(GitReferencesRequest {
        root: request.root.clone(),
    })?;
    let page = history_page(GitHistoryPageRequest {
        root: request.root.clone(),
        reference: request.reference,
        cursor: None,
        offset: None,
        limit: request.limit,
    })?;
    if let Some(cursor) = page.next_cursor.as_deref() {
        let _ = close_history_cursor(GitHistoryCursorCloseRequest {
            root: request.root,
            cursor: cursor.to_string(),
        });
    }
    Ok(GitHistoryResponse {
        references: references.references,
        recent_references: references.recent_references,
        commits: page.commits,
        has_more: page.has_more,
        user_name: references.user_name,
        user_email: references.user_email,
    })
}

/// Returns references separately so paging and branch selection do not rescan them.
pub fn references(request: GitReferencesRequest) -> Result<GitReferencesResponse, CoreError> {
    let root = validate_root(&request.root)?;
    let user_name = git_config_value(&root, "user.name");
    let user_email = git_config_value(&root, "user.email");
    let reference_arguments = vec![
        "for-each-ref".to_string(),
        "--sort=refname".to_string(),
        "--format=%(refname)\t%(refname:short)\t%(HEAD)\t%(upstream:short)\t%(upstream)\t%(upstream:track,nobracket)\t%(objecttype)\t%(*objecttype)"
            .to_string(),
        "refs/heads".to_string(),
    ];
    // `upstream:track` is evaluated independently for each local branch. A fixed
    // locale keeps its machine-parsed ahead/behind labels deterministic.
    let reference_output = execute_git_with_environment(
        &root,
        &reference_arguments,
        None,
        true,
        &[("LC_ALL".to_string(), "C".to_string())],
    )?;
    if reference_output.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Git references failed")
                .with_details(reference_output.output),
        );
    }

    let mut references = reference_output
        .output
        .lines()
        .filter_map(parse_reference)
        .collect::<Vec<_>>();
    let nonlocal_reference_output = readonly_command(GitCommandRequest {
        root: root.clone(),
        arguments: vec![
            "for-each-ref".to_string(),
            "--sort=refname".to_string(),
            "--format=%(refname)\t%(refname:short)\t%(HEAD)\t%(upstream:short)\t%(upstream)\t%(upstream:track,nobracket)\t%(objecttype)\t%(*objecttype)"
                .to_string(),
            "refs/remotes".to_string(),
            "refs/tags".to_string(),
        ],
        input: None,
    })?;
    if nonlocal_reference_output.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Git references failed")
                .with_details(nonlocal_reference_output.output),
        );
    }
    references.extend(
        nonlocal_reference_output
            .output
            .lines()
            .filter_map(parse_reference),
    );
    let recent_references = recent_local_references(&root, &references, RECENT_BRANCH_LIMIT);
    Ok(GitReferencesResponse {
        references,
        recent_references,
        user_name,
        user_email,
    })
}

/// Returns the next page from one bounded Git log stream.
pub fn history_page(request: GitHistoryPageRequest) -> Result<GitHistoryPageResponse, CoreError> {
    if request.cursor.is_some() && request.offset.is_some() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Git history page cannot combine cursor and offset",
        ));
    }
    if let Some(offset) = request.offset {
        return offset_history_page(request.root, request.reference, offset, request.limit);
    }
    let root = validate_root(&request.root)?;
    validate_reference(request.reference.as_deref())?;
    cleanup_expired_history_sessions();

    let (mut session, lease) = if let Some(cursor) = request.cursor.as_deref() {
        take_history_session(cursor)?.ok_or_else(|| invalid_history_cursor(cursor))?
    } else {
        let lease = reserve_history_session_slot()?;
        let session = HistorySession::start(root.clone(), request.reference.clone())?;
        (session, lease)
    };
    if session.root != root || session.reference != request.reference {
        let cursor = session.cursor.clone();
        lease.store(session)?;
        return Err(invalid_history_cursor(&cursor));
    }

    let limit = request.limit.clamp(
        1,
        MAX_HISTORY_COMMITS.saturating_sub(session.emitted).max(1),
    );
    let page = session.read_page(limit);
    match page {
        Ok((commits, has_more)) => {
            let next_cursor = has_more.then(|| session.cursor.clone());
            if has_more {
                session.last_access = Instant::now();
                lease.store(session)?;
            } else {
                session.stop();
            }
            Ok(GitHistoryPageResponse {
                commits,
                next_cursor,
                next_offset: None,
                has_more,
            })
        }
        Err(error) => {
            session.stop();
            Err(error)
        }
    }
}

/// Preserves the original offset contract for callers that have not migrated to cursors.
fn offset_history_page(
    root: String,
    reference: Option<String>,
    offset: usize,
    requested_limit: usize,
) -> Result<GitHistoryPageResponse, CoreError> {
    if offset >= MAX_HISTORY_COMMITS {
        return Ok(GitHistoryPageResponse {
            commits: Vec::new(),
            next_cursor: None,
            next_offset: None,
            has_more: false,
        });
    }
    validate_reference(reference.as_deref())?;
    let root = validate_root(&root)?;
    let limit = requested_limit.clamp(1, MAX_HISTORY_COMMITS - offset);
    let mut arguments = vec!["log".to_string()];
    if let Some(reference) = reference {
        arguments.push(reference);
    } else {
        arguments.push("--all".to_string());
    }
    arguments.extend([
        "--topo-order".to_string(),
        "--decorate=short".to_string(),
        "--skip".to_string(),
        offset.to_string(),
        "-n".to_string(),
        limit.saturating_add(1).to_string(),
        "--date=format:%Y/%m/%d %H:%M".to_string(),
        "--pretty=format:%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%ad%x1f%s%x1f%D".to_string(),
    ]);
    let output = readonly_command(GitCommandRequest {
        root,
        arguments,
        input: None,
    })?;
    if output.exit_code != 0 {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Git history failed")
                .with_details(output.output),
        );
    }
    let mut commits = output
        .output
        .lines()
        .filter_map(parse_commit)
        .collect::<Vec<_>>();
    let has_more = commits.len() > limit && offset.saturating_add(limit) < MAX_HISTORY_COMMITS;
    commits.truncate(limit);
    let next_offset = has_more.then_some(offset.saturating_add(commits.len()));
    Ok(GitHistoryPageResponse {
        commits,
        next_cursor: None,
        next_offset,
        has_more,
    })
}

/// Releases a cursor early so its Git child process and reader threads can terminate.
pub fn close_history_cursor(
    request: GitHistoryCursorCloseRequest,
) -> Result<GitHistoryCursorCloseResponse, CoreError> {
    let root = validate_root(&request.root)?;
    cleanup_expired_history_sessions();
    let session = {
        let mut registry = history_sessions()
            .lock()
            .map_err(history_session_lock_error)?;
        if registry
            .sessions
            .get(&request.cursor)
            .is_some_and(|session| session.root != root)
        {
            return Err(invalid_history_cursor(&request.cursor));
        }
        registry.sessions.remove(&request.cursor)
    };
    let closed = session.is_some();
    if let Some(session) = session {
        session.stop();
    }
    Ok(GitHistoryCursorCloseResponse { closed })
}

enum HistoryStreamMessage {
    Line(String),
    ReadFailed(String),
    End,
}

struct HistorySession {
    cursor: String,
    root: String,
    reference: Option<String>,
    child: Option<Child>,
    receiver: Option<Receiver<HistoryStreamMessage>>,
    stdout_reader: Option<JoinHandle<()>>,
    stderr_reader: Option<JoinHandle<Vec<u8>>>,
    pending: Option<GitCommitResponse>,
    emitted: usize,
    last_access: Instant,
    finished: bool,
}

#[derive(Default)]
struct HistorySessionRegistry {
    sessions: std::collections::HashMap<String, HistorySession>,
    /// Sessions that are starting or temporarily checked out for a page read.
    in_flight: usize,
}

/// Accounts for a live session while it is outside the registry map.
struct HistorySessionLease {
    active: bool,
}

impl HistorySessionLease {
    fn new() -> Self {
        Self { active: true }
    }

    fn store(mut self, session: HistorySession) -> Result<(), CoreError> {
        let mut registry = history_sessions()
            .lock()
            .map_err(history_session_lock_error)?;
        registry.in_flight = registry.in_flight.saturating_sub(1);
        registry.sessions.insert(session.cursor.clone(), session);
        self.active = false;
        Ok(())
    }
}

impl Drop for HistorySessionLease {
    fn drop(&mut self) {
        if !self.active {
            return;
        }
        if let Ok(mut registry) = history_sessions().lock() {
            registry.in_flight = registry.in_flight.saturating_sub(1);
        }
    }
}

impl HistorySession {
    fn start(root: String, reference: Option<String>) -> Result<Self, CoreError> {
        cancellation::check()?;
        let mut arguments = vec!["log".to_string()];
        if let Some(reference) = reference.as_deref() {
            arguments.push(reference.to_string());
        } else {
            arguments.push("--all".to_string());
        }
        arguments.extend([
            "--topo-order".to_string(),
            "--decorate=short".to_string(),
            "-n".to_string(),
            MAX_HISTORY_COMMITS.to_string(),
            "--date=format:%Y/%m/%d %H:%M".to_string(),
            "--pretty=format:%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%ad%x1f%s%x1f%D".to_string(),
        ]);
        let mut process = git_process();
        let mut child = process
            .args(&arguments)
            .current_dir(&root)
            .env("GIT_OPTIONAL_LOCKS", "0")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|error| {
                CoreError::new(ErrorCode::ProcessStartFailed, "Could not start Git history")
                    .with_details(error.to_string())
            })?;
        let stdout = child.stdout.take().ok_or_else(|| {
            CoreError::new(
                ErrorCode::ProcessFailed,
                "Git history stdout was unavailable",
            )
        })?;
        let mut stderr = child.stderr.take().ok_or_else(|| {
            CoreError::new(
                ErrorCode::ProcessFailed,
                "Git history stderr was unavailable",
            )
        })?;
        // A single-slot channel propagates backpressure to Git instead of buffering the
        // entire repository history between page requests.
        let (sender, receiver) = mpsc::sync_channel(1);
        let stdout_reader = thread::spawn(move || read_history_stream(stdout, sender));
        let stderr_reader = thread::spawn(move || {
            let mut bytes = Vec::new();
            let _ = stderr.read_to_end(&mut bytes);
            bytes
        });
        let cursor = format!(
            "git-history-cursor-{}",
            NEXT_HISTORY_CURSOR.fetch_add(1, Ordering::Relaxed)
        );
        Ok(Self {
            cursor,
            root,
            reference,
            child: Some(child),
            receiver: Some(receiver),
            stdout_reader: Some(stdout_reader),
            stderr_reader: Some(stderr_reader),
            pending: None,
            emitted: 0,
            last_access: Instant::now(),
            finished: false,
        })
    }

    fn read_page(&mut self, limit: usize) -> Result<(Vec<GitCommitResponse>, bool), CoreError> {
        let deadline = Instant::now() + HISTORY_PAGE_DEADLINE;
        let mut commits = Vec::with_capacity(limit);
        if let Some(commit) = self.pending.take() {
            commits.push(commit);
        }
        while commits.len() < limit && self.emitted + commits.len() < MAX_HISTORY_COMMITS {
            let Some(commit) = self.next_commit(deadline)? else {
                break;
            };
            commits.push(commit);
        }
        self.emitted += commits.len();
        let has_more = if self.emitted >= MAX_HISTORY_COMMITS || self.finished {
            false
        } else {
            self.pending = self.next_commit(deadline)?;
            self.pending.is_some()
        };
        Ok((commits, has_more))
    }

    fn next_commit(&mut self, deadline: Instant) -> Result<Option<GitCommitResponse>, CoreError> {
        loop {
            cancellation::check()?;
            if Instant::now() >= deadline {
                return Err(CoreError::new(
                    ErrorCode::ProcessFailed,
                    "Git history page timed out",
                ));
            }
            let message = self
                .receiver
                .as_ref()
                .ok_or_else(|| {
                    CoreError::new(
                        ErrorCode::ProcessFailed,
                        "Git history stream was unavailable",
                    )
                })?
                .recv_timeout(HISTORY_STREAM_POLL_INTERVAL);
            match message {
                Ok(HistoryStreamMessage::Line(line)) => {
                    if let Some(commit) = parse_commit(&line) {
                        return Ok(Some(commit));
                    }
                }
                Ok(HistoryStreamMessage::ReadFailed(details)) => {
                    return Err(CoreError::new(
                        ErrorCode::ProcessFailed,
                        "Could not read Git history",
                    )
                    .with_details(details));
                }
                Ok(HistoryStreamMessage::End) | Err(RecvTimeoutError::Disconnected) => {
                    self.finish_process(false)?;
                    return Ok(None);
                }
                Err(RecvTimeoutError::Timeout) => {}
            }
        }
    }

    fn finish_process(&mut self, terminate: bool) -> Result<(), CoreError> {
        if self.finished {
            return Ok(());
        }
        self.finished = true;
        self.receiver.take();
        let status = if let Some(mut child) = self.child.take() {
            if terminate {
                let _ = child.kill();
            }
            child.wait().map_err(|error| {
                CoreError::new(
                    ErrorCode::ProcessFailed,
                    "Could not read Git history status",
                )
                .with_details(error.to_string())
            })?
        } else {
            return Ok(());
        };
        if let Some(reader) = self.stdout_reader.take() {
            let _ = reader.join();
        }
        let stderr = self
            .stderr_reader
            .take()
            .and_then(|reader| reader.join().ok())
            .unwrap_or_default();
        validate_history_exit(status, stderr, terminate)
    }

    fn stop(mut self) {
        let _ = self.finish_process(true);
    }
}

impl Drop for HistorySession {
    fn drop(&mut self) {
        let _ = self.finish_process(true);
    }
}

fn read_history_stream(stdout: impl Read, sender: SyncSender<HistoryStreamMessage>) {
    let mut reader = BufReader::new(stdout);
    let mut line = String::new();
    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => {
                let _ = sender.send(HistoryStreamMessage::End);
                break;
            }
            Ok(_) => {
                let normalized = line.trim_end_matches(['\r', '\n']).to_string();
                if sender.send(HistoryStreamMessage::Line(normalized)).is_err() {
                    break;
                }
            }
            Err(error) => {
                let _ = sender.send(HistoryStreamMessage::ReadFailed(error.to_string()));
                break;
            }
        }
    }
}

fn validate_history_exit(
    status: ExitStatus,
    stderr: Vec<u8>,
    terminated: bool,
) -> Result<(), CoreError> {
    if status.success() || terminated {
        return Ok(());
    }
    Err(
        CoreError::new(ErrorCode::ProcessFailed, "Git history failed")
            .with_details(String::from_utf8_lossy(&stderr).trim().to_string()),
    )
}

fn validate_reference(reference: Option<&str>) -> Result<(), CoreError> {
    if reference.is_some_and(|value| value.starts_with('-') || value.contains('\0')) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid Git reference",
        ));
    }
    Ok(())
}

fn history_sessions() -> &'static Mutex<HistorySessionRegistry> {
    let registry = HISTORY_SESSIONS.get_or_init(|| Mutex::new(HistorySessionRegistry::default()));
    HISTORY_REAPER.get_or_init(|| {
        thread::Builder::new()
            .name("lithe-git-history-reaper".to_string())
            .spawn(|| loop {
                thread::sleep(HISTORY_CURSOR_REAPER_INTERVAL);
                cleanup_expired_history_sessions();
            })
            .expect("Git history reaper should start");
    });
    registry
}

fn history_session_lock_error<T>(error: std::sync::PoisonError<T>) -> CoreError {
    CoreError::new(
        ErrorCode::ProcessFailed,
        "Git history cursor state was unavailable",
    )
    .with_details(error.to_string())
}

fn take_history_session(
    cursor: &str,
) -> Result<Option<(HistorySession, HistorySessionLease)>, CoreError> {
    let mut registry = history_sessions()
        .lock()
        .map_err(history_session_lock_error)?;
    let Some(session) = registry.sessions.remove(cursor) else {
        return Ok(None);
    };
    registry.in_flight += 1;
    Ok(Some((session, HistorySessionLease::new())))
}

fn cleanup_expired_history_sessions() {
    let expired = history_sessions().lock().ok().map(|mut registry| {
        take_expired_history_sessions(&mut registry, Instant::now(), HISTORY_CURSOR_IDLE_TTL)
    });
    for session in expired.unwrap_or_default() {
        session.stop();
    }
}

fn take_expired_history_sessions(
    registry: &mut HistorySessionRegistry,
    now: Instant,
    ttl: Duration,
) -> Vec<HistorySession> {
    let cursors = registry
        .sessions
        .iter()
        .filter(|(_, session)| now.saturating_duration_since(session.last_access) >= ttl)
        .map(|(cursor, _)| cursor.clone())
        .collect::<Vec<_>>();
    cursors
        .into_iter()
        .filter_map(|cursor| registry.sessions.remove(&cursor))
        .collect()
}

fn reserve_history_session_slot() -> Result<HistorySessionLease, CoreError> {
    let evicted = {
        let mut registry = history_sessions()
            .lock()
            .map_err(history_session_lock_error)?;
        reserve_history_session_slot_from(&mut registry)?
    };
    for session in evicted {
        session.stop();
    }
    Ok(HistorySessionLease::new())
}

fn reserve_history_session_slot_from(
    registry: &mut HistorySessionRegistry,
) -> Result<Vec<HistorySession>, CoreError> {
    let mut evicted = Vec::new();
    while registry.sessions.len() + registry.in_flight >= MAX_HISTORY_SESSIONS {
        let Some(cursor) = registry
            .sessions
            .iter()
            .min_by_key(|(_, session)| session.last_access)
            .map(|(cursor, _)| cursor.clone())
        else {
            return Err(CoreError::new(
                ErrorCode::ProcessFailed,
                "Too many Git history sessions are active",
            ));
        };
        if let Some(session) = registry.sessions.remove(&cursor) {
            evicted.push(session);
        }
    }
    registry.in_flight += 1;
    Ok(evicted)
}

fn invalid_history_cursor(cursor: &str) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, "Invalid Git history cursor")
        .with_details(cursor.to_string())
}

/// Builds a bounded MRU list from Git's own checkout history.
fn recent_local_references(
    root: &str,
    references: &[GitReferenceResponse],
    limit: usize,
) -> Vec<GitReferenceResponse> {
    let local_references = references
        .iter()
        .filter(|reference| reference.kind == "local")
        .collect::<Vec<_>>();
    let mut recent = Vec::with_capacity(limit.min(local_references.len()));

    if let Some(current) = local_references
        .iter()
        .find(|reference| reference.is_current)
    {
        append_recent_reference(&mut recent, &local_references, &current.short_name, limit);
    }

    if let Some(reflog) = command_value(
        root,
        &[
            "reflog",
            "show",
            "-n",
            RECENT_BRANCH_REFLOG_LIMIT,
            "--format=%gs",
            "HEAD",
        ],
    ) {
        for line in reflog.lines() {
            let Some(checkout) = line.strip_prefix("checkout: moving from ") else {
                continue;
            };
            let Some((source, destination)) = checkout.split_once(" to ") else {
                continue;
            };
            append_recent_reference(&mut recent, &local_references, destination, limit);
            append_recent_reference(&mut recent, &local_references, source, limit);
            if recent.len() >= limit {
                break;
            }
        }
    }

    if recent.len() < limit {
        if let Some(remote_head) = command_value(
            root,
            &[
                "symbolic-ref",
                "--quiet",
                "--short",
                "refs/remotes/origin/HEAD",
            ],
        ) {
            append_recent_reference(
                &mut recent,
                &local_references,
                remote_head
                    .split_once('/')
                    .map_or(remote_head.as_str(), |(_, branch)| branch),
                limit,
            );
        }
    }
    for branch in DEFAULT_BRANCH_FALLBACKS {
        append_recent_reference(&mut recent, &local_references, branch, limit);
    }

    for reference in &local_references {
        append_recent_reference(&mut recent, &local_references, &reference.short_name, limit);
        if recent.len() >= limit {
            break;
        }
    }

    recent.into_iter().cloned().collect()
}

fn append_recent_reference<'a>(
    recent: &mut Vec<&'a GitReferenceResponse>,
    references: &[&'a GitReferenceResponse],
    raw_name: &str,
    limit: usize,
) {
    if recent.len() >= limit {
        return;
    }
    let name = raw_name.trim().trim_start_matches("refs/heads/");
    let Some(reference) = references
        .iter()
        .find(|reference| reference.short_name == name)
    else {
        return;
    };
    if !recent
        .iter()
        .any(|existing| existing.full_name == reference.full_name)
    {
        recent.push(*reference);
    }
}

/// Reads one optional repository configuration value without failing the snapshot.
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

#[cfg(test)]
mod tests {
    use super::{
        reserve_history_session_slot_from, take_expired_history_sessions, HistorySession,
        HistorySessionRegistry, MAX_HISTORY_SESSIONS,
    };
    use crate::protocol::ErrorCode;
    use std::time::{Duration, Instant};

    fn finished_session(cursor: &str, last_access: Instant) -> HistorySession {
        HistorySession {
            cursor: cursor.to_string(),
            root: "/test/repository".to_string(),
            reference: None,
            child: None,
            receiver: None,
            stdout_reader: None,
            stderr_reader: None,
            pending: None,
            emitted: 0,
            last_access,
            finished: true,
        }
    }

    #[test]
    fn expired_sessions_are_removed_without_touching_recent_sessions() {
        let now = Instant::now();
        let mut registry = HistorySessionRegistry::default();
        registry.sessions.insert(
            "expired".to_string(),
            finished_session("expired", now - Duration::from_secs(121)),
        );
        registry.sessions.insert(
            "recent".to_string(),
            finished_session("recent", now - Duration::from_secs(119)),
        );

        let expired = take_expired_history_sessions(&mut registry, now, Duration::from_secs(120));

        assert_eq!(expired.len(), 1);
        assert_eq!(expired[0].cursor, "expired");
        assert!(registry.sessions.contains_key("recent"));
    }

    #[test]
    fn session_limit_counts_requests_that_are_still_in_flight() {
        let mut registry = HistorySessionRegistry {
            sessions: Default::default(),
            in_flight: MAX_HISTORY_SESSIONS,
        };

        let error = match reserve_history_session_slot_from(&mut registry) {
            Ok(_) => panic!("a ninth in-flight session should be rejected"),
            Err(error) => error,
        };

        assert!(matches!(error.code, ErrorCode::ProcessFailed));
        assert_eq!(registry.in_flight, MAX_HISTORY_SESSIONS);
    }
}
