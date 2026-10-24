//! Long-lived remote connections.
//!
//! `remote.connect` starts one OpenSSH process that probes the host, installs
//! the server when needed and starts it (see `lithe_remote_client::launch`),
//! so the user authenticates once. The connection then stays open in this
//! registry until `remote.disconnect`; requests such as `remote.readDir` use
//! it by id. OpenSSH runs in its own process tree, which closing a connection
//! ends.

use super::{classify, diagnostics, ssh_hop, ProbeStatus, ProbedHost, SshConnection};
use crate::git::execution_events;
use crate::protocol::{CoreError, ErrorCode};
use lithe_git_host::ProcessTree;
use lithe_remote_client::launch::{launch, launch_command, LaunchError, Launched};
use lithe_remote_client::session::{ClientError, ConnectOptions};
use lithe_remote_client::{Hop, RemoteSession, ServerArtifact, ServerTarget, TransportChain};
use lithe_remote_protocol::methods;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, VecDeque};
use std::io::Read;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

/// Upper bound for connecting, including the time the user needs to answer
/// prompts and the upload of the server.
const CONNECT_DEADLINE: Duration = Duration::from_secs(5 * 60);

/// Interval for relaying prompts and checking cancellation while the remote
/// shell runs; it adds no noticeable latency to a network connection.
const POLL_INTERVAL: Duration = Duration::from_millis(20);

/// Time the protocol handshake may take once the server started.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(30);

/// Deadline for one request over an open connection.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

/// Time OpenSSH gets to exit and print its reason after the stream ended.
const EXIT_GRACE: Duration = Duration::from_secs(2);

/// Bytes of OpenSSH's standard error kept while a connection is open.
const STDERR_TAIL_BYTES: usize = 8 * 1024;

