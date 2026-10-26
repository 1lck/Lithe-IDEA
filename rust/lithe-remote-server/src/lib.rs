//! Remote workspace server.
//!
//! The server owns every host-side capability of a remote workspace:
//! filesystem access, walks, file watching, processes, terminals, the user's
//! login environment and tunnels. It is started by a transport (SSH,
//! `docker exec`, a chain of them, or a local child process in tests) and
//! speaks the `lithe-remote-protocol`.
//!
//! State lives in a [`session::Session`], not in a connection. In `--stdio`
//! mode the session ends with its only connection. In `--connect` mode a
//! daemon keeps the session alive across disconnections, so terminals and
//! builds survive a dropped network link, and a reconnecting client receives
//! the events it missed.
//!
//! Host differences live in `platform`; the other modules only use the
//! capabilities that module exposes.
//!
//! Note: .agents/notes/proposed/architecture/2026-10-24-remote-development-workspace-host.md

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
compile_error!("lithe-remote-server supports Linux and macOS hosts only");

mod connection;
mod daemon;
mod environment;
mod fs;
mod link;
mod platform;
mod ports;
mod process;
mod resources;
mod session;
mod spawner;
mod terminal;
mod tunnel;
mod upload;
mod walk;
mod watch;

pub use daemon::{run_daemon, run_proxy, PersistentOptions};
pub use environment::print_environment;

use lithe_remote_protocol::methods::ServerIdentity;
use lithe_remote_protocol::{ErrorCode, RemoteError, PROTOCOL_VERSION};
use serde::de::DeserializeOwned;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::io::{self, Read, Write};

/// Serves one client on the given streams. The session, and everything it
/// started, ends when the client disconnects or calls `server.shutdown`.
pub fn serve_stdio(input: impl Read, output: impl Write + Send + 'static) -> io::Result<()> {
    let session = session::Session::new(false)?;
    let result = connection::serve(&session, input, output).map(|_| ());
    session.terminate_all();
    result
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
        sha256: hasher
            .finalize()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect(),
    })
}

pub(crate) fn parse<T: DeserializeOwned>(params: Value) -> Result<T, RemoteError> {
    serde_json::from_value(params)
        .map_err(|error| RemoteError::new(ErrorCode::InvalidRequest, error.to_string()))
}

pub(crate) fn to_value(value: impl serde::Serialize) -> Result<Value, RemoteError> {
    serde_json::to_value(value).map_err(|error| RemoteError::new(ErrorCode::Io, error.to_string()))
}

/// Locks a mutex, recovering the data if a panicking thread poisoned it. The
/// server keeps serving other resources rather than failing every request.
pub(crate) fn lock<T>(mutex: &std::sync::Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}
