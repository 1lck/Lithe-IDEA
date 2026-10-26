//! Platform composition: M1 trust, native caller identity and writable state.

use super::super::{launch, lifecycle::NativeLease, store, ScannedPackage};
use super::runtime::{self, HostCore, OpenGuard};
use super::session::{
    same_root, ProviderBinding, ProviderContext, ProviderError, Reply, Status, Transport,
};
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Manager, WebviewWindow};

static NEXT_ID: AtomicU64 = AtomicU64::new(1);
pub(super) fn next_id() -> u64 {
    NEXT_ID.fetch_add(1, Ordering::Relaxed)
}

#[derive(Clone, PartialEq, Eq)]
struct Workspace {
    root: String,
    generation: u64,
}

struct Prepared {
    context: ProviderContext,
    package: ScannedPackage,
    plan: Value,
    state_directory: PathBuf,
    lease: NativeLease,
}

struct LanguageLaunch {
    identity: String,
    resolved: Value,
}

#[derive(Default)]
struct Registry {
    workspaces: HashMap<String, Workspace>,
    suspended: std::collections::HashSet<String>,
    /// Window labels are not reused after native destruction. A late start
    /// can never recreate one by supplying a formerly valid workspace.
    closed: std::collections::HashSet<String>,
    prepared: HashMap<u64, Prepared>,
    language_launches: HashMap<(String, String, String), LanguageLaunch>,
    transports: HashMap<u64, Arc<Transport>>,
    disposed: std::collections::VecDeque<(String, String)>,
}

#[derive(Default)]
pub(super) struct Inner {
    registry: Mutex<Registry>,
    workspace_changes: tokio::sync::Mutex<()>,
}

impl Inner {
    fn publish<T>(
        &self,
        plugin_active: impl FnOnce() -> bool,
        publish: impl FnOnce(&mut Registry) -> Result<T, ProviderError>,
    ) -> Result<T, ProviderError> {
        let mut registry = self.registry.lock().expect("provider registry");
        // Mutation marks the plugin blocked before taking this registry's close
        // snapshot. Checking while holding the same lock means a late owner is
        // either visible to that snapshot or rejected before retaining a lease.
        if !plugin_active() {
            return Err(ProviderError::new(
                "provider.cancelled",
                "Plugin is inactive or changing version",
            ));
        }
        publish(&mut registry)
    }

    pub fn release(&self, transport: &Arc<Transport>) {
        let session = transport
            .status
            .lock()
            .expect("provider session")
            .session_id
            .clone();
        {
            let mut registry = self.registry.lock().expect("provider registry");
            if registry.transports.remove(&transport.id).is_some() && transport.language.is_some() {
                if let Some(session) = session {
                    if registry.disposed.len() >= 256 {
                        registry.disposed.pop_front();
                    }
                    registry
                        .disposed
                        .push_back((transport.context.window.clone(), session));
                }
            }
        }
        transport.lease.lock().expect("provider lease").take();
        transport.status.lock().expect("provider session").disposed = true;
    }

    #[cfg(test)]
    pub fn retain_for_test(&self, transport: Arc<Transport>) {
        self.registry
            .lock()
            .unwrap()
            .transports
            .insert(transport.id, transport);
    }

    #[cfg(test)]
    pub fn contains_for_test(&self, id: u64) -> bool {
        self.registry.lock().unwrap().transports.contains_key(&id)
    }
}

#[derive(Default)]
pub(crate) struct ProviderHostState(Arc<Inner>);

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProviderReview {
    pub token: u64,
    pub context: ProviderContext,
    pub executes_project_code: bool,
    pub may_use_network: bool,
    /// Expanded, passive Core plan. Resolving/probing executables happens
    /// only when confirm consumes this single-use native token.
    pub launch_plan: Value,
}

fn inner(app: &AppHandle) -> Arc<Inner> {
    app.state::<ProviderHostState>().0.clone()
}
fn error(detail: impl Into<String>) -> ProviderError {
    ProviderError::new("provider.unavailable", detail)
}

