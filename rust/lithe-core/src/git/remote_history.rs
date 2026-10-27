//! Incremental Git history on the workspace host, without local reader threads.

use crate::protocol::{cancellation, CoreError, ErrorCode};
use crate::remote::workspace::{self, Host};
use lithe_remote_client::session::Event;
use lithe_remote_protocol::methods::{self, OutputStream};
use serde_json::json;
use std::collections::VecDeque;
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::time::{Duration, Instant};

const POLL: Duration = Duration::from_millis(10);
const MAX_PENDING_BYTES: usize = 8 * 1024 * 1024;
const MAX_LINE_BYTES: usize = 1024 * 1024;
const MAX_STDERR_BYTES: usize = 64 * 1024;

/// A cursor owns both its remote process and subscription across page requests.
pub(super) struct RemoteHistory {
    host: Host,
    id: u64,
    events: Option<Receiver<Event>>,
    early: VecDeque<Event>,
    line: Vec<u8>,
    output: VecDeque<u8>,
    stderr: Vec<u8>,
    exited: bool,
}

impl RemoteHistory {
    /// Starts the same Git log argv on the selected host, never a local fallback.
    pub(super) fn start(root: &str, arguments: &[String]) -> Result<Option<Self>, CoreError> {
        let Some(host) = workspace::current() else {
            return Ok(None);
        };
        let params = super::remote_process::parameters(&host, root, arguments, false, true, &[])?;
        let id = host.connection.session.allocate_id();
        let events = host.connection.session.subscribe("process", id);
        let mut stream = Self {
            host,
            id,
            events: Some(events),
            early: VecDeque::new(),
            line: Vec::new(),
            output: VecDeque::new(),
            stderr: Vec::new(),
            exited: false,
        };
        let mut params = serde_json::to_value(params).expect("spawn parameters encode");
        params["processId"] = json!(id);
        let pending = stream
            .host
            .connection
            .session
            .begin_request_value(methods::PROCESS_SPAWN, params, Duration::from_secs(30))
            .map_err(failure)?;
        let mut bytes = 0usize;
        loop {
            cancellation::check()?;
            if pending.poll(POLL).map_err(failure)?.is_some() {
                break;
            }
            // Drain early output so a full subscriber cannot hide the spawn reply.
            while let Ok(event) = stream.events.as_ref().expect("subscribed").try_recv() {
                bytes = bytes.saturating_add(event.params.to_string().len());
                if bytes > MAX_PENDING_BYTES {
                    return Err(CoreError::new(
                        ErrorCode::ProcessFailed,
                        "Remote Git startup output exceeded its limit",
                    ));
                }
                stream.early.push_back(event);
            }
        }
        Ok(Some(stream))
    }

    /// Reads one complete UTF-8 log record within the owning page's deadline.
    pub(super) fn next_line(&mut self, deadline: Instant) -> Result<Option<String>, CoreError> {
        loop {
            cancellation::check()?;
            if Instant::now() >= deadline {
                return Err(CoreError::new(
                    ErrorCode::TimedOut,
                    "Remote Git history page timed out",
                ));
            }
            while let Some(byte) = self.output.pop_front() {
                if byte == b'\n' {
                    return self.take_line().map(Some);
                }
                self.line.push(byte);
                if self.line.len() > MAX_LINE_BYTES {
                    return Err(CoreError::new(
                        ErrorCode::ProcessFailed,
                        "Git history record exceeded its limit",
                    ));
                }
            }
            if self.exited {
                return if self.line.is_empty() {
                    Ok(None)
                } else {
                    self.take_line().map(Some)
                };
            }
            let event = if let Some(event) = self.early.pop_front() {
                event
            } else {
                match self.events.as_ref().expect("subscribed").recv_timeout(POLL) {
                    Ok(event) => event,
                    Err(RecvTimeoutError::Timeout) if !self.host.connection.session.is_closed() => {
                        continue
                    }
                    Err(_) => {
                        return Err(CoreError::new(
                            ErrorCode::ConnectionClosed,
                            "Remote Git history connection closed",
                        ))
                    }
                }
            };
            match event.event.as_str() {
                methods::EVENT_PROCESS_OUTPUT => {
                    let output: methods::ProcessOutputEvent = event.decode().map_err(failure)?;
                    let bytes = methods::decode_bytes(&output.data).map_err(|error| {
                        CoreError::new(ErrorCode::ParseFailed, "Invalid remote Git history bytes")
                            .with_details(error.to_string())
                    })?;
                    if output.process_id != self.id
                        || bytes.len() > methods::MAX_TRANSFER_BYTES as usize
                    {
                        return Err(CoreError::new(
                            ErrorCode::ParseFailed,
                            "Invalid remote Git history output",
                        ));
                    }
                    if output.stream == OutputStream::Stdout {
                        self.output.extend(bytes);
                    } else {
                        let remaining = MAX_STDERR_BYTES.saturating_sub(self.stderr.len());
                        self.stderr
                            .extend_from_slice(&bytes[..bytes.len().min(remaining)]);
                    }
                }
                methods::EVENT_PROCESS_EXIT => {
                    let exit: methods::ProcessExitEvent = event.decode().map_err(failure)?;
                    if exit.process_id != self.id
                        || exit.exit_code != Some(0)
                        || exit.signal.is_some()
                    {
                        return Err(
                            CoreError::new(ErrorCode::ProcessFailed, "Git history failed")
                                .with_details(
                                    String::from_utf8_lossy(&self.stderr).trim().to_owned(),
                                ),
                        );
                    }
                    self.exited = true;
                }
                _ => {
                    return Err(CoreError::new(
                        ErrorCode::ParseFailed,
                        "Unexpected remote Git history event",
                    ))
                }
            }
        }
    }

    fn take_line(&mut self) -> Result<String, CoreError> {
        if self.line.last() == Some(&b'\r') {
            self.line.pop();
        }
        String::from_utf8(std::mem::take(&mut self.line)).map_err(|error| {
            CoreError::new(ErrorCode::ParseFailed, "Git history is not UTF-8")
                .with_details(error.to_string())
        })
    }
}

impl Drop for RemoteHistory {
    fn drop(&mut self) {
        self.events.take();
        self.host.connection.session.unsubscribe("process", self.id);
        let _ = self.host.connection.session.request_value(
            methods::PROCESS_KILL,
            json!({"processId": self.id, "force": true}),
            Duration::from_secs(2),
        );
    }
}

fn failure(error: lithe_remote_client::session::ClientError) -> CoreError {
    CoreError::new(ErrorCode::ProcessFailed, "Remote Git history failed")
        .with_details(error.to_string())
}
