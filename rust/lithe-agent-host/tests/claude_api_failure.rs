//! Opt-in local HTTP checks against the installed Claude ACP adapter and CLI.
//!
//! No provider credentials or external API are used. Set `LITHE_ACP_E2E_DATA_DIR`
//! to the existing adapter installation and `CLAUDE_CONFIG_DIR` to an isolated
//! temporary directory, then run this target with `--ignored`.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::{mpsc, Arc};
use std::time::{Duration, Instant};

use lithe_agent_host::{
    AgentAuthentication, AgentCommand, AgentEvent, AgentHandle, AgentLaunch, ProviderCredentials,
    ProviderProtocol,
};

const DEADLINE: Duration = Duration::from_secs(30);
const MAX_REQUEST_BYTES: usize = 1024 * 1024;
const RECOVER_AFTER_FAILURE: u16 = 202;
const MODEL_RESTORE_PROMPT: &str = "LITHE_MODEL_RESTORE: Only reply OK. No tools.";

struct Project(PathBuf);

impl Drop for Project {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.0).expect("remove isolated test project");
    }
}

/// Consume the entire request before closing the connection, avoiding a TCP
/// reset from unread request bytes. Every read shares the same local deadline.
fn respond(stream: &mut TcpStream, status: u16, models: Option<&mut Vec<String>>) -> bool {
    let deadline = Instant::now() + Duration::from_secs(2);
    let mut request = Vec::new();
    let (headers, content_length, header_length) = loop {
        assert!(request.len() < MAX_REQUEST_BYTES, "bounded HTTP request");
        let remaining = deadline.saturating_duration_since(Instant::now());
        assert!(!remaining.is_zero(), "HTTP request before local deadline");
        stream.set_read_timeout(Some(remaining)).unwrap();
        let mut buffer = [0; 8192];
        let count = match stream.read(&mut buffer) {
            Ok(0) if request.is_empty() => return false,
            Err(error)
                if request.is_empty()
                    && matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
            {
                return false
            }
            result => result.expect("read local HTTP request"),
        };
        assert!(count > 0, "complete HTTP request headers");
        request.extend_from_slice(&buffer[..count]);
        if let Some(end) = request.windows(4).position(|bytes| bytes == b"\r\n\r\n") {
            let headers = String::from_utf8(request[..end].to_vec()).unwrap();
            let length = headers
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse::<usize>().unwrap())
                })
                .unwrap_or(0);
            assert!(length < MAX_REQUEST_BYTES, "bounded HTTP body");
            break (headers, length, end + 4);
        }
    };
    while request.len() < header_length + content_length {
        let remaining = deadline.saturating_duration_since(Instant::now());
        assert!(!remaining.is_zero(), "HTTP body before local deadline");
        stream.set_read_timeout(Some(remaining)).unwrap();
        let mut buffer = [0; 8192];
        let count = stream.read(&mut buffer).expect("read local HTTP body");
        assert!(count > 0, "complete HTTP request body");
        request.extend_from_slice(&buffer[..count]);
    }
    let path = headers
        .lines()
        .next()
        .unwrap()
        .split_whitespace()
        .nth(1)
        .unwrap();
    let is_message = path.split('?').next() == Some("/v1/messages");
    let model = if is_message && models.is_some() {
        let body: serde_json::Value =
            serde_json::from_slice(&request[header_length..header_length + content_length])
                .expect("native Messages request JSON");
        let model = body["model"]
            .as_str()
            .expect("native request model")
            .to_owned();
        // Native setModel validation and automatic title generation may also
        // call Messages. Record only the explicitly submitted workflow prompt.
        let is_prompt = body["messages"].as_array().is_some_and(|messages| {
            messages.iter().any(|message| {
                message["role"] == "user"
                    && (message["content"] == MODEL_RESTORE_PROMPT
                        || message["content"].as_array().is_some_and(|blocks| {
                            blocks
                                .iter()
                                .any(|block| block["text"] == MODEL_RESTORE_PROMPT)
                        }))
            })
        });
        if is_prompt {
            models.unwrap().push(model.clone());
        }
        model
    } else {
        "claude-sonnet-4-6".to_owned()
    };
    if is_message && status == 0 {
        // Closing after consuming the request is a deterministic transport
        // failure: no response arrives, rather than a response-header timeout.
        return true;
    }
    let (status, content_type, body) = if is_message && matches!(status, 200 | 201) {
        let text = if status == 200 { "PARTIAL" } else { "LOCAL_OK" };
        let mut frames = vec![
            (
                "message_start",
                serde_json::json!({"type": "message_start", "message": {
                    "id": "msg_local", "type": "message", "role": "assistant", "model": model, "content": [],
                    "stop_reason": null, "stop_sequence": null, "usage": {"input_tokens": 1, "output_tokens": 0}
                }}),
            ),
            (
                "content_block_start",
                serde_json::json!({"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}),
            ),
            (
                "content_block_delta",
                serde_json::json!({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text}}),
            ),
        ];
        if status == 200 {
            frames.push(("error", serde_json::json!({"type": "error", "error": {"type": "api_error", "message": "stream interrupted"}})));
        } else {
            frames.extend([
                ("content_block_stop", serde_json::json!({"type": "content_block_stop", "index": 0})),
                ("message_delta", serde_json::json!({"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": null}, "usage": {"output_tokens": 1}})),
                ("message_stop", serde_json::json!({"type": "message_stop"})),
            ]);
        }
        (
            200,
            "text/event-stream",
            frames
                .into_iter()
                .map(|(event, data)| format!("event: {event}\ndata: {data}\n\n"))
                .collect::<String>(),
        )
    } else if is_message {
        assert!(headers
            .lines()
            .any(|line| line.to_ascii_lowercase() == "x-api-key: invalid-test-key"));
        let error_type = match status {
            400 => "invalid_request_error",
            401 => "authentication_error",
            402 => "billing_error",
            403 => "permission_error",
            404 => "not_found_error",
            429 => "rate_limit_error",
            504 => "timeout_error",
            529 => "overloaded_error",
            _ => "api_error",
        };
        let message = if status == 401 {
            "Invalid API key"
        } else {
            "No available channel for model test-model"
        };
        (
            status,
            "application/json",
            serde_json::json!({"type": "error", "error": {"type": error_type, "message": message}})
                .to_string(),
        )
    } else {
        (200, "application/json", "{\"input_tokens\":1}".into())
    };
    stream
        .set_write_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    // Even a provider explicitly requesting a three-minute retry must not
    // extend Lithe's bounded recovery after native API retries are disabled.
    write!(stream, "HTTP/1.1 {status} Test\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nRetry-After: 180\r\nx-should-retry: true\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
    is_message
}

