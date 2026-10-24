//! Bounded one-shot commands, used for probing and installing the server.

use std::io::{self, Read, Write};
use std::process::{Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

/// Output bytes kept per stream. Probe and install output is small; anything
/// larger is a misbehaving remote and only its beginning is useful.
const CAPTURE_LIMIT_BYTES: usize = 1024 * 1024;

/// Interval between exit checks. Bootstrap commands run for seconds over a
/// network, so this adds no noticeable latency.
const EXIT_POLL_INTERVAL: Duration = Duration::from_millis(20);

/// How long output pipes may stay open after the command exited. An SSH
/// `ControlPersist` master or a daemonized remote process can inherit them and
/// keep them open indefinitely.
const OUTPUT_DRAIN_GRACE: Duration = Duration::from_millis(500);

#[derive(Debug)]
pub struct CommandOutput {
    /// Exit code; `None` when the command was terminated by a signal.
    pub status: Option<i32>,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

impl CommandOutput {
    pub fn success(&self) -> bool {
        self.status == Some(0)
    }

    /// Standard error for user-facing diagnostics.
    pub fn stderr_text(&self) -> String {
        String::from_utf8_lossy(&self.stderr).trim().to_owned()
    }
}

/// Runs `argv` locally, feeding it `stdin`, and kills it after `timeout`.
pub fn run(argv: &[String], stdin: Option<&[u8]>, timeout: Duration) -> io::Result<CommandOutput> {
    let (program, arguments) = argv
        .split_first()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "empty command"))?;
    let mut child = Command::new(program)
        .args(arguments)
        .stdin(if stdin.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;

    let writer = match (child.stdin.take(), stdin) {
        (Some(mut pipe), Some(bytes)) => {
            let bytes = bytes.to_vec();
            // A remote that exits early closes the pipe; its exit status and
            // standard error then explain why, so the write error is not used.
            Some(thread::spawn(move || {
                let _ = pipe.write_all(&bytes);
            }))
        }
        _ => None,
    };
    let stdout = capture(child.stdout.take());
    let stderr = capture(child.stderr.take());

    let deadline = Instant::now() + timeout;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                format!(
                    "{program} did not finish within {} seconds",
                    timeout.as_secs()
                ),
            ));
        }
        thread::sleep(EXIT_POLL_INTERVAL);
    };
    // The writer thread is detached: it ends when the pipe closes, which
    // the exited command already did unless a descendant inherited it.
    drop(writer);
    let drain_deadline = Instant::now() + OUTPUT_DRAIN_GRACE;
    Ok(CommandOutput {
        status: status.code(),
        stdout: stdout.collect(drain_deadline),
        stderr: stderr.collect(drain_deadline),
    })
}

struct Capture {
    bytes: Arc<Mutex<Vec<u8>>>,
    finished: Receiver<()>,
}

impl Capture {
    /// Returns what was read once the pipe closed, or at `deadline` if a
    /// descendant still holds it open.
    fn collect(self, deadline: Instant) -> Vec<u8> {
        let _ = self
            .finished
            .recv_timeout(deadline.saturating_duration_since(Instant::now()));
        let bytes = self
            .bytes
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        bytes.clone()
    }
}

fn capture(pipe: Option<impl Read + Send + 'static>) -> Capture {
    let bytes = Arc::new(Mutex::new(Vec::new()));
    let (finished_sender, finished) = mpsc::channel();
    let shared = Arc::clone(&bytes);
    thread::spawn(move || {
        if let Some(mut pipe) = pipe {
            let mut buffer = [0_u8; 8192];
            loop {
                match pipe.read(&mut buffer) {
                    Ok(0) | Err(_) => break,
                    Ok(read) => {
                        let mut captured = shared
                            .lock()
                            .unwrap_or_else(|poisoned| poisoned.into_inner());
                        let room = CAPTURE_LIMIT_BYTES.saturating_sub(captured.len());
                        captured.extend_from_slice(&buffer[..read.min(room)]);
                    }
                }
            }
        }
        let _ = finished_sender.send(());
    });
    Capture { bytes, finished }
}
