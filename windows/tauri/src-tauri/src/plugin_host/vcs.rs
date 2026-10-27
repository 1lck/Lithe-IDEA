//! Native VCS root queries and isolated, short-lived read-only status sessions.
//! Accepted package bytes use the existing trust and mutation lease; Core owns
//! detection and ownership. Snapshots live only in memory and never in a bundle.
#[path = "vcs_mappings.rs"]
pub(crate) mod mappings;
#[path = "vcs_registry.rs"]
mod registry;
#[path = "vcs_session.rs"]
mod session;
#[path = "vcs_status.rs"]
pub(crate) mod status;
#[cfg(test)]
#[path = "vcs_tests.rs"]
mod tests;
#[path = "vcs_watch.rs"]
mod watch;

pub use registry::{Ownership, Scope, Snapshot};
use registry::{Package, Registry, VcsCore, READ_TIMEOUT, STALE};
use serde_json::Value;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Instant;
use tauri::{AppHandle, Manager, WebviewWindow};
use tokio::sync::Semaphore;

pub struct VcsHostState {
    registry: Mutex<Registry>,
    reads: Arc<Semaphore>,
    sessions: Arc<session::Sessions>,
    watches: watch::Watches,
}
impl Default for VcsHostState {
    fn default() -> Self {
        Self {
            registry: Mutex::new(Registry::default()),
            reads: Arc::new(Semaphore::new(4)),
            sessions: Arc::new(session::Sessions::default()),
            watches: watch::Watches::default(),
        }
    }
}
struct Core;
impl VcsCore for Core {
    fn execute(&self, command: &str, payload: Value) -> Result<Value, String> {
        super::scan::core_execute(command, payload)
    }
}

fn live(app: &AppHandle, host: &str) -> Result<(), String> {
    if (host == "main" || host.starts_with("workspace-")) && app.get_webview_window(host).is_some()
    {
        Ok(())
    } else {
        Err(STALE.into())
    }
}
fn validate(scope: &Scope) -> Result<(), String> {
    if [&scope.workspace_id, &scope.incarnation]
        .iter()
        .any(|value| value.is_empty() || value.len() > 1024 || value.chars().any(char::is_control))
        || scope.workspace_root.len() > 32768
        || scope.workspace_root.contains('\0')
        || !Path::new(&scope.workspace_root).is_absolute()
    {
        return Err("invalidRequest".into());
    }
    Ok(())
}

/// Called only on the blocking pool. The real native directory handle and
/// project claim bind the frontend incarnation to this exact registration.
fn project_registration(app: &AppHandle, host: &str, scope: &Scope) -> Result<u64, String> {
    let identity = crate::project_window_registry::ProjectWindowRegistry::identity(Path::new(
        &scope.workspace_root,
    ))
    .map_err(|_| STALE)?;
    app.state::<crate::project_windows::ProjectWindows>()
        .0
        .blocking_lock()
        .registration(&identity, host, &scope.workspace_id)
        .ok_or_else(|| STALE.into())
}

/// Retain package leases through both the Core read and final identity check.
/// Sorting makes identity comparison independent of catalog enumeration order.
fn packages(app: &AppHandle) -> Result<(Vec<Package>, Vec<super::lifecycle::NativeLease>), String> {
    let mut candidates: Vec<_> = app
        .state::<super::PluginHostState>()
        .packages()
        .into_iter()
        .filter(|package| {
            package.entry.status == "accepted"
                && package.entry.enabled
                && package.manifest["vcsProviders"]
                    .as_array()
                    .is_some_and(|rows| !rows.is_empty())
                && !app
                    .state::<super::lifecycle::LifecycleState>()
                    .blocked(&package.entry.plugin_id)
        })
        .collect();
    candidates.sort_by(|left, right| left.entry.plugin_id.cmp(&right.entry.plugin_id));
    let mut leases = Vec::new();
    let mut inputs = Vec::new();
    for candidate in candidates {
        leases.push(
            app.state::<super::lifecycle::LifecycleState>()
                .acquire(&candidate.entry.plugin_id)?,
        );
        let package = super::launch::verified_package_by_id(app, &candidate.entry.plugin_id)?;
        inputs.push(Package {
            plugin_id: package.entry.plugin_id,
            identity: format!(
                "{}:{}",
                package.root.canonicalize().map_err(|_| STALE)?.display(),
                super::signature::content_digest(&package.root).map_err(|_| STALE)?
            ),
            manifest: package.manifest,
        });
    }
    Ok((inputs, leases))
}

