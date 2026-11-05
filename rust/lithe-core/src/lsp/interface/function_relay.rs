//! Cross-plugin function relay: the rules that decide whether one plugin may
//! call a function another plugin exports, and the bookkeeping of the calls in
//! flight.
//!
//! This module is a pure state machine. It never touches a session, a thread
//! or the clock: every method takes what it needs, changes only its own
//! tables, and returns the `RelayAction`s the engine must carry out. The
//! engine (`engine_function_relay`) owns the I/O, so these rules can be tested
//! with plain values and synthetic `Instant`s.
//!
//! A call has two sides and both must have agreed in their manifests: the
//! callee lists the function under `pluginFunctions.exports` and the caller
//! lists it under `pluginFunctions.calls`, with the same contract version.
//! The host supplies the list of enabled plugins as a snapshot; presence in
//! the snapshot means the plugin is enabled.
//!
//! Trust never follows a call. The callee runs with its own permissions, and
//! the caller's plugin ID travels only as the `caller` field of the request
//! the callee receives, never as the callee session's identity.
//!
//! The rules live in the plugin contract
//! (`shared/contracts/plugins/v1/README.md`, "Plugin functions").

use super::plugin_function::{codes, is_function_id, is_plugin_id};
use crate::plugins::plugin_functions::KNOWN_CONTEXTS;
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::time::{Duration, Instant};

/// Most plugins in one hop chain. A chain A -> B -> C is depth 2 for the call
/// C receives; the limit keeps a mistaken fan-out from growing without bound.
pub(crate) const MAX_CALL_DEPTH: usize = 4;

/// Most relayed calls one plugin may have in flight at once, counted over
/// every session and window the plugin runs in.
pub(crate) const MAX_CALLS_PER_CALLER: usize = 8;

/// Largest serialized `params` a relayed call carries.
pub(crate) const MAX_PARAMS_BYTES: usize = 256 * 1024;

/// Largest serialized function result a relayed call returns.
pub(crate) const MAX_RESULT_BYTES: usize = 256 * 1024;

/// Deadline of a call that names none.
pub(crate) const DEFAULT_TIMEOUT: Duration = Duration::from_secs(60);

/// Longest deadline a call may ask for.
pub(crate) const MAX_TIMEOUT: Duration = Duration::from_secs(10 * 60);

/// How long a call waits for the callee's backend to start and register the
/// function before it fails with `plugin.function.providerUnavailable`.
pub(crate) const PROVIDER_START_TIMEOUT: Duration = Duration::from_secs(30);

/// How long after its deadline a running call may still wait for the callee's
/// own timeout reply before the relay ends it. The callee session enforces the
/// same deadline and normally answers first; this only ends calls whose callee
/// never answers.
pub(crate) const RUNNING_GRACE: Duration = Duration::from_secs(2);

/// Operation IDs of relayed calls start with this. The engine keeps them out
/// of the callee session's host events, because no host operation waits for
/// them: the answer goes to the calling plugin.
pub(crate) const OPERATION_PREFIX: &str = "relay-call-";

/// Most plugins one snapshot may list. Guards the table, not the product.
const MAX_SNAPSHOT_PLUGINS: usize = 4096;

/// Where a workspace context runs, as the host reports it.
#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ContextAuthority {
    Local,
    Remote,
}

/// One workspace context generation the host currently serves.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RelayContext {
    #[serde(rename = "contextID")]
    pub context_id: String,
    pub generation: u64,
    pub authority: ContextAuthority,
}

/// A function an enabled plugin exports.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RelayExport {
    pub id: String,
    pub version: u32,
    pub context: String,
}

/// A function an enabled plugin declared it calls.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RelayCall {
    pub id: String,
    pub version: u32,
}

/// What the relay needs to know about one enabled plugin.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RelayPlugin {
    #[serde(rename = "pluginID")]
    pub plugin_id: String,
    #[serde(default)]
    pub exports: Vec<RelayExport>,
    #[serde(default)]
    pub calls: Vec<RelayCall>,
}

/// The host's complete view: the enabled plugins and the live workspace
/// contexts. Each configuration replaces the previous one, which is how
/// installing, updating, disabling and uninstalling a plugin reaches calls
/// already in flight.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RelaySnapshot {
    #[serde(default)]
    pub plugins: Vec<RelayPlugin>,
    #[serde(default)]
    pub contexts: Vec<RelayContext>,
}

/// Why a relayed call (or a discovery) did not succeed. `code` is the stable
/// `plugin.function.*` or `plugin.host.*` code the calling plugin branches on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RelayFailure {
    pub code: &'static str,
    pub message: String,
    /// The callee's own code (`error.data.code`) when its function failed.
    pub plugin_error_code: Option<String>,
}

impl RelayFailure {
    pub(crate) fn new(code: &'static str, message: &str) -> Self {
        Self {
            code,
            message: message.to_string(),
            plugin_error_code: None,
        }
    }
}

/// Which call a new request was made while serving, as the engine resolved
/// the request's `parentOperationID`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CallParent {
    /// The request named no parent: every relayed call the caller's session
    /// is running counts as one.
    Unstated,
    /// The named operation is one the host started, not a relayed call, so
    /// the new call starts a chain.
    Root,
    /// The named operation is this relayed call.
    Relay(u64),
    /// The named operation is not running in the caller's session.
    Ended,
}

/// One request of a plugin to call an exported function.
pub(crate) struct RelayRequest {
    pub caller_session: String,
    pub caller_plugin: String,
    /// JSON-RPC ID of the request, echoed in the answer.
    pub rpc_id: Value,
    pub callee_plugin: String,
    pub function_id: String,
    /// A JSON object.
    pub params: Value,
    /// `{ contextID, generation }`.
    pub context: Value,
    pub timeout: Option<Duration>,
    /// The call this request was made while serving; decides the new call's
    /// plugin chain and which ended call cancels it.
    pub parent: CallParent,
}

/// How the callee's side of a call ended.
pub(crate) enum CalleeOutcome {
    /// The function returned this value.
    Succeeded(Value),
    /// The call ended without a value; `code` is the engine's request code,
    /// such as `plugin.function.failed` or `requestTimeout`.
    Failed {
        code: String,
        message: String,
        plugin_error_code: Option<String>,
    },
}

/// Work the engine must do after a state change. Every action runs outside
/// all session locks.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum RelayAction {
    /// Answer the calling plugin's request.
    Reply {
        session_id: String,
        rpc_id: Value,
        outcome: Result<Value, RelayFailure>,
    },
    /// Tell the callee session to stop one running call.
    CancelCallee {
        session_id: String,
        operation_id: String,
    },
    /// Find the callee's backend and send it the call.
    Dispatch { call_id: u64 },
}

/// Everything the engine needs to send one call to the callee's backend.
pub(crate) struct DispatchPlan {
    pub caller_session: String,
    pub caller_plugin: String,
    pub callee_plugin: String,
    pub function_id: String,
    pub params: Value,
    pub context: Value,
    pub remaining: Duration,
}

/// Tells the caller's session that the callee's backend must be started.
pub(crate) struct StartNotice {
    pub caller_session: String,
    pub callee_plugin: String,
}

enum Phase {
    /// Admitted; the engine is looking for the callee's backend.
    Dispatching,
    /// No ready backend yet; the host was asked to start one.
    WaitingForProvider,
    /// The callee's session has the call.
    Running {
        session_id: String,
        operation_id: String,
    },
}

struct Call {
    id: u64,
    caller_session: String,
    caller_plugin: String,
    rpc_id: Value,
    callee_plugin: String,
    function_id: String,
    params: Value,
    context: Value,
    deadline: Instant,
    /// Set when the call first waits for a backend, never moved afterwards, so
    /// retries cannot extend the wait.
    give_up_at: Option<Instant>,
    /// Plugins from the root call down to the caller, without repeats.
    chain: Vec<String>,
    /// Calls the caller's session was serving when it made this one: the one
    /// the request named, or every one when it named none. When all of them
    /// end this call is cancelled; a root call has none.
    parents: BTreeSet<u64>,
    phase: Phase,
}

/// The relay's tables. See the module comment.
#[derive(Default)]
pub(crate) struct FunctionRelay {
    plugins: BTreeMap<String, RelayPlugin>,
    contexts: BTreeMap<String, RelayContext>,
    calls: BTreeMap<u64, Call>,
    next_call_id: u64,
}

