//! A connected remote server.
//!
//! One reader thread owns the incoming stream. It routes each response to the
//! request waiting for it, and each event either to the subscriber of its
//! resource (`terminal.output` with `terminalId` 7 goes to the subscription
//! for terminal 7) or, without one, to the session's general event channel.
//!
//! Every channel is bounded and the reader blocks when one is full, which
//! stops reading the server's stream and so applies backpressure all the way
//! to the remote process. Consumers must therefore drain what they subscribe
//! to, and either drain the general channel or drop its receiver.
//!
//! A writer thread owns the outgoing stream. Requests queue their frames for
//! it, so a peer that stops reading blocks only that thread, and every request
//! still ends at its own deadline.

use crate::transport::{TransportChain, TransportError};
use lithe_remote_protocol::frame::{read_frame, skip_preamble, write_frame};
use lithe_remote_protocol::methods::{
    self, AckParams, HelloParams, HelloResult, ResumeParams, ResumeResult,
};
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
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

/// Events buffered per channel before the reader blocks.
const EVENT_CAPACITY: usize = 1024;

/// Bytes accepted before the preamble, for example a login banner.
const PREAMBLE_NOISE_LIMIT: usize = 64 * 1024;

/// Tail of the transport's standard error kept for diagnostics.
const STDERR_TAIL_BYTES: usize = 8 * 1024;

/// Events received between two acknowledgements. The session keeps every
/// unacknowledged event for redelivery, so this bounds what a reconnecting
/// client may receive twice in the worst case and what the server retains.
const ACK_INTERVAL: u64 = 256;

/// Bytes of request frames queued for the writer thread. Requests wait for
/// room within their deadline; one frame larger than this is still accepted
/// when the queue is empty.
const OUTGOING_QUEUE_BYTES: usize = 32 * 1024 * 1024;

/// Time the server gets to exit after `server.shutdown` before it is killed.
const SHUTDOWN_GRACE: Duration = Duration::from_secs(2);
const EXIT_POLL_INTERVAL: Duration = Duration::from_millis(20);

/// Server-initiated notification.
#[derive(Clone, Debug, PartialEq)]
pub struct Event {
    pub event: String,
    pub params: Value,
    /// Position in the session's event stream.
    pub seq: Option<u64>,
}

impl Event {
    /// Resource this event belongs to: `("terminal", 7)` for a
    /// `terminal.output` event with `terminalId` 7.
    pub fn resource(&self) -> Option<(&str, u64)> {
        let family = self.event.split('.').next()?;
        let id = self.params.get(format!("{family}Id"))?.as_u64()?;
        Some((family, id))
    }

    /// Decodes the parameters into a typed event.
    pub fn decode<T: DeserializeOwned>(&self) -> Result<T, ClientError> {
        serde_json::from_value(self.params.clone())
            .map_err(|error| ClientError::Protocol(format!("{}: {error}", self.event)))
    }
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

type Routes = Mutex<HashMap<(String, u64), SyncSender<Event>>>;

/// Options for establishing a session.
#[derive(Clone, Debug)]
pub struct ConnectOptions {
    pub client_name: String,
    /// Bounds transport start-up, the preamble and `server.hello` together.
    pub handshake_timeout: Duration,
    /// How long a persistent session keeps running without a client.
    pub idle_timeout: Option<Duration>,
    pub resume: ResumeMode,
}

/// When event delivery starts after the handshake.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ResumeMode {
    /// Right after `server.hello`, with every kept event after the given
    /// sequence number (`None`: every kept event). Suits new sessions.
    Immediately { after_seq: Option<u64> },
    /// Only when the caller calls [`RemoteSession::resume`]. A reconnecting
    /// client first reads `server.state` and subscribes to the resources it
    /// reattaches to, so their missed events reach those subscriptions.
    Deferred,
}

impl Default for ConnectOptions {
    fn default() -> Self {
        Self {
            client_name: "lithe".into(),
            handshake_timeout: Duration::from_secs(30),
            idle_timeout: None,
            resume: ResumeMode::Immediately { after_seq: None },
        }
    }
}

