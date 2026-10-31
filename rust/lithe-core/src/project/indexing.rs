//! Workspace-owned indexing exclusions, independent of tree visibility and Git writes.

use super::files::{existing_root, relative_path};
use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
/// User-owned policy. Missing policies preserve legacy Core callers' behavior.
pub struct IndexingPolicy {
    pub manual_excluded_directories: Vec<String>,
    pub included_directories: Vec<String>,
    pub git_ignore_enabled: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
/// Installs a policy before workspace consumers start; refresh discards Git decisions.
pub struct ConfigureIndexingRequest {
    pub root: String,
    /// Runtime identity. Omitted by legacy callers, which share one guarded lease.
    #[serde(default)]
    pub owner_id: Option<String>,
    #[serde(flatten)]
    pub policy: IndexingPolicy,
    #[serde(default)]
    pub refresh: bool,
    #[serde(default)]
    pub paths: Vec<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
/// Effective directory reasons and Git availability, never a claim about third-party scans.
pub struct IndexingStatus {
    pub revision: u64,
    pub excluded_directories: BTreeMap<String, String>,
    pub git_ignore_failed: bool,
}

/// Immutable policy generation with lazily cached Git directory decisions.
pub(crate) struct IndexingContext {
    pub(crate) revision: u64,
    /// Watcher scan refreshes retain the installation being committed or rolled back.
    installation_revision: u64,
    /// Legacy release token; watcher refreshes preserve host ownership.
    owner_revision: u64,
    /// Shared across scan generations so one owner cannot retire another owner's root.
    leases: Arc<Mutex<BTreeMap<Option<String>, IndexingLease>>>,
    root: PathBuf,
    policy: IndexingPolicy,
    /// Last successfully returned policy; failed generations never become the fallback.
    fallback_policy: Option<IndexingPolicy>,
    published: AtomicBool,
    decisions: Mutex<HashMap<String, bool>>,
    pub(crate) retired: AtomicBool,
    git_failed: AtomicBool,
    git_resolved: AtomicBool,
}

/// A failed installer may reclaim a token only before any caller has received it.
struct IndexingLease {
    revision: u64,
    published: bool,
    /// Remains releasable until a replacement token has actually been returned.
    previous_published: Option<u64>,
}

static POLICIES: OnceLock<Mutex<HashMap<PathBuf, Arc<IndexingContext>>>> = OnceLock::new();
static REVISION: AtomicU64 = AtomicU64::new(1);

fn policies() -> &'static Mutex<HashMap<PathBuf, Arc<IndexingContext>>> {
    POLICIES.get_or_init(Mutex::default)
}

fn validate_paths(paths: &mut Vec<String>) -> Result<(), CoreError> {
    for path in paths.iter_mut() {
        *path = path.trim_end_matches('/').to_string();
        if path != "."
            && (path.is_empty()
                || Path::new(path).is_absolute()
                || path.contains(['\\', '\0', ':'])
                || path
                    .split('/')
                    .any(|part| part.is_empty() || part == ".." || part == "."))
        {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Invalid indexing directory",
            ));
        }
    }
    paths.sort();
    paths.dedup();
    Ok(())
}

/// Registers a project policy atomically. In-flight readers cannot publish a retired generation.
pub fn configure(request: ConfigureIndexingRequest) -> Result<IndexingStatus, CoreError> {
    configure_with_provider_update(request, crate::lsp::indexing_changed)
}

fn configure_with_provider_update(
    mut request: ConfigureIndexingRequest,
    mut update_provider: impl FnMut(&Path) -> Result<(), CoreError>,
) -> Result<IndexingStatus, CoreError> {
    if request
        .owner_id
        .as_ref()
        .is_some_and(|owner| owner.is_empty())
    {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Indexing owner is empty",
        ));
    }
    let root = existing_root(&request.root)?;
    validate_paths(&mut request.policy.manual_excluded_directories)?;
    validate_paths(&mut request.policy.included_directories)?;
    validate_paths(&mut request.paths)?;
    let mut changed = false;
    let (context, lease_revision, installed_lease) = {
        let mut entries = policies()
            .lock()
            .map_err(|_| CoreError::new(ErrorCode::Unknown, "Indexing policy lock was poisoned"))?;
        let unchanged = entries.get(&root).filter(|old| {
            old.policy == request.policy && !request.refresh && !old.retired.load(Ordering::Acquire)
        });
        let context = if let Some(old) = unchanged {
            Arc::clone(old)
        } else {
            changed = true;
            let active = entries
                .get(&root)
                .filter(|old| !old.retired.load(Ordering::Acquire));
            let leases = active
                .map(|old| Arc::clone(&old.leases))
                .unwrap_or_default();
            let legacy_revision = active.map(|old| old.owner_revision);
            let fallback_policy = active.and_then(|old| {
                if old.published.load(Ordering::Acquire) {
                    Some(old.policy.clone())
                } else {
                    old.fallback_policy.clone()
                }
            });
            if let Some(old) = entries.get(&root) {
                old.retired.store(true, Ordering::Release);
            }
            let revision = REVISION.fetch_add(1, Ordering::Relaxed);
            let next = Arc::new(IndexingContext {
                revision,
                installation_revision: revision,
                owner_revision: if request.owner_id.is_none() {
                    revision
                } else {
                    legacy_revision.unwrap_or(revision)
                },
                leases,
                root: root.clone(),
                policy: request.policy,
                fallback_policy,
                published: AtomicBool::new(false),
                decisions: Mutex::default(),
                retired: AtomicBool::new(false),
                git_failed: AtomicBool::new(false),
                git_resolved: AtomicBool::new(false),
            });
            entries.insert(root.clone(), Arc::clone(&next));
            next
        };
        let (lease_revision, installed_lease) = {
            let mut leases = context.leases.lock().map_err(|_| {
                CoreError::new(ErrorCode::Unknown, "Indexing lease lock was poisoned")
            })?;
            let installed = changed || !leases.contains_key(&request.owner_id);
            if installed {
                let previous_published = leases.get(&request.owner_id).and_then(|lease| {
                    if lease.published {
                        Some(lease.revision)
                    } else {
                        lease.previous_published
                    }
                });
                let token = if request.owner_id.is_none() {
                    context.owner_revision
                } else {
                    REVISION.fetch_add(1, Ordering::Relaxed)
                };
                leases.insert(
                    request.owner_id.clone(),
                    IndexingLease {
                        revision: token,
                        published: false,
                        previous_published,
                    },
                );
            }
            (leases[&request.owner_id].revision, installed)
        };
        (context, lease_revision, installed_lease)
    };
    if changed {
        super::search_index::invalidate_root(&root);
    }
    let result = (|| {
        let mut excluded_directories = BTreeMap::new();
        for path in request.paths {
            if let Some(reason) = context.reason(&path, true)? {
                excluded_directories.insert(path, reason.to_string());
            }
        }
        for path in &context.policy.manual_excluded_directories {
            excluded_directories.insert(path.clone(), "manual".into());
        }
        if let Ok(decisions) = context.decisions.lock() {
            for (path, excluded) in decisions.iter() {
                if *excluded
                    && !context
                        .policy
                        .included_directories
                        .iter()
                        .any(|included| contains(included, path) || contains(path, included))
                {
                    excluded_directories
                        .entry(path.clone())
                        .or_insert_with(|| "git".into());
                }
            }
        }
        update_provider(&root)?;
        {
            // Publication and policy replacement share the registry lock. A
            // scan cannot pass its generation check and then publish an old set.
            let entries = policies().lock().map_err(|_| {
                CoreError::new(ErrorCode::Unknown, "Indexing policy lock was poisoned")
            })?;
            if !entries
                .get(&root)
                .is_some_and(|current| Arc::ptr_eq(current, &context))
            {
                return Err(CoreError::new(
                    ErrorCode::Cancelled,
                    "Indexing policy changed",
                ));
            }
            context.check()?;
            let mut leases = context.leases.lock().map_err(|_| {
                CoreError::new(ErrorCode::Unknown, "Indexing lease lock was poisoned")
            })?;
            let lease = leases
                .get_mut(&request.owner_id)
                .filter(|lease| lease.revision == lease_revision)
                .ok_or_else(|| CoreError::new(ErrorCode::Cancelled, "Indexing lease changed"))?;
            lease.published = true;
            lease.previous_published = None;
            context.published.store(true, Ordering::Release);
        }
        Ok(IndexingStatus {
            revision: lease_revision,
            excluded_directories,
            git_ignore_failed: context.git_failed.load(Ordering::Acquire),
        })
    })();
    if result.is_err() && installed_lease {
        // A caller receiving no token cannot release a failed installation.
        let _ = release_lease(
            ReleaseIndexingRequest {
                root: root.to_string_lossy().into_owned(),
                revision: lease_revision,
                owner_id: request.owner_id,
            },
            true,
        );
        if rollback_failed_policy(&root, &context)? {
            super::search_index::invalidate_root(&root);
            // Restore providers that received only part of the failed update.
            // Preserve the original error if shutdown/cancellation also blocks recovery.
            let _ = update_provider(&root);
        }
    }
    result
}

