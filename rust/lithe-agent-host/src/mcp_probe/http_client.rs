//! Bounded HTTP byte adapter for the official SDK's session/SSE transport.
//! Keeps the existing reqwest/TLS stack and caps JSON, errors and SSE bodies
//! before decoding; upstream's default JSON adapter reads an unbounded body.

use super::MAX_BYTES;
use futures::{stream::BoxStream, StreamExt};
use http::{HeaderName, HeaderValue};
use rmcp::{
    model::{ClientJsonRpcMessage, ServerJsonRpcMessage},
    transport::streamable_http_client::{
        StreamableHttpClient, StreamableHttpError, StreamableHttpPostResponse,
    },
};
use sse_stream::{Error as SseError, Sse, SseStream};
use std::{collections::HashMap, io, sync::Arc};

#[derive(Clone)]
pub(super) struct BoundedClient(pub reqwest::Client);
type Error = StreamableHttpError<io::Error>;
fn failed() -> Error {
    StreamableHttpError::Client(io::Error::other("MCP HTTP request failed"))
}

fn stream(response: reqwest::Response) -> BoxStream<'static, Result<bytes::Bytes, io::Error>> {
    response
        .bytes_stream()
        .scan(0_u64, |size, chunk| {
            let value = chunk.map_err(|_| io::Error::other("MCP response failed"));
            if let Ok(bytes) = &value {
                *size += bytes.len() as u64;
            }
            let value = if *size > MAX_BYTES {
                Err(io::Error::other("MCP response limit"))
            } else {
                value
            };
            futures::future::ready(Some(value))
        })
        .boxed()
}

fn request(
    client: &reqwest::Client,
    method: reqwest::Method,
    uri: &str,
    session: Option<Arc<str>>,
    auth: Option<String>,
    headers: HashMap<HeaderName, HeaderValue>,
) -> reqwest::RequestBuilder {
    let mut r = client
        .request(method, uri)
        .header("accept", "application/json, text/event-stream");
    if let Some(session) = session {
        r = r.header("mcp-session-id", session.as_ref());
    }
    if let Some(auth) = auth {
        r = r.bearer_auth(auth);
    }
    for (key, value) in headers {
        r = r.header(key, value);
    }
    r
}

impl StreamableHttpClient for BoundedClient {
    type Error = io::Error;

    async fn post_message(
        &self,
        uri: Arc<str>,
        message: ClientJsonRpcMessage,
        session: Option<Arc<str>>,
        auth: Option<String>,
        headers: HashMap<HeaderName, HeaderValue>,
    ) -> Result<StreamableHttpPostResponse, Error> {
        let encoded = serde_json::to_vec(&message).map_err(|_| failed())?;
        let response = request(
            &self.0,
            reqwest::Method::POST,
            &uri,
            session.clone(),
            auth,
            headers,
        )
        .header("content-type", "application/json")
        .body(encoded)
        .send()
        .await
        .map_err(|_| failed())?;
        let status = response.status();
        if status == reqwest::StatusCode::NOT_FOUND && session.is_some() {
            return Err(StreamableHttpError::SessionExpired);
        }
        if matches!(status.as_u16(), 202 | 204) {
            return Ok(StreamableHttpPostResponse::Accepted);
        }
        let session = response
            .headers()
            .get("mcp-session-id")
            .and_then(|v| v.to_str().ok())
            .map(str::to_owned);
        let sse = response
            .headers()
            .get("content-type")
            .and_then(|v| v.to_str().ok())
            .is_some_and(|s| s.starts_with("text/event-stream"));
        if response
            .content_length()
            .is_some_and(|size| size > MAX_BYTES)
        {
            return Err(failed());
        }
        if status.is_success() && sse {
            return Ok(StreamableHttpPostResponse::Sse(
                SseStream::from_bytes_stream(stream(response)).boxed(),
                session,
            ));
        }
        let mut bytes = Vec::new();
        let mut input = stream(response);
        while let Some(chunk) = input.next().await {
            bytes.extend_from_slice(&chunk.map_err(|_| failed())?);
        }
        if bytes.is_empty() && status.is_success() {
            return Ok(StreamableHttpPostResponse::Accepted);
        }
        // Keep valid JSON-RPC errors for SDK negotiation/fallback, but never
        // return an arbitrary HTML/auth body in a user-visible diagnostic.
        let parsed: ServerJsonRpcMessage = serde_json::from_slice(&bytes).map_err(|_| failed())?;
        Ok(StreamableHttpPostResponse::Json(parsed, session))
    }

    async fn delete_session(
        &self,
        uri: Arc<str>,
        session: Arc<str>,
        auth: Option<String>,
        headers: HashMap<HeaderName, HeaderValue>,
    ) -> Result<(), Error> {
        request(
            &self.0,
            reqwest::Method::DELETE,
            &uri,
            Some(session),
            auth,
            headers,
        )
        .send()
        .await
        .map_err(|_| failed())?;
        Ok(())
    }

    async fn get_stream(
        &self,
        uri: Arc<str>,
        session: Option<Arc<str>>,
        last: Option<String>,
        auth: Option<String>,
        headers: HashMap<HeaderName, HeaderValue>,
    ) -> Result<BoxStream<'static, Result<Sse, SseError>>, Error> {
        let mut request = request(&self.0, reqwest::Method::GET, &uri, session, auth, headers);
        if let Some(last) = last {
            request = request.header("last-event-id", last);
        }
        let response = request
            .send()
            .await
            .map_err(|_| failed())?
            .error_for_status()
            .map_err(|_| failed())?;
        Ok(SseStream::from_bytes_stream(stream(response)).boxed())
    }
}
