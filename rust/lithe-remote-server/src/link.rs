//! Delivery of events to whichever connection is attached to the session.
//!
//! Responses belong to the connection that sent the request and go straight
//! to its outbox. Events belong to the session: while a client is attached
//! they go to its outbox; while none is, a persistent session keeps them in a
//! bounded replay buffer and sends them, in order, right after the next
//! client's `server.hello` response.

use lithe_remote_protocol::Message;
use serde::Serialize;
use std::collections::VecDeque;
use std::sync::mpsc::SyncSender;
use std::sync::Mutex;

/// Bytes of serialized events kept while detached. Beyond it the oldest
/// events are dropped and the next client is told to re-read state.
const REPLAY_LIMIT_BYTES: usize = 8 * 1024 * 1024;

/// Item consumed by a connection's writer thread.
pub(crate) enum Outgoing {
    Message(Message),
    /// Ends the writer even while other threads still hold senders.
    Close,
}

/// Handle used to queue messages for one connection.
#[derive(Clone)]
pub(crate) struct Outbox(pub(crate) SyncSender<Outgoing>);

impl Outbox {
    /// Queues a message. Returns `false` when the writer is gone because the
    /// client disconnected.
    pub(crate) fn send(&self, message: Message) -> bool {
        self.0.send(Outgoing::Message(message)).is_ok()
    }
}

pub(crate) struct Link {
    persistent: bool,
    state: Mutex<LinkState>,
}

#[derive(Default)]
struct LinkState {
    attached: Option<(u64, Outbox)>,
    replay: VecDeque<(Message, usize)>,
    replay_bytes: usize,
    truncated: bool,
}

impl Link {
    pub(crate) fn new(persistent: bool) -> Self {
        Self {
            persistent,
            state: Mutex::new(LinkState::default()),
        }
    }

    /// Sends an event to the attached client, or keeps it for the next one.
    ///
    /// The lock is held while sending, so a slow client blocks producers.
    /// That is the intended backpressure: output readers stop reading and
    /// the remote processes block on their pipes instead of growing memory.
    pub(crate) fn emit(&self, event: &str, params: impl Serialize) {
        let params = match serde_json::to_value(params) {
            Ok(params) => params,
            Err(error) => {
                eprintln!("lithe-remote-server: cannot encode {event}: {error}");
                return;
            }
        };
        let message = Message::Event {
            event: event.into(),
            params,
        };
        let mut state = crate::lock(&self.state);
        if let Some((_, outbox)) = &state.attached {
            if outbox.send(message.clone()) {
                return;
            }
            // The writer died before the connection noticed; keep the event
            // for the next client instead of losing it.
            state.attached = None;
        }
        if !self.persistent {
            return;
        }
        let size = serde_json::to_vec(&message).map_or(0, |bytes| bytes.len());
        state.replay.push_back((message, size));
        state.replay_bytes += size;
        while state.replay_bytes > REPLAY_LIMIT_BYTES {
            let Some((_, dropped)) = state.replay.pop_front() else {
                break;
            };
            state.replay_bytes -= dropped;
            state.truncated = true;
        }
    }

    /// Makes `outbox` the destination of events. Under one lock it first
    /// sends the handshake response built by `respond` (which learns whether
    /// the replay was truncated), then every event kept while no client was
    /// attached, so nothing can overtake them.
    pub(crate) fn attach(
        &self,
        connection: u64,
        outbox: Outbox,
        respond: impl FnOnce(bool) -> Message,
    ) {
        let mut state = crate::lock(&self.state);
        let truncated = std::mem::take(&mut state.truncated);
        outbox.send(respond(truncated));
        while let Some((message, _)) = state.replay.pop_front() {
            outbox.send(message);
        }
        state.replay_bytes = 0;
        state.attached = Some((connection, outbox));
    }

    /// Detaches `connection` if it is still the attached one. A replacing
    /// connection may already have attached, and must not be detached.
    pub(crate) fn detach(&self, connection: u64) {
        let mut state = crate::lock(&self.state);
        if matches!(&state.attached, Some((attached, _)) if *attached == connection) {
            state.attached = None;
        }
    }
}