fn canonical(path: &str) -> Result<String, ProviderError> {
    let path = Path::new(path);
    if !path.is_absolute() || !path.is_dir() {
        return Err(error(
            "Provider root must be an existing absolute directory",
        ));
    }
    path.canonicalize()
        .map(|path| path.to_string_lossy().into_owned())
        .map_err(|e| error(e.to_string()))
}

fn identity(package: &ScannedPackage) -> Result<String, ProviderError> {
    Ok(format!(
        "{}:{}",
        package
            .root
            .canonicalize()
            .map_err(|e| error(e.to_string()))?
            .display(),
        super::super::signature::content_digest(&package.root).map_err(|e| error(e.message()))?
    ))
}

fn current(registry: &Registry, context: &ProviderContext) -> bool {
    !registry.closed.contains(&context.window)
        && !registry.suspended.contains(&context.window)
        && registry
            .workspaces
            .get(&context.window)
            .is_some_and(|workspace| {
                workspace.root == context.workspace_root
                    && workspace.generation == context.generation
            })
}

/// The future native build router calls this with its own workspace generation
/// before prepare. An older generation cannot replace a newer one. Closing the
/// old scope cancels all transports before publication of a new binding.
pub(crate) async fn set_workspace(
    app: &AppHandle,
    window: &WebviewWindow,
    workspace_root: String,
    generation: u64,
) -> Result<(), ProviderError> {
    let root = canonical(&workspace_root)?;
    let next_root = root.clone();
    let state = inner(app);
    let _workspace_change = state.workspace_changes.lock().await;
    {
        let mut registry = state.registry.lock().expect("provider registry");
        if registry.closed.contains(window.label()) {
            return Err(error("Window was destroyed"));
        }
        if let Some(old) = registry.workspaces.get(window.label()) {
            if old.generation > generation || (old.generation == generation && old.root != root) {
                return Err(ProviderError::new(
                    "provider.identityChanged",
                    "Workspace generation is stale",
                ));
            }
            if old.root == root
                && old.generation == generation
                && !registry.suspended.contains(window.label())
            {
                return Ok(());
            }
        }
        registry.suspended.insert(window.label().into());
    }
    // Publish the next scope only after all old processes are proven gone.
    // Failed cleanup leaves the window suspended and can be retried.
    close_matching(state.clone(), |context| context.window == window.label()).await?;
    let mut registry = state.registry.lock().expect("provider registry");
    if registry.closed.contains(window.label()) {
        return Err(error("Window was destroyed"));
    }
    registry.workspaces.insert(
        window.label().into(),
        Workspace {
            root: next_root,
            generation,
        },
    );
    registry.suspended.remove(window.label());
    Ok(())
}

