//! Bounded remote stdio for the existing plugin and language-server engine.
//! The process handle keeps its original connection; changing workspaces never
//! redirects a running backend or its cleanup to another host.

use super::process::{LspProcessHandle, LspProcessSpec, LspProcessStreams};
use crate::protocol::{cancellation, CoreError, ErrorCode};
use crate::remote::sessions::{request_error, Connection};
use crate::remote::workspace::Host;
use lithe_remote_client::session::{ClientError, Event};
use lithe_remote_protocol::methods::{self, EnvironmentSource, OutputStream, SpawnParams};
use serde_json::json;
use serde_json::Value;
use std::collections::VecDeque;
use std::io::{self, Read};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::RecvTimeoutError;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

const START_TIMEOUT: Duration = Duration::from_secs(30);
const WRITE_TIMEOUT: Duration = Duration::from_secs(5);
const CLEANUP_TIMEOUT: Duration = Duration::from_secs(2);
const POLL: Duration = Duration::from_millis(20);
const STREAM_BYTES: usize = 8 * 1024 * 1024;
const INPUT_BYTES: usize = 8 * 1024 * 1024;

/// Rewrites protocol-owned URI fields, including WorkspaceEdit map keys. Text,
/// snippets, hover contents and arbitrary plugin function values stay verbatim.
pub(crate) fn map_message(
    host: &Host,
    message: &str,
    outbound: bool,
    response_method: Option<&str>,
) -> Result<String, CoreError> {
    let mut value: Value = serde_json::from_str(message).map_err(|error| {
        CoreError::new(ErrorCode::ParseFailed, "Invalid remote backend JSON")
            .with_details(error.to_string())
    })?;
    let method = value
        .get("method")
        .and_then(Value::as_str)
        .or(response_method)
        .unwrap_or_default()
        .to_owned();
    // A JSON-RPC result has no method of its own. Its request determines
    // whether it is an LSP structure or opaque plugin-owned data.
    if method.starts_with("lithe/") {
        if outbound && method.starts_with("lithe/vcs/") {
            for pointer in ["/params/root/path", "/params/tool/executable"] {
                if let Some(value) = value.pointer_mut(pointer) {
                    if let Some(path) = value.as_str() {
                        *value = Value::String(
                            host.remote_path(std::path::Path::new(path))
                                .to_string_lossy()
                                .into_owned(),
                        );
                    }
                }
            }
        }
        return Ok(value.to_string());
    }
    if method.is_empty()
        || matches!(
            method.as_str(),
            "workspace/configuration" | "workspace/executeCommand" | "$/progress"
        )
        || !(method == "initialize"
            || method.starts_with("textDocument/")
            || method.starts_with("workspace/")
            || method.starts_with("window/")
            || method.starts_with("callHierarchy/")
            || method.starts_with("typeHierarchy/")
            || method.starts_with("completionItem/")
            || method.starts_with("codeAction/")
            || method.starts_with("codeLens/")
            || method.starts_with("documentLink/")
            || method.starts_with("inlayHint/"))
    {
        return Ok(value.to_string());
    }
    fn visit(host: &Host, value: &mut Value, outbound: bool) {
        match value {
            Value::Array(values) => {
                for value in values {
                    visit(host, value, outbound);
                }
            }
            Value::Object(object) => {
                for (key, value) in object.iter_mut() {
                    if matches!(
                        key.as_str(),
                        "uri" | "rootUri" | "targetUri" | "oldUri" | "newUri" | "documentUri"
                    ) {
                        if let Some(mapped) =
                            value.as_str().and_then(|uri| host.map_uri(uri, outbound))
                        {
                            *value = Value::String(mapped);
                        }
                    } else if key == "changes" {
                        if let Some(changes) = value.as_object_mut() {
                            let mapped = std::mem::take(changes)
                                .into_iter()
                                .map(|(uri, edits)| {
                                    (host.map_uri(&uri, outbound).unwrap_or(uri), edits)
                                })
                                .collect();
                            *changes = mapped;
                        }
                    }
                    // These fields contain user/plugin data rather than LSP structures.
                    if !matches!(
                        key.as_str(),
                        "text"
                            | "newText"
                            | "contents"
                            | "documentation"
                            | "arguments"
                            | "data"
                            | "initializationOptions"
                            | "experimental"
                            | "settings"
                            | "value"
                    ) {
                        visit(host, value, outbound);
                    }
                }
            }
            _ => {}
        }
    }
    // Error data belongs to the server; it is never an LSP location result.
    if let Some(payload) = value.get_mut("params") {
        visit(host, payload, outbound);
    }
    if let Some(payload) = value.get_mut("result") {
        visit(host, payload, outbound);
    }
    Ok(value.to_string())
}

