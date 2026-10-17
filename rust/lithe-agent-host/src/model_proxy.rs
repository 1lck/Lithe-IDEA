//! Opt-in loopback proxy between an Agent and its model provider.
//!
//! The Agent receives `http://127.0.0.1:<port>/<launch token>` instead of the
//! configured endpoint. Every request is forwarded to that endpoint with the
//! Agent's own headers and body; responses stream back byte for byte. Only
//! generation requests are observed through [`crate::model_calls`]; every other
//! request streams through without buffering. Same-origin redirects are mapped
//! back onto the proxy so they keep working. The proxy never stores, logs or
//! emits request content or credentials, binds only the loopback interface and
//! rejects paths without the per-launch token. Its lifetime is one Agent
//! connection; it writes no files.
//! Decision: .agents/notes/implemented/architecture/2026-10-13-agent-model-call-observation.md

use std::collections::HashMap;
use std::convert::Infallible;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use bytes::Bytes;
use futures::{Stream, StreamExt};
use http_body_util::{combinators::UnsyncBoxBody, BodyExt, Full, StreamBody};
use hyper::body::{Frame, Incoming};
use hyper::header::{HeaderMap, HeaderName, HeaderValue};
use hyper::{Request, Response, StatusCode};

use crate::model_calls::{self, ModelApi, ModelCall, RequestShape, ResponseObserver};

mod websocket;

/// Generation request bodies up to this size are buffered to measure their
/// composition. Larger bodies are still forwarded, just without composition.
const OBSERVED_REQUEST_BYTES: usize = 32 * 1024 * 1024;
/// Route segment for same-origin redirect targets outside the configured path.
const ORIGIN_ROUTE: &str = "/~origin";
const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);

/// Headers that describe one hop and must not be forwarded (RFC 9110 §7.6.1),
/// plus fields the forwarding client recomputes for the upstream request.
const HOP_HEADERS: [&str; 10] = [
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "proxy-connection",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
    "host",
];

/// The prompt that caused a request: its session and the Host's turn generation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct CallOwner {
    pub(crate) session: String,
    pub(crate) generation: u64,
}

/// Called once per completed or abandoned generation request with the
/// session that had the only running prompt when the request started, and
/// whether that prompt's `turnFinished` was already emitted.
pub(crate) type CallSink = Arc<dyn Fn(Option<String>, bool, ModelCall) + Send + Sync>;
/// Resolves the prompt a new request belongs to, or `None` when ambiguous.
pub(crate) type SessionResolver = Arc<dyn Fn() -> Option<CallOwner> + Send + Sync>;

/// Attributed generation requests that have started but not yet been reported.
/// The Host waits on it so a turn's `modelCall` events precede `turnFinished`.
#[derive(Default)]
pub(crate) struct CallsInFlight {
    counts: Mutex<HashMap<String, usize>>,
    changed: tokio::sync::Notify,
    /// Latest generation per session whose `turnFinished` has been emitted.
    finished: Mutex<HashMap<String, u64>>,
}

impl CallsInFlight {
    /// Record that `generation`'s turn ended. Later reports for it, from a
    /// stream that outlived the settle bound, must not count toward the next turn.
    pub(crate) fn finish_turn(&self, session: &str, generation: u64) {
        if let Ok(mut finished) = self.finished.lock() {
            let latest = finished.entry(session.to_owned()).or_default();
            *latest = (*latest).max(generation);
        }
    }

    fn after_turn(&self, owner: &CallOwner) -> bool {
        self.finished.lock().is_ok_and(|finished| {
            finished
                .get(&owner.session)
                .is_some_and(|latest| *latest >= owner.generation)
        })
    }

    fn begin(&self, session: &str) {
        if let Ok(mut counts) = self.counts.lock() {
            *counts.entry(session.to_owned()).or_default() += 1;
        }
    }

    fn end(&self, session: &str) {
        if let Ok(mut counts) = self.counts.lock() {
            if let Some(count) = counts.get_mut(session) {
                *count -= 1;
                if *count == 0 {
                    counts.remove(session);
                }
            }
        }
        self.changed.notify_waiters();
    }

