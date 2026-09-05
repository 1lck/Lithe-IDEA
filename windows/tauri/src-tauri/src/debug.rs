//! Windows Debug Adapter host: adapter process and stdio transport.
//!
//! DAP framing, request correlation, breakpoint sets, and the session state
//! machine stay in `lithe-core` under the `debug.*` contract. This module owns
//! only the adapter executable, its stdin/stdout/stderr pipes, session
//! lifecycle, and the Tauri events projected to the React debugger.
//!
//! Byte flow: React invokes `debug_*` commands, the host reduces them through
//! `lithe_core::execute_json`, writes the returned base64 `outboundFrames` to
//! the adapter stdin, and feeds adapter stdout chunks back through
//! `debug.receive`. Core-generated normalized events are emitted to React as
//! `debugger_message`, adapter stderr as `debugger_output`, and process exit
//! as `debugger_session_ended`.

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine as _;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::Path;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use tauri::{AppHandle, Emitter};

use crate::run::{apply_creation_flags, decode_process_bytes, incomplete_suffix_len};

const CORE_TIMEOUT_MILLISECONDS: u64 = 30_000;
const MAX_FRAME_BYTES: usize = 64 * 1024 * 1024;
const MAX_BUFFERED_STARTUP_EVENTS: usize = 128;

trait DebugEventSink: Clone + Send + Sync + 'static {
    fn emit_event(&self, name: &str, payload: Value);
}

impl DebugEventSink for AppHandle {
    fn emit_event(&self, name: &str, payload: Value) {
        let _ = self.emit(name, payload);
    }
}

static SESSION_COUNTER: AtomicU64 = AtomicU64::new(1);
static OPERATION_COUNTER: AtomicU64 = AtomicU64::new(1);

/// Managed marker for the Tauri state container. The session registry itself
/// is process-wide so reader and exit-waiter threads can reach it without an
/// `AppHandle`, mirroring the existing `run.rs` process manager.
pub struct DebugAdapterManager;

impl Default for DebugAdapterManager {
    fn default() -> Self {
        Self
    }
}

struct AdapterSession {
    pid: u32,
    /// Workspace root that owns this session, used to reap adapters when the
    /// owning project closes without touching sessions of other projects.
    workspace: String,
    /// Shared so adapter stdout readers can write Core-produced frames while
    /// Tauri commands write request frames; the mutex prevents interleaving.
    stdin: Arc<Mutex<ChildStdin>>,
    startup_gate: Arc<Mutex<StartupGate>>,
}

struct StartupGate {
    /// Whether the frontend has installed this session as active.
    ready: bool,
    /// Normalized protocol events received before `ready` in wire order.
    buffered_events: Vec<Value>,
}

