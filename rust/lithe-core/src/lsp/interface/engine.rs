//! Stateful language-server sessions coordinating client state and child processes.

use super::process::{LspProcessHandle, LspProcessLauncher, LspProcessSpec, SystemProcessLauncher};
use super::{
    client_apply_server_message, client_change_document, client_close_document,
    client_feature_request_canonical, client_initialize, client_open_document, client_shutdown,
    frame_message, parse_server_messages, ClientApplyServerMessageRequest,
    ClientChangeDocumentRequest, ClientCloseDocumentRequest, ClientFeatureRequest,
    ClientInitializeRequest, ClientOpenDocumentRequest, ClientShutdownRequest, FrameMessageRequest,
    LspClientDiagnostic, LspClientDocument, LspClientState, LspDocumentContentChange, LspPosition,
    LspRange, ParseServerMessagesRequest,
};
use crate::lsp::languages::jdt::{
    adapt_start, initialized_notification, virtual_source_content, virtual_source_resolve_params,
    workspace_configuration, JdtStartContext, WorkspaceConfigurationItem,
};
use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, VecDeque};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

const DEFAULT_INITIALIZE_TIMEOUT_MS: u64 = 10_000;
const DEFAULT_REQUEST_TIMEOUT_MS: u64 = 30_000;
const DEFAULT_SHUTDOWN_TIMEOUT_MS: u64 = 2_000;
const MONITOR_INTERVAL_MS: u64 = 10;

static ENGINE: OnceLock<LspEngine> = OnceLock::new();

#[derive(Debug, Clone, Copy, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
/// Observable lifecycle of one managed language-server session.
pub enum LspLifecycleState {
    /// Session state exists, but the child process has not started.
    Created,
    /// The child process and its standard streams are being created.
    ProcessStarting,
    /// The process is running and the initialize handshake is pending.
    Initializing,
    /// Initialization completed and semantic requests may be sent.
    Ready,
    /// A graceful shutdown is pending or the process is being terminated.
    Stopping,
    /// The session ended normally and will produce no further events.
    Stopped,
    /// Startup, protocol handling, or the child process failed terminally.
    Failed,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// Validated process, workspace, initialization, and timeout settings for a server.
pub struct StartServerRequest {
    pub provider_id: String,
    pub executable_path: String,
    #[serde(default)]
    pub arguments: Vec<String>,
    #[serde(default)]
    pub environment: BTreeMap<String, String>,
    pub root_uri: String,
    pub working_directory: String,
    #[serde(default)]
    pub initialization_options: Option<Value>,
    #[serde(default)]
    pub runtime_executable_path: Option<String>,
    #[serde(default)]
    pub cache_directory: Option<String>,
    #[serde(default = "default_initialize_timeout")]
    pub initialize_timeout_milliseconds: u64,
    #[serde(default = "default_request_timeout")]
    pub request_timeout_milliseconds: u64,
    #[serde(default = "default_shutdown_timeout")]
    pub shutdown_timeout_milliseconds: u64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Identity and initial lifecycle state of a newly created session.
pub struct StartServerResponse {
    pub session_id: String,
    pub state: LspLifecycleState,
    pub process_id: Option<u32>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// Request targeting one existing server session.
pub struct SessionRequest {
    pub session_id: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// Complete document contents or incremental edits to open or update in a session.
pub struct SyncDocumentRequest {
    pub session_id: String,
    pub uri: String,
    pub language_id: String,
    /// Full document text. Required for `didOpen`; optional for incremental `didChange`.
    #[serde(default)]
    pub text: String,
    /// Range-based edits used when the server advertised Incremental `textDocumentSync`.
    #[serde(default)]
    pub content_changes: Vec<LspDocumentContentChange>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// Request to remove a document from a session's synchronized state.
pub struct CloseDocumentRequest {
    pub session_id: String,
    pub uri: String,
}

#[derive(Debug, Clone, Copy, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
/// Semantic operation normalized across provider-specific LSP capabilities.
pub enum LspSemanticOperation {
    /// `textDocument/completion`.
    Completion,
    /// `textDocument/hover`.
    Hover,
    /// `textDocument/definition`.
    Definition,
    /// `textDocument/declaration`.
    Declaration,
    /// `textDocument/typeDefinition`.
    TypeDefinition,
    /// `textDocument/references`.
    References,
    /// `textDocument/implementation`.
    Implementation,
    /// `textDocument/rename`.
    Rename,
    /// `textDocument/formatting`.
    Formatting,
    /// `textDocument/codeAction`.
    CodeActions,
    /// `completionItem/resolve` for a previously returned completion item.
    ResolveCompletion,
    /// `codeAction/resolve` for a previously returned action.
    ResolveCodeAction,
    /// `workspace/executeCommand` using a server-provided command payload.
    ExecuteCommand,
    /// `textDocument/inlayHint`.
    InlayHints,
    /// `textDocument/foldingRange`.
    FoldingRanges,
    /// `textDocument/codeLens`.
    CodeLens,
    /// Provider-specific retrieval of a read-only virtual document.
    VirtualDocument,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// Inputs for one asynchronous semantic language-server operation.
pub struct SemanticRequest {
    pub session_id: String,
    #[serde(default)]
    pub operation_id: Option<String>,
    pub operation: LspSemanticOperation,
    #[serde(default)]
    pub uri: Option<String>,
    #[serde(default)]
    pub virtual_uri: Option<String>,
    #[serde(default)]
    pub position: Option<LspPosition>,
    #[serde(default)]
    pub new_name: Option<String>,
    #[serde(default)]
    pub range: Option<LspRange>,
    #[serde(default)]
    pub diagnostics: Vec<LspClientDiagnostic>,
    #[serde(default)]
    pub completion_item: Option<Value>,
    #[serde(default)]
    pub code_action: Option<Value>,
    #[serde(default)]
    pub command: Option<Value>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Correlation identifier used to receive or cancel an asynchronous result.
pub struct OperationResponse {
    pub operation_id: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// Request to cancel a pending operation in one session.
pub struct CancelOperationRequest {
    pub session_id: String,
    pub operation_id: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Ordered events drained from a session since the previous poll.
pub struct PollEventsResponse {
    pub events: Vec<LspRuntimeEvent>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// Request that waits until queued events exist or the timeout elapses.
pub struct WaitEventsRequest {
    pub session_id: String,
    /// Upper bound for blocking on the session event channel, in milliseconds.
    #[serde(default = "default_wait_events_timeout")]
    pub timeout_milliseconds: u64,
}

fn default_wait_events_timeout() -> u64 {
    30_000
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Sequenced lifecycle, diagnostic, result, or log event from a server session.
pub struct LspRuntimeEvent {
    /// Event discriminator such as `stateChanged`, `requestCompleted`, or `diagnostics`.
    #[serde(rename = "type")]
    pub kind: String,
    pub sequence: u64,
    pub provider_id: String,
    pub session_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub state: Option<LspLifecycleState>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub operation_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub method: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub uri: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub diagnostics: Option<Vec<LspClientDiagnostic>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<LspRuntimeError>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub capabilities: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub server_info: Option<LspServerInfo>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub level: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Server identity reported by the LSP initialize response.
pub struct LspServerInfo {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Structured runtime failure with session and protocol-stage context.
pub struct LspRuntimeError {
    pub code: String,
    pub provider_id: String,
    pub session_id: String,
    /// Lifecycle or protocol phase in which the error occurred.
    pub stage: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub method: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub document_uri: Option<String>,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub underlying_message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub process_exit_code: Option<i32>,
}

#[cfg(test)]
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineSnapshot {
    pub session_id: String,
    pub provider_id: String,
    /// The workspace this session serves. Replacing a workspace means stopping
    /// the session bound to the old root, so callers need to be able to tell
    /// which root a session belongs to.
    pub root_uri: String,
    pub state: LspLifecycleState,
    pub initialized: bool,
    pub open_documents: BTreeMap<String, LspClientDocument>,
    pub pending_operation_ids: Vec<String>,
    pub diagnostic_versions: BTreeMap<String, i64>,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
/// Response handling path required by one pending JSON-RPC request.
enum PendingKind {
    /// Initial handshake whose result transitions the session to ready.
    Initialize,
    /// Ordinary semantic feature whose result becomes an operation event.
    Feature,
    /// Provider-specific source retrieval normalized as a virtual document.
    VirtualDocument,
    /// Shutdown handshake after which the engine sends `exit`.
    Shutdown,
}

#[derive(Debug, Clone)]
struct PendingRequest {
    kind: PendingKind,
    operation_id: Option<String>,
    method: String,
    document_uri: Option<String>,
    created_at: Instant,
    deadline: Instant,
}

struct SessionState {
    lifecycle: LspLifecycleState,
    client: LspClientState,
    pending: BTreeMap<String, PendingRequest>,
    request_by_operation: BTreeMap<String, String>,
    events: VecDeque<LspRuntimeEvent>,
    next_sequence: u64,
    initialize_deadline: Option<Instant>,
    shutdown_deadline: Option<Instant>,
    request_timeout: Duration,
    shutdown_timeout: Duration,
    terminal_event_emitted: bool,
}

struct RuntimeSession {
    id: String,
    provider_id: String,
    #[cfg(test)]
    root_uri: String,
    state: Mutex<SessionState>,
    event_signal: Condvar,
    process: Arc<dyn LspProcessHandle>,
    active: AtomicBool,
}

/// The engine is a process-owning singleton in production, but it holds no
/// global state of its own beyond the session registry, so tests construct
/// private instances with a scripted launcher.
pub(super) struct LspEngine {
    next_session_id: AtomicU64,
    next_operation_id: AtomicU64,
    sessions: Mutex<BTreeMap<String, Arc<RuntimeSession>>>,
    launcher: Arc<dyn LspProcessLauncher>,
}

fn default_initialize_timeout() -> u64 {
    DEFAULT_INITIALIZE_TIMEOUT_MS
}

fn default_request_timeout() -> u64 {
    DEFAULT_REQUEST_TIMEOUT_MS
}

fn default_shutdown_timeout() -> u64 {
    DEFAULT_SHUTDOWN_TIMEOUT_MS
}

/// Starts a managed language-server process and begins LSP initialization.
pub fn start_server(request: StartServerRequest) -> Result<StartServerResponse, CoreError> {
    engine().start_server(request)
}

/// Performs a bounded graceful shutdown while retaining the session record.
pub fn stop_server(request: SessionRequest) -> Result<(), CoreError> {
    engine().session(&request.session_id)?.stop()
}

/// Opens or replaces the synchronized contents of one document.
pub fn sync_document(request: SyncDocumentRequest) -> Result<(), CoreError> {
    engine()
        .session(&request.session_id)?
        .sync_document(request)
}

/// Notifies the server that a synchronized document has closed.
pub fn close_document(request: CloseDocumentRequest) -> Result<(), CoreError> {
    engine()
        .session(&request.session_id)?
        .close_document(&request.uri)
}

/// Queues a semantic request and returns its operation identifier immediately.
pub fn semantic_request(request: SemanticRequest) -> Result<OperationResponse, CoreError> {
    let operation_id = request
        .operation_id
        .clone()
        .unwrap_or_else(|| engine().next_operation_id());
    engine()
        .session(&request.session_id)?
        .request(request, operation_id.clone())?;
    Ok(OperationResponse { operation_id })
}

/// Cancels a pending semantic request in both client state and the server.
pub fn cancel_operation(request: CancelOperationRequest) -> Result<(), CoreError> {
    engine()
        .session(&request.session_id)?
        .cancel_operation(&request.operation_id)
}

/// Drains all currently queued events in deterministic sequence order.
pub fn poll_events(request: SessionRequest) -> Result<PollEventsResponse, CoreError> {
    Ok(PollEventsResponse {
        events: engine().session(&request.session_id)?.poll_events()?,
    })
}

/// Waits until queued events exist or the supplied timeout elapses.
pub fn wait_events(request: WaitEventsRequest) -> Result<PollEventsResponse, CoreError> {
    Ok(PollEventsResponse {
        events: engine()
            .session(&request.session_id)?
            .wait_events(Duration::from_millis(request.timeout_milliseconds))?,
    })
}

/// Stops a session if necessary and removes all state owned by it.
pub fn destroy_server(request: SessionRequest) -> Result<(), CoreError> {
    engine().destroy(&request.session_id)
}

fn engine() -> &'static LspEngine {
    ENGINE.get_or_init(LspEngine::new)
}

impl LspEngine {
    fn new() -> Self {
        Self::with_launcher(Arc::new(SystemProcessLauncher))
    }

    fn with_launcher(launcher: Arc<dyn LspProcessLauncher>) -> Self {
        Self {
            next_session_id: AtomicU64::new(1),
            next_operation_id: AtomicU64::new(1),
            sessions: Mutex::new(BTreeMap::new()),
            launcher,
        }
    }

    fn next_operation_id(&self) -> String {
        format!(
            "lsp-operation-{}",
            self.next_operation_id.fetch_add(1, Ordering::Relaxed)
        )
    }

    fn start_server(&self, request: StartServerRequest) -> Result<StartServerResponse, CoreError> {
        validate_start_request(&request)?;
        let session_id = format!(
            "lsp-session-{}",
            self.next_session_id.fetch_add(1, Ordering::Relaxed)
        );
        let workspace_root = PathBuf::from(&request.working_directory);
        let data_root = request
            .cache_directory
            .as_deref()
            .map(PathBuf::from)
            .unwrap_or_else(|| std::env::temp_dir().join("lithe-lsp"));
        let selected_java_executable = request
            .runtime_executable_path
            .as_deref()
            .map(PathBuf::from)
            .or_else(|| java_executable_from_environment(&request.environment));
        let adaptation = adapt_start(&JdtStartContext {
            provider_id: request.provider_id.clone(),
            workspace_root: workspace_root.clone(),
            data_root,
            selected_java_executable,
            arguments: request.arguments.clone(),
        });
        if let Some(directory) = &adaptation.data_directory {
            std::fs::create_dir_all(directory).map_err(|error| {
                CoreError::new(
                    ErrorCode::ProcessStartFailed,
                    "Could not create the language-server state directory.",
                )
                .with_details(error.to_string())
            })?;
        }

        let process = self.launcher.launch(LspProcessSpec {
            executable: PathBuf::from(&request.executable_path),
            arguments: adaptation.arguments,
            working_directory: workspace_root,
            environment: request.environment,
        })?;

        let initialize_timeout = Duration::from_millis(request.initialize_timeout_milliseconds);
        let request_timeout = Duration::from_millis(request.request_timeout_milliseconds);
        let shutdown_timeout = Duration::from_millis(request.shutdown_timeout_milliseconds);
        let initialize = client_initialize(ClientInitializeRequest {
            state: LspClientState::default(),
            root_uri: request.root_uri.clone(),
            process_id: Some(std::process::id() as i64),
            initialization_options: request.initialization_options,
        })?;
        let request_id = (initialize.state.next_request_id - 1).to_string();
        let now = Instant::now();
        let process_id = process.handle.process_id();
        let session = Arc::new(RuntimeSession {
            id: session_id.clone(),
            provider_id: request.provider_id,
            #[cfg(test)]
            root_uri: request.root_uri,
            state: Mutex::new(SessionState {
                lifecycle: LspLifecycleState::Created,
                client: initialize.state,
                pending: BTreeMap::from([(
                    request_id,
                    PendingRequest {
                        kind: PendingKind::Initialize,
                        operation_id: None,
                        method: "initialize".to_string(),
                        document_uri: None,
                        created_at: now,
                        deadline: now + initialize_timeout,
                    },
                )]),
                request_by_operation: BTreeMap::new(),
                events: VecDeque::new(),
                next_sequence: 1,
                initialize_deadline: Some(now + initialize_timeout),
                shutdown_deadline: None,
                request_timeout,
                shutdown_timeout,
                terminal_event_emitted: false,
            }),
            event_signal: Condvar::new(),
            process: process.handle,
            active: AtomicBool::new(true),
        });
        session.transition(LspLifecycleState::Created, None)?;
        session.transition(LspLifecycleState::ProcessStarting, None)?;
        session.transition(LspLifecycleState::Initializing, None)?;

        self.lock_sessions()?
            .insert(session_id.clone(), session.clone());
        session.spawn_readers(process.output, process.errors);
        session.spawn_monitor();
        if let Err(error) = session.send_messages(initialize.messages) {
            session.fail(
                "transportFailed",
                "initialize",
                "Could not write the initialize request.",
                Some(core_error_detail(&error)),
                None,
            );
            session.kill_process();
            return Err(error);
        }

        Ok(StartServerResponse {
            session_id,
            state: LspLifecycleState::Initializing,
            process_id,
        })
    }

    fn session(&self, session_id: &str) -> Result<Arc<RuntimeSession>, CoreError> {
        self.lock_sessions()?
            .get(session_id)
            .cloned()
            .ok_or_else(|| unknown_session(session_id))
    }

    fn destroy(&self, session_id: &str) -> Result<(), CoreError> {
        let session = self.session(session_id)?;
        let lifecycle = session.lock_state()?.lifecycle;
        if !matches!(
            lifecycle,
            LspLifecycleState::Stopped | LspLifecycleState::Failed
        ) {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "A running language-server session cannot be destroyed.",
            ));
        }
        self.lock_sessions()?.remove(session_id);
        Ok(())
    }

    fn lock_sessions(
        &self,
    ) -> Result<MutexGuard<'_, BTreeMap<String, Arc<RuntimeSession>>>, CoreError> {
        self.sessions.lock().map_err(|_| {
            CoreError::new(
                ErrorCode::Unknown,
                "Language-server session registry lock was poisoned.",
            )
        })
    }
}

impl RuntimeSession {
    fn sync_document(&self, request: SyncDocumentRequest) -> Result<(), CoreError> {
        let uri = request.uri;
        let mut messages = Vec::new();
        {
            let mut state = self.lock_state()?;
            ensure_not_terminal(state.lifecycle)?;
            if state.lifecycle == LspLifecycleState::Ready {
                let response = if state
                    .client
                    .open_documents
                    .get(&uri)
                    .is_some_and(|document| document.version > 0)
                {
                    client_change_document(ClientChangeDocumentRequest {
                        state: state.client.clone(),
                        uri: uri.clone(),
                        text: request.text,
                        content_changes: request.content_changes,
                    })?
                } else {
                    client_open_document(ClientOpenDocumentRequest {
                        state: state.client.clone(),
                        uri: uri.clone(),
                        language_id: request.language_id,
                        text: request.text,
                    })?
                };
                state.client = response.state;
                messages = response.messages;
            } else {
                // Version zero means the semantic document exists in the Rust
                // store but has not yet been opened on the server. The latest
                // sync wins until initialize completes.
                state.client.diagnostics.remove(&uri);
                state.client.diagnostic_versions.remove(&uri);
                state.client.open_documents.insert(
                    uri.clone(),
                    LspClientDocument {
                        uri,
                        language_id: request.language_id,
                        version: 0,
                        text: request.text,
                    },
                );
            }
        }
        self.send_messages_or_fail(messages, "documentSync")
    }

