//! Isolated action owner around Core's transport. Unknown destroy outcomes
//! retain their original join handle; retry never sends a duplicate destroy.
use super::{check, check_context, Error, ReceiptOwner, Reply, Review, WindowOwner};
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;
use tauri::AppHandle;
use tokio::sync::Notify;

pub(super) trait Core: Send + Sync {
    fn execute(&self, command: &str, payload: Value) -> Reply<Value>;
    fn start(&self, payload: Value, registered: &dyn Fn(&str)) -> Reply<Value>;
}
struct HostCore;
impl Core for HostCore {
    fn execute(&self, command: &str, payload: Value) -> Reply<Value> {
        let reply: Value = serde_json::from_str(&lithe_core::execute_json(
            &json!({"command":command,"payload":payload}).to_string(),
        ))
        .map_err(|_| Error::new("plugin.function.invalidResult"))?;
        if reply["ok"] == true {
            Ok(reply["data"].clone())
        } else {
            Err(Error::core(&reply["error"]))
        }
    }
    fn start(&self, payload: Value, registered: &dyn Fn(&str)) -> Reply<Value> {
        lithe_core::start_lsp_owned(payload, registered).map_err(|error| Error::core(&json!(error)))
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Phase {
    Review,
    Starting,
    Running,
    Succeeded,
    Failed,
    Cancelled,
    CleanupFailed,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub context: super::Context,
    pub phase: Phase,
    pub progress: Option<Value>,
    pub result: Option<Value>,
    pub error: Option<Error>,
}
pub(super) struct Status {
    pub phase: Phase,
    pub session: Option<String>,
    pub launch_finished: bool,
    launch_panicked: bool,
    pub destroyed: bool,
    destroy_uncertain: bool,
    pub progress: Option<Value>,
    pub result: Option<Value>,
    pub error: Option<Error>,
}
pub(super) struct Operation {
    pub(super) native: Mutex<Option<super::native::Call>>,
    pub review: Review,
    pub(super) owner: Arc<WindowOwner>,
    pub(super) scope_revision: u64,
    params: Mutex<Value>,
    directory: PathBuf,
    pub status: Mutex<Status>,
    cancelled: AtomicBool,
    retire_requested: AtomicBool,
    registry: Mutex<Option<CleanupRegistry>>,
    changed: Notify,
    cleanup_lock: tokio::sync::Mutex<()>,
    destroy_job: tokio::sync::Mutex<Option<tauri::async_runtime::JoinHandle<Reply<Value>>>>,
    pub(super) core: Arc<dyn Core>,
    lease: Mutex<Option<super::super::lifecycle::NativeLease>>,
}
struct CleanupRegistry {
    operations: Weak<Mutex<HashMap<String, Arc<Operation>>>>,
    retired: Weak<Mutex<HashMap<String, ReceiptOwner>>>,
}
impl Operation {
    pub fn new(
        review: Review,
        directory: PathBuf,
        lease: super::super::lifecycle::NativeLease,
        owner: Arc<WindowOwner>,
    ) -> Self {
        Self {
            native: Mutex::new(None),
            review,
            owner,
            scope_revision: 0,
            params: Mutex::new(json!({})),
            directory,
            status: Mutex::new(Status {
                phase: Phase::Review,
                session: None,
                launch_finished: true,
                launch_panicked: false,
                destroyed: false,
                destroy_uncertain: false,
                progress: None,
                result: None,
                error: None,
            }),
            cancelled: AtomicBool::new(false),
            retire_requested: AtomicBool::new(false),
            registry: Mutex::new(None),
            changed: Notify::new(),
            cleanup_lock: Default::default(),
            destroy_job: Default::default(),
            core: Arc::new(HostCore),
            lease: Mutex::new(Some(lease)),
        }
    }
    pub fn phase(&self) -> Phase {
        self.status.lock().expect("function state").phase
    }
    pub fn cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Acquire)
    }
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
        self.changed.notify_waiters();
    }
    pub fn clean(&self) -> bool {
        let status = self.status.lock().expect("function state");
        status.launch_finished
            && (status.destroyed || (status.session.is_none() && !status.launch_panicked))
    }
    pub fn begin(&self) -> Reply<()> {
        let mut status = self.status.lock().expect("function state");
        if self.cancelled() || status.phase != Phase::Review {
            return Err(Error::new("plugin.function.staleContext"));
        }
        status.phase = Phase::Starting;
        status.launch_finished = false;
        Ok(())
    }
    pub fn snapshot(&self) -> Snapshot {
        let status = self.status.lock().expect("function state");
        Snapshot {
            context: self.review.context.clone(),
            phase: status.phase,
            progress: status.progress.clone(),
            result: status.result.clone(),
            error: status.error.clone(),
        }
    }
    pub fn set_params(&self, params: Value) {
        *self.params.lock().expect("function parameters") = params;
    }
    fn params(&self) -> Value {
        self.params.lock().expect("function parameters").clone()
    }
    pub(super) fn bind_registry(
        &self,
        operations: &Arc<Mutex<HashMap<String, Arc<Operation>>>>,
        retired: &Arc<Mutex<HashMap<String, ReceiptOwner>>>,
    ) {
        *self.registry.lock().expect("function cleanup registry") = Some(CleanupRegistry {
            operations: Arc::downgrade(operations),
            retired: Arc::downgrade(retired),
        });
    }
    pub(super) fn retire_clean(self: &Arc<Self>) {
        if !self.retire_requested.load(Ordering::Acquire) || !self.clean() {
            return;
        }
        let registry = self.registry.lock().expect("function cleanup registry");
        let Some((operations, retired)) = registry.as_ref().and_then(|registry| {
            Some((registry.operations.upgrade()?, registry.retired.upgrade()?))
        }) else {
            return;
        };
        let mut operations = operations.lock().expect("function operations");
        let id = &self.review.context.operation_id;
        if operations
            .get(id)
            .is_some_and(|current| Arc::ptr_eq(current, self))
        {
            if !self.review.context.action_id.starts_with("__web__:") {
                let mut retired = retired.lock().expect("retired function operations");
                if self.owner.alive.load(Ordering::Acquire) {
                    retired.insert(
                        id.clone(),
                        ReceiptOwner {
                            window: self.review.context.window.clone(),
                            incarnation: self.owner.id,
                        },
                    );
                }
            }
            operations.remove(id);
            super::native::release(self);
        }
    }
    fn cleanup_after_completion(self: &Arc<Self>) {
        if !self.cancelled() {
            return;
        }
        // A destroyed window has no UI left to retry an expired cleanup.
        // Launch and successful disposal completions each own one bounded
        // follow-up; known failures still retain the lease for explicit retry.
        let entry = self.clone();
        tauri::async_runtime::spawn(async move {
            if cleanup_inner(&entry, Duration::from_secs(8)).await.is_ok() {
                entry.retire_clean();
                entry.changed.notify_waiters();
            }
        });
    }
    fn complete_launch(self: &Arc<Self>, outcome: std::thread::Result<Reply<Value>>) {
        let mut state = self.status.lock().expect("function state");
        state.launch_finished = true;
        let result = outcome.unwrap_or_else(|_| {
            // A panic before the owned-registration callback is not proof
            // that Core never created a process. Keep the package lease.
            state.launch_panicked = true;
            Err(Error::new("plugin.function.workerFailed"))
        });
        if let Err(error) = result {
            state.error = Some(error);
        }
        drop(state);
        self.changed.notify_waiters();
        self.cleanup_after_completion();
    }
}