fn sessions() -> &'static Mutex<HashMap<String, AdapterSession>> {
    static SESSIONS: OnceLock<Mutex<HashMap<String, AdapterSession>>> = OnceLock::new();
    SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DebugAdapterLaunch {
    pub command: String,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default)]
    pub cwd: Option<String>,
    #[serde(default)]
    pub env: HashMap<String, String>,
    #[serde(default)]
    pub workspace_path: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DebugSessionInfo {
    pub id: String,
    pub command: String,
    pub args: Vec<String>,
    pub cwd: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DebugSendRequest {
    pub session_id: String,
    pub command: String,
    #[serde(default)]
    pub arguments: Value,
    #[serde(default)]
    pub operation_id: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DebugCommandResult {
    pub session_id: String,
    pub operation_id: String,
}

/// Starts one Debug Adapter executable and returns its stable session id.
#[tauri::command]
pub async fn debug_start_session(
    app: AppHandle,
    launch: DebugAdapterLaunch,
) -> Result<DebugSessionInfo, String> {
    start_debug_adapter_session(app, launch).await
}

async fn start_debug_adapter_session<S: DebugEventSink>(
    app: S,
    launch: DebugAdapterLaunch,
) -> Result<DebugSessionInfo, String> {
    let command = launch.command.trim().to_string();
    if command.is_empty() {
        return Err("The debug adapter command cannot be empty.".to_string());
    }

    let mut child_command = Command::new(&command);
    child_command
        .args(&launch.args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(cwd) = launch.cwd.as_deref().filter(|cwd| !cwd.trim().is_empty()) {
        child_command.current_dir(cwd);
    }
    if !launch.env.is_empty() {
        child_command.envs(&launch.env);
    }
    apply_creation_flags(&mut child_command);

    let mut child = child_command
        .spawn()
        .map_err(|error| format!("Unable to start debug adapter: {error}"))?;
    let pid = child.id();
    let Some(stdin) = child.stdin.take() else {
        let _ = child.kill();
        return Err("The debug adapter did not expose an input pipe.".to_string());
    };
    let stdin = Arc::new(Mutex::new(stdin));
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();

    let session_id = format!(
        "windows-debug-{}-{}",
        std::process::id(),
        SESSION_COUNTER.fetch_add(1, Ordering::Relaxed)
    );
    let root_path = launch
        .cwd
        .as_deref()
        .filter(|cwd| !cwd.trim().is_empty())
        .unwrap_or(".");
    let workspace = launch
        .workspace_path
        .as_deref()
        .map(str::trim)
        .filter(|workspace| !workspace.is_empty())
        .unwrap_or("")
        .to_string();
    let startup_gate = Arc::new(Mutex::new(StartupGate {
        ready: false,
        buffered_events: Vec::new(),
    }));

    let update = execute_core_async(
        "debug.createSession".to_string(),
        json!({
            "sessionId": session_id,
            "adapterId": adapter_identifier(&command),
            "rootPath": root_path,
            "supportsRunInTerminalRequest": false,
        }),
    )
    .await
    .map_err(|error| {
        let _ = child.kill();
        error
    })?;

    if let Err(error) = write_outbound_frames(&stdin, &update) {
        let _ = child.kill();
        let _ = execute_core_async(
            "debug.destroySession".to_string(),
            json!({ "sessionId": session_id }),
        )
        .await;
        return Err(error);
    }
    if update_state_failed(&update) {
        let message = session_failure_message(&update);
        emit_update_events(&app, &session_id, &update);
        let _ = child.kill();
        let _ = execute_core_async(
            "debug.destroySession".to_string(),
            json!({ "sessionId": session_id }),
        )
        .await;
        app.emit_event(
            "debugger_output",
            json!({ "sessionId": session_id, "stream": "stderr", "data": format!("{message}\n") }),
        );
        app.emit_event(
            "debugger_session_ended",
            json!({ "sessionId": session_id, "reason": "failed" }),
        );
        return Err(message);
    }

    {
        let mut current = sessions().lock().map_err(|_| {
            let _ = child.kill();
            let _ = execute_core_sync("debug.destroySession", json!({ "sessionId": session_id }));
            "Debug session state is unavailable.".to_string()
        })?;
        current.insert(
            session_id.clone(),
            AdapterSession {
                pid,
                workspace,
                stdin: stdin.clone(),
                startup_gate: startup_gate.clone(),
            },
        );
    }

    if let Err(error) = emit_or_buffer_update_events(&app, &session_id, &startup_gate, &update) {
        fail_session(&app, &session_id, pid, &error);
        return Err(error);
    }
    let stdout_reader = spawn_stdout_reader(
        app.clone(),
        session_id.clone(),
        pid,
        stdin,
        startup_gate,
        stdout,
    );
    let stderr_reader = spawn_stderr_reader(app.clone(), session_id.clone(), stderr);
    spawn_exit_waiter(
        app,
        session_id.clone(),
        child,
        pid,
        stdout_reader,
        stderr_reader,
    );

    Ok(DebugSessionInfo {
        id: session_id,
        command,
        args: launch.args,
        cwd: launch.cwd,
    })
}

/// Releases normalized startup events after the frontend registers the session.
#[tauri::command]
pub fn debug_session_ready(app: AppHandle, session_id: String) -> Result<(), String> {
    mark_session_ready(&app, &session_id)
}

fn mark_session_ready<S: DebugEventSink>(app: &S, session_id: &str) -> Result<(), String> {
    let gate = sessions()
        .lock()
        .map_err(|_| "Debug session state is unavailable.".to_string())?
        .get(session_id)
        .map(|session| session.startup_gate.clone())
        .ok_or_else(|| "The debug session is no longer active.".to_string())?;
    let buffered_events = {
        let mut gate = gate
            .lock()
            .map_err(|_| "Debug session startup state is unavailable.".to_string())?;
        if gate.ready {
            return Ok(());
        }
        gate.ready = true;
        std::mem::take(&mut gate.buffered_events)
    };
    for payload in buffered_events {
        app.emit_event("debugger_message", payload);
    }
    Ok(())
}

/// Temporary compatibility facade for the existing React request surface.
///
/// Every request is translated onto the shared `debug.*` contract and reduced
/// by Rust Core; this function keeps no DAP sequence or adapter state.
#[tauri::command]
pub async fn debug_send_request(
    app: AppHandle,
    request: DebugSendRequest,
) -> Result<DebugCommandResult, String> {
    send_debug_request(app, request).await
}

async fn send_debug_request<S: DebugEventSink>(
    app: S,
    request: DebugSendRequest,
) -> Result<DebugCommandResult, String> {
    let (pid, stdin) = {
        let current = sessions()
            .lock()
            .map_err(|_| "Debug session state is unavailable.".to_string())?;
        let session = current
            .get(&request.session_id)
            .ok_or_else(|| "The debug session is no longer active.".to_string())?;
        (session.pid, session.stdin.clone())
    };
    let operation_id = request.operation_id.unwrap_or_else(|| {
        format!(
            "debug-op-{}",
            OPERATION_COUNTER.fetch_add(1, Ordering::Relaxed)
        )
    });
    let (core_command, payload) = translate_request(
        &request.session_id,
        &request.command,
        &request.arguments,
        &operation_id,
    )
    .map_err(|error| {
        // The facade owns the adapter process; an unmapped request must not
        // leave a live adapter or shared session behind.
        fail_session(&app, &request.session_id, pid, &error);
        error
    })?;
    let update = execute_core_async(core_command, payload)
        .await
        .map_err(|error| {
            fail_session(&app, &request.session_id, pid, &error);
            error
        })?;
    if let Err(error) = write_outbound_frames(&stdin, &update) {
        fail_session(&app, &request.session_id, pid, &error);
        return Err(error);
    }
    emit_update_events(&app, &request.session_id, &update);
    if update_state_failed(&update) {
        let message = session_failure_message(&update);
        fail_session(&app, &request.session_id, pid, &message);
        return Err(message);
    }
    Ok(DebugCommandResult {
        session_id: request.session_id,
        operation_id,
    })
}

/// Stops one adapter session idempotently: graceful DAP disconnect, process
/// tree kill, shared-session destroy, and a single `session-ended` event.
#[tauri::command]
pub async fn debug_stop_session(app: AppHandle, session_id: String) -> Result<(), String> {
    stop_session(&app, &session_id).await
}

/// Stops every adapter session owned by one workspace. Project close and
/// workspace switches call this so adapters never outlive their project.
#[tauri::command]
pub async fn debug_stop_workspace_sessions(
    app: AppHandle,
    workspace_path: String,
) -> Result<(), String> {
    let mut failures = Vec::new();
    for session_id in matching_workspace_sessions(&workspace_path) {
        if let Err(error) = stop_session(&app, &session_id).await {
            failures.push(error);
        }
    }
    if let Some(error) = failures.into_iter().next() {
        return Err(error);
    }
    Ok(())
}

async fn stop_session<S: DebugEventSink>(app: &S, session_id: &str) -> Result<(), String> {
    let removed = {
        let mut current = sessions()
            .lock()
            .map_err(|_| "Debug session state is unavailable.".to_string())?;
        current
            .remove(session_id)
            .map(|session| (session.pid, session.stdin))
    };
    let Some((pid, stdin)) = removed else {
        // Repeated or late stops are no-ops and never touch a newer session.
        return Ok(());
    };

    match execute_core_async(
        "debug.disconnect".to_string(),
        json!({ "sessionId": session_id }),
    )
    .await
    {
        Ok(update) => {
            if let Err(error) = write_outbound_frames(&stdin, &update) {
                kill_adapter_process(pid);
                let _ = execute_core_async(
                    "debug.destroySession".to_string(),
                    json!({ "sessionId": session_id }),
                )
                .await;
                app.emit_event(
                    "debugger_session_ended",
                    json!({ "sessionId": session_id, "reason": "failed" }),
                );
                return Err(error);
            }
            emit_update_events(app, session_id, &update);
        }
        Err(_) => {
            // The shared session already ended (for example the adapter exited
            // first); only the native process still needs to be reaped.
        }
    }

    kill_adapter_process(pid);
    let _ = execute_core_async(
        "debug.destroySession".to_string(),
        json!({ "sessionId": session_id }),
    )
    .await;
    app.emit_event(
        "debugger_session_ended",
        json!({ "sessionId": session_id, "reason": "stopped" }),
    );
    Ok(())
}

/// Kills every live adapter during application exit so no child process or
/// reader task outlives the shell.
pub fn shutdown() {
    let sessions_to_stop = {
        let Ok(mut current) = sessions().lock() else {
            return;
        };
        current
            .drain()
            .map(|(session_id, session)| (session_id, session.pid))
            .collect::<Vec<_>>()
    };
    for (session_id, pid) in sessions_to_stop {
        kill_adapter_process(pid);
        let _ = execute_core_sync("debug.destroySession", json!({ "sessionId": session_id }));
    }
}

/// Maps the legacy React request surface onto the shared `debug.*` contract.
fn translate_request(
    session_id: &str,
    command: &str,
    arguments: &Value,
    operation_id: &str,
) -> Result<(String, Value), String> {
    let arguments = arguments.as_object().cloned().unwrap_or_default();
    let (core_command, payload) = match command {
        "launch" | "attach" => {
            let request_kind = arguments
                .get("request")
                .and_then(Value::as_str)
                .unwrap_or(command);
            if !matches!(request_kind, "launch" | "attach") {
                return Err(format!("Unsupported debug launch request: {request_kind}"));
            }
            let name = arguments
                .get("name")
                .and_then(Value::as_str)
                .filter(|name| !name.trim().is_empty())
                .unwrap_or("Launch");
            (
                "debug.launch".to_string(),
                json!({
                "sessionId": session_id,
                "operationId": operation_id,
                "configuration": {
                    "name": name,
                    "request": request_kind,
                    "arguments": arguments,
                }
                }),
            )
        }
        "setBreakpoints" => {
            let source_path = arguments
                .get("source")
                .and_then(Value::as_object)
                .and_then(|source| source.get("path"))
                .and_then(Value::as_str)
                .filter(|path| !path.trim().is_empty())
                .ok_or_else(|| "setBreakpoints requires a source path.".to_string())?;
            let breakpoints = arguments
                .get("breakpoints")
                .cloned()
                .unwrap_or_else(|| json!([]));
            (
                "debug.setBreakpoints".to_string(),
                json!({
                    "sessionId": session_id,
                    "sourcePath": source_path,
                    "breakpoints": breakpoints,
                }),
            )
        }
        "threads" | "stackTrace" | "scopes" | "variables" | "evaluate" => (
            "debug.inspect".to_string(),
            inspect_payload(session_id, operation_id, command, &arguments)?,
        ),
        "continue" | "pause" | "next" | "stepIn" | "stepOut" | "stepBack" => (
            "debug.execute".to_string(),
            json!({
                "sessionId": session_id,
                "operationId": operation_id,
                "command": command,
                "threadId": arguments.get("threadId").cloned().unwrap_or(Value::Null),
                "singleThread": arguments.get("singleThread").cloned().unwrap_or(json!(false)),
            }),
        ),
        "setVariable" => (
            "debug.setVariable".to_string(),
            json!({
                "sessionId": session_id,
                "operationId": operation_id,
                "variablesReference": arguments
                    .get("variablesReference")
                    .cloned()
                    .ok_or_else(|| "setVariable requires variablesReference.".to_string())?,
                "name": arguments
                    .get("name")
                    .cloned()
                    .ok_or_else(|| "setVariable requires a variable name.".to_string())?,
                "value": arguments
                    .get("value")
                    .cloned()
                    .ok_or_else(|| "setVariable requires a value.".to_string())?,
            }),
        ),
        _ => return Err(format!("Unsupported debug adapter request: {command}")),
    };
    Ok((core_command, payload))
}

/// Builds a `debug.inspect` payload from the requested normalized kind.
fn inspect_payload(
    session_id: &str,
    operation_id: &str,
    kind: &str,
    arguments: &Map<String, Value>,
) -> Result<Value, String> {
    let mut payload = Map::new();
    payload.insert("sessionId".into(), json!(session_id));
    payload.insert("operationId".into(), json!(operation_id));
    payload.insert("kind".into(), json!(kind));
    match kind {
        "threads" => {}
        "stackTrace" => {
            payload.insert("threadId".into(), required_argument(arguments, "threadId")?);
        }
        "scopes" => {
            payload.insert("frameId".into(), required_argument(arguments, "frameId")?);
        }
        "variables" => {
            payload.insert(
                "variablesReference".into(),
                required_argument(arguments, "variablesReference")?,
            );
            if let Some(filter) = arguments.get("filter").and_then(Value::as_str) {
                if !matches!(filter, "named" | "indexed") {
                    return Err(format!("Unsupported debug variable filter: {filter}"));
                }
                payload.insert("variableFilter".into(), json!(filter));
            }
            for field in ["start", "count"] {
                if let Some(value) = arguments.get(field) {
                    payload.insert(field.into(), value.clone());
                }
            }
        }
        "evaluate" => {
            payload.insert(
                "expression".into(),
                required_argument(arguments, "expression")?,
            );
            if let Some(frame_id) = arguments.get("frameId") {
                payload.insert("frameId".into(), frame_id.clone());
            }
        }
        _ => return Err(format!("Unsupported debug inspection request: {kind}")),
    }
    Ok(Value::Object(payload))
}

fn required_argument(arguments: &Map<String, Value>, field: &str) -> Result<Value, String> {
    arguments
        .get(field)
        .cloned()
        .ok_or_else(|| format!("Debug {field} is required."))
}

fn update_state_failed(update: &Value) -> bool {
    update.get("state").and_then(Value::as_str) == Some("failed")
}

/// Derives an actionable message from the failed update's events.
fn session_failure_message(update: &Value) -> String {
    if let Some(events) = update.get("events").and_then(Value::as_array) {
        for event in events {
            if event.get("type").and_then(Value::as_str) == Some("operationFailed") {
                if let Some(message) = event.get("message").and_then(Value::as_str) {
                    if !message.trim().is_empty() {
                        return message.to_string();
                    }
                }
            }
        }
    }
    "The debug session failed to start or continue.".to_string()
}

/// Returns the ids of sessions owned by the given workspace path.
fn matching_workspace_sessions(workspace_path: &str) -> Vec<String> {
    let wanted = normalize_workspace(workspace_path);
    if wanted.is_empty() {
        return Vec::new();
    }
    let Ok(current) = sessions().lock() else {
        return Vec::new();
    };
    current
        .iter()
        .filter(|(_, session)| session_owned_by(&session.workspace, &wanted))
        .map(|(session_id, _)| session_id.clone())
        .collect()
}

fn session_owned_by(session_workspace: &str, normalized_wanted: &str) -> bool {
    normalize_workspace(session_workspace) == normalized_wanted
}

fn normalize_workspace(workspace_path: &str) -> String {
    workspace_path
        .trim()
        .trim_end_matches(['/', '\\'])
        .replace('\\', "/")
        .to_lowercase()
}

/// Reduces one shared `debug.*` request and returns the serialized update.
fn execute_core_sync(command: &str, payload: Value) -> Result<Value, String> {
    let operation_id = format!("core-{}", OPERATION_COUNTER.fetch_add(1, Ordering::Relaxed));
    let request = json!({
        "id": operation_id,
        "operationId": operation_id,
        "timeoutMilliseconds": CORE_TIMEOUT_MILLISECONDS,
        "command": command,
        "payload": payload,
    })
    .to_string();
    let response = lithe_core::execute_json(&request);
    let envelope: Value = serde_json::from_str(&response)
        .map_err(|error| format!("The shared debug core returned invalid JSON: {error}"))?;
    if envelope.get("ok").and_then(Value::as_bool) == Some(true) {
        return envelope
            .get("data")
            .cloned()
            .ok_or_else(|| "The shared debug core returned an empty update.".to_string());
    }
    let error = envelope.get("error").unwrap_or(&Value::Null);
    Err(error
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or("The shared debug core operation failed")
        .to_string())
}

async fn execute_core_async(command: String, payload: Value) -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(move || execute_core_sync(&command, payload))
        .await
        .map_err(|error| format!("Shared debug core task failed: {error}"))?
}

/// Decodes Core's ordered base64 frames and writes them without interleaving.
fn write_outbound_frames<W: Write>(stdin: &Mutex<W>, update: &Value) -> Result<(), String> {
    let frames = update
        .get("outboundFrames")
        .and_then(Value::as_array)
        .ok_or_else(|| "The shared debug core returned an invalid session update.".to_string())?;
    let mut writer = stdin
        .lock()
        .map_err(|_| "The debug adapter input pipe is unavailable.".to_string())?;
    for frame in frames {
        let encoded = frame.as_str().ok_or_else(|| {
            "The shared debug core returned an invalid outbound frame.".to_string()
        })?;
        let bytes = BASE64.decode(encoded).map_err(|error| {
            format!("The shared debug core returned invalid frame data: {error}")
        })?;
        if bytes.len() > MAX_FRAME_BYTES {
            return Err("The shared debug core produced an oversized frame.".to_string());
        }
        writer
            .write_all(&bytes)
            .map_err(|error| format!("Could not write to debug adapter input: {error}"))?;
    }
    writer
        .flush()
        .map_err(|error| format!("Could not flush debug adapter input: {error}"))
}

/// Projects Core's normalized events onto the existing React event surface.
fn emit_update_events<S: DebugEventSink>(app: &S, session_id: &str, update: &Value) {
    let Some(events) = update.get("events").and_then(Value::as_array) else {
        return;
    };
    for event in events {
        app.emit_event(
            "debugger_message",
            json!({ "sessionId": session_id, "message": event }),
        );
    }
}

fn emit_or_buffer_update_events<S: DebugEventSink>(
    app: &S,
    session_id: &str,
    startup_gate: &Arc<Mutex<StartupGate>>,
    update: &Value,
) -> Result<(), String> {
    let Some(events) = update.get("events").and_then(Value::as_array) else {
        return Ok(());
    };
    let payloads = events
        .iter()
        .map(|event| json!({ "sessionId": session_id, "message": event }))
        .collect::<Vec<_>>();
    let payloads = {
        let mut gate = startup_gate
            .lock()
            .map_err(|_| "Debug session startup state is unavailable.".to_string())?;
        if !gate.ready {
            if gate.buffered_events.len() + payloads.len() > MAX_BUFFERED_STARTUP_EVENTS {
                return Err("Debug adapter produced too many startup events.".to_string());
            }
            gate.buffered_events.extend(payloads);
            return Ok(());
        }
        payloads
    };
    for payload in payloads {
        app.emit_event("debugger_message", payload);
    }
    Ok(())
}

/// Feeds adapter stdout bytes to `debug.receive` and writes resulting frames.
fn spawn_stdout_reader<S: DebugEventSink, T: Read + Send + 'static>(
    app: S,
    session_id: String,
    pid: u32,
    stdin: Arc<Mutex<ChildStdin>>,
    startup_gate: Arc<Mutex<StartupGate>>,
    stdout: Option<T>,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        let Some(mut stream) = stdout else {
            return;
        };
        let mut buffer = [0_u8; 4096];
        loop {
            match stream.read(&mut buffer) {
                Ok(0) => {
                    // EOF is not itself a failure: a normally exiting adapter
                    // closes stdout before the exit waiter can publish its
                    // exit code. Terminate a still-live process so a broken
                    // adapter cannot leave the session registered forever.
                    if is_current_session(&session_id, pid) {
                        kill_adapter_process(pid);
                    }
                    break;
                }
                Ok(count) => {
                    if !is_current_session(&session_id, pid) {
                        break;
                    }
                    let data_base64 = BASE64.encode(&buffer[..count]);
                    match execute_core_sync(
                        "debug.receive",
                        json!({
                            "sessionId": session_id,
                            "dataBase64": data_base64,
                        }),
                    ) {
                        Ok(update) => {
                            if !is_current_session(&session_id, pid) {
                                break;
                            }
                            if update_state_failed(&update) {
                                let message = session_failure_message(&update);
                                emit_update_events(&app, &session_id, &update);
                                fail_session(&app, &session_id, pid, &message);
                                break;
                            }
                            if let Err(error) = write_outbound_frames(&stdin, &update) {
                                fail_session(&app, &session_id, pid, &error);
                                break;
                            }
                            if let Err(error) = emit_or_buffer_update_events(
                                &app,
                                &session_id,
                                &startup_gate,
                                &update,
                            ) {
                                fail_session(&app, &session_id, pid, &error);
                                break;
                            }
                        }
                        Err(error) => {
                            if is_current_session(&session_id, pid) {
                                fail_session(
                                    &app,
                                    &session_id,
                                    pid,
                                    &format!("Debug adapter protocol error: {error}"),
                                );
                            }
                            break;
                        }
                    }
                }
                Err(error) => {
                    if is_current_session(&session_id, pid) {
                        fail_session(
                            &app,
                            &session_id,
                            pid,
                            &format!(
                                "Debug adapter {pid} (session {session_id}) output read failed: {error}"
                            ),
                        );
                    }
                    break;
                }
            }
        }
    })
}

