use super::*;
use serde_json::{json, Value};
use tokio::io::{
    AsyncBufReadExt, AsyncWriteExt, BufReader, DuplexStream, Lines, ReadHalf, WriteHalf,
};

const WAIT: Duration = Duration::from_secs(5);

fn fixture() -> Value {
    serde_json::from_str(include_str!(
        "../../../shared/fixtures/agent/acp-events-v1.json"
    ))
    .expect("ACP event fixture")
}

fn provider() -> ProviderCredentials {
    ProviderCredentials {
        protocol: ProviderProtocol::Responses,
        base_url: "https://gateway.example.com/v1".into(),
        api_key: "test-key-123".into(),
        name: Some("Example".into()),
        model: None,
        allow_insecure_http: false,
    }
}

fn gateway() -> Option<GatewaySignIn> {
    Some(GatewaySignIn {
        protocol: ProviderProtocol::Responses,
        base_url: "https://gateway.example.com/v1".into(),
        headers: vec![("Authorization".into(), "Bearer test-key-123".into())],
        provider_name: Some("Example".into()),
        model: None,
        native_recovery: false,
    })
}

fn claude_route() -> GatewaySignIn {
    let provider: ProviderCredentials =
        serde_json::from_value(fixture()["upstream"]["claudeSessionRouting"]["provider"].clone())
            .expect("Claude provider fixture");
    GatewaySignIn {
        protocol: provider.protocol,
        base_url: provider.anthropic_base_url().expect("valid endpoint"),
        headers: vec![("x-api-key".into(), provider.api_key)],
        provider_name: provider.name,
        model: provider.model,
        native_recovery: false,
    }
}

fn custom_launch(command: &str, provider: ProviderCredentials) -> AgentLaunch {
    AgentLaunch {
        agent_id: None,
        command: Some(command.into()),
        args: vec![],
        cwd: std::env::temp_dir(),
        data_directory: None,
        provider: Some(provider),
        authentication: AgentAuthentication::ApiKey,
        observe_model_calls: false,
        observe_subagents: false,
        process_scope: None,
    }
}

/// Scripted ACP agent on the far side of an in-memory pipe. Each step is
/// driven by the test, so message order is explicit and every read is bounded.
struct MockAgent {
    lines: Lines<BufReader<ReadHalf<DuplexStream>>>,
    writer: WriteHalf<DuplexStream>,
}

impl MockAgent {
    async fn next(&mut self) -> Value {
        let line = tokio::time::timeout(WAIT, self.lines.next_line())
            .await
            .expect("client message before deadline")
            .expect("readable pipe")
            .expect("client kept the pipe open");
        serde_json::from_str(&line).expect("JSON-RPC line")
    }

    async fn expect(&mut self, method: &str) -> Value {
        let message = self.next().await;
        assert_eq!(message["method"], method, "unexpected message {message}");
        message
    }

    async fn write(&mut self, message: Value) {
        self.writer
            .write_all(format!("{message}\n").as_bytes())
            .await
            .expect("write to client");
    }

    async fn reply(&mut self, request: &Value, result: Value) {
        self.write(json!({ "jsonrpc": "2.0", "id": request["id"], "result": result }))
            .await;
    }

    async fn handshake(&mut self) {
        self.handshake_with_steering(false, "mock-agent").await;
    }

    async fn handshake_with_steering(&mut self, supported: bool, name: &str) {
        let initialize = self.expect("initialize").await;
        self.reply(
            &initialize,
            json!({
                "protocolVersion": 1,
                "agentInfo": { "name": name, "version": "0.1.0" },
                "_meta": { "steering": { "supported": supported } },
                "agentCapabilities": { "loadSession": true, "sessionCapabilities": { "list": {} } },
                "authMethods": [{ "id": "gateway", "name": "Custom model gateway" }],
            }),
        )
        .await;
        let authenticate = self.expect("authenticate").await;
        self.reply(&authenticate, json!({})).await;
    }
}

#[tokio::test(flavor = "current_thread")]
async fn native_subagents_keep_child_permissions_owned_by_the_root_turn() {
    let mut harness = Harness::start_observing_subagents(false, gateway(), std::env::temp_dir(), true);
    let initialize = harness.agent.expect("initialize").await;
    assert!(initialize["params"]["clientCapabilities"]["_meta"]["jetbrains"]["air"]["capabilities"].as_array().unwrap().contains(&json!("nativeSubagentSessions")));
    harness.agent.reply(&initialize, json!({"protocolVersion":1,"agentCapabilities":{},"authMethods":[{"id":"gateway","name":"Gateway"}]})).await;
    let auth = harness.agent.expect("authenticate").await;
    harness.agent.reply(&auth, json!({})).await;
    assert!(matches!(harness.event().await, AgentEvent::Ready { .. }));
    harness.open_session("session-1").await;
    harness.send(json!({"kind":"prompt","sessionId":"session-1","text":"Inspect the sample"}));
    let prompt = harness.agent.expect("session/prompt").await;
    let fixture = fixture();
    for name in ["subagentSpawned", "nestedSubagentSpawned", "subagentToolCall", "subagentMessageChunk"] {
        let event = &fixture["events"][name];
        harness.agent.write(json!({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":event["sessionId"],"update":event["update"]}})).await;
        assert_eq!(serde_json::to_value(harness.event().await).unwrap(), *event);
    }
    let mut request = fixture["events"]["permission"]["request"].clone();
    request["sessionId"] = json!("child-2");
    harness.agent.write(json!({"jsonrpc":"2.0","id":"child-permission","method":"session/request_permission","params":request})).await;
    let AgentEvent::Permission { session_id, request_id, request: received } = harness.event().await else { panic!("child permission must reach the owning turn") };
    assert_eq!(session_id, "session-1");
    assert_eq!(received["sessionId"], "child-2");
    answer_permission(&harness.permissions, &request_id, Some("allow_once".into())).unwrap();
    let response = harness.agent.next().await;
    assert_eq!(response["id"], "child-permission");
    assert_eq!(response["result"]["outcome"]["optionId"], "allow_once");

    // Parent cancellation must settle the child's next permission without a timer.
    harness.agent.write(json!({"jsonrpc":"2.0","id":"pending-child","method":"session/request_permission","params":request})).await;
    assert!(matches!(harness.event().await, AgentEvent::Permission { session_id, .. } if session_id == "session-1"));
    harness.send(json!({"kind":"cancel","sessionId":"session-1"}));
    let mut cancelled_permission = false;
    let mut cancelled_turn = false;
    for _ in 0..2 {
        let message = harness.agent.next().await;
        cancelled_permission |= message["id"] == "pending-child" && message["result"]["outcome"]["outcome"] == "cancelled";
        cancelled_turn |= message["method"] == "session/cancel" && message["params"]["sessionId"] == "session-1";
    }
    assert!(cancelled_permission && cancelled_turn);
    assert!(matches!(harness.event().await, AgentEvent::TurnCancelling { session_id } if session_id == "session-1"));
    harness.agent.reply(&prompt, json!({"stopReason":"cancelled"})).await;
    assert!(matches!(harness.event().await, AgentEvent::TurnFinished { .. }));
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn terminal_subagents_cancel_only_their_pending_permissions_and_release_quiet_tracking() {
    for state in ["completed", "failed", "cancelled", "disconnected"] {
        let mut harness =
            Harness::start_observing_subagents(false, gateway(), std::env::temp_dir(), true);
        harness.agent.handshake().await;
        assert!(matches!(harness.event().await, AgentEvent::Ready { .. }));
        harness.open_session("session-1").await;
        harness.send(json!({"kind":"prompt","sessionId":"session-1","text":"Inspect the sample"}));
        let prompt = harness.agent.expect("session/prompt").await;
        for (parent, child) in [
            ("session-1", "child-1"),
            ("child-1", "child-2"),
            ("session-1", "sibling"),
        ] {
            harness.agent.write(json!({"jsonrpc":"2.0","method":"session/update","params":{
                "sessionId":parent,"update":{"sessionUpdate":"subagent_spawned","subagentSessionId":child,
                    "name":"Explore","task":"Inspect the sample","capabilities":{}}
            }})).await;
            assert!(matches!(harness.event().await, AgentEvent::Update { .. }));
        }
        let mut requests = Vec::new();
        for source in ["child-1", "child-2", "session-1", "sibling"] {
            let mut request = fixture()["events"]["permission"]["request"].clone();
            request["sessionId"] = json!(source);
            harness.agent.write(json!({"jsonrpc":"2.0","id":source,"method":"session/request_permission","params":request})).await;
            let AgentEvent::Permission {
                session_id,
                request_id,
                ..
            } = harness.event().await
            else {
                panic!("each live source must enter the root permission queue");
            };
            assert_eq!(session_id, "session-1");
            requests.push(request_id);
        }
        // End an ancestor while the root prompt stays outstanding. Both its
        // own and its descendant's requests must settle without user input.
        harness
            .agent
            .write(json!({"jsonrpc":"2.0","method":"session/update","params":{
                "sessionId":"session-1","update":{"sessionUpdate":"subagent_state_update",
                    "subagentSessionId":"child-1","state":state}
            }}))
            .await;
        assert!(matches!(harness.event().await, AgentEvent::Update { .. }));
        let mut cancelled = std::collections::BTreeSet::new();
        for _ in 0..2 {
            let response = harness.agent.next().await;
            assert_eq!(response["result"]["outcome"]["outcome"], "cancelled");
            cancelled.insert(response["id"].as_str().unwrap().to_owned());
        }
        assert_eq!(
            cancelled,
            ["child-1".to_owned(), "child-2".to_owned()].into()
        );
        assert_eq!(harness.permissions.lock().unwrap().len(), 2);
        for id in &requests[..2] {
            assert!(
                answer_permission(&harness.permissions, id, Some("allow_once".into())).is_err()
            );
        }
        let mut late = fixture()["events"]["permission"]["request"].clone();
        late["sessionId"] = json!("child-2");
        harness.agent.write(json!({"jsonrpc":"2.0","id":"late-child","method":"session/request_permission","params":late})).await;
        let response = harness.agent.next().await;
        assert_eq!(response["id"], "late-child");
        assert_eq!(response["result"]["outcome"]["outcome"], "cancelled");
        tokio::time::advance(Duration::from_secs(60 * 60)).await;
        assert!(
            harness.events.try_recv().is_err(),
            "root and sibling permissions still suppress quiet notices"
        );
        for (id, source) in requests[2..].iter().zip(["session-1", "sibling"]) {
            answer_permission(&harness.permissions, id, Some("allow_once".into())).unwrap();
            let response = harness.agent.next().await;
            assert_eq!(response["id"], source);
            assert_eq!(response["result"]["outcome"]["optionId"], "allow_once");
        }
        tokio::time::advance(prompt_retry::quiet_notice_delay()).await;
        assert!(
            matches!(
                harness.event().await,
                AgentEvent::TurnActivity { quiet: true, .. }
            ),
            "cancelled child waits must release the root's pending-permission count"
        );
        harness
            .agent
            .reply(&prompt, json!({"stopReason":"end_turn"}))
            .await;
        assert!(matches!(
            harness.event().await,
            AgentEvent::TurnFinished { .. }
        ));
        assert_eq!(harness.stop().await, Ok(()));
    }
}

#[tokio::test(flavor = "current_thread")]
async fn steering_injects_into_the_running_prompt_and_keeps_its_completion() {
    let mut harness = Harness::start();
    harness
        .agent
        .handshake_with_steering(true, "mock-agent")
        .await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::Ready {
            can_steer: true,
            ..
        }
    ));
    harness.open_session("session-1").await;
    harness.send(json!({"kind":"prompt", "sessionId":"session-1", "text":"Inspect everything"}));
    let prompt = harness.agent.expect("session/prompt").await;
    harness.send(json!({"kind":"steer", "token":"steer-1", "sessionId":"session-1", "text":"Only inspect login"}));
    let steer = harness.agent.expect("_session/steering").await;
    assert_eq!(steer["params"]["prompt"][0]["text"], "Only inspect login");
    assert_eq!(
        steer["params"]["_meta"]["steering"]["idleBehavior"],
        "promptRequired"
    );
    harness
        .agent
        .reply(&steer, json!({"outcome":"injected"}))
        .await;
    assert!(
        matches!(harness.event().await, AgentEvent::SteeringResult { outcome, .. } if outcome == "injected")
    );
    harness
        .agent
        .reply(&prompt, json!({"stopReason":"end_turn"}))
        .await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnFinished { .. }
    ));
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(flavor = "current_thread")]
async fn steering_rejection_does_not_finish_or_replay_the_original_prompt() {
    let mut harness = Harness::start();
    harness
        .agent
        .handshake_with_steering(true, "mock-agent")
        .await;
    harness.event().await;
    harness.open_session("session-1").await;
    harness.send(json!({"kind":"prompt", "sessionId":"session-1", "text":"Inspect"}));
    let prompt = harness.agent.expect("session/prompt").await;
    harness.send(
        json!({"kind":"steer", "token":"steer-1", "sessionId":"session-1", "text":"Supplement"}),
    );
    let steer = harness.agent.expect("_session/steering").await;
    harness
        .agent
        .reply(&steer, json!({"outcome":"failed"}))
        .await;
    assert!(
        matches!(harness.event().await, AgentEvent::SteeringResult { outcome, .. } if outcome == "failed")
    );
    harness.send(json!({"kind":"cancel", "sessionId":"session-1"}));
    harness.agent.expect("session/cancel").await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnCancelling { .. }
    ));
    harness
        .agent
        .reply(&prompt, json!({"stopReason":"cancelled"}))
        .await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnFinished { .. }
    ));
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(flavor = "current_thread")]
async fn steering_completion_race_publishes_delivery_before_terminal_event() {
    let mut harness = Harness::start();
    harness
        .agent
        .handshake_with_steering(true, "mock-agent")
        .await;
    harness.event().await;
    harness.open_session("session-1").await;
    harness.send(json!({"kind":"prompt", "sessionId":"session-1", "text":"Inspect"}));
    let prompt = harness.agent.expect("session/prompt").await;
    harness.send(
        json!({"kind":"steer", "token":"steer-1", "sessionId":"session-1", "text":"Supplement"}),
    );
    let steer = harness.agent.expect("_session/steering").await;
    harness
        .agent
        .reply(&prompt, json!({"stopReason":"end_turn"}))
        .await;
    harness
        .agent
        .reply(
            &steer,
            json!({"outcome":"promptRequired", "reason":"noRunningTurn"}),
        )
        .await;
    assert!(
        matches!(harness.event().await, AgentEvent::SteeringResult { outcome, .. } if outcome == "promptRequired")
    );
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnFinished { .. }
    ));
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(flavor = "current_thread")]
async fn steering_when_idle_or_unsupported_never_sends_an_extension() {
    for supported in [false, true] {
        let mut harness = Harness::start();
        harness
            .agent
            .handshake_with_steering(supported, "mock-agent")
            .await;
        harness.event().await;
        harness.send(json!({"kind":"steer", "token":"steer-1", "sessionId":"session-1", "text":"Supplement"}));
        assert!(
            matches!(harness.event().await, AgentEvent::SteeringResult { outcome, .. }
            if outcome == if supported { "promptRequired" } else { "failed" })
        );
        // The next wire request is session creation, not an unowned prompt.
        harness.open_session("session-2").await;
        assert_eq!(harness.stop().await, Ok(()));
    }
}

#[tokio::test(flavor = "current_thread")]
async fn steering_codex_commands_use_owned_prompts_without_a_detached_turn() {
    let fixture = fixture();
    let attached_command = &fixture["commands"]["nativeCommandWithFiles"];
    for (command, files) in [
        ("/status", json!([])),
        ("  \n/status", json!([])),
        ("/compact keep API details", json!([])),
        (
            "/status",
            json!([{"uri":"file:///fixture/README.md", "name":"README.md"}]),
        ),
        (
            attached_command["text"].as_str().unwrap(),
            attached_command["files"].clone(),
        ),
    ] {
        let mut harness = Harness::start();
        harness
            .agent
            .handshake_with_steering(true, "@agentclientprotocol/codex-acp")
            .await;
        harness.event().await;
        harness.open_session("session-1").await;
        harness.send(json!({"kind":"prompt", "sessionId":"session-1", "text":"Inspect"}));
        let original = harness.agent.expect("session/prompt").await;

        // Codex 1.13.1 can answer command-only steering with startedNewTurn
        // without ever publishing active -> idle. Never send that extension:
        // leave the command unconsumed until the original prompt completes.
        harness.send(json!({"kind":"steer", "token":"command", "sessionId":"session-1", "text":command, "files":files}));
        assert!(matches!(harness.event().await,
            AgentEvent::SteeringResult { token, outcome, .. }
                if token == "command" && outcome == "promptRequired"));
        harness
            .agent
            .reply(&original, json!({"stopReason":"end_turn"}))
            .await;
        assert!(matches!(
            harness.event().await,
            AgentEvent::TurnFinished { .. }
        ));

        harness
            .send(json!({"kind":"prompt", "sessionId":"session-1", "text":command, "files":files}));
        // Any unexpected _session/steering would be the next wire message.
        let prompt = harness.agent.expect("session/prompt").await;
        let mut expected = vec![json!({"type":"text", "text":command})];
        for file in files.as_array().unwrap() {
            expected.push(json!({"type":"resource_link", "uri":file["uri"], "name":file["name"]}));
        }
        assert_eq!(prompt["params"]["prompt"], json!(expected));
        harness
            .agent
            .reply(&prompt, json!({"stopReason":"end_turn"}))
            .await;
        // There are no native model-turn status events for the command. Its
        // ACP response alone must unlock the session and keep it connected.
        assert!(matches!(
            harness.event().await,
            AgentEvent::TurnFinished { .. }
        ));
        harness
            .send(json!({"kind":"prompt", "sessionId":"session-1", "text":"Continue inspecting"}));
        let next = harness.agent.expect("session/prompt").await;
        harness
            .agent
            .reply(&next, json!({"stopReason":"end_turn"}))
            .await;
        assert!(matches!(
            harness.event().await,
            AgentEvent::TurnFinished { .. }
        ));
        assert_eq!(harness.stop().await, Ok(()));
    }
}

