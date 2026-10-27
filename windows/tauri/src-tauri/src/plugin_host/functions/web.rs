//! Page-owned functions bridge. Page call IDs are only local correlation keys;
//! every Core operation gets a fresh native ID and the R10 owner does all
//! process, negotiation, result and cleanup work.
use super::*;
use crate::plugin_host::web::{bridge_error, with_page_owner, BridgeIdentity, WebPageHostState};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter};
use tokio::sync::Notify;

const MAX_PAGE_CALLS: usize = 16;
const MAX_TOTAL_CALLS: usize = 128;
const MAX_CALL_IDS: usize = 4096;
const CALL_TIMEOUT: Duration = Duration::from_secs(180);
const MAX_RESULT_BYTES: usize = 1024 * 1024;
static NEXT_OPERATION: AtomicU64 = AtomicU64::new(1);

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Parameters {
    #[serde(default)]
    instance: Option<String>,
    #[serde(default)]
    function: Option<String>,
    #[serde(default)]
    params: Option<Value>,
    #[serde(default)]
    call: Option<String>,
}

struct Pending {
    operation_id: String,
    call: Option<String>,
    page_label: String,
    identity: BridgeIdentity,
    package_identity: String,
    instance: String,
    function: Option<String>,
    params: Value,
    list: bool,
    cancelled: AtomicBool,
    failure: Mutex<Option<Error>>,
    deadline: Instant,
    changed: Notify,
}
impl Pending {
    fn cancel(&self) {
        self.finish(None);
    }
    fn finish(&self, failure: Option<Error>) {
        // Cancellation and refusal are competing terminal events. Keep the
        // first event under one lock, including its optional backend code.
        let mut outcome = self.failure.lock().expect("web function failure");
        if !self.cancelled.load(Ordering::Acquire) {
            *outcome = failure;
            self.cancelled.store(true, Ordering::Release);
        }
        drop(outcome);
        self.changed.notify_waiters();
    }
    fn check(&self, app: &AppHandle) -> Result<(), String> {
        self.check_outcome()?;
        if app
            .state::<super::super::lifecycle::LifecycleState>()
            .blocked(&self.identity.plugin_id)
        {
            return Err(bridge_error("plugin.web.forbidden", "plugin was revoked"));
        }
        with_page_owner(
            &app.state::<WebPageHostState>(),
            &self.page_label,
            &self.identity,
            || Ok(()),
        )
    }
    fn verify_package(&self, app: &AppHandle) -> Result<(), String> {
        self.check(app)?;
        let current_package = super::super::settings::read_snapshot(
            app,
            &self.identity.plugin_id,
            &self.identity.workspace_path,
        )
        .map_err(|_| bridge_error("plugin.web.forbidden", "package identity is unavailable"))?
        .package_identity;
        if current_package != self.package_identity {
            return Err(bridge_error("plugin.web.forbidden", "package was replaced"));
        }
        Ok(())
    }
    fn check_outcome(&self) -> Result<(), String> {
        let outcome = self.failure.lock().expect("web function failure");
        if let Some(error) = outcome.as_ref() {
            return Err(serde_json::to_string(error).expect("function error"));
        }
        if self.cancelled.load(Ordering::Acquire) {
            return Err(bridge_error("requestCancelled", "requestCancelled"));
        }
        if Instant::now() >= self.deadline {
            return Err(bridge_error("requestTimeout", "requestTimeout"));
        }
        Ok(())
    }
}