/// One bounded byte stream. Readers wake on exit, disconnect and termination.
#[derive(Default)]
struct Pipe {
    state: Mutex<PipeState>,
    changed: Condvar,
}

#[derive(Default)]
struct PipeState {
    chunks: VecDeque<Vec<u8>>,
    bytes: usize,
    offset: usize,
    ended: bool,
    failure: Option<String>,
}

impl Pipe {
    fn push(&self, bytes: Vec<u8>) -> Result<(), CoreError> {
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        if state.ended {
            return Ok(());
        }
        if state.bytes.saturating_add(bytes.len()) > STREAM_BYTES {
            return Err(CoreError::new(
                ErrorCode::ProcessFailed,
                "Remote backend output exceeded its budget",
            ));
        }
        if !bytes.is_empty() {
            state.bytes += bytes.len();
            state.chunks.push_back(bytes);
        }
        self.changed.notify_all();
        Ok(())
    }

    fn end(&self, failure: Option<String>) {
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        state.ended = true;
        if state.failure.is_none() {
            state.failure = failure;
        }
        self.changed.notify_all();
    }
}

struct PipeReader(Arc<Pipe>);
impl Read for PipeReader {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        if buffer.is_empty() {
            return Ok(0);
        }
        let mut state = self
            .0
            .state
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        loop {
            if let Some(failure) = state.failure.take() {
                return Err(io::Error::other(failure));
            }
            if let Some(chunk) = state.chunks.front() {
                let count = buffer.len().min(chunk.len() - state.offset);
                buffer[..count].copy_from_slice(&chunk[state.offset..state.offset + count]);
                state.offset += count;
                state.bytes -= count;
                if state.offset == state.chunks.front().unwrap().len() {
                    state.chunks.pop_front();
                    state.offset = 0;
                }
                return Ok(count);
            }
            if state.ended {
                return Ok(0);
            }
            state = self
                .0
                .changed
                .wait(state)
                .unwrap_or_else(|error| error.into_inner());
        }
    }
}

/// One writer owns the host stdin. Callers only enqueue complete frames;
/// a slow network or host reader cannot block document synchronization.
#[derive(Default)]
struct Input {
    state: Mutex<InputState>,
    changed: Condvar,
}

#[derive(Default)]
struct InputState {
    frames: VecDeque<Vec<u8>>,
    /// Includes the frame currently being delivered, until its acknowledgement.
    bytes: usize,
    closed: bool,
    stopped: bool,
}

impl Input {
    fn enqueue(&self, frame: &[u8]) -> Result<(), CoreError> {
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        if state.stopped || state.closed {
            return Err(CoreError::new(
                ErrorCode::ProcessFailed,
                "Remote backend stdin is closed",
            ));
        }
        if state.bytes.saturating_add(frame.len()) > INPUT_BYTES {
            return Err(CoreError::new(
                ErrorCode::ProcessFailed,
                "Remote backend input exceeded its budget",
            ));
        }
        state.bytes += frame.len();
        state.frames.push_back(frame.to_vec());
        self.changed.notify_one();
        Ok(())
    }

    fn close(&self) {
        self.state
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .closed = true;
        self.changed.notify_one();
    }