#[tokio::test(flavor = "current_thread")]
async fn steering_codex_detached_continuation_waits_for_its_native_idle() {
    let mut harness = Harness::start();
    harness
        .agent
        .handshake_with_steering(true, "@agentclientprotocol/codex-acp")
        .await;
    harness.event().await;
    harness.open_session("session-1").await;
    harness.send(json!({"kind":"prompt", "sessionId":"session-1", "text":"Inspect"}));
    let prompt = harness.agent.expect("session/prompt").await;
    let status = |kind| {
        json!({"jsonrpc":"2.0", "method":"session/update", "params":{
            "sessionId":"session-1", "update":{"sessionUpdate":"session_info_update", "_meta":{"codex":{"threadStatus":{"type":kind}}}}
        }})
    };
    harness.agent.write(status("active")).await;
    assert!(matches!(harness.event().await, AgentEvent::Update { .. }));
    harness.send(
        json!({"kind":"steer", "token":"steer-1", "sessionId":"session-1", "text":"Supplement"}),
    );
    let steer = harness.agent.expect("_session/steering").await;
    harness.agent.write(status("idle")).await;
    harness.agent.write(status("idle")).await;
    // A successful continuation must not inherit the original prompt's error.
    harness
        .agent
        .write(json!({"jsonrpc":"2.0", "id":prompt["id"],
        "error":{"code":-32603, "message":"Original turn failed"}}))
        .await;
    harness.agent.write(status("active")).await;
    harness
        .agent
        .reply(&steer, json!({"outcome":"startedNewTurn"}))
        .await;
    for _ in 0..3 {
        assert!(matches!(harness.event().await, AgentEvent::Update { .. }));
    }
    assert!(
        matches!(harness.event().await, AgentEvent::SteeringResult { outcome, .. } if outcome == "injected")
    );
    // Stop must still reach the continuation after the original prompt returned.
    harness.send(json!({"kind":"cancel", "sessionId":"session-1"}));
    harness.agent.expect("session/cancel").await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnCancelling { .. }
    ));
    harness.agent.write(status("idle")).await;
    assert!(matches!(harness.event().await, AgentEvent::Update { .. }));
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnFinished { usage: None, .. }
    ));
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn steering_unconfirmed_delivery_closes_the_connection_without_replay() {
    let mut harness = Harness::start();
    harness
        .agent
        .handshake_with_steering(true, "mock-agent")
        .await;
    harness.event().await;
    harness.open_session("session-1").await;
    harness.send(json!({"kind":"prompt", "sessionId":"session-1", "text":"Inspect"}));
    harness.agent.expect("session/prompt").await;
    harness.send(
        json!({"kind":"steer", "token":"steer-1", "sessionId":"session-1", "text":"Supplement"}),
    );
    harness.agent.expect("_session/steering").await;
    tokio::time::advance(SESSION_REQUEST_TIMEOUT + Duration::from_secs(1)).await;
    let result = tokio::time::timeout(WAIT, &mut harness.connection)
        .await
        .expect("unknown delivery terminates within the local bound")
        .expect("connection task joined");
    assert!(result
        .unwrap_err()
        .contains("did not confirm the supplementary message"));
}

struct Harness {
    agent: MockAgent,
    controls: async_mpsc::UnboundedSender<Control>,
    events: async_mpsc::UnboundedReceiver<AgentEvent>,
    permissions: PendingPermissions,
    connection: tokio::task::JoinHandle<Result<(), String>>,
}

impl Drop for Harness {
    fn drop(&mut self) {
        self.connection.abort();
    }
}

impl Harness {
    fn start() -> Self {
        Self::start_with(false)
    }

    fn start_with(subscription: bool) -> Self {
        Self::start_with_route(subscription, if subscription { None } else { gateway() })
    }

    fn start_with_route(subscription: bool, route: Option<GatewaySignIn>) -> Self {
        Self::start_in_workspace(subscription, route, std::env::temp_dir())
    }

    fn start_in_workspace(subscription: bool, route: Option<GatewaySignIn>, cwd: PathBuf) -> Self {
        Self::start_observing_subagents(subscription, route, cwd, false)
    }

    fn start_observing_subagents(subscription: bool, route: Option<GatewaySignIn>, cwd: PathBuf, observe_subagents: bool) -> Self {
        let (client, peer) = tokio::io::duplex(64 * 1024);
        let (client_reader, client_writer) = tokio::io::split(client);
        let (peer_reader, peer_writer) = tokio::io::split(peer);
        let (controls, receiver) = async_mpsc::unbounded_channel();
        let (event_tx, events) = async_mpsc::unbounded_channel();
        let permissions: PendingPermissions = Arc::new(Mutex::new(HashMap::new()));
        let connection = tokio::spawn(run_connection(
            ByteStreams::new(client_writer.compat_write(), client_reader.compat()),
            cwd,
            route,
            subscription.then(|| PathBuf::from("/fixture/codex")),
            None,
            None,
            observe_subagents,
            receiver,
            TurnActivity {
                permissions: permissions.clone(),
                turns: Arc::new(Mutex::new(HashMap::new())),
                calls_in_flight: Arc::default(),
            },
            Arc::new(move |event| {
                let _ = event_tx.send(event);
            }),
        ));
        Self {
            agent: MockAgent {
                lines: BufReader::new(peer_reader).lines(),
                writer: peer_writer,
            },
            controls,
            events,
            permissions,
            connection,
        }
    }

    async fn ready() -> Self {
        let mut harness = Self::start();
        harness.agent.handshake().await;
        assert!(matches!(harness.event().await, AgentEvent::Ready { .. }));
        harness
    }

    async fn ready_claude() -> Self {
        let mut harness = Self::start_with_route(false, Some(claude_route()));
        let initialize = harness.agent.expect("initialize").await;
        harness
            .agent
            .reply(&initialize, json!({"protocolVersion": 1}))
            .await;
        assert!(matches!(harness.event().await, AgentEvent::Ready { .. }));
        harness
    }

    async fn ready_codex() -> Self {
        let mut route = gateway().unwrap();
        route.native_recovery = true;
        let mut harness = Self::start_with_route(false, Some(route));
        harness.agent.handshake().await;
        assert!(matches!(harness.event().await, AgentEvent::Ready { .. }));
        harness
    }

    fn send(&self, command: Value) {
        let command = serde_json::from_value(command).expect("command JSON");
        if let AgentCommand::Cancel { session_id } = &command {
            reject_pending_permissions(&self.permissions, Some(session_id));
        }
        self.controls
            .send(Control::Command(command))
            .expect("connection running");
    }

    async fn event(&mut self) -> AgentEvent {
        // test-stability: allow(rust-unbounded-receive) reason: tokio's async receiver has no recv_timeout; tokio::time::timeout(WAIT) bounds this await without blocking the executor.
        tokio::time::timeout(WAIT, self.events.recv())
            .await
            .expect("event before deadline")
            .expect("event channel open")
    }

    async fn open_session(&mut self, session_id: &str) {
        self.send(json!({ "kind": "newSession", "token": session_id }));
        let request = self.agent.expect("session/new").await;
        self.agent
            .reply(&request, json!({ "sessionId": session_id }))
            .await;
        assert!(matches!(
            self.event().await,
            AgentEvent::SessionCreated { .. }
        ));
    }

    async fn stop(mut self) -> Result<(), String> {
        self.controls
            .send(Control::Stop)
            .expect("connection running");
        tokio::time::timeout(WAIT, &mut self.connection)
            .await
            .expect("connection stops before deadline")
            .expect("connection task completes")
    }
}

#[test]
fn serialized_events_match_the_shared_fixture() {
    let fixture = fixture();
    let events = &fixture["events"];
    let cases = [
        (
            "ready",
            AgentEvent::Ready {
                agent_name: Some("example-agent".into()),
                agent_version: Some("1.0.0".into()),
                can_load_sessions: true,
                can_list_sessions: true,
                can_list_archived_sessions: false,
                can_steer: false,
            },
        ),
        (
            "steeringResult",
            AgentEvent::SteeringResult {
                token: "steer-1".into(),
                session_id: "session-1".into(),
                outcome: "injected".into(),
                message: None,
            },
        ),
        (
            "sessionCreated",
            AgentEvent::SessionCreated {
                token: "token-1".into(),
                session_id: "session-1".into(),
                config_options: None,
            },
        ),
        (
            "sessionLoaded",
            AgentEvent::SessionLoaded {
                token: "token-2".into(),
                session_id: "session-1".into(),
                config_options: None,
            },
        ),
        (
            "sessions",
            AgentEvent::Sessions {
                token: "token-3".into(),
                sessions: vec![
                    AgentSessionSummary {
                        session_id: "session-1".into(),
                        title: Some("Explain this project".into()),
                        updated_at: Some("2026-09-25T10:00:00Z".into()),
                    },
                    AgentSessionSummary {
                        session_id: "session-2".into(),
                        title: None,
                        updated_at: None,
                    },
                ],
            },
        ),
        (
            "archivedSessions",
            AgentEvent::ArchivedSessions {
                token: "archived-1".into(),
                sessions: vec![AgentSessionSummary {
                    session_id: "archived-session-1".into(),
                    title: Some("Earlier refactor".into()),
                    updated_at: Some("2026-09-20T08:30:00Z".into()),
                }],
                complete: true,
            },
        ),
        (
            "sessionUnarchived",
            AgentEvent::SessionUnarchived {
                token: "unarchive-1".into(),
                session_id: "archived-session-1".into(),
            },
        ),
        (
            "turnFinished",
            AgentEvent::TurnFinished {
                session_id: "session-1".into(),
                stop_reason: "end_turn".into(),
                usage: None,
            },
        ),
        (
            "turnActivityQuiet",
            AgentEvent::TurnActivity {
                session_id: "session-1".into(),
                quiet: true,
            },
        ),
        (
            "turnActivityResumed",
            AgentEvent::TurnActivity {
                session_id: "session-1".into(),
                quiet: false,
            },
        ),
        (
            "turnRetrying",
            AgentEvent::TurnRetrying {
                session_id: "session-1".into(),
                turn_id: "host-turn-1".into(),
                attempt: 2,
                max_attempts: Some(5),
            },
        ),
        (
            "turnRecovering",
            AgentEvent::TurnRetrying {
                session_id: "session-1".into(),
                turn_id: "native-turn-1".into(),
                attempt: 6,
                max_attempts: None,
            },
        ),
        (
            "turnCancelled",
            AgentEvent::TurnFinished {
                session_id: "session-1".into(),
                stop_reason: "cancelled".into(),
                usage: None,
            },
        ),
        (
            "turnFinishedWithUsage",
            prompt::finished(
                "session-1".into(),
                serde_json::from_value(fixture["upstream"]["promptResponseWithUsage"].clone())
                    .unwrap(),
            ),
        ),
        (
            "requestFailed",
            failed(
                None,
                Some("session-1".into()),
                "The Agent is still responding in this conversation".into(),
            ),
        ),
        (
            "stopped",
            AgentEvent::Stopped {
                message: Some("The Agent connection closed unexpectedly".into()),
            },
        ),
    ];
    for (name, event) in cases {
        assert_eq!(
            serde_json::to_value(event).unwrap(),
            events[name],
            "fixture event {name}"
        );
    }
    let permission = &events["permission"];
    assert_eq!(
        serde_json::to_value(AgentEvent::Permission {
            session_id: "session-1".into(),
            request_id: "permission-1".into(),
            request: permission["request"].clone(),
        })
        .unwrap(),
        *permission
    );
    // Update payloads are forwarded verbatim, so the fixture must be valid ACP
    // wire format that the SDK round-trips unchanged.
    for name in [
        "userMessageChunk",
        "agentMessageChunk",
        "toolCall",
        "toolCallUpdate",
        "fileEdit",
        "claudeFileCreated",
        "claudeFileWriteUpdated",
        "sessionInfo",
        "codexRetry",
        "usageUpdate",
        "historicalUsageUpdate",
        "agentThoughtChunk",
        "plan",
        "availableCommands",
        "currentModeUpdate",
        "claudeAutoModeNotice",
    ] {
        let update = &events[name]["update"];
        let parsed: agent_client_protocol::schema::v1::SessionUpdate =
            serde_json::from_value(update.clone())
                .unwrap_or_else(|error| panic!("{name}: {error}"));
        assert_eq!(
            &serde_json::to_value(parsed).unwrap(),
            update,
            "fixture update {name}"
        );
    }
    let request: RequestPermissionRequest =
        serde_json::from_value(permission["request"].clone()).expect("ACP permission request");
    assert_eq!(
        serde_json::to_value(request).unwrap(),
        permission["request"]
    );
    assert_eq!(
        stop_reason_name(&agent_client_protocol::schema::v1::StopReason::EndTurn),
        "end_turn"
    );
}

#[test]
fn management_status_matches_the_shared_fixture() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../shared/fixtures/agent/agent-management-v1.json"
    ))
    .expect("agent management fixture");
    let data = std::env::temp_dir().join(format!("lithe-status-{}", std::process::id()));
    struct Cleanup(std::path::PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(data.clone());
    let _ = std::fs::remove_dir_all(&data);
    fake_install(&data, "codex-acp");
    let tool = |version: &str, name: &str| environment::DetectedTool {
        version: version.into(),
        path: format!("/opt/example/node/bin/{name}").into(),
    };
    let status = install::status_with(
        &data,
        environment::RuntimeEnvironment {
            node: Some(tool("20.11.0", "node")),
            npm: Some(tool("10.2.4", "npm")),
            used_login_shell: true,
        },
        &|command| (command == "codex").then(|| tool("0.156.1", "codex")),
        &|cli| {
            Some(
                serde_json::from_value(
                    fixture["cliInstallations"][if cli.command == "codex" {
                        "npm"
                    } else {
                        "missing"
                    }]
                    .clone(),
                )
                .unwrap(),
            )
        },
    );
    assert_eq!(
        serde_json::to_value(status).unwrap(),
        fixture["responses"]["status"]
    );
    for agent in catalog::CATALOG {
        fake_install(&data, agent.id);
        for (installed, expected) in [
            ("0.0.0".to_string(), Some(true)),
            (agent.version.to_string(), Some(false)),
            ("9999.0.0".to_string(), Some(false)),
            (format!("{}-beta.1", agent.version), Some(true)),
            (format!("{}+local", agent.version), Some(false)),
            ("unreadable".to_string(), None),
        ] {
            std::fs::write(
                data.join("agents").join(agent.id).join("lithe-agent.json"),
                serde_json::to_vec(&json!({"id": agent.id, "version": installed})).unwrap(),
            )
            .unwrap();
            let status = install::status_with(
                &data,
                environment::RuntimeEnvironment {
                    node: None,
                    npm: None,
                    used_login_shell: true,
                },
                &|_| None,
                &|_| None,
            );
            let actual = status
                .agents
                .iter()
                .find(|status| status.id == agent.id)
                .unwrap();
            assert_eq!(
                actual.update_available, expected,
                "{} {installed}",
                agent.id
            );
        }
    }
    let _ = std::fs::remove_dir_all(&data);
}

#[test]
fn fixture_commands_parse_as_platform_commands() {
    let fixture = fixture();
    let commands = fixture["commands"].as_object().expect("commands");
    for (name, command) in commands {
        serde_json::from_value::<AgentCommand>(command.clone())
            .unwrap_or_else(|error| panic!("command {name}: {error}"));
    }
    assert!(matches!(
        serde_json::from_value(commands["denyPermission"].clone()).unwrap(),
        AgentCommand::Permission {
            option_id: None,
            ..
        }
    ));
}

