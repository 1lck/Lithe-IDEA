//! Translate existing web selections into native IDs and bind the workbench's
//! orchestration to the page. The native build owner still prepares, executes,
//! decodes and cancels every operation.
use super::super::super::build::page::PageOperation;
use super::*;

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Selection {
    name: Option<String>,
    path: Option<String>,
    tags: Option<Vec<String>>,
    execution: Option<Value>,
    properties: Option<Value>,
}
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Parameters {
    instance: Option<String>,
    task: Option<String>,
    project: Option<Selection>,
    target: Option<Selection>,
    model_task: Option<Selection>,
    suite: Option<String>,
    case: Option<String>,
    #[serde(default)]
    user_arguments: Vec<String>,
    run: Option<String>,
}
#[derive(Clone, Debug)]
pub(super) struct Request {
    method: String,
    parameters: Parameters,
}
impl Request {
    pub fn method(&self) -> &str {
        &self.method
    }
    pub fn parse(method: &str, params: Value) -> Result<Self, String> {
        let allowed: &[&str] = match method {
            "build.refresh" => &["instance"],
            "build.runTask" => &[
                "instance",
                "task",
                "project",
                "target",
                "modelTask",
                "userArguments",
            ],
            "build.runTests" => &["instance", "project", "target", "suite", "case"],
            "build.dependencies" => &["instance", "project"],
            "build.cancel" => &["run"],
            _ => return Err(invalid("unknown build method")),
        };
        let object = params
            .as_object()
            .ok_or_else(|| invalid("parameters must be an object"))?;
        if object.keys().any(|key| !allowed.contains(&key.as_str())) {
            return Err(invalid("unknown build parameter"));
        }
        let parameters: Parameters =
            serde_json::from_value(params).map_err(|e| invalid(e.to_string()))?;
        let required = if method == "build.cancel" {
            &parameters.run
        } else {
            &parameters.instance
        };
        if !required
            .as_deref()
            .is_some_and(|value| printable(value, 1024))
        {
            return Err(invalid("missing instance or run"));
        }
        if method == "build.runTask"
            && !parameters
                .task
                .as_deref()
                .is_some_and(|id| printable(id, 256))
        {
            return Err(invalid("task is required"));
        }
        for value in [&parameters.suite, &parameters.case].into_iter().flatten() {
            if !printable(value, 1024) {
                return Err(invalid("invalid test filter"));
            }
        }
        if parameters.user_arguments.len() > 64
            || parameters
                .user_arguments
                .iter()
                .any(|value| value.len() > 4096 || value.contains('\0'))
        {
            return Err(invalid("userArguments exceeds its budget"));
        }
        for selection in [
            &parameters.project,
            &parameters.target,
            &parameters.model_task,
        ]
        .into_iter()
        .flatten()
        {
            selection.validate()?;
        }
        Ok(Self {
            method: method.into(),
            parameters,
        })
    }
}
fn printable(value: &str, limit: usize) -> bool {
    !value.is_empty() && value.len() <= limit && !value.chars().any(char::is_control)
}
impl Selection {
    fn validate(&self) -> Result<(), String> {
        if self.name.is_none() && self.path.is_none() {
            return Err(invalid("a selection needs name or path"));
        }
        if self.name.as_deref().is_some_and(|s| !printable(s, 1024))
            || self.path.as_deref().is_some_and(|s| !printable(s, 4096))
        {
            return Err(invalid("invalid selection name/path"));
        }
        if self.path.as_deref().is_some_and(|s| {
            s.starts_with('/')
                || s.contains('\\')
                || s.contains(':')
                || s.split('/').any(|s| s == "..")
        }) {
            return Err(forbidden());
        }
        if self
            .tags
            .as_ref()
            .is_some_and(|tags| tags.len() > 64 || tags.iter().any(|s| !printable(s, 64)))
        {
            return Err(invalid("invalid selection tags"));
        }
        // Compatibility fields are never used as authority; native model
        // properties/execution are rebuilt from the matched entity.
        let _ = (&self.execution, &self.properties);
        Ok(())
    }
    fn matches(&self, row: &Value) -> bool {
        self.name.as_deref().is_none_or(|s| row["name"] == s)
            && self.path.as_deref().is_none_or(|s| row["path"] == s)
            && self.tags.as_ref().is_none_or(|tags| {
                let expected: std::collections::BTreeSet<_> =
                    tags.iter().map(String::as_str).collect();
                let actual: std::collections::BTreeSet<_> = row["tags"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(Value::as_str)
                    .collect();
                actual == expected
            })
    }
}
fn match_entity(
    model: &Value,
    field: &str,
    selection: &Option<Selection>,
) -> Result<Option<Value>, String> {
    let Some(selection) = selection else {
        return Ok(None);
    };
    let rows = model[field]
        .as_array()
        .ok_or("plugin.build.modelReloadRequired")?;
    let mut matches = rows.iter().filter(|row| selection.matches(row));
    let row = matches.next().ok_or("plugin.build.invalidSelection")?;
    if matches.next().is_some() {
        return Err("plugin.build.invalidSelection".into());
    }
    Ok(Some(row.clone()))
}
pub(super) fn selection(context: &BuildModelContext, request: &Request) -> Result<Value, String> {
    let params = &request.parameters;
    if context.model_stale
        && [&params.project, &params.target, &params.model_task]
            .iter()
            .any(|s| s.is_some())
    {
        return Err("plugin.build.modelReloadRequired".into());
    }
    let model_task = match_entity(&context.model, "tasks", &params.model_task)?;
    let mut project = match_entity(&context.model, "projects", &params.project)?;
    let target = match_entity(&context.model, "targets", &params.target)?;
    if let Some(task) = &model_task {
        if task["execution"] != "task" || task["template"].as_str() != params.task.as_deref() {
            return Err("plugin.build.invalidSelection".into());
        }
        if project.is_none() {
            project = context.model["projects"]
                .as_array()
                .into_iter()
                .flatten()
                .find(|row| row["id"] == task["projectID"])
                .cloned();
        }
    }
    for row in [&target, &model_task].into_iter().flatten() {
        if !project
            .as_ref()
            .is_some_and(|p| p["id"] == row["projectID"])
        {
            return Err("plugin.build.invalidSelection".into());
        }
    }
    let id = |row: Option<Value>| row.and_then(|row| row["id"].as_str().map(str::to_string));
    Ok(
        json!({"kind":if request.method == "build.runTests" { "test" } else if request.method == "build.dependencies" { "dependencies" } else { "task" },
        "taskId":params.task,"projectId":id(project),"targetId":id(target),"modelTaskId":id(model_task),
        "suite":params.suite,"case":params.case,"userArguments":params.user_arguments}),
    )
}

struct Work {
    app: AppHandle,
    page: String,
    identity: BridgeIdentity,
    instance: String,
    request: Request,
    initial_package: super::super::super::build_registry::BuildPackageInput,
    operation: Mutex<Option<PageOperation>>,
    result: Mutex<Option<Value>>,
    preparing: AtomicBool,
    run_delivered: AtomicBool,
    executing: AtomicBool,
    request_closed: AtomicBool,
    terminal_delivered: AtomicBool,
    execution_settled: AtomicBool,
}
#[derive(Default)]
pub(super) struct Operations(
    Mutex<HashMap<String, Arc<Work>>>,
    Mutex<HashMap<String, (BridgeIdentity, Value)>>,
);
impl Operations {
    pub fn request_closed(&self, id: &str) {
        let mut rows = self.0.lock().expect("page build operations");
        if let Some(work) = rows.get(id) {
            work.request_closed.store(true, Ordering::Release);
            if !work.run_delivered.load(Ordering::Acquire) {
                if let Some(operation) = work.operation.lock().expect("page operation").as_ref() {
                    if !operation.finished() {
                        operation.revoke();
                    }
                }
                let unprepared = work.operation.lock().expect("page operation").is_none();
                if unprepared {
                    rows.remove(id);
                }
            }
        }
    }
    pub fn revoke_pages(&self, labels: &[String]) {
        for (id, work) in self.0.lock().expect("page build operations").iter() {
            if labels.contains(&work.page) {
                if let Some(operation) = work.operation.lock().expect("page operation").as_ref() {
                    operation.revoke();
                }
                let _ = work.app.emit_to(
                    &work.identity.host_label,
                    "plugin-web-build-revoked",
                    json!({"operationId":id}),
                );
            }
        }
        self.1
            .lock()
            .expect("page build notifications")
            .retain(|label, _| !labels.contains(label));
    }
    pub fn revoke_request(&self, id: &str) {
        if let Some(work) = self.0.lock().expect("page build operations").get(id) {
            if let Some(operation) = work.operation.lock().expect("page operation").as_ref() {
                operation.revoke();
            }
        }
    }
    fn insert(&self, id: &str, work: Arc<Work>) -> Result<(), String> {
        let mut rows = self.0.lock().expect("page build operations");
        rows.retain(|_, work| {
            !work.request_closed.load(Ordering::Acquire)
                || !work
                    .operation
                    .lock()
                    .expect("page operation")
                    .as_ref()
                    .is_some_and(PageOperation::finished)
        });
        if rows.len() >= MAX_HOST_REQUESTS
            || rows
                .values()
                .filter(|row| row.page == work.page && row.identity == work.identity)
                .count()
                >= MAX_PAGE_REQUESTS
        {
            return Err("plugin.build.busy".into());
        }
        if rows.contains_key(id) {
            return Err(invalid("workflow already inspected"));
        }
        rows.insert(id.into(), work);
        Ok(())
    }
    fn get(&self, id: &str, host: &str) -> Result<Arc<Work>, String> {
        self.0
            .lock()
            .expect("page build operations")
            .get(id)
            .filter(|work| work.identity.host_label == host)
            .cloned()
            .ok_or_else(forbidden)
    }
}
#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Phase {
    Inspect,
    Prepare,
    Execute,
    Finish,
    Cancel,
    StaticRefresh,
}