    fn stop(&self) {
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        state.stopped = true;
        state.frames.clear();
        state.bytes = 0;
        self.changed.notify_one();
    }
}

struct RemoteProcess {
    connection: Arc<Connection>,
    id: u64,
    stdout: Arc<Pipe>,
    stderr: Arc<Pipe>,
    exit: Mutex<Option<Option<i32>>>,
    stopped: AtomicBool,
    input: Arc<Input>,
}

impl RemoteProcess {
    fn finish(&self, exit: Option<i32>, failure: Option<String>) {
        let mut state = self.exit.lock().unwrap_or_else(|error| error.into_inner());
        if state.is_none() {
            *state = Some(exit);
        }
        self.stdout.end(failure.clone());
        self.stderr.end(failure);
    }

    fn cleanup(&self) {
        if self.stopped.swap(true, Ordering::AcqRel) {
            return;
        }
        self.input.stop();
        self.connection.session.unsubscribe("process", self.id);
        let result = self.connection.session.request_value(
            methods::PROCESS_KILL,
            json!({"processId": self.id, "force": true}),
            CLEANUP_TIMEOUT,
        );
        if let Err(error) = result {
            if !matches!(&error, ClientError::Remote(remote) if remote.code == lithe_remote_protocol::ErrorCode::UnknownResource)
                && !self.connection.session.is_closed()
            {
                eprintln!("remote backend cleanup failed: {error}");
            }
        }
        self.finish(None, None);
    }

    fn event(&self, event: Event) -> Result<bool, CoreError> {
        if event.resource() != Some(("process", self.id)) {
            return Err(CoreError::new(
                ErrorCode::ParseFailed,
                "Remote backend identity changed",
            ));
        }
        match event.event.as_str() {
            methods::EVENT_PROCESS_OUTPUT => {
                let output: methods::ProcessOutputEvent =
                    event.decode().map_err(|error| request_error("", error))?;
                let bytes = methods::decode_bytes(&output.data).map_err(|_| {
                    CoreError::new(ErrorCode::ParseFailed, "Invalid remote backend bytes")
                })?;
                let pipe = if output.stream == OutputStream::Stdout {
                    &self.stdout
                } else {
                    &self.stderr
                };
                pipe.push(bytes)?;
                Ok(false)
            }
            methods::EVENT_PROCESS_EXIT => {
                let exit: methods::ProcessExitEvent =
                    event.decode().map_err(|error| request_error("", error))?;
                self.finish(exit.exit_code, None);
                Ok(true)
            }
            _ => Err(CoreError::new(
                ErrorCode::ParseFailed,
                "Invalid remote backend event",
            )),
        }
    }
}

impl Drop for RemoteProcess {
    fn drop(&mut self) {
        self.cleanup();
    }
}

impl RemoteProcess {
    fn deliver_input(&self, frame: &[u8]) -> Result<(), CoreError> {
        let deadline = Instant::now() + WRITE_TIMEOUT;
        for chunk in frame.chunks(32 * 1024) {
            loop {
                if self.stopped.load(Ordering::Acquire) {
                    return Err(CoreError::new(
                        ErrorCode::ProcessFailed,
                        "Remote backend stdin is closed",
                    ));
                }
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    return Err(CoreError::new(
                        ErrorCode::TimedOut,
                        "Remote backend stdin timed out",
                    ));
                }
                let pending = self
                    .connection
                    .session
                    .begin_request_value(
                        methods::PROCESS_WRITE_STDIN,
                        json!({"processId": self.id, "data": methods::encode_bytes(chunk)}),
                        remaining,
                    )
                    .map_err(|error| request_error("", error))?;
                let outcome = loop {
                    if self.stopped.load(Ordering::Acquire) {
                        return Err(CoreError::new(
                            ErrorCode::ProcessFailed,
                            "Remote backend stopped",
                        ));
                    }
                    match pending.poll(POLL) {
                        Ok(None) => {}
                        result => break result,
                    }
                };
                match outcome {
                    Ok(_) => break,
                    Err(ClientError::Remote(error))
                        if error.code == lithe_remote_protocol::ErrorCode::Busy =>
                    {
                        // A full host stdin queue retries only within this frame's deadline.
                        std::thread::park_timeout(
                            POLL.min(deadline.saturating_duration_since(Instant::now())),
                        );
                    }
                    Err(error) => return Err(request_error("", error)),
                }
            }
        }
        Ok(())
    }
}

