//! Shared ACP client sessions and bounded agent subprocess ownership.
//!
//! This crate owns the protocol and process for both desktop products. Product
//! UI, settings, and persistence stay with the platform applications.
//! See `.agents/notes/implemented/architecture/2026-09-25-shared-acp-agent-conversation.md`.

use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::Duration;

use agent_client_protocol::schema::v1::{
    CancelNotification, ContentBlock, InitializeRequest, NewSessionRequest, PromptRequest,
    RequestPermissionOutcome, RequestPermissionRequest, RequestPermissionResponse,
    SelectedPermissionOutcome, SessionNotification, TextContent,
};
use agent_client_protocol::schema::ProtocolVersion;
use agent_client_protocol::{Agent, ByteStreams, Client, ConnectionTo};
use serde::{Deserialize, Serialize};
use tokio::sync::{mpsc as async_mpsc, oneshot};
use tokio_util::compat::{TokioAsyncReadCompatExt, TokioAsyncWriteCompatExt};

const START_TIMEOUT: Duration = Duration::from_secs(15);
const STOP_TIMEOUT: Duration = Duration::from_secs(3);
const PERMISSION_TIMEOUT: Duration = Duration::from_secs(300);
const CANCEL_TIMEOUT: Duration = Duration::from_secs(5);

/// Launch configuration supplied by the owning desktop product.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentLaunch {
    pub command: String,
    #[serde(default)]
    pub args: Vec<String>,
    pub cwd: PathBuf,
}

/// Events emitted in order from the ACP worker thread.
#[derive(Debug, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum AgentEvent {
    Ready {
        #[serde(rename = "sessionId")]
        session_id: String,
    },
    Update {
        update: serde_json::Value,
    },
    Permission {
        #[serde(rename = "requestId")]
        request_id: String,
        request: serde_json::Value,
    },
    TurnFinished {
        #[serde(rename = "stopReason")]
        stop_reason: String,
    },
    Error {
        message: String,
    },
    Stopped,
}

enum Command {
    Prompt(String),
    Cancel,
    Stop,
}

type PendingPermissions = Arc<Mutex<HashMap<String, oneshot::Sender<Option<String>>>>>;

/// One active ACP connection. Dropping it stops the worker and its child tree.
pub struct AgentHandle {
    commands: async_mpsc::UnboundedSender<Command>,
    permissions: PendingPermissions,
    cancellation_requested: Arc<AtomicBool>,
    child_pid: Arc<AtomicU32>,
    finished: mpsc::Receiver<()>,
    worker: Option<std::thread::JoinHandle<()>>,
}

impl AgentHandle {
    /// Start the worker without launching the agent until this method is called.
    pub fn open(
        launch: AgentLaunch,
        emit: Arc<dyn Fn(AgentEvent) + Send + Sync + 'static>,
    ) -> Result<Self, String> {
        if launch.command.trim().is_empty() || !launch.cwd.is_absolute() {
            return Err("Agent command and absolute workspace path are required".into());
        }
        let (commands, receiver) = async_mpsc::unbounded_channel();
        let (finished_tx, finished) = mpsc::channel();
        let permissions: PendingPermissions = Arc::new(Mutex::new(HashMap::new()));
        let cancellation_requested = Arc::new(AtomicBool::new(false));
        let child_pid = Arc::new(AtomicU32::new(0));
        let pending = permissions.clone();
        let cancelling = cancellation_requested.clone();
        let pid = child_pid.clone();
        let worker = std::thread::Builder::new()
            .name("lithe-acp-session".into())
            .spawn(move || {
                let runtime = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build();
                match runtime {
                    Ok(runtime) => {
                        if let Err(error) = runtime.block_on(run_agent(
                            launch,
                            receiver,
                            pending,
                            cancelling,
                            pid,
                            emit.clone(),
                        )) {
                            emit(AgentEvent::Error { message: error });
                        }
                    }
                    Err(error) => emit(AgentEvent::Error {
                        message: error.to_string(),
                    }),
                }
                emit(AgentEvent::Stopped);
                let _ = finished_tx.send(());
            })
            .map_err(|error| error.to_string())?;
        Ok(Self {
            commands,
            permissions,
            cancellation_requested,
            child_pid,
            finished,
            worker: Some(worker),
        })
    }

