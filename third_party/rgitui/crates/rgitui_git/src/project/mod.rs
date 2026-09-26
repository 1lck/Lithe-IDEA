mod argsafe;
mod auth;
mod bisect;
mod blame;
#[cfg(feature = "perf")]
mod census;
mod diff;
mod file_history;
mod history_cache;
mod local_ops;
mod network;
mod rebase;
mod reflog;
mod refresh;
mod search;
mod submodule;
mod watcher;
mod worktree_patch;

use anyhow::{Context as _, Result};
use git2::{Repository, StatusOptions};
use gpui::{AsyncApp, Context, EventEmitter, Task, WeakEntity};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use crate::types::*;

use argsafe::{validate_branch_name, validate_remote_name};

/// Normalize UNC paths (`\\server\share\…` → `//server/share/…`) for libgit2
/// on Windows. No-op on other platforms.
pub fn normalize_repo_path(path: PathBuf) -> PathBuf {
    #[cfg(target_os = "windows")]
    {
        let s = path.to_string_lossy();
        // Only rewrite share-style UNC paths (\\server\share\...).
        // Skip extended-length (\\?\...) and device (\\.\...) prefixes — libgit2
        // does not accept the slash-converted form of these, and Rust's
        // `canonicalize` routinely produces \\?\ paths we must not mangle.
        if s.starts_with("\\\\") {
            let third = s.as_bytes().get(2).copied();
            if third != Some(b'?') && third != Some(b'.') {
                return PathBuf::from(s.replace('\\', "/"));
            }
        }
    }
    path
}

/// Create a `git` [`Command`] with `CREATE_NO_WINDOW` set on Windows so that
/// spawning it from a GUI application never flashes a visible console window.
pub fn git_command() -> Command {
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        let mut cmd = Command::new("git");
        cmd.creation_flags(0x08000000);
        cmd
    }
    #[cfg(not(target_os = "windows"))]
    {
        Command::new("git")
    }
}

pub use bisect::{compute_bisect_log, is_bisect_in_progress, BisectDecision, BisectLogEntry};
pub use blame::{compute_blame, BlameEntry, BlameLine};
pub use diff::{
    compute_commit_diff, compute_file_diff, compute_staged_diff_text, compute_stash_diff,
    compute_three_way_conflict_diff,
};
pub use file_history::{compute_file_history, compute_file_history_at};
pub use local_ops::branches_containing_commit;
pub use reflog::{compute_reflog, ReflogEntryInfo};
pub use refresh::gather_refresh_data;
pub use refresh::gather_refresh_data_lightweight;
pub use refresh::{enrich_commit_info, extract_co_authors};
pub use search::git_grep;
pub use submodule::{
    compute_submodules, submodule_init, submodule_init_all, submodule_update, submodule_update_all,
    SubmoduleInfo,
};
pub use worktree_patch::{
    apply_worktree_patch, restore_worktree_files, snapshots_fit_undo_stack,
    WorktreeFilePermissions, WorktreeFileSnapshot, WorktreeFileState, WorktreePatchDirection,
    WorktreePatchOutcome, WorktreePatchScope, WorktreePatchSource, MAX_UNDO_SNAPSHOT_BYTES,
};

fn parse_remote_tracking_ref(name: &str) -> Option<(String, String)> {
    let trimmed = name.strip_prefix("refs/remotes/").unwrap_or(name);
    let mut parts = trimmed.splitn(2, '/');
    let remote = parts.next()?.trim();
    let branch = parts.next()?.trim();
    if remote.is_empty() || branch.is_empty() {
        return None;
    }
    Some((remote.to_string(), branch.to_string()))
}

fn head_branch_name(repo: &Repository) -> Result<String> {
    let head = repo.head()?;
    if !head.is_branch() {
        anyhow::bail!("HEAD is detached. Switch to a branch before running this operation.");
    }
    head.shorthand()
        .map(str::to_string)
        .ok_or_else(|| anyhow::anyhow!("Failed to determine the current branch name"))
}

/// Whether the working tree or index carries changes to **tracked** files.
///
/// Untracked and ignored files are deliberately excluded. Counting every
/// untracked file as "dirty" made a single un-ignored scratch file block branch
/// switching entirely, with no way to proceed short of deleting it.
///
/// This is only safe because every operation gated on it refuses on its own,
/// and names the file, when it would actually overwrite an untracked file: the
/// CLI-backed operations (pull, rebase) do so natively, and the git2-backed
/// checkout and fast-forward merge paths go through
/// [`local_ops::checkout_tree_safe`], which never force-checkouts. Any new
/// caller must hold to that — a forced checkout behind this relaxed guard
/// silently destroys untracked files.
fn repo_has_worktree_changes(repo: &Repository) -> Result<bool> {
    let mut opts = StatusOptions::new();
    opts.include_untracked(false)
        .recurse_untracked_dirs(false)
        .include_ignored(false)
        .include_unmodified(false);
    Ok(!repo.statuses(Some(&mut opts))?.is_empty())
}

fn ensure_clean_worktree(repo: &Repository, operation: &str) -> Result<()> {
    if repo_has_worktree_changes(repo)? {
        anyhow::bail!(
            "{} requires a clean working tree. Commit, stash, or discard your changes to \
             tracked files first.",
            operation
        );
    }
    Ok(())
}

fn default_remote_name(repo: &Repository) -> Result<String> {
    if let Ok(branch_name) = head_branch_name(repo) {
        if let Ok(branch) = repo.find_branch(&branch_name, git2::BranchType::Local) {
            if let Ok(upstream) = branch.upstream() {
                if let Some(upstream_name) = upstream.name()?.and_then(parse_remote_tracking_ref) {
                    validate_remote_name(&upstream_name.0)?;
                    return Ok(upstream_name.0);
                }
            }
        }
    }

    let remote_names = repo.remotes()?;
    if remote_names.is_empty() {
        anyhow::bail!("No remotes configured. Add one with: git remote add origin <url>")
    }

    if remote_names.iter().flatten().any(|name| name == "origin") {
        return Ok("origin".to_string());
    }

    let name = remote_names
        .iter()
        .flatten()
        .next()
        .map(str::to_string)
        .ok_or_else(|| anyhow::anyhow!("No usable git remotes are configured."))?;
    // Read straight out of .git/config, which git does not validate.
    validate_remote_name(&name)?;
    Ok(name)
}

fn pull_target(repo: &Repository, preferred_remote: Option<&str>) -> Result<(String, String)> {
    let branch_name = head_branch_name(repo)?;
    if let Ok(branch) = repo.find_branch(&branch_name, git2::BranchType::Local) {
        if let Ok(upstream) = branch.upstream() {
            if let Some(upstream_name) = upstream.name()?.and_then(parse_remote_tracking_ref) {
                if preferred_remote
                    .map(|remote| remote == upstream_name.0)
                    .unwrap_or(true)
                {
                    validate_remote_name(&upstream_name.0)?;
                    validate_branch_name(&upstream_name.1)?;
                    return Ok(upstream_name);
                }
            }
        }
    }

    let remote_name = preferred_remote
        .map(str::to_string)
        .unwrap_or(default_remote_name(repo)?);
    validate_remote_name(&remote_name)?;
    validate_branch_name(&branch_name)?;
    Ok((remote_name, branch_name))
}

fn push_target(
    repo: &Repository,
    preferred_remote: Option<&str>,
) -> Result<(String, String, bool)> {
    let branch_name = head_branch_name(repo)?;
    if let Ok(branch) = repo.find_branch(&branch_name, git2::BranchType::Local) {
        if let Ok(upstream) = branch.upstream() {
            if let Some((remote_name, remote_branch)) =
                upstream.name()?.and_then(parse_remote_tracking_ref)
            {
                if preferred_remote
                    .map(|remote| remote == remote_name)
                    .unwrap_or(true)
                {
                    validate_remote_name(&remote_name)?;
                    validate_branch_name(&remote_branch)?;
                    return Ok((remote_name, remote_branch, false));
                }
            }
        }
    }

    let remote_name = preferred_remote
        .map(str::to_string)
        .unwrap_or(default_remote_name(repo)?);
    validate_remote_name(&remote_name)?;
    validate_branch_name(&branch_name)?;
    Ok((remote_name, branch_name, true))
}

