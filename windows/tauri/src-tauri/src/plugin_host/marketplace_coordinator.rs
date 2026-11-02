//! Window-owned marketplace operations. Core owns availability and install review;
//! M1 owns snapshots, signatures, staging and the installation transaction. This
//! adapter supplies only trusted source identity, cancellation and lifetime guards.

use super::install::{self, MarketplaceInstallSource, PreparedInstall};
use super::marketplace_download::{
    download_artifact, CancelToken, FetchLimits, FetchPolicy, HttpTransport, MAX_ARTIFACT_BYTES,
    MAX_REDIRECT_HOPS,
};
use super::marketplace_index::{
    availability_of, Availability, IndexRefreshRequest, MarketplaceIndexStore, SourceKind,
};
use super::marketplace_sources::{MarketplaceSource, OFFICIAL_INDEX_URL, OFFICIAL_SOURCE_ID};
use serde::Serialize;
use serde_json::Value;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const FETCH_DEADLINE: Duration = Duration::from_secs(60);
const MAX_WINDOW_OPERATIONS: usize = 32;
const MAX_WINDOW_CANCELLATIONS: usize = 256;

/// Platform-owned live state. No URL, path, capability or official flag is
/// accepted from IPC. The source transaction excludes simultaneous removal or
/// disable while committing an installation.
pub(crate) trait MarketplaceHost: Send + Sync {
    fn sources(&self) -> Result<Vec<MarketplaceSource>, String>;
    fn platform(&self) -> String;
    fn capabilities(&self) -> Value;
    fn ensure_window(&self, window: &str) -> Result<(), String>;
    fn ensure_installable(&self, plugin_id: &str) -> Result<(), String>;
    fn with_source(
        &self,
        source: &MarketplaceSource,
        publish: &mut dyn FnMut() -> Result<(), String>,
    ) -> Result<(), String>;
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceIndex {
    pub source_id: String,
    pub source_name: String,
    pub index: Option<Value>,
    pub problem: Option<String>,
    pub installations: std::collections::BTreeMap<String, InstallationState>,
}

/// Native installed-source ownership paired with Core availability. It describes
/// eligibility to prepare, never package trust or permission to skip confirmation.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallationState {
    pub origin: &'static str,
    pub version: Option<String>,
    pub enabled: Option<bool>,
    pub source_id: Option<String>,
    pub can_prepare: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MarketplaceReview {
    pub operation_id: String,
    pub source_id: String,
    pub source_name: String,
    pub index_url: String,
    /// True only for the host-pinned official source and a verified signed package.
    pub official_publisher_verified: bool,
    pub requires_confirmation: bool,
    pub prepared: PreparedInstall,
}

struct Session {
    root: PathBuf,
    id: String,
}
impl Session {
    fn snapshot(&self) -> Result<PathBuf, String> {
        install::validated_session_path(&self.root, &self.id)
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        if let Ok(snapshot) = self.snapshot() {
            install::discard_install_session(&self.root, &self.id, &snapshot);
        }
    }
}

struct ReadyInstall {
    session: Session,
    source: MarketplaceInstallSource,
    prepared: PreparedInstall,
    requires_confirmation: bool,
    index_epoch: u64,
}

#[derive(Default)]
struct IndexEpoch {
    value: u64,
    refreshing: usize,
}

struct RefreshOwner<'a> {
    coordinator: &'a MarketplaceCoordinator,
    source: String,
}
impl Drop for RefreshOwner<'_> {
    fn drop(&mut self) {
        if let Some(epoch) = self
            .coordinator
            .index_epochs
            .lock()
            .expect("marketplace epochs")
            .get_mut(&self.source)
        {
            epoch.refreshing -= 1;
        }
    }
}

struct Operation {
    window: String,
    source: MarketplaceSource,
    plugin: Option<String>,
    cancel: CancelToken,
    ready: Mutex<Option<ReadyInstall>>,
    confirming: AtomicBool,
}

#[derive(Default)]
struct OperationRegistry {
    active: HashMap<(String, String), Arc<Operation>>,
    /// Covers cancel IPC arriving before the corresponding async command is
    /// first polled. IDs are unique per request; retain recent cancellations for
    /// one full operation deadline with a bounded per-window history.
    cancelled: HashMap<(String, String), Instant>,
    closed_windows: std::collections::HashSet<String>,
}

