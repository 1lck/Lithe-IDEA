use super::*;
use crate::model_calls::ModelCall;
use flate2::{Compress, Compression, FlushCompress};
use serde_json::json;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tungstenite::protocol::frame::{Frame, FrameHeader};

type Calls = Arc<Mutex<Vec<ModelCall>>>;

fn observation(extensions: &str) -> (Observation, Calls) {
    let calls: Calls = Arc::default();
    let sink = calls.clone();
    let state = Arc::new(State {
        prefix: "/unit".into(),
        upstream: "http://unit.invalid".into(),
        origin: url::Url::parse("http://unit.invalid").unwrap(),
        base_path: String::new(),
        client: reqwest::Client::builder().no_proxy().build().unwrap(),
        session: Arc::new(|| {
            Some(super::super::CallOwner {
                session: "session".into(),
                generation: 1,
            })
        }),
        sink: Arc::new(move |session, _, call| {
            assert_eq!(session.as_deref(), Some("session"));
            sink.lock().unwrap().push(call);
        }),
        in_flight: Arc::default(),
        connections: std::sync::Weak::new(),
    });
    (Observation::new(state, extensions), calls)
}

fn frame(
    bytes: &[u8],
    from_client: bool,
    compressed: bool,
    final_frame: bool,
    continuation: bool,
) -> Vec<u8> {
    let mut frame = Frame::message(
        Bytes::copy_from_slice(bytes),
        OpCode::Data(if continuation {
            Data::Continue
        } else {
            Data::Text
        }),
        final_frame,
    );
    frame.header_mut().rsv1 = compressed;
    if from_client {
        frame.header_mut().mask = Some([2, 3, 5, 7]);
    }
    let mut encoded = Vec::new();
    frame.format(&mut encoded).unwrap();
    encoded
}

fn compressed(compressor: &mut Compress, bytes: &[u8]) -> Vec<u8> {
    let mut output = Vec::with_capacity(bytes.len() + 128);
    compressor
        .compress_vec(bytes, &mut output, FlushCompress::Sync)
        .unwrap();
    assert!(output.ends_with(&[0, 0, 255, 255]));
    output.truncate(output.len() - 4);
    output
}

fn feed(observation: &mut Observation, from_client: bool, message: Value, now: Instant) {
    let encoded = frame(
        &serde_json::to_vec(&message).unwrap(),
        from_client,
        false,
        true,
        false,
    );
    for chunk in encoded.chunks(3) {
        observation.feed(from_client, chunk, now);
    }
}

fn full_request() -> Value {
    let fixture: Value = serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../shared/fixtures/agent/acp-events-v1.json"
    )))
    .unwrap();
    fixture["upstream"]["codexSubscriptionObservation"]["request"].clone()
}

fn completed(id: &str, tokens: u64, output: Value) -> Value {
    json!({"type":"response.completed", "response":{"id":id,"output":output,
        "usage":{"total_tokens":tokens+10,"input_tokens":tokens,"input_tokens_details":{"cached_tokens":tokens/2},
            "output_tokens":10,"output_tokens_details":{"reasoning_tokens":2}}}})
}