async fn call(entry: &Arc<Operation>, command: &'static str, payload: Value) -> Reply<Value> {
    let core = entry.core.clone();
    tokio::time::timeout(
        Duration::from_secs(5),
        tauri::async_runtime::spawn_blocking(move || core.execute(command, payload)),
    )
    .await
    .map_err(|_| Error::new("plugin.function.transportTimeout"))?
    .map_err(|_| Error::new("plugin.function.workerFailed"))?
}

async fn verify(app: &AppHandle, entry: &Arc<Operation>) -> Reply<()> {
    let app = app.clone();
    let entry = entry.clone();
    tokio::time::timeout(
        Duration::from_secs(5),
        tauri::async_runtime::spawn_blocking(move || check(&app, &entry)),
    )
    .await
    .map_err(|_| Error::new("plugin.function.timeout"))?
    .map_err(|_| Error::new("plugin.function.workerFailed"))?
}
pub(super) async fn cleanup(entry: &Arc<Operation>) -> Reply<()> {
    entry.retire_requested.store(true, Ordering::Release);
    cleanup_with_budget(entry, Duration::from_secs(8)).await
}
pub(super) async fn cleanup_with_budget(entry: &Arc<Operation>, budget: Duration) -> Reply<()> {
    entry.cancel();
    let outcome = cleanup_inner(entry, budget).await;
    if let Err(error) = &outcome {
        let mut state = entry.status.lock().expect("function state");
        state.phase = Phase::CleanupFailed;
        state.error = Some(error.clone());
    }
    outcome
}
async fn cleanup_inner(entry: &Arc<Operation>, budget: Duration) -> Reply<()> {
    let _serial = tokio::time::timeout(Duration::from_secs(12), entry.cleanup_lock.lock())
        .await
        .map_err(|_| Error::new("plugin.function.cleanupFailed"))?;
    let deadline = tokio::time::Instant::now() + budget;
    loop {
        let changed = entry.changed.notified();
        tokio::pin!(changed);
        changed.as_mut().enable();
        let (session, destroyed, finished, launch_panicked, destroy_uncertain) = {
            let state = entry.status.lock().expect("function state");
            (
                state.session.clone(),
                state.destroyed,
                state.launch_finished,
                state.launch_panicked,
                state.destroy_uncertain,
            )
        };
        if destroy_uncertain || (finished && session.is_none() && launch_panicked) {
            return Err(Error::new("plugin.function.cleanupFailed"));
        }
        if let Some(session) = session.filter(|_| !destroyed) {
            let mut job = entry.destroy_job.lock().await;
            if job.is_none() {
                let core = entry.core.clone();
                let operation = entry.review.context.operation_id.clone();
                let owner = entry.clone();
                *job = Some(tauri::async_runtime::spawn_blocking(move || {
                    let _ = core.execute(
                        "lsp.cancelOperation",
                        json!({"sessionId":session,"operationId":operation}),
                    );
                    core.execute("lsp.stopServer", json!({"sessionId":session}))?;
                    let result = core.execute("lsp.destroyServer", json!({"sessionId":session}));
                    if result.is_ok() {
                        // Store success before the timed-out waiter can lose
                        // this non-idempotent Core session's completion proof.
                        owner.status.lock().expect("function state").destroyed = true;
                        owner.changed.notify_waiters();
                        owner.cleanup_after_completion();
                    }
                    result
                }));
            }
            match tokio::time::timeout_at(deadline, job.as_mut().expect("owned destroy")).await {
                Ok(result) => {
                    *job = None;
                    result
                        .map_err(|_| {
                            // A panicked destroy worker has an unknown outcome;
                            // replaying destroy could target an already removed ID.
                            entry
                                .status
                                .lock()
                                .expect("function state")
                                .destroy_uncertain = true;
                            Error::new("plugin.function.cleanupFailed")
                        })?
                        .map_err(|_| Error::new("plugin.function.cleanupFailed"))?;
                    entry.status.lock().expect("function state").destroyed = true;
                    entry.changed.notify_waiters();
                }
                Err(_) => return Err(Error::new("plugin.function.cleanupFailed")),
            }
            continue;
        }
        if finished {
            entry.lease.lock().expect("function lease").take();
            return Ok(());
        }
        tokio::time::timeout_at(deadline, &mut changed)
            .await
            .map_err(|_| Error::new("plugin.function.cleanupFailed"))?;
    }
}