/// Covers dropped IPC futures as well as ordinary errors. A successful prepare
/// transfers ownership to the review registry; all other exits cancel workers.
struct RunningOperation<'a> {
    coordinator: &'a MarketplaceCoordinator,
    id: &'a str,
    operation: Arc<Operation>,
    keep_review: bool,
}

/// A single confirmation owns the review across the async lifecycle barrier and
/// the blocking publication worker. Dropping either phase cancels only this exact
/// operation, including when its public ID has since been reused by a new request.
pub(crate) struct Confirmation {
    coordinator: Arc<MarketplaceCoordinator>,
    operation: Arc<Operation>,
    id: String,
    plugin_id: String,
}

impl Confirmation {
    pub fn plugin_id(&self) -> &str {
        &self.plugin_id
    }

    /// Reject an unapproved, stale or wrong-digest review before the lifecycle
    /// barrier stops a currently running installation. Publication repeats all
    /// authoritative checks against live snapshot and installed-record bytes.
    pub fn check_review(&self, digest: &str, approved: bool) -> Result<(), String> {
        self.coordinator.check(&self.operation)?;
        let slot = self
            .operation
            .ready
            .lock()
            .map_err(|_| "marketplace review poisoned")?;
        let ready = slot
            .as_ref()
            .ok_or("the marketplace review is no longer ready")?;
        if ready.prepared.manifest_digest != digest {
            return Err("the review digest does not match".into());
        }
        if ready.requires_confirmation && !approved {
            return Err(
                "explicit approval is required for the permissions and new programs".into(),
            );
        }
        let epochs = self
            .coordinator
            .index_epochs
            .lock()
            .map_err(|_| "marketplace epochs poisoned")?;
        let epoch = epochs
            .get(&ready.source.source_id)
            .ok_or("the selected index expired")?;
        if epoch.value != ready.index_epoch || epoch.refreshing != 0 {
            return Err("the source index changed; prepare a new marketplace review".into());
        }
        Ok(())
    }

    pub fn publish(
        self,
        digest: &str,
        approved: bool,
    ) -> Result<install::ConfirmedDiskInstall, String> {
        self.coordinator
            .confirm_claimed(&self.operation, digest, approved)
    }
}

impl Drop for Confirmation {
    fn drop(&mut self) {
        self.operation.cancel.cancel();
        self.operation
            .ready
            .lock()
            .expect("marketplace review")
            .take();
        self.coordinator.finish(&self.id, &self.operation);
    }
}
impl Drop for RunningOperation<'_> {
    fn drop(&mut self) {
        if !self.keep_review {
            self.operation.cancel.cancel();
            self.coordinator.finish(self.id, &self.operation);
        }
    }
}

/// Runtime caches stay under the host's app-local marketplace root; snapshots and
/// downloads reuse M1's plugin-temp root. Neither is a worktree/build resource or
/// installed application resource, and neither affects signatures or delta bases.
pub(crate) struct MarketplaceCoordinator {
    host: Arc<dyn MarketplaceHost>,
    transport: Arc<dyn HttpTransport>,
    policy: FetchPolicy,
    indexes: MarketplaceIndexStore,
    temporary_root: PathBuf,
    install_root: PathBuf,
    operations: Mutex<OperationRegistry>,
    index_epochs: Mutex<HashMap<String, IndexEpoch>>,
}

impl MarketplaceCoordinator {
    pub fn new(
        host: Arc<dyn MarketplaceHost>,
        transport: Arc<dyn HttpTransport>,
        policy: FetchPolicy,
        cache_root: PathBuf,
        temporary_root: PathBuf,
        install_root: PathBuf,
    ) -> Self {
        Self {
            host,
            transport,
            policy,
            indexes: MarketplaceIndexStore::new(cache_root),
            temporary_root,
            install_root,
            operations: Mutex::new(OperationRegistry::default()),
            index_epochs: Mutex::new(HashMap::new()),
        }
    }

    fn request(&self, source: &MarketplaceSource) -> IndexRefreshRequest {
        IndexRefreshRequest {
            source_id: source.id.clone(),
            index_url: source.index_url.clone(),
            source_kind: if official_source(source) {
                SourceKind::Official
            } else {
                SourceKind::ThirdParty
            },
            platform: self.host.platform(),
            host_capabilities: self.host.capabilities(),
            deadline: FETCH_DEADLINE,
        }
    }

