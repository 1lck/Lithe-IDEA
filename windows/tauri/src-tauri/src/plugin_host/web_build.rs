//! Page-owned requests for the Windows build bridge.
//! The workbench supplies no build payloads: it accepts or refuses a native
//! request, and the native registry owns all model/option facts and writes.

use super::super::build::{run_build_option_edit, run_build_task, HostCoreExecutor};
use super::super::build_registry::{
    BuildCoreExecutor, BuildModelContext, BuildOptionsPersistence, BuildPackageSource,
    BuildRegistry, BuildView, StoredBuildOptions,
};
use super::{bridge_error, bridge_identity, with_page_owner, BridgeIdentity, WebPageHostState};
use serde::Deserialize;
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, HashMap};
use std::sync::{
    atomic::{AtomicBool, AtomicU64, Ordering},
    Arc, Mutex,
};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager, WebviewWindow};
use tokio::sync::oneshot;

#[path = "web_build_workflow.rs"]
pub mod workflow;

const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_PAGE_REQUESTS: usize = 16;
const MAX_HOST_REQUESTS: usize = 128;
const MAX_PARAMETER_BYTES: usize = 64 * 1024;
static NEXT_REQUEST: AtomicU64 = AtomicU64::new(1);

#[derive(Clone, Debug)]
enum BuildRequest {
    Instances,
    SetOptions {
        instance: String,
        values: BTreeMap<String, Value>,
    },
    Workflow(workflow::Request),
}

impl BuildRequest {
    fn parse(method: &str, params: Value) -> Result<Self, String> {
        if serde_json::to_vec(&params)
            .map_err(|e| invalid(e.to_string()))?
            .len()
            > MAX_PARAMETER_BYTES
        {
            return Err(invalid("build parameters exceed 64 KiB"));
        }
        match method {
            "build.instances" => {
                if params.is_null() || params.as_object().is_some_and(Map::is_empty) {
                    Ok(Self::Instances)
                } else {
                    Err(invalid("instances accepts no parameters"))
                }
            }
            "build.setOptions" => {
                #[derive(Deserialize)]
                #[serde(deny_unknown_fields)]
                struct Parameters {
                    instance: String,
                    values: BTreeMap<String, Value>,
                }
                let parameters: Parameters =
                    serde_json::from_value(params).map_err(|e| invalid(e.to_string()))?;
                if !valid_id(&parameters.instance)
                    || parameters.values.len() > 64
                    || parameters.values.keys().any(|key| !valid_id(key))
                {
                    return Err(invalid(
                        "setOptions requires an instance and at most 64 named values",
                    ));
                }
                Ok(Self::SetOptions {
                    instance: parameters.instance,
                    values: parameters.values,
                })
            }
            "build.refresh" | "build.runTask" | "build.runTests" | "build.cancel"
            | "build.dependencies" => Ok(Self::Workflow(workflow::Request::parse(method, params)?)),
            _ => Err(bridge_error(
                "plugin.web.unavailable",
                "this build method is not available",
            )),
        }
    }

    fn method(&self) -> &str {
        match self {
            Self::Instances => "build.instances",
            Self::SetOptions { .. } => "build.setOptions",
            Self::Workflow(request) => request.method(),
        }
    }
}

fn valid_id(value: &str) -> bool {
    !value.is_empty() && value.len() <= 1024 && !value.contains('\0')
}
fn invalid(message: impl Into<String>) -> String {
    bridge_error("plugin.web.invalidRequest", message)
}
fn forbidden() -> String {
    bridge_error(
        "plugin.web.forbidden",
        "the page request is no longer owned",
    )
}
fn timed_out() -> String {
    bridge_error("requestTimeout", "the page build request timed out")
}

struct PendingBuild {
    page_label: String,
    identity: BridgeIdentity,
    request: BuildRequest,
    deadline: Instant,
    claimed: AtomicBool,
    completion: Mutex<Option<oneshot::Sender<Result<Value, String>>>>,
    reply: Mutex<Option<ReadyBuild>>,
}

struct ReadyBuild {
    result: Result<Value, String>,
    generation: Option<u64>,
}

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BuildRequestPhase {
    Accept,
    Complete,
    Reject,
}

impl PendingBuild {
    fn complete(&self, result: Result<Value, String>) {
        if let Some(sender) = self.completion.lock().expect("build completion").take() {
            // A closed page may have dropped its receiver; there is no second delivery.
            let _ = sender.send(result);
        }
    }
}

#[derive(Default)]
pub(super) struct BuildRequests(
    Mutex<HashMap<String, Arc<PendingBuild>>>,
    workflow::Operations,
);

