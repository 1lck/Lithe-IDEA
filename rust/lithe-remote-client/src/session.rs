//! A connected remote server.
//!
//! One reader thread owns the incoming stream. It routes each response to the
//! request waiting for it and forwards events to a bounded channel. Callers
//! must drain that channel: when it is full the reader stops, and with it the
//! server's output, which is the intended backpressure for chatty processes.

use crate::transport::{TransportChain, TransportError};
use lithe_remote_protocol::frame::{read_frame, skip_preamble, write_frame};
use lithe_remote_protocol::methods::{self, HelloParams, HelloResult};
use lithe_remote_protocol::{FrameError, Message, RemoteError, PROTOCOL_VERSION};
use serde::de::DeserializeOwned;
use serde::Serialize;
use serde_json::Value;
use std::collections::{HashMap, VecDeque};
use std::fmt;
use std::io::{self, BufReader, Read, Write};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

/// Events buffered before the reader blocks.
const EVENT_CAPACITY: usize = 1024;

/// Bytes accepted before the preamble, for example a login banner.
const PREAMBLE_NOISE_LIMIT: usize = 64 * 1024;

/// Tail of the transport's standard error kept for diagnostics.
const STDERR_TAIL_BYTES: usize = 8 * 1024;

/// Time the server gets to exit after `server.shutdown` before it is killed.
const SHUTDOWN_GRACE: Duration = Duration::from_secs(2);
const EXIT_POLL_INTERVAL: Duration = Duration::from_millis(20);

/// Server-initiated notification.
#[derive(Clone, Debug, PartialEq)]
pub struct Event {
    pub event: String,
    pub params: Value,
}

#[derive(Debug)]
pub enum ClientError {
    /// The server answered with an error.
    Remote(RemoteError),
    Transport(TransportError),
    /// The transport command could not be started.
    Spawn(io::Error),
    /// The stream ended or broke. `diagnostics` holds the transport's last
    /// standard-error output, which names SSH or container failures.
    Disconnected {
        diagnostics: String,
    },
    /// No response arrived in time. A late response is discarded.
    Timeout,
    /// The peer sent something that is not this protocol.
    Protocol(String),
}

impl fmt::Display for ClientError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Remote(error) => error.fmt(formatter),
            Self::Transport(error) => error.fmt(formatter),
            Self::Spawn(error) => write!(formatter, "cannot start the connection: {error}"),
            Self::Disconnected { diagnostics } if diagnostics.is_empty() => {
                formatter.write_str("the remote connection closed")
            }
            Self::Disconnected { diagnostics } => {
                write!(formatter, "the remote connection closed: {diagnostics}")
            }
            Self::Timeout => formatter.write_str("the remote server did not answer in time"),
            Self::Protocol(message) => write!(formatter, "remote protocol error: {message}"),
        }
    }
}

impl std::error::Error for ClientError {}

type Reply = Result<Value, ClientError>;

#[derive(Default)]
struct Pending {
    /// Set once the stream ended; new requests fail immediately.
    closed: bool,
    waiting: HashMap<u64, SyncSender<Reply>>,
}

/// Options for establishing a session.
#[derive(Clone, Debug)]
pub struct ConnectOptions {
    pub client_name: String,
    /// Bounds transport start-up, the preamble and `server.hello` together.
    pub handshake_timeout: Duration,
}

impl Default for ConnectOptions {
    fn default() -> Self {
        Self {
            client_name: "lithe".into(),
            handshake_timeout: Duration::from_secs(30),
        }
    }
}

pub struct RemoteSession {
    writer: Mutex<Option<Box<dyn Write + Send>>>,
    pending: Arc<Mutex<Pending>>,
    next_id: AtomicU64,
    child: Mutex<Option<Child>>,
    stderr_tail: Arc<Mutex<VecDeque<u8>>>,
    hello: Option<HelloResult>,
}

impl RemoteSession {
    /// Runs `server_command` at the end of `chain` and completes the handshake.
    pub fn connect(
        chain: &TransportChain,
        server_command: &[String],
        options: &ConnectOptions,
    ) -> Result<(Self, Receiver<Event>), ClientError> {
        let command = chain
            .command(server_command)
            .map_err(ClientError::Transport)?;
        let (program, arguments) = command
            .split_first()
            .ok_or_else(|| ClientError::Protocol("empty server command".into()))?;
        let mut child = Command::new(program)
            .args(arguments)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(ClientError::Spawn)?;
        let stdin = child.stdin.take().expect("stdin is piped");
        let stdout = child.stdout.take().expect("stdout is piped");
        let stderr_tail = Arc::new(Mutex::new(VecDeque::new()));
        if let Some(stderr) = child.stderr.take() {
            keep_tail(stderr, Arc::clone(&stderr_tail));
        }
        Self::establish(stdout, Box::new(stdin), Some(child), stderr_tail, options)
    }