/// A server build shipped with the host.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ServerInput {
    /// Rust target triple, for example `x86_64-unknown-linux-musl`.
    target: String,
    /// Absolute path of the read-only binary inside the installed app.
    path: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ConnectRequest {
    connection: SshConnection,
    servers: Vec<ServerInput>,
    server_version: String,
    /// Install root on the remote; `None` is `$HOME/.lithe-server`.
    #[serde(default)]
    install_root: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct OpenedSession {
    id: String,
    /// Whether this connection uploaded the server.
    uploaded: bool,
    host_name: String,
    user_name: Option<String>,
    home_directory: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ConnectResult {
    /// `connected` only when `session` is set.
    status: ProbeStatus,
    session: Option<OpenedSession>,
    /// Platform reported by the remote shell, when it ran.
    host: Option<ProbedHost>,
    diagnostics: String,
}

struct Connection {
    session: RemoteSession,
    child: Mutex<Child>,
    tree: ProcessTree,
}

impl Connection {
    fn close(&self) {
        let _ = self.session.request_value(
            methods::SERVER_SHUTDOWN,
            serde_json::Value::Null,
            EXIT_GRACE,
        );
        let _ = self.tree.terminate(EXIT_GRACE);
        let mut child = self
            .child
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let _ = child.kill();
        let _ = child.wait();
    }
}

/// Set once the application is quitting; connections still being opened stop.
static CLOSING: AtomicBool = AtomicBool::new(false);

/// Number of `connect` calls that have not returned yet.
static CONNECTING: AtomicUsize = AtomicUsize::new(0);

/// Counts a connection attempt so application exit can wait for its OpenSSH
/// tree to be killed.
struct ConnectingGuard;

impl ConnectingGuard {
    fn enter() -> Self {
        CONNECTING.fetch_add(1, Ordering::SeqCst);
        Self
    }
}

impl Drop for ConnectingGuard {
    fn drop(&mut self) {
        CONNECTING.fetch_sub(1, Ordering::SeqCst);
    }
}

fn registry() -> &'static Mutex<HashMap<String, Arc<Connection>>> {
    static CONNECTIONS: OnceLock<Mutex<HashMap<String, Arc<Connection>>>> = OnceLock::new();
    CONNECTIONS.get_or_init(Mutex::default)
}

fn lookup(id: &str) -> Result<Arc<Connection>, CoreError> {
    registry()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .get(id)
        .cloned()
        .ok_or_else(|| {
            CoreError::new(
                ErrorCode::ConnectionClosed,
                "The remote connection is closed",
            )
        })
}

/// Opens a connection and registers it.
pub(crate) fn connect(request: ConnectRequest) -> Result<ConnectResult, CoreError> {
    connect_with(request, None)
}

/// `ssh_program` replaces the `ssh` found on `PATH`; tests use a stand-in.
pub(super) fn connect_with(
    request: ConnectRequest,
    ssh_program: Option<&str>,
) -> Result<ConnectResult, CoreError> {
    // Only the build for the host's platform is read and hashed, once the
    // probe reports it; here the target names are just validated.
    let servers = request
        .servers
        .iter()
        .map(|server| {
            let target = server_target(&server.target).ok_or_else(|| {
                CoreError::new(ErrorCode::InvalidRequest, "Unknown remote server target")
                    .with_details(server.target.clone())
            })?;
            Ok((target, server.path.clone()))
        })
        .collect::<Result<Vec<_>, CoreError>>()?;
    let server_version = request.server_version.clone();
    let unreadable = Arc::new(Mutex::new(None::<String>));
    let unreadable_in_launch = Arc::clone(&unreadable);
    let _connecting = ConnectingGuard::enter();

    let mut hop = ssh_hop(&request.connection)?;
    if let Some(program) = ssh_program {
        hop.program = program.into();
    }
    let argv = TransportChain::new(vec![Hop::Ssh(hop)])
        .command(&launch_command(
            request.install_root.as_deref(),
            &["--stdio"],
        ))
        .map_err(|error| {
            CoreError::new(ErrorCode::InvalidRequest, "Invalid SSH connection")
                .with_details(error.to_string())
        })?;
    let (program, arguments) = argv
        .split_first()
        .expect("an SSH hop always produces a command");
    let mut process = Command::new(program);
    process
        .args(arguments)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut authentication = lithe_git_host::authentication::Session::new().map_err(|error| {
        CoreError::new(
            ErrorCode::ProcessStartFailed,
            "Could not prepare SSH authentication",
        )
        .with_details(error.to_string())
    })?;
    authentication.configure(&mut process).map_err(|error| {
        CoreError::new(
            ErrorCode::ProcessStartFailed,
            "Could not configure SSH authentication",
        )
        .with_details(error.to_string())
    })?;
    ProcessTree::prepare(&mut process);
    let mut child = process.spawn().map_err(|error| {
        CoreError::new(ErrorCode::RuntimeMissing, "Could not start the SSH client")
            .with_details(error.to_string())
    })?;
    let tree = ProcessTree::adopt(&mut child).map_err(|error| {
        CoreError::new(
            ErrorCode::ProcessStartFailed,
            "Could not supervise the SSH client",
        )
        .with_details(error.to_string())
    })?;
    let stderr_tail = Arc::new(Mutex::new(VecDeque::new()));
    let stderr_reader = Mutex::new(
        child
            .stderr
            .take()
            .map(|stderr| keep_tail(stderr, Arc::clone(&stderr_tail))),
    );
    let mut input = child.stdin.take().expect("stdin is piped");
    let mut output = child.stdout.take().expect("stdout is piped");

    // The remote shell is driven on a helper thread with blocking reads;
    // this thread keeps relaying prompts and observing cancellation. Killing
    // the tree ends the helper's reads.
    let (finished, launched) = mpsc::channel();
    std::thread::spawn(move || {
        let result = launch(&mut output, &mut input, |report| {
            let target = report.target()?;
            let (_, path) = servers.iter().find(|(known, _)| *known == target)?;
            match ServerArtifact::from_file(target, path.clone().into(), server_version.clone()) {
                Ok(artifact) => Some(artifact),
                Err(error) => {
                    *unreadable_in_launch
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(error.to_string());
                    None
                }
            }
        });
        let _ = finished.send((result, output, input));
    });
    let deadline = Instant::now() + CONNECT_DEADLINE;
    let abandon = |error: CoreError, child: &mut Child| {
        let _ = tree.kill();
        let _ = child.wait();
        Err(error)
    };
    let (result, output, input) = loop {
        if let Err(error) = crate::protocol::cancellation::check() {
            return abandon(error, &mut child);
        }
        if CLOSING.load(Ordering::SeqCst) {
            return abandon(
                CoreError::new(ErrorCode::Cancelled, "The application is closing"),
                &mut child,
            );
        }
        if Instant::now() >= deadline {
            return abandon(
                CoreError::new(
                    ErrorCode::TimedOut,
                    "The SSH connection did not finish in time",
                ),
                &mut child,
            );
        }
        match authentication.poll() {
            Ok(challenges) => {
                for challenge in challenges {
                    execution_events::emit(serde_json::json!({
                        "type": "authentication",
                        "requestId": challenge.request_id,
                        "prompt": execution_events::redact(&challenge.prompt),
                        "secret": challenge.secret,
                        "attempt": challenge.attempt,
                    }));
                }
            }
            Err(error) => {
                return abandon(
                    CoreError::new(
                        ErrorCode::ProcessFailed,
                        "SSH authentication transport failed",
                    )
                    .with_details(error.to_string()),
                    &mut child,
                )
            }
        }
        match launched.recv_timeout(POLL_INTERVAL) {
            Ok(value) => break value,
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => {
                return abandon(
                    CoreError::new(
                        ErrorCode::ProcessFailed,
                        "The remote shell stopped unexpectedly",
                    ),
                    &mut child,
                )
            }
        }
    };

    // Only called once the OpenSSH tree has ended, so joining the reader
    // cannot block; it guarantees the last bytes OpenSSH printed (the reason
    // it gave up) are in the buffer before the failure is classified.
    let tail = |tail: &Mutex<VecDeque<u8>>| {
        let reader = stderr_reader
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .take();
        if let Some(reader) = reader {
            let _ = reader.join();
        }
        let bytes: Vec<u8> = tail
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .iter()
            .copied()
            .collect();
        bytes
    };
    let failed =
        |status: ProbeStatus, host: Option<ProbedHost>, diagnostics: String| ConnectResult {
            status,
            session: None,
            host,
            diagnostics,
        };
    let launched = match result {
        Ok(launched) => launched,
        Err(LaunchError::NoShell) => {
            // OpenSSH prints why it gave up only as it exits.
            let status = wait_for_exit(&mut child, EXIT_GRACE);
            let _ = tree.kill();
            let _ = child.wait();
            let probe = classify(status, &[], &tail(&stderr_tail));
            return Ok(failed(probe.status, None, probe.diagnostics));
        }
        Err(LaunchError::NoArtifact(report)) => {
            let report = *report;
            let _ = tree.kill();
            let _ = child.wait();
            let unreadable = unreadable
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .take();
            if let Some(details) = unreadable {
                return Err(CoreError::new(
                    ErrorCode::RuntimeMissing,
                    "A bundled remote server is unreadable",
                )
                .with_details(details));
            }
            let host = ProbedHost {
                server_target: report.target().map(ServerTarget::rust_target),
                system: report.system,
                machine: report.machine,
                home_directory: report.home,
                details: report.details,
            };
            return Ok(failed(
                ProbeStatus::UnsupportedPlatform,
                Some(host),
                String::new(),
            ));
        }
        Err(error) => {
            let _ = tree.kill();
            let _ = child.wait();
            let stderr = diagnostics(&String::from_utf8_lossy(&tail(&stderr_tail)));
            return Ok(failed(
                ProbeStatus::Failed,
                None,
                join_diagnostics(&error.to_string(), &stderr),
            ));
        }
    };
    let Launched { report, uploaded } = launched;
    let host = ProbedHost {
        server_target: report.target().map(ServerTarget::rust_target),
        system: report.system,
        machine: report.machine,
        home_directory: report.home,
        details: report.details,
    };
    let options = ConnectOptions {
        handshake_timeout: HANDSHAKE_TIMEOUT,
        ..ConnectOptions::default()
    };
    let (session, events) = match RemoteSession::from_streams(output, input, &options) {
        Ok(value) => value,
        Err(error) => {
            let _ = wait_for_exit(&mut child, EXIT_GRACE);
            let _ = tree.kill();
            let _ = child.wait();
            let stderr = diagnostics(&String::from_utf8_lossy(&tail(&stderr_tail)));
            return Ok(failed(
                ProbeStatus::Failed,
                Some(host),
                join_diagnostics(&error.to_string(), &stderr),
            ));
        }
    };
    // Process events are not used yet; draining keeps the session's reader
    // from blocking on a full channel.
    std::thread::spawn(move || for _ in events {});
    let capabilities = session.hello().host.clone();
    let id = nonce();
    registry()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .insert(
            id.clone(),
            Arc::new(Connection {
                session,
                child: Mutex::new(child),
                tree,
            }),
        );
    Ok(ConnectResult {
        status: ProbeStatus::Connected,
        session: Some(OpenedSession {
            id,
            uploaded,
            host_name: capabilities.host_name,
            user_name: capabilities.user_name,
            home_directory: capabilities.home_directory,
        }),
        host: Some(host),
        diagnostics: String::new(),
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ReadDirRequest {
    session_id: String,
    /// Absolute path on the remote host.
    path: String,
}

/// Lists a remote directory; the result is the protocol's `fs.readDir`.
pub(crate) fn read_dir(request: ReadDirRequest) -> Result<serde_json::Value, CoreError> {
    let connection = lookup(&request.session_id)?;
    connection
        .session
        .request_value(
            methods::FS_READ_DIR,
            serde_json::json!({ "path": request.path }),
            REQUEST_TIMEOUT,
        )
        .map_err(|error| request_error(&request.session_id, error))
}

/// Slowest link a save is expected to survive, in bytes per second; it
/// extends the request deadline for large files.
const WRITE_BYTES_PER_SECOND: u64 = 64 * 1024;

/// Largest file opened for editing; bigger files stay on the host.
const MAX_EDIT_BYTES: u64 = 16 * 1024 * 1024;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ReadFileRequest {
    session_id: String,
    path: String,
}

/// Reads a whole file for the editor: `{ data (base64), size, modifiedMs }`.
/// The version identifies the read for a later conflict-checked write.
pub(crate) fn read_file(request: ReadFileRequest) -> Result<serde_json::Value, CoreError> {
    let connection = lookup(&request.session_id)?;
    let metadata = connection
        .session
        .stat(&request.path)
        .map_err(|error| request_error(&request.session_id, error))?;
    if metadata.size > MAX_EDIT_BYTES {
        return Err(
            CoreError::new(ErrorCode::NotSupported, "The file is too large to open")
                .with_details(format!("{} bytes", metadata.size)),
        );
    }
    let (content, metadata) = connection
        .session
        .read_file(&request.path)
        .map_err(|error| request_error(&request.session_id, error))?;
    // The file may have grown since `stat`.
    if content.len() as u64 > MAX_EDIT_BYTES {
        return Err(
            CoreError::new(ErrorCode::NotSupported, "The file is too large to open")
                .with_details(format!("{} bytes", content.len())),
        );
    }
    Ok(serde_json::json!({
        "data": methods::encode_bytes(&content),
        "size": metadata.size,
        "modifiedMs": metadata.modified_ms,
    }))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct WriteFileRequest {
    session_id: String,
    path: String,
    /// Base64 content that replaces the whole file.
    data: String,
    /// Version last read. When present, a changed file is not replaced and
    /// the result is `conflict`; when absent, the file must not exist yet.
    #[serde(default)]
    expected: Option<methods::FileVersion>,
}

/// Saves a file atomically on the host: `{ status: "saved", size,
/// modifiedMs }`, or `{ status: "conflict" }` when it changed since it was
/// read or, for a new file, when one appeared.
pub(crate) fn write_file(request: WriteFileRequest) -> Result<serde_json::Value, CoreError> {
    let connection = lookup(&request.session_id)?;
    let content = methods::decode_bytes(&request.data).map_err(|error| {
        CoreError::new(
            ErrorCode::InvalidRequest,
            "File content is not valid base64",
        )
        .with_details(error.to_string())
    })?;
    let options = lithe_remote_client::api::WriteOptions {
        expected: request.expected,
        overwrite: false,
        create_parents: false,
    };
    // The whole file travels in one request, so the deadline grows with it.
    let timeout =
        REQUEST_TIMEOUT + Duration::from_secs(content.len() as u64 / WRITE_BYTES_PER_SECOND);
    let params = methods::WriteFileParams {
        path: request.path.clone(),
        data: methods::encode_bytes(&content),
        expected: options.expected,
        overwrite: options.overwrite,
        create_parents: options.create_parents,
    };
    let written = connection
        .session
        .request_value(
            methods::FS_WRITE_FILE,
            serde_json::to_value(&params).expect("write parameters serialize"),
            timeout,
        )
        .and_then(|value| {
            serde_json::from_value::<methods::FileMetadata>(value)
                .map_err(|error| ClientError::Protocol(error.to_string()))
        });
    match written {
        Ok(metadata) => Ok(serde_json::json!({
            "status": "saved",
            "size": metadata.size,
            "modifiedMs": metadata.modified_ms,
        })),
        Err(ClientError::Remote(error))
            if matches!(
                error.code,
                lithe_remote_protocol::ErrorCode::Conflict
                    | lithe_remote_protocol::ErrorCode::AlreadyExists
            ) =>
        {
            Ok(serde_json::json!({ "status": "conflict" }))
        }
        Err(error) => Err(request_error(&request.session_id, error)),
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct DisconnectRequest {
    session_id: String,
}

/// Closes a connection; closing an unknown or closed one succeeds.
pub(crate) fn disconnect(request: DisconnectRequest) -> bool {
    let connection = registry()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .remove(&request.session_id);
    let Some(connection) = connection else {
        return false;
    };
    connection.close();
    true
}

/// Closes every open connection, for application exit. Connections close in
/// parallel so a dead host costs one grace period, not one per connection.
pub(crate) fn close_all() -> usize {
    CLOSING.store(true, Ordering::SeqCst);
    let count = close_registered();
    // Attempts still opening notice the flag within one poll interval and
    // kill their OpenSSH tree; give them a moment to do so.
    let deadline = Instant::now() + EXIT_GRACE;
    while CONNECTING.load(Ordering::SeqCst) > 0 && Instant::now() < deadline {
        std::thread::sleep(POLL_INTERVAL);
    }
    count
}

/// Closes the registered connections in parallel.
pub(super) fn close_registered() -> usize {
    let connections: Vec<Arc<Connection>> = registry()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .drain()
        .map(|(_, connection)| connection)
        .collect();
    let count = connections.len();
    let closers: Vec<_> = connections
        .into_iter()
        .map(|connection| std::thread::spawn(move || connection.close()))
        .collect();
    for closer in closers {
        let _ = closer.join();
    }
    count
}

fn request_error(session_id: &str, error: ClientError) -> CoreError {
    match error {
        ClientError::Remote(error) => {
            let code = match error.code {
                lithe_remote_protocol::ErrorCode::NotFound => ErrorCode::WorkspaceNotFound,
                lithe_remote_protocol::ErrorCode::PermissionDenied => ErrorCode::PermissionDenied,
                _ => ErrorCode::ProcessFailed,
            };
            CoreError::new(code, error.message)
        }
        ClientError::Timeout => CoreError::new(
            ErrorCode::TimedOut,
            "The remote host did not answer in time",
        ),
        ClientError::Disconnected { diagnostics } => {
            // A broken connection cannot recover; forget it so the host
            // reconnects instead of retrying a dead session.
            if let Some(connection) = registry()
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .remove(session_id)
            {
                std::thread::spawn(move || connection.close());
            }
            CoreError::new(ErrorCode::ConnectionClosed, "The remote connection closed")
                .with_details(diagnostics)
        }
        other => CoreError::new(ErrorCode::ProcessFailed, "The remote request failed")
            .with_details(other.to_string()),
    }
}

fn server_target(name: &str) -> Option<ServerTarget> {
    [
        ServerTarget::LinuxX86_64,
        ServerTarget::LinuxAarch64,
        ServerTarget::MacosX86_64,
        ServerTarget::MacosAarch64,
    ]
    .into_iter()
    .find(|target| target.rust_target() == name)
}

fn wait_for_exit(child: &mut Child, grace: Duration) -> Option<std::process::ExitStatus> {
    let deadline = Instant::now() + grace;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Some(status),
            Ok(None) if Instant::now() < deadline => std::thread::sleep(POLL_INTERVAL),
            _ => return None,
        }
    }
}

fn join_diagnostics(summary: &str, stderr: &str) -> String {
    if stderr.is_empty() {
        summary.to_owned()
    } else {
        format!("{summary}\n{stderr}")
    }
}

fn keep_tail(
    mut stderr: impl Read + Send + 'static,
    tail: Arc<Mutex<VecDeque<u8>>>,
) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        let mut buffer = [0_u8; 4096];
        loop {
            match stderr.read(&mut buffer) {
                Ok(0) | Err(_) => return,
                Ok(read) => {
                    let mut tail = tail.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
                    tail.extend(&buffer[..read]);
                    let excess = tail.len().saturating_sub(STDERR_TAIL_BYTES);
                    tail.drain(..excess);
                }
            }
        }
    })
}

/// Unguessable connection id, so one host request cannot address a
/// connection it did not open by counting.
fn nonce() -> String {
    use rand::RngCore;
    let mut bytes = [0_u8; 16];
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}
