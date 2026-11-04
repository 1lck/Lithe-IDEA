//! Session policy of a plugin-owned language server (plan API-25).
//!
//! A plugin backend reaches its own language server only through the host:
//! it asks for `lithe/host/languageServer/request` or `notify`, and the host
//! passes the call to Core. This module is the policy those calls obey. It
//! decides, without touching the process or the clock, whether a call may
//! be sent, must wait for a gate, or joins a command that already runs, and
//! it tracks which operations it owns until the engine completes them.
//!
//! The engine stays the only writer to the server: it asks this module for a
//! verdict under its session lock, then allocates the JSON-RPC request,
//! registers the pending entry, and sends it. Ownership of an operation ends
//! in exactly one place, `finish`, which the engine calls when it publishes
//! the operation's `requestCompleted` event. Cancelling, timing out, and
//! failing the session therefore only pick the operations to complete.

use super::plugin_function::{codes, MAX_HOST_NOTIFICATION_BYTES};
use crate::plugins::language_server_sessions::{
    is_protocol_name, matches_pattern, Gate, RemoteSupport, DID_CHANGE_CONFIGURATION,
    EXECUTE_COMMAND,
};
use crate::protocol::{CoreError, ErrorCode};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::time::Instant;

/// Most requests that may wait at once, held behind a gate or joined to a
/// running command. More would only queue work behind a server that has not
/// reached the state the plugin asked to wait for.
const MAX_WAITING_REQUESTS: usize = 128;

/// Bounds of a policy received from the host. Core derives the policy from
/// a validated manifest and a launch answer, but `lsp.startServer` is also a
/// public command, so the engine bounds it again.
const MAX_REQUEST_METHODS: usize = 64;
const MAX_COMMANDS: usize = 128;
const MAX_FORWARD_NOTIFICATIONS: usize = 32;
const MAX_GATES: usize = 8;

/// What the engine enforces for one plugin-owned server. It arrives as
/// `sessionPolicy` of `lsp.startServer`, built from the plugin's declaration
/// and, for a backend launch, the gates of the launch answer.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SessionPolicy {
    /// The server's ID in the plugin's manifest; the key a backend uses.
    #[serde(rename = "serverID")]
    pub server_id: String,
    /// Requests and notifications the backend may send to the server.
    #[serde(default)]
    pub request_methods: BTreeSet<String>,
    /// Commands the backend may run through `workspace/executeCommand`.
    #[serde(default)]
    pub commands: BTreeSet<String>,
    /// Commands that run one at a time; a second request joins the first.
    #[serde(default)]
    pub serialized_commands: BTreeSet<String>,
    /// Server notifications forwarded to the backend.
    #[serde(default)]
    pub forward_notifications: BTreeSet<String>,
    /// Whether the server may serve a remote workspace.
    #[serde(default)]
    pub remote: RemoteSupport,
    /// Notifications the server must send before requests are sent.
    #[serde(default)]
    pub gates: Vec<Gate>,
    /// Retention of the server's state directories. The host keeps and
    /// prunes the directories, so the engine only accepts the field.
    #[serde(default, rename = "state")]
    _state: Option<serde::de::IgnoredAny>,
}