    /// Uses existing streams, for example an in-process server in tests.
    pub fn from_streams(
        reader: impl Read + Send + 'static,
        writer: impl Write + Send + 'static,
        options: &ConnectOptions,
    ) -> Result<(Self, Receiver<Event>), ClientError> {
        Self::establish(reader, Box::new(writer), None, Arc::default(), options)
    }

    fn establish(
        reader: impl Read + Send + 'static,
        writer: Box<dyn Write + Send>,
        child: Option<Child>,
        stderr_tail: Arc<Mutex<VecDeque<u8>>>,
        options: &ConnectOptions,
    ) -> Result<(Self, Receiver<Event>), ClientError> {
        let deadline = Instant::now() + options.handshake_timeout;
        let pending = Arc::new(Mutex::new(Pending::default()));
        let (event_sender, events) = mpsc::sync_channel(EVENT_CAPACITY);
        let (ready_sender, ready) = mpsc::channel();
        {
            let pending = Arc::clone(&pending);
            thread::Builder::new()
                .name("remote-reader".into())
                .spawn(move || read_loop(reader, pending, event_sender, ready_sender))
                .map_err(ClientError::Spawn)?;
        }
        let mut session = Self {
            writer: Mutex::new(Some(writer)),
            pending,
            next_id: AtomicU64::new(0),
            child: Mutex::new(child),
            stderr_tail,
            hello: None,
        };

        match ready.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
            Ok(Ok(())) => {}
            Ok(Err(FrameError::PreambleNotFound { noise })) => {
                let mut output = String::from_utf8_lossy(&noise).trim().to_owned();
                let stderr = session.diagnostics();
                if !stderr.is_empty() {
                    output = format!("{output}\n{stderr}").trim().to_owned();
                }
                return Err(ClientError::Disconnected {
                    diagnostics: output,
                });
            }
            Ok(Err(_)) | Err(mpsc::RecvTimeoutError::Disconnected) => {
                session.wait_for_transport_exit(SHUTDOWN_GRACE);
                return Err(ClientError::Disconnected {
                    diagnostics: session.diagnostics(),
                });
            }
            Err(mpsc::RecvTimeoutError::Timeout) => return Err(ClientError::Timeout),
        }

