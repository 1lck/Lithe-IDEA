//! Consent-bound settings actions. Core owns negotiation, JSON-RPC, function
//! references, progress and cancellation. Every action has an isolated Core
//! process owner, never an editor/build binding that another consumer owns.
pub mod native;
mod runtime;
#[cfg(test)]
mod tests;
pub mod web;

use super::{launch, settings, store};
pub use runtime::Snapshot as FunctionSnapshot;
use runtime::{Operation, Phase};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Manager, WebviewWindow};

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Error {
    pub code: String,
    pub message: String,
    pub plugin_error_code: Option<String>,
}
impl Error {
    pub(super) fn new(code: &str) -> Self {
        Self {
            code: code.into(),
            message: code.into(),
            plugin_error_code: None,
        }
    }
    pub(super) fn core(value: &Value) -> Self {
        Self {
            code: value["details"]
                .as_str()
                .filter(|code| {
                    matches!(
                        *code,
                        "plugin.function.invalidReference"
                            | "plugin.function.invalidParams"
                            | "plugin.function.unavailable"
                            | "plugin.function.wrongPlugin"
                            | "plugin.function.unknown"
                    )
                })
                .or_else(|| value["code"].as_str())
                .unwrap_or("plugin.function.failed")
                .into(),
            message: value["message"]
                .as_str()
                .unwrap_or("plugin.function.failed")
                .chars()
                .take(1024)
                .collect(),
            plugin_error_code: value["pluginErrorCode"].as_str().map(str::to_owned),
        }
    }
}
pub(super) type Reply<T> = Result<T, Error>;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Context {
    pub window: String,
    pub window_incarnation: u64,
    pub workspace_path: String,
    pub generation: u64,
    pub plugin_id: String,
    pub package_identity: String,
    pub setting_identity: String,
    pub action_id: String,
    pub function_id: String,
    pub operation_id: String,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Review {
    pub context: Context,
    pub title: String,
    pub confirm: bool,
    pub executes_project_code: bool,
    pub may_use_network: bool,
    pub launch_plan: Value,
    pub program: launch::ResolvedLaunch,
}

#[derive(Default)]
pub struct FunctionsState {
    native: native::Panels,
    operations: Arc<Mutex<HashMap<String, Arc<Operation>>>>,
    retired: Arc<Mutex<HashMap<String, ReceiptOwner>>>,
}
impl FunctionsState {
    fn retire_window(&self, owner: &Arc<WindowOwner>) -> Vec<Arc<Operation>> {
        owner.alive.store(false, Ordering::Release);
        self.native.revoke(|binding| binding.owner.id == owner.id);
        let entries: Vec<_> = self
            .operations
            .lock()
            .expect("function operations")
            .values()
            .filter(|entry| entry.owner.id == owner.id)
            .cloned()
            .collect();
        for entry in &entries {
            entry.cancel();
        }
        self.retired
            .lock()
            .expect("retired function operations")
            .retain(|_, receipt| receipt.incarnation != owner.id);
        entries
    }
}

#[derive(Clone)]
struct ReceiptOwner {
    window: String,
    incarnation: u64,
}
pub(super) struct WindowOwner {
    id: u64,
    alive: AtomicBool,
}
impl tauri::Resource for WindowOwner {}
static NEXT_WINDOW_OWNER: AtomicU64 = AtomicU64::new(1);

fn native_window_owner(window: &tauri::Window) -> Arc<WindowOwner> {
    table_window_owner(&mut window.resources_table())
}
fn table_window_owner(table: &mut tauri::ResourceTable) -> Arc<WindowOwner> {
    let existing = table
        .names()
        .find_map(|(id, _)| table.get::<WindowOwner>(id).ok());
    existing.unwrap_or_else(|| {
        let owner = Arc::new(WindowOwner {
            id: NEXT_WINDOW_OWNER.fetch_add(1, Ordering::Relaxed),
            alive: AtomicBool::new(true),
        });
        table.add_arc(owner.clone());
        owner
    })
}

fn caller_operation(app: &AppHandle, window: &WebviewWindow, id: &str) -> Reply<Arc<Operation>> {
    let owner = native_window_owner(&window.as_ref().window());
    let entry = operation(app, window.label(), id)?;
    if !owns_operation(&owner, &entry) {
        return Err(Error::new("plugin.function.staleContext"));
    }
    Ok(entry)
}
fn owns_operation(owner: &WindowOwner, entry: &Operation) -> bool {
    owner.id == entry.review.context.window_incarnation && owner.alive.load(Ordering::Acquire)
}
fn check_expected_owner(owner: &WindowOwner, expected: Option<u64>) -> Reply<()> {
    if !owner.alive.load(Ordering::Acquire) || expected.is_some_and(|id| id != owner.id) {
        return Err(Error::new("plugin.function.staleContext"));
    }
    Ok(())
}

fn generation(app: &AppHandle, window: &str, root: &str) -> Reply<u64> {
    if !(window == "main" || window.starts_with("workspace-"))
        || app.get_webview_window(window).is_none()
    {
        return Err(Error::new("plugin.function.staleContext"));
    }
    app.state::<super::build::BuildHostState>()
        .function_generation(window, root)
        .map_err(|_| Error::new("plugin.function.staleContext"))
}

fn check(app: &AppHandle, operation: &Operation) -> Reply<()> {
    check_context(app, operation)?;
    check_snapshot(app, operation)
}
fn check_snapshot(app: &AppHandle, operation: &Operation) -> Reply<()> {
    let snapshot = settings::read_snapshot(
        app,
        &operation.review.context.plugin_id,
        &operation.review.context.workspace_path,
    )
    .map_err(|_| Error::new("plugin.function.staleContext"))?;
    if snapshot.package_identity != operation.review.context.package_identity
        || snapshot.identity != operation.review.context.setting_identity
    {
        return Err(Error::new("plugin.function.staleContext"));
    }
    Ok(())
}
fn check_context(app: &AppHandle, operation: &Operation) -> Reply<()> {
    if operation.cancelled() || !operation.owner.alive.load(Ordering::Acquire) {
        return Err(Error::new("plugin.function.staleContext"));
    }
    check_scope(app, operation)?;
    native::check(app, operation)
}
fn check_scope(app: &AppHandle, operation: &Operation) -> Reply<()> {
    if app
        .state::<super::lifecycle::LifecycleState>()
        .blocked(&operation.review.context.plugin_id)
        || generation(
            app,
            &operation.review.context.window,
            &operation.review.context.workspace_path,
        )? != operation.review.context.generation
        || app
            .state::<super::build::BuildHostState>()
            .function_scope_revision(
                &operation.review.context.window,
                &operation.review.context.workspace_path,
                &operation.review.context.plugin_id,
            )
            .map_or(true, |revision| revision != operation.scope_revision)
    {
        return Err(Error::new("plugin.function.staleContext"));
    }
    Ok(())
}

/// Only a declaration from the trusted normalized manifest selects the
/// function and its provider. Language-shared providers stay unavailable:
/// their language owner may be in use by an editor or build operation.
fn selection(manifest: &Value, action_id: &str) -> Reply<(Value, String)> {
    if let Some(spec) = action_id.strip_prefix("__web__:") {
        let (build_system, function) = spec
            .split_once(':')
            .filter(|(build_system, _)| !build_system.is_empty())
            .ok_or_else(|| Error::new("plugin.function.invalidReference"))?;
        let system = manifest["buildSystems"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|system| system["id"] == build_system)
            .ok_or_else(|| Error::new("plugin.function.providerUnavailable"))?;
        if !system["provider"].is_object() || system["provider"]["languageServer"].is_string() {
            return Err(Error::new("plugin.function.providerUnavailable"));
        }
        return Ok((
            json!({"id": action_id, "function": function, "title": function, "confirm": true}),
            build_system.into(),
        ));
    }
    let action = manifest["settingActions"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|action| action["id"] == action_id)
        .ok_or_else(|| Error::new("plugin.function.unknownAction"))?
        .clone();
    let target = action["page"]["buildSystemID"].as_str();
    let language = action["page"]["languageID"].as_str();
    let providers: Vec<_> = manifest["buildSystems"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|system| {
            system["provider"].is_object()
                && target.is_none_or(|id| system["id"] == id)
                && language.is_none_or(|id| system["provider"]["languageServer"] == id)
        })
        .collect();
    if providers.len() != 1 || providers[0]["provider"]["languageServer"].is_string() {
        return Err(Error::new("plugin.function.providerUnavailable"));
    }
    Ok((
        action,
        providers[0]["id"]
            .as_str()
            .ok_or_else(|| Error::new("plugin.function.providerUnavailable"))?
            .into(),
    ))
}

/// Prepare a page-owned function using the same R10 operation owner. The page
/// label is resolved from the native page registry; plugin, package, workspace
/// and build instance are never accepted from page JSON as authority.
#[tauri::command]
pub async fn declarative_plugins_web_function_prepare(
    app: AppHandle,
    window: WebviewWindow,
    page_label: String,
    instance: String,
    function_id: String,
    operation_id: String,
    params: Value,
    list: bool,
) -> Reply<Review> {
    if !app
        .state::<super::web::WebPageHostState>()
        .functions
        .active(&operation_id, &page_label)
    {
        return Err(Error::new("requestCancelled"));
    }
    let page = super::web::page_identity(&app, &page_label)
        .map_err(|_| Error::new("plugin.web.forbidden"))?;
    if page.host_label != window.label() {
        return Err(Error::new("plugin.web.forbidden"));
    }
    let build_context = super::build::run_build_task(app.clone(), {
        let page = page.clone();
        let instance = instance.clone();
        move |registry, source, _| {
            let (view, contexts) = super::web::build::checked_view(registry, source, &page)
                .map_err(|_| "plugin.web.forbidden".to_string())?;
            super::web::build::selected_context(&view, &contexts, &instance)
                .map(|(_, context)| context)
                .map_err(|error| error)
        }
    })
    .await
    .map_err(|_| Error::new("plugin.web.forbidden"))?;
    if build_context.plugin_id != page.plugin_id
        || build_context.workspace_root != page.workspace_path
        || (!list
            && !function_id
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_'))
            || function_id.len() > 128)
    {
        return Err(Error::new("plugin.function.invalidReference"));
    }
    let snapshot = settings::read_snapshot(&app, &page.plugin_id, &page.workspace_path)
        .map_err(|_| Error::new("plugin.function.unavailable"))?;
    let action_id = format!("__web__:{}:{}", build_context.build_system_id, function_id);
    let cancel_window = window.clone();
    let review = declarative_plugins_function_prepare(
        app.clone(),
        window,
        page.plugin_id.clone(),
        action_id,
        page.workspace_path.clone(),
        snapshot.identity,
        operation_id.clone(),
    )
    .await?;
    if !app
        .state::<super::web::WebPageHostState>()
        .functions
        .active(&operation_id, &page_label)
    {
        let _ = declarative_plugins_function_cancel(
            app.clone(),
            cancel_window,
            operation_id.clone(),
            None,
            None,
        )
        .await;
        return Err(Error::new("requestCancelled"));
    }
    let entry = operation(&app, &page.host_label, &operation_id)?;
    entry.set_params(params);
    Ok(review)
}

fn operation(app: &AppHandle, window: &str, id: &str) -> Reply<Arc<Operation>> {
    app.state::<FunctionsState>()
        .operations
        .lock()
        .map_err(|_| Error::new("plugin.function.unavailable"))?
        .get(id)
        .filter(|operation| operation.review.context.window == window)
        .cloned()
        .ok_or_else(|| Error::new("plugin.function.staleContext"))
}

#[tauri::command]
pub async fn declarative_plugins_function_prepare(
    app: AppHandle,
    window: WebviewWindow,
    plugin_id: String,
    action_id: String,
    workspace_path: String,
    expected_identity: String,
    operation_id: String,
) -> Reply<Review> {
    prepare_owned(
        app,
        window,
        plugin_id,
        action_id,
        workspace_path,
        expected_identity,
        operation_id,
        None,
    )
    .await
}

async fn prepare_owned(
    app: AppHandle,
    window: WebviewWindow,
    plugin_id: String,
    action_id: String,
    workspace_path: String,
    expected_identity: String,
    operation_id: String,
    native: Option<native::Call>,
) -> Reply<Review> {
    if operation_id.len() > 128
        || operation_id.is_empty()
        || !operation_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    {
        return Err(Error::new("plugin.function.invalidReference"));
    }
    let label = window.label().to_string();
    let owner = native_window_owner(&window.as_ref().window());
    // Capture before the blocking lookup. A scoped reload may finish while
    // that worker is still preparing; the old revision must stay revoked.
    let scope_revision = app
        .state::<super::build::BuildHostState>()
        .function_scope_revision(&label, &workspace_path, &plugin_id)
        .map_err(|_| Error::new("plugin.function.staleContext"))?;
    tauri::async_runtime::spawn_blocking(move || {
        let generation = generation(&app, &label, &workspace_path)?;
        let lease = app
            .state::<super::lifecycle::LifecycleState>()
            .acquire(&plugin_id)
            .map_err(|_| Error::new("plugin.function.staleContext"))?;
        let snapshot = settings::read_snapshot(&app, &plugin_id, &workspace_path)
            .map_err(|_| Error::new("plugin.function.unavailable"))?;
        if snapshot.identity != expected_identity {
            return Err(Error::new("plugin.settings.conflict"));
        }
        let (action, build) = if let Some(call) = &native {
            call.selection(&snapshot.manifest)?
        } else {
            selection(&snapshot.manifest, &action_id)?
        };
        let package = launch::verified_package_by_id(&app, &plugin_id)
            .map_err(|_| Error::new("plugin.function.staleContext"))?;
        let directory = store::plugin_state_directory(&app, &plugin_id)
            .map_err(|_| Error::new("plugin.function.unavailable"))?;
        let layers = settings::load_layers(&app, &plugin_id, &workspace_path)
            .map_err(|_| Error::new("plugin.function.unavailable"))?;
        let plan = super::scan::core_execute(
            "plugins.declarative.languageServerLaunchPlan",
            json!({
                "manifest": package.manifest, "buildSystemID": build,
                "request": launch::launch_request(&directory, &package, &workspace_path, layers),
            }),
        )
        .map_err(|_| Error::new("plugin.function.providerUnavailable"))?;
        if plan["status"] != "ok" {
            return Err(Error::new("plugin.function.providerUnavailable"));
        }
        let plan = plan["plan"].clone();
        let program = launch::resolve_launch_passive(&package, &build, &plan, &directory)
            .map_err(|_| Error::new("plugin.function.providerUnavailable"))?;
        let review = Review {
            context: Context {
                window: label,
                window_incarnation: owner.id,
                workspace_path,
                generation,
                plugin_id,
                package_identity: snapshot.package_identity,
                setting_identity: snapshot.identity,
                action_id,
                function_id: action["function"]
                    .as_str()
                    .ok_or_else(|| Error::new("plugin.function.invalidReference"))?
                    .into(),
                operation_id: operation_id.clone(),
            },
            title: action["title"].as_str().unwrap_or_default().into(),
            confirm: action["confirm"] == true,
            executes_project_code: plan["buildProvider"]["executesProjectCode"]
                .as_bool()
                .unwrap_or(true),
            may_use_network: plan["buildProvider"]["mayUseNetwork"]
                .as_bool()
                .unwrap_or(true),
            launch_plan: plan,
            program,
        };
        let mut operation = Operation::new(review.clone(), directory, lease, owner);
        operation.scope_revision = scope_revision;
        let entry = Arc::new(operation);
        if let Some(call) = native {
            entry.set_params(call.params.clone());
            *entry.native.lock().expect("native function call") = Some(call);
        }
        check(&app, &entry)?;
        let state = app.state::<FunctionsState>();
        entry.bind_registry(&state.operations, &state.retired);
        let mut entries = state
            .operations
            .lock()
            .map_err(|_| Error::new("plugin.function.unavailable"))?;
        // Revocation takes this same registry before its close snapshot. A
        // late review is either visible to it or refused before publication.
        check_context(&app, &entry)?;
        let retired = state
            .retired
            .lock()
            .map_err(|_| Error::new("plugin.function.unavailable"))?;
        if entries.len() >= 64
            || retired.len() >= 4096
            || retired.contains_key(&operation_id)
            || entries.contains_key(&operation_id)
        {
            return Err(Error::new("plugin.function.busy"));
        }
        drop(retired);
        entries.insert(operation_id, entry.clone());
        drop(entries);
        // Abandoned passive reviews cannot retain a package lease forever.
        let expiry_app = app.clone();
        tauri::async_runtime::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_secs(120)).await;
            if entry.phase() == Phase::Review {
                entry.cancel();
                let _ = runtime::cleanup(&entry).await;
                remove_clean(&expiry_app, &entry);
            }
        });
        Ok(review)
    })
    .await
    .map_err(|_| Error::new("plugin.function.unavailable"))?
}

