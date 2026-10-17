//! Transparent WebSocket forwarding with bounded, passive frame observation.
//!
//! Hyper/reqwest own the upgraded transport and tungstenite owns frame parsing.
//! Original frames, compression, ping/pong, close messages and headers pass
//! unchanged. Malformed or oversized observations disable only statistics.
//! Only section sizes and one response identifier survive a decoded message.

use std::collections::{BTreeMap, VecDeque};
use std::io::{self, Read};
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use std::time::Instant;

use bytes::Bytes;
use flate2::{Decompress, FlushDecompress};
use http_body_util::{BodyExt, Full, StreamBody};
use hyper::body::{Frame as HttpFrame, Incoming};
use hyper::{Request, Response, StatusCode};
use serde_json::Value;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tungstenite::protocol::frame::coding::{Data, OpCode};
use tungstenite::protocol::frame::FrameSocket;

use super::{failure, is_hop_header, ProxyBody, State, CONNECT_TIMEOUT, OBSERVED_REQUEST_BYTES};
use crate::model_calls::{self, ModelApi, RequestShape, ResponseObserver};

/// Output indexes are retained as sizes, never as response bodies.
const MAX_OUTPUT_ITEMS: usize = 1024;
const MAX_RESPONSE_ID_BYTES: usize = 256;

pub(super) fn is_upgrade(request: &Request<Incoming>) -> bool {
    request.method() == hyper::Method::GET
        && request
            .headers()
            .get(hyper::header::UPGRADE)
            .and_then(|value| value.to_str().ok())
            .is_some_and(|value| value.eq_ignore_ascii_case("websocket"))
}

pub(super) async fn forward(
    mut request: Request<Incoming>,
    url: &str,
    state: Arc<State>,
    observed: bool,
) -> Response<ProxyBody> {
    let mut headers = super::forwarded_headers(request.headers(), false);
    headers.insert(
        hyper::header::CONNECTION,
        hyper::header::HeaderValue::from_static("Upgrade"),
    );
    headers.insert(
        hyper::header::UPGRADE,
        hyper::header::HeaderValue::from_static("websocket"),
    );
    let upstream = tokio::time::timeout(
        CONNECT_TIMEOUT,
        state.client.get(url).headers(headers).send(),
    )
    .await;
    let Ok(Ok(upstream)) = upstream else {
        return failure(
            StatusCode::BAD_GATEWAY,
            "Could not connect to the model WebSocket",
        );
    };
    let status = upstream.status();
    let mut response = Response::builder().status(status);
    if let Some(headers) = response.headers_mut() {
        for (name, value) in upstream.headers() {
            if !is_hop_header(name) {
                let rewritten = (name == hyper::header::LOCATION)
                    .then(|| {
                        value.to_str().ok().and_then(|location| {
                            state.rewrite_location(location, &url::Url::parse(url).ok()?)
                        })
                    })
                    .flatten()
                    .and_then(|location| hyper::header::HeaderValue::from_str(&location).ok());
                headers.append(name.clone(), rewritten.unwrap_or_else(|| value.clone()));
            }
        }
    }
    if status != StatusCode::SWITCHING_PROTOCOLS {
        // Native Codex still receives auth failures, redirects and rate limits
        // with their original bodies, so it owns refresh and retry decisions.
        let body = upstream.bytes_stream();
        return response
            .body(BodyExt::boxed_unsync(StreamBody::new(
                futures::StreamExt::map(body, |chunk| {
                    chunk.map(HttpFrame::data).map_err(|error| {
                        Box::new(error) as Box<dyn std::error::Error + Send + Sync>
                    })
                }),
            )))
            .unwrap_or_else(|_| {
                failure(
                    StatusCode::BAD_GATEWAY,
                    "Could not forward the WebSocket response",
                )
            });
    }
    if let Some(headers) = response.headers_mut() {
        headers.insert(
            hyper::header::CONNECTION,
            hyper::header::HeaderValue::from_static("Upgrade"),
        );
        headers.insert(
            hyper::header::UPGRADE,
            hyper::header::HeaderValue::from_static("websocket"),
        );
    }
    let extensions = upstream
        .headers()
        .get("sec-websocket-extensions")
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default()
        .to_owned();
    let downstream = hyper::upgrade::on(&mut request);
    let connections = state.connections.upgrade();
    if let Some(connections) = connections {
        if let Ok(mut connections) = connections.lock() {
            while connections.try_join_next().is_some() {}
            connections.spawn(async move {
                let Ok(Ok((downstream, upstream))) = tokio::time::timeout(CONNECT_TIMEOUT, async {
                    tokio::try_join!(async { downstream.await.map_err(|_| ()) }, async {
                        upstream.upgrade().await.map_err(|_| ())
                    })
                })
                .await
                else {
                    return;
                };
                let mut observation = Observation::new(state, &extensions);
                if !observed {
                    observation.disable(Instant::now());
                }
                let observation = Arc::new(Mutex::new(observation));
                let mut downstream = ObservedIo {
                    inner: hyper_util::rt::TokioIo::new(downstream),
                    from_client: true,
                    observation: observation.clone(),
                };
                let mut upstream = ObservedIo {
                    inner: upstream,
                    from_client: false,
                    observation,
                };
                // No model-turn deadline. The connection owner aborts this
                // task on shutdown; copy_bidirectional preserves half-closes.
                let _ = tokio::io::copy_bidirectional(&mut downstream, &mut upstream).await;
            });
        }
    }
    response
        .body(
            Full::new(Bytes::new())
                .map_err(|never| match never {})
                .boxed_unsync(),
        )
        .unwrap_or_else(|_| {
            failure(
                StatusCode::BAD_GATEWAY,
                "Could not forward the WebSocket upgrade",
            )
        })
}