    fn close_document(&self, uri: &str) -> Result<(), CoreError> {
        let mut messages = Vec::new();
        let cleared;
        {
            let mut state = self.lock_state()?;
            ensure_not_terminal(state.lifecycle)?;
            let Some(document) = state.client.open_documents.get(uri).cloned() else {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Cannot close a document that is not owned by the language-server session.",
                ));
            };
            cleared = state.client.diagnostics.contains_key(uri);
            if document.version == 0 {
                state.client.open_documents.remove(uri);
                state.client.diagnostics.remove(uri);
                state.client.diagnostic_versions.remove(uri);
            } else {
                let response = client_close_document(ClientCloseDocumentRequest {
                    state: state.client.clone(),
                    uri: uri.to_string(),
                })?;
                state.client = response.state;
                messages = response.messages;
            }
            if cleared {
                push_diagnostics_event(self, &mut state, uri, None, Vec::new());
            }
        }
        self.send_messages_or_fail(messages, "documentClose")
    }

    fn request(&self, request: SemanticRequest, operation_id: String) -> Result<(), CoreError> {
        let (messages, request_id) = {
            let mut state = self.lock_state()?;
            if state.lifecycle != LspLifecycleState::Ready || !state.client.initialized {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Language server is not ready.",
                ));
            }
            if state.request_by_operation.contains_key(&operation_id) {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "The language-server operation ID is already pending.",
                ));
            }
            let uri = request.uri.clone();
            let method = semantic_method(request.operation);
            let required_capability = semantic_capability(request.operation);
            if let Some(capability) = required_capability {
                if !state
                    .client
                    .server_capabilities
                    .iter()
                    .any(|candidate| candidate == capability)
                {
                    return Err(CoreError::new(
                        ErrorCode::NotSupported,
                        "The language server did not advertise this capability.",
                    )
                    .with_details(capability));
                }
            }

            let pending_kind = if request.operation == LspSemanticOperation::VirtualDocument {
                PendingKind::VirtualDocument
            } else {
                PendingKind::Feature
            };
            let response = match request.operation {
                LspSemanticOperation::ExecuteCommand => {
                    let command = request.command.ok_or_else(|| {
                        CoreError::new(
                            ErrorCode::InvalidRequest,
                            "This language-server request requires a command.",
                        )
                    })?;
                    allocate_raw_request(state.client.clone(), method, command)?
                }
                LspSemanticOperation::VirtualDocument => {
                    let virtual_uri = request.virtual_uri.as_deref().ok_or_else(|| {
                        CoreError::new(
                            ErrorCode::InvalidRequest,
                            "Virtual-document resolution requires virtualUri.",
                        )
                    })?;
                    let params = virtual_source_resolve_params(&self.provider_id, virtual_uri)
                        .ok_or_else(|| {
                            CoreError::new(
                                ErrorCode::NotSupported,
                                "The provider cannot resolve this virtual document URI.",
                            )
                        })?;
                    allocate_raw_request(
                        state.client.clone(),
                        method,
                        json!({
                            "command": params.command,
                            "arguments": params.arguments
                        }),
                    )?
                }
                _ => {
                    let uri = uri.clone().ok_or_else(|| {
                        CoreError::new(
                            ErrorCode::InvalidRequest,
                            "This language-server operation requires a document URI.",
                        )
                    })?;
                    if !state
                        .client
                        .open_documents
                        .get(&uri)
                        .is_some_and(|document| document.version > 0)
                    {
                        return Err(CoreError::new(
                            ErrorCode::InvalidRequest,
                            "The document is not open in the language server.",
                        ));
                    }
                    client_feature_request_canonical(ClientFeatureRequest {
                        state: state.client.clone(),
                        uri,
                        method: method.to_string(),
                        position: request.position,
                        new_name: request.new_name,
                        range: request.range,
                        diagnostics: request.diagnostics,
                        completion_item: request.completion_item,
                        code_action: request.code_action,
                        command: request.command,
                    })?
                }
            };
            let request_id = (response.state.next_request_id - 1).to_string();
            let now = Instant::now();
            let pending = PendingRequest {
                kind: pending_kind,
                operation_id: Some(operation_id.clone()),
                method: method.to_string(),
                document_uri: uri,
                created_at: now,
                deadline: now + state.request_timeout,
            };
            state.client = response.state;
            state.pending.insert(request_id.clone(), pending);
            state
                .request_by_operation
                .insert(operation_id, request_id.clone());
            (response.messages, request_id)
        };
        if let Err(error) = self.send_messages(messages) {
            self.complete_request_with_error(
                &request_id,
                "transportFailed",
                "request",
                "Could not write the language-server request.",
                Some(core_error_detail(&error)),
                None,
            );
            self.fail(
                "transportFailed",
                "request",
                "Language-server stdin failed.",
                Some(core_error_detail(&error)),
                None,
            );
            self.kill_process();
            return Err(error);
        }
        Ok(())
    }