/// Passive preparation. The injected native window owns the review; neither
/// a session ID nor another window's label is accepted from the webview.
pub(crate) fn prepare(
    app: &AppHandle,
    window: &WebviewWindow,
    workspace_root: String,
    generation: u64,
    plugin_id: String,
    build_system: String,
    instance_root: String,
) -> Result<ProviderReview, ProviderError> {
    let workspace_root = canonical(&workspace_root)?;
    let instance_directory =
        super::super::build_resolver::WindowsBuildToolResolver::instance_root_directory(
            &instance_root,
            Path::new(&workspace_root),
        )
        .map_err(|error| ProviderError::new("provider.invalidInstance", error.to_string()))?
        .to_string_lossy()
        .into_owned();
    let lease = app
        .state::<super::super::lifecycle::LifecycleState>()
        .acquire(&plugin_id)
        .map_err(error)?;
    let package = launch::verified_package_by_id(app, &plugin_id).map_err(error)?;
    let context = ProviderContext {
        window: window.label().into(),
        workspace_root,
        generation,
        plugin_id,
        package_identity: identity(&package)?,
        build_system,
        instance_root,
        instance_directory,
    };
    let state_directory = store::plugin_state_directory(app, &context.plugin_id).map_err(error)?;
    let plan = plan(app, &context, &package, &state_directory)?;
    let token = next_id();
    let review = ProviderReview {
        token,
        context: context.clone(),
        executes_project_code: plan["buildProvider"]["executesProjectCode"]
            .as_bool()
            .unwrap_or(true),
        may_use_network: plan["buildProvider"]["mayUseNetwork"]
            .as_bool()
            .unwrap_or(true),
        launch_plan: plan.clone(),
    };
    let state = inner(app);
    state.publish(
        || {
            !app.state::<super::super::lifecycle::LifecycleState>()
                .blocked(&review.context.plugin_id)
        },
        |registry| {
            if !current(registry, &context) {
                return Err(ProviderError::new(
                    "provider.identityChanged",
                    "Workspace changed",
                ));
            }
            // Bound abandoned reviews; cancellation/close also removes them.
            if registry.prepared.len() >= 64 {
                return Err(error("Too many pending provider reviews"));
            }
            registry.prepared.insert(
                token,
                Prepared {
                    context,
                    package,
                    plan,
                    state_directory,
                    lease,
                },
            );
            Ok(())
        },
    )?;
    Ok(review)
}

pub(crate) fn cancel_review(
    app: &AppHandle,
    window: &WebviewWindow,
    token: u64,
) -> Result<(), ProviderError> {
    let state = inner(app);
    let mut registry = state.registry.lock().expect("provider registry");
    if let Some(review) = registry.prepared.get(&token) {
        if review.context.window != window.label() {
            return Err(error("Provider review belongs to another window"));
        }
    }
    registry.prepared.remove(&token);
    Ok(())
}

fn plan(
    app: &AppHandle,
    context: &ProviderContext,
    package: &ScannedPackage,
    state: &Path,
) -> Reply {
    let layers =
        super::super::settings::load_layers(app, &context.plugin_id, &context.workspace_root)
            .map_err(error)?;
    let result = super::super::scan::core_execute(
        "plugins.declarative.languageServerLaunchPlan",
        json!({
            "manifest":package.manifest, "buildSystemID":context.build_system,
            "request":launch::launch_request(state, package, &context.workspace_root, layers),
        }),
    )
    .map_err(error)?;
    if result["plan"].is_null() || result["status"] == "rejected" {
        return Err(error(result.to_string()));
    }
    Ok(result["plan"].clone())
}

fn transport(
    id: u64,
    context: ProviderContext,
    language: Option<String>,
    launch_plan: Option<Value>,
    lease: NativeLease,
) -> Arc<Transport> {
    Arc::new(Transport {
        id,
        context,
        language,
        launch_plan,
        status: Mutex::new(Status::default()),
        changed: Default::default(),
        stopping: Default::default(),
        core: Arc::new(HostCore),
        lease: Mutex::new(Some(lease)),
    })
}