/// Tee only successful reads. Observation never changes bytes or I/O errors.
struct ObservedIo<T> {
    inner: T,
    from_client: bool,
    observation: Arc<Mutex<Observation>>,
}

impl<T: AsyncRead + Unpin> AsyncRead for ObservedIo<T> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buffer: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let before = buffer.filled().len();
        let result = Pin::new(&mut self.inner).poll_read(cx, buffer);
        if matches!(result, Poll::Ready(Ok(()))) {
            if let Ok(mut observation) = self.observation.lock() {
                observation.feed(self.from_client, &buffer.filled()[before..], Instant::now());
            }
        }
        result
    }
}

impl<T: AsyncWrite + Unpin> AsyncWrite for ObservedIo<T> {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.inner).poll_write(cx, bytes)
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(cx)
    }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

#[derive(Default, Debug)]
struct QueuedBytes(VecDeque<Bytes>);

impl Read for QueuedBytes {
    fn read(&mut self, target: &mut [u8]) -> io::Result<usize> {
        let Some(front) = self.0.front_mut() else {
            return Err(io::ErrorKind::WouldBlock.into());
        };
        let count = target.len().min(front.len());
        target[..count].copy_from_slice(&front[..count]);
        *front = front.slice(count..);
        if front.is_empty() {
            self.0.pop_front();
        }
        Ok(count)
    }
}

/// RFC 7692 permessage-deflate is decoded only on a copy. The negotiated
/// dictionary lifetime is independent in each direction.
struct Decoder {
    frames: FrameSocket<QueuedBytes>,
    message: Option<(bool, Vec<u8>)>,
    inflate: Option<Decompress>,
    reset_dictionary: bool,
}

impl Decoder {
    fn new(extensions: &str, from_client: bool) -> Self {
        let deflate = extensions
            .split(',')
            .find(|value| value.trim().starts_with("permessage-deflate"));
        let reset = if from_client {
            "client_no_context_takeover"
        } else {
            "server_no_context_takeover"
        };
        Self {
            frames: FrameSocket::new(QueuedBytes::default()),
            message: None,
            inflate: deflate.map(|_| Decompress::new(false)),
            reset_dictionary: deflate
                .is_some_and(|value| value.split(';').any(|part| part.trim() == reset)),
        }
    }

    fn push(&mut self, bytes: &[u8]) {
        if !bytes.is_empty() {
            self.frames
                .get_mut()
                .0
                .push_back(Bytes::copy_from_slice(bytes));
        }
    }

