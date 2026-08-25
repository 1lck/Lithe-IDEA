//! A scripted language server for engine tests.
//!
//! The engine's hardest rules are about timing and terminal outcomes: a request
//! that outlives its deadline, a late response that must be ignored, a crash
//! that fails everything pending exactly once. Driving those with a real server
//! means either sleeping past real timeouts or racing them. This double lets a
//! test deliver bytes and exits at chosen moments, so each rule is asserted
//! directly rather than approximated.

#![cfg(test)]

use super::process::{LspProcessHandle, LspProcessLauncher, LspProcessSpec, LspProcessStreams};
use crate::protocol::{CoreError, ErrorCode};
use serde_json::Value;
use std::io::Read;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

/// A language server a test writes the script for.
pub struct ScriptedServer {
    shared: Arc<ScriptedShared>,
}

struct ScriptedShared {
    /// Bytes the engine has written, kept raw so framing itself can be asserted.
    written: Mutex<Vec<u8>>,
    /// Bytes the test has queued for the engine to read, with `ready` signalling
    /// arrival so the reader thread blocks instead of spinning.
    pending_output: Mutex<Vec<u8>>,
    ready: Condvar,
    /// `Some` once the process has exited, mirroring `exit_status`.
    exit: Mutex<Option<Option<i32>>>,
    input_closed: AtomicBool,
    /// Set when the test wants writes to fail, standing in for a broken pipe.
    input_broken: AtomicBool,
    spec: Mutex<Option<LaunchedSpec>>,
}

/// What the engine asked the launcher for, so tests can assert provider
/// adaptation without reaching into the JDT module.
#[derive(Clone)]
pub struct LaunchedSpec {
    pub executable: String,
    pub arguments: Vec<String>,
    pub working_directory: String,
}

impl ScriptedServer {
    pub fn new() -> Self {
        Self {
            shared: Arc::new(ScriptedShared {
                written: Mutex::new(Vec::new()),
                pending_output: Mutex::new(Vec::new()),
                ready: Condvar::new(),
                exit: Mutex::new(None),
                input_closed: AtomicBool::new(false),
                input_broken: AtomicBool::new(false),
                spec: Mutex::new(None),
            }),
        }
    }

    /// A launcher that hands this server to the engine. Cloning the handle keeps
    /// the test's control surface alive after the engine takes ownership.
    pub fn launcher(&self) -> Arc<dyn LspProcessLauncher> {
        Arc::new(ScriptedLauncher {
            shared: self.shared.clone(),
        })
    }

    pub fn launched_spec(&self) -> Option<LaunchedSpec> {
        self.shared.spec.lock().unwrap().clone()
    }

    /// Sends one framed JSON-RPC message to the engine.
    pub fn send(&self, message: Value) {
        let body = message.to_string();
        self.send_raw(format!("Content-Length: {}\r\n\r\n{body}", body.len()).as_bytes());
    }

    /// Sends bytes verbatim, for framing and partial-frame tests.
    pub fn send_raw(&self, bytes: &[u8]) {
        self.shared
            .pending_output
            .lock()
            .unwrap()
            .extend_from_slice(bytes);
        self.shared.ready.notify_all();
    }

    /// Answers the standard `initialize` request with the given capabilities.
    /// Providers with a second readiness phase remain initializing afterward.
    pub fn complete_initialize(&self, capabilities: Value) {
        let id = self
            .await_request("initialize")
            .expect("the engine should send initialize");
        self.send(serde_json::json!({
            "jsonrpc": "2.0",
            "id": id,
            "result": {
                "capabilities": capabilities,
                "serverInfo": { "name": "scripted", "version": "1.0.0" }
            }
        }));
    }

    /// Completes both the standard handshake and JDT LS project-import phase.
    pub fn complete_java_initialize(&self, capabilities: Value) {
        self.complete_initialize(capabilities);
        self.send(serde_json::json!({
            "jsonrpc": "2.0",
            "method": "language/status",
            "params": { "type": "ServiceReady" }
        }));
    }

    /// Blocks until the engine has written a request for `method`, returning its
    /// JSON-RPC id. Polling the written bytes is what lets a test stay in step
    /// with the engine's reader and monitor threads without fixed sleeps.
    pub fn await_request(&self, method: &str) -> Option<String> {
        self.await_request_at(method, 0)
    }

