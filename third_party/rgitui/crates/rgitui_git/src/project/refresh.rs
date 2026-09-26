use anyhow::{Context as _, Result};
use chrono::{TimeZone, Utc};
use git2::{Repository, StatusOptions};
use std::collections::{hash_map::DefaultHasher, HashMap, HashSet};
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use crate::types::*;

use super::diff::batch_diff_stats;
use super::git_command;
use super::GitProject;
use super::GitProjectEvent;
use super::RefreshData;

pub(super) const MAX_COMMIT_LIMIT: usize = 100_000;

pub(super) fn normalize_commit_limit(limit: usize) -> usize {
    limit.clamp(1, MAX_COMMIT_LIMIT)
}

/// Per-worktree status cache: maps the worktree path to a (fingerprint, status) pair.
/// The fingerprint is derived from `repo.statuses()` output so it reflects both index
/// and working-tree changes, not just `.git` sentinel file mtimes.
pub(super) type WorktreeStatusCache = HashMap<PathBuf, (u64, WorkingTreeStatus)>;

/// Remove valid Co-Authored-By trailer lines from a commit message.
/// Only strips lines that have a parseable `Name <email>` format.
pub(super) fn clean_co_author_lines(message: &str) -> String {
    let prefix = "co-authored-by:";
    let cleaned_lines: Vec<&str> = message
        .lines()
        .filter(|line| {
            let lower = line.trim().to_ascii_lowercase();
            if !lower.starts_with(prefix) {
                return true;
            }
            let rest = &line.trim()[prefix.len()..].trim();
            let has_email = rest.contains('<') && rest.contains('>');
            if !has_email {
                return true;
            }
            if let Some(start) = rest.find('<') {
                if let Some(end) = rest.find('>') {
                    let name = rest[..start].trim();
                    let email = rest[start + 1..end].trim();
                    return name.is_empty() || email.is_empty();
                }
            }
            true
        })
        .collect();
    let cleaned = cleaned_lines.join("\n");
    cleaned.trim_end().to_string()
}

/// Extract Co-Authored-By signatures from a commit message.
pub fn extract_co_authors(message: &str) -> Vec<Signature> {
    let prefix = "co-authored-by:";
    let mut co_authors = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for line in message.lines() {
        let trimmed = line.trim();
        let lower = trimmed.to_ascii_lowercase();
        if lower.starts_with(prefix) {
            let rest = &trimmed[prefix.len()..].trim();
            if let Some(email_start) = rest.find('<') {
                if let Some(email_end) = rest.find('>') {
                    let name = rest[..email_start].trim().to_string();
                    let email = rest[email_start + 1..email_end].trim().to_string();
                    let identity = (name.to_lowercase(), email.to_lowercase());
                    if !name.is_empty() && !email.is_empty() && seen.insert(identity) {
                        co_authors.push(Signature { name, email });
                    }
                }
            }
        }
    }
    co_authors
}

/// Combined: clean message and extract co-authors in one pass.
#[cfg(test)]
fn parse_co_authors(message: &str) -> (String, Vec<Signature>) {
    let co_authors = extract_co_authors(message);
    let cleaned = clean_co_author_lines(message);
    (cleaned, co_authors)
}

/// Record separator that won't appear in commit messages.
const LOG_RECORD_SEP: &str = "\x1e";
/// Field separator within a single commit-log record.
const LOG_FIELD_SEP: &str = "\x1d";

/// The `--format` argument value for the commit-log subprocess, shared by the
/// full-refresh loader and the incremental load-more loader so the field layout
/// stays in lockstep. Fields, in order: oid, short_id, author_name,
/// author_email, committer_name, committer_email, timestamp, parent_oids,
/// summary, body.
fn commit_log_format() -> String {
    format!(
        "{rs}%H{gs}%h{gs}%an{gs}%ae{gs}%cn{gs}%ce{gs}%ct{gs}%P{gs}%s{gs}%b{gs}",
        rs = LOG_RECORD_SEP,
        gs = LOG_FIELD_SEP,
    )
}

/// Parse the stdout of a `git log --format=commit_log_format()` invocation into
/// `CommitInfo`s, attaching ref labels from `ref_map`.
///
/// Every record in `stdout` is parsed; pagination (the `-(limit + 1)` extra
/// record that signals "there are more", and the stable-cursor windowing used
/// by the incremental loader) is owned by the callers, so a single parser
/// serves both the full-refresh and load-more paths.
fn parse_git_log_records(
    stdout: &str,
    ref_map: &mut HashMap<git2::Oid, Vec<RefLabel>>,
) -> Vec<CommitInfo> {
    let mut commits = Vec::new();

    for record in stdout.split(LOG_RECORD_SEP) {
        let record = record.trim();
        if record.is_empty() {
            continue;
        }

        let fields: Vec<&str> = record.splitn(11, LOG_FIELD_SEP).collect();
        if fields.len() < 10 {
            continue;
        }

        let oid = match git2::Oid::from_str(fields[0]) {
            Ok(o) => o,
            Err(_) => continue,
        };
        let short_id = fields[1].to_string();
        let author_name = fields[2].to_string();
        let author_email = fields[3].to_string();
        let committer_name = fields[4].to_string();
        let committer_email = fields[5].to_string();
        let timestamp: i64 = fields[6].parse().unwrap_or(0);
        let parent_oids: Vec<git2::Oid> = fields[7]
            .split_whitespace()
            .filter_map(|s| git2::Oid::from_str(s).ok())
            .collect();
        let summary = fields[8].to_string();
        let body = fields[9].trim();
        let message = if body.is_empty() {
            summary.clone()
        } else {
            format!("{}\n\n{}", summary, clean_co_author_lines(body))
        };

        let time = Utc.timestamp_opt(timestamp, 0).single();
        let refs = ref_map.remove(&oid).unwrap_or_default();

        commits.push(CommitInfo {
            oid,
            short_id,
            summary,
            message,
            author: Signature {
                name: author_name,
                email: author_email,
            },
            committer: Signature {
                name: committer_name,
                email: committer_email,
            },
            co_authors: Vec::new(),
            time: time.unwrap_or_else(Utc::now),
            parent_oids,
            refs,
            is_signed: false,
        });
    }

    commits
}

/// Canonical form used to compare two working-tree paths for identity. Git
/// reports the same checkout through several spellings (trailing separator,
/// `/` vs `\` on Windows, differing case), so raw `PathBuf` equality would let
/// the same worktree appear twice. Falls back to the path as given when it
/// cannot be resolved — e.g. a registry entry whose directory was deleted.
fn worktree_identity(path: &Path) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

/// Read the checked-out branch and HEAD commit of `repo`.
///
/// git2's `shorthand()` returns a short OID rather than `None` on a detached
/// HEAD, so the detached case is reported separately and `branch` left empty —
/// otherwise every caller renders `a1b2c3d` as if it were a branch name.
fn head_summary(repo: &Repository) -> (Option<String>, bool, Option<git2::Oid>) {
    let detached = repo.head_detached().unwrap_or(false);
    let head = repo.head().ok();
    let branch = if detached {
        None
    } else {
        head.as_ref().and_then(|h| h.shorthand().map(String::from))
    };
    let head_oid = head.and_then(|h| h.target());
    (branch, detached, head_oid)
}

/// The branch a HEAD reflog message says HEAD was switched away from.
///
/// Every checkout records `checkout: moving from <from> to <to>` — git's own
/// `checkout` and `switch`, and libgit2's `set_head` and `set_head_detached`
/// alike. `<from>` is a branch name, or a commit id when HEAD was already
/// detached. Ref names cannot contain spaces, so the first ` to ` ends it.
fn checkout_source(message: &str) -> Option<&str> {
    let (from, _to) = message
        .strip_prefix("checkout: moving from ")?
        .split_once(" to ")?;
    (!from.is_empty()).then_some(from)
}

/// The local branch HEAD was most recently switched away from, other than
/// `current`, provided it still exists.
///
/// Commits HEAD was detached at are passed over rather than ending the search,
/// so after stepping from commit to commit the branch the user started on is
/// still what comes back.
pub(crate) fn previous_branch(repo: &Repository, current: Option<&str>) -> Option<String> {
    let reflog = repo.reflog("HEAD").ok()?;
    reflog
        .iter()
        .filter_map(|entry| entry.message().and_then(checkout_source).map(str::to_owned))
        .find(|from| {
            Some(from.as_str()) != current
                && repo.find_branch(from, git2::BranchType::Local).is_ok()
        })
}

/// Build a [`WorktreeInfo`] for the checkout at `path` by opening it directly.
fn worktree_info_at(
    name: String,
    path: PathBuf,
    is_locked: bool,
    is_current: bool,
) -> WorktreeInfo {
    let opened = Repository::open(&path);
    let (branch, head_detached, head_oid) = opened
        .as_ref()
        .map(head_summary)
        .unwrap_or((None, false, None));
    let state = opened
        .as_ref()
        .map(|repo| RepoState::from_git2(repo.state()))
        .unwrap_or(RepoState::Clean);
    WorktreeInfo {
        name,
        path,
        is_locked,
        is_current,
        branch,
        head_detached,
        head_oid,
        status: None,
        state,
    }
}