impl FunctionRelay {
    /// Replaces the snapshot and ends the calls it no longer allows.
    pub(crate) fn configure(
        &mut self,
        snapshot: RelaySnapshot,
    ) -> Result<Vec<RelayAction>, &'static str> {
        check_snapshot(&snapshot)?;
        self.plugins = snapshot
            .plugins
            .into_iter()
            .map(|mut plugin| {
                // An export without a context this Core knows is not callable.
                plugin
                    .exports
                    .retain(|export| KNOWN_CONTEXTS.contains(&export.context.as_str()));
                (plugin.plugin_id.clone(), plugin)
            })
            .collect();
        self.contexts = snapshot
            .contexts
            .into_iter()
            .map(|context| (context.context_id.clone(), context))
            .collect();
        Ok(self.end_calls_the_snapshot_forbids())
    }

    /// Answers `lithe/host/functions/providers`: the enabled plugins that
    /// export `function_id`, sorted by plugin ID, with the contract version
    /// each exports so a mismatch with the caller's declaration is visible.
    pub(crate) fn providers(
        &self,
        caller_plugin: &str,
        function_id: &str,
    ) -> Result<Value, RelayFailure> {
        self.declared_version(caller_plugin, function_id)?;
        let providers: Vec<Value> = self
            .plugins
            .values()
            .filter(|plugin| plugin.plugin_id != caller_plugin)
            .filter_map(|plugin| {
                let export = exported(plugin, function_id)?;
                Some(json!({ "pluginID": plugin.plugin_id, "version": export.version }))
            })
            .collect();
        Ok(json!({ "providers": providers }))
    }

    /// Checks one call request. The checks run in a fixed order, so the same
    /// request always reports the same reason. On success the call is
    /// recorded and the returned actions ask the engine to dispatch it.
    pub(crate) fn admit(
        &mut self,
        request: RelayRequest,
        now: Instant,
    ) -> Result<Vec<RelayAction>, RelayFailure> {
        let declared_version =
            self.declared_version(&request.caller_plugin, &request.function_id)?;
        let provider = self.plugins.get(&request.callee_plugin).ok_or_else(|| {
            RelayFailure::new(
                codes::PROVIDER_DISABLED,
                "The plugin that exports this function is not enabled.",
            )
        })?;
        let export = exported(provider, &request.function_id).ok_or_else(|| {
            RelayFailure::new(
                codes::NOT_EXPORTED,
                "The plugin does not export this function.",
            )
        })?;
        if export.version != declared_version {
            return Err(RelayFailure::new(
                codes::VERSION_MISMATCH,
                "The function's contract version differs from the version this plugin declared.",
            ));
        }
        self.check_context(&request.context)?;
        if request.params.to_string().len() > MAX_PARAMS_BYTES {
            return Err(RelayFailure::new(
                codes::PAYLOAD_TOO_LARGE,
                "The call's params exceed the relay limit.",
            ));
        }
        let (chain, parents) = self.ancestry(
            &request.caller_session,
            &request.caller_plugin,
            request.parent,
        )?;
        if chain.contains(&request.callee_plugin) {
            return Err(RelayFailure::new(
                codes::CALL_CYCLE,
                "The call would re-enter a plugin that is already part of this call chain.",
            ));
        }
        if chain.len() > MAX_CALL_DEPTH {
            return Err(RelayFailure::new(
                codes::DEPTH_EXCEEDED,
                "Plugin calls are nested too deeply.",
            ));
        }
        let in_flight = self
            .calls
            .values()
            .filter(|call| call.caller_plugin == request.caller_plugin)
            .count();
        if in_flight >= MAX_CALLS_PER_CALLER {
            return Err(RelayFailure::new(
                codes::TOO_MANY_CALLS,
                "This plugin has too many plugin calls in flight.",
            ));
        }

        let timeout = request.timeout.unwrap_or(DEFAULT_TIMEOUT).min(MAX_TIMEOUT);
        self.next_call_id += 1;
        let call_id = self.next_call_id;
        self.calls.insert(
            call_id,
            Call {
                id: call_id,
                caller_session: request.caller_session,
                caller_plugin: request.caller_plugin,
                rpc_id: request.rpc_id,
                callee_plugin: request.callee_plugin,
                function_id: request.function_id,
                params: request.params,
                context: request.context,
                deadline: now + timeout,
                give_up_at: None,
                chain,
                parents,
                phase: Phase::Dispatching,
            },
        );
        Ok(vec![RelayAction::Dispatch { call_id }])
    }

    /// What the engine needs to send the call, or `None` when it already
    /// ended.
    pub(crate) fn dispatch_plan(&self, call_id: u64, now: Instant) -> Option<DispatchPlan> {
        let call = self.calls.get(&call_id)?;
        Some(DispatchPlan {
            caller_session: call.caller_session.clone(),
            caller_plugin: call.caller_plugin.clone(),
            callee_plugin: call.callee_plugin.clone(),
            function_id: call.function_id.clone(),
            params: call.params.clone(),
            context: call.context.clone(),
            remaining: call.deadline.saturating_duration_since(now),
        })
    }

    /// Records that no ready backend serves the call yet. Returns the notice
    /// for the host to start one, only the first time the call waits.
    pub(crate) fn wait_for_provider(&mut self, call_id: u64, now: Instant) -> Option<StartNotice> {
        let call = self.calls.get_mut(&call_id)?;
        call.phase = Phase::WaitingForProvider;
        if call.give_up_at.is_some() {
            return None;
        }
        call.give_up_at = Some(now + PROVIDER_START_TIMEOUT);
        Some(StartNotice {
            caller_session: call.caller_session.clone(),
            callee_plugin: call.callee_plugin.clone(),
        })
    }

    /// Records the callee session and operation that now own the call, before
    /// the request is written, so an answer that beats the caller of this
    /// method still finds its call. Returns false when the call already
    /// ended.
    pub(crate) fn started(&mut self, call_id: u64, session_id: &str, operation_id: &str) -> bool {
        let Some(call) = self.calls.get_mut(&call_id) else {
            return false;
        };
        call.phase = Phase::Running {
            session_id: session_id.to_string(),
            operation_id: operation_id.to_string(),
        };
        true
    }

    /// Whether the call exists and its callee session has it. The engine asks
    /// before writing the request, to skip a call that ended while it queued.
    pub(crate) fn is_running(&self, call_id: u64) -> bool {
        self.calls
            .get(&call_id)
            .is_some_and(|call| matches!(call.phase, Phase::Running { .. }))
    }

    /// The call could not be sent to the callee's backend.
    pub(crate) fn dispatch_failed(
        &mut self,
        call_id: u64,
        failure: RelayFailure,
    ) -> Vec<RelayAction> {
        self.end_call(call_id, Some(Err(failure)), false)
    }

    /// The callee's session finished an operation. Anything that is not a
    /// running relayed call returns no actions.
    pub(crate) fn callee_finished(
        &mut self,
        session_id: &str,
        operation_id: &str,
        outcome: CalleeOutcome,
    ) -> Vec<RelayAction> {
        let Some(call_id) = self.running_call(session_id, operation_id) else {
            return Vec::new();
        };
        self.end_call(call_id, Some(answer_for(outcome)), false)
    }

    /// The calling plugin withdrew its request with `$/cancelRequest`.
    /// Returns `None` when the request names no relayed call.
    pub(crate) fn cancel_from_caller(
        &mut self,
        session_id: &str,
        rpc_id: &Value,
    ) -> Option<Vec<RelayAction>> {
        let call_id = self
            .calls
            .values()
            .find(|call| call.caller_session == session_id && &call.rpc_id == rpc_id)?
            .id;
        let cancelled = RelayFailure::new(
            codes::HOST_CANCELLED,
            "The plugin process cancelled this call.",
        );
        Some(self.end_call(call_id, Some(Err(cancelled)), true))
    }

    /// A session stopped or failed. Calls it made end silently, because
    /// nobody is left to answer, and their callees are cancelled. Calls it
    /// was serving fail for their callers.
    pub(crate) fn session_ended(&mut self, session_id: &str) -> Vec<RelayAction> {
        let made: Vec<u64> = self
            .calls
            .values()
            .filter(|call| call.caller_session == session_id)
            .map(|call| call.id)
            .collect();
        let mut actions = Vec::new();
        for call_id in made {
            actions.extend(self.end_call(call_id, None, true));
        }
        let served: Vec<u64> = self
            .calls
            .values()
            .filter(|call| {
                matches!(&call.phase, Phase::Running { session_id: owner, .. } if owner == session_id)
            })
            .map(|call| call.id)
            .collect();
        for call_id in served {
            let ended = RelayFailure::new(
                codes::PROVIDER_UNAVAILABLE,
                "The plugin's process ended before it answered.",
            );
            actions.extend(self.end_call(call_id, Some(Err(ended)), false));
        }
        actions
    }

    /// A backend of `plugin_id` became ready or registered functions: calls
    /// that waited for it are dispatched again.
    pub(crate) fn provider_changed(&mut self, plugin_id: &str) -> Vec<RelayAction> {
        self.calls
            .values_mut()
            .filter(|call| {
                call.callee_plugin == plugin_id && matches!(call.phase, Phase::WaitingForProvider)
            })
            .map(|call| {
                call.phase = Phase::Dispatching;
                RelayAction::Dispatch { call_id: call.id }
            })
            .collect()
    }

    /// Ends calls that are out of time. A call with no running callee ends at
    /// its deadline, or when its provider did not start in time. A running
    /// call carries its remaining time to the callee session, whose own
    /// timeout normally answers first; the relay ends it only `RUNNING_GRACE`
    /// after the deadline, so a callee that never answers cannot leave the
    /// call open, and it cancels the callee.
    pub(crate) fn expire(&mut self, now: Instant) -> Vec<RelayAction> {
        let mut due = Vec::new();
        for call in self.calls.values() {
            let running = matches!(call.phase, Phase::Running { .. });
            let out_of_time = if running {
                call.deadline + RUNNING_GRACE
            } else {
                call.deadline
            };
            if now >= out_of_time {
                // Only a running call has a callee to cancel.
                due.push((
                    call.id,
                    RelayFailure::new(codes::HOST_TIMEOUT, "The plugin call timed out."),
                    running,
                ));
            } else if !running && call.give_up_at.is_some_and(|limit| now >= limit) {
                due.push((
                    call.id,
                    RelayFailure::new(
                        codes::PROVIDER_UNAVAILABLE,
                        "The plugin did not start in time.",
                    ),
                    false,
                ));
            }
        }
        let mut actions = Vec::new();
        for (call_id, failure, cancel_callee) in due {
            actions.extend(self.end_call(call_id, Some(Err(failure)), cancel_callee));
        }
        actions
    }

    /// The version the caller declared for `function_id`, or `notDeclared`.
    fn declared_version(
        &self,
        caller_plugin: &str,
        function_id: &str,
    ) -> Result<u32, RelayFailure> {
        self.plugins
            .get(caller_plugin)
            .and_then(|plugin| plugin.calls.iter().find(|call| call.id == function_id))
            .map(|call| call.version)
            .ok_or_else(|| {
                RelayFailure::new(
                    codes::NOT_DECLARED,
                    "The plugin did not declare calling this function.",
                )
            })
    }

    fn check_context(&self, reference: &Value) -> Result<(), RelayFailure> {
        let current = reference
            .get("contextID")
            .and_then(Value::as_str)
            .and_then(|context_id| self.contexts.get(context_id))
            .filter(|context| Some(context.generation) == reference["generation"].as_u64());
        match current {
            None => Err(RelayFailure::new(
                codes::HOST_CONTEXT_EXPIRED,
                "The workspace context is no longer current.",
            )),
            Some(context) if context.authority == ContextAuthority::Remote => {
                Err(RelayFailure::new(
                    codes::HOST_AUTHORITY_UNSUPPORTED,
                    "Plugin functions do not run for remote workspaces.",
                ))
            }
            Some(_) => Ok(()),
        }
    }

    /// The plugin chain and the parent calls of a new call made from
    /// `caller_session`, according to what the request said about its parent.
    ///
    /// A named relayed call must be running in `caller_session`; the new call
    /// continues that call's chain and is cancelled with it. A named call that
    /// is not running there is refused with `cancelled`. A host operation
    /// starts a new chain. When the request names no parent, the parents are
    /// every relayed call that session is running: the request does not say
    /// which of them caused it, so the chain is their union. That can reject
    /// a call that is not really cyclic, never accept one that is.
    fn ancestry(
        &self,
        caller_session: &str,
        caller_plugin: &str,
        parent: CallParent,
    ) -> Result<(Vec<String>, BTreeSet<u64>), RelayFailure> {
        let not_running = || {
            RelayFailure::new(
                codes::HOST_CANCELLED,
                "The call this request belongs to is not running.",
            )
        };
        let served_here = |call: &Call| matches!(&call.phase, Phase::Running { session_id, .. } if session_id == caller_session);
        let mut chain: Vec<String> = Vec::new();
        let mut parents = BTreeSet::new();
        match parent {
            CallParent::Root => {}
            CallParent::Ended => return Err(not_running()),
            CallParent::Relay(call_id) => {
                let named = self
                    .calls
                    .get(&call_id)
                    .filter(|call| served_here(*call))
                    .ok_or_else(not_running)?;
                parents.insert(named.id);
                chain.extend(named.chain.iter().cloned());
            }
            CallParent::Unstated => {
                for served in self.calls.values().filter(|call| served_here(*call)) {
                    parents.insert(served.id);
                    for plugin in &served.chain {
                        if !chain.contains(plugin) {
                            chain.push(plugin.clone());
                        }
                    }
                }
            }
        }
        if !chain.iter().any(|plugin| plugin == caller_plugin) {
            chain.push(caller_plugin.to_string());
        }
        Ok((chain, parents))
    }

    fn running_call(&self, session_id: &str, operation_id: &str) -> Option<u64> {
        self.calls
            .values()
            .find(|call| {
                matches!(
                    &call.phase,
                    Phase::Running { session_id: owner, operation_id: operation }
                        if owner == session_id && operation == operation_id
                )
            })
            .map(|call| call.id)
    }

    /// Removes a call, optionally cancelling its callee and answering its
    /// caller, then cancels every call that only existed because of it.
    fn end_call(
        &mut self,
        call_id: u64,
        reply: Option<Result<Value, RelayFailure>>,
        cancel_callee: bool,
    ) -> Vec<RelayAction> {
        let Some(call) = self.calls.remove(&call_id) else {
            return Vec::new();
        };
        let mut actions = Vec::new();
        if let (
            true,
            Phase::Running {
                session_id,
                operation_id,
            },
        ) = (cancel_callee, &call.phase)
        {
            actions.push(RelayAction::CancelCallee {
                session_id: session_id.clone(),
                operation_id: operation_id.clone(),
            });
        }
        if let Some(outcome) = reply {
            actions.push(RelayAction::Reply {
                session_id: call.caller_session,
                rpc_id: call.rpc_id,
                outcome,
            });
        }
        actions.extend(self.cancel_orphans_of(call_id));
        actions
    }

    /// Cancels the calls whose every parent has ended. The plugin that made
    /// them was serving the ended call, so nobody wants their result.
    fn cancel_orphans_of(&mut self, ended_call: u64) -> Vec<RelayAction> {
        let mut orphans = Vec::new();
        for child in self.calls.values_mut() {
            if child.parents.remove(&ended_call) && child.parents.is_empty() {
                orphans.push(child.id);
            }
        }
        let mut actions = Vec::new();
        for orphan in orphans {
            let cancelled = RelayFailure::new(
                codes::HOST_CANCELLED,
                "The call this request belonged to ended.",
            );
            actions.extend(self.end_call(orphan, Some(Err(cancelled)), true));
        }
        actions
    }

    /// After a new snapshot: calls whose callee left, stopped exporting the
    /// function or changed its version end with `providerDisabled`; calls
    /// whose caller no longer declares them end with `notDeclared`; calls
    /// whose workspace context closed, moved to a new generation or became
    /// remote end with the context's failure.
    fn end_calls_the_snapshot_forbids(&mut self) -> Vec<RelayAction> {
        let mut doomed = Vec::new();
        for call in self.calls.values() {
            let declared = self.declared_version(&call.caller_plugin, &call.function_id);
            let exported_version = self
                .plugins
                .get(&call.callee_plugin)
                .and_then(|plugin| exported(plugin, &call.function_id))
                .map(|export| export.version);
            if declared.is_err() {
                doomed.push((
                    call.id,
                    RelayFailure::new(
                        codes::NOT_DECLARED,
                        "The plugin no longer declares calling this function.",
                    ),
                ));
            } else if exported_version.is_none() || exported_version != declared.ok() {
                doomed.push((
                    call.id,
                    RelayFailure::new(
                        codes::PROVIDER_DISABLED,
                        "The plugin that exports this function changed or was disabled.",
                    ),
                ));
            } else if let Err(failure) = self.check_context(&call.context) {
                // Workspace contexts change only through `configure`, so
                // checking here covers closed contexts and generation bumps.
                doomed.push((call.id, failure));
            }
        }
        let mut actions = Vec::new();
        for (call_id, failure) in doomed {
            actions.extend(self.end_call(call_id, Some(Err(failure)), true));
        }
        actions
    }
}