/// All the data gathered during a refresh, designed to be Send so it can
/// be computed on a background thread and then applied on the main thread.
pub struct RefreshData {
    /// Checked-out branch, or `None` when HEAD is detached.
    pub head_branch: Option<String>,
    pub head_detached: bool,
    /// The local branch HEAD was last switched away from, if it still exists.
    pub previous_branch: Option<String>,
    pub repo_state: RepoState,
    pub branches: Vec<BranchInfo>,
    pub tags: Vec<TagInfo>,
    pub remotes: Vec<RemoteInfo>,
    pub stashes: Vec<StashEntry>,
    pub worktrees: Vec<WorktreeInfo>,
    pub status: WorkingTreeStatus,
    pub recent_commits: Vec<CommitInfo>,
    /// Whether there are more commits beyond the loaded limit.
    pub has_more_commits: bool,
    /// The remote default branch (e.g. "main", "master"), detected from
    /// `refs/remotes/origin/HEAD` symbolic target. `None` if not set.
    pub default_branch: Option<String>,
    /// Current Git user email, read from repo config then global config.
    /// Used for "My Branches" / "My Commits" filtering.
    pub current_user_email: Option<String>,
}

/// Events emitted by GitProject.
#[derive(Debug, Clone)]
pub enum GitProjectEvent {
    /// A repository mutation changed one or more of HEAD, refs, or status.
    /// Subscribers should refresh their repository-derived snapshots once.
    RepositoryChanged,
    StatusChanged,
    HeadChanged,
    RefsChanged,
    /// Emitted after ahead/behind for all branches has been recomputed in the background.
    AheadBehindRefreshed,
    OperationUpdated(GitOperationUpdate),
    /// An apply/revert rewrote working-tree files on disk. Carries what those
    /// files held beforehand, which is the only record of it: the previous
    /// contents are not recoverable from git state.
    WorktreePatchApplied {
        /// Undo label, e.g. "Applied hunk 2 of src/main.rs from a1b2c3d".
        label: String,
        snapshots: Vec<worktree_patch::WorktreeFileSnapshot>,
        /// Repository entity that started the asynchronous mutation.
        repo_path: PathBuf,
        /// Effective worktree captured when the operation started.
        worktree_path: PathBuf,
    },
}

/// The core Git project state holder.
pub struct GitProject {
    repo_path: PathBuf,

    // Cached state
    head_branch: Option<String>,
    head_detached: bool,
    previous_branch: Option<String>,
    repo_state: RepoState,
    branches: Vec<BranchInfo>,
    tags: Vec<TagInfo>,
    remotes: Vec<RemoteInfo>,
    stashes: Vec<StashEntry>,
    worktrees: Vec<WorktreeInfo>,
    status: Arc<WorkingTreeStatus>,
    recent_commits: Arc<Vec<CommitInfo>>,
    /// Whether the repository has more commits beyond the loaded set.
    has_more_commits: bool,
    /// Number of commits currently loaded (used by incremental load-more).
    commit_offset: usize,
    next_operation_id: u64,
    /// Where each recent operation ran, so a retry can go back to the same
    /// checkout rather than to whatever is on screen when the failure lands.
    operation_worktrees: std::collections::HashMap<u64, PathBuf>,
    /// Remote default branch (e.g. "main"), from `refs/remotes/origin/HEAD`.
    default_branch: Option<String>,
    /// Current Git user email, read from repo config then global config.
    /// Used for "My Branches" / "My Commits" filtering.
    current_user_email: Option<String>,
    /// Author filter for "My Commits" — when set, only commits by this author are loaded.
    commit_author_filter: Option<String>,
    /// Maximum number of commits to load (configurable via settings).
    commit_limit: usize,
    /// Per-worktree status cache shared between GitProject::refresh() and the watcher loop.
    /// Keyed by worktree path; value is (fingerprint, cached WorkingTreeStatus).
    worktree_status_cache: Arc<Mutex<refresh::WorktreeStatusCache>>,
    /// Monotonic counter bumped on every `apply_refresh_data`. The watcher uses it
    /// to discard a stale lightweight refresh that would otherwise clobber a newer
    /// full/operation refresh that landed while the watcher's snapshot was in flight.
    refresh_generation: u64,
    /// Identifies the currently valid commit query (refs/filter/pagination session).
    /// Async commit results captured under an older generation must not be applied.
    commit_query_generation: u64,
    /// Suppresses duplicate pagination requests while one page is already in flight.
    load_more_in_flight: bool,
    /// The linked worktree the UI is currently inspecting, if any. The watcher
    /// always watches this checkout — even when the `watch_all_worktrees`
    /// setting is off — so the file list and diff of the worktree the user is
    /// actually looking at stay live.
    inspected_worktree: Option<PathBuf>,
    /// How many background refreshes are in flight — history paging and the
    /// ahead/behind walk, neither of which reports through `OperationUpdated`.
    ///
    /// Held behind an `Arc` so [`BackgroundWorkGuard`] can decrement it from
    /// `Drop`: a task cancelled by a newer refresh has to lower the count too,
    /// or anything waiting for the project to go quiet would wait forever.
    background_work: Arc<AtomicUsize>,
}

/// Keeps [`GitProject::has_background_work`] true for as long as it is alive.
///
/// Move one into a spawned refresh so the count falls when the task finishes
/// *or* when its future is dropped part-way through.
pub(crate) struct BackgroundWorkGuard(Arc<AtomicUsize>);

impl Drop for BackgroundWorkGuard {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::Release);
    }
}

impl EventEmitter<GitProjectEvent> for GitProject {}

impl GitProject {
    /// Create a minimal non-functional instance for error recovery paths.
    /// The resulting entity should be dropped immediately; it exists only
    /// to satisfy GPUI's `cx.new()` requirement of returning a value.
    pub fn empty_at(path: PathBuf) -> Self {
        Self {
            repo_path: path,
            head_branch: None,
            head_detached: false,
            previous_branch: None,
            repo_state: RepoState::Clean,
            branches: Vec::new(),
            tags: Vec::new(),
            remotes: Vec::new(),
            stashes: Vec::new(),
            worktrees: Vec::new(),
            status: Arc::new(WorkingTreeStatus::default()),
            recent_commits: Arc::new(Vec::new()),
            has_more_commits: false,
            commit_offset: 0,
            next_operation_id: 1,
            operation_worktrees: std::collections::HashMap::new(),
            default_branch: None,
            current_user_email: None,
            commit_author_filter: None,
            commit_limit: 1000,
            worktree_status_cache: Arc::new(Mutex::new(HashMap::new())),
            refresh_generation: 0,
            commit_query_generation: 0,
            load_more_in_flight: false,
            inspected_worktree: None,
            background_work: Arc::new(AtomicUsize::new(0)),
        }
    }

    /// Open a repository at the given path.
    pub fn open(path: PathBuf, commit_limit: usize, cx: &mut Context<Self>) -> Result<Self> {
        // Normalise UNC paths on Windows so that libgit2 can open WSL2 repos.
        let path = normalize_repo_path(path);
        let repo = Repository::open(&path)
            .with_context(|| format!("Failed to open repository at {}", path.display()))?;

        let repo_path = repo.workdir().unwrap_or_else(|| repo.path()).to_path_buf();

        let mut project = Self {
            repo_path,
            head_branch: None,
            head_detached: false,
            previous_branch: None,
            repo_state: RepoState::Clean,
            branches: Vec::new(),
            tags: Vec::new(),
            remotes: Vec::new(),
            stashes: Vec::new(),
            worktrees: Vec::new(),
            status: Arc::new(WorkingTreeStatus::default()),
            recent_commits: Arc::new(Vec::new()),
            has_more_commits: false,
            commit_offset: 0,
            next_operation_id: 1,
            operation_worktrees: std::collections::HashMap::new(),
            default_branch: None,
            current_user_email: None,
            commit_author_filter: None,
            commit_limit: refresh::normalize_commit_limit(commit_limit),
            worktree_status_cache: Arc::new(Mutex::new(HashMap::new())),
            refresh_generation: 0,
            commit_query_generation: 0,
            load_more_in_flight: false,
            inspected_worktree: None,
            background_work: Arc::new(AtomicUsize::new(0)),
        };

        if let Some(cached) = history_cache::load(&project.repo_path, project.commit_limit) {
            project.recent_commits = Arc::new(cached.commits);
            project.commit_offset = project.recent_commits.len();
            project.has_more_commits = cached.has_more_commits;
            project.default_branch = cached.default_branch;
            log::debug!(
                "hydrated {} commits from persistent history cache",
                project.recent_commits.len()
            );
        }

        project.start_watcher(cx);

        Ok(project)
    }

