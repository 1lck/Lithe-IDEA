//! Engine side of the cross-plugin function relay: it owns the relay's
//! state, carries out the actions `function_relay` returns, and connects the
//! relay to live sessions.
//!
//! Two sessions are involved in every call (the caller's and the callee's),
//! and a callee may call back into another plugin while serving, so a session
//! thread must never write to a second session itself: two sessions doing that
//! to each other would each wait for the other's write lock. Every effect on
//! a session therefore goes through the relay's threads, which hold no session
//! lock while they wait. The relay's own lock is a leaf: sessions may take it
//! while holding their locks, and it never takes a session lock while held.
//!
//! The main worker only plans: it decides which action comes next and which
//! session it concerns, but it never writes. Each session has its own lane, a
//! thread that performs the writes to that session in order. A backend that
//! stops reading its stdin therefore stalls only its own lane, and the write
//! is bounded by the session's request timeout (`bounded_relay_write`), after
//! which the session fails and its process is killed. One such backend cannot
//! hold up the calls of other plugins.

use super::super::function_relay::{
    CallParent, CalleeOutcome, DispatchPlan, FunctionRelay, RelayAction, RelayFailure,
    RelayRequest, RelaySnapshot, OPERATION_PREFIX,
};
use super::super::plugin_function::{
    bounded_host_message, codes, host_rpc_code, FunctionReference, FUNCTIONS_INVOKE,
    FUNCTIONS_PROVIDERS, INVOKE_METHOD,
};
use super::{
    json_rpc_error_with_data, json_rpc_result, push_negotiated_provider_event, LspLifecycleState,
    LspRuntimeError, PluginFunctionRequest, RuntimeSession, SessionState,
};
use crate::protocol::{CoreError, ErrorCode};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::sync::{mpsc, Arc, Mutex, MutexGuard, PoisonError, Weak};
use std::thread;
use std::time::{Duration, Instant};

type SessionMap = Mutex<BTreeMap<String, Arc<RuntimeSession>>>;

/// The relay's state plus the queue of work for its worker thread.
pub(super) struct RelayHub {
    relay: Mutex<FunctionRelay>,
    actions: Mutex<mpsc::Sender<RelayAction>>,
}

impl RelayHub {
    /// Creates the hub and its worker. The worker holds only weak references,
    /// so it ends once the engine and its sessions are gone.
    pub(super) fn start(sessions: &Arc<SessionMap>) -> Arc<Self> {
        let (sender, receiver) = mpsc::channel();
        let hub = Arc::new(Self {
            relay: Mutex::new(FunctionRelay::default()),
            actions: Mutex::new(sender),
        });
        let worker_hub = Arc::downgrade(&hub);
        let worker_sessions = Arc::downgrade(sessions);
        thread::spawn(move || run_worker(worker_hub, worker_sessions, receiver));
        hub
    }

    /// Replaces the plugin and workspace-context snapshot. Calls the new
    /// snapshot no longer allows end at once.
    pub(super) fn configure(&self, snapshot: RelaySnapshot) -> Result<(), CoreError> {
        let actions = self
            .lock()
            .configure(snapshot)
            .map_err(|message| CoreError::new(ErrorCode::InvalidRequest, message))?;
        self.send(actions);
        Ok(())
    }

    /// Answers one request a plugin backend made with `lithe/host/functions/*`.
    /// Returns the messages to write to that backend now; an admitted call
    /// has none, because its answer comes when the callee finishes.
    ///
    /// `state` is that backend's session state, which the caller already holds
    /// locked: it is how a call that names its parent is checked against the
    /// calls this backend is serving, without locking the session again.
    pub(super) fn answer_request(
        &self,
        session: &RuntimeSession,
        state: &SessionState,
        method: &str,
        request: &Value,
    ) -> Result<Vec<String>, CoreError> {
        let rpc_id = request.get("id").cloned().unwrap_or(Value::Null);
        let params = request.get("params").unwrap_or(&Value::Null);
        // Only a plugin's own session can negotiate the protocol, so a
        // session without a plugin should never get here.
        let Some(caller_plugin) = session.plugin_id.as_deref() else {
            let failure = RelayFailure::new(
                codes::HOST_UNAVAILABLE,
                "The host does not offer this method.",
            );
            return Ok(vec![reply_message(&rpc_id, &Err(failure))?]);
        };
        let outcome = match method {
            FUNCTIONS_PROVIDERS => self.providers(caller_plugin, params),
            FUNCTIONS_INVOKE => match self.admit(session, state, caller_plugin, &rpc_id, params) {
                Ok(()) => return Ok(Vec::new()),
                Err(failure) => Err(failure),
            },
            _ => Err(RelayFailure::new(
                codes::HOST_UNAVAILABLE,
                "The host does not offer this method.",
            )),
        };
        Ok(vec![reply_message(&rpc_id, &outcome)?])
    }

