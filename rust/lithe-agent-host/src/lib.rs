//! Shared ACP client connection and bounded agent subprocess ownership.
//!
//! One [`AgentHandle`] owns one agent process and one ACP connection for a
//! workspace. A connection carries many conversation sessions; the agent owns
//! their history (`session/list`, `session/load`). Product UI, settings, and
//! credential storage stay with the platform applications.
//! See `.agents/notes/implemented/architecture/2026-09-25-shared-acp-agent-conversation.md`.

pub mod catalog;
pub mod cli_update;
mod codex_context;
mod codex_history;
mod codex_retry;
pub mod environment;
pub mod install;
mod model_calls;
mod model_proxy;
mod prompt;
mod prompt_retry;
mod session_defaults;
mod session_restore;
mod session_routing;
mod steering;
mod subagents;
mod subscription;
mod workspace_context;

pub use catalog::{ModelDelivery, ProviderProtocol};
pub use model_calls::{ContextComposition, ModelApi, ModelCall, ModelCallUsage};
pub use prompt::PromptFile;

use std::collections::{HashMap, VecDeque};
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::Duration;

use agent_client_protocol::schema::v1::{
    AuthCapabilities, AuthenticateRequest, CancelNotification, ClientCapabilities,
    ClientSessionCapabilities, ContentBlock, InitializeRequest, ListSessionsRequest,
    LoadSessionRequest, NoticeCapabilities, PromptRequest, RequestPermissionOutcome,
    RequestPermissionRequest, RequestPermissionResponse, SelectedPermissionOutcome,
    SessionConfigOption, SetSessionConfigOptionRequest,
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
const CANCEL_TIMEOUT: Duration = Duration::from_secs(10);
/// Longest wait for observed model calls of a turn to report before the turn
/// finishes, so per-turn statistics see them. Never affects unobserved turns.
const MODEL_CALL_SETTLE_TIMEOUT: Duration = Duration::from_secs(2);
/// Upper bound on `session/list` pages so a misbehaving cursor cannot loop forever.
const MAX_SESSION_LIST_PAGES: usize = 50;
/// Windows flag that runs the adapter with a console it cannot display. The
/// desktop shell is a GUI process without a console, so a console-subsystem
/// adapter would otherwise open a visible console window on every launch.
#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;
/// Bytes of agent stderr kept for failure reports; older output is discarded.
const STDERR_TAIL_BYTES: usize = 16 * 1024;
const STDERR_TAIL_LINES: usize = 20;
/// Auth method id and `_meta` key of the ACP custom model gateway extension.
/// Responses API-key mode uses this method and never falls back to account login.
const GATEWAY_AUTH_METHOD: &str = "gateway";
/// Environment variable naming the platform's process scope of one connection.
/// Every descendant of the agent inherits it, which is how a host recognizes the
/// agent's tasks even after they left its process group.
pub const AGENT_SCOPE_ENVIRONMENT: &str = "LITHE_AGENT_SCOPE";

/// Launch configuration supplied by the owning desktop product.
///
/// A catalog agent (`agentId`) is started from its Lithe-managed install and
/// receives the key the way its adapter requires. Without `agentId`, `command`
/// runs a user-provided agent that must support gateway sign-in.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentLaunch {
    #[serde(default)]
    pub agent_id: Option<String>,
    #[serde(default)]
    pub command: Option<String>,
    #[serde(default)]
    pub args: Vec<String>,
    /// Absolute workspace root; sessions are created and listed for this directory.
    pub cwd: PathBuf,
    /// Directory holding Lithe-managed adapter installs; required with `agentId`.
    #[serde(default)]
    pub data_directory: Option<PathBuf>,
    #[serde(default)]
    pub authentication: AgentAuthentication,
    pub provider: Option<ProviderCredentials>,
    /// Observe API-key or Codex subscription inference through the loopback
    /// proxy and emit model-call measurements without retaining request bodies.
    #[serde(default)]
    pub observe_model_calls: bool,
    /// Opt in only when the consuming product can present native child sessions.
    /// Omitted/false preserves legacy adapter output for other clients.
    #[serde(default)]
    pub observe_subagents: bool,
    /// Exported as [`AGENT_SCOPE_ENVIRONMENT`] to the agent process tree.
    #[serde(default)]
    pub process_scope: Option<String>,
}

/// Subscription access is explicit and limited to the installed Codex adapter.
#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum AgentAuthentication {
    #[default]
    ApiKey,
    CodexSubscription,
}

/// User-supplied AI provider endpoint and API key.
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderCredentials {
    pub protocol: ProviderProtocol,
    /// Endpoint as configured, with or without the protocol's path suffix.
    pub base_url: String,
    pub api_key: String,
    #[serde(default)]
    pub name: Option<String>,
    /// Model to request; empty or absent keeps the agent's default.
    #[serde(default)]
    pub model: Option<String>,
    /// Allow a plain `http` endpoint, e.g. a local gateway the user opted into.
    #[serde(default)]
    pub allow_insecure_http: bool,
}

impl ProviderCredentials {
    /// Responses base URL accepted by gateway sign-in, e.g. `https://host/v1`.
    fn responses_base_url(&self) -> Result<String, String> {
        let trimmed = self.base_url.trim().trim_end_matches('/');
        self.checked(trimmed.strip_suffix("/responses").unwrap_or(trimmed))
    }

    /// Anthropic base URL without `/v1` or `/v1/messages`, as the SDK expects.
    fn anthropic_base_url(&self) -> Result<String, String> {
        let trimmed = self.base_url.trim().trim_end_matches('/');
        let base = trimmed.strip_suffix("/messages").unwrap_or(trimmed);
        self.checked(base.strip_suffix("/v1").unwrap_or(base))
    }

