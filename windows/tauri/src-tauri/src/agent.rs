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
//! `{ connectionId, event }`, and every command must come from that same window.
//! `agent_close`, window destruction, and application exit release the connection
//! and its process tree; exit stops accepting connections and waits a bounded
//! time for the closes that are already running.
//! See `.agents/notes/implemented/architecture/2026-09-25-shared-acp-agent-conversation.md`.

use lithe_agent_host::{AgentCommand, AgentEvent, AgentHandle, AgentLaunch};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};
use tauri::{Emitter, Manager};

/// Tauri event carrying the Agent events of every connection.
pub const AGENT_EVENT_NAME: &str = "agent_event";

/// How long application exit waits for closes that are already running before
/// it abandons them. `AgentHandle::close` bounds its own stop window, so this
/// only covers a blocking task that never got scheduled.
const CLOSING_WAIT: Duration = Duration::from_secs(15);

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

/// Queues one shared `AgentCommand` on an open connection owned by the caller.
#[tauri::command]
pub fn agent_send(
    webview: tauri::Webview,
    connection_id: String,
    command: Value,
) -> Result<(), String> {
    send_command(webview.label(), &connection_id, command)
}

/// Stops one connection owned by the caller, and its process tree. Repeated
/// calls are no-ops.
#[tauri::command]
pub async fn agent_close(webview: tauri::Webview, connection_id: String) -> Result<(), String> {
    close_connection(webview.label(), &connection_id).await
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

/// Live connections keyed by the caller's connection id, plus whether new ones
/// are still accepted. Process-wide so the window-destroyed and
/// application-exit hooks reach the same registry without an `AppHandle`,
/// mirroring `debug.rs`.
struct Registry {
    connections: HashMap<String, Connection>,
    /// Cleared by application exit in the same critical section that drains the
    /// connections: one opened after that drain would never be closed.
    accepting: bool,
}

fn registry() -> &'static Mutex<Registry> {
    static REGISTRY: OnceLock<Mutex<Registry>> = OnceLock::new();
    REGISTRY.get_or_init(|| {
        Mutex::new(Registry {
            connections: HashMap::new(),
            accepting: true,
        })
    })
}

fn open_connection<S: AgentEventSink>(
    window: &str,
    request: AgentOpenRequest,
    sink: S,
) -> Result<AgentConnectionInfo, String> {
    let mut registry = registry()
        .lock()
        .map_err(|_| "Agent connection state is unavailable.".to_string())?;
    open_in(&mut registry, window, request, sink)
}

