//! Shared helpers for end-to-end tests that drive the real server binary
//! through the local transport, exactly as an SSH or container hop would.

#![allow(dead_code)]

use lithe_remote_client::session::{ConnectOptions, Event};
use lithe_remote_client::{RemoteSession, TransportChain};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::Receiver;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub const SERVER: &str = env!("CARGO_BIN_EXE_lithe-remote-server");

/// Deadline for any single request or event wait. Local operations finish in
/// milliseconds; this only bounds a broken test.
pub const STEP_TIMEOUT: Duration = Duration::from_secs(10);

pub fn options() -> ConnectOptions {
    ConnectOptions {
        client_name: "lithe-remote-server-tests".into(),
        handshake_timeout: STEP_TIMEOUT,
        idle_timeout: None,
        ..ConnectOptions::default()
    }
}

pub fn connect() -> (RemoteSession, Receiver<Event>) {
    connect_command(&[SERVER.to_string(), "--stdio".into()])
}

pub fn connect_command(command: &[String]) -> (RemoteSession, Receiver<Event>) {
    RemoteSession::connect(&TransportChain::local(), command, &options())
        .expect("connect to the server")
}

/// Starts a `--stdio` server with extra environment variables, through
/// `env` so the test process's own environment stays untouched.
pub fn connect_with_environment(variables: &[(&str, &str)]) -> (RemoteSession, Receiver<Event>) {
    let mut command = vec!["env".to_string()];
    command.extend(
        variables
            .iter()
            .map(|(name, value)| format!("{name}={value}")),
    );
    command.extend([SERVER.to_string(), "--stdio".into()]);
    connect_command(&command)
}

/// Polls until no process with `pid` exists. Process exit is observed by the
/// kernel, not through an event we could wait on, so a bounded poll is the
/// only option here.
pub fn wait_until_gone(pid: u32) -> bool {
    let deadline = Instant::now() + STEP_TIMEOUT;
    while Instant::now() < deadline {
        // SAFETY: signal 0 only checks for existence.
        let alive = unsafe { libc::kill(pid as libc::pid_t, 0) } == 0;
        if !alive {
            return true;
        }
        // test-stability: allow(rust-real-sleep) reason: process exit of an unrelated pid has no waitable handle in this process; the loop has a monotonic deadline.
        std::thread::sleep(Duration::from_millis(20));
    }
    false
}

/// Private directory removed on drop, also after a failed assertion.
pub struct TempDir(PathBuf);

impl TempDir {
    pub fn new(label: &str) -> Self {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.subsec_nanos())
            .unwrap_or_default();
        let path = std::env::temp_dir().join(format!(
            "lithe-remote-{label}-{}-{}-{nanos}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&path).unwrap();
        // macOS places the temporary directory behind a symbolic link;
        // canonical paths keep comparisons and link tests exact.
        Self(std::fs::canonicalize(path).unwrap())
    }

    pub fn path(&self) -> &Path {
        &self.0
    }

    pub fn join(&self, name: &str) -> String {
        self.0.join(name).to_str().unwrap().to_owned()
    }

    pub fn str(&self) -> &str {
        self.0.to_str().unwrap()
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// A persistent session's daemon, killed on drop so a failed test never
/// leaves it running. The state directory holds its socket, lock and log.
pub struct Daemon {
    pub key: String,
    pub state: TempDir,
}

impl Daemon {
    pub fn new(label: &str) -> Self {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        Self {
            key: format!(
                "test-{label}-{}-{}",
                std::process::id(),
                COUNTER.fetch_add(1, Ordering::Relaxed)
            ),
            state: TempDir::new(label),
        }
    }

    pub fn command(&self) -> Vec<String> {
        vec![
            SERVER.into(),
            "--connect".into(),
            self.key.clone(),
            "--state-dir".into(),
            self.state.str().into(),
        ]
    }

    pub fn connect(&self, idle_timeout: Option<Duration>) -> (RemoteSession, Receiver<Event>) {
        let mut options = options();
        options.idle_timeout = idle_timeout;
        self.connect_with(&options)
    }

    /// Connects without starting event delivery; the caller subscribes and
    /// then calls `resume`, as a reconnecting client does.
    pub fn connect_deferred(&self) -> (RemoteSession, Receiver<Event>) {
        let mut options = options();
        options.resume = lithe_remote_client::ResumeMode::Deferred;
        self.connect_with(&options)
    }

    pub fn connect_with(&self, options: &ConnectOptions) -> (RemoteSession, Receiver<Event>) {
        RemoteSession::connect(&TransportChain::local(), &self.command(), options).unwrap_or_else(
            |error| panic!("connect to the persistent session: {error}\n{}", self.log()),
        )
    }

    fn lock_path(&self) -> Option<PathBuf> {
        let run = self.state.path().join("run");
        std::fs::read_dir(run)
            .ok()?
            .flatten()
            .find(|entry| entry.file_name().to_string_lossy().ends_with(".lock"))
            .map(|entry| entry.path())
    }

    /// Pid of the running daemon. The daemon holds an exclusive lock on its
    /// lock file for its whole life, so a lock we can take means it is gone
    /// and the recorded pid may already belong to another process.
    pub fn pid(&self) -> Option<u32> {
        use std::os::fd::AsRawFd;
        let path = self.lock_path()?;
        let file = std::fs::File::open(&path).ok()?;
        // SAFETY: flock on a descriptor this test owns.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_SH | libc::LOCK_NB) } == 0 {
            return None;
        }
        std::fs::read_to_string(path).ok()?.trim().parse().ok()
    }

    /// Waits until the daemon released its lock, which it does when exiting.
    pub fn wait_until_stopped(&self) -> bool {
        let deadline = Instant::now() + STEP_TIMEOUT;
        while Instant::now() < deadline {
            if self.pid().is_none() {
                return true;
            }
            // test-stability: allow(rust-real-sleep) reason: the daemon is another process whose exit has no waitable handle here; the loop has a monotonic deadline.
            std::thread::sleep(Duration::from_millis(20));
        }
        false
    }

    pub fn log(&self) -> String {
        let log = self.state.path().join("log");
        std::fs::read_dir(log)
            .into_iter()
            .flatten()
            .flatten()
            .filter_map(|entry| std::fs::read_to_string(entry.path()).ok())
            .collect()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if let Some(pid) = self.pid() {
            // SAFETY: sending a signal has no memory-safety preconditions.
            unsafe { libc::kill(pid as libc::pid_t, libc::SIGKILL) };
            wait_until_gone(pid);
        }
    }
}