/// Gather information about all worktrees attached to this repository.
///
/// Three sources are merged, deduplicated by canonical path:
/// 1. `repo.workdir()` — the checkout rgitui was opened on (`is_current`).
/// 2. The main checkout, derived from the common git dir. It is absent from
///    `repo.worktrees()` (which lists only *linked* worktrees), so without this
///    step it has no row at all when rgitui was opened on a linked worktree.
/// 3. `repo.worktrees()` — the linked-worktree registry, which still contains
///    the current checkout when that checkout is itself a linked worktree.
fn gather_worktrees(repo: &Repository) -> Vec<WorktreeInfo> {
    let mut worktrees = Vec::new();
    let mut seen: HashSet<PathBuf> = HashSet::new();

    // The checkout this Repository handle points at.
    let workdir = repo.workdir().unwrap_or_else(|| repo.path()).to_path_buf();
    let current_name = workdir
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("main")
        .to_string();
    let (branch, head_detached, head_oid) = head_summary(repo);
    seen.insert(worktree_identity(&workdir));
    worktrees.push(WorktreeInfo {
        name: current_name,
        path: workdir,
        is_locked: false,
        is_current: true,
        branch,
        head_detached,
        head_oid,
        status: None,
        state: RepoState::from_git2(repo.state()),
    });

    // The main checkout, when this handle was opened on a linked worktree. A
    // linked worktree's git dir is `<common>/worktrees/<name>`, so the common
    // dir's parent is where the main working directory should be. That is only
    // a guess — a bare repository has no checkout there, and an unrelated
    // repository could sit at that path — so it counts only if opening it
    // yields a working directory sharing our common git dir.
    let common_dir = repo.commondir().to_path_buf();
    if common_dir != repo.path() {
        if let Some(main_workdir) = common_dir
            .parent()
            .and_then(|candidate| Repository::open(candidate).ok())
            .filter(|main| main.commondir() == common_dir)
            .and_then(|main| main.workdir().map(Path::to_path_buf))
        {
            if seen.insert(worktree_identity(&main_workdir)) {
                if let Some(name) = main_workdir.file_name().and_then(|n| n.to_str()) {
                    let name = name.to_string();
                    worktrees.push(worktree_info_at(name, main_workdir, false, false));
                }
            }
        }
    }

    // The linked-worktree registry, shared by every checkout of this repository.
    if let Ok(names) = repo.worktrees() {
        for name in names.iter().flatten() {
            if name.is_empty() {
                continue;
            }
            if let Ok(wt) = repo.find_worktree(name) {
                let path = wt.path().to_path_buf();
                if !seen.insert(worktree_identity(&path)) {
                    // Already listed — this is the checkout rgitui was opened on.
                    continue;
                }
                let is_locked = match wt.is_locked() {
                    Ok(git2::WorktreeLockStatus::Locked(_)) => true,
                    Ok(git2::WorktreeLockStatus::Unlocked) | Err(_) => false,
                };
                worktrees.push(worktree_info_at(name.to_string(), path, is_locked, false));
            }
        }
    }

    // Sort: current worktree first, then alphabetically by name
    worktrees.sort_by(|a, b| {
        if a.is_current != b.is_current {
            return b.is_current.cmp(&a.is_current);
        }
        a.name.cmp(&b.name)
    });

    worktrees
}

/// Files at or below this size are content-hashed in full when fingerprinting
/// the working tree; larger ones are sampled (see [`mix_file_contents`]).
const FINGERPRINT_FULL_READ_LIMIT: u64 = 64 * 1024;

/// Bytes taken from each end of a file that exceeds the full-read limit.
const FINGERPRINT_SAMPLE_LEN: u64 = 32 * 1024;

/// Mix a workdir file's contents into `hasher`, reading a bounded number of
/// bytes.
///
/// Size and mtime alone are not enough: a coarse-timestamp filesystem (FAT32,
/// some network/WSL/SMB mounts) can hold both steady across an edit. But
/// reading whole files here is unaffordable — this runs for every modified file
/// on every refresh, including the watcher's cached path, so a single large
/// file in the working tree would be re-read every few hundred milliseconds.
///
/// Small files are hashed whole. Larger ones are sampled at both ends, which
/// still catches ordinary edits while keeping the work per file constant.
fn mix_file_contents(hasher: &mut DefaultHasher, path: &Path, len: u64) {
    use std::io::{Read as _, Seek as _, SeekFrom};

    if len <= FINGERPRINT_FULL_READ_LIMIT {
        if let Ok(contents) = std::fs::read(path) {
            contents.hash(hasher);
        }
        return;
    }

    let Ok(mut file) = std::fs::File::open(path) else {
        return;
    };
    let sample = FINGERPRINT_SAMPLE_LEN as usize;
    let mut buf = vec![0u8; sample];

    if file.read_exact(&mut buf).is_ok() {
        buf.hash(hasher);
    }
    if file.seek(SeekFrom::End(-(sample as i64))).is_ok() && file.read_exact(&mut buf).is_ok() {
        buf.hash(hasher);
    }
}

/// Build a cheap fingerprint from `repo.statuses()` output.
///
/// Captures: file paths, status flags, staged blob OIDs (index state), and
/// mtime+size plus bounded content sampling for workdir-modified tracked files
/// (content changes that don't move through the index). This is fast — libgit2
/// uses its own stat cache for `statuses()`, and the additional `metadata()`
/// calls are only for files already flagged as workdir-modified.
fn status_fingerprint(repo_path: &Path, statuses: &git2::Statuses<'_>) -> u64 {
    let mut hasher = DefaultHasher::new();
    for entry in statuses.iter() {
        let path = entry.path().unwrap_or("");
        path.hash(&mut hasher);
        entry.status().bits().hash(&mut hasher);
        if let Some(delta) = entry.head_to_index() {
            delta.new_file().id().as_bytes().hash(&mut hasher);
        }
        if entry.status().intersects(
            git2::Status::WT_MODIFIED | git2::Status::WT_RENAMED | git2::Status::WT_TYPECHANGE,
        ) {
            let full_path = repo_path.join(path);
            if let Ok(meta) = std::fs::metadata(&full_path) {
                meta.len().hash(&mut hasher);
                if let Ok(mtime) = meta.modified() {
                    mtime.hash(&mut hasher);
                }
                mix_file_contents(&mut hasher, &full_path, meta.len());
            }
        }
    }
    hasher.finish()
}

/// Gather all refresh data from a repository at the given path.
/// This is a standalone function (no `&self`) so it can run on a background thread.
fn compute_working_tree_status(
    repo_path: &Path,
    cache: Option<&Mutex<WorktreeStatusCache>>,
) -> Result<WorkingTreeStatus> {
    let repo = Repository::open(repo_path)?;
    let mut wt_status = WorkingTreeStatus::default();

    let mut opts = StatusOptions::new();
    opts.include_untracked(true)
        .recurse_untracked_dirs(true)
        .include_unmodified(false);

    let statuses = repo.statuses(Some(&mut opts))?;

    // Compute fingerprint once; used for both the cache read and the cache write.
    let fingerprint = cache.map(|_| status_fingerprint(repo_path, &statuses));

    if let (Some(fp), Some(c)) = (fingerprint, cache) {
        let guard = c.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((cached_fp, cached_status)) = guard.get(repo_path) {
            if *cached_fp == fp {
                log::debug!("worktree status cache hit: {}", repo_path.display());
                return Ok(cached_status.clone());
            }
        }
    }

    // Scoped OS threads rather than the executor: this whole function already
    // runs on a background thread and borrows `repo_path`, so a scope keeps the
    // borrow and costs two thread spawns, where routing through the executor
    // would make every gather function async up to its call sites.
    let (staged_stats, unstaged_stats) = std::thread::scope(|s| {
        let staged_handle = s.spawn(|| {
            let repo = Repository::open(repo_path).ok();
            repo.as_ref()
                .map(|r| batch_diff_stats(r, true))
                .unwrap_or_default()
        });
        let unstaged_handle = s.spawn(|| {
            let repo = Repository::open(repo_path).ok();
            repo.as_ref()
                .map(|r| batch_diff_stats(r, false))
                .unwrap_or_default()
        });
        (
            staged_handle.join().unwrap_or_default(),
            unstaged_handle.join().unwrap_or_default(),
        )
    });

    for entry in statuses.iter() {
        let path = PathBuf::from(entry.path().unwrap_or(""));
        let st = entry.status();

        if st.intersects(
            git2::Status::INDEX_NEW
                | git2::Status::INDEX_MODIFIED
                | git2::Status::INDEX_DELETED
                | git2::Status::INDEX_RENAMED
                | git2::Status::INDEX_TYPECHANGE,
        ) {
            let kind = if st.contains(git2::Status::INDEX_NEW) {
                FileChangeKind::Added
            } else if st.contains(git2::Status::INDEX_MODIFIED) {
                FileChangeKind::Modified
            } else if st.contains(git2::Status::INDEX_DELETED) {
                FileChangeKind::Deleted
            } else if st.contains(git2::Status::INDEX_RENAMED) {
                FileChangeKind::Renamed
            } else {
                FileChangeKind::TypeChange
            };
            let &(additions, deletions) = staged_stats.get(&path).unwrap_or(&(0, 0));
            wt_status.staged.push(FileStatus {
                path: path.clone(),
                kind,
                old_path: None,
                additions,
                deletions,
            });
        }

        if st.intersects(
            git2::Status::WT_NEW
                | git2::Status::WT_MODIFIED
                | git2::Status::WT_DELETED
                | git2::Status::WT_RENAMED
                | git2::Status::WT_TYPECHANGE,
        ) {
            let kind = if st.contains(git2::Status::WT_NEW) {
                FileChangeKind::Untracked
            } else if st.contains(git2::Status::WT_MODIFIED) {
                FileChangeKind::Modified
            } else if st.contains(git2::Status::WT_DELETED) {
                FileChangeKind::Deleted
            } else if st.contains(git2::Status::WT_RENAMED) {
                FileChangeKind::Renamed
            } else {
                FileChangeKind::TypeChange
            };
            let &(additions, deletions) = unstaged_stats.get(&path).unwrap_or(&(0, 0));
            wt_status.unstaged.push(FileStatus {
                path: path.clone(),
                kind,
                old_path: None,
                additions,
                deletions,
            });
        }

        if st.contains(git2::Status::CONFLICTED) {
            wt_status.unstaged.push(FileStatus {
                path,
                kind: FileChangeKind::Conflicted,
                old_path: None,
                additions: 0,
                deletions: 0,
            });
        }
    }

    if let (Some(fp), Some(c)) = (fingerprint, cache) {
        c.lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(repo_path.to_path_buf(), (fp, wt_status.clone()));
    }

    Ok(wt_status)
}

