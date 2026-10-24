//! Byte streams to TCP ports and Unix sockets on the remote side.
//!
//! The client listens locally and opens one tunnel per accepted connection,
//! which is how a web server, database or debugger on the remote becomes
//! reachable from the user's machine. Tunnels travel inside the protocol
//! stream, so the server never opens a listening port of its own.

use crate::connection::Context;
use crate::parse;
use crate::process::{queue_input, start_input_writer};
use crate::resources::Registry;
use crate::session::Session;
use lithe_remote_protocol::methods::{
    self, decode_bytes, encode_bytes, TunnelClosedEvent, TunnelDataEvent, TunnelOpenParams,
    TunnelParams, TunnelTarget, TunnelWriteParams,
};
use lithe_remote_protocol::{ErrorCode, RemoteError};
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
    input: SyncSender<Vec<u8>>,
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

    fn shutdown(&self) {
        let _ = match self {
            Self::Tcp(stream) => stream.shutdown(Shutdown::Both),
            Self::Unix(stream) => stream.shutdown(Shutdown::Both),
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
                queue_input(&tunnel.input, data).map(|()| Value::Null)
            }
            methods::TUNNEL_CLOSE => {
                let params: TunnelParams = parse(params)?;
                let tunnels = self.registry.lock();
                let tunnel = tunnels
                    .get(&params.tunnel_id)
                    .ok_or_else(|| self.registry.unknown(params.tunnel_id))?;
                // The reader then sees end-of-file and reports the closure.
                tunnel.stream.shutdown();
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
                tunnel.stream.shutdown();
            }
        }
    }

    pub(crate) fn close_all(&self) {
        for tunnel in self.registry.lock().values() {
            tunnel.stream.shutdown();
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
        let io_failure = |error: io::Error| crate::fs::io_error(error, "");
        let reader = stream.try_clone().map_err(io_failure)?;
        let writer = stream.try_clone().map_err(io_failure)?;
        self.registry.insert(
            params.tunnel_id,
            OpenTunnel {
                connection: context.connection,
                input: start_input_writer(writer),
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
        tunnel.stream.shutdown();
    }
    session.link.emit(
        methods::EVENT_TUNNEL_CLOSED,
        TunnelClosedEvent { tunnel_id, error },
    );
}