/// Projects adapter stderr onto the debug console output event.
fn spawn_stderr_reader<S: DebugEventSink, T: Read + Send + 'static>(
    app: S,
    session_id: String,
    stderr: Option<T>,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        let Some(mut stream) = stderr else {
            return;
        };
        let mut buffer = [0_u8; 4096];
        let mut pending = Vec::new();
        loop {
            match stream.read(&mut buffer) {
                Ok(0) => {
                    if !pending.is_empty() {
                        emit_stderr_chunk(&app, &session_id, &pending);
                    }
                    break;
                }
                Ok(count) => {
                    pending.extend_from_slice(&buffer[..count]);
                    let keep = incomplete_suffix_len(&pending);
                    let ready = pending.len().saturating_sub(keep);
                    if ready == 0 {
                        continue;
                    }
                    emit_stderr_chunk(&app, &session_id, &pending[..ready]);
                    pending.drain(..ready);
                }
                Err(_) => break,
            }
        }
    })
}

fn emit_stderr_chunk<S: DebugEventSink>(app: &S, session_id: &str, bytes: &[u8]) {
    let text = decode_process_bytes(bytes);
    if text.is_empty() {
        return;
    }
    app.emit_event(
        "debugger_output",
        json!({ "sessionId": session_id, "stream": "stderr", "data": text }),
    );
}

