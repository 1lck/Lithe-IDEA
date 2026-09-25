//! Shared ACP client connection and bounded agent subprocess ownership.
//!
//! One [`AgentHandle`] owns one agent process and one ACP connection for a
//! workspace. A connection carries many conversation sessions; the agent owns
//! their history (`session/list`, `session/load`). Product UI, settings, and
//! credential storage stay with the platform applications.
//! See `.agents/notes/implemented/architecture/2026-09-25-shared-acp-agent-conversation.md`.

use std::collections::{HashMap, VecDeque};
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::Duration;

use agent_client_protocol::schema::v1::{
    AuthCapabilities, AuthenticateRequest, CancelNotification, ClientCapabilities, ContentBlock,
    InitializeRequest, ListSessionsRequest, LoadSessionRequest, NewSessionRequest, PromptRequest,
    RequestPermissionOutcome, RequestPermissionRequest, RequestPermissionResponse,
    SelectedPermissionOutcome, SessionNotification, TextContent,
};
use agent_client_protocol::schema::ProtocolVersion;
use agent_client_protocol::{Agent, ByteStreams, Client, ConnectionTo};
use serde::{Deserialize, Serialize};
use tokio::io::AsyncReadExt;
use tokio::sync::{mpsc as async_mpsc, oneshot};
use tokio::task::JoinSet;
use tokio_util::compat::{TokioAsyncReadCompatExt, TokioAsyncWriteCompatExt};

const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(20);
const SESSION_REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const LOAD_SESSION_TIMEOUT: Duration = Duration::from_secs(60);
const STOP_TIMEOUT: Duration = Duration::from_secs(3);
const PERMISSION_TIMEOUT: Duration = Duration::from_secs(300);
/// Upper bound on `session/list` pages so a misbehaving cursor cannot loop forever.
const MAX_SESSION_LIST_PAGES: usize = 50;
/// Bytes of agent stderr kept for failure reports; older output is discarded.
const STDERR_TAIL_BYTES: usize = 16 * 1024;
const STDERR_TAIL_LINES: usize = 20;
/// Auth method id and `_meta` key of the ACP custom model gateway extension.
/// Lithe authenticates only with user-supplied API keys through this method and
/// never triggers an agent's own account login.
const GATEWAY_AUTH_METHOD: &str = "gateway";

/// Launch configuration supplied by the owning desktop product.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentLaunch {
    pub command: String,
    #[serde(default)]
    pub args: Vec<String>,
    /// Absolute workspace root; sessions are created and listed for this directory.
    pub cwd: PathBuf,
    pub gateway: GatewayAuth,
}

/// User-supplied OpenAI-compatible Responses endpoint and API key.
///
/// The key is sent to the agent only inside the ACP `authenticate` request over
/// the stdio pipe; it is never placed in arguments, environment, or files.
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GatewayAuth {
    /// Base URL without the `/responses` suffix, e.g. `https://host/v1`.
    pub base_url: String,
    pub api_key: String,
    #[serde(default)]
    pub provider_name: Option<String>,
    /// Allow a plain `http` endpoint, e.g. a local gateway the user opted into.
    #[serde(default)]
    pub allow_insecure_http: bool,
}

impl GatewayAuth {
    /// Responses base URL accepted by the agent, from a provider endpoint that
    /// may already end in `/responses`.
    fn normalized_base_url(&self) -> Result<String, String> {
        let trimmed = self.base_url.trim().trim_end_matches('/');
        let base = trimmed.strip_suffix("/responses").unwrap_or(trimmed);
        let secure = base.starts_with("https://");
        let insecure = base.starts_with("http://");
        if !(secure || insecure && self.allow_insecure_http) {
            return Err("The API endpoint must use https".into());
        }
        let host = base
            .split_once("://")
            .map(|(_, rest)| rest)
            .unwrap_or_default();
        if host.is_empty() || host.starts_with('/') || base.contains(['?', '#', ' ']) {
            return Err("The API endpoint is not a valid URL".into());
        }
        Ok(base.to_owned())
    }
}