    /// Queue a user prompt for the active session.
    pub fn prompt(&self, text: String) -> Result<(), String> {
        if text.trim().is_empty() {
            return Err("The prompt is empty".into());
        }
        self.cancellation_requested.store(false, Ordering::SeqCst);
        self.commands
            .send(Command::Prompt(text))
            .map_err(|_| "Agent session has stopped".into())
    }

    /// Request cancellation of the current prompt turn.
    pub fn cancel(&self) -> Result<(), String> {
        self.cancellation_requested.store(true, Ordering::SeqCst);
        reject_pending_permissions(&self.permissions);
        self.commands
            .send(Command::Cancel)
            .map_err(|_| "Agent session has stopped".into())
    }

    /// Answer one permission request with an advertised option ID, or reject it.
    pub fn respond_permission(&self, request_id: &str, option_id: Option<String>) -> bool {
        let sender = self
            .permissions
            .lock()
            .ok()
            .and_then(|mut pending| pending.remove(request_id));
        sender.is_some_and(|sender| sender.send(option_id).is_ok())
    }

    /// Stop the session and bound cleanup of the subprocess tree.
    pub fn close(mut self) {
        self.stop();
    }

    fn stop(&mut self) {
        if self.worker.is_none() {
            return;
        }
        reject_pending_permissions(&self.permissions);
        let _ = self.commands.send(Command::Stop);
        if self.finished.recv_timeout(STOP_TIMEOUT).is_err() {
            let pid = self.child_pid.load(Ordering::SeqCst);
            if pid != 0 {
                let _ = kill_tree::blocking::kill_tree(pid);
            }
            let _ = self.finished.recv_timeout(STOP_TIMEOUT);
        }
        if let Some(worker) = self.worker.take() {
            if worker.is_finished() {
                let _ = worker.join();
            }
        }
    }
}

fn reject_pending_permissions(permissions: &PendingPermissions) {
    if let Ok(mut pending) = permissions.lock() {
        for (_, sender) in pending.drain() {
            let _ = sender.send(None);
        }
    }
}

impl Drop for AgentHandle {
    fn drop(&mut self) {
        self.stop();
    }
}

async fn run_agent(
    launch: AgentLaunch,
    commands: async_mpsc::UnboundedReceiver<Command>,
    permissions: PendingPermissions,
    cancellation_requested: Arc<AtomicBool>,
    child_pid: Arc<AtomicU32>,
    emit: Arc<dyn Fn(AgentEvent) + Send + Sync + 'static>,
) -> Result<(), String> {
    let mut command = std::process::Command::new(&launch.command);
    command.args(&launch.args).current_dir(&launch.cwd);
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    let mut command = tokio::process::Command::from(command);
    command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    command.kill_on_drop(true);
    let mut child = command.spawn().map_err(|error| error.to_string())?;
    child_pid.store(child.id().unwrap_or(0), Ordering::SeqCst);
    let stdin = child.stdin.take().ok_or("Agent stdin is unavailable")?;
    let stdout = child.stdout.take().ok_or("Agent stdout is unavailable")?;
    let mut stderr = child.stderr.take().ok_or("Agent stderr is unavailable")?;
    let stderr_task = tokio::spawn(async move {
        let _ = tokio::io::copy(&mut stderr, &mut tokio::io::sink()).await;
    });
    let transport = ByteStreams::new(stdin.compat_write(), stdout.compat());
    let result = run_connection(
        transport,
        launch.cwd,
        commands,
        permissions,
        cancellation_requested,
        emit,
    )
    .await;
    // The connection may finish before the child exits. Never leave its process
    // tree running, including wrapper commands which launch another process.
    if let Some(pid) = child.id() {
        let _ = kill_tree::blocking::kill_tree(pid);
    }
    let _ = tokio::time::timeout(STOP_TIMEOUT, child.wait()).await;
    child_pid.store(0, Ordering::SeqCst);
    stderr_task.abort();
    result
}