    fn checked(&self, base: &str) -> Result<String, String> {
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

impl std::fmt::Debug for ProviderCredentials {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ProviderCredentials")
            .field("protocol", &self.protocol)
            .field("base_url", &self.base_url)
            .field("api_key", &"<redacted>")
            .field("name", &self.name)
            .field("model", &self.model)
            .field("allow_insecure_http", &self.allow_insecure_http)
            .finish()
    }
}

/// API-key routing sent over ACP stdio, using each adapter's supported interface.
#[derive(Clone)]
struct GatewaySignIn {
    protocol: ProviderProtocol,
    base_url: String,
    /// Authentication headers in the dialect of the provider's protocol.
    headers: Vec<(String, String)>,
    provider_name: Option<String>,
    model: Option<String>,
    /// Bounded native Codex recovery, with a pre-work HTTP 429 fallback.
    native_recovery: bool,
}

/// A validated launch: what to run and how the key reaches the agent.
struct ResolvedLaunch {
    command: PathBuf,
    args: Vec<String>,
    cwd: PathBuf,
    /// Non-secret CLI paths and model defaults for the native adapters.
    env: Vec<(String, String)>,
    gateway: Option<GatewaySignIn>,
    /// Key to redact from diagnostics.
    secret: String,
    /// The already detected Codex executable; never a separately downloaded runtime.
    subscription_cli: Option<PathBuf>,
}

#[cfg(test)]
fn resolve(launch: AgentLaunch) -> Result<ResolvedLaunch, String> {
    resolve_with_cancel(launch, &|| false)
}

/// Resolve a launch while allowing runtime and CLI detection to observe stop.
fn resolve_with_cancel(
    launch: AgentLaunch,
    cancel: &dyn Fn() -> bool,
) -> Result<ResolvedLaunch, String> {
    let resolved = resolve_with(launch, &|command| environment::detect_tool(command, cancel));
    if cancel() {
        return Err("Agent launch was cancelled".into());
    }
    resolved
}

/// [`resolve`] with an injectable lookup for the user's agent CLI.
fn resolve_with(
    launch: AgentLaunch,
    find_cli: &dyn Fn(&str) -> Option<environment::DetectedTool>,
) -> Result<ResolvedLaunch, String> {
    if launch.authentication == AgentAuthentication::CodexSubscription {
        return subscription::resolve(launch, find_cli);
    }
    let provider = launch.provider.ok_or("An API provider is required")?;
    if provider.api_key.trim().is_empty() {
        return Err("An API key is required".into());
    }
    if !launch.cwd.is_absolute() {
        return Err("The workspace path must be absolute".into());
    }
    // Credentials travel over ACP stdio. Claude uses its public session options
    // because its gateway mode adds a conflicting placeholder Bearer token.
    let native_recovery = launch.agent_id.as_deref() == Some("codex-acp");
    let gateway = |provider: &ProviderCredentials| -> Result<GatewaySignIn, String> {
        let (base_url, header) = match provider.protocol {
            ProviderProtocol::AnthropicMessages => (
                provider.anthropic_base_url()?,
                ("x-api-key".to_owned(), provider.api_key.clone()),
            ),
            ProviderProtocol::Responses | ProviderProtocol::ChatCompletions => (
                provider.responses_base_url()?,
                (
                    "Authorization".to_owned(),
                    format!("Bearer {}", provider.api_key),
                ),
            ),
        };
        Ok(GatewaySignIn {
            protocol: provider.protocol,
            base_url,
            headers: vec![header],
            provider_name: provider.name.clone(),
            model: provider.model.clone(),
            native_recovery,
        })
    };
    let Some(agent_id) = launch.agent_id else {
        let command = launch.command.unwrap_or_default();
        if command.trim().is_empty() {
            return Err("Set the ACP Agent executable before starting a conversation".into());
        }
        if provider.protocol != ProviderProtocol::Responses {
            return Err("A custom Agent needs a provider that uses the Responses API".into());
        }
        return Ok(ResolvedLaunch {
            command: PathBuf::from(command),
            args: launch.args,
            cwd: launch.cwd,
            env: Vec::new(),
            gateway: Some(gateway(&provider)?),
            secret: provider.api_key,
            subscription_cli: None,
        });
    };
    let agent = catalog::find(&agent_id).ok_or_else(|| format!("Unknown agent `{agent_id}`"))?;
    if provider.protocol != agent.protocol {
        return Err(format!(
            "{} needs an AI provider that uses the {} protocol",
            agent.name,
            match agent.protocol {
                ProviderProtocol::Responses => "Responses API",
                ProviderProtocol::ChatCompletions => "Chat Completions",
                ProviderProtocol::AnthropicMessages => "Anthropic Messages",
            }
        ));
    }
    let data_directory = launch
        .data_directory
        .ok_or("The Agent install directory is not configured")?;
    if install::installed_version(&data_directory, agent).is_none() {
        return Err(format!(
            "{} is not installed. Install it in Settings › Agents.",
            agent.name
        ));
    }
    let gateway = Some(gateway(&provider)?);
    let mut env = Vec::new();
    if let Some(cli) = &agent.cli {
        let detected = find_cli(cli.command);
        if let Some(issue) = install::cli_issue(cli, detected.as_ref()) {
            return Err(issue);
        }
        if let Some(entry) = detected.as_ref().and_then(|tool| cli_path_env(cli, tool)) {
            env.push(entry);
        }
    }
    let model = provider
        .model
        .as_deref()
        .map(str::trim)
        .filter(|model| !model.is_empty());
    match agent.model_delivery {
        ModelDelivery::CodexConfig => env.push((
            "CODEX_CONFIG".to_owned(),
            codex_session_config(model).to_string(),
        )),
        // A process-wide Claude pin also overrides every restored session.
        // New-session defaults instead travel through session_routing.
        ModelDelivery::ClaudeSessionOptions => {}
    }
    Ok(ResolvedLaunch {
        command: install::installed_command(&data_directory, agent),
        args: launch.args,
        cwd: launch.cwd,
        env,
        gateway,
        secret: provider.api_key,
        subscription_cli: None,
    })
}

/// Environment entry that points an adapter at the user's CLI.
///
/// On Windows, npm installs command shims as `.cmd` files. Adapters that pass
/// `path_env` straight to `child_process.spawn` cannot execute them; those
/// adapters use their bundled native launcher instead.
fn cli_path_env(
    cli: &catalog::AgentCli,
    tool: &environment::DetectedTool,
) -> Option<(String, String)> {
    let script_shim = cfg!(windows)
        && tool.path.extension().is_some_and(|extension| {
            extension.eq_ignore_ascii_case("cmd") || extension.eq_ignore_ascii_case("bat")
        });
    (!script_shim || cli.accepts_windows_shim).then(|| {
        (
            cli.path_env.to_owned(),
            tool.path.to_string_lossy().into_owned(),
        )
    })
}

/// Enable Codex's native checklist for Lithe-owned conversations. Codex defaults
/// it off; the adapter forwards its plan events only when the tool is available.
/// This process-local override neither changes collaboration mode nor writes the
/// user's CLI settings. Subscription and API launches must use the same default.
fn codex_session_config(model: Option<&str>) -> serde_json::Value {
    let mut config = serde_json::json!({ "tools": { "update_plan": { "enabled": true } } });
    if let Some(model) = model {
        config["model"] = serde_json::json!(model);
    }
    config
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
    /// Explicit user action; this may open the upstream browser login.
    Authenticate,
    /// Read-only snapshot, only supported on an authenticated subscription connection.
    RefreshQuota,
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
    /// Read-only listing of the workspace's archived Codex conversations.
    ListArchivedSessions {
        token: String,
    },
    /// Move an archived Codex conversation back into its active history. Sent
    /// only after the user confirmed; listing never changes upstream state.
    UnarchiveSession {
        token: String,
        session_id: String,
    },
    Prompt {
        session_id: String,
        text: String,
        #[serde(default)]
        files: Vec<PromptFile>,
    },
    /// Supplement the current logical turn. Results never end that turn.
    Steer {
        token: String,
        session_id: String,
        text: String,
        #[serde(default)]
        files: Vec<PromptFile>,
    },
    Cancel {
        session_id: String,
    },
    SetConfigOption {
        token: String,
        session_id: String,
        config_id: String,
        value: String,
    },
    Permission {
        request_id: String,
        option_id: Option<String>,
    },
    /// Processes of the agent tree the user chose to keep running.
    ///
    /// Once any process is preserved, stopping the connection ends only the
    /// agent process itself: the host has already ended the descendants it
    /// was not asked to keep, and a tree or group kill would also hit the
    /// preserved ones. Takes effect immediately on the calling thread.
    PreserveProcesses {
        process_ids: Vec<u32>,
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
    /// No local ChatGPT login is available. Opening a panel never starts browser login.
    AuthenticationRequired,
    Authenticating,
    /// Whitelisted upstream account identity; never contains credentials.
    Account {
        account: subscription::Account,
    },
    Quota {
        snapshot: subscription::QuotaSnapshot,
    },
    QuotaFailed {
        code: String,
    },
    /// Initialization and the selected authentication succeeded.
    Ready {
        agent_name: Option<String>,
        agent_version: Option<String>,
        can_load_sessions: bool,
        can_list_sessions: bool,
        /// Archived history is listed through the Agent's own CLI, not ACP.
        can_list_archived_sessions: bool,
        can_steer: bool,
    },
    /// Request-scoped delivery result, separate from prompt completion.
    SteeringResult {
        token: String,
        session_id: String,
        outcome: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    SessionCreated {
        token: String,
        session_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        config_options: Option<Vec<SessionConfigOption>>,
    },
    /// `session/load` returned. History replay arrives as `update` events and
    /// may continue after this event.
    SessionLoaded {
        token: String,
        session_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        config_options: Option<Vec<SessionConfigOption>>,
    },
    SessionConfigured {
        token: String,
        session_id: String,
        config_options: Vec<SessionConfigOption>,
    },
    TurnCancelling {
        session_id: String,
    },
    /// Advisory silence notice only; the prompt remains busy and is never replayed.
    TurnActivity {
        session_id: String,
        quiet: bool,
    },
    Sessions {
        token: String,
        sessions: Vec<AgentSessionSummary>,
    },
    /// `complete` is false when the page bound stopped the listing.
    ArchivedSessions {
        token: String,
        sessions: Vec<AgentSessionSummary>,
        complete: bool,
    },
    SessionUnarchived {
        token: String,
        session_id: String,
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
    /// The same busy turn is reconnecting, without implying another Host prompt.
    TurnRetrying {
        session_id: String,
        turn_id: String,
        attempt: u32,
        /// Only pre-work recovery has a Host attempt limit. Native recovery
        /// after work owns its budget and omits this field.
        #[serde(skip_serializing_if = "Option::is_none")]
        max_attempts: Option<u32>,
    },
    /// One provider request observed by the opt-in loopback proxy. `sessionId`
    /// is absent when no prompt, or more than one, was running at its start.
    ModelCall {
        #[serde(skip_serializing_if = "Option::is_none")]
        session_id: Option<String>,
        /// The causing turn already finished: the stream outlived the settle
        /// bound. Consumers count it for the session only, never a later turn.
        #[serde(skip_serializing_if = "std::ops::Not::not")]
        after_turn_finished: bool,
        call: model_calls::ModelCall,
    },
    /// The agent acknowledged the prompt's completion, including cancellation.
    TurnFinished {
        session_id: String,
        stop_reason: String,
        /// Optional counters reported by the agent, whose accounting scope is provider-owned.
        #[serde(skip_serializing_if = "Option::is_none")]
        usage: Option<agent_client_protocol::schema::v1::Usage>,
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
    /// Root turn used by cancellation and quiet-period accounting.
    session_id: String,
    /// Original ACP requester, retained to cancel only an ended child subtree.
    source_session_id: String,
    reply: oneshot::Sender<Option<String>>,
}

/// Permission requests awaiting a user decision, keyed by Lithe request id.
type PendingPermissions = Arc<Mutex<HashMap<String, PendingPermission>>>;

/// Running turn generation per session. A session is absent while idle, so a
/// response whose generation no longer matches belongs to a cancelled turn.
type RunningTurns = Arc<Mutex<HashMap<String, RunningTurn>>>;

/// Per-connection prompt state shared with the handle and the optional model
/// call proxy.
struct TurnActivity {
    permissions: PendingPermissions,
    turns: RunningTurns,
    /// Observed provider requests that must report before their turn finishes.
    calls_in_flight: Arc<model_proxy::CallsInFlight>,
}

struct RunningTurn {
    generation: u64,
    cancelling: bool,
    retry: tokio::sync::watch::Sender<prompt_retry::State>,
    steering: Arc<steering::Turn>,
}

enum Control {
    Command(AgentCommand),
    Stop,
}

/// Process IDs of the agent tree that stopping the connection must not end.
type PreservedProcesses = Arc<Mutex<Vec<u32>>>;

fn has_preserved_processes(preserved: &PreservedProcesses) -> bool {
    preserved.lock().map(|ids| !ids.is_empty()).unwrap_or(false)
}

/// One agent process and ACP connection. Dropping it stops the process tree.
pub struct AgentHandle {
    controls: async_mpsc::UnboundedSender<Control>,
    permissions: PendingPermissions,
    preserved: PreservedProcesses,
    child_pid: Arc<AtomicU32>,
    stop_requested: Arc<AtomicBool>,
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
        let stop_requested = Arc::new(AtomicBool::new(false));
        let preserved: PreservedProcesses = Arc::new(Mutex::new(Vec::new()));
        let pending = permissions.clone();
        let kept = preserved.clone();
        let pid = child_pid.clone();
        let stop = stop_requested.clone();
        let worker = std::thread::Builder::new()
            .name("lithe-acp-connection".into())
            .spawn(move || {
                let runtime = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build();
                let message = match runtime {
                    Ok(runtime) => runtime
                        .block_on(run_agent(
                            launch,
                            receiver,
                            AgentProcessState {
                                permissions: pending,
                                preserved: kept,
                                child_pid: pid,
                                stop_requested: stop,
                            },
                            emit.clone(),
                        ))
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
            preserved,
            child_pid,
            stop_requested,
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
            AgentCommand::PreserveProcesses { process_ids } => {
                let mut preserved = self
                    .preserved
                    .lock()
                    .map_err(|_| "Agent process state is unavailable".to_string())?;
                preserved.extend(process_ids);
                preserved.sort_unstable();
                preserved.dedup();
                Ok(())
            }
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
        self.stop_requested.store(true, Ordering::Release);
        let _ = self.controls.send(Control::Stop);
        if self.finished.recv_timeout(STOP_TIMEOUT).is_err() {
            let pid = self.child_pid.load(Ordering::SeqCst);
            if pid != 0 {
                if has_preserved_processes(&self.preserved) {
                    force_kill_process(pid);
                } else {
                    force_kill_tree(pid);
                }
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

/// The caller holds the ownership lock also used during permission registration,
/// so a terminal child cannot acquire a new pending request after this sweep.
fn reject_ended_subagent_permissions(
    permissions: &PendingPermissions,
    sessions: &subagents::Sessions,
) {
    if let Ok(mut pending) = permissions.lock() {
        let ids: Vec<_> = pending
            .iter()
            .filter(|(_, entry)| !sessions.is_live(&entry.source_session_id))
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

/// Child `PATH`: the executable's directory, then `base`. Package managers
/// such as npm install an agent script next to the `node` it runs with, and
/// `base` carries the login shell's `PATH`, which GUI apps do not inherit.
fn child_path(command: &Path, base: Option<OsString>) -> Option<OsString> {
    let mut paths: Vec<PathBuf> = command
        .parent()
        .filter(|dir| dir.is_absolute())
        .map(Path::to_path_buf)
        .into_iter()
        .collect();
    if let Some(base) = base {
        paths.extend(std::env::split_paths(&base));
    }
    (!paths.is_empty())
        .then(|| std::env::join_paths(paths).ok())
        .flatten()
}

/// State shared between an [`AgentHandle`] and its connection worker.
struct AgentProcessState {
    permissions: PendingPermissions,
    preserved: PreservedProcesses,
    child_pid: Arc<AtomicU32>,
    stop_requested: Arc<AtomicBool>,
}

async fn run_agent(
    launch: AgentLaunch,
    controls: async_mpsc::UnboundedReceiver<Control>,
    state: AgentProcessState,
    emit: Emit,
) -> Result<(), String> {
    let AgentProcessState {
        permissions,
        preserved,
        child_pid,
        stop_requested,
    } = state;
    let cancelled = || stop_requested.load(Ordering::Acquire);
    let observe_model_calls = launch.observe_model_calls;
    let observe_subagents = launch.observe_subagents;
    let process_scope = launch.process_scope.clone();
    let mut launch = resolve_with_cancel(launch, &cancelled)?;
    if cancelled() {
        return Err("Agent launch was cancelled".into());
    }
    let turns: RunningTurns = Arc::new(Mutex::new(HashMap::new()));
    let calls_in_flight = Arc::new(model_proxy::CallsInFlight::default());
    let observation_upstream = observe_model_calls
        .then(|| {
            launch
                .gateway
                .as_ref()
                .map(|route| route.base_url.clone())
                .or_else(|| {
                    launch
                        .subscription_cli
                        .as_ref()
                        .map(|_| subscription::INFERENCE_ORIGIN.to_owned())
                })
        })
        .flatten();
    let _model_calls = match observation_upstream {
        Some(upstream) => {
            let running = turns.clone();
            let session: model_proxy::SessionResolver =
                Arc::new(move || sole_running_session(&running));
            let calls = emit.clone();
            let sink: model_proxy::CallSink =
                Arc::new(move |session_id, after_turn_finished, call| {
                    calls(AgentEvent::ModelCall {
                        session_id,
                        after_turn_finished,
                        call,
                    })
                });
            // Statistics are optional. A proxy that cannot start leaves the
            // configured endpoint in place rather than blocking the Agent.
            match model_proxy::start(&upstream, session, sink, calls_in_flight.clone()).await {
                Ok(proxy) => {
                    let configured = if let Some(route) = launch.gateway.as_mut() {
                        route.base_url = proxy.base_url().to_owned();
                        true
                    } else {
                        subscription::observe_model_calls(&mut launch, proxy.base_url()).is_ok()
                    };
                    if configured {
                        Some(proxy)
                    } else {
                        eprintln!("Codex subscription statistics are unavailable");
                        None
                    }
                }
                Err(_) => {
                    eprintln!("Agent model-call statistics could not start");
                    None
                }
            }
        }
        None => None,
    };
    // Before the relay replaces CODEX_PATH: history uses the user's CLI directly.
    let history = codex_history::CodexHistory::for_launch(&launch);
    let native_recovery = launch
        .gateway
        .as_ref()
        .is_some_and(|route| route.native_recovery);
    let codex_executable = if native_recovery {
        Some(
            launch
                .env
                .iter()
                .find(|(name, _)| name == "CODEX_PATH")
                .map(|(_, value)| PathBuf::from(value))
                .ok_or("Codex executable is unavailable")?,
        )
    } else {
        launch.subscription_cli.clone()
    };
    let mut context_recovery = if codex_executable.is_some() {
        match codex_context::Recovery::start().await {
            Ok(recovery) => Some(Arc::new(recovery)),
            Err(_) => {
                eprintln!("Codex history context reporting is unavailable");
                None
            }
        }
    } else {
        None
    };
    let _relay = if let Some(executable) = codex_executable
        .filter(|_| native_recovery || context_recovery.is_some() || _model_calls.is_some())
    {
        match codex_retry::Relay::create(&executable, native_recovery) {
            Ok((relay, mut env)) => {
                if let Some(recovery) = &context_recovery {
                    env.push(("LITHE_CODEX_CONTEXT_URL".into(), recovery.url().into()));
                }
                if launch.subscription_cli.is_some() {
                    if let Some(proxy) = &_model_calls {
                        env.push((
                            "LITHE_CODEX_OBSERVATION_BASE".into(),
                            format!("{}/backend-api/codex", proxy.base_url()),
                        ));
                    }
                }
                launch.env.retain(|(name, _)| name != "CODEX_PATH");
                launch.env.extend(env);
                Some(relay)
            }
            Err(error) if native_recovery => return Err(error),
            Err(_) => {
                eprintln!("Could not prepare Codex history context reporting");
                context_recovery = None;
                // Without the native account-routing guard, retain direct
                // inference rather than bypassing managed residency rules.
                if launch.subscription_cli.is_some() {
                    if let Some((_, config)) = launch
                        .env
                        .iter_mut()
                        .find(|(name, _)| name == "CODEX_CONFIG")
                    {
                        let mut value: serde_json::Value = serde_json::from_str(config)
                            .map_err(|_| "Codex subscription configuration is unavailable")?;
                        value["openai_base_url"] = serde_json::json!("");
                        *config = value.to_string();
                    }
                }
                None
            }
        }
    } else {
        None
    };
    let mut command = std::process::Command::new(&launch.command);
    if launch
        .gateway
        .as_ref()
        .is_some_and(|route| route.protocol == ProviderProtocol::AnthropicMessages)
    {
        // An inherited model pin must not override the model restored by ACP.
        // Keep the user's alias mappings and other native CLI settings intact.
        command.env_remove("ANTHROPIC_MODEL");
        // An inherited executable can be an unusable Windows batch shim. The
        // launch environment below re-adds a valid path when one was resolved.
        command.env_remove("CLAUDE_CODE_EXECUTABLE");
    }
    if launch.subscription_cli.is_some() {
        subscription::isolate_environment(&mut command);
    }
    command
        .args(&launch.args)
        .current_dir(&launch.cwd)
        .envs(launch.env.iter().map(|(key, value)| (key, value)));
    let search_path =
        environment::search_path_with_cancel(&cancelled).or_else(|| std::env::var_os("PATH"));
    if cancelled() {
        return Err("Agent launch was cancelled".into());
    }
    if let Some(path) = child_path(&launch.command, search_path) {
        command.env("PATH", path);
    }
    if let Some(scope) = &process_scope {
        command.env(AGENT_SCOPE_ENVIRONMENT, scope);
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    let mut command = tokio::process::Command::from(command);
    #[cfg(windows)]
    {
        command.creation_flags(CREATE_NO_WINDOW);
    }
    command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    command.kill_on_drop(true);
    let mut child = command
        .spawn()
        .map_err(|error| format!("Could not start the Agent: {error}"))?;
    child_pid.store(child.id().unwrap_or(0), Ordering::SeqCst);
    if cancelled() {
        terminate_tree(&mut child).await;
        child_pid.store(0, Ordering::SeqCst);
        return Err("Agent launch was cancelled".into());
    }
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
    let subscription = launch.subscription_cli.is_some();
    let secret = launch.secret.clone();
    let transport = ByteStreams::new(stdin.compat_write(), stdout.compat());
    let result = run_connection(
        transport,
        launch.cwd,
        launch.gateway,
        launch.subscription_cli,
        history,
        context_recovery,
        observe_subagents,
        controls,
        TurnActivity {
            permissions,
            turns,
            calls_in_flight,
        },
        emit,
    )
    .await;
    // The connection may finish before the child exits. Never leave its process
    // tree running, including wrapper commands which launch another process,
    // unless the user chose to keep some of its tasks.
    if has_preserved_processes(&preserved) {
        terminate_process(&mut child).await;
    } else {
        terminate_tree(&mut child).await;
    }
    child_pid.store(0, Ordering::SeqCst);
    let _ = tokio::time::timeout(STOP_TIMEOUT, stderr_task).await;
    result.map_err(|message| {
        let message = redact(&message, &secret);
        // Subscription credentials belong to Codex, so Lithe has no secret to
        // redact. Do not surface arbitrary upstream stderr for this mode.
        if subscription {
            return message;
        }
        match tail.lock().ok().and_then(|tail| tail.summary(&secret)) {
            Some(stderr) => format!("{message}\n\nAgent output:\n{stderr}"),
            None => message,
        }
    })
}

/// Provider requests carry no ACP session id. Attribute a model call only
/// when exactly one non-cancelling prompt can have caused it.
fn sole_running_session(turns: &RunningTurns) -> Option<model_proxy::CallOwner> {
    let turns = turns.lock().ok()?;
    let mut active = turns.iter().filter(|(_, turn)| !turn.cancelling);
    match (active.next(), active.next()) {
        (Some((session_id, turn)), None) => Some(model_proxy::CallOwner {
            session: session_id.clone(),
            generation: turn.generation,
        }),
        _ => None,
    }
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

/// End only the agent process: the host already ended the descendants the user
/// did not keep, and signalling the tree or group would end the kept ones too.
async fn terminate_process(child: &mut tokio::process::Child) {
    #[cfg(unix)]
    if let Some(pid) = child.id().and_then(|pid| libc::pid_t::try_from(pid).ok()) {
        // SAFETY: `kill` only sends a signal to the direct child this
        // connection spawned and has not yet reaped.
        unsafe {
            libc::kill(pid, libc::SIGTERM);
        }
        if tokio::time::timeout(STOP_TIMEOUT, child.wait())
            .await
            .is_ok()
        {
            return;
        }
    }
    let _ = child.start_kill();
    let _ = tokio::time::timeout(STOP_TIMEOUT, child.wait()).await;
}

/// SIGKILL one process without touching its descendants or group.
///
/// Only hosts that send [`AgentCommand::PreserveProcesses`] reach this; the
/// Windows host does not, and `kill_on_drop` still ends the direct child there.
fn force_kill_process(process_id: u32) {
    #[cfg(unix)]
    if let Ok(pid) = libc::pid_t::try_from(process_id) {
        // SAFETY: `kill` only sends a signal to one process ID.
        unsafe {
            libc::kill(pid, libc::SIGKILL);
        }
    }
    #[cfg(not(unix))]
    let _ = process_id;
}

/// SIGKILL a process and its descendants; a process that already exited is ignored.
///
/// Children are started as process-group leaders, so on Unix the whole group is
/// killed as well: a descendant forked after the tree snapshot would otherwise
/// survive and keep the output pipes open.
fn force_kill_tree(process_id: u32) {
    let config = kill_tree::Config {
        signal: "SIGKILL".into(),
        include_target: true,
    };
    let _ = kill_tree::blocking::kill_tree_with_config(process_id, &config);
    #[cfg(unix)]
    if let Ok(group) = libc::pid_t::try_from(process_id) {
        if group > 1 {
            // SAFETY: `kill` only sends a signal; a negative id addresses the
            // group this process created with `process_group(0)`.
            unsafe {
                libc::kill(-group, libc::SIGKILL);
            }
        }
    }
}

async fn run_connection<OB, IB>(
    transport: ByteStreams<OB, IB>,
    cwd: PathBuf,
    gateway: Option<GatewaySignIn>,
    subscription_cli: Option<PathBuf>,
    history: Option<codex_history::CodexHistory>,
    context_recovery: Option<Arc<codex_context::Recovery>>,
    observe_subagents: bool,
    mut controls: async_mpsc::UnboundedReceiver<Control>,
    activity: TurnActivity,
    emit: Emit,
) -> Result<(), String>
where
    OB: futures::io::AsyncWrite + Send + 'static,
    IB: futures::io::AsyncRead + Send + 'static,
{
    let TurnActivity {
        permissions,
        turns,
        calls_in_flight,
    } = activity;
    let session_meta = session_routing::metadata(gateway.as_ref())?;
    let workspace = Arc::new(workspace_context::WorkspaceContext::new(&cwd)?);
    let update_workspace = workspace.clone();
    let restored_meta = session_routing::restored_metadata(gateway.as_ref())?;
    let (auth_tx, mut auth_rx) = tokio::sync::watch::channel(None::<subscription::AuthStatus>);
    let updates = emit.clone();
    let context_updates = context_recovery.clone();
    let update_turns = turns.clone();
    let subagent_sessions = Arc::new(Mutex::new(subagents::Sessions::default()));
    let update_subagents = subagent_sessions.clone();
    let permission_subagents = subagent_sessions.clone();
    let update_permissions = permissions.clone();
    let requests = emit.clone();
    let permission_turns = turns.clone();
    let cancel_permissions = permissions.clone();
    let stop_requested = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let stopped = stop_requested.clone();
    let finished_permissions = permissions.clone();
    let result = Client
        .builder()
        .on_receive_notification(
            async move |notification: subscription::AuthNotification, _| {
                auth_tx.send_replace(Some(notification.auth_status));
                Ok(())
            },
            agent_client_protocol::on_receive_notification!(),
        )
        .on_receive_notification(
            async move |notification: subagents::Notification, _| {
                if let Ok(update) = serde_json::to_value(notification.update) {
                    let session_id = notification.session_id.0.to_string();
                    if !observe_subagents && matches!(update["sessionUpdate"].as_str(), Some("subagent_spawned" | "subagent_state_update")) {
                        return Ok(());
                    }
                    let owner = {
                        let mut sessions = update_subagents.lock().map_err(|_| internal("Subagent ownership is unavailable"))?;
                        if !sessions.observe(&session_id, &update) {
                            return Err(internal("The Agent reported invalid subagent ownership"));
                        }
                        if update["sessionUpdate"] == "subagent_state_update" {
                            reject_ended_subagent_permissions(&update_permissions, &sessions);
                        }
                        sessions.is_live(&session_id).then(|| sessions.root(&session_id)).flatten()
                    };
                    let Some(update) = update_workspace.present_update(update) else {
                        return Ok(());
                    };
                    if update["sessionUpdate"] == "usage_update" {
                        if let Some(recovery) = &context_updates { recovery.prefer_upstream_report(&session_id); }
                    }
                    let mut reconnect = None;
                    if let Ok(turns) = update_turns.lock() {
                        if let Some(turn) = owner.as_ref().and_then(|id| turns.get(id)) {
                            if owner.as_deref() == Some(session_id.as_str()) { turn.steering.observe(&update); }
                            turn.retry.send_modify(|state| {
                                if prompt_retry::is_progress(&update) { state.progress(); }
                                // A child failure is the child's outcome, not a new
                                // failure or retry of the main Agent's model call.
                                if owner.as_deref() == Some(session_id.as_str()) {
                                    state.observe_failure(&update);
                                    reconnect = state.observe_native_retry(&update);
                                }
                            });
                        }
                    }
                    updates(AgentEvent::Update {
                        session_id: session_id.clone(),
                        update,
                    });
                    if let Some((turn_id, attempt, max_attempts)) = reconnect {
                        updates(AgentEvent::TurnRetrying { session_id, turn_id, attempt, max_attempts });
                    }
                }
                Ok(())
            },
            agent_client_protocol::on_receive_notification!(),
        )
        .on_receive_request(
            async move |request: RequestPermissionRequest, responder, connection| {
                let source_session_id = request.session_id.0.to_string();
                // Lock order is ownership -> pending requests -> running turns.
                // Keep ownership through registration so terminal notifications
                // cannot miss a requester checked just before it ended.
                let sessions = permission_subagents.lock().map_err(|_| internal("Subagent ownership is unavailable"))?;
                let session_id = sessions.is_live(&source_session_id).then(|| sessions.root(&source_session_id)).flatten();
                let Some(session_id) = session_id else {
                    return responder.respond(RequestPermissionResponse::new(RequestPermissionOutcome::Cancelled));
                };
                let request_id = uuid::Uuid::new_v4().to_string();
                let (reply, receiver) = oneshot::channel();
                // Register under the permission lock only while the turn is
                // still running, so a concurrent cancel cannot miss it.
                let activity = match permissions.lock() {
                    Ok(mut pending) => {
                        let running = permission_turns
                            .lock()
                            .ok()
                            .and_then(|turns| {
                                turns.get(&session_id)
                                    .filter(|turn| !turn.cancelling)
                                    .map(|turn| turn.retry.clone())
                            });
                        if let Some(activity) = &running {
                            activity.send_modify(|state| state.permission_started());
                            pending.insert(
                                request_id.clone(),
                                PendingPermission {
                                    session_id: session_id.clone(),
                                    source_session_id,
                                    reply,
                                },
                            );
                        }
                        running
                    }
                    Err(_) => None,
                };
                drop(sessions);
                let Some(activity) = activity else {
                    return responder.respond(RequestPermissionResponse::new(
                        RequestPermissionOutcome::Cancelled,
                    ));
                };
                if let Ok(value) = serde_json::to_value(&request) {
                    requests(AgentEvent::Permission {
                        session_id,
                        request_id: request_id.clone(),
                        request: value,
                    });
                }
                let permissions = permissions.clone();
                // The SDK dispatches callbacks in order. Move the user wait into
                // an SDK-owned task so updates, other permissions and EOF can flow.
                connection.spawn(async move {
                    // A user decision has no deadline. Cancellation, turn completion
                    // and connection shutdown all settle the owned pending request.
                    let selected = receiver.await.ok().flatten();
                    if let Ok(mut pending) = permissions.lock() {
                        pending.remove(&request_id);
                    }
                    activity.send_modify(|state| state.permission_finished());
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
                })?;
                Ok(())
            },
            agent_client_protocol::on_receive_request!(),
        )
        // Without this, an agent that exits leaves the command loop waiting
        // forever and the UI never learns the connection is gone.
        .on_close(async |_| Err(internal("The Agent exited")))
        .connect_with(transport, |connection: ConnectionTo<Agent>| async move {
            // The public failure extension keeps synthetic API errors
            // distinct from model output and carries their actionable titles.
            let claude_api_key = gateway.as_ref().is_some_and(|route| route.protocol == ProviderProtocol::AnthropicMessages);
            let typed_failures = claude_api_key || gateway.as_ref().is_some_and(|route| route.native_recovery);
            let mut air_capabilities = if typed_failures { vec!["recommendedValue", "sessionFailure"] } else { vec!["recommendedValue"] };
            if observe_subagents { air_capabilities.push("nativeSubagentSessions"); }
            let capabilities = ClientCapabilities::new()
                // Keep upstream advisories out of assistant transcript chunks.
                .session(ClientSessionCapabilities::new().notices(NoticeCapabilities::new()))
                .auth(AuthCapabilities::new().meta(serde_json::Map::from_iter([(
                    GATEWAY_AUTH_METHOD.to_owned(),
                    serde_json::Value::Bool(true),
                )])))
                .meta(serde_json::Map::from_iter([(
                    "jetbrains".to_owned(),
                    serde_json::json!({ "air": { "version": 1, "capabilities": air_capabilities } }),
                )]));
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
            // API-key routing is explicit and never falls back to account login.
            if let Some(gateway) = gateway.as_ref().filter(|route| route.protocol != ProviderProtocol::AnthropicMessages) {
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
                        .send_request(gateway_authentication(gateway))
                        .block_task(),
                )
                .await
                .map_err(|_| internal("The Agent did not finish API key sign-in in time"))??;
            }
            let account = if subscription_cli.is_some() {
                if !initialized.auth_methods.iter().any(|method| method.id().0.as_ref() == "chat-gpt") {
                    return Err(internal("This Codex adapter does not support ChatGPT sign-in"));
                }
                let Some(account) = subscription::authenticate(&connection, &mut auth_rx, &mut controls, &emit).await? else {
                    stopped.store(true, Ordering::SeqCst);
                    return Ok(());
                };
                emit(AgentEvent::Account { account: account.clone() });
                Some(account)
            } else { None };
            let can_steer = steering::supported(initialized.meta.as_ref());
            let tracks_detached_steering = initialized.agent_info.as_ref().is_some_and(
                |info| info.name == "@agentclientprotocol/codex-acp"
            );
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
                can_list_archived_sessions: history.is_some(),
                can_steer,
            });

            let quota_running = Arc::new(AtomicBool::new(false));
            let mut last_quota = None::<tokio::time::Instant>;
            let generations = AtomicU64::new(0);
            let mut native_sequences = HashMap::<String, Arc<AtomicU64>>::new();
            let mut tasks = JoinSet::new();
            let (cancel_deadline_tx, mut cancel_deadlines) = async_mpsc::unbounded_channel();
            let (steering_failure_tx, mut steering_failures) = async_mpsc::unbounded_channel::<String>();
            loop {
                let control = tokio::select! {
                    Some(message) = steering_failures.recv() => return Err(internal(&message)),
                    control = controls.recv() => match control {
                        Some(control) => control,
                        None => break,
                    },
                    changed = auth_rx.changed(), if account.is_some() => {
                        if changed.is_err() { return Err(internal("Codex account reporting stopped")); }
                        let status = auth_rx.borrow_and_update().clone();
                        if status.as_ref().is_none_or(|status| status.kind != "account" ||
                            status.account.as_ref().and_then(|a| a.email.as_ref()) != account.as_ref().and_then(|a| a.email.as_ref())) {
                            return Err(internal("The local Codex account changed. Reconnect to use the current account."));
                        }
                        continue;
                    }
                    deadline = cancel_deadlines.recv() => {
                        let Some((session_id, generation)) = deadline else { continue };
                        if turns.lock().is_ok_and(|turns| turns.get(&session_id).is_some_and(
                            |turn| turn.generation == generation && turn.cancelling
                        )) {
                            return Err(internal("The Agent did not acknowledge Stop. Its process has been stopped to prevent overlapping turns. Reconnect to reload the conversation."));
                        }
                        continue;
                    }
                };
                while tasks.try_join_next().is_some() {}
                let command = match control {
                    Control::Stop => {
                        stopped.store(true, Ordering::SeqCst);
                        break;
                    }
                    Control::Command(command) => command,
                };
                match command {
                    AgentCommand::Authenticate => {}
                    AgentCommand::RefreshQuota => {
                        let (Some(cli), Some(account)) = (&subscription_cli, &account) else { continue; };
                        if quota_running.load(Ordering::SeqCst) || last_quota.is_some_and(|time| time.elapsed() < subscription::QUOTA_INTERVAL) { continue; }
                        quota_running.store(true, Ordering::SeqCst);
                        last_quota = Some(tokio::time::Instant::now());
                        let (cli, cwd, account, emit, running) = (cli.clone(), cwd.clone(), account.clone(), emit.clone(), quota_running.clone());
                        tasks.spawn(async move {
                            let result = subscription::read_quota(&cli, &cwd, &account).await;
                            emit(match result {
                                Ok(snapshot) => AgentEvent::Quota { snapshot },
                                Err(code) => AgentEvent::QuotaFailed { code: code.into() },
                            });
                            running.store(false, Ordering::SeqCst);
                        });
                    }
                    AgentCommand::NewSession { token } => {
                        let subagents = subagent_sessions.clone();
                        let connection = connection.clone();
                        let emit = emit.clone();
                        let cwd = cwd.clone();
                        let session_meta = session_meta.clone();
                        tasks.spawn(async move {
                            let mut request = agent_client_protocol::schema::v1::NewSessionRequest::new(cwd);
                            request.meta = session_meta;
                            let result = request_with_timeout(
                                SESSION_REQUEST_TIMEOUT,
                                session_defaults::new_session(&connection, request),
                            )
                            .await;
                            emit(match result {
                                Ok(response) => match subagents.lock() {
                                    Ok(mut sessions) => {
                                        sessions.note_root(response.session_id.0.as_ref());
                                        AgentEvent::SessionCreated {
                                            token,
                                            session_id: response.session_id.0.to_string(),
                                            config_options: response.config_options,
                                        }
                                    }
                                    Err(_) => failed(Some(token), None, "Subagent ownership is unavailable".into()),
                                },
                                Err(message) => failed(Some(token), None, message),
                            });
                        });
                    }
                    AgentCommand::LoadSession { token, session_id } => {
                        {
                            let mut sessions = subagent_sessions.lock().map_err(|_| internal("Subagent ownership is unavailable"))?;
                            sessions.note_root(&session_id);
                            sessions.clear(&session_id);
                        }
                        let connection = connection.clone();
                        let emit = emit.clone();
                        let cwd = cwd.clone();
                        let session_meta = restored_meta.clone();
                        let confirm_model = session_meta.is_some();
                        let capture = context_recovery.as_ref().and_then(|recovery| recovery.capture(&session_id));
                        tasks.spawn(async move {
                            let mut request = LoadSessionRequest::new(session_id.clone(), cwd);
                            request.meta = session_meta;
                            let result = request_with_timeout(
                                LOAD_SESSION_TIMEOUT,
                                session_restore::load_session(&connection, request, confirm_model),
                            )
                            .await;
                            if result.is_ok() {
                                if let Some(capture) = capture {
                                    if let Some(update) = capture.finish().await {
                                        emit(AgentEvent::Update { session_id: session_id.clone(), update });
                                    }
                                }
                            }
                            emit(match result {
                                Ok(response) => AgentEvent::SessionLoaded { token, session_id, config_options: response.config_options },
                                Err(message) => failed(Some(token), Some(session_id), message),
                            });
                        });
                    }
                    AgentCommand::ListSessions { token } => {
                        let connection = connection.clone();
                        let emit = emit.clone();
                        let cwd = cwd.clone();
                        let workspace = workspace.clone();
                        tasks.spawn(async move {
                            emit(match list_sessions(&connection, cwd, &workspace).await {
                                Ok(sessions) => AgentEvent::Sessions { token, sessions },
                                Err(message) => failed(Some(token), None, message),
                            });
                        });
                    }
                    AgentCommand::ListArchivedSessions { token } => {
                        let Some(history) = history.clone() else {
                            emit(failed(Some(token), None, "This Agent has no archived history".into()));
                            continue;
                        };
                        let emit = emit.clone();
                        let workspace = workspace.clone();
                        tasks.spawn(async move {
                            emit(match history.list_archived(&workspace).await {
                                Ok(archived) => AgentEvent::ArchivedSessions { token, sessions: archived.sessions, complete: archived.complete },
                                Err(message) => failed(Some(token), None, message),
                            });
                        });
                    }
                    AgentCommand::UnarchiveSession { token, session_id } => {
                        let Some(history) = history.clone() else {
                            emit(failed(Some(token), Some(session_id), "This Agent has no archived history".into()));
                            continue;
                        };
                        let emit = emit.clone();
                        tasks.spawn(async move {
                            emit(match history.unarchive(session_id.clone()).await {
                                Ok(()) => AgentEvent::SessionUnarchived { token, session_id },
                                Err(message) => failed(Some(token), Some(session_id), message),
                            });
                        });
                    }
                    AgentCommand::SetConfigOption { token, session_id, config_id, value } => {
                        if turns.lock().is_ok_and(|turns| turns.contains_key(&session_id)) {
                            emit(failed(Some(token), Some(session_id), "Wait for the current turn before changing configuration".into()));
                            continue;
                        }
                        let connection = connection.clone();
                        let emit = emit.clone();
                        tasks.spawn(async move {
                            let result = request_with_timeout(
                                SESSION_REQUEST_TIMEOUT,
                                connection.send_request(SetSessionConfigOptionRequest::new(session_id.clone(), config_id, value.as_str())).block_task(),
                            ).await;
                            emit(match result {
                                Ok(response) => AgentEvent::SessionConfigured { token, session_id, config_options: response.config_options },
                                Err(message) => failed(Some(token), Some(session_id), message),
                            });
                        });
                    }
                    AgentCommand::Steer { token, session_id, text, files } => {
                        let reject = |message: &str| emit(AgentEvent::SteeringResult {
                            token: token.clone(), session_id: session_id.clone(),
                            outcome: "failed".into(), message: Some(message.into()),
                        });
                        if !can_steer { reject("This Agent does not support messages while responding"); continue; }
                        let content = match workspace.content(text, files) {
                            Ok(content) => content,
                            Err(message) => { reject(&message); continue; }
                        };
                        let reservation = turns.lock().ok().and_then(|turns| {
                            turns.get(&session_id).map(|turn| {
                                if turn.cancelling { return None; }
                                turn.steering.begin().map(|idle| (turn.steering.clone(), idle, turn.retry.clone()))
                            })
                        });
                        let Some(reservation) = reservation else {
                            emit(AgentEvent::SteeringResult { token, session_id, outcome: "promptRequired".into(), message: None });
                            continue;
                        };
                        let Some((progress, continuation_idle, retry)) = reservation else {
                            reject("Wait for the pending message or Stop acknowledgement"); continue;
                        };
                        if matches!(content.first(), Some(ContentBlock::Text(text)) if text.text.trim_start().starts_with('/')) {
                            // Codex ACP 1.13.1 also reports startedNewTurn for a
                            // completed command that never starts a model turn.
                            // Leave commands unconsumed so the client submits
                            // them after this turn, with an owned prompt response.
                            emit(AgentEvent::SteeringResult { token, session_id, outcome: "promptRequired".into(), message: None });
                            progress.finish(None);
                            continue;
                        }
                        let (connection, emit, fatal) = (connection.clone(), emit.clone(), steering_failure_tx.clone());
                        tasks.spawn(async move {
                            let result = tokio::time::timeout(SESSION_REQUEST_TIMEOUT,
                                connection.send_request(steering::request(&session_id, content)).block_task()).await;
                            let mut detached = false;
                            let (outcome, message) = match result {
                                Ok(Ok(response)) => {
                                    match response.outcome.as_str() {
                                        "injected" => ("injected", None),
                                        "startedNewTurn" if tracks_detached_steering => { detached = true; ("injected", None) },
                                        "startedNewTurn" => {
                                            let _ = fatal.send("This Agent started an untracked continuation. Reconnect and check the conversation before retrying.".into());
                                            return;
                                        },
                                        "promptRequired" => ("promptRequired", None),
                                        _ => ("failed", Some("The Agent did not accept the supplementary message".into())),
                                    }
                                },
                                Ok(Err(error)) => ("failed", Some(prompt_retry::error_message(&error))),
                                Err(_) => {
                                    // A timed-out extension might still consume the input.
                                    // Stop the connection rather than retrying it blindly.
                                    let _ = fatal.send("The Agent did not confirm the supplementary message. Reconnect and check the conversation before retrying.".into());
                                    return;
                                }
                            };
                            if detached && retry.borrow().cancelling {
                                let _ = connection.send_notification(CancelNotification::new(session_id.clone()));
                            }
                            emit(AgentEvent::SteeringResult { token, session_id, outcome: outcome.into(), message });
                            // Publish delivery before releasing the terminal-event barrier.
                            progress.finish(detached.then_some(continuation_idle));
                        });
                    }
                    AgentCommand::Prompt { session_id, text, files } => {
                        let content = match workspace.content(text, files) {
                            Ok(content) => content,
                            Err(message) => {
                                emit(failed(None, Some(session_id), message));
                                continue;
                            }
                        };
                        let generation = generations.fetch_add(1, Ordering::SeqCst) + 1;
                        let retry_enabled = gateway.as_ref().is_some_and(|route| route.protocol == ProviderProtocol::AnthropicMessages);
                        let native_recovery = gateway.as_ref().is_some_and(|route| route.native_recovery);
                        let retry_state = if native_recovery {
                            let sequence = native_sequences.entry(session_id.clone()).or_insert_with(|| Arc::new(AtomicU64::new(0))).clone();
                            prompt_retry::State::native(sequence)
                        } else { prompt_retry::State::new(retry_enabled) };
                        let (retry, retry_changes) = tokio::sync::watch::channel(retry_state);
                        let steering = Arc::new(steering::Turn::default());
                        let busy = match turns.lock() {
                            Ok(mut turns) if !turns.contains_key(&session_id) => {
                                turns.insert(session_id.clone(), RunningTurn { generation, cancelling: false, retry: retry.clone(), steering: steering.clone() });
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
                        let request = PromptRequest::new(session_id.clone(), content);
                        let connection = connection.clone();
                        let prompt_response = prompt_retry::run(connection.clone(), request, retry.clone(), retry_changes.clone(), uuid::Uuid::new_v4().to_string(), emit.clone());
                        let mut response = Box::pin(async move {
                            let response = prompt_response.await;
                            let continued = steering.settled().await.map_err(|message| internal(&message))?;
                            if continued {
                                // A detached continuation has no ACP usage response;
                                // its native terminal state supersedes the original
                                // response (which may have failed before steering).
                                Ok(agent_client_protocol::schema::v1::PromptResponse::new(
                                    agent_client_protocol::schema::v1::StopReason::EndTurn,
                                ))
                            } else {
                                response
                            }
                        });
                        let emit = emit.clone();
                        let turns = turns.clone();
                        let prompt_permissions = cancel_permissions.clone();
                        let cancel_deadline = cancel_deadline_tx.clone();
                        let calls_in_flight = calls_in_flight.clone();
                        tasks.spawn(async move {
                            let result = prompt_retry::wait(response.as_mut(), retry_changes, |quiet| {
                                emit(AgentEvent::TurnActivity { session_id: session_id.clone(), quiet });
                            }).await;
                            if result.is_err() {
                                let timeout_message = retry.borrow().timeout_message();
                                // Cancel an expired recovery budget, but keep the turn
                                // registered until the agent acknowledges it to prevent a
                                // late response from overlapping a new prompt.
                                let current = turns.lock().is_ok_and(|mut turns| {
                                    let Some(turn) = turns.get_mut(&session_id) else {
                                        return false;
                                    };
                                    if turn.generation != generation {
                                        return false;
                                    }
                                    turn.cancelling = true;
                                    turn.retry.send_modify(|state| state.cancelling = true);
                                    true
                                });
                                if !current {
                                    return;
                                }
                                reject_pending_permissions(&prompt_permissions, Some(&session_id));
                                let _ = connection
                                    .send_notification(CancelNotification::new(session_id.clone()));
                                emit(AgentEvent::TurnCancelling {
                                    session_id: session_id.clone(),
                                });

                                // A terminal failure also releases the UI's busy state, so
                                // report it only after cancellation has settled. Even a
                                // late successful response cannot erase the timeout error.
                                match tokio::time::timeout(CANCEL_TIMEOUT, response.as_mut()).await {
                                    Ok(_) => {
                                        let current = turns.lock().is_ok_and(|mut turns| {
                                            let current = turns.get(&session_id).is_some_and(
                                                |turn| turn.generation == generation,
                                            );
                                            if current {
                                                turns.remove(&session_id);
                                            }
                                            current
                                        });
                                        if current {
                                            reject_pending_permissions(
                                                &prompt_permissions,
                                                Some(&session_id),
                                            );
                                            calls_in_flight.finish_turn(&session_id, generation);
                                            emit(failed(
                                                None,
                                                Some(session_id),
                                                timeout_message,
                                            ));
                                        }
                                    }
                                    Err(_) => {
                                        // Keep the turn registered so the outer loop stops the
                                        // connection instead of allowing a stale request to
                                        // overlap.
                                        calls_in_flight.finish_turn(&session_id, generation);
                                        emit(failed(
                                            None,
                                            Some(session_id.clone()),
                                            timeout_message,
                                        ));
                                        let _ = cancel_deadline.send((session_id, generation));
                                    }
                                }
                                return;
                            }

                            let current = turns.lock().is_ok_and(|mut turns| {
                                let current = turns
                                    .get(&session_id)
                                    .is_some_and(|turn| turn.generation == generation);
                                if current {
                                    turns.remove(&session_id);
                                }
                                current
                            });
                            if !current {
                                return;
                            }
                            reject_pending_permissions(&prompt_permissions, Some(&session_id));
                            // The proxy reports a call when its response stream
                            // ends, which can trail the prompt response.
                            calls_in_flight.settle(&session_id, MODEL_CALL_SETTLE_TIMEOUT).await;
                            calls_in_flight.finish_turn(&session_id, generation);
                            emit(match result {
                                Ok(Ok(mut response)) => {
                                    if retry.borrow().cancelling {
                                        response.stop_reason = agent_client_protocol::schema::v1::StopReason::Cancelled;
                                    }
                                    prompt::finished(session_id, response)
                                },
                                Ok(Err(error)) => failed(None, Some(session_id), prompt_retry::error_message(&error)),
                                Err(_) => unreachable!("recovery deadline handled above"),
                            });
                        });
                    }
                    AgentCommand::Cancel { session_id } => {
                        let generation = turns
                            .lock()
                            .ok()
                            .and_then(|mut turns| {
                                let turn = turns.get_mut(&session_id)?;
                                if turn.cancelling { return None; }
                                turn.cancelling = true;
                                turn.retry.send_modify(|state| state.cancelling = true);
                                Some(turn.generation)
                            });
                        // A request registered after the caller's rejection but before
                        // this point would otherwise remain pending after cancellation.
                        reject_pending_permissions(&cancel_permissions, Some(&session_id));
                        if let Some(generation) = generation {
                            let _ = connection
                                .send_notification(CancelNotification::new(session_id.clone()));
                            emit(AgentEvent::TurnCancelling {
                                session_id: session_id.clone(),
                            });
                            let deadline = cancel_deadline_tx.clone();
                            tasks.spawn(async move {
                                tokio::time::sleep(CANCEL_TIMEOUT).await;
                                let _ = deadline.send((session_id, generation));
                            });
                        }
                    }
                    AgentCommand::Permission { .. } | AgentCommand::PreserveProcesses { .. } => {}
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
            while tasks.join_next().await.is_some() {}
            Ok(())
        })
        .await
        .map_err(|error| error.to_string());
    // EOF and protocol failures also revoke approvals owned by this connection.
    reject_pending_permissions(&finished_permissions, None);
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

fn gateway_authentication(gateway: &GatewaySignIn) -> AuthenticateRequest {
    let headers: serde_json::Map<String, serde_json::Value> = gateway
        .headers
        .iter()
        .map(|(name, value)| (name.clone(), serde_json::Value::String(value.clone())))
        .collect();
    let mut settings = serde_json::json!({ "baseUrl": gateway.base_url, "headers": headers });
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
    workspace: &workspace_context::WorkspaceContext,
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
        sessions.extend(page.sessions.into_iter().map(|session| {
            AgentSessionSummary {
                session_id: session.session_id.0.to_string(),
                title: session
                    .title
                    .and_then(|title| workspace.present_title(&title)),
                updated_at: session.updated_at,
            }
        }));
        match page.next_cursor {
            Some(next) if !next.is_empty() => cursor = Some(next),
            _ => return Ok(sessions),
        }
    }
    Ok(sessions)
}

#[cfg(test)]
mod tests;