fn exported<'a>(plugin: &'a RelayPlugin, function_id: &str) -> Option<&'a RelayExport> {
    plugin
        .exports
        .iter()
        .find(|export| export.id == function_id)
}

/// The answer the calling plugin gets for how the callee's side ended.
fn answer_for(outcome: CalleeOutcome) -> Result<Value, RelayFailure> {
    match outcome {
        CalleeOutcome::Succeeded(value) => {
            if value.to_string().len() > MAX_RESULT_BYTES {
                return Err(RelayFailure::new(
                    codes::PAYLOAD_TOO_LARGE,
                    "The function's result exceeds the relay limit.",
                ));
            }
            Ok(json!({ "value": value }))
        }
        CalleeOutcome::Failed {
            code,
            message,
            plugin_error_code,
        } => Err(match code.as_str() {
            codes::FAILED => RelayFailure {
                code: codes::FAILED,
                message,
                plugin_error_code,
            },
            // No result, or one over the engine's own bound: the provider
            // answered, but not with a value Core can pass on.
            codes::INVALID_RESULT => RelayFailure {
                code: codes::INVALID_RESULT,
                message,
                plugin_error_code: None,
            },
            "requestTimeout" => {
                RelayFailure::new(codes::HOST_TIMEOUT, "The plugin call timed out.")
            }
            // Revoked, cancelled by the callee's own shutdown, or a process
            // that exited: the provider cannot finish the call.
            _ => RelayFailure::new(
                codes::PROVIDER_UNAVAILABLE,
                "The plugin stopped before it answered.",
            ),
        }),
    }
}

