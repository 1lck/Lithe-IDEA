//! Windows Agent host: long-lived ACP connections to a user-installed Agent.
//!
//! ACP protocol behavior, session history, permission bookkeeping, and the agent
//! process tree stay in `lithe-agent-host`; macOS reaches that crate through the
//! `lithe_agent_*` C ABI. This module is the Windows equivalent and owns only the
//! per-window connection registry, the Tauri command surface, and the projection
//! of serialized events to the React layer.
//!
//! Byte flow: React subscribes to `agent_event`, calls `agent_open` with its own
//! connection id and the shared `AgentLaunch` JSON, then `agent_send` with the
//! shared `AgentCommand` JSON. Each event reaches the owning window as
//! `{ connectionId, event }`. `agent_close`, window destruction, and application
//! exit release the connection and its process tree.
//! See `.agents/notes/implemented/architecture/2026-09-25-shared-acp-agent-conversation.md`.

use lithe_agent_host::{AgentCommand, AgentEvent, AgentHandle, AgentLaunch};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};
use tauri::{Emitter, Manager};

/// Tauri event carrying the Agent events of every connection.
pub const AGENT_EVENT_NAME: &str = "agent_event";

/// Opens one Agent connection owned by the calling window.
#[tauri::command]
pub fn agent_open(
    webview: tauri::Webview,
    request: AgentOpenRequest,
) -> Result<AgentConnectionInfo, String> {
    let sink = WindowEventSink {
        app: webview.app_handle().clone(),
        window: webview.label().to_string(),
    };
    open_connection(webview.label(), request, sink)
}

/// Queues one shared `AgentCommand` on an open connection.
#[tauri::command]
pub fn agent_send(connection_id: String, command: Value) -> Result<(), String> {
    send_command(&connection_id, command)
}

/// Stops one connection and its process tree. Repeated calls are no-ops.
#[tauri::command]
pub async fn agent_close(connection_id: String) -> Result<(), String> {
    close_connection(&connection_id).await
}

/// One `agent_open` request.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentOpenRequest {
    /// Caller-chosen id, unique among live connections. The UI subscribes to
    /// `agent_event` before opening, so no event can arrive without an owner.
    pub connection_id: String,
    /// Workspace root the Agent sessions belong to.
    pub workspace_path: String,
    /// Launch configuration in the shared `AgentLaunch` shape.
    pub launch: Value,
}

/// Identity of an open connection, echoed back to the UI.
#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AgentConnectionInfo {
    pub connection_id: String,
    pub workspace_path: String,
}

/// Receives one serialized event for a connection.
///
/// Production delivers to the owning window; tests inject a recorder, so
/// lifecycle behavior is verifiable without a Tauri application.
trait AgentEventSink: Clone + Send + Sync + 'static {
    fn emit_event(&self, connection_id: &str, event: Value);
}

/// Addresses events to the window that opened the connection, so an open
/// project never receives another project's Agent traffic.
#[derive(Clone)]
struct WindowEventSink {
    app: tauri::AppHandle,
    window: String,
}

impl AgentEventSink for WindowEventSink {
    fn emit_event(&self, connection_id: &str, event: Value) {
        let _ = self.app.emit_to(
            self.window.as_str(),
            AGENT_EVENT_NAME,
            json!({ "connectionId": connection_id, "event": event }),
        );
    }
}

struct Connection {
    /// Window label that owns this connection, used to release a whole project.
    window: String,
    handle: AgentHandle,
}

/// Live connections keyed by the caller's connection id. Process-wide so the
/// window-destroyed and application-exit hooks reach the same registry without
/// an `AppHandle`, mirroring `debug.rs`.
fn connections() -> &'static Mutex<HashMap<String, Connection>> {
    static CONNECTIONS: OnceLock<Mutex<HashMap<String, Connection>>> = OnceLock::new();
    CONNECTIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn open_connection<S: AgentEventSink>(
    window: &str,
    request: AgentOpenRequest,
    sink: S,
) -> Result<AgentConnectionInfo, String> {
    let connection_id = request.connection_id.trim().to_string();
    if connection_id.is_empty() {
        return Err("An Agent connection id is required.".into());
    }
    let launch: AgentLaunch = serde_json::from_value(request.launch)
        .map_err(|error| format!("Invalid Agent launch configuration: {error}"))?;

    let events = connection_id.clone();
    let emit: Arc<dyn Fn(AgentEvent) + Send + Sync + 'static> = Arc::new(move |event| {
        // A failure to serialize must never take down the connection worker.
        match serde_json::to_value(&event) {
            Ok(event) => sink.emit_event(&events, event),
            Err(error) => eprintln!("Could not serialize an Agent event: {error}"),
        }
    });

    let mut current = connections()
        .lock()
        .map_err(|_| "Agent connection state is unavailable.".to_string())?;
    if current.contains_key(&connection_id) {
        return Err(format!("Agent connection {connection_id} is already open."));
    }
    let handle = AgentHandle::open(launch, emit)?;
    current.insert(
        connection_id.clone(),
        Connection {
            window: window.to_owned(),
            handle,
        },
    );
    Ok(AgentConnectionInfo {
        connection_id,
        workspace_path: request.workspace_path,
    })
}

