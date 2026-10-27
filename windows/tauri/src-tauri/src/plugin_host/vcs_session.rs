//! One native owner per typed VCS request. Core owns framing,
//! negotiation, reply validation and the process tree; failed disposal retains
//! the same package lease and can be retried through the native request ID.
use super::registry::{Root, Scope};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

pub(super) const CLEANUP_FAILED: &str = "vcs.provider.cleanupFailed";
pub(super) const CANCELLED: &str = "requestCancelled";
pub(super) type Reply = Result<Value, String>;

pub(super) trait Runtime: Send + Sync {
    fn execute(&self, command: &str, payload: Value) -> Reply;
    fn start(&self, payload: Value, registered: &dyn Fn(&str)) -> Reply;
}
pub(super) struct CoreRuntime;
impl Runtime for CoreRuntime {
    fn execute(&self, command: &str, payload: Value) -> Reply {
        super::super::scan::core_execute(command, payload)
    }
    fn start(&self, payload: Value, registered: &dyn Fn(&str)) -> Reply {
        lithe_core::start_lsp_owned(payload, registered).map_err(|_| "vcs.provider.failed".into())
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Context {
    pub host: String,
    pub scope: Scope,
    pub generation: u64,
    pub registration: u64,
    pub request_id: String,
    pub root: Root,
    pub root_identity: String,
    pub plugin_id: String,
    pub package_identity: String,
    pub settings_revision: u64,
}
impl Context {
    pub fn settings_scope(&self, host: &str, workspace: &str, plugin: &str) -> bool {
        self.host == host && self.scope.workspace_root == workspace && self.plugin_id == plugin
    }
}
#[derive(Default)]
struct State {
    session: Option<String>,
    launch_finished: bool,
    disposal_running: bool,
    disposed: bool,
    tool: Option<String>,
    capabilities: Value,
    mutation: bool,
    write_attempted: bool,
    write_answered: bool,
}
pub(super) struct Owner {
    pub context: Context,
    pub revoked: AtomicBool,
    state: Mutex<State>,
    stopping: tokio::sync::Mutex<()>,
    lease: Mutex<Option<super::super::lifecycle::NativeLease>>,
    registry: Mutex<Weak<Mutex<Entries>>>,
    runtime: Arc<dyn Runtime>,
}
impl Owner {
    pub fn new(context: Context, lease: super::super::lifecycle::NativeLease) -> Arc<Self> {
        Arc::new(Self {
            context,
            revoked: AtomicBool::new(false),
            state: Mutex::new(State {
                launch_finished: true,
                ..State::default()
            }),
            stopping: Default::default(),
            lease: Mutex::new(Some(lease)),
            registry: Mutex::new(Weak::new()),
            runtime: Arc::new(CoreRuntime),
        })
    }
    pub fn revoke(&self) {
        self.revoked.store(true, Ordering::Release);
    }
    pub fn current(&self) -> Result<(), String> {
        if self.revoked.load(Ordering::Acquire) {
            Err(CANCELLED.into())
        } else {
            Ok(())
        }
    }
    pub fn session(&self) -> Option<String> {
        self.state.lock().expect("VCS session").session.clone()
    }
    fn cleanup_later(self: &Arc<Self>) {
        if self.revoked.load(Ordering::Acquire) {
            let registry = self.registry.lock().expect("VCS registry").upgrade();
            if let Some(registry) = registry {
                super::status::cleanup_later(Arc::new(Sessions(registry)), self.clone());
            }
        }
    }
    /// Register before Core's first process write. A cancelled/failed launch
    /// remains reachable even if the blocking worker returns after its waiter.
    pub async fn start(
        self: &Arc<Self>,
        resolve: impl FnOnce() -> Result<(Value, Option<String>), String> + Send + 'static,
    ) -> Result<(), String> {
        self.state.lock().expect("VCS session").launch_finished = false;
        let owner = self.clone();
        tokio::time::timeout(
            Duration::from_secs(15),
            tauri::async_runtime::spawn_blocking(move || {
                struct Finished(Arc<Owner>);
                impl Drop for Finished {
                    fn drop(&mut self) {
                        self.0.state.lock().expect("VCS session").launch_finished = true;
                        // A window's last cleanup may have timed out while the
                        // native launcher was blocked. Its completion owns a
                        // fresh bounded cleanup even after that window is gone.
                        self.0.cleanup_later();
                    }
                }
                let _finished = Finished(owner.clone());
                owner.current()?;
                let (payload, tool) = resolve()?;
                owner.current()?;
                owner.state.lock().expect("VCS session").tool = tool;
                let result = owner.runtime.start(payload, &|id| {
                    owner.state.lock().expect("VCS session").session = Some(id.into());
                })?;
                if result["sessionId"].as_str() != owner.session().as_deref() {
                    return Err("invalidResponse".into());
                }
                owner.current()
            }),
        )
        .await
        .map_err(|_| "requestTimeout")?
        .map_err(|_| "internalError")?
    }
    async fn call(self: &Arc<Self>, command: &'static str, payload: Value) -> Reply {
        let owner = self.clone();
        tokio::time::timeout(
            Duration::from_secs(5),
            tauri::async_runtime::spawn_blocking(move || owner.runtime.execute(command, payload)),
        )
        .await
        .map_err(|_| "requestTimeout")?
        .map_err(|_| "internalError")?
    }
    async fn destroy(self: &Arc<Self>, session: String) -> Reply {
        {
            let mut state = self.state.lock().expect("VCS session");
            if state.disposed {
                return Ok(json!({}));
            }
            if state.disposal_running {
                return Err(CLEANUP_FAILED.into());
            }
            state.disposal_running = true;
        }
        let owner = self.clone();
        tokio::time::timeout(
            Duration::from_secs(5),
            tauri::async_runtime::spawn_blocking(move || {
                struct Finished {
                    owner: Arc<Owner>,
                    session: String,
                    succeeded: bool,
                }
                impl Drop for Finished {
                    fn drop(&mut self) {
                        let mut state = self.owner.state.lock().expect("VCS session");
                        let same = state.session.as_deref() == Some(self.session.as_str());
                        if same {
                            state.disposal_running = false;
                            // Core removes a successfully destroyed session.
                            // Preserve this proof in the original owner before
                            // its timed-out waiter can retry an unknown session.
                            state.disposed |= self.succeeded;
                        }
                        drop(state);
                        if same && self.succeeded {
                            self.owner.cleanup_later();
                        }
                    }
                }
                let mut finished = Finished {
                    owner: owner.clone(),
                    session: session.clone(),
                    succeeded: false,
                };
                let result = owner
                    .runtime
                    .execute("lsp.destroyServer", json!({"sessionId":session}));
                finished.succeeded = result.is_ok();
                result
            }),
        )
        .await
        .map_err(|_| "requestTimeout")?
        .map_err(|_| "internalError")?
    }
    async fn events(self: &Arc<Self>) -> Result<Vec<Value>, String> {
        self.current()?;
        let session = self.session().ok_or("vcs.provider.failed")?;
        let reply = self
            .call(
                "lsp.waitEvents",
                json!({"sessionId":session,"timeoutMilliseconds":250}),
            )
            .await?;
        self.current()?;
        reply["events"]
            .as_array()
            .cloned()
            .ok_or_else(|| "invalidResponse".into())
    }
    #[cfg(test)]
    pub async fn status(self: &Arc<Self>, current: impl Fn() -> Result<(), String>) -> Reply {
        self.read(&super::query::ReadOperation::Status, current)
            .await
    }
    pub fn mark_mutation(&self) {
        self.state.lock().expect("VCS session").mutation = true;
    }
    pub fn capabilities(&self) -> Value {
        self.state.lock().expect("VCS session").capabilities.clone()
    }
    pub fn uncertain(&self) -> bool {
        let state = self.state.lock().expect("VCS session");
        state.write_attempted && !state.write_answered
    }
    pub async fn read(
        self: &Arc<Self>,
        operation: &super::query::ReadOperation,
        current: impl Fn() -> Result<(), String>,
    ) -> Reply {
        operation.validate()?;
        tokio::time::timeout(Duration::from_secs(45), async {
            let session = self.session().ok_or("vcs.provider.failed")?;
            let mut negotiation = None;
            let mut ready = false;
            while !ready {
                current()?;
                for event in self.events().await? {
                    if event["sessionId"] != session {
                        continue;
                    }
                    match event["type"].as_str() {
                        Some("vcsProvider") => {
                            negotiation = Some(negotiated(&event, &self.context.root.vcs)?)
                        }
                        Some("stateChanged") if event["state"] == "ready" => ready = true,
                        Some("stateChanged")
                            if matches!(
                                event["state"].as_str(),
                                Some("failed" | "stopped" | "stopping")
                            ) =>
                        {
                            return Err(failure(&event))
                        }
                        _ => {}
                    }
                }
            }
            self.state.lock().expect("VCS session").capabilities =
                negotiation.ok_or("vcs.provider.unavailable")?;
            self.request(
                operation.name(),
                operation.arguments(),
                false,
                || Ok(()),
                current,
            )
            .await
        })
        .await
        .map_err(|_| "requestTimeout")?
    }
    pub async fn write(
        self: &Arc<Self>,
        operation: &super::actions::WriteOperation,
        preflight: impl FnOnce() -> Result<(), String> + Send + 'static,
        current: impl Fn() -> Result<(), String>,
    ) -> Reply {
        tokio::time::timeout(
            Duration::from_secs(615),
            self.request(
                operation.request_name(),
                operation.arguments(),
                true,
                preflight,
                current,
            ),
        )
        .await
        .map_err(|_| "requestTimeout")?
    }
    async fn request(
        self: &Arc<Self>,
        name: &'static str,
        arguments: Value,
        write: bool,
        preflight: impl FnOnce() -> Result<(), String> + Send + 'static,
        current: impl Fn() -> Result<(), String>,
    ) -> Reply {
        let capabilities = self.capabilities();
        let capability = match name {
            "resolve" => "conflicts",
            "fileOperation" => "fileOperations",
            _ => name,
        };
        if capabilities[capability] != 1 {
            return Err("vcs.capability.unsupported".into());
        }
        current()?;
        self.current()?;
        let session = self.session().ok_or("vcs.provider.failed")?;
        let tool = self.state.lock().expect("VCS session").tool.clone();
        // Status and mutation use distinct Core operation IDs in the same short
        // session. A late status completion cannot acknowledge the write.
        let id = if write {
            format!("{}-write", self.context.request_id)
        } else {
            self.context.request_id.clone()
        };
        let payload = json!({"sessionId":session,"operationId":id,
            "vcs":self.context.root.vcs,"operation":name,"root":self.context.root.path,
            "tool":tool,"arguments":arguments,"timeoutMilliseconds":if write {600000} else {30000}});
        let owner = self.clone();
        tokio::time::timeout(
            Duration::from_secs(15),
            tauri::async_runtime::spawn_blocking(move || {
                preflight()?;
                owner.current()?;
                if write {
                    let mut state = owner.state.lock().expect("VCS session");
                    // No retry path may ever dispatch this owner's write twice.
                    if state.write_attempted {
                        return Err("requestCancelled".into());
                    }
                    state.write_attempted = true;
                }
                owner.runtime.execute("lsp.vcsRequest", payload)
            }),
        )
        .await
        .map_err(|_| "requestTimeout")?
        .map_err(|_| "internalError")??;
        loop {
            current()?;
            for event in self.events().await? {
                if event["sessionId"] != session {
                    continue;
                }
                if event["type"] == "stateChanged"
                    && matches!(
                        event["state"].as_str(),
                        Some("failed" | "stopped" | "stopping")
                    )
                {
                    return Err(failure(&event));
                }
                if event["type"] != "requestCompleted" || event["operationId"] != id {
                    continue;
                }
                let value = match completed(&event) {
                    Ok(value) => value,
                    Err(error) => {
                        // A provider failure is a known failure. Transport loss,
                        // cancellation and invalid replies can hide side effects.
                        if write
                            && (event["error"]["code"] == "vcs.provider.failed"
                                || !matches!(
                                    error.as_str(),
                                    "requestTimeout"
                                        | "requestCancelled"
                                        | "plugin.vcs.invalidOutput"
                                        | "vcs.provider.failed"
                                ))
                        {
                            self.state.lock().expect("VCS session").write_answered = true;
                        }
                        return Err(error);
                    }
                };
                let decoded = self
                    .call(
                        "vcs.decodeReply",
                        json!({"operation":name,"capabilities":capabilities,
                    "request":arguments,"reply":value}),
                    )
                    .await?;
                if decoded["status"] != "ok" {
                    return Err("plugin.vcs.invalidOutput".into());
                }
                let result = decoded.get("result").cloned().ok_or("invalidResponse")?;
                current()?;
                self.current()?;
                if write {
                    self.state.lock().expect("VCS session").write_answered = true;
                }
                return Ok(result);
            }
        }
    }
    /// Success is proof that both the launch worker and Core's owned process
    /// tree have ended. Neither a timeout nor a frontend cancellation is proof.
    pub async fn stop(self: &Arc<Self>) -> Result<(), String> {
        self.revoke();
        let _lock = tokio::time::timeout(Duration::from_secs(12), self.stopping.lock())
            .await
            .map_err(|_| CLEANUP_FAILED)?;
        tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                if self.dispose_once().await {
                    self.lease.lock().expect("VCS lease").take();
                    return Ok(());
                }
                tokio::time::sleep(Duration::from_millis(25)).await;
            }
        })
        .await
        .map_err(|_| CLEANUP_FAILED)?
    }
    async fn dispose_once(self: &Arc<Self>) -> bool {
        let (session, finished, disposed, running) = {
            let state = self.state.lock().expect("VCS session");
            (
                state.session.clone(),
                state.launch_finished,
                state.disposed,
                state.disposal_running,
            )
        };
        if !disposed {
            if let Some(session) = session {
                if running {
                    return false;
                }
                let _ = self
                    .call("lsp.stopServer", json!({"sessionId":session}))
                    .await;
                if self.destroy(session).await.is_err() {
                    return false;
                }
            } else if !finished {
                return false;
            }
        }
        finished
    }
}