pub fn gather_refresh_data(repo_path: &Path, commit_limit: usize) -> Result<RefreshData> {
    log::debug!("gather_refresh_data: repo={}", repo_path.display());
    gather_refresh_data_internal(repo_path, true, commit_limit, None, None)
}

/// Gather refresh data without computing ahead/behind for every branch.
///
/// Use this for filesystem watcher events where only file status needs updating.
/// Ahead/behind values will be (0, 0) — they'll be recomputed on the next
/// full refresh from a git operation (fetch/push/pull) or explicit user refresh.
pub fn gather_refresh_data_lightweight(
    repo_path: &Path,
    commit_limit: usize,
) -> Result<RefreshData> {
    log::debug!(
        "gather_refresh_data_lightweight: repo={}",
        repo_path.display()
    );
    gather_refresh_data_internal(repo_path, false, commit_limit, None, None)
}

/// Like `gather_refresh_data_lightweight` but uses the per-worktree status cache to skip
/// `batch_diff_stats` for worktrees whose content has not changed since the last refresh.
///
/// `author_filter`, when `Some`, restricts the loaded commit list to commits by
/// that author so a watcher-driven refresh keeps the "My Commits" view intact
/// instead of replacing it with the full unfiltered log.
pub(super) fn gather_refresh_data_lightweight_cached(
    repo_path: &Path,
    commit_limit: usize,
    cache: &Mutex<WorktreeStatusCache>,
    author_filter: Option<&str>,
) -> Result<RefreshData> {
    log::debug!(
        "gather_refresh_data_lightweight_cached: repo={}",
        repo_path.display()
    );
    gather_refresh_data_internal(repo_path, false, commit_limit, Some(cache), author_filter)
}

/// Every commit reachable from `tip`, including `tip` itself.
///
/// A branch is merged into `tip` exactly when its own tip appears in this set,
/// which is the same answer `merge_base(branch_tip, tip) == branch_tip` gives
/// and costs one walk for all branches instead of one walk each.
///
/// A walk that fails partway returns what it had rather than nothing: the
/// flags this feeds are a visual hint on a sidebar row, and under-reporting one
/// branch as unmerged is a far better failure than refusing to open the
/// repository.
pub(super) fn reachable_set(repo: &Repository, tip: git2::Oid) -> HashSet<git2::Oid> {
    let mut reachable = HashSet::new();
    let Ok(mut walk) = repo.revwalk() else {
        return reachable;
    };
    if walk.push(tip).is_err() {
        return reachable;
    }
    for oid in walk {
        match oid {
            Ok(oid) => {
                reachable.insert(oid);
            }
            Err(_) => break,
        }
    }
    reachable
}

