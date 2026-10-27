//! One client connection: handshake, request routing and the writer thread.
//!
//! Requests that change a running resource in order (terminal input, standard
//! input, resizes) run inline on the reading thread, so they are applied
//! exactly in the order the client sent them. They never block: each one only
//! queues data. Requests that can take time run on worker threads and may
//! complete in any order; `process.kill` and `terminal.close` are among them
//! because finding every member of a session scans the process table.

use crate::link::{Outbox, Outgoing};
use crate::resources::{StartCompletion, StartGuard};
use crate::session::Session;
use crate::{environment, fs, parse, platform, ports, to_value};
use lithe_remote_protocol::frame::{read_frame, write_frame};
use lithe_remote_protocol::methods::{
    self, AckParams, HelloParams, HelloResult, ResumeParams, ResumeResult, SessionInfo,
};
use lithe_remote_protocol::{ErrorCode, Message, RemoteError, PREAMBLE, PROTOCOL_VERSION};
use serde_json::{json, Value};
use std::io::{self, Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

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
    pub(crate) closed: Arc<AtomicBool>,
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
        closed: Arc::new(AtomicBool::new(false)),
    };
    let mut input = io::BufReader::new(input);
    let mut handshaken = false;
    let mut resumed = false;
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

        if !handshaken {
            if method == methods::SERVER_HELLO {
                handshaken = hello(&context, id, params, &outbox);
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
            methods::SERVER_RESUME if resumed => {
                outbox.send(Message::failure(
                    id,
                    RemoteError::new(ErrorCode::InvalidRequest, "already resumed"),
                ));
            }
            methods::SERVER_RESUME => match parse::<ResumeParams>(params) {
                Ok(params) => {
                    resumed = true;
                    session.link.resume(
                        context.connection,
                        outbox.clone(),
                        params.after_seq.unwrap_or(0),
                        |truncated| respond(id, to_value(ResumeResult { truncated })),
                    );
                }
                Err(error) => {
                    outbox.send(Message::failure(id, error));
                }
            },
            methods::SERVER_SHUTDOWN => {
                session.begin_shutdown();
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

    context.closed.store(true, Ordering::Release);
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

/// Handles `server.hello`. Events start flowing only after `server.resume`.
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
    outbox.send(respond(
        id,
        to_value(HelloResult {
            protocol_version: PROTOCOL_VERSION,
            server_version: env!("CARGO_PKG_VERSION").into(),
            host: platform::host_capabilities(),
            session: SessionInfo {
                persistent: session.persistent,
                resumed,
                next_resource_id: session.ids.next(),
                last_event_seq: session.link.last_seq(),
            },
        }),
    ));
    true
}

fn is_inline(method: &str) -> bool {
    matches!(
        method,
        methods::SERVER_PING
            | methods::SERVER_STATE
            | methods::SERVER_ACK
            | methods::PROCESS_WRITE_STDIN
            | methods::PROCESS_CLOSE_STDIN
            | methods::TERMINAL_WRITE
            | methods::TERMINAL_RESIZE
            | methods::TUNNEL_WRITE
            | methods::TUNNEL_SHUTDOWN_WRITE
            | methods::TUNNEL_CLOSE
            | methods::WALK_CANCEL
    )
}

fn handle(context: &Context, method: &str, params: Value) -> Result<Value, RemoteError> {
    let session = &context.session;
    match method {
        methods::SERVER_PING => Ok(json!({})),
        methods::SERVER_STATE => to_value(session.state()),
        methods::SERVER_ACK => {
            let params: AckParams = parse(params)?;
            session.link.acknowledge(params.seq);
            Ok(Value::Null)
        }
        method if method.starts_with("fs.upload") => {
            session.uploads.handle(context, method, params)
        }
        methods::FS_CREATE_RUN_DIRECTORY | methods::FS_RELEASE_RUN_DIRECTORY => {
            session.run_directories.handle(context, method, params)
        }
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
    // Reserve on the reader, not the worker: a close worker can otherwise run
    // before the preceding creation worker has even entered its handler.
    let order = match ResourceOrder::prepare(&context.session, &method, &params) {
        Ok(order) => order,
        Err(error) => {
            outbox.send(Message::failure(id, error));
            return;
        }
    };
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
            let reply = if matches!(&order, ResourceOrder::After(_)) {
                // The creating worker owns teardown, including when this
                // request times out or cannot acquire a worker slot.
                order.wait(Duration::from_secs(60)).map(|()| Value::Null)
            } else {
                handle(&worker_context, &method, params)
            };
            order.finish(&worker_context);
            // Release starts before replying: a blocked writer must not hold
            // up cancellation of an already-published resource.
            drop(order);
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

enum ResourceOrder {
    Start {
        guard: StartGuard,
        close_method: &'static str,
        close_params: Value,
    },
    After(Arc<StartCompletion>),
    Independent,
}

impl ResourceOrder {
    fn prepare(session: &Arc<Session>, method: &str, params: &Value) -> Result<Self, RemoteError> {
        if matches!(
            method,
            methods::FS_CREATE_RUN_DIRECTORY | methods::FS_RELEASE_RUN_DIRECTORY
        ) {
            let parsed: methods::RunDirectoryParams = parse(params.clone())?;
            crate::run_directory::validate(&parsed)?;
            return if method == methods::FS_CREATE_RUN_DIRECTORY {
                Ok(Self::Start {
                    guard: session
                        .starts
                        .reserve("runDirectory", &parsed.directory_id)?,
                    close_method: methods::FS_RELEASE_RUN_DIRECTORY,
                    close_params: params.clone(),
                })
            } else {
                Ok(session
                    .starts
                    .cancel("runDirectory", &parsed.directory_id, params)
                    .map(Self::After)
                    .unwrap_or(Self::Independent))
            };
        }
        let (family, field, start) = match method {
            methods::PROCESS_SPAWN => ("process", "processId", true),
            methods::PROCESS_KILL => ("process", "processId", false),
            methods::TERMINAL_OPEN => ("terminal", "terminalId", true),
            methods::TERMINAL_CLOSE => ("terminal", "terminalId", false),
            methods::WATCH_START => ("watch", "watchId", true),
            methods::WATCH_STOP => ("watch", "watchId", false),
            _ => return Ok(Self::Independent),
        };
        let Some(id) = params.get(field).and_then(Value::as_u64) else {
            return Ok(Self::Independent); // The typed handler reports malformed parameters.
        };
        if !start {
            match family {
                "process" => {
                    parse::<methods::KillParams>(params.clone())?;
                }
                "terminal" => {
                    parse::<methods::TerminalParams>(params.clone())?;
                }
                _ => {
                    parse::<methods::WatchParams>(params.clone())?;
                }
            }
        }
        if start {
            Ok(Self::Start {
                guard: session.starts.reserve(family, id)?,
                close_method: match family {
                    "terminal" => methods::TERMINAL_CLOSE,
                    "watch" => methods::WATCH_STOP,
                    _ => methods::PROCESS_KILL,
                },
                close_params: if family == "process" {
                    json!({field: id, "force": true})
                } else {
                    json!({field: id})
                },
            })
        } else {
            Ok(session
                .starts
                .cancel(family, id, params)
                .map(Self::After)
                .unwrap_or(Self::Independent))
        }
    }

    fn wait(&self, timeout: Duration) -> Result<(), RemoteError> {
        match self {
            Self::After(completion) => completion.wait(timeout),
            _ => Ok(()),
        }
    }

    fn finish(&self, context: &Context) {
        if let Self::Start {
            guard,
            close_method,
            close_params,
        } = self
        {
            let requested = guard.take_cancellation();
            let cancellation = if context.session.is_ending()
                || (!context.session.persistent && context.closed.load(Ordering::Acquire))
            {
                Some(close_params.clone())
            } else {
                requested
            };
            if let Some(params) = cancellation {
                if let Err(error) = handle(context, close_method, params) {
                    if error.code != ErrorCode::UnknownResource {
                        eprintln!(
                            "lithe-remote-server: cancelled start cleanup failed: {:?}",
                            error.code
                        );
                        guard.cleanup_failed(error);
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests;

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