#[tokio::test(flavor = "current_thread")]
async fn handshake_signs_in_through_the_gateway_with_the_user_key() {
    let mut harness = Harness::start();
    let initialize = harness.agent.expect("initialize").await;
    assert_eq!(
        initialize["params"]["clientCapabilities"]["auth"]["_meta"]["gateway"],
        true
    );
    harness
        .agent
        .reply(
            &initialize,
            json!({
                "protocolVersion": 1,
                "agentInfo": { "name": "mock-agent", "version": "0.1.0" },
                "agentCapabilities": { "loadSession": true, "sessionCapabilities": { "list": {} } },
                "authMethods": [
                    { "id": "chat-gpt", "name": "ChatGPT" },
                    { "id": "gateway", "name": "Custom model gateway" }
                ],
            }),
        )
        .await;
    let authenticate = harness.agent.expect("authenticate").await;
    let params = &authenticate["params"];
    assert_eq!(params["methodId"], "gateway");
    assert_eq!(
        params["_meta"]["gateway"]["baseUrl"],
        "https://gateway.example.com/v1"
    );
    assert_eq!(
        params["_meta"]["gateway"]["headers"]["Authorization"],
        "Bearer test-key-123"
    );
    assert_eq!(params["_meta"]["gateway"]["providerName"], "Example");
    harness.agent.reply(&authenticate, json!({})).await;
    match harness.event().await {
        AgentEvent::Ready {
            agent_name,
            can_load_sessions,
            can_list_sessions,
            ..
        } => {
            assert_eq!(agent_name.as_deref(), Some("mock-agent"));
            assert!(can_load_sessions && can_list_sessions);
        }
        other => panic!("expected ready, got {other:?}"),
    }
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test]
async fn negotiated_session_notices_are_forwarded_without_becoming_replies() {
    let mut harness = Harness::start_with_route(false, Some(claude_route()));
    let initialize = harness.agent.expect("initialize").await;
    assert_eq!(
        initialize["params"]["clientCapabilities"]["session"]["notices"],
        json!({})
    );
    harness
        .agent
        .reply(&initialize, json!({"protocolVersion": 1}))
        .await;
    assert!(matches!(harness.event().await, AgentEvent::Ready { .. }));
    harness.open_session("session-1").await;
    let expected = fixture()["events"]["claudeAutoModeNotice"].clone();
    harness
        .agent
        .write(json!({
            "jsonrpc": "2.0", "method": "session/update",
            "params": {"sessionId": "session-1", "update": expected["update"]}
        }))
        .await;
    assert_eq!(
        serde_json::to_value(harness.event().await).unwrap(),
        expected
    );
    harness.stop().await.unwrap();
}

#[test]
fn claude_session_routing_clears_conflicting_credentials_and_preserves_sdk_options() {
    let mut route = claude_route();
    let meta = session_routing::metadata(Some(&route)).unwrap().unwrap();
    assert_eq!(
        json!(meta),
        fixture()["upstream"]["claudeSessionRouting"]["meta"]
    );
    let options = &meta["claudeCode"]["options"];
    assert!(options.get("permissionMode").is_none());
    assert!(options.get("tools").is_none());
    // No explicit model keeps the upstream default rather than inventing one.
    route.model = Some("  ".into());
    let meta = session_routing::metadata(Some(&route)).unwrap().unwrap();
    assert!(meta["claudeCode"]["options"].get("model").is_none());
    assert!(session_routing::metadata(gateway().as_ref())
        .unwrap()
        .is_none());
    assert!(session_routing::metadata(None).unwrap().is_none());
}

#[tokio::test(flavor = "current_thread")]
async fn claude_authentication_failure_ends_the_turn_and_allows_an_explicit_retry() {
    let mut harness = Harness::ready_claude().await;
    harness.open_session("session-1").await;
    harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "first"}));
    let first = harness.agent.expect("session/prompt").await;
    harness
        .agent
        .write(json!({
            "jsonrpc": "2.0", "id": first["id"],
            "error": {
                "code": -32603,
                "message": "Failed to authenticate. API Error: 401 Invalid API key",
                "data": {"errorKind": "authentication_failed"}
            }
        }))
        .await;
    match harness.event().await {
        AgentEvent::RequestFailed {
            token,
            session_id,
            message,
        } => {
            assert!(token.is_none());
            assert_eq!(session_id.as_deref(), Some("session-1"));
            assert!(message.contains("401 Invalid API key"));
        }
        other => panic!("expected terminal authentication failure, got {other:?}"),
    }
    // Only the user's next command starts another turn, after the failed turn
    // has released its busy state; the host never resends the rejected prompt.
    harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "retry"}));
    let retry = harness.agent.expect("session/prompt").await;
    assert_eq!(retry["params"]["prompt"][0]["text"], "retry");
    harness
        .agent
        .reply(&retry, json!({"stopReason": "end_turn"}))
        .await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnFinished { .. }
    ));
    assert_eq!(harness.stop().await, Ok(()));
}

async fn reject_prompt(harness: &mut Harness, request: &Value, kind: &str) {
    harness
        .agent
        .write(json!({
            "jsonrpc": "2.0", "id": request["id"],
            "error": {"code": -32603, "message": "API Error: 503 No available channel",
                      "data": {"errorKind": kind}}
        }))
        .await;
}

#[tokio::test(start_paused = true)]
async fn claude_temporary_errors_attempt_five_times_without_upstream_backoff() {
    for kind in ["rate_limit", "overloaded", "server_error", "transport_lost"] {
        let mut harness = Harness::ready_claude().await;
        harness.open_session("session-1").await;
        harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "first"}));
        for attempt in 1..=5 {
            let request = harness.agent.expect("session/prompt").await;
            assert_eq!(request["params"]["prompt"][0]["text"], "first");
            reject_prompt(&mut harness, &request, kind).await;
            harness.agent.expect("session/cancel").await;
            if attempt < 5 {
                match harness.event().await {
                    AgentEvent::TurnRetrying {
                        session_id,
                        attempt: next,
                        max_attempts,
                        ..
                    } => {
                        assert_eq!(session_id, "session-1");
                        assert_eq!(next, attempt + 1);
                        assert_eq!(max_attempts, Some(5));
                    }
                    other => panic!("retry before final failure: {other:?}"),
                }
                tokio::time::advance(Duration::from_millis(500 << (attempt - 1))).await;
            } else {
                assert!(matches!(
                    harness.event().await,
                    AgentEvent::RequestFailed { .. }
                ));
            }
        }
        harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "explicit retry"}));
        let retry = harness.agent.expect("session/prompt").await;
        harness
            .agent
            .reply(&retry, json!({"stopReason": "end_turn"}))
            .await;
        assert!(matches!(
            harness.event().await,
            AgentEvent::TurnFinished { .. }
        ));
        assert_eq!(harness.stop().await, Ok(()));
    }
}

#[tokio::test(start_paused = true)]
async fn claude_permanent_and_unknown_errors_never_automatically_retry() {
    for kind in [
        "authentication_failed",
        "invalid_request",
        "model_not_found",
        "billing_error",
        "verification_required",
        "unknown",
    ] {
        let mut harness = Harness::ready_claude().await;
        harness.open_session("session-1").await;
        harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "first"}));
        let first = harness.agent.expect("session/prompt").await;
        reject_prompt(&mut harness, &first, kind).await;
        assert!(matches!(
            harness.event().await,
            AgentEvent::RequestFailed { .. }
        ));
        assert_eq!(harness.stop().await, Ok(()));
    }
}

#[tokio::test(start_paused = true)]
async fn claude_air_terminal_failure_is_not_success_and_can_recover() {
    let mut harness = Harness::ready_claude().await;
    harness.open_session("session-1").await;
    harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "first"}));
    let first = harness.agent.expect("session/prompt").await;
    harness
        .agent
        .reply(
            &first,
            fixture()["upstream"]["claudeTemporaryFailureResponse"].clone(),
        )
        .await;
    harness.agent.expect("session/cancel").await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnRetrying { attempt: 2, .. }
    ));
    tokio::time::advance(Duration::from_millis(500)).await;
    let retry = harness.agent.expect("session/prompt").await;
    harness
        .agent
        .reply(&retry, json!({"stopReason": "end_turn"}))
        .await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnFinished { .. }
    ));
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(start_paused = true)]
async fn claude_generic_air_service_errors_cannot_retry_permanent_http_statuses() {
    for status in [400, 401, 402, 403, 404, 413, 422] {
        let mut harness = Harness::ready_claude().await;
        harness.open_session("session-1").await;
        harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "first"}));
        let first = harness.agent.expect("session/prompt").await;
        let mut response = fixture()["upstream"]["claudeTemporaryFailureResponse"].clone();
        response["_meta"]["jetbrains"]["air"]["sessionFailure"]["title"] =
            json!(format!("API Error: {status} Request rejected"));
        harness.agent.reply(&first, response).await;
        match harness.event().await {
            AgentEvent::RequestFailed { message, .. } => {
                assert!(message.contains(&status.to_string()));
                assert!(
                    !message.contains("sessionFailure"),
                    "incident JSON stays internal"
                );
            }
            other => panic!("expected terminal failure, got {other:?}"),
        }
        assert_eq!(harness.stop().await, Ok(()));
    }
}

#[tokio::test(start_paused = true)]
async fn claude_auth_failure_preserves_air_details_without_starting_account_login() {
    let mut harness = Harness::ready_claude().await;
    harness.open_session("session-1").await;
    harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "first"}));
    let first = harness.agent.expect("session/prompt").await;
    let update = fixture()["events"]["claudeSessionFailure"]["update"].clone();
    harness.agent.write(json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "session-1", "update": update}})).await;
    assert!(matches!(harness.event().await, AgentEvent::Update { .. }));
    reject_prompt(&mut harness, &first, "authentication_failed").await;
    assert!(
        matches!(harness.event().await, AgentEvent::RequestFailed { message, .. } if message.contains("401 Invalid API key"))
    );
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(start_paused = true)]
async fn responses_agent_errors_keep_their_upstream_retry_policy() {
    let mut harness = Harness::ready().await;
    harness.open_session("session-1").await;
    harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "first"}));
    let first = harness.agent.expect("session/prompt").await;
    reject_prompt(&mut harness, &first, "server_error").await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::RequestFailed { .. }
    ));
    assert_eq!(harness.stop().await, Ok(()));
}

fn codex_failure_update(sequence: u64, info: Value, active: bool) -> Value {
    let mut update = fixture()["events"]["codexNativeRetry"]["update"].clone();
    let title = &mut update["_meta"]["jetbrains"]["air"]["sessionFailure"]["title"];
    let mut envelope: Value = serde_json::from_str(title.as_str().unwrap()).unwrap();
    envelope["litheCodexFailure"]["sequence"] = json!(sequence);
    envelope["litheCodexFailure"]["codexErrorInfo"] = info;
    envelope["litheCodexFailure"]["activeTurn"] = json!(active);
    *title = json!(envelope.to_string());
    update
}

async fn send_codex_failure(harness: &mut Harness, update: Value) {
    harness.agent.write(json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "session-1", "update": update}})).await;
    assert!(matches!(harness.event().await, AgentEvent::Update { .. }));
}

#[tokio::test(start_paused = true)]
async fn codex_native_retries_report_five_attempts_without_resending_prompt() {
    let mut harness = Harness::ready_codex().await;
    harness.open_session("session-1").await;
    harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "first"}));
    let prompt = harness.agent.expect("session/prompt").await;
    for sequence in 1..=4 {
        send_codex_failure(
            &mut harness,
            codex_failure_update(
                sequence,
                json!({"responseStreamDisconnected": {"httpStatusCode": 503}}),
                true,
            ),
        )
        .await;
        assert!(
            matches!(harness.event().await, AgentEvent::TurnRetrying { attempt, max_attempts: Some(5), .. } if attempt == sequence as u32 + 1)
        );
    }
    harness
        .agent
        .reply(
            &prompt,
            fixture()["upstream"]["codexFailureResponse"].clone(),
        )
        .await;
    assert!(
        matches!(harness.event().await, AgentEvent::RequestFailed { message, .. } if message == "Local Codex fixture failure")
    );
    // stop() expects only shutdown/cancel protocol: another session/prompt
    // would fail the test, including after the terminal native failure.
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(start_paused = true)]
async fn codex_permanent_native_failures_cancel_immediately_and_preserve_reason() {
    for info in [
        json!("unauthorized"),
        json!("usageLimitExceeded"),
        json!("badRequest"),
        json!({"responseStreamDisconnected": {"httpStatusCode": 404}}),
    ] {
        let mut harness = Harness::ready_codex().await;
        harness.open_session("session-1").await;
        harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "first"}));
        let prompt = harness.agent.expect("session/prompt").await;
        send_codex_failure(&mut harness, codex_failure_update(1, info, true)).await;
        harness.agent.expect("session/cancel").await;
        assert!(matches!(
            harness.event().await,
            AgentEvent::TurnCancelling { .. }
        ));
        harness
            .agent
            .reply(&prompt, json!({"stopReason": "cancelled"}))
            .await;
        assert!(
            matches!(harness.event().await, AgentEvent::RequestFailed { message, .. } if message == "Local Codex fixture failure")
        );
        assert_eq!(harness.stop().await, Ok(()));
    }
}

#[tokio::test(start_paused = true)]
async fn codex_reconnect_deadline_does_not_restart_and_cancellation_is_acknowledged() {
    let mut harness = Harness::ready_codex().await;
    harness.open_session("session-1").await;
    harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "first"}));
    let prompt = harness.agent.expect("session/prompt").await;
    send_codex_failure(
        &mut harness,
        codex_failure_update(1, json!("rateLimitExceeded"), true),
    )
    .await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnRetrying { attempt: 2, .. }
    ));
    tokio::time::advance(Duration::from_secs(19)).await;
    send_codex_failure(
        &mut harness,
        codex_failure_update(2, json!("rateLimitExceeded"), true),
    )
    .await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnRetrying { attempt: 3, .. }
    ));
    tokio::time::advance(Duration::from_secs(1)).await;
    harness.agent.expect("session/cancel").await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnCancelling { .. }
    ));
    harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "overlap"}));
    assert!(
        matches!(harness.event().await, AgentEvent::RequestFailed { message, .. } if message.contains("still responding"))
    );
    harness
        .agent
        .reply(&prompt, json!({"stopReason": "cancelled"}))
        .await;
    assert!(
        matches!(harness.event().await, AgentEvent::RequestFailed { message, .. } if message.contains("20 seconds") && message.contains("Local Codex fixture failure"))
    );
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(start_paused = true)]
async fn codex_recovered_progress_ends_host_deadline_and_later_recovery_is_engine_owned() {
    let mut harness = Harness::ready_codex().await;
    harness.open_session("session-1").await;
    harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "first"}));
    let prompt = harness.agent.expect("session/prompt").await;
    let failure = codex_failure_update(
        1,
        json!({"responseStreamDisconnected": {"httpStatusCode": null}}),
        true,
    );
    send_codex_failure(&mut harness, failure.clone()).await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnRetrying {
            attempt: 2,
            max_attempts: Some(5),
            ..
        }
    ));
    send_codex_failure(&mut harness, failure).await; // duplicate is not another attempt
    send_codex_failure(
        &mut harness,
        codex_failure_update(2, json!("unauthorized"), false),
    )
    .await; // retired native turn
    harness.agent.write(json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "session-1", "update": {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "reasoning"}}}})).await;
    assert!(matches!(harness.event().await, AgentEvent::Update { .. }));
    tokio::time::advance(Duration::from_secs(25)).await;
    send_codex_failure(
        &mut harness,
        codex_failure_update(3, json!("internalServerError"), true),
    )
    .await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnRetrying {
            attempt: 2,
            max_attempts: None,
            ..
        }
    ));
    tokio::time::advance(Duration::from_secs(25)).await;
    harness
        .agent
        .reply(&prompt, json!({"stopReason": "end_turn"}))
        .await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnFinished { .. }
    ));
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(start_paused = true)]
async fn codex_post_work_recovery_exceeds_host_time_and_count_limits_without_replay() {
    for update in [
        json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Service started"}}),
        json!({"sessionUpdate": "tool_call", "toolCallId": "start", "title": "Start service", "kind": "execute", "status": "completed"}),
    ] {
        let mut harness = Harness::ready_codex().await;
        harness.open_session("session-1").await;
        harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "finish"}));
        let prompt = harness.agent.expect("session/prompt").await;
        harness.agent.write(json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "session-1", "update": update}})).await;
        assert!(matches!(harness.event().await, AgentEvent::Update { .. }));
        // Public willRetry warnings stay engine-owned even if more than four
        // arrive. No Host cancellation or second prompt may reach the peer.
        for sequence in 1..=6 {
            send_codex_failure(
                &mut harness,
                codex_failure_update(sequence, json!("internalServerError"), true),
            )
            .await;
            assert!(
                matches!(harness.event().await, AgentEvent::TurnRetrying { attempt, max_attempts: None, .. } if attempt == sequence as u32 + 1)
            );
            tokio::time::advance(Duration::from_secs(21)).await;
            harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "overlap"}));
            assert!(
                matches!(harness.event().await, AgentEvent::RequestFailed { message, .. } if message.contains("still responding"))
            );
        }
        harness
            .agent
            .reply(&prompt, json!({"stopReason": "end_turn"}))
            .await;
        assert!(matches!(
            harness.event().await,
            AgentEvent::TurnFinished { .. }
        ));
        assert_eq!(harness.stop().await, Ok(()));
    }
}