/// Opens one connection in `registry`. Takes the registry instead of locking it
/// so exit can hold a single critical section for its drain, and so tests can
/// drive the accepting rules without the process-wide state.
fn open_in<S: AgentEventSink>(
    registry: &mut Registry,
    window: &str,
    request: AgentOpenRequest,
    sink: S,
) -> Result<AgentConnectionInfo, String> {
    if !registry.accepting {
        return Err(
            "The application is shutting down, so no Agent connection can be opened.".into(),
        );
    }
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

    if registry.connections.contains_key(&connection_id) {
        return Err(format!("Agent connection {connection_id} is already open."));
    }
    let handle = AgentHandle::open(launch, emit)?;
    registry.connections.insert(
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

/// Queues one command on a connection, provided `window` opened it.
fn send_command(window: &str, connection_id: &str, command: Value) -> Result<(), String> {
    let registry = registry()
        .lock()
        .map_err(|_| "Agent connection state is unavailable.".to_string())?;
    let connection = registry
        .connections
        .get(connection_id)
        .ok_or_else(|| format!("Agent connection {connection_id} is not open."))?;
    verify_owner(window, connection_id, connection)?;
    let command: AgentCommand = serde_json::from_value(command)
        .map_err(|error| format!("Invalid Agent command: {error}"))?;
    connection.handle.send(command)
}

/// Rejects a command that names a connection another window opened. Events are
/// already addressed to the owner, so without this check a second window could
/// drive or close a connection it never opened.
fn verify_owner(window: &str, connection_id: &str, connection: &Connection) -> Result<(), String> {
    if connection.window == window {
        return Ok(());
    }
    Err(format!(
        "Agent connection {connection_id} belongs to another window."
    ))
}

/// Removes every connection `select` accepts from `registry`, counting them in
/// `state` as closing when a state is given. `select` may reject the whole call
/// with an error, which leaves the registry untouched.
///
/// Accounting inside the same critical section is what makes application exit
/// safe: an exit that drains the registry can neither miss a connection a close
/// path has already taken, nor observe the registry empty while a close that
/// path handed to the blocking pool is still pending.
fn take_connections(
    registry: &mut Registry,
    state: Option<&ClosingState>,
    select: impl Fn(&str, &Connection) -> Result<bool, String>,
) -> Result<Vec<Connection>, String> {
    let mut owned = Vec::new();
    for (connection_id, connection) in &registry.connections {
        if select(connection_id, connection)? {
            owned.push(connection_id.clone());
        }
    }
    let taken: Vec<Connection> = owned
        .into_iter()
        .filter_map(|connection_id| registry.connections.remove(&connection_id))
        .collect();
    if let Some(state) = state {
        // The count is raised before the caller can queue the close, so a
        // concurrent exit can never observe zero while a close is pending.
        account_closing(state, taken.len());
    }
    Ok(taken)
}

/// Stops the connection `window` opened. Repeated or late closes are no-ops, and
/// another window's connection is rejected without being touched.
async fn close_connection(window: &str, connection_id: &str) -> Result<(), String> {
    let taken = {
        let mut registry = registry()
            .lock()
            .map_err(|_| "Agent connection state is unavailable.".to_string())?;
        take_connections(&mut registry, Some(closing()), |id, connection| {
            if id != connection_id {
                return Ok(false);
            }
            verify_owner(window, connection_id, connection)?;
            Ok(true)
        })?
    };
    let Some(connection) = taken.into_iter().next() else {
        // Repeated, late, and unknown closes are no-ops that never touch a newer
        // or another window's connection.
        return Ok(());
    };
    // `AgentHandle::close` waits for the bounded stop window and force-kills the
    // process tree, so it must stay off the async runtime's worker threads.
    queue_close(move || connection.handle.close())
        .await
        .map_err(|error| format!("Agent connection cleanup failed: {error}"))
}

/// Closes already handed to the blocking pool, so application exit can wait for
/// them. A destroyed window removes its connection from the registry before the
/// close finishes, and closing the last window quits the application, so
/// without this counter the exit path would abandon a process tree mid-teardown.
type ClosingState = Arc<(Mutex<usize>, Condvar)>;

fn closing() -> &'static ClosingState {
    static CLOSING: OnceLock<ClosingState> = OnceLock::new();
    CLOSING.get_or_init(|| Arc::new((Mutex::new(0), Condvar::new())))
}

/// Raises the running-close count for closes that are about to be queued.
///
/// Poisoning is ignored on purpose: a waiter that cannot read the count does not
/// wait at all, so losing the count can only shorten a wait, never hang it.
fn account_closing(state: &ClosingState, added: usize) {
    if let Ok(mut count) = state.0.lock() {
        *count += added;
    }
}

/// Marks one queued close as finished and wakes application exit.
fn finish_closing(state: &ClosingState) {
    if let Ok(mut count) = state.0.lock() {
        *count = count.saturating_sub(1);
        state.1.notify_all();
    }
}

/// Runs one already-counted close on the blocking pool, reporting completion to
/// `finish_closing` so application exit can wait for it.
fn queue_close<C: FnOnce() + Send + 'static>(close: C) -> tauri::async_runtime::JoinHandle<()> {
    tauri::async_runtime::spawn_blocking(move || {
        close();
        finish_closing(closing());
    })
}

/// Waits until no close is running; false means the deadline passed first.
fn wait_for_closing(state: &ClosingState, deadline: Instant) -> bool {
    let Ok(mut count) = state.0.lock() else {
        return true;
    };
    while *count > 0 {
        let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
            return false;
        };
        match state.1.wait_timeout(count, remaining) {
            Ok((next, _)) => count = next,
            Err(_) => return true,
        }
    }
    true
}