    fn next(&mut self) -> Result<Option<Vec<u8>>, ()> {
        loop {
            let frame = match self.frames.read(Some(OBSERVED_REQUEST_BYTES)) {
                Ok(Some(frame)) => frame,
                Ok(None) => return Ok(None),
                Err(tungstenite::Error::Io(error)) if error.kind() == io::ErrorKind::WouldBlock => {
                    return Ok(None)
                }
                Err(_) => return Err(()),
            };
            let header = frame.header().clone();
            if header.rsv2 || header.rsv3 {
                return Err(());
            }
            match header.opcode {
                OpCode::Control(_) => continue,
                OpCode::Data(Data::Text | Data::Binary) if self.message.is_none() => {
                    if header.rsv1 && self.inflate.is_none() {
                        return Err(());
                    }
                    self.message = Some((header.rsv1, Vec::new()));
                }
                OpCode::Data(Data::Continue) if self.message.is_some() && !header.rsv1 => {}
                _ => return Err(()),
            }
            let (_, message) = self.message.as_mut().ok_or(())?;
            if message.len().saturating_add(frame.payload().len()) > OBSERVED_REQUEST_BYTES {
                return Err(());
            }
            let mut payload = frame.into_payload().to_vec();
            if let Some(mask) = header.mask {
                // FrameSocket parses framing without modifying the copied payload.
                for (index, byte) in payload.iter_mut().enumerate() {
                    *byte ^= mask[index % 4];
                }
            }
            message.extend(payload);
            if !header.is_final {
                continue;
            }
            let (compressed, message) = self.message.take().ok_or(())?;
            return if compressed {
                self.decompress(message).map(Some)
            } else {
                Ok(Some(message))
            };
        }
    }

    fn decompress(&mut self, mut input: Vec<u8>) -> Result<Vec<u8>, ()> {
        // RFC 7692 removes the sync-flush tail from each compressed message.
        input.extend([0, 0, 255, 255]);
        let inflate = self.inflate.as_mut().ok_or(())?;
        let mut output = Vec::new();
        let mut position = 0;
        loop {
            let mut buffer = [0u8; 8192];
            let before_in = inflate.total_in();
            let before_out = inflate.total_out();
            inflate
                .decompress(&input[position..], &mut buffer, FlushDecompress::Sync)
                .map_err(|_| ())?;
            let consumed = (inflate.total_in() - before_in) as usize;
            let produced = (inflate.total_out() - before_out) as usize;
            if output.len().saturating_add(produced) > OBSERVED_REQUEST_BYTES {
                return Err(());
            }
            output.extend_from_slice(&buffer[..produced]);
            position += consumed;
            if position == input.len() && produced < buffer.len() {
                break;
            }
            if consumed == 0 && produced == 0 {
                return Err(());
            }
        }
        if self.reset_dictionary {
            *inflate = Decompress::new(false);
        }
        Ok(output)
    }
}

struct Pending {
    observer: Option<ResponseObserver>,
    owner: Option<super::CallOwner>,
    shape: Option<RequestShape>,
    response_id: Option<String>,
    outputs: BTreeMap<u64, RequestShape>,
    outputs_valid: bool,
}

struct Previous {
    id: String,
    shape: RequestShape,
    output: RequestShape,
}

struct Observation {
    state: Arc<State>,
    client: Option<Decoder>,
    server: Option<Decoder>,
    pending: Option<Pending>,
    previous: Option<Previous>,
}

impl Observation {
    fn new(state: Arc<State>, extensions: &str) -> Self {
        Self {
            state,
            client: Some(Decoder::new(extensions, true)),
            server: Some(Decoder::new(extensions, false)),
            pending: None,
            previous: None,
        }
    }

    fn feed(&mut self, from_client: bool, bytes: &[u8], now: Instant) {
        let decoder = if from_client {
            &mut self.client
        } else {
            &mut self.server
        };
        let Some(decoder) = decoder else {
            return;
        };
        decoder.push(bytes);
        loop {
            let decoder = if from_client {
                &mut self.client
            } else {
                &mut self.server
            };
            let message = decoder.as_mut().ok_or(()).and_then(Decoder::next);
            match message {
                Ok(Some(message)) => {
                    if let Ok(value) = serde_json::from_slice::<Value>(&message) {
                        if from_client {
                            self.request(&value, &message, now);
                        } else {
                            self.response(&value, now);
                        }
                    } else {
                        self.disable(now);
                    }
                }
                Ok(None) => break,
                Err(_) => {
                    self.disable(now);
                    break;
                }
            }
        }
    }