/// Frames waiting for the writer thread.
#[derive(Default)]
struct OutgoingState {
    frames: VecDeque<(u64, Vec<u8>)>,
    bytes: usize,
    /// Set when the session is dropped or a write failed.
    closed: bool,
}

#[derive(Default)]
struct Outgoing {
    state: Mutex<OutgoingState>,
    changed: Condvar,
}

impl Outgoing {
    /// Queues a frame, waiting until `deadline` for room. `Ok(false)` means
    /// the queue is closed.
    fn push(&self, id: u64, payload: Vec<u8>, deadline: Instant) -> Result<bool, ClientError> {
        let mut state = lock(&self.state);
        loop {
            if state.closed {
                return Ok(false);
            }
            if state.frames.is_empty() || state.bytes + payload.len() <= OUTGOING_QUEUE_BYTES {
                break;
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(ClientError::Timeout);
            }
            state = self
                .changed
                .wait_timeout(state, remaining)
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .0;
        }
        state.bytes += payload.len();
        state.frames.push_back((id, payload));
        self.changed.notify_all();
        Ok(true)
    }

    /// Queues a frame only if there is room now. Used by the reader thread,
    /// which must never block on the writer.
    fn try_push(&self, id: u64, payload: Vec<u8>) -> bool {
        let mut state = lock(&self.state);
        if state.closed || state.bytes + payload.len() > OUTGOING_QUEUE_BYTES {
            return false;
        }
        state.bytes += payload.len();
        state.frames.push_back((id, payload));
        self.changed.notify_all();
        true
    }

    /// Drops a frame that was not written yet, for a request that timed out.
    fn withdraw(&self, id: u64) {
        let mut state = lock(&self.state);
        if let Some(index) = state.frames.iter().position(|(queued, _)| *queued == id) {
            if let Some((_, payload)) = state.frames.remove(index) {
                state.bytes -= payload.len();
                self.changed.notify_all();
            }
        }
    }

    fn close(&self) {
        let mut state = lock(&self.state);
        state.closed = true;
        state.frames.clear();
        state.bytes = 0;
        self.changed.notify_all();
    }

    /// Next frame for the writer thread, or `None` once closed.
    fn pop(&self) -> Option<Vec<u8>> {
        let mut state = lock(&self.state);
        loop {
            if state.closed {
                return None;
            }
            if let Some((_, payload)) = state.frames.pop_front() {
                state.bytes -= payload.len();
                self.changed.notify_all();
                return Some(payload);
            }
            state = self
                .changed
                .wait(state)
                .unwrap_or_else(|poisoned| poisoned.into_inner());
        }
    }
}

pub struct RemoteSession {
    outgoing: Arc<Outgoing>,
    pending: Arc<Mutex<Pending>>,
    routes: Arc<Routes>,
    next_request: Arc<AtomicU64>,
    next_resource: AtomicU64,
    /// Sequence number of the latest event received.
    last_seq: Arc<AtomicU64>,
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
        let routes: Arc<Routes> = Arc::default();
        let (event_sender, events) = mpsc::sync_channel(EVENT_CAPACITY);
        let (ready_sender, ready) = mpsc::channel();
        let outgoing = Arc::new(Outgoing::default());
        let next_request = Arc::new(AtomicU64::new(0));
        let last_seq = Arc::new(AtomicU64::new(0));
        {
            let outgoing = Arc::clone(&outgoing);
            let pending = Arc::clone(&pending);
            thread::Builder::new()
                .name("remote-writer".into())
                .spawn(move || write_loop(writer, &outgoing, &pending))
                .map_err(ClientError::Spawn)?;
        }
        {
            let reader_context = ReaderContext {
                pending: Arc::clone(&pending),
                routes: Arc::clone(&routes),
                events: event_sender,
                outgoing: Arc::clone(&outgoing),
                next_request: Arc::clone(&next_request),
                last_seq: Arc::clone(&last_seq),
            };
            thread::Builder::new()
                .name("remote-reader".into())
                .spawn(move || read_loop(reader, reader_context, ready_sender))
                .map_err(ClientError::Spawn)?;
        }
        let mut session = Self {
            outgoing,
            pending,
            routes,
            next_request,
            next_resource: AtomicU64::new(1),
            last_seq,
            child: Mutex::new(child),
            stderr_tail,
            hello: None,
        };