fn rollback_failed_policy(root: &Path, failed: &Arc<IndexingContext>) -> Result<bool, CoreError> {
    let mut entries = policies()
        .lock()
        .map_err(|_| CoreError::new(ErrorCode::Unknown, "Indexing policy lock was poisoned"))?;
    let Some(current) = entries.get(root).cloned() else {
        return Ok(false);
    };
    if current.installation_revision != failed.installation_revision
        || current.retired.load(Ordering::Acquire)
        || current.published.load(Ordering::Acquire)
    {
        return Ok(false);
    }
    let Some(policy) = current.fallback_policy.clone() else {
        return Ok(false);
    };
    let leases = current
        .leases
        .lock()
        .map_err(|_| CoreError::new(ErrorCode::Unknown, "Indexing lease lock was poisoned"))?;
    if leases.is_empty() {
        return Ok(false);
    }
    let revision = REVISION.fetch_add(1, Ordering::Relaxed);
    let next = Arc::new(IndexingContext {
        revision,
        installation_revision: revision,
        owner_revision: leases
            .get(&None)
            .map_or(current.owner_revision, |lease| lease.revision),
        leases: Arc::clone(&current.leases),
        root: root.to_path_buf(),
        policy: policy.clone(),
        fallback_policy: Some(policy),
        published: AtomicBool::new(true),
        decisions: Mutex::default(),
        retired: AtomicBool::new(false),
        git_failed: AtomicBool::new(false),
        git_resolved: AtomicBool::new(false),
    });
    current.retired.store(true, Ordering::Release);
    drop(leases);
    entries.insert(root.to_path_buf(), next);
    Ok(true)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
/// Revision-guarded release; a late old window must not retire a newly opened project.
pub struct ReleaseIndexingRequest {
    pub root: String,
    pub revision: u64,
    /// Releases only this runtime's lease, never another runtime using the same root.
    #[serde(default)]
    pub owner_id: Option<String>,
}

pub fn release(request: ReleaseIndexingRequest) -> Result<bool, CoreError> {
    release_lease(request, false)
}

fn release_lease(
    request: ReleaseIndexingRequest,
    only_unpublished: bool,
) -> Result<bool, CoreError> {
    let requested = PathBuf::from(request.root);
    let root =
        super::search_index::canonicalize_with_missing_components(&requested).unwrap_or(requested);
    let entries = policies()
        .lock()
        .map_err(|_| CoreError::new(ErrorCode::Unknown, "Indexing policy lock was poisoned"))?;
    let Some(context) = entries.get(&root) else {
        return Ok(false);
    };
    let mut leases = context
        .leases
        .lock()
        .map_err(|_| CoreError::new(ErrorCode::Unknown, "Indexing lease lock was poisoned"))?;
    let Some(lease) = leases.get(&request.owner_id) else {
        return Ok(false);
    };
    let matches = lease.revision == request.revision
        || (!only_unpublished && lease.previous_published == Some(request.revision));
    if !matches || (only_unpublished && lease.published) {
        return Ok(false);
    }
    if only_unpublished {
        if let Some(previous) = lease.previous_published {
            leases.insert(
                request.owner_id,
                IndexingLease {
                    revision: previous,
                    published: true,
                    previous_published: None,
                },
            );
            return Ok(false);
        }
    }
    leases.remove(&request.owner_id);
    if !leases.is_empty() {
        return Ok(true);
    }
    context.retired.store(true, Ordering::Release);
    context
        .decisions
        .lock()
        .map_err(|_| CoreError::new(ErrorCode::Unknown, "Indexing decision lock was poisoned"))?
        .clear();
    drop(leases);
    drop(entries);
    super::search_index::invalidate_root(&root);
    Ok(true)
}

pub(crate) fn context(root: &Path) -> Option<Arc<IndexingContext>> {
    policies().lock().ok()?.get(root).cloned()
}

/// Provider requests without a live owner retain their standalone behavior.
/// Retired records still cancel late inventory readers through `context`.
pub(crate) fn active_provider_context(root: &Path) -> Option<Arc<IndexingContext>> {
    context(root).filter(|context| !context.retired.load(Ordering::Acquire))
}

pub(crate) fn refresh(root: &Path) -> Result<(), CoreError> {
    {
        let mut entries = policies()
            .lock()
            .map_err(|_| CoreError::new(ErrorCode::Unknown, "Indexing policy lock was poisoned"))?;
        let Some(old) = entries.get(root) else {
            return Ok(());
        };
        // Closing a workspace must never be undone by a late watcher event.
        old.check()?;
        let next = Arc::new(IndexingContext {
            revision: REVISION.fetch_add(1, Ordering::Relaxed),
            installation_revision: old.installation_revision,
            owner_revision: old.owner_revision,
            leases: Arc::clone(&old.leases),
            root: old.root.clone(),
            policy: old.policy.clone(),
            fallback_policy: old.fallback_policy.clone(),
            published: AtomicBool::new(old.published.load(Ordering::Acquire)),
            decisions: Mutex::default(),
            retired: AtomicBool::new(false),
            git_failed: AtomicBool::new(false),
            git_resolved: AtomicBool::new(false),
        });
        old.retired.store(true, Ordering::Release);
        entries.insert(root.to_path_buf(), next);
    }
    super::search_index::invalidate_root(root);
    // The caller rebuilds Git decisions before publishing provider settings.
    Ok(())
}

/// Resolve native Git decisions before a live provider receives a new generation.
/// This reuses the inventory walker (no file text reads) and prunes excluded trees.
pub(crate) fn prepare_provider_exclusions(
    root: &Path,
) -> Result<Option<Arc<IndexingContext>>, CoreError> {
    let Some(context) = active_provider_context(root) else {
        return Ok(None);
    };
    context.check()?;
    if context.policy.git_ignore_enabled && !context.git_resolved.load(Ordering::Acquire) {
        context.prepare_parent(root, "")?;
        super::files::snapshot(super::files::WorkspaceSnapshotRequest {
            root: root.to_string_lossy().into_owned(),
            workspace_roots: Vec::new(),
            hidden_directory_names: Vec::new(),
            hidden_file_patterns: Vec::new(),
            include_tree: false,
        })?;
        context.check()?;
        context.git_resolved.store(true, Ordering::Release);
    }
    Ok(Some(context))
}

fn contains(directory: &str, path: &str) -> bool {
    #[cfg(windows)]
    let (directory, path) = (directory.to_lowercase(), path.to_lowercase());
    directory == "."
        || path == directory
        || path
            .strip_prefix(&directory[..])
            .is_some_and(|suffix| suffix.starts_with('/'))
}

impl IndexingContext {
    pub(crate) fn check(&self) -> Result<(), CoreError> {
        crate::protocol::cancellation::check()?;
        if self.retired.load(Ordering::Acquire) {
            return Err(CoreError::new(
                ErrorCode::Cancelled,
                "Indexing policy changed",
            ));
        }
        Ok(())
    }

    pub(crate) fn reason(
        &self,
        relative: &str,
        is_directory: bool,
    ) -> Result<Option<&'static str>, CoreError> {
        self.check()?;
        if self
            .policy
            .manual_excluded_directories
            .iter()
            .any(|dir| contains(dir, relative))
        {
            return Ok(Some("manual"));
        }
        if !self.policy.git_ignore_enabled
            || self
                .policy
                .included_directories
                .iter()
                .any(|dir| contains(dir, relative))
        {
            return Ok(None);
        }
        if relative.is_empty() || relative == "." {
            return Ok(None);
        }
        if is_directory
            && self
                .policy
                .included_directories
                .iter()
                .any(|included| contains(relative, included))
        {
            return Ok(None);
        }
        let parts = relative.split('/').collect::<Vec<_>>();
        let count = parts.len().saturating_sub(usize::from(!is_directory));
        for length in 1..=count {
            let directory = parts[..length].join("/");
            self.prepare_parent(
                self.root.join(&directory).parent().unwrap_or(&self.root),
                &directory,
            )?;
            if self
                .decisions
                .lock()
                .map_err(|_| {
                    CoreError::new(ErrorCode::Unknown, "Indexing decision lock was poisoned")
                })?
                .get(&directory)
                == Some(&true)
            {
                return Ok(Some("git"));
            }
        }
        Ok(None)
    }

    /// Queries sibling directories in one batch, without enumerating their contents.
    fn prepare_parent(&self, parent: &Path, requested: &str) -> Result<(), CoreError> {
        self.check()?;

        if self
            .decisions
            .lock()
            .map_err(|_| CoreError::new(ErrorCode::Unknown, "Indexing decision lock was poisoned"))?
            .contains_key(requested)
        {
            return Ok(());
        }
        let Ok(entries) = std::fs::read_dir(parent) else {
            return Ok(());
        };
        let candidates = entries
            .filter_map(Result::ok)
            .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_dir()))
            .filter_map(|entry| entry.file_name().into_string().ok())
            .collect::<Vec<_>>();
        let ignored = crate::git::ignored_paths(parent, &candidates)?;
        let mut decisions = HashMap::new();
        if let Some(ignored) = ignored {
            // The index is authoritative for tracked descendants; check-ignore on a directory
            // alone does not protect tracked files below an otherwise ignored directory.
            for name in candidates {
                let excluded = if parent.join(&name).join(".git").exists() {
                    // A nested repository owns its ignore rules and tracked content.
                    false
                } else if ignored.contains(&name) {
                    let response = crate::git::execute_git_readonly(
                        &parent.to_string_lossy(),
                        &[
                            "--literal-pathspecs".into(),
                            "ls-files".into(),
                            "-z".into(),
                            "--".into(),
                            name.clone(),
                        ],
                        None,
                    );
                    self.check()?;
                    let Ok(response) = response else {
                        self.git_failed.store(true, Ordering::Release);
                        continue;
                    };
                    if response.exit_code != 0 {
                        self.git_failed.store(true, Ordering::Release);
                        false
                    } else {
                        response.stdout.is_empty()
                    }
                } else {
                    false
                };
                decisions.insert(relative_path(&parent.join(name), &self.root), excluded);
            }
        } else {
            self.git_failed.store(true, Ordering::Release);
            for name in candidates {
                decisions.insert(relative_path(&parent.join(name), &self.root), false);
            }
        }
        self.check()?;
        let mut cache = self.decisions.lock().map_err(|_| {
            CoreError::new(ErrorCode::Unknown, "Indexing decision lock was poisoned")
        })?;
        cache.extend(decisions);
        Ok(())
    }
}