    fn current_source(&self, source_id: &str) -> Result<MarketplaceSource, String> {
        self.host
            .sources()?
            .into_iter()
            .find(|source| source.id == source_id && source.is_enabled)
            .ok_or_else(|| "the marketplace source was removed or disabled".into())
    }

    fn check(&self, operation: &Operation) -> Result<(), String> {
        if operation.cancel.is_cancelled() {
            return Err("marketplace operation cancelled".into());
        }
        self.host.ensure_window(&operation.window)?;
        if self.current_source(&operation.source.id)? != operation.source {
            return Err("the marketplace source changed during this operation".into());
        }
        Ok(())
    }

    fn begin(
        &self,
        window: &str,
        id: &str,
        source_id: &str,
        plugin: Option<String>,
    ) -> Result<Arc<Operation>, String> {
        if id.is_empty()
            || id.len() > 128
            || !id
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
        {
            return Err("invalid marketplace operation id".into());
        }
        let source = self.current_source(source_id)?;
        let mut operations = self
            .operations
            .lock()
            .map_err(|_| "marketplace operations poisoned")?;
        let key = (window.to_string(), id.to_string());
        if operations.closed_windows.contains(window) {
            return Err("the marketplace window was closed".into());
        }
        operations
            .cancelled
            .retain(|_, cancelled| cancelled.elapsed() < FETCH_DEADLINE);
        if operations.cancelled.contains_key(&key) {
            return Err("this marketplace operation was cancelled before it started".into());
        }
        if operations.active.contains_key(&key)
            || operations
                .active
                .keys()
                .filter(|(owner, _)| owner == window)
                .count()
                >= MAX_WINDOW_OPERATIONS
        {
            return Err("marketplace operation already exists or this window has too many pending operations".into());
        }
        let operation = Arc::new(Operation {
            window: window.into(),
            source,
            plugin,
            cancel: CancelToken::new(),
            ready: Mutex::new(None),
            confirming: AtomicBool::new(false),
        });
        operations.active.insert(key, operation.clone());
        drop(operations);
        // Register before checking live ownership. A destroy notification that
        // precedes registration is caught here; one arriving afterwards cancels
        // the registered token. Lazy coordinator creation cannot miss teardown.
        if let Err(error) = self.check(&operation) {
            operation.cancel.cancel();
            self.finish(id, &operation);
            return Err(error);
        }
        Ok(operation)
    }

    fn finish(&self, id: &str, operation: &Arc<Operation>) {
        let mut operations = self.operations.lock().expect("marketplace operations");
        let key = (operation.window.clone(), id.into());
        if operations
            .active
            .get(&key)
            .is_some_and(|current| Arc::ptr_eq(current, operation))
        {
            operations.active.remove(&key);
        }
    }

    pub fn cancel(&self, window: &str, id: &str) {
        if id.is_empty()
            || id.len() > 128
            || !id
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
        {
            return;
        }
        let operation = {
            let mut operations = self.operations.lock().expect("marketplace operations");
            let key = (window.to_string(), id.to_string());
            operations
                .cancelled
                .retain(|_, cancelled| cancelled.elapsed() < FETCH_DEADLINE);
            if operations
                .cancelled
                .keys()
                .filter(|(owner, _)| owner == window)
                .count()
                >= MAX_WINDOW_CANCELLATIONS
            {
                if let Some(oldest) = operations
                    .cancelled
                    .iter()
                    .filter(|((owner, _), _)| owner == window)
                    .min_by_key(|(_, time)| **time)
                    .map(|(key, _)| key.clone())
                {
                    operations.cancelled.remove(&oldest);
                }
            }
            operations.cancelled.insert(key.clone(), Instant::now());
            operations.active.remove(&key)
        };
        if let Some(operation) = operation {
            operation.cancel.cancel();
            operation.ready.lock().expect("marketplace review").take();
        }
    }
    pub fn cancel_window(&self, window: &str) {
        self.cancel_matching(|key, _| key.0 == window, Some(window));
    }
    pub fn cancel_source(&self, source: &str) {
        self.cancel_matching(|_, operation| operation.source.id == source, None);
    }
    pub fn cancel_plugin(&self, plugin: &str) {
        self.cancel_matching(
            |_, operation| operation.plugin.as_deref() == Some(plugin),
            None,
        );
    }