        match ready.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
            Ok(Ok(())) => {}
            Ok(Err(FrameError::PreambleNotFound { noise })) => {
                let mut output = String::from_utf8_lossy(&noise).trim().to_owned();
                session.wait_for_transport_exit(SHUTDOWN_GRACE);
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
                idle_timeout_seconds: options.idle_timeout.map(|timeout| timeout.as_secs()),
            },
            deadline.saturating_duration_since(Instant::now()),
        )?;
        session
            .next_resource
            .store(hello.session.next_resource_id.max(1), Ordering::Release);
        session.hello = Some(hello);
        if let ResumeMode::Immediately { after_seq } = options.resume {
            session.resume(after_seq)?;
        }
        Ok((session, events))
    }

    /// Starts event delivery, first with every kept event after `after_seq`,
    /// the [`RemoteSession::last_event_seq`] of an earlier connection to the
    /// same session. Call it once, after subscribing to the resources whose
    /// missed events should reach their subscriptions.
    pub fn resume(&self, after_seq: Option<u64>) -> Result<ResumeResult, ClientError> {
        self.request(
            methods::SERVER_RESUME,
            &ResumeParams { after_seq },
            Duration::from_secs(30),
        )
    }

    /// Sequence number of the latest event this connection received. Pass it
    /// to [`RemoteSession::resume`] on the next connection to continue
    /// without gaps or repeats.
    pub fn last_event_seq(&self) -> u64 {
        self.last_seq.load(Ordering::Acquire)
    }

    /// Handshake result, including the host capabilities.
    pub fn hello(&self) -> &HelloResult {
        self.hello.as_ref().expect("set by establish")
    }

    /// Returns a resource id that is unused in this session, also across
    /// reconnections.
    pub fn allocate_id(&self) -> u64 {
        self.next_resource.fetch_add(1, Ordering::AcqRel)
    }

    /// Routes the events of one resource to a dedicated channel. Subscribe
    /// before creating the resource, so its first events are not missed.
    /// Dropping the receiver ends the subscription.
    pub fn subscribe(&self, family: &str, id: u64) -> Receiver<Event> {
        let (sender, receiver) = mpsc::sync_channel(EVENT_CAPACITY);
        lock(&self.routes).insert((family.to_owned(), id), sender);
        receiver
    }

    pub fn unsubscribe(&self, family: &str, id: u64) {
        lock(&self.routes).remove(&(family.to_owned(), id));
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
        let deadline = Instant::now() + timeout;
        let id = self.next_request.fetch_add(1, Ordering::Relaxed) + 1;
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
        if let Err(error) = self.send(id, &message, deadline) {
            lock(&self.pending).waiting.remove(&id);
            return Err(error);
        }
        match reply.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
            Ok(Ok(value)) => Ok(value),
            Ok(Err(ClientError::Disconnected { .. }))
            | Err(mpsc::RecvTimeoutError::Disconnected) => Err(self.disconnected()),
            Ok(Err(error)) => Err(error),
            Err(mpsc::RecvTimeoutError::Timeout) => {
                // Removing the waiter makes the reader drop a late response;
                // a frame still queued is not sent at all.
                lock(&self.pending).waiting.remove(&id);
                self.outgoing.withdraw(id);
                Err(ClientError::Timeout)
            }
        }
    }

    /// Whether the stream has ended.
    pub fn is_closed(&self) -> bool {
        lock(&self.pending).closed
    }

    /// Asks the server to stop. A `--stdio` server ends; a persistent
    /// session ends together with everything it runs.
    pub fn shutdown(self, timeout: Duration) {
        let _ = self.request_value(methods::SERVER_SHUTDOWN, Value::Null, timeout);
        // Drop closes the stream and reaps the transport process.
    }

    fn send(&self, id: u64, message: &Message, deadline: Instant) -> Result<(), ClientError> {
        let payload = serde_json::to_vec(message)
            .map_err(|error| ClientError::Protocol(error.to_string()))?;
        match self.outgoing.push(id, payload, deadline)? {
            true => Ok(()),
            false => Err(self.disconnected()),
        }
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
        // The writer thread then drops standard input, which is the server's
        // disconnect signal. A writer blocked on a peer that stopped reading
        // is released when the transport is killed below.
        self.outgoing.close();
        if !self.wait_for_transport_exit(SHUTDOWN_GRACE) {
            if let Some(child) = lock(&self.child).as_mut() {
                let _ = child.kill();
                let _ = child.wait();
            }
        }
    }
}

