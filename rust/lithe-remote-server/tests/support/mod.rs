//! Shared helpers for end-to-end tests that drive the real server binary
//! through the local transport, exactly as an SSH or container hop would.

#![allow(dead_code)]

use lithe_remote_client::session::{ConnectOptions, Event};
use lithe_remote_client::{RemoteSession, TransportChain};
use lithe_remote_protocol::methods::{
    self, decode_bytes, OutputStream, ProcessExitEvent, ProcessOutputEvent,
};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::Receiver;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub const SERVER: &str = env!("CARGO_BIN_EXE_lithe-remote-server");

/// Deadline for any single request or event wait. Local operations finish in
/// milliseconds; this only bounds a broken test.
pub const STEP_TIMEOUT: Duration = Duration::from_secs(10);

pub fn connect() -> (RemoteSession, Receiver<Event>) {
    connect_command(&[SERVER.to_string(), "--stdio".into()])
}

pub fn connect_command(command: &[String]) -> (RemoteSession, Receiver<Event>) {
    let options = ConnectOptions {
        client_name: "lithe-remote-server-tests".into(),
        handshake_timeout: STEP_TIMEOUT,
    };
    RemoteSession::connect(&TransportChain::local(), command, &options)
        .expect("connect to the server")
}

/// Output and exit of one process, gathered from events.
#[derive(Debug, Default)]
pub struct Finished {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub exit: Option<ProcessExitEvent>,
    /// Whether any output event arrived after the exit event.
    pub output_after_exit: bool,
}

/// Collects events for `process_id` until its exit event, then briefly
/// keeps reading to detect output that wrongly follows the exit.
pub fn wait_for_exit(events: &Receiver<Event>, process_id: u64) -> Finished {
    let deadline = Instant::now() + STEP_TIMEOUT;
    let mut finished = Finished::default();
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        let event = if finished.exit.is_some() {
            match events.recv_timeout(Duration::from_millis(100)) {
                Ok(event) => event,
                Err(_) => return finished,
            }
        } else {
            events.recv_timeout(remaining).unwrap_or_else(|_| {
                panic!("process {process_id} did not exit; collected {finished:?}")
            })
        };
        match event.event.as_str() {
            methods::EVENT_PROCESS_OUTPUT => {
                let output: ProcessOutputEvent = serde_json::from_value(event.params).unwrap();
                if output.process_id != process_id {
                    continue;
                }
                if finished.exit.is_some() {
                    finished.output_after_exit = true;
                }
                let bytes = decode_bytes(&output.data).unwrap();
                match output.stream {
                    OutputStream::Stdout => finished.stdout.extend(bytes),
                    OutputStream::Stderr => finished.stderr.extend(bytes),
                }
            }
            methods::EVENT_PROCESS_EXIT => {
                let exit: ProcessExitEvent = serde_json::from_value(event.params).unwrap();
                if exit.process_id == process_id {
                    finished.exit = Some(exit);
                }
            }
            _ => {}
        }
    }
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
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