fn gather_refresh_data_internal(
    repo_path: &Path,
    compute_ahead_behind: bool,
    commit_limit: usize,
    worktree_cache: Option<&Mutex<WorktreeStatusCache>>,
    author_filter: Option<&str>,
) -> Result<RefreshData> {
    let commit_limit = normalize_commit_limit(commit_limit);
    let refresh_timer = std::time::Instant::now();
    let repo = Repository::open(repo_path)
        .with_context(|| format!("Failed to open repository at {}", repo_path.display()))?;

    // Head
    let (head_branch, head_detached, _) = head_summary(&repo);
    let previous_branch = previous_branch(&repo, head_branch.as_deref());
    let repo_state = RepoState::from_git2(repo.state());

    // Current user email (for "My Branches" / "My Commits" filtering)
    let current_user_email = repo
        .config()
        .ok()
        .and_then(|cfg| cfg.get_string("user.email").ok());

    // Branches
    // Branches — two-pass approach:
    // Pass 1: collect basic info + last_commit_time
    // Then find main branch tip OID
    // Pass 2: compute is_merged_into_main using git ancestry check
    let mut branches: Vec<BranchInfo> = Vec::new();
    {
        let branch_iter = repo.branches(None)?;
        for branch_result in branch_iter {
            let (branch, branch_type) = branch_result?;
            let name = branch.name()?.unwrap_or("").to_string();
            if name.is_empty() {
                continue;
            }

            let is_head = branch.is_head();
            let is_remote = branch_type == git2::BranchType::Remote;
            let tip_oid = branch.get().target();

            let upstream = branch
                .upstream()
                .ok()
                .and_then(|u| u.name().ok().flatten().map(String::from));

            // `None` rather than `(0, 0)` when the walk did not run: the
            // deferred pass fills these in, and a snapshot that reported "level
            // with upstream" here would be indistinguishable from one that had
            // simply not looked yet.
            let (ahead, behind) = if compute_ahead_behind {
                match (tip_oid, branch.upstream()) {
                    (Some(local_oid), Ok(upstream_ref)) => upstream_ref
                        .get()
                        .target()
                        .and_then(|remote_oid| repo.graph_ahead_behind(local_oid, remote_oid).ok())
                        .map_or((None, None), |(ahead, behind)| (Some(ahead), Some(behind))),
                    _ => (None, None),
                }
            } else {
                (None, None)
            };

            let last_commit_time =
                tip_oid.and_then(|oid| repo.find_commit(oid).ok().map(|c| c.time().seconds()));

            let author_email = tip_oid.and_then(|oid| {
                repo.find_commit(oid)
                    .ok()
                    .and_then(|c| c.author().email().map(String::from))
            });

            branches.push(BranchInfo {
                name,
                is_head,
                is_remote,
                upstream,
                ahead,
                behind,
                tip_oid,
                author_email,
                last_commit_time,
                is_merged_into_main: None,
                is_merged_into_head: None,
            });
        }

        branches.sort_by(|a, b| {
            b.is_head
                .cmp(&a.is_head)
                .then(a.is_remote.cmp(&b.is_remote))
                .then(a.name.cmp(&b.name))
        });

        // `is_merged_into_main` and `is_merged_into_head` are deliberately left
        // unset. Both need a walk over the repository's history and decide
        // nothing more than whether a sidebar row is dimmed, so they are filled
        // in afterwards by `refresh_branch_graph_state`, once the commits the
        // user is actually waiting for are on screen. Computing them here cost
        // 139ms of the ~290ms it took to produce the whole snapshot.
        //
        // `None` means "not computed", which `apply_refresh_data` reads as
        // "keep what was already known" — so a refresh never blanks a flag it
        // simply did not recalculate.
    }

    // Tags
    let mut tags = Vec::new();
    if let Err(e) = repo.tag_foreach(|oid, name_bytes| {
        if let Ok(name) = std::str::from_utf8(name_bytes) {
            let name = name.strip_prefix("refs/tags/").unwrap_or(name).to_string();
            let peeled_oid = repo
                .find_object(oid, None)
                .and_then(|object| object.peel_to_commit())
                .map(|commit| commit.id())
                .unwrap_or(oid);
            tags.push(TagInfo {
                name,
                oid: peeled_oid,
                message: None,
            });
        }
        true
    }) {
        log::warn!("Failed to enumerate repository tags: {}", e);
    }
    tags.sort_by(|a, b| a.name.cmp(&b.name));

    // Remotes
    let mut remotes = Vec::new();
    {
        let remote_names = repo.remotes()?;
        for name in remote_names.iter().flatten() {
            if let Ok(remote) = repo.find_remote(name) {
                remotes.push(RemoteInfo {
                    name: name.to_string(),
                    url: remote.url().map(String::from),
                    push_url: remote.pushurl().map(String::from),
                });
            }
        }
    }

    // Run status, stashes, worktrees in parallel; scoped threads for the same
    // reason as in `compute_working_tree_status`. Status and stashes open their
    // own repos, while worktrees and the revwalk share `&repo`.
    let (status, stashes, worktrees) = std::thread::scope(|s| {
        let status_handle = s.spawn(|| compute_working_tree_status(repo_path, worktree_cache));

        let stash_handle = s.spawn(|| {
            let mut stashes = Vec::new();
            if let Ok(mut repo_mut) = Repository::open(repo_path) {
                let _ = repo_mut.stash_foreach(|stash_index, message, oid| {
                    stashes.push(StashEntry {
                        index: stash_index,
                        message: message.to_string(),
                        oid: *oid,
                    });
                    true
                });
            }
            stashes
        });

        let mut worktrees = gather_worktrees(&repo);
        let mut worktree_status_handles = Vec::new();
        for (idx, worktree) in worktrees.iter().enumerate() {
            if worktree.is_current {
                continue;
            }
            let worktree_path = worktree.path.clone();
            worktree_status_handles.push((
                idx,
                s.spawn(move || compute_working_tree_status(&worktree_path, worktree_cache)),
            ));
        }

        let status = status_handle.join().unwrap().unwrap_or_default();
        if let Some(current_worktree) = worktrees.iter_mut().find(|wt| wt.is_current) {
            current_worktree.status = Some(status.clone());
        }

        // A failed or panicked status thread leaves `None` — "not known yet" —
        // rather than an empty status. An empty status is indistinguishable from
        // a clean worktree, and callers act on that: it would silently drop the
        // user out of worktree inspection because the checkout looked clean.
        for (idx, handle) in worktree_status_handles {
            worktrees[idx].status = match handle.join() {
                Ok(Ok(status)) => Some(status),
                Ok(Err(e)) => {
                    log::warn!(
                        "Failed to compute status for worktree {}: {}",
                        worktrees[idx].path.display(),
                        e
                    );
                    None
                }
                Err(_) => {
                    log::warn!(
                        "Status thread panicked for worktree {}",
                        worktrees[idx].path.display()
                    );
                    None
                }
            };
        }

        let stashes = stash_handle.join().unwrap_or_default();
        (status, stashes, worktrees)
    });

    // Recent commits — use git log subprocess for commit-graph acceleration.
    // libgit2's revwalk doesn't use .git/objects/info/commit-graph, making it
    // orders of magnitude slower on large repos like the Linux kernel.
    let (recent_commits, has_more_commits) = {
        let t_log = std::time::Instant::now();
        let limit = commit_limit;

        let mut ref_map = std::collections::HashMap::<git2::Oid, Vec<RefLabel>>::new();
        if let Ok(head) = repo.head() {
            if let Some(oid) = head.target() {
                ref_map.entry(oid).or_default().push(RefLabel::Head);
            }
        }
        for branch in &branches {
            if let Some(oid) = branch.tip_oid {
                let label = if branch.is_remote {
                    RefLabel::RemoteBranch(branch.name.clone())
                } else {
                    RefLabel::LocalBranch(branch.name.clone())
                };
                ref_map.entry(oid).or_default().push(label);
            }
        }
        for tag in &tags {
            ref_map
                .entry(tag.oid)
                .or_default()
                .push(RefLabel::Tag(tag.name.clone()));
        }

        // `--topo-order` makes the subprocess emit commits in topological order
        // (descendants before ancestors), the invariant the graph layout relies
        // on. Without it git defaults to commit-date order, which is non-monotonic
        // with topology for rebased/amended/cherry-picked or clock-skewed history
        // and produces dangling lanes and misdrawn merges.
        let mut log_cmd = git_command();
        log_cmd.current_dir(repo_path).args([
            "log",
            "--branches",
            "--remotes",
            "--tags",
            "--topo-order",
            &format!("--format={}", commit_log_format()),
        ]);
        // Preserve an active "My Commits" filter across watcher/operation
        // refreshes; without it the filtered list would be replaced by the full
        // unfiltered log.
        if let Some(author) = author_filter {
            log_cmd.arg("--fixed-strings");
            log_cmd.arg(format!("--author={}", author));
        }
        if head_detached {
            log_cmd.arg("HEAD");
        }
        log_cmd.arg(format!("-{}", limit.saturating_add(1)));
        let output = log_cmd.output().with_context(|| "Failed to run git log")?;

        if !output.status.success() {
            anyhow::bail!(
                "git log failed: {}",
                String::from_utf8_lossy(&output.stderr)
            );
        }

        let stdout = String::from_utf8_lossy(&output.stdout);
        let mut commits = parse_git_log_records(&stdout, &mut ref_map);
        // The subprocess requested one extra commit (`-{limit + 1}`); its
        // presence signals more history is available beyond the loaded window.
        let has_more = commits.len() > limit;
        commits.truncate(limit);

        log::debug!(
            "git log completed in {:?}: {} commits",
            t_log.elapsed(),
            commits.len()
        );
        (commits, has_more)
    };

    log::info!(
        "gather_refresh_data_internal complete in {:?}: {} commits, {} branches, staged={} unstaged={}",
        refresh_timer.elapsed(),
        recent_commits.len(),
        branches.len(),
        status.staged.len(),
        status.unstaged.len()
    );
    Ok(RefreshData {
        head_branch,
        head_detached,
        previous_branch,
        repo_state,
        branches,
        tags,
        remotes,
        stashes,
        status,
        recent_commits,
        has_more_commits,
        worktrees,
        default_branch: repo
            .find_reference("refs/remotes/origin/HEAD")
            .ok()
            .and_then(|reference| reference.symbolic_target().map(str::to_owned))
            .and_then(|target| {
                target
                    .strip_prefix("refs/remotes/origin/")
                    .map(str::to_owned)
            }),
        current_user_email,
    })
}

/// Enrich a commit with is_signed and co_authors (deferred from the revwalk).
pub fn enrich_commit_info(repo_path: &Path, oid: git2::Oid) -> Result<(bool, Vec<Signature>)> {
    let repo = Repository::open(repo_path)?;
    let commit = repo.find_commit(oid)?;
    let is_signed = commit.header_field_bytes("gpgsig").is_ok();
    let raw_message = commit.message().unwrap_or("");
    let co_authors = extract_co_authors(raw_message);
    Ok((is_signed, co_authors))
}

use gpui::{AsyncApp, Context, Task, WeakEntity};
use std::sync::Arc;

const FIRST_BATCH_SIZE: usize = 100;

impl GitProject {
    /// Refresh all state asynchronously on a background thread.
    /// Uses two-phase loading: the first batch of commits loads quickly so the
    /// UI appears populated during the splash animation, then the remainder
    /// loads in the background.
    pub fn refresh(&mut self, cx: &mut Context<Self>) -> Task<Result<()>> {
        self.commit_query_generation = self.commit_query_generation.wrapping_add(1);
        self.load_more_in_flight = false;
        let query_generation = self.commit_query_generation;
        let repo_path = self.repo_path.clone();
        let commit_limit = self.commit_limit;
        let first_batch = FIRST_BATCH_SIZE.min(commit_limit);
        let t = std::time::Instant::now();
        let cache = self.worktree_status_cache.clone();
        // Honour an active "My Commits" filter so the initial load matches the
        // toggle instead of showing every author.
        let author_filter = self.commit_author_filter.clone();

        let work = self.track_background_work();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            // Held for both phases, so a caller waiting for the project to
            // settle waits for the remaining history too, not just the first
            // batch that made the window look populated.
            let _work = work;
            // Phase 1: lightweight refresh (skip ahead/behind) with a small commit batch
            let repo_path_p1 = repo_path.clone();
            let cache_path_p1 = repo_path.clone();
            let author_filter_p1 = author_filter.clone();
            let data = cx
                .background_executor()
                .spawn(async move {
                    let cache_fingerprint = if author_filter_p1.is_none() {
                        super::history_cache::ref_fingerprint(&cache_path_p1).ok()
                    } else {
                        None
                    };
                    let data = gather_refresh_data_lightweight_cached(
                        &repo_path_p1,
                        first_batch,
                        &cache,
                        author_filter_p1.as_deref(),
                    )?;
                    if let Some(cache_fingerprint) = cache_fingerprint {
                        if let Err(error) = super::history_cache::store(
                            &cache_path_p1,
                            cache_fingerprint,
                            &data.recent_commits,
                            data.has_more_commits,
                            data.default_branch.as_deref(),
                        ) {
                            log::debug!("history cache write skipped: {}", error);
                        }
                    }
                    Ok::<_, anyhow::Error>(data)
                })
                .await?;

            let needs_more = data.has_more_commits && first_batch < commit_limit;
            let branch_tips: Vec<(git2::Oid, bool, String)> = data
                .branches
                .iter()
                .filter_map(|b| b.tip_oid.map(|oid| (oid, b.is_remote, b.name.clone())))
                .collect();
            let tag_tips: Vec<(git2::Oid, String)> =
                data.tags.iter().map(|t| (t.oid, t.name.clone())).collect();

            cx.update(|cx| {
                this.update(cx, |this, cx| {
                    if this.commit_query_generation != query_generation {
                        return Ok::<(), anyhow::Error>(());
                    }
                    let reached_ui = t.elapsed();
                    this.apply_refresh_data(data);
                    log::info!(
                        "refresh phase 1 applied in {:?} ({:?} waiting for the UI thread): {} commits",
                        t.elapsed(),
                        reached_ui,
                        this.recent_commits.len()
                    );
                    cx.emit(GitProjectEvent::StatusChanged);
                    // Fire ahead/behind computation in the background (deferred from lightweight refresh)
                    this.refresh_ahead_behind(cx);
                    cx.notify();
                    Ok::<(), anyhow::Error>(())
                })
            })??;

            // Phase 2: load remaining commits
            if needs_more {
                let remaining = commit_limit - first_batch;
                let repo_path_p2 = repo_path.clone();
                let author_filter_p2 = author_filter.clone();
                // Page from the stable cursor (the oldest commit loaded in phase 1)
                // rather than a numeric skip, so a ref change between the two
                // subprocesses can't shift the boundary and skip a commit.
                let (already_loaded, cursor) = cx.update(|cx| {
                    this.update(cx, |this, _| {
                        (
                            this.recent_commits.len(),
                            this.recent_commits.last().map(|c| c.oid),
                        )
                    })
                })?;
                let (more_commits, has_more) = cx
                    .background_executor()
                    .spawn(async move {
                        load_more_commits_from_repo(
                            &repo_path_p2,
                            already_loaded,
                            cursor,
                            remaining,
                            &branch_tips,
                            &tag_tips,
                            author_filter_p2.as_deref(),
                        )
                    })
                    .await?;

                cx.update(|cx| {
                    this.update(cx, |this, cx| {
                        if this.commit_query_generation != query_generation {
                            return Ok(());
                        }
                        let existing_oids: std::collections::HashSet<git2::Oid> =
                            this.recent_commits.iter().map(|c| c.oid).collect();
                        // The background task handed us a fresh Arc, so it is
                        // uniquely held here; `make_mut` appends in place rather
                        // than deep-cloning the entire loaded list each page.
                        let combined = Arc::make_mut(&mut this.recent_commits);
                        for commit in more_commits {
                            if !existing_oids.contains(&commit.oid) {
                                combined.push(commit);
                            }
                        }
                        this.commit_offset = this.recent_commits.len();
                        this.has_more_commits = has_more;
                        log::info!(
                            "refresh phase 2 applied in {:?}: {} commits total",
                            t.elapsed(),
                            this.recent_commits.len()
                        );
                        cx.emit(GitProjectEvent::StatusChanged);
                        cx.notify();
                        Ok(())
                    })
                })?
            } else {
                Ok(())
            }
        })
    }
}