/// Explicit consent entry, called only after the product presents ProviderReview.
/// No public Tauri command is registered until build routing is complete.
pub(crate) async fn confirm(
    app: &AppHandle,
    window: &WebviewWindow,
    token: u64,
) -> Result<ProviderBinding, ProviderError> {
    let state = inner(app);
    let prepared = {
        let mut registry = state.registry.lock().expect("provider registry");
        let review = registry
            .prepared
            .get(&token)
            .ok_or_else(|| error("Unknown provider review"))?;
        if review.context.window != window.label() {
            return Err(error("Provider review belongs to another window"));
        }
        if !current(&registry, &review.context) {
            return Err(error("Workspace changed"));
        }
        registry.prepared.remove(&token).expect("checked review")
    };
    let context = prepared.context.clone();
    let package = launch::verified_package_by_id(app, &context.plugin_id).map_err(error)?;
    if identity(&package)? != context.package_identity
        || plan(app, &context, &package, &prepared.state_directory)? != prepared.plan
    {
        return Err(ProviderError::new(
            "provider.identityChanged",
            "Package or settings changed since review",
        ));
    }
    if let Some(language) = prepared.plan["buildProvider"]["languageServer"].as_str() {
        let selected = {
            let registry = state.registry.lock().expect("provider registry");
            if !current(&registry, &context) {
                return Err(error("Workspace changed"));
            }
            let candidates: Vec<_> = registry
                .transports
                .values()
                .filter(|entry| entry.matches_shared(&context, language))
                .cloned()
                .collect();
            if candidates.len() != 1 {
                return Err(error("No unique native same-plugin language session"));
            }
            candidates[0].clone()
        };
        // The language owner keeps its lease. No probe or second process is
        // started for the shared source, and cancellation preserves the editor.
        runtime::ready(&selected).await?;
        let binding = ProviderBinding {
            transport: selected,
            context,
        };
        validate_binding(app, window.label(), &binding)?;
        return Ok(binding);
    }
    let candidate = transport(
        token,
        context.clone(),
        None,
        Some(prepared.plan.clone()),
        prepared.lease,
    );
    let entry = state.publish(
        || {
            !app.state::<super::super::lifecycle::LifecycleState>()
                .blocked(&context.plugin_id)
        },
        |registry| {
            if !current(registry, &context) {
                return Err(error("Workspace changed"));
            }
            if let Some(existing) = registry.transports.values().find(|entry| {
                entry.language.is_none()
                    && entry.matches_owner(&context)
                    && entry.context.build_system == context.build_system
            }) {
                if existing.launch_plan != candidate.launch_plan {
                    return Err(error(
                        "Provider settings changed; close the native session before restarting",
                    ));
                }
                Ok(existing.clone())
            } else {
                if registry.transports.len() >= 64 {
                    return Err(error("Too many native provider sessions"));
                }
                registry.transports.insert(token, candidate.clone());
                Ok(candidate)
            }
        },
    )?;
    if entry.id != token {
        // One build-system transport serves sibling instance roots. The
        // binding still validates each request's exact Core-planned root.
        runtime::ready(&entry).await?;
        let binding = ProviderBinding {
            transport: entry,
            context,
        };
        validate_binding(app, window.label(), &binding)?;
        return Ok(binding);
    }
    let mut guard = OpenGuard(state.clone(), Some(entry.clone()));
    let worker_entry = entry.clone();
    let worker_app = app.clone();
    let worker_state = state.clone();
    // Cancellation does not discard this worker: it retains the native owner
    // until the late start returns and the process tree has been disposed.
    tauri::async_runtime::spawn_blocking(move || {
        let result = (|| {
            let package =
                launch::verified_package_by_id(&worker_app, &context.plugin_id).map_err(error)?;
            if identity(&package)? != context.package_identity {
                return Err(error("Package changed"));
            }
            if worker_entry
                .status
                .lock()
                .expect("provider session")
                .revoked
            {
                return Err(error("Provider start cancelled"));
            }
            let workspace_state = prepared
                .state_directory
                .join(store::workspace_state_key(&context.workspace_root));
            // Both state directories are host app-data paths, never package
            // resources. Their per-plugin/workspace lifetime follows store.rs;
            // writes cannot affect signatures or update package baselines.
            launch::prepare_required_directories(
                &prepared.plan,
                &prepared.state_directory,
                &workspace_state,
            )
            .map_err(error)?;
            std::fs::create_dir_all(&prepared.state_directory).map_err(|e| error(e.to_string()))?;
            let resolved = launch::resolve_launch(
                &prepared.package,
                &context.build_system,
                &prepared.plan,
                &prepared.state_directory,
            )
            .map_err(error)?;
            if worker_entry
                .status
                .lock()
                .expect("provider session")
                .revoked
            {
                return Err(error("Provider start cancelled"));
            }
            if identity(
                &launch::verified_package_by_id(&worker_app, &context.plugin_id).map_err(error)?,
            )? != context.package_identity
            {
                return Err(error("Package changed during runtime resolution"));
            }
            if plan(&worker_app, &context, &package, &prepared.state_directory)? != prepared.plan {
                return Err(error("Provider settings changed during runtime resolution"));
            }
            let mut environment: std::collections::BTreeMap<String, String> =
                std::env::vars().collect();
            environment.extend(resolved.environment);
            worker_entry.core.start(json!({
                "providerId":format!("buildProvider:{}:{}",context.plugin_id,context.build_system),
                "pluginId":context.plugin_id, "executablePath":resolved.server_path, "arguments":resolved.server_args,
                "environment":environment, "workingDirectory":context.workspace_root,
                "rootUri":url::Url::from_directory_path(&context.workspace_root).map_err(|_| error("Invalid workspace URI"))?.as_str(),
                "initializationOptions":resolved.initialization_options,"workspaceConfiguration":resolved.workspace_configuration,
                "initializeTimeoutMilliseconds":10000,"requestTimeoutMilliseconds":30000,"shutdownTimeoutMilliseconds":2000,
            }), &|id| worker_entry.status.lock().expect("provider session").session_id = Some(id.into()))
        })();
        worker_entry
            .status
            .lock()
            .expect("provider session")
            .launch_finished = true;
        if let Err(error) = result {
            worker_entry.revoke(error);
        }
        worker_entry.changed.notify_waiters();
        runtime::pump(worker_state, worker_entry);
    });
    runtime::ready(&entry).await?;
    let binding = ProviderBinding {
        transport: entry,
        context: prepared.context,
    };
    validate_binding(app, window.label(), &binding)?;
    guard.1.take();
    Ok(binding)
}

