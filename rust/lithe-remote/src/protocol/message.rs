//! Envelope types carried inside frames.
//!
//! Requests and responses are correlated by a client-chosen `id`. Events are
//! server-initiated notifications, such as process output, and carry no id.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fmt;

/// One protocol message.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Message {
    /// Client-to-server call. `id` is unique per connection.
    Request {
        id: u64,
        method: String,
        #[serde(default)]
        params: Value,
    },
    /// Server reply to the request with the same `id`. Exactly one of
    /// `result` and `error` is present.
    Response {
        id: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        result: Option<Value>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<RemoteError>,
    },
    /// Server-initiated notification.
    Event {
        event: String,
        #[serde(default)]
        params: Value,
        /// Position in the session's event stream, increasing by one per
        /// event. Clients acknowledge it with `server.ack` and resume after
        /// it with `server.resume`, so no event is lost or repeated across a
        /// reconnection.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seq: Option<u64>,
    },
}

impl Message {
    /// Builds a successful response.
    pub fn success(id: u64, result: Value) -> Self {
        Self::Response {
            id,
            result: Some(result),
            error: None,
        }
    }

    /// Builds a failed response.
    pub fn failure(id: u64, error: RemoteError) -> Self {
        Self::Response {
            id,
            result: None,
            error: Some(error),
        }
    }
}

/// Stable failure category. Clients branch on the code; `message` is only for
/// people and may change between releases.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ErrorCode {
    /// The peers do not share a protocol version.
    ProtocolMismatch,
    /// The message was malformed, sent before `server.hello`, or had invalid
    /// parameters.
    InvalidRequest,
    /// The method name is not known to this server.
    UnknownMethod,
    /// A path argument was not an absolute remote path.
    InvalidPath,
    NotFound,
    PermissionDenied,
    AlreadyExists,
    NotADirectory,
    IsADirectory,
    /// A directory removal without `recursive` found entries.
    DirectoryNotEmpty,
    /// A guarded write found that the file changed since the client read it.
    Conflict,
    /// A requested transfer exceeds the per-call size limit.
    TooLarge,
    /// The process, terminal, watch, tunnel or walk id is unknown, or the
    /// resource already ended.
    UnknownResource,
    /// A resource with the client-chosen id already exists in the session.
    ResourceIdInUse,
    /// The program could not be started.
    SpawnFailed,
    /// A tunnel could not connect to its remote target.
    ConnectFailed,
    /// The server has too many requests in flight.
    Busy,
    /// The operation is not available on this host.
    Unsupported,
    /// Any other operating-system failure. `details` carries the OS error.
    Io,
    /// Client-side: no response arrived before the request deadline.
    Timeout,
    /// Client-side: the connection closed before a response arrived.
    Disconnected,
}

/// Failure carried in a response.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteError {
    pub code: ErrorCode,
    pub message: String,
    /// Host-specific diagnostics, such as the OS error number.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
}

impl RemoteError {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            details: None,
        }
    }

    pub fn with_details(mut self, details: Value) -> Self {
        self.details = Some(details);
        self
    }
}

impl fmt::Display for RemoteError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{:?}: {}", self.code, self.message)
    }
}

impl std::error::Error for RemoteError {}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // The JSON shape is a compatibility surface between independently
    // released client and server binaries; these literals pin it.
    #[test]
    fn envelopes_keep_their_wire_shape() {
        let request = Message::Request {
            id: 7,
            method: "fs.stat".into(),
            params: json!({"path": "/srv"}),
        };
        assert_eq!(
            serde_json::to_value(&request).unwrap(),
            json!({"type": "request", "id": 7, "method": "fs.stat", "params": {"path": "/srv"}})
        );
        let failure = Message::failure(7, RemoteError::new(ErrorCode::NotFound, "missing"));
        assert_eq!(
            serde_json::to_value(&failure).unwrap(),
            json!({"type": "response", "id": 7, "error": {"code": "NOT_FOUND", "message": "missing"}})
        );
        let event: Message =
            serde_json::from_value(json!({"type": "event", "event": "process.exit"})).unwrap();
        assert_eq!(
            event,
            Message::Event {
                event: "process.exit".into(),
                params: Value::Null,
                seq: None,
            }
        );
    }
}
