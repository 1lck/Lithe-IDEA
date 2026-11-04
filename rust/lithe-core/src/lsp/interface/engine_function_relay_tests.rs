//! Engine-level tests of the cross-plugin function relay.
//!
//! Each plugin backend is a scripted server, so a test plays every plugin
//! process: the Python plugin that asks the host to call a function, the Go
//! plugin that exports it, and a third plugin further down the chain. The
//! relay's own rules (limits, nesting, state transitions) have unit tests in
//! `function_relay`; these tests check that the engine carries them out on
//! real sessions: what each backend receives on the wire, and what it is told
//! when a call is refused, fails, is cancelled, or loses a participant.
//!
//! Nothing here sleeps to coordinate. A test waits on the scripted servers'
//! bounded readers or on a bounded poll of the session events, and time-based
//! outcomes use synthetic instants passed to `expire_deadlines_at`.

use super::super::function_relay::RelaySnapshot;
use super::super::plugin_function::FunctionReference;
use super::super::process::{LspProcessLauncher, LspProcessSpec, LspProcessStreams};
use super::super::scripted::ScriptedServer;
use super::tests::start_request;
use super::*;

const PYTHON: &str = "dev.lithe.fixture.python";
const GO: &str = "dev.lithe.fixture.go";
const RUST: &str = "dev.lithe.fixture.rust";
const ALPHA: &str = "dev.lithe.fixture.alpha";

const FORMAT: &str = "document.format";
const LINT: &str = "lint.run";
const SYMBOLS: &str = "symbols.list";

const CONTEXT_ID: &str = "workspace-1";

const INVOKE: &str = "lithe/host/functions/invoke";
const PROVIDERS: &str = "lithe/host/functions/providers";

/// A payload the relay refuses: it is above the relay's 256 KiB limit but
/// below every limit of the session itself.
const OVERSIZED_BYTES: usize = 300 * 1024;

/// Hands every started session its own scripted server, in the order the
/// test queued them. The engine has one launcher for all its sessions.
#[derive(Default)]
struct HandoffLauncher {
    queued: Mutex<VecDeque<Arc<dyn LspProcessLauncher>>>,
}

impl HandoffLauncher {
    fn queue(&self, launcher: Arc<dyn LspProcessLauncher>) {
        self.queued.lock().unwrap().push_back(launcher);
    }
}

impl LspProcessLauncher for HandoffLauncher {
    fn launch(&self, spec: LspProcessSpec) -> Result<LspProcessStreams, CoreError> {
        let next = self.queued.lock().unwrap().pop_front();
        match next {
            Some(launcher) => launcher.launch(spec),
            None => Err(CoreError::new(
                ErrorCode::ProcessStartFailed,
                "No scripted server was queued for this start.",
            )),
        }
    }
}

/// Polls `condition` until it holds. The wait is bounded, so a failure is
/// reported as what was missing instead of hanging the run.
fn await_until(description: &str, mut condition: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if condition() {
            return;
        }
        thread::sleep(Duration::from_millis(2));
    }
    panic!("timed out waiting for {description}");
}

/// One engine with several plugin backends that share its relay.
struct Fixture {
    engine: LspEngine,
    launcher: Arc<HandoffLauncher>,
}

impl Fixture {
    fn new() -> Self {
        let launcher = Arc::new(HandoffLauncher::default());
        Self {
            engine: LspEngine::with_launcher(launcher.clone()),
            launcher,
        }
    }

    /// Starts a plugin backend and waits until it is ready to take calls.
    fn start(&self, launch: Launch) -> Backend {
        let server = ScriptedServer::new();
        self.launcher.queue(server.launcher());
        let mut request = start_request(&server);
        request.plugin_id = Some(launch.plugin_id.to_string());
        request.root_uri = launch.root_uri.to_string();
        request.host_services = launch.host_services.clone();
        let started = self
            .engine
            .start_server(request)
            .expect("the plugin backend should start");
        server.complete_initialize(launch.capabilities());
        let session = self
            .engine
            .session(&started.session_id)
            .expect("the session should be registered");
        let backend = Backend {
            server,
            session,
            events: Vec::new(),
        };
        backend.await_ready();
        backend
    }