    fn pending(&self, session: &str) -> bool {
        self.counts
            .lock()
            .is_ok_and(|counts| counts.contains_key(session))
    }

    /// Wait until `session` has no unreported call, at most `limit`. A stream
    /// the Agent keeps open past its prompt response cannot delay the turn
    /// beyond this bound; its call is then reported for the session only.
    pub(crate) async fn settle(&self, session: &str, limit: Duration) {
        let _ = tokio::time::timeout(limit, async {
            loop {
                // Registered before the check so a concurrent `end` is not missed.
                let changed = self.changed.notified();
                if !self.pending(session) {
                    return;
                }
                changed.await;
            }
        })
        .await;
    }
}

/// A running proxy. Dropping it stops accepting connections and aborts
/// in-flight exchanges together with the Agent connection that used them.
pub(crate) struct ModelCallProxy {
    base_url: String,
    accept: tokio::task::JoinHandle<()>,
    connections: Arc<Mutex<tokio::task::JoinSet<()>>>,
}

impl ModelCallProxy {
    /// Base URL to hand to the Agent in place of the configured endpoint.
    pub(crate) fn base_url(&self) -> &str {
        &self.base_url
    }
}

impl Drop for ModelCallProxy {
    fn drop(&mut self) {
        self.accept.abort();
        if let Ok(mut connections) = self.connections.lock() {
            connections.abort_all();
        }
    }
}

struct State {
    /// Path prefix the Agent must use, e.g. `/lithe-<uuid>`.
    prefix: String,
    /// Configured endpoint without a trailing slash.
    upstream: String,
    /// Scheme, host and port of the configured endpoint.
    origin: url::Url,
    /// Path of the configured endpoint without a trailing slash, e.g. `/api`.
    base_path: String,
    client: reqwest::Client,
    session: SessionResolver,
    sink: CallSink,
    in_flight: Arc<CallsInFlight>,
    /// Upgraded sockets outlive their HTTP exchange but share its launch owner.
    connections: std::sync::Weak<Mutex<tokio::task::JoinSet<()>>>,
}

impl State {
    fn report(&self, owner: Option<CallOwner>, call: ModelCall) {
        let after_turn = owner
            .as_ref()
            .is_some_and(|owner| self.in_flight.after_turn(owner));
        (self.sink)(
            owner.as_ref().map(|owner| owner.session.clone()),
            after_turn,
            call,
        );
        self.release(owner.as_ref());
    }

    /// End an attributed request without reporting it, e.g. a redirect hop.
    fn release(&self, owner: Option<&CallOwner>) {
        if let Some(owner) = owner {
            self.in_flight.end(&owner.session);
        }
    }

    /// Map a same-origin redirect target back onto this proxy. The Agent
    /// resolves `Location` against the proxy URL, whose path differs from the
    /// upstream request by the token prefix, so absolute paths and `../`
    /// references would escape the proxy route. Resolve against the actual
    /// upstream request URL, then remap. Cross-origin targets are left for
    /// the Agent's own client and credential policy, exactly as without the proxy.
    fn rewrite_location(&self, location: &str, request: &url::Url) -> Option<String> {
        let target = request.join(location).ok()?;
        if target.origin() != self.origin.origin() {
            return None;
        }
        let mut rest = target.path().to_owned();
        if let Some(query) = target.query() {
            rest.push('?');
            rest.push_str(query);
        }
        if let Some(fragment) = target.fragment() {
            rest.push('#');
            rest.push_str(fragment);
        }
        let under_base = self.base_path.is_empty()
            || target.path() == self.base_path
            || target.path().starts_with(&format!("{}/", self.base_path));
        Some(if under_base {
            format!("{}{}", self.prefix, &rest[self.base_path.len()..])
        } else {
            format!("{}{ORIGIN_ROUTE}{rest}", self.prefix)
        })
    }
}