    fn cancel_matching(
        &self,
        matches: impl Fn(&(String, String), &Operation) -> bool,
        closed_window: Option<&str>,
    ) {
        let removed: Vec<_> = {
            let mut operations = self.operations.lock().expect("marketplace operations");
            if let Some(window) = closed_window {
                operations.closed_windows.insert(window.into());
                operations.cancelled.retain(|(owner, _), _| owner != window);
            }
            let keys: Vec<_> = operations
                .active
                .iter()
                .filter(|(key, operation)| matches(key, operation))
                .map(|(key, _)| key.clone())
                .collect();
            keys.into_iter()
                .filter_map(|key| operations.active.remove(&key))
                .collect()
        };
        // Never hold the registry lock while waiting for a publication boundary.
        for operation in removed {
            operation.cancel.cancel();
            operation.ready.lock().expect("marketplace review").take();
        }
    }

    pub fn list(&self) -> Result<Vec<SourceIndex>, String> {
        self.host
            .sources()?
            .into_iter()
            .filter(|source| source.is_enabled)
            .map(|source| {
                let result = self.indexes.cached_index(&self.request(&source));
                let (index, problem) = match result {
                    Ok(index) => (index, None),
                    Err(error) => (None, Some(error)),
                };
                let installations = match index.as_ref() {
                    Some(index) => index["plugins"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .filter_map(|plugin| {
                            plugin["id"].as_str().map(|id| {
                                (
                                    id.to_string(),
                                    self.installation_state(
                                        &source,
                                        id,
                                        plugin["availability"]["status"] == "available",
                                    ),
                                )
                            })
                        })
                        .collect(),
                    None => std::collections::BTreeMap::new(),
                };
                Ok(SourceIndex {
                    source_id: source.id,
                    source_name: source.name,
                    index,
                    problem,
                    installations,
                })
            })
            .collect()
    }

    fn installation_state(
        &self,
        source: &MarketplaceSource,
        plugin_id: &str,
        available: bool,
    ) -> InstallationState {
        let mut state = InstallationState {
            origin: "none",
            version: None,
            enabled: None,
            source_id: None,
            can_prepare: available,
        };
        if self.host.ensure_installable(plugin_id).is_err() {
            state.origin = "bundled";
            state.can_prepare = false;
            return state;
        }
        let directory = self.install_root.join(plugin_id);
        let bytes = match std::fs::read(directory.join("installation.json")) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound && !directory.exists() => {
                return state
            }
            Err(_) => {
                state.origin = "unknown";
                state.can_prepare = false;
                return state;
            }
        };
        let record = match serde_json::from_slice::<super::store::InstallationRecord>(&bytes) {
            Ok(record)
                if record.schema_version == 2
                    && record.plugin_id == plugin_id
                    && record.active_content_digest().is_some()
                    && matches!(
                        record.origin,
                        Some(
                            super::signature::InstallOrigin::Community
                                | super::signature::InstallOrigin::Marketplace
                        )
                    ) =>
            {
                record
            }
            _ => {
                state.origin = "unknown";
                state.can_prepare = false;
                return state;
            }
        };
        state.version = Some(record.version);
        state.enabled = Some(record.enabled);
        if let Some(marketplace) = record.marketplace {
            state.origin = "marketplace";
            state.can_prepare &=
                marketplace.source_id == source.id && marketplace.index_url == source.index_url;
            state.source_id = Some(marketplace.source_id);
        } else {
            state.origin = "disk";
            state.can_prepare = false;
        }
        state
    }

    pub async fn refresh(&self, window: &str, id: &str, source_id: &str) -> Result<Value, String> {
        let operation = self.begin(window, id, source_id, None)?;
        {
            let mut epochs = self
                .index_epochs
                .lock()
                .map_err(|_| "marketplace epochs poisoned")?;
            let epoch = epochs.entry(source_id.into()).or_default();
            epoch.value += 1;
            epoch.refreshing += 1;
        }
        let _refresh_owner = RefreshOwner {
            coordinator: self,
            source: source_id.into(),
        };
        let _running = RunningOperation {
            coordinator: self,
            id,
            operation: operation.clone(),
            keep_review: false,
        };
        let result = async {
            let result = self
                .indexes
                .refresh(
                    self.transport.as_ref(),
                    &self.request(&operation.source),
                    self.policy,
                    &operation.cancel,
                )
                .await
                .map_err(|error| error.message())?;
            self.check(&operation)?;
            // A superseded refresh may answer its caller, but expose the newest
            // cached view so a late IPC result cannot regress a market list.
            if !result.persisted {
                return self
                    .indexes
                    .cached_index(&self.request(&operation.source))?
                    .ok_or("the index refresh was superseded".into());
            }
            Ok(result.index)
        }
        .await;
        self.finish(id, &operation);
        result
    }

