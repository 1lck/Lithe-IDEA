//! Consent-bound settings actions. Core owns negotiation, JSON-RPC, function
//! references, progress and cancellation. Every action has an isolated Core
//! process owner, never an editor/build binding that another consumer owns.
mod runtime;
#[cfg(test)]
mod tests;

use super::{launch, settings, store};
pub use runtime::Snapshot as FunctionSnapshot;
use runtime::{Operation, Phase};
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Manager, WebviewWindow};

#[derive(Debug, Clone, Serialize)]
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
    operations: Arc<Mutex<HashMap<String, Arc<Operation>>>>,
    retired: Arc<Mutex<HashMap<String, String>>>,
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
    if operation.cancelled() {
        return Err(Error::new("plugin.function.staleContext"));
    }
    check_scope(app, operation)
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
    {
        return Err(Error::new("plugin.function.staleContext"));
    }
    Ok(())
}

/// Only a declaration from the trusted normalized manifest selects the
/// function and its provider. Language-shared providers stay unavailable:
/// their language owner may be in use by an editor or build operation.
fn selection(manifest: &Value, action_id: &str) -> Reply<(Value, String)> {
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
    if operation_id.len() > 128
        || operation_id.is_empty()
        || !operation_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    {
        return Err(Error::new("plugin.function.invalidReference"));
    }
    let label = window.label().to_string();
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
        let (action, build) = selection(&snapshot.manifest, &action_id)?;
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
        let entry = Arc::new(Operation::new(review.clone(), directory, lease));
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
            state
                .retired
                .lock()
                .expect("retired function operations")
                .insert(
                    entry.review.context.operation_id.clone(),
                    entry.review.context.window.clone(),
                );
            entries.remove(&entry.review.context.operation_id);
        }
    }
}

#[tauri::command]
pub async fn declarative_plugins_function_confirm(
    app: AppHandle,
    window: WebviewWindow,
    operation_id: String,
) -> Reply<()> {
    let entry = operation(&app, window.label(), &operation_id)?;
    let verify_app = app.clone();
    let verify = entry.clone();
    tauri::async_runtime::spawn_blocking(move || check(&verify_app, &verify))
        .await
        .map_err(|_| Error::new("plugin.function.unavailable"))??;
    entry.begin()?;
    tauri::async_runtime::spawn(runtime::run(app, entry));
    Ok(())
}

#[tauri::command]
pub async fn declarative_plugins_function_state(
    app: AppHandle,
    window: WebviewWindow,
    operation_id: String,
) -> Reply<FunctionSnapshot> {
    let entry = operation(&app, window.label(), &operation_id)?;
    tauri::async_runtime::spawn_blocking(move || {
        check_scope(&app, &entry)?;
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
) -> Reply<()> {
    // A completed receipt may already have been released by the same caller.
    let entry = match operation(&app, window.label(), &operation_id) {
        Ok(entry) => entry,
        Err(error) => {
            if app
                .state::<FunctionsState>()
                .retired
                .lock()
                .map_err(|_| Error::new("plugin.function.unavailable"))?
                .get(&operation_id)
                .is_some_and(|owner| owner == window.label())
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
    let entries: Vec<_> = app
        .state::<FunctionsState>()
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
            let app = app.clone();
            tauri::async_runtime::spawn(async move {
                runtime::cleanup(&entry).await?;
                remove_clean(&app, &entry);
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
    close_matching(app, |context| context.plugin_id == plugin).await
}
pub async fn close_window(app: &AppHandle, window: &str) -> Result<(), String> {
    close_matching(app, |context| context.window == window).await
}
pub async fn close_workspace(app: &AppHandle, window: &str, root: &str) -> Result<(), String> {
    close_matching(app, |context| {
        context.window == window && context.workspace_path == root
    })
    .await
}