#[test]
fn compressed_fragmented_continuations_keep_full_context_and_skip_warmup() {
    let (mut observation, calls) = observation("permessage-deflate");
    let mut compressor = Compress::new(Compression::fast(), false);
    let start = Instant::now();
    let mut warmup = full_request();
    warmup["generate"] = json!(false);
    let warmup = serde_json::to_vec(&warmup).unwrap();
    let mut fragmented = frame(&warmup[..17], true, false, false, false);
    fragmented.extend(frame(&warmup[17..], true, false, true, true));
    for chunk in fragmented.chunks(1) {
        observation.feed(true, chunk, start);
    }
    let reply = compressed(
        &mut compressor,
        &serde_json::to_vec(&completed("warm", 0, json!([]))).unwrap(),
    );
    observation.feed(false, &frame(&reply, false, true, true, false), start);
    assert!(
        calls.lock().unwrap().is_empty(),
        "Connection prewarm is not a model call"
    );

    let inference = start + Duration::from_millis(10);
    feed(
        &mut observation,
        true,
        json!({"type":"response.create","previous_response_id":"warm","input":[]}),
        inference,
    );
    let delta = compressed(
        &mut compressor,
        &serde_json::to_vec(&json!({
            "type":"response.output_text.delta","response_id":"first","delta":"OK"
        }))
        .unwrap(),
    );
    observation.feed(
        false,
        &frame(&delta, false, true, true, false),
        inference + Duration::from_millis(200),
    );
    let output = json!([{"type":"message","role":"assistant","content":[{"type":"output_text","text":"OK"}]}]);
    let done = compressed(
        &mut compressor,
        &serde_json::to_vec(&completed("first", 1000, output.clone())).unwrap(),
    );
    observation.feed(
        false,
        &frame(&done, false, true, true, false),
        inference + Duration::from_millis(500),
    );

    feed(
        &mut observation,
        true,
        json!({"type":"response.create","previous_response_id":"first",
        "input":[{"type":"function_call_output","call_id":"call","output":"A tool result appended to the context"}]}),
        start + Duration::from_millis(600),
    );
    feed(
        &mut observation,
        false,
        completed("second", 1200, json!([])),
        start + Duration::from_millis(1000),
    );
    let calls = calls.lock().unwrap();
    assert_eq!(calls.len(), 2);
    assert_eq!(calls[0].first_token_ms, Some(200));
    assert_eq!(calls[0].duration_ms, 500);
    for (call, prompt) in calls.iter().zip([1000, 1200]) {
        let context = call.context.as_ref().unwrap();
        assert_eq!(
            context.system_prompt_tokens
                + context.tool_tokens
                + context.mcp_tool_tokens
                + context.message_tokens,
            prompt
        );
        assert!(context.system_prompt_tokens > 0 && context.message_tokens > 0);
        assert_eq!((context.tool_count, context.mcp_tool_count), (1, 1));
        assert!(context.scaled_to_usage);
        assert_eq!(call.model.as_deref(), Some("test-model"));
        assert_eq!(call.usage.unwrap().cache_read_tokens, prompt / 2);
    }
    assert!(
        calls[1].context.as_ref().unwrap().message_tokens
            > calls[0].context.as_ref().unwrap().message_tokens
    );
}

#[test]
fn missing_continuation_keeps_real_usage_without_fabricating_a_breakdown() {
    let (mut observation, calls) = observation("");
    let now = Instant::now();
    feed(
        &mut observation,
        true,
        json!({"type":"response.create","previous_response_id":"not-observed","input":[]}),
        now,
    );
    feed(
        &mut observation,
        false,
        completed("reply", 200, json!([])),
        now,
    );
    feed(
        &mut observation,
        false,
        completed("reply", 200, json!([])),
        now,
    );
    let calls = calls.lock().unwrap();
    assert_eq!(
        calls.len(),
        1,
        "Duplicate terminal events do not duplicate billing counters"
    );
    let usage = calls[0].usage.unwrap();
    assert_eq!(
        usage.input_tokens + usage.cache_read_tokens + usage.cache_write_tokens,
        200
    );
    assert!(calls[0].context.is_none());
}

#[test]
fn observation_budget_and_protocol_errors_do_not_retain_request_content() {
    let (mut observation, calls) = observation("");
    let now = Instant::now();
    feed(&mut observation, true, full_request(), now);
    let mut oversized_header = Vec::new();
    FrameHeader::default()
        .format((OBSERVED_REQUEST_BYTES + 1) as u64, &mut oversized_header)
        .unwrap();
    observation.feed(false, &oversized_header, now);
    assert!(observation.client.is_none() && observation.server.is_none());
    let calls = calls.lock().unwrap();
    assert_eq!(calls.len(), 1);
    assert!(calls[0].context.is_none());
    assert!(calls[0].usage.is_none());
}

#[test]
fn deflate_dictionary_lifetime_matches_each_negotiated_direction() {
    for reset in [false, true] {
        let extensions = if reset {
            "permessage-deflate; client_no_context_takeover; server_no_context_takeover"
        } else {
            "permessage-deflate"
        };
        for from_client in [false, true] {
            let mut decoder = Decoder::new(extensions, from_client);
            let mut compressor = Compress::new(Compression::fast(), false);
            for _ in 0..2 {
                if reset {
                    compressor = Compress::new(Compression::fast(), false);
                }
                let message = br#"{"type":"response.create","instructions":"Repeated shared prompt words repeated shared prompt words"}"#;
                let encoded = compressed(&mut compressor, message);
                let middle = encoded.len() / 2;
                let mut bytes = frame(&encoded[..middle], from_client, true, false, false);
                bytes.extend(frame(&encoded[middle..], from_client, false, true, true));
                decoder.push(&bytes);
                assert_eq!(decoder.next().unwrap().unwrap(), message);
                assert!(decoder.next().unwrap().is_none());
            }
        }
    }
}

