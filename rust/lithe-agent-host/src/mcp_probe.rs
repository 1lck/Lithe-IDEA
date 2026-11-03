//! Explicit, short-lived MCP inventory probes using the official MCP SDK.
//!
//! Probes list metadata only. They never call tools, persist credentials or
//! start automatically while the settings page is opening.

use rmcp::{model::PaginatedRequestParams, ServiceExt};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{collections::HashSet, process::Stdio, time::Duration};
use tokio::{io::AsyncReadExt, process::Command};
mod http_client;

/// User-reviewed connection, supplied by a platform's native configuration store.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Request {
    /// `stdio`, `http`, or the legacy `sse` configuration type.
    pub transport: String,
    /// Executable, without shell evaluation.
    pub command: Option<String>,
    /// Exact argument boundaries, including empty and space-containing values.
    #[serde(default)]
    pub args: Vec<String>,
    /// Environment overrides for this child only.
    #[serde(default)]
    pub env: Vec<Entry>,
    /// Remote endpoint; HTTPS or loopback HTTP only.
    pub url: Option<String>,
    /// Explicit request headers. Values are never returned in errors.
    #[serde(default)]
    pub headers: Vec<Entry>,
}

/// One environment or HTTP header entry; never logged.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Entry {
    /// Environment or header name.
    pub key: String,
    /// User-supplied value; never included in diagnostics.
    pub value: String,
}

/// Stable diagnostic category, deliberately independent of upstream error text.
#[derive(Debug, PartialEq)]
pub enum Error {
    Invalid,
    Unsupported,
    Start,
    Connection,
    Limit,
    Timeout,
    Cancelled,
}

const DEADLINE: Duration = Duration::from_secs(30);
const MAX_BYTES: u64 = 2 * 1024 * 1024;
const MAX_TOOLS: usize = 1000;

/// Runs one bounded probe on the calling worker thread. The caller owns cancel.
pub fn execute(mut request: Request, cancelled: &dyn Fn() -> bool) -> Result<Value, Error> {
    validate(&request)?;
    if cancelled() {
        return Err(Error::Cancelled);
    }
    if request.transport == "stdio" && !request.env.iter().any(|e| e.key == "PATH") {
        if let Some(path) = crate::environment::search_path_with_cancel(cancelled) {
            request.env.push(Entry {
                key: "PATH".into(),
                value: path.to_string_lossy().into_owned(),
            });
        }
    }
    if cancelled() {
        return Err(Error::Cancelled);
    }
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|_| Error::Start)?;
    runtime.block_on(run(request, cancelled))
}

fn validate(r: &Request) -> Result<(), Error> {
    let bytes = r.args.iter().map(String::len).sum::<usize>()
        + r.env
            .iter()
            .chain(&r.headers)
            .map(|e| e.key.len() + e.value.len())
            .sum::<usize>();
    if bytes > 1024 * 1024 || r.args.len() > 256 || r.env.len() > 128 || r.headers.len() > 128 {
        return Err(Error::Invalid);
    }
    match r.transport.as_str() {
        "stdio"
            if r.command
                .as_ref()
                .is_some_and(|s| !s.is_empty() && !s.contains('\0')) =>
        {
            Ok(())
        }
        "http" => {
            let u = url::Url::parse(r.url.as_deref().unwrap_or("")).map_err(|_| Error::Invalid)?;
            let loopback = u.host_str().is_some_and(|s| {
                s == "localhost" || s == "127.0.0.1" || s == "[::1]" || s == "::1"
            });
            if (u.scheme() != "https" && !(u.scheme() == "http" && loopback))
                || u.host_str().is_none()
                || !u.username().is_empty()
                || u.password().is_some()
                || u.fragment().is_some()
            {
                return Err(Error::Invalid);
            }
            Ok(())
        }
        "sse" => Err(Error::Unsupported),
        _ => Err(Error::Invalid),
    }
}

