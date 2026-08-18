//! The language-server process boundary.
//!
//! The engine owns a language server's process and stdio, but it reaches them
//! only through these traits. That keeps the platform-specific spawn in one
//! place for the Windows client to substitute, and it lets the engine's
//! lifecycle rules -- deadlines, crash handling, restart isolation -- be tested
//! against a scripted server instead of a real one.

use crate::protocol::{CoreError, ErrorCode};
use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::{Arc, Mutex};

#[cfg(target_os = "windows")]
use std::os::windows::process::CommandExt;

/// Everything needed to start a language server, after provider adaptation has
/// already rewritten the arguments.
pub struct LspProcessSpec {
    pub executable: PathBuf,
    pub arguments: Vec<String>,
    pub working_directory: PathBuf,
    pub environment: BTreeMap<String, String>,
}

/// A running language-server process.
///
/// Every method is infallible-by-design except writing: a process that has
/// already exited is a normal state the engine reports through its own events,
/// not an error to propagate from the handle.
pub trait LspProcessHandle: Send + Sync {
    /// OS process identifier when the platform exposes one. Scripted test
    /// handles intentionally return no identifier.
    fn process_id(&self) -> Option<u32> {
        None
    }

    /// Writes one already-framed message and flushes it. Fails once the input
    /// stream is gone, which the engine turns into a transport failure.
    fn write_input(&self, frame: &[u8]) -> Result<(), CoreError>;

    /// Drops the input stream so the server observes EOF on stdin.
    fn close_input(&self);

    /// `Some` once the process has exited. The inner value is absent when the
    /// platform reports no exit code, as it does for a signalled process.
    fn exit_status(&self) -> Option<Option<i32>>;

    /// Ends the process without waiting for it to agree.
    fn terminate(&self);
}

/// A launched process and the two streams the engine reads on its own threads.
pub struct LspProcessStreams {
    pub handle: Arc<dyn LspProcessHandle>,
    pub output: Box<dyn Read + Send>,
    pub errors: Box<dyn Read + Send>,
}

/// Factory boundary used by the engine to start real or scripted servers.
pub trait LspProcessLauncher: Send + Sync {
    /// Starts one process and transfers ownership of its handle and output streams.
    fn launch(&self, spec: LspProcessSpec) -> Result<LspProcessStreams, CoreError>;
}

/// Starts language servers as real child processes with piped stdio.
pub struct SystemProcessLauncher;

impl LspProcessLauncher for SystemProcessLauncher {
    fn launch(&self, spec: LspProcessSpec) -> Result<LspProcessStreams, CoreError> {
        let mut command = Command::new(&spec.executable);
        command
            .args(&spec.arguments)
            .current_dir(&spec.working_directory)
            .envs(&spec.environment)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        apply_language_server_creation_flags(&mut command);
        let mut child = command.spawn().map_err(|error| {
            CoreError::new(
                ErrorCode::ProcessStartFailed,
                "Could not start the language-server process.",
            )
            .with_details(error.to_string())
        })?;
        let stdin = child.stdin.take().ok_or_else(|| missing_stream("stdin"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| missing_stream("stdout"))?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| missing_stream("stderr"))?;
        Ok(LspProcessStreams {
            handle: Arc::new(SystemProcess {
                input: Mutex::new(Some(stdin)),
                child: Mutex::new(child),
            }),
            output: Box::new(stdout),
            errors: Box::new(stderr),
        })
    }
}

fn apply_language_server_creation_flags(command: &mut Command) {
    #[cfg(target_os = "windows")]
    command.creation_flags(language_server_process_creation_flags());

    #[cfg(not(target_os = "windows"))]
    let _ = command;
}

#[cfg(target_os = "windows")]
fn language_server_process_creation_flags() -> u32 {
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    CREATE_NO_WINDOW
}

struct SystemProcess {
    input: Mutex<Option<ChildStdin>>,
    child: Mutex<Child>,
}

impl LspProcessHandle for SystemProcess {
    fn process_id(&self) -> Option<u32> {
        self.child.lock().ok().map(|child| child.id())
    }

    fn write_input(&self, frame: &[u8]) -> Result<(), CoreError> {
        let mut input = self.input.lock().map_err(|_| {
            CoreError::new(
                ErrorCode::Unknown,
                "Language-server stdin lock was poisoned.",
            )
        })?;
        let input = input.as_mut().ok_or_else(|| {
            CoreError::new(ErrorCode::ProcessFailed, "Language-server stdin is closed.")
        })?;
        input.write_all(frame).map_err(|error| {
            CoreError::new(
                ErrorCode::ProcessFailed,
                "Could not write to language-server stdin.",
            )
            .with_details(error.to_string())
        })?;
        input.flush().map_err(|error| {
            CoreError::new(
                ErrorCode::ProcessFailed,
                "Could not flush language-server stdin.",
            )
            .with_details(error.to_string())
        })
    }

    fn close_input(&self) {
        if let Ok(mut input) = self.input.lock() {
            *input = None;
        }
    }

    fn exit_status(&self) -> Option<Option<i32>> {
        self.child
            .lock()
            .ok()
            .and_then(|mut child| child.try_wait().ok().flatten())
            .map(|status| status.code())
    }

    fn terminate(&self) {
        if let Ok(mut child) = self.child.lock() {
            let _ = child.kill();
        }
    }
}

fn missing_stream(stream: &str) -> CoreError {
    CoreError::new(
        ErrorCode::ProcessStartFailed,
        "A language-server standard stream was unavailable.",
    )
    .with_details(stream)
}

#[cfg(all(test, target_os = "windows"))]
mod tests {
    #[test]
    fn background_language_servers_do_not_create_windows_console() {
        assert_eq!(super::language_server_process_creation_flags(), 0x0800_0000);
    }
}