fn send_command(connection_id: &str, command: Value) -> Result<(), String> {
    let current = connections()
        .lock()
        .map_err(|_| "Agent connection state is unavailable.".to_string())?;
    let connection = current
        .get(connection_id)
        .ok_or_else(|| format!("Agent connection {connection_id} is not open."))?;
    let command: AgentCommand = serde_json::from_value(command)
        .map_err(|error| format!("Invalid Agent command: {error}"))?;
    connection.handle.send(command)
}

fn take_connection(connection_id: &str) -> Result<Option<Connection>, String> {
    let mut current = connections()
        .lock()
        .map_err(|_| "Agent connection state is unavailable.".to_string())?;
    Ok(current.remove(connection_id))
}

async fn close_connection(connection_id: &str) -> Result<(), String> {
    let Some(connection) = take_connection(connection_id)? else {
        // Repeated or late closes are no-ops and never touch a newer connection.
        return Ok(());
    };
    // `AgentHandle::close` waits for the bounded stop window and force-kills the
    // process tree, so it must stay off the async runtime's worker threads.
    tauri::async_runtime::spawn_blocking(move || connection.handle.close())
        .await
        .map_err(|error| format!("Agent connection cleanup failed: {error}"))
}

/// Releases every connection owned by one window when a project window closes,
/// so a closed project never leaves an Agent process behind. Cleanup runs on the
/// blocking pool because the window is already gone and stopping an Agent waits
/// for its bounded stop window.
pub fn close_window_connections(window: &str) {
    for connection in take_window_connections(window) {
        tauri::async_runtime::spawn_blocking(move || connection.handle.close());
    }
}

fn take_window_connections(window: &str) -> Vec<Connection> {
    let Ok(mut current) = connections().lock() else {
        return Vec::new();
    };
    let owned: Vec<String> = current
        .iter()
        .filter(|(_, connection)| connection.window == window)
        .map(|(connection_id, _)| connection_id.clone())
        .collect();
    owned
        .into_iter()
        .filter_map(|connection_id| current.remove(&connection_id))
        .collect()
}