pub(super) fn validate_binding(
    app: &AppHandle,
    window: &str,
    binding: &ProviderBinding,
) -> Result<(), ProviderError> {
    let context = &binding.context;
    if context.window != window
        || app.get_webview_window(window).is_none()
        || !current(
            &inner(app).registry.lock().expect("provider registry"),
            context,
        )
        || binding
            .transport
            .status
            .lock()
            .expect("provider session")
            .revoked
    {
        return Err(ProviderError::new(
            "provider.identityChanged",
            "Provider owner is no longer current",
        ));
    }
    let package = launch::verified_package_by_id(app, &context.plugin_id).map_err(error)?;
    let directory =
        super::super::build_resolver::WindowsBuildToolResolver::instance_root_directory(
            &context.instance_root,
            Path::new(&context.workspace_root),
        )
        .map_err(|error| ProviderError::new("provider.invalidInstance", error.to_string()))?;
    if !same_root(&directory.to_string_lossy(), &context.instance_directory) {
        return Err(error("Instance directory identity changed"));
    }
    if identity(&package)? != context.package_identity {
        return Err(error("Provider package changed"));
    }
    Ok(())
}

async fn close_matching(
    state: Arc<Inner>,
    predicate: impl Fn(&ProviderContext) -> bool,
) -> Result<(), ProviderError> {
    let entries = {
        let mut registry = state.registry.lock().expect("provider registry");
        registry
            .prepared
            .retain(|_, review| !predicate(&review.context));
        let entries: Vec<_> = registry
            .transports
            .values()
            .filter(|entry| predicate(&entry.context))
            .cloned()
            .collect();
        for entry in &entries {
            entry.revoke(ProviderError::new(
                "provider.cancelled",
                "Native scope revoked",
            ));
        }
        entries
    };
    // Stop independent owners concurrently so one scope has a bounded drain,
    // rather than multiplying the stop deadline by its number of processes.
    let tasks: Vec<_> = entries
        .into_iter()
        .map(|entry| {
            let state = state.clone();
            tauri::async_runtime::spawn(async move { runtime::stop(state, entry).await })
        })
        .collect();
    let mut failure = None;
    for task in tasks {
        match task.await {
            Ok(Ok(())) => {}
            Ok(Err(error)) => failure = Some(error),
            Err(join) => failure = Some(error(join.to_string())),
        }
    }
    failure.map_or(Ok(()), Err)
}