    fn providers(&self, caller_plugin: &str, params: &Value) -> Result<Value, RelayFailure> {
        let function_id = string_param(params, "functionID")?;
        self.lock().providers(caller_plugin, function_id)
    }

    fn admit(
        &self,
        session: &RuntimeSession,
        state: &SessionState,
        caller_plugin: &str,
        rpc_id: &Value,
        params: &Value,
    ) -> Result<(), RelayFailure> {
        let request = RelayRequest {
            caller_session: session.id.clone(),
            caller_plugin: caller_plugin.to_string(),
            rpc_id: rpc_id.clone(),
            callee_plugin: string_param(params, "pluginID")?.to_string(),
            function_id: string_param(params, "functionID")?.to_string(),
            params: params.get("params").cloned().unwrap_or_else(|| json!({})),
            context: params.get("context").cloned().unwrap_or(Value::Null),
            timeout: params
                .get("timeoutMilliseconds")
                .and_then(Value::as_u64)
                .map(Duration::from_millis),
            parent: call_parent(state, params),
        };
        let actions = self.lock().admit(request, Instant::now())?;
        self.send(actions);
        Ok(())
    }

    /// A callee session finished an operation. Calls that are not relayed
    /// are ignored.
    pub(super) fn callee_finished(
        &self,
        session_id: &str,
        operation_id: &str,
        outcome: CalleeOutcome,
    ) {
        let actions = self
            .lock()
            .callee_finished(session_id, operation_id, outcome);
        self.send(actions);
    }

    /// The calling plugin sent `$/cancelRequest`. Returns whether the request
    /// named a relayed call.
    pub(super) fn cancel_from_caller(&self, session_id: &str, rpc_id: &Value) -> bool {
        let Some(actions) = self.lock().cancel_from_caller(session_id, rpc_id) else {
            return false;
        };
        self.send(actions);
        true
    }

    /// A session stopped or failed.
    pub(super) fn session_ended(&self, session_id: &str) {
        let actions = self.lock().session_ended(session_id);
        self.send(actions);
    }

    /// A backend of the plugin became ready or registered functions.
    pub(super) fn provider_changed(&self, plugin_id: &str) {
        let actions = self.lock().provider_changed(plugin_id);
        self.send(actions);
    }

    /// Ends the calls that ran out of time without a running callee.
    pub(super) fn expire(&self, now: Instant) {
        let actions = self.lock().expire(now);
        self.send(actions);
    }

    fn lock(&self) -> MutexGuard<'_, FunctionRelay> {
        // The tables are plain data that every method leaves consistent
        // before it returns, so a panic elsewhere does not invalidate them.
        self.relay.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn send(&self, actions: Vec<RelayAction>) {
        if actions.is_empty() {
            return;
        }
        let sender = self.actions.lock().unwrap_or_else(PoisonError::into_inner);
        for action in actions {
            // log-exempt: A closed queue means the worker ended with the engine, so nothing is left to carry out the action.
            let _ = sender.send(action);
        }
    }

    /// Ends a call the relay admitted but could not write to its provider.
    fn dispatch_failed(&self, call_id: u64, failure: RelayFailure) {
        let actions = self.lock().dispatch_failed(call_id, failure);
        self.send(actions);
    }

    /// Carries out one action on the main worker. It plans only: every write
    /// to a session is handed to that session's lane, so this thread never
    /// waits on a backend's stdin.
    fn perform(&self, sessions: &SessionMap, lanes: &mut Lanes, action: RelayAction) {
        match action {
            RelayAction::Reply {
                session_id,
                rpc_id,
                outcome,
            } => {
                // The caller may have stopped meanwhile; the lane drops the
                // answer when nobody is left to receive it.
                lanes.post(sessions, &session_id, LaneWork::Reply { rpc_id, outcome });
            }
            RelayAction::CancelCallee {
                session_id,
                operation_id,
            } => {
                // The callee may already have finished the operation; the lane
                // ignores a cancel that finds nothing to cancel.
                lanes.post(sessions, &session_id, LaneWork::Cancel { operation_id });
            }
            RelayAction::Dispatch { call_id } => self.dispatch(sessions, lanes, call_id),
        }
    }