#[derive(Default)]
pub(crate) struct Calls(Mutex<Ledger>);
#[derive(Default)]
struct Ledger {
    pending: HashMap<String, Arc<Pending>>,
    used: HashMap<(String, u64), HashSet<String>>,
}
impl Calls {
    fn for_host(&self, operation_id: &str, host: &str) -> Option<Arc<Pending>> {
        self.0
            .lock()
            .expect("web function ledger")
            .pending
            .get(operation_id)
            .filter(|pending| pending.identity.host_label == host)
            .cloned()
    }
    pub(super) fn cancel_for_host(
        &self,
        operation_id: &str,
        host: &str,
        failure: Option<Error>,
    ) -> bool {
        let Some(pending) = self.for_host(operation_id, host) else {
            return false;
        };
        let failure = failure.map(|mut error| {
            error.code = error.code.chars().take(128).collect();
            error.message = error.message.chars().take(1024).collect();
            error.plugin_error_code = error
                .plugin_error_code
                .map(|code| code.chars().take(128).collect());
            error
        });
        pending.finish(failure);
        true
    }
    pub(crate) fn active(&self, operation_id: &str, page_label: &str) -> bool {
        self.0
            .lock()
            .expect("web function ledger")
            .pending
            .get(operation_id)
            .is_some_and(|pending| {
                pending.page_label == page_label && !pending.cancelled.load(Ordering::Acquire)
            })
    }
    fn admit(&self, pending: Arc<Pending>) -> Result<(), String> {
        let mut ledger = self.0.lock().expect("web function ledger");
        ledger
            .pending
            .retain(|_, pending| !pending.cancelled.load(Ordering::Acquire));
        let page_count = ledger
            .pending
            .values()
            .filter(|entry| {
                entry.page_label == pending.page_label
                    && entry.identity.generation == pending.identity.generation
            })
            .count();
        if ledger.pending.len() >= MAX_TOTAL_CALLS || page_count >= MAX_PAGE_CALLS {
            return Err(bridge_error("plugin.function.busy", "plugin.function.busy"));
        }
        if let Some(call) = &pending.call {
            let used = ledger
                .used
                .entry((pending.page_label.clone(), pending.identity.generation))
                .or_default();
            if used.len() >= MAX_CALL_IDS || !used.insert(call.clone()) {
                return Err(bridge_error(
                    "plugin.web.invalidRequest",
                    "call ID was already used",
                ));
            }
        }
        ledger.pending.insert(pending.operation_id.clone(), pending);
        Ok(())
    }
    fn remove(&self, operation_id: &str) {
        self.0
            .lock()
            .expect("web function ledger")
            .pending
            .remove(operation_id);
    }
    fn cancel_call(&self, page: &str, generation: u64, call: &str) -> Option<Arc<Pending>> {
        let ledger = self.0.lock().expect("web function ledger");
        let pending = ledger
            .pending
            .values()
            .find(|pending| {
                pending.page_label == page
                    && pending.identity.generation == generation
                    && pending.call.as_deref() == Some(call)
            })?
            .clone();
        pending.cancel();
        Some(pending)
    }
    pub(crate) fn revoke_pages(&self, labels: &[String]) {
        let mut ledger = self.0.lock().expect("web function ledger");
        for pending in ledger
            .pending
            .values()
            .filter(|pending| labels.contains(&pending.page_label))
        {
            pending.cancel();
        }
        ledger.used.retain(|(page, _), _| !labels.contains(page));
    }
}

pub(super) fn confirm(app: &AppHandle, entry: &Arc<Operation>, host: &str) -> Reply<()> {
    let state = app.state::<WebPageHostState>();
    let id = &entry.review.context.operation_id;
    let pending = state
        .functions
        .for_host(id, host)
        .ok_or_else(|| Error::new("requestCancelled"))?;
    pending
        .verify_package(app)
        .map_err(|error| Error::core(&serde_json::from_str(&error).unwrap_or(Value::Null)))?;
    // Page revocation holds owners before the call ledger. Keep that lock order
    // and make the final live-receipt check atomic with the operation's start.
    with_page_owner(&state, &pending.page_label, &pending.identity, || {
        let ledger = state.functions.0.lock().expect("web function ledger");
        if !ledger
            .pending
            .get(id)
            .is_some_and(|current| Arc::ptr_eq(current, &pending))
        {
            return Err(bridge_error("requestCancelled", "requestCancelled"));
        }
        pending.check_outcome()?;
        entry
            .begin()
            .map_err(|error| serde_json::to_string(&error).expect("function error"))
    })
    .map_err(|error| Error::core(&serde_json::from_str(&error).unwrap_or(Value::Null)))
}

fn page_result(list: bool, result: Value) -> Value {
    if list {
        json!({"functions": result})
    } else {
        json!({"value": result})
    }
}