/// Load the next batch of commits after the already-loaded window, without
/// re-fetching branches/status/etc. Returns `(new_commits, has_more)`.
///
/// Pagination is driven by a stable cursor (`after_oid`, the OID of the last
/// commit already shown) rather than a numeric `--skip`. A single
/// `git log --all --topo-order` window of `already_loaded + limit + 1` commits
/// is fetched, then everything up to and including the cursor is dropped and the
/// next `limit` commits are returned. Anchoring on the cursor OID means a
/// concurrent ref change between the initial load and this call cannot shift the
/// page boundary and skip (or duplicate) a commit the way `--skip` would; the
/// `-n` bound keeps `.output()` from buffering an unbounded log.
pub(super) fn load_more_commits_from_repo(
    repo_path: &Path,
    already_loaded: usize,
    after_oid: Option<git2::Oid>,
    limit: usize,
    branch_tips: &[(git2::Oid, bool, String)],
    tag_tips: &[(git2::Oid, String)],
    author_filter: Option<&str>,
) -> Result<(Vec<CommitInfo>, bool)> {
    // Build ref-label map from the caller-supplied tips.
    let mut ref_map = std::collections::HashMap::<git2::Oid, Vec<RefLabel>>::new();
    let mut detached_head = None;
    if let Ok(repo) = Repository::open(repo_path) {
        if let Ok(head) = repo.head() {
            if let Some(oid) = head.target() {
                ref_map.entry(oid).or_default().push(RefLabel::Head);
                if repo.head_detached().unwrap_or(false) {
                    detached_head = Some(oid);
                }
            }
        }
    }
    for (oid, is_remote, name) in branch_tips {
        let label = if *is_remote {
            RefLabel::RemoteBranch(name.clone())
        } else {
            RefLabel::LocalBranch(name.clone())
        };
        ref_map.entry(*oid).or_default().push(label);
    }
    for (oid, name) in tag_tips {
        ref_map
            .entry(*oid)
            .or_default()
            .push(RefLabel::Tag(name.clone()));
    }

    let format = commit_log_format();
    // Fetch the already-loaded prefix plus this page plus one probe commit. The
    // window is re-anchored on `after_oid` below, so the prefix only needs to be
    // large enough to reach the cursor — it does not have to land exactly on it.
    let window = already_loaded.saturating_add(limit).saturating_add(1);

    let mut cmd = git_command();
    cmd.current_dir(repo_path).args([
        "log",
        "--branches",
        "--remotes",
        "--tags",
        "--topo-order",
        &format!("--format={}", format),
    ]);
    if let Some(author) = author_filter {
        cmd.arg("--fixed-strings");
        cmd.arg(format!("--author={}", author));
    }
    if let Some(head_oid) = detached_head {
        cmd.arg(head_oid.to_string());
    }
    cmd.arg(format!("-{}", window));
    let output = cmd.output().with_context(|| "Failed to run git log")?;

    if !output.status.success() {
        anyhow::bail!(
            "git log failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let parsed = parse_git_log_records(&stdout, &mut ref_map);

    // Re-anchor on the stable cursor: drop everything up to and including the
    // last already-loaded commit. If the cursor is no longer present (its ref
    // was rewritten or deleted since the prior load), fall back to the numeric
    // count so paging still makes forward progress.
    let start = match after_oid {
        Some(cursor) => match parsed.iter().position(|c| c.oid == cursor) {
            Some(idx) => idx + 1,
            None => already_loaded.min(parsed.len()),
        },
        None => 0,
    };

    let mut remaining = parsed;
    remaining.drain(..start);
    let has_more = remaining.len() > limit;
    remaining.truncate(limit);

    Ok((remaining, has_more))
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── parse_co_authors ───────────────────────────────────────────

    #[test]
    fn parse_single_co_author() {
        let message = "Fix a bug\n\nCo-Authored-By: Alice Smith <alice@example.com>";
        let (cleaned, authors) = parse_co_authors(message);
        assert_eq!(authors.len(), 1);
        assert_eq!(authors[0].name, "Alice Smith");
        assert_eq!(authors[0].email, "alice@example.com");
        assert_eq!(cleaned, "Fix a bug");
    }

    #[test]
    fn parse_multiple_co_authors() {
        let message = "Refactor module\n\n\
            Co-Authored-By: Alice <alice@example.com>\n\
            Co-Authored-By: Bob Jones <bob@example.com>";
        let (cleaned, authors) = parse_co_authors(message);
        assert_eq!(authors.len(), 2);
        assert_eq!(authors[0].name, "Alice");
        assert_eq!(authors[1].name, "Bob Jones");
        assert_eq!(cleaned, "Refactor module");
    }

    #[test]
    fn parse_duplicate_co_authors_once() {
        let message = "Subject\n\nCo-Authored-By: Claude Fable <noreply@anthropic.com>\nco-authored-by: claude fable <NOREPLY@ANTHROPIC.COM>";
        let (_, authors) = parse_co_authors(message);

        assert_eq!(authors.len(), 1);
        assert_eq!(authors[0].name, "Claude Fable");
        assert_eq!(authors[0].email, "noreply@anthropic.com");
    }

    #[test]
    fn parse_co_author_case_insensitive() {
        let message = "Fix\n\nco-authored-by: Alice <alice@example.com>";
        let (_, authors) = parse_co_authors(message);
        assert_eq!(authors.len(), 1);
        assert_eq!(authors[0].name, "Alice");
    }

    #[test]
    fn parse_no_co_authors() {
        let message = "Just a normal commit message\n\nWith a body.";
        let (cleaned, authors) = parse_co_authors(message);
        assert!(authors.is_empty());
        assert_eq!(cleaned, "Just a normal commit message\n\nWith a body.");
    }

    #[test]
    fn parse_co_author_missing_email() {
        let message = "Fix\n\nCo-Authored-By: Alice";
        let (cleaned, authors) = parse_co_authors(message);
        assert!(authors.is_empty());
        assert!(cleaned.contains("Co-Authored-By: Alice"));
    }

    #[test]
    fn parse_co_author_empty_name() {
        let message = "Fix\n\nCo-Authored-By: <alice@example.com>";
        let (_, authors) = parse_co_authors(message);
        assert!(authors.is_empty());
    }

    #[test]
    fn parse_co_author_empty_email() {
        let message = "Fix\n\nCo-Authored-By: Alice <>";
        let (_, authors) = parse_co_authors(message);
        assert!(authors.is_empty());
    }

    #[test]
    fn parse_co_author_empty_message() {
        let (cleaned, authors) = parse_co_authors("");
        assert!(authors.is_empty());
        assert_eq!(cleaned, "");
    }

    #[test]
    fn parse_co_author_preserves_body_lines() {
        let message = "Title\n\nBody line 1\nBody line 2\n\nCo-Authored-By: A <a@b.com>";
        let (cleaned, authors) = parse_co_authors(message);
        assert_eq!(authors.len(), 1);
        assert!(cleaned.contains("Body line 1"));
        assert!(cleaned.contains("Body line 2"));
    }
}

// ── load_more_commits_from_repo ──────────────────────────────────

#[cfg(test)]
mod reachable_tests {
    use super::*;
    use rgitui_test_support::TempRepo;

    /// The predicate `reachable_set` replaced, kept as the oracle it has to
    /// agree with. A branch counted as merged when `merge_base(tip, target)`
    /// was the tip itself.
    fn merged_by_merge_base(repo: &Repository, tip: git2::Oid, target: git2::Oid) -> bool {
        repo.merge_base(tip, target)
            .map(|base| base == tip)
            .unwrap_or(false)
    }

    #[test]
    fn a_tip_is_reachable_from_itself() {
        // The old predicate answered true here — merge_base(x, x) == x — and a
        // walk that excluded its own starting commit would report the checked
        // out branch as unmerged from itself.
        let repo = TempRepo::with_commits(3);
        let head = repo.head_oid();
        assert!(reachable_set(repo.repo(), head).contains(&head));
    }

    #[test]
    fn an_ancestor_is_reachable_and_a_descendant_is_not() {
        let repo = TempRepo::with_commits(1);
        let first = repo.head_oid();
        repo.commit_file("second.txt", "second", "second");
        let second = repo.head_oid();

        let from_second = reachable_set(repo.repo(), second);
        assert!(from_second.contains(&first), "ancestor must be reachable");

        let from_first = reachable_set(repo.repo(), first);
        assert!(
            !from_first.contains(&second),
            "a later commit is not reachable from an earlier one"
        );
    }

    #[test]
    fn set_membership_agrees_with_merge_base_across_a_divergent_history() {
        // Two branches off a shared base, one of them merged back. This is the
        // shape the flags exist to describe, and the case where a wrong answer
        // would mislabel a sidebar row.
        let repo = TempRepo::with_commits(2);
        let base = repo.head_oid();
        repo.branch("merged-branch");
        repo.commit_file("on-main.txt", "main", "main work");
        let main_tip = repo.head_oid();

        let merged_tip = repo
            .repo()
            .find_branch("merged-branch", git2::BranchType::Local)
            .expect("branch should exist")
            .get()
            .target()
            .expect("branch should have a tip");

        let reachable = reachable_set(repo.repo(), main_tip);
        for tip in [base, main_tip, merged_tip] {
            assert_eq!(
                reachable.contains(&tip),
                merged_by_merge_base(repo.repo(), tip, main_tip),
                "set membership disagreed with merge_base for {tip}"
            );
        }
    }

    #[test]
    fn a_walk_from_every_commit_agrees_with_merge_base() {
        // Exhaustive over a small history: whatever the old predicate said for
        // each (tip, target) pair, the set has to say the same.
        let repo = TempRepo::with_commits(6);
        let mut walk = repo.repo().revwalk().unwrap();
        walk.push_head().unwrap();
        let commits: Vec<git2::Oid> = walk.filter_map(Result::ok).collect();

        for &target in &commits {
            let reachable = reachable_set(repo.repo(), target);
            for &tip in &commits {
                assert_eq!(
                    reachable.contains(&tip),
                    merged_by_merge_base(repo.repo(), tip, target),
                    "disagreement for tip {tip} against target {target}"
                );
            }
        }
    }
}

#[cfg(test)]
mod load_more_tests {
    use super::*;
    use rgitui_test_support::TempRepo;

    #[test]
    fn load_more_returns_next_page() {
        let repo = TempRepo::with_commits(5);
        let path = repo.path();
        let branch_tips = vec![(repo.head_oid(), false, "main".to_string())];
        // Page 1: first 3 commits.
        let (page1, more1) =
            load_more_commits_from_repo(path, 0, None, 3, &branch_tips, &[], None).unwrap();
        assert_eq!(page1.len(), 3);
        assert!(more1);
        // Page 2: anchored on the oldest loaded commit, take up to 2.
        let cursor = page1.last().map(|c| c.oid);
        let (page2, more2) =
            load_more_commits_from_repo(path, 3, cursor, 2, &branch_tips, &[], None).unwrap();
        // 5 commits total, 3 already loaded → 2 remaining, no more after that.
        assert_eq!(page2.len(), 2);
        assert!(!more2);
        // The page boundary is contiguous with no overlap or gap.
        let oids: Vec<_> = page1.iter().chain(page2.iter()).map(|c| c.oid).collect();
        let unique: std::collections::HashSet<_> = oids.iter().collect();
        assert_eq!(oids.len(), unique.len(), "no commit appears twice");
        assert_eq!(oids.len(), 5, "every commit is loaded exactly once");
    }

    #[test]
    fn load_more_detects_has_more() {
        let repo = TempRepo::with_commits(5);
        let path = repo.path();
        let branch_tips = vec![(repo.head_oid(), false, "main".to_string())];
        // First page, limit 3 → should have more.
        let (commits, has_more) =
            load_more_commits_from_repo(path, 0, None, 3, &branch_tips, &[], None).unwrap();
        assert_eq!(commits.len(), 3);
        assert!(has_more);
    }

    #[test]
    fn load_more_empty_past_end() {
        let repo = TempRepo::with_commits(3);
        let path = repo.path();
        let branch_tips = vec![(repo.head_oid(), false, "main".to_string())];
        // Cursor at the oldest commit: nothing remains beyond it.
        let (all, _) =
            load_more_commits_from_repo(path, 0, None, 3, &branch_tips, &[], None).unwrap();
        let cursor = all.last().map(|c| c.oid);
        let (commits, has_more) =
            load_more_commits_from_repo(path, 3, cursor, 5, &branch_tips, &[], None).unwrap();
        assert!(commits.is_empty());
        assert!(!has_more);
    }

    #[test]
    fn load_more_survives_ref_added_between_pages() {
        // Regression for BUG-40: a commit created between page loads must not
        // shift the boundary and skip a commit. The stable cursor re-anchors on
        // the OID, so even though `already_loaded` is now stale the page is
        // still contiguous.
        let repo = TempRepo::with_commits(5);
        let path = repo.path();
        let tip = repo.head_oid();
        let mut branch_tips = vec![(tip, false, "main".to_string())];

        let (page1, _) =
            load_more_commits_from_repo(path, 0, None, 3, &branch_tips, &[], None).unwrap();
        let cursor = page1.last().map(|c| c.oid);

        // A new commit lands on main between the two page loads.
        branch_tips[0] = (repo.commit("commit 5"), false, "main".to_string());

        let (page2, _) =
            load_more_commits_from_repo(path, 3, cursor, 5, &branch_tips, &[], None).unwrap();

        let loaded: std::collections::HashSet<_> =
            page1.iter().chain(page2.iter()).map(|c| c.oid).collect();
        // The original 5 commits plus the cursor's successors are all present;
        // crucially the commit immediately after the cursor is not skipped.
        assert!(loaded.contains(&tip), "boundary commit must not be skipped");
        assert_eq!(
            page1.len() + page2.len(),
            loaded.len(),
            "no commit is loaded twice"
        );
    }

    #[test]
    fn refresh_peels_annotated_tags_and_reads_remote_head() {
        let repo = TempRepo::with_commits(1);
        let tip = repo.head_oid();
        let git = repo.repo();
        let target = git.find_object(tip, None).unwrap();
        git.tag("v1", &target, &repo.signature(), "release", false)
            .unwrap();
        git.reference("refs/remotes/origin/main", tip, true, "test")
            .unwrap();
        git.reference_symbolic(
            "refs/remotes/origin/HEAD",
            "refs/remotes/origin/main",
            true,
            "test",
        )
        .unwrap();
        drop(target);

        let data = gather_refresh_data_internal(repo.path(), false, 10, None, None).unwrap();
        assert_eq!(data.default_branch.as_deref(), Some("main"));
        assert!(data
            .tags
            .iter()
            .any(|tag| tag.name == "v1" && tag.oid == tip));
        let commit = data
            .recent_commits
            .iter()
            .find(|commit| commit.oid == tip)
            .unwrap();
        assert!(commit
            .refs
            .iter()
            .any(|label| matches!(label, RefLabel::Tag(name) if name == "v1")));
    }

    #[test]
    fn refresh_excludes_commits_reachable_only_from_stash_ref() {
        let repo = TempRepo::with_commits(1);
        let git = repo.repo();
        let tree_oid = git.index().unwrap().write_tree().unwrap();
        let stash_only = repo.commit_tree(None, "stash only", tree_oid, &[]);
        git.reference("refs/stash", stash_only, true, "test")
            .unwrap();

        let data = gather_refresh_data_internal(repo.path(), false, 10, None, None).unwrap();
        assert!(!data
            .recent_commits
            .iter()
            .any(|commit| commit.oid == stash_only));
    }

    #[test]
    fn author_filter_treats_regex_characters_literally() {
        let repo = TempRepo::with_commits(1);
        let special = repo.commit_file_as(
            "Special",
            "person+tag@example.com",
            "special.txt",
            "special\n",
            "special",
        );

        let data = gather_refresh_data_internal(
            repo.path(),
            false,
            10,
            None,
            Some("person+tag@example.com"),
        )
        .unwrap();
        assert_eq!(data.recent_commits.len(), 1);
        assert_eq!(data.recent_commits[0].oid, special);
    }

    #[test]
    fn commit_limit_is_clamped_to_safe_bounds() {
        assert_eq!(normalize_commit_limit(0), 1);
        assert_eq!(normalize_commit_limit(42), 42);
        assert_eq!(normalize_commit_limit(usize::MAX), MAX_COMMIT_LIMIT);
    }
}

// ── is_merged_into_main via graph_descendant_of ──────────────────
//
// graph_descendant_of(a, b) in libgit2 means:
//   "is b reachable from a by following parent pointers?"
//   i.e. "is a an ancestor of b?"
//
// To check "branch is merged into main":
//   We need: "is branch_tip an ancestor of main_tip?"
//   I.e., can we reach main_tip by following parent pointers from branch_tip?
//   Answer: graph_descendant_of(branch_tip, main_tip)

#[cfg(test)]
mod is_merged_tests {
    use super::*;
    use rgitui_test_support::TempRepo;

    fn empty_tree_oid(repo: &Repository) -> git2::Oid {
        repo.index().unwrap().write_tree().unwrap()
    }

    /// Commit an empty tree onto an arbitrary ref, which is how these tests
    /// draw a topology without caring about file contents.
    fn commit(
        fixture: &TempRepo,
        refname: &str,
        message: &str,
        parent: Option<git2::Oid>,
    ) -> git2::Oid {
        let repo = fixture.repo();
        let tree_oid = empty_tree_oid(repo);
        fixture.commit_tree(
            Some(refname),
            message,
            tree_oid,
            &parent.into_iter().collect::<Vec<_>>(),
        )
    }

    fn merge(fixture: &TempRepo, into_ref: &str, from_ref: &str, message: &str) -> git2::Oid {
        let repo = fixture.repo();
        let tree_oid = empty_tree_oid(repo);
        let main = repo
            .revparse_single(into_ref)
            .unwrap()
            .peel_to_commit()
            .unwrap()
            .id();
        let branch = repo
            .revparse_single(from_ref)
            .unwrap()
            .peel_to_commit()
            .unwrap()
            .id();
        fixture.commit_tree(Some(into_ref), message, tree_oid, &[main, branch])
    }

    /// Repo structure:
    ///   A (main, branch)
    /// After: A --- M (main, merged)
    ///                 \
    ///                  B (branch)
    /// merge_base(branch_tip=B, main_tip=M) should equal B (B is ancestor of M).
    #[test]
    fn branch_merged_into_main_returns_true() {
        let fixture = TempRepo::init();
        let repo = fixture.repo();

        let a = commit(&fixture, "refs/heads/main", "A", None);
        let b = commit(&fixture, "refs/heads/branch", "B", Some(a));
        let m = merge(&fixture, "refs/heads/main", "refs/heads/branch", "Merge");

        // Verify B is a parent of M
        let m_commit = repo.find_commit(m).unwrap();
        let m_parents: Vec<_> = m_commit.parent_ids().collect();
        assert!(m_parents.contains(&b), "B should be a parent of M");

        // is_merged = merge_base(branch_tip, main_tip) == branch_tip
        let mb = repo.merge_base(b, m).unwrap();
        assert_eq!(mb, b, "merge_base(branch=B, main=M) should equal B");
    }

    /// Repo structure:
    ///   A --- C (main, diverged)
    ///    \
    ///     B (branch, never merged)
    /// merge_base(branch_tip=B, main_tip=C) should NOT equal B.
    #[test]
    fn branch_not_merged_returns_false() {
        let fixture = TempRepo::init();
        let repo = fixture.repo();

        let a = commit(&fixture, "refs/heads/main", "A", None);
        let b = commit(&fixture, "refs/heads/branch", "B", Some(a));
        let c = commit(&fixture, "refs/heads/main", "C", Some(a));

        let mb = repo.merge_base(b, c).unwrap();
        assert_ne!(
            mb, b,
            "merge_base(branch=B, main=C) should NOT equal B for diverged branches"
        );
    }

    /// Repo structure (fast-forward):
    ///   A (both main and branch)
    /// Then branch advances:
    ///   A --- B (branch)
    /// (main still at A)
    /// After fast-forward of main to branch tip B:
    ///   A --- B (main, branch — same commit)
    /// merge_base(branch_tip=B, main_tip=B) == B (same commit).
    #[test]
    fn fast_forward_merged_returns_true() {
        let fixture = TempRepo::init();
        let repo = fixture.repo();

        let a = commit(&fixture, "refs/heads/main", "A", None);
        // Create branch at A (same as main)
        repo.branch("branch", &repo.find_commit(a).unwrap(), false)
            .unwrap();
        // Advance branch to B
        let b = commit(&fixture, "refs/heads/branch", "B", Some(a));

        // Fast-forward: move main ref to branch tip
        let mut main_ref = repo.find_reference("refs/heads/main").unwrap();
        main_ref
            .set_target(b, "fast-forward main to branch")
            .unwrap();

        let main_tip = repo
            .revparse_single("refs/heads/main")
            .unwrap()
            .peel_to_commit()
            .unwrap()
            .id();
        // Both point to B now
        assert_eq!(main_tip, b, "main should now point to B");

        // is_merged = merge_base(branch_tip, main_tip) == branch_tip
        // When both point to the same commit, merge_base equals that commit
        let mb = repo.merge_base(b, main_tip).unwrap();
        assert_eq!(mb, b, "merge_base of same commit should equal that commit");
    }

    /// Repo structure:
    ///   A --- B --- C (main advanced after branch split)
    ///    \
    ///     D (branch, still at D)
    /// This is the key bug scenario: main advanced past the branch commit,
    /// but the branch was never merged into main.
    /// merge_base(branch_tip=D, main_tip=C) should NOT equal D.
    #[test]
    fn main_advanced_after_branch_returns_false() {
        let fixture = TempRepo::init();
        let repo = fixture.repo();

        let a = commit(&fixture, "refs/heads/main", "A", None);
        let d = commit(&fixture, "refs/heads/branch", "D", Some(a));
        let _b = commit(&fixture, "refs/heads/main", "B", Some(a));
        let c = commit(
            &fixture,
            "refs/heads/main",
            "C",
            Some(
                repo.revparse_single("refs/heads/main")
                    .unwrap()
                    .peel_to_commit()
                    .unwrap()
                    .id(),
            ),
        );

        // branch still at D, main at C. D is NOT an ancestor of C.
        let mb = repo.merge_base(d, c).unwrap();
        assert_ne!(
            mb, d,
            "merge_base(branch=D, main=C) should NOT equal D when main advanced independently"
        );
    }

    #[test]
    fn merged_status_is_computed_against_current_branch() {
        let fixture = TempRepo::init();
        let repo = fixture.repo();

        let a = commit(&fixture, "refs/heads/main", "A", None);
        let feature_tip = commit(&fixture, "refs/heads/feature", "B", Some(a));
        let diverged_tip = commit(&fixture, "refs/heads/diverged", "D", Some(a));
        repo.set_head("refs/heads/feature").unwrap();

        let branches = vec![
            ("main".to_string(), false, false, Some(a)),
            ("feature".to_string(), false, true, Some(feature_tip)),
            ("diverged".to_string(), false, false, Some(diverged_tip)),
        ];
        let flags = super::super::merged_flags(repo, &branches);
        let flag = |wanted: &str| {
            flags
                .iter()
                .find(|(name, _, _, _)| name == wanted)
                .map(|(_, _, _, into_head)| *into_head)
                .unwrap()
        };

        assert_eq!(
            flag("main"),
            Some(true),
            "main is an ancestor of the checked-out feature"
        );
        assert_eq!(
            flag("diverged"),
            Some(false),
            "a branch that diverged before HEAD is not merged into it"
        );
        assert_eq!(
            flag("feature"),
            Some(true),
            "the checked-out branch is trivially merged into itself"
        );
    }

    #[test]
    fn the_gather_leaves_merged_flags_for_the_deferred_pass() {
        // The flags are what made opening a repository slow, so the snapshot
        // must not compute them. `None` is the signal that they are unknown
        // rather than false, which is what stops `apply_refresh_data` blanking
        // a previously computed value.
        let fixture = TempRepo::init();
        let a = commit(&fixture, "refs/heads/main", "A", None);
        let _feature = commit(&fixture, "refs/heads/feature", "B", Some(a));

        let data = gather_refresh_data_internal(fixture.path(), false, 100, None, None).unwrap();
        assert!(
            data.branches
                .iter()
                .all(|branch| branch.is_merged_into_main.is_none()
                    && branch.is_merged_into_head.is_none()),
            "the snapshot must not walk history for these"
        );
    }

    #[test]
    fn a_repository_with_no_trunk_reports_unknown_rather_than_unmerged() {
        // The trunk here is `develop`, which is not one of the names
        // `merged_flags` looks for. There is no answer to "is this merged into
        // main", and saying `false` would have the branch health panel offer
        // every branch up for deletion as unmerged.
        let fixture = TempRepo::init();
        let repo = fixture.repo();
        let a = commit(&fixture, "refs/heads/develop", "A", None);
        let feature_tip = commit(&fixture, "refs/heads/feature", "B", Some(a));
        repo.set_head("refs/heads/develop").unwrap();

        let branches = vec![
            ("develop".to_string(), false, true, Some(a)),
            ("feature".to_string(), false, false, Some(feature_tip)),
        ];
        let flags = super::super::merged_flags(repo, &branches);

        for (name, _, into_main, _) in &flags {
            assert_eq!(
                *into_main, None,
                "{name} has no trunk to be measured against, so the flag is unknown"
            );
        }
    }

    #[test]
    fn an_unreachable_branch_is_reported_as_unmerged_not_unknown() {
        // The counterpart to the test above: here the walk *did* run and the
        // tip genuinely is not in it. That is an answer, and it must not be
        // flattened into the same `None` as "could not ask".
        let fixture = TempRepo::init();
        let repo = fixture.repo();
        let a = commit(&fixture, "refs/heads/main", "A", None);
        let orphan = commit(&fixture, "refs/heads/orphan", "unrelated", None);
        repo.set_head("refs/heads/main").unwrap();

        let branches = vec![
            ("main".to_string(), false, true, Some(a)),
            ("orphan".to_string(), false, false, Some(orphan)),
        ];
        let flags = super::super::merged_flags(repo, &branches);
        let into_main = |wanted: &str| {
            flags
                .iter()
                .find(|(name, _, _, _)| name == wanted)
                .map(|(_, _, into_main, _)| *into_main)
                .unwrap()
        };

        assert_eq!(into_main("main"), Some(true));
        assert_eq!(
            into_main("orphan"),
            Some(false),
            "a root commit with no path to main is answerably not merged"
        );
    }
}

// ── gather_worktrees ─────────────────────────────────────────────

#[cfg(test)]
mod worktree_tests {
    use super::*;
    use rgitui_test_support::TempRepo;

    /// Add a linked worktree checked out on a new branch, returning its path.
    fn add_worktree(fixture: &TempRepo, name: &str) -> PathBuf {
        let repo = fixture.repo();
        let head = repo.head().unwrap().peel_to_commit().unwrap();
        repo.branch(name, &head, false).unwrap();
        let path = fixture.path().join(name);
        let reference = repo
            .find_reference(&format!("refs/heads/{}", name))
            .unwrap();
        let mut opts = git2::WorktreeAddOptions::new();
        opts.reference(Some(&reference));
        repo.worktree(name, &path, Some(&opts)).unwrap();
        path
    }

    fn find<'a>(worktrees: &'a [WorktreeInfo], name: &str) -> &'a WorktreeInfo {
        worktrees
            .iter()
            .find(|worktree| worktree.name == name)
            .unwrap_or_else(|| panic!("no worktree named {name}"))
    }

    #[test]
    fn main_repo_lists_itself_and_its_linked_worktrees() {
        let fixture = TempRepo::with_commits(1);
        add_worktree(&fixture, "feature");

        let worktrees = gather_worktrees(fixture.repo());

        assert_eq!(worktrees.len(), 2, "{worktrees:?}");
        assert!(worktrees[0].is_current, "the current worktree sorts first");
        assert_eq!(
            find(&worktrees, "feature").branch.as_deref(),
            Some("feature")
        );
        assert_eq!(
            worktrees.iter().filter(|w| w.is_current).count(),
            1,
            "exactly one worktree is current"
        );
    }

    /// Opening rgitui on a linked worktree used to list that worktree twice —
    /// once as `repo.workdir()` and again from the registry — while the main
    /// checkout had no row at all.
    #[test]
    fn opening_a_linked_worktree_lists_each_checkout_once() {
        let fixture = TempRepo::with_commits(1);
        let worktree_path = add_worktree(&fixture, "feature");
        let linked = Repository::open(&worktree_path).unwrap();

        let worktrees = gather_worktrees(&linked);

        assert_eq!(worktrees.len(), 2, "{worktrees:?}");
        let identities: HashSet<PathBuf> = worktrees
            .iter()
            .map(|worktree| worktree_identity(&worktree.path))
            .collect();
        assert_eq!(identities.len(), 2, "no checkout is listed twice");
        assert!(
            identities.contains(&worktree_identity(fixture.path())),
            "the main checkout is present"
        );
        assert!(find(&worktrees, "feature").is_current);
    }

    /// `shorthand()` reports a short OID on a detached HEAD, which must not
    /// reach the UI as if it were a branch name.
    #[test]
    fn detached_head_reports_no_branch() {
        let fixture = TempRepo::with_commits(2);
        fixture
            .repo()
            .set_head_detached(fixture.head_oid())
            .unwrap();

        let worktrees = gather_worktrees(fixture.repo());

        let current = worktrees.iter().find(|w| w.is_current).unwrap();
        assert!(current.head_detached);
        assert_eq!(current.branch, None);
        assert_eq!(current.head_oid, Some(fixture.head_oid()));
    }
}