impl std::fmt::Debug for GatewayAuth {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("GatewayAuth")
            .field("base_url", &self.base_url)
            .field("api_key", &"<redacted>")
            .field("provider_name", &self.provider_name)
            .field("allow_insecure_http", &self.allow_insecure_http)
            .finish()
    }
}

/// Commands accepted by an open connection, as UTF-8 JSON from the platform.
///
/// `token` values are caller-chosen and echoed on the matching result event so
/// the UI can correlate concurrent requests.
#[derive(Debug, Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum AgentCommand {
    NewSession {
        token: String,
    },
    LoadSession {
        token: String,
        session_id: String,
    },
    ListSessions {
        token: String,
    },
    Prompt {
        session_id: String,
        text: String,
    },
    Cancel {
        session_id: String,
    },
    Permission {
        request_id: String,
        option_id: Option<String>,
    },
}

/// One entry of the agent-owned conversation history for the workspace.
#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AgentSessionSummary {
    pub session_id: String,
    pub title: Option<String>,
    /// ISO 8601 timestamp reported by the agent, if any.
    pub updated_at: Option<String>,
}

/// Events emitted from the connection worker thread.
///
/// Field names are fixed by `shared/fixtures/agent/acp-events-v1.json`.
#[derive(Debug, Serialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum AgentEvent {
    /// Initialization and API-key authentication succeeded.
    Ready {
        agent_name: Option<String>,
        agent_version: Option<String>,
        can_load_sessions: bool,
        can_list_sessions: bool,
    },
    SessionCreated {
        token: String,
        session_id: String,
    },
    /// `session/load` returned. History replay arrives as `update` events and
    /// may continue after this event.
    SessionLoaded {
        token: String,
        session_id: String,
    },
    Sessions {
        token: String,
        sessions: Vec<AgentSessionSummary>,
    },
    /// A raw ACP `SessionUpdate`, including replayed history.
    Update {
        session_id: String,
        update: serde_json::Value,
    },
    Permission {
        session_id: String,
        request_id: String,
        request: serde_json::Value,
    },
    /// The turn ended. A user cancel reports `cancelled` immediately without
    /// waiting for the agent, so a later response for that turn is dropped.
    TurnFinished {
        session_id: String,
        stop_reason: String,
    },
    /// A command failed without ending the connection.
    RequestFailed {
        token: Option<String>,
        session_id: Option<String>,
        message: String,
    },
    /// The connection ended. `message` is absent only after a requested stop.
    Stopped {
        message: Option<String>,
    },
}

type Emit = Arc<dyn Fn(AgentEvent) + Send + Sync + 'static>;

struct PendingPermission {
    session_id: String,
    reply: oneshot::Sender<Option<String>>,
}

/// Permission requests awaiting a user decision, keyed by Lithe request id.
type PendingPermissions = Arc<Mutex<HashMap<String, PendingPermission>>>;

/// Running turn generation per session. A session is absent while idle, so a
/// response whose generation no longer matches belongs to a cancelled turn.
type RunningTurns = Arc<Mutex<HashMap<String, u64>>>;

enum Control {
    Command(AgentCommand),
    Stop,
}

/// One agent process and ACP connection. Dropping it stops the process tree.
pub struct AgentHandle {
    controls: async_mpsc::UnboundedSender<Control>,
    permissions: PendingPermissions,
    child_pid: Arc<AtomicU32>,
    finished: mpsc::Receiver<()>,
    worker: Option<std::thread::JoinHandle<()>>,
}

impl AgentHandle {
    /// Start the worker thread, spawn the agent, and authenticate.
    ///
    /// Invalid settings and launch or protocol failures are reported as a
    /// `stopped` event with a user-facing message; no process is started for
    /// invalid settings. Only a failure to create the worker thread is returned.
    pub fn open(launch: AgentLaunch, emit: Emit) -> Result<Self, String> {
        let (controls, receiver) = async_mpsc::unbounded_channel();
        let (finished_tx, finished) = mpsc::channel();
        let permissions: PendingPermissions = Arc::new(Mutex::new(HashMap::new()));
        let child_pid = Arc::new(AtomicU32::new(0));
        let pending = permissions.clone();
        let pid = child_pid.clone();
        let worker = std::thread::Builder::new()
            .name("lithe-acp-connection".into())
            .spawn(move || {
                let runtime = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build();
                let message = match runtime {
                    Ok(runtime) => runtime
                        .block_on(run_agent(launch, receiver, pending, pid, emit.clone()))
                        .err(),
                    Err(error) => Some(error.to_string()),
                };
                emit(AgentEvent::Stopped { message });
                let _ = finished_tx.send(());
            })
            .map_err(|error| error.to_string())?;
        Ok(Self {
            controls,
            permissions,
            child_pid,
            finished,
            worker: Some(worker),
        })
    }

