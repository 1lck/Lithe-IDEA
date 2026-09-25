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
        base_url: "https://gateway.example.com/v1".into(),
        api_key: "test-key-123".into(),
        provider_name: Some("Example".into()),
    })
}

fn custom_launch(command: &str, provider: ProviderCredentials) -> AgentLaunch {
    AgentLaunch {
        agent_id: None,
        command: Some(command.into()),
        args: vec![],
        cwd: std::env::temp_dir(),
        data_directory: None,
        provider,
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
        let initialize = self.expect("initialize").await;
        self.reply(
            &initialize,
            json!({
                "protocolVersion": 1,
                "agentInfo": { "name": "mock-agent", "version": "0.1.0" },
                "agentCapabilities": { "loadSession": true, "sessionCapabilities": { "list": {} } },
                "authMethods": [{ "id": "gateway", "name": "Custom model gateway" }],
            }),
        )
        .await;
        let authenticate = self.expect("authenticate").await;
        self.reply(&authenticate, json!({})).await;
    }
}

struct Harness {
    agent: MockAgent,
    controls: async_mpsc::UnboundedSender<Control>,
    events: async_mpsc::UnboundedReceiver<AgentEvent>,
    permissions: PendingPermissions,
    connection: tokio::task::JoinHandle<Result<(), String>>,
}

impl Harness {
    fn start() -> Self {
        let (client, peer) = tokio::io::duplex(64 * 1024);
        let (client_reader, client_writer) = tokio::io::split(client);
        let (peer_reader, peer_writer) = tokio::io::split(peer);
        let (controls, receiver) = async_mpsc::unbounded_channel();
        let (event_tx, events) = async_mpsc::unbounded_channel();
        let permissions: PendingPermissions = Arc::new(Mutex::new(HashMap::new()));
        let connection = tokio::spawn(run_connection(
            ByteStreams::new(client_writer.compat_write(), client_reader.compat()),
            std::env::temp_dir(),
            gateway(),
            receiver,
            permissions.clone(),
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

    async fn stop(self) -> Result<(), String> {
        self.controls
            .send(Control::Stop)
            .expect("connection running");
        tokio::time::timeout(WAIT, self.connection)
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
            },
        ),
        (
            "sessionCreated",
            AgentEvent::SessionCreated {
                token: "token-1".into(),
                session_id: "session-1".into(),
            },
        ),
        (
            "sessionLoaded",
            AgentEvent::SessionLoaded {
                token: "token-2".into(),
                session_id: "session-1".into(),
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
            "turnFinished",
            AgentEvent::TurnFinished {
                session_id: "session-1".into(),
                stop_reason: "end_turn".into(),
            },
        ),
        (
            "turnCancelled",
            AgentEvent::TurnFinished {
                session_id: "session-1".into(),
                stop_reason: "cancelled".into(),
            },
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
        "sessionInfo",
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
    );
    assert_eq!(
        serde_json::to_value(status).unwrap(),
        fixture["responses"]["status"]
    );
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
    let result = tokio::time::timeout(WAIT, harness.connection)
        .await
        .expect("connection ends before deadline")
        .expect("connection task completes");
    assert!(result.unwrap_err().contains("custom API key"));
    assert!(
        harness.events.try_recv().is_err(),
        "no ready event without sign-in"
    );
}

// Regression: cancelling must not wait for the agent. codex-acp can lose a
// cancel that races turn startup and never answer the prompt; the UI must
// still leave the responding state and accept the next prompt.
#[tokio::test(flavor = "current_thread")]
async fn cancel_ends_the_turn_immediately_and_ignores_the_late_reply() {
    let mut harness = Harness::ready().await;
    harness.open_session("session-1").await;
    harness.send(json!({ "kind": "prompt", "sessionId": "session-1", "text": "first" }));
    let first = harness.agent.expect("session/prompt").await;

    harness.send(json!({ "kind": "cancel", "sessionId": "session-1" }));
    let cancel = harness.agent.expect("session/cancel").await;
    assert_eq!(cancel["params"]["sessionId"], "session-1");
    match harness.event().await {
        AgentEvent::TurnFinished {
            session_id,
            stop_reason,
        } => {
            assert_eq!(
                (session_id.as_str(), stop_reason.as_str()),
                ("session-1", "cancelled")
            );
        }
        other => panic!("expected cancelled turn, got {other:?}"),
    }

    // A second prompt is accepted before the agent answers the first one.
    harness.send(json!({ "kind": "prompt", "sessionId": "session-1", "text": "second" }));
    let second = harness.agent.expect("session/prompt").await;
    harness
        .agent
        .reply(&first, json!({ "stopReason": "end_turn" }))
        .await;
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
        .reply(&prompt_b, json!({ "stopReason": "end_turn" }))
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
            } => (session_id, stop_reason),
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
        AgentEvent::TurnFinished { .. }
    ));
    assert!(
        harness.events.try_recv().is_err(),
        "late request must not reach the UI"
    );
    assert_eq!(harness.stop().await, Ok(()));
}

