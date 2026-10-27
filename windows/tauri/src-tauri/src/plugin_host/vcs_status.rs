//! Native composition for a detected plugin root's read-only status. The
//! package's existing install approval covers its declared VCS program/tool;
//! no build consent token or plugin-function identity is accepted here.
use super::{
    live, packages, project_registration, registry, session, validate, Scope, VcsHostState,
};
use crate::plugin_host::{launch, lifecycle, store, ScannedPackage};
use serde::Serialize;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;
use tauri::{AppHandle, Manager, WebviewWindow};

struct Prepared {
    context: session::Context,
    expected: Vec<registry::Package>,
    package: ScannedPackage,
    lease: lifecycle::NativeLease,
    plan: Value,
    state_directory: PathBuf,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusSnapshot {
    request_id: String,
    generation: u64,
    root_id: String,
    vcs: String,
    result: Value,
}
fn request_id(id: &str) -> Result<(), String> {
    if id.is_empty() || id.len() > 128 || id.chars().any(|c| !c.is_ascii_alphanumeric() && c != '-')
    {
        return Err("invalidRequest".into());
    }
    Ok(())
}
fn plan(
    app: &AppHandle,
    package: &ScannedPackage,
    scope: &Scope,
    vcs: &str,
    state: &std::path::Path,
) -> session::Reply {
    let layers = crate::plugin_host::settings::load_layers(
        app,
        &package.entry.plugin_id,
        &scope.workspace_root,
    )?;
    let response = crate::plugin_host::scan::core_execute(
        "plugins.declarative.languageServerLaunchPlan",
        json!({
            "manifest":package.manifest,"vcsProviderID":vcs,
            "request":launch::launch_request(state,package,&scope.workspace_root,layers),
        }),
    )?;
    if response["status"] != "ok" || response["plan"]["vcsProvider"]["vcs"] != vcs {
        return Err("vcs.provider.unavailable".into());
    }
    Ok(response["plan"].clone())
}
fn prepare(
    app: &AppHandle,
    host: &str,
    scope: Scope,
    generation: u64,
    root_id: String,
    id: String,
) -> Result<Prepared, String> {
    live(app, host)?;
    let (snapshot, expected, registration) = app
        .state::<VcsHostState>()
        .registry
        .lock()
        .expect("VCS registry")
        .capture(host, &scope, generation)?;
    if project_registration(app, host, &scope)? != registration {
        return Err(registry::STALE.into());
    }
    let (current, _leases) = packages(app)?;
    if current != expected {
        return Err(registry::STALE.into());
    }
    let fresh = super::redetect(app, &scope, &current, &snapshot)?;
    if !registry::same_roots(&snapshot.detection, &fresh) {
        return Err(registry::STALE.into());
    }
    if snapshot.detection.truncated {
        return Err("vcs.provider.incompleteRoots".into());
    }
    let root = snapshot
        .detection
        .roots
        .iter()
        .find(|root| root.id == root_id)
        .cloned()
        .ok_or(registry::STALE)?;
    let provider = snapshot
        .detection
        .providers
        .iter()
        .find(|provider| provider["vcs"] == root.vcs && provider["origin"]["kind"] == "plugin")
        .ok_or("vcs.provider.unavailable")?;
    let plugin_id = provider["origin"]["pluginID"]
        .as_str()
        .ok_or("invalidResponse")?;
    let lease = app
        .state::<lifecycle::LifecycleState>()
        .acquire(plugin_id)?;
    let package = launch::verified_package_by_id(app, plugin_id)?;
    let identity = expected
        .iter()
        .find(|package| package.plugin_id == plugin_id)
        .ok_or(registry::STALE)?
        .identity
        .clone();
    let state_directory = store::plugin_state_directory(app, plugin_id)?;
    let plan = plan(app, &package, &scope, &root.vcs, &state_directory)?;
    Ok(Prepared {
        context: session::Context {
            host: host.into(),
            scope,
            generation,
            registration,
            request_id: id,
            root,
            plugin_id: plugin_id.into(),
            package_identity: identity,
        },
        expected,
        package,
        lease,
        plan,
        state_directory,
    })
}
fn current(app: &AppHandle, owner: &session::Owner) -> Result<(), String> {
    owner.current()?;
    active(app, &owner.context)
}
fn active(app: &AppHandle, context: &session::Context) -> Result<(), String> {
    live(app, &context.host)?;
    if app
        .state::<lifecycle::LifecycleState>()
        .blocked(&context.plugin_id)
    {
        return Err(registry::STALE.into());
    }
    app.state::<VcsHostState>()
        .registry
        .lock()
        .expect("VCS registry")
        .capture(&context.host, &context.scope, context.generation)?;
    Ok(())
}
fn unchanged(
    app: &AppHandle,
    context: &session::Context,
    expected: &[registry::Package],
    frozen_plan: &Value,
) -> Result<registry::Snapshot, String> {
    live(app, &context.host)?;
    let (snapshot, captured, registration) = app
        .state::<VcsHostState>()
        .registry
        .lock()
        .expect("VCS registry")
        .capture(&context.host, &context.scope, context.generation)?;
    if captured != expected
        || registration != context.registration
        || project_registration(app, &context.host, &context.scope)? != registration
    {
        return Err(registry::STALE.into());
    }
    let (now, _leases) = packages(app)?;
    if now != expected
        || !now.iter().any(|package| {
            package.plugin_id == context.plugin_id && package.identity == context.package_identity
        })
    {
        return Err(registry::STALE.into());
    }
    let fresh = super::redetect(app, &context.scope, &now, &snapshot)?;
    if !registry::same_roots(&snapshot.detection, &fresh) {
        return Err(registry::STALE.into());
    }
    let package = launch::verified_package_by_id(app, &context.plugin_id)?;
    let state = store::plugin_state_directory(app, &context.plugin_id)?;
    if plan(app, &package, &context.scope, &context.root.vcs, &state)? != *frozen_plan {
        return Err(registry::STALE.into());
    }
    Ok(snapshot)
}
/// A provider reports its whole working copy. Only Core-owned paths inside
/// this window's workspace enter the projection, including both ends of moves.
fn project_status(
    core: &dyn registry::VcsCore,
    snapshot: &registry::Snapshot,
    root: &registry::Root,
    mut result: Value,
) -> session::Reply {
    if snapshot.detection.truncated {
        return Err("vcs.provider.incompleteRoots".into());
    }
    let changes = result["changes"]
        .as_array()
        .ok_or("plugin.vcs.invalidOutput")?;
    // Core resolves the workspace before detecting roots. Match that identity,
    // including Windows verbatim prefixes and workspaces opened through links.
    // Only resolve the existing directory: deleted/moved status paths may no
    // longer exist and must remain valid lexical paths for Core ownership.
    let workspace = std::path::Path::new(&snapshot.workspace_root)
        .canonicalize()
        .map_err(|_| registry::STALE)?;
    let relative = |path: &str| -> Option<String> {
        std::path::Path::new(&root.path)
            .join(path)
            .strip_prefix(&workspace)
            .ok()
            .and_then(|path| path.to_str())
            .map(|path| path.replace('\\', "/"))
    };
    let mut paths = Vec::new();
    let indices: Vec<_> = changes
        .iter()
        .map(|change| {
            let path = relative(change["path"].as_str()?)?;
            let start = paths.len();
            paths.push(path);
            if let Some(old) = change["oldPath"].as_str() {
                paths.push(relative(old)?);
            }
            Some(start..paths.len())
        })
        .collect();
    let mut owners = Vec::new();
    for batch in paths.chunks(10_000) {
        owners.extend(registry::owners(core, snapshot, batch)?.owners);
    }
    result["changes"] = Value::Array(
        changes
            .iter()
            .zip(indices)
            .filter_map(|(change, indices)| {
                indices
                    .filter(|indices| {
                        owners[indices.clone()]
                            .iter()
                            .all(|owner| owner.root.as_deref() == Some(root.id.as_str()))
                    })
                    .map(|_| change.clone())
            })
            .collect(),
    );
    Ok(result)
}
struct RequestGuard {
    sessions: Arc<session::Sessions>,
    owner: Arc<session::Owner>,
    armed: bool,
}
impl Drop for RequestGuard {
    fn drop(&mut self) {
        if self.armed {
            cleanup_later(self.sessions.clone(), self.owner.clone());
        }
    }
}
pub(super) fn cleanup_later(sessions: Arc<session::Sessions>, owner: Arc<session::Owner>) {
    owner.revoke();
    tauri::async_runtime::spawn(async move {
        if sessions.cleanup(owner).await.is_err() {
            eprintln!("VCS cleanup retained its native package owner");
        }
    });
}

#[tauri::command]
pub async fn declarative_plugins_vcs_status(
    app: AppHandle,
    caller: WebviewWindow,
    scope: Scope,
    generation: u64,
    root_id: String,
    request_id: String,
) -> Result<StatusSnapshot, String> {
    live(&app, caller.label())?;
    validate(&scope)?;
    self::request_id(&request_id)?;
    let worker_app = app.clone();
    let host = caller.label().to_string();
    let prepared = tokio::time::timeout(
        registry::READ_TIMEOUT,
        tauri::async_runtime::spawn_blocking(move || {
            prepare(&worker_app, &host, scope, generation, root_id, request_id)
        }),
    )
    .await
    .map_err(|_| "requestTimeout")?
    .map_err(|_| "internalError")??;
    let owner = session::Owner::new(prepared.context.clone(), prepared.lease);
    let sessions = app.state::<VcsHostState>().sessions.clone();
    sessions.insert(owner.clone(), || current(&app, &owner).is_ok())?;
    let mut guard = RequestGuard {
        sessions: sessions.clone(),
        owner: owner.clone(),
        armed: true,
    };
    let context = owner.context.clone();
    let expected = prepared.expected;
    let frozen_plan = prepared.plan.clone();
    let worker_app = app.clone();
    let worker_owner = owner.clone();
    let worker_expected = expected.clone();
    let worker_plan = frozen_plan.clone();
    let result = async {
        owner
            .start(move || {
                unchanged(
                    &worker_app,
                    &worker_owner.context,
                    &worker_expected,
                    &worker_plan,
                )?;
                worker_owner.current()?;
                let workspace_state = prepared.state_directory.join(store::workspace_state_key(
                    &worker_owner.context.scope.workspace_root,
                ));
                // Existing platform storage paths own writable provider state;
                // installed package resources remain read-only.
                launch::prepare_required_directories(
                    &prepared.plan,
                    &prepared.state_directory,
                    &workspace_state,
                )?;
                std::fs::create_dir_all(&prepared.state_directory)
                    .map_err(|_| "vcs.provider.failed")?;
                let resolved = launch::resolve_launch(
                    &prepared.package,
                    &worker_owner.context.root.vcs,
                    &prepared.plan,
                    &prepared.state_directory,
                )?;
                let declaration = &prepared.plan["vcsProvider"]["tool"];
                let tool = if declaration.is_null() {
                    None
                } else {
                    let tool_plan = json!({
                        "launch": {"kind":"systemCommand", "commands":declaration["commands"]},
                        "validationArguments":declaration["validationArguments"],
                    });
                    Some(
                        launch::resolve_launch(
                            &prepared.package,
                            &worker_owner.context.root.vcs,
                            &tool_plan,
                            &prepared.state_directory,
                        )
                        .map_err(|_| "vcs.tool.unavailable")?
                        .server_path,
                    )
                };
                unchanged(
                    &worker_app,
                    &worker_owner.context,
                    &worker_expected,
                    &worker_plan,
                )?;
                worker_owner.current()?;
                let root_uri =
                    url::Url::from_directory_path(&worker_owner.context.scope.workspace_root)
                        .map_err(|_| "invalidRequest")?;
                let payload = json!({
                    "providerId":format!("vcsProvider:{}:{}:{}", worker_owner.context.plugin_id,
                        worker_owner.context.root.vcs, worker_owner.context.request_id),
                    "pluginId":worker_owner.context.plugin_id,
                    "executablePath":resolved.server_path, "arguments":resolved.server_args,
                    "environment":resolved.environment, "rootUri":root_uri.as_str(),
                    "workingDirectory":worker_owner.context.scope.workspace_root,
                    "initializationOptions":resolved.initialization_options,
                    "workspaceConfiguration":resolved.workspace_configuration,
                    "initializeTimeoutMilliseconds":12000, "requestTimeoutMilliseconds":30000,
                });
                Ok((payload, tool))
            })
            .await?;
        owner.status(|| current(&app, &owner)).await
    }
    .await;
    let cleaned = sessions.cleanup(owner).await;
    guard.armed = false;
    cleaned?;
    let result = result?;
    // Cleanup may wait for a late launch worker or process descendant. Re-read
    // identities and ownership after that wait so it cannot publish stale data.
    let worker_app = app.clone();
    let worker_context = context.clone();
    let result = tokio::time::timeout(
        registry::READ_TIMEOUT,
        tauri::async_runtime::spawn_blocking(move || {
            let snapshot = unchanged(&worker_app, &worker_context, &expected, &frozen_plan)?;
            project_status(&super::Core, &snapshot, &worker_context.root, result)
        }),
    )
    .await
    .map_err(|_| "requestTimeout")?
    .map_err(|_| "internalError")??;
    active(&app, &context)?;
    if sessions.cancelled(&context) {
        return Err(session::CANCELLED.into());
    }
    Ok(StatusSnapshot {
        request_id: context.request_id,
        generation: context.generation,
        root_id: context.root.id,
        vcs: context.root.vcs,
        result,
    })
}

#[cfg(test)]
#[path = "vcs_status_tests.rs"]
mod tests;

#[tauri::command]
pub async fn declarative_plugins_vcs_cancel_status(
    app: AppHandle,
    caller: WebviewWindow,
    scope: Scope,
    request_id: String,
) -> Result<(), String> {
    live(&app, caller.label())?;
    validate(&scope)?;
    self::request_id(&request_id)?;
    let sessions = app.state::<VcsHostState>().sessions.clone();
    if let Some(owner) = sessions.get(caller.label(), &scope, &request_id)? {
        sessions.cleanup(owner).await?;
    }
    Ok(())
}
pub(super) async fn close_matching(
    app: &AppHandle,
    predicate: impl Fn(&session::Context) -> bool,
) -> Result<(), String> {
    let sessions = app.state::<VcsHostState>().sessions.clone();
    let mut failure = None;
    let tasks: Vec<_> = sessions
        .matching(predicate)
        .into_iter()
        .map(|owner| {
            let sessions = sessions.clone();
            tauri::async_runtime::spawn(async move { sessions.cleanup(owner).await })
        })
        .collect();
    for task in tasks {
        match task.await {
            Ok(Ok(())) => {}
            Ok(Err(error)) => failure = Some(error),
            Err(_) => failure = Some("internalError".into()),
        }
    }
    failure.map_or(Ok(()), Err)
}