#[tokio::test(start_paused = true)]
async fn codex_post_work_recovery_notice_is_not_delayed_by_warnings_and_progress_clears_it() {
    let mut harness = Harness::ready_codex().await;
    harness.open_session("session-1").await;
    harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "finish"}));
    let prompt = harness.agent.expect("session/prompt").await;
    let progress = json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "session-1", "update": {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "Working"}}}});
    harness.agent.write(progress.clone()).await;
    assert!(matches!(harness.event().await, AgentEvent::Update { .. }));
    // Recovery has its own advisory clock, rather than inheriting old silence.
    tokio::time::advance(prompt_retry::quiet_notice_delay() / 2).await;
    send_codex_failure(
        &mut harness,
        codex_failure_update(1, json!("internalServerError"), true),
    )
    .await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnRetrying {
            max_attempts: None,
            ..
        }
    ));
    tokio::time::advance(prompt_retry::quiet_notice_delay() / 2).await;
    send_codex_failure(
        &mut harness,
        codex_failure_update(2, json!("internalServerError"), true),
    )
    .await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnRetrying { .. }
    ));
    assert!(
        harness.events.try_recv().is_err(),
        "recovery notice starts at its first warning"
    );
    tokio::time::advance(prompt_retry::quiet_notice_delay() / 2).await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnActivity { quiet: true, .. }
    ));
    harness.agent.write(progress).await;
    assert!(matches!(harness.event().await, AgentEvent::Update { .. }));
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnActivity { quiet: false, .. }
    ));
    harness
        .agent
        .reply(&prompt, json!({"stopReason": "end_turn"}))
        .await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnFinished { .. }
    ));
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(start_paused = true)]
async fn codex_post_work_recovery_user_stop_keeps_busy_until_acknowledged() {
    let mut harness = Harness::ready_codex().await;
    harness.open_session("session-1").await;
    harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "finish"}));
    let prompt = harness.agent.expect("session/prompt").await;
    harness.agent.write(json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "session-1", "update": {"sessionUpdate": "tool_call", "toolCallId": "start", "title": "Start service", "kind": "execute"}}})).await;
    assert!(matches!(harness.event().await, AgentEvent::Update { .. }));
    send_codex_failure(
        &mut harness,
        codex_failure_update(1, json!("internalServerError"), true),
    )
    .await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnRetrying {
            max_attempts: None,
            ..
        }
    ));
    tokio::time::advance(Duration::from_secs(25)).await;
    harness.send(json!({"kind": "cancel", "sessionId": "session-1"}));
    harness.agent.expect("session/cancel").await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnCancelling { .. }
    ));
    harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "overlap"}));
    assert!(
        matches!(harness.event().await, AgentEvent::RequestFailed { message, .. } if message.contains("still responding"))
    );
    harness
        .agent
        .reply(&prompt, json!({"stopReason": "cancelled"}))
        .await;
    assert!(
        matches!(harness.event().await, AgentEvent::TurnFinished { stop_reason, .. } if stop_reason == "cancelled")
    );
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(start_paused = true)]
async fn codex_retry_budget_overrun_is_stopped_without_starting_a_sixth_host_prompt() {
    let mut harness = Harness::ready_codex().await;
    harness.open_session("session-1").await;
    harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "first"}));
    let prompt = harness.agent.expect("session/prompt").await;
    for sequence in 1..=5 {
        send_codex_failure(
            &mut harness,
            codex_failure_update(sequence, json!("internalServerError"), true),
        )
        .await;
        if sequence < 5 {
            assert!(matches!(
                harness.event().await,
                AgentEvent::TurnRetrying { .. }
            ));
        }
    }
    harness.agent.expect("session/cancel").await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnCancelling { .. }
    ));
    harness
        .agent
        .reply(&prompt, json!({"stopReason": "cancelled"}))
        .await;
    assert!(
        matches!(harness.event().await, AgentEvent::RequestFailed { message, .. } if message.contains("five attempts"))
    );
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(start_paused = true)]
async fn codex_post_work_terminal_failure_allows_only_explicit_next_prompt() {
    let mut harness = Harness::ready_codex().await;
    harness.open_session("session-1").await;
    harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "finish"}));
    let prompt = harness.agent.expect("session/prompt").await;
    harness.agent.write(json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "session-1", "update": {"sessionUpdate": "tool_call", "toolCallId": "start", "title": "Start service", "kind": "execute", "status": "completed"}}})).await;
    assert!(matches!(harness.event().await, AgentEvent::Update { .. }));
    send_codex_failure(
        &mut harness,
        codex_failure_update(1, json!("internalServerError"), true),
    )
    .await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnRetrying {
            max_attempts: None,
            ..
        }
    ));
    tokio::time::advance(Duration::from_secs(25)).await;
    harness
        .agent
        .reply(
            &prompt,
            fixture()["upstream"]["codexFailureResponse"].clone(),
        )
        .await;
    assert!(
        matches!(harness.event().await, AgentEvent::RequestFailed { message, .. } if message == "Local Codex fixture failure")
    );
    // The peer must receive only the user-authorized continuation, never an
    // automatic retry of the original task after tools have already run.
    harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "Check completed work and continue"}));
    let next = harness.agent.expect("session/prompt").await;
    assert_eq!(
        next["params"]["prompt"][0]["text"],
        "Check completed work and continue"
    );
    harness
        .agent
        .reply(&next, json!({"stopReason": "end_turn"}))
        .await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnFinished { .. }
    ));
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(start_paused = true)]
async fn codex_post_work_permanent_failure_still_cancels_and_cleans_unacknowledged_connection() {
    let mut harness = Harness::ready_codex().await;
    harness.open_session("session-1").await;
    harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "finish"}));
    harness.agent.expect("session/prompt").await;
    harness.agent.write(json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "session-1", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Service started"}}}})).await;
    assert!(matches!(harness.event().await, AgentEvent::Update { .. }));
    send_codex_failure(
        &mut harness,
        codex_failure_update(1, json!("internalServerError"), true),
    )
    .await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnRetrying {
            max_attempts: None,
            ..
        }
    ));
    tokio::time::advance(Duration::from_secs(25)).await;
    send_codex_failure(
        &mut harness,
        codex_failure_update(2, json!("unauthorized"), true),
    )
    .await;
    harness.agent.expect("session/cancel").await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnCancelling { .. }
    ));
    tokio::time::advance(CANCEL_TIMEOUT).await;
    assert!(
        matches!(harness.event().await, AgentEvent::RequestFailed { message, .. } if message == "Local Codex fixture failure")
    );
    let result = tokio::time::timeout(WAIT, &mut harness.connection)
        .await
        .expect("connection finishes within local deadline")
        .expect("connection task completes");
    assert!(result.unwrap_err().contains("did not acknowledge Stop"));
}

#[test]
fn codex_retry_helper_is_owned_by_one_launch_and_removed_on_drop() {
    let (relay, env) = codex_retry::Relay::create(Path::new("/fixture/codex"), true).unwrap();
    let script = PathBuf::from(&env.iter().find(|(name, _)| name == "CODEX_PATH").unwrap().1);
    let directory = script.parent().unwrap().to_owned();
    assert!(script.is_file());
    assert_eq!(
        env.iter()
            .find(|(name, _)| name == "LITHE_CODEX_STREAM_RETRIES")
            .unwrap()
            .1,
        "4"
    );
    drop(relay);
    assert!(
        !directory.exists(),
        "per-launch helper is not a reusable cache"
    );
}

fn codex_rate_limit_response() -> Value {
    let mut response = fixture()["upstream"]["codexFailureResponse"].clone();
    let title = &mut response["_meta"]["jetbrains"]["air"]["sessionFailure"]["title"];
    let mut envelope: Value = serde_json::from_str(title.as_str().unwrap()).unwrap();
    envelope["litheCodexFailure"]["codexErrorInfo"] =
        json!({"responseTooManyFailedAttempts": {"httpStatusCode": 429}});
    envelope["litheCodexFailure"]["sequence"] = json!(1);
    *title = json!(envelope.to_string());
    response
}

#[tokio::test(start_paused = true)]
async fn codex_rate_limit_gap_shares_native_budget_and_never_replays_work() {
    for progress in [false, true] {
        let mut harness = Harness::ready_codex().await;
        harness.open_session("session-1").await;
        harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "first"}));
        let prompt = harness.agent.expect("session/prompt").await;
        if progress {
            harness.agent.write(json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "session-1", "update": {"sessionUpdate": "tool_call", "toolCallId": "tool-1", "title": "Execute", "kind": "execute"}}})).await;
            assert!(matches!(harness.event().await, AgentEvent::Update { .. }));
        }
        harness
            .agent
            .reply(&prompt, codex_rate_limit_response())
            .await;
        if progress {
            assert!(matches!(
                harness.event().await,
                AgentEvent::RequestFailed { .. }
            ));
        } else {
            harness.agent.expect("session/cancel").await;
            assert!(matches!(
                harness.event().await,
                AgentEvent::TurnRetrying { attempt: 2, .. }
            ));
            tokio::time::advance(Duration::from_millis(500)).await;
            let retry = harness.agent.expect("session/prompt").await;
            for sequence in 1..=3 {
                send_codex_failure(
                    &mut harness,
                    codex_failure_update(sequence + 1, json!("internalServerError"), true),
                )
                .await;
                assert!(
                    matches!(harness.event().await, AgentEvent::TurnRetrying { attempt, .. } if attempt == sequence as u32 + 2)
                );
            }
            harness
                .agent
                .reply(&retry, codex_rate_limit_response())
                .await;
            assert!(matches!(
                harness.event().await,
                AgentEvent::RequestFailed { .. }
            ));
        }
        assert_eq!(harness.stop().await, Ok(()));
    }
}

#[tokio::test(start_paused = true)]
async fn codex_unacknowledged_reconnect_stop_terminates_the_connection_after_grace() {
    let mut harness = Harness::ready_codex().await;
    harness.open_session("session-1").await;
    harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "first"}));
    harness.agent.expect("session/prompt").await;
    send_codex_failure(
        &mut harness,
        codex_failure_update(1, json!("internalServerError"), true),
    )
    .await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnRetrying { .. }
    ));
    tokio::time::advance(prompt_retry::RETRY_WINDOW).await;
    harness.agent.expect("session/cancel").await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnCancelling { .. }
    ));
    tokio::time::advance(CANCEL_TIMEOUT).await;
    assert!(
        matches!(harness.event().await, AgentEvent::RequestFailed { message, .. } if message.contains("20 seconds"))
    );
    let result = tokio::time::timeout(WAIT, &mut harness.connection)
        .await
        .expect("connection finishes within local deadline")
        .expect("connection task completes");
    assert!(result.unwrap_err().contains("did not acknowledge Stop"));
}

#[tokio::test(start_paused = true)]
async fn codex_delayed_previous_turn_warnings_cannot_change_the_next_prompt() {
    let mut harness = Harness::ready_codex().await;
    harness.open_session("session-1").await;
    harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "first"}));
    let first = harness.agent.expect("session/prompt").await;
    harness
        .agent
        .reply(
            &first,
            fixture()["upstream"]["codexFailureResponse"].clone(),
        )
        .await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::RequestFailed { .. }
    ));
    harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "next"}));
    let next = harness.agent.expect("session/prompt").await;
    // The warning was encoded while the old native turn was active but arrives
    // after its terminal sequence 5. It must not cancel or count in this prompt.
    send_codex_failure(
        &mut harness,
        codex_failure_update(4, json!("unauthorized"), true),
    )
    .await;
    send_codex_failure(
        &mut harness,
        codex_failure_update(6, json!("internalServerError"), true),
    )
    .await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnRetrying { attempt: 2, .. }
    ));
    harness
        .agent
        .reply(&next, json!({"stopReason": "end_turn"}))
        .await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnFinished { .. }
    ));
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(start_paused = true)]
async fn codex_permanent_failure_cannot_be_erased_by_a_ready_success_response() {
    let mut harness = Harness::ready_codex().await;
    harness.open_session("session-1").await;
    harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "first"}));
    let prompt = harness.agent.expect("session/prompt").await;
    // Publish both messages before yielding to the host, controlling the race
    // between its permanent stop deadline and prompt completion.
    let notification = json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "session-1", "update": codex_failure_update(1, json!("unauthorized"), true)}});
    let response =
        json!({"jsonrpc": "2.0", "id": prompt["id"], "result": {"stopReason": "end_turn"}});
    harness
        .agent
        .writer
        .write_all(format!("{notification}\n{response}\n").as_bytes())
        .await
        .unwrap();
    assert!(matches!(harness.event().await, AgentEvent::Update { .. }));
    let next = harness.event().await;
    if matches!(next, AgentEvent::TurnCancelling { .. }) {
        harness.agent.expect("session/cancel").await;
        assert!(
            matches!(harness.event().await, AgentEvent::RequestFailed { message, .. } if message == "Local Codex fixture failure")
        );
    } else {
        assert!(
            matches!(next, AgentEvent::RequestFailed { message, .. } if message == "Local Codex fixture failure")
        );
    }
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(start_paused = true)]
async fn claude_cancel_during_backoff_finishes_without_resending() {
    let mut harness = Harness::ready_claude().await;
    harness.open_session("session-1").await;
    harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "first"}));
    let first = harness.agent.expect("session/prompt").await;
    reject_prompt(&mut harness, &first, "server_error").await;
    harness.agent.expect("session/cancel").await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnRetrying { .. }
    ));
    harness.send(json!({"kind": "cancel", "sessionId": "session-1"}));
    harness.agent.expect("session/cancel").await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnCancelling { .. }
    ));
    assert!(
        matches!(harness.event().await, AgentEvent::TurnFinished { stop_reason, .. } if stop_reason == "cancelled")
    );
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(start_paused = true)]
async fn claude_stalled_reconnection_cancels_within_twenty_seconds_before_unlocking() {
    let mut harness = Harness::ready_claude().await;
    harness.open_session("session-1").await;
    harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "first"}));
    let first = harness.agent.expect("session/prompt").await;
    reject_prompt(&mut harness, &first, "server_error").await;
    harness.agent.expect("session/cancel").await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnRetrying { .. }
    ));
    tokio::time::advance(Duration::from_millis(500)).await;
    let retry = harness.agent.expect("session/prompt").await;
    tokio::time::advance(prompt_retry::RETRY_WINDOW).await;
    harness.agent.expect("session/cancel").await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnCancelling { .. }
    ));
    harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "overlap"}));
    assert!(
        matches!(harness.event().await, AgentEvent::RequestFailed { message, .. } if message.contains("still responding"))
    );
    harness
        .agent
        .reply(&retry, json!({"stopReason": "cancelled"}))
        .await;
    assert!(
        matches!(harness.event().await, AgentEvent::RequestFailed { message, .. } if message.contains("20 seconds") && message.contains("503"))
    );
    harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "next"}));
    let next = harness.agent.expect("session/prompt").await;
    harness
        .agent
        .reply(&next, json!({"stopReason": "end_turn"}))
        .await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnFinished { .. }
    ));
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(start_paused = true)]
async fn claude_unacknowledged_retry_timeout_closes_the_connection_after_cancel_grace() {
    let mut harness = Harness::ready_claude().await;
    harness.open_session("session-1").await;
    harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "first"}));
    let first = harness.agent.expect("session/prompt").await;
    reject_prompt(&mut harness, &first, "server_error").await;
    harness.agent.expect("session/cancel").await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnRetrying { .. }
    ));
    tokio::time::advance(Duration::from_millis(500)).await;
    harness.agent.expect("session/prompt").await;
    tokio::time::advance(prompt_retry::RETRY_WINDOW).await;
    harness.agent.expect("session/cancel").await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnCancelling { .. }
    ));
    assert!(
        harness.events.try_recv().is_err(),
        "no terminal event before cancellation grace"
    );
    tokio::time::advance(CANCEL_TIMEOUT).await;
    assert!(
        matches!(harness.event().await, AgentEvent::RequestFailed { message, .. } if message.contains("20 seconds"))
    );
    let result = tokio::time::timeout(WAIT, &mut harness.connection)
        .await
        .expect("connection closes within its local deadline")
        .expect("connection task completes");
    assert!(result.unwrap_err().contains("did not acknowledge Stop"));
}

#[tokio::test(start_paused = true)]
async fn claude_progress_ends_the_retry_window_and_prevents_whole_turn_replay() {
    for update in [
        json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "partial"}}),
        json!({"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "reasoning"}}),
        json!({"sessionUpdate": "tool_call", "toolCallId": "tool-1", "title": "Execute", "kind": "execute"}),
    ] {
        let mut harness = Harness::ready_claude().await;
        harness.open_session("session-1").await;
        harness.send(json!({"kind": "prompt", "sessionId": "session-1", "text": "first"}));
        let first = harness.agent.expect("session/prompt").await;
        reject_prompt(&mut harness, &first, "server_error").await;
        harness.agent.expect("session/cancel").await;
        assert!(matches!(
            harness.event().await,
            AgentEvent::TurnRetrying { .. }
        ));
        tokio::time::advance(Duration::from_millis(500)).await;
        let retry = harness.agent.expect("session/prompt").await;
        harness.agent.write(json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "session-1", "update": update}})).await;
        assert!(matches!(harness.event().await, AgentEvent::Update { .. }));
        tokio::time::advance(prompt_retry::RETRY_WINDOW + Duration::from_secs(1)).await;
        reject_prompt(&mut harness, &retry, "server_error").await;
        assert!(matches!(
            harness.event().await,
            AgentEvent::RequestFailed { .. }
        ));
        assert_eq!(harness.stop().await, Ok(()));
    }
}