    /// Picks a ready backend of the callee plugin for one admitted call and
    /// hands the invoke to that backend's lane, or records that no backend
    /// exists yet.
    fn dispatch(&self, sessions: &SessionMap, lanes: &mut Lanes, call_id: u64) {
        let Some(plan) = self.lock().dispatch_plan(call_id, Instant::now()) else {
            return;
        };
        let Some(provider) = find_provider(
            sessions,
            &plan.caller_session,
            &plan.callee_plugin,
            &plan.function_id,
        ) else {
            self.wait_for_provider(sessions, call_id, &plan);
            return;
        };
        let operation_id = format!("{OPERATION_PREFIX}{call_id}");
        // Recorded before the request is posted, so an answer that arrives
        // at once still finds its call.
        if !self.lock().started(call_id, &provider.id, &operation_id) {
            return;
        }
        let milliseconds = u64::try_from(plan.remaining.as_millis()).unwrap_or(u64::MAX);
        let request = PluginFunctionRequest {
            session_id: provider.id.clone(),
            operation_id: Some(operation_id.clone()),
            function: FunctionReference {
                plugin_id: plan.callee_plugin,
                function_id: plan.function_id,
            },
            params: plan.params,
            timeout_milliseconds: Some(milliseconds),
            context: Some(plan.context),
        };
        // The provider's lane writes the request. If that write fails, the
        // lane ends the call.
        let work = LaneWork::Invoke {
            call_id,
            request,
            operation_id,
            caller_plugin: plan.caller_plugin,
        };
        lanes.post(sessions, &provider.id, work);
    }

    /// Parks the call until a backend is ready, and asks the host to start
    /// one the first time the call waits. Starting a process is the host's
    /// I/O; Core only says it is needed.
    fn wait_for_provider(&self, sessions: &SessionMap, call_id: u64, plan: &DispatchPlan) {
        let notice = self.lock().wait_for_provider(call_id, Instant::now());
        if let Some(notice) = notice {
            if let Some(session) = find_session(sessions, &notice.caller_session) {
                session.announce_provider_start_required(&notice.callee_plugin);
            }
        }
        // A backend may have become ready between the search and the wait,
        // and its announcement found no waiting call. Look once more.
        let provider_appeared = find_provider(
            sessions,
            &plan.caller_session,
            &plan.callee_plugin,
            &plan.function_id,
        )
        .is_some();
        if provider_appeared {
            self.provider_changed(&plan.callee_plugin);
        }
    }
}

/// Plans relay actions in order until the engine is gone. The worker owns the
/// lanes, so its own thread is never the one that writes to a backend.
fn run_worker(
    hub: Weak<RelayHub>,
    sessions: Weak<SessionMap>,
    actions: mpsc::Receiver<RelayAction>,
) {
    let mut lanes = Lanes::new(hub.clone(), sessions.clone());
    for action in actions {
        let (Some(hub), Some(sessions)) = (hub.upgrade(), sessions.upgrade()) else {
            return;
        };
        hub.perform(&sessions, &mut lanes, action);
    }
}

/// Work the main relay worker hands to one session's lane. The lane performs
/// it in the order it arrived, because later work may depend on earlier work:
/// a cancel follows the invoke it cancels.
enum LaneWork {
    /// Answer a `lithe/host/functions/*` request that this session's plugin
    /// backend made.
    Reply {
        rpc_id: Value,
        outcome: Result<Value, RelayFailure>,
    },
    /// Cancel one relayed call this session is serving.
    Cancel { operation_id: String },
    /// Write one admitted call to this session, the provider that serves it.
    Invoke {
        /// The relay's ID of the call, to end it if the write fails.
        call_id: u64,
        request: PluginFunctionRequest,
        /// The callee-side operation ID the relay recorded for the call.
        operation_id: String,
        /// The plugin whose call this is, which the provider sees as the caller.
        caller_plugin: String,
    },
}