#[tauri::command]
pub async fn declarative_plugins_web_build_action(
    app: AppHandle,
    caller: WebviewWindow,
    operation_id: String,
    phase: Phase,
) -> Result<Value, String> {
    let host = caller.label().to_string();
    let result = dispatch(app.clone(), caller, operation_id.clone(), phase).await;
    if let Err(error) = &result {
        if let Ok(pending) = app
            .state::<WebPageHostState>()
            .builds
            .owned(&operation_id, &host)
        {
            pending.complete(Err(normalize_error(error.clone())));
        }
    }
    result
}
async fn dispatch(
    app: AppHandle,
    caller: WebviewWindow,
    operation_id: String,
    phase: Phase,
) -> Result<Value, String> {
    let state = app.state::<WebPageHostState>();
    if matches!(phase, Phase::Inspect) {
        let pending = state.builds.owned(&operation_id, caller.label())?;
        let BuildRequest::Workflow(request) = &pending.request else {
            return Err(invalid("not a workflow request"));
        };
        if request.method == "build.cancel" {
            let run = request.parameters.run.as_deref().expect("validated run");
            let work = state
                .builds
                .1
                 .0
                .lock()
                .expect("page build operations")
                .values()
                .find(|work| {
                    work.identity == pending.identity
                        && work.page == pending.page_label
                        && work
                            .operation
                            .lock()
                            .expect("page operation")
                            .as_ref()
                            .is_some_and(|op| op.id() == run)
                })
                .cloned()
                .ok_or_else(forbidden)?;
            let operation = work
                .operation
                .lock()
                .expect("page operation")
                .clone()
                .ok_or_else(forbidden)?;
            operation.cancel().await?;
            emit_cancelled(&work, &operation);
            with_page_owner(&state, &pending.page_label, &pending.identity, || {
                check_request(&app, &operation_id, &pending)?;
                pending.complete(Ok(json!({})));
                Ok(json!({"cancelled":true}))
            })
        } else {
            let (view, contexts) =
                read_view(app.clone(), operation_id.clone(), pending.clone(), false).await?;
            let instance = request
                .parameters
                .instance
                .as_deref()
                .expect("validated instance");
            let (row, context) = selected_context(&view, &contexts, instance)?;
            let native_selection = selection(&context, request)?;
            let work = Arc::new(Work {
                app: app.clone(),
                page: pending.page_label.clone(),
                identity: pending.identity.clone(),
                instance: instance.into(),
                request: request.clone(),
                initial_package: context.package,
                operation: Mutex::new(None),
                result: Mutex::new(None),
                preparing: AtomicBool::new(false),
                run_delivered: AtomicBool::new(false),
                executing: AtomicBool::new(false),
                request_closed: AtomicBool::new(false),
                terminal_delivered: AtomicBool::new(false),
                execution_settled: AtomicBool::new(false),
            });
            with_page_owner(&state, &pending.page_label, &pending.identity, || {
                check_request(&app, &operation_id, &pending)?;
                state.builds.1.insert(&operation_id, work)?;
                Ok(
                    json!({"pluginId":context.plugin_id,"buildSystemId":context.build_system_id,"root":context.root,
                    "workspaceRoot":context.workspace_root,"modelSource":row["modelSource"],"selection":native_selection}),
                )
            })
        }
    } else {
        let work = match state.builds.1.get(&operation_id, caller.label()) {
            Ok(work) => work,
            Err(_) if matches!(phase, Phase::Cancel) => {
                // A refused/unprepared request has no native process owner.
                // Retried host cleanup is idempotent; foreign IDs gain no effect.
                if let Ok(pending) = state.builds.owned(&operation_id, caller.label()) {
                    let _ = with_page_owner(&state, &pending.page_label, &pending.identity, || {
                        pending.complete(Err(bridge_error(
                            "requestCancelled",
                            "the page build operation was cancelled",
                        )));
                        Ok(())
                    });
                }
                return Ok(json!({}));
            }
            Err(error) => return Err(error),
        };
        let operation = work.operation.lock().expect("page operation").clone();
        if matches!(phase, Phase::Cancel) {
            if let Some(operation) = operation {
                operation.cancel().await?;
                emit_cancelled(&work, &operation);
            }
            if let Ok(pending) = state.builds.owned(&operation_id, caller.label()) {
                let _ = with_page_owner(&state, &work.page, &work.identity, || {
                    pending.complete(Err(bridge_error(
                        "requestCancelled",
                        "the page build operation was cancelled",
                    )));
                    Ok(())
                });
            }
            return Ok(json!({}));
        }
        let pending = state.builds.owned(&operation_id, caller.label());
        if !matches!(phase, Phase::Execute)
            || work.request.method == "build.refresh"
            || work.request.method == "build.dependencies"
        {
            let pending = pending.as_ref().map_err(|_| forbidden())?;
            with_page_owner(&state, &work.page, &work.identity, || {
                check_request(&app, &operation_id, pending)
            })?;
        } else {
            with_page_owner(&state, &work.page, &work.identity, || Ok(()))?;
        }
        match phase {
            Phase::Prepare => {
                if work.preparing.swap(true, Ordering::AcqRel) {
                    return Err("plugin.build.busy".into());
                }
                let pending = pending?;
                let (view, contexts) =
                    read_view(app.clone(), operation_id.clone(), pending.clone(), false).await?;
                let (_, context) = selected_context(&view, &contexts, &work.instance)?;
                if context.package != work.initial_package {
                    return Err("plugin.build.packageChanged".into());
                }
                let selection = selection(&context, &work.request)?;
                let (review, operation) = super::super::super::build::page::prepare(
                    app.clone(),
                    &context,
                    work.request.method(),
                    selection,
                )
                .await?;
                if operation.context().package != work.initial_package
                    || operation.context().generation != context.generation
                {
                    operation.revoke();
                    return Err("plugin.build.staleContext".into());
                }
                *work.operation.lock().expect("page operation") = Some(operation.clone());
                let valid = with_page_owner(&state, &work.page, &work.identity, || {
                    check_request(&app, &operation_id, &pending)
                });
                if let Err(error) = valid {
                    operation.revoke();
                    return Err(error);
                }
                Ok(review)
            }
            Phase::Execute => {
                let operation = operation.ok_or_else(|| invalid("prepare is required"))?;
                if work.executing.swap(true, Ordering::AcqRel) {
                    return Err("plugin.build.busy".into());
                }
                with_page_owner(&state, &work.page, &work.identity, || {
                    if let Ok(pending) = &pending {
                        check_request(&app, &operation_id, pending)?;
                    }
                    if matches!(work.request.method(), "build.runTask" | "build.runTests") {
                        emit_run(&work, &operation, "running", None)?;
                        work.run_delivered.store(true, Ordering::Release);
                        pending
                            .as_ref()
                            .map_err(|_| forbidden())?
                            .complete(Ok(json!({"run":operation.id()})));
                    }
                    Ok(())
                })?;
                let result = operation.execute(work.request.method()).await;
                if matches!(work.request.method(), "build.runTask" | "build.runTests") {
                    match &result {
                        Ok(value) => emit_terminal(
                            &work,
                            &operation,
                            match value["kind"].as_str() {
                                Some("succeeded") => "succeeded",
                                Some("cancelled") => "cancelled",
                                _ => "failed",
                            },
                            value["exitCode"].as_i64(),
                        ),
                        Err(_) if operation.finished() => emit_terminal(
                            &work,
                            &operation,
                            if operation.cancelled() {
                                "cancelled"
                            } else {
                                "failed"
                            },
                            None,
                        ),
                        // Cleanup failure retains the owner. Stop retry publishes
                        // cancellation only after native proves the tree exited.
                        Err(_) => {}
                    }
                }
                work.execution_settled.store(true, Ordering::Release);
                let result = result?;
                *work.result.lock().expect("page workflow result") = Some(result.clone());
                Ok(result)
            }
            Phase::StaticRefresh => {
                if work.request.method != "build.refresh" {
                    return Err(invalid("only refresh can reload a passive model"));
                }
                let pending = pending?;
                let checkpoint = app.clone();
                let owned = work.clone();
                let id = operation_id.clone();
                let view = run_build_task(app.clone(), move |registry, source, _| {
                    with_page_owner(
                        &checkpoint.state::<WebPageHostState>(),
                        &owned.page,
                        &owned.identity,
                        || {
                            check_request(&checkpoint, &id, &pending)?;
                            if source.package(&owned.identity.plugin_id).as_ref()
                                != Some(&owned.initial_package)
                            {
                                return Err("plugin.build.packageChanged".into());
                            }
                            let (view, contexts) = checked_view(registry, source, &owned.identity)?;
                            let (row, context) =
                                selected_context(&view, &contexts, &owned.instance)?;
                            if !matches!(
                                row["modelSource"].as_str(),
                                Some("static" | "hostIntegration")
                            ) {
                                return Err("plugin.build.unavailable".into());
                            }
                            super::super::super::build::page::refresh_passive(
                                registry, source, &context,
                            )
                        },
                    )
                })
                .await?;
                *work.result.lock().expect("page workflow result") = Some(json!({"view":view}));
                Ok(serde_json::to_value(view).map_err(|e| e.to_string())?)
            }
            Phase::Finish => {
                let pending = pending?;
                let result = work
                    .result
                    .lock()
                    .expect("page workflow result")
                    .clone()
                    .ok_or_else(|| invalid("native work has not completed"))?;
                let final_app = app.clone();
                let owned = work.clone();
                let id = operation_id.clone();
                run_build_task(app.clone(), move |registry, source, _| {
                    with_page_owner(
                        &final_app.state::<WebPageHostState>(),
                        &owned.page,
                        &owned.identity,
                        || {
                            check_request(&final_app, &id, &pending)?;
                            let (view, _) = checked_view(registry, source, &owned.identity)?;
                            if source.package(&owned.identity.plugin_id).as_ref()
                                != Some(&owned.initial_package)
                            {
                                return Err("plugin.build.packageChanged".into());
                            }
                            let value = if owned.request.method == "build.refresh" {
                                json!({})
                            } else {
                                if result["terminal"]["kind"] != "succeeded" {
                                    return Err("plugin.build.unavailable".into());
                                }
                                dependency_result(&result)?
                            };
                            if owned.request.method == "build.refresh" {
                                if result["view"]["generation"].as_u64() != Some(view.generation)
                                    || result["view"]["instances"].as_array().and_then(|rows| {
                                        rows.iter().find(|row| {
                                            instance_id(row).as_deref() == Some(&owned.instance)
                                        })
                                    }) != view.instances.iter().find(|row| {
                                        instance_id(row).as_deref() == Some(&owned.instance)
                                    })
                                {
                                    return Err("plugin.build.staleContext".into());
                                }
                            } else if let Some(operation) =
                                owned.operation.lock().expect("page operation").as_ref()
                            {
                                if !registry.context_is_current(operation.context()) {
                                    return Err("plugin.build.staleContext".into());
                                }
                            }
                            pending.complete(Ok(value));
                            Ok(json!({}))
                        },
                    )
                })
                .await
            }
            _ => Err(invalid("invalid workflow phase")),
        }
    }
}
fn emit_cancelled(work: &Work, operation: &PageOperation) {
    if work.run_delivered.load(Ordering::Acquire) && work.execution_settled.load(Ordering::Acquire)
    {
        emit_terminal(work, operation, "cancelled", None);
    }
}