/// Bind an ephemeral loopback port and forward to `upstream`.
pub(crate) async fn start(
    upstream: &str,
    session: SessionResolver,
    sink: CallSink,
    in_flight: Arc<CallsInFlight>,
) -> Result<ModelCallProxy, String> {
    let upstream = upstream.trim_end_matches('/');
    let mut origin = url::Url::parse(upstream)
        .map_err(|error| format!("Could not prepare model call statistics: {error}"))?;
    let base_path = origin.path().trim_end_matches('/').to_owned();
    origin.set_path("/");
    origin.set_query(None);
    let client = reqwest::Client::builder()
        .connect_timeout(CONNECT_TIMEOUT)
        // Redirects and compression are the Agent's concern; forward them as-is.
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|error| format!("Could not prepare model call statistics: {error}"))?;
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .map_err(|error| format!("Could not start model call statistics: {error}"))?;
    let port = listener
        .local_addr()
        .map_err(|error| format!("Could not start model call statistics: {error}"))?
        .port();
    let prefix = format!("/lithe-{}", uuid::Uuid::new_v4().simple());
    let connections = Arc::new(Mutex::new(tokio::task::JoinSet::new()));
    let state = Arc::new(State {
        prefix: prefix.clone(),
        upstream: upstream.to_owned(),
        origin,
        base_path,
        client,
        session,
        sink,
        in_flight,
        connections: Arc::downgrade(&connections),
    });
    let accepted = connections.clone();
    let accept = tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else {
                continue;
            };
            let state = state.clone();
            let service = hyper::service::service_fn(move |request| handle(request, state.clone()));
            let connection = async move {
                let _ = hyper::server::conn::http1::Builder::new()
                    .serve_connection(hyper_util::rt::TokioIo::new(stream), service)
                    .with_upgrades()
                    .await;
            };
            if let Ok(mut connections) = accepted.lock() {
                // Reap finished exchanges so a long session does not accumulate handles.
                while connections.try_join_next().is_some() {}
                connections.spawn(connection);
            }
        }
    });
    Ok(ModelCallProxy {
        base_url: format!("http://127.0.0.1:{port}{prefix}"),
        accept,
        connections,
    })
}

type ProxyBody = UnsyncBoxBody<Bytes, Box<dyn std::error::Error + Send + Sync>>;

