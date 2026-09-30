use gpui::{AsyncApp, Context};
use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use std::collections::hash_map::DefaultHasher;
use std::collections::HashSet;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use super::refresh::{gather_refresh_data_lightweight_cached, WorktreeStatusCache};
use super::{GitProject, GitProjectEvent};

/// How long the watcher will go without a fingerprint scan when nothing under a
/// git directory appears to have changed.
///
/// The scan is normally driven by the filesystem watcher, which is immediate.
/// This is the safety net for the cases where notify cannot be trusted —
/// network shares, some container mounts — where the cost of being slow to
/// notice is a stale sidebar and the cost of polling hard is a permanent
/// fraction of a core per open tab.
const FINGERPRINT_FALLBACK: Duration = Duration::from_secs(5);

/// Fold a file's length and mtime into `hasher`. Returns whether the file's
/// metadata was readable (i.e. the file exists).
fn mix_file_meta(hasher: &mut DefaultHasher, path: &Path) -> bool {
    match path.metadata() {
        Ok(meta) => {
            meta.len().hash(hasher);
            if let Ok(mtime) = meta.modified() {
                mtime.hash(hasher);
            }
            true
        }
        Err(_) => false,
    }
}

/// Compute a fingerprint over all critical `.git` sentinel files.
///
/// This covers:
/// - `.git/HEAD` — branch switches, detached HEAD
/// - `.git/index` — staging area changes (`git add`, `git reset`)
/// - `.git/packed-refs` — packed ref updates
/// - `.git/MERGE_HEAD`, `.git/REBASE_HEAD` — in-progress operations
/// - Current branch ref file (parsed from HEAD) — commits on current branch
/// - `.git/refs/heads/` — local branch changes from external operations
/// - `.git/refs/remotes/` — push/fetch ref updates
/// - `.git/refs/tags/` — tag creation/deletion
///
/// The small sentinel files (HEAD, the current branch ref, packed-refs) are
/// hashed by *content* in addition to size and mtime, so two distinct state
/// transitions whose newest mtime collapses to the same coarse timestamp
/// (FAT32 ~2s, some network/WSL/SMB mounts) are still distinguished. Ref files
/// under `refs/` are covered by metadata plus their directory mtimes instead —
/// see [`scan_refs`].
fn git_state_fingerprint(git_dir: &Path) -> Option<u64> {
    let mut hasher = DefaultHasher::new();
    let mut any = false;

    // Sentinel files hashed by content so same-mtime content changes are seen.
    for name in ["HEAD", "index", "packed-refs", "MERGE_HEAD", "REBASE_HEAD"] {
        let path = git_dir.join(name);
        any |= mix_file_meta(&mut hasher, &path);
        // `index` can be large; hash bytes only for the tiny sentinels.
        if name != "index" {
            if let Ok(content) = std::fs::read(&path) {
                content.hash(&mut hasher);
            }
        }
    }

    // Current branch ref file (e.g. refs/heads/main from "ref: refs/heads/main\n")
    if let Ok(head_content) = std::fs::read_to_string(git_dir.join("HEAD")) {
        if let Some(ref_rel) = head_content.strip_prefix("ref: ") {
            let ref_path = git_dir.join(ref_rel.trim());
            any |= mix_file_meta(&mut hasher, &ref_path);
            if let Ok(content) = std::fs::read(&ref_path) {
                content.hash(&mut hasher);
            }
        }
    }

    // Scan refs directories (local branches, remotes, tags). Each file's hash is
    // XOR-accumulated so the directory order `read_dir` happens to return doesn't
    // perturb the result; the combined accumulator is then mixed in once.
    let mut refs_acc: u64 = 0;
    for subdir in &["refs/heads", "refs/remotes", "refs/tags"] {
        scan_refs(&git_dir.join(subdir), &mut refs_acc);
    }
    refs_acc.hash(&mut hasher);

    if any {
        Some(hasher.finish())
    } else {
        None
    }
}

