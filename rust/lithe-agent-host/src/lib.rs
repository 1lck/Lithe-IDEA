//! Shared ACP client sessions and bounded agent subprocess ownership.
//!
//! This crate owns the protocol and process for both desktop products. Product
//! UI, settings, and persistence stay with the platform applications.
//! See `.agents/notes/implemented/architecture/2026-09-25-shared-acp-agent-conversation.md`.

use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::atomic::{AtomicU32, Ordering};
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
        session_id: String,
    },
    Update {
        update: serde_json::Value,
    },
    Permission {
        request_id: String,
        request: serde_json::Value,
    },
    TurnFinished {
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
        let child_pid = Arc::new(AtomicU32::new(0));
        let pending = permissions.clone();
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
        self.commands
            .send(Command::Prompt(text))
            .map_err(|_| "Agent session has stopped".into())
    }

    /// Request cancellation of the current prompt turn.
    pub fn cancel(&self) -> Result<(), String> {
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
        for (_, sender) in self.permissions.lock().expect("permission lock").drain() {
            let _ = sender.send(None);
        }
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

impl Drop for AgentHandle {
    fn drop(&mut self) {
        self.stop();
    }
}

async fn run_agent(
    launch: AgentLaunch,
    commands: async_mpsc::UnboundedReceiver<Command>,
    permissions: PendingPermissions,
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
    let result = run_connection(transport, launch.cwd, commands, permissions, emit).await;
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
                let request_id = uuid::Uuid::new_v4().to_string();
                let (sender, receiver) = oneshot::channel();
                if let Ok(mut pending) = permissions.lock() {
                    pending.insert(request_id.clone(), sender);
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
                                    }
                                    Some(Command::Stop) | None => {
                                        let _ = connection.send_notification(CancelNotification::new(session_id.clone()));
                                        return Ok(());
                                    }
                                    Some(Command::Prompt(_)) => {
                                        emit(AgentEvent::Error { message: "The Agent is still responding".into() });
                                    }
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