fn remove_clean(app: &AppHandle, entry: &Arc<Operation>) {
    if entry.clean() {
        let state = app.state::<FunctionsState>();
        let mut entries = state.operations.lock().expect("function operations");
        if entries
            .get(&entry.review.context.operation_id)
            .is_some_and(|current| Arc::ptr_eq(current, entry))
        {
            if !entry.review.context.action_id.starts_with("__web__:") {
                let mut retired = state.retired.lock().expect("retired function operations");
                if entry.owner.alive.load(Ordering::Acquire) {
                    retired.insert(
                        entry.review.context.operation_id.clone(),
                        ReceiptOwner {
                            window: entry.review.context.window.clone(),
                            incarnation: entry.owner.id,
                        },
                    );
                }
            }
            entries.remove(&entry.review.context.operation_id);
            native::release(entry);
        }
    }
}

#[tauri::command]
pub async fn declarative_plugins_function_confirm(
    app: AppHandle,
    window: WebviewWindow,
    operation_id: String,
) -> Reply<()> {
    let entry = caller_operation(&app, &window, &operation_id)?;
    let verify_app = app.clone();
    let verify = entry.clone();
    tauri::async_runtime::spawn_blocking(move || check(&verify_app, &verify))
        .await
        .map_err(|_| Error::new("plugin.function.unavailable"))??;
    if entry.review.context.action_id.starts_with("__web__:") {
        web::confirm(&app, &entry, window.label())?;
    } else {
        native::begin(&app, &entry)?;
    }
    tauri::async_runtime::spawn(runtime::run(app, entry));
    Ok(())
}