async fn handle(
    request: Request<Incoming>,
    state: Arc<State>,
) -> Result<Response<ProxyBody>, Infallible> {
    let path = request
        .uri()
        .path_and_query()
        .map(|value| value.as_str())
        .unwrap_or("/");
    let Some(rest) = path
        .strip_prefix(&state.prefix)
        .filter(|rest| rest.is_empty() || rest.starts_with(['/', '?']))
    else {
        return Ok(failure(StatusCode::NOT_FOUND, "Unknown model call route"));
    };
    // Same-origin redirects outside the configured path use the origin route.
    let (url, route) = match rest.strip_prefix(ORIGIN_ROUTE) {
        Some(path) if path.is_empty() || path.starts_with(['/', '?']) => (
            format!("{}{path}", state.origin.as_str().trim_end_matches('/')),
            path,
        ),
        _ => (format!("{}{rest}", state.upstream), rest),
    };
    if websocket::is_upgrade(&request) {
        let observed = ModelApi::from_path(route) == Some(ModelApi::Responses);
        return Ok(websocket::forward(request, &url, state, observed).await);
    }
    let api = (request.method() == hyper::Method::POST)
        .then(|| ModelApi::from_path(route))
        .flatten();
    let compressed_request = request
        .headers()
        .contains_key(hyper::header::CONTENT_ENCODING);
    let headers = forwarded_headers(request.headers(), api.is_some());
    let (parts, body) = request.into_parts();
    let mut body = body.into_data_stream();
    let mut shape = None;
    let body = match api {
        // Auxiliary and upload requests stream through without buffering.
        None => reqwest::Body::wrap_stream(body),
        Some(api) => {
            let mut buffered = Vec::new();
            let mut size = 0;
            let mut complete = true;
            while let Some(chunk) = body.next().await {
                let Ok(chunk) = chunk else {
                    return Ok(failure(
                        StatusCode::BAD_REQUEST,
                        "The model request was interrupted",
                    ));
                };
                size += chunk.len();
                buffered.push(chunk);
                if size > OBSERVED_REQUEST_BYTES {
                    complete = false;
                    break;
                }
            }
            if complete {
                let bytes = Bytes::from(buffered.concat());
                if !compressed_request {
                    shape = model_calls::request_shape(api, &bytes);
                }
                reqwest::Body::from(bytes)
            } else {
                // Over the observation budget: forward unchanged without composition.
                reqwest::Body::wrap_stream(
                    futures::stream::iter(buffered.into_iter().map(Ok)).chain(body),
                )
            }
        }
    };
    let session = api.and_then(|_| (state.session)());
    if let Some(owner) = &session {
        state.in_flight.begin(&owner.session);
    }
    let request_url = url::Url::parse(&url).ok();
    let started = Instant::now();
    let upstream = state
        .client
        .request(parts.method, &url)
        .headers(headers)
        .body(body)
        .send()
        .await;
    let upstream = match upstream {
        Ok(response) => response,
        Err(error) => {
            if let Some(api) = api {
                let observer =
                    ResponseObserver::new(api, StatusCode::BAD_GATEWAY.as_u16(), false, started);
                state.report(session, observer.finish(shape.as_ref(), Instant::now()));
            }
            // reqwest errors carry the URL and cause, never request headers.
            return Ok(failure(
                StatusCode::BAD_GATEWAY,
                &format!("Lithe could not reach the model provider: {error}"),
            ));
        }
    };
    let status = upstream.status();
    // A redirect is a transport hop, not a generation; only the final
    // response of the followed request is a model call.
    let api = if status.is_redirection() {
        state.release(session.as_ref());
        None
    } else {
        api
    };
    let mut response = Response::builder().status(status);
    let streaming = upstream
        .headers()
        .get(hyper::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| value.starts_with("text/event-stream"));
    if let Some(headers) = response.headers_mut() {
        for (name, value) in upstream.headers() {
            if is_hop_header(name) {
                continue;
            }
            let rewritten = (name == hyper::header::LOCATION)
                .then(|| {
                    value.to_str().ok().and_then(|location| {
                        state.rewrite_location(location, request_url.as_ref()?)
                    })
                })
                .flatten()
                .and_then(|location| HeaderValue::from_str(&location).ok());
            headers.append(name.clone(), rewritten.unwrap_or_else(|| value.clone()));
        }
    }
    let stream = upstream.bytes_stream();
    let body: ProxyBody = match api {
        Some(api) => {
            let observed = ObservedStream {
                inner: stream.boxed(),
                observer: Some(ResponseObserver::new(
                    api,
                    status.as_u16(),
                    streaming,
                    started,
                )),
                shape,
                session,
                state: state.clone(),
            };
            BodyExt::boxed_unsync(StreamBody::new(
                observed.map(|chunk| chunk.map(Frame::data)),
            ))
        }
        None => BodyExt::boxed_unsync(StreamBody::new(stream.map(|chunk| {
            chunk
                .map(Frame::data)
                .map_err(|error| Box::new(error) as Box<dyn std::error::Error + Send + Sync>)
        }))),
    };
    Ok(response.body(body).unwrap_or_else(|_| {
        failure(
            StatusCode::BAD_GATEWAY,
            "Lithe could not forward the model response",
        )
    }))
}

/// Copy the Agent's headers. For observed calls, ask for an identity-encoded
/// response so usage events remain readable; the content is unchanged.
fn forwarded_headers(source: &HeaderMap, observed: bool) -> HeaderMap {
    let mut headers = HeaderMap::with_capacity(source.len());
    for (name, value) in source {
        if !is_hop_header(name) && name != hyper::header::CONTENT_LENGTH {
            headers.append(name.clone(), value.clone());
        }
    }
    if observed {
        headers.insert(
            hyper::header::ACCEPT_ENCODING,
            HeaderValue::from_static("identity"),
        );
    }
    headers
}