/// Recursively accumulate an order-independent fingerprint over every ref file
/// under `dir` (its path, size and mtime) plus the mtime of each directory
/// visited. `read_dir` yields entries in a filesystem-dependent order, so each
/// entry's hash is XOR-folded into `acc` — that keeps the result stable across
/// scans of an unchanged directory while still changing when any ref file is
/// added, removed or modified.
///
/// Ref files are deliberately *not* read. This runs every poll tick for the main
/// repo and each watched worktree, so on a repo with thousands of refs opening
/// every one of them was a sustained I/O load that scaled with refs × tabs.
/// Directory mtimes stand in for content: git updates a ref by writing a lock
/// file and renaming it into place, which touches the containing directory even
/// when the ref file's own size (a fixed-width OID) and mtime do not move. The
/// ref that matters most for HEAD state — the checked-out branch — is still
/// content-hashed separately by [`git_state_fingerprint`], as are `HEAD` and
/// `packed-refs`.
fn scan_refs(dir: &Path, acc: &mut u64) {
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };

    if let Ok(meta) = std::fs::metadata(dir) {
        if let Ok(mtime) = meta.modified() {
            let mut dir_hasher = DefaultHasher::new();
            dir.hash(&mut dir_hasher);
            mtime.hash(&mut dir_hasher);
            *acc ^= dir_hasher.finish();
        }
    }

    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            scan_refs(&path, acc);
        } else if let Ok(meta) = entry.metadata() {
            let mut file_hasher = DefaultHasher::new();
            path.hash(&mut file_hasher);
            meta.len().hash(&mut file_hasher);
            if let Ok(mtime) = meta.modified() {
                mtime.hash(&mut file_hasher);
            }
            *acc ^= file_hasher.finish();
        }
    }
}

/// Resolve the per-worktree git dir for a linked worktree under the main repo.
/// A worktree's `.git` is a file containing `gitdir: <path>` pointing into
/// `<main>/.git/worktrees/<name>/`. We read that redirect here so fingerprinting
/// still works when the caller only has the worktree's working-tree path.
fn worktree_git_dir(worktree_path: &Path) -> Option<PathBuf> {
    let dot_git = worktree_path.join(".git");
    let content = std::fs::read_to_string(&dot_git).ok()?;
    for line in content.lines() {
        if let Some(rest) = line.strip_prefix("gitdir:") {
            let p = PathBuf::from(rest.trim());
            return Some(if p.is_absolute() {
                p
            } else {
                worktree_path.join(p)
            });
        }
    }
    None
}

/// Compute a combined fingerprint across the main repo's `.git` and every
/// linked worktree's per-worktree git dir. The per-dir fingerprints are XOR-ed
/// so the result is independent of the (unordered) worktree-set iteration order
/// while still changing whenever any watched git dir changes.
fn combined_fingerprint(
    primary_git_dir: &Path,
    common_git_dir: &Path,
    extra_worktree_paths: &HashSet<PathBuf>,
) -> Option<u64> {
    let mut combined = git_state_fingerprint(primary_git_dir);
    if common_git_dir != primary_git_dir {
        if let Some(fp) = git_state_fingerprint(common_git_dir) {
            combined = Some(combined.map_or(fp, |current| current ^ fp));
        }
    }
    for wt in extra_worktree_paths {
        if let Some(git_dir) = worktree_git_dir(wt) {
            if let Some(fp) = git_state_fingerprint(&git_dir) {
                combined = Some(combined.map_or(fp, |c| c ^ fp));
            }
        }
    }
    combined
}

fn repository_git_dirs(repo_path: &Path) -> Option<(PathBuf, PathBuf)> {
    let repo = git2::Repository::open(repo_path).ok()?;
    Some((repo.path().to_path_buf(), repo.commondir().to_path_buf()))
}

/// Gitignore filtering for the notify callback, one handle per watched checkout.
///
/// `Repository::status_should_ignore` resolves the path it is given against the
/// workdir of the repository it is asked. Asking the main repository about a
/// path inside a *linked worktree* therefore evaluates a nonsense relative path
/// and answers "not ignored" no matter what that worktree's `.gitignore` says —
/// so a `cargo build` in a watched worktree woke a refresh for every file the
/// compiler wrote. Routing each event path to the checkout that owns it, and
/// asking about the path *relative to that root*, makes the answer correct.
struct IgnoreRepos {
    repos: Vec<(PathBuf, git2::Repository)>,
}

impl IgnoreRepos {
    fn new() -> Self {
        Self { repos: Vec::new() }
    }

