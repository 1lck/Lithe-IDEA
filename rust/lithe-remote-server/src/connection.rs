//! One client connection: handshake, request routing and the writer thread.
//!
//! Requests that change a running resource in order (terminal input, standard
//! input, resizes, kills) run inline on the reading thread, so they are applied
//! exactly in the order the client sent them. They never block: each one only
//! queues data or sends a signal. Requests that can take time run on worker
//! threads and may complete in any order.

use crate::link::{Outbox, Outgoing};
use crate::session::Session;
use crate::{environment, fs, parse, platform, ports, to_value};
use lithe_remote_protocol::frame::{read_frame, write_frame};
use lithe_remote_protocol::methods::{self, HelloParams, HelloResult, SessionInfo};
use lithe_remote_protocol::{ErrorCode, Message, RemoteError, PREAMBLE, PROTOCOL_VERSION};
use serde_json::{json, Value};
use std::io::{self, Read, Write};
use std::sync::mpsc::{self, Receiver};
use std::sync::Arc;
use std::thread;

/// Messages buffered for the writer thread. A full queue blocks producers;
/// see [`crate::link::Link::emit`].
const OUTBOX_CAPACITY: usize = 256;

/// How a connection ended.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Ended {
    Disconnected,
    /// The client called `server.shutdown`; the session must end too.
    Shutdown,
}

/// What a request handler knows about its origin.
#[derive(Clone)]
pub(crate) struct Context {
    pub(crate) session: Arc<Session>,
    /// Owner of connection-bound resources such as tunnels.
    pub(crate) connection: u64,
}

pub(crate) fn serve(
    session: &Arc<Session>,
    input: impl Read,
    mut output: impl Write + Send + 'static,
) -> io::Result<Ended> {
    output.write_all(PREAMBLE)?;
    output.flush()?;

    let (sender, receiver) = mpsc::sync_channel(OUTBOX_CAPACITY);
    let writer = thread::Builder::new()
        .name("remote-writer".into())
        .spawn(move || write_loop(output, receiver))?;
    let outbox = Outbox(sender.clone());
    let context = Context {
        session: Arc::clone(session),
        connection: session.next_connection_id(),
    };
    let mut input = io::BufReader::new(input);
    let mut attached = false;
    let mut ended = Ended::Disconnected;

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

        if !attached {
            if method == methods::SERVER_HELLO {
                attached = hello(&context, id, params, &outbox);
            } else {
                outbox.send(Message::failure(
                    id,
                    RemoteError::new(ErrorCode::InvalidRequest, "server.hello must come first"),
                ));
            }
            continue;
        }
        match method.as_str() {
            methods::SERVER_HELLO => {
                outbox.send(Message::failure(
                    id,
                    RemoteError::new(ErrorCode::InvalidRequest, "already said hello"),
                ));
            }
            methods::SERVER_SHUTDOWN => {
                outbox.send(Message::success(id, Value::Null));
                ended = Ended::Shutdown;
                break;
            }
            method if is_inline(method) => {
                outbox.send(respond(id, handle(&context, method, params)));
            }
            _ => dispatch_to_worker(&context, id, method, params, &outbox),
        }
    }

    session.link.detach(context.connection);
    session.release_connection_resources(context.connection);
    let _ = sender.send(Outgoing::Close);
    match writer.join() {
        Ok(Ok(())) => Ok(ended),
        // The client vanished mid-write; that is an ordinary disconnect.
        Ok(Err(_)) => Ok(ended),
        Err(_) => Err(io::Error::other("writer thread panicked")),
    }
}

/// Handles `server.hello` and attaches the connection to the session.
/// Returns whether the handshake succeeded.
fn hello(context: &Context, id: u64, params: Value, outbox: &Outbox) -> bool {
    let params: HelloParams = match parse(params) {
        Ok(params) => params,
        Err(error) => {
            outbox.send(Message::failure(id, error));
            return false;
        }
    };
    if params.protocol_version != PROTOCOL_VERSION {
        outbox.send(Message::failure(
            id,
            RemoteError::new(
                ErrorCode::ProtocolMismatch,
                format!(
                    "client speaks protocol {}, server speaks {PROTOCOL_VERSION}",
                    params.protocol_version
                ),
            )
            .with_details(json!({ "serverProtocolVersion": PROTOCOL_VERSION })),
        ));
        return false;
    }
    let session = &context.session;
    if let Some(seconds) = params.idle_timeout_seconds {
        session.set_idle_timeout(seconds);
    }
    let resumed = session.mark_client();
    session
        .link
        .attach(context.connection, outbox.clone(), |truncated| {
            respond(
                id,
                to_value(HelloResult {
                    protocol_version: PROTOCOL_VERSION,
                    server_version: env!("CARGO_PKG_VERSION").into(),
                    host: platform::host_capabilities(),
                    session: SessionInfo {
                        persistent: session.persistent,
                        resumed,
                        replay_truncated: truncated,
                        next_resource_id: session.ids.next(),
                    },
                }),
            )
        });
    true
}

fn is_inline(method: &str) -> bool {
    matches!(
        method,
        methods::SERVER_PING
            | methods::SERVER_STATE
            | methods::PROCESS_WRITE_STDIN
            | methods::PROCESS_CLOSE_STDIN
            | methods::PROCESS_KILL
            | methods::TERMINAL_WRITE
            | methods::TERMINAL_RESIZE
            | methods::TERMINAL_CLOSE
            | methods::TUNNEL_WRITE
            | methods::TUNNEL_CLOSE
            | methods::WATCH_STOP
            | methods::WALK_CANCEL
    )
}

fn handle(context: &Context, method: &str, params: Value) -> Result<Value, RemoteError> {
    let session = &context.session;
    match method {
        methods::SERVER_PING => Ok(json!({})),
        methods::SERVER_STATE => to_value(session.state()),
        method if method.starts_with("fs.") => fs::handle(method, params),
        method if method.starts_with("walk.") => session.walks.handle(context, method, params),
        method if method.starts_with("watch.") => session.watches.handle(context, method, params),
        method if method.starts_with("process.") => {
            session.processes.handle(context, method, params)
        }
        method if method.starts_with("terminal.") => {
            session.terminals.handle(context, method, params)
        }
        method if method.starts_with("tunnel.") => session.tunnels.handle(context, method, params),
        methods::ENVIRONMENT_RESOLVE => environment::handle(session, params),
        methods::PORTS_LISTENING => ports::handle(session),
        _ => Err(RemoteError::new(
            ErrorCode::UnknownMethod,
            format!("unknown method {method}"),
        )),
    }
}

fn dispatch_to_worker(context: &Context, id: u64, method: String, params: Value, outbox: &Outbox) {
    let workers = &context.session.workers;
    if !workers.try_acquire() {
        outbox.send(Message::failure(
            id,
            RemoteError::new(ErrorCode::Busy, "too many requests in flight"),
        ));
        return;
    }
    let worker_outbox = outbox.clone();
    let worker_context = context.clone();
    let spawned = thread::Builder::new()
        .name("remote-worker".into())
        .spawn(move || {
            let reply = handle(&worker_context, &method, params);
            worker_outbox.send(respond(id, reply));
            worker_context.session.workers.release();
        });
    if let Err(error) = spawned {
        workers.release();
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

pub(crate) fn respond(id: u64, reply: Result<Value, RemoteError>) -> Message {
    match reply {
        Ok(result) => Message::success(id, result),
        Err(error) => Message::failure(id, error),
    }
}
