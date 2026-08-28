//! Stateful language-server sessions coordinating client state and child processes.

use super::process::{LspProcessHandle, LspProcessLauncher, LspProcessSpec, SystemProcessLauncher};
use super::{
    client_apply_server_message, client_change_document, client_close_document,
    client_feature_request_canonical, client_initialize, client_open_document,
    client_provider_document_feature_request_canonical, client_shutdown, frame_message,
    parse_server_messages, ClientApplyServerMessageRequest, ClientChangeDocumentRequest,
    ClientCloseDocumentRequest, ClientFeatureRequest, ClientInitializeRequest,
    ClientOpenDocumentRequest, ClientShutdownRequest, FrameMessageRequest, LspClientDiagnostic,
    LspClientDocument, LspClientState, LspDocumentContentChange, LspPosition, LspRange,
    ParseServerMessagesRequest,
};
use crate::lsp::languages::jdt::{
    adapt_initialization_options, adapt_start, import_progress, initialized_notification,
    is_structured_import_notification, is_virtual_source_uri, normalize_location, readiness_signal,
    virtual_source_content, virtual_source_resolve_params, waits_for_service_ready,
    workspace_configuration, JdtDirectLaunchResources, JdtReadinessSignal, JdtStartContext,
    ProviderLocation, WorkspaceConfigurationItem,
};
use crate::lsp::languages::jdt_navigation::{JavaNavigationMarkerBatch, MAX_JAVA_NAVIGATION_TASKS};
use crate::lsp::languages::jdt_progress::JavaPreparationDiagnostics;
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
const DEFAULT_SERVICE_READY_IDLE_TIMEOUT_MS: u64 = 45_000;
const DEFAULT_SERVICE_READY_ABSOLUTE_TIMEOUT_MS: u64 = 10 * 60_000;
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
    /// Files discovered by the platform adapter for shell-free JDT LS startup.
    #[serde(default)]
    pub jdtls_launch_resources: Option<JdtlsLaunchResources>,
    #[serde(default)]
    pub cache_directory: Option<String>,
    /// Platform-computed digest of the workspace's build-system structure.
    /// Providers that keep durable per-workspace state (JDT LS) mix this into
    /// their state-directory name so a structurally changed workspace does not
    /// reuse a stale project model. See `JdtStartContext::workspace_fingerprint`.
    #[serde(default)]
    pub workspace_fingerprint: Option<String>,
    #[serde(default = "default_initialize_timeout")]
    pub initialize_timeout_milliseconds: u64,
    /// Maximum silence while waiting for a provider-specific readiness signal.
    #[serde(default = "default_service_ready_idle_timeout")]
    pub service_ready_idle_timeout_milliseconds: u64,
    /// Absolute safety cap for provider-specific preparation even while active.
    #[serde(default = "default_service_ready_absolute_timeout")]
    pub service_ready_absolute_timeout_milliseconds: u64,
    #[serde(default = "default_request_timeout")]
    pub request_timeout_milliseconds: u64,
    #[serde(default = "default_shutdown_timeout")]
    pub shutdown_timeout_milliseconds: u64,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// Platform-resolved files that let Rust launch JDT LS with bundled Java.
pub struct JdtlsLaunchResources {
    /// Equinox launcher selected deterministically from the JDT LS installation.
    pub launcher_jar_path: String,
    /// OS-specific Eclipse configuration directory for the current product.
    pub configuration_directory: String,
    /// Lombok agent shipped with the selected JDT LS installation.
    pub lombok_agent_path: String,
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

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Core-owned document synchronization state returned after an editor update.
pub struct SyncDocumentResponse {
    /// Monotonic version used by all subsequent LSP requests and diagnostics.
    pub document_version: i64,
    /// `false` when the submitted text was already synchronized.
    pub changed: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// Workspace file events forwarded through standard LSP watched-file semantics.
pub struct WorkspaceFilesChangedRequest {
    pub session_id: String,
    pub changes: Vec<WorkspaceFileChange>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// One absolute document URI and the filesystem transition observed by a host.
pub struct WorkspaceFileChange {
    pub uri: String,
    pub kind: WorkspaceFileChangeKind,
}

#[derive(Debug, Clone, Copy, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
/// LSP watched-file transition mapped to protocol event types 1, 2, and 3.
pub enum WorkspaceFileChangeKind {
    Created,
    Changed,
    Deleted,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// Requests semantic Java navigation markers for one synchronized document.
pub struct JavaNavigationMarkersRequest {
    pub session_id: String,
    #[serde(default)]
    pub operation_id: Option<String>,
    pub uri: String,
    #[serde(default)]
    pub document_version: Option<i64>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// Resolves one previously published Java marker at click time.
pub struct JavaResolveNavigationRequest {
    pub session_id: String,
    #[serde(default)]
    pub operation_id: Option<String>,
    pub uri: String,
    pub line: i64,
    pub utf16_column: i64,
    pub direction: String,
    pub relation: String,
    #[serde(default)]
    pub document_version: Option<i64>,
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
    /// JDT LS `java/findLinks` with the `superImplementation` relation.
    JavaSuperImplementation,
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
    /// CodeLens-derived Java gutter marker projection.
    JavaNavigationMarkers,
    /// One JDT LS CodeLens resolve step in a bounded marker batch.
    JavaNavigationMarkerResolve,
    /// Click-time Java parent or implementation resolution.
    JavaResolveNavigation,
    /// Shutdown handshake after which the engine sends `exit`.
    Shutdown,
}

#[derive(Debug, Clone)]
struct PendingRequest {
    kind: PendingKind,
    operation_id: Option<String>,
    method: String,
    document_uri: Option<String>,
    /// Document version observed when a presentation request was allocated.
    document_version: Option<i64>,
    created_at: Instant,
    deadline: Instant,
}

/// Latest completed marker projection for one synchronized document.
///
/// Only one version per URI is retained. This bounds memory while preventing
/// view refreshes from repeating the same multi-request JDT LS batch.
struct JavaNavigationMarkerCacheEntry {
    document_version: i64,
    markers: Vec<crate::protocol::JavaNavigationMarkerResponse>,
}

struct SessionState {
    lifecycle: LspLifecycleState,
    client: LspClientState,
    pending: BTreeMap<String, PendingRequest>,
    request_by_operation: BTreeMap<String, String>,
    java_navigation_marker_batches: BTreeMap<String, JavaNavigationMarkerBatch>,
    java_navigation_marker_cache: BTreeMap<String, JavaNavigationMarkerCacheEntry>,
    /// Latest workspace event per URI observed before protocol initialization.
    /// The engine owns and drains this queue exactly once after `initialized`.
    pending_workspace_file_changes: BTreeMap<String, WorkspaceFileChangeKind>,
    events: VecDeque<LspRuntimeEvent>,
    next_sequence: u64,
    initialize_deadline: Option<Instant>,
    service_ready_idle_timeout: Duration,
    service_ready_absolute_timeout: Duration,
    java_preparation: Option<JavaPreparationDiagnostics>,
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
    /// Serializes protocol-state commits with complete outbound message batches.
    /// Callers acquire this before `state` whenever an action can write to the
    /// server, preserving the same order in memory and on the wire.
    outbound_order: Mutex<()>,
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

fn default_service_ready_idle_timeout() -> u64 {
    DEFAULT_SERVICE_READY_IDLE_TIMEOUT_MS
}

fn default_service_ready_absolute_timeout() -> u64 {
    DEFAULT_SERVICE_READY_ABSOLUTE_TIMEOUT_MS
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
pub fn sync_document(request: SyncDocumentRequest) -> Result<SyncDocumentResponse, CoreError> {
    engine()
        .session(&request.session_id)?
        .sync_document(request)
}

/// Forwards external source and build-configuration changes without restarting
/// the server or invalidating its durable workspace state.
pub fn workspace_files_changed(request: WorkspaceFilesChangedRequest) -> Result<(), CoreError> {
    engine()
        .session(&request.session_id)?
        .workspace_files_changed(request.changes)
}

/// Queues one shared Java gutter marker request against the active LSP session.
pub fn java_navigation_markers(
    request: JavaNavigationMarkersRequest,
) -> Result<OperationResponse, CoreError> {
    let operation_id = request
        .operation_id
        .clone()
        .unwrap_or_else(|| engine().next_operation_id());
    let session = engine().session(&request.session_id)?;
    if session.complete_cached_java_navigation_markers(
        &operation_id,
        &request.uri,
        request.document_version,
    )? {
        return Ok(OperationResponse { operation_id });
    }
    session.request_with_kind(
        SemanticRequest {
            session_id: request.session_id,
            operation_id: Some(operation_id.clone()),
            operation: LspSemanticOperation::CodeLens,
            uri: Some(request.uri),
            virtual_uri: None,
            position: None,
            new_name: None,
            range: None,
            diagnostics: Vec::new(),
            completion_item: None,
            code_action: None,
            command: None,
        },
        operation_id.clone(),
        PendingKind::JavaNavigationMarkers,
        request.document_version,
    )?;
    Ok(OperationResponse { operation_id })
}

/// Queues one click-time Java parent or implementation lookup.
pub fn java_resolve_navigation(
    request: JavaResolveNavigationRequest,
) -> Result<OperationResponse, CoreError> {
    let operation_id = request
        .operation_id
        .clone()
        .unwrap_or_else(|| engine().next_operation_id());
    let operation = match request.direction.as_str() {
        "down" => LspSemanticOperation::Implementation,
        "up" => LspSemanticOperation::JavaSuperImplementation,
        _ => {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Java navigation direction must be up or down.",
            ))
        }
    };
    if !matches!(request.relation.as_str(), "interface" | "inheritance") {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Java navigation relation must be interface or inheritance.",
        ));
    }
    let session = engine().session(&request.session_id)?;
    session.request_with_kind(
        SemanticRequest {
            session_id: request.session_id,
            operation_id: Some(operation_id.clone()),
            operation,
            uri: Some(request.uri),
            virtual_uri: None,
            position: Some(LspPosition {
                line: request.line,
                utf16_column: request.utf16_column,
            }),
            new_name: None,
            range: None,
            diagnostics: Vec::new(),
            completion_item: None,
            code_action: None,
            command: None,
        },
        operation_id.clone(),
        PendingKind::JavaResolveNavigation,
        request.document_version,
    )?;
    Ok(OperationResponse { operation_id })
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
        let startup_started_at = Instant::now();
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
            direct_launch_resources: request.jdtls_launch_resources.as_ref().map(|resources| {
                JdtDirectLaunchResources {
                    launcher_jar_path: PathBuf::from(&resources.launcher_jar_path),
                    configuration_directory: PathBuf::from(&resources.configuration_directory),
                    lombok_agent_path: PathBuf::from(&resources.lombok_agent_path),
                }
            }),
            arguments: request.arguments.clone(),
            workspace_fingerprint: request.workspace_fingerprint.clone(),
        });
        let java_cache_disposition = adaptation.data_directory.as_ref().map(|directory| {
            if directory.join(".metadata").is_dir() {
                "reused"
            } else {
                "new"
            }
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
            executable: adaptation
                .executable
                .unwrap_or_else(|| PathBuf::from(&request.executable_path)),
            arguments: adaptation.arguments,
            working_directory: workspace_root,
            environment: request.environment,
        })?;
        let process_start_elapsed = startup_started_at.elapsed();

