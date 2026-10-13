//! Opt-in local Responses checks against the installed Codex ACP adapter/CLI.
//! Requires LITHE_ACP_E2E_DATA_DIR and an isolated CODEX_HOME. No real key or
//! external provider is used; the owning handle cleans the entire process tree.

use lithe_agent_host::{
    AgentAuthentication, AgentCommand, AgentEvent, AgentHandle, AgentLaunch, ProviderCredentials,
    ProviderProtocol,
};
use std::{
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    path::PathBuf,
    sync::{mpsc, Arc},
    time::{Duration, Instant},
};

struct Project(PathBuf);
impl Drop for Project {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.0).expect("remove isolated Codex workspace");
    }
}

fn respond(stream: &mut TcpStream, status: u16, long: bool, partial: bool) -> bool {
    let deadline = Instant::now() + Duration::from_secs(2);
    let mut request = Vec::new();
    let (headers, length, offset) = loop {
        assert!(request.len() < 1024 * 1024, "bounded local request");
        let remaining = deadline.saturating_duration_since(Instant::now());
        assert!(!remaining.is_zero(), "HTTP request within local deadline");
        stream.set_read_timeout(Some(remaining)).unwrap();
        let mut bytes = [0; 8192];
        let count = match stream.read(&mut bytes) {
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
            other => other.expect("read local request"),
        };
        assert!(count > 0, "complete request");
        request.extend_from_slice(&bytes[..count]);
        if let Some(end) = request.windows(4).position(|part| part == b"\r\n\r\n") {
            let headers = String::from_utf8(request[..end].to_vec()).unwrap();
            let length = headers
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse::<usize>().unwrap())
                })
                .unwrap_or(0);
            assert!(length < 1024 * 1024, "bounded request body");
            break (headers, length, end + 4);
        }
    };
    while request.len() < offset + length {
        let remaining = deadline.saturating_duration_since(Instant::now());
        assert!(!remaining.is_zero(), "HTTP body within local deadline");
        stream.set_read_timeout(Some(remaining)).unwrap();
        let mut bytes = [0; 8192];
        let count = stream.read(&mut bytes).unwrap();
        assert!(count > 0, "complete request body");
        request.extend_from_slice(&bytes[..count]);
    }
    let responses = headers
        .lines()
        .next()
        .unwrap()
        .split_whitespace()
        .nth(1)
        .unwrap()
        .split('?')
        .next()
        == Some("/v1/responses");
    if responses && status == 0 {
        return true;
    }
    let (status, content_type, body) = if responses && status == 200 {
        let text = if partial {
            "PARTIAL"
        } else {
            "LOCAL_OK 中文🙂"
        };
        let item = serde_json::json!({"id": "msg_local", "type": "message", "role": "assistant", "status": "completed", "content": [{"type": "output_text", "text": text, "annotations": []}]});
        let mut frames = vec![
            serde_json::json!({"type": "response.created", "response": {"id": "resp_local", "status": "in_progress", "output": []}}),
            serde_json::json!({"type": "response.output_item.added", "output_index": 0, "item": {"id": "msg_local", "type": "message", "role": "assistant", "status": "in_progress", "content": []}}),
            serde_json::json!({"type": "response.content_part.added", "item_id": "msg_local", "output_index": 0, "content_index": 0, "part": {"type": "output_text", "text": "", "annotations": []}}),
            serde_json::json!({"type": "response.output_text.delta", "item_id": "msg_local", "output_index": 0, "content_index": 0, "delta": text}),
        ];
        if !partial {
            frames.extend([
                serde_json::json!({"type": "response.output_item.done", "output_index": 0, "item": item}),
                serde_json::json!({"type": "response.completed", "response": {"id": "resp_local", "status": "completed", "output": [item], "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}}}),
            ]);
        }
        (
            200,
            "text/event-stream",
            frames
                .into_iter()
                .map(|frame| format!("data: {frame}\n\n"))
                .collect::<String>(),
        )
    } else if responses {
        assert!(headers
            .lines()
            .any(|line| line.eq_ignore_ascii_case("authorization: Bearer invalid-test-key")));
        (status, "application/json", serde_json::json!({"error": {"type": if status == 429 {"rate_limit_error"} else {"api_error"}, "code": if status == 429 {"rate_limit_exceeded"} else {"fixture_error"}, "message": "Local fixture failure"}}).to_string())
    } else {
        (200, "application/json", "{\"data\":[]}".into())
    };
    stream
        .set_write_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    let advice = if long { "Retry-After: 180\r\n" } else { "" };
    write!(stream, "HTTP/1.1 {status} Fixture\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\n{advice}Connection: close\r\n\r\n{body}", body.len()).unwrap();
    responses
}

fn run(status: u16, long: bool, recover: bool, partial: bool, cancel: bool, mixed: bool) {
    assert!(
        std::env::var_os("CODEX_HOME").is_some(),
        "isolate native Codex state"
    );
    let project =
        Project(std::env::temp_dir().join(format!("lithe-codex-fixture-{}", uuid::Uuid::new_v4())));
    std::fs::create_dir(&project.0).unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let (sender, events) = mpsc::channel();
    let handle = AgentHandle::open(
        AgentLaunch {
            agent_id: Some("codex-acp".into()),
            command: None,
            args: vec![],
            cwd: project.0.clone(),
            data_directory: Some(PathBuf::from(
                std::env::var_os("LITHE_ACP_E2E_DATA_DIR").expect("existing adapter installation"),
            )),
            authentication: AgentAuthentication::ApiKey,
            provider: Some(ProviderCredentials {
                protocol: ProviderProtocol::Responses,
                base_url: format!("http://{}/v1", listener.local_addr().unwrap()),
                api_key: "invalid-test-key".into(),
                name: Some("Local fixture".into()),
                model: Some("gpt-5.5".into()),
                allow_insecure_http: true,
            }),
        },
        Arc::new(move |event| {
            let _ = sender.send(event);
        }),
    )
    .unwrap();
    let start = Instant::now();
    let deadline = start + Duration::from_secs(32);
    let mut requests = 0;
    let mut attempts = Vec::new();
    let mut reply = String::new();
    let mut session = None;
    let success = (status == 200 && !partial) || recover || cancel;
    loop {
        // HTTP acceptance and host events expose separate native wait objects.
        // Poll those boundaries only, under the same monotonic local deadline.
        loop {
            match listener.accept() {
                Ok((mut stream, _)) => {
                    let response = if mixed && requests > 0 {
                        503
                    } else if recover && requests > 0 {
                        200
                    } else if partial && requests > 0 {
                        503
                    } else {
                        status
                    };
                    requests += usize::from(respond(
                        &mut stream,
                        response,
                        long,
                        partial && requests == 0,
                    ));
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(error) => panic!("accept fixture request: {error}"),
            }
        }
        assert!(
            Instant::now() < deadline,
            "Codex failure within 32 seconds, {requests} requests, attempts {attempts:?}"
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
            AgentEvent::SessionCreated { session_id, .. } => {
                session = Some(session_id.clone());
                handle
                    .send(AgentCommand::Prompt {
                        session_id,
                        text: "Only reply OK, without tools.".into(),
                        files: vec![],
                    })
                    .unwrap();
            }
            AgentEvent::TurnRetrying {
                attempt,
                max_attempts,
                ..
            } => {
                assert_eq!(max_attempts, if reply.is_empty() { Some(5) } else { None });
                attempts.push(attempt);
                if cancel {
                    handle
                        .send(AgentCommand::Cancel {
                            session_id: session.clone().unwrap(),
                        })
                        .unwrap();
                }
            }
            AgentEvent::Update { update, .. }
                if update["sessionUpdate"] == "agent_message_chunk" =>
            {
                reply.push_str(update["content"]["text"].as_str().unwrap_or_default())
            }
            AgentEvent::RequestFailed { message, .. } => {
                eprintln!("fixture status {status}, {requests} requests, attempts {attempts:?}, {} ms: {message}", start.elapsed().as_millis());
                assert!(!success, "expected successful/cancelled turn: {message}");
                assert!(
                    !message.contains("litheCodexFailure"),
                    "internal envelope is never shown"
                );
                if long && status >= 500 {
                    assert_eq!(requests, 1);
                    assert_eq!(attempts, [2]);
                    assert!(message.contains("20 seconds"));
                } else if status == 0 || partial || matches!(status, 408 | 409 | 429 | 500..=599) {
                    assert_eq!(requests, 5, "no hidden inner HTTP retries");
                    assert_eq!(attempts, [2, 3, 4, 5]);
                    if partial {
                        assert!(reply.contains("PARTIAL"));
                    }
                } else {
                    assert_eq!(requests, 1);
                    assert!(attempts.is_empty());
                    assert!(
                        start.elapsed() < Duration::from_secs(10),
                        "permanent failure skips reconnect budget"
                    );
                }
                break;
            }
            AgentEvent::TurnFinished { stop_reason, .. } => {
                assert!(success, "provider error must not be reported as success");
                assert_eq!(stop_reason, if cancel { "cancelled" } else { "end_turn" });
                assert_eq!(requests, if recover { 2 } else { 1 });
                if !cancel {
                    assert!(
                        reply.contains("LOCAL_OK 中文🙂"),
                        "UTF-8 streaming reply: {reply}"
                    );
                }
                assert_eq!(attempts, if recover || cancel { vec![2] } else { vec![] });
                break;
            }
            AgentEvent::Stopped { message } => panic!("Codex stopped unexpectedly: {message:?}"),
            _ => {}
        }
    }
    drop(handle);
}

macro_rules! local_case {
    ($name:ident, $status:expr, $long:expr, $recover:expr, $partial:expr, $cancel:expr) => {
        #[test]
        #[ignore = "requires installed Codex ACP/CLI and isolated CODEX_HOME; local HTTP only"]
        fn $name() {
            run($status, $long, $recover, $partial, $cancel, false);
        }
    };
}
local_case!(
    codex_invalid_key_ignores_long_retry_after,
    401,
    true,
    false,
    false,
    false
);
local_case!(
    codex_bad_request_ignores_long_retry_after,
    400,
    true,
    false,
    false,
    false
);
local_case!(
    codex_payment_required_ignores_long_retry_after,
    402,
    true,
    false,
    false,
    false
);
local_case!(
    codex_permission_denied_ignores_long_retry_after,
    403,
    true,
    false,
    false,
    false
);
local_case!(
    codex_missing_model_ignores_long_retry_after,
    404,
    true,
    false,
    false,
    false
);
local_case!(
    codex_rate_limit_has_five_shared_attempts,
    429,
    false,
    false,
    false,
    false
);

#[test]
#[ignore = "requires installed Codex ACP/CLI and isolated CODEX_HOME; local HTTP only"]
fn codex_rate_limit_and_native_service_retries_share_five_requests() {
    run(429, false, false, false, false, true);
}
local_case!(
    codex_service_failure_has_five_native_attempts,
    503,
    false,
    false,
    false,
    false
);
local_case!(
    codex_transport_failure_has_five_native_attempts,
    0,
    false,
    false,
    false,
    false
);
local_case!(
    codex_long_retry_after_is_cancelled_at_twenty_seconds,
    503,
    true,
    false,
    false,
    false
);
local_case!(
    codex_temporary_failure_recovers_within_one_native_turn,
    503,
    false,
    true,
    false,
    false
);
local_case!(
    codex_success_keeps_unicode_streaming,
    200,
    false,
    false,
    false,
    false
);
local_case!(
    codex_partial_stream_uses_native_recovery_without_prompt_replay,
    200,
    false,
    false,
    true,
    false
);
local_case!(
    codex_user_stop_interrupts_native_backoff,
    503,
    true,
    false,
    false,
    true
);