impl LaneWork {
    /// Drops work whose session is gone. A reply or cancel has nobody left to
    /// tell, but an invoke has a caller waiting, so its call ends.
    fn abandon(self, hub: &RelayHub) {
        if let Self::Invoke { call_id, .. } = self {
            hub.dispatch_failed(call_id, provider_unavailable());
        }
    }
}

/// The lanes the main worker owns, keyed by session ID. A lane ends after it
/// drains its queue once its sender is dropped here.
struct Lanes {
    /// What a new lane needs to reach the hub and the sessions. Lanes hold
    /// only weak references, so they end with the engine.
    hub: Weak<RelayHub>,
    sessions: Weak<SessionMap>,
    senders: BTreeMap<String, mpsc::Sender<LaneWork>>,
}

impl Lanes {
    fn new(hub: Weak<RelayHub>, sessions: Weak<SessionMap>) -> Self {
        Self {
            hub,
            sessions,
            senders: BTreeMap::new(),
        }
    }

    /// Queues `work` on the lane of `session_id`, starting the lane the first
    /// time the session needs one. Lanes of sessions that have left the
    /// session map are released first, so their threads end.
    fn post(&mut self, sessions: &SessionMap, session_id: &str, work: LaneWork) {
        let session_present = {
            let sessions = sessions.lock().unwrap_or_else(PoisonError::into_inner);
            self.senders.retain(|id, _| sessions.contains_key(id));
            sessions.contains_key(session_id)
        };
        if !session_present {
            self.abandon(work);
            return;
        }
        let (hub, lane_sessions) = (&self.hub, &self.sessions);
        let sender = self
            .senders
            .entry(session_id.to_string())
            .or_insert_with(|| {
                let (sender, receiver) = mpsc::channel();
                let (hub, sessions) = (hub.clone(), lane_sessions.clone());
                let session_id = session_id.to_string();
                thread::spawn(move || run_lane(hub, sessions, session_id, receiver));
                sender
            });
        if let Err(mpsc::SendError(work)) = sender.send(work) {
            // The lane ended without its sender being dropped. Forget it, so
            // the next post starts a new lane.
            self.senders.remove(session_id);
            self.abandon(work);
        }
    }

    /// Handles work that cannot reach its session; see `LaneWork::abandon`.
    fn abandon(&self, work: LaneWork) {
        if let Some(hub) = self.hub.upgrade() {
            work.abandon(&hub);
        }
    }
}

/// Performs the writes to one session in order. This thread alone waits on
/// the session's stdin, and each write is bounded by `bounded_relay_write`.
/// It ends once the engine is gone or the main worker released the lane.
fn run_lane(
    hub: Weak<RelayHub>,
    sessions: Weak<SessionMap>,
    session_id: String,
    queue: mpsc::Receiver<LaneWork>,
) {
    for work in queue {
        let (Some(hub), Some(sessions)) = (hub.upgrade(), sessions.upgrade()) else {
            return;
        };
        let Some(session) = find_session(&sessions, &session_id) else {
            work.abandon(&hub);
            continue;
        };
        match work {
            LaneWork::Invoke {
                call_id,
                request,
                operation_id,
                caller_plugin,
            } => {
                // The call may have ended while it waited behind earlier work.
                if !hub.lock().is_running(call_id) {
                    continue;
                }
                let written = session.bounded_relay_write(|| {
                    session.function_request(request, operation_id, Some(caller_plugin.as_str()))
                });
                if let Err(error) = written {
                    hub.dispatch_failed(call_id, dispatch_failure(&error));
                }
            }
            LaneWork::Reply { rpc_id, outcome } => {
                // log-exempt: A write failure is already recorded by send_messages_or_fail; any other failure means the caller session is unusable and nobody is left to answer.
                let _ = session.bounded_relay_write(|| session.relay_reply(&rpc_id, &outcome));
            }
            LaneWork::Cancel { operation_id } => {
                // log-exempt: The operation may already have finished; nothing is left to cancel.
                let _ = session.bounded_relay_write(|| session.cancel_operation(&operation_id));
            }
        }
    }
}

fn find_session(sessions: &SessionMap, session_id: &str) -> Option<Arc<RuntimeSession>> {
    let sessions = sessions.lock().unwrap_or_else(PoisonError::into_inner);
    sessions.get(session_id).cloned()
}