#[tauri::command]
pub async fn declarative_plugins_vcs_detect(
    app: AppHandle,
    caller: WebviewWindow,
    scope: Scope,
) -> Result<Snapshot, String> {
    live(&app, caller.label())?;
    validate(&scope)?;
    let started = Instant::now();
    let state = app.state::<VcsHostState>();
    let deadline = tokio::time::Instant::from_std(started + READ_TIMEOUT);
    let permit = tokio::time::timeout_at(deadline, state.reads.clone().acquire_owned())
        .await
        .map_err(|_| "requestTimeout")?
        .map_err(|_| "requestCancelled")?;
    let worker_app = app.clone();
    let host = caller.label().to_string();
    // The permit remains in the blocking worker if the caller times out: at
    // most four filesystem reads can survive a late OS read. No late publish.
    let worker = tauri::async_runtime::spawn_blocking(move || {
        let _permit = permit;
        live(&worker_app, &host)?;
        if Instant::now() >= started + READ_TIMEOUT {
            return Err("requestTimeout".into());
        }
        let registration = project_registration(&worker_app, &host, &scope)?;
        let sessions = worker_app.state::<VcsHostState>().sessions.clone();
        for owner in sessions.matching(|context| {
            context.host == host && context.scope.workspace_id == scope.workspace_id
        }) {
            status::cleanup_later(sessions.clone(), owner);
        }
        let owned = worker_app
            .state::<VcsHostState>()
            .registry
            .lock()
            .map_err(|_| "internalError")?
            .begin(&host, scope.clone(), registration, started)?;
        worker_app.state::<VcsHostState>().watches.remove_older(
            &host,
            &scope.workspace_id,
            owned.generation,
        );
        let result = (|| {
            let (inputs, _leases) = packages(&worker_app)?;
            let mappings = if inputs.is_empty() {
                None
            } else {
                Some(mappings::read(&worker_app, &scope)?)
            };
            let entries = mappings
                .as_ref()
                .map(|source| source.entries.as_slice())
                .unwrap_or(&[]);
            let detection = registry::detect_mapped(&Core, &scope, &inputs, entries)?;
            let choices = if entries.is_empty() {
                detection.ambiguous.clone()
            } else {
                registry::detect(&Core, &scope, &inputs)?.ambiguous
            };
            if packages(&worker_app)?.0 != inputs {
                return Err(STALE.into());
            }
            live(&worker_app, &host)?;
            if project_registration(&worker_app, &host, &scope)? != owned.registration {
                return Err(STALE.into());
            }
            let published = worker_app
                .state::<VcsHostState>()
                .registry
                .lock()
                .map_err(|_| "internalError")?
                .publish(&owned, detection.clone(), inputs.clone(), Instant::now())?;
            // With no accepted provider, keep the passive Git path independent
            // of the gated mapping store and do not allocate VCS watches.
            let Some(mappings) = mappings else {
                return Ok(published);
            };
            worker_app
                .state::<VcsHostState>()
                .registry
                .lock()
                .map_err(|_| "internalError")?
                .annotate(&owned, mappings.clone(), None, choices.clone())?;
            let watch_error = watch::install(
                &worker_app,
                &host,
                &scope,
                owned.generation,
                &detection,
                &mappings.source,
            )
            .err();
            if mappings::read(&worker_app, &scope)? != mappings
                || !registry::same_roots(
                    &detection,
                    &registry::detect_mapped(&Core, &scope, &inputs, &mappings.entries)?,
                )
            {
                return Err(STALE.into());
            }
            if Instant::now() >= owned.deadline {
                return Err("requestTimeout".into());
            }
            worker_app
                .state::<VcsHostState>()
                .registry
                .lock()
                .map_err(|_| "internalError")?
                .annotate(&owned, mappings, watch_error, choices)
        })();
        if result.is_err() {
            worker_app
                .state::<VcsHostState>()
                .registry
                .lock()
                .map_err(|_| "internalError")?
                .discard(&owned);
            worker_app
                .state::<VcsHostState>()
                .watches
                .remove_generation(&host, &scope, owned.generation);
        }
        result
    });
    let result = tokio::time::timeout_at(deadline, worker)
        .await
        .map_err(|_| "requestTimeout".to_string())
        .and_then(|value| value.map_err(|_| "internalError".to_string()))
        .and_then(|value| value);
    result
}