    pub async fn prepare(
        self: &Arc<Self>,
        window: &str,
        id: &str,
        source_id: &str,
        plugin_id: &str,
    ) -> Result<MarketplaceReview, String> {
        let operation = self.begin(window, id, source_id, Some(plugin_id.into()))?;
        let mut running = RunningOperation {
            coordinator: self,
            id,
            operation: operation.clone(),
            keep_review: false,
        };
        let result = self
            .prepare_operation(id, operation.clone(), plugin_id)
            .await;
        running.keep_review = result.is_ok();
        result
    }

    async fn prepare_operation(
        self: &Arc<Self>,
        id: &str,
        operation: Arc<Operation>,
        plugin_id: &str,
    ) -> Result<MarketplaceReview, String> {
        self.host.ensure_installable(plugin_id)?;
        let (index_epoch, index) = {
            let mut epochs = self
                .index_epochs
                .lock()
                .map_err(|_| "marketplace epochs poisoned")?;
            let epoch = epochs.entry(operation.source.id.clone()).or_default();
            if epoch.refreshing != 0 {
                return Err(
                    "wait for this source refresh to finish before preparing an installation"
                        .into(),
                );
            }
            let index = self
                .indexes
                .cached_index(&self.request(&operation.source))?
                .ok_or("refresh this source before preparing an installation")?;
            (epoch.value, index)
        };
        let (version, archive_url, archive_sha256) = match availability_of(&index, plugin_id) {
            Availability::Available {
                version,
                download_url,
                sha256,
            } => (version, download_url, sha256),
            Availability::Unsupported { code, message } => {
                return Err(format!("{code}: {message}"))
            }
            Availability::NotFound => return Err("the plugin is not offered by this source".into()),
        };
        let source = MarketplaceInstallSource {
            source_id: operation.source.id.clone(),
            source_name: operation.source.name.clone(),
            index_url: operation.source.index_url.clone(),
            repository: operation.source.repository.clone().unwrap_or_default(),
            archive_url: archive_url.clone(),
            archive_sha256: archive_sha256.clone(),
            plugin_id: plugin_id.into(),
            version,
            official: official_source(&operation.source),
        };
        install::marketplace_previous_record(&self.install_root, &source)?;
        let artifact = download_artifact(
            &self.temporary_root,
            self.transport.as_ref(),
            &archive_url,
            &archive_sha256,
            FetchLimits {
                max_bytes: MAX_ARTIFACT_BYTES,
                max_redirects: MAX_REDIRECT_HOPS,
            },
            self.policy,
            &operation.cancel,
            Instant::now() + FETCH_DEADLINE,
        )
        .await
        .map_err(|error| error.message())?;
        // Ownership moves into the blocking worker before any await. The worker
        // always drops both archive and snapshot on failure or cancellation.
        struct Archive(PathBuf);
        impl Drop for Archive {
            fn drop(&mut self) {
                let _ = std::fs::remove_file(&self.0);
            }
        }
        let archive = Archive(artifact.path);
        let session = Session {
            root: self.temporary_root.clone(),
            id: format!("lithe-plugin-disk-{}", install::uuid_like_suffix()),
        };
        let coordinator = self.clone();
        let worker_operation = operation.clone();
        let ready = tauri::async_runtime::spawn_blocking(move || {
            coordinator.check(&worker_operation)?;
            let prepared = install::prepare_marketplace_install_snapshot(
                &coordinator.install_root,
                &session.root,
                &session.id,
                &archive.0,
                &source,
            )?;
            coordinator.check(&worker_operation)?;
            let requires_confirmation = prepared.approval_required;
            Ok::<_, String>(ReadyInstall {
                session,
                source,
                prepared,
                requires_confirmation,
                index_epoch,
            })
        })
        .await
        .map_err(|error| error.to_string())??;
        let response = MarketplaceReview {
            operation_id: id.into(),
            source_id: ready.source.source_id.clone(),
            source_name: ready.source.source_name.clone(),
            index_url: ready.source.index_url.clone(),
            official_publisher_verified: ready.source.official,
            requires_confirmation: ready.requires_confirmation,
            prepared: ready.prepared.clone(),
        };
        let mut slot = operation
            .ready
            .lock()
            .map_err(|_| "marketplace review poisoned")?;
        self.check(&operation)?;
        *slot = Some(ready);
        Ok(response)
    }