fn launch_payload(entry: &Operation) -> Reply<Value> {
    let context = &entry.review.context;
    let program = &entry.review.program;
    let mut environment: std::collections::BTreeMap<String, String> = std::env::vars().collect();
    super::super::launch::merge_environment(&mut environment, program.environment.clone());
    Ok(
        json!({"providerId":format!("settingsAction:{}:{}",context.plugin_id,context.operation_id),"pluginId":context.plugin_id,
        "executablePath":program.server_path,"arguments":program.server_args,"environment":environment,
        "workingDirectory":context.workspace_path,"rootUri":url::Url::from_directory_path(&context.workspace_path).map_err(|_|Error::new("plugin.function.staleContext"))?.as_str(),
        "initializationOptions":program.initialization_options,"workspaceConfiguration":program.workspace_configuration,
        "hostServices":[],"initializeTimeoutMilliseconds":10000,"requestTimeoutMilliseconds":30000,"shutdownTimeoutMilliseconds":2000}),
    )
}

pub(super) async fn run(app: AppHandle, entry: Arc<Operation>) {
    let worker = entry.clone();
    let worker_app = app.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            check(&worker_app, &worker)?;
            let plan = &worker.review.launch_plan;
            let workspace = worker
                .directory
                .join(super::super::store::workspace_state_key(
                    &worker.review.context.workspace_path,
                ));
            super::super::launch::prepare_required_directories(plan, &worker.directory, &workspace)
                .map_err(|_| Error::new("plugin.function.startFailed"))?;
            std::fs::create_dir_all(&worker.directory)
                .map_err(|_| Error::new("plugin.function.startFailed"))?;
            super::super::launch::validate_resolved_launch_checked(
                plan,
                &worker.review.program,
                &worker.directory,
                || check_context(&worker_app, &worker).map_err(|error| error.code),
            )
            .map_err(|_| Error::new("plugin.function.startFailed"))?;
            check(&worker_app, &worker)?;
            worker.core.start(launch_payload(&worker)?, &|id| {
                worker.status.lock().expect("function state").session = Some(id.into());
                worker.changed.notify_waiters();
            })
        }));
        worker.complete_launch(outcome);
    });
    let result = tokio::time::timeout(Duration::from_secs(180), invoke(&app, &entry))
        .await
        .unwrap_or_else(|_| Err(Error::new("plugin.function.timeout")));
    let was_cancelled = entry.cancelled();
    // Keep a completed action readable until its UI consumes the result.
    if cleanup_with_budget(&entry, Duration::from_secs(8))
        .await
        .is_ok()
    {
        let mut state = entry.status.lock().expect("function state");
        match result {
            Ok(value) if !was_cancelled => {
                state.result = Some(value);
                state.phase = Phase::Succeeded;
                state.error = None;
            }
            _ if was_cancelled => {
                state.phase = Phase::Cancelled;
                state.error = None;
            }
            Err(error) => {
                state.phase = Phase::Failed;
                state.error = Some(error);
            }
            _ => {
                state.phase = Phase::Cancelled;
            }
        }
    }
}