// ── previous_branch ──────────────────────────────────────────────

#[cfg(test)]
mod previous_branch_tests {
    use super::*;
    use rgitui_test_support::TempRepo;

    fn switch_to(fixture: &TempRepo, branch: &str) {
        fixture
            .repo()
            .set_head(&format!("refs/heads/{branch}"))
            .unwrap();
    }

    #[test]
    fn checkout_source_reads_the_branch_or_commit_moved_away_from() {
        assert_eq!(
            checkout_source("checkout: moving from main to feature"),
            Some("main")
        );
        assert_eq!(
            checkout_source("checkout: moving from 1a2b3c4d to main"),
            Some("1a2b3c4d")
        );
        assert_eq!(
            checkout_source("checkout: moving from feature/to-do to main"),
            Some("feature/to-do")
        );
        assert_eq!(checkout_source("commit: add a file"), None);
        assert_eq!(checkout_source("checkout: moving from  to main"), None);
    }

    #[test]
    fn detaching_remembers_the_branch_it_left() {
        let fixture = TempRepo::with_commits(2);
        fixture
            .repo()
            .set_head_detached(fixture.head_oid())
            .unwrap();

        assert_eq!(
            previous_branch(fixture.repo(), None).as_deref(),
            Some(TempRepo::DEFAULT_BRANCH)
        );
    }