    /// Open a handle for `root` if one is not held already.
    fn add(&mut self, root: &Path) {
        if self.repos.iter().any(|(path, _)| path == root) {
            return;
        }
        match git2::Repository::open(root) {
            Ok(repo) => self.repos.push((root.to_path_buf(), repo)),
            Err(e) => log::debug!("No gitignore filtering for {}: {}", root.display(), e),
        }
    }

    /// Drop handles for roots that are no longer watched.
    fn retain_roots(&mut self, keep: &HashSet<PathBuf>) {
        self.repos.retain(|(path, _)| keep.contains(path));
    }

    /// Whether every path in `paths` is ignored by the checkout that owns it.
    /// A path under no watched root counts as not ignored, so unknown changes
    /// still wake a refresh rather than being silently dropped.
    fn all_ignored(&self, paths: &[PathBuf]) -> bool {
        !paths.is_empty() && paths.iter().all(|path| self.is_ignored(path))
    }

    fn is_ignored(&self, path: &Path) -> bool {
        let Some(owner) = owning_root(self.repos.iter().map(|(root, _)| root.as_path()), path)
        else {
            return false;
        };
        self.repos
            .iter()
            .find(|(root, _)| root == owner)
            .is_some_and(|(root, repo)| match path.strip_prefix(root) {
                Ok(relative) if relative.as_os_str().is_empty() => false,
                // A workdir-relative path sidesteps libgit2's absolute-path
                // relativization entirely, which is where the cross-worktree
                // answer went wrong.
                Ok(relative) => repo.status_should_ignore(relative).unwrap_or(false),
                Err(_) => false,
            })
    }
}

/// The checkout that owns `path`: the deepest watched root containing it.
///
/// A linked worktree may live inside the main checkout, and when it does the
/// main repository almost certainly ignores that directory — you do not want a
/// worktree showing up as untracked files in its own parent. Asking every root
/// and taking any "yes" would let that answer suppress events for files the
/// worktree itself tracks, leaving its status and diff stale while the user
/// edits them. Only the innermost checkout has standing to answer.
fn owning_root<'a>(roots: impl Iterator<Item = &'a Path>, path: &Path) -> Option<&'a Path> {
    roots
        .filter(|root| {
            path.strip_prefix(root)
                .is_ok_and(|relative| !relative.as_os_str().is_empty())
        })
        .max_by_key(|root| root.components().count())
}