pub(super) fn negotiated(event: &Value, vcs: &str) -> Reply {
    if event["type"] != "vcsProvider" || event["result"]["vcs"] != vcs {
        return Err("vcs.provider.unavailable".into());
    }
    event["result"]
        .get("capabilities")
        .filter(|value| value.is_object())
        .cloned()
        .ok_or_else(|| "invalidResponse".into())
}
fn completed(event: &Value) -> Reply {
    if !event["error"].is_null() {
        return Err(failure(event));
    }
    event["result"]
        .get("value")
        .cloned()
        .ok_or_else(|| "plugin.vcs.invalidOutput".into())
}
fn failure(event: &Value) -> String {
    match event["error"]["code"].as_str().unwrap_or_default() {
        "initializeTimeout" | "requestTimeout" => "requestTimeout",
        "requestCancelled" => CANCELLED,
        code @ ("vcs.authentication.failed"
        | "vcs.conflict"
        | "vcs.outOfDate"
        | "vcs.tool.unavailable"
        | "vcs.workingCopy.locked"
        | "vcs.workingCopy.unsupported"
        | "plugin.vcs.invalidOutput") => code,
        _ => "vcs.provider.failed",
    }
    .into()
}

#[derive(Default)]
struct Entries {
    running: HashMap<(String, String), Arc<Owner>>,
    cancelled: HashSet<(String, String)>,
}
#[derive(Default)]
pub(super) struct Sessions(Arc<Mutex<Entries>>);
impl Sessions {
    pub fn insert(&self, owner: Arc<Owner>, active: impl FnOnce() -> bool) -> Result<(), String> {
        let mut entries = self.0.lock().expect("VCS owners");
        if !active()
            || entries
                .cancelled
                .contains(&(owner.context.host.clone(), owner.context.request_id.clone()))
        {
            return Err(CANCELLED.into());
        }
        if entries.running.len() >= 64 {
            return Err("requestLimitExceeded".into());
        }
        let context = &owner.context;
        if entries.running.values().any(|old| {
            (old.context.host == context.host
                && (old.context.request_id == context.request_id
                    || old.context.root.path == context.root.path))
                || old.context.root.path == context.root.path
                    && (old.state.lock().expect("VCS session").mutation
                        || owner.state.lock().expect("VCS session").mutation)
        }) {
            return Err(CLEANUP_FAILED.into());
        }
        *owner.registry.lock().expect("VCS registry") = Arc::downgrade(&self.0);
        entries
            .running
            .insert((context.host.clone(), context.request_id.clone()), owner);
        Ok(())
    }
    pub fn get(&self, host: &str, scope: &Scope, id: &str) -> Result<Option<Arc<Owner>>, String> {
        let mut entries = self.0.lock().expect("VCS owners");
        let key = (host.into(), id.into());
        let owner = entries.running.get(&key).cloned();
        if owner
            .as_ref()
            .is_some_and(|owner| owner.context.scope != *scope)
        {
            return Err(CANCELLED.into());
        }
        // Cancellation may beat a slow package/settings read. A later prepare
        // cannot publish that request after Stop already acknowledged it.
        if !entries.cancelled.contains(&key) && entries.cancelled.len() >= 4096 {
            return Err("requestLimitExceeded".into());
        }
        entries.cancelled.insert(key);
        Ok(owner)
    }
    pub fn cancelled(&self, context: &Context) -> bool {
        self.0
            .lock()
            .expect("VCS owners")
            .cancelled
            .contains(&(context.host.clone(), context.request_id.clone()))
    }
    pub fn matching(&self, predicate: impl Fn(&Context) -> bool) -> Vec<Arc<Owner>> {
        self.0
            .lock()
            .expect("VCS owners")
            .running
            .values()
            .filter(|owner| predicate(&owner.context))
            .map(|owner| {
                owner.revoke();
                owner.clone()
            })
            .collect()
    }
    pub fn private_session(&self, command: &str, payload: &Value) -> bool {
        command == "lsp.vcsRequest"
            || command == "lsp.startServer"
                && payload["providerId"]
                    .as_str()
                    .is_some_and(|id| id.starts_with("vcsProvider:"))
            || command.starts_with("lsp.")
                && self
                    .0
                    .lock()
                    .expect("VCS owners")
                    .running
                    .values()
                    .any(|owner| {
                        owner.session().as_deref() == payload["sessionId"].as_str()
                            && owner.session().is_some()
                    })
    }
    pub async fn cleanup(&self, owner: Arc<Owner>) -> Result<(), String> {
        owner.stop().await?;
        let key = (owner.context.host.clone(), owner.context.request_id.clone());
        let mut entries = self.0.lock().expect("VCS owners");
        if entries
            .running
            .get(&key)
            .is_some_and(|entry| Arc::ptr_eq(entry, &owner))
        {
            entries.running.remove(&key);
        }
        Ok(())
    }
}

#[cfg(test)]
#[path = "vcs_session_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "vcs_session_core_tests.rs"]
mod core_tests;