fn is_hop_header(name: &HeaderName) -> bool {
    HOP_HEADERS.contains(&name.as_str())
}

fn failure(status: StatusCode, message: &str) -> Response<ProxyBody> {
    // Use the provider error envelope shape both Anthropic and OpenAI clients read.
    let body = serde_json::json!({"error": {"type": "api_error", "message": message}}).to_string();
    let mut response = Response::new(BodyExt::boxed_unsync(
        Full::new(Bytes::from(body)).map_err(|never| match never {}),
    ));
    *response.status_mut() = status;
    response.headers_mut().insert(
        hyper::header::CONTENT_TYPE,
        HeaderValue::from_static("application/json"),
    );
    response
}

/// Forwards upstream chunks unchanged while feeding the observer. The call is
/// reported at end of stream, upstream error, or when the Agent disconnects.
struct ObservedStream {
    inner: futures::stream::BoxStream<'static, reqwest::Result<Bytes>>,
    observer: Option<ResponseObserver>,
    shape: Option<RequestShape>,
    session: Option<CallOwner>,
    state: Arc<State>,
}

impl ObservedStream {
    fn report(&mut self) {
        if let Some(observer) = self.observer.take() {
            let call = observer.finish(self.shape.as_ref(), Instant::now());
            self.state.report(self.session.take(), call);
        }
    }
}

impl Stream for ObservedStream {
    type Item = Result<Bytes, Box<dyn std::error::Error + Send + Sync>>;

    fn poll_next(mut self: Pin<&mut Self>, context: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        match self.inner.poll_next_unpin(context) {
            Poll::Ready(Some(Ok(chunk))) => {
                if let Some(observer) = self.observer.as_mut() {
                    observer.feed(&chunk, Instant::now());
                }
                Poll::Ready(Some(Ok(chunk)))
            }
            Poll::Ready(Some(Err(error))) => {
                self.report();
                Poll::Ready(Some(Err(Box::new(error))))
            }
            Poll::Ready(None) => {
                self.report();
                Poll::Ready(None)
            }
            Poll::Pending => Poll::Pending,
        }
    }
}