impl SessionPolicy {
    /// Checks the bounds of a policy that a plugin-owned session received.
    pub(super) fn validate(&self, plugin_id: Option<&str>) -> Result<(), CoreError> {
        let invalid = |field: &str| {
            CoreError::new(
                ErrorCode::InvalidRequest,
                "Invalid language-server start request.",
            )
            .with_details(format!("sessionPolicy/{field}"))
        };
        if plugin_id.is_none() || !is_protocol_name(&self.server_id) {
            return Err(invalid("serverID"));
        }
        let names_ok = |names: &BTreeSet<String>, limit: usize| {
            names.len() <= limit && names.iter().all(|name| is_protocol_name(name))
        };
        if !names_ok(&self.request_methods, MAX_REQUEST_METHODS) {
            return Err(invalid("requestMethods"));
        }
        if !names_ok(&self.commands, MAX_COMMANDS) {
            return Err(invalid("commands"));
        }
        if !names_ok(&self.serialized_commands, MAX_COMMANDS)
            || !self.serialized_commands.is_subset(&self.commands)
        {
            return Err(invalid("serializedCommands"));
        }
        if !names_ok(&self.forward_notifications, MAX_FORWARD_NOTIFICATIONS) {
            return Err(invalid("forwardNotifications"));
        }
        let gate_ids: BTreeSet<&str> = self.gates.iter().map(|gate| gate.id.as_str()).collect();
        if self.gates.len() > MAX_GATES
            || gate_ids.len() != self.gates.len()
            || self
                .gates
                .iter()
                .any(|gate| !is_protocol_name(&gate.method))
        {
            return Err(invalid("gates"));
        }
        Ok(())
    }
}

/// A request that waits for its gates to open. Core allocates the JSON-RPC
/// request only when the gates open, so cancelling it writes nothing.
#[derive(Debug, Clone)]
pub(super) struct HeldRequest {
    pub operation_id: String,
    pub method: String,
    pub params: Value,
    pub created_at: Instant,
    pub deadline: Instant,
}

/// An operation that must be completed, with the method its event names.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Waiter {
    pub operation_id: String,
    pub method: String,
}

/// What the engine does with an admitted request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Admission {
    /// Allocate the request and write it to the server now.
    Send,
    /// The request waits in the policy until a gate opens.
    Held,
    /// A serialized command is already running; this request completes with
    /// the same result or error as the first one.
    Joined,
}

/// One request being admitted.
pub(super) struct Arrival<'a> {
    pub operation_id: &'a str,
    pub method: &'a str,
    pub params: &'a Value,
    pub now: Instant,
    pub deadline: Instant,
}

/// What a server notification changed in the policy.
#[derive(Debug, Default)]
pub(super) struct Observation {
    /// The `pluginServerNotification` result to publish for the backend.
    pub forward: Option<Value>,
    /// Requests whose gates are now open, in arrival order.
    pub released: Vec<HeldRequest>,
}

/// An operation the policy owns until the engine finishes it.
#[derive(Debug)]
struct Owned {
    method: String,
    /// The serialized command the operation runs or joined, if any.
    serialized_command: Option<String>,
}

/// The first request of a serialized command and the ones that joined it.
#[derive(Debug)]
struct RunningCommand {
    leader: String,
    joiners: Vec<String>,
}

/// Mutable part of the policy: gates opened so far, requests waiting for
/// them, and serialized commands in flight.
#[derive(Debug)]
pub(super) struct PluginServerState {
    policy: SessionPolicy,
    open_gates: BTreeSet<String>,
    held: VecDeque<HeldRequest>,
    running: BTreeMap<String, RunningCommand>,
    owned: BTreeMap<String, Owned>,
}

impl PluginServerState {
    pub(super) fn new(policy: SessionPolicy) -> Self {
        Self {
            policy,
            open_gates: BTreeSet::new(),
            held: VecDeque::new(),
            running: BTreeMap::new(),
            owned: BTreeMap::new(),
        }
    }

    /// Refuses a call that names another plugin or another server than the
    /// one this session runs. The host resolves the server by ID, so a
    /// mismatch means it resolved a session of a different contribution.
    pub(super) fn check_owner(
        &self,
        session_plugin_id: Option<&str>,
        plugin_id: &str,
        server_id: &str,
    ) -> Result<(), CoreError> {
        if session_plugin_id == Some(plugin_id) && self.policy.server_id == server_id {
            return Ok(());
        }
        Err(foreign_contribution())
    }