    fn cancel_operation(&self, operation_id: &str) -> Result<(), CoreError> {
        let request_id = {
            let mut state = self.lock_state()?;
            let request_id = state
                .request_by_operation
                .remove(operation_id)
                .ok_or_else(|| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Unknown pending language-server operation.",
                    )
                })?;
            let pending = state.pending.remove(&request_id).ok_or_else(|| {
                CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Unknown pending language-server request.",
                )
            })?;
            state.client.pending_requests.remove(&request_id);
            let error = runtime_error(
                self,
                "requestCancelled",
                "request",
                Some(&pending.method),
                pending.document_uri.as_deref(),
                "Language-server request was cancelled.",
                None,
                None,
            );
            push_request_event(
                self,
                &mut state,
                operation_id,
                &pending.method,
                None,
                Some(error),
            );
            request_id
        };
        let cancellation = json!({
            "jsonrpc": "2.0",
            "method": "$/cancelRequest",
            "params": { "id": request_id }
        })
        .to_string();
        self.send_messages_or_fail(vec![cancellation], "requestCancel")
    }

    fn stop(&self) -> Result<(), CoreError> {
        let (messages, force_kill) = {
            let mut state = self.lock_state()?;
            if matches!(
                state.lifecycle,
                LspLifecycleState::Stopped | LspLifecycleState::Failed
            ) {
                return Ok(());
            }
            if state.lifecycle == LspLifecycleState::Stopping {
                return Ok(());
            }
            fail_feature_requests(
                self,
                &mut state,
                "requestCancelled",
                "stop",
                "Language-server session is stopping.",
                None,
            );
            clear_runtime_diagnostics(self, &mut state);
            transition_locked(self, &mut state, LspLifecycleState::Stopping, None);
            state.initialize_deadline = None;
            state.shutdown_deadline = Some(Instant::now() + state.shutdown_timeout);
            if state.client.initialized {
                let response = client_shutdown(ClientShutdownRequest {
                    state: state.client.clone(),
                })?;
                let request_id = (response.state.next_request_id - 1).to_string();
                let now = Instant::now();
                let shutdown_timeout = state.shutdown_timeout;
                state.pending.insert(
                    request_id,
                    PendingRequest {
                        kind: PendingKind::Shutdown,
                        operation_id: None,
                        method: "shutdown".to_string(),
                        document_uri: None,
                        created_at: now,
                        deadline: now + shutdown_timeout,
                    },
                );
                state.client = response.state;
                (response.messages, false)
            } else {
                state.client.pending_requests.clear();
                state.pending.clear();
                (Vec::new(), true)
            }
        };
        self.send_messages_or_fail(messages, "shutdown")?;
        if force_kill {
            self.kill_process();
        }
        Ok(())
    }

    fn poll_events(&self) -> Result<Vec<LspRuntimeEvent>, CoreError> {
        let mut state = self.lock_state()?;
        Ok(state.events.drain(..).collect())
    }

    fn wait_events(&self, timeout: Duration) -> Result<Vec<LspRuntimeEvent>, CoreError> {
        let mut state = self.lock_state()?;
        let deadline = Instant::now() + timeout;
        loop {
            crate::protocol::cancellation::check()?;
            if !state.events.is_empty() {
                return Ok(state.events.drain(..).collect());
            }
            if matches!(
                state.lifecycle,
                LspLifecycleState::Stopped | LspLifecycleState::Failed
            ) {
                return Ok(Vec::new());
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Ok(Vec::new());
            }
            let (guard, wait_result) =
                self.event_signal
                    .wait_timeout(state, remaining)
                    .map_err(|_| {
                        CoreError::new(
                            ErrorCode::Unknown,
                            "Language-server event wait lock was poisoned.",
                        )
                    })?;
            state = guard;
            if wait_result.timed_out() && state.events.is_empty() {
                return Ok(Vec::new());
            }
        }
    }

    #[cfg(test)]
    fn snapshot(&self) -> Result<EngineSnapshot, CoreError> {
        let state = self.lock_state()?;
        Ok(EngineSnapshot {
            session_id: self.id.clone(),
            provider_id: self.provider_id.clone(),
            root_uri: self.root_uri.clone(),
            state: state.lifecycle,
            initialized: state.client.initialized,
            open_documents: state.client.open_documents.clone(),
            pending_operation_ids: state.request_by_operation.keys().cloned().collect(),
            diagnostic_versions: state.client.diagnostic_versions.clone(),
        })
    }

    fn spawn_readers(
        self: &Arc<Self>,
        mut stdout: Box<dyn Read + Send>,
        mut stderr: Box<dyn Read + Send>,
    ) {
        let output_session = self.clone();
        thread::spawn(move || {
            let mut frame_buffer = Vec::new();
            let mut chunk = vec![0_u8; 8 * 1024];
            while output_session.active.load(Ordering::Acquire) {
                match stdout.read(&mut chunk) {
                    Ok(0) => break,
                    Ok(count) => {
                        match parse_server_messages(ParseServerMessagesRequest {
                            buffer: std::mem::take(&mut frame_buffer),
                            chunk: chunk[..count].to_vec(),
                        }) {
                            Ok(parsed) => {
                                frame_buffer = parsed.buffer;
                                for message in parsed.messages {
                                    if let Err(error) =
                                        output_session.handle_server_message(message)
                                    {
                                        output_session.fail(
                                            "invalidServerMessage",
                                            "transport",
                                            "Language server sent an invalid message.",
                                            Some(core_error_detail(&error)),
                                            None,
                                        );
                                        output_session.kill_process();
                                        return;
                                    }
                                }
                            }
                            Err(error) => {
                                output_session.fail(
                                    "transportFailed",
                                    "transport",
                                    "Language-server stdout framing failed.",
                                    Some(core_error_detail(&error)),
                                    None,
                                );
                                output_session.kill_process();
                                return;
                            }
                        }
                    }
                    Err(error) => {
                        output_session.fail(
                            "transportFailed",
                            "transport",
                            "Could not read language-server stdout.",
                            Some(error.to_string()),
                            None,
                        );
                        output_session.kill_process();
                        return;
                    }
                }
            }
        });

        let error_session = self.clone();
        thread::spawn(move || {
            let mut chunk = vec![0_u8; 4 * 1024];
            while error_session.active.load(Ordering::Acquire) {
                match stderr.read(&mut chunk) {
                    Ok(0) => break,
                    Ok(count) => error_session.log(
                        "warning",
                        "Language-server stderr",
                        Some(String::from_utf8_lossy(&chunk[..count]).trim().to_string()),
                    ),
                    Err(error) => {
                        error_session.log(
                            "warning",
                            "Could not read language-server stderr",
                            Some(error.to_string()),
                        );
                        break;
                    }
                }
            }
        });
    }

    fn spawn_monitor(self: &Arc<Self>) {
        let session = self.clone();
        thread::spawn(move || {
            while session.active.load(Ordering::Acquire) {
                if let Some(exit_code) = session.process.exit_status() {
                    session.handle_process_exit(exit_code);
                    break;
                }
                session.expire_deadlines();
                thread::sleep(Duration::from_millis(MONITOR_INTERVAL_MS));
            }
        });
    }

    fn handle_server_message(&self, message: String) -> Result<(), CoreError> {
        let value: Value = serde_json::from_str(&message).map_err(|error| {
            CoreError::new(ErrorCode::ParseFailed, "Invalid LSP server JSON message.")
                .with_details(error.to_string())
        })?;

        if value.get("method").and_then(Value::as_str) == Some("workspace/configuration") {
            if let Some(response) = self.provider_configuration_response(&value)? {
                return self.send_messages_or_fail(vec![response], "serverRequest");
            }
        }

        let response_id = if value.get("method").is_none() {
            lsp_value_id(value.get("id"))
        } else {
            None
        };
        let (known_pending, pending_before, old_capabilities) = {
            let state = self.lock_state()?;
            let pending = response_id
                .as_ref()
                .and_then(|id| state.pending.get(id).cloned());
            (
                response_id
                    .as_ref()
                    .is_none_or(|id| state.client.pending_requests.contains_key(id)),
                pending,
                state.client.server_capabilities.clone(),
            )
        };
        // A response whose request has timed out, been cancelled, or belongs
        // to an older session is intentionally ignored.
        if response_id.is_some() && !known_pending {
            self.log(
                "info",
                "Ignored a late language-server response",
                response_id,
            );
            return Ok(());
        }

        let reduced = {
            let state = self.lock_state()?;
            client_apply_server_message(ClientApplyServerMessageRequest {
                state: state.client.clone(),
                message,
            })?
        };
        let mut outbound = reduced.messages;
        let mut flush_documents = false;
        let mut fail_initialize: Option<(String, Option<String>)> = None;
        {
            let mut state = self.lock_state()?;
            state.client = reduced.state;
            if let Some(request_id) = response_id.as_ref() {
                state.client.pending_requests.remove(request_id);
                if let Some(pending) = state.pending.remove(request_id) {
                    if let Some(operation_id) = &pending.operation_id {
                        state.request_by_operation.remove(operation_id);
                    }
                }
            }

            match pending_before.as_ref().map(|pending| pending.kind) {
                Some(PendingKind::Initialize) => {
                    state.initialize_deadline = None;
                    let server_error = value.get("error").map(Value::to_string);
                    if server_error.is_some() || !state.client.initialized {
                        fail_initialize = Some((
                            if server_error.is_some() {
                                "initializeFailed".to_string()
                            } else {
                                "invalidServerMessage".to_string()
                            },
                            server_error,
                        ));
                    } else {
                        transition_locked(self, &mut state, LspLifecycleState::Ready, None);
                        let capabilities = state.client.server_capabilities.clone();
                        push_features_event(self, &mut state, capabilities);
                        if let Some(info) = parse_server_info(&value) {
                            push_server_info_event(self, &mut state, info);
                        }
                        flush_documents = true;
                    }
                }
                Some(PendingKind::Feature) => {
                    if let Some(pending) = pending_before.as_ref() {
                        if let Some(operation_id) = &pending.operation_id {
                            let event = reduced
                                .events
                                .iter()
                                .find(|event| event.request_id.as_ref() == response_id.as_ref());
                            let error =
                                event.and_then(|event| event.error.as_ref()).map(|detail| {
                                    runtime_error(
                                        self,
                                        "serverError",
                                        "request",
                                        Some(&pending.method),
                                        pending.document_uri.as_deref(),
                                        "Language server returned an error.",
                                        Some(detail),
                                        None,
                                    )
                                });
                            push_request_event(
                                self,
                                &mut state,
                                operation_id,
                                &pending.method,
                                event.and_then(|event| event.result.clone()),
                                error,
                            );
                        }
                    }
                }
                Some(PendingKind::VirtualDocument) => {
                    if let Some(pending) = pending_before.as_ref() {
                        if let Some(operation_id) = &pending.operation_id {
                            let reduced_event = reduced
                                .events
                                .iter()
                                .find(|event| event.request_id.as_ref() == response_id.as_ref());
                            let server_error = reduced_event
                                .and_then(|event| event.error.as_ref())
                                .map(|detail| {
                                    runtime_error(
                                        self,
                                        "serverError",
                                        "request",
                                        Some(&pending.method),
                                        None,
                                        "Language server returned an error.",
                                        Some(detail),
                                        None,
                                    )
                                });
                            let content = value.get("result").and_then(|result| {
                                virtual_source_content(&self.provider_id, result)
                            });
                            let invalid_result = if server_error.is_none() && content.is_none() {
                                Some(runtime_error(
                                    self,
                                    "invalidServerResult",
                                    "request",
                                    Some(&pending.method),
                                    None,
                                    "Language server returned no virtual-document text.",
                                    None,
                                    None,
                                ))
                            } else {
                                None
                            };
                            push_request_event(
                                self,
                                &mut state,
                                operation_id,
                                &pending.method,
                                content.map(|text| json!({ "text": text })),
                                server_error.or(invalid_result),
                            );
                        }
                    }
                }
                Some(PendingKind::Shutdown) => {
                    // The reducer emits `exit` only after the shutdown response.
                    state.shutdown_deadline = Some(Instant::now() + state.shutdown_timeout);
                }
                None => {}
            }

            for event in reduced.events {
                if event.kind == "diagnostics" {
                    if let Some(uri) = event.uri.as_deref() {
                        push_diagnostics_event(
                            self,
                            &mut state,
                            uri,
                            event.version,
                            event.diagnostics.unwrap_or_default(),
                        );
                    }
                } else if event.kind == "notification" {
                    push_log_event(
                        self,
                        &mut state,
                        "info",
                        event
                            .method
                            .as_deref()
                            .unwrap_or("Language-server notification"),
                        event.result.map(|value| value.to_string()),
                    );
                }
            }
            if state.client.server_capabilities != old_capabilities
                && state.lifecycle == LspLifecycleState::Ready
            {
                let capabilities = state.client.server_capabilities.clone();
                push_features_event(self, &mut state, capabilities);
            }
        }

        if let Some((code, detail)) = fail_initialize {
            self.fail(
                &code,
                "initialize",
                "Language-server initialization failed.",
                detail,
                None,
            );
            self.kill_process();
            return Ok(());
        }
        if flush_documents {
            if let Some(notification) = initialized_notification(&self.provider_id) {
                outbound.push(
                    json!({
                        "jsonrpc": "2.0",
                        "method": notification.method,
                        "params": notification.params
                    })
                    .to_string(),
                );
            }
            outbound.extend(self.flush_queued_documents()?);
        }
        self.send_messages_or_fail(outbound, "serverResponse")
    }