/// Reaps an exited adapter, destroys its shared session, and emits the ended
/// event only when this process generation is still the registered one.
fn spawn_exit_waiter<S: DebugEventSink>(
    app: S,
    session_id: String,
    mut child: Child,
    pid: u32,
    stdout_reader: thread::JoinHandle<()>,
    stderr_reader: thread::JoinHandle<()>,
) {
    thread::spawn(move || {
        let exit_code = child
            .wait()
            .ok()
            .and_then(|status| status.code())
            .unwrap_or(-1);
        let _ = stdout_reader.join();
        let _ = stderr_reader.join();
        if !remove_session(&session_id, pid) {
            return;
        }
        let _ = execute_core_sync("debug.destroySession", json!({ "sessionId": session_id }));
        app.emit_event(
            "debugger_session_ended",
            json!({
                "sessionId": session_id,
                "reason": "exited",
                "exitCode": exit_code,
            }),
        );
    });
}

/// Removes the session only when its pid still matches, so a late event from
/// an old adapter can never clean up or end a newer session.
fn remove_session(session_id: &str, pid: u32) -> bool {
    match sessions().lock() {
        Ok(mut current) => match current.get(session_id) {
            Some(session) if session.pid == pid => {
                current.remove(session_id);
                true
            }
            _ => false,
        },
        Err(_) => false,
    }
}

