//! Local transport fixtures never call a public server or an installed runtime.
use super::*;
use std::io::{BufRead, Write};

fn fixture_request() -> Request {
    Request {
        transport: "stdio".into(),
        command: Some(
            std::env::current_exe()
                .unwrap()
                .to_string_lossy()
                .into_owned(),
        ),
        args: vec![
            "--exact".into(),
            "mcp_probe::tests::fixture_server".into(),
            "--nocapture".into(),
        ],
        env: vec![
            Entry {
                key: "LITHE_MCP_PROBE_FIXTURE".into(),
                value: "1".into(),
            },
            Entry {
                key: "PATH".into(),
                value: std::env::var("PATH").unwrap_or_default(),
            },
        ],
        url: None,
        headers: vec![],
    }
}

fn response(message: &Value) -> Option<Value> {
    let id = message.get("id")?;
    let result = match message["method"].as_str()? {
        "server/discover" => {
            return Some(
                json!({"jsonrpc":"2.0","id":id,"error":{"code":-32601,"message":"Use initialize"}}),
            )
        }
        "initialize" => {
            json!({"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"fixture","version":"1"}})
        }
        "tools/list" if message["params"]["cursor"] == "next" => {
            json!({"tools":[{"name":"second","description":"Fixture page two","inputSchema":{"type":"object"}}]})
        }
        "tools/list" => {
            json!({"tools":[{"name":"first","description":std::process::id().to_string(),"inputSchema":{"type":"object"}}],"nextCursor":"next"})
        }
        _ => panic!("Probe attempted a method outside metadata listing"),
    };
    Some(json!({"jsonrpc":"2.0","id":id,"result":result}))
}

#[test]
fn fixture_server() {
    if std::env::var("LITHE_MCP_PROBE_FIXTURE").as_deref() != Ok("1") {
        return;
    }
    // Child-only blocking stdin is owned by the parent probe's 30-second
    // deadline and mandatory process-tree kill, never the test executor.
    for line in std::io::stdin().lock().lines() {
        let Ok(line) = line else {
            break;
        };
        let Ok(value) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if value["method"] == "tools/list" {
            if let Ok(address) = std::env::var("LITHE_MCP_FIXTURE_SIGNAL") {
                let mut signal = std::net::TcpStream::connect(address).unwrap();
                write!(signal, "{}", std::process::id()).unwrap();
                continue;
            }
        }
        if let Some(value) = response(&value) {
            println!("{value}");
            std::io::stdout().flush().unwrap();
        }
    }
}

#[test]
fn real_stdio_probe_lists_pages_and_reaps_its_child() {
    let value = execute(fixture_request(), &|| false).unwrap();
    assert_eq!(value["tools"][0]["name"], "first");
    assert_eq!(value["tools"][1]["name"], "second");
    #[cfg(unix)]
    {
        let pid: i32 = value["tools"][0]["description"]
            .as_str()
            .unwrap()
            .parse()
            .unwrap();
        // SAFETY: signal zero only checks whether the already-reaped child exists.
        assert_eq!(unsafe { libc::kill(pid, 0) }, -1);
    }
}

#[test]
fn cancellation_and_invalid_remote_inputs_do_not_launch_anything() {
    assert_eq!(
        execute(fixture_request(), &|| true).unwrap_err(),
        Error::Cancelled
    );
    for url in [
        "http://example.invalid/mcp",
        "https://user:token@example.invalid/mcp",
        "file:///tmp/mcp",
    ] {
        let mut r = fixture_request();
        r.transport = "http".into();
        r.url = Some(url.into());
        assert_eq!(execute(r, &|| false).unwrap_err(), Error::Invalid);
    }
}

#[tokio::test(start_paused = true)]
async fn silent_server_hits_virtual_deadline_and_cancellation_is_observed() {
    let (client, _server) = tokio::io::duplex(4096);
    let start = tokio::time::Instant::now();
    let result = inventory(client, &|| false).await;
    assert_eq!(result.unwrap_err(), Error::Timeout);
    assert!(start.elapsed() <= DEADLINE + Duration::from_secs(2));
    let (client, _server) = tokio::io::duplex(4096);
    assert_eq!(
        inventory(client, &|| true).await.unwrap_err(),
        Error::Cancelled
    );
}

#[tokio::test]
async fn cancellation_after_stdio_handshake_reaps_the_live_child() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mut request = fixture_request();
    request.env.push(Entry {
        key: "LITHE_MCP_FIXTURE_SIGNAL".into(),
        value: listener.local_addr().unwrap().to_string(),
    });
    let cancelled = std::cell::Cell::new(false);
    let cancel = || cancelled.get();
    let signal = async {
        let (mut stream, _) = listener.accept().await.unwrap();
        let mut pid = String::new();
        stream.read_to_string(&mut pid).await.unwrap();
        cancelled.set(true);
        pid
    };
    let (result, pid) = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(run(request, &cancel), signal)
    })
    .await
    .unwrap();
    assert_eq!(result.unwrap_err(), Error::Cancelled);
    #[cfg(unix)]
    {
        let pid: i32 = pid.parse().unwrap();
        // SAFETY: signal zero only checks for the reaped fixture process.
        assert_eq!(unsafe { libc::kill(pid, 0) }, -1);
    }
    #[cfg(not(unix))]
    let _ = pid;
}