async fn invoke(app: &AppHandle, entry: &Arc<Operation>) -> Reply<Value> {
    let mut ready = false;
    let mut negotiated = false;
    let mut functions = None;
    let mut dispatched = false;
    loop {
        check_context(app, entry)?;
        let (session, finished, error) = {
            let state = entry.status.lock().expect("function state");
            (
                state.session.clone(),
                state.launch_finished,
                state.error.clone(),
            )
        };
        if let Some(error) = error {
            return Err(error);
        }
        if let Some(session) = session {
            let events = call(
                entry,
                "lsp.waitEvents",
                json!({"sessionId":session,"timeoutMilliseconds":250}),
            )
            .await?;
            for event in events["events"].as_array().into_iter().flatten() {
                if event["sessionId"] != session {
                    continue;
                }
                match event["type"].as_str() {
                    Some("stateChanged") if event["state"] == "ready" => ready = true,
                    Some("stateChanged")
                        if matches!(
                            event["state"].as_str(),
                            Some("failed" | "stopping" | "stopped")
                        ) =>
                    {
                        return Err(Error::new("plugin.function.sessionEnded"))
                    }
                    Some("functionsChanged") => {
                        functions = Some(event["result"]["functions"].clone())
                    }
                    Some("featuresChanged") => {
                        negotiated = event["capabilities"].as_array().is_some_and(|features| {
                            features.iter().any(|feature| feature == "litheFunctions")
                        });
                        if !negotiated {
                            return Err(Error::new("plugin.function.unavailable"));
                        }
                    }
                    Some("hostRequest") => {
                        call(entry,"lsp.hostResponse",json!({"sessionId":session,"hostRequestID":event["result"]["hostRequestID"],"error":{"message":"plugin.host.unavailable"}})).await?;
                    }
                    Some("requestProgress")
                        if dispatched
                            && event["operationId"] == entry.review.context.operation_id =>
                    {
                        check_context(app, entry)?;
                        entry.status.lock().expect("function state").progress =
                            Some(event["result"].clone());
                    }
                    Some("requestCompleted")
                        if dispatched
                            && event["operationId"] == entry.review.context.operation_id =>
                    {
                        verify(app, entry).await?;
                        if !event["error"].is_null() {
                            return Err(Error::core(&event["error"]));
                        }
                        let value = event["result"]
                            .get("value")
                            .cloned()
                            .ok_or_else(|| Error::new("plugin.function.invalidResult"))?;
                        return super::native::result(entry, value);
                    }
                    _ => {}
                }
            }
            if ready && finished && negotiated && functions.is_some() && !dispatched {
                let functions = functions.as_ref().expect("function registry");
                if entry.review.context.function_id.is_empty() {
                    return Ok(functions.clone());
                }
                if !functions.as_array().is_some_and(|items| {
                    items
                        .iter()
                        .any(|id| id == &entry.review.context.function_id)
                }) {
                    return Err(Error::new("plugin.function.unknown"));
                }
                verify(app, entry).await?;
                call(entry,"lsp.functionRequest",json!({"sessionId":session,"operationId":entry.review.context.operation_id,
                    "function":{"pluginID":entry.review.context.plugin_id,"functionID":entry.review.context.function_id},"params":entry.params(),"timeoutMilliseconds":120000})).await?;
                dispatched = true;
                entry.status.lock().expect("function state").phase = Phase::Running;
            }
        } else if finished {
            return Err(Error::new("plugin.function.startFailed"));
        } else {
            tokio::select! { _=entry.changed.notified()=>{}, _=tokio::time::sleep(Duration::from_millis(50))=>{} }
        }
    }
}

#[cfg(test)]
mod tests;