    /// Decides what happens to a request the backend sent to the server.
    pub(super) fn admit_request(&mut self, arrival: Arrival<'_>) -> Result<Admission, CoreError> {
        if !self.policy.request_methods.contains(arrival.method) {
            return Err(not_declared("The language-server method is not declared."));
        }
        if byte_size(arrival.params) > MAX_HOST_NOTIFICATION_BYTES {
            return Err(too_large());
        }
        let serialized = self.serialized_command(arrival.method, arrival.params)?;
        let joins = serialized
            .as_ref()
            .is_some_and(|command| self.running.contains_key(command));
        let gated = !self.gates_open();
        if (joins || gated) && self.waiting() >= MAX_WAITING_REQUESTS {
            return Err(refusal(
                ErrorCode::Unknown,
                "Too many language-server requests are waiting.",
                codes::HOST_BUSY,
            ));
        }
        self.owned.insert(
            arrival.operation_id.to_string(),
            Owned {
                method: arrival.method.to_string(),
                serialized_command: serialized.clone(),
            },
        );
        if let Some(command) = serialized {
            if let Some(running) = self.running.get_mut(&command) {
                running.joiners.push(arrival.operation_id.to_string());
                return Ok(Admission::Joined);
            }
            self.running.insert(
                command,
                RunningCommand {
                    leader: arrival.operation_id.to_string(),
                    joiners: Vec::new(),
                },
            );
        }
        if gated {
            self.held.push_back(HeldRequest {
                operation_id: arrival.operation_id.to_string(),
                method: arrival.method.to_string(),
                params: arrival.params.clone(),
                created_at: arrival.now,
                deadline: arrival.deadline,
            });
            return Ok(Admission::Held);
        }
        Ok(Admission::Send)
    }

    /// Decides whether a notification may be sent. Gates never hold a
    /// notification: it carries no answer a backend waits for, and the
    /// configuration notification may be exactly what opens a gate.
    pub(super) fn admit_notification(&self, method: &str, params: &Value) -> Result<(), CoreError> {
        // A command is only run as a request, where it is checked against
        // the declared commands.
        let declared = method == DID_CHANGE_CONFIGURATION
            || (method != EXECUTE_COMMAND && self.policy.request_methods.contains(method));
        if !declared {
            return Err(not_declared("The language-server method is not declared."));
        }
        if byte_size(params) > MAX_HOST_NOTIFICATION_BYTES {
            return Err(too_large());
        }
        Ok(())
    }

    /// Applies a notification the server sent: it may open gates and may
    /// be one the backend asked to receive.
    pub(super) fn observe(&mut self, method: &str, params: &Value) -> Observation {
        for gate in &self.policy.gates {
            if gate.method == method && matches_pattern(params, &gate.pattern) {
                self.open_gates.insert(gate.id.clone());
            }
        }
        let released: Vec<HeldRequest> = if self.gates_open() {
            self.held.drain(..).collect()
        } else {
            Vec::new()
        };
        let forward = self
            .policy
            .forward_notifications
            .contains(method)
            .then(|| self.forwarded(method, params));
        Observation { forward, released }
    }

    /// Whether the operation has no request on the wire: it waits behind a
    /// gate or joined another request. Cancelling it only completes it.
    pub(super) fn is_unsent(&self, operation_id: &str) -> bool {
        if self
            .held
            .iter()
            .any(|held| held.operation_id == operation_id)
        {
            return true;
        }
        self.owned
            .get(operation_id)
            .and_then(|owned| owned.serialized_command.as_ref())
            .and_then(|command| self.running.get(command))
            .is_some_and(|running| running.leader != operation_id)
    }

    /// Whether the operation came through `admit_request` and is not done.
    pub(super) fn owns(&self, operation_id: &str) -> bool {
        self.owned.contains_key(operation_id)
    }

    /// Requests whose deadline passed while they waited for a gate. Their
    /// ownership ends when the engine finishes them.
    pub(super) fn expired_held(&self, now: Instant) -> Vec<Waiter> {
        self.held
            .iter()
            .filter(|held| now >= held.deadline)
            .map(HeldRequest::waiter)
            .collect()
    }