/// Abort on every failure path; joining always has its own monotonic deadline.
struct Task(Option<tokio::task::JoinHandle<()>>);
impl Drop for Task {
    fn drop(&mut self) {
        if let Some(task) = &self.0 {
            task.abort();
        }
    }
}
impl Task {
    async fn finish(&mut self) {
        tokio::time::timeout(Duration::from_secs(3), self.0.as_mut().unwrap())
            .await
            .expect("The local WebSocket server did not stop")
            .unwrap();
        self.0 = None;
    }
}

async fn headers(stream: &mut tokio::net::TcpStream) -> String {
    let read = async {
        let mut bytes = Vec::new();
        while !bytes.ends_with(b"\r\n\r\n") {
            assert!(bytes.len() < 16 * 1024, "Bounded mock HTTP header");
            bytes.push(stream.read_u8().await.unwrap());
        }
        String::from_utf8(bytes).unwrap()
    };
    tokio::time::timeout(Duration::from_secs(3), read)
        .await
        .expect("Timed out reading the local handshake")
}

#[tokio::test]
async fn upgrade_preserves_auth_compression_control_frames_and_exact_wire_bytes() {
    tokio::time::timeout(Duration::from_secs(5), async {
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let upstream = format!("http://{}", listener.local_addr().unwrap());
        let calls: Calls = Arc::default();
        let sink = calls.clone();
        let proxy = super::super::start(&upstream,
            Arc::new(|| Some(super::super::CallOwner { session: "wire".into(), generation: 1 })),
            Arc::new(move |_, _, call| sink.lock().unwrap().push(call)), Arc::default()).await.unwrap();
        let request = serde_json::to_vec(&full_request()).unwrap();
        let mut client_bytes = frame(&request[..10], true, false, false, false);
        let mut ping = Frame::ping(Bytes::from_static(b"ping"));
        ping.header_mut().mask = Some([1, 2, 3, 4]);
        ping.format(&mut client_bytes).unwrap();
        client_bytes.extend(frame(&request[10..], true, false, true, true));
        let mut compressor = Compress::new(Compression::fast(), false);
        let encoded = compressed(&mut compressor, &serde_json::to_vec(&completed("response", 1000, json!([]))).unwrap());
        let mut server_bytes = frame(&encoded, false, true, true, false);
        Frame::pong(Bytes::from_static(b"ping")).format(&mut server_bytes).unwrap();
        let expected_request = client_bytes.clone();
        let expected_response = server_bytes.clone();
        let mut server = Task(Some(tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let request = headers(&mut stream).await.to_ascii_lowercase();
            assert!(request.starts_with("get /responses "));
            assert!(request.contains("authorization: bearer fake-subscription-token"));
            assert!(request.contains("sec-websocket-extensions: permessage-deflate"));
            stream.write_all(b"HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\nSec-WebSocket-Extensions: permessage-deflate\r\n\r\n").await.unwrap();
            let mut received = vec![0; expected_request.len()];
            stream.read_exact(&mut received).await.unwrap();
            assert_eq!(received, expected_request, "Masking, fragments and ping frames must remain byte-identical");
            stream.write_all(&server_bytes).await.unwrap();
            stream.shutdown().await.unwrap();
        })));
        let url = url::Url::parse(proxy.base_url()).unwrap();
        let mut client = tokio::net::TcpStream::connect(("127.0.0.1", url.port().unwrap())).await.unwrap();
        client.write_all(format!("GET {}/responses HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Extensions: permessage-deflate\r\nAuthorization: Bearer fake-subscription-token\r\n\r\n", url.path()).as_bytes()).await.unwrap();
        let response = headers(&mut client).await;
        assert!(response.starts_with("HTTP/1.1 101"));
        assert!(response.to_ascii_lowercase().contains("sec-websocket-extensions: permessage-deflate"));
        client.write_all(&client_bytes).await.unwrap();
        let mut received = vec![0; expected_response.len()];
        client.read_exact(&mut received).await.unwrap();
        assert_eq!(received, expected_response, "Compression and control frames must remain byte-identical");
        assert_eq!(calls.lock().unwrap().len(), 1);
        assert_eq!(calls.lock().unwrap()[0].context.as_ref().unwrap().mcp_tool_count, 1);
        client.shutdown().await.unwrap();
        server.finish().await;
        drop(proxy);
    }).await.expect("Bounded local WebSocket forwarding scenario");
}