    /// Queue a command. Permission answers and cancel-time permission
    /// rejection take effect immediately on the calling thread.
    pub fn send(&self, command: AgentCommand) -> Result<(), String> {
        match command {
            AgentCommand::Permission {
                request_id,
                option_id,
            } => answer_permission(&self.permissions, &request_id, option_id),
            command => {
                if let AgentCommand::Cancel { session_id } = &command {
                    // ACP requires pending permission requests of a cancelled
                    // turn to be answered `cancelled`; do it before queuing.
                    reject_pending_permissions(&self.permissions, Some(session_id));
                }
                self.controls
                    .send(Control::Command(command))
                    .map_err(|_| "Agent connection has stopped".into())
            }
        }
    }

    /// Stop the connection and bound cleanup of the subprocess tree.
    pub fn close(mut self) {
        self.stop();
    }

    fn stop(&mut self) {
        if self.worker.is_none() {
            return;
        }
        reject_pending_permissions(&self.permissions, None);
        let _ = self.controls.send(Control::Stop);
        if self.finished.recv_timeout(STOP_TIMEOUT).is_err() {
            let pid = self.child_pid.load(Ordering::SeqCst);
            if pid != 0 {
                force_kill_tree(pid);
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

/// Deliver a user decision; `None` rejects. Fails once the request is gone.
fn answer_permission(
    permissions: &PendingPermissions,
    request_id: &str,
    option_id: Option<String>,
) -> Result<(), String> {
    let pending = permissions
        .lock()
        .ok()
        .and_then(|mut pending| pending.remove(request_id));
    match pending {
        Some(pending) => {
            let _ = pending.reply.send(option_id);
            Ok(())
        }
        None => Err("The permission request is no longer pending".into()),
    }
}

fn reject_pending_permissions(permissions: &PendingPermissions, session_id: Option<&str>) {
    if let Ok(mut pending) = permissions.lock() {
        let ids: Vec<String> = pending
            .iter()
            .filter(|(_, entry)| session_id.is_none_or(|id| entry.session_id == id))
            .map(|(id, _)| id.clone())
            .collect();
        for id in ids {
            if let Some(entry) = pending.remove(&id) {
                let _ = entry.reply.send(None);
            }
        }
    }
}

/// Bounded buffer of the most recent agent stderr bytes.
#[derive(Default)]
struct StderrTail(VecDeque<u8>);

impl StderrTail {
    fn push(&mut self, bytes: &[u8]) {
        self.0.extend(bytes);
        let excess = self.0.len().saturating_sub(STDERR_TAIL_BYTES);
        self.0.drain(..excess);
    }

    /// Last lines of stderr with the API key removed, or `None` when empty.
    fn summary(&self, secret: &str) -> Option<String> {
        let (front, back) = self.0.as_slices();
        let text = String::from_utf8_lossy(&[front, back].concat()).into_owned();
        let lines: Vec<&str> = text
            .lines()
            .filter(|line| !line.trim().is_empty())
            .collect();
        let start = lines.len().saturating_sub(STDERR_TAIL_LINES);
        let tail = lines[start..].join("\n");
        (!tail.is_empty()).then(|| redact(&tail, secret))
    }
}

fn redact(text: &str, secret: &str) -> String {
    if secret.is_empty() {
        text.to_owned()
    } else {
        text.replace(secret, "<redacted>")
    }
}

/// Child `PATH` with the executable's directory first. Package managers such
/// as npm install an agent script next to the `node` it runs with, and GUI
/// apps do not inherit the login shell's `PATH`.
fn child_path(command: &Path) -> Option<OsString> {
    let directory = command.parent().filter(|dir| dir.is_absolute())?;
    let mut paths = vec![directory.to_path_buf()];
    if let Some(existing) = std::env::var_os("PATH") {
        paths.extend(std::env::split_paths(&existing));
    }
    std::env::join_paths(paths).ok()
}

fn validate(launch: &AgentLaunch) -> Result<(), String> {
    if launch.command.trim().is_empty() {
        return Err("Set the ACP Agent executable before starting a conversation".into());
    }
    if !launch.cwd.is_absolute() {
        return Err("The workspace path must be absolute".into());
    }
    if launch.gateway.api_key.trim().is_empty() {
        return Err("An API key is required".into());
    }
    launch.gateway.normalized_base_url().map(|_| ())
}

async fn run_agent(
    launch: AgentLaunch,
    controls: async_mpsc::UnboundedReceiver<Control>,
    permissions: PendingPermissions,
    child_pid: Arc<AtomicU32>,
    emit: Emit,
) -> Result<(), String> {
    validate(&launch)?;
    let mut command = std::process::Command::new(&launch.command);
    command.args(&launch.args).current_dir(&launch.cwd);
    if let Some(path) = child_path(Path::new(&launch.command)) {
        command.env("PATH", path);
    }
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
    let mut child = command
        .spawn()
        .map_err(|error| format!("Could not start the Agent: {error}"))?;
    child_pid.store(child.id().unwrap_or(0), Ordering::SeqCst);
    let stdin = child.stdin.take().ok_or("Agent stdin is unavailable")?;
    let stdout = child.stdout.take().ok_or("Agent stdout is unavailable")?;
    let mut stderr = child.stderr.take().ok_or("Agent stderr is unavailable")?;
    let tail = Arc::new(Mutex::new(StderrTail::default()));
    let stderr_tail = tail.clone();
    let stderr_task = tokio::spawn(async move {
        let mut buffer = [0u8; 4096];
        while let Ok(read) = stderr.read(&mut buffer).await {
            if read == 0 {
                break;
            }
            if let Ok(mut tail) = stderr_tail.lock() {
                tail.push(&buffer[..read]);
            }
        }
    });
    let secret = launch.gateway.api_key.clone();
    let transport = ByteStreams::new(stdin.compat_write(), stdout.compat());
    let result = run_connection(
        transport,
        launch.cwd,
        launch.gateway,
        controls,
        permissions,
        emit,
    )
    .await;
    // The connection may finish before the child exits. Never leave its process
    // tree running, including wrapper commands which launch another process.
    terminate_tree(&mut child).await;
    child_pid.store(0, Ordering::SeqCst);
    let _ = tokio::time::timeout(STOP_TIMEOUT, stderr_task).await;
    result.map_err(|message| {
        let message = redact(&message, &secret);
        match tail.lock().ok().and_then(|tail| tail.summary(&secret)) {
            Some(stderr) => format!("{message}\n\nAgent output:\n{stderr}"),
            None => message,
        }
    })
}

/// Ask the whole agent tree to exit, then force-kill whatever is left.
///
/// Agents such as codex-acp run a separate app-server that can outlive the
/// wrapper by seconds after SIGTERM. Once the direct child exits, descendants
/// are re-parented and no longer reachable from its PID, so the tree is
/// recorded before signalling and survivors are killed by recorded PID.
async fn terminate_tree(child: &mut tokio::process::Child) {
    let Some(pid) = child.id() else {
        return;
    };
    let tree: Vec<u32> = kill_tree::blocking::kill_tree(pid)
        .map(|outputs| {
            outputs
                .into_iter()
                .filter_map(|output| match output {
                    kill_tree::Output::Killed { process_id, .. } => Some(process_id),
                    kill_tree::Output::MaybeAlreadyTerminated { .. } => None,
                })
                .collect()
        })
        .unwrap_or_default();
    let _ = tokio::time::timeout(STOP_TIMEOUT, child.wait()).await;
    for process_id in tree {
        force_kill_tree(process_id);
    }
    let _ = tokio::time::timeout(STOP_TIMEOUT, child.wait()).await;
}

/// SIGKILL a process and its descendants; a process that already exited is ignored.
fn force_kill_tree(process_id: u32) {
    let config = kill_tree::Config {
        signal: "SIGKILL".into(),
        include_target: true,
    };
    let _ = kill_tree::blocking::kill_tree_with_config(process_id, &config);
}

async fn run_connection<OB, IB>(
    transport: ByteStreams<OB, IB>,
    cwd: PathBuf,
    gateway: GatewayAuth,
    mut controls: async_mpsc::UnboundedReceiver<Control>,
    permissions: PendingPermissions,
    emit: Emit,
) -> Result<(), String>
where
    OB: futures::io::AsyncWrite + Send + 'static,
    IB: futures::io::AsyncRead + Send + 'static,
{
    let turns: RunningTurns = Arc::new(Mutex::new(HashMap::new()));
    let updates = emit.clone();
    let requests = emit.clone();
    let permission_turns = turns.clone();
    let cancel_permissions = permissions.clone();
    let stop_requested = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let stopped = stop_requested.clone();
    let result = Client
        .builder()
        .on_receive_notification(
            async move |notification: SessionNotification, _| {
                if let Ok(update) = serde_json::to_value(notification.update) {
                    updates(AgentEvent::Update {
                        session_id: notification.session_id.0.to_string(),
                        update,
                    });
                }
                Ok(())
            },
            agent_client_protocol::on_receive_notification!(),
        )
        .on_receive_request(
            async move |request: RequestPermissionRequest, responder, _| {
                let session_id = request.session_id.0.to_string();
                let request_id = uuid::Uuid::new_v4().to_string();
                let (reply, receiver) = oneshot::channel();
                // Register under the permission lock only while the turn is
                // still running, so a concurrent cancel cannot miss it.
                let registered = match permissions.lock() {
                    Ok(mut pending) => {
                        let running = permission_turns
                            .lock()
                            .is_ok_and(|turns| turns.contains_key(&session_id));
                        if running {
                            pending.insert(
                                request_id.clone(),
                                PendingPermission {
                                    session_id: session_id.clone(),
                                    reply,
                                },
                            );
                        }
                        running
                    }
                    Err(_) => false,
                };
                if !registered {
                    return responder.respond(RequestPermissionResponse::new(
                        RequestPermissionOutcome::Cancelled,
                    ));
                }
                if let Ok(value) = serde_json::to_value(&request) {
                    requests(AgentEvent::Permission {
                        session_id,
                        request_id: request_id.clone(),
                        request: value,
                    });
                }
                let selected = tokio::time::timeout(PERMISSION_TIMEOUT, receiver)
                    .await
                    .ok()
                    .and_then(Result::ok)
                    .flatten();
                if let Ok(mut pending) = permissions.lock() {
                    pending.remove(&request_id);
                }
                let outcome = match selected.filter(|id| {
                    request
                        .options
                        .iter()
                        .any(|option| option.option_id.0.as_ref() == id)
                }) {
                    Some(id) => {
                        RequestPermissionOutcome::Selected(SelectedPermissionOutcome::new(id))
                    }
                    None => RequestPermissionOutcome::Cancelled,
                };
                responder.respond(RequestPermissionResponse::new(outcome))
            },
            agent_client_protocol::on_receive_request!(),
        )
        // Without this, an agent that exits leaves the command loop waiting
        // forever and the UI never learns the connection is gone.
        .on_close(async |_| Err(internal("The Agent exited")))
        .connect_with(transport, |connection: ConnectionTo<Agent>| async move {
            let capabilities = ClientCapabilities::new().auth(AuthCapabilities::new().meta(
                serde_json::Map::from_iter([(
                    GATEWAY_AUTH_METHOD.to_owned(),
                    serde_json::Value::Bool(true),
                )]),
            ));
            let initialized = tokio::time::timeout(
                HANDSHAKE_TIMEOUT,
                connection
                    .send_request(
                        InitializeRequest::new(ProtocolVersion::V1)
                            .client_capabilities(capabilities),
                    )
                    .block_task(),
            )
            .await
            .map_err(|_| internal("The Agent did not finish initialization in time"))??;
            if !initialized
                .auth_methods
                .iter()
                .any(|method| method.id().0.as_ref() == GATEWAY_AUTH_METHOD)
            {
                return Err(internal(
                    "This Agent does not support signing in with a custom API key",
                ));
            }
            tokio::time::timeout(
                HANDSHAKE_TIMEOUT,
                connection
                    .send_request(gateway_authentication(&gateway))
                    .block_task(),
            )
            .await
            .map_err(|_| internal("The Agent did not finish API key sign-in in time"))??;
            let agent = initialized.agent_info.as_ref();
            emit(AgentEvent::Ready {
                agent_name: agent.map(|info| info.name.clone()),
                agent_version: agent.map(|info| info.version.clone()),
                can_load_sessions: initialized.agent_capabilities.load_session,
                can_list_sessions: initialized
                    .agent_capabilities
                    .session_capabilities
                    .list
                    .is_some(),
            });

            let generations = AtomicU64::new(0);
            let mut tasks = JoinSet::new();
            while let Some(control) = controls.recv().await {
                while tasks.try_join_next().is_some() {}
                let command = match control {
                    Control::Stop => {
                        stopped.store(true, Ordering::SeqCst);
                        break;
                    }
                    Control::Command(command) => command,
                };
                match command {
                    AgentCommand::NewSession { token } => {
                        let connection = connection.clone();
                        let emit = emit.clone();
                        let cwd = cwd.clone();
                        tasks.spawn(async move {
                            let result = request_with_timeout(
                                SESSION_REQUEST_TIMEOUT,
                                connection
                                    .send_request(NewSessionRequest::new(cwd))
                                    .block_task(),
                            )
                            .await;
                            emit(match result {
                                Ok(response) => AgentEvent::SessionCreated {
                                    token,
                                    session_id: response.session_id.0.to_string(),
                                },
                                Err(message) => failed(Some(token), None, message),
                            });
                        });
                    }
                    AgentCommand::LoadSession { token, session_id } => {
                        let connection = connection.clone();
                        let emit = emit.clone();
                        let cwd = cwd.clone();
                        tasks.spawn(async move {
                            let result = request_with_timeout(
                                LOAD_SESSION_TIMEOUT,
                                connection
                                    .send_request(LoadSessionRequest::new(session_id.clone(), cwd))
                                    .block_task(),
                            )
                            .await;
                            emit(match result {
                                Ok(_) => AgentEvent::SessionLoaded { token, session_id },
                                Err(message) => failed(Some(token), Some(session_id), message),
                            });
                        });
                    }
                    AgentCommand::ListSessions { token } => {
                        let connection = connection.clone();
                        let emit = emit.clone();
                        let cwd = cwd.clone();
                        tasks.spawn(async move {
                            emit(match list_sessions(&connection, cwd).await {
                                Ok(sessions) => AgentEvent::Sessions { token, sessions },
                                Err(message) => failed(Some(token), None, message),
                            });
                        });
                    }
                    AgentCommand::Prompt { session_id, text } => {
                        let generation = generations.fetch_add(1, Ordering::SeqCst) + 1;
                        let busy = match turns.lock() {
                            Ok(mut turns) if !turns.contains_key(&session_id) => {
                                turns.insert(session_id.clone(), generation);
                                false
                            }
                            _ => true,
                        };
                        if busy {
                            emit(failed(
                                None,
                                Some(session_id),
                                "The Agent is still responding in this conversation".into(),
                            ));
                            continue;
                        }
                        let request = PromptRequest::new(
                            session_id.clone(),
                            vec![ContentBlock::Text(TextContent::new(text))],
                        );
                        let response = connection.send_request(request).block_task();
                        let emit = emit.clone();
                        let turns = turns.clone();
                        tasks.spawn(async move {
                            let result = response.await;
                            // Only the running generation may report; a cancel
                            // already reported `cancelled` for older turns.
                            let current = turns.lock().is_ok_and(|mut turns| {
                                let current = turns.get(&session_id) == Some(&generation);
                                if current {
                                    turns.remove(&session_id);
                                }
                                current
                            });
                            if !current {
                                return;
                            }
                            emit(match result {
                                Ok(response) => AgentEvent::TurnFinished {
                                    session_id,
                                    stop_reason: stop_reason_name(&response.stop_reason),
                                },
                                Err(error) => failed(None, Some(session_id), error.to_string()),
                            });
                        });
                    }
                    AgentCommand::Cancel { session_id } => {
                        let running = turns
                            .lock()
                            .is_ok_and(|mut turns| turns.remove(&session_id).is_some());
                        // A request registered after the caller's rejection but before
                        // this point would otherwise wait for its timeout.
                        reject_pending_permissions(&cancel_permissions, Some(&session_id));
                        if running {
                            // Mirror mainstream ACP clients: send one cancel,
                            // end the turn in the UI now, and keep awaiting
                            // the agent's reply in the prompt task.
                            let _ = connection
                                .send_notification(CancelNotification::new(session_id.clone()));
                            emit(AgentEvent::TurnFinished {
                                session_id,
                                stop_reason: "cancelled".into(),
                            });
                        }
                    }
                    AgentCommand::Permission { .. } => {}
                }
            }
            let running: Vec<String> = turns
                .lock()
                .map(|turns| turns.keys().cloned().collect())
                .unwrap_or_default();
            for session_id in running {
                let _ = connection.send_notification(CancelNotification::new(session_id));
            }
            tasks.abort_all();
            Ok(())
        })
        .await
        .map_err(|error| error.to_string());
    match result {
        Ok(()) if !stop_requested.load(Ordering::SeqCst) => {
            Err("The Agent connection closed unexpectedly".into())
        }
        other => other,
    }
}

fn internal(message: &str) -> agent_client_protocol::Error {
    agent_client_protocol::util::internal_error(message)
}

fn failed(token: Option<String>, session_id: Option<String>, message: String) -> AgentEvent {
    AgentEvent::RequestFailed {
        token,
        session_id,
        message,
    }
}

async fn request_with_timeout<T>(
    limit: Duration,
    request: impl std::future::Future<Output = Result<T, agent_client_protocol::Error>>,
) -> Result<T, String> {
    match tokio::time::timeout(limit, request).await {
        Ok(result) => result.map_err(|error| error.to_string()),
        Err(_) => Err("The Agent did not respond in time".into()),
    }
}

fn gateway_authentication(gateway: &GatewayAuth) -> AuthenticateRequest {
    let base_url = gateway
        .normalized_base_url()
        .unwrap_or_else(|_| gateway.base_url.clone());
    let mut settings = serde_json::json!({
        "baseUrl": base_url,
        "headers": { "Authorization": format!("Bearer {}", gateway.api_key) },
    });
    if let Some(name) = gateway
        .provider_name
        .as_deref()
        .filter(|name| !name.is_empty())
    {
        settings["providerName"] = serde_json::Value::String(name.to_owned());
    }
    AuthenticateRequest::new(GATEWAY_AUTH_METHOD).meta(serde_json::Map::from_iter([(
        GATEWAY_AUTH_METHOD.to_owned(),
        settings,
    )]))
}

/// ACP wire name of a stop reason, e.g. `end_turn`.
fn stop_reason_name(reason: &agent_client_protocol::schema::v1::StopReason) -> String {
    match serde_json::to_value(reason) {
        Ok(serde_json::Value::String(name)) => name,
        _ => "unknown".into(),
    }
}

async fn list_sessions(
    connection: &ConnectionTo<Agent>,
    cwd: PathBuf,
) -> Result<Vec<AgentSessionSummary>, String> {
    let mut sessions = Vec::new();
    let mut cursor: Option<String> = None;
    for _ in 0..MAX_SESSION_LIST_PAGES {
        let page = request_with_timeout(
            SESSION_REQUEST_TIMEOUT,
            connection
                .send_request(
                    ListSessionsRequest::new()
                        .cwd(cwd.clone())
                        .cursor(cursor.take()),
                )
                .block_task(),
        )
        .await?;
        sessions.extend(
            page.sessions
                .into_iter()
                .map(|session| AgentSessionSummary {
                    session_id: session.session_id.0.to_string(),
                    title: session.title,
                    updated_at: session.updated_at,
                }),
        );
        match page.next_cursor {
            Some(next) if !next.is_empty() => cursor = Some(next),
            _ => return Ok(sessions),
        }
    }
    Ok(sessions)
}

#[cfg(test)]
mod tests;