    pub(crate) fn begin_operation(
        &mut self,
        kind: GitOperationKind,
        summary: impl Into<String>,
        remote_name: Option<String>,
        branch_name: Option<String>,
        cx: &mut Context<Self>,
    ) -> u64 {
        let id = self.next_operation_id;
        self.next_operation_id += 1;
        cx.emit(GitProjectEvent::OperationUpdated(GitOperationUpdate {
            id,
            kind,
            state: GitOperationState::Running,
            summary: summary.into(),
            details: None,
            remote_name,
            branch_name,
            worktree_path: None,
            retryable: false,
        }));
        cx.notify();
        id
    }

    /// How many operations' worktrees to remember. Only the retryable ones
    /// register, and only the most recent failure is ever offered, so this is
    /// far more history than anything reads.
    const REMEMBERED_OPERATION_WORKTREES: usize = 32;

    /// Records where operation `id` is running, so its retry can go back there.
    pub(crate) fn note_operation_worktree(&mut self, id: u64, worktree_path: &Path) {
        self.operation_worktrees
            .insert(id, worktree_path.to_path_buf());
        if self.operation_worktrees.len() > Self::REMEMBERED_OPERATION_WORKTREES {
            let cutoff = id.saturating_sub(Self::REMEMBERED_OPERATION_WORKTREES as u64);
            self.operation_worktrees
                .retain(|recorded, _| *recorded > cutoff);
        }
    }

    fn operation_worktree(&self, id: u64) -> Option<PathBuf> {
        self.operation_worktrees.get(&id).cloned()
    }

    pub(crate) fn complete_op(
        &self,
        id: u64,
        kind: GitOperationKind,
        summary: impl Into<String>,
        names: (Option<String>, Option<String>, Option<String>),
        cx: &mut Context<Self>,
    ) {
        cx.emit(GitProjectEvent::OperationUpdated(GitOperationUpdate {
            id,
            kind,
            state: GitOperationState::Succeeded,
            summary: summary.into(),
            details: names.0,
            remote_name: names.1,
            branch_name: names.2,
            worktree_path: self.operation_worktree(id),
            retryable: false,
        }));
    }

    pub(crate) fn fail_op(
        &self,
        id: u64,
        kind: GitOperationKind,
        summary: impl Into<String>,
        error: impl Into<String>,
        names: (Option<String>, Option<String>, bool),
        cx: &mut Context<Self>,
    ) {
        cx.emit(GitProjectEvent::OperationUpdated(GitOperationUpdate {
            id,
            kind,
            state: GitOperationState::Failed,
            summary: summary.into(),
            details: Some(error.into()),
            remote_name: names.0,
            branch_name: names.1,
            worktree_path: self.operation_worktree(id),
            retryable: names.2,
        }));
    }

    /// Report an operation that failed before its task could start. The
    /// worktree is recorded just as a started operation's is, so a retry offered
    /// for a preflight failure goes back to the checkout the operation was aimed
    /// at rather than whichever one the user is looking at when they click it.
    pub(crate) fn fail_to_start_task(
        &mut self,
        kind: GitOperationKind,
        summary: impl Into<String>,
        error: anyhow::Error,
        retryable: bool,
        worktree_path: &Path,
        cx: &mut Context<Self>,
    ) -> Task<Result<()>> {
        let summary = summary.into();
        let branch_name = self.head_branch_at(worktree_path);
        let operation_id =
            self.begin_operation(kind, summary.clone(), None, branch_name.clone(), cx);
        self.note_operation_worktree(operation_id, worktree_path);
        self.fail_op(
            operation_id,
            kind,
            summary,
            error.to_string(),
            (None, branch_name, retryable),
            cx,
        );
        cx.spawn(async move |_this: WeakEntity<Self>, _cx: &mut AsyncApp| Err(error))
    }

    pub fn repo_path(&self) -> &Path {
        &self.repo_path
    }

    /// Raise [`GitProject::has_background_work`] until the returned guard drops.
    pub(crate) fn track_background_work(&self) -> BackgroundWorkGuard {
        self.background_work.fetch_add(1, Ordering::AcqRel);
        BackgroundWorkGuard(self.background_work.clone())
    }

    /// Whether a background refresh is still running.
    ///
    /// Neither history paging nor the ahead/behind walk emits an
    /// `OperationUpdated`, so a caller that only watches operations sees an idle
    /// project while both are still loading. Anything that waits for the
    /// repository to settle — a measurement, a snapshot — has to consult this
    /// as well as the operation list.
    pub fn has_background_work(&self) -> bool {
        self.background_work.load(Ordering::Acquire) > 0
    }

    /// Resolve the current HEAD commit OID of the given worktree (or the main
    /// repo when `worktree_path` is the repo path). A cheap synchronous ref read
    /// used to capture the pre-commit HEAD so a commit can be undone against the
    /// branch it was actually made on, not the main repo's HEAD.
    pub fn head_oid_at(&self, worktree_path: &Path) -> Option<git2::Oid> {
        let repo = git2::Repository::open(worktree_path).ok()?;
        let head = repo.head().ok()?;
        head.target()
    }

    pub fn repo_name(&self) -> &str {
        self.repo_path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("unknown")
    }

    /// The checked-out branch, or `None` when HEAD is detached or unborn.
    pub fn head_branch(&self) -> Option<&str> {
        self.head_branch.as_deref()
    }

    pub fn is_head_detached(&self) -> bool {
        self.head_detached
    }

    /// The local branch HEAD was last switched away from, the one
    /// `git switch -` would return to, if it still exists.
    pub fn previous_branch(&self) -> Option<&str> {
        self.previous_branch.as_deref()
    }

    /// The commit HEAD points at, as of the last refresh.
    pub fn head_oid(&self) -> Option<git2::Oid> {
        self.worktrees
            .iter()
            .find(|worktree| worktree.is_current)
            .and_then(|worktree| worktree.head_oid)
    }

    /// The commit HEAD points at, when it is among the loaded commits.
    pub fn head_commit(&self) -> Option<&CommitInfo> {
        let head = self.head_oid()?;
        self.recent_commits.iter().find(|commit| commit.oid == head)
    }

    /// Tell the watcher which linked worktree the UI is inspecting so it is
    /// watched and fingerprinted regardless of the `watch_all_worktrees`
    /// setting. Pass `None` when the user leaves worktree inspection.
    pub fn set_inspected_worktree(&mut self, path: Option<PathBuf>) {
        self.inspected_worktree = path;
    }

    pub(crate) fn inspected_worktree(&self) -> Option<&Path> {
        self.inspected_worktree.as_deref()
    }

    /// The worktree in the current snapshot whose working directory is
    /// `worktree_path`, if any.
    pub fn worktree_at(&self, worktree_path: &Path) -> Option<&WorktreeInfo> {
        self.worktrees
            .iter()
            .find(|worktree| worktree.path == worktree_path)
    }

    /// The branch checked out in `worktree_path`. Falls back to this project's
    /// own HEAD branch when the path is not a worktree we know about, so
    /// operation labels degrade to something sensible rather than blank.
    pub fn head_branch_at(&self, worktree_path: &Path) -> Option<String> {
        match self.worktree_at(worktree_path) {
            Some(worktree) => worktree.branch.clone(),
            None => self.head_branch.clone(),
        }
    }

    pub fn repo_state(&self) -> RepoState {
        self.repo_state
    }

    /// The merge/rebase state of `worktree_path`. Each checkout keeps its own —
    /// a conflicted pull inside a linked worktree writes `MERGE_HEAD` under
    /// `.git/worktrees/<name>/`, which the main repository reports as clean —
    /// so a banner or a Continue/Abort command asking about the project would
    /// tell the user nothing is in progress while they are looking at conflicts.
    pub fn repo_state_at(&self, worktree_path: &Path) -> RepoState {
        match self.worktree_at(worktree_path) {
            Some(worktree) => worktree.state,
            None => self.repo_state,
        }
    }

    pub fn branches(&self) -> &[BranchInfo] {
        &self.branches
    }

    pub fn tags(&self) -> &[TagInfo] {
        &self.tags
    }

    pub fn remotes(&self) -> &[RemoteInfo] {
        &self.remotes
    }

    /// The remote a default fetch should use for `worktree_path`.
    ///
    /// Derived from that checkout's own HEAD and upstream. A linked worktree on
    /// a branch tracking `fork/feature` should fetch `fork`, and asking the
    /// main repository would answer `origin` — the remote of a branch the user
    /// is not on.
    pub fn preferred_remote_name_at(&self, worktree_path: &Path) -> Result<String> {
        let repo = Repository::open(worktree_path)
            .with_context(|| format!("Failed to open repository at {}", worktree_path.display()))?;
        default_remote_name(&repo)
    }