    fn provider_configuration_response(
        &self,
        message: &Value,
    ) -> Result<Option<String>, CoreError> {
        let Some(id) = message.get("id") else {
            return Ok(None);
        };
        let items: Vec<WorkspaceConfigurationItem> = message
            .get("params")
            .and_then(|params| params.get("items"))
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .map(|item| WorkspaceConfigurationItem {
                scope_uri: item
                    .get("scopeUri")
                    .and_then(Value::as_str)
                    .map(ToString::to_string),
                section: item
                    .get("section")
                    .and_then(Value::as_str)
                    .map(ToString::to_string),
            })
            .collect();
        let Some(values) = workspace_configuration(&self.provider_id, &items) else {
            return Ok(None);
        };
        Ok(Some(
            serde_json::to_string(&json!({
                "jsonrpc": "2.0",
                "id": id,
                "result": values
            }))
            .map_err(|error| {
                CoreError::new(
                    ErrorCode::Unknown,
                    "Could not encode the provider configuration response.",
                )
                .with_details(error.to_string())
            })?,
        ))
    }

    fn flush_queued_documents(&self) -> Result<Vec<String>, CoreError> {
        let mut state = self.lock_state()?;
        let queued: Vec<_> = state
            .client
            .open_documents
            .values()
            .filter(|document| document.version == 0)
            .cloned()
            .collect();
        let mut messages = Vec::new();
        for document in queued {
            let response = client_open_document(ClientOpenDocumentRequest {
                state: state.client.clone(),
                uri: document.uri,
                language_id: document.language_id,
                text: document.text,
            })?;
            state.client = response.state;
            messages.extend(response.messages);
        }
        Ok(messages)
    }

    fn expire_deadlines(&self) {
        let now = Instant::now();
        let mut cancellations = Vec::new();
        let mut initialize_timeout = false;
        let mut shutdown_timeout = false;
        if let Ok(mut state) = self.lock_state() {
            if state.lifecycle == LspLifecycleState::Initializing
                && state
                    .initialize_deadline
                    .is_some_and(|deadline| now >= deadline)
            {
                state.initialize_deadline = None;
                initialize_timeout = true;
            }

            let expired: Vec<_> = state
                .pending
                .iter()
                .filter(|(_, pending)| {
                    matches!(
                        pending.kind,
                        PendingKind::Feature | PendingKind::VirtualDocument
                    ) && now >= pending.deadline
                })
                .map(|(id, _)| id.clone())
                .collect();
            for request_id in expired {
                let Some(pending) = state.pending.remove(&request_id) else {
                    continue;
                };
                state.client.pending_requests.remove(&request_id);
                if let Some(operation_id) = pending.operation_id.as_deref() {
                    state.request_by_operation.remove(operation_id);
                    let elapsed = now.saturating_duration_since(pending.created_at);
                    let error = runtime_error(
                        self,
                        "requestTimeout",
                        "request",
                        Some(&pending.method),
                        pending.document_uri.as_deref(),
                        "Language-server request timed out.",
                        Some(&format!("elapsedMilliseconds={}", elapsed.as_millis())),
                        None,
                    );
                    push_request_event(
                        self,
                        &mut state,
                        operation_id,
                        &pending.method,
                        None,
                        Some(error),
                    );
                }
                cancellations.push(request_id);
            }
            if state.lifecycle == LspLifecycleState::Stopping
                && state
                    .shutdown_deadline
                    .is_some_and(|deadline| now >= deadline)
            {
                state.shutdown_deadline = None;
                shutdown_timeout = true;
                push_log_event(
                    self,
                    &mut state,
                    "warning",
                    "Language-server shutdown timed out; forcing termination",
                    None,
                );
            }
        }
        if !cancellations.is_empty() {
            let messages = cancellations
                .into_iter()
                .map(|id| {
                    json!({
                        "jsonrpc": "2.0",
                        "method": "$/cancelRequest",
                        "params": { "id": id }
                    })
                    .to_string()
                })
                .collect();
            let _ = self.send_messages(messages);
        }
        if initialize_timeout {
            self.fail(
                "initializeTimeout",
                "initialize",
                "Language-server initialization timed out.",
                None,
                None,
            );
            self.kill_process();
        } else if shutdown_timeout {
            self.kill_process();
        }
    }

    fn handle_process_exit(&self, exit_code: Option<i32>) {
        self.active.store(false, Ordering::Release);
        self.process.close_input();
        if let Ok(mut state) = self.lock_state() {
            let was_stopping = state.lifecycle == LspLifecycleState::Stopping;
            if !state.terminal_event_emitted {
                let error = (!was_stopping).then(|| {
                    runtime_error(
                        self,
                        "serverExited",
                        "process",
                        None,
                        None,
                        "Language-server process exited.",
                        None,
                        exit_code,
                    )
                });
                fail_feature_requests(
                    self,
                    &mut state,
                    "serverExited",
                    "process",
                    "Language-server process exited before the request completed.",
                    exit_code,
                );
                clear_runtime_state(self, &mut state);
                transition_locked(
                    self,
                    &mut state,
                    if was_stopping {
                        LspLifecycleState::Stopped
                    } else {
                        LspLifecycleState::Failed
                    },
                    error,
                );
                state.terminal_event_emitted = true;
            }
        }
    }

    fn complete_request_with_error(
        &self,
        request_id: &str,
        code: &str,
        stage: &str,
        message: &str,
        underlying: Option<String>,
        exit_code: Option<i32>,
    ) {
        if let Ok(mut state) = self.lock_state() {
            let Some(pending) = state.pending.remove(request_id) else {
                return;
            };
            state.client.pending_requests.remove(request_id);
            if let Some(operation_id) = pending.operation_id.as_deref() {
                state.request_by_operation.remove(operation_id);
                let error = runtime_error(
                    self,
                    code,
                    stage,
                    Some(&pending.method),
                    pending.document_uri.as_deref(),
                    message,
                    underlying.as_deref(),
                    exit_code,
                );
                push_request_event(
                    self,
                    &mut state,
                    operation_id,
                    &pending.method,
                    None,
                    Some(error),
                );
            }
        }
    }

    fn fail(
        &self,
        code: &str,
        stage: &str,
        message: &str,
        underlying: Option<String>,
        exit_code: Option<i32>,
    ) {
        if let Ok(mut state) = self.lock_state() {
            if state.terminal_event_emitted {
                return;
            }
            fail_feature_requests(self, &mut state, code, stage, message, exit_code);
            clear_runtime_state(self, &mut state);
            let error = runtime_error(
                self,
                code,
                stage,
                None,
                None,
                message,
                underlying.as_deref(),
                exit_code,
            );
            transition_locked(self, &mut state, LspLifecycleState::Failed, Some(error));
            state.terminal_event_emitted = true;
        }
    }

    fn transition(
        &self,
        lifecycle: LspLifecycleState,
        error: Option<LspRuntimeError>,
    ) -> Result<(), CoreError> {
        let mut state = self.lock_state()?;
        transition_locked(self, &mut state, lifecycle, error);
        Ok(())
    }

    fn log(&self, level: &str, message: &str, detail: Option<String>) {
        if let Ok(mut state) = self.lock_state() {
            push_log_event(self, &mut state, level, message, detail);
        }
    }

    fn send_messages_or_fail(&self, messages: Vec<String>, stage: &str) -> Result<(), CoreError> {
        if messages.is_empty() {
            return Ok(());
        }
        if let Err(error) = self.send_messages(messages) {
            self.fail(
                "transportFailed",
                stage,
                "Could not write to language-server stdin.",
                Some(core_error_detail(&error)),
                None,
            );
            self.kill_process();
            return Err(error);
        }
        Ok(())
    }

    fn send_messages(&self, messages: Vec<String>) -> Result<(), CoreError> {
        for message in messages {
            let frame = frame_message(FrameMessageRequest { message })?.frame;
            self.process.write_input(frame.as_bytes())?;
        }
        Ok(())
    }

    fn kill_process(&self) {
        self.process.terminate();
    }

    fn lock_state(&self) -> Result<MutexGuard<'_, SessionState>, CoreError> {
        self.state.lock().map_err(|_| {
            CoreError::new(
                ErrorCode::Unknown,
                "Language-server session state lock was poisoned.",
            )
        })
    }
}

fn validate_start_request(request: &StartServerRequest) -> Result<(), CoreError> {
    if request.provider_id.trim().is_empty() {
        return Err(invalid_field("providerId"));
    }
    if request.executable_path.trim().is_empty()
        || request.executable_path.contains('\0')
        || request.working_directory.trim().is_empty()
        || request.working_directory.contains('\0')
    {
        return Err(invalid_field("executablePath/workingDirectory"));
    }
    if !request.root_uri.contains("://") || request.root_uri.contains('\0') {
        return Err(invalid_field("rootUri"));
    }
    Ok(())
}

fn invalid_field(field: &str) -> CoreError {
    CoreError::new(
        ErrorCode::InvalidRequest,
        "Invalid language-server start request.",
    )
    .with_details(field)
}

fn core_error_detail(error: &CoreError) -> String {
    match error.details.as_deref() {
        Some(details) if !details.is_empty() => format!("{} ({details})", error.message),
        _ => error.message.clone(),
    }
}

fn unknown_session(session_id: &str) -> CoreError {
    CoreError::new(
        ErrorCode::InvalidRequest,
        "Unknown language-server session.",
    )
    .with_details(session_id)
}

fn ensure_not_terminal(lifecycle: LspLifecycleState) -> Result<(), CoreError> {
    if matches!(
        lifecycle,
        LspLifecycleState::Stopping | LspLifecycleState::Stopped | LspLifecycleState::Failed
    ) {
        Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Language-server session is not accepting document changes.",
        ))
    } else {
        Ok(())
    }
}

fn java_executable_from_environment(environment: &BTreeMap<String, String>) -> Option<PathBuf> {
    environment.get("JAVA_HOME").map(|home| {
        let executable = if cfg!(windows) { "java.exe" } else { "java" };
        Path::new(home).join("bin").join(executable)
    })
}

