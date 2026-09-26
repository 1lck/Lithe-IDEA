//! Detection of the user-installed runtime that npm-distributed agents need.
//!
//! Lithe never installs Node.js; it only reports what it finds. GUI apps on
//! macOS do not inherit the login shell's `PATH`, so version managers such as
//! nvm or fnm are invisible unless the shell is asked for its `PATH`.

use std::ffi::OsString;
use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::Serialize;

const SHELL_TIMEOUT: Duration = Duration::from_secs(10);
const VERSION_TIMEOUT: Duration = Duration::from_secs(10);
const POLL_INTERVAL: Duration = Duration::from_millis(50);
/// How long to wait for output after the child exited or was killed.
const OUTPUT_GRACE: Duration = Duration::from_secs(2);
const PATH_START: &str = "__LITHE_PATH_START__";
const PATH_END: &str = "__LITHE_PATH_END__";

/// Most recent search path, refreshed by [`detect`] and reused by launches.
static SEARCH_PATH: Mutex<Option<OsString>> = Mutex::new(None);

/// A tool found on the search path.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct DetectedTool {
    pub version: String,
    pub path: PathBuf,
}

/// Node.js and npm as seen by agent launches and installs.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeEnvironment {
    pub node: Option<DetectedTool>,
    pub npm: Option<DetectedTool>,
    /// Whether the login shell reported a `PATH`; false means only the app's
    /// own `PATH` was searched.
    pub used_login_shell: bool,
}

impl RuntimeEnvironment {
    /// Major version of the detected Node.js, e.g. 22 for `v22.3.1`.
    pub fn node_major(&self) -> Option<u32> {
        self.node
            .as_ref()
            .and_then(|node| parse_major(&node.version))
    }
}

/// Failure of a bounded child process.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum RunError {
    Start(String),
    TimedOut,
    Cancelled,
}

/// Detect Node.js and npm, refreshing the cached search path.
pub fn detect(cancel: &dyn Fn() -> bool) -> RuntimeEnvironment {
    let shell_path = login_shell_path(cancel);
    let used_login_shell = shell_path.is_some();
    let path = merge_paths(shell_path, std::env::var_os("PATH"));
    if let Ok(mut cached) = SEARCH_PATH.lock() {
        *cached = path.clone();
    }
    let tool = |name: &str| {
        let executable = find_executable(name, path.as_deref())?;
        let version = tool_version(&executable, path.as_deref(), cancel)?;
        Some(DetectedTool {
            version,
            path: executable,
        })
    };
    RuntimeEnvironment {
        node: tool("node"),
        npm: tool("npm"),
        used_login_shell,
    }
}

/// Search path for launching agents, detecting it on first use.
pub fn search_path() -> Option<OsString> {
    if let Some(path) = SEARCH_PATH.lock().ok().and_then(|cached| cached.clone()) {
        return Some(path);
    }
    detect(&|| false);
    SEARCH_PATH.lock().ok().and_then(|cached| cached.clone())
}

/// `PATH` reported by the user's interactive login shell (Unix only).
fn login_shell_path(cancel: &dyn Fn() -> bool) -> Option<OsString> {
    if cfg!(windows) {
        return None;
    }
    let shell = std::env::var_os("SHELL")
        .filter(|shell| !shell.is_empty())
        .unwrap_or_else(|| OsString::from("/bin/sh"));
    let is_fish = Path::new(&shell)
        .file_name()
        .is_some_and(|name| name == "fish");
    // Markers separate the value from greetings printed by shell startup files.
    let script = if is_fish {
        format!("printf '{PATH_START}%s{PATH_END}' (string join : $PATH)")
    } else {
        format!("printf '{PATH_START}%s{PATH_END}' \"$PATH\"")
    };
    let mut command = Command::new(&shell);
    command.args(["-i", "-l", "-c", &script]);
    let output = run_bounded(command, SHELL_TIMEOUT, cancel).ok()?;
    parse_marked_path(&output)
}