fn run_local_api_turn(status: u16) {
    run_local_api_turn_with(status, false);
}

fn run_local_api_turn_with(status: u16, observe_model_calls: bool) {
    assert!(
        std::env::var_os("CLAUDE_CONFIG_DIR").is_some(),
        "isolate native CLI state before running this opt-in test"
    );
    let data_directory = PathBuf::from(
        std::env::var_os("LITHE_ACP_E2E_DATA_DIR").expect("existing adapter data directory"),
    );
    let project = Project(
        std::env::temp_dir().join(format!("lithe-claude-failure-{}", uuid::Uuid::new_v4())),
    );
    std::fs::create_dir_all(project.0.join(".claude")).unwrap();
    // The session's public options must override conflicting project settings.
    std::fs::write(
        project.0.join(".claude/settings.json"),
        r#"{"env":{"CLAUDE_CODE_MAX_RETRIES":"10","CLAUDE_CODE_RETRY_WATCHDOG":"1","CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK":"0"}}"#,
    )
    .unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let (sender, events) = mpsc::channel();
    let handle = AgentHandle::open(
        AgentLaunch {
            agent_id: Some("claude-acp".into()),
            command: None,
            args: vec![],
            cwd: project.0.clone(),
            data_directory: Some(data_directory),
            authentication: AgentAuthentication::ApiKey,
            observe_model_calls,
            observe_subagents: false,
            process_scope: None,
            provider: Some(ProviderCredentials {
                protocol: ProviderProtocol::AnthropicMessages,
                base_url: format!("http://{}", listener.local_addr().unwrap()),
                api_key: "invalid-test-key".into(),
                name: Some("Local failure fixture".into()),
                model: Some("claude-sonnet-4-6".into()),
                allow_insecure_http: true,
            }),
        },
        Arc::new(move |event| {
            let _ = sender.send(event);
        }),
    )
    .unwrap();
    let mut session_id = None;
    let mut requests = 0;
    let mut reply = String::new();
    let mut attempts = Vec::new();
    let mut model_calls = Vec::new();
    let deadline = Instant::now() + DEADLINE;
    loop {
        // Native TCP acceptance and the host's event channel have no shared
        // wait primitive. Poll only these observable boundaries, bounded by
        // one deadline; no sleep or private CLI state controls the test.
        loop {
            match listener.accept() {
                Ok((mut stream, _)) => {
                    let response_status = if status == RECOVER_AFTER_FAILURE {
                        if requests == 0 {
                            503
                        } else {
                            201
                        }
                    } else {
                        status
                    };
                    requests += usize::from(respond(&mut stream, response_status, None));
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(error) => panic!("accept local HTTP request: {error}"),
            }
        }
        assert!(
            Instant::now() < deadline,
            "Claude must report {status} without minutes of backoff"
        );
        let event = match events.recv_timeout(Duration::from_millis(10)) {
            Ok(event) => event,
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(error) => panic!("host event channel closed: {error}"),
        };
        match event {
            AgentEvent::Ready { .. } => handle
                .send(AgentCommand::NewSession {
                    token: "new".into(),
                })
                .unwrap(),
            AgentEvent::SessionCreated { session_id: id, .. } => {
                session_id = Some(id.clone());
                handle
                    .send(AgentCommand::Prompt {
                        session_id: id,
                        text: "Only reply OK, without tools.".into(),
                        files: vec![],
                    })
                    .unwrap();
            }
            AgentEvent::RequestFailed {
                session_id: id,
                message,
                ..
            } => {
                eprintln!("local status {status}, requests {requests}, failure {message}");
                assert!(
                    !matches!(status, 201 | RECOVER_AFTER_FAILURE),
                    "successful streaming turn: {message}"
                );
                assert_eq!(id, session_id);
                match status {
                    0 => assert!(
                        message.to_ascii_lowercase().contains("connection")
                            || message.contains("server_error"),
                        "expected transport failure: {message}"
                    ),
                    200 => assert!(
                        message.contains("stream interrupted"),
                        "expected streaming failure: {message}"
                    ),
                    // The adapter translates 404 into an actionable typed model
                    // error; the HTTP number is intentionally absent from it.
                    404 => assert!(
                        message.contains("selected model"),
                        "expected model failure: {message}"
                    ),
                    _ => assert!(
                        message.contains(&status.to_string()),
                        "expected {status}: {message}"
                    ),
                }
                let expected = match status {
                    0 | 408 | 429 | 500 | 502 | 503 | 504 | 529 => 5,
                    // The native model resolver probes twice even with API
                    // retries and non-streaming fallback both disabled.
                    404 => 2,
                    _ => 1,
                };
                if expected == 5 {
                    // An adapter attempt can fail before making a fresh HTTP
                    // request. Assert the wire budget and all five Host attempts
                    // independently, so hidden native duplicate calls still fail.
                    assert!(
                        (1..=5).contains(&requests),
                        "at most five HTTP requests, got {requests}"
                    );
                    assert_eq!(attempts, vec![2, 3, 4, 5]);
                } else {
                    assert_eq!(requests, expected, "permanent failure has no Host replay");
                    assert!(attempts.is_empty(), "permanent errors do not reconnect");
                }
                break;
            }
            AgentEvent::TurnRetrying {
                attempt,
                max_attempts,
                ..
            } => {
                eprintln!("local status {status}, retry attempt {attempt}/{max_attempts:?}");
                assert_eq!(max_attempts, Some(5));
                attempts.push(attempt);
            }
            AgentEvent::Update { update, .. }
                if update["sessionUpdate"] == "session_info_update"
                    && update["_meta"]["jetbrains"]["air"]["sessionFailure"].is_object() =>
            {
                eprintln!(
                    "local status {status}, public failure {}",
                    update["_meta"]["jetbrains"]["air"]["sessionFailure"]
                );
            }
            AgentEvent::Update { update, .. }
                if update["sessionUpdate"] == "agent_message_chunk" =>
            {
                reply.push_str(update["content"]["text"].as_str().unwrap_or_default());
            }
            AgentEvent::TurnFinished {
                session_id: id,
                stop_reason,
                ..
            } => {
                assert!(
                    matches!(status, 201 | RECOVER_AFTER_FAILURE),
                    "API failure must not look like success"
                );
                assert_eq!(id, session_id.clone().unwrap());
                assert_eq!(stop_reason, "end_turn");
                assert_eq!(reply, "LOCAL_OK");
                assert_eq!(
                    requests,
                    if status == RECOVER_AFTER_FAILURE {
                        2
                    } else {
                        1
                    }
                );
                assert_eq!(
                    attempts,
                    if status == RECOVER_AFTER_FAILURE {
                        vec![2]
                    } else {
                        vec![]
                    }
                );
                break;
            }
            AgentEvent::ModelCall {
                session_id: id,
                after_turn_finished,
                call,
            } => {
                assert!(!after_turn_finished, "the turn waits for its own calls");
                model_calls.push((id, call));
            }
            AgentEvent::Stopped { message } => {
                panic!("agent stopped before API failure: {message:?}")
            }
            _ => {}
        }
    }
    if observe_model_calls {
        // The host settles a turn's observed calls before `turnFinished`, so
        // they are already present here without draining later events.
        let (id, call) = model_calls
            .iter()
            .find(|(_, call)| call.usage.is_some())
            .expect("the proxied message request is observed");
        assert_eq!(id, &session_id);
        assert!(call.streaming, "Claude streams through the proxy");
        assert!(call.first_token_ms.is_some());
        assert_eq!(call.usage.map(|usage| usage.output_tokens), Some(1));
        assert!(call.context.is_some_and(|context| context.tool_count > 0));
    } else {
        assert!(model_calls.is_empty(), "no observation without the opt-in");
    }
    // AgentHandle owns bounded termination of the entire subprocess tree;
    // dropping it also guarantees cleanup on every assertion-failure path.
    drop(handle);
}

/// Exercise the real installed ACP and CLI, but answer Messages requests locally.
/// Both phases share one isolated transcript store; each owns its process tree.
fn local_model_phase(
    listener: &TcpListener,
    project: &Project,
    data_directory: &std::path::Path,
    restore: Option<&str>,
) -> (String, Vec<String>) {
    let (sender, events) = mpsc::channel();
    let handle = AgentHandle::open(
        AgentLaunch {
            agent_id: Some("claude-acp".into()),
            command: None,
            args: vec![],
            cwd: project.0.clone(),
            data_directory: Some(data_directory.to_path_buf()),
            authentication: AgentAuthentication::ApiKey,
            observe_model_calls: false,
            observe_subagents: false,
            process_scope: None,
            provider: Some(ProviderCredentials {
                protocol: ProviderProtocol::AnthropicMessages,
                base_url: format!("http://{}", listener.local_addr().unwrap()),
                api_key: "invalid-test-key".into(),
                name: Some("Local model fixture".into()),
                model: Some("sonnet".into()),
                allow_insecure_http: true,
            }),
        },
        Arc::new(move |event| {
            let _ = sender.send(event);
        }),
    )
    .unwrap();
    let deadline = Instant::now() + DEADLINE;
    let mut session_id = restore.map(str::to_owned);
    let mut models = Vec::new();
    let mut reply = String::new();
    loop {
        loop {
            match listener.accept() {
                Ok((mut stream, _)) => {
                    respond(&mut stream, 201, Some(&mut models));
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(error) => panic!("accept local model request: {error}"),
            }
        }
        assert!(
            Instant::now() < deadline,
            "model phase before local deadline"
        );
        let event = match events.recv_timeout(Duration::from_millis(10)) {
            Ok(event) => event,
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(error) => panic!("model event channel closed: {error}"),
        };
        match event {
            AgentEvent::Ready { .. } => handle
                .send(match restore {
                    Some(id) => AgentCommand::LoadSession {
                        token: "load".into(),
                        session_id: id.into(),
                    },
                    None => AgentCommand::NewSession {
                        token: "new".into(),
                    },
                })
                .unwrap(),
            AgentEvent::SessionCreated { session_id: id, .. } => {
                session_id = Some(id.clone());
                // Public native alias: the adapter owns its canonical model ID.
                handle
                    .send(AgentCommand::SetConfigOption {
                        token: "model".into(),
                        session_id: id,
                        config_id: "model".into(),
                        value: "opus".into(),
                    })
                    .unwrap();
            }
            AgentEvent::SessionConfigured { session_id: id, .. }
            | AgentEvent::SessionLoaded { session_id: id, .. } => {
                assert_eq!(Some(&id), session_id.as_ref());
                reply.clear(); // Replayed history is not this phase's new reply.
                handle
                    .send(AgentCommand::Prompt {
                        session_id: id,
                        text: MODEL_RESTORE_PROMPT.into(),
                        files: vec![],
                    })
                    .unwrap();
            }
            AgentEvent::Update { update, .. }
                if update["sessionUpdate"] == "agent_message_chunk" =>
            {
                reply.push_str(update["content"]["text"].as_str().unwrap_or_default());
            }
            AgentEvent::TurnFinished { stop_reason, .. } => {
                assert_eq!(stop_reason, "end_turn");
                assert_eq!(reply, "LOCAL_OK");
                assert_eq!(models.len(), 1, "one native prompt request per phase");
                break;
            }
            AgentEvent::RequestFailed { message, .. } => panic!("model workflow failed: {message}"),
            AgentEvent::Stopped { message } => panic!("model workflow stopped: {message:?}"),
            _ => {}
        }
    }
    // Drop/close owns bounded process-tree termination on success and panic.
    handle.close();
    (session_id.unwrap(), models)
}

#[test]
#[ignore = "requires an installed Claude ACP/CLI and an isolated CLAUDE_CONFIG_DIR; uses only local HTTP"]
fn claude_restore_uses_the_last_selected_model_in_the_actual_request() {
    assert!(
        std::env::var_os("CLAUDE_CONFIG_DIR").is_some(),
        "isolate native CLI state"
    );
    let data_directory = PathBuf::from(
        std::env::var_os("LITHE_ACP_E2E_DATA_DIR").expect("installed adapter directory"),
    );
    let project =
        Project(std::env::temp_dir().join(format!("lithe-claude-model-{}", uuid::Uuid::new_v4())));
    std::fs::create_dir_all(&project.0).unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let (id, original) = local_model_phase(&listener, &project, &data_directory, None);
    let (_, restored) = local_model_phase(&listener, &project, &data_directory, Some(&id));
    eprintln!("selected request models: {original:?}; restored request models: {restored:?}");
    assert!(
        original[0].contains("opus"),
        "explicitly selected native Opus model"
    );
    assert_eq!(
        restored, original,
        "restarted ACP must preserve the selected model on the wire"
    );
}

#[test]
#[ignore = "requires an installed Claude ACP/CLI and an isolated CLAUDE_CONFIG_DIR; uses only local HTTP"]
fn claude_turn_through_the_model_call_proxy_is_observed() {
    run_local_api_turn_with(201, true);
}

#[test]
#[ignore = "requires an installed Claude ACP/CLI and an isolated CLAUDE_CONFIG_DIR; uses only local HTTP"]
fn claude_invalid_key_fails_after_one_request() {
    run_local_api_turn(401);
}

#[test]
#[ignore = "requires an installed Claude ACP/CLI and an isolated CLAUDE_CONFIG_DIR; uses only local HTTP"]
fn claude_unavailable_channel_uses_five_short_attempts() {
    run_local_api_turn(503);
}

macro_rules! api_failure_test {
    ($name:ident, $status:expr) => {
        #[test]
        #[ignore = "requires an installed Claude ACP/CLI and an isolated CLAUDE_CONFIG_DIR; uses only local HTTP"]
        fn $name() {
            run_local_api_turn($status);
        }
    };
}

api_failure_test!(claude_invalid_request_fails_after_one_request, 400);
api_failure_test!(claude_billing_error_fails_after_one_request, 402);
api_failure_test!(claude_permission_error_fails_after_one_request, 403);
api_failure_test!(claude_missing_model_fails_without_reconnecting, 404);
api_failure_test!(claude_request_timeout_uses_five_short_attempts, 408);
api_failure_test!(claude_rate_limit_uses_five_short_attempts, 429);
api_failure_test!(claude_server_error_uses_five_short_attempts, 500);
api_failure_test!(claude_bad_gateway_uses_five_short_attempts, 502);
api_failure_test!(claude_gateway_timeout_uses_five_short_attempts, 504);
api_failure_test!(claude_overload_uses_five_short_attempts, 529);
api_failure_test!(claude_closed_connection_uses_five_short_attempts, 0);

api_failure_test!(claude_stream_error_does_not_resend_without_streaming, 200);
api_failure_test!(claude_successful_stream_still_completes, 201);

api_failure_test!(
    claude_recovers_after_one_failed_attempt,
    RECOVER_AFTER_FAILURE
);