/// What the reader thread shares with the session.
struct ReaderContext {
    pending: Arc<Mutex<Pending>>,
    routes: Arc<Routes>,
    events: SyncSender<Event>,
    outgoing: Arc<Outgoing>,
    next_request: Arc<AtomicU64>,
    last_seq: Arc<AtomicU64>,
}

fn read_loop(
    reader: impl Read,
    context: ReaderContext,
    ready: mpsc::Sender<Result<(), FrameError>>,
) {
    let ReaderContext {
        pending,
        routes,
        events,
        outgoing,
        next_request,
        last_seq,
    } = context;
    let mut reader = BufReader::new(reader);
    if let Err(error) = skip_preamble(&mut reader, PREAMBLE_NOISE_LIMIT) {
        let _ = ready.send(Err(error));
        close(&pending);
        return;
    }
    let _ = ready.send(Ok(()));
    let mut acknowledged = 0;
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
            Ok(Message::Event { event, params, seq }) => {
                route(&routes, &events, Event { event, params, seq });
                if let Some(seq) = seq {
                    last_seq.store(seq, Ordering::Release);
                    if seq >= acknowledged + ACK_INTERVAL
                        && acknowledge(&outgoing, &next_request, seq)
                    {
                        acknowledged = seq;
                    }
                }
            }
            Ok(Message::Request { .. }) | Err(_) => break,
        }
    }
    close(&pending);
    // Ending every subscription tells consumers the stream is gone.
    lock(&routes).clear();
}

/// Queues `server.ack` without waiting for its response, which the reader
/// discards because no request waits for it. Returns `false` when the queue
/// is full; the next acknowledgement then covers this one.
fn acknowledge(outgoing: &Outgoing, next_request: &AtomicU64, seq: u64) -> bool {
    let id = next_request.fetch_add(1, Ordering::Relaxed) + 1;
    let message = Message::Request {
        id,
        method: methods::SERVER_ACK.into(),
        params: serde_json::to_value(AckParams { seq }).unwrap_or(Value::Null),
    };
    match serde_json::to_vec(&message) {
        Ok(payload) => outgoing.try_push(id, payload),
        Err(_) => false,
    }
}

fn write_loop(mut writer: Box<dyn Write + Send>, outgoing: &Outgoing, pending: &Mutex<Pending>) {
    while let Some(payload) = outgoing.pop() {
        if write_frame(&mut writer, &payload).is_err() {
            // A broken stream fails every waiting request now instead of at
            // its deadline.
            outgoing.close();
            close(pending);
            return;
        }
    }
}

fn route(routes: &Routes, events: &SyncSender<Event>, event: Event) {
    let key = event.resource().map(|(family, id)| (family.to_owned(), id));
    // The sender is cloned so that a blocking send does not hold the lock
    // a consumer needs to subscribe or unsubscribe.
    let subscriber = key.as_ref().and_then(|key| lock(routes).get(key).cloned());
    match subscriber {
        Some(subscriber) => {
            if subscriber.send(event).is_err() {
                if let Some(key) = key {
                    lock(routes).remove(&key);
                }
            }
        }
        // A dropped general receiver means nobody consumes these events.
        None => {
            let _ = events.send(event);
        }
    }
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn events_name_their_resource_by_family_and_id() {
        let event = Event {
            event: "terminal.output".into(),
            params: json!({ "terminalId": 7, "data": "" }),
            seq: Some(1),
        };
        assert_eq!(event.resource(), Some(("terminal", 7)));
        let unrelated = Event {
            event: "watch.changed".into(),
            params: json!({ "terminalId": 7 }),
            seq: Some(2),
        };
        assert_eq!(unrelated.resource(), None);
    }
}