async fn run_connection<OB, IB>(
    transport: ByteStreams<OB, IB>,
    cwd: PathBuf,
    mut commands: async_mpsc::UnboundedReceiver<Command>,
    permissions: PendingPermissions,
    cancellation_requested: Arc<AtomicBool>,
    emit: Arc<dyn Fn(AgentEvent) + Send + Sync + 'static>,
) -> Result<(), String>
where
    OB: futures::io::AsyncWrite + Send + 'static,
    IB: futures::io::AsyncRead + Send + 'static,
{
    let updates = emit.clone();
    let requests = emit.clone();
    Client
        .builder()
        .on_receive_notification(
            async move |notification: SessionNotification, _| {
                if let Ok(update) = serde_json::to_value(notification.update) {
                    updates(AgentEvent::Update { update });
                }
                Ok(())
            },
            agent_client_protocol::on_receive_notification!(),
        )
        .on_receive_request(
            async move |request: RequestPermissionRequest, responder, _| {
                if cancellation_requested.load(Ordering::SeqCst) {
                    return responder.respond(RequestPermissionResponse::new(
                        RequestPermissionOutcome::Cancelled,
                    ));
                }
                let request_id = uuid::Uuid::new_v4().to_string();
                let (sender, receiver) = oneshot::channel();
                if let Ok(mut pending) = permissions.lock() {
                    if cancellation_requested.load(Ordering::SeqCst) {
                        return responder.respond(RequestPermissionResponse::new(
                            RequestPermissionOutcome::Cancelled,
                        ));
                    }
                    pending.insert(request_id.clone(), sender);
                }
                if cancellation_requested.load(Ordering::SeqCst) {
                    reject_pending_permissions(&permissions);
                    return responder.respond(RequestPermissionResponse::new(
                        RequestPermissionOutcome::Cancelled,
                    ));
                }
                if let Ok(value) = serde_json::to_value(&request) {
                    requests(AgentEvent::Permission { request_id: request_id.clone(), request: value });
                }
                let selected = tokio::time::timeout(PERMISSION_TIMEOUT, receiver)
                    .await
                    .ok()
                    .and_then(Result::ok)
                    .flatten();
                if let Ok(mut pending) = permissions.lock() {
                    pending.remove(&request_id);
                }
                let outcome = match selected.filter(|id| request.options.iter().any(|option| option.option_id.0.as_ref() == id)) {
                    Some(id) => RequestPermissionOutcome::Selected(SelectedPermissionOutcome::new(id)),
                    None => RequestPermissionOutcome::Cancelled,
                };
                responder.respond(RequestPermissionResponse::new(outcome))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .connect_with(transport, |connection: ConnectionTo<Agent>| async move {
            tokio::time::timeout(
                START_TIMEOUT,
                connection.send_request(InitializeRequest::new(ProtocolVersion::V1)).block_task(),
            )
            .await
            .map_err(|_| agent_client_protocol::util::internal_error("ACP initialize timed out"))??;
            let session = tokio::time::timeout(
                START_TIMEOUT,
                connection.send_request(NewSessionRequest::new(cwd)).block_task(),
            )
            .await
            .map_err(|_| agent_client_protocol::util::internal_error("ACP session creation timed out"))??;
            let session_id = session.session_id;
            emit(AgentEvent::Ready { session_id: session_id.0.to_string() });

            while let Some(command) = commands.recv().await {
                match command {
                    Command::Stop => break,
                    Command::Cancel => {}
                    Command::Prompt(text) => {
                        let request = PromptRequest::new(
                            session_id.clone(),
                            vec![ContentBlock::Text(TextContent::new(text))],
                        );
                        let response = connection.send_request(request).block_task();
                        tokio::pin!(response);
                        let mut cancel_deadline: Option<tokio::time::Instant> = None;
                        loop {
                            tokio::select! {
                                result = &mut response => {
                                    match result {
                                        Ok(value) => emit(AgentEvent::TurnFinished {
                                            stop_reason: format!("{:?}", value.stop_reason),
                                        }),
                                        Err(error) => emit(AgentEvent::Error { message: error.to_string() }),
                                    }
                                    break;
                                }
                                command = commands.recv() => match command {
                                    Some(Command::Cancel) => {
                                        connection.send_notification(CancelNotification::new(session_id.clone()))?;
                                        cancel_deadline.get_or_insert_with(|| tokio::time::Instant::now() + CANCEL_TIMEOUT);
                                    }
                                    Some(Command::Stop) | None => {
                                        let _ = connection.send_notification(CancelNotification::new(session_id.clone()));
                                        return Ok(());
                                    }
                                    Some(Command::Prompt(_)) => {
                                        emit(AgentEvent::Error { message: "The Agent is still responding".into() });
                                    }
                                },
                                _ = tokio::time::sleep_until(cancel_deadline.unwrap_or_else(tokio::time::Instant::now)), if cancel_deadline.is_some() => {
                                    return Err(agent_client_protocol::util::internal_error("ACP cancellation timed out"));
                                }
                            }
                        }
                    }
                }
            }
            Ok(())
        })
        .await
        .map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serialized_events_match_the_swift_permission_fixture() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../shared/fixtures/agent/acp-events-v1.json"
        ))
        .expect("ACP event fixture");
        assert_eq!(fixture["version"], 1);
        let events = &fixture["events"];
        assert_eq!(
            serde_json::to_value(AgentEvent::Ready {
                session_id: "session-1".into(),
            })
            .unwrap(),
            events["ready"]
        );
        assert_eq!(
            serde_json::to_value(AgentEvent::Permission {
                request_id: "permission-1".into(),
                request: events["permission"]["request"].clone(),
            })
            .unwrap(),
            events["permission"]
        );
        assert_eq!(
            serde_json::to_value(AgentEvent::TurnFinished {
                stop_reason: "Cancelled".into(),
            })
            .unwrap(),
            events["turnFinished"]
        );
    }

    #[test]
    fn cancel_rejects_pending_permissions_before_queuing_notification() {
        let (commands, mut receiver) = async_mpsc::unbounded_channel();
        let (finished_tx, finished) = mpsc::channel();
        drop(finished_tx);
        let (reply, selected) = oneshot::channel();
        let permissions: PendingPermissions =
            Arc::new(Mutex::new(HashMap::from([("request-1".into(), reply)])));
        let handle = AgentHandle {
            commands,
            permissions,
            cancellation_requested: Arc::new(AtomicBool::new(false)),
            child_pid: Arc::new(AtomicU32::new(0)),
            finished,
            worker: None,
        };

        handle.cancel().expect("cancel queued");
        assert!(handle.cancellation_requested.load(Ordering::SeqCst));
        assert_eq!(selected.blocking_recv().expect("permission resolved"), None);
        assert!(matches!(receiver.try_recv(), Ok(Command::Cancel)));
        assert!(!handle.respond_permission("request-1", Some("allow_once".into())));
    }

    #[tokio::test(flavor = "current_thread", start_paused = true)]
    async fn early_cancel_ends_an_unresponsive_prompt_after_the_deadline() {
        use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

        let (client, peer) = tokio::io::duplex(4096);
        let (client_reader, client_writer) = tokio::io::split(client);
        let transport = ByteStreams::new(client_writer.compat_write(), client_reader.compat());
        let (commands, receiver) = async_mpsc::unbounded_channel();
        let (ready_tx, ready_rx) = oneshot::channel();
        let ready = Arc::new(Mutex::new(Some(ready_tx)));
        let (cancel_seen_tx, cancel_seen_rx) = oneshot::channel();
        let (release_peer_tx, release_peer_rx) = oneshot::channel::<()>();

        let peer_task = tokio::spawn(async move {
            let (reader, mut writer) = tokio::io::split(peer);
            let mut lines = tokio::io::BufReader::new(reader).lines();
            for result in [
                serde_json::json!({"protocolVersion": 1}),
                serde_json::json!({"sessionId": "test-session"}),
            ] {
                let line = lines.next_line().await.unwrap().unwrap();
                let request: serde_json::Value = serde_json::from_str(&line).unwrap();
                let reply = serde_json::json!({
                    "jsonrpc": "2.0", "id": request["id"], "result": result
                });
                writer
                    .write_all(reply.to_string().as_bytes())
                    .await
                    .unwrap();
                writer.write_all(b"\n").await.unwrap();
            }
            let prompt: serde_json::Value =
                serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
            assert!(prompt["method"].as_str().unwrap().contains("prompt"));
            let cancel: serde_json::Value =
                serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
            assert!(cancel["method"].as_str().unwrap().contains("cancel"));
            let _ = cancel_seen_tx.send(());
            let _ = release_peer_rx.await;
        });
        let worker = tokio::spawn(run_connection(
            transport,
            std::env::temp_dir(),
            receiver,
            Arc::new(Mutex::new(HashMap::new())),
            Arc::new(AtomicBool::new(false)),
            Arc::new(move |event| {
                if matches!(event, AgentEvent::Ready { .. }) {
                    if let Ok(mut sender) = ready.lock() {
                        if let Some(sender) = sender.take() {
                            let _ = sender.send(());
                        }
                    }
                }
            }),
        ));

        tokio::time::timeout(Duration::from_secs(1), ready_rx)
            .await
            .expect("ACP initialization reached the mock peer")
            .expect("ready event delivered");
        commands.send(Command::Prompt("hello".into())).unwrap();
        commands.send(Command::Cancel).unwrap();
        tokio::time::timeout(Duration::from_secs(1), cancel_seen_rx)
            .await
            .expect("ACP cancel notification was sent")
            .expect("mock peer observed cancel");
        tokio::time::advance(CANCEL_TIMEOUT).await;
        let result = tokio::time::timeout(Duration::from_secs(1), worker)
            .await
            .expect("cancel deadline ends the session")
            .expect("connection task completes");
        assert!(result.unwrap_err().contains("ACP cancellation timed out"));
        let _ = release_peer_tx.send(());
        peer_task.await.unwrap();
    }

    #[test]
    fn rejects_missing_command_without_spawning_worker() {
        let launch = AgentLaunch {
            command: " ".into(),
            args: vec![],
            cwd: std::env::temp_dir(),
        };
        let emit = Arc::new(|_: AgentEvent| {});
        assert!(AgentHandle::open(launch, emit).is_err());
    }

    #[test]
    fn spawn_failure_emits_error_then_stopped_and_closes() {
        let (sender, receiver) = mpsc::channel();
        let launch = AgentLaunch {
            command: "/lithe/nonexistent-acp-agent".into(),
            args: vec![],
            cwd: std::env::temp_dir(),
        };
        let mut handle = AgentHandle::open(
            launch,
            Arc::new(move |event| {
                let _ = sender.send(event);
            }),
        )
        .expect("worker starts");
        assert!(matches!(
            receiver.recv_timeout(Duration::from_secs(2)),
            Ok(AgentEvent::Error { .. })
        ));
        assert!(matches!(
            receiver.recv_timeout(Duration::from_secs(2)),
            Ok(AgentEvent::Stopped)
        ));
        handle.stop();
    }
}