#[tokio::test]
async fn dropping_proxy_closes_an_idle_upgraded_socket_and_its_upstream() {
    tokio::time::timeout(Duration::from_secs(5), async {
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let upstream = format!("http://{}", listener.local_addr().unwrap());
        let proxy = super::super::start(&upstream, Arc::new(|| None), Arc::new(|_, _, _| {}), Arc::default()).await.unwrap();
        let mut server = Task(Some(tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            headers(&mut stream).await;
            stream.write_all(b"HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n").await.unwrap();
            let mut byte = [0];
            assert_eq!(stream.read(&mut byte).await.unwrap(), 0);
        })));
        let url = url::Url::parse(proxy.base_url()).unwrap();
        let mut client = tokio::net::TcpStream::connect(("127.0.0.1", url.port().unwrap())).await.unwrap();
        client.write_all(format!("GET {}/responses HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n", url.path()).as_bytes()).await.unwrap();
        assert!(headers(&mut client).await.starts_with("HTTP/1.1 101"));
        drop(proxy);
        let mut byte = [0];
        assert_eq!(client.read(&mut byte).await.unwrap(), 0);
        server.finish().await;
    }).await.expect("Dropping the connection owner must close both peers");
}

/// Uses the installed upstream executable but fake credentials and a local
/// provider. No account files, user prompts or real model service are touched.
#[cfg(unix)]
#[tokio::test]
#[ignore = "requires LITHE_CODEX_OBSERVATION_CLI pointing to an installed Codex CLI"]
async fn native_subscription_websocket_reports_two_turns_without_counting_prewarm() {
    use std::process::Stdio;
    use tokio::io::{AsyncBufReadExt, BufReader};
    struct Native {
        child: tokio::process::Child,
        directory: std::path::PathBuf,
    }
    impl Drop for Native {
        fn drop(&mut self) {
            if let Some(pid) = self.child.id() {
                // The process group also owns any native helper descendants.
                unsafe {
                    libc::kill(-(pid as i32), libc::SIGKILL);
                }
            }
            let _ = std::fs::remove_dir_all(&self.directory);
        }
    }
    const FIXTURE_TOKEN: &str = "e30.eyJlbWFpbCI6ICJwZXJzb25AZXhhbXBsZS50ZXN0IiwgImV4cCI6IDQxMDI0NDQ4MDAsICJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOiB7ImNoYXRncHRfYWNjb3VudF9pZCI6ICJmaXh0dXJlLWFjY291bnQiLCAiY2hhdGdwdF9wbGFuX3R5cGUiOiAicGx1cyJ9fQ.fake";
    async fn read(
        input: &mut tokio::process::ChildStdin,
        reader: &mut tokio::io::Lines<BufReader<tokio::process::ChildStdout>>,
    ) -> Value {
        let message: Value = serde_json::from_str(
            &reader
                .next_line()
                .await
                .unwrap()
                .expect("native app-server output"),
        )
        .unwrap();
        if message["method"] == "account/chatgptAuthTokens/refresh" {
            input.write_all(format!("{}\n", json!({"id":message["id"],"result":{"accessToken":FIXTURE_TOKEN,"chatgptAccountId":"fixture-account","chatgptPlanType":"plus"}})).as_bytes()).await.unwrap();
        }
        message
    }
    async fn rpc(
        input: &mut tokio::process::ChildStdin,
        reader: &mut tokio::io::Lines<BufReader<tokio::process::ChildStdout>>,
        id: u64,
        method: &str,
        params: Value,
    ) -> Value {
        input
            .write_all(format!("{}\n", json!({"id":id,"method":method,"params":params})).as_bytes())
            .await
            .unwrap();
        loop {
            let message = read(input, reader).await;
            if message["method"] == "error" {
                eprintln!("Native fixture error: {message}");
            }
            if message["id"] == id {
                assert!(message.get("error").is_none(), "Native {method}: {message}");
                return message["result"].clone();
            }
        }
    }
    tokio::time::timeout(Duration::from_secs(20), async {
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let upstream = format!("http://{}", listener.local_addr().unwrap());
        let calls: Calls = Arc::default();
        let sink = calls.clone();
        let proxy = super::super::start(&upstream,
            Arc::new(|| Some(super::super::CallOwner { session: "native".into(), generation: 1 })),
            Arc::new(move |_, _, call| sink.lock().unwrap().push(call)), Arc::default()).await.unwrap();
        let real_requests = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let measured = real_requests.clone();
        let mut server = Task(Some(tokio::spawn(async move {
            let mut peers = tokio::task::JoinSet::new();
            loop {
                let (mut stream, _) = listener.accept().await.unwrap();
                let measured = measured.clone();
                peers.spawn(async move {
                    let header = headers(&mut stream).await;
                    let key = header.lines().find_map(|line| {
                        let (name, value) = line.split_once(':')?;
                        name.eq_ignore_ascii_case("sec-websocket-key").then(|| value.trim())
                    });
                    let Some(key) = key else {
                        let body = if header.contains("/wham/accounts/check") {
                            r#"{"accounts":[{"id":"fixture-account","workspace_backend_origin":"https://chatgpt.com","account_routing_override":"NO_CONSTRAINT"}]}"#
                        } else { r#"{"models":[]}"# };
                        stream.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).as_bytes()).await.unwrap();
                        return;
                    };
                    assert!(header.starts_with("GET /backend-api/codex/responses"));
                    assert!(header.to_ascii_lowercase().contains("chatgpt-account-id: fixture-account"));
                    let accept = tungstenite::handshake::derive_accept_key(key.as_bytes());
                    // Native Codex may propose compression; a server can decline it.
                    stream.write_all(format!("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: {accept}\r\n\r\n").as_bytes()).await.unwrap();
                    let mut decoder = Decoder::new("", true);
                    let mut sequence = 0;
                    loop {
                        let mut buffer = [0; 8192];
                        let count = stream.read(&mut buffer).await.unwrap();
                        if count == 0 { return; }
                        decoder.push(&buffer[..count]);
                        while let Some(bytes) = decoder.next().unwrap() {
                            let request: Value = serde_json::from_slice(&bytes).unwrap();
                            assert_eq!(request["type"], "response.create");
                            sequence += 1;
                            let id = format!("resp_{sequence}");
                            let warmup = request["generate"] == false;
                            let mut events = vec![json!({"type":"response.created","response":{"id":id,"status":"in_progress","output":[]}})];
                            let output = if warmup { json!([]) } else {
                                measured.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                                let item = json!({"type":"message","id":format!("msg_{sequence}"),"role":"assistant","status":"completed","content":[{"type":"output_text","text":"LOCAL_OK","annotations":[]}]});
                                events.extend([
                                    json!({"type":"response.output_item.added","output_index":0,"item":{"id":format!("msg_{sequence}"),"type":"message","role":"assistant","status":"in_progress","content":[]}}),
                                    json!({"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"LOCAL_OK"}),
                                    json!({"type":"response.output_item.done","output_index":0,"item":item}),
                                ]);
                                json!([item])
                            };
                            let mut done = completed(&id, if warmup { 0 } else { 1000 }, output);
                            done["response"]["status"] = json!("completed");
                            events.push(done);
                            for event in events { stream.write_all(&frame(&serde_json::to_vec(&event).unwrap(), false, false, true, false)).await.unwrap(); }
                        }
                    }
                });
            }
        })));
        let directory = std::env::temp_dir().join(format!("lithe-subscription-observation-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(directory.join("workspace")).unwrap();
        let executable = std::path::PathBuf::from(std::env::var_os("LITHE_CODEX_OBSERVATION_CLI").expect("installed Codex CLI path"));
        let (_relay, relay_env) = crate::codex_retry::Relay::create(&executable, false).unwrap();
        let launcher = &relay_env.iter().find(|(name, _)| name == "CODEX_PATH").unwrap().1;
        std::fs::write(directory.join("config.toml"), format!(
            "model_provider = \"openai\"\nchatgpt_base_url = \"{upstream}/backend-api/\"\n[features]\napps = false\nplugins = false\nskip_host_skill_discovery = true\n[analytics]\nenabled = false\n"
        )).unwrap();
        let mut command = std::process::Command::new(launcher);
        crate::subscription::isolate_environment(&mut command);
        use std::os::unix::process::CommandExt;
        command.arg("app-server").envs(relay_env.clone())
            .env("LITHE_CODEX_OBSERVATION_BASE", format!("{}/backend-api/codex",proxy.base_url()))
            .env("CODEX_HOME", &directory).env("NO_PROXY", "127.0.0.1,localhost")
            .env("HTTP_PROXY", &upstream).env("HTTPS_PROXY", &upstream).env("ALL_PROXY", &upstream)
            .current_dir(directory.join("workspace")).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).process_group(0);
        let mut command = tokio::process::Command::from(command);
        command.kill_on_drop(true);
        let mut native = Native { child: command.spawn().unwrap(), directory };
        let mut input = native.child.stdin.take().unwrap();
        let mut reader = BufReader::new(native.child.stdout.take().unwrap()).lines();
        rpc(&mut input, &mut reader, 1, "initialize", json!({"clientInfo":{"name":"lithe-subscription-fixture","version":"1"},"capabilities":{"experimentalApi":true}})).await;
        input.write_all(b"{\"method\":\"initialized\"}\n").await.unwrap();
        // Unsigned fake JWT with an example.test email; accepted only by this
        // isolated native external-token mode and our loopback fixture.
        input.write_all(format!("{}\n", json!({"id":2,"method":"account/login/start","params":{
            "type":"chatgptAuthTokens", "accessToken":FIXTURE_TOKEN, "chatgptAccountId":"fixture-account","chatgptPlanType":"plus"
        }})).as_bytes()).await.unwrap();
        // Native login responds before its completion/account notifications.
        // Query routing only after all three have arrived: discovery started
        // before an account change must now be revoked by the relay.
        let (mut replied, mut completed, mut updated) = (false, false, false);
        while !(replied && completed && updated) {
            let message = read(&mut input, &mut reader).await;
            if message["id"] == 2 {
                assert!(message.get("error").is_none(), "Native login: {message}");
                replied = true;
            }
            if message["method"] == "account/login/completed" {
                assert_eq!(message["params"]["success"], true);
                completed = true;
            }
            if message["method"] == "account/updated" { updated = true; }
        }
        let account = rpc(&mut input, &mut reader, 10, "account/read", json!({"refreshToken":false})).await;
        assert_eq!(account["workspaceRouting"]["accountRoutingOverride"], "NO_CONSTRAINT");
        let thread = rpc(&mut input, &mut reader, 3, "thread/start", json!({"model":"gpt-5.4","cwd":native.directory.join("workspace"),"approvalPolicy":"never","sandbox":"read-only","ephemeral":true,
            "config":{"openai_base_url":format!("{}/backend-api/codex",proxy.base_url())}})).await;
        let id = thread["thread"]["id"].as_str().unwrap();
        for turn in 0..2 {
            rpc(&mut input, &mut reader, 4+turn, "turn/start", json!({"threadId":id,"input":[{"type":"text","text":"Reply LOCAL_OK","text_elements":[]}]})).await;
            loop {
                let notification = read(&mut input, &mut reader).await;
                if notification["method"] == "error" { eprintln!("Native fixture error: {notification}"); }
                if notification["method"] == "turn/completed" {
                    assert_eq!(notification["params"]["turn"]["status"], "completed", "{notification}");
                    break;
                }
            }
        }
        assert_eq!(real_requests.load(std::sync::atomic::Ordering::SeqCst), 2);
        {
            let calls = calls.lock().unwrap();
            assert_eq!(calls.len(), 2, "Native connection prewarm must not count as a model call");
            for call in calls.iter() {
                assert_eq!(call.usage.unwrap().input_tokens + call.usage.unwrap().cache_read_tokens, 1000);
                let context = call.context.as_ref().expect("Full native request composition");
                assert!(context.system_prompt_tokens > 0 && context.tool_count > 0 && context.message_tokens > 0);
                assert!(call.first_token_ms.is_some());
            }
        }
        crate::terminate_tree(&mut native.child).await;
        drop(proxy);
        let server_task = server.0.take().unwrap();
        server_task.abort();
        assert!(server_task.await.unwrap_err().is_cancelled());
    }).await.expect("Native subscription integration exceeded its local deadline");
}
