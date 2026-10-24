//! Processes spawned on behalf of the client.
//!
//! Each process leads its own session and process group. Output is streamed
//! as events in bounded chunks; the exit event is sent after the process's
//! own output has drained, so clients can treat it as the end of the stream.
//!
//! The exit event reports the leader. Other members of its session, such as
//! build daemons started in the background, may outlive it; the server keeps
//! owning the session until it is empty, so `process.kill` and the final
//! cleanup still reach them.

use crate::connection::Context;
use crate::fs::{host_path, io_error};
use crate::platform::{self, ChildKind};
use crate::resources::Registry;
use crate::session::Session;
use crate::{parse, to_value};
use lithe_remote_protocol::methods::{
    self, decode_bytes, encode_bytes, EnvironmentSource, KillParams, OutputStream,
    ProcessExitEvent, ProcessOutputEvent, ProcessParams, ProcessState, SpawnParams, SpawnResult,
    WriteStdinParams,
};
use lithe_remote_protocol::{ErrorCode, RemoteError};
use serde_json::{json, Value};
use std::io::{self, Read, Write};
use std::os::unix::process::ExitStatusExt;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::mpsc::{self, Receiver, SyncSender, TrySendError};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

pub(crate) const OUTPUT_CHUNK_BYTES: usize = 32 * 1024;

/// Pending standard-input writes per process. A full queue answers `BUSY`
/// instead of blocking the dispatcher on a child that stopped reading.
pub(crate) const INPUT_QUEUE_CAPACITY: usize = 64;

/// How long output readers may keep a pipe open after the process exited.
/// Grandchildren that inherited the pipe can hold it open indefinitely; their
/// later output is dropped so the exit event remains the last event.
pub(crate) const OUTPUT_DRAIN_GRACE: Duration = Duration::from_millis(500);

/// Interval for checking whether signalled sessions are empty during
/// cleanup. Members that are not the server's children report no exit to
/// it, so the wait polls them within the caller's deadline.
pub(crate) const SESSION_POLL_INTERVAL: Duration = Duration::from_millis(50);

/// The leader of a session the server started, kept after the leader exits
/// for as long as the session has members.
///
/// POSIX does not reuse a process id while a process group or session with
/// that id exists, so signalling a kept leader id cannot reach an unrelated
/// process.
pub(crate) struct Leader {
    pub(crate) pid: u32,
    /// Set when the leader exited and its exit event was sent.
    pub(crate) exited: bool,
}

impl Leader {
    pub(crate) fn new(pid: u32) -> Self {
        Self { pid, exited: false }
    }
}

/// Forgets entries whose leader exited and whose session is empty. One call
/// checks all exited leaders together, scanning the process table at most
/// once.
pub(crate) fn prune<T>(registry: &Registry<T>, leader: impl Fn(&T) -> &Leader) {
    let exited: Vec<u32> = registry
        .lock()
        .values()
        .map(&leader)
        .filter(|leader| leader.exited)
        .map(|leader| leader.pid)
        .collect();
    if exited.is_empty() {
        return;
    }
    let live = platform::live_sessions(&exited);
    registry.retain(|entry| {
        let leader = leader(entry);
        !leader.exited || live.contains(&leader.pid)
    });
}

/// Whether any entry is kept only for its session's remaining members.
pub(crate) fn has_exited_leaders<T>(
    registry: &Registry<T>,
    leader: impl Fn(&T) -> &Leader,
) -> bool {
    registry.lock().values().any(|entry| leader(entry).exited)
}

pub(crate) struct ProcessTable {
    registry: Registry<RunningProcess>,
}

struct RunningProcess {
    leader: Leader,
    argv: Vec<String>,
    /// `None` when standard input was not piped or has been closed.
    stdin: Option<SyncSender<Vec<u8>>>,
}

impl ProcessTable {
    pub(crate) fn new() -> Self {
        Self {
            registry: Registry::new("process"),
        }
    }