pub(crate) fn is_excluded(root: &Path, path: &Path, is_directory: bool) -> Result<bool, CoreError> {
    match context(root) {
        Some(policy) => Ok(policy
            .reason(&relative_path(path, root), is_directory)?
            .is_some()),
        None => Ok(false),
    }
}

/// Resolved roots for provider adapters. Git decisions are populated by the project scan.
pub(crate) fn excluded_roots(root: &Path) -> Vec<String> {
    let Some(context) = active_provider_context(root) else {
        return Vec::new();
    };
    let mut roots = context.policy.manual_excluded_directories.clone();
    if let Ok(decisions) = context.decisions.lock() {
        roots.extend(
            decisions
                .iter()
                .filter(|(path, excluded)| {
                    **excluded
                        && !context
                            .policy
                            .included_directories
                            .iter()
                            .any(|included| contains(included, path) || contains(path, included))
                })
                .map(|(path, _)| path.clone()),
        );
    }
    roots.sort();
    roots.dedup();
    roots
}

/// File URIs are normalized through the same workspace root as index consumers.
pub(crate) fn uri_is_excluded(root_uri: &str, uri: &str) -> Result<bool, CoreError> {
    let root = url::Url::parse(root_uri)
        .ok()
        .and_then(|value| value.to_file_path().ok());
    let path = url::Url::parse(uri)
        .ok()
        .and_then(|value| value.to_file_path().ok());
    match (root, path) {
        (Some(root), Some(path)) => {
            let root = root.canonicalize().unwrap_or(root);
            // A server may report a canonical URI while its workspace uses a
            // symlink alias. Deleted files still need their surviving ancestor.
            let path =
                super::search_index::canonicalize_with_missing_components(&path).unwrap_or(path);
            if !path.starts_with(&root) {
                return Ok(false);
            }
            if active_provider_context(&root).is_none() {
                return Ok(false);
            }
            is_excluded(&root, &path, false)
        }
        _ => Ok(false),
    }
}