    /// Resolve a tag name to the commit OID it points to.
    /// Handles both lightweight and annotated tags by peeling to the commit.
    pub fn resolve_tag_to_oid(&self, tag_name: &str) -> Result<git2::Oid> {
        let repo = self.open_repo()?;
        let obj = repo
            .revparse_single(&format!("refs/tags/{}", tag_name))
            .with_context(|| format!("Failed to resolve tag '{}'", tag_name))?;
        let commit = obj
            .peel_to_commit()
            .with_context(|| format!("Tag '{}' does not point to a commit", tag_name))?;
        Ok(commit.id())
    }

    /// Resolve a branch name to the commit OID it points to.
    /// Tries local branch first, then remote, then raw revparse.
    pub fn resolve_branch_to_oid(&self, branch_name: &str) -> Result<git2::Oid> {
        let repo = self.open_repo()?;
        let refs_to_try = [
            format!("refs/heads/{}", branch_name),
            format!("refs/remotes/{}", branch_name),
            branch_name.to_string(),
        ];
        for refspec in &refs_to_try {
            if let Ok(obj) = repo.revparse_single(refspec) {
                if let Ok(commit) = obj.peel_to_commit() {
                    return Ok(commit.id());
                }
            }
        }
        anyhow::bail!("Failed to resolve branch '{}' to a commit", branch_name)
    }

    pub fn stashes(&self) -> &[StashEntry] {
        &self.stashes
    }

    pub fn worktrees(&self) -> &[WorktreeInfo] {
        &self.worktrees
    }

    pub fn status(&self) -> &WorkingTreeStatus {
        &self.status
    }

    pub fn status_arc(&self) -> Arc<WorkingTreeStatus> {
        Arc::clone(&self.status)
    }

    pub fn recent_commits(&self) -> &[CommitInfo] {
        &self.recent_commits
    }

    pub fn recent_commits_arc(&self) -> Arc<Vec<CommitInfo>> {
        Arc::clone(&self.recent_commits)
    }

    pub fn has_changes(&self) -> bool {
        !self.status.staged.is_empty() || !self.status.unstaged.is_empty()
    }

    /// Returns the list of conflicted file paths from the unstaged changes.
    pub fn conflicted_files(&self) -> Vec<&FileStatus> {
        self.status
            .unstaged
            .iter()
            .filter(|f| f.kind == FileChangeKind::Conflicted)
            .collect()
    }

    /// The conflicted files in `worktree_path`. Falls back to this project's
    /// own status when that checkout has no cached status yet, which is the
    /// same answer the caller would have got before asking.
    pub fn conflicted_files_at(&self, worktree_path: &Path) -> Vec<&FileStatus> {
        match self
            .worktree_at(worktree_path)
            .and_then(|worktree| worktree.status.as_ref())
        {
            Some(status) => status
                .unstaged
                .iter()
                .filter(|f| f.kind == FileChangeKind::Conflicted)
                .collect(),
            None => self.conflicted_files(),
        }
    }

    /// Whether `worktree_path` has any conflicted files.
    pub fn has_conflicts_at(&self, worktree_path: &Path) -> bool {
        !self.conflicted_files_at(worktree_path).is_empty()
    }

    pub(crate) fn open_repo(&self) -> Result<Repository> {
        Repository::open(&self.repo_path)
            .with_context(|| format!("Failed to open repository at {}", self.repo_path.display()))
    }

    /// Apply pre-gathered refresh data to self.
    /// Whether any local branch is missing graph state it could have.
    ///
    /// True right after a reference point moves: the carry-forward drops the
    /// answers that were derived from it, leaving a hole that only a fresh walk
    /// can fill. False in the steady state, where nothing moved and everything
    /// was carried — which is what keeps the watcher from scheduling two
    /// history walks on every file save.
    ///
    /// "Could have" is doing real work. A repository whose trunk is named
    /// something other than `main` or `master` has no trunk for
    /// `is_merged_into_main` to be about, and that answer is `None` for as long
    /// as the repository exists. Reading that as work outstanding would put a
    /// full history walk and a `git for-each-ref` behind every file save, on
    /// exactly the repositories that already got the worst of this code.
    pub fn needs_graph_state_refresh(&self) -> bool {
        graph_state_is_incomplete(&self.branches, self.head_detached)
    }

    pub(crate) fn apply_refresh_data(&mut self, data: RefreshData) {
        self.head_branch = data.head_branch;
        self.head_detached = data.head_detached;
        self.previous_branch = data.previous_branch;
        self.repo_state = data.repo_state;
        self.branches = carry_forward_branch_graph_state(&self.branches, data.branches);
        self.tags = data.tags;
        self.remotes = data.remotes;
        self.stashes = data.stashes;
        self.worktrees = data.worktrees;
        self.status = Arc::new(data.status);
        self.recent_commits = Arc::new(data.recent_commits);
        self.has_more_commits = data.has_more_commits;
        self.default_branch = data.default_branch;
        self.current_user_email = data.current_user_email;
        // Reset offset — the full refresh replaces all commits.
        self.commit_offset = self.recent_commits.len();
        // Advance the refresh generation so an in-flight watcher snapshot that
        // started before this apply discards its now-stale lightweight result.
        self.refresh_generation = self.refresh_generation.wrapping_add(1);
    }

    /// The current refresh generation, bumped on every `apply_refresh_data`.
    /// The watcher captures this before gathering and drops its result if the
    /// generation advanced in the meantime (a newer full refresh won).
    pub(crate) fn refresh_generation(&self) -> u64 {
        self.refresh_generation
    }

    /// Whether a refresh has ever been applied to this project.
    ///
    /// The honest test for "there is something to show". Counting commits
    /// instead treats an empty repository as permanently unloaded, which is a
    /// real state — a freshly initialised one — and leaves whatever is waiting
    /// on it waiting until its timeout.
    pub fn has_loaded(&self) -> bool {
        self.refresh_generation > 0
    }

    /// Whether there are more commits beyond the currently loaded set.
    pub fn has_more_commits(&self) -> bool {
        self.has_more_commits
    }

    /// The remote default branch (e.g. "main", "master") determined from
    /// `refs/remotes/origin/HEAD` symbolic reference.
    pub fn default_branch(&self) -> Option<&str> {
        self.default_branch.as_deref()
    }

    /// The current Git user email, used for "My Branches" / "My Commits" filtering.
    pub fn current_user_email(&self) -> Option<&str> {
        self.current_user_email.as_deref()
    }

    /// Set the author filter for "My Commits" mode. When `Some(email)`,
    /// only commits authored by this email are loaded. Clears existing commits
    /// and resets the offset so the next load fetches from the beginning.
    pub fn set_commit_author_filter(&mut self, email: Option<String>) {
        if self.commit_author_filter != email {
            self.commit_author_filter = email;
            self.commit_query_generation = self.commit_query_generation.wrapping_add(1);
            self.load_more_in_flight = false;
            // Reset commit list so next load starts fresh with the filter applied.
            self.recent_commits = Arc::new(Vec::new());
            self.commit_offset = 0;
            self.has_more_commits = true;
        }
    }

    /// How many commits are currently loaded.
    pub fn loaded_commit_count(&self) -> usize {
        self.recent_commits.len()
    }