pub(crate) async fn request(
    app: &AppHandle,
    page_label: &str,
    identity: BridgeIdentity,
    method: &str,
    value: Value,
) -> Result<Value, String> {
    let parameters: Parameters = serde_json::from_value(value)
        .map_err(|_| bridge_error("plugin.web.invalidRequest", "invalid function parameters"))?;
    if parameters
        .call
        .as_ref()
        .is_some_and(|call| call.is_empty() || call.len() > 128 || call.contains('\0'))
        || parameters.instance.as_ref().is_some_and(|instance| {
            instance.is_empty() || instance.len() > 1024 || instance.contains('\0')
        })
        || parameters.function.as_ref().is_some_and(|function| {
            function.is_empty() || function.len() > 128 || function.contains('\0')
        })
        || serde_json::to_vec(&parameters.params)
            .map(|bytes| bytes.len() > 64 * 1024)
            .unwrap_or(true)
    {
        return Err(bridge_error(
            "plugin.web.invalidRequest",
            "invalid function parameters",
        ));
    }
    if method == "functions.cancel" {
        let call = parameters.call.as_deref().ok_or_else(|| {
            bridge_error(
                "plugin.web.invalidRequest",
                "functions.cancel requires call",
            )
        })?;
        let pending = app.state::<WebPageHostState>().functions.cancel_call(
            page_label,
            identity.generation,
            call,
        );
        if let Some(pending) = pending {
            let _ = app.emit_to(
                &pending.identity.host_label,
                "plugin-web-function-cancelled",
                json!({ "operationId": pending.operation_id }),
            );
        }
        return Ok(json!({}));
    }
    let instance = parameters.instance.clone().ok_or_else(|| {
        bridge_error(
            "plugin.function.unavailable",
            "plugin backend functions are unavailable",
        )
    })?;
    let list = method == "functions.list";
    if (method != "functions.list" && method != "functions.invoke")
        || (list && (parameters.function.is_some() || parameters.params.is_some()))
        || (!list
            && parameters
                .function
                .as_ref()
                .is_none_or(|function| function.is_empty()))
        || parameters
            .params
            .as_ref()
            .is_some_and(|params| !params.is_object())
    {
        return Err(bridge_error(
            "plugin.web.invalidRequest",
            "invalid function parameters",
        ));
    }
    let operation_id = format!(
        "web-function-{}",
        NEXT_OPERATION.fetch_add(1, Ordering::Relaxed)
    );
    let package_identity =
        super::super::settings::read_snapshot(app, &identity.plugin_id, &identity.workspace_path)
            .map_err(|_| bridge_error("plugin.web.forbidden", "package identity is unavailable"))?
            .package_identity;
    let pending = Arc::new(Pending {
        operation_id: operation_id.clone(),
        call: parameters.call.clone(),
        page_label: page_label.into(),
        identity,
        package_identity,
        instance,
        function: parameters.function,
        params: parameters.params.unwrap_or_else(|| json!({})),
        list,
        cancelled: AtomicBool::new(false),
        failure: Mutex::new(None),
        deadline: Instant::now() + CALL_TIMEOUT,
        changed: Notify::new(),
    });
    let state = app.state::<WebPageHostState>();
    with_page_owner(&state, page_label, &pending.identity, || {
        state.functions.admit(pending.clone())
    })?;
    if let Err(error) = app.emit_to(
        &pending.identity.host_label,
        "plugin-web-function-request",
        json!({
            "operationId": pending.operation_id,
            "call": pending.call,
            "pageLabel": pending.page_label,
            "pageGeneration": pending.identity.generation,
            "hostLabel": pending.identity.host_label,
            "pluginId": pending.identity.plugin_id,
            "workspaceId": pending.identity.workspace_id,
            "workspacePath": pending.identity.workspace_path,
            "instance": pending.instance,
            "function": pending.function,
            "params": pending.params,
            "list": pending.list,
        }),
    ) {
        state.functions.remove(&pending.operation_id);
        return Err(bridge_error(
            "plugin.function.unavailable",
            error.to_string(),
        ));
    }
    let outcome = wait_for_result(app, pending.clone()).await;
    pending.cancel();
    // Dismiss an approval even when native timeout or page revocation wins.
    let _ = app.emit_to(
        &pending.identity.host_label,
        "plugin-web-function-cancelled",
        json!({"operationId": pending.operation_id}),
    );
    if outcome.is_err() {
        if let Ok(entry) =
            super::operation(app, &pending.identity.host_label, &pending.operation_id)
        {
            entry.cancel();
            if let Err(error) = super::runtime::cleanup(&entry).await {
                let _ = app.emit_to(
                    &pending.identity.host_label,
                    "plugin-web-function-cleanup-failed",
                    json!({ "operationId": pending.operation_id, "context": entry.review.context, "error": error }),
                );
            } else {
                super::remove_clean(app, &entry);
            }
        }
    }
    state.functions.remove(&pending.operation_id);
    outcome
}