#[tokio::test]
async fn real_loopback_http_probe_uses_the_same_inventory_protocol() {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    for mode in ["json", "sse", "oversized-header", "oversized-body"] {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            loop {
                let (stream, _) = listener.accept().await.unwrap();
                let mut reader = BufReader::new(stream);
                let mut first = String::new();
                reader.read_line(&mut first).await.unwrap();
                let mut length = 0;
                loop {
                    let mut line = String::new();
                    reader.read_line(&mut line).await.unwrap();
                    if line == "\r\n" {
                        break;
                    }
                    if let Some(value) = line.to_lowercase().strip_prefix("content-length:") {
                        length = value.trim().parse::<usize>().unwrap();
                    }
                }
                assert!(length < 16384);
                let mut bytes = vec![0; length];
                reader.read_exact(&mut bytes).await.unwrap();
                let body = if first.starts_with("POST") {
                    response(&serde_json::from_slice(&bytes).unwrap())
                } else {
                    None
                };
                let mut text = body.map(|v| v.to_string()).unwrap_or_default();
                let content_type = if mode == "sse" {
                    "text/event-stream"
                } else {
                    "application/json"
                };
                if mode == "sse" && !text.is_empty() {
                    text = format!("event: message\ndata: {text}\n\n");
                }
                let reply = if mode == "oversized-header" {
                    format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        MAX_BYTES + 1
                    )
                } else if mode == "oversized-body" {
                    // No length header: enforce the cap while streaming, before JSON decode.
                    format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{}", "x".repeat(MAX_BYTES as usize + 1))
                } else {
                    format!("HTTP/1.1 {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", if text.is_empty() { "202 Accepted" } else { "200 OK" }, content_type, text.len(), text)
                };
                // The client may reject the oversized response before all bytes are sent.
                if reader.get_mut().write_all(reply.as_bytes()).await.is_err() {
                    break;
                }
            }
        });
        let mut request = fixture_request();
        request.transport = "http".into();
        request.url = Some(format!("http://{address}/mcp"));
        let result = tokio::time::timeout(Duration::from_secs(5), run(request, &|| false)).await;
        server.abort();
        let _ = server.await;
        let result = result.unwrap();
        if mode.starts_with("oversized") {
            assert_eq!(result.unwrap_err(), Error::Connection);
        } else {
            assert_eq!(result.unwrap()["tools"].as_array().unwrap().len(), 2);
        }
    }
}
