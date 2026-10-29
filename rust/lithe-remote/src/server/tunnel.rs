//! Byte streams to TCP ports and Unix sockets on the remote side.
//!
//! The client listens locally and opens one tunnel per accepted connection,
//! which is how a web server, database or debugger on the remote becomes
//! reachable from the user's machine. Tunnels travel inside the protocol
//! stream, so the server never opens a listening port of its own.

use crate::protocol::methods::{
    self, decode_bytes, encode_bytes, TunnelClosedEvent, TunnelDataEvent, TunnelOpenParams,
    TunnelParams, TunnelTarget, TunnelWriteParams,
};
use crate::protocol::{ErrorCode, RemoteError};
use crate::server::connection::Context;
use crate::server::parse;
use crate::server::process::{queue_input, INPUT_QUEUE_CAPACITY};
use crate::server::resources::Registry;
use crate::server::session::Session;
use serde_json::{json, Value};
use std::io::{self, Read, Write};
use std::net::{Shutdown, TcpStream, ToSocketAddrs};
use std::os::unix::net::UnixStream;
use std::sync::mpsc::SyncSender;
use std::sync::Arc;
use std::thread;
use std::time::Duration;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const READ_CHUNK_BYTES: usize = 32 * 1024;

pub(crate) struct TunnelTable {
    registry: Registry<OpenTunnel>,
}

struct OpenTunnel {
    connection: u64,
    /// `None` after `tunnel.shutdownWrite`: the writer then sends what is
    /// queued and half-closes the stream.
    input: Option<SyncSender<Vec<u8>>>,
    stream: Stream,
}

enum Stream {
    Tcp(TcpStream),
    Unix(UnixStream),
}

impl Stream {
    fn try_clone(&self) -> io::Result<Self> {
        Ok(match self {
            Self::Tcp(stream) => Self::Tcp(stream.try_clone()?),
            Self::Unix(stream) => Self::Unix(stream.try_clone()?),
        })
    }

    fn shutdown(&self, how: Shutdown) {
        let _ = match self {
            Self::Tcp(stream) => stream.shutdown(how),
            Self::Unix(stream) => stream.shutdown(how),
        };
    }
}

impl Read for Stream {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        match self {
            Self::Tcp(stream) => stream.read(buffer),
            Self::Unix(stream) => stream.read(buffer),
        }
    }
}

impl Write for Stream {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        match self {
            Self::Tcp(stream) => stream.write(bytes),
            Self::Unix(stream) => stream.write(bytes),
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        match self {
            Self::Tcp(stream) => stream.flush(),
            Self::Unix(stream) => stream.flush(),
        }
    }
}

impl TunnelTable {
    pub(crate) fn new() -> Self {
        Self {
            registry: Registry::new("tunnel"),
        }
    }

    pub(crate) fn handle(
        &self,
        context: &Context,
        method: &str,
        params: Value,
    ) -> Result<Value, RemoteError> {
        match method {
            methods::TUNNEL_OPEN => self.open(context, parse(params)?).map(|()| Value::Null),
            methods::TUNNEL_WRITE => {
                let params: TunnelWriteParams = parse(params)?;
                let data = decode_bytes(&params.data).map_err(|error| {
                    RemoteError::new(ErrorCode::InvalidRequest, error.to_string())
                })?;
                let tunnels = self.registry.lock();
                let tunnel = tunnels
                    .get(&params.tunnel_id)
                    .ok_or_else(|| self.registry.unknown(params.tunnel_id))?;
                let Some(input) = &tunnel.input else {
                    return Err(RemoteError::new(
                        ErrorCode::InvalidRequest,
                        "the tunnel's write side is shut down",
                    ));
                };
                queue_input(input, data).map(|()| Value::Null)
            }
            methods::TUNNEL_SHUTDOWN_WRITE => {
                // Like `shutdown(SHUT_WR)` on a socket: the peer reads
                // end-of-file after the queued data, and its reply still
                // arrives as `tunnel.data` until it closes.
                let params: TunnelParams = parse(params)?;
                let mut tunnels = self.registry.lock();
                let tunnel = tunnels
                    .get_mut(&params.tunnel_id)
                    .ok_or_else(|| self.registry.unknown(params.tunnel_id))?;
                tunnel.input = None;
                Ok(Value::Null)
            }
            methods::TUNNEL_CLOSE => {
                // Aborts both directions; queued data is discarded.
                let params: TunnelParams = parse(params)?;
                let tunnels = self.registry.lock();
                let tunnel = tunnels
                    .get(&params.tunnel_id)
                    .ok_or_else(|| self.registry.unknown(params.tunnel_id))?;
                tunnel.stream.shutdown(Shutdown::Both);
                Ok(Value::Null)
            }
            _ => Err(RemoteError::new(
                ErrorCode::UnknownMethod,
                format!("unknown method {method}"),
            )),
        }
    }

