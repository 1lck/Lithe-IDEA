use anyhow::{Context, Result};
use notify::RecursiveMode;
use notify_debouncer_mini::{DebounceEventResult, Debouncer, new_debouncer};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[derive(Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitWatchContext {
    pub repository_root: PathBuf,
    pub git_directory: PathBuf,
    pub git_common_directory: PathBuf,
}

#[derive(Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitMetadataChange {
    pub repository_roots: Vec<PathBuf>,
    pub metadata_link_changed: bool,
}

pub trait GitMetadataEmitter: Send + Sync {
    fn emit_git_metadata_change(&self, event: &GitMetadataChange);
}

struct Registration {
    lease: String,
    context: Option<GitWatchContext>,
}

struct WatchState {
    watcher: Option<Debouncer<notify::RecommendedWatcher>>,
    paths: BTreeMap<PathBuf, bool>,
}

pub struct GitMetadataWatcher {
    emitter: Arc<dyn GitMetadataEmitter>,
    registrations: Arc<Mutex<HashMap<String, Registration>>>,
    state: Mutex<WatchState>,
}

impl GitMetadataWatcher {
    pub fn new(emitter: Arc<dyn GitMetadataEmitter>) -> Self {
        Self {
            emitter,
            registrations: Arc::new(Mutex::new(HashMap::new())),
            state: Mutex::new(WatchState {
                watcher: None,
                paths: BTreeMap::new(),
            }),
        }
    }

    /// Reserve ownership before Core discovery so a late result cannot restore an old watch.
    pub fn begin(&self, owner: &str, lease: &str) -> Result<()> {
        let mut state = self.state.lock().unwrap();
        let mut registrations = self.registrations.lock().unwrap();
        let context = registrations.remove(owner).and_then(|entry| entry.context);
        registrations.insert(
            owner.into(),
            Registration {
                lease: lease.into(),
                context,
            },
        );
        drop(registrations);
        self.reconcile(&mut state)
    }

    pub fn install(&self, owner: &str, lease: &str, context: GitWatchContext) -> Result<()> {
        let mut state = self.state.lock().unwrap();
        {
            let mut registrations = self.registrations.lock().unwrap();
            let Some(current) = registrations
                .get_mut(owner)
                .filter(|entry| entry.lease == lease)
            else {
                return Ok(());
            };
            current.context = Some(context);
        }
        self.reconcile(&mut state)
    }

    pub fn remove(&self, owner: &str, lease: Option<&str>) -> Result<()> {
        let mut state = self.state.lock().unwrap();
        {
            let mut registrations = self.registrations.lock().unwrap();
            if registrations
                .get(owner)
                .is_some_and(|entry| lease.is_none_or(|value| value == entry.lease))
            {
                registrations.remove(owner);
            }
        }
        self.reconcile(&mut state)
    }

    fn reconcile(&self, state: &mut WatchState) -> Result<()> {
        let mut desired = BTreeMap::<PathBuf, bool>::new();
        for context in self
            .registrations
            .lock()
            .unwrap()
            .values()
            .filter_map(|entry| entry.context.as_ref())
        {
            desired
                .entry(context.repository_root.clone())
                .or_insert(false);
            desired.insert(context.git_directory.clone(), true);
            desired.insert(context.git_common_directory.clone(), true);
        }
        if desired.is_empty() {
            state.watcher = None;
            state.paths.clear();
            return Ok(());
        }
        if state.watcher.is_none() {
            let registrations = Arc::clone(&self.registrations);
            let emitter = Arc::clone(&self.emitter);
            state.watcher = Some(new_debouncer(
                Duration::from_millis(300),
                move |result: DebounceEventResult| {
                    let events = match result {
                        Ok(events) => events,
                        Err(error) => {
                            log::warn!("Git metadata watch failed: {error:?}");
                            return;
                        }
                    };
                    let registrations = registrations.lock().unwrap();
                    let mut roots = BTreeSet::new();
                    let mut metadata_link_changed = false;
                    for context in registrations
                        .values()
                        .filter_map(|entry| entry.context.as_ref())
                    {
                        for event in &events {
                            if event.path == context.repository_root.join(".git") {
                                roots.insert(context.repository_root.clone());
                                metadata_link_changed = true;
                            } else if is_relevant_metadata_change(context, &event.path) {
                                roots.insert(context.repository_root.clone());
                            }
                        }
                    }
                    drop(registrations);
                    if !roots.is_empty() {
                        emitter.emit_git_metadata_change(&GitMetadataChange {
                            repository_roots: roots.into_iter().collect(),
                            metadata_link_changed,
                        });
                    }
                },
            )?);
        }
        let watcher = state
            .watcher
            .as_mut()
            .context("Git metadata watcher is unavailable")?
            .watcher();
        for (path, recursive) in &desired {
            if state.paths.get(path) == Some(recursive) {
                continue;
            }
            if state.paths.contains_key(path) {
                watcher.unwatch(path)?;
                state.paths.remove(path);
            }
            watcher.watch(
                path,
                if *recursive {
                    RecursiveMode::Recursive
                } else {
                    RecursiveMode::NonRecursive
                },
            )?;
            state.paths.insert(path.clone(), *recursive);
        }
        let removed: Vec<_> = state
            .paths
            .keys()
            .filter(|path| !desired.contains_key(*path))
            .cloned()
            .collect();
        for path in removed {
            match watcher.unwatch(&path) {
                Ok(()) => {
                    state.paths.remove(&path);
                }
                Err(error) => {
                    log::warn!(
                        "Could not release Git metadata watch {}: {error}",
                        path.display()
                    );
                }
            }
        }
        Ok(())
    }
}

/// Lithe Core creates short-lived `<git-common-dir>/lithe-commit-<pid>-<seq>`
/// directories (`TemporaryGitCommitContext`) for read-only snapshot diffs and
/// isolated commits. They never change repository state, and reporting them
/// makes every snapshot diff refresh the views that requested it.
const LITHE_TEMPORARY_GIT_CONTEXT_PREFIX: &str = "lithe-commit-";

fn is_relevant_metadata_change(context: &GitWatchContext, path: &Path) -> bool {
    if let Ok(relative) = path.strip_prefix(&context.git_directory) {
        let first = relative
            .components()
            .next()
            .map(|part| part.as_os_str().to_string_lossy());
        if first
            .as_deref()
            .is_some_and(|part| part.starts_with(LITHE_TEMPORARY_GIT_CONTEXT_PREFIX))
        {
            return false;
        }
        if !matches!(
            first.as_deref(),
            Some("objects" | "lfs" | "modules" | "worktrees")
        ) {
            return true;
        }
    }
    let Ok(relative) = path.strip_prefix(&context.git_common_directory) else {
        return false;
    };
    let parts: Vec<_> = relative
        .components()
        .map(|part| part.as_os_str().to_string_lossy())
        .collect();
    match parts.first().map(|part| part.as_ref()) {
        Some("refs" | "packed-refs" | "config" | "shallow" | "info") => true,
        Some("logs") => parts.get(1).is_some_and(|part| part == "refs"),
        Some("worktrees") => {
            parts.len() <= 2
                || parts.get(2).is_some_and(|part| {
                    matches!(part.as_ref(), "HEAD" | "locked" | "gitdir" | "commondir")
                })
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_native_linked_worktree_notification(relative_metadata_path: &str) {
        use std::sync::atomic::{AtomicU64, Ordering};
        use std::sync::mpsc;

        static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);
        struct Fixture(PathBuf);
        impl Drop for Fixture {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
        struct Emitter(mpsc::Sender<Vec<PathBuf>>);
        impl GitMetadataEmitter for Emitter {
            fn emit_git_metadata_change(&self, event: &GitMetadataChange) {
                let _ = self.0.send(event.repository_roots.clone());
            }
        }
        let fixture = Fixture(std::env::temp_dir().join(format!(
            "lithe-git-watch-path-{}-{}",
            std::process::id(),
            NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed)
        )));
        let repository_root = fixture.0.join("linked 工作树");
        let git_common_directory = fixture.0.join("main repo/.git");
        let git_directory = git_common_directory.join("worktrees/linked");
        std::fs::create_dir_all(&repository_root).unwrap();
        std::fs::create_dir_all(&git_directory).unwrap();
        std::fs::create_dir_all(git_common_directory.join("refs/heads")).unwrap();
        std::fs::write(
            repository_root.join(".git"),
            format!("gitdir: {}\n", git_directory.display()),
        )
        .unwrap();
        let metadata_path = git_common_directory.join(relative_metadata_path);
        std::fs::write(&metadata_path, "before\n").unwrap();
        let (sender, receiver) = mpsc::channel();
        // The watcher drops before the fixture even if the assertion fails.
        let watcher = GitMetadataWatcher::new(Arc::new(Emitter(sender)));
        watcher.begin("fixture-window", "fixture-lease").unwrap();
        watcher
            .install(
                "fixture-window",
                "fixture-lease",
                GitWatchContext {
                    repository_root: repository_root.clone(),
                    git_directory,
                    git_common_directory,
                },
            )
            .unwrap();
        // Model the metadata writes made by an external commit or checkout.
        // Registration is synchronous; wait for the observable native event,
        // never for an assumed amount of time needed by the debounce timer.
        std::fs::write(metadata_path, "after\n").unwrap();
        let roots = receiver
            .recv_timeout(Duration::from_secs(5))
            .expect("native Git metadata notification should arrive within five seconds");
        assert!(roots.contains(&repository_root), "{roots:?}");
        watcher
            .remove("fixture-window", Some("fixture-lease"))
            .unwrap();
    }

    #[test]
    fn native_linked_worktree_watch_receives_external_commit_metadata() {
        assert_native_linked_worktree_notification("refs/heads/main");
    }

    #[test]
    fn native_linked_worktree_watch_receives_external_checkout_metadata() {
        assert_native_linked_worktree_notification("worktrees/linked/HEAD");
    }

    #[test]
    fn shared_refs_and_worktree_registration_changes_refresh_all_related_worktrees() {
        let context = GitWatchContext {
            repository_root: PathBuf::from("workspace/linked"),
            git_directory: PathBuf::from("workspace/main/.git/worktrees/linked"),
            git_common_directory: PathBuf::from("workspace/main/.git"),
        };
        for path in [
            "refs/heads/main",
            "packed-refs",
            "worktrees/other/HEAD",
            "worktrees/other/locked",
            "worktrees/linked/index",
        ] {
            assert!(
                is_relevant_metadata_change(&context, &context.git_common_directory.join(path)),
                "{path}"
            );
        }
        for path in ["objects/ab/object", "worktrees/other/index", "index"] {
            assert!(
                !is_relevant_metadata_change(&context, &context.git_common_directory.join(path)),
                "{path}"
            );
        }
    }

    #[test]
    fn temporary_core_git_contexts_do_not_report_repository_changes() {
        // Snapshot diffs create and delete these directories while a diff opens;
        // reporting them made the open working-tree diff refresh and close itself.
        let context = GitWatchContext {
            repository_root: PathBuf::from("workspace/repo"),
            git_directory: PathBuf::from("workspace/repo/.git"),
            git_common_directory: PathBuf::from("workspace/repo/.git"),
        };
        for path in [
            "lithe-commit-4242-7",
            "lithe-commit-4242-7/HEAD",
            "lithe-commit-4242-7/index",
            "lithe-commit-4242-7/index.lock",
        ] {
            assert!(
                !is_relevant_metadata_change(&context, &context.git_directory.join(path)),
                "{path}"
            );
        }
        for path in ["index", "HEAD", "refs/heads/main"] {
            assert!(
                is_relevant_metadata_change(&context, &context.git_directory.join(path)),
                "{path}"
            );
        }
    }
}