/// Releases every connection owned by one window when a project window closes,
/// so a closed project never leaves an Agent process behind. Cleanup runs on the
/// blocking pool because the window is already gone and stopping an Agent waits
/// for its bounded stop window. Dropping the handle detaches the task.
pub fn close_window_connections(window: &str) {
    let taken = {
        let Ok(mut registry) = registry().lock() else {
            return;
        };
        take_connections(&mut registry, Some(closing()), |_, connection| {
            Ok(connection.window == window)
        })
        .unwrap_or_default()
    };
    for connection in taken {
        drop(queue_close(move || connection.handle.close()));
    }
}

/// Takes every connection and stops accepting new ones, in one critical section,
/// so nothing can be opened behind an exit that already drained the registry.
fn drain_in(registry: &mut Registry) -> Vec<Connection> {
    registry.accepting = false;
    registry
        .connections
        .drain()
        .map(|(_, connection)| connection)
        .collect()
}

/// Closes every live connection during application exit so no Agent process
/// outlives the shell. Runs synchronously: the process is about to exit, and a
/// detached cleanup task would be abandoned with it. Connections a destroyed
/// window already handed to the blocking pool are waited for afterwards, up to
/// `CLOSING_WAIT`.
pub fn shutdown() {
    // These closes run inline, so they are not counted as pending pool work.
    let live = match registry().lock() {
        Ok(mut registry) => drain_in(&mut registry),
        Err(_) => Vec::new(),
    };
    for connection in live {
        connection.handle.close();
    }
    if !wait_for_closing(closing(), Instant::now() + CLOSING_WAIT) {
        eprintln!("Agent shutdown timed out while waiting for an in-flight close.");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(windows)]
    use std::path::{Path, PathBuf};
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
            // A test that has already finished no longer reads events, and its
            // connection worker can still report one; dropping it is not a
            // failure. A test that is waiting asserts on its own `recv_timeout`.
            let _ = self.events.send((connection_id.to_string(), event));
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

    fn close(window: &str, connection_id: &str) {
        tauri::async_runtime::block_on(close_connection(window, connection_id)).expect("close");
    }

    /// Reads the registry without counting a close, for assertions about what is
    /// still open. Production paths remove and account in one step.
    fn take_connection(connection_id: &str) -> Result<Option<Connection>, String> {
        let mut registry = registry()
            .lock()
            .map_err(|_| "Agent connection state is unavailable.".to_string())?;
        Ok(
            take_connections(&mut registry, None, |id, _| Ok(id == connection_id))?
                .into_iter()
                .next(),
        )
    }

    /// Path of the ACP fixture the process-tree tests spawn. It is a regular
    /// binary, so the suite has it without enabling `test-support`.
    #[cfg(windows)]
    fn fixture_path() -> PathBuf {
        let test_binary = std::env::current_exe().expect("test binary path");
        test_binary
            .parent()
            .and_then(Path::parent)
            .expect("target directory")
            .join("fake-acp-adapter.exe")
    }

    /// Where the fixture records the process ids of its wrapper and grandchild.
    #[cfg(windows)]
    fn fixture_pid_file(label: &str) -> PathBuf {
        let path =
            std::env::temp_dir().join(format!("lithe-fake-acp-{label}-{}.txt", std::process::id()));
        let _ = std::fs::remove_file(&path);
        path
    }

    /// Starts the fixture adapter: a live ACP connection whose wrapper owns a
    /// grandchild that inherits stdout, like a real adapter's app-server.
    #[cfg(windows)]
    fn fixture_request(connection_id: &str, pid_file: &Path) -> AgentOpenRequest {
        AgentOpenRequest {
            connection_id: connection_id.to_string(),
            workspace_path: std::env::temp_dir().to_string_lossy().into_owned(),
            launch: json!({
                "command": fixture_path().to_string_lossy(),
                "args": ["serve", pid_file.to_string_lossy()],
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

    /// Waits for one event, failing with the host's message when the connection
    /// stops first: a fixture that cannot complete the handshake must not look
    /// like a lifecycle failure.
    #[cfg(windows)]
    fn wait_for_event(receiver: &mpsc::Receiver<(String, Value)>, connection_id: &str, kind: &str) {
        let deadline = Instant::now() + EVENT_WAIT;
        loop {
            let remaining = deadline
                .checked_duration_since(Instant::now())
                .unwrap_or_else(|| {
                    panic!("no `{kind}` event for {connection_id} before the deadline")
                });
            let (event_connection, event) = receiver
                .recv_timeout(remaining)
                .expect("an Agent event before the deadline");
            assert_eq!(event_connection, connection_id);
            if event["kind"] == kind {
                return;
            }
            assert_ne!(
                event["kind"], "stopped",
                "the fixture adapter stopped before `{kind}`: {}",
                event["message"]
            );
        }
    }

    /// Waits for the wrapper and grandchild process ids the fixture recorded.
    #[cfg(windows)]
    fn wait_for_fixture_tree(pid_file: &Path) -> (u32, u32) {
        let deadline = Instant::now() + EVENT_WAIT;
        loop {
            if let Some(tree) = read_fixture_tree(pid_file) {
                return tree;
            }
            assert!(
                Instant::now() < deadline,
                "the fixture must record its process tree before the deadline: {}",
                pid_file.display()
            );
            // test-stability: allow(rust-real-sleep) reason: the pid file is written by a separate fixture process, so bounded polling of that file is the only readiness signal; the deadline above already bounds the loop.
            std::thread::sleep(Duration::from_millis(25));
        }
    }

    #[cfg(windows)]
    fn read_fixture_tree(pid_file: &Path) -> Option<(u32, u32)> {
        let contents = std::fs::read_to_string(pid_file).ok()?;
        let mut adapter = None;
        let mut grandchild = None;
        for line in contents.lines() {
            let mut fields = line.split_whitespace();
            match (fields.next(), fields.next()) {
                (Some("adapter"), Some(pid)) => adapter = pid.parse().ok(),
                (Some("grandchild"), Some(pid)) => grandchild = pid.parse().ok(),
                _ => {}
            }
        }
        Some((adapter?, grandchild?))
    }

    /// Whether the process is still running. A killed process is only observable
    /// through the operating system, so liveness is polled against a deadline.
    #[cfg(windows)]
    fn process_alive(pid: u32) -> bool {
        let mut system = sysinfo::System::new();
        system.refresh_processes(sysinfo::ProcessesToUpdate::All, true);
        system.process(sysinfo::Pid::from_u32(pid)).is_some()
    }

    /// Asserts the host reclaimed the whole tree, and kills whatever survived so
    /// a failure cannot leak fixture processes into the rest of the suite.
    #[cfg(windows)]
    fn assert_fixture_tree_reclaimed(tree: (u32, u32)) {
        let (adapter, grandchild) = tree;
        let deadline = Instant::now() + EVENT_WAIT;
        loop {
            let adapter_alive = process_alive(adapter);
            let grandchild_alive = process_alive(grandchild);
            if !adapter_alive && !grandchild_alive {
                return;
            }
            if Instant::now() >= deadline {
                kill_fixture_survivors(tree);
                panic!(
                    "the whole adapter tree must be reclaimed; adapter {adapter} alive: {adapter_alive}, grandchild {grandchild} alive: {grandchild_alive}"
                );
            }
            // test-stability: allow(rust-real-sleep) reason: an externally killed process has no callback, so bounded operating-system liveness polling is the only way to verify the cleanup; the deadline above bounds the loop.
            std::thread::sleep(Duration::from_millis(25));
        }
    }

    #[cfg(windows)]
    fn kill_fixture_survivors(tree: (u32, u32)) {
        let mut system = sysinfo::System::new();
        system.refresh_processes(sysinfo::ProcessesToUpdate::All, true);
        for pid in [tree.1, tree.0] {
            if let Some(process) = system.process(sysinfo::Pid::from_u32(pid)) {
                process.kill();
            }
        }
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
        let still_open = send_command("test-window", "test-unique-id", json!("not a command"))
            .expect_err("the command payload is invalid");
        assert!(still_open.contains("Invalid Agent command"), "{still_open}");
        close("test-window", "test-unique-id");
    }

    #[test]
    fn a_failed_launch_is_reported_and_close_is_repeatable() {
        let (sink, receiver) = recording();
        let opened = open_connection("test-window-failure", request("test-failed-launch"), sink)
            .expect("open should succeed before the launch fails");
        assert_eq!(opened.connection_id, "test-failed-launch");

        wait_for_stopped(&receiver, "test-failed-launch");

        close("test-window-failure", "test-failed-launch");
        // A late close must stay a no-op instead of touching a newer connection.
        close("test-window-failure", "test-failed-launch");
        assert!(take_connection("test-failed-launch")
            .expect("registry")
            .is_none());
    }

    #[test]
    fn unknown_connections_and_malformed_commands_are_rejected() {
        let error = send_command(
            "test-window-unknown",
            "test-unknown-connection",
            json!("not a command"),
        )
        .expect_err("an unknown connection must be rejected");
        assert!(error.contains("is not open"), "{error}");

        let (sink, _receiver) = recording();
        open_connection(
            "test-window-commands",
            request("test-malformed-command"),
            sink,
        )
        .expect("open should succeed before the launch fails");

        let error = send_command(
            "test-window-commands",
            "test-malformed-command",
            json!("not a command"),
        )
        .expect_err("a malformed command must be rejected");
        assert!(error.contains("Invalid Agent command"), "{error}");

        close("test-window-commands", "test-malformed-command");
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

        let released = send_command(
            "test-window-a",
            "test-window-a-connection",
            json!("not a command"),
        )
        .expect_err("the closed window's connection must be gone");
        assert!(released.contains("is not open"), "{released}");

        // The other window keeps its connection: its send fails on the command
        // payload, never on a missing connection.
        let kept = send_command(
            "test-window-b",
            "test-window-b-connection",
            json!("not a command"),
        )
        .expect_err("the command payload is still invalid");
        assert!(kept.contains("Invalid Agent command"), "{kept}");

        close_window_connections("test-window-b");

        // Both windows' closes must drain to zero, otherwise application exit
        // would wait the whole bounded window for closes that already finished.
        assert!(wait_for_closing(closing(), Instant::now() + EVENT_WAIT));
    }

    #[test]
    fn exit_wait_returns_at_once_when_no_close_is_running() {
        let state: ClosingState = Arc::new((Mutex::new(0), Condvar::new()));
        assert!(wait_for_closing(&state, Instant::now() + EVENT_WAIT));
    }

    #[test]
    fn exit_wait_gives_up_at_its_deadline_while_a_close_is_pending() {
        let state: ClosingState = Arc::new((Mutex::new(1), Condvar::new()));
        let started = Instant::now();

        assert!(!wait_for_closing(
            &state,
            started + Duration::from_millis(100)
        ));

        assert!(started.elapsed() >= Duration::from_millis(100));
    }

    #[test]
    fn exit_wait_returns_once_the_last_close_is_released() {
        let state: ClosingState = Arc::new((Mutex::new(1), Condvar::new()));
        let waiter = state.clone();
        let (result, released) = mpsc::channel();
        std::thread::spawn(move || {
            let _ = result.send(wait_for_closing(&waiter, Instant::now() + EVENT_WAIT));
        });

        finish_closing(&state);

        assert!(
            released
                .recv_timeout(EVENT_WAIT)
                .expect("the wait must return"),
            "waking a pending close must report that nothing is running"
        );
    }

    #[test]
    fn taking_a_connection_for_a_close_counts_it_before_any_task_runs() {
        let (sink, _receiver) = recording();
        let mut registry = Registry {
            connections: HashMap::new(),
            accepting: true,
        };
        open_in(
            &mut registry,
            "test-window-accounting",
            request("test-accounting-connection"),
            sink,
        )
        .expect("open the window's connection");
        let state: ClosingState = Arc::new((Mutex::new(0), Condvar::new()));

        let taken = take_connections(&mut registry, Some(&state), |_, connection| {
            Ok(connection.window == "test-window-accounting")
        })
        .expect("registry");

        assert_eq!(taken.len(), 1);
        // The count is visible before any close is queued, which is what stops
        // application exit from observing an empty registry and leaving then.
        assert_eq!(*state.0.lock().expect("count"), 1);
        assert!(registry.connections.is_empty());

        for connection in taken {
            connection.handle.close();
        }
        finish_closing(&state);
        assert!(wait_for_closing(&state, Instant::now() + EVENT_WAIT));
    }

    #[test]
    fn an_exit_drain_takes_every_connection_and_refuses_new_ones() {
        let (sink, _receiver) = recording();
        let mut registry = Registry {
            connections: HashMap::new(),
            accepting: true,
        };
        open_in(
            &mut registry,
            "test-window-exit",
            request("test-exit-connection"),
            sink,
        )
        .expect("open before exit");

        let taken = drain_in(&mut registry);

        assert_eq!(taken.len(), 1);
        assert!(!registry.accepting);

        let (later_sink, _later_receiver) = recording();
        let error = open_in(
            &mut registry,
            "test-window-exit",
            request("test-after-exit"),
            later_sink,
        )
        .expect_err("exit must refuse a connection nothing would close");
        assert!(error.contains("shutting down"), "{error}");
        assert!(registry.connections.is_empty());

        for connection in taken {
            connection.handle.close();
        }
    }

    #[test]
    fn a_window_cannot_drive_or_close_another_windows_connection() {
        let (sink, _receiver) = recording();
        open_connection("test-window-owner", request("test-owned-connection"), sink)
            .expect("open the owner's connection");

        let refused = send_command(
            "test-window-intruder",
            "test-owned-connection",
            json!("not a command"),
        )
        .expect_err("another window must not queue commands on the connection");
        assert!(refused.contains("belongs to another window"), "{refused}");

        let refused = tauri::async_runtime::block_on(close_connection(
            "test-window-intruder",
            "test-owned-connection",
        ))
        .expect_err("another window must not close the connection");
        assert!(refused.contains("belongs to another window"), "{refused}");

        // The refused calls left the owner's connection untouched: its send still
        // fails on the payload, never on a missing connection.
        let kept = send_command(
            "test-window-owner",
            "test-owned-connection",
            json!("not a command"),
        )
        .expect_err("the command payload is still invalid");
        assert!(kept.contains("Invalid Agent command"), "{kept}");

        close("test-window-owner", "test-owned-connection");
    }

    /// Closing a live connection reclaims the whole Agent process tree, not just
    /// the wrapper the host started: the fixture's grandchild inherits stdout,
    /// so a host that only waited for the direct child would leave it running
    /// and holding the connection's output pipe.
    #[cfg(windows)]
    #[test]
    fn closing_a_live_connection_reclaims_the_whole_agent_tree() {
        let (sink, receiver) = recording();
        let pid_file = fixture_pid_file("close");
        open_connection(
            "test-window-tree-close",
            fixture_request("test-tree-close", &pid_file),
            sink,
        )
        .expect("open a live fixture adapter");

        wait_for_event(&receiver, "test-tree-close", "ready");
        let tree = wait_for_fixture_tree(&pid_file);

        close("test-window-tree-close", "test-tree-close");

        assert_fixture_tree_reclaimed(tree);
        assert!(take_connection("test-tree-close")
            .expect("registry")
            .is_none());
        let _ = std::fs::remove_file(&pid_file);
    }

    /// Destroying a project window releases the connection it opened and its
    /// whole process tree, so a closed project cannot leave an Agent running.
    #[cfg(windows)]
    #[test]
    fn destroying_a_window_reclaims_the_agent_tree_it_opened() {
        let (sink, receiver) = recording();
        let pid_file = fixture_pid_file("window");
        open_connection(
            "test-window-tree-owner",
            fixture_request("test-tree-window", &pid_file),
            sink,
        )
        .expect("open a live fixture adapter");

        wait_for_event(&receiver, "test-tree-window", "ready");
        let tree = wait_for_fixture_tree(&pid_file);

        close_window_connections("test-window-tree-owner");

        assert!(take_connection("test-tree-window")
            .expect("registry")
            .is_none());
        assert_fixture_tree_reclaimed(tree);
        let _ = std::fs::remove_file(&pid_file);
    }
}
