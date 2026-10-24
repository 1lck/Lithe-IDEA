//! Delivery of events to whichever connection is attached to the session.
//!
//! Responses belong to the connection that sent the request and go straight
//! to its outbox. Events belong to the session. Each event gets the next
//! sequence number and is kept until the client acknowledges it with
//! `server.ack`, because "written to the socket" is not "received": when a
//! connection dies, events can still sit in its outbox or in kernel buffers.
//! A connection receives events only after `server.resume`, which first
//! sends every kept event after the sequence number the client last saw.
//! This lets a reconnecting client subscribe before its missed events arrive,
//! and gives it each event exactly once.

use lithe_remote_protocol::Message;
use serde::Serialize;
use std::collections::VecDeque;
use std::sync::mpsc::SyncSender;
use std::sync::Mutex;

/// Bytes of serialized, unacknowledged events kept for redelivery. Beyond it
/// the oldest are dropped, and a client resuming before them is told to
/// re-read state.
const RETENTION_LIMIT_BYTES: usize = 8 * 1024 * 1024;

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
    state: Mutex<LinkState>,
}

#[derive(Default)]
struct LinkState {
    attached: Option<(u64, Outbox)>,
    /// Sequence number of the latest event.
    last_seq: u64,
    /// Unacknowledged events, oldest first.
    retained: VecDeque<Retained>,
    retained_bytes: usize,
    /// Highest sequence number dropped before it was acknowledged.
    dropped_through: u64,
}

struct Retained {
    seq: u64,
    message: Message,
    size: usize,
}

impl Link {
    pub(crate) fn new() -> Self {
        Self {
            state: Mutex::new(LinkState::default()),
        }
    }

    /// Records an event and sends it to the resumed client, if any.
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
        let mut state = crate::lock(&self.state);
        state.last_seq += 1;
        let seq = state.last_seq;
        let message = Message::Event {
            event: event.into(),
            params,
            seq: Some(seq),
        };
        let size = serde_json::to_vec(&message).map_or(0, |bytes| bytes.len());
        state.retained.push_back(Retained {
            seq,
            message: message.clone(),
            size,
        });
        state.retained_bytes += size;
        while state.retained_bytes > RETENTION_LIMIT_BYTES {
            let Some(dropped) = state.retained.pop_front() else {
                break;
            };
            state.retained_bytes -= dropped.size;
            state.dropped_through = dropped.seq;
        }
        if let Some((_, outbox)) = &state.attached {
            if !outbox.send(message) {
                // The writer died before the connection noticed. The event
                // stays retained for the next client.
                state.attached = None;
            }
        }
    }

    pub(crate) fn last_seq(&self) -> u64 {
        crate::lock(&self.state).last_seq
    }

    /// Starts delivery to `outbox`. Under one lock it sends the response
    /// built by `respond` (which learns whether events after `after_seq` were
    /// dropped), then every kept event after `after_seq`, so later events
    /// cannot overtake them.
    pub(crate) fn resume(
        &self,
        connection: u64,
        outbox: Outbox,
        after_seq: u64,
        respond: impl FnOnce(bool) -> Message,
    ) {
        let mut state = crate::lock(&self.state);
        let truncated = state.dropped_through > after_seq;
        outbox.send(respond(truncated));
        for retained in state
            .retained
            .iter()
            .filter(|retained| retained.seq > after_seq)
        {
            outbox.send(retained.message.clone());
        }
        state.attached = Some((connection, outbox));
    }

    /// Forgets events up to `seq`, which the client confirmed.
    pub(crate) fn acknowledge(&self, seq: u64) {
        let mut state = crate::lock(&self.state);
        while state
            .retained
            .front()
            .is_some_and(|retained| retained.seq <= seq)
        {
            if let Some(acknowledged) = state.retained.pop_front() {
                state.retained_bytes -= acknowledged.size;
            }
        }
    }

    /// Detaches `connection` if it is still the attached one. A replacing
    /// connection may already have resumed, and must not be detached.
    pub(crate) fn detach(&self, connection: u64) {
        let mut state = crate::lock(&self.state);
        if matches!(&state.attached, Some((attached, _)) if *attached == connection) {
            state.attached = None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::mpsc;

    fn outbox() -> (Outbox, mpsc::Receiver<Outgoing>) {
        let (sender, receiver) = mpsc::sync_channel(1024);
        (Outbox(sender), receiver)
    }

    fn seqs(receiver: &mpsc::Receiver<Outgoing>) -> Vec<u64> {
        receiver
            .try_iter()
            .filter_map(|outgoing| match outgoing {
                Outgoing::Message(Message::Event { seq, .. }) => seq,
                _ => None,
            })
            .collect()
    }

    // A connection that died after its outbox accepted events must not lose
    // them: the next connection resumes after the last event the client
    // actually received, and gets each later event exactly once.
    #[test]
    fn resuming_redelivers_everything_after_the_last_received_event() {
        let link = Link::new();
        let (first, first_received) = outbox();
        link.resume(1, first, 0, |_| Message::success(0, json!(null)));
        for index in 0..5 {
            link.emit("process.output", json!({ "index": index }));
        }
        // The client confirmed only the first two before the link died.
        link.acknowledge(2);
        assert_eq!(seqs(&first_received), [1, 2, 3, 4, 5]);
        link.detach(1);
        link.emit("process.exit", json!({}));

        let (second, second_received) = outbox();
        link.resume(2, second, 3, |truncated| {
            assert!(!truncated);
            Message::success(0, json!(null))
        });
        assert_eq!(seqs(&second_received), [4, 5, 6]);
        assert_eq!(link.last_seq(), 6);
    }

    #[test]
    fn events_are_kept_until_a_client_resumes() {
        let link = Link::new();
        link.emit("terminal.output", json!({}));
        let (outbox, received) = outbox();
        link.resume(1, outbox, 0, |_| Message::success(0, json!(null)));
        assert_eq!(seqs(&received), [1]);
    }
}