/// A ready backend of `plugin_id` that registered `function_id`. A backend
/// of the caller's own workspace wins, so a call stays inside the workspace
/// it was made for when several windows run the same plugin.
fn find_provider(
    sessions: &SessionMap,
    caller_session: &str,
    plugin_id: &str,
    function_id: &str,
) -> Option<Arc<RuntimeSession>> {
    let (candidates, caller_root) = {
        let sessions = sessions.lock().unwrap_or_else(PoisonError::into_inner);
        let candidates: Vec<Arc<RuntimeSession>> = sessions
            .values()
            .filter(|session| session.plugin_id.as_deref() == Some(plugin_id))
            .cloned()
            .collect();
        let caller_root = sessions
            .get(caller_session)
            .map(|session| session.root_uri.clone());
        (candidates, caller_root)
    };
    let mut serving: Vec<Arc<RuntimeSession>> = candidates
        .into_iter()
        .filter(|session| session.serves_function(function_id))
        .collect();
    let same_workspace = serving
        .iter()
        .position(|session| Some(&session.root_uri) == caller_root.as_ref());
    match same_workspace {
        Some(index) => Some(serving.swap_remove(index)),
        None => serving.into_iter().next(),
    }
}

/// Why `function_request` refused a call the relay had admitted.
fn dispatch_failure(error: &CoreError) -> RelayFailure {
    match error.details.as_deref() {
        Some(codes::UNKNOWN) => RelayFailure::new(
            codes::NOT_EXPORTED,
            "The plugin has not registered this function.",
        ),
        _ => provider_unavailable(),
    }
}

/// The failure of a call whose provider's session cannot take it, because the
/// session is gone, not ready, or refused the write.
fn provider_unavailable() -> RelayFailure {
    RelayFailure::new(
        codes::PROVIDER_UNAVAILABLE,
        "The plugin could not take the call.",
    )
}

/// Which call a new `lithe/host/functions/invoke` was made while serving, as
/// the request's `parentOperationID` names it. The backend sends the wire
/// `operationID` of the `lithe/function/invoke` the engine wrote to it. That
/// ID is also the key of the invoke in `state.pending`, so the session's own
/// table proves both that the call is still running and that this backend is
/// the one serving it.
fn call_parent(state: &SessionState, params: &Value) -> CallParent {
    let Some(named) = params.get("parentOperationID") else {
        return CallParent::Unstated;
    };
    // The request's shape was checked before it reached the relay, so a value
    // that is not a string cannot name a call that is running.
    let Some(wire_id) = named.as_str() else {
        return CallParent::Ended;
    };
    let Some(pending) = state
        .pending
        .get(wire_id)
        .filter(|pending| pending.method == INVOKE_METHOD)
    else {
        return CallParent::Ended;
    };
    match pending.operation_id.as_deref() {
        // A relayed call: its operation ID carries the relay's call ID.
        Some(operation_id) if is_relay_operation_id(operation_id) => operation_id
            .strip_prefix(OPERATION_PREFIX)
            .and_then(|call_id| call_id.parse::<u64>().ok())
            .map_or(CallParent::Ended, CallParent::Relay),
        // A call the host started, which is not part of a relay chain.
        _ => CallParent::Root,
    }
}

fn string_param<'a>(params: &'a Value, key: &str) -> Result<&'a str, RelayFailure> {
    params.get(key).and_then(Value::as_str).ok_or_else(|| {
        RelayFailure::new(
            codes::HOST_INVALID_PARAMS,
            "The request params are malformed.",
        )
    })
}

/// The JSON-RPC message that answers the calling plugin's request. A failure
/// carries its stable code in `error.data.code`, and the callee's own error
/// code, if any, in `error.data.details.pluginErrorCode`.
fn reply_message(
    rpc_id: &Value,
    outcome: &Result<Value, RelayFailure>,
) -> Result<String, CoreError> {
    match outcome {
        Ok(result) => json_rpc_result(rpc_id, result.clone()),
        Err(failure) => {
            let mut data = json!({ "code": failure.code });
            if let Some(plugin_error_code) = &failure.plugin_error_code {
                data["details"] = json!({ "pluginErrorCode": plugin_error_code });
            }
            json_rpc_error_with_data(
                rpc_id,
                host_rpc_code(failure.code),
                &bounded_host_message(&failure.message),
                data,
            )
        }
    }
}