#[test]
fn claude_session_routing_rejects_missing_credentials_without_native_account_fallback() {
    let mut route = claude_route();
    route.headers.clear();
    assert!(session_routing::metadata(Some(&route)).is_err());
    route.headers.push(("x-api-key".into(), " ".into()));
    assert!(session_routing::metadata(Some(&route)).is_err());
}

#[tokio::test(flavor = "current_thread")]
async fn claude_new_and_restored_sessions_receive_credentials_over_stdio_without_gateway_login() {
    let mut harness = Harness::start_with_route(false, Some(claude_route()));
    let initialize = harness.agent.expect("initialize").await;
    harness
        .agent
        .reply(
            &initialize,
            json!({
                "protocolVersion": 1,
                "agentInfo": {"name": "claude-acp", "version": "fixture"},
                "agentCapabilities": {"loadSession": true},
                "authMethods": []
            }),
        )
        .await;
    assert!(matches!(harness.event().await, AgentEvent::Ready { .. }));
    let expected = fixture()["upstream"]["claudeSessionRouting"]["meta"].clone();
    harness.send(json!({"kind": "newSession", "token": "new-claude"}));
    // The very next request must be session/new, never gateway authenticate.
    let created = harness.agent.expect("session/new").await;
    assert_eq!(created["params"]["_meta"], expected);
    harness
        .agent
        .reply(&created, json!({"sessionId": "claude-1"}))
        .await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::SessionCreated { .. }
    ));
    harness.send(json!({"kind": "loadSession", "token": "load-claude", "sessionId": "claude-1"}));
    let loaded = harness.agent.expect("session/load").await;
    let restored = fixture()["upstream"]["claudeSessionRouting"]["restoredMeta"].clone();
    assert_eq!(loaded["params"]["_meta"], restored);
    assert_eq!(loaded["params"]["sessionId"], "claude-1");
    harness.agent.reply(&loaded, json!({})).await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::SessionLoaded { .. }
    ));
    assert_eq!(harness.stop().await, Ok(()));
}

// A restored selector can describe the transcript while the SDK still runs the
// launch default. Publishing it before an explicit model acknowledgement would
// allow the next prompt to use a different model from the visible selection.
#[tokio::test(flavor = "current_thread")]
async fn claude_restored_session_confirms_model_before_publishing_loaded() {
    for scenario in [
        "different-default",
        "same-default",
        "grouped",
        "outside-picker",
    ] {
        let mut harness = Harness::ready_claude().await;
        let mut options = fixture()["upstream"]["claudeRestoredSession"]["configOptions"].clone();
        if scenario == "same-default" {
            options[0]["currentValue"] =
                fixture()["upstream"]["claudeSessionRouting"]["provider"]["model"].clone();
        }
        if scenario == "grouped" {
            let choices = options[0]["options"].clone();
            options[0]["options"] =
                json!([{"group": "models", "name": "Models", "options": choices}]);
        } else if scenario == "outside-picker" {
            options[0]["options"] = json!([]);
        }
        let model = options[0]["currentValue"].as_str().unwrap().to_owned();
        harness.send(json!({"kind": "loadSession", "token": "restore", "sessionId": "history"}));
        let load = harness.agent.expect("session/load").await;
        assert!(load["params"]["_meta"]["claudeCode"]["options"]
            .get("model")
            .is_none());
        harness
            .agent
            .reply(&load, json!({"configOptions": options}))
            .await;
        let configure = harness.agent.expect("session/set_config_option").await;
        assert_eq!(configure["params"]["sessionId"], "history");
        assert_eq!(configure["params"]["configId"], "restored-model-selector");
        assert_eq!(configure["params"]["value"], model);
        assert!(
            harness.events.try_recv().is_err(),
            "loading stays pending until model confirmation"
        );
        // Return the full upstream configuration, including a changed effort
        // catalog; consumers must receive that response rather than stale load data.
        options[2]["currentValue"] = json!("high");
        harness
            .agent
            .reply(&configure, json!({"configOptions": options}))
            .await;
        match harness.event().await {
            AgentEvent::SessionLoaded {
                token,
                session_id,
                config_options,
            } => {
                assert_eq!(token, "restore");
                assert_eq!(session_id, "history");
                assert_eq!(serde_json::to_value(config_options).unwrap(), options);
            }
            other => panic!("expected confirmed restore, got {other:?}"),
        }
        harness.send(json!({"kind": "prompt", "sessionId": "history", "text": "continue"}));
        let prompt = harness.agent.expect("session/prompt").await;
        harness
            .agent
            .reply(&prompt, json!({"stopReason": "end_turn"}))
            .await;
        assert!(matches!(
            harness.event().await,
            AgentEvent::TurnFinished { .. }
        ));
        assert_eq!(harness.stop().await, Ok(()));
    }
}

#[tokio::test(flavor = "current_thread")]
async fn claude_restored_model_rejection_or_mismatch_does_not_report_loaded() {
    for rejection in [true, false] {
        let mut harness = Harness::ready_claude().await;
        let mut options = fixture()["upstream"]["claudeRestoredSession"]["configOptions"].clone();
        harness.send(json!({"kind": "loadSession", "token": "restore", "sessionId": "history"}));
        let load = harness.agent.expect("session/load").await;
        harness
            .agent
            .reply(&load, json!({"configOptions": options}))
            .await;
        let configure = harness.agent.expect("session/set_config_option").await;
        if rejection {
            harness.agent.write(json!({"jsonrpc": "2.0", "id": configure["id"], "error": {"code": -32603, "message": "model switch rejected"}})).await;
        } else {
            options[0]["currentValue"] = json!("wrong-model");
            harness
                .agent
                .reply(&configure, json!({"configOptions": options}))
                .await;
        }
        assert!(
            matches!(harness.event().await, AgentEvent::RequestFailed { token: Some(token), session_id: Some(id), .. } if token == "restore" && id == "history")
        );
        assert!(
            harness.events.try_recv().is_err(),
            "failed model sync must not unlock a queued prompt"
        );
        assert_eq!(harness.stop().await, Ok(()));
    }
}

#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn claude_restored_model_confirmation_shares_the_load_deadline() {
    let mut harness = Harness::ready_claude().await;
    harness.send(json!({"kind": "loadSession", "token": "restore", "sessionId": "history"}));
    let load = harness.agent.expect("session/load").await;
    tokio::time::advance(Duration::from_secs(30)).await;
    let options = fixture()["upstream"]["claudeRestoredSession"]["configOptions"].clone();
    harness
        .agent
        .reply(&load, json!({"configOptions": options}))
        .await;
    harness.agent.expect("session/set_config_option").await;
    tokio::time::advance(LOAD_SESSION_TIMEOUT - Duration::from_secs(30)).await;
    assert!(
        matches!(harness.event().await, AgentEvent::RequestFailed { token: Some(token), session_id: Some(id), message } if token == "restore" && id == "history" && message == "The Agent did not respond in time")
    );
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(flavor = "current_thread")]
async fn agent_without_gateway_sign_in_is_rejected_without_account_login() {
    let mut harness = Harness::start();
    let initialize = harness.agent.expect("initialize").await;
    harness
        .agent
        .reply(
            &initialize,
            json!({ "protocolVersion": 1, "authMethods": [{ "id": "chat-gpt", "name": "ChatGPT" }] }),
        )
        .await;
    let result = tokio::time::timeout(WAIT, &mut harness.connection)
        .await
        .expect("connection ends before deadline")
        .expect("connection task completes");
    assert!(result.unwrap_err().contains("custom API key"));
    assert!(
        harness.events.try_recv().is_err(),
        "no ready event without sign-in"
    );
}

// A lost startup cancel must never allow another prompt into the old turn.
#[tokio::test(flavor = "current_thread")]
async fn cancel_blocks_the_next_prompt_until_acknowledged() {
    let mut harness = Harness::ready().await;
    harness.open_session("session-1").await;
    harness.send(json!({ "kind": "prompt", "sessionId": "session-1", "text": "first" }));
    let first = harness.agent.expect("session/prompt").await;

    harness.send(json!({ "kind": "cancel", "sessionId": "session-1" }));
    let cancel = harness.agent.expect("session/cancel").await;
    assert_eq!(cancel["params"]["sessionId"], "session-1");
    match harness.event().await {
        AgentEvent::TurnCancelling { session_id } => assert_eq!(session_id, "session-1"),
        other => panic!("expected stopping turn, got {other:?}"),
    }

    // A second prompt is rejected before the agent answers the first one.
    harness.send(json!({ "kind": "prompt", "sessionId": "session-1", "text": "second" }));
    assert!(matches!(
        harness.event().await,
        AgentEvent::RequestFailed { .. }
    ));
    harness
        .agent
        .reply(&first, json!({ "stopReason": "cancelled" }))
        .await;
    assert!(
        matches!(harness.event().await, AgentEvent::TurnFinished { stop_reason, .. } if stop_reason == "cancelled")
    );
    harness.send(json!({ "kind": "prompt", "sessionId": "session-1", "text": "second" }));
    let second = harness.agent.expect("session/prompt").await;
    harness
        .agent
        .reply(&second, json!({ "stopReason": "end_turn" }))
        .await;
    // Events are ordered, so a stale report for the first turn would come first.
    match harness.event().await {
        AgentEvent::TurnFinished { stop_reason, .. } => assert_eq!(stop_reason, "end_turn"),
        other => panic!("expected the second turn to finish, got {other:?}"),
    }
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn unacknowledged_cancel_ends_the_connection_with_recovery_error() {
    let mut harness = Harness::ready().await;
    harness.open_session("session-1").await;
    harness.send(json!({ "kind": "prompt", "sessionId": "session-1", "text": "first" }));
    harness.agent.expect("session/prompt").await;
    harness.send(json!({ "kind": "cancel", "sessionId": "session-1" }));
    harness.agent.expect("session/cancel").await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnCancelling { .. }
    ));
    tokio::time::advance(CANCEL_TIMEOUT).await;
    let result = tokio::time::timeout(WAIT, &mut harness.connection)
        .await
        .unwrap()
        .unwrap();
    assert!(result.unwrap_err().contains("Reconnect"));
}

#[tokio::test(flavor = "current_thread")]
async fn session_configuration_round_trips_upstream_options() {
    let mut harness = Harness::ready().await;
    let options = fixture()["events"]["sessionConfigured"]["configOptions"].clone();
    harness.send(json!({ "kind": "newSession", "token": "new" }));
    let request = harness.agent.expect("session/new").await;
    harness
        .agent
        .reply(
            &request,
            json!({ "sessionId": "session-1", "configOptions": options }),
        )
        .await;
    match harness.event().await {
        AgentEvent::SessionCreated { config_options, .. } => {
            assert_eq!(serde_json::to_value(config_options).unwrap(), options)
        }
        other => panic!("expected session, got {other:?}"),
    }
    harness.send(fixture()["commands"]["setConfigOption"].clone());
    let request = harness.agent.expect("session/set_config_option").await;
    assert_eq!(request["params"]["configId"], "model");
    assert_eq!(request["params"]["value"], "example-model");
    harness
        .agent
        .reply(&request, json!({ "configOptions": options }))
        .await;
    assert_eq!(
        serde_json::to_value(harness.event().await).unwrap(),
        fixture()["events"]["sessionConfigured"]
    );
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(flavor = "current_thread")]
async fn every_new_session_repairs_a_stale_model_before_publishing_options() {
    let mut harness = Harness::ready().await;
    let upstream = fixture()["upstream"].clone();
    for token in ["first", "second"] {
        let mut initial = upstream["staleModelSession"].clone();
        if token == "second" {
            // Adapters without AIR recommendations still expose a usable catalog.
            initial["configOptions"][0]
                .as_object_mut()
                .unwrap()
                .remove("_meta");
        }
        harness.send(json!({ "kind": "newSession", "token": token }));
        let request = harness.agent.expect("session/new").await;
        harness.agent.reply(&request, initial).await;
        let repair = harness.agent.expect("session/set_config_option").await;
        assert_eq!(repair["params"]["sessionId"], "session-repaired");
        assert_eq!(repair["params"]["configId"], "model");
        assert_eq!(repair["params"]["value"], "model-current");
        assert!(
            harness.events.try_recv().is_err(),
            "a session must not be exposed before confirmation"
        );
        harness
            .agent
            .reply(&repair, upstream["repairedModelConfiguration"].clone())
            .await;
        let event = serde_json::to_value(harness.event().await).unwrap();
        assert_eq!(event["kind"], "sessionCreated");
        assert_eq!(event["token"], token);
        assert_eq!(
            event["configOptions"],
            upstream["repairedModelConfiguration"]["configOptions"]
        );
    }
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(flavor = "current_thread")]
async fn model_repair_rejection_does_not_publish_a_fake_success() {
    let mut harness = Harness::ready().await;
    harness.send(json!({ "kind": "newSession", "token": "new" }));
    let request = harness.agent.expect("session/new").await;
    harness
        .agent
        .reply(&request, fixture()["upstream"]["staleModelSession"].clone())
        .await;
    let repair = harness.agent.expect("session/set_config_option").await;
    harness.agent.write(json!({ "jsonrpc": "2.0", "id": repair["id"], "error": {"code": -32602, "message": "Model rejected"} })).await;
    let event = serde_json::to_value(harness.event().await).unwrap();
    assert_eq!(event["kind"], "requestFailed");
    assert_eq!(event["token"], "new");
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(flavor = "current_thread")]
async fn model_repair_requires_the_upstream_to_confirm_the_new_value() {
    let mut harness = Harness::ready().await;
    harness.send(json!({ "kind": "newSession", "token": "new" }));
    let request = harness.agent.expect("session/new").await;
    let stale = fixture()["upstream"]["staleModelSession"].clone();
    harness.agent.reply(&request, stale.clone()).await;
    let repair = harness.agent.expect("session/set_config_option").await;
    harness
        .agent
        .reply(&repair, json!({"configOptions": stale["configOptions"]}))
        .await;
    let event = serde_json::to_value(harness.event().await).unwrap();
    assert_eq!(event["kind"], "requestFailed");
    assert!(event["message"]
        .as_str()
        .unwrap()
        .contains("did not confirm"));
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn model_repair_shares_the_bounded_session_creation_deadline() {
    let mut harness = Harness::ready().await;
    harness.send(json!({ "kind": "newSession", "token": "new" }));
    let request = harness.agent.expect("session/new").await;
    harness
        .agent
        .reply(&request, fixture()["upstream"]["staleModelSession"].clone())
        .await;
    harness.agent.expect("session/set_config_option").await;
    tokio::time::advance(SESSION_REQUEST_TIMEOUT).await;
    let event = serde_json::to_value(harness.event().await).unwrap();
    assert_eq!(event["kind"], "requestFailed");
    assert_eq!(event["token"], "new");
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(flavor = "current_thread")]
async fn updates_and_turns_are_routed_to_their_own_sessions() {
    let mut harness = Harness::ready().await;
    harness.open_session("session-a").await;
    harness.open_session("session-b").await;
    harness.send(json!({ "kind": "prompt", "sessionId": "session-a", "text": "a" }));
    let prompt_a = harness.agent.expect("session/prompt").await;
    harness.send(json!({ "kind": "prompt", "sessionId": "session-b", "text": "b" }));
    let prompt_b = harness.agent.expect("session/prompt").await;
    for session in ["session-b", "session-a"] {
        harness
            .agent
            .write(json!({
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": {
                    "sessionId": session,
                    "update": { "sessionUpdate": "agent_message_chunk", "content": { "type": "text", "text": session } }
                }
            }))
            .await;
    }
    for expected in ["session-b", "session-a"] {
        match harness.event().await {
            AgentEvent::Update { session_id, update } => {
                assert_eq!(session_id, expected);
                assert_eq!(update["content"]["text"], expected);
            }
            other => panic!("expected update, got {other:?}"),
        }
    }
    harness
        .agent
        .reply(
            &prompt_b,
            fixture()["upstream"]["promptResponseWithUsage"].clone(),
        )
        .await;
    harness
        .agent
        .reply(&prompt_a, json!({ "stopReason": "max_tokens" }))
        .await;
    let finished: Vec<(String, String)> = [harness.event().await, harness.event().await]
        .into_iter()
        .map(|event| match event {
            AgentEvent::TurnFinished {
                session_id,
                stop_reason,
                usage,
            } => {
                if session_id == "session-b" {
                    let usage = usage.expect("reported counters survive the prompt response");
                    assert_eq!(usage.input_tokens, 18000);
                    assert_eq!(usage.output_tokens, 2000);
                    assert_eq!(usage.cached_read_tokens, Some(3000));
                } else {
                    assert!(usage.is_none(), "usage is not carried between sessions");
                }
                (session_id, stop_reason)
            }
            other => panic!("expected turn end, got {other:?}"),
        })
        .collect();
    assert_eq!(
        finished,
        [
            ("session-b".into(), "end_turn".into()),
            ("session-a".into(), "max_tokens".into())
        ]
    );
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(flavor = "current_thread")]
async fn permission_is_answered_by_the_user_and_rejected_by_cancel() {
    let mut harness = Harness::ready().await;
    harness.open_session("session-1").await;
    harness.send(json!({ "kind": "prompt", "sessionId": "session-1", "text": "run" }));
    let _prompt = harness.agent.expect("session/prompt").await;
    let permission_request = |id: u64| {
        json!({
            "jsonrpc": "2.0", "id": id, "method": "session/request_permission",
            "params": {
                "sessionId": "session-1",
                "toolCall": { "toolCallId": "call-1", "title": "Run tests" },
                "options": [{ "optionId": "allow_once", "name": "Allow Once", "kind": "allow_once" }]
            }
        })
    };

    harness.agent.write(permission_request(900)).await;
    let request_id = match harness.event().await {
        AgentEvent::Permission {
            session_id,
            request_id,
            ..
        } => {
            assert_eq!(session_id, "session-1");
            request_id
        }
        other => panic!("expected permission, got {other:?}"),
    };
    answer_permission(&harness.permissions, &request_id, Some("allow_once".into())).unwrap();
    let answer = harness.agent.next().await;
    assert_eq!(answer["id"], 900);
    assert_eq!(answer["result"]["outcome"]["outcome"], "selected");
    assert_eq!(answer["result"]["outcome"]["optionId"], "allow_once");

    harness.agent.write(permission_request(901)).await;
    let request_id = match harness.event().await {
        AgentEvent::Permission { request_id, .. } => request_id,
        other => panic!("expected permission, got {other:?}"),
    };
    harness.send(json!({ "kind": "cancel", "sessionId": "session-1" }));
    let answer = harness.agent.next().await;
    assert_eq!(answer["id"], 901);
    assert_eq!(answer["result"]["outcome"]["outcome"], "cancelled");
    assert!(answer_permission(&harness.permissions, &request_id, None).is_err());
    let _cancel = harness.agent.expect("session/cancel").await;

    // With no running turn, a late request is refused without asking the user.
    harness.agent.write(permission_request(902)).await;
    let answer = harness.agent.next().await;
    assert_eq!(answer["id"], 902);
    assert_eq!(answer["result"]["outcome"]["outcome"], "cancelled");
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnCancelling { .. }
    ));
    assert!(
        harness.events.try_recv().is_err(),
        "late request must not reach the UI"
    );
    assert_eq!(harness.stop().await, Ok(()));
}

