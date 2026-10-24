//! Tunnels, local port forwarding and listening-port discovery.

mod support;

use lithe_remote_client::api::TunnelEvent;
use lithe_remote_client::PortForward;
use lithe_remote_protocol::methods::TunnelTarget;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::net::UnixListener;
use std::sync::Arc;
use std::thread;
use support::{connect, STEP_TIMEOUT};

/// A one-connection echo server that uppercases what it reads, so the test
/// can tell the server's answer from its own request.
fn spawn_tcp_echo() -> (u16, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream.set_read_timeout(Some(STEP_TIMEOUT)).unwrap();
        let mut buffer = [0_u8; 1024];
        loop {
            match stream.read(&mut buffer) {
                Ok(0) | Err(_) => return,
                Ok(read) => {
                    let upper = buffer[..read].to_ascii_uppercase();
                    if stream.write_all(&upper).is_err() {
                        return;
                    }
                }
            }
        }
    });
    (port, server)
}

#[test]
fn tunnels_reach_tcp_ports_on_the_remote() {
    let (port, server) = spawn_tcp_echo();
    let (session, _events) = connect();
    let tunnel = session
        .open_tunnel(TunnelTarget::Tcp {
            host: "127.0.0.1".into(),
            port,
        })
        .unwrap();
    tunnel.write(b"hello").unwrap();
    let mut received = Vec::new();
    while received.len() < 5 {
        match tunnel.next_event(STEP_TIMEOUT).unwrap() {
            Some(TunnelEvent::Data(bytes)) => received.extend(bytes),
            other => panic!("unexpected {other:?}"),
        }
    }
    assert_eq!(received, b"HELLO");
    tunnel.close().unwrap();
    loop {
        match tunnel.next_event(STEP_TIMEOUT).unwrap() {
            Some(TunnelEvent::Closed(closed)) => {
                assert!(closed.error.is_none(), "{closed:?}");
                break;
            }
            Some(TunnelEvent::Data(_)) => {}
            None => panic!("the subscription ended without a closed event"),
        }
    }
    server.join().unwrap();
    drop(tunnel);
    session.shutdown(STEP_TIMEOUT);
}

// Docker and database sockets are Unix sockets on the remote.
/// A private directory directly under `/tmp`, removed on drop.
struct ShortDir(std::path::PathBuf);

impl ShortDir {
    fn new() -> Self {
        let path = std::path::PathBuf::from(format!("/tmp/lithe-tunnel-{}", std::process::id()));
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}

impl Drop for ShortDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn tunnels_reach_unix_sockets_on_the_remote() {
    // Socket paths are limited to about 100 bytes, which the temporary
    // directory on macOS already nearly exhausts.
    let directory = ShortDir::new();
    let path = directory.0.join("service.sock");
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream.write_all(b"greeting").unwrap();
    });
    let (session, _events) = connect();
    let tunnel = session
        .open_tunnel(TunnelTarget::Unix {
            path: path.to_str().unwrap().into(),
        })
        .unwrap();
    let mut received = Vec::new();
    loop {
        match tunnel.next_event(STEP_TIMEOUT).unwrap() {
            Some(TunnelEvent::Data(bytes)) => received.extend(bytes),
            Some(TunnelEvent::Closed(_)) => break,
            None => panic!("the subscription ended without a closed event"),
        }
    }
    assert_eq!(received, b"greeting");
    server.join().unwrap();
    drop(tunnel);
    session.shutdown(STEP_TIMEOUT);
}

#[test]
fn connecting_to_a_closed_port_fails_with_a_stable_code() {
    // Binding then dropping a listener yields a port nobody listens on.
    let port = TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    let (session, _events) = connect();
    match session.open_tunnel(TunnelTarget::Tcp {
        host: "127.0.0.1".into(),
        port,
    }) {
        Err(lithe_remote_client::ClientError::Remote(error)) => {
            assert_eq!(error.code, lithe_remote_protocol::ErrorCode::ConnectFailed)
        }
        Err(other) => panic!("unexpected {other:?}"),
        Ok(_) => panic!("connected to a closed port"),
    }
    session.shutdown(STEP_TIMEOUT);
}

// The full path a browser takes: local port → tunnel → remote port.
#[test]
fn port_forwards_bridge_local_connections_to_the_remote() {
    let (port, server) = spawn_tcp_echo();
    let (session, _events) = connect();
    let session = Arc::new(session);
    let forward = PortForward::start(
        Arc::clone(&session),
        "127.0.0.1:0".parse().unwrap(),
        TunnelTarget::Tcp {
            host: "127.0.0.1".into(),
            port,
        },
    )
    .unwrap();

    let mut local = TcpStream::connect(forward.local_address()).unwrap();
    local.set_read_timeout(Some(STEP_TIMEOUT)).unwrap();
    local.write_all(b"through the tunnel").unwrap();
    let mut answer = vec![0_u8; b"through the tunnel".len()];
    local.read_exact(&mut answer).unwrap();
    assert_eq!(answer, b"THROUGH THE TUNNEL");
    drop(local);
    server.join().unwrap();
    drop(forward);
    Arc::into_inner(session)
        .expect("forwarded connections released the session")
        .shutdown(STEP_TIMEOUT);
}

#[test]
fn listening_ports_include_a_local_listener() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let (session, _events) = connect();
    let ports = session.listening_ports().unwrap();
    assert!(
        ports
            .iter()
            .any(|listening| listening.port == port && listening.address == "127.0.0.1"),
        "{port} not in {ports:?}"
    );
    drop(listener);
    session.shutdown(STEP_TIMEOUT);
}