pub(crate) async fn close_plugin(app: &AppHandle, plugin: &str) -> Result<(), ProviderError> {
    inner(app)
        .registry
        .lock()
        .expect("provider registry")
        .language_launches
        .retain(|_, approval| approval.resolved["pluginId"] != plugin);
    close_matching(inner(app), |context| context.plugin_id == plugin).await
}
pub(crate) async fn close_window(app: &AppHandle, window: &str) -> Result<(), ProviderError> {
    let state = inner(app);
    {
        let mut registry = state.registry.lock().expect("provider registry");
        registry.closed.insert(window.into());
        registry.workspaces.remove(window);
        registry
            .language_launches
            .retain(|(owner, _, _), _| owner != window);
    }
    close_matching(state, |context| context.window == window).await
}
pub(crate) async fn close_workspace(
    app: &AppHandle,
    window: &str,
    root: &str,
) -> Result<(), ProviderError> {
    let state = inner(app);
    // A workspace may have been deleted before close. Prefer the canonical
    // identity, but never prevent cleanup merely because the directory is gone.
    let root = canonical(root).unwrap_or_else(|_| root.to_owned());
    {
        let mut registry = state.registry.lock().expect("provider registry");
        if registry
            .workspaces
            .get(window)
            .is_some_and(|workspace| same_root(&workspace.root, &root))
        {
            registry.workspaces.remove(window);
            registry.suspended.insert(window.into());
        }
        registry
            .language_launches
            .retain(|(owner, workspace, _), _| owner != window || !same_root(workspace, &root));
    }
    close_matching(state, |context| {
        context.window == window && same_root(&context.workspace_root, &root)
    })
    .await
}