// Regression: a permission request registered after the handle rejected the
// session's pending requests, but before the loop processed the cancel, must
// still be answered instead of remaining pending after cancellation.
#[tokio::test(flavor = "current_thread")]
async fn cancel_also_rejects_a_permission_registered_after_the_handle_check() {
    let mut harness = Harness::ready().await;
    harness.open_session("session-1").await;
    harness.send(json!({ "kind": "prompt", "sessionId": "session-1", "text": "run" }));
    let _prompt = harness.agent.expect("session/prompt").await;
    harness
        .agent
        .write(json!({
            "jsonrpc": "2.0", "id": 950, "method": "session/request_permission",
            "params": {
                "sessionId": "session-1",
                "toolCall": { "toolCallId": "call-1", "title": "Run tests" },
                "options": [{ "optionId": "allow_once", "name": "Allow Once", "kind": "allow_once" }]
            }
        }))
        .await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::Permission { .. }
    ));
    // Queue the cancel directly, skipping the handle's own rejection.
    let cancel =
        serde_json::from_value(json!({ "kind": "cancel", "sessionId": "session-1" })).unwrap();
    harness
        .controls
        .send(Control::Command(cancel))
        .expect("connection running");
    // The protocol does not order the cancel notification and the permission
    // reply, which are written by different tasks.
    let messages = [harness.agent.next().await, harness.agent.next().await];
    let answer = messages
        .iter()
        .find(|m| m["id"] == 950)
        .expect("permission answered");
    assert_eq!(answer["result"]["outcome"]["outcome"], "cancelled");
    assert!(messages.iter().any(|m| m["method"] == "session/cancel"));
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnCancelling { .. }
    ));
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(flavor = "current_thread")]
async fn session_history_is_listed_across_pages_and_loaded() {
    let mut harness = Harness::ready().await;
    harness.send(json!({ "kind": "listSessions", "token": "list" }));
    let first = harness.agent.expect("session/list").await;
    assert!(first["params"]["cwd"].is_string());
    harness
        .agent
        .reply(&first, json!({ "sessions": [{ "sessionId": "s1", "cwd": "/w", "title": "One" }], "nextCursor": "page-2" }))
        .await;
    let second = harness.agent.expect("session/list").await;
    assert_eq!(second["params"]["cursor"], "page-2");
    harness
        .agent
        .reply(
            &second,
            json!({ "sessions": [{ "sessionId": "s2", "cwd": "/w" }] }),
        )
        .await;
    match harness.event().await {
        AgentEvent::Sessions { token, sessions } => {
            assert_eq!(token, "list");
            let ids: Vec<&str> = sessions.iter().map(|s| s.session_id.as_str()).collect();
            assert_eq!(ids, ["s1", "s2"]);
        }
        other => panic!("expected sessions, got {other:?}"),
    }

    harness.send(json!({ "kind": "loadSession", "token": "load", "sessionId": "s1" }));
    let load = harness.agent.expect("session/load").await;
    assert_eq!(load["params"]["sessionId"], "s1");
    harness.agent.reply(&load, json!({})).await;
    match harness.event().await {
        AgentEvent::SessionLoaded {
            token, session_id, ..
        } => {
            assert_eq!((token.as_str(), session_id.as_str()), ("load", "s1"))
        }
        other => panic!("expected loaded session, got {other:?}"),
    }
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(flavor = "current_thread")]
async fn a_busy_session_rejects_a_second_prompt_without_stopping() {
    let mut harness = Harness::ready().await;
    harness.open_session("session-1").await;
    harness.send(json!({ "kind": "prompt", "sessionId": "session-1", "text": "first" }));
    let first = harness.agent.expect("session/prompt").await;
    harness.send(json!({ "kind": "prompt", "sessionId": "session-1", "text": "again" }));
    match harness.event().await {
        AgentEvent::RequestFailed { session_id, .. } => {
            assert_eq!(session_id.as_deref(), Some("session-1"))
        }
        other => panic!("expected request failure, got {other:?}"),
    }
    harness
        .agent
        .reply(&first, json!({ "stopReason": "end_turn" }))
        .await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnFinished { .. }
    ));
    assert_eq!(harness.stop().await, Ok(()));
}

// Quiet prompts remain busy even far beyond the former ten-minute cap.
#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn a_long_silent_prompt_warns_without_cancelling_or_replaying() {
    let mut harness = Harness::ready().await;
    harness.open_session("session-1").await;
    harness.send(json!({ "kind": "prompt", "sessionId": "session-1", "text": "wait" }));
    let prompt = harness.agent.expect("session/prompt").await;
    tokio::time::advance(prompt_retry::quiet_notice_delay()).await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnActivity { quiet: true, .. }
    ));
    tokio::time::advance(Duration::from_secs(60 * 60)).await;
    assert!(
        harness.events.try_recv().is_err(),
        "silence is advisory only"
    );
    harness.send(json!({ "kind": "prompt", "sessionId": "session-1", "text": "overlap" }));
    assert!(matches!(
        harness.event().await,
        AgentEvent::RequestFailed { .. }
    ));
    harness
        .agent
        .reply(&prompt, json!({ "stopReason": "end_turn" }))
        .await;
    assert!(
        matches!(harness.event().await, AgentEvent::TurnFinished { stop_reason, .. } if stop_reason == "end_turn")
    );
    // There was no automatic cancel or replay before this new prompt.
    harness.send(json!({ "kind": "prompt", "sessionId": "session-1", "text": "next" }));
    let next = harness.agent.expect("session/prompt").await;
    harness
        .agent
        .reply(&next, json!({ "stopReason": "end_turn" }))
        .await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnFinished { .. }
    ));
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn progress_resets_the_advisory_and_long_tools_can_complete() {
    let mut harness = Harness::ready().await;
    harness.open_session("session-1").await;
    harness.send(json!({ "kind": "prompt", "sessionId": "session-1", "text": "build" }));
    let prompt = harness.agent.expect("session/prompt").await;
    // Successive tool updates keep one turn alive for more than ten minutes.
    for _ in 0..5 {
        tokio::time::advance(prompt_retry::quiet_notice_delay() / 2).await;
        harness.agent.write(json!({ "jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": "session-1", "update": { "sessionUpdate": "tool_call", "toolCallId": "build", "title": "Build", "status": "in_progress" }
        }})).await;
        assert!(matches!(harness.event().await, AgentEvent::Update { .. }));
    }
    tokio::time::advance(prompt_retry::quiet_notice_delay()).await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnActivity { quiet: true, .. }
    ));
    harness.agent.write(json!({ "jsonrpc": "2.0", "method": "session/update", "params": {
        "sessionId": "session-1", "update": { "sessionUpdate": "tool_call_update", "toolCallId": "build", "status": "completed" }
    }})).await;
    assert!(matches!(harness.event().await, AgentEvent::Update { .. }));
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnActivity { quiet: false, .. }
    ));
    tokio::time::advance(prompt_retry::quiet_notice_delay() / 2).await;
    assert!(harness.events.try_recv().is_err());
    harness
        .agent
        .reply(&prompt, json!({ "stopReason": "end_turn" }))
        .await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnFinished { .. }
    ));
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn permission_wait_has_no_deadline_and_quiet_tracking_resumes_after_all_answers() {
    let mut harness = Harness::ready().await;
    harness.open_session("session-1").await;
    harness.send(json!({ "kind": "prompt", "sessionId": "session-1", "text": "run" }));
    let prompt = harness.agent.expect("session/prompt").await;
    let mut requests = Vec::new();
    for id in [801, 802] {
        harness.agent.write(json!({ "jsonrpc": "2.0", "id": id, "method": "session/request_permission", "params": {
            "sessionId": "session-1", "toolCall": { "toolCallId": format!("call-{id}"), "title": "Run tests" },
            "options": [{ "optionId": "allow_once", "name": "Allow Once", "kind": "allow_once" }]
        }})).await;
        match harness.event().await {
            AgentEvent::Permission { request_id, .. } => requests.push(request_id),
            other => panic!("expected permission, got {other:?}"),
        }
    }
    tokio::time::advance(Duration::from_secs(60 * 60)).await;
    assert!(harness.events.try_recv().is_err());
    answer_permission(
        &harness.permissions,
        &requests[0],
        Some("allow_once".into()),
    )
    .unwrap();
    let answer = harness.agent.next().await;
    assert_eq!(answer["result"]["outcome"]["optionId"], "allow_once");
    tokio::time::advance(Duration::from_secs(60 * 60)).await;
    assert!(
        harness.events.try_recv().is_err(),
        "another permission is still pending"
    );
    answer_permission(
        &harness.permissions,
        &requests[1],
        Some("allow_once".into()),
    )
    .unwrap();
    let answer = harness.agent.next().await;
    assert_eq!(answer["result"]["outcome"]["optionId"], "allow_once");
    tokio::time::advance(prompt_retry::quiet_notice_delay()).await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnActivity { quiet: true, .. }
    ));
    harness
        .agent
        .reply(&prompt, json!({ "stopReason": "end_turn" }))
        .await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnFinished { .. }
    ));
    assert_eq!(harness.stop().await, Ok(()));
}

// A user approval cannot hold the SDK dispatch loop or hide another session's progress.
#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn pending_permission_does_not_block_other_sessions_and_exit_settles_the_connection() {
    let mut harness = Harness::ready().await;
    harness.open_session("session-a").await;
    harness.open_session("session-b").await;
    for session in ["session-a", "session-b"] {
        harness.send(json!({ "kind": "prompt", "sessionId": session, "text": "run" }));
        harness.agent.expect("session/prompt").await;
    }
    harness.agent.write(json!({ "jsonrpc": "2.0", "id": 901, "method": "session/request_permission", "params": {
        "sessionId": "session-a", "toolCall": { "toolCallId": "approval", "title": "Run tests" },
        "options": [{ "optionId": "allow_once", "name": "Allow Once", "kind": "allow_once" }]
    }})).await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::Permission { .. }
    ));
    harness.agent.write(json!({ "jsonrpc": "2.0", "method": "session/update", "params": {
        "sessionId": "session-b", "update": { "sessionUpdate": "agent_message_chunk", "content": { "type": "text", "text": "Other work continues" } }
    }})).await;
    assert!(
        matches!(harness.event().await, AgentEvent::Update { session_id, .. } if session_id == "session-b")
    );
    tokio::time::advance(prompt_retry::quiet_notice_delay()).await;
    assert!(
        matches!(harness.event().await, AgentEvent::TurnActivity { session_id, quiet: true } if session_id == "session-b")
    );
    assert!(
        harness.events.try_recv().is_err(),
        "approval wait is not quiet work"
    );
    harness
        .agent
        .writer
        .shutdown()
        .await
        .expect("agent exits with pending approval");
    let result = tokio::time::timeout(WAIT, &mut harness.connection)
        .await
        .expect("EOF is dispatched despite pending approval")
        .expect("connection joins");
    assert!(result.is_err());
    assert!(
        harness.permissions.lock().unwrap().is_empty(),
        "connection exit releases approval senders"
    );
}

#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn user_stop_after_quiet_notice_retains_busy_state_until_acknowledged() {
    let mut harness = Harness::ready().await;
    harness.open_session("session-1").await;
    harness.send(json!({ "kind": "prompt", "sessionId": "session-1", "text": "wait" }));
    let prompt = harness.agent.expect("session/prompt").await;
    tokio::time::advance(prompt_retry::quiet_notice_delay()).await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnActivity { quiet: true, .. }
    ));
    harness.send(json!({ "kind": "cancel", "sessionId": "session-1" }));
    harness.agent.expect("session/cancel").await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnCancelling { .. }
    ));
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnActivity { quiet: false, .. }
    ));
    harness.send(json!({ "kind": "prompt", "sessionId": "session-1", "text": "overlap" }));
    assert!(matches!(
        harness.event().await,
        AgentEvent::RequestFailed { .. }
    ));
    harness
        .agent
        .reply(&prompt, json!({ "stopReason": "cancelled" }))
        .await;
    assert!(
        matches!(harness.event().await, AgentEvent::TurnFinished { stop_reason, .. } if stop_reason == "cancelled")
    );
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(flavor = "current_thread")]
async fn agent_exit_without_a_stop_request_is_reported_as_failure() {
    let mut harness = Harness::ready().await;
    harness
        .agent
        .writer
        .shutdown()
        .await
        .expect("close agent output");
    let result = tokio::time::timeout(WAIT, &mut harness.connection)
        .await
        .expect("connection ends before deadline")
        .expect("connection task completes");
    assert!(result.is_err());
}

#[test]
fn stderr_tail_keeps_recent_lines_and_redacts_the_key() {
    let mut tail = StderrTail::default();
    for index in 0..40 {
        tail.push(format!("line {index}\n").as_bytes());
    }
    tail.push(b"auth failed for sk-secret\n");
    let summary = tail.summary("sk-secret").expect("stderr summary");
    assert!(!summary.contains("sk-secret"));
    assert!(summary.ends_with("auth failed for <redacted>"));
    assert!(!summary.contains("line 0\n"));
    assert_eq!(summary.lines().count(), STDERR_TAIL_LINES);

    let mut large = StderrTail::default();
    large.push(&vec![b'x'; STDERR_TAIL_BYTES * 2]);
    assert_eq!(large.0.len(), STDERR_TAIL_BYTES);
    assert!(StderrTail::default().summary("key").is_none());
}

#[test]
fn provider_endpoints_are_normalized_per_protocol_and_must_be_secure() {
    let endpoint = |url: &str, insecure: bool| ProviderCredentials {
        base_url: url.into(),
        allow_insecure_http: insecure,
        ..provider()
    };
    for url in [
        "https://host.example/v1",
        "https://host.example/v1/",
        " https://host.example/v1/responses ",
    ] {
        assert_eq!(
            endpoint(url, false).responses_base_url().unwrap(),
            "https://host.example/v1"
        );
    }
    for url in [
        "https://api.example",
        "https://api.example/v1",
        "https://api.example/v1/messages/",
    ] {
        assert_eq!(
            endpoint(url, false).anthropic_base_url().unwrap(),
            "https://api.example"
        );
    }
    assert!(endpoint("http://localhost:1234/v1", false)
        .responses_base_url()
        .is_err());
    assert_eq!(
        endpoint("http://localhost:1234/v1", true)
            .responses_base_url()
            .unwrap(),
        "http://localhost:1234/v1"
    );
    for url in [
        "",
        "host.example/v1",
        "https://",
        "https://host.example/v1?key=1",
        "ftp://host",
    ] {
        assert!(endpoint(url, true).responses_base_url().is_err(), "{url}");
    }
}