    /// Asynchronously load the next batch of commits and append them to the
    /// existing list.  Emits `GitProjectEvent::StatusChanged` when done so the
    /// graph view re-renders.
    pub fn load_more_commits(&mut self, cx: &mut Context<Self>) -> Task<Result<()>> {
        if self.load_more_in_flight || !self.has_more_commits {
            return cx.spawn(async move |_, _| Ok(()));
        }
        self.load_more_in_flight = true;
        let query_generation = self.commit_query_generation;
        let repo_path = self.repo_path.clone();
        let already_loaded = self.commit_offset;
        // Stable pagination cursor: the OID of the last loaded commit. Re-anchoring
        // on it (rather than a raw `--skip`) avoids dropping a commit if refs change
        // between pages.
        let after_oid = self.recent_commits.last().map(|c| c.oid);
        // Collect the branch/tag ref-map data we need for labelling
        let branch_tips: Vec<(git2::Oid, bool, String)> = self
            .branches
            .iter()
            .filter_map(|b| b.tip_oid.map(|oid| (oid, b.is_remote, b.name.clone())))
            .collect();
        let tag_tips: Vec<(git2::Oid, String)> =
            self.tags.iter().map(|t| (t.oid, t.name.clone())).collect();
        let commit_limit = self.commit_limit;
        let author_filter = self.commit_author_filter.clone();

        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = cx
                .background_executor()
                .spawn(async move {
                    refresh::load_more_commits_from_repo(
                        &repo_path,
                        already_loaded,
                        after_oid,
                        commit_limit,
                        &branch_tips,
                        &tag_tips,
                        author_filter.as_deref(),
                    )
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    if this.commit_query_generation != query_generation {
                        return Ok(());
                    }
                    this.load_more_in_flight = false;
                    let (new_commits, has_more) = result?;
                    // Append the new commits, deduplicated by OID.
                    let existing_oids: std::collections::HashSet<git2::Oid> =
                        this.recent_commits.iter().map(|c| c.oid).collect();
                    // Append in place (no full-Vec clone) via Arc::make_mut.
                    let combined = Arc::make_mut(&mut this.recent_commits);
                    for commit in new_commits {
                        if !existing_oids.contains(&commit.oid) {
                            combined.push(commit);
                        }
                    }
                    this.commit_offset = this.recent_commits.len();
                    this.has_more_commits = has_more;
                    cx.emit(GitProjectEvent::StatusChanged);
                    cx.notify();
                    Ok(())
                })
            })?
        })
    }

    /// Compute ahead/behind for all local branches with upstreams in a background
    /// task, then update the branches list and emit `AheadBehindRefreshed` so the
    /// UI refreshes. This is called after the initial refresh so that the
    /// expensive graph walks don't block the first render.
    ///
    /// The walk itself is delegated to `git for-each-ref`, which reads the
    /// commit-graph file; libgit2's `graph_ahead_behind` does not, and one call
    /// per branch made this the second-largest cost in a refresh.
    pub fn refresh_ahead_behind(&mut self, cx: &mut Context<Self>) {
        self.refresh_ahead_behind_attempt(0, cx);
    }

    /// The walk itself, carrying how many times it has already been restarted.
    ///
    /// Two full-history walks take long enough that an ordinary file save can
    /// land a refresh underneath them, and the result then belongs to a
    /// superseded snapshot. Dropping it silently — which is what this did —
    /// leaves the flags permanently unset on a repository that is being written
    /// to, because every attempt loses the same race. Restarting is bounded so
    /// that sustained churn degrades to "no answer yet" rather than to a task
    /// that respawns itself forever.
    fn refresh_ahead_behind_attempt(&mut self, attempt: u8, cx: &mut Context<Self>) {
        const MAX_ATTEMPTS: u8 = 3;

        let repo_path = self.repo_path.clone();
        let query_generation = self.commit_query_generation;
        let refresh_generation = self.refresh_generation;
        let branch_tips: Vec<BranchTip> = self
            .branches
            .iter()
            .map(|branch| {
                (
                    branch.name.clone(),
                    branch.is_remote,
                    branch.is_head,
                    branch.tip_oid,
                )
            })
            .collect();

        let work = self.track_background_work();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let _work = work;
            let (computed, merged) = cx
                .background_executor()
                .spawn(async move {
                    let repo = match git2::Repository::open(&repo_path) {
                        Ok(r) => r,
                        Err(_) => return (Vec::new(), Vec::new()),
                    };

                    let ahead_behind = ahead_behind_via_for_each_ref(&repo_path, &repo);
                    let merged = merged_flags(&repo, &branch_tips);
                    (ahead_behind, merged)
                })
                .await;

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    // Nothing to apply: the repository would not open, or it
                    // has no branches. Retrying would not change that.
                    if computed.is_empty() && merged.is_empty() {
                        return;
                    }

                    if this.commit_query_generation != query_generation
                        || this.refresh_generation != refresh_generation
                    {
                        let next = attempt + 1;
                        if next < MAX_ATTEMPTS && this.needs_graph_state_refresh() {
                            log::debug!(
                                "ahead/behind superseded by a newer refresh; retry {next} of {MAX_ATTEMPTS}"
                            );
                            this.refresh_ahead_behind_attempt(next, cx);
                        }
                        return;
                    }
                    for (name, tip, into_main, into_head) in merged {
                        if let Some(branch) = this
                            .branches
                            .iter_mut()
                            .find(|b| b.name == name && b.tip_oid == tip)
                        {
                            branch.is_merged_into_main = into_main;
                            branch.is_merged_into_head = into_head;
                        }
                    }
                    // Update ahead/behind values in place
                    for (name, local_oid, _upstream_oid, ahead, behind) in computed {
                        if let Some(branch) = this
                            .branches
                            .iter_mut()
                            .find(|b| b.name == name && b.tip_oid == Some(local_oid))
                        {
                            branch.ahead = Some(ahead);
                            branch.behind = Some(behind);
                        }
                    }
                    cx.emit(GitProjectEvent::AheadBehindRefreshed);
                    cx.notify();
                })
            })
            .ok();
        })
        .detach();
    }
}

/// A branch as the merged-flag walk needs it: name, remote, checked-out, tip.
type BranchTip = (String, bool, bool, Option<git2::Oid>);

/// One branch's answer: name, tip, merged-into-main, merged-into-HEAD. Each
/// flag is `None` when the question could not be asked at all.
type MergedFlags = (String, Option<git2::Oid>, Option<bool>, Option<bool>);

/// Whether each local branch is merged into main, and into HEAD.
///
/// Two history walks for the whole repository, rather than one per branch: the
/// question "is this tip an ancestor of that one" is a set-membership test once
/// you have walked the target's history, and there are only two targets.
///
/// Returns `(name, tip, merged_into_main, merged_into_head)` for local branches
/// only; a remote branch has neither flag. Each flag is `None` when the question
/// could not be asked at all — no trunk to compare against, or an unborn HEAD —
/// so that "unknown" never reaches the UI dressed as "not merged".
fn merged_flags(repo: &Repository, branches: &[BranchTip]) -> Vec<MergedFlags> {
    // Priority: local main > local master > remote origin/main > remote origin/master
    let tip_named = |wanted: &str, remote: bool| {
        branches
            .iter()
            .find(|(name, is_remote, _, _)| *is_remote == remote && name == wanted)
            .and_then(|(_, _, _, tip)| *tip)
    };
    let main_tip = tip_named("main", false)
        .or_else(|| tip_named("master", false))
        .or_else(|| tip_named("origin/main", true))
        .or_else(|| tip_named("origin/master", true));
    let head_tip = repo.head().ok().and_then(|reference| reference.target());

    let reachable_from_main = main_tip.map(|tip| refresh::reachable_set(repo, tip));

    // When HEAD is the same commit as main the second walk would rebuild an
    // identical set. Borrowing the first one instead of cloning it matters at
    // scale: on a repository the size of linux.git each set is tens of
    // megabytes, and the clone also pays for a full rehash.
    let head_is_main = matches!((head_tip, main_tip), (Some(head), Some(main)) if head == main);
    let walked_from_head = match head_tip {
        Some(head) if !head_is_main => Some(refresh::reachable_set(repo, head)),
        _ => None,
    };
    let reachable_from_head = if head_is_main {
        reachable_from_main.as_ref()
    } else {
        walked_from_head.as_ref()
    };

    // A tip that is not in the set is genuinely not merged; a set that does not
    // exist means the question could not be asked. The two must not collapse
    // together — a repository whose trunk is `develop` has no `main` to walk,
    // and reporting every branch as unmerged there invites the user to delete
    // branches that are fully merged.
    let membership = |set: Option<&std::collections::HashSet<git2::Oid>>,
                      tip: Option<git2::Oid>| {
        set.zip(tip)
            .map(|(reachable, tip)| reachable.contains(&tip))
    };

    branches
        .iter()
        .filter(|(_, is_remote, _, _)| !is_remote)
        .map(|(name, _, _, tip)| {
            // The checked-out branch needs no special case: `reachable_set`
            // includes the commit it starts from, so a branch that *is* main
            // finds its own tip in the set, and one that was merged into main
            // finds it there too — which the previous tip-equality test got
            // wrong for exactly that second case.
            let into_main = membership(reachable_from_main.as_ref(), *tip);
            let into_head = membership(reachable_from_head, *tip);
            (name.clone(), *tip, into_main, into_head)
        })
        .collect()
}