fn semantic_method(operation: LspSemanticOperation) -> &'static str {
    match operation {
        LspSemanticOperation::Completion => "textDocument/completion",
        LspSemanticOperation::Hover => "textDocument/hover",
        LspSemanticOperation::Definition => "textDocument/definition",
        LspSemanticOperation::Declaration => "textDocument/declaration",
        LspSemanticOperation::TypeDefinition => "textDocument/typeDefinition",
        LspSemanticOperation::References => "textDocument/references",
        LspSemanticOperation::Implementation => "textDocument/implementation",
        LspSemanticOperation::Rename => "textDocument/rename",
        LspSemanticOperation::Formatting => "textDocument/formatting",
        LspSemanticOperation::CodeActions => "textDocument/codeAction",
        LspSemanticOperation::ResolveCompletion => "completionItem/resolve",
        LspSemanticOperation::ResolveCodeAction => "codeAction/resolve",
        LspSemanticOperation::ExecuteCommand | LspSemanticOperation::VirtualDocument => {
            "workspace/executeCommand"
        }
        LspSemanticOperation::InlayHints => "textDocument/inlayHint",
        LspSemanticOperation::FoldingRanges => "textDocument/foldingRange",
        LspSemanticOperation::CodeLens => "textDocument/codeLens",
    }
}

fn semantic_capability(operation: LspSemanticOperation) -> Option<&'static str> {
    match operation {
        LspSemanticOperation::Completion => Some("completion"),
        LspSemanticOperation::Hover => Some("hover"),
        LspSemanticOperation::Definition => Some("definition"),
        LspSemanticOperation::Declaration => Some("declaration"),
        LspSemanticOperation::TypeDefinition => Some("typeDefinition"),
        LspSemanticOperation::References => Some("references"),
        LspSemanticOperation::Implementation => Some("implementation"),
        LspSemanticOperation::Rename => Some("rename"),
        LspSemanticOperation::Formatting => Some("formatting"),
        LspSemanticOperation::CodeActions => Some("codeActions"),
        LspSemanticOperation::ResolveCompletion => Some("completionResolve"),
        LspSemanticOperation::ResolveCodeAction => Some("codeActionResolve"),
        LspSemanticOperation::ExecuteCommand | LspSemanticOperation::VirtualDocument => {
            Some("executeCommand")
        }
        LspSemanticOperation::InlayHints => Some("inlayHints"),
        LspSemanticOperation::FoldingRanges => Some("foldingRanges"),
        LspSemanticOperation::CodeLens => Some("codeLens"),
    }
}

fn allocate_raw_request(
    mut state: LspClientState,
    method: &str,
    params: Value,
) -> Result<super::LspClientResponse, CoreError> {
    let id = state.next_request_id.to_string();
    state.next_request_id += 1;
    state
        .pending_requests
        .insert(id.clone(), method.to_string());
    let message = serde_json::to_string(&json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": method,
        "params": params
    }))
    .map_err(|error| {
        CoreError::new(
            ErrorCode::Unknown,
            "Could not encode a language-server request.",
        )
        .with_details(error.to_string())
    })?;
    Ok(super::LspClientResponse {
        state,
        messages: vec![message],
        events: Vec::new(),
    })
}

fn lsp_value_id(value: Option<&Value>) -> Option<String> {
    match value? {
        Value::String(value) => Some(value.clone()),
        Value::Number(value) => Some(value.to_string()),
        _ => None,
    }
}

fn parse_server_info(message: &Value) -> Option<LspServerInfo> {
    let info = message.get("result")?.get("serverInfo")?;
    Some(LspServerInfo {
        name: info.get("name")?.as_str()?.to_string(),
        version: info
            .get("version")
            .and_then(Value::as_str)
            .map(ToString::to_string),
    })
}

fn enqueue_runtime_event(
    session: &RuntimeSession,
    state: &mut SessionState,
    event: LspRuntimeEvent,
) {
    state.events.push_back(event);
    session.event_signal.notify_all();
}

fn transition_locked(
    session: &RuntimeSession,
    state: &mut SessionState,
    lifecycle: LspLifecycleState,
    error: Option<LspRuntimeError>,
) {
    state.lifecycle = lifecycle;
    let sequence = take_sequence(state);
    enqueue_runtime_event(
        session,
        state,
        LspRuntimeEvent {
            kind: "stateChanged".to_string(),
            sequence,
            provider_id: session.provider_id.clone(),
            session_id: session.id.clone(),
            state: Some(lifecycle),
            operation_id: None,
            method: None,
            uri: None,
            version: None,
            diagnostics: None,
            result: None,
            error,
            capabilities: None,
            server_info: None,
            level: None,
            message: None,
            detail: None,
        },
    );
}

fn push_request_event(
    session: &RuntimeSession,
    state: &mut SessionState,
    operation_id: &str,
    method: &str,
    result: Option<Value>,
    error: Option<LspRuntimeError>,
) {
    let sequence = take_sequence(state);
    enqueue_runtime_event(
        session,
        state,
        LspRuntimeEvent {
            kind: "requestCompleted".to_string(),
            sequence,
            provider_id: session.provider_id.clone(),
            session_id: session.id.clone(),
            state: None,
            operation_id: Some(operation_id.to_string()),
            method: Some(method.to_string()),
            uri: None,
            version: None,
            diagnostics: None,
            result,
            error,
            capabilities: None,
            server_info: None,
            level: None,
            message: None,
            detail: None,
        },
    );
}

fn push_diagnostics_event(
    session: &RuntimeSession,
    state: &mut SessionState,
    uri: &str,
    version: Option<i64>,
    diagnostics: Vec<LspClientDiagnostic>,
) {
    let sequence = take_sequence(state);
    enqueue_runtime_event(
        session,
        state,
        LspRuntimeEvent {
            kind: "diagnostics".to_string(),
            sequence,
            provider_id: session.provider_id.clone(),
            session_id: session.id.clone(),
            state: None,
            operation_id: None,
            method: None,
            uri: Some(uri.to_string()),
            version,
            diagnostics: Some(diagnostics),
            result: None,
            error: None,
            capabilities: None,
            server_info: None,
            level: None,
            message: None,
            detail: None,
        },
    );
}

fn push_features_event(
    session: &RuntimeSession,
    state: &mut SessionState,
    capabilities: Vec<String>,
) {
    let sequence = take_sequence(state);
    enqueue_runtime_event(
        session,
        state,
        LspRuntimeEvent {
            kind: "featuresChanged".to_string(),
            sequence,
            provider_id: session.provider_id.clone(),
            session_id: session.id.clone(),
            state: None,
            operation_id: None,
            method: None,
            uri: None,
            version: None,
            diagnostics: None,
            result: None,
            error: None,
            capabilities: Some(capabilities),
            server_info: None,
            level: None,
            message: None,
            detail: None,
        },
    );
}

fn push_server_info_event(session: &RuntimeSession, state: &mut SessionState, info: LspServerInfo) {
    let sequence = take_sequence(state);
    enqueue_runtime_event(
        session,
        state,
        LspRuntimeEvent {
            kind: "serverInfoChanged".to_string(),
            sequence,
            provider_id: session.provider_id.clone(),
            session_id: session.id.clone(),
            state: None,
            operation_id: None,
            method: None,
            uri: None,
            version: None,
            diagnostics: None,
            result: None,
            error: None,
            capabilities: None,
            server_info: Some(info),
            level: None,
            message: None,
            detail: None,
        },
    );
}

fn push_log_event(
    session: &RuntimeSession,
    state: &mut SessionState,
    level: &str,
    message: &str,
    detail: Option<String>,
) {
    let sequence = take_sequence(state);
    enqueue_runtime_event(
        session,
        state,
        LspRuntimeEvent {
            kind: "log".to_string(),
            sequence,
            provider_id: session.provider_id.clone(),
            session_id: session.id.clone(),
            state: None,
            operation_id: None,
            method: None,
            uri: None,
            version: None,
            diagnostics: None,
            result: None,
            error: None,
            capabilities: None,
            server_info: None,
            level: Some(level.to_string()),
            message: Some(message.to_string()),
            detail: detail.filter(|value| !value.is_empty()),
        },
    );
}

fn take_sequence(state: &mut SessionState) -> u64 {
    let sequence = state.next_sequence;
    state.next_sequence += 1;
    sequence
}

fn runtime_error(
    session: &RuntimeSession,
    code: &str,
    stage: &str,
    method: Option<&str>,
    document_uri: Option<&str>,
    message: &str,
    underlying: Option<&str>,
    process_exit_code: Option<i32>,
) -> LspRuntimeError {
    LspRuntimeError {
        code: code.to_string(),
        provider_id: session.provider_id.clone(),
        session_id: session.id.clone(),
        stage: stage.to_string(),
        method: method.map(ToString::to_string),
        document_uri: document_uri.map(ToString::to_string),
        message: message.to_string(),
        underlying_message: underlying.map(ToString::to_string),
        process_exit_code,
    }
}

fn fail_feature_requests(
    session: &RuntimeSession,
    state: &mut SessionState,
    code: &str,
    stage: &str,
    message: &str,
    exit_code: Option<i32>,
) {
    let pending: Vec<_> = state
        .pending
        .iter()
        .filter(|(_, pending)| {
            matches!(
                pending.kind,
                PendingKind::Feature | PendingKind::VirtualDocument
            )
        })
        .map(|(request_id, pending)| (request_id.clone(), pending.clone()))
        .collect();
    for (request_id, pending) in pending {
        state.pending.remove(&request_id);
        state.client.pending_requests.remove(&request_id);
        if let Some(operation_id) = pending.operation_id.as_deref() {
            state.request_by_operation.remove(operation_id);
            let error = runtime_error(
                session,
                code,
                stage,
                Some(&pending.method),
                pending.document_uri.as_deref(),
                message,
                None,
                exit_code,
            );
            push_request_event(
                session,
                state,
                operation_id,
                &pending.method,
                None,
                Some(error),
            );
        }
    }
}

fn clear_runtime_diagnostics(session: &RuntimeSession, state: &mut SessionState) {
    let diagnostics: Vec<_> = state.client.diagnostics.keys().cloned().collect();
    state.client.diagnostics.clear();
    state.client.diagnostic_versions.clear();
    for uri in diagnostics {
        push_diagnostics_event(session, state, &uri, None, Vec::new());
    }
}

fn clear_runtime_state(session: &RuntimeSession, state: &mut SessionState) {
    clear_runtime_diagnostics(session, state);
    state.client.initialized = false;
    state.client.shutdown_requested = false;
    state.client.server_capabilities.clear();
    state.client.open_documents.clear();
    state.client.pending_requests.clear();
    state.pending.clear();
    state.request_by_operation.clear();
    state.initialize_deadline = None;
    state.shutdown_deadline = None;
    push_features_event(session, state, Vec::new());
}

#[cfg(test)]
mod tests {
    use super::super::scripted::ScriptedServer;
    use super::*;

    /// The capabilities every test needs to reach `Ready` with a usable feature
    /// surface. Individual tests narrow or extend this.
    fn ready_capabilities() -> Value {
        json!({
            "hoverProvider": true,
            "definitionProvider": true,
            "completionProvider": {},
            "renameProvider": true
        })
    }

    fn start_request(server: &ScriptedServer) -> StartServerRequest {
        let _ = server;
        StartServerRequest {
            // A non-Java provider keeps JDT argument adaptation out of the way;
            // `adapt_start` is covered by its own tests.
            provider_id: "gopls".to_string(),
            executable_path: "/usr/bin/scripted-server".to_string(),
            arguments: vec!["--stdio".to_string()],
            environment: BTreeMap::new(),
            root_uri: "file:///workspace".to_string(),
            working_directory: "/workspace".to_string(),
            initialization_options: None,
            runtime_executable_path: None,
            cache_directory: None,
            initialize_timeout_milliseconds: 10_000,
            request_timeout_milliseconds: 10_000,
            shutdown_timeout_milliseconds: 10_000,
        }
    }

