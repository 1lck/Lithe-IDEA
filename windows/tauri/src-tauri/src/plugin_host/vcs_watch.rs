//! Per-incarnation leases reuse the bounded project FileWatcher. Callbacks only
//! revoke a matching generation and emit one hint; they never scan or launch.
use super::{registry, Scope};
use lithe_project::{FileChangeEmitter, FileChangeEvent, FileChangeType, FileWatcher};
use std::{
    collections::{BTreeMap, HashMap},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
};
use tauri::AppHandle;

const MAX_ROOTS: usize = 64;
const MAX_PATHS: usize = 256;
const MAX_ANCESTORS: usize = 64;
pub(super) struct Lease {
    pub scope: Scope,
    generation: u64,
    enabled: Arc<AtomicBool>,
    _watcher: Arc<FileWatcher>,
}
impl Drop for Lease {
    fn drop(&mut self) {
        self.enabled.store(false, Ordering::Release);
    }
}
#[derive(Default)]
pub(super) struct Watches(pub Mutex<HashMap<(String, String), Lease>>);
impl Watches {
    fn publish(
        &self,
        registry: &Mutex<registry::Registry>,
        host: &str,
        lease: Lease,
    ) -> Result<(), String> {
        let mut watches = self.0.lock().map_err(|_| "internalError")?;
        registry.lock().map_err(|_| "internalError")?.capture(
            host,
            &lease.scope,
            lease.generation,
        )?;
        watches.insert((host.into(), lease.scope.workspace_id.clone()), lease);
        Ok(())
    }
    pub fn remove_older(&self, host: &str, workspace_id: &str, generation: u64) {
        self.0
            .lock()
            .expect("VCS watches")
            .retain(|(window, workspace), lease| {
                window != host || workspace != workspace_id || lease.generation >= generation
            });
    }
    pub fn remove_generation(&self, host: &str, scope: &Scope, generation: u64) {
        self.0
            .lock()
            .expect("VCS watches")
            .retain(|(window, _), lease| {
                window != host || lease.scope != *scope || lease.generation != generation
            });
    }
    pub fn remove(&self, host: &str, scope: &Scope) {
        self.0
            .lock()
            .expect("VCS watches")
            .retain(|(window, _), lease| window != host || lease.scope != *scope);
    }
    pub fn retire_window(&self, host: &str, revoke: impl FnOnce()) {
        // Admission must close before disposal. A discovery worker that
        // publishes while revocation is pending is then included in removal;
        // one that arrives afterwards fails its registry capture in publish.
        // The callback releases the registry lock before the watch lock is taken.
        revoke();
        self.0
            .lock()
            .expect("VCS watches")
            .retain(|(window, _), _| window != host);
    }
    pub fn clear(&self) {
        self.0.lock().expect("VCS watches").clear();
    }
}
#[derive(Clone)]
struct Plan {
    workspace: PathBuf,
    markers: Vec<String>,
    metadata: Vec<PathBuf>,
    source: PathBuf,
    paths: BTreeMap<PathBuf, bool>,
}
fn nearest_directory(path: &Path) -> Option<PathBuf> {
    path.ancestors()
        .find(|path| path.is_dir())
        .map(Path::to_path_buf)
}
fn plan(scope: &Scope, detection: &registry::Detection, source: &str) -> Result<Plan, String> {
    if detection.roots.len() > MAX_ROOTS || detection.ambiguous.len() > MAX_ROOTS {
        return Err("vcs.watch.limit".into());
    }
    let workspace = Path::new(&scope.workspace_root)
        .canonicalize()
        .map_err(|_| registry::STALE)?;
    let source = Path::new(source);
    let source = if let Some(parent) = nearest_directory(source) {
        parent.canonicalize().map_err(|_| "vcs.watch.failed")?.join(
            source
                .strip_prefix(&parent)
                .map_err(|_| "vcs.watch.failed")?,
        )
    } else {
        return Err("vcs.watch.failed".into());
    };
    let mut plan = Plan {
        workspace: workspace.clone(),
        markers: Vec::new(),
        metadata: Vec::new(),
        source,
        paths: BTreeMap::new(),
    };
    plan.paths.insert(workspace.clone(), true);
    for provider in &detection.providers {
        for marker in provider["markers"].as_array().into_iter().flatten() {
            if let Some(name) = marker["name"].as_str() {
                plan.markers.push(name.into());
            }
        }
    }
    for (index, parent) in workspace.ancestors().skip(1).enumerate() {
        if index >= MAX_ANCESTORS {
            return Err("vcs.watch.limit".into());
        }
        plan.paths.entry(parent.to_path_buf()).or_insert(false);
    }
    for root in &detection.roots {
        let root_path = Path::new(&root.path);
        plan.paths.entry(root_path.into()).or_insert(false);
        if let Some(provider) = detection
            .providers
            .iter()
            .find(|provider| provider["vcs"] == root.vcs)
        {
            for path in provider["metadataPaths"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|value| value.as_str())
            {
                let target = root_path.join(path);
                // Watch the closest existing parent; a newly created metadata
                // directory causes the next passive scan to refine the lease.
                if let Some(parent) = target.parent().and_then(nearest_directory) {
                    let resolved = parent.canonicalize().map_err(|_| "vcs.watch.failed")?;
                    let root = root_path.canonicalize().map_err(|_| registry::STALE)?;
                    if !resolved.starts_with(root) {
                        return Err("vcs.watch.failed".into());
                    }
                    plan.paths.entry(parent).or_insert(false);
                }
                if target.is_dir() {
                    let resolved = target.canonicalize().map_err(|_| "vcs.watch.failed")?;
                    if !resolved.starts_with(root_path.canonicalize().map_err(|_| registry::STALE)?)
                    {
                        return Err("vcs.watch.failed".into());
                    }
                    plan.paths.insert(target.clone(), true);
                }
                plan.metadata.push(target);
            }
        }
    }
    if let Some(parent) = plan.source.parent().and_then(nearest_directory) {
        plan.paths.entry(parent).or_insert(false);
    }
    if plan.paths.len() > MAX_PATHS {
        return Err("vcs.watch.limit".into());
    }
    Ok(plan)
}
fn relevant(plan: &Plan, event: &FileChangeEvent) -> bool {
    let path = Path::new(&event.path);
    if event.event_type == FileChangeType::Rescan {
        return true;
    }
    if path == plan.source || plan.source.starts_with(path) {
        return true;
    }
    if plan.metadata.iter().any(|metadata| {
        path == metadata || metadata.starts_with(path) || path.starts_with(metadata)
    }) {
        return true;
    }
    if path.starts_with(&plan.workspace) {
        return matches!(
            event.event_type,
            FileChangeType::Opened | FileChangeType::Deleted
        );
    }
    // Only root markers/directories are relevant outside the opened workspace.
    // Never recursively watch an enclosing working copy or interpret metadata.
    plan.workspace.starts_with(path)
        || path
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| plan.markers.iter().any(|marker| marker == name))
}
struct Emitter {
    app: AppHandle,
    host: String,
    scope: Scope,
    generation: u64,
    enabled: Arc<AtomicBool>,
    plan: Plan,
}
impl FileChangeEmitter for Emitter {
    fn emit_file_change(&self, event: &FileChangeEvent) {
        if relevant(&self.plan, event) && self.enabled.swap(false, Ordering::AcqRel) {
            super::metadata_changed(&self.app, &self.host, &self.scope, self.generation);
        }
    }
}
pub(super) fn install(
    app: &AppHandle,
    host: &str,
    scope: &Scope,
    generation: u64,
    detection: &registry::Detection,
    source: &str,
) -> Result<(), String> {
    use tauri::Manager;
    let plan = plan(scope, detection, source)?;
    let enabled = Arc::new(AtomicBool::new(true));
    let watcher = Arc::new(FileWatcher::new(Arc::new(Emitter {
        app: app.clone(),
        host: host.into(),
        scope: scope.clone(),
        generation,
        enabled: enabled.clone(),
        plan: plan.clone(),
    })));
    for (path, recursive) in plan.paths {
        if recursive {
            tauri::async_runtime::block_on(watcher.watch_path(path.to_string_lossy().into_owned()))
                .map_err(|_| "vcs.watch.failed")?;
        } else {
            watcher
                .watch_directory_shallow(path.to_string_lossy().into_owned())
                .map_err(|_| "vcs.watch.failed")?;
        }
    }
    let state = app.state::<super::VcsHostState>();
    state.watches.publish(
        &state.registry,
        host,
        Lease {
            scope: scope.clone(),
            generation,
            enabled,
            _watcher: watcher,
        },
    )
}

#[cfg(test)]
#[path = "vcs_watch_tests.rs"]
mod tests;