fn parse_marked_path(output: &str) -> Option<OsString> {
    let start = output.rfind(PATH_START)? + PATH_START.len();
    let end = start + output[start..].find(PATH_END)?;
    let path = output[start..end].trim();
    (!path.is_empty()).then(|| OsString::from(path))
}

/// Shell entries first, then the app's own entries not already present.
fn merge_paths(first: Option<OsString>, second: Option<OsString>) -> Option<OsString> {
    let mut entries: Vec<PathBuf> = Vec::new();
    for path in [first, second].into_iter().flatten() {
        for entry in std::env::split_paths(&path) {
            if !entry.as_os_str().is_empty() && !entries.contains(&entry) {
                entries.push(entry);
            }
        }
    }
    (!entries.is_empty())
        .then(|| std::env::join_paths(entries).ok())
        .flatten()
}

/// First `name` executable on `path`; on Windows also `name.cmd` and `name.exe`.
pub(crate) fn find_executable(name: &str, path: Option<&std::ffi::OsStr>) -> Option<PathBuf> {
    let candidates: &[&str] = if cfg!(windows) {
        &[".exe", ".cmd", ""]
    } else {
        &[""]
    };
    std::env::split_paths(path?).find_map(|directory| {
        candidates
            .iter()
            .map(|suffix| directory.join(format!("{name}{suffix}")))
            .find(|candidate| is_executable(candidate))
    })
}

fn is_executable(path: &Path) -> bool {
    let Ok(metadata) = std::fs::metadata(path) else {
        return false;
    };
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        metadata.is_file() && metadata.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        metadata.is_file()
    }
}

fn tool_version(
    executable: &Path,
    path: Option<&std::ffi::OsStr>,
    cancel: &dyn Fn() -> bool,
) -> Option<String> {
    let mut command = Command::new(executable);
    command.arg("--version");
    if let Some(path) = path {
        command.env("PATH", path);
    }
    let output = run_bounded(command, VERSION_TIMEOUT, cancel).ok()?;
    let line = output
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())?;
    // `v22.3.1`, `10.2.4`, or a named banner such as `codex-cli 0.156.1`.
    let version = line
        .split_whitespace()
        .map(|token| token.trim_start_matches('v'))
        .find(|token| token.starts_with(|c: char| c.is_ascii_digit()))
        .unwrap_or(line);
    Some(version.to_owned())
}

/// Find `command` on the agent search path and read its version.
pub fn detect_tool(command: &str, cancel: &dyn Fn() -> bool) -> Option<DetectedTool> {
    let path = search_path();
    let executable = find_executable(command, path.as_deref())?;
    let version = tool_version(&executable, path.as_deref(), cancel)?;
    Some(DetectedTool {
        version,
        path: executable,
    })
}

/// Whether dotted `version` is at least `minimum`, comparing numeric parts;
/// pre-release suffixes such as `-alpha.1` are ignored.
pub fn version_at_least(version: &str, minimum: &str) -> bool {
    let parts = |value: &str| -> Vec<u64> {
        value
            .trim()
            .trim_start_matches('v')
            .split(['-', '+'])
            .next()
            .unwrap_or_default()
            .split('.')
            .map(|part| part.parse().unwrap_or(0))
            .collect()
    };
    let (version, minimum) = (parts(version), parts(minimum));
    for index in 0..version.len().max(minimum.len()) {
        let (left, right) = (
            version.get(index).copied().unwrap_or(0),
            minimum.get(index).copied().unwrap_or(0),
        );
        if left != right {
            return left > right;
        }
    }
    true
}

/// Major version of `22.3.1` or `v22.3.1`.
pub fn parse_major(version: &str) -> Option<u32> {
    version
        .trim()
        .trim_start_matches('v')
        .split('.')
        .next()?
        .parse()
        .ok()
}