/// Called only by the native Core bridge, before a plugin language start.
/// The caller window, package digest, provider/language and canonical root are
/// recorded natively; a later build review can only bind this exact source.
pub(crate) fn language_start(app: &AppHandle, window: &str, payload: &Value) -> Option<Reply> {
    let plugin = payload["pluginId"].as_str()?;
    let candidate = match app
        .state::<super::super::PluginHostState>()
        .packages()
        .into_iter()
        .find(|package| package.entry.plugin_id == plugin)
    {
        Some(package) => package,
        None => {
            return Some(Err(error(
                "Plugin language start has no native package record",
            )))
        }
    };
    // This adapter owns languages of plugins that explicitly share a server
    // with a build provider.
    // Other existing language start paths retain their current composition.
    if !candidate.manifest["buildSystems"]
        .as_array()
        .is_some_and(|systems| {
            systems
                .iter()
                .any(|system| system["provider"]["languageServer"].is_string())
        })
    {
        return None;
    }
    Some((|| {
        let lease = app
            .state::<super::super::lifecycle::LifecycleState>()
            .acquire(plugin)
            .map_err(error)?;
        let package = launch::verified_package_by_id(app, plugin).map_err(error)?;
        let root = canonical(payload["workingDirectory"].as_str().unwrap_or_default())?;
        let uri_root = url::Url::parse(payload["rootUri"].as_str().unwrap_or_default())
            .ok()
            .and_then(|uri| uri.to_file_path().ok())
            .and_then(|path| path.canonicalize().ok());
        if uri_root.as_deref() != Some(Path::new(&root)) {
            return Err(error("Language root URI does not match its workspace"));
        }
        let state = inner(app);
        let entry = state.publish(
            || {
                !app.state::<super::super::lifecycle::LifecycleState>()
                    .blocked(plugin)
            },
            |registry| {
                if registry.closed.contains(window) || app.get_webview_window(window).is_none() {
                    return Err(error("Window closed"));
                }
                if registry.suspended.contains(window) {
                    return Err(error("Workspace is stopping its old native sessions"));
                }
                // The editor uses pluginId as providerId, not languageID. Recover
                // the language only from the native launch ticket, never that field.
                let matching: Vec<_> = registry
                    .language_launches
                    .iter()
                    .filter(|((owner, workspace, _), approval)| {
                        owner == window
                            && workspace == &root
                            && matches_language_launch(&approval.resolved, payload)
                    })
                    .map(|(key, _)| key.clone())
                    .collect();
                if matching.len() != 1 {
                    return Err(error(
                        "Language start needs one unambiguous native launch approval",
                    ));
                }
                let key = matching[0].clone();
                let language = key.2.clone();
                let approved = registry
                    .language_launches
                    .remove(&key)
                    .expect("checked launch approval");
                if !package.manifest["languageServers"]
                    .as_array()
                    .is_some_and(|servers| {
                        servers
                            .iter()
                            .any(|server| server["languageID"] == language)
                    })
                {
                    return Err(error("Language session is not declared by its plugin"));
                }
                if approved.identity != identity(&package)?
                    || !matches_language_launch(&approved.resolved, payload)
                {
                    return Err(error(
                        "Language start differs from its verified native launch",
                    ));
                }
                // Existing language starts predate build routing. A later native
                // build router must adopt this generation via set_workspace.
                let workspace = registry
                    .workspaces
                    .entry(window.into())
                    .or_insert(Workspace {
                        root: root.clone(),
                        generation: 0,
                    });
                if workspace.root != root {
                    return Err(error(
                        "Workspace changed; native owner must advance its generation",
                    ));
                }
                let context = ProviderContext {
                    window: window.into(),
                    workspace_root: root.clone(),
                    generation: workspace.generation,
                    plugin_id: plugin.into(),
                    package_identity: identity(&package)?,
                    build_system: String::new(),
                    instance_root: ".".into(),
                    instance_directory: root,
                };
                if registry.transports.len() >= 64 {
                    return Err(error("Too many native provider sessions"));
                }
                let entry = transport(next_id(), context, Some(language.into()), None, lease);
                registry.transports.insert(entry.id, entry.clone());
                Ok(entry)
            },
        )?;
        let result = entry.core.start(payload.clone(), &|id| {
            entry.status.lock().expect("provider session").session_id = Some(id.into())
        });
        entry
            .status
            .lock()
            .expect("provider session")
            .launch_finished = true;
        if let Err(error) = &result {
            entry.revoke(error.clone());
            runtime::cleanup_later(state, entry.clone());
        }
        result
    })())
}

pub(crate) fn remember_language_launch(
    app: &AppHandle,
    window: &str,
    root: &str,
    package: &ScannedPackage,
    resolved: &launch::ResolvedLaunch,
) -> Result<(), String> {
    if !package.manifest["buildSystems"]
        .as_array()
        .is_some_and(|systems| {
            systems
                .iter()
                .any(|system| system["provider"]["languageServer"].is_string())
        })
    {
        return Ok(());
    }
    let root = canonical(root).map_err(|error| error.detail)?;
    let approved = LanguageLaunch {
        identity: identity(package).map_err(|error| error.detail)?,
        resolved: serde_json::to_value(resolved).map_err(|error| error.to_string())?,
    };
    let state = inner(app);
    state
        .publish(
            || {
                !app.state::<super::super::lifecycle::LifecycleState>()
                    .blocked(&package.entry.plugin_id)
            },
            |registry| {
                if registry.closed.contains(window) {
                    return Err(error("Language owner window closed"));
                }
                if registry.suspended.contains(window) {
                    return Err(error("Language owner workspace is closed or stopping"));
                }
                if registry.language_launches.len() >= 64 {
                    return Err(error("Too many pending language launch approvals"));
                }
                registry.language_launches.insert(
                    (window.into(), root, resolved.language_id.clone()),
                    approved,
                );
                Ok(())
            },
        )
        .map_err(|error| error.detail)
}