impl GitProject {
    /// Start watching the repository for filesystem changes.
    ///
    /// Always watches the main repo path. When the `watch_all_worktrees`
    /// setting is enabled, additionally watches every linked worktree's path
    /// and fingerprints its per-worktree git dir. The watched set is
    /// re-evaluated on every poll tick, so toggling the setting or adding /
    /// removing worktrees takes effect without restarting the app.
    pub(super) fn start_watcher(&mut self, cx: &mut Context<Self>) {
        let repo_path = self.repo_path.clone();
        let (main_git_dir, common_git_dir) = repository_git_dirs(&repo_path).unwrap_or_else(|| {
            let fallback = repo_path.join(".git");
            (fallback.clone(), fallback)
        });
        let dirty = Arc::new(AtomicBool::new(false));
        let worktree_cache: Arc<Mutex<WorktreeStatusCache>> = self.worktree_status_cache.clone();

        // Keep the notify watcher behind a mutex so the poll loop can add /
        // remove watched paths when the all-worktrees setting flips.
        let watcher_handle: Arc<Mutex<Option<RecommendedWatcher>>> = Arc::new(Mutex::new(None));

        // Set when something under a git directory changed, which is the only
        // time the fingerprint scan can tell us anything new.
        let git_dirty = Arc::new(AtomicBool::new(false));

        // One gitignore handle per watched checkout, kept in step with the
        // watched set by the poll loop below.
        let ignore_repos: Arc<Mutex<IgnoreRepos>> = Arc::new(Mutex::new(IgnoreRepos::new()));
        ignore_repos.lock().expect("ignore mutex").add(&repo_path);

        {
            let dirty_flag = dirty.clone();
            let git_dirty_flag = git_dirty.clone();
            let callback_ignore_repos = ignore_repos.clone();
            let watcher =
                notify::recommended_watcher(move |res: Result<notify::Event, notify::Error>| {
                    if let Ok(event) = res {
                        // A change under `.git` is not a working-tree change,
                        // but it is exactly what the fingerprint scan exists to
                        // detect — a commit, a checkout, a branch move. Noting
                        // it here is what lets the poll loop skip that scan
                        // while nothing is happening, instead of walking every
                        // loose ref ten times a minute forever.
                        let dominated_by_git = event
                            .paths
                            .iter()
                            .all(|p| p.components().any(|c| c.as_os_str() == ".git"));
                        if dominated_by_git {
                            git_dirty_flag.store(true, Ordering::Relaxed);
                            return;
                        }
                        // Skip events where every changed path is gitignored
                        // (e.g. `target/`, `node_modules/`). Tracked files —
                        // even modified ones — are never reported as ignored,
                        // so legitimate changes still pass through.
                        if let Ok(repos) = callback_ignore_repos.lock() {
                            if repos.all_ignored(&event.paths) {
                                return;
                            }
                        }
                        match event.kind {
                            notify::EventKind::Create(_)
                            | notify::EventKind::Modify(_)
                            | notify::EventKind::Remove(_) => {
                                dirty_flag.store(true, Ordering::Relaxed);
                            }
                            _ => {}
                        }
                    }
                });

            match watcher {
                Ok(mut w) => {
                    if let Err(e) = w.watch(&repo_path, RecursiveMode::Recursive) {
                        log::warn!(
                            "Failed to watch repository directory for filesystem changes: {}",
                            e
                        );
                    }
                    // A linked worktree or a `.git` file pointing elsewhere puts
                    // the git directory outside the tree just watched, and
                    // without this the fingerprint scan would only ever run on
                    // the slow fallback for those repositories.
                    for git_dir in [&main_git_dir, &common_git_dir] {
                        if git_dir.starts_with(&repo_path) {
                            continue;
                        }
                        if let Err(e) = w.watch(git_dir, RecursiveMode::Recursive) {
                            log::warn!(
                                "Failed to watch git directory {}: {}",
                                git_dir.display(),
                                e
                            );
                        }
                    }
                    *watcher_handle.lock().expect("watcher mutex") = Some(w);
                }
                Err(e) => {
                    log::warn!("Failed to create filesystem watcher: {}", e);
                }
            }
        }

        let last_fingerprint: Arc<Mutex<Option<u64>>> = Arc::new(Mutex::new(combined_fingerprint(
            &main_git_dir,
            &common_git_dir,
            &HashSet::new(),
        )));
        let watched_extras: Arc<Mutex<HashSet<PathBuf>>> = Arc::new(Mutex::new(HashSet::new()));

        let watcher_commit_limit = self.commit_limit;
        cx.spawn({
            let watcher_handle = watcher_handle.clone();
            let watched_extras = watched_extras.clone();
            let ignore_repos = ignore_repos.clone();
            let last_fingerprint = last_fingerprint.clone();
            let dirty = dirty.clone();
            let repo_path = repo_path.clone();
            let main_git_dir = main_git_dir.clone();
            let common_git_dir = common_git_dir.clone();
            let worktree_cache = worktree_cache.clone();
            async move |weak, cx: &mut AsyncApp| {
                // Keep the watcher handle alive for the lifetime of this task.
                // When the task ends (because the entity was dropped), the Arc
                // refcount hits zero and the notify watcher shuts down.
                let _keepalive = watcher_handle.clone();
                // Forces a scan on the first tick, so a change made between
                // opening the repository and the watcher starting is not missed.
                let mut last_scan = std::time::Instant::now() - FINGERPRINT_FALLBACK;

                loop {
                    smol::Timer::after(Duration::from_millis(300)).await;
                    log::trace!("watcher: poll tick");

                    // Re-read the all-worktrees setting and current worktree
                    // list. Sync the notify watcher's watched paths and the
                    // fingerprint set to match. `None` signals the entity
                    // has been dropped so we should end the watcher loop. The
                    // refresh generation captured here gates whether this tick's
                    // (lightweight) result is allowed to land later (BUG-22).
                    let snapshot: Option<(HashSet<PathBuf>, usize, Option<String>, u64)> = cx
                        .update(|app| {
                            let entity = weak.upgrade()?;
                            let watch_all = app
                                .try_global::<rgitui_settings::SettingsState>()
                                .map(|s| s.settings().watch_all_worktrees)
                                .unwrap_or(false);
                            let proj = entity.read(app);
                            // Refetch at least as many commits as are currently loaded
                            // so a background refresh doesn't truncate commits the user
                            // paged in via "load more" (the gather otherwise replaces
                            // the whole list with just `commit_limit` commits).
                            let effective_limit =
                                proj.loaded_commit_count().max(watcher_commit_limit);
                            let mut paths = if watch_all {
                                proj.worktrees
                                    .iter()
                                    .filter(|w| !w.is_current)
                                    .map(|w| w.path.clone())
                                    .collect::<HashSet<PathBuf>>()
                            } else {
                                HashSet::new()
                            };
                            // The worktree the user is inspecting is watched
                            // whether or not the setting is on: its file list
                            // and diff are on screen, so they have to stay live.
                            if let Some(inspected) = proj.inspected_worktree() {
                                if inspected != proj.repo_path {
                                    paths.insert(inspected.to_path_buf());
                                }
                            }
                            Some((
                                paths,
                                effective_limit,
                                proj.commit_author_filter.clone(),
                                proj.refresh_generation(),
                            ))
                        });
                    let (desired, effective_limit, author_filter, generation) = match snapshot {
                        Some(d) => d,
                        None => break,
                    };

                    // A change to the watched set changes what the fingerprint
                    // covers, so the next scan must run even if nothing on disk
                    // moved — otherwise a newly watched worktree stays invisible
                    // until the fallback.
                    let watched_changed = {
                        let mut current = watched_extras.lock().expect("watched mutex");
                        let changed = *current != desired;
                        if changed {
                            if let Ok(mut guard) = watcher_handle.lock() {
                                if let Some(w) = guard.as_mut() {
                                    for to_remove in current.difference(&desired) {
                                        if let Err(e) = w.unwatch(to_remove) {
                                            log::debug!(
                                                "Failed to unwatch {}: {}",
                                                to_remove.display(),
                                                e
                                            );
                                        }
                                    }
                                    for to_add in desired.difference(&current) {
                                        if let Err(e) = w.watch(to_add, RecursiveMode::Recursive) {
                                            log::warn!(
                                                "Failed to watch worktree {}: {}",
                                                to_add.display(),
                                                e
                                            );
                                        }
                                    }
                                }
                            }
                            *current = desired.clone();

                            if let Ok(mut repos) = ignore_repos.lock() {
                                let mut keep = desired.clone();
                                keep.insert(repo_path.clone());
                                repos.retain_roots(&keep);
                                for root in &desired {
                                    repos.add(root);
                                }
                            }
                        }
                        changed
                    };

                    // Detect git internal state changes across main + watched
                    // worktrees (commits, pushes, branch ops, staging
                    // changes, etc.) that don't produce working-directory
                    // events on the main repo. The fingerprint scan walks the
                    // `refs/` directories and reads sentinel files, so it runs on
                    // the background executor — never the UI thread (QUAL-01,
                    // PERF-13).
                    //
                    // Only when the watcher saw a git directory change, or the
                    // fallback is due. The scan reads sentinel files and
                    // `metadata()`s every loose ref, which measured 6.4ms p95
                    // against a 200-ref repository — running it unconditionally
                    // every 300ms cost around 2% of a core per open tab with
                    // nothing happening at all, and scaled with ref count.
                    // The fallback covers network mounts, where notify is
                    // unreliable enough that it cannot be the only signal.
                    let fallback_due = last_scan.elapsed() >= FINGERPRINT_FALLBACK;
                    let fingerprint_changed = if git_dirty.swap(false, Ordering::Relaxed)
                        || fallback_due
                        || watched_changed
                    {
                        last_scan = std::time::Instant::now();
                        let fp_git_dir = main_git_dir.clone();
                        let fp_common_git_dir = common_git_dir.clone();
                        let fp_extras = desired.clone();
                        let current = cx
                            .background_executor()
                            .spawn(async move {
                                combined_fingerprint(&fp_git_dir, &fp_common_git_dir, &fp_extras)
                            })
                            .await;
                        let mut guard = last_fingerprint.lock().expect("fp mutex");
                        if current.is_some() && current != *guard {
                            *guard = current;
                            true
                        } else {
                            false
                        }
                    } else {
                        false
                    };

                    if fingerprint_changed {
                        log::debug!("watcher: git state changed, scheduling refresh");
                        dirty.store(true, Ordering::Relaxed);
                    }

                    if dirty.swap(false, Ordering::Relaxed) {
                        // Debounce: coalesce a burst of events (e.g. `git checkout`
                        // touching many files) into one refresh. `swap` already
                        // cleared the flag; any event arriving during this wait or
                        // the refresh below re-arms `dirty` and is picked up on the
                        // next poll tick, so no refresh is lost.
                        smol::Timer::after(Duration::from_millis(200)).await;

                        let path = repo_path.clone();
                        let cache = worktree_cache.clone();
                        // Carry the active "My Commits" filter through the
                        // lightweight gather so a watcher tick doesn't replace
                        // the filtered list with the full unfiltered log (BUG-06).
                        let watcher_author_filter = author_filter.clone();
                        let data = cx
                            .background_executor()
                            .spawn(async move {
                                gather_refresh_data_lightweight_cached(
                                    &path,
                                    effective_limit,
                                    &cache,
                                    watcher_author_filter.as_deref(),
                                )
                            })
                            .await;

                        let data = match data {
                            Ok(d) => {
                                log::debug!("watcher: lightweight refresh complete");
                                d
                            }
                            Err(_) => continue,
                        };

                        let result = cx.update(|cx| {
                            weak.update(cx, |this, cx| {
                                // Generation guard (BUG-22): if a full/operation
                                // refresh applied while this lightweight gather
                                // was in flight, its accurate state (correct
                                // ahead/behind, filtered commits) must win. Drop
                                // this stale lightweight result and re-arm `dirty`
                                // so the next tick re-gathers against the current
                                // generation — the fingerprint already advanced,
                                // so without re-arming the change could otherwise
                                // be missed until an unrelated event.
                                if this.refresh_generation() != generation {
                                    log::debug!(
                                        "watcher: dropping stale lightweight refresh (gen {} != {})",
                                        generation,
                                        this.refresh_generation()
                                    );
                                    return false;
                                }

                                // Ahead/behind survives this apply through
                                // `carry_forward_branch_graph_state`, which keys
                                // on the branch tip and the upstream tip. The
                                // name-keyed overlay that used to live here
                                // predated that and re-applied counts across a
                                // moved upstream, which is exactly what a push
                                // does to them.
                                this.apply_refresh_data(data);

                                // A reference point may have moved — HEAD most
                                // often, via a checkout in a terminal — which
                                // drops the flags derived from it. Nothing else
                                // on this path recomputes them, so without this
                                // the sidebar would keep rendering a "merged"
                                // badge measured against the previous HEAD until
                                // an unrelated full refresh happened along.
                                if this.needs_graph_state_refresh() {
                                    this.refresh_ahead_behind(cx);
                                }

                                cx.emit(GitProjectEvent::StatusChanged);
                                cx.notify();
                                true
                            })
                        });

                        match result {
                            Ok(true) => {}
                            // The lightweight result was dropped as stale; re-arm
                            // so the next poll tick reapplies against the current
                            // generation.
                            Ok(false) => dirty.store(true, Ordering::Relaxed),
                            // Entity released (or app shutting down): end the loop.
                            Err(_) => break,
                        }
                    }
                }
                drop(_keepalive);
            }
        })
        .detach();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_nested_worktree_answers_for_its_own_files() {
        let main = Path::new("/repo");
        let nested = Path::new("/repo/feature");
        let roots = [main, nested];

        // The main checkout very likely ignores `feature/` — a worktree inside
        // it would otherwise read as a pile of untracked files — so letting it
        // answer would suppress events for files the worktree tracks.
        assert_eq!(
            owning_root(roots.into_iter(), Path::new("/repo/feature/src/main.rs")),
            Some(nested)
        );
        assert_eq!(
            owning_root(roots.into_iter(), Path::new("/repo/src/main.rs")),
            Some(main)
        );
    }

    #[test]
    fn a_path_under_no_watched_root_has_no_owner() {
        let roots = [Path::new("/repo")];
        assert_eq!(
            owning_root(roots.into_iter(), Path::new("/elsewhere/file.rs")),
            None
        );
    }

    #[test]
    fn a_root_does_not_own_itself() {
        // Stripping the prefix leaves nothing, and asking libgit2 whether a
        // checkout ignores its own directory is not a question with an answer.
        let roots = [Path::new("/repo")];
        assert_eq!(owning_root(roots.into_iter(), Path::new("/repo")), None);
    }

    #[test]
    fn loose_ref_fingerprint_includes_oid_content() {
        let temp = tempfile::TempDir::new().unwrap();
        let git_dir = temp.path();
        std::fs::create_dir_all(git_dir.join("refs/heads")).unwrap();
        std::fs::write(git_dir.join("HEAD"), "ref: refs/heads/main\n").unwrap();
        let reference = git_dir.join("refs/heads/main");
        std::fs::write(&reference, format!("{}\n", "1".repeat(40))).unwrap();
        let before = git_state_fingerprint(git_dir).unwrap();
        std::fs::write(&reference, format!("{}\n", "2".repeat(40))).unwrap();
        let after = git_state_fingerprint(git_dir).unwrap();
        assert_ne!(before, after);
    }

    /// Ref files outside the checked-out branch are tracked by metadata and
    /// directory mtime rather than by reading each one, so adding or removing a
    /// ref must still move the fingerprint.
    #[test]
    fn fingerprint_tracks_added_and_removed_refs() {
        let temp = tempfile::TempDir::new().unwrap();
        let git_dir = temp.path();
        std::fs::create_dir_all(git_dir.join("refs/heads")).unwrap();
        std::fs::create_dir_all(git_dir.join("refs/remotes/origin")).unwrap();
        std::fs::write(git_dir.join("HEAD"), "ref: refs/heads/main\n").unwrap();
        std::fs::write(
            git_dir.join("refs/heads/main"),
            format!("{}\n", "1".repeat(40)),
        )
        .unwrap();

        let baseline = git_state_fingerprint(git_dir).unwrap();

        let remote_ref = git_dir.join("refs/remotes/origin/feature");
        std::fs::write(&remote_ref, format!("{}\n", "3".repeat(40))).unwrap();
        let with_ref = git_state_fingerprint(git_dir).unwrap();
        assert_ne!(baseline, with_ref, "adding a remote ref must be visible");

        std::fs::remove_file(&remote_ref).unwrap();
        let without_ref = git_state_fingerprint(git_dir).unwrap();
        assert_ne!(with_ref, without_ref, "removing a ref must be visible");
        // Not expected to equal `baseline`: the directory mtime moved when the
        // ref was created and again when it was removed, and that mtime is part
        // of the fingerprint. Fingerprints only need to differ when state
        // differs, never to be reproducible across a round trip.
    }

    /// The accumulator must not depend on `read_dir` ordering.
    #[test]
    fn fingerprint_is_stable_across_repeated_scans() {
        let temp = tempfile::TempDir::new().unwrap();
        let git_dir = temp.path();
        std::fs::create_dir_all(git_dir.join("refs/heads")).unwrap();
        std::fs::create_dir_all(git_dir.join("refs/tags")).unwrap();
        std::fs::write(git_dir.join("HEAD"), "ref: refs/heads/main\n").unwrap();
        std::fs::write(
            git_dir.join("refs/heads/main"),
            format!("{}\n", "1".repeat(40)),
        )
        .unwrap();
        for i in 0..25 {
            std::fs::write(
                git_dir.join(format!("refs/tags/v{i}")),
                format!("{}\n", "a".repeat(40)),
            )
            .unwrap();
        }

        let first = git_state_fingerprint(git_dir).unwrap();
        let second = git_state_fingerprint(git_dir).unwrap();
        assert_eq!(first, second);
    }

    #[test]
    fn linked_worktree_uses_redirected_and_common_git_dirs() {
        let temp = tempfile::TempDir::new().unwrap();
        let main_path = temp.path().join("main");
        let linked_path = temp.path().join("linked");
        let repo = git2::Repository::init(&main_path).unwrap();
        let sig = git2::Signature::now("Test", "test@example.com").unwrap();
        let tree_oid = repo.index().unwrap().write_tree().unwrap();
        let tree = repo.find_tree(tree_oid).unwrap();
        repo.commit(Some("HEAD"), &sig, &sig, "initial", &tree, &[])
            .unwrap();
        drop(tree);
        repo.worktree("linked", &linked_path, None).unwrap();

        let (git_dir, common_dir) = repository_git_dirs(&linked_path).unwrap();
        assert_ne!(git_dir, linked_path.join(".git"));
        assert_eq!(common_dir, repo.commondir());
        assert!(git_state_fingerprint(&git_dir).is_some());
        assert!(git_state_fingerprint(&common_dir).is_some());
    }
}

#[cfg(test)]
mod ignore_repos_tests {
    use super::*;
    use rgitui_test_support::TempRepo;

