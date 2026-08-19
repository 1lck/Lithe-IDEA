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
#[cfg(target_os = "windows")]
use std::path::Path;
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
        let mut command = language_server_command(&spec);
        command
            .current_dir(&spec.working_directory)
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

fn language_server_command(spec: &LspProcessSpec) -> Command {
    #[cfg(target_os = "windows")]
    if is_windows_batch_script(&spec.executable) {
        let mut command = Command::new("cmd.exe");
        command.envs(&spec.environment);
        // Environment expansion is single-pass, so quoted values reach the batch
        // file without cmd.exe interpreting path metacharacters or percent pairs.
        command.env(
            WINDOWS_BATCH_EXECUTABLE_ENV,
            windows_batch_env_value(&spec.executable.to_string_lossy()),
        );
        for (index, argument) in spec.arguments.iter().enumerate() {
            command.env(
                windows_batch_argument_env(index),
                windows_batch_env_value(argument),
            );
        }
        command.raw_arg("/D");
        command.raw_arg("/S");
        command.raw_arg("/V:OFF");
        command.raw_arg("/C");
        command.raw_arg(windows_batch_command_line(spec.arguments.len()));
        return command;
    }

    let mut command = Command::new(&spec.executable);
    command.args(&spec.arguments).envs(&spec.environment);
    command
}

#[cfg(target_os = "windows")]
fn is_windows_batch_script(executable: &Path) -> bool {
    matches!(
        executable.extension().and_then(|extension| extension.to_str()),
        Some(extension) if extension.eq_ignore_ascii_case("bat") || extension.eq_ignore_ascii_case("cmd")
    )
}

#[cfg(target_os = "windows")]
const WINDOWS_BATCH_EXECUTABLE_ENV: &str = "LITHE_LSP_BATCH_EXECUTABLE";

#[cfg(target_os = "windows")]
fn windows_batch_argument_env(index: usize) -> String {
    format!("LITHE_LSP_BATCH_ARGUMENT_{index}")
}

#[cfg(target_os = "windows")]
fn windows_batch_command_line(argument_count: usize) -> String {
    let mut command_line = format!("\"%{WINDOWS_BATCH_EXECUTABLE_ENV}%\"");
    for index in 0..argument_count {
        command_line.push_str(&format!(" \"%{}%\"", windows_batch_argument_env(index)));
    }
    format!("\"{command_line}\"")
}

#[cfg(target_os = "windows")]
fn windows_batch_env_value(value: &str) -> String {
    let mut escaped = String::new();
    let mut backslashes = 0;
    for character in value.chars() {
        match character {
            '\\' => backslashes += 1,
            '"' => {
                escaped.push_str(&"\\".repeat(backslashes * 2 + 1));
                escaped.push('"');
                backslashes = 0;
            }
            _ => {
                escaped.push_str(&"\\".repeat(backslashes));
                escaped.push(character);
                backslashes = 0;
            }
        }
    }
    escaped.push_str(&"\\".repeat(backslashes * 2));
    escaped
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
    use super::{
        language_server_command, windows_batch_command_line, LspProcessLauncher, LspProcessSpec,
        SystemProcessLauncher, WINDOWS_BATCH_EXECUTABLE_ENV,
    };
    use std::collections::BTreeMap;
    use std::ffi::OsStr;
    use std::fs;
    use std::io::Read;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn background_language_servers_do_not_create_windows_console() {
        assert_eq!(super::language_server_process_creation_flags(), 0x0800_0000);
    }

    #[test]
    fn batch_language_server_uses_cmd_exe() {
        let spec = LspProcessSpec {
            executable: PathBuf::from(r"C:\Program Files\Lithe\jdtls.bat"),
            arguments: vec!["-data".to_string(), r"C:\workspace data".to_string()],
            working_directory: PathBuf::from(r"C:\workspace"),
            environment: BTreeMap::new(),
        };

        let command = language_server_command(&spec);

        assert_eq!(command.get_program(), OsStr::new("cmd.exe"));
        assert_eq!(
            windows_batch_command_line(spec.arguments.len()),
            r#"""%LITHE_LSP_BATCH_EXECUTABLE%" "%LITHE_LSP_BATCH_ARGUMENT_0%" "%LITHE_LSP_BATCH_ARGUMENT_1%"""#
        );
        assert!(command.get_envs().any(|(name, value)| {
            name == OsStr::new(WINDOWS_BATCH_EXECUTABLE_ENV)
                && value == Some(spec.executable.as_os_str())
        }));
    }

    #[test]
    fn batch_language_server_preserves_spaced_paths_and_shell_metacharacters() {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        let root = std::env::temp_dir().join(format!("lithe lsp batch {stamp}"));
        fs::create_dir_all(&root).expect("temp directory");
        let executable = root.join("scripted server.cmd");
        let argument_writer = root.join("write-argument.ps1");
        fs::write(
            &argument_writer,
            "[Console]::Out.Write(($args -join [Environment]::NewLine))\r\n",
        )
        .expect("PowerShell argument writer");
        fs::write(
            &executable,
            "@echo off\r\npowershell.exe -NoLogo -NoProfile -File \"%~dp0write-argument.ps1\" %*\r\n",
        )
        .expect("batch script");
        let arguments = vec![
            "workspace&echo_injected".to_string(),
            "percent%PATH%value".to_string(),
            "bang!value".to_string(),
            "caret^value".to_string(),
            "paren(value)".to_string(),
            "quoted\"value".to_string(),
            r"C:\workspace data\".to_string(),
        ];
        let spec = LspProcessSpec {
            executable,
            arguments: arguments.clone(),
            working_directory: root.clone(),
            environment: BTreeMap::new(),
        };

        let mut streams = SystemProcessLauncher
            .launch(spec)
            .expect("launch batch script");
        streams.handle.close_input();
        let mut output = String::new();
        streams.output.read_to_string(&mut output).expect("stdout");

        assert_eq!(output, arguments.join("\r\n"));
        fs::remove_dir_all(root).ok();
    }
}