/// Keeps graph-derived branch state that the incoming snapshot did not compute.
///
/// A refresh replaces the branch list wholesale, but the fields that need a
/// history walk — merged flags, ahead/behind — are computed afterwards, off the
/// path a user is waiting on. Without this, every refresh would blank them and
/// the sidebar would flicker between "merged" and "unknown" on every watcher
/// tick until the follow-up landed.
///
/// Each answer is carried only when *both* commits it was derived from are
/// unchanged. A branch's own tip is not enough: "merged into HEAD" is a fact
/// about the branch and HEAD together, so checking out a different branch
/// invalidates it even though nothing about the branch moved. The same holds
/// for ahead/behind against a moved upstream, which is what a push does.
fn carry_forward_branch_graph_state(
    previous: &[BranchInfo],
    mut incoming: Vec<BranchInfo>,
) -> Vec<BranchInfo> {
    if previous.is_empty() {
        return incoming;
    }

    // An unresolvable reference point counts as changed, so the answer is
    // dropped rather than carried on an assumption.
    let trunk_unchanged =
        trunk_tip(previous).is_some() && trunk_tip(previous) == trunk_tip(&incoming);
    let head_unchanged = head_tip(previous).is_some() && head_tip(previous) == head_tip(&incoming);

    let known: std::collections::HashMap<(&str, Option<git2::Oid>), &BranchInfo> = previous
        .iter()
        .map(|branch| ((branch.name.as_str(), branch.tip_oid), branch))
        .collect();

    for index in 0..incoming.len() {
        let Some(before) = known
            .get(&(incoming[index].name.as_str(), incoming[index].tip_oid))
            .copied()
        else {
            continue;
        };

        if trunk_unchanged && incoming[index].is_merged_into_main.is_none() {
            incoming[index].is_merged_into_main = before.is_merged_into_main;
        }
        if head_unchanged && incoming[index].is_merged_into_head.is_none() {
            incoming[index].is_merged_into_head = before.is_merged_into_head;
        }

        if !incoming[index].has_ahead_behind() {
            let upstream_moved = match incoming[index].upstream.as_deref() {
                Some(upstream) => {
                    upstream_tip(previous, upstream) != upstream_tip(&incoming, upstream)
                }
                // No upstream to be ahead or behind of.
                None => true,
            };
            if !upstream_moved {
                incoming[index].ahead = before.ahead;
                incoming[index].behind = before.behind;
            }
        }
    }

    incoming
}

/// Tip of the branch the merged-into-main flag is measured against.
///
/// Same priority as [`merged_flags`] uses, so the carry-forward invalidates on
/// exactly the commit the flag was derived from.
fn trunk_tip(branches: &[BranchInfo]) -> Option<git2::Oid> {
    let named = |wanted: &str, remote: bool| {
        branches
            .iter()
            .find(|branch| branch.is_remote == remote && branch.name == wanted)
            .and_then(|branch| branch.tip_oid)
    };
    named("main", false)
        .or_else(|| named("master", false))
        .or_else(|| named("origin/main", true))
        .or_else(|| named("origin/master", true))
}

/// Tip of the checked-out branch, or `None` when HEAD is detached and no branch
/// in the list claims it.
fn head_tip(branches: &[BranchInfo]) -> Option<git2::Oid> {
    branches
        .iter()
        .find(|branch| branch.is_head)
        .and_then(|branch| branch.tip_oid)
}

/// Whether any local branch is missing graph state that a walk could supply.
///
/// The distinction that matters is between an answer nobody has computed yet
/// and one that does not exist. A repository whose trunk is neither `main` nor
/// `master` has nothing for `is_merged_into_main` to be about, and reading that
/// permanent `None` as outstanding work would put a full history walk and a
/// `git for-each-ref` behind every file save.
///
/// `head_detached` is passed separately because a detached HEAD still resolves
/// to a commit — the walk answers merged-into-HEAD from the repository, not
/// from this list — while no branch here claims to be it.
fn graph_state_is_incomplete(branches: &[BranchInfo], head_detached: bool) -> bool {
    let trunk = trunk_tip(branches);
    let head = head_tip(branches).is_some() || head_detached;
    branches.iter().any(|branch| {
        if branch.is_remote {
            return false;
        }
        let merged_into_main_pending =
            trunk.is_some() && branch.is_merged_into_main.is_none() && branch.tip_oid.is_some();
        let merged_into_head_pending =
            head && branch.is_merged_into_head.is_none() && branch.tip_oid.is_some();
        let ahead_behind_pending = branch
            .upstream
            .as_deref()
            .is_some_and(|upstream| upstream_tip(branches, upstream).is_some())
            && !branch.has_ahead_behind();
        merged_into_main_pending || merged_into_head_pending || ahead_behind_pending
    })
}

/// Tip of the remote-tracking branch `upstream`, by its full name.
fn upstream_tip(branches: &[BranchInfo], upstream: &str) -> Option<git2::Oid> {
    branches
        .iter()
        .find(|branch| branch.is_remote && branch.name == upstream)
        .and_then(|branch| branch.tip_oid)
}

