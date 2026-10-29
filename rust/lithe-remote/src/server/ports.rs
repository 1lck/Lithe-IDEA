//! Listening ports on the remote, for automatic port forwarding.

use crate::protocol::methods::ListeningPortsResult;
use crate::protocol::RemoteError;
use crate::server::platform;
use crate::server::session::Session;
use crate::server::to_value;
use serde_json::Value;
use std::sync::Arc;

pub(crate) fn handle(_session: &Arc<Session>) -> Result<Value, RemoteError> {
    let mut ports =
        platform::listening_ports().map_err(|error| crate::server::fs::io_error(error, ""))?;
    ports.sort();
    ports.dedup();
    to_value(ListeningPortsResult { ports })
}