    /// An engine with a scripted server behind it, plus the started session.
    struct Harness {
        engine: LspEngine,
        server: ScriptedServer,
        session_id: String,
        /// Events are drained by every poll, so the harness accumulates them and
        /// tests assert against the whole history.
        events: Vec<LspRuntimeEvent>,
    }

    impl Harness {
        fn start(configure: impl FnOnce(&mut StartServerRequest)) -> Self {
            let server = ScriptedServer::new();
            let engine = LspEngine::with_launcher(server.launcher());
            let mut request = start_request(&server);
            configure(&mut request);
            let started = engine
                .start_server(request)
                .expect("the server should start");
            Self {
                engine,
                server,
                session_id: started.session_id,
                events: Vec::new(),
            }
        }

        fn ready() -> Self {
            let mut harness = Self::start(|_| {});
            harness.server.complete_initialize(ready_capabilities());
            harness.await_state(LspLifecycleState::Ready);
            harness
        }

        fn session(&self) -> Arc<RuntimeSession> {
            self.engine
                .session(&self.session_id)
                .expect("the session should be registered")
        }

        fn poll(&mut self) -> &[LspRuntimeEvent] {
            let events = self
                .session()
                .poll_events()
                .expect("polling should succeed");
            self.events.extend(events);
            &self.events
        }

        /// Waits until the session reports `lifecycle`, draining events as it
        /// goes so nothing is lost to the poll that observes the transition.
        fn await_state(&mut self, lifecycle: LspLifecycleState) {
            let deadline = Instant::now() + Duration::from_secs(5);
            while Instant::now() < deadline {
                self.poll();
                if self.snapshot().state == lifecycle {
                    // The transition can happen between the poll and snapshot;
                    // drain once more so its co-published events are retained.
                    self.poll();
                    return;
                }
                thread::sleep(Duration::from_millis(2));
            }
            self.poll();
            panic!(
                "session stayed in {:?} instead of reaching {lifecycle:?}",
                self.snapshot().state
            );
        }

        /// Waits until an event matching `matches` has been observed.
        fn await_event(&mut self, matches: impl Fn(&LspRuntimeEvent) -> bool) -> &LspRuntimeEvent {
            let deadline = Instant::now() + Duration::from_secs(5);
            while Instant::now() < deadline {
                self.poll();
                if self.events.iter().any(&matches) {
                    break;
                }
                thread::sleep(Duration::from_millis(2));
            }
            self.events
                .iter()
                .find(|event| matches(event))
                .expect("the expected runtime event was never emitted")
        }

        fn snapshot(&self) -> EngineSnapshot {
            self.session().snapshot().expect("snapshot should succeed")
        }

        fn sync(&self, uri: &str, text: &str) {
            self.session()
                .sync_document(SyncDocumentRequest {
                    session_id: self.session_id.clone(),
                    uri: uri.to_string(),
                    language_id: "go".to_string(),
                    text: text.to_string(),
                    content_changes: Vec::new(),
                })
                .expect("syncing a document should succeed");
        }

        /// Issues a feature request and returns its opaque operation ID.
        fn request(&self, operation: LspSemanticOperation, uri: &str) -> String {
            let operation_id = self.engine.next_operation_id();
            self.session()
                .request(
                    SemanticRequest {
                        session_id: self.session_id.clone(),
                        operation_id: Some(operation_id.clone()),
                        operation,
                        uri: Some(uri.to_string()),
                        virtual_uri: None,
                        position: Some(LspPosition {
                            line: 0,
                            utf16_column: 0,
                        }),
                        new_name: None,
                        range: None,
                        diagnostics: Vec::new(),
                        completion_item: None,
                        code_action: None,
                        command: None,
                    },
                    operation_id.clone(),
                )
                .expect("a ready session should accept the request");
            operation_id
        }

        /// The notification the server received for `method`, if any.
        fn notification(&self, method: &str) -> Option<Value> {
            self.server
                .messages()
                .into_iter()
                .find(|message| message.get("method").and_then(Value::as_str) == Some(method))
        }
    }

    /// Criterion 1: a spawned process that never initializes cannot become ready.
    #[test]
    fn a_server_that_never_answers_initialize_fails_instead_of_becoming_ready() {
        let mut harness = Harness::start(|request| {
            request.initialize_timeout_milliseconds = 30;
        });
        harness.await_state(LspLifecycleState::Failed);

        let states: Vec<_> = harness
            .events
            .iter()
            .filter_map(|event| event.state)
            .collect();
        assert!(
            !states.contains(&LspLifecycleState::Ready),
            "an uninitialized session must never pass through Ready: {states:?}"
        );
        let failure = harness
            .events
            .iter()
            .find_map(|event| event.error.as_ref())
            .expect("the timeout should be reported as a runtime error");
        assert_eq!(failure.code, "initializeTimeout");
        assert_eq!(failure.stage, "initialize");
    }

    /// Criterion 2: an initialize error cannot become ready.
    #[test]
    fn an_initialize_error_response_fails_the_session() {
        let mut harness = Harness::start(|_| {});
        let id = harness
            .server
            .await_request("initialize")
            .expect("initialize should be sent");
        harness.server.send(json!({
            "jsonrpc": "2.0",
            "id": id,
            "error": { "code": -32603, "message": "workspace is unsupported" }
        }));
        harness.await_state(LspLifecycleState::Failed);

        assert!(!harness.snapshot().initialized);
        let failure = harness
            .events
            .iter()
            .find_map(|event| event.error.as_ref())
            .expect("the rejection should be reported as a runtime error");
        assert_eq!(failure.code, "initializeFailed");
        assert!(
            failure
                .underlying_message
                .as_deref()
                .is_some_and(|detail| detail.contains("workspace is unsupported")),
            "the server's own message must survive into the error: {:?}",
            failure.underlying_message
        );
    }

    /// Criterion 3: two syncs emit open version 1 then change version 2.
    #[test]
    fn consecutive_syncs_open_at_version_one_and_change_to_version_two() {
        let harness = Harness::ready();
        let uri = "file:///workspace/main.go";
        harness.sync(uri, "package main");
        harness.sync(uri, "package main\nfunc main() {}");

        let versions: Vec<_> = harness
            .server
            .messages()
            .into_iter()
            .filter_map(|message| {
                let method = message.get("method")?.as_str()?.to_string();
                let document = message.get("params")?.get("textDocument")?;
                let version = document.get("version")?.as_i64()?;
                Some((method, version))
            })
            .collect();
        assert_eq!(
            versions,
            vec![
                ("textDocument/didOpen".to_string(), 1),
                ("textDocument/didChange".to_string(), 2)
            ]
        );
        assert_eq!(harness.snapshot().open_documents[uri].version, 2);
    }

    #[test]
    fn all_documents_synced_during_initialize_are_opened_when_ready() {
        let mut harness = Harness::start(|_| {});
        let first_uri = "file:///workspace/first.go";
        let second_uri = "file:///workspace/second.go";
        harness.sync(first_uri, "package main\nvar first = 1");
        harness.sync(second_uri, "package main\nvar second = 2");

        harness.server.complete_initialize(ready_capabilities());
        harness.await_state(LspLifecycleState::Ready);

        let opened_uris: Vec<_> = harness
            .server
            .messages()
            .into_iter()
            .filter(|message| {
                message.get("method").and_then(Value::as_str) == Some("textDocument/didOpen")
            })
            .filter_map(|message| {
                message
                    .get("params")?
                    .get("textDocument")?
                    .get("uri")?
                    .as_str()
                    .map(ToString::to_string)
            })
            .collect();
        assert_eq!(
            opened_uris,
            vec![first_uri.to_string(), second_uri.to_string()]
        );
        let snapshot = harness.snapshot();
        assert_eq!(snapshot.open_documents[first_uri].version, 1);
        assert_eq!(snapshot.open_documents[second_uri].version, 1);
    }

    /// Criterion 4: a crash fails pending operations with `serverExited`.
    #[test]
    fn a_crash_fails_every_pending_operation_once_with_server_exited() {
        let mut harness = Harness::ready();
        let uri = "file:///workspace/main.go";
        harness.sync(uri, "package main");
        let hover = harness.request(LspSemanticOperation::Hover, uri);
        let definition = harness.request(LspSemanticOperation::Definition, uri);

        harness.server.exit(Some(134));
        harness.await_state(LspLifecycleState::Failed);

        let failures: Vec<_> = harness
            .events
            .iter()
            .filter(|event| event.kind == "requestCompleted")
            .collect();
        assert_eq!(
            failures.len(),
            2,
            "each pending operation must fail exactly once"
        );
        for event in failures {
            let error = event.error.as_ref().expect("a crash cannot yield a result");
            assert_eq!(error.code, "serverExited");
            assert_eq!(error.process_exit_code, Some(134));
        }
        let completed: Vec<_> = harness
            .events
            .iter()
            .filter_map(|event| event.operation_id.clone())
            .collect();
        assert!(completed.contains(&hover) && completed.contains(&definition));
        assert!(harness.snapshot().pending_operation_ids.is_empty());
    }

    /// Criterion 5: a request deadline removes the pending request.
    /// Criterion 6: a late response after that timeout is ignored.
    #[test]
    fn a_timed_out_request_is_removed_cancelled_and_deaf_to_its_late_response() {
        let mut harness = Harness::start(|request| {
            request.request_timeout_milliseconds = 30;
        });
        harness.server.complete_initialize(ready_capabilities());
        harness.await_state(LspLifecycleState::Ready);
        let uri = "file:///workspace/main.go";
        harness.sync(uri, "package main");
        let operation = harness.request(LspSemanticOperation::Hover, uri);
        let request_id = harness
            .server
            .await_request("textDocument/hover")
            .expect("the hover request should reach the server");

        let timeout = harness
            .await_event(|event| {
                event
                    .error
                    .as_ref()
                    .is_some_and(|error| error.code == "requestTimeout")
            })
            .clone();
        assert_eq!(timeout.operation_id.as_deref(), Some(operation.as_str()));
        assert!(harness.snapshot().pending_operation_ids.is_empty());
        // The completion event is queued before the cancellation is written, so
        // the wire assertion has to wait for the write rather than assume it.
        assert!(
            harness.server.await_notification("$/cancelRequest"),
            "a timed-out request must be cancelled on the wire"
        );

        // The server answers anyway. Nothing may reach the application: the
        // operation has already been completed with its timeout error.
        harness.server.send(json!({
            "jsonrpc": "2.0",
            "id": request_id,
            "result": { "contents": "too late" }
        }));
        thread::sleep(Duration::from_millis(50));
        harness.poll();
        let completions = harness
            .events
            .iter()
            .filter(|event| event.operation_id.as_deref() == Some(operation.as_str()))
            .count();
        assert_eq!(
            completions, 1,
            "a late response must not complete the operation a second time"
        );
    }