/// Ahead/behind counts for every local branch that has an upstream.
///
/// One `git for-each-ref` rather than one `graph_ahead_behind` per branch.
/// libgit2's version walks both sides without consulting
/// `.git/objects/info/commit-graph`, so it costs a full object-parsing traversal
/// per branch; git's own does consult it. The OIDs still come from libgit2,
/// because the caller matches on them and parsing them back out of the
/// subprocess would only add a way to disagree.
fn ahead_behind_via_for_each_ref(
    repo_path: &Path,
    repo: &git2::Repository,
) -> Vec<(String, git2::Oid, git2::Oid, usize, usize)> {
    let output = git_command()
        .current_dir(repo_path)
        .args([
            "for-each-ref",
            // Not `%(refname:short)`: that shortens to a *non-ambiguous*
            // form, so a branch `foo` sharing its name with a tag comes back
            // as `heads/foo`. Nothing then finds it, and the branch that has
            // two things named after it is exactly the one whose counts a
            // user wants. The full name is unambiguous by construction.
            "--format=%(refname)%09%(upstream:track)",
            "refs/heads",
        ])
        .output();

    let Ok(output) = output else {
        return Vec::new();
    };
    if !output.status.success() {
        return Vec::new();
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut results = Vec::new();

    for line in stdout.lines() {
        let Some((refname, track)) = line.split_once('\t') else {
            continue;
        };
        let Some(name) = local_branch_name(refname) else {
            continue;
        };
        let Some((ahead, behind)) = parse_upstream_track(track) else {
            continue;
        };
        // A branch with no upstream, or a gone one, is not reported at all —
        // matching what the per-branch version did by skipping it.
        let Ok(branch) = repo.find_branch(name, git2::BranchType::Local) else {
            continue;
        };
        let (Some(local), Ok(upstream)) = (branch.get().target(), branch.upstream()) else {
            continue;
        };
        let Some(upstream_target) = upstream.get().target() else {
            continue;
        };
        results.push((name.to_string(), local, upstream_target, ahead, behind));
    }

    results
}

/// The branch name in a full local refname, spelled as the rest of the
/// snapshot spells it. Anything outside `refs/heads/` is not our business.
fn local_branch_name(refname: &str) -> Option<&str> {
    refname
        .strip_prefix("refs/heads/")
        .filter(|name| !name.is_empty())
}

/// Reads git's `%(upstream:track)` field into ahead/behind counts.
///
/// The field is prose, not data: `[ahead 2, behind 1]`, `[ahead 3]`,
/// `[behind 4]`, `[gone]`, or empty when the branch is level with its upstream.
/// Returning `None` covers both "no upstream" and "upstream gone", which are the
/// cases that have no counts to report.
fn parse_upstream_track(track: &str) -> Option<(usize, usize)> {
    let track = track.trim();
    if track.is_empty() {
        // An upstream that exists and matches exactly prints nothing. Only a
        // branch that has one is level with it, so this is 0/0 rather than
        // "not applicable" — but a branch with no upstream also prints nothing,
        // and the caller filters those out by looking the upstream up.
        return Some((0, 0));
    }
    let inner = track.strip_prefix('[')?.strip_suffix(']')?;
    if inner == "gone" {
        return None;
    }

    let mut ahead = 0;
    let mut behind = 0;
    for part in inner.split(',') {
        let part = part.trim();
        if let Some(count) = part.strip_prefix("ahead ") {
            ahead = count.trim().parse().ok()?;
        } else if let Some(count) = part.strip_prefix("behind ") {
            behind = count.trim().parse().ok()?;
        }
    }
    Some((ahead, behind))
}

#[cfg(test)]
mod carry_forward_tests {
    use super::{carry_forward_branch_graph_state, graph_state_is_incomplete, BranchInfo};

    /// [`graph_state_is_incomplete`] for a repository whose HEAD is on a branch,
    /// which is every case but the one test that says otherwise.
    fn needs_refresh(branches: &[BranchInfo]) -> bool {
        graph_state_is_incomplete(branches, false)
    }

    fn oid(byte: u8) -> git2::Oid {
        git2::Oid::from_bytes(&[byte; 20]).unwrap()
    }

    fn branch(name: &str, tip: u8) -> BranchInfo {
        BranchInfo {
            name: name.to_string(),
            is_head: false,
            is_remote: false,
            upstream: None,
            ahead: None,
            behind: None,
            tip_oid: Some(oid(tip)),
            author_email: None,
            last_commit_time: None,
            is_merged_into_main: None,
            is_merged_into_head: None,
        }
    }

    /// `main`, checked out, so both reference points resolve.
    fn trunk(tip: u8) -> BranchInfo {
        let mut main = branch("main", tip);
        main.is_head = true;
        main
    }

    fn remote(name: &str, tip: u8) -> BranchInfo {
        let mut branch = branch(name, tip);
        branch.is_remote = true;
        branch
    }

    /// A `feature` branch tracking `origin/feature`, with every answer known.
    fn tracked_feature(tip: u8) -> BranchInfo {
        let mut feature = branch("feature", tip);
        feature.upstream = Some("origin/feature".to_string());
        feature.is_merged_into_main = Some(true);
        feature.is_merged_into_head = Some(true);
        feature.ahead = Some(3);
        feature.behind = Some(2);
        feature
    }

    /// The same branch after the carry-forward, by name.
    fn feature_of(branches: &[BranchInfo]) -> &BranchInfo {
        branches
            .iter()
            .find(|branch| branch.name == "feature")
            .expect("the feature branch survives the carry-forward")
    }

    #[test]
    fn a_repository_with_no_trunk_does_not_ask_for_the_walk_forever() {
        // `develop`, checked out, with no `main` or `master` anywhere. The
        // merged-into-main answer is unavailable, not outstanding, and reading
        // it as outstanding would put a full history walk behind every file
        // save for the life of the repository.
        let mut develop = branch("develop", 1);
        develop.is_head = true;
        develop.is_merged_into_head = Some(true);
        assert!(!needs_refresh(&[develop]));
    }

    #[test]
    fn a_branch_tracking_an_upstream_nothing_lists_does_not_ask_either() {
        // The upstream ref is gone — deleted on the remote, or never fetched.
        // Nothing a walk can do will produce counts against it.
        let mut orphan = branch("feature", 2);
        orphan.upstream = Some("origin/feature".to_string());
        orphan.is_merged_into_head = Some(false);
        assert!(!needs_refresh(&[orphan]));
    }

    #[test]
    fn a_detached_head_still_asks_for_the_walk() {
        // `git checkout <commit>` in a terminal leaves no branch marked
        // `is_head`, but HEAD still resolves and the walk can still answer.
        // Treating the missing branch as a missing reference point would strand
        // every merged-into-current badge as unknown.
        let feature = branch("feature", 2);
        assert!(!needs_refresh(std::slice::from_ref(&feature)));
        assert!(graph_state_is_incomplete(&[feature], true));
    }

    #[test]
    fn a_missing_answer_that_a_walk_could_supply_still_asks() {
        // `main` is present, so merged-into-main is a question with an answer,
        // and nothing has supplied it.
        let feature = branch("feature", 2);
        assert!(needs_refresh(&[trunk(1), feature]));
    }

    #[test]
    fn a_fully_answered_repository_asks_for_nothing() {
        let branches = vec![
            {
                let mut main = trunk(1);
                main.is_merged_into_main = Some(true);
                main.is_merged_into_head = Some(true);
                main
            },
            tracked_feature(2),
            remote("origin/feature", 2),
        ];
        assert!(!needs_refresh(&branches));
    }

    /// An incoming `feature` that tracks its upstream and knows nothing else.
    fn incoming_feature(tip: u8) -> BranchInfo {
        let mut feature = branch("feature", tip);
        feature.upstream = Some("origin/feature".to_string());
        feature
    }

    #[test]
    fn answers_the_snapshot_did_not_compute_keep_their_previous_values() {
        let before = vec![trunk(1), remote("origin/feature", 5), tracked_feature(2)];
        let incoming = vec![trunk(1), remote("origin/feature", 5), incoming_feature(2)];

        let after = carry_forward_branch_graph_state(&before, incoming);
        let feature = feature_of(&after);

        assert_eq!(feature.is_merged_into_main, Some(true));
        assert_eq!(feature.is_merged_into_head, Some(true));
        assert_eq!((feature.ahead, feature.behind), (Some(3), Some(2)));
    }

    #[test]
    fn a_moved_tip_discards_what_was_known_about_the_old_one() {
        // The answers described the previous commit. Showing them against a new
        // one would be worse than showing nothing.
        let before = vec![trunk(1), remote("origin/feature", 5), tracked_feature(2)];
        let incoming = vec![trunk(1), remote("origin/feature", 5), incoming_feature(9)];

        let after = carry_forward_branch_graph_state(&before, incoming);
        let feature = feature_of(&after);

        assert_eq!(feature.is_merged_into_main, None);
        assert_eq!(feature.ahead, None);
    }

    #[test]
    fn checking_out_another_branch_invalidates_merged_into_head_but_not_into_main() {
        // The branch did not move; the thing it was compared against did. This
        // is the case a tip-only key cannot see, and it is the common one — it
        // is what `git checkout` in a terminal looks like from here.
        let before = vec![trunk(1), tracked_feature(2)];

        let mut moved_head = incoming_feature(2);
        moved_head.is_head = true;
        let incoming = vec![branch("main", 1), moved_head];

        let after = carry_forward_branch_graph_state(&before, incoming);
        let feature = feature_of(&after);

        assert_eq!(
            feature.is_merged_into_head, None,
            "HEAD moved, so the answer measured against the old HEAD is gone"
        );
        assert_eq!(
            feature.is_merged_into_main,
            Some(true),
            "main did not move, so that answer still holds"
        );
    }

    #[test]
    fn a_moved_trunk_invalidates_merged_into_main() {
        let before = vec![trunk(1), tracked_feature(2)];
        let incoming = vec![trunk(7), incoming_feature(2)];

        let after = carry_forward_branch_graph_state(&before, incoming);
        assert_eq!(feature_of(&after).is_merged_into_main, None);
    }

    #[test]
    fn pushing_a_branch_does_not_leave_it_reporting_the_old_ahead_count() {
        // A push moves the upstream and leaves the local tip alone, so a key
        // built only from the local tip matches and carries "ahead 3" onto a
        // branch that is now level.
        let before = vec![trunk(1), remote("origin/feature", 5), tracked_feature(2)];
        let incoming = vec![trunk(1), remote("origin/feature", 2), incoming_feature(2)];

        let after = carry_forward_branch_graph_state(&before, incoming);
        let feature = feature_of(&after);

        assert_eq!((feature.ahead, feature.behind), (None, None));
        assert_eq!(
            feature.is_merged_into_main,
            Some(true),
            "the upstream is irrelevant to the merged flags"
        );
    }

    #[test]
    fn a_branch_level_with_its_upstream_is_not_mistaken_for_an_uncomputed_one() {
        // `Some(0)` is an answer. The sentinel this replaced could not tell it
        // from "no walk has run", and overwrote it with whatever came before.
        let before = vec![trunk(1), remote("origin/feature", 2), tracked_feature(2)];
        let mut level = incoming_feature(2);
        level.ahead = Some(0);
        level.behind = Some(0);
        let incoming = vec![trunk(1), remote("origin/feature", 2), level];

        let after = carry_forward_branch_graph_state(&before, incoming);
        let feature = feature_of(&after);

        assert_eq!((feature.ahead, feature.behind), (Some(0), Some(0)));
    }

    #[test]
    fn a_freshly_computed_flag_wins_over_the_old_one() {
        let mut stale = tracked_feature(2);
        stale.is_merged_into_main = Some(false);
        let before = vec![trunk(1), stale];

        let mut fresh = incoming_feature(2);
        fresh.is_merged_into_main = Some(true);
        let incoming = vec![trunk(1), fresh];

        let after = carry_forward_branch_graph_state(&before, incoming);
        assert_eq!(feature_of(&after).is_merged_into_main, Some(true));
    }

    #[test]
    fn a_branch_that_is_new_is_left_alone() {
        let before = vec![trunk(1), branch("old", 3)];
        let after = carry_forward_branch_graph_state(&before, vec![trunk(1), branch("new", 9)]);

        assert_eq!(after.len(), 2);
        let fresh = after
            .iter()
            .find(|branch| branch.name == "new")
            .expect("the new branch is present");
        assert_eq!(fresh.is_merged_into_main, None);
    }

    #[test]
    fn nothing_is_carried_when_the_reference_points_cannot_be_resolved() {
        // No trunk in the list and no branch claiming HEAD: both answers were
        // measured against something this snapshot cannot identify, so neither
        // is safe to keep.
        let before = vec![tracked_feature(2)];
        let after = carry_forward_branch_graph_state(&before, vec![incoming_feature(2)]);

        assert_eq!(after[0].is_merged_into_main, None);
        assert_eq!(after[0].is_merged_into_head, None);
    }
}

#[cfg(test)]
mod ahead_behind_tests {
    use super::{local_branch_name, parse_upstream_track};

    #[test]
    fn a_full_refname_gives_the_name_the_snapshot_uses() {
        assert_eq!(local_branch_name("refs/heads/main"), Some("main"));
        assert_eq!(
            local_branch_name("refs/heads/feature/login"),
            Some("feature/login")
        );
    }

    #[test]
    fn a_branch_sharing_a_tag_s_name_still_resolves() {
        // This is the case `%(refname:short)` used to lose: with both
        // `refs/heads/release` and `refs/tags/release` present, git shortens
        // the branch to `heads/release`, which matches no branch at all and
        // left the counts unknown for the one branch anybody would be watching.
        assert_eq!(local_branch_name("refs/heads/release"), Some("release"));
    }

    #[test]
    fn anything_that_is_not_a_local_branch_is_declined() {
        assert_eq!(local_branch_name("refs/tags/v1.0.0"), None);
        assert_eq!(local_branch_name("refs/remotes/origin/main"), None);
        assert_eq!(local_branch_name("refs/heads/"), None);
        assert_eq!(local_branch_name("main"), None);
    }

    #[test]
    fn a_level_branch_prints_nothing_and_is_zero_zero() {
        assert_eq!(parse_upstream_track(""), Some((0, 0)));
        assert_eq!(parse_upstream_track("   "), Some((0, 0)));
    }

    #[test]
    fn both_directions_are_read() {
        assert_eq!(parse_upstream_track("[ahead 2, behind 1]"), Some((2, 1)));
    }

    #[test]
    fn one_direction_leaves_the_other_at_zero() {
        assert_eq!(parse_upstream_track("[ahead 3]"), Some((3, 0)));
        assert_eq!(parse_upstream_track("[behind 4]"), Some((0, 4)));
    }

    #[test]
    fn a_gone_upstream_has_no_counts() {
        assert_eq!(parse_upstream_track("[gone]"), None);
    }

    #[test]
    fn unparseable_input_is_rejected_rather_than_guessed() {
        assert_eq!(parse_upstream_track("[ahead many]"), None);
        assert_eq!(parse_upstream_track("ahead 2"), None);
    }
}

#[cfg(test)]
mod tests {
    use super::{normalize_repo_path, GitProject};
    use rgitui_test_support::TempRepo;
    use std::path::PathBuf;

    fn has_adjacent_legacy_change_events(source: &str) -> bool {
        let is_legacy = |line: &str| {
            let line = line.trim();
            line == "cx.emit(GitProjectEvent::StatusChanged);"
                || line == "cx.emit(GitProjectEvent::HeadChanged);"
                || line == "cx.emit(GitProjectEvent::RefsChanged);"
        };
        source
            .lines()
            .zip(source.lines().skip(1))
            .any(|(left, right)| is_legacy(left) && is_legacy(right))
    }

    #[test]
    fn background_work_is_reported_until_every_guard_drops() {
        let project = GitProject::empty_at(PathBuf::from("."));
        assert!(!project.has_background_work());

        let first = project.track_background_work();
        let second = project.track_background_work();
        assert!(project.has_background_work());

        drop(first);
        assert!(
            project.has_background_work(),
            "one refresh finishing must not make a project with another in flight look idle"
        );

        drop(second);
        assert!(!project.has_background_work());
    }

    #[test]
    fn a_dropped_refresh_still_lowers_the_background_count() {
        // A task cancelled by a newer refresh never reaches its own completion
        // path, so the count has to come down from `Drop` or anything waiting
        // for the project to settle waits forever.
        let project = GitProject::empty_at(PathBuf::from("."));
        {
            let _abandoned = project.track_background_work();
            assert!(project.has_background_work());
        }
        assert!(!project.has_background_work());
    }

    #[test]
    fn aggregate_operations_do_not_emit_adjacent_legacy_change_events() {
        for source in [
            include_str!("local_ops.rs"),
            include_str!("network.rs"),
            include_str!("rebase.rs"),
        ] {
            assert!(!has_adjacent_legacy_change_events(source));
        }
    }

    /// Build a repo with one commit containing `tracked.txt`.
    fn repo_with_one_commit() -> TempRepo {
        let fixture = TempRepo::init();
        fixture.commit_file("tracked.txt", "original\n", "initial");
        fixture
    }

    #[test]
    fn untracked_files_do_not_make_the_worktree_dirty() {
        let fixture = repo_with_one_commit();
        let repo = fixture.repo();
        assert!(!super::repo_has_worktree_changes(repo).unwrap());

        // A scratch file with no .gitignore entry must not block checkout.
        fixture.write_file("notes.txt", "scratch");
        fixture.write_file("build/out.o", "junk");

        assert!(
            !super::repo_has_worktree_changes(repo).unwrap(),
            "untracked files must not count as worktree changes"
        );
        assert!(super::ensure_clean_worktree(repo, "Checkout").is_ok());
    }

    #[test]
    fn modified_tracked_files_make_the_worktree_dirty() {
        let fixture = repo_with_one_commit();
        fixture.write_file("tracked.txt", "edited\n");

        assert!(super::repo_has_worktree_changes(fixture.repo()).unwrap());
        let err = super::ensure_clean_worktree(fixture.repo(), "Checkout").unwrap_err();
        assert!(err.to_string().contains("Checkout"));
    }

    #[test]
    fn staged_changes_make_the_worktree_dirty() {
        let fixture = repo_with_one_commit();
        fixture.write_file("staged.txt", "new\n");
        fixture.stage("staged.txt");

        assert!(
            super::repo_has_worktree_changes(fixture.repo()).unwrap(),
            "a staged addition is a tracked change"
        );
    }

    #[test]
    fn normalize_non_unc_path_unchanged() {
        let path = PathBuf::from("/home/user/repo");
        assert_eq!(normalize_repo_path(path.clone()), path);
    }

    #[test]
    fn normalize_relative_path_unchanged() {
        let path = PathBuf::from("./my-repo");
        assert_eq!(normalize_repo_path(path.clone()), path);
    }

    #[test]
    fn changing_commit_author_filter_invalidates_async_commit_queries() {
        let mut project = GitProject::empty_at(PathBuf::from("repo"));
        let initial = project.commit_query_generation;
        project.load_more_in_flight = true;

        project.set_commit_author_filter(Some("person+tag@example.com".to_string()));

        assert_ne!(project.commit_query_generation, initial);
        assert!(!project.load_more_in_flight);
        assert!(project.recent_commits.is_empty());
        assert_eq!(project.commit_offset, 0);
        assert!(project.has_more_commits);

        let unchanged = project.commit_query_generation;
        project.set_commit_author_filter(Some("person+tag@example.com".to_string()));
        assert_eq!(project.commit_query_generation, unchanged);
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn normalize_wsl_localhost_unc_path() {
        let input = PathBuf::from(r"\\wsl.localhost\archlinux\home\user\repo");
        let expected = PathBuf::from("//wsl.localhost/archlinux/home/user/repo");
        assert_eq!(normalize_repo_path(input), expected);
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn normalize_wsl_dollar_unc_path() {
        let input = PathBuf::from(r"\\wsl$\Ubuntu\home\user\project");
        let expected = PathBuf::from("//wsl$/Ubuntu/home/user/project");
        assert_eq!(normalize_repo_path(input), expected);
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn normalize_windows_drive_path_unchanged() {
        // Regular Windows drive paths must not be modified.
        let path = PathBuf::from(r"C:\Users\user\repo");
        assert_eq!(normalize_repo_path(path.clone()), path);
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn normalize_network_share_unc_path() {
        let input = PathBuf::from(r"\\server\share\project");
        let expected = PathBuf::from("//server/share/project");
        assert_eq!(normalize_repo_path(input), expected);
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn normalize_extended_length_prefix_unchanged() {
        // \\?\ is the Windows extended-length prefix; std::fs::canonicalize
        // emits it and libgit2 does not accept the slash-converted form.
        let path = PathBuf::from(r"\\?\C:\Users\user\repo");
        assert_eq!(normalize_repo_path(path.clone()), path);
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn normalize_device_namespace_prefix_unchanged() {
        let path = PathBuf::from(r"\\.\C:\Users\user\repo");
        assert_eq!(normalize_repo_path(path.clone()), path);
    }
}