    /// Every request still waiting for a gate, for a session that ended.
    pub(super) fn all_held(&self) -> Vec<Waiter> {
        self.held.iter().map(HeldRequest::waiter).collect()
    }

    /// Ends the policy's ownership of an operation the engine completes and
    /// returns the requests that joined it, which complete the same way. A
    /// joiner that finishes on its own (cancelled) just leaves the list.
    pub(super) fn finish(&mut self, operation_id: &str) -> Vec<Waiter> {
        self.held.retain(|held| held.operation_id != operation_id);
        let Some(owned) = self.owned.remove(operation_id) else {
            return Vec::new();
        };
        let Some(command) = owned.serialized_command else {
            return Vec::new();
        };
        let leads = self
            .running
            .get(&command)
            .is_some_and(|running| running.leader == operation_id);
        if !leads {
            if let Some(running) = self.running.get_mut(&command) {
                running.joiners.retain(|joiner| joiner != operation_id);
            }
            return Vec::new();
        }
        let Some(running) = self.running.remove(&command) else {
            return Vec::new();
        };
        running
            .joiners
            .into_iter()
            .filter_map(|joiner| {
                self.owned.remove(&joiner).map(|owned| Waiter {
                    operation_id: joiner,
                    method: owned.method,
                })
            })
            .collect()
    }

    /// The method a finished operation was admitted with.
    pub(super) fn method_of(&self, operation_id: &str) -> Option<&str> {
        self.owned
            .get(operation_id)
            .map(|owned| owned.method.as_str())
    }

    /// The command of an `executeCommand` request that must be serialized.
    fn serialized_command(
        &self,
        method: &str,
        params: &Value,
    ) -> Result<Option<String>, CoreError> {
        if method != EXECUTE_COMMAND {
            return Ok(None);
        }
        let command = params
            .get("command")
            .and_then(Value::as_str)
            .filter(|command| self.policy.commands.contains(*command))
            .ok_or_else(|| not_declared("The language-server command is not declared."))?;
        Ok(self
            .policy
            .serialized_commands
            .contains(command)
            .then(|| command.to_string()))
    }

    fn gates_open(&self) -> bool {
        self.policy
            .gates
            .iter()
            .all(|gate| self.open_gates.contains(&gate.id))
    }

    /// Requests that wait without being on the wire.
    fn waiting(&self) -> usize {
        self.held.len()
            + self
                .running
                .values()
                .map(|running| running.joiners.len())
                .sum::<usize>()
    }

    /// The result a forwarded notification carries. An oversized payload
    /// keeps only the fact that it happened, so the backend can ask for
    /// the state it needs instead of receiving a truncated message.
    fn forwarded(&self, method: &str, params: &Value) -> Value {
        if byte_size(params) > MAX_HOST_NOTIFICATION_BYTES {
            return json!({
                "serverID": self.policy.server_id,
                "method": method,
                "truncated": true,
            });
        }
        json!({
            "serverID": self.policy.server_id,
            "method": method,
            "params": params,
        })
    }
}

impl HeldRequest {
    fn waiter(&self) -> Waiter {
        Waiter {
            operation_id: self.operation_id.clone(),
            method: self.method.clone(),
        }
    }
}

/// The `plugin.host.*` code a backend sees for a failure the engine reports
/// with its own runtime code. Anything that ends a request without an
/// answer from the server means the server is not usable now.
pub(super) fn host_error_code(runtime_code: &str) -> &str {
    match runtime_code {
        "requestTimeout" => codes::HOST_TIMEOUT,
        "requestCancelled" => codes::HOST_CANCELLED,
        code if code.starts_with("plugin.host.") => code,
        _ => codes::HOST_LANGUAGE_SERVER_UNAVAILABLE,
    }
}