/// Run a child to completion within `timeout`, returning combined output.
///
/// Output is collected on reader threads so a chatty child cannot block on a
/// full pipe. The child is killed on timeout or cancellation.
pub(crate) fn run_bounded(
    mut command: Command,
    timeout: Duration,
    cancel: &dyn Fn() -> bool,
) -> Result<String, RunError> {
    let (status, output) = run_bounded_status(&mut command, timeout, cancel)?;
    if status {
        Ok(output)
    } else {
        Err(RunError::Start(output))
    }
}

/// Like [`run_bounded`], but returns whether the child succeeded with its output.
pub(crate) fn run_bounded_status(
    command: &mut Command,
    timeout: Duration,
    cancel: &dyn Fn() -> bool,
) -> Result<(bool, String), RunError> {
    run_bounded_status_observed(command, timeout, cancel, &mut |_| {})
}

/// Streams bounded output lines on the caller thread while retaining a diagnostic tail.
/// Observers must not block; their lifetime ends before this function returns.
pub(crate) fn run_bounded_status_observed(
    command: &mut Command,
    timeout: Duration,
    cancel: &dyn Fn() -> bool,
    observe: &mut dyn FnMut(&str),
) -> Result<(bool, String), RunError> {
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        // Keep the child in its own group so a terminal-reading shell cannot
        // stop Lithe with SIGTTIN, and so the whole tree can be killed.
        command.process_group(0);
    }
    let mut child = command
        .spawn()
        .map_err(|error| RunError::Start(error.to_string()))?;
    let (output_tx, output_rx) = std::sync::mpsc::sync_channel::<Option<Vec<u8>>>(32);
    let readers = [
        child
            .stdout
            .take()
            .map(|p| Box::new(p) as Box<dyn std::io::Read + Send>),
        child
            .stderr
            .take()
            .map(|p| Box::new(p) as Box<dyn std::io::Read + Send>),
    ]
    .into_iter()
    .flatten()
    .map(|pipe| {
        let sender = output_tx.clone();
        std::thread::spawn(move || {
            let mut reader = BufReader::new(pipe);
            // Bound individual lines even if a child never writes a newline.
            loop {
                let mut bytes = Vec::new();
                let read = std::io::Read::by_ref(&mut reader)
                    .take(8192)
                    .read_until(b'\n', &mut bytes);
                match read {
                    Ok(0) | Err(_) => break,
                    Ok(_) if sender.send(Some(bytes)).is_err() => return,
                    _ => {}
                }
            }
            let _ = sender.send(None);
        });
        1
    })
    .sum::<usize>();
    drop(output_tx);
    let mut output = String::new();
    let ended = std::cell::Cell::new(0);
    let mut collect = |event: Option<Vec<u8>>| {
        if let Some(bytes) = event {
            let text = String::from_utf8_lossy(&bytes);
            observe(&text);
            output.push_str(&text);
            if output.len() > 65536 {
                let mut first = output.len() - 65536;
                while !output.is_char_boundary(first) {
                    first += 1;
                }
                output.drain(..first);
            }
        } else {
            ended.set(ended.get() + 1);
        }
    };
    let deadline = Instant::now() + timeout;
    let outcome = loop {
        // A chatty process must not starve cancellation or its deadline.
        for _ in 0..32 {
            match output_rx.try_recv() {
                Ok(event) => collect(event),
                Err(_) => break,
            }
        }
        match child.try_wait() {
            Ok(Some(status)) => break Ok(status.success()),
            Ok(None) if cancel() => break Err(RunError::Cancelled),
            Ok(None) if Instant::now() >= deadline => break Err(RunError::TimedOut),
            Ok(None) => std::thread::sleep(POLL_INTERVAL),
            Err(error) => break Err(RunError::Start(error.to_string())),
        }
    };
    if outcome.is_err() {
        crate::force_kill_tree(child.id());
        let _ = child.wait();
    }
    // A descendant that left the process group can hold a pipe open; do not
    // let it block the caller past a short grace period.
    let output_deadline = Instant::now() + OUTPUT_GRACE;
    while ended.get() < readers {
        match output_rx.recv_timeout(output_deadline.saturating_duration_since(Instant::now())) {
            Ok(event) => {
                collect(event);
            }
            Err(_) => break,
        }
    }
    drop(collect);
    outcome.map(|success| (success, output))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn marked_path_ignores_shell_greetings() {
        let output = format!("Welcome!\n{PATH_START}/opt/node/bin:/usr/bin{PATH_END}\nbye");
        assert_eq!(
            parse_marked_path(&output),
            Some(OsString::from("/opt/node/bin:/usr/bin"))
        );
        assert_eq!(parse_marked_path("no markers"), None);
        assert_eq!(parse_marked_path(&format!("{PATH_START}{PATH_END}")), None);
    }

    #[test]
    fn merged_path_keeps_shell_order_without_duplicates() {
        let merged = merge_paths(
            Some(std::env::join_paths(["/shell/bin", "/usr/bin"]).unwrap()),
            Some(std::env::join_paths(["/usr/bin", "/app/bin"]).unwrap()),
        )
        .unwrap();
        let entries: Vec<PathBuf> = std::env::split_paths(&merged).collect();
        assert_eq!(
            entries,
            [
                PathBuf::from("/shell/bin"),
                "/usr/bin".into(),
                "/app/bin".into()
            ]
        );
        assert_eq!(merge_paths(None, None), None);
    }

    #[test]
    fn versions_compare_numerically() {
        assert!(version_at_least("0.156.1", "0.156.0"));
        assert!(version_at_least("0.160.0", "0.156.0"));
        assert!(version_at_least("1.0.0", "0.156.0"));
        assert!(!version_at_least("0.99.9", "0.156.0"));
        assert!(!version_at_least("0.155.9-alpha.1", "0.156.0"));
        assert!(version_at_least("v22", "22.0.0"));
    }

    #[test]
    fn major_versions_parse_with_or_without_prefix() {
        assert_eq!(parse_major("v22.3.1"), Some(22));
        assert_eq!(parse_major("20.11.0"), Some(20));
        assert_eq!(parse_major("latest"), None);
    }

    #[cfg(unix)]
    #[test]
    fn bounded_run_reports_timeout_and_cancellation() {
        let sleeper = || {
            let mut command = Command::new("sh");
            command.args(["-c", "sleep 30"]);
            command
        };
        let started = Instant::now();
        assert_eq!(
            run_bounded(sleeper(), Duration::from_millis(200), &|| false),
            Err(RunError::TimedOut)
        );
        assert_eq!(
            run_bounded(sleeper(), Duration::from_secs(30), &|| true),
            Err(RunError::Cancelled)
        );
        assert!(
            started.elapsed() < Duration::from_secs(10),
            "child was killed"
        );
        let mut echo = Command::new("sh");
        echo.args(["-c", "echo out; echo err >&2"]);
        let output = run_bounded(echo, Duration::from_secs(10), &|| false).unwrap();
        assert!(output.contains("out") && output.contains("err"));
    }

    #[cfg(unix)]
    #[test]
    fn executables_are_found_only_when_runnable() {
        use std::os::unix::fs::PermissionsExt;
        let directory = std::env::temp_dir().join(format!("lithe-env-{}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();
        let tool = directory.join("lithe-tool");
        std::fs::write(&tool, "#!/bin/sh\necho lithe-tool v1.2.3\n").unwrap();
        let path = OsString::from(directory.as_os_str());
        assert_eq!(
            find_executable("lithe-tool", Some(&path)),
            None,
            "not executable yet"
        );
        std::fs::set_permissions(&tool, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(
            find_executable("lithe-tool", Some(&path)),
            Some(tool.clone())
        );
        assert_eq!(
            tool_version(&tool, Some(&path), &|| false).as_deref(),
            Some("1.2.3")
        );
        let _ = std::fs::remove_dir_all(&directory);
    }
}