        let initialize_timeout = Duration::from_millis(request.initialize_timeout_milliseconds);
        let service_ready_idle_timeout =
            Duration::from_millis(request.service_ready_idle_timeout_milliseconds);
        let service_ready_absolute_timeout =
            Duration::from_millis(request.service_ready_absolute_timeout_milliseconds);
        let request_timeout = Duration::from_millis(request.request_timeout_milliseconds);
        let shutdown_timeout = Duration::from_millis(request.shutdown_timeout_milliseconds);
        let initialize = client_initialize(ClientInitializeRequest {
            state: LspClientState::default(),
            root_uri: request.root_uri.clone(),
            process_id: Some(std::process::id() as i64),
            initialization_options: adapt_initialization_options(
                &request.provider_id,
                request.initialization_options,
            ),
        })?;
        let request_id = (initialize.state.next_request_id - 1).to_string();
        let now = Instant::now();
        let process_id = process.handle.process_id();
        let java_preparation = java_cache_disposition.map(|cache_disposition| {
            JavaPreparationDiagnostics::new(
                startup_started_at,
                process_start_elapsed,
                cache_disposition,
                request.workspace_fingerprint.is_some(),
            )
        });
        let java_startup_detail = java_preparation
            .as_ref()
            .map(JavaPreparationDiagnostics::startup_detail);
        let session = Arc::new(RuntimeSession {
            id: session_id.clone(),
            provider_id: request.provider_id,
            #[cfg(test)]
            root_uri: request.root_uri,
            outbound_order: Mutex::new(()),
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
                        document_version: None,
                        created_at: now,
                        deadline: now + initialize_timeout,
                    },
                )]),
                request_by_operation: BTreeMap::new(),
                java_navigation_marker_batches: BTreeMap::new(),
                java_navigation_marker_cache: BTreeMap::new(),
                pending_workspace_file_changes: BTreeMap::new(),
                events: VecDeque::new(),
                next_sequence: 1,
                initialize_deadline: Some(now + initialize_timeout),
                service_ready_idle_timeout,
                service_ready_absolute_timeout,
                java_preparation,
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
        if let Some(detail) = java_startup_detail {
            session.log(
                "info",
                "Java language service process started",
                Some(detail),
            );
        }

        self.lock_sessions()?
            .insert(session_id.clone(), session.clone());
        session.spawn_readers(process.output, process.errors);
        session.spawn_monitor();
        let outbound_order = session.lock_outbound_order()?;
        if let Err(error) = session.send_messages(&outbound_order, initialize.messages) {
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
    fn workspace_files_changed(&self, changes: Vec<WorkspaceFileChange>) -> Result<(), CoreError> {
        if changes.is_empty() {
            return Ok(());
        }
        let mut normalized = BTreeMap::new();
        for change in changes {
            if !change.uri.contains("://") || change.uri.contains('\0') {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Workspace file changes require absolute document URIs.",
                )
                .with_details(change.uri));
            }
            // The last event for a URI represents its final filesystem state
            // and prevents a watcher burst from causing redundant imports.
            normalized.insert(change.uri, change.kind);
        }
        let outbound_order = self.lock_outbound_order()?;
        let message = {
            let mut state = self.lock_state()?;
            ensure_not_terminal(state.lifecycle)?;
            if !state.client.initialized
                || (waits_for_service_ready(&self.provider_id)
                    && state.lifecycle != LspLifecycleState::Ready)
            {
                state.pending_workspace_file_changes.extend(normalized);
                return Ok(());
            }
            workspace_file_changes_notification(normalized)
        };
        self.send_messages_or_fail(&outbound_order, vec![message], "workspaceFilesChanged")
    }

    fn sync_document(
        &self,
        request: SyncDocumentRequest,
    ) -> Result<SyncDocumentResponse, CoreError> {
        let uri = request.uri;
        let mut messages = Vec::new();
        let mut stale_cancellations = Vec::new();
        let document_version;
        let outbound_order = self.lock_outbound_order()?;
        {
            let mut state = self.lock_state()?;
            ensure_not_terminal(state.lifecycle)?;
            if let Some(document) = state.client.open_documents.get(&uri) {
                // Hosts commonly publish both a ranged edit and the resulting
                // full text. Repeating that full text must not create another
                // JDTLS reconciliation cycle or advance the semantic version.
                if request.content_changes.is_empty() && document.text == request.text {
                    return Ok(SyncDocumentResponse {
                        document_version: document.version.max(1),
                        changed: false,
                    });
                }
            }
            state.java_navigation_marker_cache.remove(&uri);
            // JDT LS associates working copies with the Java project model that
            // exists when `didOpen` arrives. Opening restored documents before
            // `ServiceReady` can permanently bind them to an incomplete Maven
            // model, so retain only their latest text until import finishes.
            let can_sync_on_wire = state.client.initialized
                && (!waits_for_service_ready(&self.provider_id)
                    || state.lifecycle == LspLifecycleState::Ready);
            if can_sync_on_wire {
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
                document_version = state
                    .client
                    .open_documents
                    .get(&uri)
                    .map(|document| document.version)
                    .unwrap_or_default();
                stale_cancellations =
                    cancel_stale_document_requests_locked(self, &mut state, &uri, document_version);
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
                // Version zero remains an internal "not opened on the wire"
                // sentinel. Consumers receive version one, which is the exact
                // version the latest queued text will have after initialize.
                document_version = 1;
            }
        }
        messages.extend(stale_cancellations);
        self.send_messages_or_fail(&outbound_order, messages, "documentSync")?;
        Ok(SyncDocumentResponse {
            document_version,
            changed: true,
        })
    }

    fn close_document(&self, uri: &str) -> Result<(), CoreError> {
        let mut messages = Vec::new();
        let cleared;
        let outbound_order = self.lock_outbound_order()?;
        {
            let mut state = self.lock_state()?;
            ensure_not_terminal(state.lifecycle)?;
            let Some(document) = state.client.open_documents.get(uri).cloned() else {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Cannot close a document that is not owned by the language-server session.",
                ));
            };
            state.java_navigation_marker_cache.remove(uri);
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
        self.send_messages_or_fail(&outbound_order, messages, "documentClose")
    }

    fn complete_cached_java_navigation_markers(
        &self,
        operation_id: &str,
        uri: &str,
        requested_document_version: Option<i64>,
    ) -> Result<bool, CoreError> {
        let mut state = self.lock_state()?;
        if state.lifecycle != LspLifecycleState::Ready || !state.client.initialized {
            return Ok(false);
        }
        if state.request_by_operation.contains_key(operation_id) {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "The language-server operation ID is already pending.",
            ));
        }
        let current_version = state
            .client
            .open_documents
            .get(uri)
            .map(|document| document.version.max(1));
        let Some(entry) = state.java_navigation_marker_cache.get(uri) else {
            return Ok(false);
        };
        let expected_version = requested_document_version.or(current_version);
        if expected_version != Some(entry.document_version)
            || current_version != Some(entry.document_version)
        {
            return Ok(false);
        }
        let document_version = entry.document_version;
        let markers = entry.markers.clone();
        push_log_event(
            self,
            &mut state,
            "debug",
            "Java navigation markers served from cache",
            Some(format!(
                "operationId={operation_id}, uri={uri}, documentVersion={document_version}, markers={}",
                markers.len()
            )),
        );
        push_request_event(
            self,
            &mut state,
            operation_id,
            "textDocument/codeLens",
            Some(json!({
                "documentVersion": document_version,
                "markers": markers
            })),
            None,
        );
        Ok(true)
    }

    fn request(&self, request: SemanticRequest, operation_id: String) -> Result<(), CoreError> {
        let document_version = request.uri.as_deref().and_then(|uri| {
            self.lock_state().ok().and_then(|state| {
                state
                    .client
                    .open_documents
                    .get(uri)
                    .map(|document| document.version.max(1))
            })
        });
        let pending_kind = if request.operation == LspSemanticOperation::VirtualDocument {
            PendingKind::VirtualDocument
        } else {
            PendingKind::Feature
        };
        self.request_with_kind(request, operation_id, pending_kind, document_version)
    }

    fn request_with_kind(
        &self,
        request: SemanticRequest,
        operation_id: String,
        requested_kind: PendingKind,
        requested_document_version: Option<i64>,
    ) -> Result<(), CoreError> {
        let outbound_order = self.lock_outbound_order()?;
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
            if let (Some(uri), Some(expected_version)) =
                (uri.as_deref(), requested_document_version)
            {
                let current_version = state
                    .client
                    .open_documents
                    .get(uri)
                    .map(|document| document.version.max(1))
                    .ok_or_else(|| {
                        CoreError::new(
                            ErrorCode::InvalidRequest,
                            "The document is not synchronized with the language server.",
                        )
                    })?;
                if current_version != expected_version {
                    return Err(CoreError::new(
                        ErrorCode::Cancelled,
                        "The document changed before the Java navigation request started.",
                    )
                    .with_details(format!(
                        "expectedVersion={expected_version}, currentVersion={current_version}"
                    )));
                }
            }
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

            let pending_kind = requested_kind;
            let response = match request.operation {
                LspSemanticOperation::JavaSuperImplementation => {
                    let uri = uri.clone().ok_or_else(|| {
                        CoreError::new(
                            ErrorCode::InvalidRequest,
                            "Java super navigation requires a document URI.",
                        )
                    })?;
                    let position = request.position.ok_or_else(|| {
                        CoreError::new(
                            ErrorCode::InvalidRequest,
                            "Java super navigation requires a document position.",
                        )
                    })?;
                    allocate_raw_request(
                        state.client.clone(),
                        method,
                        json!({
                            "type": "superImplementation",
                            "position": {
                                "textDocument": { "uri": uri },
                                "position": {
                                    "line": position.line,
                                    "character": position.utf16_column
                                }
                            }
                        }),
                    )?
                }
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
                    let document_is_open = state
                        .client
                        .open_documents
                        .get(&uri)
                        .is_some_and(|document| document.version > 0);
                    let provider_owns_document = is_virtual_source_uri(&self.provider_id, &uri);
                    if !document_is_open && !provider_owns_document {
                        return Err(CoreError::new(
                            ErrorCode::InvalidRequest,
                            "The document is not open in the language server.",
                        ));
                    }
                    let feature_request = ClientFeatureRequest {
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
                    };
                    if provider_owns_document {
                        client_provider_document_feature_request_canonical(feature_request)?
                    } else {
                        client_feature_request_canonical(feature_request)?
                    }
                }
            };
            let request_id = (response.state.next_request_id - 1).to_string();
            let now = Instant::now();
            let pending = PendingRequest {
                kind: pending_kind,
                operation_id: Some(operation_id.clone()),
                method: method.to_string(),
                document_uri: uri.clone(),
                document_version: requested_document_version.or_else(|| {
                    uri.as_deref()
                        .and_then(|uri| state.client.open_documents.get(uri))
                        .map(|document| document.version)
                }),
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
        if let Err(error) = self.send_messages(&outbound_order, messages) {
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
        let outbound_order = self.lock_outbound_order()?;
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
            state.java_navigation_marker_batches.remove(operation_id);
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
        self.send_messages_or_fail(&outbound_order, vec![cancellation], "requestCancel")
    }

    fn stop(&self) -> Result<(), CoreError> {
        let outbound_order = self.lock_outbound_order()?;
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
                        document_version: None,
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
        self.send_messages_or_fail(&outbound_order, messages, "shutdown")?;
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
                // Returning Ok([]) here would let frontend pumps spin on Core IPC
                // forever after the terminal stateChanged event was drained.
                let details = match state.lifecycle {
                    LspLifecycleState::Failed => "sessionFailed",
                    _ => "sessionStopped",
                };
                return Err(CoreError::new(
                    ErrorCode::ProcessFailed,
                    "Language-server session is no longer running.",
                )
                .with_details(details));
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
        let method = value.get("method").and_then(Value::as_str);
        let readiness = readiness_signal(&self.provider_id, method, value.get("params"));
        let java_import_progress = import_progress(&self.provider_id, method, value.get("params"));
        let outbound_order = self.lock_outbound_order()?;

        if value.get("method").and_then(Value::as_str) == Some("workspace/configuration") {
            if let Some(response) = self.provider_configuration_response(&value)? {
                return self.send_messages_or_fail(
                    &outbound_order,
                    vec![response],
                    "serverRequest",
                );
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
        let mut ready_server_info = None;
        let mut fail_initialize: Option<(String, Option<String>)> = None;
        let mut service_ready = false;
        let mut fail_service_ready = None;
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
                    let server_error = value.get("error").map(Value::to_string);
                    if server_error.is_some() || !state.client.initialized {
                        state.initialize_deadline = None;
                        fail_initialize = Some((
                            if server_error.is_some() {
                                "initializeFailed".to_string()
                            } else {
                                "invalidServerMessage".to_string()
                            },
                            server_error,
                        ));
                    } else {
                        state.initialize_deadline = None;
                        if waits_for_service_ready(&self.provider_id) {
                            let now = Instant::now();
                            let idle_timeout = state.service_ready_idle_timeout;
                            let absolute_timeout = state.service_ready_absolute_timeout;
                            let initialize_elapsed = pending_before
                                .as_ref()
                                .map(|pending| now.saturating_duration_since(pending.created_at))
                                .unwrap_or_default();
                            if let Some(diagnostics) = state.java_preparation.as_mut() {
                                let detail = diagnostics.begin_readiness(
                                    now,
                                    initialize_elapsed,
                                    idle_timeout,
                                    absolute_timeout,
                                );
                                push_log_event(
                                    self,
                                    &mut state,
                                    "info",
                                    "Java language service protocol initialized",
                                    Some(detail),
                                );
                            }
                        }
                        ready_server_info = parse_server_info(&value);
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
                            let result = normalize_provider_navigation_result(
                                &self.provider_id,
                                event.and_then(|event| event.result.clone()),
                            );
                            push_request_event(
                                self,
                                &mut state,
                                operation_id,
                                &pending.method,
                                result,
                                error,
                            );
                        }
                    }
                }
                Some(PendingKind::JavaNavigationMarkers) => {
                    if let Some(pending) = pending_before.as_ref() {
                        if let Some(operation_id) = &pending.operation_id {
                            let event = reduced
                                .events
                                .iter()
                                .find(|event| event.request_id.as_ref() == response_id.as_ref());
                            let server_error =
                                event.and_then(|event| event.error.as_ref()).map(|detail| {
                                    runtime_error(
                                        self,
                                        "serverError",
                                        "javaNavigationMarkers",
                                        Some(&pending.method),
                                        pending.document_uri.as_deref(),
                                        "Language server returned an error.",
                                        Some(detail),
                                        None,
                                    )
                                });
                            if let Some(error) = server_error {
                                push_request_event(
                                    self,
                                    &mut state,
                                    operation_id,
                                    &pending.method,
                                    None,
                                    Some(error),
                                );
                            } else {
                                let raw_lenses = value
                                    .get("result")
                                    .and_then(Value::as_array)
                                    .cloned()
                                    .unwrap_or_default();
                                let source = pending
                                    .document_uri
                                    .as_deref()
                                    .and_then(|uri| state.client.open_documents.get(uri))
                                    .map(|document| document.text.as_str())
                                    .unwrap_or_default();
                                let batch = JavaNavigationMarkerBatch::new(
                                    &raw_lenses,
                                    source,
                                    pending.created_at,
                                    pending.deadline,
                                );
                                let total_tasks = batch.total_tasks();
                                state
                                    .java_navigation_marker_batches
                                    .insert(operation_id.clone(), batch);
                                if total_tasks > MAX_JAVA_NAVIGATION_TASKS {
                                    push_log_event(
                                        self,
                                        &mut state,
                                        "warning",
                                        "Java navigation marker batch was limited",
                                        Some(format!(
                                            "operationId={operation_id}, uri={}, documentVersion={}, tasks={total_tasks}, limit={MAX_JAVA_NAVIGATION_TASKS}",
                                            pending.document_uri.as_deref().unwrap_or(""),
                                            pending.document_version.unwrap_or_default()
                                        )),
                                    );
                                }
                                if !queue_next_java_marker_resolve(
                                    &mut state,
                                    operation_id,
                                    pending,
                                    &mut outbound,
                                )? {
                                    finish_java_navigation_marker_batch(
                                        self,
                                        &mut state,
                                        operation_id,
                                        pending,
                                    );
                                }
                            }
                        }
                    }
                }
                Some(PendingKind::JavaNavigationMarkerResolve) => {
                    if let Some(pending) = pending_before.as_ref() {
                        if let Some(operation_id) = &pending.operation_id {
                            if value.get("error").is_none() {
                                if let Some(batch) =
                                    state.java_navigation_marker_batches.get_mut(operation_id)
                                {
                                    batch.record_active_result(value.get("result"));
                                }
                            } else {
                                push_log_event(
                                    self,
                                    &mut state,
                                    "warning",
                                    "JDT LS could not verify one Java navigation marker",
                                    Some(format!(
                                        "operationId={operation_id}, uri={}, documentVersion={}, error={}",
                                        pending.document_uri.as_deref().unwrap_or(""),
                                        pending.document_version.unwrap_or_default(),
                                        value.get("error").map(Value::to_string).unwrap_or_default()
                                    )),
                                );
                            }
                            if !queue_next_java_marker_resolve(
                                &mut state,
                                operation_id,
                                pending,
                                &mut outbound,
                            )? {
                                finish_java_navigation_marker_batch(
                                    self,
                                    &mut state,
                                    operation_id,
                                    pending,
                                );
                            }
                        }
                    }
                }
                Some(PendingKind::JavaResolveNavigation) => {
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
                                        "javaResolveNavigation",
                                        Some(&pending.method),
                                        pending.document_uri.as_deref(),
                                        "Language server returned an error.",
                                        Some(detail),
                                        None,
                                    )
                                });
                            let normalized = normalize_provider_navigation_result(
                                &self.provider_id,
                                event.and_then(|event| event.result.clone()),
                            );
                            let locations = normalized
                                .as_ref()
                                .and_then(|result| result.get("locations"))
                                .cloned()
                                .unwrap_or_else(|| Value::Array(Vec::new()));
                            push_request_event(
                                self,
                                &mut state,
                                operation_id,
                                &pending.method,
                                Some(json!({
                                    "documentVersion": pending.document_version,
                                    "locations": locations
                                })),
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

            let suppress_structured_java_preparation_notification = state.lifecycle
                == LspLifecycleState::Initializing
                && (java_import_progress.is_some() || readiness.is_some());
            if state.lifecycle == LspLifecycleState::Initializing {
                if let Some(progress) = java_import_progress {
                    let detail = state.java_preparation.as_mut().and_then(|diagnostics| {
                        diagnostics.record_progress(progress, Instant::now())
                    });
                    if let Some(detail) = detail {
                        push_log_event(
                            self,
                            &mut state,
                            "info",
                            "Java workspace import progress",
                            Some(detail),
                        );
                    }
                }
            }

            if state.lifecycle == LspLifecycleState::Initializing {
                match readiness.as_ref() {
                    Some(JdtReadinessSignal::Ready) if state.client.initialized => {
                        service_ready = true;
                    }
                    Some(JdtReadinessSignal::Failed(detail)) => {
                        fail_service_ready = Some(detail.clone());
                    }
                    _ => {}
                }
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
                } else if event.kind == "notification"
                    && !(suppress_structured_java_preparation_notification
                        && is_structured_import_notification(
                            &self.provider_id,
                            event.method.as_deref(),
                        ))
                {
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
        if let Some(detail) = fail_service_ready {
            self.fail(
                "serviceReadyFailed",
                "serviceReady",
                "Java language service failed while preparing the workspace.",
                Some(detail),
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
            if !waits_for_service_ready(&self.provider_id) {
                outbound.extend(self.flush_queued_documents()?);
            }
            self.send_messages_or_fail(&outbound_order, outbound, "serverResponse")?;
            let mut state = self.lock_state()?;
            if let Some(info) = ready_server_info {
                push_server_info_event(self, &mut state, info);
            }
            if waits_for_service_ready(&self.provider_id) {
                push_log_event(
                    self,
                    &mut state,
                    "info",
                    "Waiting for the Java language service to finish project import",
                    None,
                );
            } else {
                transition_locked(self, &mut state, LspLifecycleState::Ready, None);
                let capabilities = state.client.server_capabilities.clone();
                push_features_event(self, &mut state, capabilities);
            }
            return Ok(());
        }
        self.send_messages_or_fail(&outbound_order, outbound, "serverResponse")?;
        if service_ready {
            let queued_messages = {
                let mut state = self.lock_state()?;
                state.initialize_deadline = None;
                flush_queued_documents_locked(&mut state)?
            };
            self.send_messages_or_fail(&outbound_order, queued_messages, "serviceReady")?;
            {
                let mut state = self.lock_state()?;
                let ready_detail = state
                    .java_preparation
                    .as_mut()
                    .map(|diagnostics| diagnostics.ready_detail(Instant::now()));
                transition_locked(self, &mut state, LspLifecycleState::Ready, None);
                let capabilities = state.client.server_capabilities.clone();
                push_features_event(self, &mut state, capabilities);
                push_log_event(
                    self,
                    &mut state,
                    "info",
                    "Java language service finished project import",
                    ready_detail,
                );
            }
        }
        Ok(())
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
        flush_queued_documents_locked(&mut state)
    }

    fn expire_deadlines(&self) {
        let now = Instant::now();
        let mut cancellations = Vec::new();
        let mut initialize_timeout = false;
        let mut service_ready_timeout = None;
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
            if state.lifecycle == LspLifecycleState::Initializing && !initialize_timeout {
                service_ready_timeout = state
                    .java_preparation
                    .as_mut()
                    .and_then(|diagnostics| diagnostics.take_timeout(now));
            }

            let expired: Vec<_> = state
                .pending
                .iter()
                .filter(|(_, pending)| {
                    matches!(
                        pending.kind,
                        PendingKind::Feature
                            | PendingKind::VirtualDocument
                            | PendingKind::JavaNavigationMarkers
                            | PendingKind::JavaNavigationMarkerResolve
                            | PendingKind::JavaResolveNavigation
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
                    state.java_navigation_marker_batches.remove(operation_id);
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
        if initialize_timeout {
            // Timeout termination must not wait behind a blocked stdin write;
            // killing the process is what releases that write.
            self.fail(
                "initializeTimeout",
                "initialize",
                "Language-server initialization timed out.",
                None,
                None,
            );
            self.kill_process();
        } else if let Some(detail) = service_ready_timeout {
            self.fail(
                "serviceReadyTimeout",
                "serviceReady",
                "Java language service project import timed out.",
                Some(detail),
                None,
            );
            self.kill_process();
        } else if shutdown_timeout {
            self.kill_process();
        } else if !cancellations.is_empty() {
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
            match self.lock_outbound_order() {
                Ok(outbound_order) => {
                    let _ = self.send_messages(&outbound_order, messages);
                }
                Err(error) => {
                    self.fail(
                        "transportFailed",
                        "outboundOrder",
                        "Language-server outbound ordering failed.",
                        Some(core_error_detail(&error)),
                        None,
                    );
                    self.kill_process();
                }
            }
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
                state.java_navigation_marker_batches.remove(operation_id);
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

    fn send_messages_or_fail(
        &self,
        outbound_order: &MutexGuard<'_, ()>,
        messages: Vec<String>,
        stage: &str,
    ) -> Result<(), CoreError> {
        if messages.is_empty() {
            return Ok(());
        }
        if let Err(error) = self.send_messages(outbound_order, messages) {
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

    fn send_messages(
        &self,
        _outbound_order: &MutexGuard<'_, ()>,
        messages: Vec<String>,
    ) -> Result<(), CoreError> {
        for message in messages {
            let frame = frame_message(FrameMessageRequest { message })?.frame;
            self.process.write_input(frame.as_bytes())?;
        }
        Ok(())
    }

    fn kill_process(&self) {
        self.process.terminate();
    }

    fn lock_outbound_order(&self) -> Result<MutexGuard<'_, ()>, CoreError> {
        self.outbound_order.lock().map_err(|_| {
            CoreError::new(
                ErrorCode::Unknown,
                "Language-server outbound ordering lock was poisoned.",
            )
        })
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
    if let Some(resources) = &request.jdtls_launch_resources {
        if !request.provider_id.trim().eq_ignore_ascii_case("java") {
            return Err(invalid_field("jdtlsLaunchResources/providerId"));
        }
        if !is_valid_process_path(request.runtime_executable_path.as_deref())
            || !is_valid_process_path(Some(&resources.launcher_jar_path))
            || !is_valid_process_path(Some(&resources.configuration_directory))
            || !is_valid_process_path(Some(&resources.lombok_agent_path))
        {
            return Err(invalid_field("jdtlsLaunchResources/runtimeExecutablePath"));
        }
    }
    Ok(())
}

fn is_valid_process_path(path: Option<&str>) -> bool {
    path.is_some_and(|path| !path.trim().is_empty() && !path.contains('\0'))
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
        LspSemanticOperation::JavaSuperImplementation => "java/findLinks",
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
        LspSemanticOperation::JavaSuperImplementation => Some("definition"),
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

fn queue_next_java_marker_resolve(
    state: &mut SessionState,
    operation_id: &str,
    pending: &PendingRequest,
    outbound: &mut Vec<String>,
) -> Result<bool, CoreError> {
    let next = state
        .java_navigation_marker_batches
        .get_mut(operation_id)
        .and_then(JavaNavigationMarkerBatch::take_next);
    let Some(task) = next else {
        return Ok(false);
    };
    let uri = pending.document_uri.as_deref().unwrap_or_default();
    let (method, params) = task.request(uri);
    let response = allocate_raw_request(state.client.clone(), method, params)?;
    let request_id = (response.state.next_request_id - 1).to_string();
    let (created_at, deadline) = state
        .java_navigation_marker_batches
        .get(operation_id)
        .map(|batch| (batch.created_at(), batch.deadline()))
        .unwrap_or((pending.created_at, pending.deadline));
    state.client = response.state;
    state.pending.insert(
        request_id.clone(),
        PendingRequest {
            kind: PendingKind::JavaNavigationMarkerResolve,
            operation_id: Some(operation_id.to_string()),
            method: method.to_string(),
            document_uri: pending.document_uri.clone(),
            document_version: pending.document_version,
            created_at,
            deadline,
        },
    );
    state
        .request_by_operation
        .insert(operation_id.to_string(), request_id);
    outbound.extend(response.messages);
    Ok(true)
}

fn finish_java_navigation_marker_batch(
    session: &RuntimeSession,
    state: &mut SessionState,
    operation_id: &str,
    pending: &PendingRequest,
) {
    let Some(batch) = state.java_navigation_marker_batches.remove(operation_id) else {
        return;
    };
    state.request_by_operation.remove(operation_id);
    let source = pending
        .document_uri
        .as_deref()
        .and_then(|uri| state.client.open_documents.get(uri))
        .map(|document| document.text.clone())
        .unwrap_or_default();
    let created_at = batch.created_at();
    let total_tasks = batch.total_tasks();
    let resolved_lens_count = batch.resolved_lens_count();
    let markers = batch.finish(&source);
    if let (Some(uri), Some(document_version)) =
        (pending.document_uri.as_ref(), pending.document_version)
    {
        let is_current = state
            .client
            .open_documents
            .get(uri)
            .is_some_and(|document| document.version.max(1) == document_version);
        if is_current {
            state.java_navigation_marker_cache.insert(
                uri.clone(),
                JavaNavigationMarkerCacheEntry {
                    document_version,
                    markers: markers.clone(),
                },
            );
        }
    }
    let elapsed = Instant::now().saturating_duration_since(created_at);
    push_log_event(
        session,
        state,
        "debug",
        "Java navigation markers resolved",
        Some(format!(
            "operationId={operation_id}, uri={}, documentVersion={}, durationMilliseconds={}, tasks={}, codeLenses={}, markers={}",
            pending.document_uri.as_deref().unwrap_or(""),
            pending.document_version.unwrap_or_default(),
            elapsed.as_millis(),
            total_tasks,
            resolved_lens_count,
            markers.len()
        )),
    );
    push_request_event(
        session,
        state,
        operation_id,
        "textDocument/codeLens",
        Some(json!({
            "documentVersion": pending.document_version,
            "markers": markers
        })),
        None,
    );
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

fn normalize_provider_navigation_result(
    provider_id: &str,
    mut result: Option<Value>,
) -> Option<Value> {
    let locations = result
        .as_mut()
        .and_then(|result| result.get_mut("locations"))
        .and_then(Value::as_array_mut);
    let Some(locations) = locations else {
        return result;
    };

    for location in locations {
        let Some(uri) = location
            .get("uri")
            .and_then(Value::as_str)
            .map(ToString::to_string)
        else {
            continue;
        };
        let normalized = normalize_location(
            provider_id,
            ProviderLocation {
                uri,
                is_read_only: location
                    .get("isReadOnly")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
                display_path: location
                    .get("displayPath")
                    .and_then(Value::as_str)
                    .map(ToString::to_string),
            },
        );
        location["isReadOnly"] = Value::Bool(normalized.is_read_only);
        location["displayPath"] = normalized.display_path.map_or(Value::Null, Value::String);
    }

    result
}

fn cancel_stale_document_requests_locked(
    session: &RuntimeSession,
    state: &mut SessionState,
    uri: &str,
    document_version: i64,
) -> Vec<String> {
    let stale_ids: Vec<String> = state
        .pending
        .iter()
        .filter(|(_, pending)| {
            pending.document_uri.as_deref() == Some(uri)
                && pending
                    .document_version
                    .is_some_and(|version| version < document_version)
                && is_stale_sensitive_method(&pending.method)
        })
        .map(|(request_id, _)| request_id.clone())
        .collect();
    let mut messages = Vec::new();
    for request_id in stale_ids {
        let Some(pending) = state.pending.remove(&request_id) else {
            continue;
        };
        state.client.pending_requests.remove(&request_id);
        if let Some(operation_id) = pending.operation_id.as_deref() {
            state.request_by_operation.remove(operation_id);
            state.java_navigation_marker_batches.remove(operation_id);
            let error = runtime_error(
                session,
                "staleDocumentVersion",
                "request",
                Some(&pending.method),
                Some(uri),
                "The document changed before the language-server result arrived.",
                Some("A newer document version superseded this request."),
                None,
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
        messages.push(
            json!({
                "jsonrpc": "2.0",
                "method": "$/cancelRequest",
                "params": { "id": request_id }
            })
            .to_string(),
        );
    }
    messages
}

fn is_stale_sensitive_method(method: &str) -> bool {
    matches!(
        method,
        "textDocument/completion"
            | "textDocument/hover"
            | "textDocument/inlayHint"
            | "textDocument/foldingRange"
            | "textDocument/codeLens"
            | "codeLens/resolve"
            | "textDocument/implementation"
            | "java/findLinks"
    )
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
                PendingKind::Feature
                    | PendingKind::VirtualDocument
                    | PendingKind::JavaNavigationMarkers
                    | PendingKind::JavaNavigationMarkerResolve
                    | PendingKind::JavaResolveNavigation
            )
        })
        .map(|(request_id, pending)| (request_id.clone(), pending.clone()))
        .collect();
    for (request_id, pending) in pending {
        state.pending.remove(&request_id);
        state.client.pending_requests.remove(&request_id);
        if let Some(operation_id) = pending.operation_id.as_deref() {
            state.request_by_operation.remove(operation_id);
            state.java_navigation_marker_batches.remove(operation_id);
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
    state.java_navigation_marker_batches.clear();
    state.java_navigation_marker_cache.clear();
    state.pending_workspace_file_changes.clear();
    state.initialize_deadline = None;
    state.shutdown_deadline = None;
    push_features_event(session, state, Vec::new());
}

fn flush_queued_documents_locked(state: &mut SessionState) -> Result<Vec<String>, CoreError> {
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
    if !state.pending_workspace_file_changes.is_empty() {
        let changes = std::mem::take(&mut state.pending_workspace_file_changes);
        messages.push(workspace_file_changes_notification(changes));
    }
    Ok(messages)
}

fn workspace_file_changes_notification(
    changes: BTreeMap<String, WorkspaceFileChangeKind>,
) -> String {
    let changes: Vec<_> = changes
        .into_iter()
        .map(|(uri, kind)| {
            let event_type = match kind {
                WorkspaceFileChangeKind::Created => 1,
                WorkspaceFileChangeKind::Changed => 2,
                WorkspaceFileChangeKind::Deleted => 3,
            };
            json!({ "uri": uri, "type": event_type })
        })
        .collect();
    json!({
        "jsonrpc": "2.0",
        "method": "workspace/didChangeWatchedFiles",
        "params": { "changes": changes }
    })
    .to_string()
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
            jdtls_launch_resources: None,
            cache_directory: None,
            workspace_fingerprint: None,
            initialize_timeout_milliseconds: 10_000,
            service_ready_idle_timeout_milliseconds: 45_000,
            service_ready_absolute_timeout_milliseconds: 600_000,
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

    /// Owns an opt-in real-process smoke session and removes every temporary
    /// resource even when the smoke test unwinds after a failed assertion.
    struct RealSmokeCleanup<'a> {
        engine: &'a LspEngine,
        session_id: String,
        root: PathBuf,
    }

    impl Drop for RealSmokeCleanup<'_> {
        fn drop(&mut self) {
            if let Ok(session) = self.engine.session(&self.session_id) {
                let _ = session.stop();
                let deadline = Instant::now() + Duration::from_secs(10);
                while Instant::now() < deadline {
                    let terminal = session.snapshot().is_ok_and(|snapshot| {
                        matches!(
                            snapshot.state,
                            LspLifecycleState::Stopped | LspLifecycleState::Failed
                        )
                    });
                    if terminal {
                        break;
                    }
                    let _ = session.poll_events();
                    thread::sleep(Duration::from_millis(20));
                }
                if session.snapshot().is_ok_and(|snapshot| {
                    !matches!(
                        snapshot.state,
                        LspLifecycleState::Stopped | LspLifecycleState::Failed
                    )
                }) {
                    session.kill_process();
                }
            }
            let _ = self.engine.destroy(&self.session_id);
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    fn await_real_smoke_ready(
        session: &Arc<RuntimeSession>,
    ) -> Result<Vec<LspRuntimeEvent>, String> {
        let deadline = Instant::now() + Duration::from_secs(90);
        let mut events = Vec::new();
        while Instant::now() < deadline {
            events.extend(session.poll_events().map_err(|error| error.message)?);
            let snapshot = session.snapshot().map_err(|error| error.message)?;
            match snapshot.state {
                LspLifecycleState::Ready => {
                    events.extend(session.poll_events().map_err(|error| error.message)?);
                    return Ok(events);
                }
                LspLifecycleState::Failed => {
                    return Err(format!("JDTLS failed during initialization: {events:?}"));
                }
                _ => thread::sleep(Duration::from_millis(20)),
            }
        }
        Err(format!(
            "JDTLS did not become ready before the smoke timeout: {events:?}"
        ))
    }

    fn real_smoke_request(
        engine: &LspEngine,
        session: &Arc<RuntimeSession>,
        operation: LspSemanticOperation,
        uri: Option<&str>,
        virtual_uri: Option<&str>,
        position: Option<LspPosition>,
    ) -> Result<Value, String> {
        let operation_id = engine.next_operation_id();
        session
            .request(
                SemanticRequest {
                    session_id: session.id.clone(),
                    operation_id: Some(operation_id.clone()),
                    operation,
                    uri: uri.map(str::to_string),
                    virtual_uri: virtual_uri.map(str::to_string),
                    position,
                    new_name: None,
                    range: None,
                    diagnostics: Vec::new(),
                    completion_item: None,
                    code_action: None,
                    command: None,
                },
                operation_id.clone(),
            )
            .map_err(|error| error.message)?;

        let deadline = Instant::now() + Duration::from_secs(35);
        while Instant::now() < deadline {
            for event in session.poll_events().map_err(|error| error.message)? {
                if event.operation_id.as_deref() != Some(operation_id.as_str()) {
                    continue;
                }
                if let Some(error) = event.error {
                    return Err(format!(
                        "JDTLS smoke request {} failed: {error:?}",
                        semantic_method(operation)
                    ));
                }
                return event.result.ok_or_else(|| {
                    format!(
                        "JDTLS smoke request {} returned no result",
                        semantic_method(operation)
                    )
                });
            }
            thread::sleep(Duration::from_millis(20));
        }
        Err(format!(
            "JDTLS smoke request {} timed out",
            semantic_method(operation)
        ))
    }

    fn real_smoke_locations(result: &Value) -> &[Value] {
        result
            .get("locations")
            .and_then(Value::as_array)
            .map(Vec::as_slice)
            .unwrap_or_default()
    }

    fn real_smoke_token_position(text: &str, marker: &str, token_offset: usize) -> LspPosition {
        let marker_index = text.find(marker).expect("smoke marker should exist") + token_offset;
        let prefix = &text[..marker_index];
        let line = prefix.bytes().filter(|byte| *byte == b'\n').count() as i64;
        let line_prefix = prefix.rsplit_once('\n').map_or(prefix, |(_, tail)| tail);
        LspPosition {
            line,
            utf16_column: line_prefix.encode_utf16().count() as i64,
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

    #[test]
    fn java_waits_for_service_ready_after_standard_initialize() {
        let mut harness = Harness::start(|request| {
            request.provider_id = "java".to_string();
        });
        harness.server.complete_initialize(ready_capabilities());
        assert!(harness
            .server
            .await_notification("workspace/didChangeConfiguration"));

        assert_eq!(
            harness.snapshot().state,
            LspLifecycleState::Initializing,
            "the initialize response alone must not advertise a usable Java index"
        );
        harness.server.send(json!({
            "jsonrpc": "2.0",
            "method": "language/status",
            "params": { "type": "ServiceReady", "message": "ServiceReady" }
        }));
        harness.await_state(LspLifecycleState::Ready);
    }

    #[test]
    fn java_service_error_fails_the_preparing_session() {
        let mut harness = Harness::start(|request| {
            request.provider_id = "java".to_string();
        });
        harness.server.complete_initialize(ready_capabilities());
        assert!(harness.server.await_notification("initialized"));
        harness.server.send(json!({
            "jsonrpc": "2.0",
            "method": "language/status",
            "params": { "type": "Error", "message": "Project import failed" }
        }));
        harness.await_state(LspLifecycleState::Failed);

        let failure = harness
            .events
            .iter()
            .find_map(|event| event.error.as_ref())
            .expect("the Java service error should be retained");
        assert_eq!(failure.code, "serviceReadyFailed");
        assert_eq!(failure.stage, "serviceReady");
        assert_eq!(
            failure.underlying_message.as_deref(),
            Some("Project import failed")
        );
    }

    #[test]
    fn java_preparation_timeout_covers_project_import() {
        let mut harness = Harness::start(|request| {
            request.provider_id = "java".to_string();
            request.initialize_timeout_milliseconds = 1_000;
            request.service_ready_idle_timeout_milliseconds = 40;
            request.service_ready_absolute_timeout_milliseconds = 5_000;
        });
        harness.server.complete_initialize(ready_capabilities());
        assert!(harness.server.await_notification("initialized"));
        harness.await_state(LspLifecycleState::Failed);

        let failure = harness
            .events
            .iter()
            .find_map(|event| event.error.as_ref())
            .expect("project import timeout should be reported");
        assert_eq!(failure.code, "serviceReadyTimeout");
        assert_eq!(failure.stage, "serviceReady");
        assert!(failure
            .underlying_message
            .as_deref()
            .is_some_and(|detail| detail.contains("\"classification\":\"noProgressStall\"")));
    }

    #[test]
    fn java_import_notifications_are_logged_after_service_ready() {
        let mut harness = Harness::start(|request| {
            request.provider_id = "java".to_string();
        });
        harness.server.complete_initialize(ready_capabilities());
        assert!(harness.server.await_notification("initialized"));
        harness.server.send(json!({
            "jsonrpc": "2.0",
            "method": "$/progress",
            "params": {
                "token": "java-import",
                "value": {
                    "kind": "report",
                    "message": "Importing Maven project(s) - Importing project module-a",
                    "percentage": 20
                }
            }
        }));
        harness.await_event(|event| {
            event.message.as_deref() == Some("Java workspace import progress")
        });
        harness.server.send(json!({
            "jsonrpc": "2.0",
            "method": "language/status",
            "params": { "type": "ServiceReady" }
        }));
        harness.await_state(LspLifecycleState::Ready);
        assert!(
            !harness.events.iter().any(|event| {
                matches!(
                    event.message.as_deref(),
                    Some("$/progress" | "language/status")
                )
            }),
            "structured preparation notifications should not be logged twice"
        );

        harness.server.send(json!({
            "jsonrpc": "2.0",
            "method": "$/progress",
            "params": {
                "token": "java-build",
                "value": {
                    "kind": "report",
                    "message": "Building workspace - Project 'module-a'",
                    "percentage": 50
                }
            }
        }));
        harness.await_event(|event| event.message.as_deref() == Some("$/progress"));

        harness.server.send(json!({
            "jsonrpc": "2.0",
            "method": "language/status",
            "params": {
                "type": "Error",
                "message": "Background build failed"
            }
        }));
        harness.await_event(|event| event.message.as_deref() == Some("language/status"));
        assert_eq!(harness.snapshot().state, LspLifecycleState::Ready);
    }

    #[test]
    fn java_documents_wait_for_service_ready_and_latest_text_wins() {
        let mut harness = Harness::start(|request| {
            request.provider_id = "java".to_string();
        });
        let uri = "file:///workspace/Main.java";
        harness.sync(uri, "class Main {}");
        harness.server.complete_initialize(ready_capabilities());
        assert!(harness
            .server
            .await_notification("workspace/didChangeConfiguration"));
        assert!(!harness
            .server
            .messages()
            .iter()
            .any(|message| message["method"] == "textDocument/didOpen"));

        harness.sync(uri, "class Main { int value; }");
        assert_eq!(harness.snapshot().state, LspLifecycleState::Initializing);
        assert_eq!(harness.snapshot().open_documents[uri].version, 0);
        assert!(!harness.server.messages().iter().any(|message| {
            matches!(
                message["method"].as_str(),
                Some("textDocument/didOpen" | "textDocument/didChange")
            )
        }));

        harness.server.send(json!({
            "jsonrpc": "2.0",
            "method": "language/status",
            "params": { "type": "ServiceReady" }
        }));
        harness.await_state(LspLifecycleState::Ready);

        let document_messages: Vec<_> = harness
            .server
            .messages()
            .into_iter()
            .filter(|message| {
                matches!(
                    message["method"].as_str(),
                    Some("textDocument/didOpen" | "textDocument/didChange")
                )
            })
            .collect();
        assert_eq!(document_messages.len(), 1);
        assert_eq!(document_messages[0]["method"], "textDocument/didOpen");
        assert_eq!(
            document_messages[0]["params"]["textDocument"]["text"],
            "class Main { int value; }"
        );
        assert_eq!(harness.snapshot().open_documents[uri].version, 1);
    }

    #[test]
    fn java_ready_flush_precedes_concurrent_edits_and_closes() {
        let mut harness = Harness::start(|request| {
            request.provider_id = "java".to_string();
        });
        let first_uri = "file:///workspace/First.java";
        let second_uri = "file:///workspace/Second.java";
        harness.sync(first_uri, "class First {}");
        harness.sync(second_uri, "class Second {}");
        harness.server.complete_initialize(ready_capabilities());
        assert!(harness
            .server
            .await_notification("workspace/didChangeConfiguration"));

        // Hold the first restored didOpen before it reaches the server. The
        // complete ready flush must retain outbound ownership and keep Ready
        // private until every restored document has been written.
        harness.server.pause_input();
        harness.server.send(json!({
            "jsonrpc": "2.0",
            "method": "language/status",
            "params": { "type": "ServiceReady" }
        }));
        assert!(
            harness.server.await_input_pause(),
            "the restored document flush should reach the write barrier"
        );
        assert_eq!(
            harness.snapshot().state,
            LspLifecycleState::Initializing,
            "Ready must not be published before queued didOpen messages are written"
        );

        let start = Arc::new(std::sync::Barrier::new(3));
        let edit_session = harness.session();
        let edit_session_id = harness.session_id.clone();
        let edit_start = start.clone();
        let edit = thread::spawn(move || {
            edit_start.wait();
            edit_session.sync_document(SyncDocumentRequest {
                session_id: edit_session_id,
                uri: second_uri.to_string(),
                language_id: "java".to_string(),
                text: "class Second { int value; }".to_string(),
                content_changes: Vec::new(),
            })
        });
        let close_session = harness.session();
        let close_start = start.clone();
        let close = thread::spawn(move || {
            close_start.wait();
            close_session.close_document(first_uri)
        });
        start.wait();

        assert!(
            harness.session().outbound_order.try_lock().is_err(),
            "the ready flush should exclude concurrent protocol state commits"
        );
        harness.server.resume_input();
        edit.join()
            .expect("the concurrent edit thread should finish")
            .expect("the concurrent edit should succeed after Ready");
        close
            .join()
            .expect("the concurrent close thread should finish")
            .expect("the concurrent close should succeed after Ready");
        harness.await_state(LspLifecycleState::Ready);

        let document_messages: Vec<_> = harness
            .server
            .messages()
            .into_iter()
            .filter(|message| {
                matches!(
                    message["method"].as_str(),
                    Some(
                        "textDocument/didOpen" | "textDocument/didChange" | "textDocument/didClose"
                    )
                )
            })
            .collect();
        assert_eq!(document_messages.len(), 4);
        assert_eq!(document_messages[0]["method"], "textDocument/didOpen");
        assert_eq!(
            document_messages[0]["params"]["textDocument"]["uri"],
            first_uri
        );
        assert_eq!(document_messages[1]["method"], "textDocument/didOpen");
        assert_eq!(
            document_messages[1]["params"]["textDocument"]["uri"],
            second_uri
        );
        assert!(document_messages[2..].iter().any(|message| {
            message["method"] == "textDocument/didChange"
                && message["params"]["textDocument"]["uri"] == second_uri
                && message["params"]["textDocument"]["version"] == 2
        }));
        assert!(document_messages[2..].iter().any(|message| {
            message["method"] == "textDocument/didClose"
                && message["params"]["textDocument"]["uri"] == first_uri
        }));

        let snapshot = harness.snapshot();
        assert!(!snapshot.open_documents.contains_key(first_uri));
        assert_eq!(snapshot.open_documents[second_uri].version, 2);
        assert_eq!(
            snapshot.open_documents[second_uri].text,
            "class Second { int value; }"
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

    #[test]
    fn workspace_file_changes_queue_until_initialize_and_collapse_watcher_bursts() {
        let mut harness = Harness::start(|_| {});
        harness
            .session()
            .workspace_files_changed(vec![
                WorkspaceFileChange {
                    uri: "file:///workspace/pom.xml".to_string(),
                    kind: WorkspaceFileChangeKind::Changed,
                },
                WorkspaceFileChange {
                    uri: "file:///workspace/src/Main.java".to_string(),
                    kind: WorkspaceFileChangeKind::Created,
                },
                WorkspaceFileChange {
                    uri: "file:///workspace/src/Main.java".to_string(),
                    kind: WorkspaceFileChangeKind::Changed,
                },
            ])
            .expect("watcher events should queue before initialize");
        assert!(!harness
            .server
            .messages()
            .iter()
            .any(|message| { message["method"] == "workspace/didChangeWatchedFiles" }));

        harness.server.complete_initialize(ready_capabilities());
        harness.await_state(LspLifecycleState::Ready);
        let notification = harness
            .server
            .messages()
            .into_iter()
            .find(|message| message["method"] == "workspace/didChangeWatchedFiles")
            .expect("queued watcher events should flush after initialize");
        assert_eq!(
            notification["params"]["changes"],
            json!([
                { "uri": "file:///workspace/pom.xml", "type": 2 },
                { "uri": "file:///workspace/src/Main.java", "type": 2 }
            ])
        );
    }

    #[test]
    fn java_workspace_changes_wait_for_service_ready() {
        let mut harness = Harness::start(|request| {
            request.provider_id = "java".to_string();
        });
        harness
            .session()
            .workspace_files_changed(vec![WorkspaceFileChange {
                uri: "file:///workspace/src/Main.java".to_string(),
                kind: WorkspaceFileChangeKind::Changed,
            }])
            .expect("Java watcher events should queue while project import is pending");
        harness.server.complete_initialize(ready_capabilities());
        assert!(harness
            .server
            .await_notification("workspace/didChangeConfiguration"));
        assert!(!harness
            .server
            .messages()
            .iter()
            .any(|message| { message["method"] == "workspace/didChangeWatchedFiles" }));

        harness.server.send(json!({
            "jsonrpc": "2.0",
            "method": "language/status",
            "params": { "type": "ServiceReady" }
        }));
        harness.await_state(LspLifecycleState::Ready);

        let notification = harness
            .server
            .messages()
            .into_iter()
            .find(|message| message["method"] == "workspace/didChangeWatchedFiles")
            .expect("queued Java watcher events should flush after project import");
        assert_eq!(
            notification["params"]["changes"],
            json!([{ "uri": "file:///workspace/src/Main.java", "type": 2 }])
        );
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

    #[test]
    fn structured_jdtls_resources_launch_the_runtime_executable_directly() {
        let server = ScriptedServer::new();
        let engine = LspEngine::with_launcher(server.launcher());
        let cache = std::env::temp_dir().join("lithe-core-direct-jdtls-tests");
        let mut request = start_request(&server);
        request.provider_id = "java".to_string();
        request.arguments = vec!["--jvm-arg=-Duser.language=en".to_string()];
        request.runtime_executable_path = Some("/opt/lithe/jdk/bin/java".to_string());
        request.jdtls_launch_resources = Some(JdtlsLaunchResources {
            launcher_jar_path: "/opt/lithe/jdtls/plugins/equinox.jar".to_string(),
            configuration_directory: "/opt/lithe/jdtls/config_mac".to_string(),
            lombok_agent_path: "/opt/lithe/jdtls/lombok/lombok.jar".to_string(),
        });
        request.cache_directory = Some(cache.to_string_lossy().into_owned());
        engine
            .start_server(request)
            .expect("the server should start with direct Java");

        let spec = server
            .launched_spec()
            .expect("starting a server must launch a process");
        assert_eq!(spec.executable, "/opt/lithe/jdk/bin/java");
        assert_eq!(
            spec.arguments.first().map(String::as_str),
            Some("-javaagent:/opt/lithe/jdtls/lombok/lombok.jar")
        );
        assert!(spec.arguments.contains(&"-Duser.language=en".to_string()));
        assert_eq!(
            spec.arguments
                .iter()
                .position(|argument| argument == "-jar")
                .map(|index| spec.arguments[index + 1].as_str()),
            Some("/opt/lithe/jdtls/plugins/equinox.jar")
        );
        assert_eq!(
            spec.arguments
                .iter()
                .position(|argument| argument == "-configuration")
                .map(|index| spec.arguments[index + 1].as_str()),
            Some("/opt/lithe/jdtls/config_mac")
        );
        assert!(!spec
            .arguments
            .iter()
            .any(|argument| argument.starts_with("--java-executable")));
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
    fn java_start_enables_and_normalizes_class_file_navigation() {
        let cache = std::env::temp_dir().join("lithe-core-java-navigation-tests");
        let mut harness = Harness::start(|request| {
            request.provider_id = "java".to_string();
            request.cache_directory = Some(cache.to_string_lossy().into_owned());
            request.initialization_options = Some(json!({
                "extendedClientCapabilities": { "customCapability": true }
            }));
        });
        let initialize = harness
            .server
            .messages()
            .into_iter()
            .find(|message| message["method"] == "initialize")
            .expect("the initialize request should reach JDT LS");
        assert_eq!(
            initialize["params"]["initializationOptions"]["extendedClientCapabilities"]
                ["classFileContentsSupport"],
            true
        );
        assert_eq!(
            initialize["params"]["initializationOptions"]["extendedClientCapabilities"]
                ["customCapability"],
            true
        );

        harness
            .server
            .complete_java_initialize(json!({ "definitionProvider": true }));
        harness.await_state(LspLifecycleState::Ready);
        let uri = "file:///workspace/Main.java";
        harness.sync(uri, "class Main { String value; }");
        let operation_id = harness.request(LspSemanticOperation::Definition, uri);
        let request_id = harness
            .server
            .await_request("textDocument/definition")
            .expect("the definition request should reach JDT LS");
        let virtual_uri = "jdt://contents/java.base/java/lang/String.class?=demo";
        harness.server.send(json!({
            "jsonrpc": "2.0",
            "id": request_id,
            "result": [{
                "uri": virtual_uri,
                "range": {
                    "start": { "line": 10, "character": 4 },
                    "end": { "line": 10, "character": 10 }
                }
            }]
        }));
        let event = harness
            .await_event(|event| event.operation_id.as_deref() == Some(operation_id.as_str()))
            .clone();
        let location = &event.result.as_ref().unwrap()["locations"][0];
        assert_eq!(location["uri"], virtual_uri);
        assert_eq!(location["isReadOnly"], true);
        assert_eq!(location["displayPath"], "java.base/java/lang/String.java");

        let _ = std::fs::remove_dir_all(cache);
    }

    #[test]
    fn java_virtual_document_returns_decompiled_text_without_an_open_document() {
        let mut harness = Harness::start(|request| {
            request.provider_id = "java".to_string();
            request.cache_directory = Some("/tmp/lithe-lsp-engine-tests".to_string());
        });
        harness.server.complete_java_initialize(json!({
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
    fn wait_events_errors_after_terminal_state_events_are_drained() {
        let mut harness = Harness::ready();
        harness.poll();
        harness.session().stop().unwrap();
        let shutdown_id = harness
            .server
            .await_request("shutdown")
            .expect("stop should request shutdown");
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

        // Drain any remaining lifecycle events from the stop transition.
        loop {
            let events = match harness.session().wait_events(Duration::from_millis(20)) {
                Ok(events) => events,
                Err(error) => {
                    assert!(matches!(error.code, ErrorCode::ProcessFailed));
                    assert_eq!(error.details.as_deref(), Some("sessionStopped"));
                    return;
                }
            };
            if events.is_empty() {
                break;
            }
        }

        let error = harness
            .session()
            .wait_events(Duration::from_millis(50))
            .expect_err("drained terminal sessions must not return empty Ok");
        assert!(matches!(error.code, ErrorCode::ProcessFailed));
        assert_eq!(error.details.as_deref(), Some("sessionStopped"));
    }

    #[test]
    fn java_virtual_semantics_bypass_did_open_without_weakening_physical_ownership() {
        let mut harness = Harness::start(|request| {
            request.provider_id = "java".to_string();
            request.cache_directory = Some("/tmp/lithe-lsp-engine-tests".to_string());
        });
        harness.server.complete_java_initialize(json!({
            "referencesProvider": true
        }));
        harness.await_state(LspLifecycleState::Ready);
        let virtual_uri = "jdt://contents/java.base/java/lang/String.class?=smoke";
        let operation_id = harness.request(LspSemanticOperation::References, virtual_uri);
        let request_id = harness
            .server
            .await_request("textDocument/references")
            .expect("virtual references should reach JDT LS without didOpen");
        harness.server.send(json!({
            "jsonrpc": "2.0",
            "id": request_id,
            "result": []
        }));
        let event = harness
            .await_event(|event| event.operation_id.as_deref() == Some(operation_id.as_str()));
        assert!(event.error.is_none());

        let physical_operation_id = harness.engine.next_operation_id();
        let error = harness
            .session()
            .request(
                SemanticRequest {
                    session_id: harness.session_id.clone(),
                    operation_id: Some(physical_operation_id.clone()),
                    operation: LspSemanticOperation::References,
                    uri: Some("file:///workspace/Unopened.java".to_string()),
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
                physical_operation_id,
            )
            .expect_err("an unopened physical document must remain rejected");
        assert_eq!(
            error.message,
            "The document is not open in the language server."
        );
    }

    #[test]
    fn real_jdtls_routes_physical_and_virtual_references() {
        let Ok(executable_path) = std::env::var("LITHE_JDTLS_SMOKE_EXECUTABLE") else {
            return;
        };
        let java_path = std::env::var("LITHE_JDTLS_SMOKE_JAVA")
            .expect("LITHE_JDTLS_SMOKE_JAVA must accompany the JDTLS smoke executable");
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system clock should follow the Unix epoch")
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "lithe-real-jdtls-smoke-{}-{stamp}",
            std::process::id()
        ));
        let workspace = root.join("workspace");
        let source_directory = workspace
            .join("src")
            .join("main")
            .join("java")
            .join("smoke");
        let dependency_source_directory = root.join("dependency-source").join("dependency");
        let dependency_classes = root.join("dependency-classes");
        let dependency_jar = workspace.join("lib").join("smoke-dependency.jar");
        std::fs::create_dir_all(&source_directory).expect("smoke source directory should exist");
        std::fs::create_dir_all(&dependency_source_directory)
            .expect("smoke dependency source directory should exist");
        std::fs::create_dir_all(&dependency_classes)
            .expect("smoke dependency classes directory should exist");
        std::fs::create_dir_all(
            dependency_jar
                .parent()
                .expect("dependency JAR should have a parent"),
        )
        .expect("smoke dependency library directory should exist");
        let java_home = PathBuf::from(&java_path)
            .parent()
            .and_then(Path::parent)
            .expect("smoke Java executable should be inside a JDK bin directory")
            .to_path_buf();
        let executable_suffix = if cfg!(windows) { ".exe" } else { "" };
        let dependency_source = dependency_source_directory.join("Widget.java");
        std::fs::write(
            &dependency_source,
            "package dependency; public class Widget { public String value() { return \"widget\"; } }\n",
        )
        .expect("smoke dependency source should be written");
        let javac_status = std::process::Command::new(
            java_home
                .join("bin")
                .join(format!("javac{executable_suffix}")),
        )
        .arg("-d")
        .arg(&dependency_classes)
        .arg(&dependency_source)
        .status()
        .expect("smoke javac should start");
        assert!(javac_status.success(), "smoke dependency should compile");
        let jar_status = std::process::Command::new(
            java_home
                .join("bin")
                .join(format!("jar{executable_suffix}")),
        )
        .arg("--create")
        .arg("--file")
        .arg(&dependency_jar)
        .arg("-C")
        .arg(&dependency_classes)
        .arg(".")
        .status()
        .expect("smoke jar should start");
        assert!(
            jar_status.success(),
            "smoke dependency JAR should be created"
        );
        std::fs::write(
            workspace.join("pom.xml"),
            r#"<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>smoke</groupId>
  <artifactId>lithe-jdtls-smoke</artifactId>
  <version>1.0.0</version>
  <properties><maven.compiler.release>17</maven.compiler.release></properties>
  <dependencies>
    <dependency>
      <groupId>smoke</groupId>
      <artifactId>dependency</artifactId>
      <version>1.0.0</version>
      <scope>system</scope>
      <systemPath>${project.basedir}/lib/smoke-dependency.jar</systemPath>
    </dependency>
  </dependencies>
</project>
"#,
        )
        .expect("smoke pom should be written");
        let source = r#"package smoke;

import dependency.Widget;

public class Main {
  private Widget widget;
  public Widget read() { return widget; }
  public void write(Widget replacement) { widget = replacement; }
}
"#;
        let source_path = source_directory.join("Main.java");
        std::fs::write(&source_path, source).expect("smoke source should be written");

        let root_uri = url::Url::from_directory_path(&workspace)
            .expect("workspace should convert to a file URI")
            .to_string();
        let source_uri = url::Url::from_file_path(&source_path)
            .expect("source should convert to a file URI")
            .to_string();
        let engine = LspEngine::new();
        let started = engine
            .start_server(StartServerRequest {
                provider_id: "java".to_string(),
                executable_path,
                arguments: Vec::new(),
                environment: BTreeMap::from([(
                    "JAVA_HOME".to_string(),
                    java_home.to_string_lossy().into_owned(),
                )]),
                root_uri,
                working_directory: workspace.to_string_lossy().into_owned(),
                initialization_options: None,
                runtime_executable_path: Some(java_path),
                jdtls_launch_resources: None,
                cache_directory: Some(root.join("cache").to_string_lossy().into_owned()),
                workspace_fingerprint: None,
                initialize_timeout_milliseconds: 90_000,
                service_ready_idle_timeout_milliseconds: 45_000,
                service_ready_absolute_timeout_milliseconds: 600_000,
                request_timeout_milliseconds: 30_000,
                shutdown_timeout_milliseconds: 10_000,
            })
            .expect("real JDTLS should start");
        let _cleanup = RealSmokeCleanup {
            engine: &engine,
            session_id: started.session_id.clone(),
            root,
        };
        let session = engine
            .session(&started.session_id)
            .expect("real JDTLS session should be registered");
        let mut ready_events =
            await_real_smoke_ready(&session).unwrap_or_else(|error| panic!("{error}"));
        let capability_deadline = Instant::now() + Duration::from_secs(30);
        let capabilities = loop {
            if let Some(capabilities) = ready_events.iter().find_map(|event| {
                event
                    .capabilities
                    .as_ref()
                    .filter(|capabilities| {
                        ["definition", "references", "executeCommand"]
                            .iter()
                            .all(|required| capabilities.iter().any(|feature| feature == required))
                    })
                    .cloned()
            }) {
                break capabilities;
            }
            assert!(
                Instant::now() < capability_deadline,
                "real JDTLS should dynamically publish capabilities: {ready_events:?}"
            );
            ready_events.extend(
                session
                    .poll_events()
                    .expect("real JDTLS capability events should poll"),
            );
            thread::sleep(Duration::from_millis(20));
        };
        for required in ["definition", "references", "executeCommand"] {
            assert!(
                capabilities.iter().any(|feature| feature == required),
                "real JDTLS did not negotiate {required}: {capabilities:?}"
            );
        }

        session
            .sync_document(SyncDocumentRequest {
                session_id: started.session_id.clone(),
                uri: source_uri.clone(),
                language_id: "java".to_string(),
                text: source.to_string(),
                content_changes: Vec::new(),
            })
            .expect("smoke source should synchronize");

        let field_position = real_smoke_token_position(source, "Widget widget", "Widget ".len());
        let physical_deadline = Instant::now() + Duration::from_secs(30);
        let physical_references = loop {
            let result = real_smoke_request(
                &engine,
                &session,
                LspSemanticOperation::References,
                Some(&source_uri),
                None,
                Some(field_position),
            )
            .unwrap_or_else(|error| panic!("{error}"));
            if real_smoke_locations(&result).len() >= 3 {
                break result;
            }
            assert!(
                Instant::now() < physical_deadline,
                "real JDTLS did not index physical references: {result}"
            );
            thread::sleep(Duration::from_millis(250));
        };
        assert!(real_smoke_locations(&physical_references).len() >= 3);

        let widget_position = real_smoke_token_position(source, "Widget widget", 1);
        let definition = real_smoke_request(
            &engine,
            &session,
            LspSemanticOperation::Definition,
            Some(&source_uri),
            None,
            Some(widget_position),
        )
        .unwrap_or_else(|error| panic!("{error}"));
        let virtual_uri = real_smoke_locations(&definition)
            .iter()
            .find_map(|location| location.get("uri").and_then(Value::as_str))
            .filter(|uri| uri.starts_with("jdt://"))
            .expect("Widget definition should resolve to a JDT virtual URI")
            .to_string();
        let virtual_document = real_smoke_request(
            &engine,
            &session,
            LspSemanticOperation::VirtualDocument,
            None,
            Some(&virtual_uri),
            None,
        )
        .unwrap_or_else(|error| panic!("{error}"));
        let virtual_source = virtual_document
            .get("text")
            .and_then(Value::as_str)
            .filter(|text| !text.is_empty())
            .expect("JDTLS should return decompiled Widget source");
        let virtual_position =
            real_smoke_token_position(virtual_source, "class Widget", "class ".len());
        let virtual_references = real_smoke_request(
            &engine,
            &session,
            LspSemanticOperation::References,
            Some(&virtual_uri),
            None,
            Some(virtual_position),
        )
        .unwrap_or_else(|error| panic!("{error}"));
        assert!(
            real_smoke_locations(&virtual_references).iter().any(|location| {
                location.get("uri").and_then(Value::as_str) == Some(source_uri.as_str())
            }),
            "virtual Widget references should include the synchronized project source: {virtual_references}"
        );
    }

    #[test]
    fn java_navigation_markers_resolve_only_implementation_lenses_and_omit_zero_targets() {
        let mut harness = Harness::start(|_| {});
        harness.server.complete_initialize(json!({
            "codeLensProvider": { "resolveProvider": true }
        }));
        harness.await_state(LspLifecycleState::Ready);
        let uri = "file:///workspace/Service.java";
        harness.sync(uri, "public interface Service {}\n");
        let version = harness.snapshot().open_documents[uri].version;
        let operation_id = harness.engine.next_operation_id();
        harness
            .session()
            .request_with_kind(
                SemanticRequest {
                    session_id: harness.session_id.clone(),
                    operation_id: Some(operation_id.clone()),
                    operation: LspSemanticOperation::CodeLens,
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
                operation_id.clone(),
                PendingKind::JavaNavigationMarkers,
                Some(version),
            )
            .expect("marker request should start");

        let code_lens_id = harness
            .server
            .await_request("textDocument/codeLens")
            .expect("the marker operation should request CodeLens data");
        harness.server.send(json!({
            "jsonrpc": "2.0",
            "id": code_lens_id,
            "result": [
                {
                    "range": {
                        "start": { "line": 0, "character": 17 },
                        "end": { "line": 0, "character": 24 }
                    },
                    "data": [uri, { "line": 0, "character": 17 }, "implementations"]
                },
                {
                    "range": {
                        "start": { "line": 0, "character": 17 },
                        "end": { "line": 0, "character": 24 }
                    },
                    "data": [uri, { "line": 0, "character": 17 }, "references"]
                }
            ]
        }));
        let resolve_id = harness
            .server
            .await_request("codeLens/resolve")
            .expect("only the implementation lens should be resolved");
        harness.server.send(json!({
            "jsonrpc": "2.0",
            "id": resolve_id,
            "result": {
                "range": {
                    "start": { "line": 0, "character": 17 },
                    "end": { "line": 0, "character": 24 }
                },
                "command": {
                    "title": "0 implementations",
                    "command": "java.show.implementations",
                    "arguments": []
                }
            }
        }));

        let event = harness.await_event(|event| {
            event.operation_id.as_deref() == Some(operation_id.as_str())
                && event.kind == "requestCompleted"
        });
        assert_eq!(event.result.as_ref().unwrap()["documentVersion"], version);
        assert_eq!(
            event.result.as_ref().unwrap()["markers"]
                .as_array()
                .map(Vec::len),
            Some(0)
        );
        assert_eq!(
            harness
                .server
                .messages()
                .iter()
                .filter(|message| {
                    message.get("method").and_then(Value::as_str) == Some("codeLens/resolve")
                })
                .count(),
            1
        );

        let cached_operation_id = harness.engine.next_operation_id();
        assert!(harness
            .session()
            .complete_cached_java_navigation_markers(&cached_operation_id, uri, Some(version))
            .expect("the completed marker result should be cached"));
        let cached_event = harness.await_event(|event| {
            event.operation_id.as_deref() == Some(cached_operation_id.as_str())
                && event.kind == "requestCompleted"
        });
        assert_eq!(
            cached_event.result.as_ref().unwrap()["documentVersion"],
            version
        );
        assert_eq!(
            harness
                .server
                .messages()
                .iter()
                .filter(|message| {
                    message.get("method").and_then(Value::as_str) == Some("textDocument/codeLens")
                })
                .count(),
            1
        );

        harness.sync(uri, "public interface Service { void run(); }\n");
        let new_version = harness.snapshot().open_documents[uri].version;
        assert_ne!(new_version, version);
        assert!(!harness
            .session()
            .complete_cached_java_navigation_markers(
                &harness.engine.next_operation_id(),
                uri,
                Some(new_version)
            )
            .expect("editing the document should invalidate the marker cache"));
    }

    #[test]
    fn java_navigation_marker_batch_verifies_method_targets_and_keeps_both_directions() {
        let mut harness = Harness::start(|_| {});
        harness.server.complete_initialize(json!({
            "codeLensProvider": { "resolveProvider": true },
            "implementationProvider": true
        }));
        harness.await_state(LspLifecycleState::Ready);
        let uri = "file:///workspace/Service.java";
        let source = concat!(
            "interface Service { void run(); }\n",
            "class ServiceImpl implements Service {\n",
            "    @Override public void run() {}\n",
            "}\n"
        );
        harness.sync(uri, source);
        let version = harness.snapshot().open_documents[uri].version;
        let operation_id = harness.engine.next_operation_id();
        harness
            .session()
            .request_with_kind(
                SemanticRequest {
                    session_id: harness.session_id.clone(),
                    operation_id: Some(operation_id.clone()),
                    operation: LspSemanticOperation::CodeLens,
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
                operation_id.clone(),
                PendingKind::JavaNavigationMarkers,
                Some(version),
            )
            .expect("marker request should start");

        let code_lens_id = harness
            .server
            .await_request("textDocument/codeLens")
            .expect("the marker operation should request CodeLens data");
        harness.server.send(json!({
            "jsonrpc": "2.0",
            "id": code_lens_id,
            "result": []
        }));

        let super_id = harness
            .server
            .await_request("java/findLinks")
            .expect("the override candidate should request its super implementation");
        harness.server.send(json!({
            "jsonrpc": "2.0",
            "id": super_id,
            "result": [{
                "uri": uri,
                "range": {
                    "start": { "line": 0, "character": 25 },
                    "end": { "line": 0, "character": 28 }
                }
            }]
        }));

        let interface_implementation_id = harness
            .server
            .await_request_at("textDocument/implementation", 0)
            .expect("the interface declaration should query implementations");
        harness.server.send(json!({
            "jsonrpc": "2.0",
            "id": interface_implementation_id,
            "result": [{
                "uri": uri,
                "range": {
                    "start": { "line": 2, "character": 26 },
                    "end": { "line": 2, "character": 29 }
                }
            }]
        }));

        let overriding_implementation_id = harness
            .server
            .await_request_at("textDocument/implementation", 1)
            .expect("the overriding method should query lower implementations");
        harness.server.send(json!({
            "jsonrpc": "2.0",
            "id": overriding_implementation_id,
            "result": [{
                "uri": "file:///workspace/SpecialService.java",
                "range": {
                    "start": { "line": 1, "character": 16 },
                    "end": { "line": 1, "character": 19 }
                }
            }]
        }));

        let event = harness.await_event(|event| {
            event.operation_id.as_deref() == Some(operation_id.as_str())
                && event.kind == "requestCompleted"
        });
        let markers = event.result.as_ref().unwrap()["markers"]
            .as_array()
            .expect("marker result should be an array");
        assert_eq!(markers.len(), 3);
        assert!(markers.iter().any(|marker| {
            marker["line"] == 0
                && marker["direction"] == "down"
                && marker["relation"] == "interface"
        }));
        assert!(markers.iter().any(|marker| {
            marker["line"] == 2 && marker["direction"] == "up" && marker["relation"] == "interface"
        }));
        assert!(markers.iter().any(|marker| {
            marker["line"] == 2
                && marker["direction"] == "down"
                && marker["relation"] == "inheritance"
        }));
    }

    #[test]
    fn java_navigation_marker_batch_is_cancelled_when_the_document_changes() {
        let mut harness = Harness::start(|_| {});
        harness.server.complete_initialize(json!({
            "codeLensProvider": { "resolveProvider": true },
            "implementationProvider": true
        }));
        harness.await_state(LspLifecycleState::Ready);
        let uri = "file:///workspace/Service.java";
        harness.sync(
            uri,
            "class ServiceImpl implements Service { @Override public void run() {} }\n",
        );
        let version = harness.snapshot().open_documents[uri].version;
        let operation_id = harness.engine.next_operation_id();
        harness
            .session()
            .request_with_kind(
                SemanticRequest {
                    session_id: harness.session_id.clone(),
                    operation_id: Some(operation_id.clone()),
                    operation: LspSemanticOperation::CodeLens,
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
                operation_id.clone(),
                PendingKind::JavaNavigationMarkers,
                Some(version),
            )
            .expect("marker request should start");

        let code_lens_id = harness
            .server
            .await_request("textDocument/codeLens")
            .expect("the marker operation should request CodeLens data");
        harness.server.send(json!({
            "jsonrpc": "2.0",
            "id": code_lens_id,
            "result": []
        }));
        harness
            .server
            .await_request("java/findLinks")
            .expect("the first verification request should be in flight");

        harness.sync(
            uri,
            "class ServiceImpl implements Service { @Override public void changed() {} }\n",
        );
        let event = harness.await_event(|event| {
            event.operation_id.as_deref() == Some(operation_id.as_str())
                && event.kind == "requestCompleted"
        });
        assert_eq!(
            event.error.as_ref().map(|error| error.code.as_str()),
            Some("staleDocumentVersion")
        );
        assert_eq!(
            harness
                .server
                .messages()
                .iter()
                .filter(|message| {
                    message.get("method").and_then(Value::as_str)
                        == Some("textDocument/implementation")
                })
                .count(),
            0
        );
    }

    #[test]
    fn failed_java_marker_task_preserves_other_verified_markers() {
        let mut harness = Harness::start(|_| {});
        harness.server.complete_initialize(json!({
            "codeLensProvider": { "resolveProvider": true },
            "implementationProvider": true
        }));
        harness.await_state(LspLifecycleState::Ready);
        let uri = "file:///workspace/Service.java";
        harness.sync(uri, "interface Service { void run(); }\n");
        let version = harness.snapshot().open_documents[uri].version;
        let operation_id = harness.engine.next_operation_id();
        harness
            .session()
            .request_with_kind(
                SemanticRequest {
                    session_id: harness.session_id.clone(),
                    operation_id: Some(operation_id.clone()),
                    operation: LspSemanticOperation::CodeLens,
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
                operation_id.clone(),
                PendingKind::JavaNavigationMarkers,
                Some(version),
            )
            .expect("marker request should start");

        let code_lens_id = harness
            .server
            .await_request("textDocument/codeLens")
            .expect("the marker operation should request CodeLens data");
        harness.server.send(json!({
            "jsonrpc": "2.0",
            "id": code_lens_id,
            "result": [{
                "range": {
                    "start": { "line": 0, "character": 25 },
                    "end": { "line": 0, "character": 28 }
                },
                "command": { "title": "1 implementation" }
            }]
        }));
        let implementation_id = harness
            .server
            .await_request("textDocument/implementation")
            .expect("the method candidate should be verified");
        harness.server.send(json!({
            "jsonrpc": "2.0",
            "id": implementation_id,
            "error": { "code": -32603, "message": "index temporarily unavailable" }
        }));

        let event = harness.await_event(|event| {
            event.operation_id.as_deref() == Some(operation_id.as_str())
                && event.kind == "requestCompleted"
        });
        assert!(event.error.is_none());
        assert_eq!(
            event.result.as_ref().unwrap()["markers"]
                .as_array()
                .map(Vec::len),
            Some(1)
        );
    }

    #[test]
    fn java_navigation_marker_batch_enforces_the_task_limit() {
        let mut harness = Harness::start(|_| {});
        harness.server.complete_initialize(json!({
            "codeLensProvider": { "resolveProvider": true },
            "implementationProvider": true
        }));
        harness.await_state(LspLifecycleState::Ready);
        let uri = "file:///workspace/LargeService.java";
        let methods = (0..(MAX_JAVA_NAVIGATION_TASKS + 1))
            .map(|index| format!("    void method{index}();"))
            .collect::<Vec<_>>()
            .join("\n");
        let source = format!("interface LargeService {{\n{methods}\n}}\n");
        harness.sync(uri, &source);
        let version = harness.snapshot().open_documents[uri].version;
        let operation_id = harness.engine.next_operation_id();
        harness
            .session()
            .request_with_kind(
                SemanticRequest {
                    session_id: harness.session_id.clone(),
                    operation_id: Some(operation_id.clone()),
                    operation: LspSemanticOperation::CodeLens,
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
                operation_id.clone(),
                PendingKind::JavaNavigationMarkers,
                Some(version),
            )
            .expect("marker request should start");

        let code_lens_id = harness
            .server
            .await_request("textDocument/codeLens")
            .expect("the marker operation should request CodeLens data");
        harness.server.send(json!({
            "jsonrpc": "2.0",
            "id": code_lens_id,
            "result": []
        }));
        for index in 0..MAX_JAVA_NAVIGATION_TASKS {
            let request_id = harness
                .server
                .await_request_at("textDocument/implementation", index)
                .expect("every task within the limit should be requested");
            harness.server.send(json!({
                "jsonrpc": "2.0",
                "id": request_id,
                "result": []
            }));
        }

        let event = harness.await_event(|event| {
            event.operation_id.as_deref() == Some(operation_id.as_str())
                && event.kind == "requestCompleted"
        });
        assert_eq!(
            event.result.as_ref().unwrap()["markers"]
                .as_array()
                .map(Vec::len),
            Some(0)
        );
        assert_eq!(
            harness
                .server
                .messages()
                .iter()
                .filter(|message| {
                    message.get("method").and_then(Value::as_str)
                        == Some("textDocument/implementation")
                })
                .count(),
            MAX_JAVA_NAVIGATION_TASKS
        );
        assert!(harness.events.iter().any(|event| {
            event.kind == "log"
                && event.message.as_deref() == Some("Java navigation marker batch was limited")
        }));
    }

    #[test]
    fn java_super_navigation_normalizes_find_links_locations() {
        let mut harness = Harness::start(|_| {});
        harness.server.complete_initialize(json!({
            "definitionProvider": true
        }));
        harness.await_state(LspLifecycleState::Ready);
        let uri = "file:///workspace/ServiceImpl.java";
        harness.sync(
            uri,
            "class ServiceImpl { @Override public void run() {} }\n",
        );
        let version = harness.snapshot().open_documents[uri].version;
        let operation_id = harness.engine.next_operation_id();
        harness
            .session()
            .request_with_kind(
                SemanticRequest {
                    session_id: harness.session_id.clone(),
                    operation_id: Some(operation_id.clone()),
                    operation: LspSemanticOperation::JavaSuperImplementation,
                    uri: Some(uri.to_string()),
                    virtual_uri: None,
                    position: Some(LspPosition {
                        line: 0,
                        utf16_column: 42,
                    }),
                    new_name: None,
                    range: None,
                    diagnostics: Vec::new(),
                    completion_item: None,
                    code_action: None,
                    command: None,
                },
                operation_id.clone(),
                PendingKind::JavaResolveNavigation,
                Some(version),
            )
            .expect("super navigation should start");

        let find_links_id = harness
            .server
            .await_request("java/findLinks")
            .expect("super navigation should use JDT LS findLinks");
        harness.server.send(json!({
            "jsonrpc": "2.0",
            "id": find_links_id,
            "result": [{
                "uri": "file:///workspace/Service.java",
                "range": {
                    "start": { "line": 0, "character": 25 },
                    "end": { "line": 0, "character": 28 }
                }
            }]
        }));

        let event = harness.await_event(|event| {
            event.operation_id.as_deref() == Some(operation_id.as_str())
                && event.kind == "requestCompleted"
        });
        let locations = event.result.as_ref().unwrap()["locations"]
            .as_array()
            .expect("findLinks should be normalized to locations");
        assert_eq!(locations.len(), 1);
        assert_eq!(locations[0]["uri"], "file:///workspace/Service.java");
        assert_eq!(event.result.as_ref().unwrap()["documentVersion"], version);
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
            jdtls_launch_resources: None,
            cache_directory: None,
            workspace_fingerprint: None,
            initialize_timeout_milliseconds: 1,
            service_ready_idle_timeout_milliseconds: 1,
            service_ready_absolute_timeout_milliseconds: 1,
            request_timeout_milliseconds: 1,
            shutdown_timeout_milliseconds: 1,
        };
        assert!(validate_start_request(&request).is_err());
    }

    #[test]
    fn direct_jdtls_contract_requires_a_java_provider_and_runtime() {
        let server = ScriptedServer::new();
        let mut request = start_request(&server);
        request.jdtls_launch_resources = Some(JdtlsLaunchResources {
            launcher_jar_path: "/jdtls/plugins/equinox.jar".to_string(),
            configuration_directory: "/jdtls/config_mac".to_string(),
            lombok_agent_path: "/jdtls/lombok/lombok.jar".to_string(),
        });

        assert!(validate_start_request(&request).is_err());
        request.provider_id = "java".to_string();
        assert!(validate_start_request(&request).is_err());
        request.runtime_executable_path = Some("/jdk/bin/java".to_string());
        assert!(validate_start_request(&request).is_ok());
    }

    #[test]
    fn direct_jdtls_start_request_matches_the_shared_contract_fixture() {
        let fixture: Value = serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/fixtures/lsp/jdt-direct-launch-v1.json"
        )))
        .expect("direct JDTLS fixture should be valid JSON");
        let request: StartServerRequest = serde_json::from_value(fixture["request"].clone())
            .expect("fixture request should match the Core contract");

        validate_start_request(&request).expect("fixture request should be valid");
        let resources = request
            .jdtls_launch_resources
            .expect("fixture should use structured direct launch");
        assert_eq!(
            request.runtime_executable_path.as_deref(),
            Some("/opt/lithe/jdk/bin/java")
        );
        assert_eq!(
            resources.configuration_directory,
            "/opt/lithe/jdtls/config_mac"
        );
        assert_eq!(request.initialize_timeout_milliseconds, 30_000);
        assert_eq!(request.service_ready_idle_timeout_milliseconds, 45_000);
        assert_eq!(request.service_ready_absolute_timeout_milliseconds, 600_000);
    }
}
