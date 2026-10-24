//! Persistent sessions that survive a dropped connection.
//!
//! The transport runs `lithe-remote-server --connect <key>`, a small proxy.
//! It connects to the session daemon for `<key>` over a Unix socket, starting
//! the daemon first if none runs, and then copies bytes between its standard
//! streams and the socket. When SSH drops, only the proxy dies: the daemon
//! keeps terminals and builds running, buffers their events, and hands them
//! to the next connection. A daemon without clients ends its session after
//! the idle timeout the client requested.
//!
//! The socket lives in a directory only the user can access, and the daemon
//! also verifies the peer's user id, so other users on a shared host cannot
//! attach to a session.

use crate::connection::{self, Ended};
use crate::platform;
use crate::session::Session;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

/// Bound for the proxy to see a freshly started daemon's socket. It covers a
/// predecessor that is still ending its session (terminating process groups
/// and draining requests takes up to about 13 seconds) before the new daemon
/// can take the lock.
const DAEMON_START_TIMEOUT: Duration = Duration::from_secs(30);

/// Bound for a new daemon to wait for a predecessor's lock.
const LOCK_WAIT_TIMEOUT: Duration = Duration::from_secs(25);

/// Pause after a failed `accept`, such as `EMFILE`, which otherwise repeats
/// immediately and spins.
const ACCEPT_FAILURE_BACKOFF: Duration = Duration::from_millis(200);
const DAEMON_START_POLL: Duration = Duration::from_millis(20);

/// Longest wait for a connection before the daemon re-checks its idle
/// deadline and shutdown flag. A connection ends the wait immediately.
const IDLE_CHECK_INTERVAL: Duration = Duration::from_millis(200);

/// Socket paths are limited to about 104 bytes on macOS and 108 on Linux.
const MAX_SOCKET_PATH_BYTES: usize = 100;

/// Short, always-present directory for sockets whose regular path is too
/// long. Its per-user subdirectory is private, like the regular location.
const SHORT_SOCKET_ROOT: &str = "/tmp";

/// Session key and where its state lives.
#[derive(Clone, Debug)]
pub struct PersistentOptions {
    /// Client-chosen session name: 1–64 characters from `[A-Za-z0-9._-]`.
    pub key: String,
    /// Defaults to `$HOME/.lithe-server`.
    pub state_directory: Option<PathBuf>,
}

struct Paths {
    socket: PathBuf,
    lock: PathBuf,
    log: PathBuf,
}

impl PersistentOptions {
    fn paths(&self) -> io::Result<Paths> {
        if self.key.is_empty()
            || self.key.len() > 64
            || !self
                .key
                .chars()
                .all(|character| character.is_ascii_alphanumeric() || "._-".contains(character))
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid session key",
            ));
        }
        let state = match &self.state_directory {
            Some(directory) => directory.clone(),
            None => PathBuf::from(
                platform::current_account()
                    .home_directory
                    .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "no home directory"))?,
            )
            .join(".lithe-server"),
        };
        // The server version is part of the name: a client upgrade starts a
        // new daemon instead of talking to an older one, which ends on its
        // own once idle.
        let name = format!("{}-{}", self.key, env!("CARGO_PKG_VERSION"));
        let run = state.join("run");
        private_directory(&run)?;
        let mut socket = run.join(format!("{name}.sock"));
        if socket.as_os_str().len() > MAX_SOCKET_PATH_BYTES {
            // `/tmp` rather than the temporary directory: on macOS the latter
            // is itself too long for a socket path.
            let fallback = PathBuf::from(SHORT_SOCKET_ROOT)
                .join(format!("lithe-server-{}", platform::current_uid()));
            private_directory(&fallback)?;
            socket = fallback.join(format!("{name}.sock"));
            if socket.as_os_str().len() > MAX_SOCKET_PATH_BYTES {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "the session key is too long for a socket path",
                ));
            }
        }
        let log_directory = state.join("log");
        private_directory(&log_directory)?;
        Ok(Paths {
            socket,
            lock: run.join(format!("{name}.lock")),
            log: log_directory.join(format!("{name}.log")),
        })
    }
}

