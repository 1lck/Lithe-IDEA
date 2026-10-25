//! Listening ports on the remote, for automatic port forwarding.

use crate::platform;
use crate::session::Session;
use crate::to_value;
use lithe_remote_protocol::methods::ListeningPortsResult;
use lithe_remote_protocol::RemoteError;
use serde_json::Value;
use std::sync::Arc;

pub(crate) fn handle(_session: &Arc<Session>) -> Result<Value, RemoteError> {
    let mut ports = platform::listening_ports().map_err(|error| crate::fs::io_error(error, ""))?;
    ports.sort();
    ports.dedup();
    to_value(ListeningPortsResult { ports })
}