    /// Publishes the host's view of the enabled plugins and workspace.
    fn configure(&self, snapshot: Value) {
        let snapshot: RelaySnapshot =
            serde_json::from_value(snapshot).expect("the snapshot has the documented shape");
        self.engine
            .relay
            .configure(snapshot)
            .expect("the snapshot is valid");
    }
}

/// How a plugin backend starts: what it negotiated and which functions it
/// registered.
struct Launch {
    plugin_id: &'static str,
    root_uri: &'static str,
    protocol_version: u64,
    functions: Vec<&'static str>,
    host_services: Vec<String>,
}

impl Launch {
    /// A backend that negotiated the relay protocol and holds the grant for
    /// it, in the standard workspace.
    fn new(plugin_id: &'static str) -> Self {
        Self {
            plugin_id,
            root_uri: "file:///workspace",
            protocol_version: 4,
            functions: Vec::new(),
            host_services: vec!["functions".to_string()],
        }
    }

    fn serving(mut self, functions: &[&'static str]) -> Self {
        self.functions = functions.to_vec();
        self
    }

    fn at(mut self, root_uri: &'static str) -> Self {
        self.root_uri = root_uri;
        self
    }

    fn speaking(mut self, protocol_version: u64) -> Self {
        self.protocol_version = protocol_version;
        self
    }

    fn without_grant(mut self) -> Self {
        self.host_services.clear();
        self
    }

    fn capabilities(&self) -> Value {
        let functions: Vec<Value> = self
            .functions
            .iter()
            .map(|id| json!({ "id": id }))
            .collect();
        json!({
            "experimental": {
                "litheFunctions": { "version": self.protocol_version, "functions": functions }
            }
        })
    }
}

/// A started plugin backend: the scripted server that plays its process and
/// the engine session that talks to it.
struct Backend {
    server: ScriptedServer,
    session: Arc<RuntimeSession>,
    /// Events are drained by every poll, so the backend accumulates them.
    events: Vec<LspRuntimeEvent>,
}

impl Drop for Backend {
    fn drop(&mut self) {
        // Ends the session's reader thread instead of leaving it to the run.
        self.server.exit(Some(0));
    }
}

impl Backend {
    fn await_ready(&self) {
        await_until("the backend to become ready", || {
            self.session
                .snapshot()
                .is_ok_and(|snapshot| snapshot.state == LspLifecycleState::Ready)
        });
    }

    fn poll(&mut self) {
        let events = self.session.poll_events().expect("polling should succeed");
        self.events.extend(events);
    }

    fn await_event(
        &mut self,
        description: &str,
        matches: impl Fn(&LspRuntimeEvent) -> bool,
    ) -> LspRuntimeEvent {
        await_until(description, || {
            self.poll();
            self.events.iter().any(&matches)
        });
        self.events
            .iter()
            .find(|&event| matches(event))
            .cloned()
            .expect("the event was observed")
    }

    // The plugin's side: requests the backend sends to the host.

    /// Sends one request to the host, as the plugin process would.
    fn ask(&self, id: &str, method: &str, params: Value) {
        self.server.send(json!({
            "jsonrpc": "2.0", "id": id, "method": method, "params": params
        }));
    }

    /// Asks the host to call `function` of `plugin` in the standard context.
    fn call(&self, id: &str, plugin: &str, function: &str) {
        self.ask(id, INVOKE, call_params(plugin, function));
    }

    /// The plugin process cancels a request it sent earlier.
    fn cancel(&self, id: &str) {
        self.server.send(json!({
            "jsonrpc": "2.0", "method": "$/cancelRequest", "params": { "id": id }
        }));
    }

    /// The host's answer to a request this backend sent.
    fn reply(&self, id: &str) -> Value {
        self.server
            .await_response(id)
            .unwrap_or_else(|| panic!("the host never answered request {id}"))
    }

    // The callee's side: calls the engine writes to the backend.

    /// The relayed call as this backend received it: its wire ID and params.
    fn await_invoke(&self) -> (String, Value) {
        let wire_id = self
            .server
            .await_request("lithe/function/invoke")
            .expect("the call should reach the callee");
        let request = self
            .server
            .messages()
            .into_iter()
            .find(|message| {
                message["id"] == wire_id.as_str() && message["method"] == "lithe/function/invoke"
            })
            .expect("the request was written");
        (wire_id, request["params"].clone())
    }