/// Creates `path` with mode 0700, or verifies an existing one is a real
/// directory owned by the user that nobody else can write to.
fn private_directory(path: &Path) -> io::Result<()> {
    match fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)
    {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error),
    }
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_dir()
        || metadata.uid() != platform::current_uid()
        || metadata.mode() & 0o022 != 0
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!(
                "{} must be a private directory owned by the user",
                path.display()
            ),
        ));
    }
    Ok(())
}

/// Implements `--connect`: relays standard streams to the session daemon,
/// starting it when needed.
pub fn run_proxy(options: &PersistentOptions) -> io::Result<()> {
    let paths = options.paths()?;
    let stream = match UnixStream::connect(&paths.socket) {
        Ok(stream) => stream,
        Err(_) => {
            start_daemon(options, &paths)?;
            wait_for_socket(&paths.socket)?
        }
    };
    relay(stream)
}

fn start_daemon(options: &PersistentOptions, paths: &Paths) -> io::Result<()> {
    let log = OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(&paths.log)?;
    let mut command = Command::new(std::env::current_exe()?);
    command.arg("--daemon").arg(&options.key);
    if let Some(directory) = &options.state_directory {
        command.arg("--state-dir").arg(directory);
    }
    command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::from(log));
    // A new session detaches the daemon from the SSH session, so the hangup
    // that ends the SSH session does not reach it.
    // SAFETY: setsid is async-signal-safe.
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    // The daemon is not waited for: it outlives this proxy and is adopted by
    // init when the proxy exits.
    command.spawn().map(|_| ())
}

fn wait_for_socket(socket: &Path) -> io::Result<UnixStream> {
    let deadline = Instant::now() + DAEMON_START_TIMEOUT;
    loop {
        match UnixStream::connect(socket) {
            Ok(stream) => return Ok(stream),
            Err(error) if Instant::now() >= deadline => return Err(error),
            Err(_) => thread::sleep(DAEMON_START_POLL),
        }
    }
}

/// Copies bytes in both directions until the daemon closes the connection.
fn relay(stream: UnixStream) -> io::Result<()> {
    let mut to_daemon = stream.try_clone()?;
    thread::spawn(move || {
        let _ = io::copy(&mut io::stdin().lock(), &mut to_daemon);
        // End-of-file from the transport is the client's disconnect.
        let _ = to_daemon.shutdown(std::net::Shutdown::Write);
    });
    let mut from_daemon = stream;
    let mut stdout = io::stdout().lock();
    let mut buffer = vec![0_u8; 64 * 1024];
    loop {
        let read = match from_daemon.read(&mut buffer) {
            Ok(0) => return Ok(()),
            Ok(read) => read,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        };
        // Flushing every chunk keeps interactive output latency low.
        if stdout
            .write_all(&buffer[..read])
            .and_then(|()| stdout.flush())
            .is_err()
        {
            return Ok(());
        }
    }
}