// Regression: a permission request registered after the handle rejected the
// session's pending requests, but before the loop processed the cancel, must
// still be answered instead of waiting for its five-minute timeout.
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
        AgentEvent::TurnFinished { .. }
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
        AgentEvent::SessionLoaded { token, session_id } => {
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

#[tokio::test(flavor = "current_thread")]
async fn agent_exit_without_a_stop_request_is_reported_as_failure() {
    let harness = Harness::ready().await;
    drop(harness.agent);
    let result = tokio::time::timeout(WAIT, harness.connection)
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
    let data = std::env::temp_dir().join(format!("lithe-resolve-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&data);
    let launch = |agent_id: &str, provider: ProviderCredentials| AgentLaunch {
        agent_id: Some(agent_id.into()),
        command: None,
        args: vec![],
        cwd: std::env::temp_dir(),
        data_directory: Some(data.clone()),
        provider,
    };
    let anthropic = ProviderCredentials {
        protocol: ProviderProtocol::AnthropicMessages,
        base_url: "https://api.example/v1/messages".into(),
        ..provider()
    };
    let codex_cli = |command: &str| {
        (command == "codex").then(|| environment::DetectedTool {
            version: "0.156.1".into(),
            path: "/opt/example/bin/codex".into(),
        })
    };
    let resolve = |launch: AgentLaunch| resolve_with(launch, &codex_cli);
    let not_installed = resolve(launch("codex-acp", provider())).err().unwrap();
    assert!(not_installed.contains("not installed"), "{not_installed}");
    fake_install(&data, "codex-acp");
    fake_install(&data, "claude-acp");

    let codex = resolve(launch("codex-acp", provider())).unwrap();
    assert!(codex.command.ends_with("node_modules/.bin/codex-acp") || cfg!(windows));
    // The adapter drives the user's own Codex; the key never enters the environment.
    assert_eq!(
        codex.env,
        [("CODEX_PATH".to_owned(), "/opt/example/bin/codex".to_owned())]
    );
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
    assert_eq!(
        with_model.env,
        [
            ("CODEX_PATH".to_owned(), "/opt/example/bin/codex".to_owned()),
            (
                "CODEX_CONFIG".to_owned(),
                r#"{"model":"gpt-5.5"}"#.to_owned()
            ),
        ]
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
    assert!(claude.gateway.is_none());
    assert_eq!(
        claude.env,
        [
            ("ANTHROPIC_API_KEY".to_owned(), "test-key-123".to_owned()),
            (
                "ANTHROPIC_BASE_URL".to_owned(),
                "https://api.example".to_owned()
            ),
            ("ANTHROPIC_MODEL".to_owned(), "claude-sonnet-5".to_owned()),
        ]
    );
    let mismatch = resolve(launch("claude-acp", provider())).err().unwrap();
    assert!(mismatch.contains("Anthropic Messages"), "{mismatch}");
    assert!(resolve(launch("unknown", provider())).is_err());
    let _ = std::fs::remove_dir_all(&data);
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
