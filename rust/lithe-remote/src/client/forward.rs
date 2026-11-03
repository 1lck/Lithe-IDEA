//! Local port forwarding through tunnels.
//!
//! A [`PortForward`] listens on a local address. Every accepted connection
//! opens its own tunnel to the remote target and copies bytes both ways, so
//! `http://127.0.0.1:<local port>` in a browser reaches a server that only
//! listens on the remote machine's loopback interface.

use crate::client::api::TunnelEvent;
use crate::client::session::{ClientError, RemoteSession};
use crate::protocol::methods::TunnelTarget;
use std::io::{self, Read, Write};
use std::net::{Shutdown, SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

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
                            Err(error) => {
                                forward_failed(
                                    "remote.forward.accept_failed",
                                    "accept",
                                    &format!("{:?}", error.kind()),
                                    "io",
                                    &ACCEPT_LOG,
                                );
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
                                if let Some(category) = crate::failure_log::bridge_category(&error)
                                {
                                    forward_failed(
                                        "remote.forward.connection_failed",
                                        "bridge",
                                        &category,
                                        "remote",
                                        &BRIDGE_LOG,
                                    );
                                }
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
        // The acceptor owns the listener. A refused wakeup means that owner
        // already dropped it; otherwise the next accept result observes stopping.
        match TcpStream::connect(self.local_address) {
            Ok(_) => {}
            // log-exempt: 预期的缺失：ConnectionRefused 表示 listener 已关闭，拥有它的 acceptor 已经退出。
            Err(error) if error.kind() == io::ErrorKind::ConnectionRefused => {}
            Err(error) => crate::failure_log::io::<()>(
                "remote.client.operation_failed",
                "acceptor_wakeup",
                Err(error),
            ),
        }
        if let Some(acceptor) = self.acceptor.take() {
            crate::failure_log::outcome(
                "remote.client.operation_failed",
                "forward_acceptor_join",
                acceptor.join(),
                "panic",
                "thread",
            );
        }
    }
}

fn bridge(
    session: &RemoteSession,
    local: TcpStream,
    target: TunnelTarget,
) -> Result<(), ClientError> {
    crate::failure_log::teardown(
        "remote.client.operation_failed",
        "nodelay",
        local.set_nodelay(true),
    );
    let tunnel = match session.open_tunnel(target) {
        Ok(tunnel) => tunnel,
        Err(error) => {
            // log-exempt: 同一次失败已经记录过：隧道建立错误向上传到 bridge 边界记录，随后关闭本地连接不再重复记录。
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
                crate::failure_log::client("tunnel_half_close", writer.shutdown_write());
            } else {
                crate::failure_log::client("tunnel_close", writer.close());
            }
        });
        loop {
            match tunnel.next_event(IDLE_CHECK) {
                Ok(Some(TunnelEvent::Data(bytes))) => {
                    if to_local.write_all(&bytes).is_err() {
                        crate::failure_log::client("tunnel_close", tunnel.close());
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
        crate::failure_log::teardown(
            "remote.client.operation_failed",
            "socket_shutdown",
            to_local.shutdown(Shutdown::Both),
        );
    });
    Ok(())
}

// Each forward failure family emits at most once per five seconds process-wide,
// matching the catalog's rate=12 even across concurrent forwarded connections.
const FAILURE_LOG_INTERVAL: Duration = Duration::from_secs(5);
static ACCEPT_LOG: Mutex<Option<Instant>> = Mutex::new(None);
static BRIDGE_LOG: Mutex<Option<Instant>> = Mutex::new(None);

fn permit_failure(last: &mut Option<Instant>, now: Instant) -> bool {
    if last.is_some_and(|previous| now.saturating_duration_since(previous) < FAILURE_LOG_INTERVAL) {
        return false;
    }
    *last = Some(now);
    true
}

fn forward_failed(
    event: &str,
    stage: &'static str,
    code: &str,
    domain: &'static str,
    gate: &Mutex<Option<Instant>>,
) {
    let permitted = permit_failure(
        &mut gate.lock().unwrap_or_else(|error| error.into_inner()),
        Instant::now(),
    );
    if permitted {
        crate::failure_log::failed(event, stage, code, domain);
    }
}

#[cfg(test)]
mod failure_tests {
    #[test]
    fn forwarding_failure_rate_is_bounded_without_real_time_waits() {
        let now = std::time::Instant::now();
        let mut last = None;
        assert!(super::permit_failure(&mut last, now));
        assert!(!super::permit_failure(&mut last, now));
        assert!(!super::permit_failure(
            &mut last,
            now + std::time::Duration::from_secs(4)
        ));
        assert!(super::permit_failure(
            &mut last,
            now + super::FAILURE_LOG_INTERVAL
        ));
    }
}