/// Implements `--daemon`: serves the persistent session for `options.key`.
pub fn run_daemon(options: &PersistentOptions) -> io::Result<()> {
    let paths = options.paths()?;
    // The lock decides which daemon owns the key.
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .mode(0o600)
        .open(&paths.lock)?;
    if !acquire_lock(&lock, &paths.socket) {
        return Ok(());
    }
    write_pid(&lock)?;
    // A socket left by a crashed daemon refuses connections; the lock proves
    // nobody serves it.
    match fs::remove_file(&paths.socket) {
        Err(error) if error.kind() != io::ErrorKind::NotFound => return Err(error),
        _ => {}
    }
    let listener = UnixListener::bind(&paths.socket)?;
    fs::set_permissions(&paths.socket, fs::Permissions::from_mode(0o600))?;
    listener.set_nonblocking(true)?;

    let session = Session::new(true)?;
    let shutdown = Arc::new(std::sync::atomic::AtomicBool::new(false));
    {
        // A client that reconnects right after `server.shutdown` must not
        // reach this ending session: the socket disappears before the
        // response, so its proxy starts a new daemon, which waits for the lock.
        let socket = paths.socket.clone();
        let shutdown = Arc::clone(&shutdown);
        session.set_shutdown_hook(move || {
            shutdown.store(true, Ordering::Release);
            let _ = fs::remove_file(socket);
        });
    }
    let attached = Arc::new(AtomicUsize::new(0));
    // The attached connection's id and a copy of its socket, kept so that a
    // replacing connection can disconnect it.
    let current: Arc<Mutex<Option<(u64, UnixStream)>>> = Arc::new(Mutex::new(None));
    let mut next_connection: u64 = 0;
    let mut idle_since = Instant::now();

    while !shutdown.load(Ordering::Acquire) {
        match listener.accept() {
            Ok((stream, _)) => {
                if platform::peer_uid(stream.as_raw_fd()).ok() != Some(platform::current_uid()) {
                    eprintln!("lithe-remote-server: rejected a connection from another user");
                    continue;
                }
                stream.set_nonblocking(false)?;
                // A new connection replaces the current one. The old one may
                // be half-dead after a network change and not yet noticed.
                next_connection += 1;
                let connection_id = next_connection;
                if let Some((_, previous)) =
                    crate::lock(&current).replace((connection_id, stream.try_clone()?))
                {
                    let _ = previous.shutdown(std::net::Shutdown::Both);
                }
                let current = Arc::clone(&current);
                attached.fetch_add(1, Ordering::AcqRel);
                let session = Arc::clone(&session);
                let attached = Arc::clone(&attached);
                let shutdown = Arc::clone(&shutdown);
                thread::Builder::new()
                    .name("remote-connection".into())
                    .spawn(move || {
                        let input = match stream.try_clone() {
                            Ok(input) => input,
                            Err(error) => {
                                eprintln!("lithe-remote-server: {error}");
                                attached.fetch_sub(1, Ordering::AcqRel);
                                return;
                            }
                        };
                        let ended = connection::serve(&session, input, stream);
                        // The copy kept for replacement is the last open
                        // descriptor of this socket. Closing it delivers
                        // end-of-file to the proxy, which would otherwise
                        // linger on the host after every disconnect.
                        // (`shutdown` is not enough: BSD rejects it with
                        // ENOTCONN once the peer has half-closed.)
                        let mut current = crate::lock(&current);
                        if matches!(&*current, Some((id, _)) if *id == connection_id) {
                            current.take();
                        }
                        drop(current);
                        if matches!(ended, Ok(Ended::Shutdown)) {
                            shutdown.store(true, Ordering::Release);
                        }
                        attached.fetch_sub(1, Ordering::AcqRel);
                    })?;
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                if attached.load(Ordering::Acquire) > 0 {
                    idle_since = Instant::now();
                } else if idle_since.elapsed() >= session.idle_timeout() {
                    break;
                }
                wait_for_connection(&listener, IDLE_CHECK_INTERVAL);
            }
            Err(error) => {
                // Persistent failures such as EMFILE return immediately; the
                // pause keeps the loop from spinning and flooding the log.
                eprintln!("lithe-remote-server: accept failed: {error}");
                thread::sleep(ACCEPT_FAILURE_BACKOFF);
            }
        }
    }

    let _ = fs::remove_file(&paths.socket);
    session.terminate_all();
    if let Some((_, stream)) = crate::lock(&current).take() {
        let _ = stream.shutdown(std::net::Shutdown::Both);
    }
    drop(lock);
    Ok(())
}

/// Takes the exclusive lock for the key. Another daemon holding it is either
/// serving the key, then this daemon is redundant and exits, or ending its
/// session after removing the socket, then this daemon waits for it so the
/// proxy that started it finds a fresh session instead of nothing.
fn acquire_lock(lock: &File, socket: &Path) -> bool {
    let deadline = Instant::now() + LOCK_WAIT_TIMEOUT;
    loop {
        // SAFETY: flock on a descriptor this process owns.
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
            return true;
        }
        if UnixStream::connect(socket).is_ok() {
            eprintln!("lithe-remote-server: another daemon serves this session; exiting");
            return false;
        }
        if Instant::now() >= deadline {
            eprintln!("lithe-remote-server: the previous daemon did not release the session lock");
            return false;
        }
        thread::sleep(DAEMON_START_POLL);
    }
}

fn wait_for_connection(listener: &UnixListener, timeout: Duration) {
    let mut descriptor = libc::pollfd {
        fd: listener.as_raw_fd(),
        events: libc::POLLIN,
        revents: 0,
    };
    // SAFETY: one live pollfd is passed with its count.
    unsafe { libc::poll(&mut descriptor, 1, timeout.as_millis() as libc::c_int) };
}

fn write_pid(mut lock: &File) -> io::Result<()> {
    lock.set_len(0)?;
    writeln!(lock, "{}", std::process::id())?;
    lock.flush()
}
