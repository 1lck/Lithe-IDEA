//! Processes spawned on behalf of the client.
//!
//! Each process leads its own process group. Output is streamed as events in
//! bounded chunks; the exit event is sent after the process's own output has
//! drained, so clients can treat it as the end of the stream.
//!
//! The exit event reports the group leader. Other members of the group, such
//! as build daemons started in the background, may outlive it; the server
//! keeps owning the group until it is empty, so `process.kill` and the
//! disconnect cleanup still reach them.

use crate::fs::io_error;
use crate::{parse, platform, to_value, Outbox};
use lithe_remote_protocol::methods::{
    self, decode_bytes, encode_bytes, KillParams, OutputStream, ProcessExitEvent,
    ProcessOutputEvent, ProcessParams, SpawnParams, SpawnResult, WriteStdinParams,
};
use lithe_remote_protocol::{ErrorCode, Message, RemoteError};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::io::{self, Read, Write};
use std::os::unix::process::ExitStatusExt;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver, SyncSender, TrySendError};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const OUTPUT_CHUNK_BYTES: usize = 32 * 1024;

/// Pending standard-input writes per process. A full queue answers `BUSY`
/// instead of blocking the dispatcher on a child that stopped reading.
const STDIN_QUEUE_CAPACITY: usize = 64;

/// How long output readers may keep a pipe open after the process exited.
/// Grandchildren that inherited the pipe can hold it open indefinitely; their
/// later output is dropped so the exit event remains the last event.
const OUTPUT_DRAIN_GRACE: Duration = Duration::from_millis(500);

/// Interval for checking whether signalled groups are empty during cleanup.
/// Members that are not the server's children report no exit to it, so the
/// wait polls the group within the caller's deadline.
const GROUP_POLL_INTERVAL: Duration = Duration::from_millis(20);

pub(crate) struct ProcessTable {
    state: Arc<(Mutex<TableState>, Condvar)>,
    outbox: Outbox,
}

#[derive(Default)]
struct TableState {
    next_id: u64,
    /// Every process group the server still owns, keyed by process id.
    groups: BTreeMap<u64, OwnedGroup>,
}

struct OwnedGroup {
    /// Process id of the leader, which is also the process group id.
    pid: u32,
    /// `None` when standard input was not piped or has been closed.
    stdin: Option<SyncSender<Vec<u8>>>,
    /// Set when the leader exited and its exit event was sent.
    leader_exited: bool,
}

impl TableState {
    /// Forgets groups whose leader exited and that have no members left.
    /// POSIX does not reuse a process id while a group with that id exists,
    /// so a group id stays safe to signal for as long as it is kept here.
    fn prune_empty_groups(&mut self) {
        self.groups
            .retain(|_, group| !group.leader_exited || platform::process_group_exists(group.pid));
    }
}

impl ProcessTable {
    pub(crate) fn new(outbox: Outbox) -> Self {
        Self {
            state: Arc::new((Mutex::new(TableState::default()), Condvar::new())),
            outbox,
        }
    }

    pub(crate) fn handle(&self, method: &str, params: Value) -> Result<Value, RemoteError> {
        match method {
            methods::PROCESS_SPAWN => to_value(self.spawn(parse(params)?)?),
            methods::PROCESS_WRITE_STDIN => self.write_stdin(parse(params)?).map(|()| Value::Null),
            methods::PROCESS_CLOSE_STDIN => self.close_stdin(parse(params)?).map(|()| Value::Null),
            methods::PROCESS_KILL => self.kill(parse(params)?).map(|()| Value::Null),
            _ => Err(RemoteError::new(
                ErrorCode::UnknownMethod,
                format!("unknown method {method}"),
            )),
        }
    }

