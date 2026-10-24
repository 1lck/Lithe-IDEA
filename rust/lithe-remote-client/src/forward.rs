//! Local port forwarding through tunnels.
//!
//! A [`PortForward`] listens on a local address. Every accepted connection
//! opens its own tunnel to the remote target and copies bytes both ways, so
//! `http://127.0.0.1:<local port>` in a browser reaches a server that only
//! listens on the remote machine's loopback interface.

use crate::api::TunnelEvent;
use crate::session::{ClientError, RemoteSession};
use lithe_remote_protocol::methods::TunnelTarget;
use std::io::{self, Read, Write};
use std::net::{Shutdown, SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::Duration;

const READ_CHUNK_BYTES: usize = 32 * 1024;

/// Pause after a failed `accept`.
const ACCEPT_FAILURE_BACKOFF: Duration = Duration::from_millis(200);

/// How long a tunnel waits for remote data before checking whether the
/// local side has gone away. Data ends the wait immediately.
const IDLE_CHECK: Duration = Duration::from_secs(1);

pub struct PortForward {
    local_address: SocketAddr,
    stopping: Arc<AtomicBool>,
    acceptor: Option<JoinHandle<()>>,
}

impl PortForward {
    /// Starts forwarding `bind` to `target`. Use port 0 to let the system
    /// choose a free local port, then read [`PortForward::local_address`].
    pub fn start(
        session: Arc<RemoteSession>,
        bind: SocketAddr,
        target: TunnelTarget,
    ) -> io::Result<Self> {
        let listener = TcpListener::bind(bind)?;
        let local_address = listener.local_addr()?;
        let stopping = Arc::new(AtomicBool::new(false));
        let acceptor = {
            let stopping = Arc::clone(&stopping);
            thread::Builder::new()
                .name("remote-forward".into())
                .spawn(move || {
                    for connection in listener.incoming() {
                        if stopping.load(Ordering::Acquire) {
                            return;
                        }
                        let connection = match connection {
                            Ok(connection) => connection,
                            Err(_) => {
                                // Failures such as EMFILE repeat immediately;
                                // pausing keeps the acceptor from spinning.
                                thread::sleep(ACCEPT_FAILURE_BACKOFF);
                                continue;
                            }
                        };
                        let session = Arc::clone(&session);
                        let target = target.clone();
                        thread::spawn(move || {
                            if let Err(error) = bridge(&session, connection, target) {
                                eprintln!(
                                    "lithe-remote-client: forwarded connection failed: {error}"
                                );
                            }
                        });
                    }
                })?
        };
        Ok(Self {
            local_address,
            stopping,
            acceptor: Some(acceptor),
        })
    }

    pub fn local_address(&self) -> SocketAddr {
        self.local_address
    }
}

impl Drop for PortForward {
    /// Stops accepting new connections. Connections already bridged continue
    /// until either side closes them.
    fn drop(&mut self) {
        self.stopping.store(true, Ordering::Release);
        // A blocking accept only returns for a connection, so make one.
        let _ = TcpStream::connect(self.local_address);
        if let Some(acceptor) = self.acceptor.take() {
            let _ = acceptor.join();
        }
    }
}

fn bridge(
    session: &RemoteSession,
    local: TcpStream,
    target: TunnelTarget,
) -> Result<(), ClientError> {
    let _ = local.set_nodelay(true);
    let tunnel = match session.open_tunnel(target) {
        Ok(tunnel) => tunnel,
        Err(error) => {
            let _ = local.shutdown(Shutdown::Both);
            return Err(error);
        }
    };
    let mut to_remote = local.try_clone().map_err(ClientError::Spawn)?;
    let mut to_local = local;
    let local_done = Arc::new(AtomicBool::new(false));

    thread::scope(|scope| {
        let local_done_writer = Arc::clone(&local_done);
        let writer = tunnel.writer();
        scope.spawn(move || {
            let mut buffer = vec![0_u8; READ_CHUNK_BYTES];
            let local_ended = loop {
                match to_remote.read(&mut buffer) {
                    Ok(0) => break true,
                    Ok(read) => {
                        if writer.write(&buffer[..read]).is_err() {
                            break false;
                        }
                    }
                    Err(_) => break false,
                }
            };
            local_done_writer.store(true, Ordering::Release);
            if local_ended {
                // The local client finished sending, as HTTP/1.0 clients and
                // `nc -N` do, and now waits for the reply: pass the half-close
                // on after the queued data, and keep receiving.
                let _ = writer.shutdown_write();
            } else {
                let _ = writer.close();
            }
        });
        loop {
            match tunnel.next_event(IDLE_CHECK) {
                Ok(Some(TunnelEvent::Data(bytes))) => {
                    if to_local.write_all(&bytes).is_err() {
                        let _ = tunnel.close();
                        break;
                    }
                }
                Ok(Some(TunnelEvent::Closed(_))) | Ok(None) => break,
                Err(ClientError::Timeout) => {
                    if local_done.load(Ordering::Acquire) && session.is_closed() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
        let _ = to_local.shutdown(Shutdown::Both);
    });
    Ok(())
}