    /// Criterion 7: responses from an old session cannot affect a restarted one.
    #[test]
    fn a_restarted_session_ignores_the_previous_session_s_responses() {
        // The first session is taken to Ready and then torn down. Its hover
        // request id is recorded first, because every session numbers its
        // requests from one: an id alone cannot tell two sessions apart, so only
        // per-session pending state can reject a foreign response.
        let mut first = Harness::ready();
        let uri = "file:///workspace/main.go";
        first.sync(uri, "package main");
        first.request(LspSemanticOperation::Hover, uri);
        let stale_id = first
            .server
            .await_request("textDocument/hover")
            .expect("the hover request should reach the server");
        first.server.exit(Some(0));
        first.await_state(LspLifecycleState::Failed);
        first.engine.destroy(&first.session_id).unwrap();

        let mut restarted = Harness::ready();
        restarted.sync(uri, "package main");
        let operation = restarted.request(LspSemanticOperation::Hover, uri);
        assert_eq!(
            restarted
                .server
                .await_request("textDocument/hover")
                .as_deref(),
            Some(stale_id.as_str()),
            "the restarted session must reuse the id, or this proves nothing"
        );

        // Delivered to the new session, the id does match a pending request, so
        // isolation cannot rest on ids. It rests on the process: the old
        // session's reader thread is gone with its process, so its responses
        // have no path into the new session at all.
        let before = restarted.snapshot();
        first.server.send(json!({
            "jsonrpc": "2.0",
            "id": stale_id,
            "result": { "contents": "from the dead session" }
        }));
        thread::sleep(Duration::from_millis(50));
        restarted.poll();
        assert_eq!(
            restarted.snapshot().pending_operation_ids,
            before.pending_operation_ids,
            "the old session's response must not complete the new session's request"
        );
        assert!(
            !restarted
                .events
                .iter()
                .any(|event| event.kind == "requestCompleted"),
            "no operation may complete from a foreign session's traffic"
        );

        // The new session's own response still lands, so the isolation above is
        // not merely a dead session.
        restarted.server.send(json!({
            "jsonrpc": "2.0",
            "id": stale_id,
            "result": { "contents": "from the live session" }
        }));
        let completion = restarted
            .await_event(|event| event.kind == "requestCompleted")
            .clone();
        assert_eq!(completion.operation_id.as_deref(), Some(operation.as_str()));
        assert_eq!(
            completion
                .result
                .as_ref()
                .and_then(|result| result.get("hover")?.get("contents"))
                .and_then(Value::as_str),
            Some("from the live session")
        );
    }

    /// Provider adaptation has to reach the process boundary, not just the
    /// adapter: the arguments a Windows launcher receives are the ones asserted
    /// here.
    #[test]
    fn the_launched_process_receives_the_adapted_provider_arguments() {
        let server = ScriptedServer::new();
        let engine = LspEngine::with_launcher(server.launcher());
        let cache = std::env::temp_dir().join("lithe-core-engine-tests");
        let mut request = start_request(&server);
        request.provider_id = "java".to_string();
        request.arguments = vec!["-data".to_string(), "/stale/data".to_string()];
        request.runtime_executable_path = Some("/opt/jdk/bin/java".to_string());
        request.cache_directory = Some(cache.to_string_lossy().into_owned());
        engine
            .start_server(request)
            .expect("the server should start");

        let spec = server
            .launched_spec()
            .expect("starting a server must launch a process");
        assert_eq!(spec.executable, "/usr/bin/scripted-server");
        assert_eq!(spec.working_directory, "/workspace");
        assert!(
            !spec
                .arguments
                .iter()
                .any(|argument| argument == "/stale/data"),
            "a caller-supplied -data must be replaced, not appended: {:?}",
            spec.arguments
        );
        assert_eq!(
            spec.arguments
                .iter()
                .position(|argument| argument == "--java-executable")
                .map(|index| spec.arguments[index + 1].as_str()),
            Some("/opt/jdk/bin/java")
        );
        let data = spec
            .arguments
            .iter()
            .position(|argument| argument == "-data")
            .map(|index| spec.arguments[index + 1].clone())
            .expect("JDT requires a data directory");
        assert!(Path::new(&data).starts_with(&cache));
        assert!(
            Path::new(&data).is_dir(),
            "the data directory must exist before the server starts"
        );
        let _ = std::fs::remove_dir_all(&cache);
    }

    /// A write that fails mid-session is a transport failure, not a silent drop.
    #[test]
    fn a_broken_stdin_fails_the_session_and_stops_writing() {
        let mut harness = Harness::ready();
        let written = harness.server.written_bytes().len();
        harness.server.break_input();
        let error = harness
            .session()
            .sync_document(SyncDocumentRequest {
                session_id: harness.session_id.clone(),
                uri: "file:///workspace/main.go".to_string(),
                language_id: "go".to_string(),
                text: "package main".to_string(),
                content_changes: Vec::new(),
            })
            .expect_err("a broken pipe must surface to the caller");
        assert!(matches!(error.code, ErrorCode::ProcessFailed));

        harness.await_state(LspLifecycleState::Failed);
        let failure = harness
            .events
            .iter()
            .find_map(|event| event.error.as_ref())
            .expect("the failure should be reported as a runtime error");
        assert_eq!(failure.code, "transportFailed");
        assert_eq!(
            harness.server.written_bytes().len(),
            written,
            "nothing may be written after the pipe breaks"
        );
    }

    /// The stopped session's own late response is dropped rather than acted on,
    /// which is the same rule seen from the other side of a restart.
    #[test]
    fn a_response_to_an_already_failed_session_is_logged_and_dropped() {
        let mut harness = Harness::ready();
        let uri = "file:///workspace/main.go";
        harness.sync(uri, "package main");
        harness.request(LspSemanticOperation::Hover, uri);
        let request_id = harness
            .server
            .await_request("textDocument/hover")
            .expect("the hover request should reach the server");

        harness.server.exit(Some(1));
        harness.await_state(LspLifecycleState::Failed);
        let completions = harness
            .events
            .iter()
            .filter(|event| event.kind == "requestCompleted")
            .count();
        assert_eq!(completions, 1, "the crash already completed the operation");

        harness.server.send(json!({
            "jsonrpc": "2.0",
            "id": request_id,
            "result": { "contents": "unreachable" }
        }));
        thread::sleep(Duration::from_millis(50));
        harness.poll();
        assert_eq!(
            harness
                .events
                .iter()
                .filter(|event| event.kind == "requestCompleted")
                .count(),
            completions,
            "a response after the terminal state must not complete anything"
        );
        assert_eq!(harness.snapshot().state, LspLifecycleState::Failed);
    }

    /// Criterion 8: diagnostics for a stale document version are ignored.
    /// Criterion 9: closing a document clears document and diagnostic state.
    #[test]
    fn diagnostics_follow_the_current_document_version_and_clear_on_close() {
        let mut harness = Harness::ready();
        let uri = "file:///workspace/main.go";
        harness.sync(uri, "package main");
        harness.sync(uri, "package main\nfunc main() {}");

        harness.server.send(json!({
            "jsonrpc": "2.0",
            "method": "textDocument/publishDiagnostics",
            "params": {
                "uri": uri,
                "version": 2,
                "diagnostics": [{
                    "range": {
                        "start": { "line": 1, "character": 0 },
                        "end": { "line": 1, "character": 4 }
                    },
                    "severity": 1,
                    "message": "current"
                }]
            }
        }));
        harness.await_event(|event| {
            event.kind == "diagnostics"
                && event
                    .diagnostics
                    .as_ref()
                    .is_some_and(|list| list.len() == 1)
        });
        assert_eq!(harness.snapshot().diagnostic_versions[uri], 2);

        // Version 1 is behind the open document, so it cannot replace version 2.
        harness.server.send(json!({
            "jsonrpc": "2.0",
            "method": "textDocument/publishDiagnostics",
            "params": { "uri": uri, "version": 1, "diagnostics": [] }
        }));
        thread::sleep(Duration::from_millis(50));
        harness.poll();
        assert_eq!(
            harness.snapshot().diagnostic_versions[uri],
            2,
            "a stale version must not clear current diagnostics"
        );

        harness.session().close_document(uri).unwrap();
        let snapshot = harness.snapshot();
        assert!(!snapshot.open_documents.contains_key(uri));
        assert!(!snapshot.diagnostic_versions.contains_key(uri));
        assert!(
            harness.notification("textDocument/didClose").is_some(),
            "the server must be told the document closed"
        );
        // Clearing is published so the editor drops its markers, rather than
        // leaving them until the next unrelated publish.
        let cleared = harness
            .poll()
            .iter()
            .rev()
            .find(|event| event.kind == "diagnostics" && event.uri.as_deref() == Some(uri));
        assert_eq!(
            cleared
                .and_then(|event| event.diagnostics.as_ref())
                .map(Vec::len),
            Some(0)
        );
    }

    /// Criterion 10: shutdown sends exit after the response, and a shutdown that
    /// is never answered force-terminates.
    #[test]
    fn shutdown_sends_exit_after_the_response_and_force_terminates_on_timeout() {
        let mut harness = Harness::ready();
        harness.session().stop().unwrap();
        let shutdown_id = harness
            .server
            .await_request("shutdown")
            .expect("stop should request shutdown");
        assert!(
            harness.notification("exit").is_none(),
            "exit must not precede the shutdown response"
        );

        harness.server.send(json!({
            "jsonrpc": "2.0",
            "id": shutdown_id,
            "result": null
        }));
        assert!(
            harness.server.await_notification("exit"),
            "exit must follow the shutdown response"
        );
        harness.server.exit(Some(0));
        harness.await_state(LspLifecycleState::Stopped);

        let mut silent = Harness::start(|request| {
            request.shutdown_timeout_milliseconds = 30;
        });
        silent.server.complete_initialize(ready_capabilities());
        silent.await_state(LspLifecycleState::Ready);
        silent.session().stop().unwrap();
        silent
            .server
            .await_request("shutdown")
            .expect("stop should request shutdown");
        // No response ever arrives, so the deadline must kill the process
        // instead of leaving the session stuck in Stopping.
        silent.await_state(LspLifecycleState::Stopped);
        silent.await_event(|event| {
            event.kind == "log"
                && event
                    .message
                    .as_deref()
                    .is_some_and(|message| message.contains("shutdown timed out"))
        });
    }

    /// Criterion 11: a malformed `Content-Length` is a transport failure.
    #[test]
    fn a_malformed_content_length_header_fails_the_session_in_transport() {
        let mut harness = Harness::ready();
        harness.server.send_raw(b"Content-Length: banana\r\n\r\n{}");
        harness.await_state(LspLifecycleState::Failed);

        let failure = harness
            .events
            .iter()
            .find_map(|event| event.error.as_ref())
            .expect("bad framing should be reported as a runtime error");
        assert_eq!(failure.code, "transportFailed");
        assert_eq!(failure.stage, "transport");
    }

    /// Criterion 12: a partial frame is retained until it completes.
    /// Criterion 13: consecutive frames are handled in order.
    #[test]
    fn partial_frames_are_buffered_and_consecutive_frames_arrive_in_order() {
        let mut harness = Harness::ready();
        let uri = "file:///workspace/main.go";
        harness.sync(uri, "package main");

        let split = |uri: &str, message: &str| {
            let body = json!({
                "jsonrpc": "2.0",
                "method": "textDocument/publishDiagnostics",
                "params": {
                    "uri": uri,
                    "version": 1,
                    "diagnostics": [{
                        "range": {
                            "start": { "line": 0, "character": 0 },
                            "end": { "line": 0, "character": 1 }
                        },
                        "severity": 1,
                        "message": message
                    }]
                }
            })
            .to_string();
            format!("Content-Length: {}\r\n\r\n{body}", body.len())
        };

        let first = split(uri, "first");
        let boundary = first.len() - 12;
        harness.server.send_raw(first[..boundary].as_bytes());
        thread::sleep(Duration::from_millis(40));
        harness.poll();
        assert!(
            !harness
                .events
                .iter()
                .any(|event| event.kind == "diagnostics"),
            "an incomplete frame must not be delivered"
        );

        // The tail of the first frame and a whole second frame arrive together,
        // which is exactly how a stream coalesces writes.
        harness
            .server
            .send_raw(format!("{}{}", &first[boundary..], split(uri, "second")).as_bytes());
        harness.await_event(|event| {
            event
                .diagnostics
                .as_ref()
                .and_then(|list| list.first())
                .is_some_and(|diagnostic| diagnostic.message == "second")
        });
        let delivered: Vec<_> = harness
            .events
            .iter()
            .filter(|event| event.kind == "diagnostics")
            .filter_map(|event| event.diagnostics.as_ref())
            .filter_map(|list| list.first())
            .map(|diagnostic| diagnostic.message.clone())
            .collect();
        assert_eq!(delivered, vec!["first".to_string(), "second".to_string()]);
        assert_eq!(harness.snapshot().state, LspLifecycleState::Ready);
    }