/// The web contract returns Core's complete decoded tree, including its
/// selected project path. Do not rebuild it from presentation-only fields.
pub(super) fn dependency_result(result: &Value) -> Result<Value, String> {
    let tree = &result["dependencyTree"];
    if !tree["project"].is_string()
        || !tree["dependencies"].is_array()
        || !tree["truncated"].is_boolean()
    {
        return Err("plugin.build.invalidOutput".into());
    }
    Ok(tree.clone())
}
fn emit_terminal(work: &Work, operation: &PageOperation, status: &str, exit: Option<i64>) {
    let state = work.app.state::<WebPageHostState>();
    let result = with_page_owner(&state, &work.page, &work.identity, || {
        if work.terminal_delivered.swap(true, Ordering::AcqRel) {
            return Ok(());
        }
        emit_run(work, operation, status, exit)
    });
    if let Err(error) = result {
        eprintln!("page run notification was discarded: {error}");
    }
}
fn emit_run(
    work: &Work,
    operation: &PageOperation,
    state: &str,
    exit: Option<i64>,
) -> Result<(), String> {
    let mut payload = json!({"run":operation.id(),"instance":work.instance,"state":state});
    if let Some(code) = exit {
        payload["exitCode"] = json!(code);
    }
    work.app
        .get_webview_window(&work.page)
        .ok_or_else(forbidden)?
        .eval(format!(
            "if(window.__lithePageGeneration === {}) window.__litheDeliverEvent?.('build.runChanged', {payload});", work.identity.generation
        ))
        .map_err(|e| e.to_string())
}