    fn spawn(&self, params: SpawnParams) -> Result<SpawnResult, RemoteError> {
        let Some((program, arguments)) = params.argv.split_first() else {
            return Err(RemoteError::new(ErrorCode::InvalidRequest, "argv is empty"));
        };
        let mut command = Command::new(program);
        command
            .args(arguments)
            .envs(&params.env)
            .stdin(if params.pipe_stdin {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if let Some(cwd) = &params.cwd {
            if !cwd.starts_with('/') {
                return Err(RemoteError::new(
                    ErrorCode::InvalidPath,
                    "cwd must be an absolute host path",
                ));
            }
            command.current_dir(cwd);
        }
        platform::prepare_child(&mut command);
        let mut child = command.spawn().map_err(|error| {
            RemoteError::new(
                ErrorCode::SpawnFailed,
                format!("cannot start {program}: {error}"),
            )
            .with_details(json!({ "program": program, "osError": error.raw_os_error() }))
        })?;

        let pid = child.id();
        let stdin = child.stdin.take().map(|pipe| self.start_stdin_writer(pipe));
        let process_id = {
            let mut state = self.lock();
            state.prune_empty_groups();
            state.next_id += 1;
            let process_id = state.next_id;
            state.groups.insert(
                process_id,
                OwnedGroup {
                    pid,
                    stdin,
                    leader_exited: false,
                },
            );
            process_id
        };
        self.start_monitor(process_id, child);
        Ok(SpawnResult { process_id, pid })
    }

    fn start_stdin_writer(&self, mut pipe: ChildStdin) -> SyncSender<Vec<u8>> {
        let (sender, receiver): (_, Receiver<Vec<u8>>) = mpsc::sync_channel(STDIN_QUEUE_CAPACITY);
        // Dropping the sender (close or exit) ends the loop after queued
        // writes, and dropping the pipe delivers end-of-file to the child.
        thread::spawn(move || {
            while let Ok(chunk) = receiver.recv() {
                if pipe.write_all(&chunk).is_err() {
                    break;
                }
            }
        });
        sender
    }

    fn start_monitor(&self, process_id: u64, mut child: Child) {
        // Set under this lock when the exit event is sent; readers check it
        // under the same lock, so no output can follow the exit event.
        let published = Arc::new(Mutex::new(false));
        let (drained_sender, drained) = mpsc::channel();
        let mut readers = 0;
        for (pipe, stream) in [
            (
                child
                    .stdout
                    .take()
                    .map(|pipe| Box::new(pipe) as Box<dyn Read + Send>),
                OutputStream::Stdout,
            ),
            (
                child
                    .stderr
                    .take()
                    .map(|pipe| Box::new(pipe) as Box<dyn Read + Send>),
                OutputStream::Stderr,
            ),
        ] {
            let Some(pipe) = pipe else { continue };
            readers += 1;
            let outbox = self.outbox.clone();
            let published = Arc::clone(&published);
            let drained_sender = drained_sender.clone();
            thread::spawn(move || {
                forward_output(pipe, process_id, stream, &outbox, &published);
                let _ = drained_sender.send(());
            });
        }
        drop(drained_sender);

        let outbox = self.outbox.clone();
        let state = Arc::clone(&self.state);
        thread::spawn(move || {
            let status = child.wait();
            let deadline = Instant::now() + OUTPUT_DRAIN_GRACE;
            for _ in 0..readers {
                let remaining = deadline.saturating_duration_since(Instant::now());
                if drained.recv_timeout(remaining).is_err() {
                    break;
                }
            }
            let mut published = published
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            *published = true;
            {
                let (lock, changed) = &*state;
                let mut table = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
                if let Some(group) = table.groups.get_mut(&process_id) {
                    group.leader_exited = true;
                    group.stdin = None;
                }
                table.prune_empty_groups();
                changed.notify_all();
            }
            let (exit_code, signal) = match status {
                Ok(status) => (status.code(), status.signal()),
                Err(error) => {
                    eprintln!("lithe-remote-server: waiting for process failed: {error}");
                    (None, None)
                }
            };
            let event = ProcessExitEvent {
                process_id,
                exit_code,
                signal,
            };
            if let Ok(params) = serde_json::to_value(event) {
                outbox.send(Message::Event {
                    event: methods::EVENT_PROCESS_EXIT.into(),
                    params,
                });
            }
            drop(published);
        });
    }

    fn write_stdin(&self, params: WriteStdinParams) -> Result<(), RemoteError> {
        let data = decode_bytes(&params.data)
            .map_err(|error| RemoteError::new(ErrorCode::InvalidRequest, error.to_string()))?;
        let state = self.lock();
        let process = running(&state, params.process_id)?;
        let Some(stdin) = &process.stdin else {
            return Err(RemoteError::new(
                ErrorCode::InvalidRequest,
                "standard input is not open",
            ));
        };
        match stdin.try_send(data) {
            Ok(()) => Ok(()),
            Err(TrySendError::Full(_)) => Err(RemoteError::new(
                ErrorCode::Busy,
                "the process is not reading its input",
            )),
            Err(TrySendError::Disconnected(_)) => Err(RemoteError::new(
                ErrorCode::InvalidRequest,
                "standard input is closed",
            )),
        }
    }

    fn close_stdin(&self, params: ProcessParams) -> Result<(), RemoteError> {
        let mut state = self.lock();
        let process = state
            .groups
            .get_mut(&params.process_id)
            .filter(|group| !group.leader_exited)
            .ok_or_else(|| process_not_found(params.process_id))?;
        process.stdin = None;
        Ok(())
    }

    /// Signals the whole group, also after the leader exited while other
    /// members still run.
    fn kill(&self, params: KillParams) -> Result<(), RemoteError> {
        let signal = if params.force {
            libc::SIGKILL
        } else {
            libc::SIGTERM
        };
        let mut state = self.lock();
        let pid = state
            .groups
            .get(&params.process_id)
            .ok_or_else(|| process_not_found(params.process_id))?
            .pid;
        match platform::signal_process_group(pid, signal) {
            Ok(()) => Ok(()),
            Err(error) if error.raw_os_error() == Some(libc::ESRCH) => {
                state.prune_empty_groups();
                Err(process_not_found(params.process_id))
            }
            Err(error) => Err(io_error(error, "")),
        }
    }

    /// Ends every owned process group: `SIGTERM`, a bounded grace period,
    /// then `SIGKILL` for groups that still have members. A group counts as
    /// gone only when it is empty, not when its leader exited.
    pub(crate) fn terminate_all(&self, grace: Duration) {
        for signal in [libc::SIGTERM, libc::SIGKILL] {
            let leaders: Vec<u32> = {
                let mut state = self.lock();
                state.prune_empty_groups();
                state.groups.values().map(|group| group.pid).collect()
            };
            if leaders.is_empty() {
                return;
            }
            for leader in leaders {
                let _ = platform::signal_process_group(leader, signal);
            }
            let deadline = Instant::now() + grace;
            let (lock, changed) = &*self.state;
            let mut state = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            loop {
                state.prune_empty_groups();
                let remaining = deadline.saturating_duration_since(Instant::now());
                if state.groups.is_empty() || remaining.is_zero() {
                    break;
                }
                // Leader exits notify the condition; other members are
                // only observed by polling.
                state = changed
                    .wait_timeout(state, remaining.min(GROUP_POLL_INTERVAL))
                    .unwrap_or_else(|poisoned| poisoned.into_inner())
                    .0;
            }
        }
        let survivors = self.lock().groups.len();
        if survivors > 0 {
            eprintln!("lithe-remote-server: {survivors} process groups did not exit after SIGKILL");
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, TableState> {
        self.state
            .0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

/// Group whose leader is still running; only those accept input.
fn running(state: &TableState, process_id: u64) -> Result<&OwnedGroup, RemoteError> {
    state
        .groups
        .get(&process_id)
        .filter(|group| !group.leader_exited)
        .ok_or_else(|| process_not_found(process_id))
}

fn process_not_found(process_id: u64) -> RemoteError {
    RemoteError::new(
        ErrorCode::ProcessNotFound,
        format!("process {process_id} is not running"),
    )
}

fn forward_output(
    mut pipe: impl Read,
    process_id: u64,
    stream: OutputStream,
    outbox: &Outbox,
    published: &Mutex<bool>,
) {
    let mut buffer = vec![0_u8; OUTPUT_CHUNK_BYTES];
    loop {
        let read = match pipe.read(&mut buffer) {
            Ok(0) => return,
            Ok(read) => read,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => return,
        };
        let published = published
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if *published {
            continue;
        }
        let event = ProcessOutputEvent {
            process_id,
            stream,
            data: encode_bytes(&buffer[..read]),
        };
        if let Ok(params) = serde_json::to_value(event) {
            outbox.send(Message::Event {
                event: methods::EVENT_PROCESS_OUTPUT.into(),
                params,
            });
        }
    }
}