#[test]
fn provider_debug_output_never_contains_the_key() {
    let rendered = format!("{:?}", provider());
    assert!(!rendered.contains("test-key-123"));
    assert!(rendered.contains("<redacted>"));
}

#[test]
fn child_path_puts_the_agent_directory_before_the_search_path() {
    let directory = std::env::temp_dir().join("lithe-agent-bin");
    let base = std::env::join_paths(["/shell/node/bin", "/usr/bin"]).unwrap();
    let path = child_path(&directory.join("codex-acp"), Some(base)).expect("PATH");
    let entries: Vec<PathBuf> = std::env::split_paths(&path).collect();
    assert_eq!(
        entries,
        [directory, "/shell/node/bin".into(), "/usr/bin".into()]
    );
    assert!(child_path(Path::new("codex-acp"), None).is_none());
}

/// Install a fake adapter the way `install` leaves it, without running npm.
fn fake_install(data: &Path, agent_id: &str) {
    let agent = catalog::find(agent_id).unwrap();
    let command = install::installed_command(data, agent);
    std::fs::create_dir_all(command.parent().unwrap()).unwrap();
    std::fs::write(&command, "#!/bin/sh\n").unwrap();
    std::fs::write(
        install::agent_directory(data, agent).join("lithe-agent.json"),
        format!(r#"{{"id":"{agent_id}","version":"{}"}}"#, agent.version),
    )
    .unwrap();
}

#[test]
fn catalog_agents_resolve_to_their_install_and_key_delivery() {
    struct Cleanup(PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    let data = std::env::temp_dir().join(format!("lithe-resolve-{}", std::process::id()));
    let _cleanup = Cleanup(data.clone());
    let _ = std::fs::remove_dir_all(&data);
    let launch = |agent_id: &str, provider: ProviderCredentials| AgentLaunch {
        agent_id: Some(agent_id.into()),
        command: None,
        args: vec![],
        cwd: std::env::temp_dir(),
        data_directory: Some(data.clone()),
        provider: Some(provider),
        authentication: AgentAuthentication::ApiKey,
        observe_model_calls: false,
        observe_subagents: false,
        process_scope: None,
    };
    let anthropic = ProviderCredentials {
        protocol: ProviderProtocol::AnthropicMessages,
        base_url: "https://api.example/v1/messages".into(),
        ..provider()
    };
    let codex_cli = |command: &str| match command {
        "codex" => Some(environment::DetectedTool {
            version: "0.156.1".into(),
            path: "/opt/example/bin/codex".into(),
        }),
        "claude" => Some(environment::DetectedTool {
            version: "2.1.282".into(),
            path: "/opt/example/bin/claude".into(),
        }),
        _ => None,
    };
    let resolve = |launch: AgentLaunch| resolve_with(launch, &codex_cli);
    let not_installed = resolve(launch("codex-acp", provider())).err().unwrap();
    assert!(not_installed.contains("not installed"), "{not_installed}");
    fake_install(&data, "codex-acp");
    fake_install(&data, "claude-acp");

    let mut subscription = launch("codex-acp", provider());
    subscription.authentication = AgentAuthentication::CodexSubscription;
    subscription.provider = None;
    let mut subscription = resolve(subscription).unwrap();
    assert!(subscription.gateway.is_none());
    assert!(subscription.secret.is_empty());
    assert_eq!(
        subscription.subscription_cli,
        Some("/opt/example/bin/codex".into())
    );
    let config: Value = serde_json::from_str(
        &subscription
            .env
            .iter()
            .find(|(name, _)| name == "CODEX_CONFIG")
            .unwrap()
            .1,
    )
    .unwrap();
    assert_eq!(config["model_provider"], "openai");
    assert_eq!(config["openai_base_url"], "");
    assert_eq!(
        config["chatgpt_base_url"],
        "https://chatgpt.com/backend-api/"
    );
    assert!(config.get("model").is_none());
    assert_eq!(config["tools"]["update_plan"]["enabled"], true);
    assert!(config.get("collaboration_mode").is_none());

    // Statistics changes only this process's inference route; native account,
    // quota and model ownership survive without installing a second provider.
    let environment = subscription.env.clone();
    subscription::observe_model_calls(&mut subscription, "http://127.0.0.1:1234/lithe-fixture")
        .unwrap();
    for ((name, before), (_, after)) in environment.iter().zip(&subscription.env) {
        if name == "CODEX_CONFIG" {
            let mut after: Value = serde_json::from_str(after).unwrap();
            assert_eq!(
                after["openai_base_url"],
                "http://127.0.0.1:1234/lithe-fixture/backend-api/codex"
            );
            after["openai_base_url"] = json!("");
            assert_eq!(after, serde_json::from_str::<Value>(before).unwrap());
        } else {
            assert_eq!(before, after);
        }
    }
    assert!(subscription.gateway.is_none() && subscription.secret.is_empty());

    let codex = resolve(launch("codex-acp", provider())).unwrap();
    assert!(codex.command.ends_with("node_modules/.bin/codex-acp") || cfg!(windows));
    // The adapter drives the user's own Codex; the key never enters the environment.
    assert_eq!(
        codex.env[0],
        ("CODEX_PATH".to_owned(), "/opt/example/bin/codex".to_owned())
    );
    let config: Value = serde_json::from_str(&codex.env[1].1).unwrap();
    assert_eq!(codex.env[1].0, "CODEX_CONFIG");
    assert_eq!(config["tools"]["update_plan"]["enabled"], true);
    assert!(config.get("model").is_none());
    assert!(config.get("collaboration_mode").is_none());
    assert_eq!(
        codex.gateway.unwrap().base_url,
        "https://gateway.example.com/v1"
    );
    let with_model = resolve(launch(
        "codex-acp",
        ProviderCredentials {
            model: Some(" gpt-5.5 ".into()),
            ..provider()
        },
    ))
    .unwrap();
    let config: Value = serde_json::from_str(&with_model.env[1].1).unwrap();
    assert_eq!(with_model.env.len(), 2);
    assert_eq!(with_model.env[0], codex.env[0]);
    assert_eq!(with_model.env[1].0, "CODEX_CONFIG");
    assert_eq!(
        config,
        json!({"model":"gpt-5.5","tools":{"update_plan":{"enabled":true}}})
    );
    let missing_cli = resolve_with(launch("codex-acp", provider()), &|_| None)
        .err()
        .unwrap();
    assert!(
        missing_cli.contains("Codex CLI was not found"),
        "{missing_cli}"
    );
    let old_cli = resolve_with(launch("codex-acp", provider()), &|_| {
        Some(environment::DetectedTool {
            version: "0.150.0".into(),
            path: "/opt/example/bin/codex".into(),
        })
    })
    .err()
    .unwrap();
    assert!(old_cli.contains("0.156.0 or later"), "{old_cli}");
    assert!(!with_model
        .env
        .iter()
        .any(|(_, value)| value.contains("test-key-123")));

    let claude = resolve(launch(
        "claude-acp",
        ProviderCredentials {
            model: Some("claude-sonnet-5".into()),
            ..anthropic
        },
    ))
    .unwrap();
    // Claude uses ACP session options; the key never enters the adapter's
    // launch environment or arguments.
    let sign_in = claude.gateway.expect("gateway sign-in");
    assert_eq!(sign_in.base_url, "https://api.example");
    assert_eq!(
        sign_in.headers,
        [("x-api-key".to_owned(), "test-key-123".to_owned())]
    );
    assert_eq!(sign_in.model.as_deref(), Some("claude-sonnet-5"));
    assert_eq!(
        claude.env,
        [(
            "CLAUDE_CODE_EXECUTABLE".to_owned(),
            "/opt/example/bin/claude".to_owned()
        )]
    );
    let mismatch = resolve(launch("claude-acp", provider())).err().unwrap();
    assert!(mismatch.contains("Anthropic Messages"), "{mismatch}");
    assert!(resolve(launch("unknown", provider())).is_err());
    let _ = std::fs::remove_dir_all(&data);
}

#[test]
fn windows_batch_shims_are_only_forwarded_to_adapters_that_shell_out() {
    let claude = catalog::find("claude-acp").unwrap().cli.as_ref().unwrap();
    let codex = catalog::find("codex-acp").unwrap().cli.as_ref().unwrap();
    let tool = |path: &str| environment::DetectedTool {
        version: "2.1.303".into(),
        path: path.into(),
    };
    let shim = tool("C:/tools/claude.cmd");

    let claude_shim = cli_path_env(claude, &shim);
    if cfg!(windows) {
        assert_eq!(claude_shim, None);
    } else {
        assert_eq!(
            claude_shim,
            Some((
                "CLAUDE_CODE_EXECUTABLE".into(),
                "C:/tools/claude.cmd".into()
            ))
        );
    }
    assert_eq!(
        cli_path_env(codex, &shim),
        Some(("CODEX_PATH".into(), "C:/tools/claude.cmd".into()))
    );
    assert_eq!(
        cli_path_env(claude, &tool("C:/tools/claude.exe")),
        Some((
            "CLAUDE_CODE_EXECUTABLE".into(),
            "C:/tools/claude.exe".into()
        ))
    );
}

#[test]
fn invalid_settings_are_reported_without_starting_a_process() {
    let launch = |command: &str, key: &str, url: &str, protocol: ProviderProtocol| {
        custom_launch(
            command,
            ProviderCredentials {
                protocol,
                api_key: key.into(),
                base_url: url.into(),
                ..provider()
            },
        )
    };
    let responses = ProviderProtocol::Responses;
    let cases = [
        (launch(" ", "key", "https://h/v1", responses), "executable"),
        (
            launch(
                "/lithe/nonexistent-acp-agent",
                " ",
                "https://h/v1",
                responses,
            ),
            "API key",
        ),
        (
            launch(
                "/lithe/nonexistent-acp-agent",
                "key",
                "http://h/v1",
                responses,
            ),
            "https",
        ),
        (
            launch(
                "/lithe/nonexistent-acp-agent",
                "key",
                "https://h",
                ProviderProtocol::AnthropicMessages,
            ),
            "Responses API",
        ),
    ];
    for (launch, expected) in cases {
        let (sender, receiver) = mpsc::channel();
        let handle = AgentHandle::open(
            launch,
            Arc::new(move |event| {
                let _ = sender.send(event);
            }),
        )
        .expect("worker starts");
        match receiver.recv_timeout(WAIT) {
            Ok(AgentEvent::Stopped {
                message: Some(message),
            }) => {
                assert!(message.contains(expected), "{message}");
                assert!(
                    !message.contains("Could not start"),
                    "no process for invalid settings"
                );
            }
            other => panic!("expected stopped, got {other:?}"),
        }
        handle.close();
    }
}

// The timing harness starts this test cold: a missing custom command must not
// wait for Node/npm version probes before reporting its spawn error.
#[test]
fn spawn_failure_reports_stopped_with_a_message() {
    let (sender, receiver) = mpsc::channel();
    let launch = custom_launch("/lithe/nonexistent-acp-agent", provider());
    let handle = AgentHandle::open(
        launch,
        Arc::new(move |event| {
            let _ = sender.send(event);
        }),
    )
    .expect("worker starts");
    match receiver.recv_timeout(WAIT) {
        Ok(AgentEvent::Stopped {
            message: Some(message),
        }) => {
            assert!(message.contains("Could not start the Agent"));
        }
        other => panic!("expected stopped with message, got {other:?}"),
    }
    handle.close();
}

// Protect the actual SDK wire boundary, not just the local command DTO.
#[tokio::test]
async fn selected_files_reach_the_agent_as_acp_resource_links() {
    let mut harness = Harness::ready().await;
    harness.open_session("session-1").await;
    let fixture = fixture();
    for name in ["promptWithFiles", "fileOnlyPrompt"] {
        harness.send(fixture["commands"][name].clone());
        let request = harness.agent.expect("session/prompt").await;
        let content = request["params"]["prompt"]
            .as_array()
            .expect("prompt content");
        let files = fixture["commands"][name]["files"].as_array().unwrap();
        let offset = usize::from(name == "promptWithFiles");
        assert_eq!(content.len(), files.len() + offset + 1);
        if offset == 1 {
            assert_eq!(
                content[0],
                json!({ "type": "text", "text": "Explain these files" })
            );
        }
        for (actual, file) in content[offset..offset + files.len()].iter().zip(files) {
            assert_eq!(
                actual,
                &json!({ "type": "resource_link", "uri": file["uri"], "name": file["name"] })
            );
        }
        assert!(content.last().unwrap()["text"]
            .as_str()
            .unwrap()
            .contains("openedWorkspaceRoot"));
        harness
            .agent
            .reply(&request, json!({ "stopReason": "end_turn" }))
            .await;
        assert!(matches!(
            harness.event().await,
            AgentEvent::TurnFinished { .. }
        ));
    }
    harness.stop().await.expect("owned connection stopped");
}

#[tokio::test]
async fn invalid_file_reference_does_not_reserve_or_finish_a_turn() {
    let mut harness = Harness::ready().await;
    harness.open_session("session-1").await;
    for files in [
        json!([{ "uri": "https://example.com/file.txt", "name": "file.txt" }]),
        json!([{ "uri": "file:///example/file.txt?secret", "name": "file.txt" }]),
        json!((0..33)
            .map(
                |index| json!({ "uri": format!("file:///example/{index}.txt"), "name": "file.txt" })
            )
            .collect::<Vec<_>>()),
    ] {
        harness.send(
            json!({ "kind": "prompt", "sessionId": "session-1", "text": "Read", "files": files }),
        );
        assert!(matches!(
            harness.event().await,
            AgentEvent::RequestFailed {
                session_id: Some(_),
                ..
            }
        ));
    }
    harness.send(fixture()["commands"]["prompt"].clone());
    let request = harness.agent.expect("session/prompt").await;
    assert_eq!(
        request["params"]["prompt"][0],
        json!({ "type": "text", "text": "Explain this project" })
    );
    harness
        .agent
        .reply(&request, json!({ "stopReason": "end_turn" }))
        .await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnFinished { .. }
    ));
    harness.stop().await.expect("owned connection stopped");
}

// The opened nested project remains the scope of new, steered and restored
// turns. Test the actual ACP wire and replay, including text-only adapters.
#[tokio::test(flavor = "current_thread")]
async fn nested_workspace_scope_survives_new_restore_steering_and_replay() {
    let fixture = fixture()["workspaceContext"].clone();
    for relative_root in fixture["relativeRoots"].as_array().unwrap() {
        let cwd = std::env::temp_dir().join(relative_root.as_str().unwrap());
        let mut harness = Harness::start_in_workspace(false, gateway(), cwd.clone());
        harness
            .agent
            .handshake_with_steering(true, "text-only-agent")
            .await;
        assert!(matches!(harness.event().await, AgentEvent::Ready { .. }));
        harness.send(json!({ "kind": "newSession", "token": "new" }));
        let new = harness.agent.expect("session/new").await;
        assert_eq!(new["params"]["cwd"], cwd.to_str().unwrap());
        harness
            .agent
            .reply(&new, json!({ "sessionId": "nested" }))
            .await;
        assert!(matches!(
            harness.event().await,
            AgentEvent::SessionCreated { .. }
        ));

        let question = fixture["question"].as_str().unwrap();
        harness.send(json!({ "kind": "prompt", "sessionId": "nested", "text": question }));
        let prompt = harness.agent.expect("session/prompt").await;
        let content = prompt["params"]["prompt"].as_array().unwrap();
        assert_eq!(content[0], json!({ "type": "text", "text": question }));
        let context = content.last().unwrap().clone();
        let context_text = context["text"].as_str().unwrap();
        let metadata: Value = serde_json::from_str(context_text.lines().nth(2).unwrap()).unwrap();
        assert_eq!(metadata["openedWorkspaceRoot"], cwd.to_str().unwrap());

        harness.send(json!({ "kind": "steer", "token": "supplement", "sessionId": "nested", "text": fixture["supplement"] }));
        let steer = harness.agent.expect("_session/steering").await;
        assert_eq!(
            steer["params"]["prompt"].as_array().unwrap().last(),
            Some(&context)
        );
        harness
            .agent
            .reply(&steer, json!({ "outcome": "injected" }))
            .await;
        assert!(matches!(
            harness.event().await,
            AgentEvent::SteeringResult { .. }
        ));
        harness
            .agent
            .reply(&prompt, json!({ "stopReason": "end_turn" }))
            .await;
        assert!(matches!(
            harness.event().await,
            AgentEvent::TurnFinished { .. }
        ));

        harness.send(json!({ "kind": "loadSession", "token": "restore", "sessionId": "nested" }));
        let load = harness.agent.expect("session/load").await;
        assert_eq!(load["params"]["cwd"], new["params"]["cwd"]);
        let echo = |text: &str| {
            json!({ "jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "nested", "update": { "sessionUpdate": "user_message_chunk",
                    "content": { "type": "text", "text": text } }
            }})
        };
        harness.agent.write(echo(context_text)).await;
        harness
            .agent
            .write(echo(&format!("{question}\n\n{context_text}")))
            .await;
        match harness.event().await {
            AgentEvent::Update { update, .. } => assert_eq!(update["content"]["text"], question),
            other => panic!("expected original user message, got {other:?}"),
        }
        harness.agent.reply(&load, json!({})).await;
        assert!(matches!(
            harness.event().await,
            AgentEvent::SessionLoaded { .. }
        ));
        harness.send(json!({ "kind": "prompt", "sessionId": "nested", "text": "Continue explaining this project" }));
        let resumed = harness.agent.expect("session/prompt").await;
        assert_eq!(
            resumed["params"]["prompt"].as_array().unwrap().last(),
            Some(&context)
        );
        harness
            .agent
            .reply(&resumed, json!({ "stopReason": "end_turn" }))
            .await;
        assert!(matches!(
            harness.event().await,
            AgentEvent::TurnFinished { .. }
        ));
        let title = format!(
            "{question}\n\n{}",
            context_text.chars().take(300).collect::<String>()
        );
        harness.agent.write(json!({ "jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": "nested", "update": { "sessionUpdate": "session_info_update", "title": title }
        }})).await;
        match harness.event().await {
            AgentEvent::Update { update, .. } => assert_eq!(update["title"], question),
            other => panic!("expected clean live title, got {other:?}"),
        }
        harness.send(json!({ "kind": "listSessions", "token": "history" }));
        let list = harness.agent.expect("session/list").await;
        harness
            .agent
            .reply(
                &list,
                json!({ "sessions": [{ "sessionId": "nested", "cwd": cwd, "title": title }] }),
            )
            .await;
        match harness.event().await {
            AgentEvent::Sessions { sessions, .. } => {
                assert_eq!(sessions[0].title.as_deref(), Some(question))
            }
            other => panic!("expected clean history title, got {other:?}"),
        }
        assert_eq!(harness.stop().await, Ok(()));
    }
}