/// Suspension completion queues a final read after the registry barrier drops.
pub(crate) fn queue_instance_changes(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        let result = run_build_task(app, |_, _, _| Ok(())).await;
        if let Err(error) = result {
            eprintln!("page instances notification was discarded: {error}");
        }
    });
}

/// Observe the same registry after native or page edits, model loads and sync.
/// Deduplicate page payloads, and hold page ownership through final delivery.
pub(crate) fn publish_instance_changes(
    app: &AppHandle,
    registry: &BuildRegistry,
    source: &dyn BuildPackageSource,
) {
    let state = app.state::<WebPageHostState>();
    let owners = state.owners.lock().expect("page owners");
    let mut previous = state.builds.1 .1.lock().expect("page build notifications");
    for (label, owner) in owners.iter() {
        if owner.workspace_generation
            != super::super::workspace_generation(&state, &owner.host_label, &owner.workspace_id)
        {
            continue;
        }
        let identity = BridgeIdentity {
            generation: owner.generation,
            workspace_generation: owner.workspace_generation,
            plugin_id: owner.plugin_id.clone(),
            window_id: owner.window_id.clone(),
            host_label: owner.host_label.clone(),
            workspace_id: owner.workspace_id.clone(),
            workspace_path: owner.workspace_path.clone(),
            state_id: owner.state_id.clone(),
        };
        let payload = instances_json(&registry.view(&owner.host_label), &owner.plugin_id);
        if previous.get(label) == Some(&(identity.clone(), payload.clone())) {
            continue;
        }
        if checked_view(registry, source, &identity).is_err() {
            continue;
        }
        if let Some(page) = app.get_webview_window(label) {
            match page.eval(format!("if(window.__lithePageGeneration === {}) window.__litheDeliverEvent?.('build.instancesChanged', {payload});", owner.generation)) {
                Ok(()) => { previous.insert(label.clone(), (identity, payload)); },
                Err(error) => eprintln!("page instances notification was discarded: {error}"),
            }
        }
    }
}