    pub(crate) fn close_owned_by(&self, connection: u64) {
        for tunnel in self.registry.lock().values() {
            if tunnel.connection == connection {
                tunnel.stream.shutdown(Shutdown::Both);
            }
        }
    }

    pub(crate) fn close_all(&self) {
        for tunnel in self.registry.lock().values() {
            tunnel.stream.shutdown(Shutdown::Both);
        }
    }

    fn open(&self, context: &Context, params: TunnelOpenParams) -> Result<(), RemoteError> {
        let session = &context.session;
        session.ids.observe(params.tunnel_id);
        self.registry.ensure_free(params.tunnel_id)?;
        let stream = connect(&params.target).map_err(|error| {
            RemoteError::new(ErrorCode::ConnectFailed, format!("cannot connect: {error}"))
                .with_details(json!({ "osError": error.raw_os_error() }))
        })?;
        let io_failure = |error: io::Error| crate::server::fs::io_error(error, "");
        let reader = stream.try_clone().map_err(io_failure)?;
        let writer = stream.try_clone().map_err(io_failure)?;
        self.registry.insert(
            params.tunnel_id,
            OpenTunnel {
                connection: context.connection,
                input: Some(start_tunnel_writer(writer)),
                stream,
            },
        )?;
        let session = Arc::clone(session);
        let tunnel_id = params.tunnel_id;
        thread::Builder::new()
            .name("remote-tunnel".into())
            .spawn(move || forward(&session, tunnel_id, reader))
            .map_err(io_failure)?;
        Ok(())
    }
}

/// Writes queued chunks to the remote stream. When the queue's sender is
/// dropped (`tunnel.shutdownWrite`), the queued data is still written and
/// then only the write side is shut down, so the peer can still answer.
fn start_tunnel_writer(mut stream: Stream) -> SyncSender<Vec<u8>> {
    let (sender, receiver) = std::sync::mpsc::sync_channel::<Vec<u8>>(INPUT_QUEUE_CAPACITY);
    thread::spawn(move || {
        while let Ok(chunk) = receiver.recv() {
            if stream.write_all(&chunk).is_err() {
                return;
            }
        }
        stream.shutdown(Shutdown::Write);
    });
    sender
}

fn connect(target: &TunnelTarget) -> io::Result<Stream> {
    match target {
        TunnelTarget::Tcp { host, port } => {
            let mut last_error = None;
            for address in (host.as_str(), *port).to_socket_addrs()? {
                match TcpStream::connect_timeout(&address, CONNECT_TIMEOUT) {
                    Ok(stream) => {
                        // Interactive protocols such as debuggers and
                        // terminals in browsers send small writes.
                        let _ = stream.set_nodelay(true);
                        return Ok(Stream::Tcp(stream));
                    }
                    Err(error) => last_error = Some(error),
                }
            }
            Err(last_error.unwrap_or_else(|| {
                io::Error::new(io::ErrorKind::NotFound, "the host has no address")
            }))
        }
        TunnelTarget::Unix { path } => UnixStream::connect(path).map(Stream::Unix),
    }
}

fn forward(session: &Session, tunnel_id: u64, mut reader: Stream) {
    let mut buffer = vec![0_u8; READ_CHUNK_BYTES];
    let error = loop {
        match reader.read(&mut buffer) {
            Ok(0) => break None,
            Ok(read) => session.link.emit(
                methods::EVENT_TUNNEL_DATA,
                TunnelDataEvent {
                    tunnel_id,
                    data: encode_bytes(&buffer[..read]),
                },
            ),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => break Some(error.to_string()),
        }
    };
    if let Some(tunnel) = session.tunnels.registry.remove(tunnel_id) {
        tunnel.stream.shutdown(Shutdown::Both);
    }
    session.link.emit(
        methods::EVENT_TUNNEL_CLOSED,
        TunnelClosedEvent { tunnel_id, error },
    );
}
