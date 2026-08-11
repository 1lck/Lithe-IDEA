use super::{
    client_apply_server_message, client_change_document, client_close_document,
    client_feature_request_canonical, client_initialize, client_open_document, client_shutdown,
    frame_message, parse_server_messages, ClientApplyServerMessageRequest,
    ClientChangeDocumentRequest, ClientCloseDocumentRequest, ClientFeatureRequest,
    ClientInitializeRequest, ClientOpenDocumentRequest, ClientShutdownRequest, FrameMessageRequest,
    LspClientDiagnostic, LspClientDocument, LspClientState, LspPosition, LspRange,
    ParseServerMessagesRequest,
};
use crate::lsp::languages::jdt::{
    adapt_start, initialized_notification, virtual_source_resolve_params, workspace_configuration,
    JdtStartContext, ProviderLocation, WorkspaceConfigurationItem,
};
use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, VecDeque};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

const DEFAULT_INITIALIZE_TIMEOUT_MS: u64 = 10_000;
const DEFAULT_REQUEST_TIMEOUT_MS: u64 = 30_000;
const DEFAULT_SHUTDOWN_TIMEOUT_MS: u64 = 2_000;
const MONITOR_INTERVAL_MS: u64 = 10;

static ENGINE: OnceLock<LspEngine> = OnceLock::new();