fn is_current_session(session_id: &str, pid: u32) -> bool {
    sessions().lock().ok().is_some_and(|current| {
        current
            .get(session_id)
            .is_some_and(|session| session.pid == pid)
    })
}

/// Tears down a failed session: process tree kill, shared-session destroy,
/// console error, and a single `failed` end event.
fn fail_session<S: DebugEventSink>(app: &S, session_id: &str, pid: u32, message: &str) {
    if !remove_session(session_id, pid) {
        return;
    }
    kill_adapter_process(pid);
    let _ = execute_core_sync("debug.destroySession", json!({ "sessionId": session_id }));
    app.emit_event(
        "debugger_output",
        json!({ "sessionId": session_id, "stream": "stderr", "data": format!("{message}\n") }),
    );
    app.emit_event(
        "debugger_session_ended",
        json!({ "sessionId": session_id, "reason": "failed" }),
    );
}

fn kill_adapter_process(pid: u32) {
    if pid == 0 {
        return;
    }
    let mut command = Command::new("taskkill");
    command.args(["/F", "/T", "/PID", &pid.to_string()]);
    apply_creation_flags(&mut command);
    let _ = command.output();
}

fn adapter_identifier(command: &str) -> String {
    Path::new(command)
        .file_stem()
        .and_then(|stem| stem.to_str())
        .filter(|stem| !stem.trim().is_empty())
        .unwrap_or("custom")
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Stdio;
    use std::sync::mpsc;
    use std::time::Duration;

    #[cfg(feature = "test-support")]
    #[derive(Clone)]
    struct RecordingSink {
        events: mpsc::Sender<(String, Value)>,
    }

    #[cfg(feature = "test-support")]
    impl DebugEventSink for RecordingSink {
        fn emit_event(&self, name: &str, payload: Value) {
            self.events
                .send((name.to_string(), payload))
                .expect("recording sink receiver should remain active");
        }
    }

    #[cfg(feature = "test-support")]
    fn fake_adapter_path() -> std::path::PathBuf {
        let test_binary = std::env::current_exe().expect("test binary path");
        test_binary
            .parent()
            .and_then(Path::parent)
            .expect("target directory")
            .join("fake-dap-adapter.exe")
    }

    #[cfg(all(windows, feature = "test-support"))]
    fn start_launched_fake_session(
        sink: &RecordingSink,
        mode: &str,
        operation_id: &str,
    ) -> DebugSessionInfo {
        let session = tauri::async_runtime::block_on(start_debug_adapter_session(
            sink.clone(),
            DebugAdapterLaunch {
                command: fake_adapter_path().to_string_lossy().into_owned(),
                args: vec![mode.to_string()],
                cwd: None,
                env: HashMap::new(),
                workspace_path: None,
            },
        ))
        .expect("host should start the fake adapter");
        tauri::async_runtime::block_on(send_debug_request(
            sink.clone(),
            DebugSendRequest {
                session_id: session.id.clone(),
                command: "launch".to_string(),
                arguments: json!({ "request": "launch", "name": "Demo" }),
                operation_id: Some(operation_id.to_string()),
            },
        ))
        .expect("host should queue launch");
        mark_session_ready(sink, &session.id).expect("startup gate should open");
        session
    }

    #[test]
    fn translates_launch_into_shared_launch_configuration() {
        let (command, payload) = translate_request(
            "session-1",
            "launch",
            &json!({
                "name": "Demo",
                "request": "launch",
                "type": "node",
                "program": "C:/work/main.js",
            }),
            "op-1",
        )
        .unwrap();
        assert_eq!(command, "debug.launch");
        assert_eq!(payload["sessionId"], "session-1");
        assert_eq!(payload["operationId"], "op-1");
        assert_eq!(payload["configuration"]["name"], "Demo");
        assert_eq!(payload["configuration"]["request"], "launch");
        assert_eq!(
            payload["configuration"]["arguments"]["program"],
            "C:/work/main.js"
        );
    }

    #[test]
    fn translates_attach_requests_without_changing_the_payload() {
        let (_, payload) = translate_request(
            "session-1",
            "launch",
            &json!({ "request": "attach", "port": 9229 }),
            "op-2",
        )
        .unwrap();
        assert_eq!(payload["configuration"]["request"], "attach");
        assert_eq!(payload["configuration"]["arguments"]["port"], 9229);
    }

    #[test]
    fn facade_accepts_attach_as_the_request_command() {
        let (command, payload) = translate_request(
            "session-1",
            "attach",
            &json!({ "name": "Attach", "port": 9229, "type": "node" }),
            "op-attach",
        )
        .unwrap();
        assert_eq!(command, "debug.launch");
        assert_eq!(payload["configuration"]["request"], "attach");
        assert_eq!(payload["configuration"]["arguments"]["port"], 9229);
        assert_eq!(payload["configuration"]["name"], "Attach");
    }

    #[test]
    fn workspace_ownership_matching_ignores_trailing_separators_and_case() {
        assert!(session_owned_by(
            "C:/work/project-a",
            &normalize_workspace("C:\\Work\\Project-A\\")
        ));
        assert!(!session_owned_by(
            "C:/work/project-b",
            &normalize_workspace("C:/work/project-a")
        ));
        assert!(!session_owned_by(
            "",
            &normalize_workspace("C:/work/project-a")
        ));
    }

    #[test]
    fn failed_updates_expose_the_adapter_message() {
        let update = json!({
            "state": "failed",
            "events": [
                {
                    "type": "operationFailed",
                    "operationId": "op-1",
                    "command": "launch",
                    "code": "adapterRejected",
                    "message": "The adapter rejected the launch configuration.",
                }
            ]
        });
        assert!(update_state_failed(&update));
        assert_eq!(
            session_failure_message(&update),
            "The adapter rejected the launch configuration."
        );

        let running = json!({ "state": "running", "events": [] });
        assert!(!update_state_failed(&running));
        assert_eq!(
            session_failure_message(&running),
            "The debug session failed to start or continue."
        );
    }

    #[cfg(all(windows, feature = "test-support"))]
    #[test]
    fn startup_events_are_buffered_until_session_ready() {
        let gate = Arc::new(Mutex::new(StartupGate {
            ready: false,
            buffered_events: Vec::new(),
        }));
        let (events, received) = mpsc::channel();
        let sink = RecordingSink { events };
        let update = json!({
            "events": [
                { "type": "stateChanged", "state": "paused" },
                { "type": "stopped", "reason": "entry" }
            ]
        });

        emit_or_buffer_update_events(&sink, "session-1", &gate, &update).unwrap();
        assert!(received.try_recv().is_err());
        assert_eq!(gate.lock().unwrap().buffered_events.len(), 2);

        gate.lock().unwrap().ready = true;
        emit_or_buffer_update_events(
            &sink,
            "session-1",
            &gate,
            &json!({ "events": [{ "type": "initialized" }] }),
        )
        .unwrap();
        assert_eq!(
            received
                .recv_timeout(Duration::from_secs(1))
                .unwrap()
                .1["message"]["type"],
            "initialized"
        );
    }

    #[test]
    fn translates_set_breakpoints_into_the_core_contract() {
        let (command, payload) = translate_request(
            "session-1",
            "setBreakpoints",
            &json!({
                "source": { "path": "C:/work/main.js" },
                "breakpoints": [{ "line": 3, "enabled": true }, { "line": 7 }],
            }),
            "op-3",
        )
        .unwrap();
        assert_eq!(command, "debug.setBreakpoints");
        assert_eq!(payload["sourcePath"], "C:/work/main.js");
        assert_eq!(payload["breakpoints"][0]["line"], 3);
        assert_eq!(payload["breakpoints"][1]["line"], 7);
    }

    #[test]
    fn translates_inspection_requests_onto_debug_inspect() {
        let (command, payload) =
            translate_request("session-1", "stackTrace", &json!({ "threadId": 4 }), "op-4")
                .unwrap();
        assert_eq!(command, "debug.inspect");
        assert_eq!(payload["kind"], "stackTrace");
        assert_eq!(payload["threadId"], 4);

        let (_, variables) = translate_request(
            "session-1",
            "variables",
            &json!({ "variablesReference": 9, "start": 0, "count": 50 }),
            "op-5",
        )
        .unwrap();
        assert_eq!(variables["kind"], "variables");
        assert_eq!(variables["variablesReference"], 9);
        assert_eq!(variables["start"], 0);
        assert_eq!(variables["count"], 50);
    }

    #[test]
    fn translates_execution_controls_onto_debug_execute() {
        let (command, payload) =
            translate_request("session-1", "stepIn", &json!({ "threadId": 7 }), "op-6").unwrap();
        assert_eq!(command, "debug.execute");
        assert_eq!(payload["command"], "stepIn");
        assert_eq!(payload["threadId"], 7);
        assert_eq!(payload["singleThread"], false);
    }

    #[test]
    fn rejects_unsupported_requests_and_missing_arguments() {
        let error = translate_request("session-1", "restart", &json!({}), "op-7").unwrap_err();
        assert!(error.contains("Unsupported debug adapter request: restart"));

        let error = translate_request("session-1", "stackTrace", &json!({}), "op-8").unwrap_err();
        assert!(error.contains("threadId is required"));

        let error = translate_request(
            "session-1",
            "setBreakpoints",
            &json!({ "breakpoints": [] }),
            "op-9",
        )
        .unwrap_err();
        assert!(error.contains("source path"));
    }

    #[test]
    fn writes_decoded_frames_in_order_without_mangling() {
        let first = "Content-Length: 5\r\n\r\nhello";
        let second = "Content-Length: 5\r\n\r\nworld";
        let sink = Mutex::new(Vec::new());
        let update = json!({
            "sessionId": "session-1",
            "state": "initializing",
            "outboundFrames": [BASE64.encode(first), BASE64.encode(second)],
            "events": [],
        });
        write_outbound_frames(&sink, &update).unwrap();
        let bytes = sink.into_inner().unwrap();
        assert_eq!(
            String::from_utf8(bytes).unwrap(),
            format!("{first}{second}")
        );
    }

    #[cfg(windows)]
    #[test]
    fn fake_adapter_process_round_trips_stdio_with_bounded_cleanup() {
        let mut child = Command::new("cmd.exe")
            .args(["/D", "/Q", "/C", "more"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("fake adapter process should start");
        let mut stdin = child.stdin.take().expect("fake adapter stdin");
        let stdout = child.stdout.take().expect("fake adapter stdout");
        let stderr = child.stderr.take().expect("fake adapter stderr");
        let (output_tx, output_rx) = mpsc::channel();
        thread::spawn(move || {
            let mut stdout = stdout;
            let mut bytes = Vec::new();
            let _ = stdout.read_to_end(&mut bytes);
            let _ = output_tx.send(bytes);
        });
        thread::spawn(move || {
            let mut stderr = stderr;
            let mut bytes = Vec::new();
            let _ = stderr.read_to_end(&mut bytes);
        });

        let frame = b"Content-Length: 4\r\n\r\nTEST";
        stdin.write_all(frame).expect("fake adapter stdin write");
        drop(stdin);
        let (wait_tx, wait_rx) = mpsc::channel();
        thread::spawn(move || {
            let _ = wait_tx.send(child.wait());
        });
        let status = wait_rx
            .recv_timeout(Duration::from_secs(3))
            .expect("fake adapter must exit within watchdog deadline")
            .expect("fake adapter wait should succeed");
        let echoed = output_rx
            .recv_timeout(Duration::from_secs(3))
            .expect("stdout reader must finish within watchdog deadline");
        assert!(status.success());
        assert_eq!(echoed, [frame.as_slice(), b"\r\n"].concat());
    }

    #[cfg(all(windows, feature = "test-support"))]
    #[test]
    fn fake_dap_adapter_emits_fragmented_protocol_and_stderr() {
        let adapter = fake_adapter_path();
        let output = Command::new(adapter)
            .arg("fragmented")
            .output()
            .expect("fake DAP adapter should start");
        assert!(output.status.success());
        assert!(String::from_utf8_lossy(&output.stderr).contains("fake-dap-adapter:fragmented"));
        assert!(String::from_utf8_lossy(&output.stdout).contains("Content-Length:"));
        assert!(String::from_utf8_lossy(&output.stdout).contains("terminated"));
    }

    #[cfg(all(windows, feature = "test-support"))]
    #[test]
    fn fake_dap_adapter_rejection_and_eof_modes_are_deterministic() {
        let adapter = fake_adapter_path();
        for (mode, expected) in [("reject-initialize", "initialize")] {
            let output = Command::new(&adapter)
                .arg(mode)
                .output()
                .expect("fake DAP adapter should start");
            assert!(output.status.success());
            assert!(String::from_utf8_lossy(&output.stdout).contains(r#""success":false"#));
            assert!(String::from_utf8_lossy(&output.stdout).contains(expected));
        }
        let output = Command::new(adapter)
            .arg("eof-live")
            .output()
            .expect("fake DAP adapter should start");
        assert!(output.status.success());
        assert!(output.stdout.is_empty());
        assert!(String::from_utf8_lossy(&output.stderr).contains("eof-live"));
    }

    #[cfg(all(windows, feature = "test-support"))]
    #[test]
    fn fake_dap_adapter_runs_through_stdout_reader_and_exit_waiter() {
        let adapter = fake_adapter_path();
        let mut child = Command::new(adapter)
            .arg("eof-live")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("fake DAP adapter should start");
        let pid = child.id();
        let stdin = Arc::new(Mutex::new(child.stdin.take().expect("adapter stdin")));
        let session_id = format!("fake-host-session-{}", pid);
        execute_core_sync(
            "debug.createSession",
            json!({
                "sessionId": session_id,
                "adapterId": "fake-dap-adapter",
                "rootPath": ".",
                "supportsRunInTerminalRequest": false,
            }),
        )
        .expect("Core session should be created");
        sessions().lock().unwrap().insert(
            session_id.clone(),
            AdapterSession {
                pid,
                workspace: String::new(),
                stdin: stdin.clone(),
                startup_gate: Arc::new(Mutex::new(StartupGate {
                    ready: true,
                    buffered_events: Vec::new(),
                })),
            },
        );
        let (events, received) = mpsc::channel();
        let sink = RecordingSink { events };
        let stdout_reader = spawn_stdout_reader(
            sink.clone(),
            session_id.clone(),
            pid,
            stdin,
            Arc::new(Mutex::new(StartupGate {
                ready: true,
                buffered_events: Vec::new(),
            })),
            child.stdout.take(),
        );
        let stderr_reader =
            spawn_stderr_reader(sink.clone(), session_id.clone(), child.stderr.take());
        spawn_exit_waiter(
            sink,
            session_id.clone(),
            child,
            pid,
            stdout_reader,
            stderr_reader,
        );
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        let mut saw_stderr = false;
        let ended = loop {
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            let event = received
                .recv_timeout(remaining)
                .expect("exit waiter should publish a bounded completion event");
            if event.0 == "debugger_output" {
                saw_stderr = true;
                continue;
            }
            break event;
        };
        assert!(saw_stderr);
        assert_eq!(ended.0, "debugger_session_ended");
        assert_eq!(ended.1["sessionId"], session_id);
        assert_eq!(ended.1["reason"], "exited");
        assert!(!is_current_session(&session_id, pid));
    }

    #[cfg(all(windows, feature = "test-support"))]
    #[test]
    fn fake_dap_adapter_initialize_rejection_triggers_host_teardown() {
        let adapter = fake_adapter_path();
        let (events, received) = mpsc::channel();
        let sink = RecordingSink { events };
        let launch = DebugAdapterLaunch {
            command: adapter.to_string_lossy().into_owned(),
            args: vec!["reject-initialize".to_string()],
            cwd: None,
            env: HashMap::new(),
            workspace_path: None,
        };
        let session = tauri::async_runtime::block_on(start_debug_adapter_session(sink, launch))
            .expect("host should return session before reader receives rejection");
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        let mut observed = Vec::new();
        while std::time::Instant::now() < deadline {
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            let Ok((name, payload)) = received.recv_timeout(remaining) else {
                break;
            };
            observed.push(format!("{name}:{}", payload));
            if name == "debugger_session_ended" {
                assert_eq!(payload["sessionId"], session.id);
                assert_eq!(payload["reason"], "failed");
                assert!(!sessions().lock().unwrap().contains_key(&session.id));
                return;
            }
        }
        panic!("host rejection teardown was not observed; events={observed:?}");
    }

    #[cfg(all(windows, feature = "test-support"))]
    #[test]
    fn repeated_stop_only_ends_the_selected_session() {
        let (events, _received) = mpsc::channel();
        let sink = RecordingSink { events };
        let first = start_launched_fake_session(&sink, "hold", "hold-launch-1");
        let second = start_launched_fake_session(&sink, "hold", "hold-launch-2");

        tauri::async_runtime::block_on(stop_session(&sink, &first.id))
            .expect("first session should stop");
        tauri::async_runtime::block_on(stop_session(&sink, &first.id))
            .expect("repeated stop should be idempotent");
        assert!(!sessions().lock().unwrap().contains_key(&first.id));
        let second_pid = sessions().lock().unwrap()[&second.id].pid;
        assert!(is_current_session(&second.id, second_pid));

        tauri::async_runtime::block_on(stop_session(&sink, &second.id))
            .expect("second session should stop");
        assert!(!sessions().lock().unwrap().contains_key(&second.id));
    }

    #[cfg(all(windows, feature = "test-support"))]
    #[test]
    fn normal_adapter_exit_reaches_host_exit_waiter_once() {
        let adapter = fake_adapter_path();
        let (events, received) = mpsc::channel();
        let sink = RecordingSink { events };
        let session = tauri::async_runtime::block_on(start_debug_adapter_session(
            sink.clone(),
            DebugAdapterLaunch {
                command: adapter.to_string_lossy().into_owned(),
                args: Vec::new(),
                cwd: None,
                env: HashMap::new(),
                workspace_path: None,
            },
        ))
        .expect("host should start the fake adapter");
        tauri::async_runtime::block_on(send_debug_request(
            sink.clone(),
            DebugSendRequest {
                session_id: session.id.clone(),
                command: "launch".to_string(),
                arguments: json!({ "request": "launch", "name": "Demo" }),
                operation_id: Some("normal-launch".to_string()),
            },
        ))
        .expect("host should queue launch");
        mark_session_ready(&sink, &session.id).expect("startup gate should open");

        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        let mut ended = Vec::new();
        while std::time::Instant::now() < deadline {
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            let Ok((name, payload)) = received.recv_timeout(remaining) else {
                break;
            };
            if name == "debugger_session_ended" {
                ended.push(payload);
                break;
            }
        }
        assert_eq!(ended.len(), 1);
        assert_eq!(ended[0]["reason"], "exited");
        assert!(received.recv_timeout(Duration::from_millis(100)).is_err());
        assert!(!sessions().lock().unwrap().contains_key(&session.id));
    }

    #[test]
    fn rejects_updates_without_outbound_frames() {
        let sink = Mutex::new(Vec::new());
        let error = write_outbound_frames(&sink, &json!({ "sessionId": "session-1" })).unwrap_err();
        assert!(error.contains("invalid session update"));
    }

    #[test]
    fn reports_adapter_stdin_write_failure() {
        struct FailingWriter;
        impl Write for FailingWriter {
            fn write(&mut self, _buffer: &[u8]) -> std::io::Result<usize> {
                Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "closed"))
            }

            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }

        let stdin = Mutex::new(FailingWriter);
        let update = json!({
            "outboundFrames": [BASE64.encode(b"Content-Length: 0\r\n\r\n")]
        });
        let error = write_outbound_frames(&stdin, &update).unwrap_err();
        assert!(error.contains("Could not write to debug adapter input"));
    }

    #[test]
    fn derives_adapter_identifier_from_the_executable_name() {
        assert_eq!(adapter_identifier(r"C:\tools\bun.exe"), "bun");
        assert_eq!(adapter_identifier("python"), "python");
        assert_eq!(adapter_identifier(""), "custom");
    }

    #[test]
    fn facade_launch_reaches_the_adapter_through_the_shared_state_machine() {
        let session_id = format!("facade-session-{}", std::process::id());
        let created = execute_core_sync(
            "debug.createSession",
            json!({
                "sessionId": session_id,
                "adapterId": "fake-adapter",
                "rootPath": ".",
                "supportsRunInTerminalRequest": false,
            }),
        )
        .unwrap();
        assert_eq!(created["state"], "initializing");
        assert_eq!(created["outboundFrames"].as_array().unwrap().len(), 1);

        let (_, launch_payload) = translate_request(
            &session_id,
            "launch",
            &json!({ "name": "Demo", "request": "launch", "program": "C:/work/main.js" }),
            "facade-op-1",
        )
        .unwrap();
        let launched = execute_core_sync("debug.launch", launch_payload).unwrap();
        assert!(launched["outboundFrames"].as_array().unwrap().is_empty());

        // The fake adapter answers initialize and announces readiness; Core
        // then emits the queued launch and closes the configuration handshake.
        let initialize_response = json!({
            "seq": 101,
            "type": "response",
            "request_seq": 1,
            "success": true,
            "command": "initialize",
            "body": { "supportsConfigurationDoneRequest": true }
        });
        let initialized_event = json!({ "seq": 102, "type": "event", "event": "initialized" });
        let mut adapter_bytes = dap_frame(&initialize_response);
        adapter_bytes.extend(dap_frame(&initialized_event));

        let received = execute_core_sync(
            "debug.receive",
            json!({
                "sessionId": session_id,
                "dataBase64": BASE64.encode(&adapter_bytes),
            }),
        )
        .unwrap();
        let commands = decode_frame_commands(received["outboundFrames"].as_array().unwrap());
        assert_eq!(
            commands,
            vec!["launch", "setExceptionBreakpoints", "configurationDone"]
        );
        let event_types = received["events"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|event| event["type"].as_str())
            .collect::<Vec<_>>();
        assert!(event_types.contains(&"initialized"));
        assert!(event_types.contains(&"capabilities"));

        execute_core_sync("debug.destroySession", json!({ "sessionId": session_id })).unwrap();
    }

    fn dap_frame(message: &Value) -> Vec<u8> {
        let body = serde_json::to_vec(message).unwrap();
        let mut frame = format!("Content-Length: {}\r\n\r\n", body.len()).into_bytes();
        frame.extend(body);
        frame
    }

    fn decode_frame_commands(frames: &[Value]) -> Vec<String> {
        frames
            .iter()
            .filter_map(|frame| {
                let bytes = BASE64.decode(frame.as_str()?).ok()?;
                let text = String::from_utf8(bytes).ok()?;
                let body_start = text.find("\r\n\r\n")? + 4;
                let message: Value = serde_json::from_str(&text[body_start..]).ok()?;
                message
                    .get("command")
                    .and_then(Value::as_str)
                    .map(str::to_string)
            })
            .collect()
    }
}