    #[test]
    fn stepping_between_detached_commits_still_finds_the_branch() {
        let fixture = TempRepo::with_commits(3);
        let repo = fixture.repo();
        let head = fixture.head_oid();
        let parent = repo.find_commit(head).unwrap().parent_id(0).unwrap();
        repo.set_head_detached(head).unwrap();
        repo.set_head_detached(parent).unwrap();

        assert_eq!(
            previous_branch(repo, None).as_deref(),
            Some(TempRepo::DEFAULT_BRANCH)
        );
    }

    #[test]
    fn on_a_branch_it_is_the_one_switched_from() {
        let fixture = TempRepo::with_commits(1);
        fixture.branch("feature");
        switch_to(&fixture, "feature");

        assert_eq!(
            previous_branch(fixture.repo(), Some("feature")).as_deref(),
            Some(TempRepo::DEFAULT_BRANCH)
        );
    }

    #[test]
    fn the_current_branch_is_never_the_previous_one() {
        let fixture = TempRepo::with_commits(1);
        fixture.branch("feature");
        switch_to(&fixture, "feature");
        switch_to(&fixture, TempRepo::DEFAULT_BRANCH);
        switch_to(&fixture, "feature");

        assert_eq!(
            previous_branch(fixture.repo(), Some("feature")).as_deref(),
            Some(TempRepo::DEFAULT_BRANCH)
        );
    }