    /// Main repo with a committed `/target` ignore rule plus a linked worktree
    /// that inherits it. The worktree lives *outside* the main working
    /// directory, which is where linked worktrees normally sit and where the
    /// cross-checkout ignore question actually bites.
    fn repo_with_worktree() -> (TempRepo, tempfile::TempDir) {
        let fixture = TempRepo::init();
        fixture.commit_file(".gitignore", "/target\n", "add gitignore");

        let elsewhere = tempfile::TempDir::new().unwrap();
        let worktree_path = elsewhere.path().join("feature");
        {
            let repo = fixture.repo();
            let head = repo.head().unwrap().peel_to_commit().unwrap();
            repo.branch("feature", &head, false).unwrap();
            let reference = repo.find_reference("refs/heads/feature").unwrap();
            let mut opts = git2::WorktreeAddOptions::new();
            opts.reference(Some(&reference));
            repo.worktree("feature", &worktree_path, Some(&opts))
                .unwrap();
        }

        (fixture, elsewhere)
    }

    /// The checkout [`repo_with_worktree`] added, inside its temp directory.
    fn worktree_path(elsewhere: &tempfile::TempDir) -> PathBuf {
        elsewhere.path().join("feature")
    }

    #[test]
    fn ignored_build_output_in_the_main_repo_is_filtered() {
        let fixture = TempRepo::init();
        fixture.commit_file(".gitignore", "/target\n", "add gitignore");
        let mut repos = IgnoreRepos::new();
        repos.add(fixture.path());

        assert!(repos.all_ignored(&[fixture.path().join("target/debug/app.exe")]));
        assert!(!repos.all_ignored(&[fixture.path().join("src/main.rs")]));
    }