    fn answer(&self, wire_id: &str, result: Value) {
        self.server
            .send(json!({ "jsonrpc": "2.0", "id": wire_id, "result": result }));
    }

    fn fail(&self, wire_id: &str, message: &str, plugin_error_code: &str) {
        self.server.send(json!({
            "jsonrpc": "2.0", "id": wire_id,
            "error": { "code": -32000, "message": message, "data": { "code": plugin_error_code } }
        }));
    }

    /// Nothing has been written to this backend as a function call. A call the
    /// relay refuses never reaches the callee, so this holds without waiting.
    fn assert_not_invoked(&self) {
        assert!(self
            .server
            .messages()
            .iter()
            .all(|message| message["method"] != "lithe/function/invoke"));
    }

    /// A call the host itself starts, as a host feature would.
    fn host_call(&self, operation_id: &str, plugin: &str, function: &str) -> Result<(), CoreError> {
        self.session.function_request(
            PluginFunctionRequest {
                session_id: self.session.id.clone(),
                operation_id: Some(operation_id.to_string()),
                function: FunctionReference {
                    plugin_id: plugin.to_string(),
                    function_id: function.to_string(),
                },
                params: json!({}),
                timeout_milliseconds: None,
                context: None,
            },
            operation_id.to_string(),
            None,
        )
    }
}

fn workspace_context() -> Value {
    json!({ "contextID": CONTEXT_ID, "generation": 1 })
}

/// The params of `lithe/host/functions/invoke` for a plain call.
fn call_params(plugin: &str, function: &str) -> Value {
    json!({
        "pluginID": plugin,
        "functionID": function,
        "context": workspace_context(),
        "params": { "uri": "file:///workspace/main.go" }
    })
}

/// One plugin as the host reports it: the functions it exports and the
/// functions it declared calling, with their contract versions.
fn plugin(id: &str, exports: &[(&str, u32)], calls: &[(&str, u32)]) -> Value {
    let exports: Vec<Value> = exports
        .iter()
        .map(|(function, version)| {
            json!({ "id": function, "version": version, "context": "workspace" })
        })
        .collect();
    let calls: Vec<Value> = calls
        .iter()
        .map(|(function, version)| json!({ "id": function, "version": version }))
        .collect();
    json!({ "pluginID": id, "exports": exports, "calls": calls })
}

fn snapshot(plugins: Vec<Value>, authority: &str) -> Value {
    json!({
        "plugins": plugins,
        "contexts": [{ "contextID": CONTEXT_ID, "generation": 1, "authority": authority }]
    })
}

/// Python declares calling `document.format`, Go exports it, locally.
fn standard_snapshot() -> Value {
    snapshot(
        vec![
            plugin(PYTHON, &[], &[(FORMAT, 1)]),
            plugin(GO, &[(FORMAT, 1)], &[]),
        ],
        "local",
    )
}

/// The failure a backend sees: the stable code in `error.data.code` and the
/// JSON-RPC number, which is unique to that code.
fn assert_error(reply: &Value, code: &str, rpc_code: i64) {
    assert_eq!(reply["error"]["data"]["code"], code, "{reply}");
    assert_eq!(reply["error"]["code"], rpc_code, "{reply}");
}

// The call path.

#[test]
fn a_declared_exported_call_reaches_the_callee_and_returns_its_value() {
    let fixture = Fixture::new();
    let python = fixture.start(Launch::new(PYTHON));
    let mut go = fixture.start(Launch::new(GO).serving(&[FORMAT]));
    fixture.configure(standard_snapshot());

    // The function's own params may carry a `caller` of their own. Only the
    // field Core writes beside them names the caller.
    let mut params = call_params(GO, FORMAT);
    params["params"]["caller"] = json!({ "pluginID": "dev.lithe.forged" });
    python.ask("call-1", INVOKE, params);

    let (wire_id, received) = go.await_invoke();
    assert_eq!(received["functionID"], FORMAT);
    assert_eq!(received["context"], workspace_context());
    assert_eq!(received["caller"], json!({ "pluginID": PYTHON }));
    assert_eq!(
        received["params"]["caller"],
        json!({ "pluginID": "dev.lithe.forged" })
    );
    go.answer(&wire_id, json!({ "edits": 2 }));

    assert_eq!(
        python.reply("call-1")["result"],
        json!({ "value": { "edits": 2 } })
    );
    // The callee keeps its own identity; the caller is only request context.
    assert_eq!(go.session.plugin_id.as_deref(), Some(GO));
    // The relay answers the calling plugin, so the host never sees the call.
    go.poll();
    assert!(go.events.iter().all(|event| !event
        .operation_id
        .as_deref()
        .is_some_and(|id| id.starts_with("relay-call-"))));
    await_until("the callee to forget the call", || {
        go.session
            .snapshot()
            .is_ok_and(|snapshot| snapshot.pending_operation_ids.is_empty())
    });
}

#[test]
fn a_caller_field_in_the_host_request_is_refused() {
    let fixture = Fixture::new();
    let python = fixture.start(Launch::new(PYTHON));
    let go = fixture.start(Launch::new(GO).serving(&[FORMAT]));
    fixture.configure(standard_snapshot());

    let mut params = call_params(GO, FORMAT);
    params["caller"] = json!({ "pluginID": "dev.lithe.forged" });
    python.ask("call-1", INVOKE, params);

    assert_error(
        &python.reply("call-1"),
        "plugin.host.unsupportedOption",
        -32018,
    );
    go.assert_not_invoked();
}

#[test]
fn a_call_the_host_starts_carries_no_caller() {
    let fixture = Fixture::new();
    let go = fixture.start(Launch::new(GO).serving(&[FORMAT]));

    go.host_call("host-call-1", GO, FORMAT)
        .expect("the host call is sent");

    let (_, received) = go.await_invoke();
    assert!(received.get("caller").is_none(), "{received}");
}

#[test]
fn a_callee_on_an_older_protocol_version_gets_no_caller() {
    let fixture = Fixture::new();
    let python = fixture.start(Launch::new(PYTHON));
    let go = fixture.start(Launch::new(GO).speaking(3).serving(&[FORMAT]));
    fixture.configure(standard_snapshot());

    python.call("call-1", GO, FORMAT);

    let (wire_id, received) = go.await_invoke();
    assert!(received.get("caller").is_none(), "{received}");
    // The rest of the call is unchanged for that callee.
    assert_eq!(received["context"], workspace_context());
    go.answer(&wire_id, json!({}));
    assert_eq!(python.reply("call-1")["result"], json!({ "value": {} }));
}

#[test]
fn a_failing_callee_keeps_its_own_error_code() {
    let fixture = Fixture::new();
    let python = fixture.start(Launch::new(PYTHON));
    let go = fixture.start(Launch::new(GO).serving(&[FORMAT]));
    fixture.configure(standard_snapshot());

    python.call("call-1", GO, FORMAT);
    let (wire_id, _) = go.await_invoke();
    go.fail(&wire_id, "Parse failed.", "go.parseFailed");

    let reply = python.reply("call-1");
    assert_error(&reply, "plugin.function.failed", -32603);
    assert_eq!(reply["error"]["message"], "Parse failed.");
    assert_eq!(
        reply["error"]["data"]["details"]["pluginErrorCode"],
        "go.parseFailed"
    );
}

#[test]
fn a_result_above_the_relay_limit_is_refused() {
    let fixture = Fixture::new();
    let python = fixture.start(Launch::new(PYTHON));
    let go = fixture.start(Launch::new(GO).serving(&[FORMAT]));
    fixture.configure(standard_snapshot());

    python.call("call-1", GO, FORMAT);
    let (wire_id, _) = go.await_invoke();
    // Within the session's own result limit, above the relay's.
    go.answer(&wire_id, json!({ "text": "x".repeat(OVERSIZED_BYTES) }));

    assert_error(
        &python.reply("call-1"),
        "plugin.function.payloadTooLarge",
        -32068,
    );
}

// Discovery.

#[test]
fn discovery_follows_the_enabled_plugins() {
    let fixture = Fixture::new();
    let python = fixture.start(Launch::new(PYTHON));
    fixture.configure(standard_snapshot());

    python.ask("first", PROVIDERS, json!({ "functionID": FORMAT }));
    assert_eq!(
        python.reply("first")["result"],
        json!({ "providers": [{ "pluginID": GO, "version": 1 }] })
    );

    // A plugin is installed: providers are listed by plugin ID.
    fixture.configure(snapshot(
        vec![
            plugin(PYTHON, &[], &[(FORMAT, 1)]),
            plugin(GO, &[(FORMAT, 1)], &[]),
            plugin(ALPHA, &[(FORMAT, 1)], &[]),
        ],
        "local",
    ));
    python.ask("second", PROVIDERS, json!({ "functionID": FORMAT }));
    assert_eq!(
        python.reply("second")["result"],
        json!({ "providers": [
            { "pluginID": ALPHA, "version": 1 },
            { "pluginID": GO, "version": 1 }
        ] })
    );

    // A plugin is uninstalled or disabled: it is gone at once.
    fixture.configure(snapshot(
        vec![
            plugin(PYTHON, &[], &[(FORMAT, 1)]),
            plugin(ALPHA, &[(FORMAT, 1)], &[]),
        ],
        "local",
    ));
    python.ask("third", PROVIDERS, json!({ "functionID": FORMAT }));
    assert_eq!(
        python.reply("third")["result"],
        json!({ "providers": [{ "pluginID": ALPHA, "version": 1 }] })
    );

    // A caller that did not declare the function learns nothing about it.
    fixture.configure(snapshot(vec![plugin(PYTHON, &[], &[])], "local"));
    python.ask("fourth", PROVIDERS, json!({ "functionID": FORMAT }));
    assert_error(
        &python.reply("fourth"),
        "plugin.function.notDeclared",
        -32027,
    );
}

// Refusals.

struct Refusal {
    name: &'static str,
    snapshot: Value,
    params: Value,
    code: &'static str,
    rpc_code: i64,
}

fn refusals() -> Vec<Refusal> {
    let mut stale_generation = call_params(GO, FORMAT);
    stale_generation["context"]["generation"] = json!(2);
    let mut oversized_params = call_params(GO, FORMAT);
    oversized_params["params"] = json!({ "text": "x".repeat(OVERSIZED_BYTES) });
    vec![
        Refusal {
            name: "the caller did not declare the call",
            snapshot: snapshot(
                vec![plugin(PYTHON, &[], &[]), plugin(GO, &[(FORMAT, 1)], &[])],
                "local",
            ),
            params: call_params(GO, FORMAT),
            code: "plugin.function.notDeclared",
            rpc_code: -32027,
        },
        Refusal {
            name: "the plugin does not export the function",
            snapshot: snapshot(
                vec![plugin(PYTHON, &[], &[(FORMAT, 1)]), plugin(GO, &[], &[])],
                "local",
            ),
            params: call_params(GO, FORMAT),
            code: "plugin.function.notExported",
            rpc_code: -32028,
        },
        Refusal {
            name: "the plugin is not enabled",
            snapshot: snapshot(vec![plugin(PYTHON, &[], &[(FORMAT, 1)])], "local"),
            params: call_params(GO, FORMAT),
            code: "plugin.function.providerDisabled",
            rpc_code: -32029,
        },
        Refusal {
            name: "the contract versions differ",
            snapshot: snapshot(
                vec![
                    plugin(PYTHON, &[], &[(FORMAT, 2)]),
                    plugin(GO, &[(FORMAT, 1)], &[]),
                ],
                "local",
            ),
            params: call_params(GO, FORMAT),
            code: "plugin.function.versionMismatch",
            rpc_code: -32030,
        },
        Refusal {
            name: "the workspace context is stale",
            snapshot: standard_snapshot(),
            params: stale_generation,
            code: "plugin.host.contextExpired",
            rpc_code: -32011,
        },
        Refusal {
            name: "the workspace is remote",
            snapshot: snapshot(
                vec![
                    plugin(PYTHON, &[], &[(FORMAT, 1)]),
                    plugin(GO, &[(FORMAT, 1)], &[]),
                ],
                "remote",
            ),
            params: call_params(GO, FORMAT),
            code: "plugin.host.authorityUnsupported",
            rpc_code: -32012,
        },
        Refusal {
            name: "the params are above the relay limit",
            snapshot: standard_snapshot(),
            params: oversized_params,
            code: "plugin.function.payloadTooLarge",
            rpc_code: -32068,
        },
    ]
}

#[test]
fn a_refused_call_never_reaches_the_callee() {
    let fixture = Fixture::new();
    let python = fixture.start(Launch::new(PYTHON));
    let go = fixture.start(Launch::new(GO).serving(&[FORMAT]));

    for (index, refusal) in refusals().into_iter().enumerate() {
        fixture.configure(refusal.snapshot);
        let id = format!("call-{index}");
        python.ask(&id, INVOKE, refusal.params);
        let reply = python.reply(&id);
        assert_eq!(
            reply["error"]["data"]["code"], refusal.code,
            "{}: {reply}",
            refusal.name
        );
        assert_eq!(
            reply["error"]["code"], refusal.rpc_code,
            "{}: {reply}",
            refusal.name
        );
    }
    go.assert_not_invoked();
}

#[test]
fn relay_methods_need_protocol_version_4_and_the_functions_grant() {
    let fixture = Fixture::new();
    let old_protocol = fixture.start(Launch::new(PYTHON).speaking(3));
    old_protocol.call("call-1", GO, FORMAT);
    assert_error(
        &old_protocol.reply("call-1"),
        "plugin.host.unavailable",
        -32601,
    );
    old_protocol.ask("providers-1", PROVIDERS, json!({ "functionID": FORMAT }));
    assert_error(
        &old_protocol.reply("providers-1"),
        "plugin.host.unavailable",
        -32601,
    );

    let ungranted = fixture.start(Launch::new(ALPHA).without_grant());
    ungranted.call("call-2", GO, FORMAT);
    assert_error(
        &ungranted.reply("call-2"),
        "plugin.host.permissionDenied",
        -32010,
    );
}

#[test]
fn the_old_refusals_still_hold_with_the_relay() {
    let fixture = Fixture::new();
    let python = fixture.start(Launch::new(PYTHON).serving(&[LINT]));
    fixture.configure(standard_snapshot());

    // A backend still cannot ask the host to run a function or a domain
    // operation, which could route back into the backend itself.
    for (id, method) in [
        ("invoke", "lithe/function/invoke"),
        ("model", "lithe/build/model"),
    ] {
        python.ask(id, method, json!({}));
        assert_eq!(
            python.reply(id)["error"]["data"]["code"],
            "plugin.function.recursiveCall",
            "{method}"
        );
    }

    // The host still cannot call another plugin's function through a session.
    let error = python
        .host_call("host-call-1", GO, FORMAT)
        .expect_err("another plugin's function stays private");
    assert!(matches!(error.code, ErrorCode::PermissionDenied));
    assert_eq!(
        error.details.as_deref(),
        Some("plugin.function.wrongPlugin")
    );

    // The host cannot take an operation ID the relay hands out.
    let error = python
        .host_call("relay-call-1", PYTHON, LINT)
        .expect_err("the operation ID is reserved");
    assert!(matches!(error.code, ErrorCode::InvalidRequest));
}

// Chains.

#[test]
fn a_plugin_cannot_call_itself_or_back_into_its_own_chain() {
    let fixture = Fixture::new();
    let python = fixture.start(Launch::new(PYTHON).serving(&[LINT]));
    let go = fixture.start(Launch::new(GO).serving(&[FORMAT]));
    fixture.configure(snapshot(
        vec![
            plugin(PYTHON, &[(LINT, 1)], &[(FORMAT, 1), (LINT, 1)]),
            plugin(GO, &[(FORMAT, 1)], &[(LINT, 1)]),
        ],
        "local",
    ));

    python.call("self", PYTHON, LINT);
    assert_error(&python.reply("self"), "plugin.function.callCycle", -32065);

    // Python -> Go -> Python: Go's call lands on a plugin that is already
    // waiting for Go's answer.
    python.call("forward", GO, FORMAT);
    let (wire_id, _) = go.await_invoke();
    go.call("back", PYTHON, LINT);
    assert_error(&go.reply("back"), "plugin.function.callCycle", -32065);
    python.assert_not_invoked();

    go.answer(&wire_id, json!({}));
    assert_eq!(python.reply("forward")["result"], json!({ "value": {} }));
}

#[test]
fn cancelling_a_call_cancels_the_calls_made_while_serving_it() {
    let fixture = Fixture::new();
    let python = fixture.start(Launch::new(PYTHON));
    let go = fixture.start(Launch::new(GO).serving(&[FORMAT]));
    let rust = fixture.start(Launch::new(RUST).serving(&[SYMBOLS]));
    fixture.configure(snapshot(
        vec![
            plugin(PYTHON, &[], &[(FORMAT, 1)]),
            plugin(GO, &[(FORMAT, 1)], &[(SYMBOLS, 1)]),
            plugin(RUST, &[(SYMBOLS, 1)], &[]),
        ],
        "local",
    ));

    python.call("outer", GO, FORMAT);
    go.await_invoke();
    go.call("inner", RUST, SYMBOLS);
    let (_, nested) = rust.await_invoke();
    // The innermost callee sees the plugin that called it, not the origin.
    assert_eq!(nested["caller"], json!({ "pluginID": GO }));

    python.cancel("outer");

    assert_error(&python.reply("outer"), "plugin.host.cancelled", -32800);
    assert!(go.server.await_notification("$/cancelRequest"));
    assert!(rust.server.await_notification("$/cancelRequest"));
    assert_error(&go.reply("inner"), "plugin.host.cancelled", -32800);
}

// Time, loss of a participant, hot activation.

#[test]
fn a_callee_that_runs_out_of_time_fails_the_call() {
    let fixture = Fixture::new();
    let python = fixture.start(Launch::new(PYTHON));
    let go = fixture.start(Launch::new(GO).serving(&[FORMAT]));
    fixture.configure(standard_snapshot());

    let mut params = call_params(GO, FORMAT);
    params["timeoutMilliseconds"] = json!(1_000);
    python.ask("call-1", INVOKE, params);
    go.await_invoke();

    // A synthetic instant past the callee session's deadline for the call.
    go.session
        .expire_deadlines_at(Instant::now() + Duration::from_secs(120));

    assert_error(&python.reply("call-1"), "plugin.host.timeout", -32015);
}

#[test]
fn a_caller_that_stops_cancels_its_callee() {
    let fixture = Fixture::new();
    let python = fixture.start(Launch::new(PYTHON));
    let go = fixture.start(Launch::new(GO).serving(&[FORMAT]));
    fixture.configure(standard_snapshot());

    python.call("call-1", GO, FORMAT);
    go.await_invoke();
    python.server.exit(Some(1));

    // Nobody is left to answer; the callee is told to stop working.
    assert!(go.server.await_notification("$/cancelRequest"));
}

#[test]
fn a_callee_that_stops_fails_the_call_for_its_caller() {
    let fixture = Fixture::new();
    let python = fixture.start(Launch::new(PYTHON));
    let go = fixture.start(Launch::new(GO).serving(&[FORMAT]));
    fixture.configure(standard_snapshot());

    python.call("call-1", GO, FORMAT);
    go.await_invoke();
    go.server.exit(Some(1));

    assert_error(
        &python.reply("call-1"),
        "plugin.function.providerUnavailable",
        -32069,
    );
}

#[test]
fn disabling_the_provider_ends_calls_in_flight() {
    let fixture = Fixture::new();
    let python = fixture.start(Launch::new(PYTHON));
    let go = fixture.start(Launch::new(GO).serving(&[FORMAT]));
    fixture.configure(standard_snapshot());

    python.call("call-1", GO, FORMAT);
    go.await_invoke();
    fixture.configure(snapshot(vec![plugin(PYTHON, &[], &[(FORMAT, 1)])], "local"));

    assert_error(
        &python.reply("call-1"),
        "plugin.function.providerDisabled",
        -32029,
    );
    assert!(go.server.await_notification("$/cancelRequest"));
    python.call("call-2", GO, FORMAT);
    assert_error(
        &python.reply("call-2"),
        "plugin.function.providerDisabled",
        -32029,
    );
}

// A callee whose backend is not running.

#[test]
fn a_call_waits_for_a_provider_the_host_starts() {
    let fixture = Fixture::new();
    let mut python = fixture.start(Launch::new(PYTHON));
    fixture.configure(standard_snapshot());

    python.call("call-1", GO, FORMAT);
    // Core only says that a backend is needed; starting it is the host's job.
    let notice = python.await_event("the start request", |event| {
        event.kind == "functionProviderStartRequired"
    });
    assert_eq!(notice.result, Some(json!({ "pluginID": GO })));

    let go = fixture.start(Launch::new(GO).serving(&[FORMAT]));
    let (wire_id, received) = go.await_invoke();
    assert_eq!(received["caller"], json!({ "pluginID": PYTHON }));
    go.answer(&wire_id, json!({ "edits": 0 }));

    assert_eq!(
        python.reply("call-1")["result"],
        json!({ "value": { "edits": 0 } })
    );
    python.poll();
    let notices = python
        .events
        .iter()
        .filter(|event| event.kind == "functionProviderStartRequired")
        .count();
    assert_eq!(notices, 1, "one waiting call asks for one start");
}

#[test]
fn a_provider_that_registers_the_function_later_serves_the_waiting_call() {
    let fixture = Fixture::new();
    let mut python = fixture.start(Launch::new(PYTHON));
    fixture.configure(standard_snapshot());

    python.call("call-1", GO, FORMAT);
    python.await_event("the start request", |event| {
        event.kind == "functionProviderStartRequired"
    });
    // The backend is ready but has not registered the function yet.
    let go = fixture.start(Launch::new(GO));
    go.assert_not_invoked();

    go.ask(
        "register",
        "lithe/function/register",
        json!({ "functions": [{ "id": FORMAT }] }),
    );
    assert_eq!(go.reply("register")["result"], Value::Null);

    let (wire_id, _) = go.await_invoke();
    go.answer(&wire_id, json!({}));
    assert_eq!(python.reply("call-1")["result"], json!({ "value": {} }));
}

#[test]
fn a_provider_that_never_starts_ends_the_call() {
    let fixture = Fixture::new();
    let mut python = fixture.start(Launch::new(PYTHON));
    fixture.configure(standard_snapshot());

    python.call("call-1", GO, FORMAT);
    python.await_event("the start request", |event| {
        event.kind == "functionProviderStartRequired"
    });
    // Synthetic instant past the 30 second start limit, within the call's own
    // 60 second limit.
    python
        .session
        .expire_deadlines_at(Instant::now() + Duration::from_secs(31));

    assert_error(
        &python.reply("call-1"),
        "plugin.function.providerUnavailable",
        -32069,
    );
}

#[test]
fn a_call_that_runs_out_of_time_while_waiting_times_out() {
    let fixture = Fixture::new();
    let mut python = fixture.start(Launch::new(PYTHON));
    fixture.configure(standard_snapshot());

    let mut params = call_params(GO, FORMAT);
    params["timeoutMilliseconds"] = json!(5_000);
    python.ask("call-1", INVOKE, params);
    python.await_event("the start request", |event| {
        event.kind == "functionProviderStartRequired"
    });
    python
        .session
        .expire_deadlines_at(Instant::now() + Duration::from_secs(10));

    assert_error(&python.reply("call-1"), "plugin.host.timeout", -32015);
}

#[test]
fn a_call_goes_to_the_provider_of_the_callers_workspace() {
    let fixture = Fixture::new();
    let python = fixture.start(Launch::new(PYTHON).at("file:///workspace-b"));
    // Started first, so it would win on session order alone.
    let other_workspace =
        fixture.start(Launch::new(GO).serving(&[FORMAT]).at("file:///workspace-a"));
    let same_workspace =
        fixture.start(Launch::new(GO).serving(&[FORMAT]).at("file:///workspace-b"));
    fixture.configure(standard_snapshot());

    python.call("call-1", GO, FORMAT);
    let (wire_id, _) = same_workspace.await_invoke();
    same_workspace.answer(&wire_id, json!({}));

    assert_eq!(python.reply("call-1")["result"], json!({ "value": {} }));
    other_workspace.assert_not_invoked();
}