    #[test]
    fn a_deleted_branch_is_passed_over() {
        let fixture = TempRepo::with_commits(1);
        fixture.branch("feature");
        fixture.branch("topic");
        switch_to(&fixture, "topic");
        switch_to(&fixture, "feature");
        fixture
            .repo()
            .set_head_detached(fixture.head_oid())
            .unwrap();
        fixture
            .repo()
            .find_branch("feature", git2::BranchType::Local)
            .unwrap()
            .delete()
            .unwrap();

        assert_eq!(
            previous_branch(fixture.repo(), None).as_deref(),
            Some("topic")
        );
    }

    #[test]
    fn a_repository_never_switched_has_no_previous_branch() {
        let fixture = TempRepo::with_commits(2);
        assert_eq!(
            previous_branch(fixture.repo(), Some(TempRepo::DEFAULT_BRANCH)),
            None
        );
    }

    /// `head_branch` used to be `shorthand()`, which is the literal `HEAD` on a
    /// detached HEAD — so the title bar named a branch called HEAD and Rename
    /// Branch offered to rename it.
    #[test]
    fn a_detached_refresh_reports_no_branch_and_where_to_return() {
        let fixture = TempRepo::with_commits(2);
        fixture
            .repo()
            .set_head_detached(fixture.head_oid())
            .unwrap();

        let data = gather_refresh_data(fixture.path(), 50).unwrap();

        assert!(data.head_detached);
        assert_eq!(data.head_branch, None);
        assert_eq!(
            data.previous_branch.as_deref(),
            Some(TempRepo::DEFAULT_BRANCH)
        );
    }
}