#[derive(Debug, Clone, Copy, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum LspLifecycleState {
    Created,
    ProcessStarting,
    Initializing,
    Ready,
    Stopping,
    Stopped,
    Failed,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
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
pub struct StartServerResponse {
    pub session_id: String,
    pub state: LspLifecycleState,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SessionRequest {
    pub session_id: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SyncDocumentRequest {
    pub session_id: String,
    pub uri: String,
    pub language_id: String,
    pub text: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CloseDocumentRequest {
    pub session_id: String,
    pub uri: String,
}

#[derive(Debug, Clone, Copy, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum LspSemanticOperation {
    Completion,
    Hover,
    Definition,
    Declaration,
    TypeDefinition,
    References,
    Implementation,
    Rename,
    Formatting,
    CodeActions,
    ResolveCompletion,
    ResolveCodeAction,
    ExecuteCommand,
    InlayHints,
    FoldingRanges,
    CodeLens,
    VirtualDocument,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
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
pub struct OperationResponse {
    pub operation_id: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CancelOperationRequest {
    pub session_id: String,
    pub operation_id: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PollEventsResponse {
    pub events: Vec<LspRuntimeEvent>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LspRuntimeEvent {
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
pub struct LspServerInfo {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LspRuntimeError {
    pub code: String,
    pub provider_id: String,
    pub session_id: String,
    pub stage: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub method: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub document_uri: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub underlying_message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub process_exit_code: Option<i32>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineSnapshot {
    pub session_id: String,
    pub provider_id: String,
    pub state: LspLifecycleState,
    pub initialized: bool,
    pub open_documents: BTreeMap<String, LspClientDocument>,
    pub pending_operation_ids: Vec<String>,
    pub diagnostic_versions: BTreeMap<String, i64>,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
enum PendingKind {
    Initialize,
    Feature,
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
    root_uri: String,
    state: Mutex<SessionState>,
    stdin: Mutex<Option<ChildStdin>>,
    child: Mutex<Child>,
    active: AtomicBool,
}

struct LspEngine {
    next_session_id: AtomicU64,
    next_operation_id: AtomicU64,
    sessions: Mutex<BTreeMap<String, Arc<RuntimeSession>>>,
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

pub fn start_server(request: StartServerRequest) -> Result<StartServerResponse, CoreError> {
    engine().start_server(request)
}

pub fn stop_server(request: SessionRequest) -> Result<(), CoreError> {
    engine().session(&request.session_id)?.stop()
}

pub fn sync_document(request: SyncDocumentRequest) -> Result<(), CoreError> {
    engine()
        .session(&request.session_id)?
        .sync_document(request)
}

pub fn close_document(request: CloseDocumentRequest) -> Result<(), CoreError> {
    engine()
        .session(&request.session_id)?
        .close_document(&request.uri)
}

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

pub fn cancel_operation(request: CancelOperationRequest) -> Result<(), CoreError> {
    engine()
        .session(&request.session_id)?
        .cancel_operation(&request.operation_id)
}

pub fn poll_events(request: SessionRequest) -> Result<PollEventsResponse, CoreError> {
    Ok(PollEventsResponse {
        events: engine().session(&request.session_id)?.poll_events()?,
    })
}

pub fn clear_diagnostics(request: SessionRequest) -> Result<(), CoreError> {
    engine().session(&request.session_id)?.clear_diagnostics()
}

pub fn snapshot(request: SessionRequest) -> Result<EngineSnapshot, CoreError> {
    engine().session(&request.session_id)?.snapshot()
}

pub fn destroy_server(request: SessionRequest) -> Result<(), CoreError> {
    engine().destroy(&request.session_id)
}

fn engine() -> &'static LspEngine {
    ENGINE.get_or_init(LspEngine::new)
}

impl LspEngine {
    fn new() -> Self {
        Self {
            next_session_id: AtomicU64::new(1),
            next_operation_id: AtomicU64::new(1),
            sessions: Mutex::new(BTreeMap::new()),
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

        let mut command = Command::new(&request.executable_path);
        command
            .args(&adaptation.arguments)
            .current_dir(&workspace_root)
            .envs(&request.environment)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let mut child = command.spawn().map_err(|error| {
            CoreError::new(
                ErrorCode::ProcessStartFailed,
                "Could not start the language-server process.",
            )
            .with_details(error.to_string())
        })?;
        let stdin = child.stdin.take().ok_or_else(|| {
            CoreError::new(
                ErrorCode::ProcessStartFailed,
                "Language-server stdin was unavailable.",
            )
        })?;
        let stdout = child.stdout.take().ok_or_else(|| {
            CoreError::new(
                ErrorCode::ProcessStartFailed,
                "Language-server stdout was unavailable.",
            )
        })?;
        let stderr = child.stderr.take().ok_or_else(|| {
            CoreError::new(
                ErrorCode::ProcessStartFailed,
                "Language-server stderr was unavailable.",
            )
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
        let session = Arc::new(RuntimeSession {
            id: session_id.clone(),
            provider_id: request.provider_id,
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
            stdin: Mutex::new(Some(stdin)),
            child: Mutex::new(child),
            active: AtomicBool::new(true),
        });
        session.transition(LspLifecycleState::Created, None)?;
        session.transition(LspLifecycleState::ProcessStarting, None)?;
        session.transition(LspLifecycleState::Initializing, None)?;

        self.lock_sessions()?
            .insert(session_id.clone(), session.clone());
        session.spawn_readers(stdout, stderr);
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

            let response = if request.operation == LspSemanticOperation::VirtualDocument {
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
            } else {
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
            };
            let request_id = (response.state.next_request_id - 1).to_string();
            let now = Instant::now();
            let pending = PendingRequest {
                kind: PendingKind::Feature,
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
                Some(&request_id),
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

    fn clear_diagnostics(&self) -> Result<(), CoreError> {
        let mut state = self.lock_state()?;
        clear_runtime_diagnostics(self, &mut state);
        Ok(())
    }

    fn poll_events(&self) -> Result<Vec<LspRuntimeEvent>, CoreError> {
        let mut state = self.lock_state()?;
        Ok(state.events.drain(..).collect())
    }

    fn snapshot(&self) -> Result<EngineSnapshot, CoreError> {
        let state = self.lock_state()?;
        Ok(EngineSnapshot {
            session_id: self.id.clone(),
            provider_id: self.provider_id.clone(),
            state: state.lifecycle,
            initialized: state.client.initialized,
            open_documents: state.client.open_documents.clone(),
            pending_operation_ids: state.request_by_operation.keys().cloned().collect(),
            diagnostic_versions: state.client.diagnostic_versions.clone(),
        })
    }

    fn spawn_readers(
        self: &Arc<Self>,
        mut stdout: std::process::ChildStdout,
        mut stderr: std::process::ChildStderr,
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
                let exit = session
                    .child
                    .lock()
                    .ok()
                    .and_then(|mut child| child.try_wait().ok().flatten());
                if let Some(status) = exit {
                    session.handle_process_exit(status.code());
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
                                        response_id.as_deref(),
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
                    pending.kind == PendingKind::Feature && now >= pending.deadline
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
                        Some(&request_id),
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
        if let Ok(mut input) = self.stdin.lock() {
            *input = None;
        }
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
                    Some(request_id),
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
        if messages.is_empty() {
            return Ok(());
        }
        let mut input = self.stdin.lock().map_err(|_| {
            CoreError::new(
                ErrorCode::Unknown,
                "Language-server stdin lock was poisoned.",
            )
        })?;
        let input = input.as_mut().ok_or_else(|| {
            CoreError::new(ErrorCode::ProcessFailed, "Language-server stdin is closed.")
        })?;
        for message in messages {
            let frame = frame_message(FrameMessageRequest { message })?.frame;
            input.write_all(frame.as_bytes()).map_err(|error| {
                CoreError::new(
                    ErrorCode::ProcessFailed,
                    "Could not write to language-server stdin.",
                )
                .with_details(error.to_string())
            })?;
        }
        input.flush().map_err(|error| {
            CoreError::new(
                ErrorCode::ProcessFailed,
                "Could not flush language-server stdin.",
            )
            .with_details(error.to_string())
        })
    }

    fn kill_process(&self) {
        if let Ok(mut child) = self.child.lock() {
            let _ = child.kill();
        }
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

fn transition_locked(
    session: &RuntimeSession,
    state: &mut SessionState,
    lifecycle: LspLifecycleState,
    error: Option<LspRuntimeError>,
) {
    state.lifecycle = lifecycle;
    let sequence = take_sequence(state);
    state.events.push_back(LspRuntimeEvent {
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
    });
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
    state.events.push_back(LspRuntimeEvent {
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
    });
}

fn push_diagnostics_event(
    session: &RuntimeSession,
    state: &mut SessionState,
    uri: &str,
    version: Option<i64>,
    diagnostics: Vec<LspClientDiagnostic>,
) {
    let sequence = take_sequence(state);
    state.events.push_back(LspRuntimeEvent {
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
    });
}

fn push_features_event(
    session: &RuntimeSession,
    state: &mut SessionState,
    capabilities: Vec<String>,
) {
    let sequence = take_sequence(state);
    state.events.push_back(LspRuntimeEvent {
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
    });
}

fn push_server_info_event(session: &RuntimeSession, state: &mut SessionState, info: LspServerInfo) {
    let sequence = take_sequence(state);
    state.events.push_back(LspRuntimeEvent {
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
    });
}

fn push_log_event(
    session: &RuntimeSession,
    state: &mut SessionState,
    level: &str,
    message: &str,
    detail: Option<String>,
) {
    let sequence = take_sequence(state);
    state.events.push_back(LspRuntimeEvent {
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
    });
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
    request_id: Option<&str>,
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
        request_id: request_id.map(ToString::to_string),
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
        .filter(|(_, pending)| pending.kind == PendingKind::Feature)
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
                Some(&request_id),
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
    use super::*;

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