    pub(crate) fn handle(
        &self,
        context: &Context,
        method: &str,
        params: Value,
    ) -> Result<Value, RemoteError> {
        match method {
            methods::PROCESS_SPAWN => to_value(self.spawn(&context.session, parse(params)?)?),
            methods::PROCESS_WRITE_STDIN => self.write_stdin(parse(params)?).map(|()| Value::Null),
            methods::PROCESS_CLOSE_STDIN => self.close_stdin(parse(params)?).map(|()| Value::Null),
            methods::PROCESS_KILL => self.kill(parse(params)?).map(|()| Value::Null),
            _ => Err(RemoteError::new(
                ErrorCode::UnknownMethod,
                format!("unknown method {method}"),
            )),
        }
    }

    pub(crate) fn states(&self) -> Vec<ProcessState> {
        self.registry
            .lock()
            .iter()
            .map(|(process_id, process)| ProcessState {
                process_id: *process_id,
                pid: process.leader.pid,
                argv: process.argv.clone(),
                leader_exited: process.leader.exited,
            })
            .collect()
    }

    fn spawn(
        &self,
        session: &Arc<Session>,
        params: SpawnParams,
    ) -> Result<SpawnResult, RemoteError> {
        session.ids.observe(params.process_id);
        prune(&self.registry, |process| &process.leader);
        self.registry.ensure_free(params.process_id)?;
        let Some((program, arguments)) = params.argv.split_first() else {
            return Err(RemoteError::new(ErrorCode::InvalidRequest, "argv is empty"));
        };
        let mut command = Command::new(program);
        command
            .args(arguments)
            .stdin(if params.pipe_stdin {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if params.environment == EnvironmentSource::Login {
            let login = session.environment.resolve(session, false);
            command.env_clear().envs(login.environment);
        }
        command.envs(&params.env);
        if let Some(cwd) = &params.cwd {
            command.current_dir(host_path(cwd)?);
        }
        platform::prepare_child(&mut command, ChildKind::Plain);
        let program_name = program.clone();
        let mut child = session
            .spawner
            .run(move || command.spawn())
            .map_err(|error| spawn_error(&program_name, error))?;

        let pid = child.id();
        let stdin = child.stdin.take().map(start_input_writer);
        let entry = RunningProcess {
            leader: Leader::new(pid),
            argv: params.argv.clone(),
            stdin,
        };
        if let Err(error) = self.registry.insert(params.process_id, entry) {
            // Another spawn with the same id won the race; this child was
            // never visible to the client, so it must not keep running.
            let _ = platform::signal_process_group(pid, libc::SIGKILL);
            let _ = child.wait();
            return Err(error);
        }
        self.start_monitor(Arc::clone(session), params.process_id, child);
        Ok(SpawnResult { pid })
    }

    fn start_monitor(&self, session: Arc<Session>, process_id: u64, mut child: Child) {
        let mut gate = OutputGate::new();
        let pipes = [
            child
                .stdout
                .take()
                .map(|pipe| (Box::new(pipe) as Box<dyn Read + Send>, OutputStream::Stdout)),
            child
                .stderr
                .take()
                .map(|pipe| (Box::new(pipe) as Box<dyn Read + Send>, OutputStream::Stderr)),
        ];
        for (pipe, stream) in pipes.into_iter().flatten() {
            let session = Arc::clone(&session);
            gate.start_reader(pipe, move |chunk| {
                session.link.emit(
                    methods::EVENT_PROCESS_OUTPUT,
                    ProcessOutputEvent {
                        process_id,
                        stream,
                        data: encode_bytes(chunk),
                    },
                );
            });
        }
        thread::spawn(move || {
            let status = child.wait();
            gate.finish(|| {
                let registry = &session.processes.registry;
                if let Some(process) = registry.lock().get_mut(&process_id) {
                    process.leader.exited = true;
                    process.stdin = None;
                }
                prune(registry, |process| &process.leader);
                let (exit_code, signal) = exit_parts(status);
                session.link.emit(
                    methods::EVENT_PROCESS_EXIT,
                    ProcessExitEvent {
                        process_id,
                        exit_code,
                        signal,
                    },
                );
            });
        });
    }

    fn write_stdin(&self, params: WriteStdinParams) -> Result<(), RemoteError> {
        let data = decode_bytes(&params.data)
            .map_err(|error| RemoteError::new(ErrorCode::InvalidRequest, error.to_string()))?;
        let processes = self.registry.lock();
        let process = processes
            .get(&params.process_id)
            .filter(|process| !process.leader.exited)
            .ok_or_else(|| self.registry.unknown(params.process_id))?;
        let Some(stdin) = &process.stdin else {
            return Err(RemoteError::new(
                ErrorCode::InvalidRequest,
                "standard input is not open",
            ));
        };
        queue_input(stdin, data)
    }

    fn close_stdin(&self, params: ProcessParams) -> Result<(), RemoteError> {
        let mut processes = self.registry.lock();
        let process = processes
            .get_mut(&params.process_id)
            .filter(|process| !process.leader.exited)
            .ok_or_else(|| self.registry.unknown(params.process_id))?;
        process.stdin = None;
        Ok(())
    }

    /// Signals the whole session, also after the leader exited while other
    /// members still run.
    fn kill(&self, params: KillParams) -> Result<(), RemoteError> {
        // A session that emptied since the last check must not be signalled:
        // its id may already belong to an unrelated process.
        prune(&self.registry, |process| &process.leader);
        let pid = self
            .registry
            .lock()
            .get(&params.process_id)
            .map(|process| process.leader.pid)
            .ok_or_else(|| self.registry.unknown(params.process_id))?;
        let signal = if params.force {
            libc::SIGKILL
        } else {
            libc::SIGTERM
        };
        match platform::signal_session(pid, signal) {
            Ok(()) => Ok(()),
            Err(error) if error.raw_os_error() == Some(libc::ESRCH) => {
                prune(&self.registry, |process| &process.leader);
                Err(self.registry.unknown(params.process_id))
            }
            Err(error) => Err(io_error(error, "")),
        }
    }

    /// Forgets sessions that emptied after their leader exited.
    pub(crate) fn reap(&self) {
        if has_exited_leaders(&self.registry, |process| &process.leader) {
            prune(&self.registry, |process| &process.leader);
        }
    }

    /// Ends every owned session: `SIGTERM`, a bounded grace period, then
    /// `SIGKILL` for sessions that still have members.
    pub(crate) fn terminate_all(&self, grace: Duration) {
        terminate_groups(
            &self.registry,
            grace,
            |process| &process.leader,
            libc::SIGTERM,
        );
    }
}

/// Signals every session in `registry` with `first`, then `SIGKILL`, waiting
/// up to `grace` after each signal until the sessions are empty. A session
/// counts as gone only when no member is left, not when its leader exited.
pub(crate) fn terminate_groups<T>(
    registry: &Registry<T>,
    grace: Duration,
    leader: impl Fn(&T) -> &Leader + Copy,
    first: libc::c_int,
) {
    for signal in [first, libc::SIGKILL] {
        prune(registry, leader);
        let leaders: Vec<u32> = registry
            .lock()
            .values()
            .map(|entry| leader(entry).pid)
            .collect();
        if leaders.is_empty() {
            return;
        }
        for pid in leaders {
            let _ = platform::signal_session(pid, signal);
        }
        let deadline = Instant::now() + grace;
        loop {
            prune(registry, leader);
            let remaining = deadline.saturating_duration_since(Instant::now());
            if registry.lock().is_empty() {
                return;
            }
            if remaining.is_zero() {
                break;
            }
            // Leader exits wake the wait; other members are only observed by
            // polling.
            registry.wait_for_change(remaining.min(SESSION_POLL_INTERVAL));
        }
    }
    prune(registry, leader);
    let survivors = registry.lock().len();
    if survivors > 0 {
        eprintln!("lithe-remote-server: {survivors} process groups did not exit after SIGKILL");
    }
}

pub(crate) fn spawn_error(program: &str, error: io::Error) -> RemoteError {
    RemoteError::new(
        ErrorCode::SpawnFailed,
        format!("cannot start {program}: {error}"),
    )
    .with_details(json!({ "program": program, "osError": error.raw_os_error() }))
}

pub(crate) fn exit_parts(status: io::Result<ExitStatus>) -> (Option<i32>, Option<i32>) {
    match status {
        Ok(status) => (status.code(), status.signal()),
        Err(error) => {
            eprintln!("lithe-remote-server: waiting for a child failed: {error}");
            (None, None)
        }
    }
}

/// Starts a thread that writes queued chunks to `pipe`. Dropping the sender
/// (close or exit) ends the loop after queued writes, and dropping the pipe
/// delivers end-of-file to the child.
pub(crate) fn start_input_writer(mut pipe: impl Write + Send + 'static) -> SyncSender<Vec<u8>> {
    let (sender, receiver): (_, Receiver<Vec<u8>>) = mpsc::sync_channel(INPUT_QUEUE_CAPACITY);
    thread::spawn(move || {
        while let Ok(chunk) = receiver.recv() {
            if pipe.write_all(&chunk).is_err() {
                break;
            }
        }
    });
    sender
}

pub(crate) fn queue_input(queue: &SyncSender<Vec<u8>>, data: Vec<u8>) -> Result<(), RemoteError> {
    match queue.try_send(data) {
        Ok(()) => Ok(()),
        Err(TrySendError::Full(_)) => Err(RemoteError::new(
            ErrorCode::Busy,
            "the process is not reading its input",
        )),
        Err(TrySendError::Disconnected(_)) => Err(RemoteError::new(
            ErrorCode::InvalidRequest,
            "input is closed",
        )),
    }
}

/// Orders a child's output before its exit event.
///
/// Readers forward chunks while holding the gate; `finish` waits briefly for
/// the readers to reach end-of-file, then closes the gate and runs the exit
/// action under it. Output read after that is dropped, because it can only
/// come from descendants that inherited the pipe.
pub(crate) struct OutputGate {
    closed: Arc<Mutex<bool>>,
    drained: (mpsc::Sender<()>, Receiver<()>),
    readers: usize,
}

impl OutputGate {
    pub(crate) fn new() -> Self {
        Self {
            closed: Arc::new(Mutex::new(false)),
            drained: mpsc::channel(),
            readers: 0,
        }
    }

    pub(crate) fn start_reader(
        &mut self,
        mut pipe: impl Read + Send + 'static,
        forward: impl Fn(&[u8]) + Send + 'static,
    ) {
        self.readers += 1;
        let closed = Arc::clone(&self.closed);
        let drained = self.drained.0.clone();
        thread::spawn(move || {
            let mut buffer = vec![0_u8; OUTPUT_CHUNK_BYTES];
            loop {
                let read = match pipe.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(read) => read,
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                    // A terminal reports EIO once every slave descriptor is
                    // closed, which is its end-of-file.
                    Err(_) => break,
                };
                let closed = crate::lock(&closed);
                if !*closed {
                    forward(&buffer[..read]);
                }
            }
            let _ = drained.send(());
        });
    }

    pub(crate) fn finish(self, exit: impl FnOnce()) {
        let deadline = Instant::now() + OUTPUT_DRAIN_GRACE;
        for _ in 0..self.readers {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if self.drained.1.recv_timeout(remaining).is_err() {
                break;
            }
        }
        let mut closed = crate::lock(&self.closed);
        *closed = true;
        exit();
    }
}