async fn run(r: Request, cancelled: &dyn Fn() -> bool) -> Result<Value, Error> {
    let mut child = None;
    let transport = r.transport.clone();
    let mut command = if transport == "stdio" {
        let path = r
            .env
            .iter()
            .find(|e| e.key == "PATH")
            .map(|e| std::ffi::OsStr::new(&e.value));
        let executable =
            crate::environment::find_executable(r.command.as_deref().ok_or(Error::Invalid)?, path)
                .ok_or(Error::Start)?;
        let mut cmd = Command::new(executable);
        cmd.args(&r.args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true);
        for e in &r.env {
            cmd.env(&e.key, &e.value);
        }
        #[cfg(unix)]
        cmd.process_group(0);
        #[cfg(windows)]
        cmd.creation_flags(crate::CREATE_NO_WINDOW);
        let mut spawned = cmd.spawn().map_err(|_| Error::Start)?;
        let output = spawned.stdout.take().ok_or(Error::Start)?;
        let input = spawned.stdin.take().ok_or(Error::Start)?;
        child = Some(spawned);
        // Bound the complete stdio metadata exchange, including an unterminated
        // JSON line; SDK parsing cannot grow forever on a malicious child.
        Some((output.take(MAX_BYTES), input))
    } else {
        None
    };
    let result = async {
        if let Some(streams) = command.take() {
            inventory(streams, cancelled).await
        } else {
            use rmcp::transport::streamable_http_client::{
                StreamableHttpClientTransport, StreamableHttpClientTransportConfig,
            };
            let mut headers = http::HeaderMap::new();
            for e in &r.headers {
                let key = http::header::HeaderName::from_bytes(e.key.as_bytes())
                    .map_err(|_| Error::Invalid)?;
                // Session and content framing belong to the SDK, not user headers.
                if matches!(
                    key.as_str(),
                    "host"
                        | "content-length"
                        | "content-type"
                        | "accept"
                        | "mcp-session-id"
                        | "mcp-protocol-version"
                ) {
                    return Err(Error::Invalid);
                }
                let mut value =
                    http::header::HeaderValue::from_str(&e.value).map_err(|_| Error::Invalid)?;
                value.set_sensitive(true);
                headers.insert(key, value);
            }
            let client = reqwest::Client::builder()
                .default_headers(headers)
                .redirect(reqwest::redirect::Policy::none())
                .connect_timeout(Duration::from_secs(8))
                .timeout(DEADLINE)
                .build()
                .map_err(|_| Error::Start)?;
            let mut config =
                StreamableHttpClientTransportConfig::with_uri(r.url.ok_or(Error::Invalid)?);
            config.max_sse_event_size = MAX_BYTES as usize;
            let http = StreamableHttpClientTransport::with_client(
                http_client::BoundedClient(client),
                config,
            );
            inventory(http, cancelled).await
        }
    }
    .await;
    if let Some(mut child) = child {
        if let Some(pid) = child.id() {
            crate::force_kill_tree(pid);
        }
        let _ = tokio::time::timeout(Duration::from_secs(3), child.wait()).await;
    }
    result
}

#[cfg(test)]
mod tests;

async fn inventory<T, E, A>(transport: T, cancelled: &dyn Fn() -> bool) -> Result<Value, Error>
where
    T: rmcp::transport::IntoTransport<rmcp::RoleClient, E, A>,
    E: std::error::Error + Send + Sync + 'static,
{
    let deadline = tokio::time::Instant::now() + DEADLINE;
    let cancel = async {
        let mut ticks = tokio::time::interval(Duration::from_millis(50));
        loop {
            ticks.tick().await;
            if cancelled() {
                return;
            }
        }
    };
    tokio::pin!(cancel);
    let service = tokio::select! {
        _ = &mut cancel => return Err(Error::Cancelled),
        _ = tokio::time::sleep_until(deadline) => return Err(Error::Timeout),
        value = ().serve(transport) => value.map_err(|_| Error::Connection)?,
    };
    let listing = async {
        let mut tools = Vec::new();
        let mut names = HashSet::new();
        let mut cursors = HashSet::new();
        let mut cursor = None;
        let mut size = 0;
        for _ in 0..20 {
            let mut params = PaginatedRequestParams::default();
            params.cursor = cursor;
            let page = service
                .list_tools(Some(params))
                .await
                .map_err(|_| Error::Connection)?;
            for tool in page.tools {
                let name = tool.name.to_string();
                let description = tool.description.unwrap_or_default().to_string();
                size += name.len() + description.len();
                if name.is_empty()
                    || name.len() > 256
                    || description.len() > 16384
                    || size > MAX_BYTES as usize
                    || tools.len() >= MAX_TOOLS
                {
                    return Err(Error::Limit);
                }
                if names.insert(name.clone()) {
                    tools.push(json!({"name": name, "description": description}));
                }
            }
            cursor = page.next_cursor;
            if cursor.is_none() {
                tools.sort_by(|a, b| a["name"].as_str().cmp(&b["name"].as_str()));
                return Ok(json!({"tools": tools}));
            }
            if cursor.as_ref().is_some_and(|c| c.len() > 2048) {
                return Err(Error::Limit);
            }
            if !cursors.insert(cursor.clone()) {
                return Err(Error::Limit);
            }
        }
        Err(Error::Limit)
    };
    let result = tokio::select! {
        _ = &mut cancel => Err(Error::Cancelled),
        _ = tokio::time::sleep_until(deadline) => Err(Error::Timeout),
        value = listing => value,
    };
    let _ = tokio::time::timeout(Duration::from_secs(2), service.cancel()).await;
    result
}