impl BuildRequests {
    fn admit(&self, pending: Arc<PendingBuild>) -> Result<String, String> {
        let mut requests = self.0.lock().expect("page build requests");
        if requests.len() >= MAX_HOST_REQUESTS
            || requests
                .values()
                .filter(|p| p.page_label == pending.page_label)
                .count()
                >= MAX_PAGE_REQUESTS
        {
            return Err(invalid("too many pending page build requests"));
        }
        let id = format!("web-build-{}", NEXT_REQUEST.fetch_add(1, Ordering::Relaxed));
        requests.insert(id.clone(), pending);
        Ok(id)
    }

    fn claim(&self, id: &str, host: &str, now: Instant) -> Result<Arc<PendingBuild>, String> {
        let requests = self.0.lock().expect("page build requests");
        let pending = requests.get(id).ok_or_else(forbidden)?;
        if pending.identity.host_label != host {
            return Err(forbidden());
        }
        if now >= pending.deadline {
            return Err(timed_out());
        }
        if pending.claimed.swap(true, Ordering::AcqRel) {
            return Err(invalid("request was already accepted"));
        }
        Ok(pending.clone())
    }

    fn owned(&self, id: &str, host: &str) -> Result<Arc<PendingBuild>, String> {
        self.0
            .lock()
            .expect("page build requests")
            .get(id)
            .filter(|pending| pending.identity.host_label == host)
            .cloned()
            .ok_or_else(forbidden)
    }

    fn check(&self, id: &str, pending: &Arc<PendingBuild>, now: Instant) -> Result<(), String> {
        if now >= pending.deadline {
            return Err(timed_out());
        }
        if !self
            .0
            .lock()
            .expect("page build requests")
            .get(id)
            .is_some_and(|p| Arc::ptr_eq(p, pending))
        {
            return Err(forbidden());
        }
        Ok(())
    }

    fn remove(&self, id: &str) {
        self.0.lock().expect("page build requests").remove(id);
    }

    pub(super) fn revoke_pages(&self, labels: &[String]) {
        self.1.revoke_pages(labels);
        self.0
            .lock()
            .expect("page build requests")
            .retain(|_, pending| {
                if !labels.contains(&pending.page_label) {
                    return true;
                }
                pending.complete(Err(forbidden()));
                false
            });
    }
}

struct RequestLease {
    app: AppHandle,
    id: String,
}
impl Drop for RequestLease {
    fn drop(&mut self) {
        self.app
            .state::<WebPageHostState>()
            .builds
            .1
            .request_closed(&self.id);
        self.app.state::<WebPageHostState>().builds.remove(&self.id);
    }
}

pub(super) async fn request(
    app: &AppHandle,
    page_label: &str,
    identity: BridgeIdentity,
    method: &str,
    params: Value,
) -> Result<Value, String> {
    let request = BuildRequest::parse(method, params)?;
    let timeout = if matches!(request, BuildRequest::Workflow(_)) {
        std::time::Duration::from_secs(120)
    } else {
        REQUEST_TIMEOUT
    };
    let (completion, receiver) = oneshot::channel();
    let pending = Arc::new(PendingBuild {
        page_label: page_label.into(),
        identity: identity.clone(),
        request,
        deadline: Instant::now() + timeout,
        claimed: AtomicBool::new(false),
        completion: Mutex::new(Some(completion)),
        reply: Mutex::new(None),
    });
    let state = app.state::<WebPageHostState>();
    let id = with_page_owner(&state, page_label, &identity, || {
        state.builds.admit(pending.clone())
    })?;
    let _lease = RequestLease {
        app: app.clone(),
        id: id.clone(),
    };
    with_page_owner(&state, page_label, &identity, || {
        app.emit_to(
            &identity.host_label,
            "plugin-web-build-request",
            json!({
                "operationId": id, "pluginId": identity.plugin_id, "pageLabel": page_label,
                "pageGeneration": identity.generation, "hostLabel": identity.host_label,
                "workspaceId": identity.workspace_id, "workspacePath": identity.workspace_path,
                "method": pending.request.method(),
            }),
        )
        .map_err(|e| bridge_error("plugin.web.unavailable", e.to_string()))
    })?;
    let result = async {
        let value =
            tokio::time::timeout_at(tokio::time::Instant::from_std(pending.deadline), receiver)
                .await
                .map_err(|_| timed_out())?
                .map_err(|_| forbidden())??;
        with_page_owner(&state, page_label, &identity, || {
            state.builds.check(&id, &pending, Instant::now())?;
            Ok(value)
        })
    }
    .await;
    if result.is_err() {
        state.builds.1.revoke_request(&id);
        let _ = app.emit_to(
            &identity.host_label,
            "plugin-web-build-revoked",
            json!({"operationId": id}),
        );
    }
    result
}