    #[cfg(test)]
    pub fn pending_plugin(&self, window: &str, id: &str) -> Result<String, String> {
        self.operations
            .lock()
            .map_err(|_| "marketplace operations poisoned")?
            .active
            .get(&(window.into(), id.into()))
            .and_then(|operation| operation.plugin.clone())
            .ok_or_else(|| "this window owns no such marketplace review".into())
    }

    pub fn claim_confirmation(
        self: &Arc<Self>,
        window: &str,
        id: &str,
    ) -> Result<Confirmation, String> {
        let operation = self
            .operations
            .lock()
            .map_err(|_| "marketplace operations poisoned")?
            .active
            .get(&(window.into(), id.into()))
            .cloned()
            .ok_or("this window owns no such marketplace review")?;
        let ready = operation
            .ready
            .lock()
            .map_err(|_| "marketplace review poisoned")?;
        if ready.is_none() {
            return Err("the marketplace review is not ready".into());
        }
        if operation.confirming.swap(true, Ordering::SeqCst) {
            return Err("this marketplace review is already being confirmed".into());
        }
        drop(ready);
        let plugin_id = operation
            .plugin
            .clone()
            .ok_or("not an installation review")?;
        Ok(Confirmation {
            coordinator: self.clone(),
            operation,
            id: id.into(),
            plugin_id,
        })
    }

    /// Test entry to the same transaction. Production first claims the review,
    /// then holds M1's native lifecycle barrier before calling publish.
    #[cfg(test)]
    pub fn confirm(
        self: &Arc<Self>,
        window: &str,
        id: &str,
        digest: &str,
        approved: bool,
    ) -> Result<install::ConfirmedDiskInstall, String> {
        let confirmation = self.claim_confirmation(window, id)?;
        confirmation.check_review(digest, approved)?;
        confirmation.publish(digest, approved)
    }

    fn confirm_claimed(
        &self,
        operation: &Operation,
        digest: &str,
        approved: bool,
    ) -> Result<install::ConfirmedDiskInstall, String> {
        let ready = operation
            .ready
            .lock()
            .map_err(|_| "marketplace review poisoned")?
            .take()
            .ok_or("the marketplace review is not ready or is already being confirmed")?;
        self.check(operation)?;
        if ready.requires_confirmation && !approved {
            return Err(
                "explicit approval is required for the permissions and new programs".into(),
            );
        }
        self.host.ensure_installable(&ready.source.plugin_id)?;
        let candidate = install::confirm_marketplace_install_snapshot(
            &self.install_root,
            &ready.session.root,
            &ready.session.id,
            digest,
            &ready.source,
        )?;
        install::publish_installed_version_guarded(
            &self.install_root,
            &candidate.plugin_id,
            &candidate.version,
            &ready.session.snapshot()?,
            candidate.record.clone(),
            &|activate| {
                // Staging already passed M1's byte and trust checks. Only
                // activation/record replacement holds these commit gates.
                let epochs = self
                    .index_epochs
                    .lock()
                    .map_err(|_| "marketplace epochs poisoned")?;
                let epoch = epochs
                    .get(&ready.source.source_id)
                    .ok_or("the selected index expired")?;
                if epoch.value != ready.index_epoch || epoch.refreshing != 0 {
                    return Err("the source index changed; prepare a new marketplace review".into());
                }
                self.host.with_source(&operation.source, &mut || {
                    operation
                        .cancel
                        .commit(Instant::now() + FETCH_DEADLINE, &mut *activate)
                        .map_err(|error| error.message())?
                })
            },
        )?;
        Ok(candidate)
    }
}

pub(crate) fn official_source(source: &MarketplaceSource) -> bool {
    source.id == OFFICIAL_SOURCE_ID && source.index_url == OFFICIAL_INDEX_URL
}