async fn wait_for_result(app: &AppHandle, pending: Arc<Pending>) -> Result<Value, String> {
    let mut last_progress = Value::Null;
    loop {
        pending.check(app)?;
        if let Ok(entry) =
            super::operation(app, &pending.identity.host_label, &pending.operation_id)
        {
            let snapshot = entry.snapshot();
            if let (Some(call), Some(progress)) = (&pending.call, snapshot.progress.clone()) {
                if progress != last_progress {
                    pending.check(app)?;
                    if let Some(page) = app.get_webview_window(&pending.page_label) {
                        let payload = json!({
                            "call": call,
                            "instance": pending.instance,
                            "function": pending.function,
                            "message": progress["message"],
                            "percentage": progress["percentage"],
                        });
                        page.eval(format!(
                            "if(window.__lithePageGeneration==={})window.__litheDeliverEvent?.('functions.progress',{});",
                            pending.identity.generation,
                            payload
                        ))
                        .map_err(|error| error.to_string())?;
                    }
                    last_progress = progress;
                }
            }
            if matches!(
                snapshot.phase,
                Phase::Succeeded | Phase::Failed | Phase::Cancelled | Phase::CleanupFailed
            ) {
                pending.verify_package(app)?;
                let cleanup = super::runtime::cleanup(&entry).await;
                super::remove_clean(app, &entry);
                cleanup.map_err(|error| serde_json::to_string(&error).expect("function error"))?;
                if snapshot.phase == Phase::Succeeded {
                    let result = snapshot.result.unwrap_or(Value::Null);
                    if serde_json::to_vec(&result)
                        .map_err(|_| "invalid result".to_string())?
                        .len()
                        > MAX_RESULT_BYTES
                    {
                        return Err(bridge_error(
                            "plugin.function.resultTooLarge",
                            "result is too large",
                        ));
                    }
                    return Ok(page_result(pending.list, result));
                }
                if snapshot.phase == Phase::Cancelled {
                    return Err(bridge_error("requestCancelled", "requestCancelled"));
                }
                return Err(serde_json::to_string(
                    &snapshot
                        .error
                        .unwrap_or_else(|| Error::new("plugin.function.failed")),
                )
                .expect("function error"));
            }
        }
        tokio::select! {
            _ = pending.changed.notified() => {},
            _ = tokio::time::sleep(Duration::from_millis(100)) => {},
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn identity(page: &str, generation: u64) -> BridgeIdentity {
        BridgeIdentity {
            generation,
            workspace_generation: 1,
            plugin_id: "example.plugin".into(),
            window_id: page.into(),
            host_label: "main".into(),
            workspace_id: "workspace".into(),
            workspace_path: "C:/fixture/project".into(),
            state_id: page.into(),
        }
    }

    fn pending(page: &str, generation: u64, call: &str) -> Arc<Pending> {
        Arc::new(Pending {
            operation_id: format!("op-{page}-{call}"),
            call: Some(call.into()),
            page_label: page.into(),
            identity: identity(page, generation),
            package_identity: "package-bytes".into(),
            instance: "mix@root".into(),
            function: Some("snapshot.refresh".into()),
            params: json!({}),
            list: false,
            cancelled: AtomicBool::new(false),
            failure: Mutex::new(None),
            deadline: Instant::now() + CALL_TIMEOUT,
            changed: Notify::new(),
        })
    }

    #[test]
    fn page_call_ids_are_unique_within_one_page_incarnation() {
        let calls = Calls::default();
        calls.admit(pending("page", 1, "call")).unwrap();
        assert!(calls.admit(pending("page", 1, "call")).is_err());
        assert!(calls.admit(pending("page", 2, "call")).is_ok());
    }

    #[test]
    fn page_revocation_cancels_calls_and_releases_call_id_budget() {
        let calls = Calls::default();
        let entry = pending("page", 1, "call");
        calls.admit(entry.clone()).unwrap();
        calls.revoke_pages(&["page".into()]);
        assert!(entry.cancelled.load(Ordering::Acquire));
        assert!(calls.admit(pending("page", 2, "call")).is_ok());
    }

    #[test]
    fn cancel_while_waiting_for_approval_makes_late_prepare_inert() {
        let calls = Calls::default();
        let entry = pending("page", 1, "waiting");
        calls.admit(entry.clone()).unwrap();
        calls.cancel_call("page", 1, "waiting");
        assert!(!calls.active(&entry.operation_id, "page"));
        assert!(entry.cancelled.load(Ordering::Acquire));
    }

    #[test]
    fn per_page_concurrency_is_bounded_without_affecting_another_page() {
        let calls = Calls::default();
        for index in 0..MAX_PAGE_CALLS {
            calls
                .admit(pending("page", 1, &format!("call-{index}")))
                .unwrap();
        }
        assert!(calls.admit(pending("page", 1, "overflow")).is_err());
        assert!(calls.admit(pending("other-page", 1, "call")).is_ok());
    }

    #[test]
    fn host_approval_resolves_the_registered_page_and_refusal_finishes_before_prepare() {
        let calls = Calls::default();
        let entry = pending("plugin-page", 4, "call");
        calls.admit(entry.clone()).unwrap();
        assert!(calls.for_host(&entry.operation_id, "main").is_some());
        assert!(calls.for_host(&entry.operation_id, "plugin-page").is_none());
        assert!(!calls.cancel_for_host(&entry.operation_id, "other-workbench", None));
        assert!(entry.check_outcome().is_ok());
        let error = Error {
            code: "plugin.function.failed".into(),
            message: "backend rejected".into(),
            plugin_error_code: Some("fixture.refused".into()),
        };
        assert!(calls.cancel_for_host(&entry.operation_id, "main", Some(error)));
        let result: Value = serde_json::from_str(&entry.check_outcome().unwrap_err()).unwrap();
        assert_eq!(result["code"], "plugin.function.failed");
        assert_eq!(result["pluginErrorCode"], "fixture.refused");
        assert!(!calls.active(&entry.operation_id, "plugin-page"));
    }

    #[test]
    fn page_success_uses_the_shared_list_and_invoke_envelopes() {
        assert_eq!(
            page_result(true, json!(["snapshot.refresh"])),
            json!({"functions":["snapshot.refresh"]})
        );
        assert_eq!(
            page_result(false, json!({"answer":42})),
            json!({"value":{"answer":42}})
        );
        assert_eq!(page_result(false, Value::Null), json!({"value":null}));
    }

    #[test]
    fn the_first_cancellation_or_refusal_keeps_its_terminal_code() {
        let calls = Calls::default();
        let cancelled = pending("page", 1, "cancel-first");
        calls.admit(cancelled.clone()).unwrap();
        calls.cancel_call("page", 1, "cancel-first");
        let refusal = Error {
            code: "plugin.function.failed".into(),
            message: "backend refused".into(),
            plugin_error_code: Some("fixture.refused".into()),
        };
        calls.cancel_for_host(&cancelled.operation_id, "main", Some(refusal.clone()));
        let outcome: Value = serde_json::from_str(&cancelled.check_outcome().unwrap_err()).unwrap();
        assert_eq!(outcome["code"], "requestCancelled");

        let refused = pending("page", 1, "refusal-first");
        calls.admit(refused.clone()).unwrap();
        calls.cancel_for_host(&refused.operation_id, "main", Some(refusal));
        calls.cancel_call("page", 1, "refusal-first");
        let outcome: Value = serde_json::from_str(&refused.check_outcome().unwrap_err()).unwrap();
        assert_eq!(outcome["code"], "plugin.function.failed");
        assert_eq!(outcome["pluginErrorCode"], "fixture.refused");
    }
}