impl Drop for ObservedStream {
    fn drop(&mut self) {
        self.report();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    /// Minimal HTTP/1.1 upstream that records one request and replies with `reply`.
    async fn upstream(reply: &'static str) -> (String, tokio::task::JoinHandle<String>) {
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .unwrap();
        let address = listener.local_addr().unwrap();
        let task = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut received = Vec::new();
            let mut buffer = [0u8; 4096];
            // Read headers, then the declared body length.
            loop {
                let read = stream.read(&mut buffer).await.unwrap();
                received.extend_from_slice(&buffer[..read]);
                let text = String::from_utf8_lossy(&received).to_string();
                if let Some(end) = text.find("\r\n\r\n") {
                    let length = text[..end]
                        .lines()
                        .find_map(|line| {
                            line.to_ascii_lowercase()
                                .strip_prefix("content-length:")
                                .map(|value| value.trim().parse::<usize>().unwrap())
                        })
                        .unwrap_or(0);
                    if received.len() >= end + 4 + length || read == 0 {
                        break;
                    }
                }
            }
            stream.write_all(reply.as_bytes()).await.unwrap();
            stream.shutdown().await.unwrap();
            String::from_utf8_lossy(&received).to_string()
        });
        (format!("http://{address}/api"), task)
    }

    async fn send(base: &str, path: &str, body: &str) -> (u16, String) {
        let client = reqwest::Client::new();
        let response = client
            .post(format!("{base}{path}"))
            .header("x-api-key", "secret-key")
            .header("content-type", "application/json")
            .body(body.to_owned())
            .send()
            .await
            .unwrap();
        (response.status().as_u16(), response.text().await.unwrap())
    }

    fn owner() -> Option<CallOwner> {
        Some(CallOwner {
            session: "session-1".into(),
            generation: 1,
        })
    }

    /// Calls reported by the proxy, in completion order.
    type Collected = Arc<Mutex<Vec<(Option<String>, ModelCall)>>>;

    fn collecting() -> (CallSink, Collected) {
        let calls = Arc::new(Mutex::new(Vec::new()));
        let sink = calls.clone();
        (
            Arc::new(move |session, _, call| sink.lock().unwrap().push((session, call))),
            calls,
        )
    }

    #[tokio::test]
    async fn streams_are_forwarded_unchanged_and_observed() {
        let stream = "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":5,\"output_tokens\":1}}}\n\ndata: {\"type\":\"content_block_delta\"}\n\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":9}}\n\n";
        let reply: &'static str = Box::leak(format!(
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nretry-after: 7\r\ncontent-length: {}\r\n\r\n{stream}",
            stream.len()
        ).into_boxed_str());
        let (base, request) = upstream(reply).await;
        let (sink, calls) = collecting();
        let in_flight = Arc::new(CallsInFlight::default());
        let proxy = start(&base, Arc::new(owner), sink, in_flight.clone())
            .await
            .unwrap();
        let (status, body) = send(
            proxy.base_url(),
            "/v1/messages",
            r#"{"model":"m","messages":[]}"#,
        )
        .await;
        assert_eq!((status, body.as_str()), (200, stream));
        let request = request.await.unwrap();
        // The Agent's credentials and body reach the configured path unchanged.
        assert!(request.starts_with("POST /api/v1/messages HTTP/1.1"));
        assert!(request
            .to_ascii_lowercase()
            .contains("x-api-key: secret-key"));
        assert!(request.ends_with(r#"{"model":"m","messages":[]}"#));
        drop(proxy);
        let calls = calls.lock().unwrap();
        assert_eq!(calls.len(), 1);
        let (session, call) = &calls[0];
        assert_eq!(session.as_deref(), Some("session-1"));
        assert!(
            !in_flight.pending("session-1"),
            "reported calls are no longer in flight"
        );
        assert!(call.streaming);
        assert_eq!(call.model.as_deref(), Some("m"));
        assert_eq!(call.usage.map(|usage| usage.output_tokens), Some(9));
    }

    #[tokio::test]
    async fn auxiliary_requests_and_foreign_paths_are_not_observed() {
        let (base, request) =
            upstream("HTTP/1.1 404 Not Found\r\ncontent-length: 2\r\n\r\n{}").await;
        let (sink, calls) = collecting();
        let proxy = start(&base, Arc::new(|| None), sink, Arc::default())
            .await
            .unwrap();
        let (status, _) = send(proxy.base_url(), "/v1/messages/count_tokens", "{}").await;
        assert_eq!(status, 404);
        request.await.unwrap();
        // Without the per-launch token another local process cannot use the route.
        let origin = proxy.base_url().rsplit_once('/').unwrap().0.to_owned();
        let (status, body) = send(&origin, "/v1/messages", "{}").await;
        assert_eq!(status, 404);
        assert!(body.contains("Unknown model call route"));
        assert!(calls.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn unreachable_providers_return_an_error_envelope_and_a_failed_call() {
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .unwrap();
        let closed = format!("http://{}", listener.local_addr().unwrap());
        drop(listener);
        let (sink, calls) = collecting();
        let proxy = start(&closed, Arc::new(|| None), sink, Arc::default())
            .await
            .unwrap();
        let (status, body) = send(proxy.base_url(), "/v1/responses", "{}").await;
        assert_eq!(status, 502);
        assert!(body.contains("\"api_error\""));
        assert!(!body.contains("secret-key"));
        assert_eq!(calls.lock().unwrap()[0].1.status, 502);
    }

    /// `(status, headers, body)` returned for one upstream request.
    type ScriptedReply = (u16, Vec<(&'static str, &'static str)>, &'static str);

    /// Recorded `(path, body length)` of each request a hyper upstream served.
    type Served = Arc<Mutex<Vec<(String, usize)>>>;

    /// HTTP/1.1 upstream that drains each request body, including chunked
    /// uploads, and answers with the next scripted `(status, headers, body)`.
    async fn scripted_upstream(replies: Vec<ScriptedReply>) -> (String, Served) {
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .unwrap();
        let address = listener.local_addr().unwrap();
        let served: Served = Arc::default();
        let log = served.clone();
        let replies = Arc::new(Mutex::new(std::collections::VecDeque::from(replies)));
        tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                let (log, replies) = (log.clone(), replies.clone());
                tokio::spawn(async move {
                    let service = hyper::service::service_fn(move |request: Request<Incoming>| {
                        let (log, replies) = (log.clone(), replies.clone());
                        async move {
                            let path = request
                                .uri()
                                .path_and_query()
                                .map(|value| value.to_string())
                                .unwrap_or_default();
                            let length = request
                                .into_body()
                                .collect()
                                .await
                                .map(|body| body.to_bytes().len())
                                .unwrap_or(0);
                            log.lock().unwrap().push((path, length));
                            let (status, headers, body) = replies
                                .lock()
                                .unwrap()
                                .pop_front()
                                .unwrap_or((200, vec![], ""));
                            let mut response =
                                Response::new(Full::new(Bytes::from_static(body.as_bytes())));
                            *response.status_mut() = StatusCode::from_u16(status).unwrap();
                            for (name, value) in headers {
                                response
                                    .headers_mut()
                                    .insert(name, HeaderValue::from_static(value));
                            }
                            Ok::<_, Infallible>(response)
                        }
                    });
                    let _ = hyper::server::conn::http1::Builder::new()
                        .serve_connection(hyper_util::rt::TokioIo::new(stream), service)
                        .await;
                });
            }
        });
        (format!("http://{address}/api"), served)
    }

    #[tokio::test]
    async fn same_origin_redirects_are_mapped_back_onto_the_proxy() {
        let (base, _) = scripted_upstream(vec![]).await;
        let proxy = start(
            &format!("{base}/v1"),
            Arc::new(|| None),
            collecting().0,
            Arc::default(),
        )
        .await
        .unwrap();
        let prefix = proxy
            .base_url()
            .split_once("/lithe-")
            .map(|(_, token)| format!("/lithe-{token}"))
            .unwrap();
        let origin = base.trim_end_matches("/api");
        let state = State {
            prefix: prefix.clone(),
            upstream: format!("{base}/v1"),
            origin: url::Url::parse(&format!("{origin}/")).unwrap(),
            base_path: "/api/v1".into(),
            client: reqwest::Client::new(),
            session: Arc::new(|| None),
            sink: collecting().0,
            in_flight: Arc::default(),
            connections: std::sync::Weak::new(),
        };
        // Locations resolve against the actual upstream request, not the proxy URL.
        let request = url::Url::parse(&format!("{origin}/api/v1/messages")).unwrap();
        let rewrite = |location: &str| state.rewrite_location(location, &request);
        assert_eq!(
            rewrite("/api/v1/messages?beta=1").unwrap(),
            format!("{prefix}/messages?beta=1")
        );
        assert_eq!(
            rewrite(&format!("{origin}/api/v1/responses")).unwrap(),
            format!("{prefix}/responses")
        );
        assert_eq!(
            rewrite("/v2/responses").unwrap(),
            format!("{prefix}/~origin/v2/responses")
        );
        // A path that only shares a textual prefix with the base is outside it.
        assert_eq!(
            rewrite("/api/v10/x").unwrap(),
            format!("{prefix}/~origin/api/v10/x")
        );
        // Relative references, including `../` that leave the configured path.
        assert_eq!(rewrite("responses").unwrap(), format!("{prefix}/responses"));
        assert_eq!(
            rewrite("../v2/messages?x=1").unwrap(),
            format!("{prefix}/~origin/api/v2/messages?x=1")
        );
        assert_eq!(
            rewrite("../../v2/messages").unwrap(),
            format!("{prefix}/~origin/v2/messages")
        );
        assert_eq!(
            rewrite("./v1/../responses").unwrap(),
            format!("{prefix}/responses")
        );
        // Cross-origin targets are left to the Agent's own client.
        assert_eq!(rewrite("https://other.example/v1/messages"), None);
    }

    #[tokio::test]
    async fn relative_redirects_keep_working_through_the_proxy() {
        let stream = "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n";
        let (base, served) = scripted_upstream(vec![
            (307, vec![("location", "/v2/messages")], ""),
            (200, vec![("content-type", "text/event-stream")], stream),
        ])
        .await;
        let (sink, calls) = collecting();
        let in_flight = Arc::new(CallsInFlight::default());
        let proxy = start(&base, Arc::new(owner), sink, in_flight.clone())
            .await
            .unwrap();
        // reqwest follows a 307 like the Agents' HTTP clients, resending the body.
        let (status, body) = send(proxy.base_url(), "/v1/messages", r#"{"messages":[]}"#).await;
        assert_eq!((status, body.as_str()), (200, stream));
        let served = served.lock().unwrap().clone();
        assert_eq!(
            served
                .iter()
                .map(|(path, _)| path.as_str())
                .collect::<Vec<_>>(),
            ["/api/v1/messages", "/v2/messages"]
        );
        // The released redirect hop does not leave the turn waiting.
        assert!(!in_flight.pending("session-1"));
        drop(proxy);
        // The 307 hop is transport, not a generation: exactly one model call.
        let calls = calls.lock().unwrap();
        assert_eq!(calls.len(), 1, "{calls:?}");
        assert!(calls[0].1.streaming && calls[0].1.usage.is_some());
    }

    #[tokio::test]
    async fn large_requests_stream_through_instead_of_failing() {
        let (base, served) =
            scripted_upstream(vec![(200, vec![], "{}"), (200, vec![], "{}")]).await;
        let (sink, calls) = collecting();
        let proxy = start(&base, Arc::new(|| None), sink, Arc::default())
            .await
            .unwrap();
        let large = "x".repeat(OBSERVED_REQUEST_BYTES + 1024);
        // An unobserved upload and an observed request over the measuring budget.
        for path in ["/v1/files", "/v1/messages"] {
            let (status, _) = send(proxy.base_url(), path, &large).await;
            assert_eq!(status, 200, "{path}");
        }
        assert!(served
            .lock()
            .unwrap()
            .iter()
            .all(|(_, length)| *length == large.len()));
        drop(proxy);
        let calls = calls.lock().unwrap();
        assert_eq!(calls.len(), 1, "only the generation endpoint is observed");
        assert!(
            calls[0].1.context.is_none(),
            "composition is skipped over budget"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn settling_waits_for_reported_calls_within_a_bound() {
        let in_flight = Arc::new(CallsInFlight::default());
        let started = tokio::time::Instant::now();
        in_flight.settle("idle", Duration::from_secs(2)).await;
        assert_eq!(
            started.elapsed(),
            Duration::ZERO,
            "no attributed call means no wait"
        );
        in_flight.begin("session-1");
        let reporting = in_flight.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(300)).await;
            reporting.end("session-1");
        });
        in_flight.settle("session-1", Duration::from_secs(2)).await;
        assert_eq!(started.elapsed(), Duration::from_millis(300));
        // A stream left open cannot hold the turn beyond the bound.
        in_flight.begin("session-2");
        let bounded = tokio::time::Instant::now();
        in_flight.settle("session-2", Duration::from_secs(2)).await;
        assert_eq!(bounded.elapsed(), Duration::from_secs(2));
        // After the turn ends its late call is marked; the next turn's is not.
        let late = CallOwner {
            session: "session-2".into(),
            generation: 4,
        };
        let next = CallOwner {
            session: "session-2".into(),
            generation: 7,
        };
        assert!(!in_flight.after_turn(&late));
        in_flight.finish_turn("session-2", 4);
        assert!(in_flight.after_turn(&late));
        assert!(!in_flight.after_turn(&next));
    }
}
