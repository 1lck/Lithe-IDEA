//! Window-scoped ordered events matching output/build-output-types.ts. The
//! native operation is the sole lifecycle owner; no replay buffer or second
//! run registry is maintained here.

use super::super::build_registry::BuildModelContext;
use serde::Serialize;
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};

pub(super) const MAX_RUN_OUTPUT: usize = 8 * 1024 * 1024;
const MAX_EVENTS: usize = 16_384;
const MAX_DECODED_EVENT: usize = 8 * 1024 * 1024;

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct BuildRunTerminal {
    pub kind: String,
    pub exit_code: Option<i32>,
    /// Stable host category or bounded tool diagnostic, never raw environment.
    pub message: Option<String>,
}

pub(super) trait BuildOutputSink: Send + Sync {
    fn emit(&self, window_label: &str, event: Value) -> Result<(), String>;
}

#[derive(Default)]
struct EventState {
    bytes: usize,
    events: usize,
    terminal: bool,
}

pub(super) struct RunEvents {
    window: String,
    identity: Value,
    sink: Arc<dyn BuildOutputSink>,
    state: Mutex<EventState>,
}

impl RunEvents {
    pub fn new(
        context: &BuildModelContext,
        operation_id: &str,
        sink: Arc<dyn BuildOutputSink>,
    ) -> Self {
        Self {
            window: context.window_label.clone(),
            identity: json!({
                "operationId": operation_id, "pluginId": context.plugin_id,
                "buildSystemId": context.build_system_id, "root": context.root,
                "workspaceRoot": context.workspace_root, "generation": context.generation,
            }),
            sink,
            state: Mutex::new(EventState::default()),
        }
    }

    fn event(&self, payload: Value) -> Value {
        let mut event = self.identity.clone();
        event
            .as_object_mut()
            .expect("routing identity")
            .extend(payload.as_object().expect("event").clone());
        event
    }

    pub fn chunk(&self, stream: &str, text: &str) -> Result<(), String> {
        if text.is_empty() {
            return Ok(());
        }
        let mut state = self
            .state
            .lock()
            .map_err(|_| "plugin.build.outputUnavailable")?;
        if state.terminal {
            return Err("plugin.build.staleContext".into());
        }
        if state.bytes.saturating_add(text.len()) > MAX_RUN_OUTPUT || state.events >= MAX_EVENTS {
            return Err("plugin.build.outputLimit".into());
        }
        state.bytes += text.len();
        state.events += 1;
        self.sink.emit(
            &self.window,
            self.event(json!({"type":"chunk", "stream":stream, "text":text})),
        )
    }

    pub fn decoded(&self, kind: &str, key: &str, value: Value) -> Result<(), String> {
        if serde_json::to_vec(&value)
            .map_err(|_| "plugin.build.invalidOutput")?
            .len()
            > MAX_DECODED_EVENT
        {
            return Err("plugin.build.outputLimit".into());
        }
        let state = self
            .state
            .lock()
            .map_err(|_| "plugin.build.outputUnavailable")?;
        if state.terminal {
            return Err("plugin.build.staleContext".into());
        }
        let mut payload = json!({"type":kind});
        payload[key] = value;
        self.sink.emit(&self.window, self.event(payload))
    }

    /// Called only after the executor has drained its complete tree, or for
    /// a cancelled review that has never acquired a process. Failed cleanup
    /// deliberately leaves the operation occupied and emits no false terminal.
    pub fn terminal(&self, terminal: &BuildRunTerminal) -> Result<(), String> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| "plugin.build.outputUnavailable")?;
        if state.terminal {
            return Ok(());
        }
        state.terminal = true;
        self.sink.emit(
            &self.window,
            self.event(json!({"type":"terminal", "terminal":terminal})),
        )
    }
}

/// Incremental stream decoding keeps UTF-8 code points intact across native
/// pipe chunks. The pending tail is at most three bytes for valid UTF-8.
#[derive(Default)]
pub(super) struct Utf8Stream {
    pending: Vec<u8>,
}
impl Utf8Stream {
    pub fn push(&mut self, bytes: &[u8]) -> String {
        self.pending.extend_from_slice(bytes);
        let mut text = String::new();
        loop {
            match std::str::from_utf8(&self.pending) {
                Ok(valid) => {
                    text.push_str(valid);
                    self.pending.clear();
                    break;
                }
                Err(error) => {
                    let end = error.valid_up_to();
                    text.push_str(
                        std::str::from_utf8(&self.pending[..end]).expect("validated prefix"),
                    );
                    match error.error_len() {
                        Some(length) => {
                            text.push('\u{fffd}');
                            self.pending.drain(..end + length);
                        }
                        None => {
                            self.pending.drain(..end);
                            break;
                        }
                    }
                }
            }
        }
        text
    }
    pub fn finish(&mut self) -> String {
        let text = String::from_utf8_lossy(&self.pending).into_owned();
        self.pending.clear();
        text
    }
}