#[tauri::command]
pub async fn declarative_plugins_function_state(
    app: AppHandle,
    window: WebviewWindow,
    operation_id: String,
    cleanup_only: Option<bool>,
    expected_window_incarnation: Option<u64>,
) -> Reply<FunctionSnapshot> {
    let owner = native_window_owner(&window.as_ref().window());
    check_expected_owner(&owner, expected_window_incarnation)?;
    let entry = caller_operation(&app, &window, &operation_id)?;
    // A retained cleanup receipt outlives its workspace. This read is still
    // authenticated by the caller's exact native window resource above.
    if cleanup_only == Some(true) {
        let mut snapshot = entry.snapshot();
        snapshot.progress = None;
        snapshot.result = None;
        return Ok(snapshot);
    }
    tauri::async_runtime::spawn_blocking(move || {
        check_scope(&app, &entry)?;
        native::check(&app, &entry)?;
        if matches!(entry.phase(), Phase::Succeeded | Phase::Failed) {
            check_snapshot(&app, &entry)?;
        }
        Ok(entry.snapshot())
    })
    .await
    .map_err(|_| Error::new("plugin.function.unavailable"))?
}

#[tauri::command]
pub async fn declarative_plugins_function_cancel(
    app: AppHandle,
    window: WebviewWindow,
    operation_id: String,
    web_error: Option<Error>,
    expected_window_incarnation: Option<u64>,
) -> Reply<()> {
    let owner = native_window_owner(&window.as_ref().window());
    check_expected_owner(&owner, expected_window_incarnation)?;
    // A refusal can precede native prepare. Revoke the page receipt first so
    // late preparation cannot publish or start a provider after cancellation.
    let page_owned = app
        .state::<super::web::WebPageHostState>()
        .functions
        .cancel_for_host(&operation_id, window.label(), web_error);
    // A completed receipt may already have been released by the same caller.
    let entry = match caller_operation(&app, &window, &operation_id) {
        Ok(entry) => entry,
        Err(error) => {
            if page_owned
                || app
                    .state::<FunctionsState>()
                    .retired
                    .lock()
                    .map_err(|_| Error::new("plugin.function.unavailable"))?
                    .get(&operation_id)
                    .is_some_and(|receipt| {
                        receipt.window == window.label()
                            && receipt.incarnation == owner.id
                            && owner.alive.load(Ordering::Acquire)
                    })
            {
                return Ok(());
            }
            return Err(error);
        }
    };
    entry.cancel();
    runtime::cleanup(&entry).await?;
    remove_clean(&app, &entry);
    Ok(())
}