/// Only the product window named by a pending request may accept it. There is
/// deliberately no page-supplied plugin/workspace/argv or host-supplied answer.
#[tauri::command]
pub async fn declarative_plugins_web_build_handle(
    app: AppHandle,
    caller: WebviewWindow,
    operation_id: String,
    phase: BuildRequestPhase,
) -> Result<Option<BuildView>, String> {
    let state = app.state::<WebPageHostState>();
    let pending = if matches!(phase, BuildRequestPhase::Accept) {
        state
            .builds
            .claim(&operation_id, caller.label(), Instant::now())?
    } else {
        state.builds.owned(&operation_id, caller.label())?
    };
    let identity = bridge_identity(&app, &pending.page_label)?;
    if identity != pending.identity {
        return Err(forbidden());
    }
    if matches!(phase, BuildRequestPhase::Reject) {
        with_page_owner(&state, &pending.page_label, &identity, || {
            pending.complete(Err(forbidden()));
            state.builds.remove(&operation_id);
            Ok(())
        })?;
        return Ok(None);
    }
    if matches!(phase, BuildRequestPhase::Complete) {
        return publish(app.clone(), operation_id, pending).await;
    }
    if matches!(pending.request, BuildRequest::Workflow(_)) {
        return Ok(None);
    }
    let outcome = perform(app.clone(), operation_id.clone(), pending.clone()).await;
    let view = match &outcome {
        Ok((_, view)) => Some(view.clone()),
        Err(_) => read_view(app.clone(), operation_id.clone(), pending.clone(), false)
            .await
            .ok()
            .map(|(view, _)| view),
    };
    with_page_owner(&state, &pending.page_label, &identity, || {
        state
            .builds
            .check(&operation_id, &pending, Instant::now())?;
        *pending.reply.lock().expect("build reply") = Some(ReadyBuild {
            result: outcome.map(|(value, _)| value).map_err(normalize_error),
            generation: view.as_ref().map(|view| view.generation),
        });
        Ok(())
    })?;
    Ok(view)
}

async fn publish(
    app: AppHandle,
    id: String,
    pending: Arc<PendingBuild>,
) -> Result<Option<BuildView>, String> {
    let checkpoint_app = app.clone();
    run_build_task(app, move |registry, source, _| {
        with_page_owner(
            &checkpoint_app.state::<WebPageHostState>(),
            &pending.page_label,
            &pending.identity,
            || {
                check_request(&checkpoint_app, &id, &pending)?;
                let reply = pending
                    .reply
                    .lock()
                    .expect("build reply")
                    .take()
                    .ok_or_else(|| invalid("the request has no completed native reply"))?;
                let validity = if let Some(generation) = reply.generation {
                    checked_view(registry, source, &pending.identity).and_then(|(view, _)| {
                        if view.generation == generation {
                            Ok(())
                        } else {
                            Err("plugin.build.staleContext".into())
                        }
                    })
                } else {
                    Ok(())
                };
                check_request(&checkpoint_app, &id, &pending)?;
                match validity {
                    Ok(()) => pending.complete(reply.result),
                    Err(error) => {
                        let error = normalize_error(error);
                        pending.complete(Err(error.clone()));
                        return Err(error);
                    }
                }
                Ok(())
            },
        )
    })
    .await?;
    Ok(None)
}

fn normalize_error(error: String) -> String {
    if serde_json::from_str::<Value>(&error)
        .ok()
        .is_some_and(|v| v["code"].is_string())
    {
        return error;
    }
    if error.starts_with("plugin.build.") {
        return bridge_error(error.split(':').next().unwrap_or(&error), &error);
    }
    bridge_error("plugin.web.unavailable", error)
}

fn check_request(app: &AppHandle, id: &str, pending: &Arc<PendingBuild>) -> Result<(), String> {
    let state = app.state::<WebPageHostState>();
    state.builds.check(id, pending, Instant::now())?;
    if super::workspace_generation(
        &state,
        &pending.identity.host_label,
        &pending.identity.workspace_id,
    ) != pending.identity.workspace_generation
    {
        return Err(forbidden());
    }
    Ok(())
}