    /// Blocks until the zero-based request occurrence for `method` is written.
    pub fn await_request_at(&self, method: &str, index: usize) -> Option<String> {
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            if let Some(id) = self.request_ids(method).get(index).cloned() {
                return Some(id);
            }
            std::thread::sleep(Duration::from_millis(2));
        }
        None
    }

    /// Blocks until the engine has written a notification for `method`.
    pub fn await_notification(&self, method: &str) -> bool {
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            if self
                .messages()
                .iter()
                .any(|message| message.get("method").and_then(Value::as_str) == Some(method))
            {
                return true;
            }
            std::thread::sleep(Duration::from_millis(2));
        }
        false
    }

    fn request_ids(&self, method: &str) -> Vec<String> {
        self.messages()
            .into_iter()
            .filter_map(|message| {
                (message.get("method").and_then(Value::as_str) == Some(method))
                    .then(|| {
                        message
                            .get("id")
                            .and_then(Value::as_str)
                            .map(str::to_string)
                    })
                    .flatten()
            })
            .collect()
    }

    /// Every JSON-RPC message the engine has written, unframed.
    pub fn messages(&self) -> Vec<Value> {
        let written = self.shared.written.lock().unwrap().clone();
        let mut messages = Vec::new();
        let mut rest = written.as_slice();
        while let Some(header_end) = rest.windows(4).position(|window| window == b"\r\n\r\n") {
            let header = String::from_utf8_lossy(&rest[..header_end]).to_string();
            let Some(length) = header
                .lines()
                .find_map(|line| line.strip_prefix("Content-Length: "))
                .and_then(|value| value.trim().parse::<usize>().ok())
            else {
                break;
            };
            let body_start = header_end + 4;
            let body_end = body_start + length;
            if rest.len() < body_end {
                break;
            }
            if let Ok(value) = serde_json::from_slice::<Value>(&rest[body_start..body_end]) {
                messages.push(value);
            }
            rest = &rest[body_end..];
        }
        messages
    }

    /// The raw bytes the engine wrote, for asserting frame headers.
    pub fn written_bytes(&self) -> Vec<u8> {
        self.shared.written.lock().unwrap().clone()
    }

    /// Ends the process, as a crash or a clean exit depending on the code.
    pub fn exit(&self, code: Option<i32>) {
        *self.shared.exit.lock().unwrap() = Some(code);
        // Waking the reader lets it observe the closed stream and finish rather
        // than holding the session's Arc alive until the test ends.
        self.shared.ready.notify_all();
    }

    pub fn input_was_closed(&self) -> bool {
        self.shared.input_closed.load(Ordering::Acquire)
    }

    /// Makes every later write fail, standing in for a broken stdin pipe.
    pub fn break_input(&self) {
        self.shared.input_broken.store(true, Ordering::Release);
    }
}

struct ScriptedLauncher {
    shared: Arc<ScriptedShared>,
}

impl LspProcessLauncher for ScriptedLauncher {
    fn launch(&self, spec: LspProcessSpec) -> Result<LspProcessStreams, CoreError> {
        *self.shared.spec.lock().unwrap() = Some(LaunchedSpec {
            executable: spec.executable.to_string_lossy().into_owned(),
            arguments: spec.arguments.clone(),
            working_directory: spec.working_directory.to_string_lossy().into_owned(),
        });
        Ok(LspProcessStreams {
            handle: Arc::new(ScriptedProcess {
                shared: self.shared.clone(),
            }),
            output: Box::new(ScriptedOutput {
                shared: self.shared.clone(),
            }),
            errors: Box::new(ScriptedErrors),
        })
    }
}

struct ScriptedProcess {
    shared: Arc<ScriptedShared>,
}

impl LspProcessHandle for ScriptedProcess {
    fn write_input(&self, frame: &[u8]) -> Result<(), CoreError> {
        if self.shared.input_broken.load(Ordering::Acquire)
            || self.shared.input_closed.load(Ordering::Acquire)
        {
            return Err(CoreError::new(
                ErrorCode::ProcessFailed,
                "Language-server stdin is closed.",
            ));
        }
        self.shared.written.lock().unwrap().extend_from_slice(frame);
        Ok(())
    }

    fn close_input(&self) {
        self.shared.input_closed.store(true, Ordering::Release);
    }

    fn exit_status(&self) -> Option<Option<i32>> {
        *self.shared.exit.lock().unwrap()
    }

    fn terminate(&self) {
        let mut exit = self.shared.exit.lock().unwrap();
        if exit.is_none() {
            *exit = Some(Some(9));
        }
        drop(exit);
        self.shared.ready.notify_all();
    }
}

struct ScriptedOutput {
    shared: Arc<ScriptedShared>,
}

impl Read for ScriptedOutput {
    fn read(&mut self, target: &mut [u8]) -> std::io::Result<usize> {
        let mut pending = self.shared.pending_output.lock().unwrap();
        loop {
            if !pending.is_empty() {
                let count = pending.len().min(target.len());
                target[..count].copy_from_slice(&pending[..count]);
                pending.drain(..count);
                return Ok(count);
            }
            // An exited process closes its stdout, which the engine reads as
            // zero bytes and treats as end of stream.
            if self.shared.exit.lock().unwrap().is_some() {
                return Ok(0);
            }
            let (guard, _) = self
                .shared
                .ready
                .wait_timeout(pending, Duration::from_millis(20))
                .unwrap();
            pending = guard;
        }
    }
}

/// A scripted server writes nothing to stderr; the engine only logs it.
struct ScriptedErrors;

impl Read for ScriptedErrors {
    fn read(&mut self, _: &mut [u8]) -> std::io::Result<usize> {
        Ok(0)
    }
}