/// Rejects a snapshot that is malformed rather than merely restrictive.
fn check_snapshot(snapshot: &RelaySnapshot) -> Result<(), &'static str> {
    if snapshot.plugins.len() > MAX_SNAPSHOT_PLUGINS {
        return Err("The function-relay snapshot lists too many plugins.");
    }
    let mut seen = BTreeSet::new();
    for plugin in &snapshot.plugins {
        if !is_plugin_id(&plugin.plugin_id) || !seen.insert(plugin.plugin_id.as_str()) {
            return Err("A snapshot plugin ID is malformed or listed twice.");
        }
        let ids_are_valid = plugin
            .exports
            .iter()
            .map(|export| export.id.as_str())
            .chain(plugin.calls.iter().map(|call| call.id.as_str()))
            .all(is_function_id);
        if !ids_are_valid {
            return Err("A snapshot function ID is malformed.");
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const PYTHON: &str = "dev.lithe.python";
    const GO: &str = "dev.lithe.go";
    const ZIG: &str = "dev.lithe.zig";
    /// A second plugin that calls Go, so Go can serve two callers at once.
    const RUBY: &str = "dev.lithe.ruby";
    const FUNCTION: &str = "project.describe";

    fn plugin(id: &str, exports: &[(&str, u32)], calls: &[(&str, u32)]) -> RelayPlugin {
        RelayPlugin {
            plugin_id: id.to_string(),
            exports: exports
                .iter()
                .map(|(function, version)| RelayExport {
                    id: function.to_string(),
                    version: *version,
                    context: "workspace".to_string(),
                })
                .collect(),
            calls: calls
                .iter()
                .map(|(function, version)| RelayCall {
                    id: function.to_string(),
                    version: *version,
                })
                .collect(),
        }
    }

    fn local_context() -> RelayContext {
        RelayContext {
            context_id: "workspace-1".to_string(),
            generation: 3,
            authority: ContextAuthority::Local,
        }
    }

    /// The snapshot of `relay()` with a different set of live contexts.
    fn snapshot_with_contexts(contexts: Vec<RelayContext>) -> RelaySnapshot {
        RelaySnapshot {
            plugins: vec![
                plugin(PYTHON, &[], &[(FUNCTION, 1)]),
                plugin(GO, &[(FUNCTION, 1)], &[]),
            ],
            contexts,
        }
    }

    /// Python calls `project.describe` (version 1), Go exports it.
    fn relay() -> FunctionRelay {
        let mut relay = FunctionRelay::default();
        relay
            .configure(snapshot_with_contexts(vec![local_context()]))
            .expect("the snapshot is valid");
        relay
    }

    /// Python and Ruby call Go; Go calls Zig, which exports the function too.
    /// Go can serve a call from each caller at once and call Zig for both.
    fn relay_with_two_callers_of_go() -> FunctionRelay {
        let mut relay = FunctionRelay::default();
        relay
            .configure(RelaySnapshot {
                plugins: vec![
                    plugin(PYTHON, &[], &[(FUNCTION, 1)]),
                    plugin(RUBY, &[], &[(FUNCTION, 1)]),
                    plugin(GO, &[(FUNCTION, 1)], &[(FUNCTION, 1)]),
                    plugin(ZIG, &[(FUNCTION, 1)], &[]),
                ],
                contexts: vec![local_context()],
            })
            .expect("the snapshot is valid");
        relay
    }

    /// Six plugins in a line, each exporting and calling the function, with
    /// `MAX_CALL_DEPTH` hops running. Hop `i` (call ID `i + 1`) is plugin `i`
    /// calling plugin `i + 1` from `session-i` with RPC ID `i`; the session
    /// `session-(i + 1)` serves it. One more hop, made by the last served
    /// plugin `names[MAX_CALL_DEPTH]`, would be too deep.
    fn relay_with_calls_down_a_line(now: Instant) -> (FunctionRelay, Vec<String>) {
        let names: Vec<String> = (1..=6).map(|index| format!("dev.lithe.p{index}")).collect();
        let mut relay = FunctionRelay::default();
        relay
            .configure(RelaySnapshot {
                plugins: names
                    .iter()
                    .map(|name| plugin(name, &[(FUNCTION, 1)], &[(FUNCTION, 1)]))
                    .collect(),
                contexts: vec![local_context()],
            })
            .expect("the snapshot is valid");
        for hop in 0..MAX_CALL_DEPTH {
            running_call(
                &mut relay,
                request(
                    &format!("session-{hop}"),
                    &names[hop],
                    &names[hop + 1],
                    hop as i64,
                ),
                &format!("session-{}", hop + 1),
                now,
            );
        }
        (relay, names)
    }

    fn request(caller_session: &str, caller: &str, callee: &str, rpc_id: i64) -> RelayRequest {
        RelayRequest {
            caller_session: caller_session.to_string(),
            caller_plugin: caller.to_string(),
            rpc_id: json!(rpc_id),
            callee_plugin: callee.to_string(),
            function_id: FUNCTION.to_string(),
            params: json!({ "project": "app" }),
            context: json!({ "contextID": "workspace-1", "generation": 3 }),
            timeout: None,
            parent: CallParent::Unstated,
        }
    }

    /// `request`, made while serving the call `parent` names.
    fn request_from(
        parent: CallParent,
        caller_session: &str,
        caller: &str,
        callee: &str,
        rpc_id: i64,
    ) -> RelayRequest {
        RelayRequest {
            parent,
            ..request(caller_session, caller, callee, rpc_id)
        }
    }

    /// The action that cancels the call `call_id` in its callee session.
    fn cancel_of(callee_session: &str, call_id: u64) -> RelayAction {
        RelayAction::CancelCallee {
            session_id: callee_session.to_string(),
            operation_id: format!("{OPERATION_PREFIX}{call_id}"),
        }
    }

    /// The codes of the failed replies among `actions`, in order.
    fn failed_reply_codes(actions: &[RelayAction]) -> Vec<&'static str> {
        actions
            .iter()
            .filter_map(|action| match action {
                RelayAction::Reply {
                    outcome: Err(failure),
                    ..
                } => Some(failure.code),
                _ => None,
            })
            .collect()
    }

    fn admitted_call(relay: &mut FunctionRelay, request: RelayRequest, now: Instant) -> u64 {
        match relay
            .admit(request, now)
            .expect("the call is admitted")
            .as_slice()
        {
            [RelayAction::Dispatch { call_id }] => *call_id,
            other => panic!("expected one dispatch, got {other:?}"),
        }
    }

    fn refusal(relay: &mut FunctionRelay, request: RelayRequest) -> &'static str {
        relay
            .admit(request, Instant::now())
            .expect_err("the call is refused")
            .code
    }

    /// Admits a call and records its callee session, like the engine does.
    fn running_call(
        relay: &mut FunctionRelay,
        request: RelayRequest,
        callee_session: &str,
        now: Instant,
    ) -> u64 {
        let call_id = admitted_call(relay, request, now);
        assert!(relay.started(
            call_id,
            callee_session,
            &format!("{OPERATION_PREFIX}{call_id}")
        ));
        call_id
    }

    #[test]
    fn a_declared_exported_call_is_admitted_and_dispatched() {
        let mut relay = relay();
        let now = Instant::now();
        let call_id = admitted_call(&mut relay, request("py", PYTHON, GO, 7), now);
        let plan = relay.dispatch_plan(call_id, now).expect("the call is live");
        assert_eq!(plan.callee_plugin, GO);
        assert_eq!(plan.caller_plugin, PYTHON);
        assert_eq!(plan.function_id, FUNCTION);
        assert_eq!(plan.remaining, DEFAULT_TIMEOUT);
    }

    #[test]
    fn a_requested_timeout_is_capped() {
        let mut relay = relay();
        let now = Instant::now();
        let mut long = request("py", PYTHON, GO, 7);
        long.timeout = Some(Duration::from_secs(24 * 3600));
        let call_id = admitted_call(&mut relay, long, now);
        assert_eq!(
            relay.dispatch_plan(call_id, now).unwrap().remaining,
            MAX_TIMEOUT
        );
    }

    #[test]
    fn discovery_lists_exporters_sorted_with_their_versions() {
        let mut relay = relay();
        relay
            .configure(RelaySnapshot {
                plugins: vec![
                    plugin(PYTHON, &[], &[(FUNCTION, 1)]),
                    plugin("dev.lithe.zig", &[(FUNCTION, 2)], &[]),
                    plugin(GO, &[(FUNCTION, 1)], &[]),
                    plugin("dev.lithe.rust", &[("other.run", 1)], &[]),
                ],
                contexts: vec![],
            })
            .unwrap();
        assert_eq!(
            relay.providers(PYTHON, FUNCTION).unwrap(),
            json!({ "providers": [
                { "pluginID": GO, "version": 1 },
                { "pluginID": "dev.lithe.zig", "version": 2 }
            ] })
        );
    }

    #[test]
    fn discovery_requires_the_caller_to_declare_the_function() {
        let relay = relay();
        assert_eq!(
            relay.providers(GO, FUNCTION).unwrap_err().code,
            codes::NOT_DECLARED
        );
        assert_eq!(
            relay
                .providers("dev.lithe.unknown", FUNCTION)
                .unwrap_err()
                .code,
            codes::NOT_DECLARED
        );
    }

    #[test]
    fn an_undeclared_call_is_refused_before_anything_about_the_callee() {
        let mut relay = relay();
        let mut undeclared = request("go", GO, PYTHON, 1);
        undeclared.function_id = "other.run".to_string();
        assert_eq!(refusal(&mut relay, undeclared), codes::NOT_DECLARED);
    }

    #[test]
    fn a_disabled_provider_is_refused() {
        let mut relay = relay();
        assert_eq!(
            refusal(&mut relay, request("py", PYTHON, "dev.lithe.gone", 1)),
            codes::PROVIDER_DISABLED
        );
    }

    #[test]
    fn a_function_the_provider_does_not_export_is_refused() {
        let mut relay = relay();
        relay
            .configure(RelaySnapshot {
                plugins: vec![
                    plugin(PYTHON, &[], &[(FUNCTION, 1)]),
                    plugin(GO, &[("other.run", 1)], &[]),
                ],
                contexts: vec![local_context()],
            })
            .unwrap();
        assert_eq!(
            refusal(&mut relay, request("py", PYTHON, GO, 1)),
            codes::NOT_EXPORTED
        );
    }

    #[test]
    fn an_export_with_an_unknown_context_is_not_callable() {
        let mut relay = relay();
        let mut provider = plugin(GO, &[(FUNCTION, 1)], &[]);
        provider.exports[0].context = "everywhere".to_string();
        relay
            .configure(RelaySnapshot {
                plugins: vec![plugin(PYTHON, &[], &[(FUNCTION, 1)]), provider],
                contexts: vec![local_context()],
            })
            .unwrap();
        assert_eq!(
            refusal(&mut relay, request("py", PYTHON, GO, 1)),
            codes::NOT_EXPORTED
        );
    }

    #[test]
    fn different_contract_versions_are_refused() {
        let mut relay = relay();
        relay
            .configure(RelaySnapshot {
                plugins: vec![
                    plugin(PYTHON, &[], &[(FUNCTION, 1)]),
                    plugin(GO, &[(FUNCTION, 2)], &[]),
                ],
                contexts: vec![local_context()],
            })
            .unwrap();
        assert_eq!(
            refusal(&mut relay, request("py", PYTHON, GO, 1)),
            codes::VERSION_MISMATCH
        );
    }

    #[test]
    fn a_stale_or_unknown_context_is_refused() {
        let mut relay = relay();
        let mut stale = request("py", PYTHON, GO, 1);
        stale.context = json!({ "contextID": "workspace-1", "generation": 2 });
        assert_eq!(refusal(&mut relay, stale), codes::HOST_CONTEXT_EXPIRED);
        let mut unknown = request("py", PYTHON, GO, 2);
        unknown.context = json!({ "contextID": "workspace-9", "generation": 3 });
        assert_eq!(refusal(&mut relay, unknown), codes::HOST_CONTEXT_EXPIRED);
    }

    #[test]
    fn a_remote_workspace_is_refused() {
        let mut relay = relay();
        relay
            .configure(RelaySnapshot {
                plugins: vec![
                    plugin(PYTHON, &[], &[(FUNCTION, 1)]),
                    plugin(GO, &[(FUNCTION, 1)], &[]),
                ],
                contexts: vec![RelayContext {
                    authority: ContextAuthority::Remote,
                    ..local_context()
                }],
            })
            .unwrap();
        assert_eq!(
            refusal(&mut relay, request("py", PYTHON, GO, 1)),
            codes::HOST_AUTHORITY_UNSUPPORTED
        );
    }

    #[test]
    fn oversized_params_are_refused() {
        let mut relay = relay();
        let mut big = request("py", PYTHON, GO, 1);
        big.params = json!({ "text": "x".repeat(MAX_PARAMS_BYTES) });
        assert_eq!(refusal(&mut relay, big), codes::PAYLOAD_TOO_LARGE);
    }

    #[test]
    fn a_plugin_cannot_call_itself() {
        let mut relay = relay();
        relay
            .configure(RelaySnapshot {
                plugins: vec![plugin(GO, &[(FUNCTION, 1)], &[(FUNCTION, 1)])],
                contexts: vec![local_context()],
            })
            .unwrap();
        assert_eq!(
            refusal(&mut relay, request("go", GO, GO, 1)),
            codes::CALL_CYCLE
        );
    }

    /// Python calls Go; while Go serves that call it calls Python back.
    #[test]
    fn a_call_back_into_the_chain_is_a_cycle() {
        let mut relay = FunctionRelay::default();
        relay
            .configure(RelaySnapshot {
                plugins: vec![
                    plugin(PYTHON, &[(FUNCTION, 1)], &[(FUNCTION, 1)]),
                    plugin(GO, &[(FUNCTION, 1)], &[(FUNCTION, 1)]),
                ],
                contexts: vec![local_context()],
            })
            .unwrap();
        let now = Instant::now();
        running_call(&mut relay, request("py", PYTHON, GO, 1), "go-session", now);
        assert_eq!(
            refusal(&mut relay, request("go-session", GO, PYTHON, 2)),
            codes::CALL_CYCLE
        );
    }

    /// Six plugins in a line, each calling the next: the fifth hop is one too
    /// many.
    #[test]
    fn nesting_is_limited() {
        let (mut relay, names) = relay_with_calls_down_a_line(Instant::now());
        let last = MAX_CALL_DEPTH;
        assert_eq!(
            refusal(
                &mut relay,
                request(
                    &format!("session-{last}"),
                    &names[last],
                    &names[last + 1],
                    99
                )
            ),
            codes::DEPTH_EXCEEDED
        );
    }

    /// A call made while serving a host operation starts a new chain, so the
    /// calls the session is serving for other plugins neither make it a cycle
    /// nor make it too deep, and ending them does not cancel it.
    #[test]
    fn a_call_made_for_a_host_operation_starts_a_new_chain() {
        let now = Instant::now();
        let (mut relay, names) = relay_with_calls_down_a_line(now);
        let last = MAX_CALL_DEPTH;
        let last_session = format!("session-{last}");

        // With no named parent this is the depth error of `nesting_is_limited`.
        let deeper = running_call(
            &mut relay,
            request_from(
                CallParent::Root,
                &last_session,
                &names[last],
                &names[last + 1],
                98,
            ),
            "session-deeper",
            now,
        );
        assert_eq!(relay.calls[&deeper].chain, [names[last].as_str()]);
        assert!(relay.calls[&deeper].parents.is_empty());

        // With no named parent this would re-enter the first plugin: a cycle.
        let back = running_call(
            &mut relay,
            request_from(CallParent::Root, &last_session, &names[last], &names[0], 99),
            "session-back",
            now,
        );
        assert_eq!(relay.calls[&back].chain, [names[last].as_str()]);

        // Ending the first hop (call 1) of the line cancels the hops made
        // while serving it (call 4 is the last), but not the two calls that
        // started their own chain.
        let actions = relay.cancel_from_caller("session-0", &json!(0)).unwrap();
        assert!(actions.contains(&cancel_of("session-1", 1)));
        assert!(actions.contains(&cancel_of("session-4", 4)));
        assert!(!actions.contains(&cancel_of("session-deeper", deeper)));
        assert!(!actions.contains(&cancel_of("session-back", back)));
        assert!(relay.is_running(deeper));
        assert!(relay.is_running(back));
    }

    #[test]
    fn a_caller_has_a_limited_number_of_calls_in_flight() {
        let mut relay = relay();
        let now = Instant::now();
        for rpc_id in 0..MAX_CALLS_PER_CALLER {
            admitted_call(&mut relay, request("py", PYTHON, GO, rpc_id as i64), now);
        }
        assert_eq!(
            refusal(&mut relay, request("py-2", PYTHON, GO, 100)),
            codes::TOO_MANY_CALLS
        );
    }

    #[test]
    fn a_finished_call_frees_its_slot() {
        let mut relay = relay();
        let now = Instant::now();
        let mut calls = Vec::new();
        for rpc_id in 0..MAX_CALLS_PER_CALLER {
            calls.push(running_call(
                &mut relay,
                request("py", PYTHON, GO, rpc_id as i64),
                "go",
                now,
            ));
        }
        relay.callee_finished(
            "go",
            &format!("{OPERATION_PREFIX}{}", calls[0]),
            CalleeOutcome::Succeeded(json!(1)),
        );
        admitted_call(&mut relay, request("py", PYTHON, GO, 100), now);
    }

    #[test]
    fn a_result_is_wrapped_for_the_caller() {
        let mut relay = relay();
        let call_id = running_call(
            &mut relay,
            request("py", PYTHON, GO, 7),
            "go",
            Instant::now(),
        );
        let actions = relay.callee_finished(
            "go",
            &format!("{OPERATION_PREFIX}{call_id}"),
            CalleeOutcome::Succeeded(json!({ "name": "app" })),
        );
        assert_eq!(
            actions,
            vec![RelayAction::Reply {
                session_id: "py".to_string(),
                rpc_id: json!(7),
                outcome: Ok(json!({ "value": { "name": "app" } })),
            }]
        );
    }

    #[test]
    fn an_oversized_result_is_refused() {
        let mut relay = relay();
        let call_id = running_call(
            &mut relay,
            request("py", PYTHON, GO, 7),
            "go",
            Instant::now(),
        );
        let actions = relay.callee_finished(
            "go",
            &format!("{OPERATION_PREFIX}{call_id}"),
            CalleeOutcome::Succeeded(json!("x".repeat(MAX_RESULT_BYTES))),
        );
        match actions.as_slice() {
            [RelayAction::Reply {
                outcome: Err(failure),
                ..
            }] => {
                assert_eq!(failure.code, codes::PAYLOAD_TOO_LARGE)
            }
            other => panic!("expected one failed reply, got {other:?}"),
        }
    }

    #[test]
    fn callee_failures_map_to_distinct_codes() {
        let cases = [
            ("plugin.function.failed", codes::FAILED),
            ("plugin.function.invalidResult", codes::INVALID_RESULT),
            ("requestTimeout", codes::HOST_TIMEOUT),
            ("plugin.function.revoked", codes::PROVIDER_UNAVAILABLE),
            ("requestCancelled", codes::PROVIDER_UNAVAILABLE),
            ("serverExited", codes::PROVIDER_UNAVAILABLE),
        ];
        for (engine_code, expected) in cases {
            let mut relay = relay();
            let call_id = running_call(
                &mut relay,
                request("py", PYTHON, GO, 7),
                "go",
                Instant::now(),
            );
            let actions = relay.callee_finished(
                "go",
                &format!("{OPERATION_PREFIX}{call_id}"),
                CalleeOutcome::Failed {
                    code: engine_code.to_string(),
                    message: "no".to_string(),
                    plugin_error_code: Some("go.locked".to_string()),
                },
            );
            match actions.as_slice() {
                [RelayAction::Reply {
                    outcome: Err(failure),
                    ..
                }] => {
                    assert_eq!(failure.code, expected, "{engine_code}")
                }
                other => panic!("expected one failed reply, got {other:?}"),
            }
        }
    }

    #[test]
    fn a_failed_function_keeps_its_message_and_plugin_code() {
        let mut relay = relay();
        let call_id = running_call(
            &mut relay,
            request("py", PYTHON, GO, 7),
            "go",
            Instant::now(),
        );
        let actions = relay.callee_finished(
            "go",
            &format!("{OPERATION_PREFIX}{call_id}"),
            CalleeOutcome::Failed {
                code: codes::FAILED.to_string(),
                message: "Index is locked.".to_string(),
                plugin_error_code: Some("go.locked".to_string()),
            },
        );
        match actions.as_slice() {
            [RelayAction::Reply {
                outcome: Err(failure),
                ..
            }] => {
                assert_eq!(failure.message, "Index is locked.");
                assert_eq!(failure.plugin_error_code.as_deref(), Some("go.locked"));
            }
            other => panic!("expected one failed reply, got {other:?}"),
        }
    }

    #[test]
    fn an_unrelated_finish_changes_nothing() {
        let mut relay = relay();
        running_call(
            &mut relay,
            request("py", PYTHON, GO, 7),
            "go",
            Instant::now(),
        );
        let actions =
            relay.callee_finished("go", "lsp-operation-1", CalleeOutcome::Succeeded(json!(1)));
        assert!(actions.is_empty());
    }

    #[test]
    fn the_caller_cancelling_cancels_the_callee_and_is_answered() {
        let mut relay = relay();
        let call_id = running_call(
            &mut relay,
            request("py", PYTHON, GO, 7),
            "go",
            Instant::now(),
        );
        let actions = relay
            .cancel_from_caller("py", &json!(7))
            .expect("the request names a relayed call");
        assert_eq!(
            actions[0],
            RelayAction::CancelCallee {
                session_id: "go".to_string(),
                operation_id: format!("{OPERATION_PREFIX}{call_id}"),
            }
        );
        match &actions[1] {
            RelayAction::Reply {
                outcome: Err(failure),
                ..
            } => {
                assert_eq!(failure.code, codes::HOST_CANCELLED)
            }
            other => panic!("expected a cancelled reply, got {other:?}"),
        }
        assert!(relay.cancel_from_caller("py", &json!(7)).is_none());
    }

    #[test]
    fn a_cancelled_call_cancels_the_calls_made_while_serving_it() {
        let mut relay = FunctionRelay::default();
        relay
            .configure(RelaySnapshot {
                plugins: vec![
                    plugin(PYTHON, &[], &[(FUNCTION, 1)]),
                    plugin(GO, &[(FUNCTION, 1)], &[(FUNCTION, 1)]),
                    plugin("dev.lithe.zig", &[(FUNCTION, 1)], &[]),
                ],
                contexts: vec![local_context()],
            })
            .unwrap();
        let now = Instant::now();
        let parent = running_call(&mut relay, request("py", PYTHON, GO, 1), "go", now);
        let child = running_call(
            &mut relay,
            request("go", GO, "dev.lithe.zig", 2),
            "zig",
            now,
        );
        let actions = relay.cancel_from_caller("py", &json!(1)).unwrap();
        assert!(actions.contains(&RelayAction::CancelCallee {
            session_id: "go".to_string(),
            operation_id: format!("{OPERATION_PREFIX}{parent}"),
        }));
        assert!(actions.contains(&RelayAction::CancelCallee {
            session_id: "zig".to_string(),
            operation_id: format!("{OPERATION_PREFIX}{child}"),
        }));
        // Both ends were answered once.
        let replies = actions
            .iter()
            .filter(|action| matches!(action, RelayAction::Reply { .. }))
            .count();
        assert_eq!(replies, 2);
    }

    /// Go serves a call from Python and one from Ruby at once and calls Zig
    /// while serving each. Because each request names its parent, ending the
    /// Python call must not cancel the Zig call made for the Ruby call.
    #[test]
    fn a_named_parent_scopes_the_chain_and_the_cancellation_to_that_call() {
        let mut relay = relay_with_two_callers_of_go();
        let now = Instant::now();
        let from_python = running_call(&mut relay, request("py", PYTHON, GO, 1), "go", now);
        let from_ruby = running_call(&mut relay, request("rb", RUBY, GO, 2), "go", now);
        let zig_for_python = running_call(
            &mut relay,
            request_from(CallParent::Relay(from_python), "go", GO, ZIG, 3),
            "zig-1",
            now,
        );
        let zig_for_ruby = running_call(
            &mut relay,
            request_from(CallParent::Relay(from_ruby), "go", GO, ZIG, 4),
            "zig-2",
            now,
        );

        // Each chain is the named call's chain plus the caller, nothing from
        // the sibling call.
        assert_eq!(relay.calls[&zig_for_python].chain, [PYTHON, GO]);
        assert_eq!(
            relay.calls[&zig_for_python].parents,
            BTreeSet::from([from_python])
        );
        assert_eq!(relay.calls[&zig_for_ruby].chain, [RUBY, GO]);
        assert_eq!(
            relay.calls[&zig_for_ruby].parents,
            BTreeSet::from([from_ruby])
        );

        let actions = relay.cancel_from_caller("py", &json!(1)).unwrap();
        assert!(actions.contains(&cancel_of("go", from_python)));
        assert!(actions.contains(&cancel_of("zig-1", zig_for_python)));
        assert!(!actions.contains(&cancel_of("zig-2", zig_for_ruby)));
        // Python and Go were each answered once; Ruby's side saw nothing.
        assert_eq!(
            failed_reply_codes(&actions),
            [codes::HOST_CANCELLED, codes::HOST_CANCELLED]
        );
        assert!(relay.is_running(from_ruby));
        assert!(relay.is_running(zig_for_ruby));
        assert!(!relay.is_running(zig_for_python));
    }

    /// Without a named parent a call belongs to every call its session serves,
    /// so it ends only when all of them have ended.
    #[test]
    fn a_request_naming_no_parent_belongs_to_every_call_its_session_serves() {
        let mut relay = relay_with_two_callers_of_go();
        let now = Instant::now();
        let from_python = running_call(&mut relay, request("py", PYTHON, GO, 1), "go", now);
        let from_ruby = running_call(&mut relay, request("rb", RUBY, GO, 2), "go", now);
        let zig = running_call(&mut relay, request("go", GO, ZIG, 3), "zig", now);

        assert_eq!(relay.calls[&zig].chain, [PYTHON, RUBY, GO]);
        assert_eq!(
            relay.calls[&zig].parents,
            BTreeSet::from([from_python, from_ruby])
        );
        let first = relay.cancel_from_caller("py", &json!(1)).unwrap();
        assert!(!first.contains(&cancel_of("zig", zig)));
        let second = relay.cancel_from_caller("rb", &json!(2)).unwrap();
        assert!(second.contains(&cancel_of("zig", zig)));
    }

    /// A parent the caller's session is not running can no longer be what the
    /// request belongs to: the request is refused instead of being tied to
    /// some other call.
    #[test]
    fn a_parent_that_is_not_running_in_the_callers_session_is_refused() {
        let mut relay = relay_with_two_callers_of_go();
        let now = Instant::now();
        let waiting = admitted_call(&mut relay, request("py", PYTHON, GO, 1), now);
        relay.wait_for_provider(waiting, now);
        let served = running_call(&mut relay, request("rb", RUBY, GO, 2), "go", now);

        let ended = request_from(CallParent::Ended, "go", GO, ZIG, 3);
        assert_eq!(refusal(&mut relay, ended), codes::HOST_CANCELLED);
        let unknown = request_from(CallParent::Relay(99), "go", GO, ZIG, 4);
        assert_eq!(refusal(&mut relay, unknown), codes::HOST_CANCELLED);
        // The call is served by the session "go", not by another session of Go.
        let elsewhere = request_from(CallParent::Relay(served), "go-2", GO, ZIG, 5);
        assert_eq!(refusal(&mut relay, elsewhere), codes::HOST_CANCELLED);
        // No session serves a call that still waits for its provider.
        let not_started = request_from(CallParent::Relay(waiting), "go", GO, ZIG, 6);
        assert_eq!(refusal(&mut relay, not_started), codes::HOST_CANCELLED);
        // Refused requests leave no call behind.
        assert_eq!(relay.calls.len(), 2);

        // The same request from the session that serves the call is admitted.
        admitted_call(
            &mut relay,
            request_from(CallParent::Relay(served), "go", GO, ZIG, 7),
            now,
        );
    }

    #[test]
    fn a_caller_session_ending_cancels_its_callee_without_a_reply() {
        let mut relay = relay();
        let call_id = running_call(
            &mut relay,
            request("py", PYTHON, GO, 7),
            "go",
            Instant::now(),
        );
        let actions = relay.session_ended("py");
        assert_eq!(
            actions,
            vec![RelayAction::CancelCallee {
                session_id: "go".to_string(),
                operation_id: format!("{OPERATION_PREFIX}{call_id}"),
            }]
        );
    }

    #[test]
    fn a_callee_session_ending_fails_the_call_for_its_caller() {
        let mut relay = relay();
        running_call(
            &mut relay,
            request("py", PYTHON, GO, 7),
            "go",
            Instant::now(),
        );
        let actions = relay.session_ended("go");
        match actions.as_slice() {
            [RelayAction::Reply {
                session_id,
                outcome: Err(failure),
                ..
            }] => {
                assert_eq!(session_id, "py");
                assert_eq!(failure.code, codes::PROVIDER_UNAVAILABLE);
            }
            other => panic!("expected one failed reply, got {other:?}"),
        }
    }

    #[test]
    fn a_call_waits_for_a_provider_and_is_dispatched_when_one_appears() {
        let mut relay = relay();
        let now = Instant::now();
        let call_id = admitted_call(&mut relay, request("py", PYTHON, GO, 7), now);
        let notice = relay
            .wait_for_provider(call_id, now)
            .expect("first wait asks for a start");
        assert_eq!(notice.caller_session, "py");
        assert_eq!(notice.callee_plugin, GO);
        assert!(relay.wait_for_provider(call_id, now).is_none());
        assert!(relay.provider_changed("dev.lithe.other").is_empty());
        assert_eq!(
            relay.provider_changed(GO),
            vec![RelayAction::Dispatch { call_id }]
        );
    }

    #[test]
    fn a_provider_that_never_starts_ends_the_call() {
        let mut relay = relay();
        let now = Instant::now();
        let call_id = admitted_call(&mut relay, request("py", PYTHON, GO, 7), now);
        relay.wait_for_provider(call_id, now);
        assert!(relay
            .expire(now + PROVIDER_START_TIMEOUT - Duration::from_secs(1))
            .is_empty());
        match relay.expire(now + PROVIDER_START_TIMEOUT).as_slice() {
            [RelayAction::Reply {
                outcome: Err(failure),
                ..
            }] => {
                assert_eq!(failure.code, codes::PROVIDER_UNAVAILABLE)
            }
            other => panic!("expected one failed reply, got {other:?}"),
        }
    }

    #[test]
    fn retrying_a_wait_does_not_extend_it() {
        let mut relay = relay();
        let now = Instant::now();
        let call_id = admitted_call(&mut relay, request("py", PYTHON, GO, 7), now);
        relay.wait_for_provider(call_id, now);
        relay.provider_changed(GO);
        relay.wait_for_provider(call_id, now + Duration::from_secs(20));
        assert_eq!(relay.expire(now + PROVIDER_START_TIMEOUT).len(), 1);
    }

    #[test]
    fn a_call_out_of_time_before_it_started_times_out() {
        let mut relay = relay();
        let now = Instant::now();
        let mut short = request("py", PYTHON, GO, 7);
        short.timeout = Some(Duration::from_secs(10));
        let call_id = admitted_call(&mut relay, short, now);
        relay.wait_for_provider(call_id, now);
        assert!(relay.expire(now + Duration::from_secs(9)).is_empty());
        match relay.expire(now + Duration::from_secs(10)).as_slice() {
            [RelayAction::Reply {
                outcome: Err(failure),
                ..
            }] => {
                assert_eq!(failure.code, codes::HOST_TIMEOUT)
            }
            other => panic!("expected one failed reply, got {other:?}"),
        }
    }

    /// The callee session enforces the same deadline and answers with its own
    /// timeout, so the relay must not end a running call before `RUNNING_GRACE`
    /// after the deadline has passed.
    #[test]
    fn a_running_call_is_left_to_its_session_until_the_grace_ends() {
        let mut relay = relay();
        let now = Instant::now();
        let call_id = running_call(&mut relay, request("py", PYTHON, GO, 7), "go", now);
        let deadline = now + DEFAULT_TIMEOUT;
        assert!(relay.expire(deadline - Duration::from_secs(1)).is_empty());
        assert!(relay.expire(deadline).is_empty());
        assert!(relay
            .expire(deadline + RUNNING_GRACE - Duration::from_millis(1))
            .is_empty());
        assert!(relay.is_running(call_id));
    }

    /// A callee that never answers, even with its own timeout, must not leave
    /// the call open: the relay ends it and cancels the callee.
    #[test]
    fn a_running_call_whose_callee_never_answers_times_out_after_the_grace() {
        let mut relay = relay();
        let now = Instant::now();
        let call_id = running_call(&mut relay, request("py", PYTHON, GO, 7), "go", now);
        let actions = relay.expire(now + DEFAULT_TIMEOUT + RUNNING_GRACE);
        assert_eq!(actions.len(), 2);
        assert_eq!(actions[0], cancel_of("go", call_id));
        assert_eq!(failed_reply_codes(&actions), [codes::HOST_TIMEOUT]);
        assert!(!relay.is_running(call_id));
        // The call is gone, so a later sweep has nothing left to end.
        assert!(relay.expire(now + MAX_TIMEOUT).is_empty());
    }

    /// The provider-start limit only applies while the call waits for a
    /// backend; once the callee runs it, that older limit must not end it.
    #[test]
    fn a_call_that_waited_for_its_provider_is_not_ended_by_that_wait_once_running() {
        let mut relay = relay();
        let now = Instant::now();
        let call_id = admitted_call(&mut relay, request("py", PYTHON, GO, 7), now);
        relay.wait_for_provider(call_id, now);
        assert!(relay.started(call_id, "go", &format!("{OPERATION_PREFIX}{call_id}")));
        assert!(relay.expire(now + PROVIDER_START_TIMEOUT).is_empty());
        assert!(relay.is_running(call_id));
    }

    #[test]
    fn a_call_is_running_only_while_its_callee_session_has_it() {
        let mut relay = relay();
        let now = Instant::now();
        assert!(!relay.is_running(1));
        let call_id = admitted_call(&mut relay, request("py", PYTHON, GO, 7), now);
        assert!(!relay.is_running(call_id));
        relay.wait_for_provider(call_id, now);
        assert!(!relay.is_running(call_id));
        let operation_id = format!("{OPERATION_PREFIX}{call_id}");
        assert!(relay.started(call_id, "go", &operation_id));
        assert!(relay.is_running(call_id));
        relay.callee_finished("go", &operation_id, CalleeOutcome::Succeeded(json!(1)));
        assert!(!relay.is_running(call_id));
    }

    #[test]
    fn disabling_the_provider_ends_calls_in_flight() {
        let mut relay = relay();
        let call_id = running_call(
            &mut relay,
            request("py", PYTHON, GO, 7),
            "go",
            Instant::now(),
        );
        let actions = relay
            .configure(RelaySnapshot {
                plugins: vec![plugin(PYTHON, &[], &[(FUNCTION, 1)])],
                contexts: vec![local_context()],
            })
            .unwrap();
        assert!(actions.contains(&RelayAction::CancelCallee {
            session_id: "go".to_string(),
            operation_id: format!("{OPERATION_PREFIX}{call_id}"),
        }));
        match actions.last() {
            Some(RelayAction::Reply {
                outcome: Err(failure),
                ..
            }) => {
                assert_eq!(failure.code, codes::PROVIDER_DISABLED)
            }
            other => panic!("expected a failed reply, got {other:?}"),
        }
    }

    #[test]
    fn a_caller_that_stops_declaring_ends_its_calls() {
        let mut relay = relay();
        running_call(
            &mut relay,
            request("py", PYTHON, GO, 7),
            "go",
            Instant::now(),
        );
        let actions = relay
            .configure(RelaySnapshot {
                plugins: vec![plugin(PYTHON, &[], &[]), plugin(GO, &[(FUNCTION, 1)], &[])],
                contexts: vec![local_context()],
            })
            .unwrap();
        match actions.last() {
            Some(RelayAction::Reply {
                outcome: Err(failure),
                ..
            }) => {
                assert_eq!(failure.code, codes::NOT_DECLARED)
            }
            other => panic!("expected a failed reply, got {other:?}"),
        }
    }

    #[test]
    fn an_unchanged_snapshot_keeps_calls_running() {
        let mut relay = relay();
        running_call(
            &mut relay,
            request("py", PYTHON, GO, 7),
            "go",
            Instant::now(),
        );
        let actions = relay
            .configure(RelaySnapshot {
                plugins: vec![
                    plugin(PYTHON, &[], &[(FUNCTION, 1)]),
                    plugin(GO, &[(FUNCTION, 1)], &[]),
                ],
                contexts: vec![local_context()],
            })
            .unwrap();
        assert!(actions.is_empty());
    }

    /// A snapshot that drops a workspace context, or replaces it with a newer
    /// generation, ends the calls made in it even while they wait for a
    /// backend, so they cannot be dispatched into a context that is gone.
    #[test]
    fn a_waiting_call_ends_when_its_context_closes_or_changes_generation() {
        let new_contexts = [
            ("closed", vec![]),
            (
                "new generation",
                vec![RelayContext {
                    generation: 4,
                    ..local_context()
                }],
            ),
        ];
        for (label, contexts) in new_contexts {
            let mut relay = relay();
            let now = Instant::now();
            let call_id = admitted_call(&mut relay, request("py", PYTHON, GO, 7), now);
            relay.wait_for_provider(call_id, now);
            let actions = relay.configure(snapshot_with_contexts(contexts)).unwrap();
            // The callee never had the call, so there is nothing to cancel.
            assert_eq!(actions.len(), 1, "{label}");
            assert_eq!(
                failed_reply_codes(&actions),
                [codes::HOST_CONTEXT_EXPIRED],
                "{label}"
            );
            assert!(relay.dispatch_plan(call_id, now).is_none(), "{label}");
            assert!(relay.provider_changed(GO).is_empty(), "{label}");
        }
    }

    /// The same snapshot also stops a call its callee is already running.
    #[test]
    fn a_running_call_ends_when_its_context_closes_or_changes_generation() {
        let new_contexts = [
            ("closed", vec![]),
            (
                "new generation",
                vec![RelayContext {
                    generation: 4,
                    ..local_context()
                }],
            ),
        ];
        for (label, contexts) in new_contexts {
            let mut relay = relay();
            let now = Instant::now();
            let call_id = running_call(&mut relay, request("py", PYTHON, GO, 7), "go", now);
            let actions = relay.configure(snapshot_with_contexts(contexts)).unwrap();
            assert_eq!(actions.len(), 2, "{label}");
            assert_eq!(actions[0], cancel_of("go", call_id), "{label}");
            assert_eq!(
                failed_reply_codes(&actions),
                [codes::HOST_CONTEXT_EXPIRED],
                "{label}"
            );
            assert!(!relay.is_running(call_id), "{label}");
        }
    }

    #[test]
    fn a_malformed_snapshot_is_rejected_and_changes_nothing() {
        let mut relay = relay();
        let duplicate = RelaySnapshot {
            plugins: vec![plugin(GO, &[], &[]), plugin(GO, &[], &[])],
            contexts: vec![],
        };
        assert!(relay.configure(duplicate).is_err());
        let bad_function = RelaySnapshot {
            plugins: vec![plugin(GO, &[("Not A Function", 1)], &[])],
            contexts: vec![],
        };
        assert!(relay.configure(bad_function).is_err());
        // The earlier snapshot still stands.
        assert!(relay.providers(PYTHON, FUNCTION).is_ok());
    }
}
