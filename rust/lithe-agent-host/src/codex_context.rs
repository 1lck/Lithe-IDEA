//! Restore actual Codex context reports through the existing native connection.
//!
//! The pinned ACP adapter omits usage during history loading. Its per-launch
//! native relay asks this loopback bridge for a load ticket and returns the
//! official App Server replay. Only the matching load may consume that report.
//! No transcript files, credentials, model calls, or installed packages are used.
//! Decision: .agents/notes/implemented/architecture/2026-09-25-shared-acp-agent-conversation.md

use std::collections::HashMap;
use std::convert::Infallible;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use bytes::Bytes;
use http_body_util::{BodyExt, Full, Limited};
use hyper::{body::Incoming, Method, Request, Response, StatusCode};
use serde::Deserialize;
use serde_json::{json, Value};
use tokio::sync::oneshot;

const REPORT_WAIT: Duration = Duration::from_millis(500);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(2);
const MAX_BODY: usize = 4096;
const MAX_LOADS: usize = 32;

/// One load owns one sender, so cancelled/replaced loads cannot publish later.
struct PendingLoad {
    ticket: String,
    report: Option<oneshot::Sender<Value>>,
    upstream_reported: bool,
}

/// Connection-local tickets; never persisted or shared between Agent processes.
type Loads = Arc<Mutex<HashMap<String, PendingLoad>>>;

/// Owns the listener and every accepted HTTP connection until the Agent stops.
pub(crate) struct Recovery {
    url: String,
    loads: Loads,
    server: tokio::task::JoinHandle<()>,
}

impl Drop for Recovery {
    fn drop(&mut self) {
        self.server.abort();
    }
}

impl Recovery {
    /// Optional compatibility bridge. Failure leaves standard ACP loading intact.
    pub(crate) async fn start() -> std::io::Result<Self> {
        let listener = tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0)).await?;
        let path = format!("/{}", uuid::Uuid::new_v4());
        let url = format!("http://{}{path}", listener.local_addr()?);
        let loads = Loads::default();
        let server_loads = loads.clone();
        let server = tokio::spawn(async move {
            let mut connections = tokio::task::JoinSet::new();
            loop {
                tokio::select! {
                    accepted = listener.accept() => {
                        let Ok((stream, _)) = accepted else { break };
                        if connections.len() >= MAX_LOADS { continue; }
                        let (loads, path) = (server_loads.clone(), path.clone());
                        connections.spawn(async move {
                            let service = hyper::service::service_fn(move |request| handle(request, loads.clone(), path.clone()));
                            let connection = hyper::server::conn::http1::Builder::new()
                                .keep_alive(false)
                                .serve_connection(hyper_util::rt::TokioIo::new(stream), service);
                            let _ = tokio::time::timeout(REQUEST_TIMEOUT, connection).await;
                        });
                    }
                    _ = connections.join_next(), if !connections.is_empty() => {}
                }
            }
            // JoinSet drops and aborts all in-flight clients when this owner stops.
        });
        Ok(Self { url, loads, server })
    }

    pub(crate) fn url(&self) -> &str {
        &self.url
    }

    pub(crate) fn capture(&self, session: &str) -> Option<Capture> {
        capture(&self.loads, session)
    }

    /// Standard ACP is authoritative, including an explicitly invalid report.
    pub(crate) fn prefer_upstream_report(&self, session: &str) {
        if let Ok(mut loads) = self.loads.lock() {
            if let Some(load) = loads.get_mut(session) {
                load.upstream_reported = true;
                load.report = None;
            }
        }
    }
}

/// RAII ticket for one ACP load. Its result is historical, not a new live report.
pub(crate) struct Capture {
    session: String,
    ticket: String,
    loads: Loads,
    report: Option<oneshot::Receiver<Value>>,
}

impl Capture {
    pub(crate) async fn finish(mut self) -> Option<Value> {
        let report = tokio::time::timeout(REPORT_WAIT, self.report.take()?)
            .await
            .ok()?
            .ok()?;
        let current = self
            .loads
            .lock()
            .ok()?
            .get(&self.session)
            .is_some_and(|load| load.ticket == self.ticket && !load.upstream_reported);
        current.then_some(report)
    }
}

impl Drop for Capture {
    fn drop(&mut self) {
        if let Ok(mut loads) = self.loads.lock() {
            if loads
                .get(&self.session)
                .is_some_and(|load| load.ticket == self.ticket)
            {
                loads.remove(&self.session);
            }
        }
    }
}

fn capture(loads: &Loads, session: &str) -> Option<Capture> {
    let mut pending = loads.lock().ok()?;
    if session.is_empty()
        || session.len() > 256
        || (!pending.contains_key(session) && pending.len() >= MAX_LOADS)
    {
        return None;
    }
    let ticket = uuid::Uuid::new_v4().to_string();
    let (sender, receiver) = oneshot::channel();
    pending.insert(
        session.to_owned(),
        PendingLoad {
            ticket: ticket.clone(),
            report: Some(sender),
            upstream_reported: false,
        },
    );
    Some(Capture {
        session: session.to_owned(),
        ticket,
        loads: loads.clone(),
        report: Some(receiver),
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Report {
    session_id: String,
    ticket: String,
    used: u64,
    size: u64,
}

/// Accept only an armed load and a positive native capacity. Report once.
fn dispatch(loads: &Loads, action: &str, value: Value) -> Value {
    let Ok(mut loads) = loads.lock() else {
        return Value::Null;
    };
    if action == "capture" {
        return value["sessionId"]
            .as_str()
            .and_then(|id| loads.get(id))
            .map(|load| json!({ "ticket": load.ticket }))
            .unwrap_or(Value::Null);
    }
    if action == "report" {
        if let Ok(report) = serde_json::from_value::<Report>(value) {
            if report.size > 0 {
                if let Some(load) = loads
                    .get_mut(&report.session_id)
                    .filter(|load| load.ticket == report.ticket && !load.upstream_reported)
                {
                    if let Some(sender) = load.report.take() {
                        let _ = sender.send(json!({ "sessionUpdate": "usage_update", "used": report.used, "size": report.size,
                            "_meta": { "lithe": { "contextUsageSource": "history" } } }));
                    }
                }
            }
        }
    }
    Value::Null
}

async fn handle(
    request: Request<Incoming>,
    loads: Loads,
    path: String,
) -> Result<Response<Full<Bytes>>, Infallible> {
    let action = request
        .uri()
        .path()
        .strip_prefix(&(path + "/"))
        .map(str::to_owned);
    let mut response = Response::new(Full::new(Bytes::new()));
    if request.method() != Method::POST || !matches!(action.as_deref(), Some("capture" | "report"))
    {
        *response.status_mut() = StatusCode::NOT_FOUND;
        return Ok(response);
    }
    let body = Limited::new(request.into_body(), MAX_BODY).collect().await;
    let value = body
        .ok()
        .and_then(|body| serde_json::from_slice(&body.to_bytes()).ok());
    let Some(value) = value else {
        *response.status_mut() = StatusCode::BAD_REQUEST;
        return Ok(response);
    };
    *response.body_mut() = Full::new(Bytes::from(
        dispatch(&loads, action.as_deref().unwrap_or_default(), value).to_string(),
    ));
    Ok(response)
}

#[cfg(test)]
mod tests;