async fn perform(
    app: AppHandle,
    id: String,
    pending: Arc<PendingBuild>,
) -> Result<(Value, BuildView), String> {
    let (baseline, contexts) = read_view(app.clone(), id.clone(), pending.clone(), true).await?;
    let BuildRequest::SetOptions { instance, values } = &pending.request else {
        return Ok((
            instances_json(&baseline, &pending.identity.plugin_id),
            baseline,
        ));
    };
    let (selected, context) = selected_context(&baseline, &contexts, instance)?;
    if values.is_empty() {
        return Ok((json!({ "options": stored_options(&selected) }), baseline));
    }
    let edit_app = app.clone();
    let host = pending.identity.host_label.clone();
    run_build_option_edit(app, host, move |registry, source, persistence| {
        with_page_owner(
            &edit_app.state::<WebPageHostState>(),
            &pending.page_label,
            &pending.identity,
            || {
                check_request(&edit_app, &id, &pending)?;
                let view = registry.view(&pending.identity.host_label);
                if view.workspace_root != baseline.workspace_root
                    || view.generation != baseline.generation + 1
                    || source.package(&context.plugin_id).as_ref() != Some(&context.package)
                    || !view.instances.contains(&selected)
                {
                    return Err("plugin.build.staleContext".into());
                }
                let BuildRequest::SetOptions { values, .. } = &pending.request else {
                    unreachable!()
                };
                // Keep the existing native edit semantics (including explicit empty
                // multi-select markers). No web option store or argv path exists.
                let mut view = view;
                for (option, value) in values {
                    check_request(&edit_app, &id, &pending)?;
                    let check = || check_request(&edit_app, &id, &pending);
                    let guarded = CheckedPersistence {
                        inner: persistence,
                        check: &check,
                        previous: persistence.load(&context.workspace_root)?,
                        last_written: Mutex::new(None),
                    };
                    view = registry.set_option(
                        &HostCoreExecutor,
                        source,
                        &guarded,
                        &context.window_label,
                        &context.workspace_root,
                        &context.plugin_id,
                        &context.build_system_id,
                        &context.root,
                        option,
                        (!value.is_null()).then(|| value.clone()),
                    )?;
                }
                check_request(&edit_app, &id, &pending)?;
                let row = view
                    .instances
                    .iter()
                    .find(|row| {
                        row["pluginID"] == context.plugin_id
                            && row["buildSystemID"] == context.build_system_id
                            && row["root"] == context.root
                    })
                    .ok_or_else(|| "plugin.build.staleContext".to_string())?;
                Ok((json!({ "options": stored_options(row) }), view))
            },
        )
    })
    .await
}

async fn read_view(
    app: AppHandle,
    id: String,
    pending: Arc<PendingBuild>,
    validate_options: bool,
) -> Result<(BuildView, Vec<BuildModelContext>), String> {
    let checkpoint_app = app.clone();
    run_build_task(app, move |registry, source, _| {
        with_page_owner(
            &checkpoint_app.state::<WebPageHostState>(),
            &pending.page_label,
            &pending.identity,
            || {
                check_request(&checkpoint_app, &id, &pending)?;
                let snapshot = checked_view(registry, source, &pending.identity)?;
                if validate_options {
                    if let BuildRequest::SetOptions { instance, values } = &pending.request {
                        let (selected, context) =
                            selected_context(&snapshot.0, &snapshot.1, instance)?;
                        validate_option_names(&selected, values)?;
                        validate_option_values(&HostCoreExecutor, &context, values)?;
                    }
                }
                Ok(snapshot)
            },
        )
    })
    .await
}

fn selected_context(
    view: &BuildView,
    contexts: &[BuildModelContext],
    instance: &str,
) -> Result<(Value, BuildModelContext), String> {
    let selected = view
        .instances
        .iter()
        .find(|row| instance_id(row).as_deref() == Some(instance))
        .ok_or_else(|| {
            bridge_error(
                "plugin.web.forbidden",
                "the instance is outside this plugin page",
            )
        })?;
    let context = contexts
        .iter()
        .find(|context| {
            selected["pluginID"] == context.plugin_id
                && selected["buildSystemID"] == context.build_system_id
                && selected["root"] == context.root
        })
        .ok_or_else(forbidden)?;
    Ok((selected.clone(), context.clone()))
}