#[tokio::test(flavor = "current_thread")]
async fn native_slash_command_reaches_acp_without_extra_context_or_arguments() {
    let mut harness = Harness::ready().await;
    harness.open_session("commands").await;
    for text in [
        "/usage",
        "/compact preserve project structure",
        "/model example-model",
    ] {
        harness.send(json!({ "kind": "prompt", "sessionId": "commands", "text": text }));
        let prompt = harness.agent.expect("session/prompt").await;
        assert_eq!(
            prompt["params"]["prompt"],
            json!([{ "type": "text", "text": text }])
        );
        harness
            .agent
            .reply(&prompt, json!({ "stopReason": "end_turn" }))
            .await;
        assert!(matches!(
            harness.event().await,
            AgentEvent::TurnFinished { .. }
        ));
    }
    let mut command = fixture()["commands"]["nativeCommandWithFiles"].clone();
    command["sessionId"] = json!("commands");
    harness.send(command);
    let prompt = harness.agent.expect("session/prompt").await;
    assert_eq!(
        prompt["params"]["prompt"],
        fixture()["workspaceContext"]["nativeCommandWithFilesContent"]
    );
    harness
        .agent
        .reply(&prompt, json!({"stopReason":"end_turn"}))
        .await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnFinished { .. }
    ));
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(flavor = "current_thread")]
async fn context_only_titles_are_missing_in_live_updates_and_history() {
    let mut harness = Harness::ready().await;
    harness.open_session("file-only").await;
    let mut command = fixture()["commands"]["fileOnlyPrompt"].clone();
    command["sessionId"] = json!("file-only");
    harness.send(command);
    let prompt = harness.agent.expect("session/prompt").await;
    let content = prompt["params"]["prompt"].as_array().unwrap();
    assert_eq!(content[0]["type"], "resource_link");
    let context = content.last().unwrap()["text"].as_str().unwrap();
    let titles = [
        context.to_owned(),
        context.chars().take(300).collect(),
        context
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
            .chars()
            .take(300)
            .collect(),
        " \n\t ".into(),
    ];
    harness
        .agent
        .reply(&prompt, json!({"stopReason":"end_turn"}))
        .await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::TurnFinished { .. }
    ));

    let expected = fixture()["events"]["sessionsWithoutGeneratedTitles"].clone();
    let sessions: Vec<_> = expected["sessions"].as_array().unwrap().iter().zip(&titles)
        .map(|(session, title)| json!({"sessionId":session["sessionId"], "cwd":std::env::temp_dir(), "title":title}))
        .collect();
    harness.send(json!({"kind":"listSessions", "token":"untitled-history"}));
    let list = harness.agent.expect("session/list").await;
    harness
        .agent
        .reply(&list, json!({"sessions":sessions}))
        .await;
    assert_eq!(
        serde_json::to_value(harness.event().await).unwrap(),
        expected
    );

    for title in titles {
        harness.agent.write(json!({"jsonrpc":"2.0", "method":"session/update", "params":{
            "sessionId":"file-only", "update":{"sessionUpdate":"session_info_update", "title":title, "_meta":{"preserved":true}}
        }})).await;
        match harness.event().await {
            AgentEvent::Update { update, .. } => {
                assert!(
                    update["title"].is_null(),
                    "A removed title must not hide UI fallbacks"
                );
                assert_eq!(update["_meta"]["preserved"], true);
            }
            other => panic!("expected missing live title, got {other:?}"),
        }
    }
    assert_eq!(harness.stop().await, Ok(()));
}

/// The adapter owns login and reports identity before any session can start.
async fn subscription_initialize(harness: &mut Harness, account: bool) {
    let initialize = harness.agent.expect("initialize").await;
    harness
        .agent
        .reply(
            &initialize,
            json!({
                "protocolVersion": 1,
                "authMethods": [{"id":"chat-gpt","name":"ChatGPT"}],
                "agentCapabilities": {"_meta":{"authStatus":{}}}
            }),
        )
        .await;
    subscription_identity(harness, account).await;
}

async fn subscription_identity(harness: &mut Harness, account: bool) {
    harness.agent.write(json!({"jsonrpc":"2.0","method":"_auth/status_update","params":{
        "authStatus": if account {
            json!({"kind":"account","label":"ChatGPT Plus","account":{"email":"person@example.test","plan":"plus"}})
        } else { json!({"kind":"none","label":"Not logged in"}) }
    }})).await;
}

#[tokio::test(flavor = "current_thread")]
async fn subscription_reuses_account_without_api_key_or_browser_login() {
    let mut harness = Harness::start_with(true);
    subscription_initialize(&mut harness, true).await;
    assert!(matches!(harness.event().await, AgentEvent::Account { .. }));
    assert!(matches!(harness.event().await, AgentEvent::Ready { .. }));
    harness.send(json!({"kind":"newSession","token":"new"}));
    // No authenticate call is needed for an already reported account.
    let request = harness.agent.expect("session/new").await;
    harness
        .agent
        .reply(&request, json!({"sessionId":"subscription-session"}))
        .await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::SessionCreated { .. }
    ));
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(flavor = "current_thread")]
async fn subscription_login_requires_explicit_command_and_confirmed_account() {
    let mut harness = Harness::start_with(true);
    subscription_initialize(&mut harness, false).await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::AuthenticationRequired
    ));
    harness.send(json!({"kind":"authenticate"}));
    assert!(matches!(harness.event().await, AgentEvent::Authenticating));
    let request = harness.agent.expect("authenticate").await;
    assert_eq!(request["params"], json!({"methodId":"chat-gpt"}));
    // A response can be dispatched before its separate account notification.
    harness.agent.reply(&request, json!({})).await;
    subscription_identity(&mut harness, true).await;
    assert!(matches!(harness.event().await, AgentEvent::Account { .. }));
    assert!(matches!(harness.event().await, AgentEvent::Ready { .. }));
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(flavor = "current_thread")]
async fn subscription_login_can_stop_without_waiting_for_browser() {
    let mut harness = Harness::start_with(true);
    subscription_initialize(&mut harness, false).await;
    assert!(matches!(
        harness.event().await,
        AgentEvent::AuthenticationRequired
    ));
    harness.send(json!({"kind":"authenticate"}));
    assert!(matches!(harness.event().await, AgentEvent::Authenticating));
    harness.agent.expect("authenticate").await;
    assert_eq!(harness.stop().await, Ok(()));
}

#[tokio::test(flavor = "current_thread")]
async fn subscription_account_change_disconnects_before_reusing_old_identity() {
    let mut harness = Harness::start_with(true);
    subscription_initialize(&mut harness, true).await;
    harness.event().await;
    harness.event().await;
    subscription_identity(&mut harness, false).await;
    let result = tokio::time::timeout(WAIT, &mut harness.connection)
        .await
        .expect("bounded account change")
        .unwrap();
    assert!(result.unwrap_err().contains("account changed"));
}

#[test]
fn subscription_rejects_claude_custom_agents_and_ambiguous_api_credentials() {
    for agent in [None, Some("claude-acp"), Some("codex-acp")] {
        let mut launch = custom_launch("fixture-agent", provider());
        launch.authentication = AgentAuthentication::CodexSubscription;
        launch.agent_id = agent.map(str::to_owned);
        assert!(resolve_with(launch, &|_| None)
            .err()
            .unwrap()
            .contains("only available for Codex"));
    }
}

#[tokio::test(flavor = "current_thread")]
async fn subscription_login_deadline_does_not_leave_a_waiting_connection() {
    let mut harness = Harness::start_with(true);
    subscription_initialize(&mut harness, false).await;
    harness.event().await;
    harness.send(json!({"kind":"authenticate"}));
    harness.event().await;
    harness.agent.expect("authenticate").await;
    tokio::time::pause();
    tokio::time::advance(subscription::LOGIN_TIMEOUT + Duration::from_secs(1)).await;
    let result = tokio::time::timeout(WAIT, &mut harness.connection)
        .await
        .expect("bounded login deadline")
        .unwrap();
    assert!(result.unwrap_err().contains("sign-in timed out"));
}

#[test]
fn model_calls_are_attributed_only_to_a_sole_running_prompt() {
    let turns: RunningTurns = Arc::new(Mutex::new(HashMap::new()));
    let turn = |cancelling| RunningTurn {
        generation: 1,
        cancelling,
        retry: tokio::sync::watch::channel(prompt_retry::State::new(false)).0,
        steering: Arc::new(steering::Turn::default()),
    };
    assert_eq!(sole_running_session(&turns), None);
    turns
        .lock()
        .unwrap()
        .insert("session-1".into(), turn(false));
    // The owner carries the turn generation so late calls can be told apart.
    let owner = model_proxy::CallOwner {
        session: "session-1".into(),
        generation: 1,
    };
    assert_eq!(sole_running_session(&turns), Some(owner.clone()));
    // A cancelling turn can still issue requests, but they are not attributed.
    turns.lock().unwrap().insert("session-2".into(), turn(true));
    assert_eq!(sole_running_session(&turns), Some(owner));
    // Concurrent prompts make a provider request ambiguous.
    turns
        .lock()
        .unwrap()
        .insert("session-3".into(), turn(false));
    assert_eq!(sole_running_session(&turns), None);
}

#[test]
fn model_call_events_use_the_fixture_shape() {
    let expected = fixture()["events"]["modelCall"].clone();
    let call: ModelCall = ModelCall {
        api: ModelApi::AnthropicMessages,
        model: Some("claude-sonnet".into()),
        status: 200,
        streaming: true,
        first_token_ms: Some(820),
        duration_ms: 6400,
        usage: Some(ModelCallUsage {
            input_tokens: 1200,
            cache_read_tokens: 42000,
            cache_write_tokens: 800,
            output_tokens: 640,
            reasoning_tokens: None,
        }),
        context: Some(ContextComposition {
            system_prompt_tokens: 4500,
            tool_tokens: 3500,
            mcp_tool_tokens: 14000,
            message_tokens: 22000,
            tool_count: 18,
            mcp_tool_count: 40,
            scaled_to_usage: true,
        }),
    };
    let event = AgentEvent::ModelCall {
        session_id: Some("session-1".into()),
        after_turn_finished: false,
        call: call.clone(),
    };
    assert_eq!(serde_json::to_value(event).unwrap(), expected);
    let late = AgentEvent::ModelCall {
        session_id: Some("session-1".into()),
        after_turn_finished: true,
        call,
    };
    assert_eq!(
        serde_json::to_value(late).unwrap(),
        fixture()["events"]["modelCallAfterTurn"]
    );
}

/// A fake agent that starts one background task, records its PID, and exits
/// once the test opens `gate` for writing. The agent never answers ACP, so its
/// own exit is what ends the connection.
///
/// Dropping it ends the task and removes the temporary directory and FIFO, so
/// an assertion or timeout panic cannot leave a 300-second task behind.
#[cfg(unix)]
struct AgentWithTask {
    handle: Option<AgentHandle>,
    directory: PathBuf,
    gate: PathBuf,
    task: u32,
    /// Cleared once the test observed the task gone; its PID may then be reused.
    task_may_run: bool,
}

#[cfg(unix)]
impl AgentWithTask {
    fn start(name: &str) -> Self {
        use std::os::unix::fs::PermissionsExt;
        let directory = std::env::temp_dir().join(format!("lithe-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).unwrap();
        let pid_file = directory.join("task.pid");
        let gate = directory.join("gate");
        let gate_path = std::ffi::CString::new(gate.to_str().unwrap()).unwrap();
        // SAFETY: creates a FIFO at a path owned by this test.
        assert_eq!(unsafe { libc::mkfifo(gate_path.as_ptr(), 0o600) }, 0);
        let script = directory.join("agent.sh");
        std::fs::write(
            &script,
            format!(
                "#!/bin/sh\nsleep 300 &\necho $! > '{}'\nread _ < '{}'\n",
                pid_file.display(),
                gate.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        let mut launch = custom_launch(script.to_str().unwrap(), provider());
        launch.process_scope = Some("test-scope".into());
        let handle = AgentHandle::open(launch, Arc::new(|_| {})).expect("worker starts");
        let task = wait_for("the fake agent's task PID", || {
            std::fs::read_to_string(&pid_file)
                .ok()
                .and_then(|text| text.trim().parse::<u32>().ok())
        });
        Self {
            handle: Some(handle),
            directory,
            gate,
            task,
            task_may_run: true,
        }
    }

    fn handle(&self) -> &AgentHandle {
        self.handle.as_ref().expect("the connection is still open")
    }

    /// Lets the agent exit, then closes the connection. The task stays owned
    /// by this value until it is dropped.
    fn finish(&mut self) {
        use std::os::unix::fs::OpenOptionsExt;
        let gate = self.gate.clone();
        wait_for("the fake agent to read its gate", || {
            std::fs::OpenOptions::new()
                .write(true)
                .custom_flags(libc::O_NONBLOCK)
                .open(&gate)
                .ok()
                .and_then(|mut fifo| std::io::Write::write_all(&mut fifo, b"\n").ok())
        });
        if let Some(handle) = self.handle.take() {
            handle.close();
        }
    }
}

#[cfg(unix)]
impl Drop for AgentWithTask {
    fn drop(&mut self) {
        if self.task_may_run && process_is_alive(self.task) {
            kill_test_process(self.task);
        }
        drop(self.handle.take());
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

/// Polls an external process boundary with a local deadline.
#[cfg(unix)]
fn wait_for<T>(what: &str, mut probe: impl FnMut() -> Option<T>) -> T {
    let deadline = std::time::Instant::now() + WAIT;
    loop {
        if let Some(value) = probe() {
            return value;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "timed out waiting for {what}"
        );
        // test-stability: allow(rust-real-sleep) reason: the observed state belongs to a separate OS process that offers no notification channel to the test.
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[cfg(unix)]
fn process_is_alive(pid: u32) -> bool {
    // SAFETY: signal 0 only checks whether the process exists.
    unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
}

#[cfg(unix)]
fn kill_test_process(pid: u32) {
    // SAFETY: ends a background task this test started.
    unsafe {
        libc::kill(pid as libc::pid_t, libc::SIGKILL);
    }
}

// Regression: a task the user chose to keep must survive closing the
// connection, which previously killed the agent's whole process group.
#[cfg(unix)]
#[test]
fn preserved_agent_task_survives_closing_the_connection() {
    let mut agent = AgentWithTask::start("preserve");
    agent
        .handle()
        .send(AgentCommand::PreserveProcesses {
            process_ids: vec![agent.task],
        })
        .expect("preserve is accepted");
    agent.finish();
    assert!(
        process_is_alive(agent.task),
        "preserved task was ended with the agent"
    );
}

#[cfg(unix)]
#[test]
fn closing_without_preserved_tasks_still_ends_the_agent_tree() {
    let mut agent = AgentWithTask::start("tree");
    agent.finish();
    let ended = std::time::Instant::now() + WAIT;
    while process_is_alive(agent.task) && std::time::Instant::now() < ended {
        // test-stability: allow(rust-real-sleep) reason: the killed task is reaped by launchd, which offers no notification channel to the test.
        std::thread::sleep(Duration::from_millis(10));
    }
    let gone = !process_is_alive(agent.task);
    agent.task_may_run = !gone;
    assert!(gone, "agent task outlived the connection");
}