/// Import globs only: these do not guarantee exclusion of referenced Java resources.
pub(crate) fn java_import_exclusions(root_uri: &str) -> Vec<String> {
    let Some(root) = url::Url::parse(root_uri)
        .ok()
        .and_then(|value| value.to_file_path().ok())
    else {
        return Vec::new();
    };
    let root = root.canonicalize().unwrap_or(root);
    excluded_roots(&root)
        .into_iter()
        // Native import patterns cannot faithfully represent literal glob metacharacters.
        .filter(|path| !path.contains(['*', '?', '[', ']', '{', '}']))
        .flat_map(|path| {
            if path == "." {
                vec!["**".into()]
            } else {
                let directory = root.join(path).to_string_lossy().replace('\\', "/");
                // JDT LS BasicFileDetector matches the candidate directory itself
                // before visiting children. A trailing /** alone misses its pom.xml.
                vec![directory.clone(), format!("{directory}/**")]
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::super::{files, search_index};
    use super::*;
    use serde_json::json;
    use std::fs;

    #[test]
    fn java_import_exclusion_matches_the_directory_itself_before_its_descendants() {
        let workspace = Workspace::new();
        workspace.configure(&["ignored"], &[], false);
        let uri = url::Url::from_directory_path(&workspace.0).unwrap();
        let directory = workspace
            .0
            .join("ignored")
            .to_string_lossy()
            .replace('\\', "/");
        assert_eq!(
            java_import_exclusions(uri.as_str()),
            vec![directory.clone(), format!("{directory}/**")]
        );
    }

    struct Workspace(PathBuf);
    impl Workspace {
        fn new() -> Self {
            let root = crate::tests::support::temporary_root("indexing-policy");
            fs::create_dir_all(root.join("ignored/deep")).unwrap();
            fs::create_dir_all(root.join("src")).unwrap();
            fs::write(
                root.join("ignored/deep/Excluded.java"),
                "class Excluded { String needle; }",
            )
            .unwrap();
            fs::write(
                root.join("src/Included.java"),
                "class Included { String needle; }",
            )
            .unwrap();
            Self(root.canonicalize().unwrap())
        }
        fn configure(&self, manual: &[&str], included: &[&str], git: bool) -> IndexingStatus {
            configure(
                serde_json::from_value(json!({"root": self.0,
                "manualExcludedDirectories": manual, "includedDirectories": included,
                "gitIgnoreEnabled": git, "refresh": true}))
                .unwrap(),
            )
            .unwrap()
        }
        fn files(&self) -> Vec<String> {
            files::snapshot(
                serde_json::from_value(json!({"root": self.0, "includeTree": false})).unwrap(),
            )
            .unwrap()
            .files
        }
        fn git(&self, args: &[&str]) {
            let response = crate::git::execute_git_readonly(
                &self.0.to_string_lossy(),
                &args.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
                None,
            )
            .unwrap();
            assert_eq!(response.exit_code, 0, "{}", response.stderr);
        }
    }
    impl Drop for Workspace {
        fn drop(&mut self) {
            if let Some(context) = policies().lock().unwrap().remove(&self.0) {
                context.retired.store(true, Ordering::Release);
            }
            search_index::invalidate_root(&self.0);
            files::DIRECTORY_VISITS.with_borrow_mut(|trace| *trace = None);
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn nested_roots_prune_real_inventories_search_and_incremental_refills() {
        let parent = Workspace::new();
        let nested = Workspace(parent.0.join("ignored"));
        parent.configure(&[], &[], false);
        fs::write(
            nested.0.join("Visible.java"),
            "class Visible { String needle; }",
        )
        .unwrap();
        let roots = vec![parent.0.clone(), nested.0.clone()];
        let search = |root: &Path, roots: &[PathBuf]| {
            files::search(
                serde_json::from_value(json!({
                    "root": root, "workspaceRoots": roots, "query":"needle", "maxFileResults":0
                }))
                .unwrap(),
            )
            .unwrap()
        };
        assert_eq!(
            search(&parent.0, &[]).matches.len(),
            3,
            "warm the legacy parent index"
        );
        for git in [false, true] {
            if git {
                nested.git(&["init", "--quiet"]);
                fs::write(nested.0.join(".gitignore"), "deep/\n").unwrap();
            }
            nested.configure(if git { &[] } else { &["deep"] }, &[], git);
            files::DIRECTORY_VISITS.with_borrow_mut(|trace| *trace = Some(Vec::new()));
            let inventory = files::snapshot(
                serde_json::from_value(json!({
                    "root":parent.0, "workspaceRoots":roots, "includeTree":false
                }))
                .unwrap(),
            )
            .unwrap();
            assert_eq!(inventory.files, ["src/Included.java"]);
            files::DIRECTORY_VISITS.with_borrow(|trace| {
                assert!(!trace
                    .as_ref()
                    .unwrap()
                    .iter()
                    .any(|path| path.starts_with(&nested.0)))
            });
            assert_eq!(search(&parent.0, &roots).matches.len(), 1);
            assert_eq!(
                search(&nested.0, &roots)
                    .matches
                    .iter()
                    .map(|item| item.path.as_str())
                    .collect::<Vec<_>>(),
                ["Visible.java"]
            );
            let warm = files::warm_search_index(
                serde_json::from_value(json!({
                    "root":parent.0,"workspaceRoots":roots
                }))
                .unwrap(),
            )
            .unwrap();
            assert_eq!(warm.file_count, 1);
            search_index::update_cached_file(&parent.0, &nested.0.join("Visible.java"));
            let updated = files::update_search_index(
                serde_json::from_value(json!({
                    "root":parent.0,"workspaceRoots":roots,"paths":["ignored/Visible.java"]
                }))
                .unwrap(),
            )
            .unwrap();
            assert_eq!(
                updated.file_count, 1,
                "watcher updates cannot refill a delegated subtree"
            );
            let preview = files::replace_preview(serde_json::from_value(json!({
                "root":parent.0,"workspaceRoots":roots,"query":"needle","replacement":"changed",
                "paths":["ignored/Visible.java"],"textOverrides":{"ignored/Visible.java":"needle"}
            })).unwrap()).unwrap();
            assert!(
                preview.files.is_empty(),
                "explicit paths and dirty overrides also obey ownership"
            );
            let names = files::search_everywhere(serde_json::from_value(json!({
                "root":parent.0,"workspaceRoots":roots,"query":"Visible","includeGeneratedFileNames":true
            })).unwrap()).unwrap();
            assert!(names.matches.is_empty());
        }
        // Another window's registered policy does not delegate this window's scan.
        assert_eq!(search(&parent.0, &[]).matches.len(), 3);
        let status = context(&nested.0).unwrap();
        release(ReleaseIndexingRequest {
            owner_id: None,
            root: nested.0.to_string_lossy().into_owned(),
            revision: status.owner_revision,
        })
        .unwrap();
        assert_eq!(
            search(&parent.0, &[parent.0.clone()]).matches.len(),
            3,
            "removing an added root restores parent scanning even while its policy is retired"
        );
    }

    #[test]
    fn unavailable_roots_do_not_break_scoped_search_or_missing_descendant_boundaries() {
        let workspace = Workspace::new();
        workspace.configure(&[], &[], false);
        let unavailable_sibling = workspace.0.with_extension("disconnected");
        let roots = vec![workspace.0.clone(), unavailable_sibling];
        let response = files::search(
            serde_json::from_value(json!({
                "root":workspace.0,"workspaceRoots":roots,"scopePaths":["src"],
                "query":"needle","maxFileResults":0,"maxResults":1
            }))
            .unwrap(),
        )
        .unwrap();
        assert_eq!(response.matches.len(), 1);
        let nested = workspace.0.join("ignored");
        fs::remove_dir_all(&nested).unwrap();
        let request =
            json!({"root":workspace.0,"workspaceRoots":[workspace.0,nested],"includeTree":false});
        assert_eq!(
            files::snapshot(serde_json::from_value(request.clone()).unwrap())
                .unwrap()
                .files,
            ["src/Included.java"]
        );
        fs::create_dir_all(&nested).unwrap();
        fs::write(nested.join("Reappeared.java"), "class Reappeared {}").unwrap();
        assert_eq!(
            files::snapshot(serde_json::from_value(request).unwrap())
                .unwrap()
                .files,
            ["src/Included.java"],
            "reappearing delegated content cannot leak into the parent"
        );
    }

    #[test]
    fn nested_root_fixture_keeps_scopes_caps_and_tree_browsing_independent() {
        let parent = Workspace::new();
        let nested = Workspace(parent.0.join("ignored"));
        parent.configure(&[], &[], false);
        nested.configure(&["deep"], &[], false);
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/workspace/indexing-policy-v1.json"
        ))
        .unwrap();
        for case in fixture["ownershipCases"].as_array().unwrap() {
            let roots = if case["nestedRegistered"].as_bool().unwrap() {
                vec![parent.0.clone(), nested.0.clone()]
            } else {
                vec![parent.0.clone()]
            };
            let response = files::search(serde_json::from_value(json!({
                "root":parent.0,"workspaceRoots":roots,"query":"needle","scopePaths":["ignored"],
                "maxFileResults":0,"maxResults":1
            })).unwrap()).unwrap();
            assert_eq!(
                response.matches.len(),
                case["parentScopedMatches"].as_u64().unwrap() as usize
            );
        }
        let tree = files::list_directories(
            serde_json::from_value(json!({
                "root":parent.0,"paths":["ignored/deep"]
            }))
            .unwrap(),
        )
        .unwrap();
        assert_eq!(tree.directories[0].children[0].name, "Excluded.java");
    }

    #[test]
    fn manual_exclusion_prunes_enumeration_but_keeps_tree_browsing() {
        let workspace = Workspace::new();
        workspace.configure(&["ignored"], &[], false);
        files::DIRECTORY_VISITS.with_borrow_mut(|trace| *trace = Some(Vec::new()));
        assert_eq!(workspace.files(), ["src/Included.java"]);
        files::DIRECTORY_VISITS.with_borrow(|trace| {
            assert!(!trace
                .as_ref()
                .unwrap()
                .iter()
                .any(|path| path.starts_with(workspace.0.join("ignored"))))
        });
        let tree = files::list_directories(
            serde_json::from_value(
                json!({"root": workspace.0, "paths": ["", "ignored", "ignored/deep"]}),
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(tree.directories.len(), 3);
        assert!(tree.directories[2]
            .children
            .iter()
            .any(|node| node.name == "Excluded.java"));
        assert_eq!(
            workspace.files(),
            ["src/Included.java"],
            "Browsing must not add candidates"
        );
    }

    #[test]
    fn policy_change_retires_old_readers_and_blocks_warm_cache_refill() {
        let workspace = Workspace::new();
        workspace.configure(&[], &[], false);
        let old = context(&workspace.0).unwrap();
        let query = || {
            files::search_everywhere(serde_json::from_value(json!({"root":workspace.0,"query":"Excluded", "includeGeneratedFileNames":true})).unwrap()).unwrap()
        };
        assert!(!query().matches.is_empty());
        workspace.configure(&["ignored"], &["ignored/deep"], false);
        assert!(matches!(
            old.check().unwrap_err().code,
            ErrorCode::Cancelled
        ));
        assert!(
            query().matches.is_empty(),
            "A child exception cannot bypass a manual ancestor"
        );
        search_index::update_cached_file(
            &workspace.0,
            &workspace.0.join("ignored/deep/Excluded.java"),
        );
        assert!(query().matches.is_empty());
        workspace.configure(&[], &[], false);
        assert!(!query().matches.is_empty());
    }

    /// Integration fixture uses the bounded native Git runner; no user repository or Git config is modified.
    #[test]
    fn git_directory_rules_preserve_tracked_files_and_include_exceptions() {
        let workspace = Workspace::new();
        workspace.git(&["init", "--quiet"]);
        fs::write(
            workspace.0.join(".gitignore"),
            "ignored/\n*.log\ntracked/\n",
        )
        .unwrap();
        fs::write(workspace.0.join("single.log"), "still a candidate").unwrap();
        fs::create_dir_all(workspace.0.join("tracked")).unwrap();
        fs::write(workspace.0.join("tracked/keep.java"), "class Keep {}").unwrap();
        workspace.git(&["add", "-f", "tracked/keep.java"]);
        workspace.configure(&[], &[], true);
        let files = workspace.files();
        assert!(!files.contains(&"ignored/deep/Excluded.java".into()));
        assert!(files.contains(&"single.log".into()));
        assert!(files.contains(&"tracked/keep.java".into()));
        workspace.configure(&[], &["ignored/deep"], true);
        assert!(workspace
            .files()
            .contains(&"ignored/deep/Excluded.java".into()));
        workspace.configure(&["ignored/deep"], &["ignored"], true);
        assert!(!workspace
            .files()
            .contains(&"ignored/deep/Excluded.java".into()));
        workspace.configure(&[], &[], false);
        assert!(workspace
            .files()
            .contains(&"ignored/deep/Excluded.java".into()));
    }
    #[test]
    fn watcher_refresh_preserves_host_release_and_rejects_both_stale_and_closed_readers() {
        let workspace = Workspace::new();
        let installed = workspace.configure(&["ignored"], &[], false);
        let before = context(&workspace.0).unwrap();
        files::update_search_index(
            serde_json::from_value(json!({
                "root": workspace.0, "paths": [".gitignore"]
            }))
            .unwrap(),
        )
        .unwrap();
        let after = context(&workspace.0).unwrap();
        assert_ne!(before.revision, after.revision);
        assert!(before.check().is_err());
        assert_eq!(workspace.files(), ["src/Included.java"]);
        assert!(release(ReleaseIndexingRequest {
            owner_id: None,
            root: workspace.0.to_string_lossy().into_owned(),
            revision: installed.revision,
        })
        .unwrap());
        assert!(after.check().is_err());
        assert!(
            refresh(&workspace.0).is_err(),
            "A late watcher cannot reopen a closed policy"
        );
        assert!(
            files::snapshot(serde_json::from_value(json!({ "root": workspace.0 })).unwrap())
                .is_err()
        );
        let reopened = workspace.configure(&[], &[], false);
        assert!(!release(ReleaseIndexingRequest {
            owner_id: None,
            root: workspace.0.to_string_lossy().into_owned(),
            revision: installed.revision,
        })
        .unwrap());
        assert_ne!(reopened.revision, installed.revision);
        assert_eq!(workspace.files().len(), 2);
    }

    #[test]
    fn release_rejects_late_work_and_cannot_retire_a_new_generation() {
        let workspace = Workspace::new();
        let first = workspace.configure(&[], &[], false);
        let old = context(&workspace.0).unwrap();
        assert!(release(ReleaseIndexingRequest {
            owner_id: None,
            root: workspace.0.to_string_lossy().into_owned(),
            revision: first.revision
        })
        .unwrap());
        assert!(old.check().is_err());
        let second = workspace.configure(&["ignored"], &[], false);
        assert!(second.revision > first.revision);
        assert!(!release(ReleaseIndexingRequest {
            owner_id: None,
            root: workspace.0.to_string_lossy().into_owned(),
            revision: first.revision
        })
        .unwrap());
        assert_eq!(workspace.files(), ["src/Included.java"]);
    }

    #[test]
    fn shared_root_leases_survive_other_owner_refresh_close_and_late_release() {
        let workspace = Workspace::new();
        let install = |owner: &str, excluded: bool, refresh: bool| {
            configure(serde_json::from_value(json!({
            "root": workspace.0, "ownerId": owner, "manualExcludedDirectories": if excluded { vec!["ignored"] } else { vec![] },
            "includedDirectories": [], "gitIgnoreEnabled": false, "refresh": refresh
        })).unwrap()).unwrap().revision
        };
        let close = |owner: &str, revision| {
            release(ReleaseIndexingRequest {
                root: workspace.0.to_string_lossy().into_owned(),
                owner_id: Some(owner.into()),
                revision,
            })
            .unwrap()
        };
        let first = install("window-a/workspace-a", false, false);
        let second = install("window-b/workspace-b", false, false);
        assert_ne!(first, second);
        assert!(
            !release_lease(
                ReleaseIndexingRequest {
                    root: workspace.0.to_string_lossy().into_owned(),
                    owner_id: Some("window-b/workspace-b".into()),
                    revision: second,
                },
                true
            )
            .unwrap(),
            "a failed concurrent installer cannot reclaim a token already returned to a caller"
        );
        assert!(close("window-a/workspace-a", first));
        assert_eq!(
            workspace.files().len(),
            2,
            "the other workspace still owns this root"
        );
        let reopened = install("window-a/workspace-reopened", true, true);
        assert!(!close("window-a/workspace-a", first));
        assert!(
            close("window-b/workspace-b", second),
            "policy replacement preserves other leases"
        );
        refresh(&workspace.0).unwrap();
        assert_eq!(workspace.files(), ["src/Included.java"]);
        let replacement = install("window-a/workspace-reopened", false, true);
        assert!(!close("window-a/workspace-reopened", reopened));
        assert_eq!(workspace.files().len(), 2);
        assert!(close("window-a/workspace-reopened", replacement));
        assert!(context(&workspace.0).unwrap().check().is_err());
        assert!(
            refresh(&workspace.0).is_err(),
            "watchers must not resurrect the last closed lease"
        );
    }

    #[test]
    fn failed_policy_update_restores_the_last_successful_policy_and_owner_leases() {
        assert_failed_policy_restores_published_state(false);
    }

    #[test]
    fn failed_policy_update_restores_the_policy_after_a_concurrent_watcher_refresh() {
        assert_failed_policy_restores_published_state(true);
    }

    fn assert_failed_policy_restores_published_state(watcher_refresh: bool) {
        let workspace = Workspace::new();
        let request = |owner: &str, excluded: bool| {
            serde_json::from_value(json!({
            "root":workspace.0,"ownerId":owner,"manualExcludedDirectories":if excluded {vec!["ignored"]} else {vec![]},
            "includedDirectories":[],"gitIgnoreEnabled":false
        })).unwrap()
        };
        let original = configure(request("owner-a", false)).unwrap();
        let other = configure(request("owner-b", false)).unwrap();
        let old_context = context(&workspace.0).unwrap();
        let mut calls = 0;
        let result = configure_with_provider_update(request("owner-a", true), |_| {
            calls += 1;
            if calls == 1 {
                if watcher_refresh {
                    refresh(&workspace.0)?;
                }
                Err(CoreError::new(
                    ErrorCode::Cancelled,
                    "provider update cancelled",
                ))
            } else {
                Ok(())
            }
        });
        assert!(result.is_err());
        assert_eq!(calls, 2, "providers receive a best-effort restoration");
        assert!(
            old_context.check().is_err(),
            "old in-flight scans stay retired after rollback"
        );
        assert_eq!(
            workspace.files().len(),
            2,
            "failed exclusions must not remain active"
        );
        for (owner, revision) in [("owner-a", original.revision), ("owner-b", other.revision)] {
            assert!(release(ReleaseIndexingRequest {
                root: workspace.0.to_string_lossy().into_owned(),
                owner_id: Some(owner.into()),
                revision
            })
            .unwrap());
        }
        assert!(context(&workspace.0).unwrap().check().is_err());
    }

    #[test]
    fn another_successful_installer_keeps_an_adopted_policy_after_the_first_caller_fails() {
        let workspace = Workspace::new();
        let request = |excluded| {
            serde_json::from_value(json!({
            "root":workspace.0,"ownerId":"owner-a","manualExcludedDirectories":if excluded {vec!["ignored"]} else {vec![]},
            "includedDirectories":[],"gitIgnoreEnabled":false
        })).unwrap()
        };
        configure(request(false)).unwrap();
        let mut received = 0;
        let result = configure_with_provider_update(request(true), |_| {
            received = configure(request(true))?.revision;
            Err(CoreError::new(
                ErrorCode::Cancelled,
                "caller cancelled after concurrent publication",
            ))
        });
        assert!(result.is_err());
        assert_eq!(workspace.files(), ["src/Included.java"]);
        assert!(release(ReleaseIndexingRequest {
            root: workspace.0.to_string_lossy().into_owned(),
            owner_id: Some("owner-a".into()),
            revision: received
        })
        .unwrap());
    }

    #[test]
    fn cancelled_reconfiguration_preserves_the_last_published_owner_lease() {
        let workspace = Workspace::new();
        let request = |owner: &str, excluded: bool, refresh: bool| {
            serde_json::from_value(json!({
            "root":workspace.0,"ownerId":owner,"manualExcludedDirectories":if excluded {vec!["ignored"]} else {vec![]},
            "includedDirectories":[],"gitIgnoreEnabled":false,"refresh":refresh
        })).unwrap()
        };
        let original = configure(request("owner-a", false, false)).unwrap();
        let mut other = 0;
        let cancelled = configure_with_provider_update(request("owner-a", false, true), |_| {
            other = configure(request("owner-b", true, false))?.revision;
            Ok(())
        });
        assert!(matches!(
            cancelled,
            Err(CoreError {
                code: ErrorCode::Cancelled,
                ..
            })
        ));
        assert!(release(ReleaseIndexingRequest {
            root: workspace.0.to_string_lossy().into_owned(),
            owner_id: Some("owner-b".into()),
            revision: other
        })
        .unwrap());
        assert_eq!(
            workspace.files(),
            ["src/Included.java"],
            "the still-open owner keeps the latest root policy alive"
        );
        assert!(release(ReleaseIndexingRequest {
            root: workspace.0.to_string_lossy().into_owned(),
            owner_id: Some("owner-a".into()),
            revision: original.revision
        })
        .unwrap());
        assert!(context(&workspace.0).unwrap().check().is_err());
    }

    #[test]
    fn cancelled_installer_cannot_withdraw_a_shared_token_returned_by_another_call() {
        let workspace = Workspace::new();
        let request = |owner: &str, excluded: bool| {
            serde_json::from_value(json!({
            "root":workspace.0,"ownerId":owner,"manualExcludedDirectories":if excluded {vec!["ignored"]} else {vec![]},
            "includedDirectories":[],"gitIgnoreEnabled":false
        })).unwrap()
        };
        let mut received = 0;
        let mut other = 0;
        let cancelled = configure_with_provider_update(request("owner-a", false), |_| {
            received = configure(request("owner-a", false))?.revision;
            other = configure(request("owner-b", true))?.revision;
            Ok(())
        });
        assert!(cancelled.is_err());
        assert!(release(ReleaseIndexingRequest {
            root: workspace.0.to_string_lossy().into_owned(),
            owner_id: Some("owner-b".into()),
            revision: other
        })
        .unwrap());
        assert_eq!(workspace.files(), ["src/Included.java"]);
        assert!(release(ReleaseIndexingRequest {
            root: workspace.0.to_string_lossy().into_owned(),
            owner_id: Some("owner-a".into()),
            revision: received
        })
        .unwrap());
    }

    #[test]
    fn closing_the_published_lease_also_cancels_an_unpublished_replacement() {
        let workspace = Workspace::new();
        let request = |refresh| {
            serde_json::from_value(json!({
            "root":workspace.0,"ownerId":"owner-a","manualExcludedDirectories":[],"includedDirectories":[],"gitIgnoreEnabled":false,"refresh":refresh
        })).unwrap()
        };
        let original = configure(request(false)).unwrap();
        let cancelled = configure_with_provider_update(request(true), |_| {
            assert!(release(ReleaseIndexingRequest {
                root: workspace.0.to_string_lossy().into_owned(),
                owner_id: Some("owner-a".into()),
                revision: original.revision
            })?);
            Ok(())
        });
        assert!(cancelled.is_err());
        assert!(context(&workspace.0).unwrap().check().is_err());
    }

    #[test]
    fn provider_preparation_returns_the_exact_generation_that_was_scanned() {
        let workspace = Workspace::new();
        workspace.configure(&[], &[], true);
        let prepared = prepare_provider_exclusions(&workspace.0).unwrap().unwrap();
        assert!(prepared.git_resolved.load(Ordering::Acquire));
        refresh(&workspace.0).unwrap();
        assert!(prepared.check().is_err());
        let next = context(&workspace.0).unwrap();
        assert!(!next.git_resolved.load(Ordering::Acquire));
        assert!(next.check().is_ok());
    }

    #[test]
    fn git_negation_nested_rules_new_directories_and_unicode_are_native() {
        let workspace = Workspace::new();
        workspace.git(&["init", "--quiet"]);
        fs::write(
            workspace.0.join(".gitignore"),
            "projects/*/repos/\n晚到目录/\n",
        )
        .unwrap();
        fs::create_dir_all(workspace.0.join("projects/中文 空格/repos")).unwrap();
        fs::write(
            workspace.0.join("projects/.gitignore"),
            "!中文 空格/repos/\n",
        )
        .unwrap();
        fs::write(
            workspace.0.join("projects/中文 空格/repos/kept.txt"),
            "kept",
        )
        .unwrap();
        workspace.configure(&[], &[], true);
        assert!(workspace
            .files()
            .contains(&"projects/中文 空格/repos/kept.txt".into()));
        fs::create_dir_all(workspace.0.join("晚到目录")).unwrap();
        fs::write(workspace.0.join("晚到目录/hidden.txt"), "hidden").unwrap();
        assert!(
            !workspace.files().contains(&"晚到目录/hidden.txt".into()),
            "A cached parent must still check a newly created directory"
        );
    }

    #[test]
    fn git_failure_does_not_drop_manual_exclusions() {
        let workspace = Workspace::new();
        workspace.configure(&["ignored"], &[], true);
        assert_eq!(workspace.files(), ["src/Included.java"]);
        let status = configure(serde_json::from_value(json!({"root":workspace.0,
            "manualExcludedDirectories":["ignored"],"includedDirectories":[],"gitIgnoreEnabled":true})).unwrap()).unwrap();
        assert!(status.git_ignore_failed);
        assert_eq!(status.excluded_directories["ignored"], "manual");
    }
    #[test]
    fn scoped_search_keeps_project_policy_and_applies_scope_before_limit() {
        let workspace = Workspace::new();
        workspace.configure(&[], &[], false);
        let search = || {
            files::search(
                serde_json::from_value(json!({
                    "root":workspace.0,"query":"needle","scopePaths":["src"],
                    "maxResults":1,"maxFileResults":0
                }))
                .unwrap(),
            )
            .unwrap()
        };
        assert_eq!(search().matches[0].path, "src/Included.java");
        workspace.configure(&["src"], &[], false);
        assert!(search().matches.is_empty());
    }
    #[test]
    fn repository_archive_fixture_reduces_visits_and_resident_index_files() {
        let workspace = Workspace::new();
        workspace.git(&["init", "--quiet"]);
        fs::write(
            workspace.0.join(".gitignore"),
            "bare-repos/\nprojects/*/repos/\n",
        )
        .unwrap();
        for directory in [
            "bare-repos/archive",
            "projects/alpha/repos/archive",
            "projects/beta/repos/archive",
        ] {
            fs::create_dir_all(workspace.0.join(directory)).unwrap();
            for index in 0..32 {
                fs::write(
                    workspace.0.join(directory).join(format!("file{index}.txt")),
                    "needle",
                )
                .unwrap();
            }
        }
        let measure = |git| {
            workspace.configure(&[], &[], git);
            files::DIRECTORY_VISITS.with_borrow_mut(|trace| *trace = Some(Vec::new()));
            let stats = files::warm_search_index(
                serde_json::from_value(json!({"root":workspace.0})).unwrap(),
            )
            .unwrap();
            let visits = files::DIRECTORY_VISITS.with_borrow(|trace| trace.as_ref().unwrap().len());
            (stats.file_count, visits)
        };
        let before = measure(false);
        let after = measure(true);
        assert_eq!(before.0 - after.0, 96);
        assert!(after.1 < before.1);
        eprintln!(
            "archive fixture: indexed files {} -> {}, directory visits {} -> {}",
            before.0, after.0, before.1, after.1
        );
    }
    #[cfg(unix)]
    #[test]
    fn inaccessible_optional_directory_reports_an_incomplete_inventory() {
        use std::os::unix::fs::PermissionsExt;
        let workspace = Workspace::new();
        workspace.configure(&[], &[], false);
        let directory = workspace.0.join("ignored/deep");
        struct Restore(std::path::PathBuf);
        impl Drop for Restore {
            fn drop(&mut self) {
                let _ = fs::set_permissions(&self.0, fs::Permissions::from_mode(0o755));
            }
        }
        let _restore = Restore(directory.clone());
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o000)).unwrap();
        if fs::read_dir(&directory).is_ok() {
            return;
        } // Privileged hosts cannot exercise permission denial.
        for include_tree in [true, false] {
            let snapshot = files::snapshot(
                serde_json::from_value(json!({"root":workspace.0,"includeTree":include_tree}))
                    .unwrap(),
            )
            .unwrap();
            assert_eq!(snapshot.incomplete_directories, ["ignored/deep"]);
            assert!(snapshot.files.contains(&"src/Included.java".into()));
        }
    }
}