        let hello: HelloResult = session.request(
            methods::SERVER_HELLO,
            &HelloParams {
                protocol_version: PROTOCOL_VERSION,
                client_name: options.client_name.clone(),
            },
            deadline.saturating_duration_since(Instant::now()),
        )?;
        session.hello = Some(hello);
        Ok((session, events))
    }

    /// Handshake result, including the host capabilities.
    pub fn hello(&self) -> &HelloResult {
        self.hello.as_ref().expect("set by establish")
    }

    /// Sends a request and waits for its typed result.
    pub fn request<P: Serialize, R: DeserializeOwned>(
        &self,
        method: &str,
        params: &P,
        timeout: Duration,
    ) -> Result<R, ClientError> {
        let params = serde_json::to_value(params)
            .map_err(|error| ClientError::Protocol(error.to_string()))?;
        let result = self.request_value(method, params, timeout)?;
        serde_json::from_value(result).map_err(|error| ClientError::Protocol(error.to_string()))
    }

    /// Sends a request and waits for its raw result.
    pub fn request_value(
        &self,
        method: &str,
        params: Value,
        timeout: Duration,
    ) -> Result<Value, ClientError> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed) + 1;
        let (reply_sender, reply) = mpsc::sync_channel(1);
        {
            let mut pending = lock(&self.pending);
            if pending.closed {
                return Err(self.disconnected());
            }
            pending.waiting.insert(id, reply_sender);
        }
        let message = Message::Request {
            id,
            method: method.into(),
            params,
        };
        if let Err(error) = self.send(&message) {
            lock(&self.pending).waiting.remove(&id);
            return Err(error);
        }
        match reply.recv_timeout(timeout) {
            Ok(Ok(value)) => Ok(value),
            Ok(Err(ClientError::Disconnected { .. }))
            | Err(mpsc::RecvTimeoutError::Disconnected) => Err(self.disconnected()),
            Ok(Err(error)) => Err(error),
            Err(mpsc::RecvTimeoutError::Timeout) => {
                // Removing the waiter makes the reader drop a late response.
                lock(&self.pending).waiting.remove(&id);
                Err(ClientError::Timeout)
            }
        }
    }

    /// Asks the server to stop, then closes the transport. Spawned remote
    /// processes are terminated by the server as part of its shutdown.
    pub fn shutdown(self, timeout: Duration) {
        let _ = self.request_value(methods::SERVER_SHUTDOWN, Value::Null, timeout);
        // Drop closes the stream and reaps the transport process.
    }

    fn send(&self, message: &Message) -> Result<(), ClientError> {
        let payload = serde_json::to_vec(message)
            .map_err(|error| ClientError::Protocol(error.to_string()))?;
        let mut writer = lock(&self.writer);
        let Some(stream) = writer.as_mut() else {
            return Err(self.disconnected());
        };
        write_frame(stream, &payload).map_err(|_| self.disconnected())
    }

    fn disconnected(&self) -> ClientError {
        ClientError::Disconnected {
            diagnostics: self.diagnostics(),
        }
    }

    fn diagnostics(&self) -> String {
        let tail = lock(&self.stderr_tail);
        let bytes: Vec<u8> = tail.iter().copied().collect();
        String::from_utf8_lossy(&bytes).trim().to_owned()
    }

    /// Waits up to `grace` for the transport process to exit, so its final
    /// standard-error output is captured for diagnostics.
    fn wait_for_transport_exit(&self, grace: Duration) -> bool {
        let mut child = lock(&self.child);
        let Some(process) = child.as_mut() else {
            return true;
        };
        let deadline = Instant::now() + grace;
        loop {
            match process.try_wait() {
                Ok(Some(_)) | Err(_) => return true,
                Ok(None) if Instant::now() >= deadline => return false,
                Ok(None) => thread::sleep(EXIT_POLL_INTERVAL),
            }
        }
    }
}

impl Drop for RemoteSession {
    fn drop(&mut self) {
        // Closing standard input is the server's disconnect signal.
        lock(&self.writer).take();
        if !self.wait_for_transport_exit(SHUTDOWN_GRACE) {
            if let Some(child) = lock(&self.child).as_mut() {
                let _ = child.kill();
                let _ = child.wait();
            }
        }
    }
}

fn read_loop(
    reader: impl Read,
    pending: Arc<Mutex<Pending>>,
    events: SyncSender<Event>,
    ready: mpsc::Sender<Result<(), FrameError>>,
) {
    let mut reader = BufReader::new(reader);
    if let Err(error) = skip_preamble(&mut reader, PREAMBLE_NOISE_LIMIT) {
        let _ = ready.send(Err(error));
        close(&pending);
        return;
    }
    let _ = ready.send(Ok(()));
    while let Ok(Some(frame)) = read_frame(&mut reader) {
        match serde_json::from_slice::<Message>(&frame) {
            Ok(Message::Response { id, result, error }) => {
                let waiter = lock(&pending).waiting.remove(&id);
                if let Some(waiter) = waiter {
                    let reply = match (result, error) {
                        (_, Some(error)) => Err(ClientError::Remote(error)),
                        (result, None) => Ok(result.unwrap_or(Value::Null)),
                    };
                    let _ = waiter.send(reply);
                }
            }
            Ok(Message::Event { event, params }) => {
                // A dropped receiver means nobody consumes events; keep
                // routing responses.
                let _ = events.send(Event { event, params });
            }
            Ok(Message::Request { .. }) | Err(_) => break,
        }
    }
    close(&pending);
}

fn close(pending: &Mutex<Pending>) {
    let mut pending = lock(pending);
    pending.closed = true;
    for (_, waiter) in pending.waiting.drain() {
        let _ = waiter.send(Err(ClientError::Disconnected {
            diagnostics: String::new(),
        }));
    }
}

fn keep_tail(mut stderr: impl Read + Send + 'static, tail: Arc<Mutex<VecDeque<u8>>>) {
    thread::spawn(move || {
        let mut buffer = [0_u8; 4096];
        loop {
            match stderr.read(&mut buffer) {
                Ok(0) | Err(_) => return,
                Ok(read) => {
                    let mut tail = lock(&tail);
                    tail.extend(&buffer[..read]);
                    let excess = tail.len().saturating_sub(STDERR_TAIL_BYTES);
                    tail.drain(..excess);
                }
            }
        }
    });
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}
