//! Remote workspace server.
//!
//! The server owns every host-side capability of a remote workspace:
//! filesystem access, process execution and, later, terminals and file
//! watching. It is started by a transport (SSH, `docker exec`, a chain of
//! them, or a local child process in tests) and speaks the
//! `lithe-remote-protocol` on its standard streams.
//!
//! Host differences live in `platform`; the dispatcher and the operation
//! modules only use the capabilities that module exposes.
//!
//! Note: .agents/notes/proposed/architecture/2026-10-24-remote-development-workspace-host.md

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
compile_error!("lithe-remote-server supports Linux and macOS hosts only");

mod fs;
mod platform;
mod process;

use lithe_remote_protocol::frame::{read_frame, write_frame};
use lithe_remote_protocol::methods::{self, HelloParams, HelloResult, ServerIdentity};
use lithe_remote_protocol::{ErrorCode, Message, RemoteError, PREAMBLE, PROTOCOL_VERSION};
use serde::de::DeserializeOwned;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::io::{self, Read, Write};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

/// Messages buffered for the writer thread. A full queue blocks producers,
/// which in turn stops reading child output, so a slow client applies
/// backpressure all the way to the remote process instead of growing memory.
const OUTBOX_CAPACITY: usize = 256;

/// Filesystem requests executing concurrently. Further requests fail with
/// `BUSY` rather than spawning unbounded threads.
const MAX_IN_FLIGHT_REQUESTS: usize = 64;

/// Time spawned process groups get to exit after `SIGTERM` when the client
/// disconnects, before they are killed.
const TERMINATION_GRACE: Duration = Duration::from_secs(2);

/// Item consumed by the writer thread.
pub(crate) enum Outgoing {
    Message(Message),
    /// Ends the writer even while detached output readers still hold senders.
    Close,
}

/// Handle used by operations to queue messages for the client.
#[derive(Clone)]
pub(crate) struct Outbox(SyncSender<Outgoing>);

impl Outbox {
    /// Queues a message. A failure means the writer is gone because the
    /// client disconnected, and there is no one left to tell.
    pub(crate) fn send(&self, message: Message) {
        let _ = self.0.send(Outgoing::Message(message));
    }
}

/// Serves one client until it disconnects or calls `server.shutdown`.
///
/// Must be called on a thread that lives for the whole session: on Linux the
/// parent-death signal of spawned processes is tied to the spawning thread.
pub fn serve(input: impl Read, mut output: impl Write + Send + 'static) -> io::Result<()> {
    output.write_all(PREAMBLE)?;
    output.flush()?;

    let (sender, receiver) = mpsc::sync_channel(OUTBOX_CAPACITY);
    let writer = thread::Builder::new()
        .name("remote-writer".into())
        .spawn(move || write_loop(output, receiver))?;
    let outbox = Outbox(sender.clone());
    let processes = process::ProcessTable::new(outbox.clone());
    let in_flight = Arc::new(AtomicUsize::new(0));
    let mut input = io::BufReader::new(input);
    let mut handshaken = false;

    loop {
        let frame = match read_frame(&mut input) {
            Ok(Some(frame)) => frame,
            Ok(None) => break,
            Err(error) => {
                eprintln!("lithe-remote-server: {error}");
                break;
            }
        };
        let (id, method, params) = match serde_json::from_slice::<Message>(&frame) {
            Ok(Message::Request { id, method, params }) => (id, method, params),
            Ok(_) => {
                eprintln!("lithe-remote-server: ignoring a non-request message");
                continue;
            }
            Err(error) => {
                // Without a parsable id there is no response to send.
                eprintln!("lithe-remote-server: malformed message: {error}");
                continue;
            }
        };

        if !handshaken && method != methods::SERVER_HELLO {
            outbox.send(Message::failure(
                id,
                RemoteError::new(ErrorCode::InvalidRequest, "server.hello must come first"),
            ));
            continue;
        }
        match method.as_str() {
            methods::SERVER_HELLO => {
                let reply = hello(params);
                handshaken |= reply.is_ok();
                outbox.send(respond(id, reply));
            }
            methods::SERVER_SHUTDOWN => {
                outbox.send(Message::success(id, Value::Null));
                break;
            }
            method if method.starts_with("process.") => {
                // Spawning stays on this long-lived thread; see `serve`.
                outbox.send(respond(id, processes.handle(method, params)));
            }
            method if method.starts_with("fs.") => {
                dispatch_filesystem(id, method.to_owned(), params, &outbox, &in_flight);
            }
            _ => outbox.send(Message::failure(
                id,
                RemoteError::new(ErrorCode::UnknownMethod, format!("unknown method {method}")),
            )),
        }
    }

    processes.terminate_all(TERMINATION_GRACE);
    let _ = sender.send(Outgoing::Close);
    match writer.join() {
        Ok(result) => result,
        Err(_) => Err(io::Error::other("writer thread panicked")),
    }
}