async fn close_matching(
    app: &AppHandle,
    predicate: impl Fn(&Context) -> bool,
) -> Result<(), String> {
    drain_matching(&app.state::<FunctionsState>(), predicate).await
}

async fn drain_matching(
    state: &FunctionsState,
    predicate: impl Fn(&Context) -> bool,
) -> Result<(), String> {
    let entries: Vec<_> = state
        .operations
        .lock()
        .map_err(|_| "plugin.function.unavailable")?
        .values()
        .filter(|entry| predicate(&entry.review.context))
        .cloned()
        .collect();
    for entry in &entries {
        entry.cancel();
    }
    let tasks: Vec<_> = entries
        .into_iter()
        .map(|entry| {
            tauri::async_runtime::spawn(async move {
                runtime::cleanup(&entry).await?;
                entry.retire_clean();
                Ok::<(), Error>(())
            })
        })
        .collect();
    let mut error = None;
    for task in tasks {
        match task.await {
            Ok(Ok(())) => {}
            Ok(Err(failure)) => error = Some(failure.code),
            Err(_) => error = Some("plugin.function.cleanupFailed".into()),
        }
    }
    error.map_or(Ok(()), Err)
}
pub async fn close_plugin(app: &AppHandle, plugin: &str) -> Result<(), String> {
    app.state::<FunctionsState>()
        .native
        .revoke(|binding| binding.plugin_id == plugin);
    close_matching(app, |context| context.plugin_id == plugin).await
}
/// Retire the exact native window before any await. Label reuse cannot change
/// this resource or make its delayed cleanup select a replacement window.
pub fn window_destroyed(window: &tauri::Window) {
    let owner = native_window_owner(window);
    let app = window.app_handle().clone();
    let entries = app.state::<FunctionsState>().retire_window(&owner);
    tauri::async_runtime::spawn(async move {
        for entry in entries {
            if let Err(error) = runtime::cleanup(&entry).await {
                eprintln!("Could not release plugin function owner: {}", error.code);
            } else {
                remove_clean(&app, &entry);
            }
        }
    });
}
pub async fn close_workspace(app: &AppHandle, window: &str, root: &str) -> Result<(), String> {
    app.state::<FunctionsState>()
        .native
        .revoke(|binding| binding.window == window && binding.workspace == root);
    close_matching(app, |context| {
        context.window == window && context.workspace_path == root
    })
    .await
}

/// A project settings reload retires only this plugin in this workspace.
/// The build registry has already raised its scoped admission revision before
/// this snapshot; cleanup failures retain the original owner for retry.
pub(crate) async fn close_scope(
    app: &AppHandle,
    window: &str,
    root: &str,
    plugin: &str,
) -> Result<(), String> {
    app.state::<super::web::WebPageHostState>()
        .functions
        .revoke_scope(window, root, plugin);
    app.state::<FunctionsState>().native.revoke(|binding| {
        binding.window == window && binding.workspace == root && binding.plugin_id == plugin
    });
    close_matching(app, |context| {
        context.window == window && context.workspace_path == root && context.plugin_id == plugin
    })
    .await
}
