//! Interactive terminals backed by pseudo-terminals.
//!
//! The program, by default the user's login shell, becomes a session leader
//! with the pseudo-terminal as its controlling terminal, exactly as an SSH
//! login would set it up. Job control, `Ctrl-C` and window-size changes
//! therefore behave as users expect.

use crate::connection::Context;
use crate::fs::host_path;
use crate::platform::{self, ChildKind};
use crate::process::{
    exit_parts, prune, queue_input, spawn_error, start_input_writer, terminate_groups, Leader,
    OutputGate,
};
use crate::resources::Registry;
use crate::session::{Session, TERMINATION_GRACE};
use crate::{parse, to_value};
use lithe_remote_protocol::methods::{
    self, decode_bytes, encode_bytes, TerminalExitEvent, TerminalOpenParams, TerminalOpenResult,
    TerminalOutputEvent, TerminalParams, TerminalResizeParams, TerminalState, TerminalWriteParams,
};
use lithe_remote_protocol::{ErrorCode, RemoteError};
use serde_json::Value;
use std::fs::File;
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::mpsc::SyncSender;
use std::sync::Arc;
use std::thread;

const DEFAULT_TERM: &str = "xterm-256color";

/// Shell used when the account has none, which happens in minimal images.
const FALLBACK_SHELL: &str = "/bin/sh";

pub(crate) struct TerminalTable {
    registry: Registry<RunningTerminal>,
}

struct RunningTerminal {
    /// Kept after the shell exits while jobs it started still run, so that
    /// closing the terminal or ending the session still reaches them.
    leader: Leader,
    columns: u16,
    rows: u16,
    master: Arc<OwnedFd>,
    /// `None` after `terminal.close`.
    input: Option<SyncSender<Vec<u8>>>,
}

impl TerminalTable {
    pub(crate) fn new() -> Self {
        Self {
            registry: Registry::new("terminal"),
        }
    }

    pub(crate) fn handle(
        &self,
        context: &Context,
        method: &str,
        params: Value,
    ) -> Result<Value, RemoteError> {
        match method {
            methods::TERMINAL_OPEN => to_value(self.open(&context.session, parse(params)?)?),
            methods::TERMINAL_WRITE => self.write(parse(params)?).map(|()| Value::Null),
            methods::TERMINAL_RESIZE => self.resize(parse(params)?).map(|()| Value::Null),
            methods::TERMINAL_CLOSE => self
                .close(&context.session, parse(params)?)
                .map(|()| Value::Null),
            _ => Err(RemoteError::new(
                ErrorCode::UnknownMethod,
                format!("unknown method {method}"),
            )),
        }
    }

    pub(crate) fn states(&self) -> Vec<TerminalState> {
        self.registry
            .lock()
            .iter()
            .filter(|(_, terminal)| !terminal.leader.exited)
            .map(|(terminal_id, terminal)| TerminalState {
                terminal_id: *terminal_id,
                pid: terminal.leader.pid,
                columns: terminal.columns,
                rows: terminal.rows,
            })
            .collect()
    }

    fn open(
        &self,
        session: &Arc<Session>,
        params: TerminalOpenParams,
    ) -> Result<TerminalOpenResult, RemoteError> {
        session.ids.observe(params.terminal_id);
        self.registry.ensure_free(params.terminal_id)?;
        let account = platform::current_account();
        let mut command = match &params.argv {
            Some(argv) => {
                let Some((program, arguments)) = argv.split_first() else {
                    return Err(RemoteError::new(ErrorCode::InvalidRequest, "argv is empty"));
                };
                let mut command = Command::new(program);
                command.args(arguments);
                command
            }
            None => {
                let shell = account
                    .shell
                    .clone()
                    .unwrap_or_else(|| FALLBACK_SHELL.into());
                let mut command = Command::new(&shell);
                // A leading `-` in argv[0] is the POSIX convention for a login
                // shell, understood by sh, bash, zsh, fish and csh alike.
                let name = Path::new(&shell)
                    .file_name()
                    .map(|name| name.to_string_lossy().into_owned())
                    .unwrap_or_else(|| "sh".into());
                command.arg0(format!("-{name}"));
                command
            }
        };
        let directory = match &params.cwd {
            Some(cwd) => host_path(cwd)?,
            None => account
                .home_directory
                .as_deref()
                .map(std::path::PathBuf::from)
                .unwrap_or_else(|| "/".into()),
        };
        let (master, slave) = platform::open_pty(params.columns, params.rows)
            .map_err(|error| crate::fs::io_error(error, ""))?;
        let stdio = |fd: &OwnedFd| -> Result<Stdio, RemoteError> {
            fd.try_clone()
                .map(Stdio::from)
                .map_err(|error| crate::fs::io_error(error, ""))
        };
        command
            .current_dir(directory)
            .env("TERM", DEFAULT_TERM)
            .envs(&params.env)
            .stdin(stdio(&slave)?)
            .stdout(stdio(&slave)?)
            .stderr(stdio(&slave)?);
        platform::prepare_child(&mut command, ChildKind::Terminal);
        let program = command.get_program().to_string_lossy().into_owned();
        // The command, and with it the parent's copies of the slave side, is
        // dropped on the spawner thread right after the fork.
        let child = session
            .spawner
            .run(move || command.spawn())
            .map_err(|error| spawn_error(&program, error))?;
        drop(slave);

        let master = Arc::new(master);
        let reader = File::from(
            master
                .try_clone()
                .map_err(|error| crate::fs::io_error(error, ""))?,
        );
        let writer = File::from(
            master
                .try_clone()
                .map_err(|error| crate::fs::io_error(error, ""))?,
        );
        let pid = child.id();
        let entry = RunningTerminal {
            leader: Leader::new(pid),
            columns: params.columns,
            rows: params.rows,
            master,
            input: Some(start_input_writer(writer)),
        };
        if let Err(error) = self.registry.insert(params.terminal_id, entry) {
            let _ = platform::signal_process_group(pid, libc::SIGKILL);
            return Err(error);
        }

        let terminal_id = params.terminal_id;
        let mut gate = OutputGate::new();
        let output_session = Arc::clone(session);
        gate.start_reader(reader, move |chunk| {
            output_session.link.emit(
                methods::EVENT_TERMINAL_OUTPUT,
                TerminalOutputEvent {
                    terminal_id,
                    data: encode_bytes(chunk),
                },
            );
        });
        let session = Arc::clone(session);
        let mut child = child;
        thread::spawn(move || {
            let status = child.wait();
            gate.finish(|| {
                let registry = &session.terminals.registry;
                if let Some(terminal) = registry.lock().get_mut(&terminal_id) {
                    terminal.leader.exited = true;
                    terminal.input = None;
                }
                prune(registry, |terminal| &terminal.leader);
                let (exit_code, signal) = exit_parts(status);
                session.link.emit(
                    methods::EVENT_TERMINAL_EXIT,
                    TerminalExitEvent {
                        terminal_id,
                        exit_code,
                        signal,
                    },
                );
            });
        });
        Ok(TerminalOpenResult { pid })
    }