    /// The main repository cannot answer for a path inside a *different*
    /// checkout: libgit2 resolves the path against its own workdir, so the
    /// answer comes back "not ignored" and every file a compiler writes in the
    /// worktree used to wake a refresh.
    #[test]
    fn a_worktree_needs_its_own_handle_to_filter_its_build_output() {
        let (fixture, elsewhere) = repo_with_worktree();
        let worktree_path = worktree_path(&elsewhere);
        let build_output = worktree_path.join("target/debug/app.exe");

        let mut main_only = IgnoreRepos::new();
        main_only.add(fixture.path());
        assert!(
            !main_only.all_ignored(std::slice::from_ref(&build_output)),
            "the main repo has no basis to answer for another checkout"
        );

        let mut both = IgnoreRepos::new();
        both.add(fixture.path());
        both.add(&worktree_path);
        assert!(both.all_ignored(&[build_output]));
        assert!(!both.all_ignored(&[worktree_path.join("src/main.rs")]));
    }

    #[test]
    fn a_mixed_event_is_not_filtered() {
        let fixture = TempRepo::init();
        fixture.commit_file(".gitignore", "/target\n", "add gitignore");
        let mut repos = IgnoreRepos::new();
        repos.add(fixture.path());

        assert!(!repos.all_ignored(&[
            fixture.path().join("target/debug/app.exe"),
            fixture.path().join("src/main.rs"),
        ]));
        assert!(!repos.all_ignored(&[]), "an empty event is never filtered");
    }

    #[test]
    fn dropping_a_root_stops_it_answering() {
        let (fixture, elsewhere) = repo_with_worktree();
        let worktree_path = worktree_path(&elsewhere);
        let build_output = worktree_path.join("target/debug/app.exe");
        let mut repos = IgnoreRepos::new();
        repos.add(fixture.path());
        repos.add(&worktree_path);
        assert!(repos.all_ignored(std::slice::from_ref(&build_output)));

        let keep: HashSet<PathBuf> = std::iter::once(fixture.path().to_path_buf()).collect();
        repos.retain_roots(&keep);
        assert!(!repos.all_ignored(&[build_output]));
    }
}