/// The relay's view of how a function call ended on the callee's session.
/// `result` is the engine's wrapped `{ value }`.
pub(super) fn callee_outcome(
    result: Option<Value>,
    error: Option<LspRuntimeError>,
) -> CalleeOutcome {
    match error {
        Some(error) => CalleeOutcome::Failed {
            code: error.code,
            message: error.message,
            plugin_error_code: error.plugin_error_code,
        },
        None => CalleeOutcome::Succeeded(
            result
                .and_then(|wrapped| wrapped.get("value").cloned())
                .unwrap_or(Value::Null),
        ),
    }
}

/// Whether the host may not use this operation ID, because the relay does.
pub(super) fn is_relay_operation_id(operation_id: &str) -> bool {
    operation_id.starts_with(OPERATION_PREFIX)
}

/// Whether an operation of the callee's session belongs to the relay.
pub(super) fn is_relayed_operation(operation_id: &str, method: &str) -> bool {
    method == INVOKE_METHOD && is_relay_operation_id(operation_id)
}

/// Tells the relay about a lifecycle change of `session`. A backend that
/// became ready may serve a call that waited for it; a session that is
/// ending takes its calls with it, in both roles.
pub(super) fn observe_lifecycle(session: &RuntimeSession, lifecycle: LspLifecycleState) {
    match lifecycle {
        LspLifecycleState::Ready => observe_functions_changed(session),
        LspLifecycleState::Stopping | LspLifecycleState::Stopped | LspLifecycleState::Failed => {
            session.relay.session_ended(&session.id)
        }
        LspLifecycleState::Created
        | LspLifecycleState::ProcessStarting
        | LspLifecycleState::Initializing => {}
    }
}

/// Tells the relay that `session` may now serve functions it did not before.
pub(super) fn observe_functions_changed(session: &RuntimeSession) {
    if let Some(plugin_id) = session.plugin_id.as_deref() {
        session.relay.provider_changed(plugin_id);
    }
}

impl RuntimeSession {
    /// Whether a call to `function_id` can be written to this session now.
    fn serves_function(&self, function_id: &str) -> bool {
        let Ok(state) = self.lock_state() else {
            return false;
        };
        state.lifecycle == LspLifecycleState::Ready
            && state.client.initialized
            && state.client.plugin_functions.contains(function_id)
    }

    /// Runs one write the relay's lane makes to this session, and bounds how
    /// long it may take. The session monitor fails the session and kills its
    /// process when the write is still running after the session's request
    /// timeout, which releases a write blocked on a backend that stopped
    /// reading its stdin. `write` runs with no session lock held.
    fn bounded_relay_write<T>(&self, write: impl FnOnce() -> T) -> T {
        if let Ok(mut state) = self.lock_state() {
            state.relay_write_deadline = Some(Instant::now() + state.request_timeout);
        }
        let result = write();
        if let Ok(mut state) = self.lock_state() {
            state.relay_write_deadline = None;
        }
        result
    }

    /// Writes the answer to a `lithe/host/functions/*` request this plugin
    /// backend made earlier.
    fn relay_reply(
        &self,
        rpc_id: &Value,
        outcome: &Result<Value, RelayFailure>,
    ) -> Result<(), CoreError> {
        let outbound_order = self.lock_outbound_order()?;
        let message = reply_message(rpc_id, outcome)?;
        self.send_messages_or_fail(&outbound_order, vec![message], "relayReply")
    }

    /// Tells the host that a call waits for a backend of `plugin_id` that is
    /// not running, so the host can start it.
    fn announce_provider_start_required(&self, plugin_id: &str) {
        if let Ok(mut state) = self.lock_state() {
            push_provider_start_event(self, &mut state, plugin_id);
        }
    }
}

/// The `functionProviderStartRequired` event: a call waits for the plugin's
/// backend, and the host should start it if it can. Like the provider events
/// it carries only its kind and a result, so it shares their builder.
fn push_provider_start_event(session: &RuntimeSession, state: &mut SessionState, plugin_id: &str) {
    push_negotiated_provider_event(
        session,
        state,
        json!({ "pluginID": plugin_id }),
        "functionProviderStartRequired",
    );
}