/// Closes every live connection during application exit so no Agent process
/// outlives the shell. Runs synchronously: the process is about to exit, and a
/// detached cleanup task would be abandoned with it.
pub fn shutdown() {
    let Ok(mut current) = connections().lock() else {
        return;
    };
    let live: Vec<Connection> = current.drain().map(|(_, connection)| connection).collect();
    drop(current);
    for connection in live {
        connection.handle.close();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;
    use std::time::{Duration, Instant};

    /// Bound for the one asynchronous step these tests wait on: the connection
    /// worker reporting a launch failure as a `stopped` event.
    const EVENT_WAIT: Duration = Duration::from_secs(15);

    #[derive(Clone)]
    struct RecordingSink {
        events: mpsc::Sender<(String, Value)>,
    }

    impl AgentEventSink for RecordingSink {
        fn emit_event(&self, connection_id: &str, event: Value) {
            self.events
                .send((connection_id.to_string(), event))
                .expect("recording sink receiver should remain active");
        }
    }

    fn recording() -> (RecordingSink, mpsc::Receiver<(String, Value)>) {
        let (sender, receiver) = mpsc::channel();
        (RecordingSink { events: sender }, receiver)
    }

    /// A launch that resolves and then cannot start, so a connection reports a
    /// `stopped` event without an installed Agent, a network, or a fake adapter.
    fn request(connection_id: &str) -> AgentOpenRequest {
        AgentOpenRequest {
            connection_id: connection_id.to_string(),
            workspace_path: std::env::temp_dir().to_string_lossy().into_owned(),
            launch: json!({
                "command": "lithe-missing-agent-binary",
                "cwd": std::env::temp_dir(),
                "authentication": "apiKey",
                "provider": {
                    "protocol": "responses",
                    "baseUrl": "https://gateway.example.com/v1",
                    "apiKey": "test-key",
                },
            }),
        }
    }

    fn close(connection_id: &str) {
        tauri::async_runtime::block_on(close_connection(connection_id)).expect("close");
    }

    fn wait_for_stopped(receiver: &mpsc::Receiver<(String, Value)>, connection_id: &str) {
        let deadline = Instant::now() + EVENT_WAIT;
        loop {
            let remaining = deadline
                .checked_duration_since(Instant::now())
                .unwrap_or_else(|| {
                    panic!("no `stopped` event for {connection_id} before the deadline")
                });
            let (event_connection, event) = receiver
                .recv_timeout(remaining)
                .expect("an Agent event before the deadline");
            assert_eq!(event_connection, connection_id);
            if event["kind"] == "stopped" {
                return;
            }
        }
    }

    #[test]
    fn an_invalid_launch_is_rejected_without_opening_a_connection() {
        let (sink, _receiver) = recording();
        let mut invalid = request("test-invalid-launch");
        invalid.launch = json!({ "command": "lithe-missing-agent-binary" });

        let error = open_connection("test-window", invalid, sink)
            .expect_err("a launch without a workspace root must be rejected");

        assert!(
            error.contains("Invalid Agent launch configuration"),
            "{error}"
        );
        assert!(take_connection("test-invalid-launch")
            .expect("registry")
            .is_none());
    }

    #[test]
    fn a_connection_id_must_be_present_and_unique() {
        let (sink, _receiver) = recording();
        let mut blank = request("test-blank-id");
        blank.connection_id = "   ".into();

        let error = open_connection("test-window", blank, sink.clone())
            .expect_err("a blank connection id must be rejected");
        assert!(error.contains("connection id is required"), "{error}");

        let opened = open_connection("test-window", request("test-unique-id"), sink.clone())
            .expect("first open should succeed");
        assert_eq!(opened.connection_id, "test-unique-id");
        assert_eq!(
            opened.workspace_path,
            std::env::temp_dir().to_string_lossy().into_owned()
        );

        let error = open_connection("test-window", request("test-unique-id"), sink)
            .expect_err("a duplicate connection id must be rejected");
        assert!(error.contains("already open"), "{error}");

        // The rejected duplicate must not have replaced the live connection.
        let still_open = send_command("test-unique-id", json!("not a command"))
            .expect_err("the command payload is invalid");
        assert!(still_open.contains("Invalid Agent command"), "{still_open}");
        close("test-unique-id");
    }

    #[test]
    fn a_failed_launch_is_reported_and_close_is_repeatable() {
        let (sink, receiver) = recording();
        let opened = open_connection("test-window-failure", request("test-failed-launch"), sink)
            .expect("open should succeed before the launch fails");
        assert_eq!(opened.connection_id, "test-failed-launch");

        wait_for_stopped(&receiver, "test-failed-launch");

        close("test-failed-launch");
        // A late close must stay a no-op instead of touching a newer connection.
        close("test-failed-launch");
        assert!(take_connection("test-failed-launch")
            .expect("registry")
            .is_none());
    }

    #[test]
    fn unknown_connections_and_malformed_commands_are_rejected() {
        let error = send_command("test-unknown-connection", json!("not a command"))
            .expect_err("an unknown connection must be rejected");
        assert!(error.contains("is not open"), "{error}");

        let (sink, _receiver) = recording();
        open_connection(
            "test-window-commands",
            request("test-malformed-command"),
            sink,
        )
        .expect("open should succeed before the launch fails");

        let error = send_command("test-malformed-command", json!("not a command"))
            .expect_err("a malformed command must be rejected");
        assert!(error.contains("Invalid Agent command"), "{error}");

        close("test-malformed-command");
    }

    #[test]
    fn closing_a_window_releases_only_its_own_connections() {
        let (sink, _receiver) = recording();
        open_connection(
            "test-window-a",
            request("test-window-a-connection"),
            sink.clone(),
        )
        .expect("open the first window");
        open_connection("test-window-b", request("test-window-b-connection"), sink)
            .expect("open the second window");

        close_window_connections("test-window-a");

        let released = send_command("test-window-a-connection", json!("not a command"))
            .expect_err("the closed window's connection must be gone");
        assert!(released.contains("is not open"), "{released}");

        // The other window keeps its connection: its send fails on the command
        // payload, never on a missing connection.
        let kept = send_command("test-window-b-connection", json!("not a command"))
            .expect_err("the command payload is still invalid");
        assert!(kept.contains("Invalid Agent command"), "{kept}");

        close_window_connections("test-window-b");
    }
}