/// Marks locations that are not files as read-only and gives them a path to
/// show. The host opens such a location through the plugin's content
/// provider, so it can never write the document back.
pub(super) fn normalize_navigation_result(mut result: Option<Value>) -> Option<Value> {
    let locations = result
        .as_mut()
        .and_then(|result| result.get_mut("locations"))
        .and_then(Value::as_array_mut);
    for location in locations.into_iter().flatten() {
        let Some(uri) = location
            .get("uri")
            .and_then(Value::as_str)
            .map(str::to_string)
        else {
            continue;
        };
        if is_file_uri(&uri) {
            continue;
        }
        location["isReadOnly"] = Value::Bool(true);
        location["displayPath"] = display_path(&uri).map_or(Value::Null, Value::String);
    }
    result
}

fn is_file_uri(uri: &str) -> bool {
    uri.split_once(':')
        .is_some_and(|(scheme, _)| scheme.eq_ignore_ascii_case("file"))
}

/// The path of a URI as people read it: without scheme, authority, query,
/// or fragment, and with escapes decoded.
fn display_path(uri: &str) -> Option<String> {
    let (_, remainder) = uri.split_once(':')?;
    let path = match remainder.strip_prefix("//") {
        Some(with_authority) => &with_authority[with_authority.find('/')? + 1..],
        None => remainder.trim_start_matches('/'),
    };
    let path = path.split(['?', '#']).next().unwrap_or(path);
    let decoded = super::client::percent_decode(path);
    let components: Vec<&str> = decoded
        .split('/')
        .filter(|component| !component.is_empty())
        .collect();
    (!components.is_empty()).then(|| components.join("/"))
}

fn byte_size(value: &Value) -> usize {
    serde_json::to_vec(value).map_or(usize::MAX, |bytes| bytes.len())
}

/// The refusal for a call that reached a session of another contribution,
/// or a session that is no plugin-owned language server at all.
pub(super) fn foreign_contribution() -> CoreError {
    refusal(
        ErrorCode::PermissionDenied,
        "The language server belongs to another contribution.",
        codes::HOST_FOREIGN_CONTRIBUTION,
    )
}

/// The refusal for a call to a server that is not running yet or any more.
pub(super) fn unavailable() -> CoreError {
    refusal(
        ErrorCode::InvalidRequest,
        "The language server is not ready.",
        codes::HOST_LANGUAGE_SERVER_UNAVAILABLE,
    )
}

fn not_declared(message: &str) -> CoreError {
    refusal(
        ErrorCode::PermissionDenied,
        message,
        codes::HOST_METHOD_NOT_DECLARED,
    )
}

fn too_large() -> CoreError {
    refusal(
        ErrorCode::InvalidRequest,
        "The language-server message is too large.",
        codes::HOST_LIMIT_EXCEEDED,
    )
}

fn refusal(category: ErrorCode, message: &str, code: &str) -> CoreError {
    CoreError::new(category, message).with_details(code)
}

#[cfg(test)]
mod tests {
    //! Policies of two unrelated servers, so no case depends on one
    //! language: a Metals-like server with a build command that must run
    //! one at a time and a gate, and a rust-analyzer-like server without
    //! either.

    use super::*;
    use std::time::Duration;

    fn metals() -> SessionPolicy {
        serde_json::from_value(json!({
            "serverID": "metals",
            "requestMethods": [
                "textDocument/definition",
                "workspace/executeCommand",
            ],
            "commands": ["build-import", "build-connect"],
            "serializedCommands": ["build-import"],
            "forwardNotifications": ["metals/status"],
            "remote": "unsupported",
            "gates": [{
                "id": "imported",
                "until": "notification",
                "method": "metals/status",
                "match": { "text": "ready" },
            }],
        }))
        .unwrap()
    }

    fn rust_analyzer() -> SessionPolicy {
        serde_json::from_value(json!({
            "serverID": "rust-analyzer",
            "requestMethods": ["experimental/runnables", "textDocument/definition"],
        }))
        .unwrap()
    }