    /// Criterion 14: dynamic registration and unregistration change availability.
    #[test]
    fn dynamic_capability_registration_and_unregistration_change_availability() {
        let mut harness = Harness::start(|_| {});
        // Formatting is absent from the static capabilities, so it can only
        // become available through dynamic registration.
        harness
            .server
            .complete_initialize(json!({ "hoverProvider": true }));
        harness.await_state(LspLifecycleState::Ready);
        let uri = "file:///workspace/main.go";
        harness.sync(uri, "package main");
        assert!(harness
            .session()
            .request(
                SemanticRequest {
                    session_id: harness.session_id.clone(),
                    operation_id: Some("op-formatting".to_string()),
                    operation: LspSemanticOperation::Formatting,
                    uri: Some(uri.to_string()),
                    virtual_uri: None,
                    position: None,
                    new_name: None,
                    range: None,
                    diagnostics: Vec::new(),
                    completion_item: None,
                    code_action: None,
                    command: None,
                },
                "op-formatting".to_string(),
            )
            .is_err());

        harness.server.send(json!({
            "jsonrpc": "2.0",
            "id": "registration-1",
            "method": "client/registerCapability",
            "params": {
                "registrations": [{
                    "id": "formatting-1",
                    "method": "textDocument/formatting",
                    "registerOptions": {}
                }]
            }
        }));
        let registered = harness
            .await_event(|event| {
                event
                    .capabilities
                    .as_ref()
                    .is_some_and(|names| names.iter().any(|name| name == "formatting"))
            })
            .clone();
        assert_eq!(registered.kind, "featuresChanged");

        harness.server.send(json!({
            "jsonrpc": "2.0",
            "id": "registration-2",
            "method": "client/unregisterCapability",
            "params": {
                "unregisterations": [{
                    "id": "formatting-1",
                    "method": "textDocument/formatting"
                }]
            }
        }));
        // The initialize handshake also emitted a formatting-free feature set, so
        // the withdrawal is only identifiable by coming after the registration.
        let registered_at = registered.sequence;
        harness.await_event(|event| {
            event.kind == "featuresChanged"
                && event.sequence > registered_at
                && event
                    .capabilities
                    .as_ref()
                    .is_some_and(|names| !names.iter().any(|name| name == "formatting"))
        });
        assert!(
            harness
                .session()
                .request(
                    SemanticRequest {
                        session_id: harness.session_id.clone(),
                        operation_id: Some("op-formatting-2".to_string()),
                        operation: LspSemanticOperation::Formatting,
                        uri: Some(uri.to_string()),
                        virtual_uri: None,
                        position: None,
                        new_name: None,
                        range: None,
                        diagnostics: Vec::new(),
                        completion_item: None,
                        code_action: None,
                        command: None,
                    },
                    "op-formatting-2".to_string(),
                )
                .is_err(),
            "an unregistered capability must stop being offered"
        );
    }

    /// Criterion 15: replacing the workspace stops the old root and clears it.
    #[test]
    fn replacing_the_workspace_stops_the_old_root_and_clears_its_state() {
        let old_server = ScriptedServer::new();
        let engine = LspEngine::with_launcher(old_server.launcher());
        let old = engine.start_server(start_request(&old_server)).unwrap();
        old_server.complete_initialize(ready_capabilities());
        let old_session = engine.session(&old.session_id).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline
            && old_session.snapshot().unwrap().state != LspLifecycleState::Ready
        {
            thread::sleep(Duration::from_millis(2));
        }
        let uri = "file:///workspace/main.go";
        old_session
            .sync_document(SyncDocumentRequest {
                session_id: old.session_id.clone(),
                uri: uri.to_string(),
                language_id: "go".to_string(),
                text: "package main".to_string(),
                content_changes: Vec::new(),
            })
            .unwrap();
        old_server.send(json!({
            "jsonrpc": "2.0",
            "method": "textDocument/publishDiagnostics",
            "params": {
                "uri": uri,
                "version": 1,
                "diagnostics": [{
                    "range": {
                        "start": { "line": 0, "character": 0 },
                        "end": { "line": 0, "character": 1 }
                    },
                    "severity": 1,
                    "message": "old root"
                }]
            }
        }));
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline
            && !old_session
                .snapshot()
                .unwrap()
                .diagnostic_versions
                .contains_key(uri)
        {
            thread::sleep(Duration::from_millis(2));
        }

        old_session.stop().unwrap();
        let shutdown = old_server.await_request("shutdown").unwrap();
        old_server.send(json!({ "jsonrpc": "2.0", "id": shutdown, "result": null }));
        old_server.exit(Some(0));
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline
            && old_session.snapshot().unwrap().state != LspLifecycleState::Stopped
        {
            thread::sleep(Duration::from_millis(2));
        }

        let stopped = old_session.snapshot().unwrap();
        assert_eq!(stopped.root_uri, "file:///workspace");
        assert_eq!(stopped.state, LspLifecycleState::Stopped);
        assert!(stopped.open_documents.is_empty());
        assert!(stopped.diagnostic_versions.is_empty());
        assert!(stopped.pending_operation_ids.is_empty());
        assert!(
            old_server.input_was_closed(),
            "the old root's stdin must be released"
        );

        // Only a stopped session may be destroyed, and a destroyed one is
        // unreachable, so the replacement cannot inherit any of its state.
        engine.destroy(&old.session_id).unwrap();
        assert!(engine.session(&old.session_id).is_err());
        assert!(old_session
            .sync_document(SyncDocumentRequest {
                session_id: old.session_id.clone(),
                uri: uri.to_string(),
                language_id: "go".to_string(),
                text: "package main".to_string(),
                content_changes: Vec::new(),
            })
            .is_err());
    }

    #[test]
    fn semantic_operations_are_protocol_methods_but_never_expose_request_ids() {
        assert_eq!(
            semantic_method(LspSemanticOperation::Definition),
            "textDocument/definition"
        );
        assert_eq!(
            semantic_capability(LspSemanticOperation::VirtualDocument),
            Some("executeCommand")
        );
    }

    #[test]
    fn workspace_execute_command_does_not_require_an_open_document() {
        let mut harness = Harness::start(|_| {});
        harness.server.complete_initialize(json!({
            "executeCommandProvider": { "commands": ["source.fix"] }
        }));
        harness.await_state(LspLifecycleState::Ready);
        let operation_id = harness.engine.next_operation_id();

        harness
            .session()
            .request(
                SemanticRequest {
                    session_id: harness.session_id.clone(),
                    operation_id: Some(operation_id.clone()),
                    operation: LspSemanticOperation::ExecuteCommand,
                    uri: None,
                    virtual_uri: None,
                    position: None,
                    new_name: None,
                    range: None,
                    diagnostics: Vec::new(),
                    completion_item: None,
                    code_action: None,
                    command: Some(json!({
                        "title": "Apply fix",
                        "command": "source.fix",
                        "arguments": []
                    })),
                },
                operation_id,
            )
            .expect("workspace commands should not be gated on an open document");

        let request = harness
            .server
            .messages()
            .into_iter()
            .find(|message| message["method"] == "workspace/executeCommand")
            .expect("the command should reach the language server");
        assert_eq!(request["params"]["command"], "source.fix");
        assert!(request["params"].get("textDocument").is_none());
    }

    #[test]
    fn java_virtual_document_returns_decompiled_text_without_an_open_document() {
        let mut harness = Harness::start(|request| {
            request.provider_id = "java".to_string();
            request.cache_directory = Some("/tmp/lithe-lsp-engine-tests".to_string());
        });
        harness.server.complete_initialize(json!({
            "executeCommandProvider": { "commands": ["java.decompile"] }
        }));
        harness.await_state(LspLifecycleState::Ready);
        let operation_id = harness.engine.next_operation_id();
        let virtual_uri = "jdt://contents/java.base/java/lang/String.class";

        harness
            .session()
            .request(
                SemanticRequest {
                    session_id: harness.session_id.clone(),
                    operation_id: Some(operation_id.clone()),
                    operation: LspSemanticOperation::VirtualDocument,
                    uri: None,
                    virtual_uri: Some(virtual_uri.to_string()),
                    position: None,
                    new_name: None,
                    range: None,
                    diagnostics: Vec::new(),
                    completion_item: None,
                    code_action: None,
                    command: None,
                },
                operation_id.clone(),
            )
            .expect("virtual documents should not require an open file");

        let request_id = harness
            .server
            .await_request("workspace/executeCommand")
            .expect("the decompile command should reach JDT LS");
        let request = harness
            .server
            .messages()
            .into_iter()
            .find(|message| message["id"] == request_id)
            .expect("the decompile request should be recorded");
        assert_eq!(request["params"]["command"], "java.decompile");
        assert_eq!(request["params"]["arguments"], json!([virtual_uri]));

        harness.server.send(json!({
            "jsonrpc": "2.0",
            "id": request_id,
            "result": "public final class String {}"
        }));
        let event = harness
            .await_event(|event| event.operation_id.as_deref() == Some(operation_id.as_str()))
            .clone();
        assert_eq!(
            event.result,
            Some(json!({
                "text": "public final class String {}"
            }))
        );
        assert!(event.error.is_none());
    }

    #[test]
    fn wait_events_returns_queued_events_without_waiting_the_timeout() {
        let harness = Harness::start(|_| {});
        let started = Instant::now();
        let events = harness
            .session()
            .wait_events(Duration::from_secs(2))
            .expect("waiting should succeed");
        assert!(
            !events.is_empty(),
            "starting a session should enqueue at least one lifecycle event"
        );
        assert!(
            started.elapsed() < Duration::from_millis(500),
            "queued events must not wait out the timeout"
        );
    }

    #[test]
    fn wait_events_times_out_with_an_empty_queue() {
        let mut harness = Harness::ready();
        harness.poll();
        let started = Instant::now();
        let events = harness
            .session()
            .wait_events(Duration::from_millis(40))
            .expect("waiting should succeed");
        assert!(events.is_empty());
        assert!(started.elapsed() >= Duration::from_millis(30));
    }

    #[test]
    fn wait_events_wakes_when_the_session_enqueues_a_lifecycle_event() {
        let mut harness = Harness::ready();
        harness.poll();
        let session = harness.session();
        let waiter = thread::spawn({
            let session = Arc::clone(&session);
            move || {
                session
                    .wait_events(Duration::from_secs(2))
                    .expect("waiting should succeed")
            }
        });
        thread::sleep(Duration::from_millis(30));
        session.stop().expect("the session should stop");
        let events = waiter.join().expect("the waiter thread should finish");
        assert!(
            events.iter().any(|event| event.kind == "stateChanged"),
            "stop should wake waiters with a lifecycle event, got {events:?}"
        );
    }

    #[test]
    fn java_runtime_is_derived_from_the_start_environment() {
        let environment = BTreeMap::from([("JAVA_HOME".to_string(), "/jdk".to_string())]);
        let path = java_executable_from_environment(&environment).unwrap();
        assert!(path.ends_with(if cfg!(windows) {
            "bin/java.exe"
        } else {
            "bin/java"
        }));
    }

    #[test]
    fn start_contract_rejects_missing_runtime_identity() {
        let request = StartServerRequest {
            provider_id: String::new(),
            executable_path: "/bin/server".to_string(),
            arguments: Vec::new(),
            environment: BTreeMap::new(),
            root_uri: "file:///workspace".to_string(),
            working_directory: "/workspace".to_string(),
            initialization_options: None,
            runtime_executable_path: None,
            cache_directory: None,
            initialize_timeout_milliseconds: 1,
            request_timeout_milliseconds: 1,
            shutdown_timeout_milliseconds: 1,
        };
        assert!(validate_start_request(&request).is_err());
    }
}