fn dispatch_filesystem(
    id: u64,
    method: String,
    params: Value,
    outbox: &Outbox,
    in_flight: &Arc<AtomicUsize>,
) {
    if in_flight.fetch_add(1, Ordering::AcqRel) >= MAX_IN_FLIGHT_REQUESTS {
        in_flight.fetch_sub(1, Ordering::AcqRel);
        outbox.send(Message::failure(
            id,
            RemoteError::new(ErrorCode::Busy, "too many requests in flight"),
        ));
        return;
    }
    let outbox_for_worker = outbox.clone();
    let counter = Arc::clone(in_flight);
    let spawned = thread::Builder::new()
        .name("remote-fs".into())
        .spawn(move || {
            let reply = fs::handle(&method, params);
            outbox_for_worker.send(respond(id, reply));
            counter.fetch_sub(1, Ordering::AcqRel);
        });
    if let Err(error) = spawned {
        in_flight.fetch_sub(1, Ordering::AcqRel);
        outbox.send(Message::failure(
            id,
            RemoteError::new(ErrorCode::Busy, format!("cannot start worker: {error}")),
        ));
    }
}

fn write_loop(mut output: impl Write, receiver: Receiver<Outgoing>) -> io::Result<()> {
    while let Ok(Outgoing::Message(message)) = receiver.recv() {
        let payload = serde_json::to_vec(&message).map_err(io::Error::from)?;
        write_frame(&mut output, &payload).map_err(|error| io::Error::other(error.to_string()))?;
    }
    Ok(())
}

fn hello(params: Value) -> Result<Value, RemoteError> {
    let params: HelloParams = parse(params)?;
    if params.protocol_version != PROTOCOL_VERSION {
        return Err(RemoteError::new(
            ErrorCode::ProtocolMismatch,
            format!(
                "client speaks protocol {}, server speaks {PROTOCOL_VERSION}",
                params.protocol_version
            ),
        )
        .with_details(serde_json::json!({ "serverProtocolVersion": PROTOCOL_VERSION })));
    }
    to_value(HelloResult {
        protocol_version: PROTOCOL_VERSION,
        server_version: env!("CARGO_PKG_VERSION").into(),
        host: platform::host_capabilities(),
    })
}

/// Identity printed by `--identity`.
pub fn identity() -> io::Result<ServerIdentity> {
    let executable = std::env::current_exe()?;
    let mut file = std::fs::File::open(executable)?;
    let mut hasher = Sha256::new();
    io::copy(&mut file, &mut hasher)?;
    Ok(ServerIdentity {
        server_version: env!("CARGO_PKG_VERSION").into(),
        protocol_version: PROTOCOL_VERSION,
        sha256: hex(&hasher.finalize()),
    })
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn respond(id: u64, reply: Result<Value, RemoteError>) -> Message {
    match reply {
        Ok(result) => Message::success(id, result),
        Err(error) => Message::failure(id, error),
    }
}

pub(crate) fn parse<T: DeserializeOwned>(params: Value) -> Result<T, RemoteError> {
    serde_json::from_value(params)
        .map_err(|error| RemoteError::new(ErrorCode::InvalidRequest, error.to_string()))
}

pub(crate) fn to_value(value: impl serde::Serialize) -> Result<Value, RemoteError> {
    serde_json::to_value(value).map_err(|error| RemoteError::new(ErrorCode::Io, error.to_string()))
}