#[tauri::command]
pub async fn declarative_plugins_vcs_owners(
    app: AppHandle,
    caller: WebviewWindow,
    scope: Scope,
    generation: u64,
    paths: Vec<String>,
) -> Result<Ownership, String> {
    live(&app, caller.label())?;
    validate(&scope)?;
    if paths.len() > 100_000
        || paths.iter().any(|path| path.len() > 32768)
        || paths
            .iter()
            .try_fold(0usize, |total, path| total.checked_add(path.len()))
            .is_none_or(|bytes| bytes > 32 * 1024 * 1024)
    {
        return Err("invalidRequest".into());
    }
    let (snapshot, expected, registration) = app
        .state::<VcsHostState>()
        .registry
        .lock()
        .map_err(|_| "internalError")?
        .capture(caller.label(), &scope, generation)?;
    let host = caller.label().to_string();
    let deadline = tokio::time::Instant::now() + READ_TIMEOUT;
    let permit = tokio::time::timeout_at(
        deadline,
        app.state::<VcsHostState>().reads.clone().acquire_owned(),
    )
    .await
    .map_err(|_| "requestTimeout")?
    .map_err(|_| "requestCancelled")?;
    tokio::time::timeout_at(
        deadline,
        tauri::async_runtime::spawn_blocking(move || {
            let _permit = permit;
            if project_registration(&app, &host, &scope)? != registration {
                return Err(STALE.into());
            }
            let (current, _leases) = packages(&app)?;
            if current != expected {
                return Err(STALE.into());
            }
            // Static markers may have changed since the list was rendered.
            // Never report an enclosing owner after a new nested/ambiguous
            // root appears; the next explicit refresh replaces the snapshot.
            let fresh = redetect(&app, &scope, &current, &snapshot)?;
            if !registry::same_roots(&snapshot.detection, &fresh) {
                return Err(STALE.into());
            }
            let result = registry::owners(&Core, &snapshot, &paths)?;
            if packages(&app)?.0 != expected {
                return Err(STALE.into());
            }
            live(&app, &host)?;
            if project_registration(&app, &host, &scope)? != registration {
                return Err(STALE.into());
            }
            app.state::<VcsHostState>()
                .registry
                .lock()
                .map_err(|_| "internalError")?
                .capture(&host, &scope, generation)?;
            Ok(result)
        }),
    )
    .await
    .map_err(|_| "requestTimeout".to_string())?
    .map_err(|_| "internalError".to_string())?
}

#[tauri::command]
pub async fn declarative_plugins_vcs_close(
    app: AppHandle,
    caller: WebviewWindow,
    scope: Scope,
) -> Result<(), String> {
    live(&app, caller.label())?;
    validate(&scope)?;
    app.state::<VcsHostState>()
        .registry
        .lock()
        .map_err(|_| "internalError")?
        .retire(caller.label(), &scope)?;
    app.state::<VcsHostState>()
        .watches
        .remove(caller.label(), &scope);
    status::close_matching(&app, |context| {
        context.host == caller.label() && context.scope == scope
    })
    .await
}
pub async fn plugin_changing(app: &AppHandle, plugin_id: &str) -> Result<(), String> {
    if let Some(state) = app.try_state::<VcsHostState>() {
        state.registry.lock().expect("VCS registry").invalidate();
        state.watches.clear();
    }
    status::close_matching(app, |context| context.plugin_id == plugin_id).await
}
pub fn window_destroyed(app: &AppHandle, host: &str) {
    if let Some(state) = app.try_state::<VcsHostState>() {
        state.watches.retire_window(host, || {
            state
                .registry
                .lock()
                .expect("VCS registry")
                .close_window(host);
        });
        let sessions = state.sessions.clone();
        for owner in sessions.matching(|context| context.host == host) {
            status::cleanup_later(sessions.clone(), owner);
        }
    }
}

/// Native VCS transports never expose a generic JSON-RPC tunnel or event
/// queue to a product/web page, even one from the same native window.
pub(crate) fn private_core_request(app: &AppHandle, command: &str, payload: &Value) -> bool {
    command == "lsp.vcsRequest"
        || app
            .state::<VcsHostState>()
            .sessions
            .private_session(command, payload)
}

/// Re-read the exact Lithe mapping source for every ownership/status check.
fn redetect(
    app: &AppHandle,
    scope: &Scope,
    packages: &[Package],
    snapshot: &Snapshot,
) -> Result<registry::Detection, String> {
    if packages.is_empty() && snapshot.mappings.is_none() {
        return registry::detect(&Core, scope, packages);
    }
    let mappings = mappings::read(app, scope)?;
    if snapshot.mappings.as_ref() != Some(&mappings) {
        return Err(STALE.into());
    }
    registry::detect_mapped(&Core, scope, packages, &mappings.entries)
}

fn metadata_changed(app: &AppHandle, host: &str, scope: &Scope, generation: u64) {
    use tauri::Emitter;
    let state = app.state::<VcsHostState>();
    if !state
        .registry
        .lock()
        .expect("VCS registry")
        .invalidate_generation(host, scope, generation)
    {
        return;
    }
    let sessions = state.sessions.clone();
    for owner in sessions.matching(|context| {
        context.host == host && context.scope == *scope && context.generation == generation
    }) {
        status::cleanup_later(sessions.clone(), owner);
    }
    let _ = app.emit_to(host, "vcs-roots-invalidated", serde_json::json!({"workspaceId":scope.workspace_id,"incarnation":scope.incarnation,"generation":generation}));
}