    fn write(&self, params: TerminalWriteParams) -> Result<(), RemoteError> {
        let data = decode_bytes(&params.data)
            .map_err(|error| RemoteError::new(ErrorCode::InvalidRequest, error.to_string()))?;
        let terminals = self.registry.lock();
        let terminal = terminals
            .get(&params.terminal_id)
            .filter(|terminal| !terminal.leader.exited)
            .ok_or_else(|| self.registry.unknown(params.terminal_id))?;
        let Some(input) = &terminal.input else {
            return Err(RemoteError::new(
                ErrorCode::InvalidRequest,
                "the terminal is closing",
            ));
        };
        queue_input(input, data)
    }

    fn resize(&self, params: TerminalResizeParams) -> Result<(), RemoteError> {
        let mut terminals = self.registry.lock();
        let terminal = terminals
            .get_mut(&params.terminal_id)
            .filter(|terminal| !terminal.leader.exited)
            .ok_or_else(|| self.registry.unknown(params.terminal_id))?;
        // The kernel sends SIGWINCH to the foreground process group.
        platform::set_window_size(terminal.master.as_raw_fd(), params.columns, params.rows)
            .map_err(|error| crate::fs::io_error(error, ""))?;
        terminal.columns = params.columns;
        terminal.rows = params.rows;
        Ok(())
    }

    /// Hangs up the terminal like closing a terminal window: `SIGHUP` to its
    /// whole session, including background jobs, and `SIGKILL` after a grace
    /// period to whatever ignored it.
    fn close(&self, session: &Arc<Session>, params: TerminalParams) -> Result<(), RemoteError> {
        let pid = {
            let mut terminals = self.registry.lock();
            let terminal = terminals
                .get_mut(&params.terminal_id)
                .ok_or_else(|| self.registry.unknown(params.terminal_id))?;
            terminal.input = None;
            terminal.leader.pid
        };
        let _ = platform::signal_session(pid, libc::SIGHUP);
        let session = Arc::clone(session);
        let terminal_id = params.terminal_id;
        thread::spawn(move || {
            let terminals = &session.terminals.registry;
            let deadline = std::time::Instant::now() + TERMINATION_GRACE;
            let owned = || {
                prune(terminals, |terminal| &terminal.leader);
                terminals
                    .lock()
                    .get(&terminal_id)
                    .is_some_and(|terminal| terminal.leader.pid == pid)
            };
            while std::time::Instant::now() < deadline {
                if !owned() {
                    return;
                }
                // Jobs that are not the server's children report no exit, so
                // the wait also wakes periodically to re-check the session.
                let remaining = deadline.saturating_duration_since(std::time::Instant::now());
                terminals.wait_for_change(remaining.min(std::time::Duration::from_millis(20)));
            }
            if owned() {
                let _ = platform::signal_session(pid, libc::SIGKILL);
            }
        });
        Ok(())
    }

    pub(crate) fn terminate_all(&self, grace: std::time::Duration) {
        terminate_groups(
            &self.registry,
            grace,
            |terminal| &terminal.leader,
            libc::SIGHUP,
        );
    }
}