struct CheckedPersistence<'a> {
    inner: &'a dyn BuildOptionsPersistence,
    check: &'a (dyn Fn() -> Result<(), String> + Sync),
    previous: StoredBuildOptions,
    last_written: Mutex<Option<StoredBuildOptions>>,
}
impl BuildOptionsPersistence for CheckedPersistence<'_> {
    fn load(&self, root: &str) -> Result<StoredBuildOptions, String> {
        self.inner.load(root)
    }
    fn save(&self, root: &str, values: &StoredBuildOptions) -> Result<(), String> {
        let mut last_written = self.last_written.lock().expect("guarded option write");
        if let Err(error) = (self.check)() {
            // Native set_option may roll back a failed re-detection. Permit
            // only restoration of this edit's original bytes, with no lost
            // external update, after its deadline/revocation. This is cleanup.
            if values != &self.previous || last_written.as_ref() != Some(&self.inner.load(root)?) {
                return Err(error);
            }
        }
        self.inner.save(root, values)?;
        *last_written = Some(values.clone());
        Ok(())
    }
}

fn checked_view(
    registry: &BuildRegistry,
    source: &dyn BuildPackageSource,
    identity: &BridgeIdentity,
) -> Result<(BuildView, Vec<BuildModelContext>), String> {
    let view = registry.view(&identity.host_label);
    registry.check_read_snapshot(
        &identity.host_label,
        &identity.workspace_path,
        view.generation,
    )?;
    if view.workspace_root != identity.workspace_path {
        return Err(bridge_error(
            "plugin.web.unavailable",
            "the workbench build registry is not ready for this workspace",
        ));
    }
    let mut contexts = Vec::new();
    for row in view
        .instances
        .iter()
        .filter(|row| row["pluginID"] == identity.plugin_id)
    {
        let system = row["buildSystemID"].as_str().ok_or_else(forbidden)?;
        let root = row["root"].as_str().ok_or_else(forbidden)?;
        let context = registry.model_context(
            &identity.host_label,
            &identity.workspace_path,
            &identity.plugin_id,
            system,
            root,
        )?;
        if source.package(&identity.plugin_id).as_ref() != Some(&context.package) {
            return Err("plugin.build.packageChanged".into());
        }
        contexts.push(context);
    }
    Ok((view, contexts))
}

fn validate_option_names(row: &Value, values: &BTreeMap<String, Value>) -> Result<(), String> {
    for key in values.keys() {
        if !row["options"]
            .as_array()
            .is_some_and(|options| options.iter().any(|option| option["id"] == *key))
        {
            return Err(invalid(format!("the instance has no option {key}")));
        }
    }
    Ok(())
}

fn validate_option_values(
    core: &dyn BuildCoreExecutor,
    context: &BuildModelContext,
    values: &BTreeMap<String, Value>,
) -> Result<(), String> {
    let mut candidate = context.options.clone();
    for (key, value) in values {
        if value.is_null() {
            candidate.remove(key);
        } else {
            candidate.insert(key.clone(), value.clone());
        }
    }
    let response = core.execute("build.resolveOptions", json!({
        "manifest": context.package.manifest, "buildSystemID": context.build_system_id,
        "request": { "options": candidate, "modelValues": context.model["optionValues"].as_object().cloned().unwrap_or_default() },
    }))?;
    if response["status"] != "ok" {
        return Err(response["error"].to_string());
    }
    if response["options"]["dropped"]
        .as_array()
        .into_iter()
        .flatten()
        .any(|key| {
            key.as_str()
                .is_some_and(|key| values.get(key).is_some_and(|value| !value.is_null()))
        })
    {
        return Err(invalid("Core rejected one or more option values"));
    }
    Ok(())
}

fn instance_id(row: &Value) -> Option<String> {
    Some(
        json!([
            row["pluginID"].as_str()?,
            row["buildSystemID"].as_str()?,
            row["root"].as_str()?
        ])
        .to_string(),
    )
}

fn stored_options(row: &Value) -> Value {
    Value::Object(
        row["options"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|option| option["source"] == "user")
            .filter_map(|option| Some((option["id"].as_str()?.into(), option["value"].clone())))
            .collect(),
    )
}

fn instances_json(view: &BuildView, plugin_id: &str) -> Value {
    json!({ "instances": view.instances.iter().filter(|row| row["pluginID"] == plugin_id)
        .filter_map(|row| {
            let mut instance = json!({ "id": instance_id(row)?, "buildSystemID": row["buildSystemID"],
                "root": row["root"], "options": stored_options(row),
                "state": if row["modelError"].is_object() { "failed" } else if row["model"].is_object() { "loaded" } else { "notLoaded" },
            });
            if row["model"].is_object() { instance["model"] = row["model"].clone(); }
            if row["modelError"].is_object() { instance["error"] = row["modelError"].clone(); }
            Some(instance)
        }).collect::<Vec<_>>() })
}

#[cfg(test)]
#[path = "web_build_tests.rs"]
mod tests;