    fn arrival<'a>(operation_id: &'a str, method: &'a str, params: &'a Value) -> Arrival<'a> {
        let now = Instant::now();
        Arrival {
            operation_id,
            method,
            params,
            now,
            deadline: now + Duration::from_secs(60),
        }
    }

    fn command(name: &str) -> Value {
        json!({ "command": name, "arguments": [] })
    }

    fn open_gate(state: &mut PluginServerState) -> Observation {
        state.observe("metals/status", &json!({ "text": "ready", "level": 1 }))
    }

    fn detail(error: CoreError) -> String {
        error.details.unwrap_or_default()
    }

    #[test]
    fn declared_request_is_sent_without_gates() {
        let mut state = PluginServerState::new(rust_analyzer());
        let params = json!({});
        let admission = state
            .admit_request(arrival("op-1", "experimental/runnables", &params))
            .unwrap();
        assert_eq!(admission, Admission::Send);
        assert!(state.owns("op-1"));
    }

    #[test]
    fn undeclared_method_is_refused() {
        let mut state = PluginServerState::new(rust_analyzer());
        let params = json!({});
        let error = state
            .admit_request(arrival("op-1", "textDocument/rename", &params))
            .unwrap_err();
        assert_eq!(detail(error), codes::HOST_METHOD_NOT_DECLARED);
        assert!(!state.owns("op-1"));
    }

    #[test]
    fn undeclared_command_is_refused() {
        let mut state = PluginServerState::new(metals());
        open_gate(&mut state);
        let params = command("build-clean");
        let error = state
            .admit_request(arrival("op-1", EXECUTE_COMMAND, &params))
            .unwrap_err();
        assert_eq!(detail(error), codes::HOST_METHOD_NOT_DECLARED);
        let missing = json!({});
        let error = state
            .admit_request(arrival("op-2", EXECUTE_COMMAND, &missing))
            .unwrap_err();
        assert_eq!(detail(error), codes::HOST_METHOD_NOT_DECLARED);
    }

    #[test]
    fn another_contribution_is_foreign() {
        let state = PluginServerState::new(metals());
        assert!(state
            .check_owner(Some("a.plugin"), "a.plugin", "metals")
            .is_ok());
        for (session, plugin, server) in [
            (Some("a.plugin"), "b.plugin", "metals"),
            (Some("a.plugin"), "a.plugin", "rust-analyzer"),
            (None, "a.plugin", "metals"),
        ] {
            let error = state.check_owner(session, plugin, server).unwrap_err();
            assert_eq!(detail(error), codes::HOST_FOREIGN_CONTRIBUTION);
        }
    }

    #[test]
    fn requests_wait_for_the_gate_in_order() {
        let mut state = PluginServerState::new(metals());
        let params = json!({});
        for operation in ["op-1", "op-2"] {
            let admission = state
                .admit_request(arrival(operation, "textDocument/definition", &params))
                .unwrap();
            assert_eq!(admission, Admission::Held);
        }
        // A status that does not match the pattern leaves the gate closed.
        let early = state.observe("metals/status", &json!({ "text": "importing" }));
        assert!(early.released.is_empty());
        assert!(early.forward.is_some(), "the backend still sees the status");
        let released = open_gate(&mut state).released;
        let order: Vec<&str> = released
            .iter()
            .map(|held| held.operation_id.as_str())
            .collect();
        assert_eq!(order, ["op-1", "op-2"]);
        let later = state
            .admit_request(arrival("op-3", "textDocument/definition", &params))
            .unwrap();
        assert_eq!(later, Admission::Send);
    }

    #[test]
    fn notifications_are_not_held_by_gates() {
        let state = PluginServerState::new(metals());
        let params = json!({ "settings": {} });
        assert!(state
            .admit_notification(DID_CHANGE_CONFIGURATION, &params)
            .is_ok());
        assert!(state
            .admit_notification("textDocument/definition", &params)
            .is_ok());
    }

    #[test]
    fn commands_are_never_notifications() {
        let state = PluginServerState::new(metals());
        let error = state
            .admit_notification(EXECUTE_COMMAND, &command("build-import"))
            .unwrap_err();
        assert_eq!(detail(error), codes::HOST_METHOD_NOT_DECLARED);
        let error = state
            .admit_notification("textDocument/rename", &json!({}))
            .unwrap_err();
        assert_eq!(detail(error), codes::HOST_METHOD_NOT_DECLARED);
    }

    #[test]
    fn oversized_notification_is_refused() {
        let state = PluginServerState::new(rust_analyzer());
        let params = json!({ "text": "x".repeat(MAX_HOST_NOTIFICATION_BYTES) });
        let error = state
            .admit_notification("textDocument/definition", &params)
            .unwrap_err();
        assert_eq!(detail(error), codes::HOST_LIMIT_EXCEEDED);
    }

    #[test]
    fn oversized_request_is_refused_before_it_is_owned() {
        let mut state = PluginServerState::new(rust_analyzer());
        let params = json!({ "text": "x".repeat(MAX_HOST_NOTIFICATION_BYTES) });
        let error = state
            .admit_request(arrival("op-1", "textDocument/definition", &params))
            .unwrap_err();
        assert_eq!(detail(error), codes::HOST_LIMIT_EXCEEDED);
        assert!(!state.owns("op-1"));
    }

    #[test]
    fn serialized_command_joins_the_running_one() {
        let mut state = PluginServerState::new(metals());
        open_gate(&mut state);
        let params = command("build-import");
        let first = state
            .admit_request(arrival("op-1", EXECUTE_COMMAND, &params))
            .unwrap();
        let second = state
            .admit_request(arrival("op-2", EXECUTE_COMMAND, &params))
            .unwrap();
        assert_eq!((first, second), (Admission::Send, Admission::Joined));
        // A command that is not serialized always starts on its own.
        let other = command("build-connect");
        for operation in ["op-3", "op-4"] {
            let admission = state
                .admit_request(arrival(operation, EXECUTE_COMMAND, &other))
                .unwrap();
            assert_eq!(admission, Admission::Send);
        }
        let joiners = state.finish("op-1");
        assert_eq!(
            joiners,
            [Waiter {
                operation_id: "op-2".into(),
                method: EXECUTE_COMMAND.into()
            }]
        );
        assert!(!state.owns("op-1") && !state.owns("op-2"));
        // The command can run again once the first request is done.
        let third = state
            .admit_request(arrival("op-5", EXECUTE_COMMAND, &params))
            .unwrap();
        assert_eq!(third, Admission::Send);
    }

    #[test]
    fn cancelling_a_joiner_leaves_the_leader_running() {
        let mut state = PluginServerState::new(metals());
        open_gate(&mut state);
        let params = command("build-import");
        state
            .admit_request(arrival("op-1", EXECUTE_COMMAND, &params))
            .unwrap();
        state
            .admit_request(arrival("op-2", EXECUTE_COMMAND, &params))
            .unwrap();
        assert!(state.is_unsent("op-2"));
        assert!(!state.is_unsent("op-1"));
        assert!(state.finish("op-2").is_empty());
        assert!(state.owns("op-1"));
        assert!(state.finish("op-1").is_empty(), "no joiner is left");
    }

    #[test]
    fn a_held_leader_takes_its_joiners_with_it() {
        let mut state = PluginServerState::new(metals());
        let params = command("build-import");
        let first = state
            .admit_request(arrival("op-1", EXECUTE_COMMAND, &params))
            .unwrap();
        let second = state
            .admit_request(arrival("op-2", EXECUTE_COMMAND, &params))
            .unwrap();
        assert_eq!((first, second), (Admission::Held, Admission::Joined));
        assert!(
            state.is_unsent("op-1"),
            "held requests have no wire request"
        );
        let joiners = state.finish("op-1");
        assert_eq!(joiners.len(), 1);
        assert!(state.all_held().is_empty());
        assert!(open_gate(&mut state).released.is_empty());
    }

    #[test]
    fn held_requests_expire_at_their_deadline() {
        let mut state = PluginServerState::new(metals());
        let params = json!({});
        let start = Instant::now();
        state
            .admit_request(Arrival {
                operation_id: "op-1",
                method: "textDocument/definition",
                params: &params,
                now: start,
                deadline: start + Duration::from_secs(5),
            })
            .unwrap();
        assert!(state
            .expired_held(start + Duration::from_secs(4))
            .is_empty());
        let expired = state.expired_held(start + Duration::from_secs(5));
        assert_eq!(expired.len(), 1);
        assert_eq!(expired[0].operation_id, "op-1");
        state.finish("op-1");
        assert!(state.all_held().is_empty());
    }

    #[test]
    fn waiting_requests_are_bounded() {
        let mut state = PluginServerState::new(metals());
        let params = json!({});
        for index in 0..MAX_WAITING_REQUESTS {
            let operation = format!("op-{index}");
            state
                .admit_request(arrival(&operation, "textDocument/definition", &params))
                .unwrap();
        }
        let error = state
            .admit_request(arrival("op-over", "textDocument/definition", &params))
            .unwrap_err();
        assert_eq!(detail(error), codes::HOST_BUSY);
        assert!(!state.owns("op-over"));
    }

    #[test]
    fn forwarded_notification_is_bounded() {
        let mut state = PluginServerState::new(metals());
        let small = state.observe("metals/status", &json!({ "text": "x" }));
        assert_eq!(
            small.forward.unwrap(),
            json!({ "serverID": "metals", "method": "metals/status", "params": { "text": "x" } })
        );
        let large = state.observe(
            "metals/status",
            &json!({ "text": "x".repeat(MAX_HOST_NOTIFICATION_BYTES) }),
        );
        assert_eq!(
            large.forward.unwrap(),
            json!({ "serverID": "metals", "method": "metals/status", "truncated": true })
        );
        assert!(state
            .observe("window/logMessage", &json!({}))
            .forward
            .is_none());
    }

    #[test]
    fn policy_bounds_are_enforced() {
        assert!(metals().validate(Some("a.plugin")).is_ok());
        assert!(
            metals().validate(None).is_err(),
            "a host-owned session has no policy"
        );
        let mut policy = metals();
        policy.serialized_commands.insert("build-clean".into());
        assert!(policy.validate(Some("a.plugin")).is_err());
        let mut policy = metals();
        policy.request_methods = (0..=MAX_REQUEST_METHODS)
            .map(|n| format!("m/{n}"))
            .collect();
        assert!(policy.validate(Some("a.plugin")).is_err());
        let mut policy = metals();
        policy.gates.push(policy.gates[0].clone());
        assert!(
            policy.validate(Some("a.plugin")).is_err(),
            "gate IDs are unique"
        );
    }

    #[test]
    fn runtime_codes_map_to_host_codes() {
        assert_eq!(host_error_code("requestTimeout"), codes::HOST_TIMEOUT);
        assert_eq!(host_error_code("requestCancelled"), codes::HOST_CANCELLED);
        assert_eq!(
            host_error_code("processExited"),
            codes::HOST_LANGUAGE_SERVER_UNAVAILABLE
        );
        assert_eq!(
            host_error_code(codes::HOST_LANGUAGE_SERVER_ERROR),
            codes::HOST_LANGUAGE_SERVER_ERROR
        );
    }

    #[test]
    fn locations_that_are_not_files_become_read_only() {
        let result = json!({ "locations": [
            { "uri": "file:///work/src/lib.rs", "isReadOnly": false, "displayPath": null },
            { "uri": "metals-jar://host/a%20b/Main.scala?x=1#L2", "isReadOnly": false },
        ]});
        let normalized = normalize_navigation_result(Some(result)).unwrap();
        let locations = normalized["locations"].as_array().unwrap();
        assert_eq!(locations[0]["isReadOnly"], false);
        assert_eq!(locations[1]["isReadOnly"], true);
        assert_eq!(locations[1]["displayPath"], "a b/Main.scala");
        assert!(normalize_navigation_result(None).is_none());
    }
}