pub(super) fn matches_language_launch(approved: &Value, payload: &Value) -> bool {
    approved["pluginId"] == payload["pluginId"]
        && approved["pluginId"] == payload["providerId"]
        && approved["serverPath"] == payload["executablePath"]
        && approved["serverArgs"] == payload["arguments"]
        && approved["initializationOptions"] == payload["initializationOptions"]
        && approved["workspaceConfiguration"] == payload["workspaceConfiguration"]
        && approved["environment"] == payload["environment"]
        && [
            "runtimeExecutablePath",
            "jdtlsLaunchResources",
            "cacheDirectory",
            "workspaceFingerprint",
            "mavenContext",
            "javaGradle",
        ]
        .iter()
        .all(|key| payload[*key].is_null())
        && ["hostServices", "javaRuntimes"].iter().all(|key| {
            payload[*key].is_null() || payload[*key].as_array().is_some_and(Vec::is_empty)
        })
}

/// Shared language cleanup can finish before the editor acknowledges a plugin
/// mutation. Recognize its later stop/destroy without releasing an unverified
/// owner, and reject foreign-window or direct webview build requests.
pub(crate) fn core_preflight(
    app: &AppHandle,
    window: &str,
    command: &str,
    payload: &Value,
) -> Option<Reply> {
    preflight(&inner(app), window, command, payload)
}

pub(super) fn preflight(
    state: &Inner,
    window: &str,
    command: &str,
    payload: &Value,
) -> Option<Reply> {
    if !command.starts_with("lsp.") {
        return None;
    }
    let session = payload["sessionId"].as_str()?;
    let registry = state.registry.lock().expect("provider registry");
    if let Some((owner, _)) = registry.disposed.iter().find(|(_, id)| id == session) {
        if owner != window {
            return Some(Err(error("Session belongs to another native window")));
        }
        if matches!(command, "lsp.stopServer" | "lsp.destroyServer") {
            return Some(Ok(json!({})));
        }
    }
    for transport in registry.transports.values() {
        if transport
            .status
            .lock()
            .expect("provider session")
            .session_id
            .as_deref()
            == Some(session)
            && (transport.context.window != window
                || transport.language.is_none()
                || command == "lsp.buildRequest")
        {
            return Some(Err(error(
                "Provider request requires its native approved binding",
            )));
        }
    }
    None
}

/// Mirrors an existing event consumer's response. It never drains a shared
/// language queue. On successful destroy, Core has already verified disposal.
pub(crate) fn observe_core(
    app: &AppHandle,
    window: &str,
    command: &str,
    payload: &Value,
    response: &Value,
) {
    let state = inner(app);
    let entries: Vec<_> = state
        .registry
        .lock()
        .expect("provider registry")
        .transports
        .values()
        .filter(|entry| {
            entry.context.window == window
                && entry.language.is_some()
                && entry
                    .status
                    .lock()
                    .expect("provider session")
                    .session_id
                    .as_deref()
                    == payload["sessionId"].as_str()
        })
        .cloned()
        .collect();
    for entry in entries {
        if response["ok"] != true {
            continue;
        }
        if matches!(command, "lsp.pollEvents" | "lsp.waitEvents") {
            for event in response["data"]["events"].as_array().into_iter().flatten() {
                entry.observe(event);
            }
        }
        if command == "lsp.destroyServer" {
            entry.revoke(ProviderError::new(
                "provider.sessionEnded",
                "Language owner destroyed the session",
            ));
            state.release(&entry);
        } else if entry.status.lock().expect("provider session").revoked {
            runtime::cleanup_later(state.clone(), entry.clone());
        }
    }
}

#[cfg(test)]
#[path = "host_tests.rs"]
mod tests;