    fn disable(&mut self, now: Instant) {
        self.client = None;
        self.server = None;
        self.previous = None;
        if let Some(pending) = &mut self.pending {
            pending.shape = None;
        }
        self.finish(now);
    }

    fn request(&mut self, value: &Value, bytes: &[u8], now: Instant) {
        if value["type"] != "response.create" {
            return;
        }
        if self.pending.is_some() {
            // Codex has one inference per socket. Unknown multiplexing cannot
            // be attributed safely, but its original frames still pass through.
            self.disable(now);
            return;
        }
        let mut shape = model_calls::request_shape(ModelApi::Responses, bytes);
        if let Some(previous_id) = value["previous_response_id"].as_str() {
            shape = match (&self.previous, shape) {
                (Some(previous), Some(mut shape)) if previous.id == previous_id => {
                    shape.continue_responses(
                        &previous.shape,
                        &previous.output,
                        value.get("instructions").is_none(),
                        value.get("tools").is_none(),
                    );
                    Some(shape)
                }
                _ => None,
            };
        }
        let warmup = value["generate"] == false;
        let owner = (!warmup).then(|| (self.state.session)()).flatten();
        if let Some(owner) = &owner {
            self.state.in_flight.begin(&owner.session);
        }
        self.pending = Some(Pending {
            observer: (!warmup).then(|| ResponseObserver::new(ModelApi::Responses, 200, true, now)),
            owner,
            shape,
            response_id: None,
            outputs: BTreeMap::new(),
            outputs_valid: true,
        });
    }

    fn response(&mut self, value: &Value, now: Instant) {
        let Some(pending) = &mut self.pending else {
            return;
        };
        let response_id = value["response"]["id"]
            .as_str()
            .or_else(|| value["response_id"].as_str());
        if let Some(id) = response_id {
            if pending
                .response_id
                .as_deref()
                .is_some_and(|current| current != id)
            {
                return;
            }
            if self
                .previous
                .as_ref()
                .is_some_and(|previous| previous.id == id)
            {
                return;
            }
            if pending.response_id.is_none() {
                if id.len() > MAX_RESPONSE_ID_BYTES {
                    self.disable(now);
                    return;
                }
                pending.response_id = Some(id.to_owned());
            }
        }
        if let Some(observer) = &mut pending.observer {
            observer.event(value, now);
        }
        let kind = value["type"].as_str().unwrap_or_default();
        if kind == "response.output_item.done" {
            if let Some(index) = value["output_index"].as_u64() {
                if pending.outputs.len() < MAX_OUTPUT_ITEMS || pending.outputs.contains_key(&index)
                {
                    pending
                        .outputs
                        .insert(index, RequestShape::response_item(&value["item"]));
                } else {
                    pending.outputs_valid = false;
                }
            } else {
                pending.outputs_valid = false;
            }
        }
        if kind == "response.completed" {
            let output =
                RequestShape::response_output(&value["response"]["output"]).or_else(|| {
                    (pending.outputs_valid
                        && (!pending.outputs.is_empty() || pending.observer.is_none()))
                    .then(|| RequestShape::sum_outputs(pending.outputs.values()))
                });
            self.previous = match (&pending.response_id, &pending.shape, output) {
                (Some(id), Some(shape), Some(output)) => Some(Previous {
                    id: id.clone(),
                    shape: shape.clone(),
                    output,
                }),
                _ => None,
            };
            self.finish(now);
        } else if matches!(kind, "response.incomplete" | "response.failed" | "error") {
            self.finish(now);
        }
    }

    fn finish(&mut self, now: Instant) {
        if let Some(pending) = self.pending.take() {
            if let Some(observer) = pending.observer {
                self.state
                    .report(pending.owner, observer.finish(pending.shape.as_ref(), now));
            }
        }
    }
}

impl Drop for Observation {
    fn drop(&mut self) {
        self.finish(Instant::now());
    }
}

#[cfg(test)]
mod tests;