impl LspProcessHandle for RemoteProcess {
    // A remote pid must never enter the local process registry.
    fn write_input(&self, frame: &[u8]) -> Result<(), CoreError> {
        self.input.enqueue(frame)
    }
    fn close_input(&self) {
        self.input.close();
    }
    fn exit_status(&self) -> Option<Option<i32>> {
        *self.exit.lock().unwrap_or_else(|error| error.into_inner())
    }
    fn terminate(&self) {
        self.cleanup();
    }
}

pub(super) fn launch(host: Host, spec: LspProcessSpec) -> Result<LspProcessStreams, CoreError> {
    let connection = host.connection.clone();
    let id = connection.session.allocate_id();
    let events = connection.session.subscribe("process", id);
    let process = Arc::new(RemoteProcess {
        connection,
        id,
        stdout: Arc::default(),
        stderr: Arc::default(),
        exit: Mutex::new(None),
        stopped: AtomicBool::new(false),
        input: Arc::default(),
    });
    let parameters = SpawnParams {
        process_id: id,
        argv: std::iter::once(
            host.remote_path(&spec.executable)
                .to_string_lossy()
                .into_owned(),
        )
        .chain(spec.arguments)
        .collect(),
        cwd: Some(
            host.remote_path(&spec.working_directory)
                .to_string_lossy()
                .into_owned(),
        ),
        environment: EnvironmentSource::Login,
        env: spec.environment,
        pipe_stdin: true,
    };
    let pending = process
        .connection
        .session
        .begin_request_value(
            methods::PROCESS_SPAWN,
            serde_json::to_value(parameters).expect("backend spawn parameters encode"),
            START_TIMEOUT,
        )
        .map_err(|error| request_error("", error))?;
    loop {
        cancellation::check()?;
        while let Ok(event) = events.try_recv() {
            process.event(event)?;
        }
        if pending
            .poll(POLL)
            .map_err(|error| request_error("", error))?
            .is_some()
        {
            break;
        }
    }
    let input = process.input.clone();
    let writer = Arc::downgrade(&process);
    std::thread::Builder::new()
        .name("remote-plugin-stdin".into())
        .spawn(move || loop {
            let frame = {
                let mut state = input
                    .state
                    .lock()
                    .unwrap_or_else(|error| error.into_inner());
                loop {
                    if state.stopped {
                        return;
                    }
                    if let Some(frame) = state.frames.pop_front() {
                        break Some(frame);
                    }
                    if state.closed {
                        break None;
                    }
                    state = input
                        .changed
                        .wait(state)
                        .unwrap_or_else(|error| error.into_inner());
                }
            };
            let Some(process) = writer.upgrade() else {
                return;
            };
            let outcome = match &frame {
                Some(frame) => process.deliver_input(frame),
                None => process
                    .connection
                    .session
                    .request_value(
                        methods::PROCESS_CLOSE_STDIN,
                        json!({"processId": process.id}),
                        CLEANUP_TIMEOUT,
                    )
                    .map(|_| ())
                    .map_err(|error| request_error("", error)),
            };
            if let Err(error) = outcome {
                process.finish(None, Some(error.message));
                process.cleanup();
                return;
            }
            if let Some(frame) = frame {
                let mut state = input
                    .state
                    .lock()
                    .unwrap_or_else(|error| error.into_inner());
                state.bytes = state.bytes.saturating_sub(frame.len());
            } else {
                return;
            }
        })
        .map_err(|error| {
            CoreError::new(
                ErrorCode::ProcessStartFailed,
                "Could not own remote backend input",
            )
            .with_details(error.to_string())
        })?;
    // The worker owns no strong handle while idle. Dropping the engine handle
    // closes its subscription, wakes both readers and ends the remote tree.
    let weak = Arc::downgrade(&process);
    std::thread::Builder::new()
        .name("remote-plugin-stdio".into())
        .spawn(move || loop {
            let Some(process) = weak.upgrade() else {
                break;
            };
            if process.stopped.load(Ordering::Acquire) {
                break;
            }
            let result = match events.recv_timeout(POLL) {
                Ok(event) => process.event(event),
                Err(RecvTimeoutError::Timeout) if !process.connection.session.is_closed() => {
                    continue
                }
                Err(_) => Err(CoreError::new(
                    ErrorCode::ProcessFailed,
                    "Remote backend disconnected",
                )),
            };
            match result {
                Ok(false) => {}
                Ok(true) => {
                    process.cleanup();
                    break;
                }
                Err(error) => {
                    process.finish(None, Some(error.message));
                    process.cleanup();
                    break;
                }
            }
        })
        .map_err(|error| {
            CoreError::new(
                ErrorCode::ProcessStartFailed,
                "Could not own remote backend output",
            )
            .with_details(error.to_string())
        })?;
    Ok(LspProcessStreams {
        output: Box::new(PipeReader(process.stdout.clone())),
        errors: Box::new(PipeReader(process.stderr.clone())),
        handle: process,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn input_preserves_frames_and_counts_in_flight_bytes_until_acknowledged() {
        let input = Input::default();
        input.enqueue(b"first").unwrap();
        input.enqueue(b"second").unwrap();
        input.close();
        assert!(input.enqueue(b"late").is_err());
        let mut state = input.state.lock().unwrap();
        assert_eq!(state.frames.pop_front().unwrap(), b"first");
        assert_eq!(state.frames.pop_front().unwrap(), b"second");
        assert_eq!(
            state.bytes, 11,
            "dequeued data remains budgeted during delivery"
        );
        assert!(state.closed);
        drop(state);
        input.stop();
        assert_eq!(input.state.lock().unwrap().bytes, 0);
        assert!(input.enqueue(b"stopped").is_err());
    }

    #[test]
    fn input_overflow_rejects_a_whole_frame_without_discarding_prior_data() {
        let input = Input::default();
        input.enqueue(&vec![b'x'; INPUT_BYTES]).unwrap();
        assert!(input.enqueue(b"overflow").is_err());
        let state = input.state.lock().unwrap();
        assert_eq!(state.frames.len(), 1);
        assert_eq!(state.bytes, INPUT_BYTES);
    }

    #[test]
    fn output_partial_reads_preserve_order_and_terminal_failures_reach_readers() {
        let pipe = Arc::new(Pipe::default());
        pipe.push(b"ab".to_vec()).unwrap();
        pipe.push(b"cd".to_vec()).unwrap();
        pipe.end(None);
        let mut reader = PipeReader(pipe.clone());
        let mut byte = [0];
        reader.read_exact(&mut byte).unwrap();
        assert_eq!(byte, *b"a");
        let mut rest = Vec::new();
        reader.read_to_end(&mut rest).unwrap();
        assert_eq!(rest, b"bcd");
        assert_eq!(pipe.state.lock().unwrap().bytes, 0);
        pipe.end(Some("connection closed".into()));
        assert_eq!(
            reader.read(&mut byte).unwrap_err().to_string(),
            "connection closed"
        );
    }

    #[test]
    fn output_budget_failure_does_not_accept_excess_bytes() {
        let pipe = Pipe::default();
        pipe.push(vec![0; STREAM_BYTES]).unwrap();
        assert!(pipe.push(vec![0]).is_err());
        assert_eq!(pipe.state.lock().unwrap().bytes, STREAM_BYTES);
    }
}
