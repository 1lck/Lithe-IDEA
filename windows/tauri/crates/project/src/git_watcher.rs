use anyhow::{Context, Result};
use lithe_core::{GitMetadataChangeKind, GitMetadataWatchContext, classify_git_metadata_change};
use notify::RecursiveMode;
use notify_debouncer_mini::{DebounceEventResult, Debouncer, new_debouncer};
use std::collections::{BTreeMap, BTreeSet, HashMap};
#[cfg(test)]
use std::path::Path;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[derive(Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitWatchContext {
    pub repository_root: PathBuf,
    pub git_directory: PathBuf,
    pub git_common_directory: PathBuf,
    #[serde(default)]
    pub rule_directories: Vec<PathBuf>,
}

impl GitWatchContext {
    fn shared_context(&self) -> GitMetadataWatchContext {
        GitMetadataWatchContext {
            workspace_root: None,
            repository_root: self.repository_root.clone(),
            git_directory: self.git_directory.clone(),
            git_common_directory: self.git_common_directory.clone(),
            rule_directories: self.rule_directories.clone(),
        }
    }
}

#[derive(Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitMetadataChange {
    pub repository_roots: Vec<PathBuf>,
    pub metadata_link_changed: bool,
    /// Every change of the batch rewrote the index (`index`, `index.lock`):
    /// staging and stat refreshes changed, but no commit, ref or setting did.
    /// Git and other tools rewrite the index constantly while a project is
    /// opened, so consumers refresh only working-tree state for such batches.
    pub index_only: bool,
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
    closed_windows: BTreeSet<String>,
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
                closed_windows: BTreeSet::new(),
            }),
        }
    }

    /// Reserve ownership before Core discovery so a late result cannot restore an old watch.
    pub fn begin(&self, owner: &str, lease: &str) -> Result<()> {
        let state = self.state.lock().unwrap();
        if state
            .closed_windows
            .contains(owner.split('\0').next().unwrap_or(owner))
        {
            anyhow::bail!("Watch window closed");
        }
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
        Ok(())
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

    /// All repository registrations owned by a destroyed WebView are revoked together.
    pub fn remove_window(&self, window: &str) -> Result<()> {
        let mut state = self.state.lock().unwrap();
        state.closed_windows.insert(window.to_owned());
        self.registrations
            .lock()
            .unwrap()
            .retain(|owner, _| owner.split('\0').next() != Some(window));
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
            for directory in &context.rule_directories {
                desired.entry(directory.clone()).or_insert(false);
            }
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
                    let mut index_only = true;
                    for context in registrations
                        .values()
                        .filter_map(|entry| entry.context.as_ref())
                    {
                        let shared = context.shared_context();
                        for event in &events {
                            let classification = classify_git_metadata_change(&shared, &event.path);
                            match classification.kind {
                                GitMetadataChangeKind::Context => {
                                    roots.insert(context.repository_root.clone());
                                    metadata_link_changed = true;
                                    index_only = false;
                                }
                                GitMetadataChangeKind::Metadata
                                | GitMetadataChangeKind::IgnoreRule => {
                                    roots.insert(context.repository_root.clone());
                                    index_only &= classification.index_only;
                                }
                                GitMetadataChangeKind::Ignored | GitMetadataChangeKind::Other => {}
                            }
                        }
                    }
                    drop(registrations);
                    if !roots.is_empty() {
                        emitter.emit_git_metadata_change(&GitMetadataChange {
                            repository_roots: roots.into_iter().collect(),
                            metadata_link_changed,
                            index_only,
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

#[cfg(test)]
fn is_index_write(context: &GitWatchContext, path: &Path) -> bool {
    classify_git_metadata_change(&context.shared_context(), path).index_only
}

#[cfg(test)]
fn is_relevant_metadata_change(context: &GitWatchContext, path: &Path) -> bool {
    matches!(
        classify_git_metadata_change(&context.shared_context(), path).kind,
        GitMetadataChangeKind::Metadata | GitMetadataChangeKind::IgnoreRule
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shared_metadata_cases_use_the_native_core_classifier() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../../shared/fixtures/git/metadata-classification-v1.json"
        ))
        .unwrap();
        for case in fixture["cases"].as_array().unwrap() {
            let mut context = fixture["contexts"][case["context"].as_str().unwrap()].clone();
            // The native watcher observes the repository pointer; workspace-only
            // pointers belong to the workspace watcher rather than this host.
            let workspace_root = context["workspaceRoot"].as_str().unwrap().to_string();
            context.as_object_mut().unwrap().remove("workspaceRoot");
            let native: GitWatchContext = serde_json::from_value(context).unwrap();
            let path = PathBuf::from(case["path"].as_str().unwrap());
            if path == PathBuf::from(workspace_root).join(".git")
                && path != native.repository_root.join(".git")
            {
                continue;
            }
            let actual = classify_git_metadata_change(&native.shared_context(), &path);
            let value = serde_json::to_value(actual).unwrap();
            assert_eq!(value["kind"], case["kind"], "{}", case["name"]);
            assert_eq!(value["indexOnly"], case["indexOnly"], "{}", case["name"]);
        }
    }

    fn receive_repository_change(
        receiver: &std::sync::mpsc::Receiver<Vec<PathBuf>>,
        repository_root: &Path,
    ) {
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        loop {
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            assert!(
                !remaining.is_zero(),
                "timed out waiting for {repository_root:?}"
            );
            let roots = receiver
                .recv_timeout(remaining)
                .unwrap_or_else(|error| panic!("waiting for {repository_root:?}: {error}"));
            if roots.iter().any(|root| root == repository_root) {
                return;
            }
        }
    }

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
        let repository_root = std::fs::canonicalize(repository_root).unwrap();
        let git_directory = std::fs::canonicalize(git_directory).unwrap();
        let git_common_directory = std::fs::canonicalize(git_common_directory).unwrap();
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
                    rule_directories: Vec::new(),
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
        receive_repository_change(&receiver, &repository_root);
        watcher
            .remove("fixture-window", Some("fixture-lease"))
            .unwrap();
    }

    #[test]
    fn window_keeps_multiple_repositories_and_shared_holders_until_final_release() {
        use std::sync::mpsc;
        struct Fixture(PathBuf);
        impl Drop for Fixture {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
        struct Emitter(mpsc::Sender<Vec<PathBuf>>, mpsc::Sender<()>);
        impl GitMetadataEmitter for Emitter {
            fn emit_git_metadata_change(&self, event: &GitMetadataChange) {
                let _ = self.0.send(event.repository_roots.clone());
                let _ = self.1.send(());
            }
        }
        let fixture = Fixture(
            std::env::temp_dir().join(format!("lithe-multi-repo-watch-{}", std::process::id())),
        );
        let context = |name: &str| {
            let root = fixture.0.join(name);
            std::fs::create_dir_all(root.join(".git/info")).unwrap();
            let root = std::fs::canonicalize(root).unwrap();
            std::fs::write(root.join(".git/info/exclude"), "before").unwrap();
            GitWatchContext {
                git_directory: root.join(".git"),
                git_common_directory: root.join(".git"),
                repository_root: root,
                rule_directories: Vec::new(),
            }
        };
        let first = context("one");
        let second = context("two");
        let (sender, receiver) = mpsc::channel();
        let (observed, notification) = mpsc::channel();
        let watcher = GitMetadataWatcher::new(Arc::new(Emitter(sender, observed)));
        for (owner, context) in [("window\0a\01", &first), ("other\0b\03", &first)] {
            watcher.begin(owner, "lease").unwrap();
            watcher.install(owner, "lease", context.clone()).unwrap();
        }
        // Queue a real notification from the other repository before the target
        // write. Native backends may deliver these roots in separate batches.
        std::fs::write(first.git_directory.join("info/exclude"), "unrelated").unwrap();
        notification
            .recv_timeout(Duration::from_secs(5))
            .expect("the first native notification should be queued");
        watcher.begin("window\0a\02", "lease").unwrap();
        watcher
            .install("window\0a\02", "lease", second.clone())
            .unwrap();
        assert_eq!(watcher.registrations.lock().unwrap().len(), 3);
        std::fs::write(second.git_directory.join("info/exclude"), "after").unwrap();
        receive_repository_change(&receiver, &second.repository_root);
        watcher.remove_window("window").unwrap();
        assert_eq!(watcher.registrations.lock().unwrap().len(), 1);
        std::fs::write(first.git_directory.join("info/exclude"), "after").unwrap();
        receive_repository_change(&receiver, &first.repository_root);
        assert!(watcher.begin("window\0late\04", "late").is_err());
        watcher.install("window\0a\02", "lease", second).unwrap();
        watcher.remove_window("other").unwrap();
        let state = watcher.state.lock().unwrap();
        assert!(state.paths.is_empty());
        assert!(state.watcher.is_none());
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
            rule_directories: Vec::new(),
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
    fn only_the_worktree_index_counts_as_an_index_write() {
        // Index rewrites refresh staging only; blame and history wait for refs.
        let linked = GitWatchContext {
            rule_directories: Vec::new(),
            repository_root: PathBuf::from("workspace/linked"),
            git_directory: PathBuf::from("workspace/main/.git/worktrees/linked"),
            git_common_directory: PathBuf::from("workspace/main/.git"),
        };
        for path in ["index", "index.lock"] {
            assert!(
                is_index_write(&linked, &linked.git_directory.join(path)),
                "{path}"
            );
        }
        for path in ["HEAD", "ORIG_HEAD", "index/nested", "indexes"] {
            assert!(
                !is_index_write(&linked, &linked.git_directory.join(path)),
                "{path}"
            );
        }
        for path in ["refs/heads/main", "packed-refs", "config"] {
            assert!(
                !is_index_write(&linked, &linked.git_common_directory.join(path)),
                "{path}"
            );
        }
    }

    #[test]
    fn temporary_core_git_contexts_do_not_report_repository_changes() {
        // Snapshot diffs create and delete these directories while a diff opens;
        // reporting them made the open working-tree diff refresh and close itself.
        let context = GitWatchContext {
            rule_directories: Vec::new(),
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
