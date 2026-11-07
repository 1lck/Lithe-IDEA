//! Stateful language-server sessions coordinating client state and child processes.

use super::client::{
    client_apply_server_message_for_plugin, client_initialize_for_plugin, json_rpc_error_with_code,
    json_rpc_error_with_data, json_rpc_notification, json_rpc_result,
};
use super::engine_logging::{
    EngineLog, EngineLogInput, SessionLogIdentity, SessionRole, StderrFact, StderrLines,
};
use super::plugin_server::{self, Admission, Arrival, PluginServerState};
use super::process::{LspProcessHandle, LspProcessLauncher, LspProcessSpec, SystemProcessLauncher};
use super::{
    client_change_document, client_close_document, client_feature_request_canonical,
    client_open_document, client_shutdown, frame_message, parse_server_messages,
    ClientChangeDocumentRequest, ClientCloseDocumentRequest, ClientFeatureRequest,
    ClientInitializeRequest, ClientOpenDocumentRequest, ClientShutdownRequest, FrameMessageRequest,
    LspClientDiagnostic, LspClientDocument, LspClientState, LspDocumentContentChange, LspPosition,
    LspRange, ParseServerMessagesRequest,
};
use crate::diagnostics::plugin_operations::{
    self as plugin_operations, Attempt, AttemptHandoff, AttemptSlot, Stage as AttemptStage,
    LANGUAGE_SERVER_START,
};
use crate::plugins::language_server_sessions::{
    RemoteSupport, DEFAULT_REQUEST_TIMEOUT_MILLISECONDS, DID_CHANGE_CONFIGURATION,
    MAX_REQUEST_TIMEOUT_MILLISECONDS,
};
use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

const DEFAULT_INITIALIZE_TIMEOUT_MS: u64 = 10_000;
const DEFAULT_REQUEST_TIMEOUT_MS: u64 = 30_000;
const DEFAULT_SHUTDOWN_TIMEOUT_MS: u64 = 2_000;
/// Upper bound of one build-provider request. A model request can load a
/// large build, so it may outlive the ordinary request timeout, but never
/// stays pending without a deadline.
const MAX_BUILD_PROVIDER_TIMEOUT_MS: u64 = 60 * 60_000;
/// Upper bound of one VCS-provider request. An update or check-in of a large
/// working copy over a slow link can take long, but never stays pending
/// without a deadline.
const MAX_VCS_PROVIDER_TIMEOUT_MS: u64 = 60 * 60_000;
/// Longest toolchain query a host may ask for; queries only read manager state.
const MAX_TOOLCHAIN_QUERY_TIMEOUT_MS: u64 = 60_000;
/// Bounds one provider request; the host can cancel sooner when a snapshot expires.
const MAX_KEYMAP_IMPORT_TIMEOUT_MS: u64 = 60_000;
const MONITOR_INTERVAL_MS: u64 = 10;
/// Shared plugin diagnostic budget per process session and monotonic minute.
const MAX_PLUGIN_DIAGNOSTICS_PER_MINUTE: u16 = 600;

static ENGINE: OnceLock<LspEngine> = OnceLock::new();

#[path = "engine_function_relay.rs"]
mod relay_hub;
use relay_hub::RelayHub;

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
    /// Process role supplied by the host; old hosts retain language-server routing.
    #[serde(default)]
    pub role: SessionRole,
    /// Stable VCS identity supplied explicitly by the provider catalog, never parsed from providerID.
    #[serde(default)]
    pub log_subject: Option<String>,
    /// Plugin that owns the process, for plugin-provided servers and build
    /// providers. Only such a session can serve that plugin's functions;
    /// host-owned servers leave it out.
    #[serde(default)]
    pub plugin_id: Option<String>,
    /// Declarative `languageServer/start` attempt the host began; Core records its
    /// result. Absent for v1 hosts and SDK-owned backend processes.
    #[serde(default)]
    pub startup_operation: Option<AttemptHandoff>,
    /// Host services the plugin's permissions grant the session, as the
    /// launch plan lists them (`backend.hostServices`). Only a plugin-owned
    /// session may name any; Core forwards only these `lithe/host/*`
    /// requests to the host.
    #[serde(default)]
    pub host_services: Vec<String>,
    /// Options of the granted host services, such as the icons the host
    /// draws for editor actions. Only a plugin-owned session may name any.
    #[serde(default)]
    pub host_options: super::HostOptions,
    /// Provider IDs of the plugin's verified manifest. Only a plugin-owned
    /// session with some is offered `litheToolchains`.
    #[serde(default)]
    pub toolchain_providers: Vec<String>,
    /// Shortcut import providers declared by this plugin's verified manifest.
    #[serde(default)]
    pub keymap_import_providers: Vec<String>,
    /// What the plugin backend may do with this plugin-owned language server
    /// (plan API-25): the requests it may send, the gates they wait for, and
    /// the notifications it receives. Only a plugin-owned session has one;
    /// without it the backend cannot reach the server through the host.
    #[serde(default)]
    pub session_policy: Option<super::plugin_server::SessionPolicy>,
    pub executable_path: String,
    #[serde(default)]
    pub arguments: Vec<String>,
    #[serde(default)]
    pub environment: BTreeMap<String, String>,
    pub root_uri: String,
    pub working_directory: String,
    #[serde(default)]
    pub initialization_options: Option<Value>,
    /// Settings a plugin-provided server reads through
    /// `workspace/configuration`, already expanded from the plugin's
    /// `workspaceConfiguration` template. Must be an object when present.
    #[serde(default)]
    pub workspace_configuration: Option<Value>,
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
    /// Catalog-derived channel for host diagnostic I/O; never derived from provider ID by hosts.
    pub channel: String,
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
    /// Full document text. May be omitted when `content_changes` extends a
    /// document Core already holds.
    #[serde(default)]
    pub text: String,
    /// Edits in the order they happened, each range relative to the previous result.
    #[serde(default)]
    pub content_changes: Vec<LspDocumentContentChange>,
}

/// A host-confirmed disk save, carrying the exact saved text rather than newer edits.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SaveDocumentRequest {
    pub session_id: String,
    pub uri: String,
    pub text: String,
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
    /// Full `textDocument/semanticTokens/full` with its negotiated legend.
    SemanticTokens,
    /// `textDocument/codeLens`.
    CodeLens,
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
    pub position: Option<LspPosition>,
    #[serde(default)]
    pub new_name: Option<String>,
    #[serde(default)]
    pub range: Option<LspRange>,
    #[serde(default)]
    pub diagnostics: Vec<LspClientDiagnostic>,
    /// LSP completion trigger context; validated by the shared request mapper.
    #[serde(default)]
    pub completion_context: Option<Value>,
    #[serde(default)]
    pub completion_item: Option<Value>,
    #[serde(default)]
    pub code_action: Option<Value>,
    #[serde(default)]
    pub command: Option<Value>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// One build-provider request, forwarded as `build.modelPlan` or
/// `build.dependencyPlan` planned it. The result arrives as a
/// `requestCompleted` event whose `result.value` is the provider's reply,
/// which the host passes to Core's decoder unchanged.
pub struct BuildProviderRequest {
    pub session_id: String,
    #[serde(default)]
    pub operation_id: Option<String>,
    /// `lithe/build/model` or `lithe/build/dependencies`.
    pub method: String,
    /// The plan's `provider.params`, sent as is.
    pub params: Value,
    /// Deadline of this request, in milliseconds, capped at
    /// `MAX_BUILD_PROVIDER_TIMEOUT_MS`; the session's request timeout when absent.
    #[serde(default)]
    pub timeout_milliseconds: Option<u64>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// One `toolchains/query`, addressed to a session that negotiated the provider
/// named in `params`. The result arrives as a `requestCompleted` event whose
/// `result.value` is `{ id, response }`, the complete untrusted JSON-RPC response,
/// which the host passes to `toolchains.decodeReply`.
pub struct ToolchainProviderRequest {
    pub session_id: String,
    #[serde(default)]
    pub operation_id: Option<String>,
    /// Query parameters; `toolchains.decodeReply` validates them with the reply.
    pub params: Value,
    /// Deadline of this request, capped at `MAX_TOOLCHAIN_QUERY_TIMEOUT_MS`.
    #[serde(default)]
    pub timeout_milliseconds: Option<u64>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// One shortcut import operation against an opaque, host-owned snapshot.
pub struct KeymapImportProviderRequest {
    /// Plugin-owned session which negotiated the provider.
    pub session_id: String,
    /// Optional correlation identity for cancellation and completion events.
    #[serde(default)]
    pub operation_id: Option<String>,
    /// Plugin-local identity of the selected provider.
    #[serde(rename = "providerID")]
    pub provider_id: String,
    /// Host-owned snapshot reference, scoped to this import operation.
    #[serde(rename = "snapshotID")]
    pub snapshot_id: String,
    /// Requested deadline in milliseconds, bounded by the runtime.
    #[serde(default)]
    pub timeout_milliseconds: Option<u64>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// One VCS-provider request. Core plans the method and params from the
/// operation and its arguments, so the host never writes a raw method. The
/// result arrives as a `requestCompleted` event whose `result.value` is the
/// provider's reply, which the host passes to `vcs.decodeReply`; a failure
/// carries a `vcs.*` code.
pub struct VcsProviderRequest {
    pub session_id: String,
    #[serde(default)]
    pub operation_id: Option<String>,
    /// The VCS the host launched the session for; a session that negotiated
    /// another VCS is refused.
    pub vcs: String,
    /// Operation name, such as `status` or `checkin`.
    pub operation: String,
    /// Native absolute path of the working-copy root.
    pub root: String,
    /// Absolute path of the VCS client the host resolved, when the provider
    /// declares one.
    #[serde(default)]
    pub tool: Option<String>,
    /// Operation arguments; see `crate::vcs` for each operation's shape.
    #[serde(default)]
    pub arguments: Value,
    /// Deadline of this request, in milliseconds, capped at
    /// `MAX_VCS_PROVIDER_TIMEOUT_MS`; the session's request timeout when absent.
    #[serde(default)]
    pub timeout_milliseconds: Option<u64>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// The host's answer to one `hostRequest` event: the outcome of a host
/// service a plugin backend asked for. Exactly one of `result` and `error`.
pub struct PluginHostResponse {
    pub session_id: String,
    /// The `hostRequestID` of the `hostRequest` event being answered,
    /// spelled as the event spells it.
    #[serde(rename = "hostRequestID")]
    pub host_request_id: String,
    /// The service's result; `null` for a write or delete.
    #[serde(default)]
    pub result: Option<Value>,
    /// The host could not perform the service. Its message reaches the
    /// backend, bounded. Its code passes only when it is one a host may
    /// report (`plugin_function::host_failure`); otherwise, and before
    /// protocol version 3, it is `plugin.host.failed`.
    #[serde(default)]
    pub error: Option<PluginHostFailure>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// Why the host could not perform a forwarded host-service request.
pub struct PluginHostFailure {
    pub message: String,
    /// Stable `plugin.host.*` code of the failure, from protocol version 3.
    #[serde(default)]
    pub code: Option<String>,
    /// Structured facts a backend may act on, such as the current version
    /// of a `plugin.host.versionConflict`. From protocol version 3 it
    /// reaches the backend as `error.data.details` when it is an object
    /// within `plugin_function::MAX_HOST_DETAILS_BYTES`; otherwise it is
    /// dropped and the code and message still arrive.
    #[serde(default)]
    pub details: Option<Value>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// One notification from the host to a plugin backend, such as a
/// subscription event or a changed set of workspace contexts. Core admits
/// only the methods of `plugin_function::HOST_NOTIFICATIONS`.
pub struct PluginHostNotification {
    pub session_id: String,
    pub method: String,
    pub params: Value,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Whether a host notification was written to the backend. `false` means
/// the backend negotiated a protocol version without the notification.
pub struct PluginHostNotificationResponse {
    pub delivered: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// One plugin-function invocation. The result arrives as a `requestCompleted`
/// event whose `result.value` is the function's result; failures carry a
/// stable `plugin.function.*` code. Progress arrives as `requestProgress`.
pub struct PluginFunctionRequest {
    pub session_id: String,
    #[serde(default)]
    pub operation_id: Option<String>,
    pub function: super::plugin_function::FunctionReference,
    /// Serializable function input; must be a JSON object.
    #[serde(default = "empty_object")]
    pub params: Value,
    /// Deadline of this call, in milliseconds, capped at one hour; the
    /// session's request timeout when absent.
    #[serde(default)]
    pub timeout_milliseconds: Option<u64>,
    /// Workspace context `{ contextID, generation }` the call belongs to.
    /// It reaches a backend that negotiated protocol version 3 or later as
    /// `params.context`, and is dropped for an older backend.
    #[serde(default)]
    pub context: Option<Value>,
}

fn empty_object() -> Value {
    json!({})
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// One request a plugin backend sent to its own language server through the
/// host (plan API-25). The reply arrives as a `requestCompleted` event whose
/// `result.value` is the server's result; failures carry a `plugin.host.*`
/// code as `error.code`.
pub struct PluginServerRequest {
    /// The plugin-owned language-server session the host resolved.
    pub session_id: String,
    #[serde(default)]
    pub operation_id: Option<String>,
    /// The plugin and server the backend named. Core checks that the
    /// session really is that contribution, so a stale or mistaken
    /// resolution can never reach another plugin's server.
    pub plugin_id: String,
    #[serde(rename = "serverID")]
    pub server_id: String,
    /// An LSP request method the plugin declared in `requestMethods`.
    pub method: String,
    #[serde(default = "empty_object")]
    pub params: Value,
    /// Deadline in milliseconds, 60000 when absent and at most 300000.
    #[serde(default)]
    pub timeout_milliseconds: Option<u64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// One notification a plugin backend sent to its own language server.
pub struct PluginServerNotify {
    pub session_id: String,
    pub plugin_id: String,
    #[serde(rename = "serverID")]
    pub server_id: String,
    pub method: String,
    #[serde(default = "empty_object")]
    pub params: Value,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Whether the notification reached the server. `false` means the server
/// was not initialized yet and will receive the stored configuration with
/// its `initialized` notification instead.
pub struct PluginServerNotifyResponse {
    pub delivered: bool,
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
    /// Core-derived catalog channel, present for structured log facts.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub channel: Option<String>,
    /// Plugin that owns this process; omitted for host-owned sessions.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub plugin_id: Option<String>,
    /// Explicit process role, independent of the provider's opaque ID.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub role: Option<SessionRole>,
    /// Stable catalog identity; existing v1 fields remain available.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub event: Option<String>,
    /// Catalog disk fields, validated and redacted by Core.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fields: Option<BTreeMap<String, Value>>,
    /// Canonical catalog severity for v2; independent of the preserved v1 level.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub catalog_level: Option<crate::diagnostics::record::LogLevel>,
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
    /// Plugin-defined code of a failed plugin function (`error.data.code`),
    /// passed through for the plugin's own UI; Lithe never branches on it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub plugin_error_code: Option<String>,
    /// Structured facts of a failed plugin-server request, such as the
    /// server's own error `code` and `message`, passed to the backend as the
    /// failure's details. Only `lsp.pluginServerRequest` sets it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
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
    /// Request a plugin backend sent to its own language server through
    /// `lsp.pluginServerRequest`; the answer reaches the backend verbatim.
    PluginServer,
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

/// Links one host operation to the exact backend request and function it owns.
struct PendingFunctionCall {
    function_id: String,
    /// Also serves as the opaque wire operation ID; request IDs never repeat in a session.
    request_id: String,
}

struct SessionState {
    lifecycle: LspLifecycleState,
    client: LspClientState,
    pending: BTreeMap<String, PendingRequest>,
    request_by_operation: BTreeMap<String, String>,
    /// Exact function invocation owned by each active host operation. Every
    /// terminal path removes its entry before that host operation ID can be reused.
    function_by_operation: BTreeMap<String, PendingFunctionCall>,
    /// Symbolic-link facts about the open documents, rebuilt lazily from
    /// `client.open_documents`.
    linked_document_paths: LinkedDocumentPaths,
    /// Latest workspace event per URI observed before protocol initialization.
    /// The engine owns and drains this queue exactly once after `initialized`.
    pending_workspace_file_changes: BTreeMap<String, WorkspaceFileChangeKind>,
    events: VecDeque<LspRuntimeEvent>,
    next_sequence: u64,
    initialize_deadline: Option<Instant>,
    shutdown_deadline: Option<Instant>,
    request_timeout: Duration,
    shutdown_timeout: Duration,
    terminal_event_emitted: bool,
    /// Deadline cancellations awaiting the outbound worker, never written by the monitor.
    deadline_cancellations: Vec<String>,
    /// Bounds an outbound maintenance write independently of caller deadlines.
    maintenance_write_deadline: Option<Instant>,
    /// Policy and waiting requests of a plugin-owned language server; `None`
    /// for every other session.
    plugin_server: Option<PluginServerState>,
    /// Bounds one write the function relay's lane makes to this session, so a
    /// backend that stops reading its stdin cannot hold the lane forever.
    relay_write_deadline: Option<Instant>,
    /// Backend requests for a host service awaiting `lsp.hostResponse`, by
    /// the opaque ID the host sees, with the backend's own JSON-RPC ID.
    host_requests: BTreeMap<String, Value>,
    next_host_request_id: u64,
    /// Trace is opt-in and serialized with protocol writes through outbound_order.
    detailed_diagnostics: bool,
    /// Desired trace setting retained until the initialize handshake permits notifications.
    requested_diagnostics: bool,
    /// Malformed plugin diagnostics are summarized once per process session.
    rejected_plugin_diagnostics: bool,
    /// Sender-side ingress budget uses the existing process clock, never a timer.
    plugin_diagnostics_window: Instant,
    plugin_diagnostics_count: u16,
}

struct RuntimeSession {
    /// Declarative plugin start attempt shared with `start_server`.
    startup_attempt: AttemptSlot,
    id: String,
    provider_id: String,
    /// Plugin that owns the process, if any; see `StartServerRequest::plugin_id`.
    plugin_id: Option<String>,
    log_identity: SessionLogIdentity,
    /// Fixed workspace host, inherited by protocol workers; never a global selection.
    workspace_host: Option<crate::remote::workspace::Host>,
    /// Plugin-declared settings answered to `workspace/configuration`.
    /// Replaced as a whole by `lsp.updateWorkspaceConfiguration`; never held
    /// across another lock.
    plugin_configuration: Mutex<Option<Arc<Value>>>,
    /// Workspace URI the server was initialized with; scopes indexing
    /// exclusions and other workspace-wide checks to this session's root.
    root_uri: String,
    /// Serializes policy eligibility with document/file-event publication and
    /// policy withdrawal. Acquire before outbound_order; Git scans stay outside
    /// the outbound and registry locks.
    indexing_roots: Mutex<Vec<String>>,
    indexing_revision: std::sync::atomic::AtomicU64,
    /// Serializes protocol-state commits with complete outbound message batches.
    /// Callers acquire this before `state` whenever an action can write to the
    /// server, preserving the same order in memory and on the wire.
    outbound_order: Mutex<()>,
    state: Mutex<SessionState>,
    event_signal: Condvar,
    process: Arc<dyn LspProcessHandle>,
    active: AtomicBool,
    /// The engine's cross-plugin function relay; see `engine_function_relay`.
    relay: Arc<RelayHub>,
}

/// The engine is a process-owning singleton in production, but it holds no
/// global state of its own beyond the session registry, so tests construct
/// private instances with a scripted launcher.
pub(super) struct LspEngine {
    next_session_id: AtomicU64,
    next_operation_id: AtomicU64,
    /// Shared with the relay's worker, which reaches sessions by ID.
    sessions: Arc<Mutex<BTreeMap<String, Arc<RuntimeSession>>>>,
    /// Cross-plugin function calls; every session of this engine uses it.
    relay: Arc<RelayHub>,
    /// Failed wire starts have no returned identity. Retain their cleanup
    /// responsibility here and retry disposal before another process starts.
    failed_starts: Mutex<BTreeSet<String>>,
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

/// Rejects plugin configuration that is not a JSON object, the only shape
/// `workspace/configuration` sections can be looked up in.
fn checked_workspace_configuration(
    configuration: Option<Value>,
) -> Result<Option<Value>, CoreError> {
    match configuration {
        None | Some(Value::Null) => Ok(None),
        Some(configuration @ Value::Object(_)) => Ok(Some(configuration)),
        Some(_) => Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "workspaceConfiguration must be a JSON object.",
        )),
    }
}

/// Answers one `workspace/configuration` item from plugin configuration.
///
/// A section names a dotted path (`python.analysis`); an exact top-level key
/// wins over the path so servers that use dotted keys still match. A missing
/// section answers `null`, which tells the server to use its own default.
fn configuration_section(configuration: &Value, section: Option<&str>) -> Value {
    let Some(section) = section.filter(|section| !section.is_empty()) else {
        return configuration.clone();
    };
    if let Some(value) = configuration.get(section) {
        return value.clone();
    }
    section
        .split('.')
        .try_fold(configuration, |value, key| value.get(key))
        .cloned()
        .unwrap_or(Value::Null)
}

/// `workspace/didChangeConfiguration` carrying the whole plugin configuration.
fn plugin_configuration_notification(configuration: &Value) -> String {
    json!({
        "jsonrpc": "2.0",
        "method": "workspace/didChangeConfiguration",
        "params": { "settings": configuration }
    })
    .to_string()
}

/// Replaces the plugin configuration of a running plugin-provided session.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct UpdateWorkspaceConfigurationRequest {
    pub session_id: String,
    pub configuration: Value,
}

/// Whether the change reached the server now or waits for `initialized`.
#[derive(Debug, Serialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UpdateWorkspaceConfigurationResponse {
    pub sent: bool,
}

/// Applies a plugin setting with `effect: immediate` without a restart.
///
/// The stored configuration answers later `workspace/configuration` requests;
/// an initialized server is also told through `workspace/didChangeConfiguration`
/// so servers that pull configuration only on that signal refresh too.
pub fn update_workspace_configuration(
    request: UpdateWorkspaceConfigurationRequest,
) -> Result<UpdateWorkspaceConfigurationResponse, CoreError> {
    let configuration =
        checked_workspace_configuration(Some(request.configuration))?.unwrap_or_else(|| json!({}));
    engine()
        .session(&request.session_id)?
        .update_plugin_configuration(configuration)
}

/// Withdraw excluded working copies and update supported provider import configuration.
pub(crate) fn indexing_changed(root: &Path) -> Result<(), CoreError> {
    let sessions = engine()
        .sessions
        .lock()
        .map_err(|_| CoreError::new(ErrorCode::Unknown, "LSP registry lock was poisoned"))?
        .values()
        .cloned()
        .collect::<Vec<_>>();
    apply_indexing_to_sessions(root, sessions)
}

fn apply_indexing_to_sessions(
    root: &Path,
    sessions: Vec<Arc<RuntimeSession>>,
) -> Result<(), CoreError> {
    let root_uri = url::Url::from_directory_path(root).ok();
    let canonical_root = root_uri
        .as_ref()
        .and_then(|uri| canonical_workspace_root(uri.as_str()));
    let sessions = sessions
        .into_iter()
        .filter(|session| {
            canonical_workspace_root(&session.root_uri) == canonical_root
                && session.active.load(Ordering::Acquire)
        })
        .collect::<Vec<_>>();
    if sessions.is_empty() {
        return Ok(());
    }
    let prepared = crate::project::indexing::prepare_provider_exclusions(root)?;
    let roots = crate::project::indexing::excluded_roots(root);
    let revision = prepared.as_ref().map_or(0, |policy| policy.revision);
    if let Some(policy) = &prepared {
        policy.check()?;
    }
    for session in sessions {
        if let Some(policy) = &prepared {
            policy.check()?;
        }
        if ensure_not_terminal(session.lock_state()?.lifecycle).is_err() {
            continue;
        }
        if canonical_workspace_root(&session.root_uri) != canonical_root {
            continue;
        }
        let mut previous = session.lock_indexing_roots()?;
        if *previous == roots && session.indexing_revision.load(Ordering::Acquire) == revision {
            continue;
        }
        let documents = session
            .lock_state()?
            .client
            .open_documents
            .keys()
            .cloned()
            .collect::<Vec<_>>();
        for uri in documents {
            if crate::project::indexing::uri_is_excluded(&session.root_uri, &uri)? {
                session.close_document(&uri)?;
            }
        }
        let diagnostic_uris = session
            .lock_state()?
            .client
            .diagnostics
            .keys()
            .cloned()
            .collect::<Vec<_>>();
        for uri in diagnostic_uris {
            if crate::project::indexing::uri_is_excluded(&session.root_uri, &uri)? {
                let mut state = session.lock_state()?;
                state.client.diagnostics.remove(&uri);
                state.client.diagnostic_versions.remove(&uri);
                push_diagnostics_event(&session, &mut state, &uri, None, Vec::new());
            }
        }
        let pending_uris = session
            .lock_state()?
            .pending_workspace_file_changes
            .keys()
            .cloned()
            .collect::<Vec<_>>();
        for uri in pending_uris {
            if crate::project::indexing::uri_is_excluded(&session.root_uri, &uri)? {
                session
                    .lock_state()?
                    .pending_workspace_file_changes
                    .remove(&uri);
            }
        }
        // Exclusions are folded into the configuration answered through
        // `workspace/configuration`, so an initialized server is told to pull
        // the changed sections again instead of keeping its old import scope.
        {
            let order = session.lock_outbound_order()?;
            if session.lock_state()?.client.initialized {
                if let Some(configuration) = session.plugin_configuration() {
                    session.send_messages_or_fail(
                        &order,
                        vec![plugin_configuration_notification(&configuration)],
                        "indexingChanged",
                    )?;
                }
            }
        }
        *previous = roots.clone();
        session.indexing_revision.store(revision, Ordering::Release);
    }
    Ok(())
}

/// Starts a managed language-server process and begins LSP initialization.
pub fn start_server(request: StartServerRequest) -> Result<StartServerResponse, CoreError> {
    engine().start_server(request)
}

/// Native host ownership hook; it does not add an application command.
pub fn start_server_owned(
    request: StartServerRequest,
    registered: impl FnOnce(&str),
) -> Result<StartServerResponse, CoreError> {
    engine().start_server_owned(request, registered)
}

/// Performs a bounded graceful shutdown while retaining the session record.
pub fn stop_server(request: SessionRequest) -> Result<(), CoreError> {
    engine().session(&request.session_id)?.stop()
}

impl RuntimeSession {
    /// Plugin configuration the server currently sees, if any.
    fn plugin_configuration(&self) -> Option<Arc<Value>> {
        let base = self
            .plugin_configuration
            .lock()
            .map(|configuration| configuration.clone())
            .unwrap_or_else(|poisoned| poisoned.into_inner().clone());
        crate::lsp::languages::indexing::configuration(
            &self.provider_id,
            &self.root_uri,
            base.as_deref(),
        )
        .map(Arc::new)
    }

    fn update_plugin_configuration(
        &self,
        configuration: Value,
    ) -> Result<UpdateWorkspaceConfigurationResponse, CoreError> {
        if self.plugin_id.is_none() {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Only plugin-provided language servers accept plugin configuration.",
            ));
        }
        let configuration = Arc::new(configuration);
        let outbound_order = self.lock_outbound_order()?;
        let initialized = {
            let state = self.lock_state()?;
            if matches!(
                state.lifecycle,
                LspLifecycleState::Stopping
                    | LspLifecycleState::Stopped
                    | LspLifecycleState::Failed
            ) {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "The language session is no longer running.",
                ));
            }
            // Under `outbound_order`, an uninitialized client sends the stored
            // configuration with its `initialized` notification instead.
            state.client.initialized
        };
        *self
            .plugin_configuration
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(configuration.clone());
        let messages = if initialized {
            vec![plugin_configuration_notification(
                self.plugin_configuration()
                    .as_deref()
                    .unwrap_or(&configuration),
            )]
        } else {
            Vec::new()
        };
        self.send_messages_or_fail(&outbound_order, messages, "workspaceConfigurationUpdate")?;
        Ok(UpdateWorkspaceConfigurationResponse { sent: initialized })
    }
}

/// Opens or replaces the synchronized contents of one document.
pub fn sync_document(request: SyncDocumentRequest) -> Result<SyncDocumentResponse, CoreError> {
    engine()
        .session(&request.session_id)?
        .sync_document(request)
}

/// Notifies an interested server after a successful native save. Returns false
/// for unopened documents, unsupported saves, or a save superseded by new edits.
pub fn save_document(request: SaveDocumentRequest) -> Result<bool, CoreError> {
    engine()
        .session(&request.session_id)?
        .save_document(request)
}

/// Forwards external source and build-configuration changes without restarting
/// the server or invalidating its durable workspace state.
pub fn workspace_files_changed(request: WorkspaceFilesChangedRequest) -> Result<(), CoreError> {
    engine()
        .session(&request.session_id)?
        .workspace_files_changed(request.changes)
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

/// Sends one build-provider request to a session that negotiated the protocol.
pub fn build_provider_request(
    request: BuildProviderRequest,
) -> Result<OperationResponse, CoreError> {
    let operation_id = request
        .operation_id
        .clone()
        .unwrap_or_else(|| engine().next_operation_id());
    engine()
        .session(&request.session_id)?
        .build_request(request, operation_id.clone())?;
    Ok(OperationResponse { operation_id })
}

/// Sends one `toolchains/query` to a session that negotiated its provider.
pub fn toolchain_provider_request(
    request: ToolchainProviderRequest,
) -> Result<OperationResponse, CoreError> {
    let operation_id = request
        .operation_id
        .clone()
        .unwrap_or_else(|| engine().next_operation_id());
    engine()
        .session(&request.session_id)?
        .toolchain_request(request, operation_id.clone())?;
    Ok(OperationResponse { operation_id })
}

/// Sends a shortcut import request only to a negotiated plugin provider.
pub fn keymap_import_provider_request(
    request: KeymapImportProviderRequest,
) -> Result<OperationResponse, CoreError> {
    let operation_id = request
        .operation_id
        .clone()
        .unwrap_or_else(|| engine().next_operation_id());
    engine()
        .session(&request.session_id)?
        .keymap_import_request(request, operation_id.clone())?;
    Ok(OperationResponse { operation_id })
}

/// Sends one VCS-provider request to a session that negotiated the protocol.
pub fn vcs_provider_request(request: VcsProviderRequest) -> Result<OperationResponse, CoreError> {
    let operation_id = request
        .operation_id
        .clone()
        .unwrap_or_else(|| engine().next_operation_id());
    engine()
        .session(&request.session_id)?
        .vcs_request(request, operation_id.clone())?;
    Ok(OperationResponse { operation_id })
}

/// Answers one `hostRequest` event of a plugin backend with the outcome of
/// the host service it asked for.
pub fn plugin_host_response(request: PluginHostResponse) -> Result<(), CoreError> {
    engine()
        .session(&request.session_id)?
        .host_response(request)
}

/// Sends one host notification to a plugin backend.
pub fn plugin_host_notify(
    request: PluginHostNotification,
) -> Result<PluginHostNotificationResponse, CoreError> {
    let delivered = engine()
        .session(&request.session_id)?
        .host_notify(request)?;
    Ok(PluginHostNotificationResponse { delivered })
}

/// Invokes one plugin function on a session of the function's plugin.
pub fn plugin_function_request(
    request: PluginFunctionRequest,
) -> Result<OperationResponse, CoreError> {
    let operation_id = request
        .operation_id
        .clone()
        .unwrap_or_else(|| engine().next_operation_id());
    engine()
        .session(&request.session_id)?
        .function_request(request, operation_id.clone(), None)?;
    Ok(OperationResponse { operation_id })
}

/// Sends one request of a plugin backend to the plugin's own language server.
pub fn plugin_server_request(request: PluginServerRequest) -> Result<OperationResponse, CoreError> {
    let operation_id = request
        .operation_id
        .clone()
        .unwrap_or_else(|| engine().next_operation_id());
    engine()
        .session(&request.session_id)?
        .plugin_server_request(request, operation_id.clone())?;
    Ok(OperationResponse { operation_id })
}

/// Sends one notification of a plugin backend to the plugin's own language server.
pub fn plugin_server_notify(
    request: PluginServerNotify,
) -> Result<PluginServerNotifyResponse, CoreError> {
    let delivered = engine()
        .session(&request.session_id)?
        .plugin_server_notify(request)?;
    Ok(PluginServerNotifyResponse { delivered })
}

/// Replaces the host's view of the enabled plugins and live workspace
/// contexts that the cross-plugin function relay checks calls against. Calls
/// in flight that the new view forbids end with an error.
pub fn configure_function_relay(
    snapshot: super::function_relay::RelaySnapshot,
) -> Result<(), CoreError> {
    engine().relay.configure(snapshot)
}

/// Cancels a pending semantic request in both client state and the server.
pub fn cancel_operation(request: CancelOperationRequest) -> Result<(), CoreError> {
    engine()
        .session(&request.session_id)?
        .cancel_operation(&request.operation_id)
}

/// Host-owned toggle for one session's upstream trace diagnostics.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SetDetailedDiagnosticsRequest {
    /// Opaque session returned by startServer.
    pub session_id: String,
    /// True sends verbose tracing, false sends off; default sessions start disabled.
    pub enabled: bool,
}

/// Updates the trace gate only after the corresponding ordered write succeeds.
pub fn set_detailed_diagnostics(request: SetDetailedDiagnosticsRequest) -> Result<(), CoreError> {
    engine()
        .session(&request.session_id)?
        .set_detailed_diagnostics(request.enabled)
}

/// Drains all currently queued events in deterministic sequence order.
pub fn poll_events(request: SessionRequest) -> Result<PollEventsResponse, CoreError> {
    let events = engine().session(&request.session_id)?.poll_events()?;
    Ok(PollEventsResponse { events })
}

/// Waits until queued events exist or the supplied timeout elapses.
pub fn wait_events(request: WaitEventsRequest) -> Result<PollEventsResponse, CoreError> {
    let events = engine()
        .session(&request.session_id)?
        .wait_events(Duration::from_millis(request.timeout_milliseconds))?;
    Ok(PollEventsResponse { events })
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
        let sessions = Arc::new(Mutex::new(BTreeMap::new()));
        Self {
            next_session_id: AtomicU64::new(1),
            next_operation_id: AtomicU64::new(1),
            relay: RelayHub::start(&sessions),
            sessions,
            failed_starts: Mutex::new(BTreeSet::new()),
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
        let mut registered = None;
        let result = self.start_server_owned(request, |id| registered = Some(id.to_owned()));
        if result.is_err() {
            if let Some(id) = registered {
                if self.lock_sessions()?.contains_key(&id) {
                    self.lock_failed_starts()?.insert(id);
                    // Preserve the original startup error. Incomplete cleanup
                    // stays owned; an explicit startup retry reaps it before
                    // any replacement process can be launched.
                    // log-exempt: Same failure already recorded: this cleanup follows the startup failure returned below and traced by this request's Core failure; residue stays in failed_starts and the next start reports ProcessFailed.
                    let _ = self.cleanup_failed_start();
                }
            }
        }
        result
    }

    fn lock_failed_starts(&self) -> Result<MutexGuard<'_, BTreeSet<String>>, CoreError> {
        self.failed_starts.lock().map_err(|_| {
            CoreError::new(
                ErrorCode::Unknown,
                "Failed startup cleanup lock was poisoned.",
            )
        })
    }

    fn cleanup_failed_start(&self) -> Result<(), CoreError> {
        // Serialize cleanup attempts, but never hold the session registry or
        // protocol-state lock across process disposal. Each retry owns at most
        // one two-second disposal; a backlog must not make one call unbounded.
        let mut failed = self.lock_failed_starts()?;
        if let Some(id) = failed.first().cloned() {
            if self.lock_sessions()?.contains_key(&id) {
                self.destroy(&id)?;
            }
            failed.remove(&id);
        }
        if !failed.is_empty() {
            return Err(CoreError::new(
                ErrorCode::ProcessFailed,
                "Previous language-server startup cleanup is still pending. Retry startup to continue cleanup.",
            ));
        }
        Ok(())
    }

    fn start_server_owned(
        &self,
        request: StartServerRequest,
        registered: impl FnOnce(&str),
    ) -> Result<StartServerResponse, CoreError> {
        let attempt = startup_attempt(&request);
        let result = self.start_server_attempt(request, &attempt, registered);
        // A session that already reached a terminal result took the attempt;
        // otherwise the process never started. Cancellation is not a result.
        match &result {
            Err(error) if !matches!(error.code, ErrorCode::Cancelled) => {
                plugin_operations::finish(&attempt, Some(AttemptStage::Launch));
            }
            Err(_) => plugin_operations::abandon(&attempt),
            Ok(_) => {}
        }
        result
    }

    fn start_server_attempt(
        &self,
        request: StartServerRequest,
        attempt: &AttemptSlot,
        registered: impl FnOnce(&str),
    ) -> Result<StartServerResponse, CoreError> {
        validate_start_request(&request)?;
        self.cleanup_failed_start()?;
        if crate::remote::workspace::is_remote()
            && request
                .session_policy
                .as_ref()
                .is_some_and(|policy| policy.remote == RemoteSupport::Unsupported)
        {
            return Err(CoreError::new(
                ErrorCode::NotSupported,
                "The plugin's language server does not support remote workspaces",
            ));
        }
        // Initial provider settings must include native Git decisions even when
        // no session or inventory warm-up has run. Never scan under registry locks.
        let indexing_root = canonical_workspace_path(&request.root_uri);
        let indexing_context = if let Some(root) = &indexing_root {
            crate::project::indexing::prepare_provider_exclusions(root)?
        } else {
            None
        };
        let check_indexing = || {
            if let Some(context) = &indexing_context {
                return context.check();
            }
            if indexing_root.as_ref().is_some_and(|root| {
                crate::project::indexing::active_provider_context(root).is_some()
            }) {
                return Err(CoreError::new(
                    ErrorCode::Cancelled,
                    "Indexing policy changed",
                ));
            }
            Ok(())
        };
        let session_id = format!(
            "lsp-session-{}",
            self.next_session_id.fetch_add(1, Ordering::Relaxed)
        );
        let workspace_root = PathBuf::from(&request.working_directory);
        let initialize_timeout = Duration::from_millis(request.initialize_timeout_milliseconds);
        let request_timeout = Duration::from_millis(request.request_timeout_milliseconds);
        let shutdown_timeout = Duration::from_millis(request.shutdown_timeout_milliseconds);
        let workspace_configuration =
            checked_workspace_configuration(request.workspace_configuration)?;
        let initialize = client_initialize_for_plugin(
            ClientInitializeRequest {
                state: LspClientState {
                    offered_toolchain_providers: if request.plugin_id.is_some() {
                        request.toolchain_providers.iter().cloned().collect()
                    } else {
                        Default::default()
                    },
                    offered_keymap_import_providers: if request.plugin_id.is_some() {
                        request.keymap_import_providers.iter().cloned().collect()
                    } else {
                        Default::default()
                    },
                    ..LspClientState::default()
                },
                root_uri: request.root_uri.clone(),
                process_id: (!crate::remote::workspace::is_remote())
                    .then_some(std::process::id() as i64),
                initialization_options: request.initialization_options,
            },
            request.plugin_id.is_some(),
        )?;
        let process = self.launcher.launch(LspProcessSpec {
            executable: PathBuf::from(&request.executable_path),
            arguments: request.arguments,
            working_directory: workspace_root,
            environment: request.environment,
        })?;

        let request_id = (initialize.state.next_request_id - 1).to_string();
        let now = Instant::now();
        let process_id = process.handle.process_id();
        let plugin_server = request.session_policy.map(PluginServerState::new);
        let session = Arc::new(RuntimeSession {
            startup_attempt: Arc::clone(attempt),
            id: session_id.clone(),
            log_identity: SessionLogIdentity::new(
                request.role,
                &request.provider_id,
                request.plugin_id.as_deref(),
                request.log_subject.as_deref(),
            ),
            provider_id: request.provider_id,
            plugin_id: request.plugin_id,
            workspace_host: crate::remote::workspace::current(),
            plugin_configuration: Mutex::new(workspace_configuration.map(Arc::new)),
            root_uri: request.root_uri,
            indexing_roots: Mutex::default(),
            indexing_revision: std::sync::atomic::AtomicU64::new(0),
            outbound_order: Mutex::new(()),
            state: Mutex::new(SessionState {
                lifecycle: LspLifecycleState::Created,
                client: LspClientState {
                    host_services: request.host_services.into_iter().collect(),
                    host_options: request.host_options,
                    ..initialize.state
                },
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
                function_by_operation: BTreeMap::new(),
                linked_document_paths: LinkedDocumentPaths::default(),
                pending_workspace_file_changes: BTreeMap::new(),
                events: VecDeque::new(),
                next_sequence: 1,
                initialize_deadline: Some(now + initialize_timeout),
                shutdown_deadline: None,
                request_timeout,
                shutdown_timeout,
                terminal_event_emitted: false,
                deadline_cancellations: Vec::new(),
                maintenance_write_deadline: None,
                plugin_server,
                relay_write_deadline: None,
                host_requests: BTreeMap::new(),
                next_host_request_id: 1,
                detailed_diagnostics: false,
                requested_diagnostics: false,
                rejected_plugin_diagnostics: false,
                plugin_diagnostics_window: Instant::now(),
                plugin_diagnostics_count: 0,
            }),
            event_signal: Condvar::new(),
            process: process.handle,
            active: AtomicBool::new(true),
            relay: Arc::clone(&self.relay),
        });
        session.transition(LspLifecycleState::Created, None)?;
        session.transition(LspLifecycleState::ProcessStarting, None)?;
        session.transition(LspLifecycleState::Initializing, None)?;
        session.log(
            "info",
            EngineLog::ProcessStarted,
            "Language server process started",
            None,
        );

        // Register before checking the prepared generation. A policy change
        // either retires that generation or sees this session for its update.
        self.lock_sessions()?
            .insert(session_id.clone(), session.clone());
        if let Err(error) = check_indexing() {
            // A retired start is cancelled, not a handshake failure. Abandon
            // the attempt before `fail` or the process exit can record it.
            plugin_operations::abandon(attempt);
            session.fail(
                "indexingChanged",
                "initialize",
                "Indexing policy changed during language-server startup.",
                Some(core_error_detail(&error)),
                None,
            );
            session.active.store(false, Ordering::Release);
            session.kill_process();
            // No native identity has been published yet. Forget the session
            // only after disposal proves that its process tree has exited.
            if session.process.dispose(Duration::from_secs(2)).is_ok() {
                self.lock_sessions()?.remove(&session_id);
            } else {
                registered(&session_id);
            }
            return Err(error);
        }
        // Native owners learn the identity before initialize writes can fail.
        // They keep their package barrier until destroy verifies disposal.
        registered(&session_id);
        session.spawn_readers(process.output, process.errors);
        session.spawn_monitor();
        session.spawn_outbound_maintenance();
        let outbound_order = session.lock_outbound_order()?;
        if let Err(error) = session.send_messages(&outbound_order, initialize.messages) {
            // startServer fails here, so the attempt failed to launch.
            plugin_operations::finish(attempt, Some(AttemptStage::Launch));
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

        if let Err(error) = check_indexing() {
            // The readers already run; abandon before `fail` and the kill so
            // neither the failure nor the observed exit records the cancel.
            plugin_operations::abandon(attempt);
            session.fail(
                "indexingChanged",
                "initialize",
                "Indexing policy changed during language-server startup.",
                Some(core_error_detail(&error)),
                None,
            );
            session.active.store(false, Ordering::Release);
            session.kill_process();
            // The native owner already holds this identity. Keep it until
            // destroy verifies disposal and returns a positive receipt.
            return Err(error);
        }

        Ok(StartServerResponse {
            channel: session.log_identity.channel(),
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
        session.process.dispose(Duration::from_secs(2))?;
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
    fn save_document(&self, request: SaveDocumentRequest) -> Result<bool, CoreError> {
        let outbound_order = self.lock_outbound_order()?;
        let message = {
            let state = self.lock_state()?;
            ensure_not_terminal(state.lifecycle)?;
            if state.lifecycle != LspLifecycleState::Ready {
                return Ok(false);
            }
            let Some(include_text) = state.client.text_document_save_include_text else {
                return Ok(false);
            };
            let Some(document) = state.client.open_documents.get(&request.uri) else {
                return Ok(false);
            };
            // A server may reload its working copy from the saved text. A
            // delayed save must not discard a newer editor revision already
            // synchronized.
            if *document.text != request.text {
                return Ok(false);
            }
            let mut params = json!({"textDocument": {"uri": request.uri}});
            if include_text {
                params["text"] = json!(request.text);
            }
            json!({"jsonrpc": "2.0", "method": "textDocument/didSave", "params": params})
                .to_string()
        };
        self.send_messages_or_fail(&outbound_order, vec![message], "saveDocument")?;
        Ok(true)
    }

    fn workspace_files_changed(&self, changes: Vec<WorkspaceFileChange>) -> Result<(), CoreError> {
        if changes.is_empty() {
            return Ok(());
        }
        let _indexing_order = self.lock_indexing_roots()?;
        let mut normalized = BTreeMap::new();
        for change in changes {
            if crate::project::indexing::uri_is_excluded(&self.root_uri, &change.uri)? {
                continue;
            }
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
        if normalized.is_empty() {
            return Ok(());
        }
        let outbound_order = self.lock_outbound_order()?;
        let message = {
            let mut state = self.lock_state()?;
            ensure_not_terminal(state.lifecycle)?;
            if !state.client.initialized {
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
        self.sync_document_after_policy_check(request, || {})
    }

    fn sync_document_after_policy_check(
        &self,
        request: SyncDocumentRequest,
        after_policy_check: impl FnOnce(),
    ) -> Result<SyncDocumentResponse, CoreError> {
        let _indexing_order = self.lock_indexing_roots()?;
        if crate::project::indexing::uri_is_excluded(&self.root_uri, &request.uri)? {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Document is excluded from indexing",
            ));
        }
        after_policy_check();
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
                // server reconciliation cycle or advance the semantic version.
                if request.content_changes.is_empty() && *document.text == *request.text {
                    return Ok(SyncDocumentResponse {
                        document_version: document.version.max(1),
                        changed: false,
                    });
                }
            }
            if state.client.initialized {
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
                    let text = unopened_document_text(
                        state.client.open_documents.get(&uri),
                        request.text,
                        &request.content_changes,
                    )?;
                    client_open_document(ClientOpenDocumentRequest {
                        state: state.client.clone(),
                        uri: uri.clone(),
                        language_id: request.language_id,
                        text,
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
                let text = unopened_document_text(
                    state.client.open_documents.get(&uri),
                    request.text,
                    &request.content_changes,
                )?;
                state.client.diagnostics.remove(&uri);
                state.client.diagnostic_versions.remove(&uri);
                state.client.open_documents.insert(
                    uri.clone(),
                    LspClientDocument {
                        uri,
                        language_id: request.language_id,
                        version: 0,
                        text: text.into(),
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
        self.request_with_kind(
            request,
            operation_id,
            PendingKind::Feature,
            document_version,
        )
    }

    /// Writes a build-provider request. It needs no open document, so it is
    /// not a semantic feature request; only the negotiated protocol's methods
    /// are accepted, so the host cannot use it as a generic JSON-RPC tunnel.
    fn build_request(
        &self,
        request: BuildProviderRequest,
        operation_id: String,
    ) -> Result<(), CoreError> {
        if !super::build_provider::is_build_method(&request.method) {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "This is not a build-provider request.",
            )
            .with_details(request.method));
        }
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
            if !state
                .client
                .server_capabilities
                .iter()
                .any(|feature| feature == super::build_provider::BUILD_PROVIDER_FEATURE)
            {
                return Err(CoreError::new(
                    ErrorCode::NotSupported,
                    "The process did not agree on a build-provider protocol version.",
                )
                .with_details(super::build_provider::BUILD_PROVIDER_FEATURE));
            }
            if super::build_provider::is_execution_method(&request.method)
                && !state
                    .client
                    .server_capabilities
                    .iter()
                    .any(|feature| feature == super::build_provider::EXECUTION_FEATURE)
            {
                return Err(CoreError::new(
                    ErrorCode::NotSupported,
                    "The provider did not negotiate build execution.",
                )
                .with_details("plugin.build.unavailable"));
            }
            if matches!(
                request.method.as_str(),
                super::build_provider::TEST_METHOD | super::build_provider::DISCOVER_TESTS_METHOD
            ) && !state
                .client
                .server_capabilities
                .iter()
                .any(|feature| feature == super::build_provider::TEST_EXECUTION_FEATURE)
            {
                return Err(CoreError::new(
                    ErrorCode::NotSupported,
                    "The provider did not negotiate test execution.",
                )
                .with_details("plugin.build.unavailable"));
            }
            if request.params.pointer("/launchOptions/debug").is_some()
                && !state
                    .client
                    .server_capabilities
                    .iter()
                    .any(|feature| feature == super::build_provider::RUNTIME_DEBUG_FEATURE)
            {
                return Err(CoreError::new(
                    ErrorCode::NotSupported,
                    "The provider did not negotiate runtime debug options.",
                )
                .with_details("plugin.build.unavailable"));
            }
            if request.params.get("launchOptions").is_some() {
                if request.method != super::build_provider::PREPARE_RUN_METHOD {
                    return Err(CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Launch options apply only to run preparation.",
                    ));
                }
                if !state
                    .client
                    .server_capabilities
                    .iter()
                    .any(|feature| feature == super::build_provider::RUN_OPTIONS_FEATURE)
                {
                    return Err(CoreError::new(
                        ErrorCode::NotSupported,
                        "The provider did not negotiate typed run options.",
                    )
                    .with_details("plugin.build.unavailable"));
                }
            }
            if request.params.get("selectorKind").is_some()
                || request.params.get("selectors").is_some()
            {
                if request.method != super::build_provider::TEST_METHOD {
                    return Err(CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Opaque selectors require a provider test request.",
                    ));
                }
                if !state
                    .client
                    .server_capabilities
                    .iter()
                    .any(|feature| feature == super::build_provider::TEST_SELECTORS_FEATURE)
                {
                    return Err(CoreError::new(
                        ErrorCode::NotSupported,
                        "The provider did not negotiate opaque test selectors.",
                    )
                    .with_details("plugin.build.unavailable"));
                }
            }
            if request.params.get("testResults").is_some() {
                if request.method != super::build_provider::TEST_METHOD
                    || request.params["testResults"] != json!(true)
                {
                    return Err(CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Inline test reports require a provider test request.",
                    ));
                }
                if !state
                    .client
                    .server_capabilities
                    .iter()
                    .any(|feature| feature == super::build_provider::TEST_REPORTS_FEATURE)
                {
                    return Err(CoreError::new(
                        ErrorCode::NotSupported,
                        "The provider did not negotiate inline test reports.",
                    )
                    .with_details("plugin.build.unavailable"));
                }
            }
            if matches!(
                request.method.as_str(),
                super::build_provider::CONFIGURATION_METHOD
                    | super::build_provider::EDIT_CONFIGURATION_METHOD
            ) && !state
                .client
                .server_capabilities
                .iter()
                .any(|feature| feature == super::build_provider::CONFIGURATION_FEATURE)
            {
                return Err(CoreError::new(
                    ErrorCode::NotSupported,
                    "The provider did not negotiate native configuration.",
                )
                .with_details("plugin.build.unavailable"));
            }
            if request.method == super::build_provider::PREPARE_DEBUG_METHOD
                && !state
                    .client
                    .server_capabilities
                    .iter()
                    .any(|feature| feature == super::build_provider::DEBUG_PREPARATION_FEATURE)
            {
                return Err(CoreError::new(
                    ErrorCode::NotSupported,
                    "The provider did not negotiate debug preparation.",
                )
                .with_details("plugin.build.unavailable"));
            }
            if request.method == super::build_provider::PREPARE_RUN_METHOD
                && !state
                    .client
                    .server_capabilities
                    .iter()
                    .any(|feature| feature == super::build_provider::RUN_PREPARATION_FEATURE)
            {
                return Err(CoreError::new(
                    ErrorCode::NotSupported,
                    "The provider did not negotiate run preparation.",
                )
                .with_details("plugin.build.unavailable"));
            }
            if request.params.get("modelInputs").is_some()
                && !state
                    .client
                    .server_capabilities
                    .iter()
                    .any(|feature| feature == super::build_provider::MODEL_INPUTS_FEATURE)
            {
                return Err(CoreError::new(
                    ErrorCode::NotSupported,
                    "The provider did not negotiate model inputs.",
                )
                .with_details("plugin.build.unavailable"));
            }
            let mut params = request.params;
            if super::build_provider::is_progress_method(&request.method) {
                let object = params.as_object_mut().ok_or_else(|| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Build task parameters must be an object.",
                    )
                })?;
                object.insert(
                    "operationID".to_string(),
                    json!(state.client.next_request_id.to_string()),
                );
            }
            let timeout = request
                .timeout_milliseconds
                .map(|milliseconds| {
                    Duration::from_millis(milliseconds.clamp(1, MAX_BUILD_PROVIDER_TIMEOUT_MS))
                })
                .unwrap_or(state.request_timeout);
            let response = allocate_raw_request(state.client.clone(), &request.method, params)?;
            let request_id = (response.state.next_request_id - 1).to_string();
            let now = Instant::now();
            state.client = response.state;
            state.pending.insert(
                request_id.clone(),
                PendingRequest {
                    kind: PendingKind::Feature,
                    operation_id: Some(operation_id.clone()),
                    method: request.method,
                    document_uri: None,
                    document_version: None,
                    created_at: now,
                    deadline: now + timeout,
                },
            );
            state
                .request_by_operation
                .insert(operation_id, request_id.clone());
            (response.messages, request_id)
        };
        self.send_request_or_fail(&outbound_order, messages, &request_id)
    }

    fn keymap_import_request(
        &self,
        request: KeymapImportProviderRequest,
        operation_id: String,
    ) -> Result<(), CoreError> {
        // A snapshot reference is an opaque token, never a filesystem path.
        // The future host service must separately enforce its session ownership.
        if request.snapshot_id.is_empty()
            || request.snapshot_id.len() > 128
            || !request
                .snapshot_id
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
        {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Invalid import snapshot reference.",
            ));
        }
        let outbound_order = self.lock_outbound_order()?;
        let (messages, request_id) = {
            let mut state = self.lock_state()?;
            if state.lifecycle != LspLifecycleState::Ready || !state.client.initialized {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Plugin backend is not ready.",
                ));
            }
            if state.request_by_operation.contains_key(&operation_id) {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "The operation ID is already pending.",
                ));
            }
            if !state
                .client
                .keymap_import_providers
                .contains(&request.provider_id)
            {
                return Err(CoreError::new(
                    ErrorCode::NotSupported,
                    "The plugin did not negotiate this import provider.",
                )
                .with_details("plugin.keymapImport.providerUnavailable"));
            }
            let timeout = request
                .timeout_milliseconds
                .map(|milliseconds| {
                    Duration::from_millis(milliseconds.clamp(1, MAX_KEYMAP_IMPORT_TIMEOUT_MS))
                })
                .unwrap_or(
                    state
                        .request_timeout
                        .min(Duration::from_millis(MAX_KEYMAP_IMPORT_TIMEOUT_MS)),
                );
            let response = allocate_raw_request(
                state.client.clone(),
                super::keymap_provider::IMPORT_METHOD,
                json!({"providerID": request.provider_id, "snapshotID": request.snapshot_id}),
            )?;
            let request_id = (response.state.next_request_id - 1).to_string();
            let now = Instant::now();
            state.client = response.state;
            state.pending.insert(
                request_id.clone(),
                PendingRequest {
                    kind: PendingKind::Feature,
                    operation_id: Some(operation_id.clone()),
                    method: super::keymap_provider::IMPORT_METHOD.to_string(),
                    document_uri: None,
                    document_version: None,
                    created_at: now,
                    deadline: now + timeout,
                },
            );
            state
                .request_by_operation
                .insert(operation_id, request_id.clone());
            (response.messages, request_id)
        };
        self.send_request_or_fail(&outbound_order, messages, &request_id)
    }

    /// Writes a VCS-provider request planned by `crate::vcs::plan`, which
    /// checks the operation's arguments and negotiated capability.
    fn toolchain_request(
        &self,
        request: ToolchainProviderRequest,
        operation_id: String,
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
            let provider = request.params["providerID"].as_str().unwrap_or_default();
            if !state
                .client
                .toolchain_providers
                .iter()
                .any(|negotiated| negotiated == provider)
            {
                return Err(CoreError::new(
                    ErrorCode::NotSupported,
                    "The process did not negotiate this toolchain provider.",
                )
                .with_details("plugin.toolchain.providerUnavailable"));
            }
            let timeout = request
                .timeout_milliseconds
                .map(|milliseconds| {
                    Duration::from_millis(milliseconds.clamp(1, MAX_TOOLCHAIN_QUERY_TIMEOUT_MS))
                })
                .unwrap_or(state.request_timeout);
            let response = allocate_raw_request(
                state.client.clone(),
                super::toolchain_provider::QUERY_METHOD,
                request.params,
            )?;
            let request_id = (response.state.next_request_id - 1).to_string();
            let now = Instant::now();
            state.client = response.state;
            state.pending.insert(
                request_id.clone(),
                PendingRequest {
                    kind: PendingKind::Feature,
                    operation_id: Some(operation_id.clone()),
                    method: super::toolchain_provider::QUERY_METHOD.to_string(),
                    document_uri: None,
                    document_version: None,
                    created_at: now,
                    deadline: now + timeout,
                },
            );
            state
                .request_by_operation
                .insert(operation_id, request_id.clone());
            (response.messages, request_id)
        };
        self.send_request_or_fail(&outbound_order, messages, &request_id)
    }

    fn vcs_request(
        &self,
        request: VcsProviderRequest,
        operation_id: String,
    ) -> Result<(), CoreError> {
        let operation = crate::vcs::Operation::parse(&request.operation).ok_or_else(|| {
            CoreError::new(ErrorCode::InvalidRequest, "Unknown VCS operation")
                .with_details(request.operation.clone())
        })?;
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
            let negotiation = state
                .client
                .vcs_provider
                .as_ref()
                .filter(|negotiation| negotiation.vcs == request.vcs)
                .ok_or_else(|| {
                    CoreError::new(
                        ErrorCode::NotSupported,
                        format!("The process is not a negotiated {} provider.", request.vcs),
                    )
                    .with_details("vcs.provider.unavailable")
                })?;
            let planned = crate::vcs::plan(
                operation,
                &request.root,
                request.tool.as_deref(),
                request.arguments,
                &negotiation.capabilities,
            )?;
            let timeout = request
                .timeout_milliseconds
                .map(|milliseconds| {
                    Duration::from_millis(milliseconds.clamp(1, MAX_VCS_PROVIDER_TIMEOUT_MS))
                })
                .unwrap_or(state.request_timeout);
            let response =
                allocate_raw_request(state.client.clone(), planned.method, planned.params)?;
            let request_id = (response.state.next_request_id - 1).to_string();
            let now = Instant::now();
            state.client = response.state;
            state.pending.insert(
                request_id.clone(),
                PendingRequest {
                    kind: PendingKind::Feature,
                    operation_id: Some(operation_id.clone()),
                    method: planned.method.to_string(),
                    document_uri: None,
                    document_version: None,
                    created_at: now,
                    deadline: now + timeout,
                },
            );
            state
                .request_by_operation
                .insert(operation_id, request_id.clone());
            (response.messages, request_id)
        };
        self.send_request_or_fail(&outbound_order, messages, &request_id)
    }

    /// Writes a `lithe/function/invoke` request. The plan comes from
    /// `plugin_function::plan_invocation`, so plugin identity, negotiation,
    /// and registration are checked before anything reaches the process.
    ///
    /// `caller` is the plugin whose call the relay forwards, and `None` for a
    /// call the host starts. Only the relay passes `Some`, so a host cannot
    /// name a plugin as the caller and a plugin cannot choose its own name.
    fn function_request(
        &self,
        request: PluginFunctionRequest,
        operation_id: String,
        caller: Option<&str>,
    ) -> Result<(), CoreError> {
        if caller.is_none() && relay_hub::is_relay_operation_id(&operation_id) {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "This language-server operation ID is reserved for relayed plugin calls.",
            ));
        }
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
            let negotiated = state
                .client
                .server_capabilities
                .iter()
                .any(|feature| feature == super::plugin_function::FUNCTIONS_FEATURE);
            // Progress echoes this per-request wire ID, never the reusable host ID.
            let wire_operation_id = state.client.next_request_id.to_string();
            let params = super::plugin_function::plan_invocation(
                &super::plugin_function::FunctionSession {
                    plugin_id: self.plugin_id.as_deref(),
                    negotiated,
                    functions: &state.client.plugin_functions,
                },
                &request.function,
                &wire_operation_id,
                &request.params,
            )?;
            let mut params = params;
            let version = state.client.plugin_function_version.unwrap_or(0);
            super::plugin_function::attach_context(&mut params, version, request.context.as_ref())?;
            super::plugin_function::attach_caller(&mut params, version, caller);
            let timeout = request
                .timeout_milliseconds
                .map(|milliseconds| {
                    Duration::from_millis(
                        milliseconds.clamp(1, super::plugin_function::MAX_FUNCTION_TIMEOUT_MS),
                    )
                })
                .unwrap_or(state.request_timeout);
            let response = allocate_raw_request(
                state.client.clone(),
                super::plugin_function::INVOKE_METHOD,
                params,
            )?;
            let request_id = (response.state.next_request_id - 1).to_string();
            let now = Instant::now();
            state.client = response.state;
            state.pending.insert(
                request_id.clone(),
                PendingRequest {
                    kind: PendingKind::Feature,
                    operation_id: Some(operation_id.clone()),
                    method: super::plugin_function::INVOKE_METHOD.to_string(),
                    document_uri: None,
                    document_version: None,
                    created_at: now,
                    deadline: now + timeout,
                },
            );
            state
                .request_by_operation
                .insert(operation_id.clone(), request_id.clone());
            state.function_by_operation.insert(
                operation_id,
                PendingFunctionCall {
                    function_id: request.function.function_id,
                    request_id: request_id.clone(),
                },
            );
            (response.messages, request_id)
        };
        self.send_request_or_fail(&outbound_order, messages, &request_id)
    }

    /// Sends the backend the host's answer to one forwarded host-service
    /// request. An unknown ID, including one already answered or of a session
    /// that restarted, is refused so a late answer never reaches another
    /// request.
    fn host_response(&self, response: PluginHostResponse) -> Result<(), CoreError> {
        let outbound_order = self.lock_outbound_order()?;
        let message = {
            let mut state = self.lock_state()?;
            let backend_id = state
                .host_requests
                .remove(&response.host_request_id)
                .ok_or_else(|| {
                    CoreError::new(
                        ErrorCode::InvalidRequest,
                        "No host-service request with this ID is waiting for an answer.",
                    )
                })?;
            match (response.result, response.error) {
                (_, Some(failure)) => {
                    let version = state.client.plugin_function_version.unwrap_or(0);
                    let (code, rpc_code) = if version >= super::plugin_function::CONTEXT_VERSION {
                        super::plugin_function::host_failure(failure.code.as_deref())
                    } else {
                        (super::plugin_function::codes::HOST_FAILED, -32603)
                    };
                    let mut data = json!({ "code": code });
                    if version >= super::plugin_function::CONTEXT_VERSION {
                        if let Some(details) =
                            super::plugin_function::bounded_host_details(failure.details.as_ref())
                        {
                            data["details"] = details;
                        }
                    }
                    json_rpc_error_with_data(
                        &backend_id,
                        rpc_code,
                        &super::plugin_function::bounded_host_message(&failure.message),
                        data,
                    )?
                }
                (result, None) => {
                    let result = result.unwrap_or(Value::Null);
                    if state.client.plugin_function_version.unwrap_or(0)
                        >= super::plugin_function::CONTEXT_VERSION
                        && result.to_string().len() > super::plugin_function::MAX_RESULT_BYTES
                    {
                        json_rpc_error_with_code(
                            &backend_id,
                            -32014,
                            "Host result exceeds the byte limit.",
                            super::plugin_function::codes::HOST_LIMIT_EXCEEDED,
                        )?
                    } else {
                        json_rpc_result(&backend_id, result)?
                    }
                }
            }
        };
        self.send_messages_or_fail(&outbound_order, vec![message], "hostResponse")
    }

    /// Writes one host notification to a ready plugin-owned backend.
    /// Returns `false`, writing nothing, when the backend negotiated a
    /// protocol version without the notification.
    fn host_notify(&self, notification: PluginHostNotification) -> Result<bool, CoreError> {
        let outbound_order = self.lock_outbound_order()?;
        let message = {
            let state = self.lock_state()?;
            if self.plugin_id.is_none() {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Only a plugin process receives host notifications.",
                ));
            }
            if state.lifecycle != LspLifecycleState::Ready || !state.client.initialized {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Language server is not ready.",
                ));
            }
            let delivered = super::plugin_function::host_notification(
                &notification.method,
                &notification.params,
                state.client.plugin_function_version.unwrap_or(0),
                &state.client.host_services,
            )?;
            if !delivered {
                return Ok(false);
            }
            json_rpc_notification(&notification.method, notification.params)?
        };
        self.send_messages_or_fail(&outbound_order, vec![message], "hostNotify")?;
        Ok(true)
    }

    /// Admits a backend's request to its language server: it is sent now,
    /// held behind a gate, or joined to a command that already runs.
    fn plugin_server_request(
        &self,
        request: PluginServerRequest,
        operation_id: String,
    ) -> Result<(), CoreError> {
        let outbound_order = self.lock_outbound_order()?;
        let (messages, request_id) = {
            let mut state = self.lock_state()?;
            if state.request_by_operation.contains_key(&operation_id) {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "The language-server operation ID is already pending.",
                ));
            }
            let server = plugin_server_target(
                &mut state,
                self.plugin_id.as_deref(),
                &request.plugin_id,
                &request.server_id,
            )?;
            let now = Instant::now();
            let deadline = now + plugin_server_timeout(request.timeout_milliseconds);
            let admission = server.admit_request(Arrival {
                operation_id: &operation_id,
                method: &request.method,
                params: &request.params,
                now,
                deadline,
            })?;
            if admission != Admission::Send {
                // Held and joined requests are written later, or never.
                return Ok(());
            }
            match register_plugin_server_request(
                &mut state,
                &operation_id,
                &request.method,
                request.params,
                now,
                deadline,
            ) {
                Ok(registered) => registered,
                Err(error) => {
                    if let Some(server) = state.plugin_server.as_mut() {
                        server.finish(&operation_id);
                    }
                    return Err(error);
                }
            }
        };
        self.send_request_or_fail(&outbound_order, messages, &request_id)
    }

    /// Sends a backend's notification to its language server. Returns whether
    /// it was sent now.
    fn plugin_server_notify(&self, request: PluginServerNotify) -> Result<bool, CoreError> {
        {
            let mut state = self.lock_state()?;
            let server = plugin_server_target(
                &mut state,
                self.plugin_id.as_deref(),
                &request.plugin_id,
                &request.server_id,
            )?;
            server.admit_notification(&request.method, &request.params)?;
        }
        if request.method == DID_CHANGE_CONFIGURATION {
            // The settings also answer the server's own `workspace/configuration`
            // requests, so they go through the plugin configuration.
            let settings = request
                .params
                .get("settings")
                .filter(|settings| settings.is_object())
                .cloned()
                .ok_or_else(|| {
                    CoreError::new(ErrorCode::InvalidRequest, "settings must be an object.")
                        .with_details(super::plugin_function::codes::HOST_INVALID_PARAMS)
                })?;
            return Ok(self.update_plugin_configuration(settings)?.sent);
        }
        let message = json_rpc_notification(&request.method, request.params)?;
        let outbound_order = self.lock_outbound_order()?;
        self.send_messages_or_fail(&outbound_order, vec![message], "pluginServerNotify")?;
        Ok(true)
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
                        "The document changed before the language-server request started.",
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
                LspSemanticOperation::ExecuteCommand => {
                    let command = request.command.ok_or_else(|| {
                        CoreError::new(
                            ErrorCode::InvalidRequest,
                            "This language-server request requires a command.",
                        )
                    })?;
                    allocate_raw_request(state.client.clone(), method, command)?
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
                    if !document_is_open {
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
                        completion_context: request.completion_context,
                        completion_item: request.completion_item,
                        code_action: request.code_action,
                        command: request.command,
                    };
                    client_feature_request_canonical(feature_request)?
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
        self.send_request_or_fail(&outbound_order, messages, &request_id)
    }

    /// Writes an allocated request. A write failure completes the request
    /// with an error and fails the session, because the server's view of the
    /// conversation is no longer known.
    fn send_request_or_fail(
        &self,
        outbound_order: &MutexGuard<'_, ()>,
        messages: Vec<String>,
        request_id: &str,
    ) -> Result<(), CoreError> {
        if let Err(error) = self.send_messages(outbound_order, messages) {
            self.complete_request_with_error(
                request_id,
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
            if state
                .plugin_server
                .as_ref()
                .is_some_and(|server| server.is_unsent(operation_id))
            {
                cancel_unsent_plugin_server_request(self, &mut state, operation_id);
                return Ok(());
            }
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
            state.client.pending_semantic_legends.remove(&request_id);
            state.function_by_operation.remove(operation_id);
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
            clear_function_registry(self, &mut state);
            clear_runtime_diagnostics(self, &mut state);
            transition_locked(self, &mut state, LspLifecycleState::Stopping, None);
            plugin_operations::abandon(&self.startup_attempt);
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
            pending_operation_ids: {
                let mut ids: Vec<String> = state.request_by_operation.keys().cloned().collect();
                ids.sort();
                ids
            },
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
            let _host = crate::remote::workspace::enter(output_session.workspace_host.clone());
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
            let mut chunk = [0_u8; 4096];
            let mut lines = StderrLines::default();
            let started = Instant::now();
            let emit = |fact| match fact {
                StderrFact::Line {
                    diagnostic,
                    truncated,
                } => error_session.log(
                    "debug",
                    EngineLog::StderrReceived
                        .with_fields(json!({"diagnostic": diagnostic, "truncated": truncated})),
                    "Language-server stderr",
                    Some(diagnostic),
                ),
                StderrFact::Dropped(count) => error_session.log(
                    "warning",
                    EngineLog::Dropped.with_fields(json!({"count": count})),
                    "Engine stderr lines dropped",
                    Some(format!("count={count}")),
                ),
            };
            while error_session.active.load(Ordering::Acquire) {
                match stderr.read(&mut chunk) {
                    Ok(0) => break,
                    Ok(count) => {
                        lines.feed(&chunk[..count], started.elapsed().as_millis() as u64, emit)
                    }
                    Err(error) => {
                        error_session.log_issue(
                            "warning",
                            "stderr",
                            "stderrReadFailed",
                            EngineLog::StderrReadFailed,
                            "Could not read language-server stderr",
                            Some(error.to_string()),
                        );
                        break;
                    }
                }
            }
            lines.finish(started.elapsed().as_millis() as u64, emit);
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
        self.handle_server_message_after_policy_check(message, || {})
    }

    fn handle_server_message_after_policy_check(
        &self,
        message: String,
        after_policy_check: impl FnOnce(),
    ) -> Result<(), CoreError> {
        let value: Value = serde_json::from_str(&message).map_err(|error| {
            CoreError::new(ErrorCode::ParseFailed, "Invalid LSP server JSON message.")
                .with_details(error.to_string())
        })?;
        // Diagnostics and readiness flushes must share the same policy boundary
        // as host document commits and exclusion withdrawal.
        let _indexing_order = self.lock_indexing_roots()?;
        let outbound_order = self.lock_outbound_order()?;
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
                EngineLog::ResponseSkipped.with_fields(json!(response_id)),
                "Ignored a late language-server response",
                response_id,
            );
            return Ok(());
        }
        // Only a remote workspace rewrites the message; a local one keeps the
        // value parsed above instead of parsing the same text again.
        let value = match &self.workspace_host {
            Some(host) => {
                let mapped = super::remote_process::map_message(
                    host,
                    &message,
                    false,
                    pending_before
                        .as_ref()
                        .map(|pending| pending.method.as_str()),
                )?;
                serde_json::from_str(&mapped).map_err(|error| {
                    CoreError::new(
                        ErrorCode::ParseFailed,
                        "Invalid mapped LSP server JSON message.",
                    )
                    .with_details(error.to_string())
                })?
            }
            None => value,
        };
        let method = value.get("method").and_then(Value::as_str);
        if method == Some("textDocument/publishDiagnostics") {
            if let Some(uri) = value.pointer("/params/uri").and_then(Value::as_str) {
                if crate::project::indexing::uri_is_excluded(&self.root_uri, uri).unwrap_or(true) {
                    return Ok(());
                }
            }
        }
        after_policy_check();
        if method == Some("workspace/configuration") {
            if let Some(response) = self.provider_configuration_response(&value)? {
                return self.send_messages_or_fail(
                    &outbound_order,
                    vec![response],
                    "serverRequest",
                );
            }
        }

        let reduced = {
            let mut state = self.lock_state()?;
            let redirected = if method == Some("textDocument/publishDiagnostics") {
                let state = &mut *state;
                diagnostics_addressed_to_open_document(
                    &state.client.open_documents,
                    &mut state.linked_document_paths,
                    &value,
                )
            } else {
                None
            };
            client_apply_server_message_for_plugin(
                state.client.clone(),
                redirected.as_ref().unwrap_or(&value),
                self.plugin_id.is_some(),
            )?
        };
        let mut outbound = reduced.messages;
        let mut flush_documents = false;
        let mut ready_server_info = None;
        let mut fail_initialize: Option<(String, Option<String>)> = None;
        {
            let mut state = self.lock_state()?;
            state.client = reduced.state;
            if let Some(request_id) = response_id.as_ref() {
                state.client.pending_requests.remove(request_id);
                state.client.pending_semantic_legends.remove(request_id);
                if let Some(pending) = state.pending.remove(request_id) {
                    if let Some(operation_id) = &pending.operation_id {
                        state.request_by_operation.remove(operation_id);
                        state.function_by_operation.remove(operation_id);
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
                        plugin_operations::finish(&self.startup_attempt, None);
                        state.initialize_deadline = None;
                        ready_server_info = parse_server_info(&value);
                        flush_documents = true;
                    }
                }
                Some(PendingKind::Feature)
                    if pending_before.as_ref().is_some_and(|pending| {
                        pending.method == super::plugin_function::INVOKE_METHOD
                    }) =>
                {
                    if let Some(operation_id) = pending_before
                        .as_ref()
                        .and_then(|pending| pending.operation_id.as_ref())
                    {
                        let (result, error) =
                            match super::plugin_function::invocation_outcome(&value) {
                                Ok(result) => (Some(result), None),
                                Err(failure) => (None, Some(function_runtime_error(self, failure))),
                            };
                        push_request_event(
                            self,
                            &mut state,
                            operation_id,
                            super::plugin_function::INVOKE_METHOD,
                            result,
                            error,
                        );
                    }
                }
                Some(PendingKind::Feature)
                    if pending_before.as_ref().is_some_and(|pending| {
                        super::build_provider::is_execution_method(&pending.method)
                    }) =>
                {
                    if let Some(pending) = pending_before.as_ref() {
                        if let Some(operation_id) = &pending.operation_id {
                            let (result, error) = match super::build_provider::execution_outcome(
                                &value,
                                state.client.server_capabilities.iter().any(|feature| {
                                    feature == super::build_provider::TEST_REPORTS_FEATURE
                                }),
                            ) {
                                Ok(result) => (Some(result), None),
                                Err((code, message)) => (
                                    None,
                                    Some(runtime_error(
                                        self,
                                        code,
                                        "request",
                                        Some(&pending.method),
                                        None,
                                        &message,
                                        None,
                                        None,
                                    )),
                                ),
                            };
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
                Some(PendingKind::Feature)
                    if pending_before
                        .as_ref()
                        .is_some_and(|pending| crate::vcs::is_vcs_method(&pending.method)) =>
                {
                    if let Some(pending) = pending_before.as_ref() {
                        if let Some(operation_id) = &pending.operation_id {
                            let (result, error) = match super::vcs_provider::reply_outcome(&value) {
                                Ok(result) => (Some(result), None),
                                Err(failure) => (
                                    None,
                                    Some(runtime_error(
                                        self,
                                        failure.code,
                                        "request",
                                        Some(&pending.method),
                                        None,
                                        &failure.message,
                                        None,
                                        None,
                                    )),
                                ),
                            };
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
                Some(PendingKind::Feature)
                    if pending_before.as_ref().is_some_and(|pending| {
                        pending.method == super::keymap_provider::IMPORT_METHOD
                    }) =>
                {
                    if let Some(pending) = pending_before.as_ref() {
                        if let Some(operation_id) = &pending.operation_id {
                            let (result, error) = if value.to_string().len()
                                > super::keymap_provider::MAX_REPLY_BYTES
                            {
                                (
                                    None,
                                    Some(runtime_error(
                                        self,
                                        "plugin.keymapImport.replyTooLarge",
                                        "request",
                                        Some(&pending.method),
                                        None,
                                        "The shortcut import provider reply is too large.",
                                        None,
                                        None,
                                    )),
                                )
                            } else {
                                (
                                    Some(
                                        json!({"value": {"id": value.get("id"), "response": value}}),
                                    ),
                                    None,
                                )
                            };
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
                Some(PendingKind::Feature)
                    if pending_before.as_ref().is_some_and(|pending| {
                        pending.method == super::toolchain_provider::QUERY_METHOD
                    }) =>
                {
                    if let Some(pending) = pending_before.as_ref() {
                        if let Some(operation_id) = &pending.operation_id {
                            let result = super::toolchain_provider::reply_outcome(&value);
                            push_request_event(
                                self,
                                &mut state,
                                operation_id,
                                &pending.method,
                                Some(result),
                                None,
                            );
                        }
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
                            let result = event.and_then(|event| event.result.clone());
                            // A plugin-owned server marks locations that are not
                            // files read-only; answers from other servers pass through.
                            let result = if state.plugin_server.is_some() {
                                plugin_server::normalize_navigation_result(result)
                            } else {
                                result
                            };
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
                Some(PendingKind::PluginServer) => {
                    if let Some(pending) = pending_before.as_ref() {
                        if let Some(operation_id) = &pending.operation_id {
                            let (result, error) =
                                plugin_server_answer(self, &pending.method, &value);
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
                Some(PendingKind::Shutdown) => {
                    // The reducer emits `exit` only after the shutdown response.
                    state.shutdown_deadline = Some(Instant::now() + state.shutdown_timeout);
                }
                None => {}
            }

            for event in reduced.events {
                if event.kind == "notification" {
                    outbound.extend(observe_plugin_server_notification(
                        self,
                        &mut state,
                        event.method.as_deref(),
                        event.result.as_ref(),
                    ));
                }
                if event.kind == "semanticTokensRefresh" {
                    push_semantic_tokens_refresh_event(self, &mut state);
                } else if event.kind == "functionsChanged" {
                    let result = event.result.unwrap_or_default();
                    let removed: Vec<String> = result
                        .get("removed")
                        .and_then(Value::as_array)
                        .into_iter()
                        .flatten()
                        .filter_map(Value::as_str)
                        .map(ToString::to_string)
                        .collect();
                    outbound.extend(revoke_function_calls_locked(self, &mut state, &removed));
                    push_functions_event(self, &mut state, result);
                    relay_hub::observe_functions_changed(self);
                } else if event.kind == "functionRelayRequest" {
                    outbound.extend(self.relay.answer_request(
                        self,
                        &state,
                        event.method.as_deref().unwrap_or_default(),
                        &event.result.unwrap_or_default(),
                    )?);
                } else if event.kind == "functionProgress" {
                    push_function_progress_locked(self, &mut state, event.result);
                } else if event.kind == "buildProgress" {
                    push_build_progress_locked(self, &mut state, event.result);
                } else if event.kind == "hostRequest" {
                    outbound.extend(forward_host_request_locked(
                        self,
                        &mut state,
                        event.method.unwrap_or_default(),
                        event.result.unwrap_or_default(),
                    )?);
                } else if event.kind == super::vcs_provider::NEGOTIATED_EVENT {
                    push_vcs_provider_event(self, &mut state, event.result.unwrap_or_default());
                } else if event.kind == super::toolchain_provider::NEGOTIATED_EVENT {
                    push_negotiated_provider_event(
                        self,
                        &mut state,
                        event.result.unwrap_or_default(),
                        "toolchainProviders",
                    );
                } else if event.kind == super::keymap_provider::NEGOTIATED_EVENT {
                    push_negotiated_provider_event(
                        self,
                        &mut state,
                        event.result.unwrap_or_default(),
                        "keymapImportProviders",
                    );
                } else if event.kind == "diagnostics" {
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
                    && event.method.as_deref() == Some(super::plugin_logging::METHOD)
                {
                    receive_plugin_diagnostic(self, &mut state, event.result.as_ref());
                } else if event.kind == "notification"
                    && self.plugin_id.is_some()
                    && event.method.as_deref() == Some("$/cancelRequest")
                    && cancel_host_request_locked(
                        self,
                        &mut state,
                        event.result.as_ref(),
                        &mut outbound,
                    )?
                {
                    // The backend withdrew one of its own host requests.
                } else if event.kind == "notification" {
                    let method = event.method.as_deref().unwrap_or("unknown");
                    let params = event.result.as_ref().unwrap_or(&Value::Null);
                    if method != "$/logTrace" || state.detailed_diagnostics {
                        let (identity, fields) = EngineLog::notification(method, params);
                        push_log_event(
                            self,
                            &mut state,
                            "info",
                            identity.with_fields(fields),
                            method,
                            event.result.map(|value| value.to_string()),
                        );
                    }
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
            if let Some(configuration) = self.plugin_configuration() {
                outbound.push(plugin_configuration_notification(&configuration));
            }
            outbound.extend(self.flush_queued_documents()?);
            let diagnostics_enabled = self.lock_state()?.requested_diagnostics;
            if diagnostics_enabled {
                // LSP forbids setTrace before the initialize response. This batch
                // already starts with initialized, under the same outbound lock.
                outbound.push(trace_notification(true));
            }
            self.send_messages_or_fail(&outbound_order, outbound, "serverResponse")?;
            let mut state = self.lock_state()?;
            state.detailed_diagnostics = diagnostics_enabled;
            if let Some(info) = ready_server_info {
                push_server_info_event(self, &mut state, info);
            }
            push_log_event(
                self,
                &mut state,
                "info",
                EngineLog::ProtocolInitialized,
                "Language service protocol initialized",
                None,
            );
            transition_locked(self, &mut state, LspLifecycleState::Ready, None);
            let capabilities = state.client.server_capabilities.clone();
            push_features_event(self, &mut state, capabilities);
            return Ok(());
        }
        self.send_messages_or_fail(&outbound_order, outbound, "serverResponse")?;
        Ok(())
    }

    fn provider_configuration_response(
        &self,
        message: &Value,
    ) -> Result<Option<String>, CoreError> {
        let Some(id) = message.get("id") else {
            return Ok(None);
        };
        let Some(configuration) = self.plugin_configuration() else {
            return Ok(None);
        };
        // Each item asks for one section; `scopeUri` is ignored because a
        // session carries one configuration for its whole workspace.
        let values: Vec<Value> = message
            .get("params")
            .and_then(|params| params.get("items"))
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .map(|item| {
                configuration_section(&configuration, item.get("section").and_then(Value::as_str))
            })
            .collect();
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
        let queued = {
            let state = self.lock_state()?;
            state
                .pending_workspace_file_changes
                .keys()
                .cloned()
                .chain(
                    state
                        .client
                        .open_documents
                        .values()
                        .filter(|document| document.version == 0)
                        .map(|document| document.uri.clone()),
                )
                .collect::<BTreeSet<_>>()
        };
        for uri in queued {
            if crate::project::indexing::uri_is_excluded(&self.root_uri, &uri)? {
                let mut state = self.lock_state()?;
                state.pending_workspace_file_changes.remove(&uri);
                if state
                    .client
                    .open_documents
                    .get(&uri)
                    .is_some_and(|document| document.version == 0)
                {
                    state.client.open_documents.remove(&uri);
                }
            }
        }
        let mut state = self.lock_state()?;
        flush_queued_documents_locked(&mut state)
    }

    /// One session-owned writer sends deadline cancellations off the monitor thread.
    /// The monitor remains free to terminate a stalled write and expire other callers.
    fn spawn_outbound_maintenance(self: &Arc<Self>) {
        let session = self.clone();
        thread::spawn(move || {
            while session.active.load(Ordering::Acquire) {
                session.pump_outbound_maintenance();
                thread::sleep(Duration::from_millis(MONITOR_INTERVAL_MS));
            }
        });
    }

    fn pump_outbound_maintenance(&self) {
        if !self
            .lock_state()
            .is_ok_and(|state| !state.deadline_cancellations.is_empty())
        {
            return;
        }
        let Ok(outbound_order) = self.outbound_order.try_lock() else {
            return;
        };
        let Ok(mut state) = self.lock_state() else {
            return;
        };
        let messages: Vec<String> = std::mem::take(&mut state.deadline_cancellations)
            .into_iter()
            .map(|id| {
                json!({ "jsonrpc": "2.0", "method": "$/cancelRequest", "params": { "id": id } })
                    .to_string()
            })
            .collect();
        if messages.is_empty() {
            return;
        }
        state.maintenance_write_deadline = Some(Instant::now() + state.request_timeout);
        drop(state);
        // Process termination by the monitor releases a blocked native stdin write.
        // log-exempt: Same failure already recorded: send_messages_or_fail transitions the session and emits its transport failure.
        let _ = self.send_messages_or_fail(&outbound_order, messages, "outboundMaintenance");
        if let Ok(mut state) = self.lock_state() {
            state.maintenance_write_deadline = None;
        }
    }

    fn expire_deadlines(&self) {
        self.expire_deadlines_at(Instant::now());
    }

    fn expire_deadlines_at(&self, now: Instant) {
        // Relayed calls that no callee runs yet have no session deadline.
        self.relay.expire(now);
        let mut cancellations = Vec::new();
        let mut initialize_timeout = false;
        let mut shutdown_timeout = false;
        let mut maintenance_write_timeout = false;
        let mut relay_write_timeout = false;
        if let Ok(mut state) = self.lock_state() {
            maintenance_write_timeout = state
                .maintenance_write_deadline
                .is_some_and(|deadline| now >= deadline);
            if maintenance_write_timeout {
                state.maintenance_write_deadline = None;
            }
            relay_write_timeout = state
                .relay_write_deadline
                .is_some_and(|deadline| now >= deadline);
            if relay_write_timeout {
                state.relay_write_deadline = None;
            }
            if state.lifecycle == LspLifecycleState::Initializing
                && state
                    .initialize_deadline
                    .is_some_and(|deadline| now >= deadline)
            {
                state.initialize_deadline = None;
                initialize_timeout = true;
                // Decided under the state lock, like the initialize response,
                // so exactly one of the two records the attempt.
                plugin_operations::finish(&self.startup_attempt, Some(AttemptStage::Timeout));
            }
            let expired: Vec<_> = state
                .pending
                .iter()
                .filter(|(_, pending)| {
                    matches!(
                        pending.kind,
                        PendingKind::Feature | PendingKind::PluginServer
                    ) && now >= pending.deadline
                })
                .map(|(id, _)| id.clone())
                .collect();
            for request_id in expired {
                let Some(pending) = state.pending.remove(&request_id) else {
                    continue;
                };
                state.client.pending_requests.remove(&request_id);
                state.client.pending_semantic_legends.remove(&request_id);
                if let Some(operation_id) = pending.operation_id.as_deref() {
                    state.request_by_operation.remove(operation_id);
                    state.function_by_operation.remove(operation_id);
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
            let held_expired = state
                .plugin_server
                .as_ref()
                .map(|server| server.expired_held(now))
                .unwrap_or_default();
            for waiter in held_expired {
                // Nothing was sent, so there is nothing to cancel on the wire.
                let error = runtime_error(
                    self,
                    "requestTimeout",
                    "request",
                    Some(&waiter.method),
                    None,
                    "Language-server request timed out waiting for the server to become ready.",
                    None,
                    None,
                );
                push_request_event(
                    self,
                    &mut state,
                    &waiter.operation_id,
                    &waiter.method,
                    None,
                    Some(error),
                );
            }
            if state.lifecycle == LspLifecycleState::Stopping
                && state
                    .shutdown_deadline
                    .is_some_and(|deadline| now >= deadline)
            {
                state.shutdown_deadline = None;
                shutdown_timeout = true;
                push_issue_log_event(
                    self,
                    &mut state,
                    "warning",
                    "shutdown",
                    "shutdownTimeout",
                    EngineLog::ShutdownTimedOut,
                    "Language-server shutdown timed out; forcing termination",
                    None,
                );
            }
        }
        if maintenance_write_timeout {
            self.fail(
                "transportFailed",
                "outboundMaintenance",
                "Language-server stdin write timed out.",
                None,
                None,
            );
            self.kill_process();
        } else if relay_write_timeout {
            // Killing the process releases the relay lane's blocked stdin write.
            self.fail(
                "transportFailed",
                "relayWrite",
                "Language-server stdin write timed out.",
                None,
                None,
            );
            self.kill_process();
        } else if initialize_timeout {
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
        } else if shutdown_timeout {
            self.kill_process();
        }
        if !cancellations.is_empty() {
            if let Ok(mut state) = self.lock_state() {
                if !matches!(
                    state.lifecycle,
                    LspLifecycleState::Stopped | LspLifecycleState::Failed
                ) {
                    state.deadline_cancellations.extend(cancellations);
                }
            }
        }
    }

    fn handle_process_exit(&self, exit_code: Option<i32>) {
        self.active.store(false, Ordering::Release);
        self.process.close_input();
        if let Ok(mut state) = self.lock_state() {
            let was_stopping = state.lifecycle == LspLifecycleState::Stopping;
            if !was_stopping {
                plugin_operations::finish(&self.startup_attempt, Some(AttemptStage::Exit));
            }
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
            state.client.pending_semantic_legends.remove(request_id);
            if let Some(operation_id) = pending.operation_id.as_deref() {
                state.request_by_operation.remove(operation_id);
                state.function_by_operation.remove(operation_id);
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
            // Timeouts were already taken by their caller; every other terminal
            // failure before `initialize` succeeded is a handshake failure.
            plugin_operations::finish(&self.startup_attempt, Some(AttemptStage::Initialize));
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

    fn set_detailed_diagnostics(&self, enabled: bool) -> Result<(), CoreError> {
        let order = self.lock_outbound_order()?;
        let mut state = self.lock_state()?;
        let lifecycle = state.lifecycle;
        if matches!(
            lifecycle,
            LspLifecycleState::Stopped | LspLifecycleState::Failed | LspLifecycleState::Stopping
        ) {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "The session is no longer running.",
            ));
        }
        if !state.client.initialized {
            state.requested_diagnostics = enabled;
            return Ok(());
        }
        drop(state);
        self.send_messages_or_fail(&order, vec![trace_notification(enabled)], "setTrace")?;
        let mut state = self.lock_state()?;
        state.requested_diagnostics = enabled;
        state.detailed_diagnostics = enabled;
        Ok(())
    }

    fn log(
        &self,
        level: &str,
        identity: impl Into<EngineLogInput>,
        message: &str,
        detail: Option<String>,
    ) {
        if let Ok(mut state) = self.lock_state() {
            push_log_event(self, &mut state, level, identity, message, detail);
        }
    }

    fn log_issue(
        &self,
        level: &str,
        stage: &str,
        code: &str,
        identity: impl Into<EngineLogInput>,
        message: &str,
        detail: Option<String>,
    ) {
        if let Ok(mut state) = self.lock_state() {
            push_issue_log_event(
                self, &mut state, level, stage, code, identity, message, detail,
            );
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
            let message = match &self.workspace_host {
                Some(host) => super::remote_process::map_message(host, &message, true, None)?,
                None => message,
            };
            let frame = frame_message(FrameMessageRequest { message })?.frame;
            self.process.write_input(frame.as_bytes())?;
        }
        Ok(())
    }

    fn kill_process(&self) {
        self.process.terminate();
        if let Some(error) = self.process.take_termination_failure() {
            // The session owns process recovery; WARN reports cleanup degradation.
            // Reuse the role routing and runtime envelope without adding a v1 log row.
            if let Ok(mut state) = self.lock_state() {
                let category = format!("{:?}", error.kind());
                let error = runtime_error(
                    self,
                    "processCleanupFailed",
                    "cleanup",
                    None,
                    None,
                    "Engine process cleanup failed",
                    None,
                    None,
                );
                let input = EngineLog::ProcessCleanupFailed.with_fields(json!({}));
                let (id, mut fields) =
                    input
                        .identity
                        .fact(&self.log_identity, &input.fields, Some(&error));
                fields.insert("error_code".into(), json!(category));
                fields.insert("error_domain".into(), json!("io"));
                push_cleanup_fact(self, &mut state, id, fields, error);
            }
        }
    }

    fn lock_outbound_order(&self) -> Result<MutexGuard<'_, ()>, CoreError> {
        self.outbound_order.lock().map_err(|_| {
            CoreError::new(
                ErrorCode::Unknown,
                "Language-server outbound ordering lock was poisoned.",
            )
        })
    }

    fn lock_indexing_roots(&self) -> Result<MutexGuard<'_, Vec<String>>, CoreError> {
        self.indexing_roots
            .lock()
            .map_err(|_| CoreError::new(ErrorCode::Unknown, "LSP indexing lock was poisoned"))
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

fn trace_notification(enabled: bool) -> String {
    json!({"jsonrpc":"2.0", "method":"$/setTrace", "params":{"value": if enabled { "verbose" } else { "off" }}}).to_string()
}

fn validate_start_request(request: &StartServerRequest) -> Result<(), CoreError> {
    if request.provider_id.trim().is_empty() {
        return Err(invalid_field("providerId"));
    }
    // A host-owned server is no plugin's backend, and a service Core does not
    // know could never be forwarded.
    if !request.host_services.is_empty()
        && (request.plugin_id.is_none()
            || request
                .host_services
                .iter()
                .any(|service| !super::plugin_function::is_host_grant(service)))
    {
        return Err(invalid_field("hostServices"));
    }
    if let Some(policy) = &request.session_policy {
        policy.validate(request.plugin_id.as_deref())?;
    }
    if !request.host_options.is_empty()
        && (request.plugin_id.is_none()
            || request
                .host_options
                .editor
                .as_ref()
                .is_some_and(|editor| editor.validate().is_err()))
    {
        return Err(invalid_field("hostOptions"));
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

/// The file a `file:` URI resolves to once symbolic links are followed, or
/// `None` for other schemes and for files that do not exist.
fn resolved_file_of_uri(uri: &str) -> Option<PathBuf> {
    let path = url::Url::parse(uri).ok()?.to_file_path().ok()?;
    crate::remote::workspace_io::canonicalize(path).ok()
}

/// Which open documents the host reached through a symbolic link.
///
/// Only such a document can be the target of a diagnostics rewrite, so the
/// rest are remembered as examined and never resolved again while open.
#[derive(Default)]
struct LinkedDocumentPaths {
    /// Open documents whose file has already been resolved.
    examined: BTreeSet<String>,
    /// Resolved file of each examined document that differs from its own
    /// path, keyed by the document's URI.
    resolved: BTreeMap<String, PathBuf>,
}

impl LinkedDocumentPaths {
    /// Drops closed documents and resolves each newly opened one once.
    fn refresh(&mut self, open_documents: &BTreeMap<String, LspClientDocument>) {
        self.examined.retain(|uri| open_documents.contains_key(uri));
        self.resolved
            .retain(|uri, _| open_documents.contains_key(uri));
        for uri in open_documents.keys() {
            if self.examined.contains(uri) {
                continue;
            }
            let Some(resolved) = resolved_file_of_uri(uri) else {
                // Not on disk yet (an unsaved document); look again next time.
                continue;
            };
            self.examined.insert(uri.clone());
            let own = url::Url::parse(uri)
                .ok()
                .and_then(|url| url.to_file_path().ok());
            if own.as_ref() != Some(&resolved) {
                self.resolved.insert(uri.clone(), resolved);
            }
        }
    }
}

/// Re-addresses published diagnostics to the open document they describe.
///
/// A server reports a file at its resolved location while the host may have
/// opened it through a symbolic link (a server may answer `/private/tmp/...`
/// for a document opened as `/tmp/...` on macOS). The client reducer matches URIs
/// textually and would drop such diagnostics, so when no open document carries
/// the published URI this returns the message rewritten to the URI of the open
/// document that resolves to the same file. Returns `None` when the message
/// needs no change.
///
/// Servers publish for many files that are not open, so this runs on a hot
/// path. Only documents opened through a link can be rewrite targets, and
/// `linked` remembers those, which makes the common case free of file-system
/// calls and the linked case a single `canonicalize` of the published file.
fn diagnostics_addressed_to_open_document(
    open_documents: &BTreeMap<String, LspClientDocument>,
    linked: &mut LinkedDocumentPaths,
    message: &Value,
) -> Option<Value> {
    let published = message.get("params")?.get("uri")?.as_str()?;
    if open_documents.contains_key(published) {
        return None;
    }
    linked.refresh(open_documents);
    if linked.resolved.is_empty() {
        return None;
    }
    let target = resolved_file_of_uri(published)?;
    let document_uri = linked
        .resolved
        .iter()
        .find(|(_, resolved)| **resolved == target)
        .map(|(uri, _)| uri.clone())?;
    let mut message = message.clone();
    message["params"]["uri"] = Value::String(document_uri);
    Some(message)
}

/// The workspace directory with symbolic links resolved, when it exists.
///
/// Resolving links touches the file system, so it happens here in the engine
/// rather than in the pure normalizer that receives the result.
fn canonical_workspace_path(root_uri: &str) -> Option<PathBuf> {
    let path = url::Url::parse(root_uri).ok()?.to_file_path().ok()?;
    // Core policy identity uses the native canonical path, including Windows'
    // verbatim prefix. A protocol/display path is not a policy registry key.
    crate::remote::workspace_io::canonicalize(path).ok()
}

fn canonical_workspace_root(root_uri: &str) -> Option<String> {
    let canonical = canonical_workspace_path(root_uri)?;
    let canonical = canonical.to_string_lossy().replace('\\', "/");
    // Windows canonical paths carry a verbatim `\\?\` prefix that language servers never report.
    Some(
        canonical
            .strip_prefix("//?/UNC/")
            .map(|rest| format!("//{rest}"))
            .or_else(|| canonical.strip_prefix("//?/").map(str::to_string))
            .unwrap_or(canonical),
    )
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
        LspSemanticOperation::ExecuteCommand => "workspace/executeCommand",
        LspSemanticOperation::InlayHints => "textDocument/inlayHint",
        LspSemanticOperation::FoldingRanges => "textDocument/foldingRange",
        LspSemanticOperation::SemanticTokens => "textDocument/semanticTokens/full",
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
        LspSemanticOperation::ExecuteCommand => Some("executeCommand"),
        LspSemanticOperation::InlayHints => Some("inlayHints"),
        LspSemanticOperation::FoldingRanges => Some("foldingRanges"),
        LspSemanticOperation::SemanticTokens => Some("semanticTokens"),
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
    mut event: LspRuntimeEvent,
) {
    if event.event.is_some() {
        let (id, fields) = (
            event.event.take().expect("source catalog identity"),
            event.fields.take().expect("source catalog fields"),
        );
        let level = if id == "log.dropped" {
            Some(crate::diagnostics::record::LogLevel::Warn)
        } else {
            crate::diagnostics::catalog::event_by_id(&id).map(|entry| entry.level)
        };
        // In-memory v1 detail is retained for old hosts. The v2 fields always pass
        // the same normalization and catalog routing boundary as persisted facts.
        // A fact that fails that boundary keeps only its v1 fields; the runtime
        // event itself is never dropped and Core never panics on source data.
        if let Some(level) = level {
            let mut fact = crate::diagnostics::record::StructuredLogEvent {
                ts: String::new(),
                level,
                seq: 0,
                event: id.clone(),
                op: None,
                msg: String::new(),
                fields,
            };
            if let Ok(channel) = crate::diagnostics::record::prepare_catalog_event(
                &mut fact,
                &json!({"channel": session.log_identity.channel()}),
            ) {
                event.channel = Some(channel);
                event.plugin_id = session.plugin_id.clone();
                event.role = Some(session.log_identity.role);
                event.event = Some(id);
                event.fields = Some(fact.fields);
                event.catalog_level = Some(fact.level);
            }
        }
    }
    state.events.push_back(event);
    session.event_signal.notify_all();
}

// Cleanup failure is a log row, never a state change: hosts take the latest
// `stateChanged` as the session state, so a stateless one would erase `failed`.
fn push_cleanup_fact(
    session: &RuntimeSession,
    state: &mut SessionState,
    id: String,
    fields: std::collections::BTreeMap<String, Value>,
    error: LspRuntimeError,
) {
    let sequence = take_sequence(state);
    enqueue_runtime_event(
        session,
        state,
        LspRuntimeEvent {
            kind: "log".to_string(),
            channel: None,
            plugin_id: None,
            role: None,
            event: Some(id),
            fields: Some(fields),
            catalog_level: None,
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
            error: Some(error),
            capabilities: None,
            server_info: None,
            level: Some("warning".to_string()),
            message: Some("Engine process cleanup failed".to_string()),
            detail: None,
        },
    );
}

// Only a declarative language server carries a host attempt. SDK backends report
// their own operations through `lithe/log`, so a stray handoff on another role is
// ignored rather than rejecting the start. The handoff names its plugin, since a
// plugin API 1 server starts with no session plugin; a session another plugin
// owns never takes the attempt, so no fact lands on a plugin that did not run.
fn startup_attempt(request: &StartServerRequest) -> AttemptSlot {
    match &request.startup_operation {
        Some(handoff)
            if request.role == SessionRole::LanguageServer
                && request
                    .plugin_id
                    .as_ref()
                    .is_none_or(|owner| *owner == handoff.plugin_id) =>
        {
            Attempt::slot(&LANGUAGE_SERVER_START, handoff.clone())
        }
        _ => Attempt::none(),
    }
}

fn transition_locked(
    session: &RuntimeSession,
    state: &mut SessionState,
    lifecycle: LspLifecycleState,
    error: Option<LspRuntimeError>,
) {
    state.lifecycle = lifecycle;
    relay_hub::observe_lifecycle(session, lifecycle);
    let (id, fields) = EngineLog::SessionUpdated.fact(
        &session.log_identity,
        &json!({"state": lifecycle}),
        error.as_ref(),
    );
    let sequence = take_sequence(state);
    enqueue_runtime_event(
        session,
        state,
        LspRuntimeEvent {
            kind: "stateChanged".to_string(),
            channel: None,
            plugin_id: None,
            role: None,
            event: Some(id),
            fields: Some(fields),
            catalog_level: None,
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
    if state
        .plugin_server
        .as_ref()
        .is_some_and(|server| server.owns(operation_id))
    {
        complete_plugin_server_request(session, state, operation_id, method, result, error);
        return;
    }
    // No host operation waits for a relayed call: the relay answers the
    // calling plugin, so the event never reaches the host.
    if relay_hub::is_relayed_operation(operation_id, method) {
        session.relay.callee_finished(
            &session.id,
            operation_id,
            relay_hub::callee_outcome(result, error),
        );
        return;
    }
    enqueue_request_completed(session, state, operation_id, method, result, error);
}

/// Ends a request the backend sent to its plugin-owned language server. This
/// is the only place where the session policy releases such an operation, so
/// every way a request can end (answer, cancel, timeout, session failure)
/// leaves the policy consistent. Requests that joined a running command
/// finish with the same result or error.
fn complete_plugin_server_request(
    session: &RuntimeSession,
    state: &mut SessionState,
    operation_id: &str,
    method: &str,
    result: Option<Value>,
    mut error: Option<LspRuntimeError>,
) {
    if let Some(error) = error.as_mut() {
        error.code = plugin_server::host_error_code(&error.code).to_string();
    }
    let joined = state
        .plugin_server
        .as_mut()
        .map(|server| server.finish(operation_id))
        .unwrap_or_default();
    for waiter in joined {
        enqueue_request_completed(
            session,
            state,
            &waiter.operation_id,
            &waiter.method,
            result.clone(),
            error.clone(),
        );
    }
    enqueue_request_completed(session, state, operation_id, method, result, error);
}

fn enqueue_request_completed(
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
            channel: None,
            plugin_id: None,
            role: None,
            event: None,
            fields: None,
            catalog_level: None,
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

/// Resolves a function mapping only while both pending tables still own its exact request.
fn pending_function_request<'a>(
    state: &'a SessionState,
    operation_id: &str,
    call: &PendingFunctionCall,
) -> Option<&'a PendingRequest> {
    if state.request_by_operation.get(operation_id) != Some(&call.request_id)
        || state
            .client
            .pending_requests
            .get(&call.request_id)
            .map(String::as_str)
            != Some(super::plugin_function::INVOKE_METHOD)
    {
        return None;
    }
    state.pending.get(&call.request_id).filter(|pending| {
        pending.kind == PendingKind::Feature
            && pending.method == super::plugin_function::INVOKE_METHOD
            && pending.operation_id.as_deref() == Some(operation_id)
    })
}

/// Ends every running call of the withdrawn functions with
/// `plugin.function.revoked` and returns the `$/cancelRequest` messages
/// telling the backend to stop. A reply that still arrives is late and is
/// ignored like any reply to a request that is no longer pending.
fn revoke_function_calls_locked(
    session: &RuntimeSession,
    state: &mut SessionState,
    removed: &[String],
) -> Vec<String> {
    let revoked: Vec<String> = state
        .function_by_operation
        .iter()
        .filter(|(operation, call)| {
            removed.contains(&call.function_id)
                && pending_function_request(state, operation, call).is_some()
        })
        .map(|(operation, _)| operation.clone())
        .collect();
    let mut cancellations = Vec::new();
    for operation_id in revoked {
        state.function_by_operation.remove(&operation_id);
        let Some(request_id) = state.request_by_operation.remove(&operation_id) else {
            continue;
        };
        state.pending.remove(&request_id);
        state.client.pending_requests.remove(&request_id);
        let failure = super::plugin_function::FunctionFailure {
            code: super::plugin_function::codes::REVOKED,
            message: "The plugin withdrew this function while it was running.".to_string(),
            plugin_error_code: None,
        };
        let error = function_runtime_error(session, failure);
        push_request_event(
            session,
            state,
            &operation_id,
            super::plugin_function::INVOKE_METHOD,
            None,
            Some(error),
        );
        cancellations.push(
            json!({
                "jsonrpc": "2.0",
                "method": "$/cancelRequest",
                "params": { "id": request_id }
            })
            .to_string(),
        );
    }
    cancellations
}

/// A wire request ID identifies one exact build operation in this session.
/// Cancellation/completion removes it from pending, so late progress is inert.
fn push_build_progress_locked(
    session: &RuntimeSession,
    state: &mut SessionState,
    progress: Option<Value>,
) {
    let Some(mut progress) = progress else {
        return;
    };
    let Some(id) = progress.get("operationID").and_then(Value::as_str) else {
        return;
    };
    let Some(pending) = state.pending.get(id) else {
        return;
    };
    if !super::build_provider::is_progress_method(&pending.method) {
        return;
    }
    let Some(operation_id) = pending.operation_id.clone() else {
        return;
    };
    progress["operationID"] = json!(operation_id);
    let method = pending.method.clone();
    let sequence = take_sequence(state);
    enqueue_runtime_event(
        session,
        state,
        LspRuntimeEvent {
            kind: "requestProgress".to_string(),
            channel: None,
            plugin_id: None,
            role: None,
            event: None,
            fields: None,
            catalog_level: None,
            sequence,
            provider_id: session.provider_id.clone(),
            session_id: session.id.clone(),
            state: None,
            operation_id: Some(operation_id),
            method: Some(method),
            uri: None,
            version: None,
            diagnostics: None,
            result: Some(progress),
            error: None,
            capabilities: None,
            server_info: None,
            level: None,
            message: None,
            detail: None,
        },
    );
}

/// Publishes a progress report of a call that is still running. Reports for
/// an unknown, finished, cancelled, or revoked operation are dropped, so a
/// late report never revives an ended call in the host.
fn push_function_progress_locked(
    session: &RuntimeSession,
    state: &mut SessionState,
    progress: Option<Value>,
) {
    let Some(mut progress) = progress else {
        return;
    };
    let Some(wire_operation_id) = progress.get("operationID").and_then(Value::as_str) else {
        return;
    };
    let Some(operation_id) = state
        .function_by_operation
        .iter()
        .find_map(|(operation, call)| {
            (call.request_id == wire_operation_id
                && pending_function_request(state, operation, call).is_some())
            .then(|| operation.clone())
        })
    else {
        return;
    };
    progress["operationID"] = json!(operation_id);
    let sequence = take_sequence(state);
    enqueue_runtime_event(
        session,
        state,
        LspRuntimeEvent {
            kind: "requestProgress".to_string(),
            channel: None,
            plugin_id: None,
            role: None,
            event: None,
            fields: None,
            catalog_level: None,
            sequence,
            provider_id: session.provider_id.clone(),
            session_id: session.id.clone(),
            state: None,
            operation_id: Some(operation_id),
            method: Some(super::plugin_function::INVOKE_METHOD.to_string()),
            uri: None,
            version: None,
            diagnostics: None,
            result: Some(progress),
            error: None,
            capabilities: None,
            server_info: None,
            level: None,
            message: None,
            detail: None,
        },
    );
}

/// Publishes the VCS and capabilities a provider negotiated, so the host can
/// check the VCS against the manifest entry and decide which actions to show.
fn push_vcs_provider_event(session: &RuntimeSession, state: &mut SessionState, result: Value) {
    let sequence = take_sequence(state);
    enqueue_runtime_event(
        session,
        state,
        LspRuntimeEvent {
            kind: "vcsProvider".to_string(),
            channel: None,
            plugin_id: None,
            role: None,
            event: None,
            fields: None,
            catalog_level: None,
            sequence,
            provider_id: session.provider_id.clone(),
            session_id: session.id.clone(),
            state: None,
            operation_id: None,
            method: None,
            uri: None,
            version: None,
            diagnostics: None,
            result: Some(result),
            error: None,
            capabilities: None,
            server_info: None,
            level: None,
            message: None,
            detail: None,
        },
    );
}

/// Publishes the providers a backend selected, so the host queries only those.
fn push_negotiated_provider_event(
    session: &RuntimeSession,
    state: &mut SessionState,
    result: Value,
    kind: &str,
) {
    let sequence = take_sequence(state);
    enqueue_runtime_event(
        session,
        state,
        LspRuntimeEvent {
            kind: kind.to_string(),
            channel: None,
            plugin_id: None,
            role: None,
            event: None,
            fields: None,
            catalog_level: None,
            sequence,
            provider_id: session.provider_id.clone(),
            session_id: session.id.clone(),
            state: None,
            operation_id: None,
            method: None,
            uri: None,
            version: None,
            diagnostics: None,
            result: Some(result),
            error: None,
            capabilities: None,
            server_info: None,
            level: None,
            message: None,
            detail: None,
        },
    );
}

/// Handles a backend's `$/cancelRequest` for one of its own pending host
/// requests: the backend gets `plugin.host.cancelled` at once, so the
/// pending slot frees without waiting for the host, and the host gets a
/// `hostRequestCancelled` event naming the `hostRequestID` so it can stop
/// the work. A later answer from the host for that ID is refused like any
/// unknown ID. Returns false when the notification names no pending host
/// request, so it is handled like any other notification.
fn cancel_host_request_locked(
    session: &RuntimeSession,
    state: &mut SessionState,
    params: Option<&Value>,
    outbound: &mut Vec<String>,
) -> Result<bool, CoreError> {
    if state.client.plugin_function_version.unwrap_or(0) < super::plugin_function::CONTEXT_VERSION {
        return Ok(false);
    }
    let Some(backend_id) = params.and_then(|params| params.get("id")) else {
        return Ok(false);
    };
    let Some(host_request_id) = state
        .host_requests
        .iter()
        .find(|(_, pending)| *pending == backend_id)
        .map(|(host_request_id, _)| host_request_id.clone())
    else {
        // Not a host request: it may name a call the backend relayed to
        // another plugin.
        return Ok(session.relay.cancel_from_caller(&session.id, backend_id));
    };
    let backend_id = state
        .host_requests
        .remove(&host_request_id)
        .unwrap_or(Value::Null);
    outbound.push(json_rpc_error_with_code(
        &backend_id,
        -32800,
        "The plugin process cancelled this host-service request.",
        super::plugin_function::codes::HOST_CANCELLED,
    )?);
    let sequence = take_sequence(state);
    enqueue_runtime_event(
        session,
        state,
        LspRuntimeEvent {
            kind: "hostRequestCancelled".to_string(),
            channel: None,
            plugin_id: None,
            role: None,
            event: None,
            fields: None,
            catalog_level: None,
            sequence,
            provider_id: session.provider_id.clone(),
            session_id: session.id.clone(),
            state: None,
            operation_id: None,
            method: None,
            uri: None,
            version: None,
            diagnostics: None,
            result: Some(json!({ "hostRequestID": host_request_id })),
            error: None,
            capabilities: None,
            server_info: None,
            level: None,
            message: None,
            detail: None,
        },
    );
    Ok(true)
}

/// Publishes the session's registered functions after a registry change.
/// Publishes a backend's well-formed host-service request as `hostRequest`,
/// or answers it at once when the session already has the most requests the
/// host may owe it. Returns the messages to send to the backend.
fn forward_host_request_locked(
    session: &RuntimeSession,
    state: &mut SessionState,
    method: String,
    request: Value,
) -> Result<Vec<String>, CoreError> {
    let backend_id = request.get("id").cloned().unwrap_or(Value::Null);
    if state.host_requests.len() >= super::plugin_function::MAX_PENDING_HOST_REQUESTS {
        let version = state.client.plugin_function_version.unwrap_or(0);
        let code = if version >= super::plugin_function::CONTEXT_VERSION {
            super::plugin_function::codes::HOST_LIMIT_EXCEEDED
        } else {
            super::plugin_function::codes::HOST_FAILED
        };
        return Ok(vec![json_rpc_error_with_code(
            &backend_id,
            super::plugin_function::host_rpc_code(code),
            "Too many host-service requests are waiting for the host.",
            code,
        )?]);
    }
    let host_request_id = format!("host-{}", state.next_host_request_id);
    state.next_host_request_id += 1;
    state
        .host_requests
        .insert(host_request_id.clone(), backend_id);
    let sequence = take_sequence(state);
    enqueue_runtime_event(
        session,
        state,
        LspRuntimeEvent {
            kind: "hostRequest".to_string(),
            channel: None,
            plugin_id: None,
            role: None,
            event: None,
            fields: None,
            catalog_level: None,
            sequence,
            provider_id: session.provider_id.clone(),
            session_id: session.id.clone(),
            state: None,
            operation_id: None,
            method: Some(method),
            uri: None,
            version: None,
            diagnostics: None,
            result: Some(json!({
                "hostRequestID": host_request_id,
                "service": request.get("service").cloned().unwrap_or(Value::Null),
                "params": request.get("params").cloned().unwrap_or(Value::Null),
            })),
            error: None,
            capabilities: None,
            server_info: None,
            level: None,
            message: None,
            detail: None,
        },
    );
    Ok(Vec::new())
}

fn push_functions_event(session: &RuntimeSession, state: &mut SessionState, result: Value) {
    let sequence = take_sequence(state);
    enqueue_runtime_event(
        session,
        state,
        LspRuntimeEvent {
            kind: "functionsChanged".to_string(),
            channel: None,
            plugin_id: None,
            role: None,
            event: None,
            fields: None,
            catalog_level: None,
            sequence,
            provider_id: session.provider_id.clone(),
            session_id: session.id.clone(),
            state: None,
            operation_id: None,
            method: None,
            uri: None,
            version: None,
            diagnostics: None,
            result: Some(result),
            error: None,
            capabilities: None,
            server_info: None,
            level: None,
            message: None,
            detail: None,
        },
    );
}

fn function_runtime_error(
    session: &RuntimeSession,
    failure: super::plugin_function::FunctionFailure,
) -> LspRuntimeError {
    let mut error = runtime_error(
        session,
        failure.code,
        "request",
        Some(super::plugin_function::INVOKE_METHOD),
        None,
        &failure.message,
        None,
        None,
    );
    error.plugin_error_code = failure.plugin_error_code;
    error
}

/// The plugin-owned server a call targets, after checking that the session
/// is that contribution and can take requests now.
fn plugin_server_target<'a>(
    state: &'a mut SessionState,
    session_plugin_id: Option<&str>,
    plugin_id: &str,
    server_id: &str,
) -> Result<&'a mut PluginServerState, CoreError> {
    let ready = state.lifecycle == LspLifecycleState::Ready && state.client.initialized;
    let server = state
        .plugin_server
        .as_mut()
        .ok_or_else(plugin_server::foreign_contribution)?;
    server.check_owner(session_plugin_id, plugin_id, server_id)?;
    if !ready {
        return Err(plugin_server::unavailable());
    }
    Ok(server)
}

fn plugin_server_timeout(requested: Option<u64>) -> Duration {
    let milliseconds = requested
        .unwrap_or(DEFAULT_REQUEST_TIMEOUT_MILLISECONDS)
        .clamp(1, MAX_REQUEST_TIMEOUT_MILLISECONDS);
    Duration::from_millis(milliseconds)
}

/// Allocates the JSON-RPC request of an admitted operation and records it as
/// pending. Returns the messages to write and the request ID.
fn register_plugin_server_request(
    state: &mut SessionState,
    operation_id: &str,
    method: &str,
    params: Value,
    created_at: Instant,
    deadline: Instant,
) -> Result<(Vec<String>, String), CoreError> {
    let response = allocate_raw_request(state.client.clone(), method, params)?;
    let request_id = (response.state.next_request_id - 1).to_string();
    state.client = response.state;
    state.pending.insert(
        request_id.clone(),
        PendingRequest {
            kind: PendingKind::PluginServer,
            operation_id: Some(operation_id.to_string()),
            method: method.to_string(),
            document_uri: None,
            document_version: None,
            created_at,
            deadline,
        },
    );
    state
        .request_by_operation
        .insert(operation_id.to_string(), request_id.clone());
    Ok((response.messages, request_id))
}

/// Applies a notification the server sent to a plugin-owned session: it may
/// open gates, and the backend may have asked to receive it. Returns the
/// messages of the requests that waited for those gates.
fn observe_plugin_server_notification(
    session: &RuntimeSession,
    state: &mut SessionState,
    method: Option<&str>,
    params: Option<&Value>,
) -> Vec<String> {
    let (Some(method), Some(server)) = (method, state.plugin_server.as_mut()) else {
        return Vec::new();
    };
    let observation = server.observe(method, params.unwrap_or(&Value::Null));
    if let Some(forwarded) = observation.forward {
        push_negotiated_provider_event(session, state, forwarded, "pluginServerNotification");
    }
    observation
        .released
        .into_iter()
        .flat_map(|held| release_held_plugin_server_request(session, state, held))
        .collect()
}

/// Sends a request whose gates opened. It keeps the deadline it was
/// admitted with, so the time spent waiting counts against its timeout.
fn release_held_plugin_server_request(
    session: &RuntimeSession,
    state: &mut SessionState,
    held: plugin_server::HeldRequest,
) -> Vec<String> {
    let registered = register_plugin_server_request(
        state,
        &held.operation_id,
        &held.method,
        held.params,
        held.created_at,
        held.deadline,
    );
    match registered {
        Ok((messages, _)) => messages,
        Err(error) => {
            let failure = runtime_error(
                session,
                "transportFailed",
                "request",
                Some(&held.method),
                None,
                "Could not encode the language-server request.",
                Some(&error.message),
                None,
            );
            push_request_event(
                session,
                state,
                &held.operation_id,
                &held.method,
                None,
                Some(failure),
            );
            Vec::new()
        }
    }
}

/// Cancels a plugin-server request that never reached the server, because it
/// waits behind a gate or joined a running command. Nothing is written.
fn cancel_unsent_plugin_server_request(
    session: &RuntimeSession,
    state: &mut SessionState,
    operation_id: &str,
) {
    let method = state
        .plugin_server
        .as_ref()
        .and_then(|server| server.method_of(operation_id))
        .unwrap_or_default()
        .to_string();
    let error = runtime_error(
        session,
        "requestCancelled",
        "request",
        Some(&method),
        None,
        "Language-server request was cancelled.",
        None,
        None,
    );
    push_request_event(session, state, operation_id, &method, None, Some(error));
}

/// What the backend receives for a plugin-owned server's reply: the result
/// untouched, so no Lithe normalizer reinterprets the server's own protocol,
/// or the server's error code and message as details of
/// `plugin.host.languageServerError`.
fn plugin_server_answer(
    session: &RuntimeSession,
    method: &str,
    reply: &Value,
) -> (Option<Value>, Option<LspRuntimeError>) {
    use super::plugin_function::{bounded_host_message, codes, MAX_RESULT_BYTES};
    let failure = |code: &str, message: &str| {
        runtime_error(
            session,
            code,
            "request",
            Some(method),
            None,
            message,
            None,
            None,
        )
    };
    if let Some(upstream) = reply.get("error") {
        let mut error = failure(
            codes::HOST_LANGUAGE_SERVER_ERROR,
            "The language server returned an error.",
        );
        let message = upstream
            .get("message")
            .and_then(Value::as_str)
            .map(bounded_host_message);
        error.details = Some(json!({ "code": upstream.get("code"), "message": message }));
        return (None, Some(error));
    }
    let result = reply.get("result").cloned().unwrap_or(Value::Null);
    let size = serde_json::to_vec(&result).map_or(usize::MAX, |bytes| bytes.len());
    if size > MAX_RESULT_BYTES {
        let error = failure(
            codes::HOST_LIMIT_EXCEEDED,
            "The language server's result is too large.",
        );
        return (None, Some(error));
    }
    (Some(json!({ "value": result })), None)
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
        state.client.pending_semantic_legends.remove(&request_id);
        if let Some(operation_id) = pending.operation_id.as_deref() {
            state.request_by_operation.remove(operation_id);
            state.function_by_operation.remove(operation_id);
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
            channel: None,
            plugin_id: None,
            role: None,
            event: None,
            fields: None,
            catalog_level: None,
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

fn push_semantic_tokens_refresh_event(session: &RuntimeSession, state: &mut SessionState) {
    let sequence = take_sequence(state);
    enqueue_runtime_event(
        session,
        state,
        LspRuntimeEvent {
            kind: "semanticTokensRefresh".to_string(),
            channel: None,
            plugin_id: None,
            role: None,
            event: None,
            fields: None,
            catalog_level: None,
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
            channel: None,
            plugin_id: None,
            role: None,
            event: None,
            fields: None,
            catalog_level: None,
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
            channel: None,
            plugin_id: None,
            role: None,
            event: None,
            fields: None,
            catalog_level: None,
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

/// Accepts only negotiated scalar plugin facts. Persistence and overload accounting
/// reuse the bounded Core handoff instead of copying protocol params into v1 detail.
fn receive_plugin_diagnostic(
    session: &RuntimeSession,
    state: &mut SessionState,
    params: Option<&Value>,
) {
    let Some(plugin) = session.plugin_id.as_deref() else {
        return;
    };
    let plugin_identity = SessionLogIdentity::new(
        SessionRole::Backend,
        &session.provider_id,
        Some(plugin),
        None,
    );
    let plugin = plugin_identity.segment();
    let valid = state
        .client
        .server_capabilities
        .iter()
        .any(|name| name == super::plugin_logging::FEATURE)
        .then(|| {
            super::plugin_logging::decode(
                plugin,
                &state.client.plugin_functions,
                params.unwrap_or(&Value::Null),
            )
        })
        .flatten();
    let Some(fact) = valid else {
        if !state.rejected_plugin_diagnostics {
            state.rejected_plugin_diagnostics = true;
            if crate::diagnostics::core_events::record(
                "plugins.diagnostics.rejected",
                BTreeMap::from([
                    ("plugin".into(), json!(plugin)),
                    ("code".into(), json!("invalid_diagnostic")),
                ]),
                None,
            )
            .is_err()
            {
                crate::diagnostics::core_events::note_dropped();
            }
        }
        return;
    };
    if state.plugin_diagnostics_window.elapsed() >= Duration::from_secs(60) {
        state.plugin_diagnostics_window = Instant::now();
        state.plugin_diagnostics_count = 0;
    }
    if state.plugin_diagnostics_count >= MAX_PLUGIN_DIAGNOSTICS_PER_MINUTE {
        crate::diagnostics::core_events::note_dropped();
        return;
    }
    state.plugin_diagnostics_count += 1;
    // SDK contexts carry wire request IDs, not reusable UI operation IDs. Only
    // a live request owned by this session may extend the host's correlation.
    let operation = fact.wire_operation.as_deref().and_then(|wire| {
        state
            .pending
            .get(wire)
            .and_then(|pending| pending.operation_id.clone())
    });
    if crate::diagnostics::core_events::record(fact.event, fact.fields, operation).is_err() {
        crate::diagnostics::core_events::note_dropped();
    }
}

fn push_log_event(
    session: &RuntimeSession,
    state: &mut SessionState,
    level: &str,
    identity: impl Into<EngineLogInput>,
    message: &str,
    detail: Option<String>,
) {
    push_classified_log_event(session, state, level, identity, message, detail, None);
}

fn push_issue_log_event(
    session: &RuntimeSession,
    state: &mut SessionState,
    level: &str,
    stage: &str,
    code: &str,
    identity: impl Into<EngineLogInput>,
    message: &str,
    detail: Option<String>,
) {
    let error = runtime_error(session, code, stage, None, None, message, None, None);
    push_classified_log_event(
        session,
        state,
        level,
        identity,
        message,
        detail,
        Some(error),
    );
}

fn push_classified_log_event(
    session: &RuntimeSession,
    state: &mut SessionState,
    level: &str,
    identity: impl Into<EngineLogInput>,
    message: &str,
    detail: Option<String>,
    error: Option<LspRuntimeError>,
) {
    let input = identity.into();
    let (event_id, fields) =
        input
            .identity
            .fact(&session.log_identity, &input.fields, error.as_ref());
    let sequence = take_sequence(state);
    enqueue_runtime_event(
        session,
        state,
        LspRuntimeEvent {
            kind: "log".to_string(),
            channel: None,
            plugin_id: None,
            role: None,
            event: Some(event_id),
            fields: Some(fields),
            catalog_level: None,
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
            error,
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
        plugin_error_code: None,
        details: None,
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
                PendingKind::Feature | PendingKind::PluginServer
            )
        })
        .map(|(request_id, pending)| (request_id.clone(), pending.clone()))
        .collect();
    for (request_id, pending) in pending {
        state.pending.remove(&request_id);
        state.client.pending_requests.remove(&request_id);
        state.client.pending_semantic_legends.remove(&request_id);
        if let Some(operation_id) = pending.operation_id.as_deref() {
            state.request_by_operation.remove(operation_id);
            state.function_by_operation.remove(operation_id);
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
    // Requests held behind a gate have no pending entry, so they end here.
    let held = state
        .plugin_server
        .as_ref()
        .map(|server| server.all_held())
        .unwrap_or_default();
    for waiter in held {
        let error = runtime_error(
            session,
            code,
            stage,
            Some(&waiter.method),
            None,
            message,
            None,
            exit_code,
        );
        push_request_event(
            session,
            state,
            &waiter.operation_id,
            &waiter.method,
            None,
            Some(error),
        );
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

/// Withdraws the session registry when shutdown or process failure ends its lifetime.
fn clear_function_registry(session: &RuntimeSession, state: &mut SessionState) {
    let removed: Vec<_> = std::mem::take(&mut state.client.plugin_functions)
        .into_iter()
        .collect();
    if !removed.is_empty() {
        push_functions_event(
            session,
            state,
            json!({ "functions": [], "removed": removed }),
        );
    }
}

fn clear_runtime_state(session: &RuntimeSession, state: &mut SessionState) {
    clear_runtime_diagnostics(session, state);
    state.client.initialized = false;
    state.client.text_document_save_include_text = None;
    state.client.shutdown_requested = false;
    state.client.server_capabilities.clear();
    state.client.open_documents.clear();
    state.client.pending_requests.clear();
    state.pending.clear();
    state.request_by_operation.clear();
    state.function_by_operation.clear();
    clear_function_registry(session, state);
    state.client.vcs_provider = None;
    state.client.toolchain_providers.clear();
    state.client.keymap_import_providers.clear();
    state.linked_document_paths = LinkedDocumentPaths::default();
    state.deadline_cancellations.clear();
    state.maintenance_write_deadline = None;
    state.relay_write_deadline = None;
    state.pending_workspace_file_changes.clear();
    state.initialize_deadline = None;
    state.shutdown_deadline = None;
    push_features_event(session, state, Vec::new());
}

/// Resolves the text of a document that has not been opened on the wire yet.
///
/// Hosts may send only ranged edits, which then extend the text Core retained.
/// Edits for a document Core never received cannot be resolved, so the host
/// resends the full text.
fn unopened_document_text(
    stored: Option<&LspClientDocument>,
    text: String,
    changes: &[LspDocumentContentChange],
) -> Result<String, CoreError> {
    if !text.is_empty() || changes.is_empty() {
        return Ok(text);
    }
    let Some(stored) = stored else {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Cannot apply ranged edits to a document Core has not received.",
        )
        .with_details("documentNotSynchronized"));
    };
    crate::lsp::apply_content_changes_sequential(&stored.text, changes)
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
            text: document.text.to_string(),
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
#[path = "engine_function_relay_tests.rs"]
mod function_relay_tests;

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

    pub(super) fn start_request(server: &ScriptedServer) -> StartServerRequest {
        let _ = server;
        StartServerRequest {
            provider_id: "gopls".to_string(),
            role: SessionRole::LanguageServer,
            log_subject: None,
            plugin_id: None,
            startup_operation: None,
            host_services: Vec::new(),
            host_options: Default::default(),
            toolchain_providers: Vec::new(),
            keymap_import_providers: Vec::new(),
            session_policy: None,
            executable_path: "/usr/bin/scripted-server".to_string(),
            arguments: vec!["--stdio".to_string()],
            environment: BTreeMap::new(),
            root_uri: "file:///workspace".to_string(),
            working_directory: "/workspace".to_string(),
            initialization_options: None,
            workspace_configuration: None,
            initialize_timeout_milliseconds: 10_000,
            request_timeout_milliseconds: 10_000,
            shutdown_timeout_milliseconds: 10_000,
        }
    }

    #[test]
    fn native_owner_keeps_failed_initialize_identity_until_verified_disposal() {
        let server = ScriptedServer::new();
        server.break_input();
        server.block_cleanup(true);
        let engine = LspEngine::with_launcher(server.launcher());
        let registered = Mutex::new(None);
        let result = engine.start_server_owned(start_request(&server), |id| {
            // Registration precedes the very first write, including its failure.
            assert!(server.messages().is_empty());
            *registered.lock().unwrap() = Some(id.to_string());
        });
        assert!(result.is_err());
        let id = registered
            .into_inner()
            .unwrap()
            .expect("native owner received the session");
        assert!(engine.session(&id).is_ok());
        assert!(engine.destroy(&id).is_err());
        assert!(
            engine.session(&id).is_ok(),
            "failed disposal must retain the process owner"
        );
        server.block_cleanup(false);
        engine
            .destroy(&id)
            .expect("verified cleanup allows destruction");
        assert!(engine.session(&id).is_err());
    }

    #[test]
    fn wire_owner_retries_failed_initialize_disposal_before_another_start() {
        let server = ScriptedServer::new();
        server.break_input();
        server.block_cleanup(true);
        let engine = LspEngine::with_launcher(server.launcher());
        assert!(engine.start_server(start_request(&server)).is_err());
        let id = engine
            .lock_failed_starts()
            .unwrap()
            .first()
            .cloned()
            .unwrap();
        let session = engine.session(&id).unwrap();
        let events = session.poll_events().unwrap();
        assert!(events.iter().any(|event| {
            event
                .error
                .as_ref()
                .is_some_and(|error| error.code == "transportFailed")
        }));
        let next_id = engine.next_session_id.load(Ordering::Relaxed);
        let error = engine.start_server(start_request(&server)).unwrap_err();
        assert!(matches!(error.code, ErrorCode::ProcessFailed));
        let error = engine
            .start_server_owned(start_request(&server), |_| {
                panic!("cleanup must precede spawn")
            })
            .unwrap_err();
        assert!(matches!(error.code, ErrorCode::ProcessFailed));
        assert_eq!(engine.next_session_id.load(Ordering::Relaxed), next_id);
        assert_eq!(engine.lock_sessions().unwrap().len(), 1);
        assert!(Arc::ptr_eq(&session, &engine.session(&id).unwrap()));
        server.block_cleanup(false);
        // The original transport remains broken, but retry first reclaims the
        // old owner and also disposes the replacement's failed initialization.
        assert!(engine.start_server(start_request(&server)).is_err());
        assert_eq!(engine.next_session_id.load(Ordering::Relaxed), next_id + 1);
        assert!(engine.lock_failed_starts().unwrap().is_empty());
        assert!(engine.lock_sessions().unwrap().is_empty());
    }

    #[test]
    fn wire_owner_cleans_at_most_one_failed_start_before_rejecting_a_backlog() {
        let server = ScriptedServer::new();
        server.break_input();
        let engine = LspEngine::with_launcher(server.launcher());
        let mut ids = BTreeSet::new();
        for _ in 0..2 {
            let mut id = None;
            assert!(engine
                .start_server_owned(start_request(&server), |registered| {
                    id = Some(registered.to_owned());
                })
                .is_err());
            ids.insert(id.unwrap());
        }
        // Simulate two wire starts already in flight before either failure
        // established the cleanup barrier.
        assert_eq!(ids.len(), 2);
        *engine.lock_failed_starts().unwrap() = ids;
        let next_id = engine.next_session_id.load(Ordering::Relaxed);
        let error = engine.start_server(start_request(&server)).unwrap_err();
        assert!(matches!(error.code, ErrorCode::ProcessFailed));
        assert_eq!(engine.next_session_id.load(Ordering::Relaxed), next_id);
        assert_eq!(engine.lock_sessions().unwrap().len(), 1);
        assert_eq!(engine.lock_failed_starts().unwrap().len(), 1);
        engine.cleanup_failed_start().unwrap();
        assert!(engine.lock_sessions().unwrap().is_empty());
        assert!(engine.lock_failed_starts().unwrap().is_empty());
    }

    #[test]
    fn invalid_initial_configuration_is_rejected_before_launch() {
        let server = ScriptedServer::new();
        let engine = LspEngine::with_launcher(server.launcher());
        let mut request = start_request(&server);
        request.workspace_configuration = Some(json!(["not an object"]));
        assert!(engine.start_server(request).is_err());
        assert!(!server.was_launched());
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

    struct IndexingPolicyFixture {
        root: PathBuf,
        revision: u64,
    }

    impl IndexingPolicyFixture {
        fn new(root: PathBuf) -> Self {
            let mut fixture = Self { root, revision: 0 };
            fixture.exclude(&[]);
            fixture
        }

        fn exclude(&mut self, paths: &[&str]) {
            self.revision = crate::project::indexing::configure(
                serde_json::from_value(json!({
                    "root": self.root, "manualExcludedDirectories": paths,
                    "includedDirectories": [], "gitIgnoreEnabled": false
                }))
                .unwrap(),
            )
            .unwrap()
            .revision;
        }
    }

    impl Drop for IndexingPolicyFixture {
        fn drop(&mut self) {
            let _ = crate::project::indexing::release(
                crate::project::indexing::ReleaseIndexingRequest {
                    root: self.root.to_string_lossy().into_owned(),
                    owner_id: None,
                    revision: self.revision,
                },
            );
        }
    }

    /// A throw-away workspace with a nested directory tree, removed on drop.
    struct TemporaryWorkspace {
        root: PathBuf,
    }

    impl TemporaryWorkspace {
        fn recursive(label: &str) -> Self {
            static NEXT_ID: AtomicU64 = AtomicU64::new(1);
            let root = std::env::temp_dir().join(format!(
                "lithe-lsp-{label}-{}-{}",
                std::process::id(),
                NEXT_ID.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir_all(root.join("reactor/module-a/nested"))
                .expect("nested fixture should be creatable");
            std::fs::write(
                root.join("reactor/module-a/nested/main.go"),
                "package main\n",
            )
            .expect("fixture file should be writable");
            Self { root }
        }

        fn configure(&self, request: &mut StartServerRequest) {
            request.root_uri = url::Url::from_directory_path(&self.root)
                .expect("fixture root should convert to a URI")
                .to_string();
            request.working_directory = self.root.to_string_lossy().into_owned();
        }
    }

    impl Drop for TemporaryWorkspace {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
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
                        position: Some(LspPosition {
                            line: 0,
                            utf16_column: 0,
                        }),
                        new_name: None,
                        range: None,
                        diagnostics: Vec::new(),
                        completion_context: None,
                        completion_item: None,
                        code_action: None,
                        command: None,
                    },
                    operation_id.clone(),
                )
                .expect("a ready session should accept the request");
            operation_id
        }

        /// The recorded JSON-RPC message with the given request ID.
        fn written_request(&self, request_id: &str) -> Value {
            self.server
                .messages()
                .into_iter()
                .find(|message| message["id"] == request_id)
                .expect("the request should have been written")
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

    /// Messages the scripted server received for `method`, in order.
    fn notifications(harness: &Harness, method: &str) -> Vec<Value> {
        harness
            .server
            .messages()
            .into_iter()
            .filter(|message| message.get("method").and_then(Value::as_str) == Some(method))
            .collect()
    }

    #[test]
    fn structured_logging_warnings_keep_source_stage_and_code() {
        let harness = Harness::ready();
        let session = harness.session();
        session.log_issue(
            "warn",
            "processCleanup",
            "processCleanupFailed",
            EngineLog::ProcessCleanupFailed,
            "Cleanup failed",
            None,
        );
        let event = session
            .poll_events()
            .unwrap()
            .into_iter()
            .find(|event| event.kind == "log")
            .unwrap();
        assert_eq!(event.level.as_deref(), Some("warn"));
        let error = event.error.unwrap();
        assert_eq!(error.code, "processCleanupFailed");
        assert_eq!(error.stage, "processCleanup");
        assert!(error.underlying_message.is_none());
        for (stage, code) in [
            ("stderr", "upstreamStderr"),
            ("stderr", "stderrReadFailed"),
            ("shutdown", "shutdownTimeout"),
        ] {
            session.log_issue(
                "warning",
                stage,
                code,
                if code == "upstreamStderr" {
                    EngineLog::StderrReceived
                } else if code == "stderrReadFailed" {
                    EngineLog::StderrReadFailed
                } else {
                    EngineLog::ShutdownTimedOut
                },
                "Updated diagnostic wording",
                None,
            );
            let event = session
                .poll_events()
                .unwrap()
                .into_iter()
                .find(|event| event.kind == "log")
                .unwrap();
            assert_eq!(event.level.as_deref(), Some("warning"));
            let error = event.error.unwrap();
            assert_eq!(error.stage, stage);
            assert_eq!(error.code, code);
        }
        // Ordinary logs must remain unclassified even when their wording matches an issue.
        session.log(
            "warning",
            EngineLog::StderrReceived,
            "Language-server stderr",
            None,
        );
        let event = session
            .poll_events()
            .unwrap()
            .into_iter()
            .find(|event| event.kind == "log")
            .unwrap();
        assert!(event.error.is_none());
    }

    #[test]
    fn lifecycle_catalog_identity_preserves_v1_event_without_extra_log() {
        for role in [
            SessionRole::LanguageServer,
            SessionRole::Vcs,
            SessionRole::Build,
            SessionRole::Toolchain,
            SessionRole::Backend,
        ] {
            let harness = Harness::start(|request| {
                request.role = role;
                request.provider_id = "c++".into();
                request.log_subject = Some("git".into());
                request.plugin_id = Some("io.example.tools".into());
            });
            let session = harness.session();
            session.active.store(false, Ordering::Release);
            session.kill_process();
            let mut state = session.state.lock().unwrap();
            state.events.clear();
            let sequence = state.next_sequence;
            transition_locked(&session, &mut state, LspLifecycleState::Stopped, None);
            assert!(!state.events.iter().any(|e| e.kind == "log"));
            let event = state.events.front().unwrap();
            let (id, fields) = EngineLog::SessionUpdated.fact(
                &session.log_identity,
                &json!({"state": "stopped"}),
                None,
            );
            assert_eq!(event.event.as_deref(), Some(id.as_str()));
            assert_eq!(event.fields.as_ref(), Some(&fields));
            assert_eq!(
                event.channel.as_deref(),
                Some(session.log_identity.channel().as_str())
            );
            assert_eq!(event.role, Some(role));
            assert_eq!(event.plugin_id.as_deref(), Some("io.example.tools"));
            assert_eq!(
                event.catalog_level,
                Some(crate::diagnostics::record::LogLevel::Debug)
            );
            let mut legacy = serde_json::to_value(event).unwrap();
            for key in [
                "channel",
                "pluginId",
                "role",
                "event",
                "fields",
                "catalogLevel",
            ] {
                legacy.as_object_mut().unwrap().remove(key);
            }
            assert_eq!(
                legacy,
                json!({"type": "stateChanged", "sequence": sequence,
                "providerId": "c++", "sessionId": session.id, "state": "stopped"})
            );
            state.events.clear();
            let error = runtime_error(
                &session,
                "processCleanupFailed",
                "cleanup",
                None,
                None,
                "Engine process cleanup failed",
                None,
                None,
            );
            let (id, fields) = EngineLog::ProcessCleanupFailed.fact(
                &session.log_identity,
                &Value::Null,
                Some(&error),
            );
            push_cleanup_fact(&session, &mut state, id, fields, error);
            let event = state.events.front().unwrap();
            assert_eq!(
                event.channel.as_deref(),
                Some(session.log_identity.channel().as_str())
            );
            assert_eq!(
                event.catalog_level,
                Some(crate::diagnostics::record::LogLevel::Warn)
            );
            assert_eq!(event.kind, "log");
            assert_eq!(event.level.as_deref(), Some("warning"));
            assert_eq!(
                event.message.as_deref(),
                Some("Engine process cleanup failed")
            );
            assert!(event.detail.is_none() && event.state.is_none());
            assert_eq!(
                event.error.as_ref().map(|error| error.code.as_str()),
                Some("processCleanupFailed")
            );
        }
    }

    #[test]
    fn v1_detail_is_independent_of_catalog_fields() {
        let harness = Harness::start(|_| {});
        let session = harness.session();
        struct Cleanup(Arc<RuntimeSession>);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                self.0.active.store(false, Ordering::Release);
                self.0.kill_process();
            }
        }
        let _cleanup = Cleanup(session.clone());
        session.poll_events().unwrap();
        let line = "  upstream diagnostic  ";
        session.log_issue(
            "warning",
            "stderr",
            "upstreamStderr",
            EngineLog::StderrReceived.with_fields(json!({"diagnostic": line, "truncated": false})),
            "Language-server stderr",
            Some(line.into()),
        );
        let event = session
            .poll_events()
            .unwrap()
            .into_iter()
            .find(|e| e.event.as_deref() == Some("lsp.stderr.received"))
            .unwrap();
        assert_eq!(event.level.as_deref(), Some("warning"));
        assert_eq!(event.message.as_deref(), Some("Language-server stderr"));
        assert_eq!(event.detail.as_deref(), Some(line));
        assert_eq!(event.fields.as_ref().unwrap()["diagnostic"], line);
        assert_eq!(event.fields.as_ref().unwrap()["truncated"], false);
        // A JSON-looking v1 detail cannot supply or overwrite a catalog fact.
        session.log(
            "info",
            EngineLog::StderrReceived.with_fields(json!({"diagnostic": "kept", "truncated": true})),
            "Language-server stderr",
            Some("{\"diagnostic\":\"overwritten\",\"truncated\":false}".into()),
        );
        let event = session.poll_events().unwrap().into_iter().next().unwrap();
        let fields = event.fields.unwrap();
        assert_eq!(fields["diagnostic"], "kept");
        assert_eq!(fields["truncated"], true);
    }

    #[test]
    fn engine_logging_wire_fixture_preserves_defaults_and_routes_new_commands() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../../../shared/fixtures/diagnostics/engine-logging-v2.json"
        ))
        .unwrap();
        let request: StartServerRequest = serde_json::from_value(fixture["start"].clone()).unwrap();
        assert_eq!(request.role, SessionRole::Vcs);
        assert_eq!(
            SessionLogIdentity::new(
                request.role,
                &request.provider_id,
                request.plugin_id.as_deref(),
                request.log_subject.as_deref()
            )
            .channel(),
            "vcs/git"
        );
        let mut legacy = fixture["start"].clone();
        legacy.as_object_mut().unwrap().remove("role");
        legacy.as_object_mut().unwrap().remove("logSubject");
        assert_eq!(
            serde_json::from_value::<StartServerRequest>(legacy)
                .unwrap()
                .role,
            SessionRole::LanguageServer
        );
        for name in ["trace", "drain", "resolveSubject"] {
            assert!(crate::protocol::CoreCommand::parse(
                fixture[name]["command"].as_str().unwrap()
            )
            .is_some());
        }
        let response: Value = serde_json::from_str(&crate::runtime::execute_json(
            &fixture["resolveSubject"].to_string(),
        ))
        .unwrap();
        assert_eq!(response["data"], fixture["resolveSubject"]["result"]);
        let request: SetDetailedDiagnosticsRequest =
            serde_json::from_value(fixture["trace"]["payload"].clone()).unwrap();
        assert!(request.enabled);
        let response: Value =
            serde_json::from_str(&crate::runtime::execute_json(&fixture["drain"].to_string()))
                .unwrap();
        assert_eq!(response["ok"], true);
        assert!(response["data"]["events"].is_array());
        assert!(response["data"]["dropped"].as_u64().is_some());
    }

    #[test]
    fn detailed_diagnostics_waits_for_initialized_and_keeps_the_latest_request() {
        for enabled in [true, false] {
            let harness = Harness::start(|_| {});
            let session = harness.session();
            struct Cleanup(Arc<RuntimeSession>);
            impl Drop for Cleanup {
                fn drop(&mut self) {
                    self.0.active.store(false, Ordering::Release);
                    self.0.kill_process();
                }
            }
            let _cleanup = Cleanup(session.clone());
            session.set_detailed_diagnostics(true).unwrap();
            if !enabled {
                session.set_detailed_diagnostics(false).unwrap();
            }
            assert!(!harness
                .server
                .messages()
                .iter()
                .any(|m| m["method"] == "$/setTrace"));
            assert!(!session.lock_state().unwrap().detailed_diagnostics);

            // Drive the real handshake handler synchronously; no reader timing
            // or sleep is needed to establish the notification ordering.
            let initialize = harness.server.await_request("initialize").unwrap();
            session
                .handle_server_message(
                    json!({
                        "jsonrpc":"2.0", "id":initialize,
                        "result":{"capabilities":ready_capabilities()}
                    })
                    .to_string(),
                )
                .unwrap();
            let methods: Vec<_> = harness
                .server
                .messages()
                .into_iter()
                .filter_map(|m| m["method"].as_str().map(str::to_owned))
                .collect();
            if enabled {
                let initialized = methods.iter().position(|m| m == "initialized").unwrap();
                let trace = methods.iter().position(|m| m == "$/setTrace").unwrap();
                assert!(trace > initialized);
            } else {
                assert!(!methods.iter().any(|m| m == "$/setTrace"));
            }
            assert_eq!(session.lock_state().unwrap().detailed_diagnostics, enabled);
            session.set_detailed_diagnostics(false).unwrap();
            assert_eq!(
                harness.server.messages().last().unwrap()["params"],
                json!({"value":"off"})
            );
        }
    }

    #[test]
    fn upstream_catalog_messages_trace_toggle_and_v1_fields_coexist() {
        let harness = Harness::start(|request| {
            request.role = SessionRole::Vcs;
            request.log_subject = Some("git".into());
            request.plugin_id = Some("io.example.git".into());
            request.provider_id = "opaque:provider:git".into();
        });
        let session = harness.session();
        struct Cleanup(Arc<RuntimeSession>);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                self.0.active.store(false, Ordering::Release);
                self.0.kill_process();
            }
        }
        let _cleanup = Cleanup(session.clone());
        let initialize = harness.server.await_request("initialize").unwrap();
        session
            .handle_server_message(
                json!({
                    "jsonrpc":"2.0", "id":initialize, "result":{"capabilities":{}}
                })
                .to_string(),
            )
            .unwrap();
        session.poll_events().unwrap();
        session.log(
            "warning",
            EngineLog::Dropped.with_fields(json!({"count": 7})),
            "Engine stderr lines dropped",
            Some("count=7".into()),
        );
        let dropped = session
            .poll_events()
            .unwrap()
            .into_iter()
            .find(|event| event.event.as_deref() == Some("log.dropped"))
            .unwrap();
        assert_eq!(dropped.channel.as_deref(), Some("vcs/git"));
        assert_eq!(dropped.fields.unwrap()["count"], 7);
        for (method, expected) in [
            ("window/logMessage", "vcs.message.warning.logged"),
            ("window/showMessage", "vcs.message.warning.shown"),
        ] {
            session.handle_server_message(json!({"jsonrpc":"2.0", "method":method, "params":{"type":2,"message":"warning token=private-value"}}).to_string()).unwrap();
            let events = session.poll_events().unwrap();
            let event = events
                .iter()
                .find(|e| e.event.as_deref() == Some(expected))
                .expect("upstream catalog event");
            assert_eq!(event.channel.as_deref(), Some("vcs/git"));
            assert_eq!(event.plugin_id.as_deref(), Some("io.example.git"));
            assert_eq!(event.role, Some(SessionRole::Vcs));
            assert_eq!(
                event.catalog_level,
                Some(crate::diagnostics::record::LogLevel::Warn)
            );
            assert_eq!(event.message.as_deref(), Some(method));
            assert!(event.level.is_some() && event.detail.is_some());
            let fields = event.fields.as_ref().unwrap();
            assert_eq!(fields["severity"], "warning");
            assert!(!fields["diagnostic"]
                .as_str()
                .unwrap()
                .contains("private-value"));
        }
        let trace = json!({"jsonrpc":"2.0", "method":"$/logTrace", "params":{
            "message":"trace token=fixture-secret", "verbose":json!({
                "textDocument":{"text":"private_source_marker"}
            }).to_string()
        }})
        .to_string();
        session.handle_server_message(trace.clone()).unwrap();
        assert!(!session
            .poll_events()
            .unwrap()
            .iter()
            .any(|e| e.event.as_deref() == Some("vcs.trace.received")));
        session.set_detailed_diagnostics(true).unwrap();
        assert_eq!(
            harness.server.messages().last().unwrap()["params"],
            json!({"value":"verbose"})
        );
        session.handle_server_message(trace.clone()).unwrap();
        let event = session
            .poll_events()
            .unwrap()
            .into_iter()
            .find(|e| e.event.as_deref() == Some("vcs.trace.received"))
            .unwrap();
        assert_eq!(
            event.catalog_level,
            Some(crate::diagnostics::record::LogLevel::Debug)
        );
        assert_eq!(event.level.as_deref(), Some("info"));
        let fields = event.fields.unwrap();
        assert_eq!(fields["diagnostic"], "trace token=<redacted>");
        let encoded = crate::diagnostics::record::encode_log_batch(
            serde_json::from_value(json!({"validateCatalog":true,"events":[{
                "ts":"2026-11-03T00:00:00.000Z", "seq":1, "level":"DEBUG",
                "event":"vcs.trace.received", "msg":"", "fields":fields
            }]}))
            .unwrap(),
        );
        let line = encoded.results[0].line.as_ref().unwrap();
        assert!(!line.contains("private_source_marker"));
        assert!(!line.contains("fixture-secret"));
        session.set_detailed_diagnostics(false).unwrap();
        assert_eq!(
            harness.server.messages().last().unwrap()["params"],
            json!({"value":"off"})
        );
        session.handle_server_message(trace).unwrap();
        assert!(!session
            .poll_events()
            .unwrap()
            .iter()
            .any(|e| e.event.as_deref() == Some("vcs.trace.received")));
        assert!(
            serde_json::from_value::<SetDetailedDiagnosticsRequest>(json!({"sessionId":"s"}))
                .is_err()
        );
    }

    #[test]
    fn ranged_edits_extend_text_retained_before_the_server_is_ready() {
        let mut harness = Harness::start(|request| {
            request.provider_id = "gopls".to_string();
        });
        let uri = "file:///workspace/First.java";
        harness.sync(uri, "class First {}");
        let appended = LspDocumentContentChange {
            range: Some(LspRange {
                start: LspPosition {
                    line: 0,
                    utf16_column: 11,
                },
                end: LspPosition {
                    line: 0,
                    utf16_column: 11,
                },
            }),
            text: "Renamed".to_string(),
        };
        harness
            .session()
            .sync_document(SyncDocumentRequest {
                session_id: harness.session_id.clone(),
                uri: uri.to_string(),
                language_id: "java".to_string(),
                text: String::new(),
                content_changes: vec![appended.clone()],
            })
            .expect("ranged edits should extend the retained text");

        harness.server.complete_initialize(ready_capabilities());
        harness.await_state(LspLifecycleState::Ready);
        assert!(harness.server.await_notification("textDocument/didOpen"));
        let written = String::from_utf8_lossy(&harness.server.written_bytes()).into_owned();
        assert!(written.contains("class FirstRenamed {}"));

        let error = harness
            .session()
            .sync_document(SyncDocumentRequest {
                session_id: harness.session_id.clone(),
                uri: "file:///workspace/Unknown.java".to_string(),
                language_id: "java".to_string(),
                text: String::new(),
                content_changes: vec![appended],
            })
            .expect_err("edits to an unknown document cannot be resolved");
        assert_eq!(error.details.as_deref(), Some("documentNotSynchronized"));
    }

    /// A path descriptor reaches the server with reserved characters escaped.
    #[test]
    fn native_path_emits_the_canonical_uri_on_the_lsp_wire() {
        let harness = Harness::ready();
        let mut payload = json!({"sessionId":harness.session_id, "languageId":"go", "text":"package main",
            "uri":{"path":"/workspace/A#B.go","platform":"posix"}});
        crate::lsp::resolve_request_paths("lsp.syncDocument", &mut payload).unwrap();
        let request: SyncDocumentRequest = serde_json::from_value(payload).unwrap();
        harness
            .session()
            .sync_document(request)
            .expect("document should synchronize");
        assert!(harness.server.await_notification("textDocument/didOpen"));
        let opened = harness
            .server
            .messages()
            .into_iter()
            .find(|message| message["method"] == "textDocument/didOpen")
            .unwrap();
        assert_eq!(
            opened["params"]["textDocument"]["uri"],
            "file:///workspace/A%23B.go"
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

    #[test]
    fn indexing_policy_withdrawal_serializes_with_a_checked_document_commit() {
        assert_policy_withdrawal_serializes_with_checked_commit(false);
    }

    #[test]
    fn indexing_policy_withdrawal_serializes_with_checked_diagnostics() {
        assert_policy_withdrawal_serializes_with_checked_commit(true);
    }

    fn assert_policy_withdrawal_serializes_with_checked_commit(diagnostics: bool) {
        let workspace = TemporaryWorkspace::recursive("indexing-document-commit");
        let root = workspace.root.canonicalize().unwrap();
        let mut policy = IndexingPolicyFixture::new(root.clone());
        let mut harness = Harness::start(|request| workspace.configure(request));
        harness.server.complete_initialize(ready_capabilities());
        harness.await_state(LspLifecycleState::Ready);
        let uri = url::Url::from_file_path(root.join("reactor/hidden.go"))
            .unwrap()
            .to_string();
        let session = harness.session();
        let (checked_tx, checked_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let (sync_done_tx, sync_done_rx) = std::sync::mpsc::channel();
        let syncing = {
            let session = session.clone();
            let uri = uri.clone();
            thread::spawn(move || {
                let checked = || {
                    checked_tx.send(()).unwrap();
                    release_rx
                        .recv_timeout(Duration::from_secs(3))
                        .expect("document commit was not released");
                };
                let result = if diagnostics {
                    session.handle_server_message_after_policy_check(json!({"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{
                        "uri":uri,"diagnostics":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"message":"old diagnostic"}]
                    }}).to_string(), checked)
                } else {
                    session
                        .sync_document_after_policy_check(
                            SyncDocumentRequest {
                                session_id: session.id.clone(),
                                uri,
                                language_id: "java".into(),
                                text: "class Hidden {}".into(),
                                content_changes: Vec::new(),
                            },
                            checked,
                        )
                        .map(|_| ())
                };
                let _ = sync_done_tx.send(());
                result
            })
        };
        checked_rx
            .recv_timeout(Duration::from_secs(3))
            .expect("document eligibility was not reached");
        assert!(
            matches!(
                session.indexing_roots.try_lock(),
                Err(std::sync::TryLockError::WouldBlock)
            ),
            "eligibility and document publication must retain the policy serialization guard"
        );
        policy.exclude(&["reactor"]);
        let (update_done_tx, update_done_rx) = std::sync::mpsc::channel();
        let updating = {
            let session = session.clone();
            let root = root.clone();
            thread::spawn(move || {
                let result = apply_indexing_to_sessions(&root, vec![session]);
                let _ = update_done_tx.send(());
                result
            })
        };
        release_tx.send(()).unwrap();
        sync_done_rx
            .recv_timeout(Duration::from_secs(3))
            .expect("document commit did not finish");
        update_done_rx
            .recv_timeout(Duration::from_secs(3))
            .expect("policy update did not finish");
        syncing.join().unwrap().unwrap();
        updating.join().unwrap().unwrap();
        assert!(!harness.snapshot().open_documents.contains_key(&uri));
        assert!(!session
            .lock_state()
            .unwrap()
            .client
            .diagnostics
            .contains_key(&uri));
        if !diagnostics {
            assert!(notifications(&harness, "textDocument/didClose")
                .iter()
                .any(|message| message["params"]["textDocument"]["uri"] == uri));
        }
    }

    #[test]
    fn indexing_policy_withdraws_queued_file_changes_before_service_readiness() {
        let workspace = TemporaryWorkspace::recursive("indexing-pending-file-changes");
        let root = workspace.root.canonicalize().unwrap();
        let mut policy = IndexingPolicyFixture::new(root.clone());
        let mut harness = Harness::start(|request| workspace.configure(request));
        let hidden = url::Url::from_file_path(root.join("reactor/hidden.go"))
            .unwrap()
            .to_string();
        let visible = url::Url::from_file_path(root.join("visible.go"))
            .unwrap()
            .to_string();
        harness
            .session()
            .workspace_files_changed(vec![
                WorkspaceFileChange {
                    uri: hidden.clone(),
                    kind: WorkspaceFileChangeKind::Created,
                },
                WorkspaceFileChange {
                    uri: visible.clone(),
                    kind: WorkspaceFileChangeKind::Created,
                },
            ])
            .unwrap();
        assert_eq!(
            harness
                .session()
                .lock_state()
                .unwrap()
                .pending_workspace_file_changes
                .len(),
            2
        );
        policy.exclude(&["reactor"]);
        // The policy is installed, but this independent session has not received
        // its withdrawal callback yet. Readiness must recheck queued eligibility.
        harness.server.complete_initialize(ready_capabilities());
        harness.await_state(LspLifecycleState::Ready);
        let changes = notifications(&harness, "workspace/didChangeWatchedFiles");
        assert!(changes.iter().any(|message| message["params"]["changes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|change| change["uri"] == visible)));
        assert!(!changes.iter().any(|message| message["params"]["changes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|change| change["uri"] == hidden)));
    }

    #[test]
    fn indexing_startup_cancels_when_policy_changes_during_process_launch() {
        const CANCELLED_PLUGIN: &str = "io.example.indexing-cancel-launch";
        struct RetireOnLaunch {
            inner: Arc<dyn LspProcessLauncher>,
            root: PathBuf,
            revision: Arc<AtomicU64>,
            process: Arc<Mutex<Option<Arc<dyn LspProcessHandle>>>>,
        }
        impl LspProcessLauncher for RetireOnLaunch {
            fn launch(
                &self,
                spec: LspProcessSpec,
            ) -> Result<super::super::process::LspProcessStreams, CoreError> {
                let process = self.inner.launch(spec)?;
                *self.process.lock().unwrap() = Some(process.handle.clone());
                let status = crate::project::indexing::configure(serde_json::from_value(json!({
                    "root": self.root, "manualExcludedDirectories": ["reactor"], "includedDirectories": [], "gitIgnoreEnabled": false
                })).unwrap())?;
                self.revision.store(status.revision, Ordering::Release);
                Ok(process)
            }
        }
        struct Cleanup {
            root: PathBuf,
            revision: Arc<AtomicU64>,
            process: Arc<Mutex<Option<Arc<dyn LspProcessHandle>>>>,
        }
        impl Drop for Cleanup {
            fn drop(&mut self) {
                if let Some(process) = self.process.lock().unwrap().as_ref() {
                    process.terminate();
                }
                let _ = crate::project::indexing::release(
                    crate::project::indexing::ReleaseIndexingRequest {
                        root: self.root.to_string_lossy().into_owned(),
                        owner_id: None,
                        revision: self.revision.load(Ordering::Acquire),
                    },
                );
            }
        }
        for (initially_configured, cleanup_blocked, native_owner) in [
            (false, false, false),
            (true, false, false),
            (false, true, false),
            (true, true, false),
            (false, false, true),
            (true, false, true),
            (false, true, true),
            (true, true, true),
        ] {
            let workspace = TemporaryWorkspace::recursive(&format!(
                "indexing-startup-retired-{initially_configured}"
            ));
            let root = workspace.root.canonicalize().unwrap();
            let installed = if initially_configured {
                crate::project::indexing::configure(serde_json::from_value(json!({
            "root":root,"manualExcludedDirectories":[],"includedDirectories":[],"gitIgnoreEnabled":false
        })).unwrap()).unwrap().revision
            } else {
                0
            };
            let cleanup = Cleanup {
                root: root.clone(),
                revision: Arc::new(AtomicU64::new(installed)),
                process: Arc::new(Mutex::new(None)),
            };
            let server = ScriptedServer::new();
            server.block_cleanup(cleanup_blocked);
            let engine = LspEngine::with_launcher(Arc::new(RetireOnLaunch {
                inner: server.launcher(),
                root: root.clone(),
                revision: cleanup.revision.clone(),
                process: cleanup.process.clone(),
            }));
            let mut request = start_request(&server);
            request.provider_id = "python".into();
            request.root_uri = url::Url::from_directory_path(&root).unwrap().to_string();
            request.working_directory = root.to_string_lossy().into_owned();
            request.startup_operation = Some(AttemptHandoff {
                plugin_id: CANCELLED_PLUGIN.to_string(),
                operation_id: "indexing-cancel-before-registration".to_string(),
                elapsed_ms: 5,
            });
            let mut registered = None;
            let result = if native_owner {
                engine.start_server_owned(request, |id| registered = Some(id.to_owned()))
            } else {
                engine.start_server(request)
            };
            assert!(matches!(result.unwrap_err().code, ErrorCode::Cancelled));
            if cleanup_blocked {
                let id = if native_owner {
                    registered.expect("incomplete disposal must reach the native owner")
                } else {
                    engine
                        .lock_failed_starts()
                        .unwrap()
                        .first()
                        .cloned()
                        .expect("incomplete wire disposal retains its internal owner")
                };
                assert!(engine.destroy(&id).is_err());
                assert!(engine.session(&id).is_ok());
                server.block_cleanup(false);
                if native_owner {
                    engine
                        .destroy(&id)
                        .expect("native owner can retry verified disposal");
                } else {
                    engine
                        .cleanup_failed_start()
                        .expect("wire retry confirms disposal");
                    assert!(engine.lock_failed_starts().unwrap().is_empty());
                }
            } else {
                assert!(
                    registered.is_none(),
                    "disposed startup needs no native barrier"
                );
            }
            assert!(engine.lock_sessions().unwrap().is_empty());
            assert!(
                server.input_was_closed(),
                "the cancelled startup owns process termination"
            );
            assert!(
                plugin_operations::test_capture::take(CANCELLED_PLUGIN).is_empty(),
                "a cancelled start records no plugin operation result"
            );
        }
    }

    #[test]
    fn native_owner_retains_indexing_cancellation_after_registration() {
        const CANCELLED_PLUGIN: &str = "io.example.indexing-cancel-registered";
        let workspace = TemporaryWorkspace::recursive("indexing-owned-startup");
        let root = workspace.root.canonicalize().unwrap();
        let mut policy = IndexingPolicyFixture::new(root.clone());
        let server = ScriptedServer::new();
        server.block_cleanup(true);
        let engine = LspEngine::with_launcher(server.launcher());
        let mut request = start_request(&server);
        request.provider_id = "python".into();
        request.root_uri = url::Url::from_directory_path(&root).unwrap().to_string();
        request.working_directory = root.to_string_lossy().into_owned();
        request.startup_operation = Some(AttemptHandoff {
            plugin_id: CANCELLED_PLUGIN.to_string(),
            operation_id: "indexing-cancel-after-registration".to_string(),
            elapsed_ms: 5,
        });
        let mut registered = None;
        let result = engine.start_server_owned(request, |id| {
            registered = Some(id.to_owned());
            // Revoke between the initial policy check and initialize write.
            policy.exclude(&["reactor"]);
        });
        assert!(matches!(result.unwrap_err().code, ErrorCode::Cancelled));
        let id = registered.expect("native owner received its session");
        assert!(engine.destroy(&id).is_err());
        assert!(engine.session(&id).is_ok());
        server.block_cleanup(false);
        engine
            .destroy(&id)
            .expect("native owner confirms process disposal");
        assert!(engine.session(&id).is_err());
        assert!(
            plugin_operations::test_capture::take(CANCELLED_PLUGIN).is_empty(),
            "a cancelled start records no plugin operation result"
        );
    }

    #[test]
    fn indexing_released_root_allows_a_standalone_provider_without_old_exclusions() {
        let workspace = TemporaryWorkspace::recursive("indexing-released-standalone");
        let root = workspace.root.canonicalize().unwrap();
        let root_uri = url::Url::from_directory_path(&root).unwrap().to_string();
        let status = crate::project::indexing::configure(serde_json::from_value(json!({
            "root": root, "manualExcludedDirectories": ["reactor"], "includedDirectories": [], "gitIgnoreEnabled": false
        })).unwrap()).unwrap();
        let old = crate::project::indexing::context(&root).unwrap();
        crate::project::indexing::release(crate::project::indexing::ReleaseIndexingRequest {
            root: root.to_string_lossy().into_owned(),
            revision: status.revision,
            owner_id: None,
        })
        .unwrap();
        assert!(
            old.check().is_err(),
            "late inventory readers must remain cancelled"
        );
        let harness = Harness::start(|request| {
            workspace.configure(request);
            request.root_uri = root_uri.clone();
            request.initialization_options =
                Some(json!({"settings":{"java":{"import":{"exclusions":["**/vendor/**"]}}}}));
        });
        let initialize = notifications(&harness, "initialize").pop().unwrap();
        assert_eq!(
            initialize["params"]["initializationOptions"]["settings"]["java"]["import"]
                ["exclusions"],
            json!(["**/vendor/**"])
        );
        let file_uri = url::Url::from_file_path(root.join("reactor/visible.go"))
            .unwrap()
            .to_string();
        assert!(!crate::project::indexing::uri_is_excluded(&root_uri, &file_uri).unwrap());
    }

    #[test]
    fn indexing_cold_start_resolves_git_before_provider_initialization() {
        let workspace = TemporaryWorkspace::recursive("indexing-cold-start");
        let root = workspace.root.canonicalize().unwrap();
        std::fs::create_dir_all(root.join("ignored")).unwrap();
        std::fs::write(root.join("ignored/hidden.txt"), "hidden").unwrap();
        std::fs::write(root.join(".gitignore"), "ignored/\n").unwrap();
        let git = crate::git::execute_git_readonly(
            &root.to_string_lossy(),
            &["init".into(), "--quiet".into()],
            None,
        )
        .unwrap();
        assert_eq!(git.exit_code, 0, "{}", git.stderr);
        let status = crate::project::indexing::configure(serde_json::from_value(json!({
            "root": root, "manualExcludedDirectories": [], "includedDirectories": [], "gitIgnoreEnabled": true
        })).unwrap()).unwrap();
        let harness = Harness::start(|request| {
            workspace.configure(request);
            request.root_uri = url::Url::from_directory_path(&root).unwrap().to_string();
        });
        assert!(notifications(&harness, "initialize").pop().is_some());
        for (provider, pointer) in [
            ("go", "/gopls/directoryFilters"),
            ("rust", "/rust-analyzer/files/exclude"),
        ] {
            let value = crate::lsp::languages::indexing::configuration(
                provider,
                &harness.session().root_uri,
                None,
            )
            .unwrap();
            assert!(value
                .pointer(pointer)
                .unwrap()
                .as_array()
                .unwrap()
                .iter()
                .any(|item| item
                    == if provider == "go" {
                        "-ignored"
                    } else {
                        "ignored"
                    }));
        }
        crate::project::indexing::release(crate::project::indexing::ReleaseIndexingRequest {
            root: root.to_string_lossy().into_owned(),
            revision: status.revision,
            owner_id: None,
        })
        .unwrap();
    }

    #[test]
    fn indexing_change_withdraws_open_working_copies_and_rejects_sync() {
        let workspace = TemporaryWorkspace::recursive("indexing-working-copy");
        let root = workspace.root.canonicalize().unwrap();
        let root_uri = url::Url::from_directory_path(&root).unwrap().to_string();
        let mut harness = Harness::start(|request| {
            request.root_uri = root_uri.clone();
            request.working_directory = root.to_string_lossy().into_owned();
        });
        harness.server.complete_initialize(ready_capabilities());
        harness.await_state(LspLifecycleState::Ready);
        let uri = url::Url::from_file_path(root.join("reactor/main.go"))
            .unwrap()
            .to_string();
        harness.sync(&uri, "package main");
        let status = crate::project::indexing::configure(
            serde_json::from_value(json!({
                "root":root,"manualExcludedDirectories":["reactor"],
                "includedDirectories":[],"gitIgnoreEnabled":false
            }))
            .unwrap(),
        )
        .unwrap();
        apply_indexing_to_sessions(&root, vec![harness.session()]).unwrap();
        assert!(!harness
            .session()
            .lock_state()
            .unwrap()
            .client
            .open_documents
            .contains_key(&uri));
        assert!(crate::project::indexing::uri_is_excluded(&root_uri, &uri).unwrap());
        let session = harness.session();
        assert!(session
            .sync_document(SyncDocumentRequest {
                session_id: harness.session_id.clone(),
                uri: uri.clone(),
                language_id: "go".into(),
                text: "package main".into(),
                content_changes: Vec::new(),
            })
            .is_err());
        session.handle_server_message(json!({"jsonrpc":"2.0","method":"textDocument/publishDiagnostics", "params":{
            "uri":uri,"diagnostics":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"severity":1,"message":"late"}]
        }}).to_string()).unwrap();
        assert!(!session
            .lock_state()
            .unwrap()
            .client
            .diagnostics
            .contains_key(&uri));

        assert_eq!(
            harness.session().indexing_revision.load(Ordering::Acquire),
            status.revision
        );
        crate::project::indexing::release(crate::project::indexing::ReleaseIndexingRequest {
            owner_id: None,
            root: root.to_string_lossy().into_owned(),
            revision: status.revision,
        })
        .unwrap();
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

    /// A declarative plugin start handed off by the host ends in exactly one Core
    /// result: `initialize` success, an exit before it, or nothing for a user stop.
    /// Later exits belong to the session, not the start. A plugin API 1 server
    /// starts host-owned, so the handoff alone names the plugin; a session owned
    /// by a different plugin records nothing.
    #[test]
    fn declarative_plugin_start_records_one_host_operation_per_attempt() {
        const PLUGIN: &str = "io.example.declarative-start";
        const OTHER: &str = "io.example.declarative-start-other";
        let handoff = |operation_id: &'static str, owner: Option<&'static str>| {
            move |request: &mut StartServerRequest| {
                request.plugin_id = owner.map(str::to_string);
                request.startup_operation = Some(AttemptHandoff {
                    plugin_id: PLUGIN.to_string(),
                    operation_id: operation_id.to_string(),
                    elapsed_ms: 5,
                });
            }
        };

        let mut ready = Harness::start(handoff("declarative-ready", Some(PLUGIN)));
        ready.server.complete_initialize(ready_capabilities());
        ready.await_state(LspLifecycleState::Ready);
        ready.server.exit(Some(1));
        ready.await_state(LspLifecycleState::Failed);

        let mut exited = Harness::start(handoff("declarative-exited", None));
        exited.server.exit(Some(2));
        exited.await_state(LspLifecycleState::Failed);

        let mut stopped = Harness::start(handoff("declarative-stopped", Some(PLUGIN)));
        stopped.session().stop().unwrap();
        stopped.await_state(LspLifecycleState::Stopped);

        let mut foreign = Harness::start(handoff("declarative-foreign", Some(OTHER)));
        foreign.server.exit(Some(3));
        foreign.await_state(LspLifecycleState::Failed);
        assert!(plugin_operations::test_capture::take(OTHER).is_empty());

        let facts = plugin_operations::test_capture::take(PLUGIN);
        assert!(facts
            .iter()
            .all(|fact| std::ptr::eq(fact.contribution, &LANGUAGE_SERVER_START)));
        let results: Vec<_> = facts
            .into_iter()
            .map(|fact| (fact.operation_id, fact.failure))
            .collect();
        assert_eq!(
            results,
            [
                (Some("declarative-ready".to_string()), None),
                (
                    Some("declarative-exited".to_string()),
                    Some(AttemptStage::Exit)
                ),
            ]
        );
    }

    /// startServer failing after spawn is a `launch` failure, and an initialize
    /// timeout decided under the state lock is the only result even when the
    /// response arrives afterwards.
    #[test]
    fn declarative_plugin_start_attributes_write_failure_and_timeout() {
        const PLUGIN: &str = "io.example.declarative-start-failures";
        let handoff = |operation_id: &str, request: &mut StartServerRequest| {
            request.plugin_id = Some(PLUGIN.to_string());
            request.startup_operation = Some(AttemptHandoff {
                plugin_id: PLUGIN.to_string(),
                operation_id: operation_id.to_string(),
                elapsed_ms: 5,
            });
        };

        let broken = ScriptedServer::new();
        broken.break_input();
        let engine = LspEngine::with_launcher(broken.launcher());
        let mut request = start_request(&broken);
        handoff("declarative-write-failed", &mut request);
        assert!(engine.start_server(request).is_err());

        let mut timed_out = Harness::start(|request| {
            handoff("declarative-timed-out", request);
            request.initialize_timeout_milliseconds = 60_000;
        });
        timed_out
            .session()
            .expire_deadlines_at(Instant::now() + Duration::from_secs(61));
        timed_out.await_state(LspLifecycleState::Failed);
        timed_out.server.complete_initialize(ready_capabilities());

        let results: Vec<_> = plugin_operations::test_capture::take(PLUGIN)
            .into_iter()
            .map(|fact| (fact.operation_id, fact.failure))
            .collect();
        assert_eq!(
            results,
            [
                (
                    Some("declarative-write-failed".to_string()),
                    Some(AttemptStage::Launch)
                ),
                (
                    Some("declarative-timed-out".to_string()),
                    Some(AttemptStage::Timeout)
                ),
            ]
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
                && event.error.as_ref().is_some_and(|error| {
                    error.stage == "shutdown" && error.code == "shutdownTimeout"
                })
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
                    position: None,
                    new_name: None,
                    range: None,
                    diagnostics: Vec::new(),
                    completion_context: None,
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
                        position: None,
                        new_name: None,
                        range: None,
                        diagnostics: Vec::new(),
                        completion_context: None,
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
                    position: None,
                    new_name: None,
                    range: None,
                    diagnostics: Vec::new(),
                    completion_context: None,
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
    fn document_saves_honor_server_options_and_never_replace_newer_editor_text() {
        let fixture: Value = serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/fixtures/lsp/document-save-v1.json"
        )))
        .unwrap();
        for case in fixture["cases"].as_array().unwrap() {
            let option = &case["saveOption"];
            let mut harness = Harness::start(|_| {});
            let mut capabilities = ready_capabilities();
            capabilities["textDocumentSync"] = json!({"change": 1, "save": option});
            harness.server.complete_initialize(capabilities);
            harness.await_state(LspLifecycleState::Ready);
            let uri = case["uri"].as_str().unwrap();
            let saved_text = case["savedText"].as_str().unwrap();
            harness.sync(uri, saved_text);
            let saved = || SaveDocumentRequest {
                session_id: harness.session_id.clone(),
                uri: uri.to_string(),
                text: saved_text.to_string(),
            };
            let supported = case["sent"].as_bool().unwrap();
            assert_eq!(harness.session().save_document(saved()).unwrap(), supported);
            if supported {
                let notification = harness
                    .server
                    .await_notification_at("textDocument/didSave", 0)
                    .unwrap();
                assert_eq!(notification["params"]["textDocument"]["uri"], uri);
                assert_eq!(
                    notification["params"].get("text"),
                    case["includeText"]
                        .as_bool()
                        .unwrap()
                        .then_some(&json!(saved_text))
                );
            }
            harness.sync(uri, "newer unsaved edit");
            assert!(!harness.session().save_document(saved()).unwrap());
            let session = harness.session();
            let state = session.lock_state().unwrap();
            assert_eq!(
                state.client.open_documents[uri].text.as_ref(),
                "newer unsaved edit"
            );
            assert_eq!(state.client.open_documents[uri].version, 2);
        }
    }

    /// Removes a scratch directory when the owning test ends or unwinds.
    struct ScratchDirectory(PathBuf);

    impl Drop for ScratchDirectory {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    // Regression: JDT publishes diagnostics under the resolved path of a file
    // the host opened through a symbolic link; matching the URIs textually
    // dropped every Java error in such a workspace.
    #[cfg(unix)]
    #[test]
    fn diagnostics_published_under_the_resolved_path_reach_the_linked_document() {
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system clock should follow the Unix epoch")
            .as_nanos();
        let scratch = ScratchDirectory(std::env::temp_dir().join(format!(
            "lithe-linked-diagnostics-{}-{stamp}",
            std::process::id()
        )));
        let workspace = scratch.0.join("resolved");
        std::fs::create_dir_all(&workspace).expect("workspace should be creatable");
        std::fs::write(workspace.join("main.go"), "package main").expect("source file");
        let link = scratch.0.join("link");
        std::os::unix::fs::symlink(&workspace, &link).expect("link should be creatable");
        let opened_uri = url::Url::from_file_path(link.join("main.go"))
            .expect("linked file converts to a URI")
            .to_string();
        let published_uri = url::Url::from_file_path(
            workspace
                .canonicalize()
                .expect("workspace canonicalizes")
                .join("main.go"),
        )
        .expect("resolved file converts to a URI")
        .to_string();
        assert_ne!(opened_uri, published_uri);

        let mut harness = Harness::ready();
        harness.sync(&opened_uri, "package main");
        harness.server.send(json!({
            "jsonrpc": "2.0",
            "method": "textDocument/publishDiagnostics",
            "params": {
                "uri": published_uri,
                "diagnostics": [{
                    "range": {
                        "start": { "line": 0, "character": 0 },
                        "end": { "line": 0, "character": 7 }
                    },
                    "severity": 1,
                    "message": "reported at the resolved path"
                }]
            }
        }));
        let event = harness
            .await_event(|event| event.kind == "diagnostics")
            .clone();
        assert_eq!(event.uri.as_deref(), Some(opened_uri.as_str()));
        assert_eq!(event.diagnostics.map(|list| list.len()), Some(1));
    }

    fn open_document(uri: &str) -> (String, LspClientDocument) {
        (
            uri.to_string(),
            LspClientDocument {
                uri: uri.to_string(),
                language_id: "go".to_string(),
                version: 1,
                text: "".into(),
            },
        )
    }

    // Servers publish for many files nobody has open. A session whose documents
    // were not opened through a link must remember that and leave those
    // messages untouched; closing a document must forget what was learned.
    #[cfg(unix)]
    #[test]
    fn diagnostics_for_unlinked_documents_are_left_alone_and_forgotten_on_close() {
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system clock should follow the Unix epoch")
            .as_nanos();
        let scratch = ScratchDirectory(std::env::temp_dir().join(format!(
            "lithe-unlinked-diagnostics-{}-{stamp}",
            std::process::id()
        )));
        std::fs::create_dir_all(&scratch.0).expect("scratch should be creatable");
        let real = scratch.0.canonicalize().expect("scratch canonicalizes");
        std::fs::write(real.join("main.go"), "package main").expect("source file");
        std::fs::write(real.join("other.go"), "package main").expect("source file");
        let uri_of = |name: &str| {
            url::Url::from_file_path(real.join(name))
                .expect("file converts to a URI")
                .to_string()
        };
        let message = |uri: &str| {
            json!({
                "jsonrpc": "2.0",
                "method": "textDocument/publishDiagnostics",
                "params": { "uri": uri, "diagnostics": [] }
            })
        };

        let documents: BTreeMap<_, _> = [open_document(&uri_of("main.go"))].into();
        let mut linked = LinkedDocumentPaths::default();
        assert_eq!(
            diagnostics_addressed_to_open_document(
                &documents,
                &mut linked,
                &message(&uri_of("other.go"))
            ),
            None
        );
        assert!(linked.resolved.is_empty());
        assert!(linked.examined.contains(&uri_of("main.go")));

        diagnostics_addressed_to_open_document(
            &BTreeMap::new(),
            &mut linked,
            &message(&uri_of("other.go")),
        );
        assert!(linked.examined.is_empty());
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

    /// Execution must not reach a model-only provider.
    #[test]
    fn provider_execution_requires_version_two() {
        let harness = negotiated_build_provider();
        let error = build_request(&harness, "lithe/build/execute", json!({}), None).unwrap_err();
        assert!(matches!(error.code, ErrorCode::NotSupported));
        assert!(harness
            .server
            .messages()
            .iter()
            .all(|message| message["method"] != "lithe/build/execute"));
    }

    #[test]
    fn provider_test_execution_requires_version_three() {
        for version in [1, 2] {
            for method in ["lithe/build/test", "lithe/build/discoverTests"] {
                let harness = plugin_backend(json!({"litheBuild":{"version":version}}));
                let error = build_request(&harness, method, json!({}), None).unwrap_err();
                assert!(matches!(error.code, ErrorCode::NotSupported));
                assert!(harness
                    .server
                    .messages()
                    .iter()
                    .all(|message| message["method"] != method));
            }
        }
    }

    #[test]
    fn provider_debug_preparation_requires_version_five_and_retains_progress() {
        for version in [1, 2, 3, 4] {
            let harness = plugin_backend(json!({"litheBuild":{"version":version}}));
            let error =
                build_request(&harness, "lithe/build/prepareDebug", json!({}), None).unwrap_err();
            assert_eq!(error.details.as_deref(), Some("plugin.build.unavailable"));
            assert!(harness
                .server
                .messages()
                .iter()
                .all(|message| message["method"] != "lithe/build/prepareDebug"));
        }
        let mut harness = plugin_backend(json!({"litheBuild":{"version":5}}));
        let operation =
            build_request(&harness, "lithe/build/prepareDebug", json!({}), None).unwrap();
        let request = harness
            .server
            .await_request("lithe/build/prepareDebug")
            .unwrap();
        let wire_id = request.clone();
        assert_eq!(
            harness.written_request(&request)["params"]["operationID"],
            wire_id
        );
        harness.server.send(json!({"jsonrpc":"2.0","method":"lithe/build/progress","params":{"operationID":wire_id,"output":"built"}}));
        let progress = harness.await_event(|event| {
            event.kind == "requestProgress"
                && event.operation_id.as_deref() == Some(operation.as_str())
        });
        assert_eq!(progress.result.as_ref().unwrap()["output"], "built");
        harness.server.send(json!({"jsonrpc":"2.0","id":request,"result":{"program":"app/bin/main","arguments":[],"environment":{},"workingDirectory":"app"}}));
        let done = harness.await_event(|event| {
            event.kind == "requestCompleted"
                && event.operation_id.as_deref() == Some(operation.as_str())
        });
        assert_eq!(
            done.result.as_ref().unwrap()["value"]["program"],
            "app/bin/main"
        );
    }

    #[test]
    fn inline_test_reports_cannot_reach_a_provider_without_version_eight() {
        for version in [7, 8] {
            let mut harness = plugin_backend(json!({"litheBuild":{"version":version}}));
            let result = build_request(
                &harness,
                "lithe/build/test",
                json!({"testResults":true}),
                None,
            );
            if version == 7 {
                assert!(matches!(result.unwrap_err().code, ErrorCode::NotSupported));
                assert!(harness
                    .server
                    .messages()
                    .iter()
                    .all(|message| message["method"] != "lithe/build/test"));
            } else {
                let operation = result.unwrap();
                let id = harness.server.await_request("lithe/build/test").unwrap();
                let value = json!({"exitCode":1,"output":"failure","testResults":{"format":"litheTestResults","version":1,"tests":[]}});
                harness
                    .server
                    .send(json!({"jsonrpc":"2.0","id":id,"result":value}));
                let event = harness.await_event(|event| {
                    event.kind == "requestCompleted"
                        && event.operation_id.as_deref() == Some(operation.as_str())
                });
                assert_eq!(event.result.as_ref().unwrap()["value"], value);
            }
        }
    }

    #[test]
    fn provider_native_configuration_requires_version_seven_and_returns_only_the_projection() {
        for version in 1..7 {
            let harness = plugin_backend(json!({"litheBuild":{"version":version}}));
            let error =
                build_request(&harness, "lithe/build/configuration", json!({}), None).unwrap_err();
            assert!(matches!(error.code, ErrorCode::NotSupported));
            assert!(harness
                .server
                .messages()
                .iter()
                .all(|message| message["method"] != "lithe/build/configuration"));
        }
        let mut harness = plugin_backend(json!({"litheBuild":{"version":7}}));
        let operation =
            build_request(&harness, "lithe/build/configuration", json!({}), None).unwrap();
        let id = harness
            .server
            .await_request("lithe/build/configuration")
            .unwrap();
        let result = json!({"format":"litheBuildConfiguration","version":1,"sources":[]});
        harness
            .server
            .send(json!({"jsonrpc":"2.0","id":id,"result":result}));
        let event = harness.await_event(|event| {
            event.kind == "requestCompleted"
                && event.operation_id.as_deref() == Some(operation.as_str())
        });
        assert_eq!(event.result.as_ref().unwrap()["value"], result);
    }

    /// User options must never be silently downgraded before a provider request.
    #[test]
    fn provider_run_options_require_version_ten_before_wire_send() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../../../shared/contracts/plugins/v1/fixtures/build-providers/build-run-options.json"
        ))
        .unwrap();
        let params = json!({"launchOptions":fixture["launchOptions"]});
        let old = plugin_backend(json!({"litheBuild":{"version":9}}));
        let error =
            build_request(&old, "lithe/build/prepareRun", params.clone(), None).unwrap_err();
        assert!(matches!(error.code, ErrorCode::NotSupported));
        assert!(old
            .server
            .messages()
            .iter()
            .all(|message| message["method"] != "lithe/build/prepareRun"));
        let mut current = plugin_backend(json!({"litheBuild":{"version":10}}));
        let error = build_request(&current, "lithe/build/model", params.clone(), None).unwrap_err();
        assert!(matches!(error.code, ErrorCode::InvalidRequest));
        let operation = build_request(&current, "lithe/build/prepareRun", params, None).unwrap();
        let id = current
            .server
            .await_request("lithe/build/prepareRun")
            .unwrap();
        let message = current
            .server
            .messages()
            .into_iter()
            .find(|message| message["method"] == "lithe/build/prepareRun")
            .unwrap();
        assert_eq!(message["params"]["launchOptions"], fixture["launchOptions"]);
        current
            .server
            .send(json!({"jsonrpc":"2.0","id":id,"result":fixture["result"]}));
        let event = current.await_event(|event| {
            event.kind == "requestCompleted"
                && event.operation_id.as_deref() == Some(operation.as_str())
        });
        assert_eq!(event.result.as_ref().unwrap()["value"], fixture["result"]);
    }

    /// Port ownership cannot be silently discarded by a version-10 process.
    #[test]
    fn provider_runtime_debug_requires_version_eleven_before_wire_send() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../../../shared/contracts/plugins/v1/fixtures/build-providers/build-connection-debug-options.json"
        ))
        .unwrap();
        let params = json!({"launchOptions":fixture["launchOptions"]});
        let old = plugin_backend(json!({"litheBuild":{"version":10}}));
        let error =
            build_request(&old, "lithe/build/prepareRun", params.clone(), None).unwrap_err();
        assert!(matches!(error.code, ErrorCode::NotSupported));
        assert!(old
            .server
            .messages()
            .iter()
            .all(|message| message["method"] != "lithe/build/prepareRun"));
        let mut current = plugin_backend(json!({"litheBuild":{"version":11}}));
        let operation = build_request(&current, "lithe/build/prepareRun", params, None).unwrap();
        let id = current
            .server
            .await_request("lithe/build/prepareRun")
            .unwrap();
        current
            .server
            .send(json!({"jsonrpc":"2.0","id":id,"result":fixture["result"]}));
        let event = current.await_event(|event| {
            event.kind == "requestCompleted"
                && event.operation_id.as_deref() == Some(operation.as_str())
        });
        assert_eq!(event.result.as_ref().unwrap()["value"], fixture["result"]);
    }

    #[test]
    fn provider_run_preparation_requires_version_four_and_returns_raw_plan() {
        for version in [1, 2, 3] {
            let harness = plugin_backend(json!({"litheBuild":{"version":version}}));
            let error =
                build_request(&harness, "lithe/build/prepareRun", json!({}), None).unwrap_err();
            assert!(matches!(error.code, ErrorCode::NotSupported));
            assert!(harness
                .server
                .messages()
                .iter()
                .all(|message| message["method"] != "lithe/build/prepareRun"));
        }
        let mut harness = plugin_backend(json!({"litheBuild":{"version":4}}));
        let operation = build_request(&harness, "lithe/build/prepareRun", json!({}), None).unwrap();
        let id = harness
            .server
            .await_request("lithe/build/prepareRun")
            .unwrap();
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../../../shared/contracts/plugins/v1/fixtures/build-providers/build-run-preparation.json"
        ))
        .unwrap();
        harness
            .server
            .send(json!({"jsonrpc":"2.0","id":id,"result":fixture["result"]}));
        let event = harness.await_event(|event| {
            event.kind == "requestCompleted"
                && event.operation_id.as_deref() == Some(operation.as_str())
        });
        assert_eq!(event.result.as_ref().unwrap()["value"], fixture["result"]);
    }

    #[test]
    fn provider_test_discovery_uses_the_existing_request_lifecycle() {
        let mut harness = plugin_backend(json!({"litheBuild":{"version":3}}));
        let operation = build_request(
            &harness,
            "lithe/build/discoverTests",
            json!({"root":"."}),
            None,
        )
        .unwrap();
        let id = harness
            .server
            .await_request("lithe/build/discoverTests")
            .unwrap();
        let result = json!({"format":"litheTestDiscovery","version":1,"tests":[]});
        harness
            .server
            .send(json!({"jsonrpc":"2.0","id":id,"result":result}));
        let event = harness.await_event(|event| {
            event.kind == "requestCompleted"
                && event.operation_id.as_deref() == Some(operation.as_str())
        });
        assert_eq!(event.result.as_ref().unwrap()["value"], result);
        assert!(harness.snapshot().pending_operation_ids.is_empty());
    }

    /// Ordered messages use a completed round trip as a barrier: old progress
    /// and replies are drained before checking that cancellation stayed final.
    #[test]
    fn provider_execution_progress_cancel_and_late_results_are_isolated() {
        for (version, method) in [
            (2, "lithe/build/execute"),
            (3, "lithe/build/test"),
            (4, "lithe/build/prepareRun"),
        ] {
            let mut harness = Harness::start(|_| {});
            harness
                .server
                .complete_initialize(json!({"experimental":{"litheBuild":{"version":version}}}));
            harness.await_state(LspLifecycleState::Ready);
            let operation =
                build_request(&harness, method, json!({"operationID":"spoof"}), None).unwrap();
            let id = harness.server.await_request(method).unwrap();
            assert_eq!(harness.written_request(&id)["params"]["operationID"], id);
            harness
                .server
                .send(json!({"jsonrpc":"2.0","method":"lithe/build/progress",
            "params":{"operationID":id,"output":"first","percentage":20}}));
            let progress = harness
                .await_event(|event| event.kind == "requestProgress")
                .clone();
            assert_eq!(progress.operation_id.as_deref(), Some(operation.as_str()));
            assert_eq!(progress.result.unwrap()["output"], "first");
            harness.session().cancel_operation(&operation).unwrap();
            let ended = harness
                .await_event(|event| {
                    event.kind == "requestCompleted"
                        && event.operation_id.as_deref() == Some(operation.as_str())
                })
                .clone();
            assert_eq!(ended.error.unwrap().code, "requestCancelled");
            harness
                .server
                .send(json!({"jsonrpc":"2.0","method":"lithe/build/progress",
            "params":{"operationID":id,"output":"late"}}));
            harness
                .server
                .send(json!({"jsonrpc":"2.0","id":id,"result":{"exitCode":0,"output":"late"}}));
            let barrier = build_request(&harness, "lithe/build/model", json!({}), None).unwrap();
            let barrier_id = harness.server.await_request("lithe/build/model").unwrap();
            harness
                .server
                .send(json!({"jsonrpc":"2.0","id":barrier_id,"result":{}}));
            harness.await_event(|event| {
                event.kind == "requestCompleted"
                    && event.operation_id.as_deref() == Some(barrier.as_str())
            });
            assert_eq!(
                harness
                    .events
                    .iter()
                    .filter(|event| event.kind == "requestProgress")
                    .count(),
                1
            );
            assert_eq!(
                harness
                    .events
                    .iter()
                    .filter(|event| event.kind == "requestCompleted"
                        && event.operation_id.as_deref() == Some(operation.as_str()))
                    .count(),
                1
            );
        }
    }

    /// Host operation IDs may be reused; only the current wire request ID
    /// may contribute progress to that new call.
    #[test]
    fn provider_execution_reused_host_ids_reject_old_wire_progress() {
        for (version, method) in [
            (2, "lithe/build/execute"),
            (3, "lithe/build/test"),
            (4, "lithe/build/prepareRun"),
        ] {
            let mut harness = plugin_backend(json!({"litheBuild":{"version":version}}));
            let operation = "reused-build".to_string();
            let send = |harness: &Harness| {
                harness
                    .session()
                    .build_request(
                        BuildProviderRequest {
                            session_id: harness.session_id.clone(),
                            operation_id: Some(operation.clone()),
                            method: method.to_string(),
                            params: json!({}),
                            timeout_milliseconds: None,
                        },
                        operation.clone(),
                    )
                    .unwrap()
            };
            send(&harness);
            let old = harness.server.await_request(method).unwrap();
            harness.session().cancel_operation(&operation).unwrap();
            harness.await_event(|event| {
                event.kind == "requestCompleted"
                    && event.operation_id.as_deref() == Some(operation.as_str())
            });
            send(&harness);
            let current = harness.server.await_request_at(method, 1).unwrap();
            assert_ne!(old, current);
            for (id, output) in [(old, "old"), (current, "current")] {
                harness
                    .server
                    .send(json!({"jsonrpc":"2.0","method":"lithe/build/progress",
                "params":{"operationID":id,"output":output}}));
            }
            harness.await_event(|event| {
                event.kind == "requestProgress"
                    && event
                        .result
                        .as_ref()
                        .is_some_and(|result| result["output"] == "current")
            });
            assert!(harness
                .events
                .iter()
                .filter(|event| event.kind == "requestProgress")
                .all(|event| event.result.as_ref().unwrap()["output"] != "old"));
            harness.session().cancel_operation(&operation).unwrap();
        }
    }

    #[test]
    fn provider_execution_validates_results_and_expires_without_sleeping() {
        for (version, method) in [
            (2, "lithe/build/execute"),
            (3, "lithe/build/test"),
            (4, "lithe/build/prepareRun"),
        ] {
            let mut harness = Harness::start(|_| {});
            harness
                .server
                .complete_initialize(json!({"experimental":{"litheBuild":{"version":version}}}));
            harness.await_state(LspLifecycleState::Ready);
            for (index, (reply, code)) in [
                (json!({"exitCode":7,"output":"failed build"}), None),
                (
                    json!({"exitCode":"bad"}),
                    Some("plugin.build.invalidResult"),
                ),
            ]
            .into_iter()
            .enumerate()
            {
                let operation = build_request(&harness, method, json!({}), None).unwrap();
                let id = harness.server.await_request_at(method, index).unwrap();
                harness
                    .server
                    .send(json!({"jsonrpc":"2.0","id":id,"result":reply}));
                let ended = harness
                    .await_event(|event| {
                        event.kind == "requestCompleted"
                            && event.operation_id.as_deref() == Some(operation.as_str())
                    })
                    .clone();
                // Preparation returns raw launch data; the build decoder validates it.
                let code = if version == 4 { None } else { code };
                assert_eq!(ended.error.as_ref().map(|error| error.code.as_str()), code);
                if code.is_none() {
                    assert_eq!(ended.result.unwrap()["value"], reply);
                }
            }
            let operation = build_request(&harness, method, json!({}), Some(1000)).unwrap();
            harness.server.await_request_at(method, 2).unwrap();
            harness
                .session()
                .expire_deadlines_at(Instant::now() + Duration::from_secs(2));
            assert_eq!(
                harness
                    .await_event(|event| event.kind == "requestCompleted"
                        && event.operation_id.as_deref() == Some(operation.as_str()))
                    .error
                    .as_ref()
                    .unwrap()
                    .code,
                "requestTimeout"
            );
            assert!(harness.snapshot().pending_operation_ids.is_empty());
        }
    }

    /// A process that answered build-provider protocol version 1.
    fn negotiated_build_provider() -> Harness {
        let mut harness = Harness::start(|_| {});
        harness.server.complete_initialize(json!({
            "experimental": { "litheBuild": { "version": 1 } }
        }));
        harness.await_state(LspLifecycleState::Ready);
        harness
    }

    fn build_request(
        harness: &Harness,
        method: &str,
        params: Value,
        timeout_milliseconds: Option<u64>,
    ) -> Result<String, CoreError> {
        let operation_id = harness.engine.next_operation_id();
        harness
            .session()
            .build_request(
                BuildProviderRequest {
                    session_id: harness.session_id.clone(),
                    operation_id: Some(operation_id.clone()),
                    method: method.to_string(),
                    params,
                    timeout_milliseconds,
                },
                operation_id.clone(),
            )
            .map(|()| operation_id)
    }

    /// Every session offers the protocol, but one whose process did not
    /// choose a version must never receive a build request: a shared
    /// language server keeps serving its language without it.
    #[test]
    fn build_requests_need_a_negotiated_protocol_version() {
        let harness = Harness::ready();
        let initialize = harness
            .server
            .messages()
            .into_iter()
            .find(|message| message["method"] == "initialize")
            .expect("initialize should have been written");
        assert_eq!(
            initialize["params"]["capabilities"]["experimental"]["litheBuild"],
            json!({ "versions": [11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1] })
        );

        let error = build_request(&harness, "lithe/build/model", json!({}), None)
            .expect_err("an unnegotiated session must refuse build requests");
        assert!(matches!(error.code, ErrorCode::NotSupported));
        assert!(harness
            .server
            .messages()
            .iter()
            .all(|message| message["method"] != "lithe/build/model"));
    }

    /// A legacy backend must never silently execute without a declared shared input.
    #[test]
    fn model_inputs_need_version_six_even_for_an_old_model_method() {
        for version in [5, 6] {
            let mut harness = Harness::start(|_| {});
            harness
                .server
                .complete_initialize(json!({"experimental":{"litheBuild":{"version":version}}}));
            harness.await_state(LspLifecycleState::Ready);
            let params = json!({"modelInputs":{"version":1,"revision":7,"inputs":[]}});
            let result = build_request(&harness, "lithe/build/model", params.clone(), None);
            if version == 5 {
                assert!(matches!(result.unwrap_err().code, ErrorCode::NotSupported));
                assert!(harness
                    .server
                    .messages()
                    .iter()
                    .all(|message| message["method"] != "lithe/build/model"));
            } else {
                let operation = result.unwrap();
                let id = harness
                    .server
                    .await_request("lithe/build/model")
                    .expect("version six receives its snapshot");
                assert_eq!(harness.written_request(&id)["params"], params);
                harness
                    .server
                    .send(json!({"jsonrpc":"2.0","id":id,"result":{"projects":[]}}));
                harness.await_event(|event| {
                    event.operation_id.as_deref() == Some(&operation)
                        && event.kind == "requestCompleted"
                });
            }
        }
    }

    #[test]
    fn a_negotiated_build_request_forwards_the_plan_and_returns_the_reply() {
        let mut harness = negotiated_build_provider();
        let params = json!({
            "buildSystemID": "gradle",
            "root": "",
            "options": { "offline": true },
            "optionArguments": ["--offline"],
            "environment": {}
        });
        let operation =
            build_request(&harness, "lithe/build/model", params.clone(), None).expect("accepted");
        let request_id = harness
            .server
            .await_request("lithe/build/model")
            .expect("the request should reach the provider");
        assert_eq!(harness.written_request(&request_id)["params"], params);

        // A reply with a `locations` field proves no navigation normalizer
        // rewrites the document Core decodes.
        let reply = json!({ "format": "litheBuildModel", "version": 1, "locations": [] });
        harness
            .server
            .send(json!({ "jsonrpc": "2.0", "id": request_id, "result": reply }));
        let completed = harness
            .await_event(|event| {
                event.kind == "requestCompleted"
                    && event.operation_id.as_deref() == Some(operation.as_str())
            })
            .clone();
        assert!(completed.error.is_none());
        assert_eq!(completed.result, Some(json!({ "value": reply })));
        assert!(harness.snapshot().pending_operation_ids.is_empty());
    }

    /// Only the negotiated methods pass, so the build path cannot become a
    /// generic JSON-RPC tunnel into a language server.
    #[test]
    fn build_requests_accept_only_the_protocol_methods() {
        let harness = negotiated_build_provider();
        for method in ["workspace/executeCommand", "shutdown"] {
            let error = build_request(&harness, method, json!({}), None)
                .expect_err("only protocol methods are build requests");
            assert!(matches!(error.code, ErrorCode::InvalidRequest), "{method}");
        }
        assert!(harness
            .server
            .messages()
            .iter()
            .all(|message| message["method"] != "workspace/executeCommand"));
    }

    /// A build request's own deadline replaces the session's request timeout,
    /// here shortened, and the timed-out request is cancelled on the wire.
    #[test]
    fn a_build_request_times_out_on_its_own_deadline() {
        let mut harness = negotiated_build_provider();
        let operation = build_request(&harness, "lithe/build/dependencies", json!({}), Some(30))
            .expect("accepted");
        harness
            .server
            .await_request("lithe/build/dependencies")
            .expect("the request should reach the provider");
        let timeout = harness
            .await_event(|event| event.operation_id.as_deref() == Some(operation.as_str()))
            .clone();
        assert_eq!(
            timeout.error.as_ref().map(|error| error.code.as_str()),
            Some("requestTimeout")
        );
        assert!(harness.server.await_notification("$/cancelRequest"));
    }

    #[test]
    fn keymap_import_negotiation_is_available_only_to_plugin_owned_sessions() {
        for plugin_owned in [false, true] {
            let mut harness = Harness::start(|request| {
                request.keymap_import_providers = vec!["fixture".to_string()];
                if plugin_owned {
                    request.plugin_id = Some("dev.lithe.fixture.import".to_string());
                }
            });
            harness.server.complete_initialize(json!({"experimental": {
                "litheKeymapImport": {"version": 1, "providers": ["fixture"]}
            }}));
            harness.await_state(LspLifecycleState::Ready);
            let initialize = harness
                .server
                .messages()
                .into_iter()
                .find(|message| message["method"] == "initialize")
                .unwrap();
            let offer =
                initialize["params"]["capabilities"]["experimental"].get("litheKeymapImport");
            assert_eq!(offer.is_some(), plugin_owned);
            if plugin_owned {
                assert_eq!(
                    offer,
                    Some(&json!({"versions": [1], "providers": ["fixture"]}))
                );
            }
            let event = harness
                .events
                .iter()
                .find(|event| event.kind == "keymapImportProviders");
            assert_eq!(event.is_some(), plugin_owned);
            if let Some(event) = event {
                assert_eq!(event.result, Some(json!({"providers": ["fixture"]})));
            }
        }
    }

    #[test]
    fn keymap_import_provider_cannot_select_an_undeclared_identity() {
        let mut harness = Harness::start(|request| {
            request.plugin_id = Some("dev.lithe.fixture.import".to_string());
            request.keymap_import_providers = vec!["fixture".to_string()];
        });
        harness.server.complete_initialize(json!({"experimental": {
            "litheKeymapImport": {"version": 1, "providers": ["fixture", "other"]}
        }}));
        harness.await_state(LspLifecycleState::Ready);
        assert!(harness
            .events
            .iter()
            .all(|event| event.kind != "keymapImportProviders"));
    }

    #[test]
    fn keymap_import_request_only_reaches_its_negotiated_provider() {
        let mut harness = Harness::start(|request| {
            request.plugin_id = Some("dev.lithe.fixture.import".to_string());
            request.keymap_import_providers = vec!["fixture".to_string()];
        });
        harness.server.complete_initialize(json!({"experimental": {
            "litheKeymapImport": {"version": 1, "providers": ["fixture"]}
        }}));
        harness.await_state(LspLifecycleState::Ready);
        let request = |provider: &str| KeymapImportProviderRequest {
            session_id: harness.session_id.clone(),
            operation_id: None,
            provider_id: provider.to_string(),
            snapshot_id: "snapshot-1".to_string(),
            timeout_milliseconds: Some(1_000),
        };
        assert!(harness
            .session()
            .keymap_import_request(request("other"), "refused".to_string())
            .is_err());
        assert!(harness
            .server
            .messages()
            .iter()
            .all(|message| message["method"] != "lithe/keymap/import"));
        harness
            .session()
            .keymap_import_request(request("fixture"), "import-1".to_string())
            .unwrap();
        let id = harness.server.await_request("lithe/keymap/import").unwrap();
        let wire_id: u64 = id.parse().unwrap();
        let sent = harness.written_request(&id);
        assert_eq!(
            sent["params"],
            json!({"providerID": "fixture", "snapshotID": "snapshot-1"})
        );
        let response = json!({"jsonrpc": "2.0", "id": wire_id, "result": {"bindings": []}});
        harness.server.send(response.clone());
        let event = harness.await_event(|event| {
            event.kind == "requestCompleted" && event.operation_id.as_deref() == Some("import-1")
        });
        assert_eq!(
            event.result,
            Some(json!({"value": {"id": wire_id, "response": response}}))
        );
    }

    #[test]
    fn keymap_import_request_rejects_paths_and_can_be_cancelled() {
        let mut harness = Harness::start(|request| {
            request.plugin_id = Some("dev.lithe.fixture.import".to_string());
            request.keymap_import_providers = vec!["fixture".to_string()];
        });
        harness.server.complete_initialize(json!({"experimental": {
            "litheKeymapImport": {"version": 1, "providers": ["fixture"]}
        }}));
        harness.await_state(LspLifecycleState::Ready);
        let mut request = KeymapImportProviderRequest {
            session_id: harness.session_id.clone(),
            operation_id: None,
            provider_id: "fixture".to_string(),
            snapshot_id: "../private".to_string(),
            timeout_milliseconds: None,
        };
        assert!(harness
            .session()
            .keymap_import_request(request.clone(), "invalid".to_string())
            .is_err());
        assert!(harness
            .server
            .messages()
            .iter()
            .all(|message| message["method"] != "lithe/keymap/import"));
        request.snapshot_id = "snapshot-1".to_string();
        harness
            .session()
            .keymap_import_request(request, "import-2".to_string())
            .unwrap();
        harness.server.await_request("lithe/keymap/import").unwrap();
        harness.session().cancel_operation("import-2").unwrap();
        assert!(harness.server.await_notification("$/cancelRequest"));
        let event = harness.await_event(|event| {
            event.kind == "requestCompleted" && event.operation_id.as_deref() == Some("import-2")
        });
        assert_eq!(
            event.error.as_ref().map(|error| error.code.as_str()),
            Some("requestCancelled")
        );
        assert!(event.result.is_none());
    }

    #[test]
    fn keymap_import_request_rejects_oversized_provider_replies() {
        let mut harness = Harness::start(|request| {
            request.plugin_id = Some("dev.lithe.fixture.import".to_string());
            request.keymap_import_providers = vec!["fixture".to_string()];
        });
        harness.server.complete_initialize(json!({"experimental": {
            "litheKeymapImport": {"version": 1, "providers": ["fixture"]}
        }}));
        harness.await_state(LspLifecycleState::Ready);
        let request = KeymapImportProviderRequest {
            session_id: harness.session_id.clone(),
            operation_id: None,
            provider_id: "fixture".to_string(),
            snapshot_id: "snapshot-1".to_string(),
            timeout_milliseconds: Some(5_000),
        };
        harness
            .session()
            .keymap_import_request(request, "import-3".to_string())
            .unwrap();
        let id = harness.server.await_request("lithe/keymap/import").unwrap();
        harness
            .server
            .send(json!({"jsonrpc": "2.0", "id": id.parse::<u64>().unwrap(),
            "result": {"data": "x".repeat(super::super::keymap_provider::MAX_REPLY_BYTES)}}));
        let event = harness.await_event(|event| {
            event.kind == "requestCompleted" && event.operation_id.as_deref() == Some("import-3")
        });
        assert_eq!(
            event.error.as_ref().map(|error| error.code.as_str()),
            Some("plugin.keymapImport.replyTooLarge")
        );
        assert!(event.result.is_none());
    }

    // Toolchain providers against a scripted backend. Only a plugin-owned
    // session launched with declared providers is offered `litheToolchains`,
    // and only a provider its process selected receives `toolchains/query`.

    fn toolchain_backend(answer: Value) -> Harness {
        let mut harness = Harness::start(|request| {
            request.plugin_id = Some("dev.lithe.fixture.toolchain-provider".to_string());
            request.toolchain_providers = vec!["mise".to_string()];
        });
        harness
            .server
            .complete_initialize(json!({ "experimental": { "litheToolchains": answer } }));
        harness.await_state(LspLifecycleState::Ready);
        harness
    }

    fn toolchain_query(harness: &Harness, provider: &str) -> Result<String, CoreError> {
        let operation_id = harness.engine.next_operation_id();
        harness
            .session()
            .toolchain_request(
                ToolchainProviderRequest {
                    session_id: harness.session_id.clone(),
                    operation_id: Some(operation_id.clone()),
                    params: json!({ "operationID": "query-1", "generation": 1, "providerID": provider }),
                    timeout_milliseconds: None,
                },
                operation_id.clone(),
            )
            .map(|()| operation_id)
    }

    fn no_toolchain_query_written(harness: &Harness) -> bool {
        harness
            .server
            .messages()
            .iter()
            .all(|message| message["method"] != "toolchains/query")
    }

    #[test]
    fn host_sessions_are_not_offered_the_toolchain_protocol() {
        let harness = Harness::start(|request| {
            request.toolchain_providers = vec!["mise".to_string()];
        });
        harness.server.complete_initialize(json!({}));
        let initialize = harness
            .server
            .messages()
            .into_iter()
            .find(|message| message["method"] == "initialize")
            .expect("initialize should have been written");
        assert!(initialize["params"]["capabilities"]["experimental"]
            .get("litheToolchains")
            .is_none());
    }

    #[test]
    fn a_query_reaches_only_a_selected_provider_and_returns_the_raw_response() {
        let mut harness = toolchain_backend(json!({ "version": 1, "providers": ["mise"] }));
        let initialize = harness
            .server
            .messages()
            .into_iter()
            .find(|message| message["method"] == "initialize")
            .expect("initialize should have been written");
        assert_eq!(
            initialize["params"]["capabilities"]["experimental"]["litheToolchains"],
            json!({ "versions": [1], "providers": ["mise"] })
        );
        let event = harness
            .await_event(|event| event.kind == "toolchainProviders")
            .clone();
        assert_eq!(event.result, Some(json!({ "providers": ["mise"] })));

        let refused = toolchain_query(&harness, "asdf").expect_err("not selected");
        assert_eq!(
            refused.details.as_deref(),
            Some("plugin.toolchain.providerUnavailable")
        );
        assert!(no_toolchain_query_written(&harness));

        let operation = toolchain_query(&harness, "mise").expect("written");
        let id = harness
            .server
            .await_request("toolchains/query")
            .expect("the query is written");
        let wire_id: u64 = id.parse().expect("a numeric wire ID");
        // Even a provider error stays a raw reply: decodeReply owns its mapping.
        let response = json!({
            "jsonrpc": "2.0", "id": wire_id,
            "error": { "code": -32073, "message": "untrusted", "data": { "code": "x" } }
        });
        harness.server.send(response.clone());
        let event = harness
            .await_event(|event| {
                event.kind == "requestCompleted"
                    && event.operation_id.as_deref() == Some(operation.as_str())
            })
            .clone();
        assert!(event.error.is_none());
        assert_eq!(
            event.result,
            Some(json!({ "value": { "id": wire_id, "response": response } }))
        );
    }

    #[test]
    fn an_undeclared_toolchain_provider_enables_nothing() {
        let mut harness = toolchain_backend(json!({ "version": 1, "providers": ["mise", "asdf"] }));
        harness.poll();
        assert!(harness
            .events
            .iter()
            .all(|event| event.kind != "toolchainProviders"));
        let error = toolchain_query(&harness, "mise").expect_err("refused");
        assert!(matches!(error.code, ErrorCode::NotSupported));
        assert!(no_toolchain_query_written(&harness));
    }

    // VCS providers against a scripted backend. Only a plugin-owned session
    // is offered `litheVcs`, and only one whose process answered with a VCS
    // ID and every required capability receives requests, each planned by
    // Core from an operation name.

    const VCS_PLUGIN: &str = "dev.lithe.fixture.vcs-provider";

    fn vcs_capabilities() -> Value {
        json!({ "status": 1, "baseContent": 1, "checkin": 1, "rollback": 1, "update": 1 })
    }

    fn vcs_backend(answer: Value) -> Harness {
        let mut harness = Harness::start(|request| {
            request.plugin_id = Some(VCS_PLUGIN.to_string());
        });
        harness
            .server
            .complete_initialize(json!({ "experimental": { "litheVcs": answer } }));
        harness.await_state(LspLifecycleState::Ready);
        harness
    }

    fn negotiated_vcs_provider() -> Harness {
        vcs_backend(json!({ "version": 1, "vcs": "svn", "capabilities": vcs_capabilities() }))
    }

    /// A native absolute path on every platform the tests run on.
    fn working_copy() -> String {
        std::env::temp_dir()
            .join("lithe-vcs-working-copy")
            .to_string_lossy()
            .into_owned()
    }

    fn vcs_request(
        harness: &Harness,
        vcs: &str,
        operation: &str,
        arguments: Value,
    ) -> Result<String, CoreError> {
        let operation_id = harness.engine.next_operation_id();
        harness
            .session()
            .vcs_request(
                VcsProviderRequest {
                    session_id: harness.session_id.clone(),
                    operation_id: Some(operation_id.clone()),
                    vcs: vcs.to_string(),
                    operation: operation.to_string(),
                    root: working_copy(),
                    tool: None,
                    arguments,
                    timeout_milliseconds: None,
                },
                operation_id.clone(),
            )
            .map(|()| operation_id)
    }

    /// Feature names the session recorded from the provider's answer.
    fn vcs_features(harness: &Harness) -> Vec<String> {
        let session = harness.session();
        let state = session.lock_state().expect("state");
        state.client.server_capabilities.clone()
    }

    fn no_vcs_request_written(harness: &Harness) -> bool {
        harness.server.messages().iter().all(|message| {
            !message["method"]
                .as_str()
                .is_some_and(|method| method.starts_with("lithe/vcs/"))
        })
    }

    #[test]
    fn host_sessions_are_not_offered_the_vcs_protocol() {
        let harness = Harness::ready();
        let initialize = harness
            .server
            .messages()
            .into_iter()
            .find(|message| message["method"] == "initialize")
            .expect("initialize should have been written");
        assert!(initialize["params"]["capabilities"]["experimental"]
            .get("litheVcs")
            .is_none());
        let error = vcs_request(&harness, "svn", "status", json!({}))
            .expect_err("a host session is never a provider");
        assert!(matches!(error.code, ErrorCode::NotSupported));
        assert_eq!(error.details.as_deref(), Some("vcs.provider.unavailable"));
        assert!(no_vcs_request_written(&harness));
    }

    /// The negotiated VCS and capabilities reach the host as one event, so
    /// it can check the VCS against the manifest and pick the actions to show.
    #[test]
    fn a_negotiated_provider_is_announced_with_its_capabilities() {
        let mut harness = negotiated_vcs_provider();
        let event = harness
            .await_event(|event| event.kind == "vcsProvider")
            .clone();
        assert_eq!(
            event.result,
            Some(json!({ "vcs": "svn", "capabilities": vcs_capabilities() }))
        );
        assert!(vcs_features(&harness)
            .iter()
            .any(|feature| feature == "litheVcs"));
    }

    /// Version 1 has no host side for credentials or console routing yet: an
    /// authentication request is refused so the provider fails with
    /// `vcs.authentication.failed`, and an execution report is passed on as a
    /// session log entry.
    #[test]
    fn provider_authentication_is_refused_and_execution_reports_pass_through() {
        let mut harness = negotiated_vcs_provider();
        harness.server.send(json!({
            "jsonrpc": "2.0",
            "id": "auth-1",
            "method": "lithe/vcs/authenticate",
            "params": { "realm": "<https://svn.example.invalid:443> Example" }
        }));
        assert_eq!(await_reply(&harness, "auth-1")["error"]["code"], -32601);
        harness.server.send(json!({
            "jsonrpc": "2.0",
            "method": "lithe/vcs/execution",
            "params": { "kind": "started", "arguments": ["status", "--xml"] }
        }));
        let event = harness
            .await_event(|event| {
                event.kind == "log" && event.message.as_deref() == Some("lithe/vcs/execution")
            })
            .clone();
        assert!(event
            .detail
            .as_deref()
            .is_some_and(|detail| detail.contains("--xml")));
    }

    /// An answer without a required capability makes the process a plain
    /// plugin session: no announcement, no feature, and no request.
    #[test]
    fn an_incomplete_vcs_answer_is_not_a_provider() {
        let mut harness = vcs_backend(json!({
            "version": 1, "vcs": "svn", "capabilities": { "status": 1, "baseContent": 1 }
        }));
        harness.poll();
        assert!(harness
            .events
            .iter()
            .all(|event| event.kind != "vcsProvider"));
        assert!(vcs_features(&harness)
            .iter()
            .all(|feature| feature != "litheVcs"));
        let error = vcs_request(&harness, "svn", "status", json!({})).expect_err("refused");
        assert_eq!(error.details.as_deref(), Some("vcs.provider.unavailable"));
        assert!(no_vcs_request_written(&harness));
    }

    #[test]
    fn a_vcs_request_is_planned_from_its_operation_and_returns_the_reply() {
        let mut harness = negotiated_vcs_provider();
        let operation = vcs_request(
            &harness,
            "svn",
            "checkin",
            json!({ "paths": ["src/b.txt", "src/a.txt"], "message": "Fix" }),
        )
        .expect("accepted");
        let request_id = harness
            .server
            .await_request("lithe/vcs/checkin")
            .expect("the request should reach the provider");
        assert_eq!(
            harness.written_request(&request_id)["params"],
            json!({
                "paths": ["src/a.txt", "src/b.txt"],
                "message": "Fix",
                "root": { "path": working_copy() },
                "tool": null
            })
        );
        let reply = json!({ "revision": { "id": "12", "display": "r12", "kind": "number" } });
        harness
            .server
            .send(json!({ "jsonrpc": "2.0", "id": request_id, "result": reply }));
        let completed = harness
            .await_event(|event| {
                event.kind == "requestCompleted"
                    && event.operation_id.as_deref() == Some(operation.as_str())
            })
            .clone();
        assert!(completed.error.is_none(), "{:?}", completed.error);
        assert_eq!(completed.result, Some(json!({ "value": reply })));
        assert!(harness.snapshot().pending_operation_ids.is_empty());
    }

    /// The host names an operation, never a method, so the session cannot
    /// be used as a tunnel; another VCS, an unknown operation, a capability
    /// the provider lacks, or a path leaving the root never reach the wire.
    #[test]
    fn vcs_requests_are_refused_before_they_are_written() {
        let harness = negotiated_vcs_provider();
        let error = vcs_request(&harness, "hg", "status", json!({})).expect_err("wrong VCS");
        assert_eq!(error.details.as_deref(), Some("vcs.provider.unavailable"));
        let error =
            vcs_request(&harness, "svn", "shutdown", json!({})).expect_err("no such operation");
        assert!(matches!(error.code, ErrorCode::InvalidRequest));
        let error = vcs_request(&harness, "svn", "annotate", json!({ "path": "a.txt" }))
            .expect_err("not negotiated");
        assert!(matches!(error.code, ErrorCode::NotSupported));
        assert_eq!(error.details.as_deref(), Some("vcs.capability.unsupported"));
        let error = vcs_request(&harness, "svn", "rollback", json!({ "paths": ["../x"] }))
            .expect_err("outside the root");
        assert!(matches!(error.code, ErrorCode::InvalidRequest));
        assert!(no_vcs_request_written(&harness));
    }

    /// A provider may name one of the contract's failure codes; any other
    /// code, including one of Lithe's own, becomes the generic failure.
    #[test]
    fn vcs_failures_keep_only_contract_codes() {
        let mut harness = negotiated_vcs_provider();
        for (index, (data, expected)) in [
            (json!({ "code": "vcs.outOfDate" }), "vcs.outOfDate"),
            (
                json!({ "code": "plugin.vcs.invalidOutput" }),
                "vcs.provider.failed",
            ),
        ]
        .into_iter()
        .enumerate()
        {
            let operation = vcs_request(&harness, "svn", "update", json!({})).expect("sent");
            let request_id = harness
                .server
                .await_request_at("lithe/vcs/update", index)
                .expect("the request should reach the provider");
            harness.server.send(json!({
                "jsonrpc": "2.0",
                "id": request_id,
                "error": { "code": -32000, "message": "Working copy is out of date.", "data": data }
            }));
            let error = harness
                .await_event(|event| event.operation_id.as_deref() == Some(operation.as_str()))
                .error
                .clone()
                .expect("an error reply fails the request");
            assert_eq!(error.code, expected);
            assert_eq!(error.message, "Working copy is out of date.");
        }
    }

    // Plugin functions against a scripted backend. The scripted server plays
    // the plugin process, so every outcome (result, failure, cancellation,
    // deadline, late reply, revocation, and compatibility with a backend that
    // only speaks the build protocol) is driven at a chosen moment.

    const FUNCTION_PLUGIN: &str = "dev.lithe.fixture.maven";

    /// A session owned by `FUNCTION_PLUGIN` whose backend answered
    /// `initialize` with `experimental`.
    fn plugin_backend(experimental: Value) -> Harness {
        let mut harness = Harness::start(|request| {
            request.plugin_id = Some(FUNCTION_PLUGIN.to_string());
        });
        harness
            .server
            .complete_initialize(json!({ "experimental": experimental }));
        harness.await_state(LspLifecycleState::Ready);
        harness
    }

    fn function_backend() -> Harness {
        plugin_backend(json!({
            "litheBuild": { "version": 1 },
            "litheFunctions": { "version": 1, "functions": [{ "id": "snapshot.refresh" }] }
        }))
    }

    fn invoke(
        harness: &Harness,
        plugin_id: &str,
        function_id: &str,
        timeout_milliseconds: Option<u64>,
    ) -> Result<String, CoreError> {
        let operation_id = harness.engine.next_operation_id();
        invoke_with_operation(
            harness,
            plugin_id,
            function_id,
            timeout_milliseconds,
            operation_id,
        )
    }

    /// Starts a call using a host-selected ID so regressions can exercise ID reuse.
    fn invoke_with_operation(
        harness: &Harness,
        plugin_id: &str,
        function_id: &str,
        timeout_milliseconds: Option<u64>,
        operation_id: String,
    ) -> Result<String, CoreError> {
        harness
            .session()
            .function_request(
                PluginFunctionRequest {
                    session_id: harness.session_id.clone(),
                    operation_id: Some(operation_id.clone()),
                    function: super::super::plugin_function::FunctionReference {
                        plugin_id: plugin_id.to_string(),
                        function_id: function_id.to_string(),
                    },
                    params: json!({ "project": "app" }),
                    timeout_milliseconds,
                    context: None,
                },
                operation_id.clone(),
                None,
            )
            .map(|()| operation_id)
    }

    /// The engine's reply to a request the scripted backend sent, waited for
    /// with a bounded deadline because the reply is written by the reader thread.
    fn await_reply(harness: &Harness, id: &str) -> Value {
        harness
            .server
            .await_response(id)
            .unwrap_or_else(|| panic!("the engine never answered backend request {id}"))
    }

    fn plugin_configured() -> Harness {
        let mut harness = Harness::start(|request| {
            request.plugin_id = Some("dev.lithe.go".to_string());
            request.workspace_configuration = Some(json!({
                "gopls": { "ui": { "staticcheck": true } },
                "go.dotted": 7
            }));
        });
        harness.server.complete_initialize(ready_capabilities());
        harness.await_state(LspLifecycleState::Ready);
        harness
    }

    #[test]
    fn plugin_configuration_answers_sections_and_announces_itself() {
        let harness = plugin_configured();
        assert!(harness
            .server
            .await_notification("workspace/didChangeConfiguration"));
        harness.server.send(json!({
            "jsonrpc": "2.0",
            "id": "cfg-1",
            "method": "workspace/configuration",
            "params": { "items": [
                { "section": "gopls" },
                { "section": "gopls.ui.staticcheck" },
                { "section": "go.dotted" },
                { "section": "missing.path" }
            ] }
        }));
        let reply = await_reply(&harness, "cfg-1");
        assert_eq!(
            reply["result"],
            json!([{ "ui": { "staticcheck": true } }, true, 7, null])
        );
    }

    #[test]
    fn plugin_configuration_updates_reach_a_running_server() {
        let harness = plugin_configured();
        let response = harness
            .session()
            .update_plugin_configuration(json!({ "gopls": { "ui": { "staticcheck": false } } }))
            .expect("the update should be accepted");
        assert!(response.sent);
        let change = harness
            .server
            .await_notification_at("workspace/didChangeConfiguration", 1)
            .expect("the configuration change was never sent");
        assert_eq!(
            change["params"]["settings"]["gopls"]["ui"]["staticcheck"],
            json!(false)
        );
    }

    #[test]
    fn host_servers_reject_plugin_configuration() {
        let harness = Harness::ready();
        assert!(harness
            .session()
            .update_plugin_configuration(json!({}))
            .is_err());
        assert!(checked_workspace_configuration(Some(json!([1]))).is_err());
    }

    fn completions(harness: &mut Harness, operation: &str) -> Vec<LspRuntimeEvent> {
        harness.poll();
        harness
            .events
            .iter()
            .filter(|event| {
                event.kind == "requestCompleted" && event.operation_id.as_deref() == Some(operation)
            })
            .cloned()
            .collect()
    }

    #[test]
    fn a_plugin_function_is_routed_to_its_plugin_and_returns_its_result() {
        let mut harness = function_backend();
        let initialize = harness
            .server
            .messages()
            .into_iter()
            .find(|message| message["method"] == "initialize")
            .expect("initialize should have been written");
        assert_eq!(
            initialize["params"]["capabilities"]["experimental"],
            json!({
                "litheBuild": { "versions": [11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1] },
                "litheFunctions": { "versions": [1, 2, 3, 4] },
                "litheLogging": { "versions": [1] },
                "litheVcs": { "versions": [1] }
            })
        );

        // Another plugin's reference never reaches this process.
        let error = invoke(
            &harness,
            "dev.lithe.fixture.gradle",
            "snapshot.refresh",
            None,
        )
        .expect_err("a foreign plugin is refused");
        assert!(matches!(error.code, ErrorCode::PermissionDenied));
        assert_eq!(
            error.details.as_deref(),
            Some("plugin.function.wrongPlugin")
        );
        let error = invoke(&harness, FUNCTION_PLUGIN, "snapshot.clear", None)
            .expect_err("an unregistered function is refused");
        assert_eq!(error.details.as_deref(), Some("plugin.function.unknown"));
        assert!(harness
            .server
            .messages()
            .iter()
            .all(|message| message["method"] != "lithe/function/invoke"));

        let operation = invoke(&harness, FUNCTION_PLUGIN, "snapshot.refresh", None).expect("sent");
        let request_id = harness
            .server
            .await_request("lithe/function/invoke")
            .expect("the call should reach the backend");
        let wire_operation = harness.written_request(&request_id)["params"]["operationID"].clone();
        assert!(wire_operation.as_str().is_some_and(|id| !id.is_empty()));
        assert_eq!(
            harness.written_request(&request_id)["params"],
            json!({
                "functionID": "snapshot.refresh",
                "operationID": wire_operation,
                "params": { "project": "app" }
            })
        );
        harness.server.send(json!({
            "jsonrpc": "2.0",
            "id": request_id,
            "result": { "snapshot": 3, "locations": [] }
        }));
        let completed = harness
            .await_event(|event| {
                event.kind == "requestCompleted"
                    && event.operation_id.as_deref() == Some(operation.as_str())
            })
            .clone();
        assert!(completed.error.is_none());
        assert_eq!(
            completed.result,
            Some(json!({ "value": { "snapshot": 3, "locations": [] } }))
        );
        assert!(harness.snapshot().pending_operation_ids.is_empty());
    }

    #[test]
    fn a_failing_plugin_function_reports_the_stable_and_the_plugin_code() {
        let mut harness = function_backend();
        let operation = invoke(&harness, FUNCTION_PLUGIN, "snapshot.refresh", None).expect("sent");
        let request_id = harness
            .server
            .await_request("lithe/function/invoke")
            .expect("the call should reach the backend");
        harness.server.send(json!({
            "jsonrpc": "2.0",
            "id": request_id,
            "error": { "code": -32000, "message": "Snapshot is locked.", "data": { "code": "maven.snapshotLocked" } }
        }));
        let error = harness
            .await_event(|event| event.operation_id.as_deref() == Some(operation.as_str()))
            .error
            .clone()
            .expect("an error reply fails the call");
        assert_eq!(error.code, "plugin.function.failed");
        assert_eq!(error.message, "Snapshot is locked.");
        assert_eq!(
            error.plugin_error_code.as_deref(),
            Some("maven.snapshotLocked")
        );
    }

    /// Cancellation reaches the backend, ends the call once, and neither a
    /// late reply nor a late progress report revives it.
    #[test]
    fn a_cancelled_plugin_function_ignores_its_late_reply_and_progress() {
        let mut harness = function_backend();
        let operation = invoke(&harness, FUNCTION_PLUGIN, "snapshot.refresh", None).expect("sent");
        let request_id = harness
            .server
            .await_request("lithe/function/invoke")
            .expect("the call should reach the backend");
        let wire_operation = harness.written_request(&request_id)["params"]["operationID"].clone();
        harness.server.send(json!({
            "jsonrpc": "2.0",
            "method": "lithe/function/progress",
            "params": { "operationID": wire_operation, "message": "Reading snapshot", "percentage": 40 }
        }));
        let progress = harness
            .await_event(|event| event.kind == "requestProgress")
            .clone();
        assert_eq!(progress.operation_id.as_deref(), Some(operation.as_str()));
        assert_eq!(
            progress.result,
            Some(
                json!({ "operationID": operation, "message": "Reading snapshot", "percentage": 40 })
            )
        );

        harness
            .session()
            .cancel_operation(&operation)
            .expect("a running call can be cancelled");
        assert!(harness.server.await_notification("$/cancelRequest"));
        harness.server.send(json!({
            "jsonrpc": "2.0",
            "method": "lithe/function/progress",
            "params": { "operationID": wire_operation, "percentage": 90 }
        }));
        harness
            .server
            .send(json!({ "jsonrpc": "2.0", "id": request_id, "result": "too late" }));
        // A request the backend sends after the late messages is answered only
        // once the reader has processed them, so its reply orders the check.
        harness.server.send(json!({
            "jsonrpc": "2.0",
            "id": "fence",
            "method": "workspace/configuration",
            "params": { "items": [] }
        }));
        await_reply(&harness, "fence");

        let ended = completions(&mut harness, &operation);
        assert_eq!(
            ended.len(),
            1,
            "a late reply must not complete the call again"
        );
        assert_eq!(
            ended[0].error.as_ref().map(|error| error.code.as_str()),
            Some("requestCancelled")
        );
        assert_eq!(
            harness
                .events
                .iter()
                .filter(|event| event.kind == "requestProgress")
                .count(),
            1,
            "progress after cancellation must be dropped"
        );
    }

    #[test]
    fn a_plugin_function_times_out_on_its_own_deadline() {
        let mut harness = function_backend();
        let operation =
            invoke(&harness, FUNCTION_PLUGIN, "snapshot.refresh", Some(60_000)).expect("sent");
        harness
            .server
            .await_request("lithe/function/invoke")
            .expect("the call should reach the backend");
        harness
            .session()
            .expire_deadlines_at(Instant::now() + Duration::from_secs(30));
        assert!(completions(&mut harness, &operation).is_empty());
        assert_eq!(
            harness.snapshot().pending_operation_ids,
            vec![operation.clone()]
        );
        harness
            .session()
            .expire_deadlines_at(Instant::now() + Duration::from_secs(61));
        let timeout = harness
            .await_event(|event| event.operation_id.as_deref() == Some(operation.as_str()))
            .clone();
        assert_eq!(
            timeout.error.as_ref().map(|error| error.code.as_str()),
            Some("requestTimeout")
        );
        assert!(harness.server.await_notification("$/cancelRequest"));
    }

    /// Registration after `initialize` is all or nothing, and withdrawing a
    /// function ends its running calls instead of letting them finish later.
    #[test]
    fn unregistering_a_running_function_revokes_the_call() {
        let mut harness = function_backend();
        harness.server.send(json!({
            "jsonrpc": "2.0",
            "id": "register-bad",
            "method": "lithe/function/register",
            "params": { "functions": [{ "id": "snapshot.clear" }, { "id": "snapshot.refresh" }] }
        }));
        let refused = await_reply(&harness, "register-bad");
        assert_eq!(
            refused["error"]["data"]["code"],
            "plugin.function.invalidRegistration"
        );

        harness.server.send(json!({
            "jsonrpc": "2.0",
            "id": "register",
            "method": "lithe/function/register",
            "params": { "functions": [{ "id": "snapshot.clear" }] }
        }));
        assert_eq!(await_reply(&harness, "register")["result"], Value::Null);
        let changed = harness
            .await_event(|event| {
                event.kind == "functionsChanged"
                    && event.result.as_ref().is_some_and(|result| {
                        result["functions"] == json!(["snapshot.clear", "snapshot.refresh"])
                    })
            })
            .clone();
        assert_eq!(
            changed.result,
            Some(json!({ "functions": ["snapshot.clear", "snapshot.refresh"], "removed": [] }))
        );

        let operation = invoke(&harness, FUNCTION_PLUGIN, "snapshot.clear", None).expect("sent");
        let request_id = harness
            .server
            .await_request("lithe/function/invoke")
            .expect("the call should reach the backend");
        harness.server.send(json!({
            "jsonrpc": "2.0",
            "id": "unregister",
            "method": "lithe/function/unregister",
            "params": { "ids": ["snapshot.clear"] }
        }));
        assert_eq!(await_reply(&harness, "unregister")["result"], Value::Null);
        let revoked = harness
            .await_event(|event| event.operation_id.as_deref() == Some(operation.as_str()))
            .clone();
        assert_eq!(
            revoked.error.as_ref().map(|error| error.code.as_str()),
            Some("plugin.function.revoked")
        );
        // The revocation is published before the cancellation is written, so
        // the write is awaited rather than expected to be there already.
        let cancel = harness
            .server
            .await_notification_at("$/cancelRequest", 0)
            .expect("the revoked call should be cancelled on the wire");
        assert_eq!(cancel["params"]["id"], request_id);
        let error = invoke(&harness, FUNCTION_PLUGIN, "snapshot.clear", None)
            .expect_err("a withdrawn function is unknown");
        assert_eq!(error.details.as_deref(), Some("plugin.function.unknown"));
        assert!(harness.snapshot().pending_operation_ids.is_empty());
    }

    /// A backend written before plugin functions keeps its build requests;
    /// it receives no function calls and its function messages are not
    /// mistaken for registrations.
    #[test]
    fn a_build_only_backend_keeps_working_without_plugin_functions() {
        let mut harness = plugin_backend(json!({ "litheBuild": { "version": 1 } }));
        let error = invoke(&harness, FUNCTION_PLUGIN, "snapshot.refresh", None)
            .expect_err("functions need the negotiated protocol");
        assert!(matches!(error.code, ErrorCode::NotSupported));
        assert_eq!(
            error.details.as_deref(),
            Some("plugin.function.unavailable")
        );

        harness.server.send(json!({
            "jsonrpc": "2.0",
            "id": "register",
            "method": "lithe/function/register",
            "params": { "functions": [{ "id": "snapshot.refresh" }] }
        }));
        assert_eq!(await_reply(&harness, "register")["error"]["code"], -32601);

        let operation = build_request(&harness, "lithe/build/model", json!({}), None)
            .expect("the build protocol is unaffected");
        let request_id = harness
            .server
            .await_request("lithe/build/model")
            .expect("the build request should reach the backend");
        let reply = json!({ "format": "litheBuildModel", "version": 1 });
        harness
            .server
            .send(json!({ "jsonrpc": "2.0", "id": request_id, "result": reply }));
        let completed = harness
            .await_event(|event| event.operation_id.as_deref() == Some(operation.as_str()))
            .clone();
        assert_eq!(completed.result, Some(json!({ "value": reply })));
    }

    /// Host-owned sessions neither offer nor accept the plugin-function protocol.
    #[test]
    fn a_host_owned_session_serves_no_plugin_functions() {
        let mut harness = Harness::start(|_| {});
        harness.server.complete_initialize(json!({
            "experimental": { "litheFunctions": { "version": 1, "functions": [{ "id": "snapshot.refresh" }] } }
        }));
        harness.await_state(LspLifecycleState::Ready);
        let initialize = harness
            .server
            .messages()
            .into_iter()
            .find(|message| message["method"] == "initialize")
            .expect("initialize written");
        assert!(initialize["params"]["capabilities"]["experimental"]
            .get("litheFunctions")
            .is_none());
        assert!(!harness
            .session()
            .lock_state()
            .expect("session state")
            .client
            .server_capabilities
            .iter()
            .any(|feature| feature == "litheFunctions"));
        for (id, method, params) in [
            (
                "host-register",
                "lithe/function/register",
                json!({ "functions": [{ "id": "snapshot.clear" }] }),
            ),
            (
                "host-unregister",
                "lithe/function/unregister",
                json!({ "ids": ["snapshot.refresh"] }),
            ),
        ] {
            harness
                .server
                .send(json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params }));
            assert_eq!(await_reply(&harness, id)["error"]["code"], -32601);
        }
        harness.poll();
        assert!(harness
            .events
            .iter()
            .all(|event| event.kind != "functionsChanged"));
        let error = invoke(&harness, FUNCTION_PLUGIN, "snapshot.refresh", None)
            .expect_err("a session without a plugin is refused");
        assert_eq!(
            error.details.as_deref(),
            Some("plugin.function.unavailable")
        );
    }

    /// Ends the first invocation at a controlled boundary before reusing its host ID.
    fn finish_function_for_reuse(
        harness: &mut Harness,
        operation: &str,
        request: &str,
        ending: &str,
    ) {
        match ending {
            "cancel" => harness
                .session()
                .cancel_operation(operation)
                .expect("cancelled"),
            "timeout" => harness
                .session()
                .expire_deadlines_at(Instant::now() + Duration::from_secs(61)),
            "complete" => harness
                .server
                .send(json!({ "jsonrpc": "2.0", "id": request, "result": "first" })),
            "error" => harness.server.send(json!({ "jsonrpc": "2.0", "id": request, "error": { "code": -32000, "message": "first failed" } })),
            "revoke" => {
                harness.server.send(json!({
                    "jsonrpc": "2.0", "id": "withdraw-first", "method": "lithe/function/unregister",
                    "params": { "ids": ["snapshot.refresh"] }
                }));
                assert_eq!(
                    await_reply(harness, "withdraw-first")["result"],
                    Value::Null
                );
            }
            _ => panic!("unknown termination scenario"),
        }
        harness.await_event(|event| {
            event.kind == "requestCompleted" && event.operation_id.as_deref() == Some(operation)
        });
        if matches!(ending, "cancel" | "timeout" | "revoke") {
            assert!(harness.server.await_notification("$/cancelRequest"));
        }
        if ending == "revoke" {
            harness.server.send(json!({
                "jsonrpc": "2.0", "id": "restore-first", "method": "lithe/function/register",
                "params": { "functions": [{ "id": "snapshot.refresh" }] }
            }));
            assert_eq!(await_reply(harness, "restore-first")["result"], Value::Null);
        }
    }

    #[test]
    fn plugin_function_initialization_publishes_the_full_registry() {
        for functions in [
            json!([{ "id": "snapshot.refresh" }, { "id": "snapshot.clear" }]),
            json!([]),
        ] {
            let mut harness = plugin_backend(
                json!({ "litheFunctions": { "version": 1, "functions": functions } }),
            );
            let initialized = harness
                .await_event(|event| event.kind == "functionsChanged")
                .clone();
            let mut expected: Vec<_> = functions
                .as_array()
                .expect("descriptors")
                .iter()
                .map(|item| item["id"].as_str().expect("function identifier"))
                .collect();
            expected.sort_unstable();
            assert_eq!(
                initialized.result,
                Some(json!({ "functions": expected, "removed": [] }))
            );
            assert_eq!(
                harness
                    .events
                    .iter()
                    .filter(|event| event.kind == "functionsChanged")
                    .count(),
                1
            );
        }
    }

    /// An ended call's response and progress cannot become the next call's result,
    /// even when the host chooses the same operation ID after every terminal outcome.
    #[test]
    fn reused_plugin_function_operation_ids_ignore_old_wire_progress() {
        for ending in ["cancel", "timeout", "complete", "error", "revoke"] {
            let mut harness = function_backend();
            harness.server.send(json!({
                "jsonrpc": "2.0", "id": "register-second", "method": "lithe/function/register",
                "params": { "functions": [{ "id": "snapshot.clear" }] }
            }));
            assert_eq!(
                await_reply(&harness, "register-second")["result"],
                Value::Null
            );
            let operation = "reusable-function-operation";
            invoke_with_operation(
                &harness,
                FUNCTION_PLUGIN,
                "snapshot.refresh",
                Some(60_000),
                operation.to_string(),
            )
            .expect("first call");
            let first = harness
                .server
                .await_request("lithe/function/invoke")
                .expect("first wire request");
            let old_wire = harness.written_request(&first)["params"]["operationID"].clone();
            finish_function_for_reuse(&mut harness, operation, &first, ending);
            invoke_with_operation(
                &harness,
                FUNCTION_PLUGIN,
                "snapshot.clear",
                None,
                operation.to_string(),
            )
            .expect("reused host ID");
            let second = harness
                .server
                .await_request_at("lithe/function/invoke", 1)
                .expect("second wire request");
            let current_wire = harness.written_request(&second)["params"]["operationID"].clone();
            assert_ne!(
                old_wire, current_wire,
                "wire identity must change after {ending}"
            );
            harness.server.send(json!({
                "jsonrpc": "2.0", "id": "withdraw-old-function", "method": "lithe/function/unregister",
                "params": { "ids": ["snapshot.refresh"] }
            }));
            assert_eq!(
                await_reply(&harness, "withdraw-old-function")["result"],
                Value::Null
            );
            assert_eq!(
                harness.snapshot().pending_operation_ids,
                vec![operation.to_string()]
            );
            assert!(harness
                .server
                .messages()
                .iter()
                .all(|message| message["method"] != "$/cancelRequest"
                    || message["params"]["id"] != second));
            harness
                .server
                .send(json!({ "jsonrpc": "2.0", "id": first, "result": "late" }));
            harness.server.send(json!({ "jsonrpc": "2.0", "method": "lithe/function/progress", "params": { "operationID": old_wire, "message": "stale" } }));
            harness.server.send(json!({ "jsonrpc": "2.0", "method": "lithe/function/progress", "params": { "operationID": current_wire, "message": "current", "percentage": 50 } }));
            let progress = harness
                .await_event(|event| event.kind == "requestProgress")
                .clone();
            assert_eq!(progress.operation_id.as_deref(), Some(operation));
            assert_eq!(
                progress.result,
                Some(json!({ "operationID": operation, "message": "current", "percentage": 50 })),
                "{ending}"
            );
            harness
                .server
                .send(json!({ "jsonrpc": "2.0", "id": second, "result": "second" }));
            harness.await_event(|event| {
                event.kind == "requestCompleted"
                    && event.result == Some(json!({ "value": "second" }))
            });
            assert_eq!(completions(&mut harness, operation).len(), 2, "{ending}");
            assert_eq!(
                harness
                    .events
                    .iter()
                    .filter(|event| event.kind == "requestProgress")
                    .count(),
                1,
                "{ending}"
            );
            assert!(harness.snapshot().pending_operation_ids.is_empty());
        }
    }

    /// Revocation after a function has ended must never cancel an unrelated
    /// build that reused the same host operation ID.
    #[test]
    fn reused_plugin_function_operation_ids_preserve_build_requests() {
        for ending in ["cancel", "timeout", "complete", "error", "revoke"] {
            let mut harness = function_backend();
            let operation = "reusable-build-operation";
            invoke_with_operation(
                &harness,
                FUNCTION_PLUGIN,
                "snapshot.refresh",
                Some(60_000),
                operation.to_string(),
            )
            .expect("first call");
            let first = harness
                .server
                .await_request("lithe/function/invoke")
                .expect("function request");
            let old_wire = harness.written_request(&first)["params"]["operationID"].clone();
            finish_function_for_reuse(&mut harness, operation, &first, ending);
            harness
                .session()
                .build_request(
                    BuildProviderRequest {
                        session_id: harness.session_id.clone(),
                        operation_id: Some(operation.to_string()),
                        method: "lithe/build/model".to_string(),
                        params: json!({}),
                        timeout_milliseconds: None,
                    },
                    operation.to_string(),
                )
                .expect("build may reuse host operation ID");
            let build = harness
                .server
                .await_request("lithe/build/model")
                .expect("build request");
            harness
                .server
                .send(json!({ "jsonrpc": "2.0", "id": first, "result": "late" }));
            harness.server.send(json!({ "jsonrpc": "2.0", "method": "lithe/function/progress", "params": { "operationID": old_wire, "message": "stale" } }));
            harness.server.send(json!({
                "jsonrpc": "2.0", "id": "withdraw-during-build", "method": "lithe/function/unregister",
                "params": { "ids": ["snapshot.refresh"] }
            }));
            assert_eq!(
                await_reply(&harness, "withdraw-during-build")["result"],
                Value::Null
            );
            harness.poll();
            assert!(harness
                .events
                .iter()
                .any(|event| event.kind == "functionsChanged"
                    && event.result
                        == Some(json!({ "functions": [], "removed": ["snapshot.refresh"] }))));
            assert_eq!(
                harness.snapshot().pending_operation_ids,
                vec![operation.to_string()],
                "{ending}"
            );
            assert!(harness
                .server
                .messages()
                .iter()
                .all(|message| message["method"] != "$/cancelRequest"
                    || message["params"]["id"] != build));
            harness
                .server
                .send(json!({ "jsonrpc": "2.0", "id": build, "result": { "version": 1 } }));
            harness.await_event(|event| {
                event.kind == "requestCompleted"
                    && event.method.as_deref() == Some("lithe/build/model")
            });
            let ended = completions(&mut harness, operation);
            assert_eq!(ended.len(), 2, "{ending}");
            assert!(ended[1].error.is_none(), "{ending}: {:?}", ended[1]);
            assert!(
                harness
                    .events
                    .iter()
                    .all(|event| event.kind != "requestProgress"),
                "{ending}"
            );
        }
    }

    #[test]
    fn stopping_a_plugin_function_withdraws_registry_and_ignores_late_messages() {
        let mut harness = function_backend();
        let operation = invoke(&harness, FUNCTION_PLUGIN, "snapshot.refresh", None).expect("call");
        let request = harness
            .server
            .await_request("lithe/function/invoke")
            .expect("wire request");
        let wire = harness.written_request(&request)["params"]["operationID"].clone();
        harness.session().stop().expect("shutdown starts");
        let shutdown = harness
            .server
            .await_request("shutdown")
            .expect("shutdown request");
        harness.poll();
        let registry_changes = harness
            .events
            .iter()
            .filter(|event| event.kind == "functionsChanged")
            .count();
        assert_eq!(
            registry_changes, 2,
            "initialize publishes, then stop withdraws"
        );
        harness.server.send(json!({ "jsonrpc": "2.0", "method": "lithe/function/progress", "params": { "operationID": wire, "message": "late" } }));
        harness
            .server
            .send(json!({ "jsonrpc": "2.0", "id": request, "result": "late" }));
        for (id, method, params) in [
            (
                "late-register",
                "lithe/function/register",
                json!({ "functions": [{ "id": "snapshot.late" }] }),
            ),
            (
                "late-unregister",
                "lithe/function/unregister",
                json!({ "ids": ["snapshot.refresh"] }),
            ),
        ] {
            harness
                .server
                .send(json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params }));
            // The reply fences every earlier notification before asserting absence.
            assert_eq!(await_reply(&harness, id)["error"]["code"], -32601);
        }
        harness.poll();
        assert!(harness
            .session()
            .lock_state()
            .expect("session state")
            .client
            .plugin_functions
            .is_empty());
        assert_eq!(
            harness
                .events
                .iter()
                .filter(|event| event.kind == "functionsChanged")
                .count(),
            registry_changes
        );
        harness
            .server
            .send(json!({ "jsonrpc": "2.0", "id": shutdown, "result": null }));
        assert!(harness.server.await_notification("exit"));
        harness.server.exit(Some(0));
        harness.await_state(LspLifecycleState::Stopped);
        assert_eq!(completions(&mut harness, &operation).len(), 1);
        assert!(harness
            .events
            .iter()
            .all(|event| event.kind != "requestProgress"));
        assert!(harness
            .events
            .iter()
            .any(|event| event.kind == "functionsChanged"
                && event.result
                    == Some(json!({ "functions": [], "removed": ["snapshot.refresh"] }))));
    }

    #[test]
    fn a_plugin_function_process_failure_withdraws_registry_and_completes_calls() {
        let mut harness = function_backend();
        let operation = invoke(&harness, FUNCTION_PLUGIN, "snapshot.refresh", None).expect("call");
        harness
            .server
            .await_request("lithe/function/invoke")
            .expect("wire request");
        harness.server.exit(Some(42));
        harness.await_state(LspLifecycleState::Failed);
        let ended = completions(&mut harness, &operation);
        assert_eq!(ended.len(), 1);
        assert!(ended[0].error.is_some());
        assert!(harness.snapshot().pending_operation_ids.is_empty());
        assert!(harness
            .events
            .iter()
            .any(|event| event.kind == "functionsChanged"
                && event.result
                    == Some(json!({ "functions": [], "removed": ["snapshot.refresh"] }))));
    }

    /// Domain dispatch could route back into the backend that asked, whose
    /// handler would wait on itself; version 1 also offers no host capability.
    #[test]
    fn a_backend_cannot_ask_the_host_to_dispatch_back_into_itself() {
        let harness = function_backend();
        for (id, method, code) in [
            (
                "invoke",
                "lithe/function/invoke",
                "plugin.function.recursiveCall",
            ),
            (
                "model",
                "lithe/build/model",
                "plugin.function.recursiveCall",
            ),
            (
                "process",
                "lithe/host/process.run",
                "plugin.host.unavailable",
            ),
        ] {
            harness.server.send(json!({
                "jsonrpc": "2.0",
                "id": id,
                "method": method,
                "params": {}
            }));
            let reply = await_reply(&harness, id);
            assert_eq!(reply["error"]["data"]["code"], code, "{method}");
        }
    }

    fn host_service_backend(version: u64, host_services: &[&str]) -> Harness {
        let host_services: Vec<String> = host_services.iter().map(ToString::to_string).collect();
        let mut harness = Harness::start(move |request| {
            request.plugin_id = Some(FUNCTION_PLUGIN.to_string());
            request.host_services = host_services.clone();
        });
        harness.server.complete_initialize(json!({
            "experimental": { "litheFunctions": { "version": version } }
        }));
        harness.await_state(LspLifecycleState::Ready);
        harness
    }

    fn host_response(
        harness: &Harness,
        host_request_id: &str,
        result: Option<Value>,
        error: Option<&str>,
    ) -> Result<(), CoreError> {
        // Decoded from the wire shape `lsp.hostResponse` documents, so the
        // field spelling is checked with the round trip.
        let mut wire = json!({
            "sessionId": harness.session_id,
            "hostRequestID": host_request_id,
        });
        if let Some(result) = result {
            wire["result"] = result;
        }
        if let Some(message) = error {
            wire["error"] = match message.split_once('|') {
                Some((code, message)) => json!({ "message": message, "code": code }),
                None => json!({ "message": message }),
            };
        }
        let response: PluginHostResponse =
            serde_json::from_value(wire).expect("documented wire shape");
        harness.session().host_response(response)
    }

    /// A granted credential request reaches the host as `hostRequest`. The
    /// backend receives exactly the host's answer under its own ID, and a
    /// second answer to the same request is refused instead of reaching a
    /// later request.
    #[test]
    fn a_granted_host_service_request_round_trips_through_the_host() {
        let mut harness = host_service_backend(2, &["credentials"]);
        harness.server.send(json!({
            "jsonrpc": "2.0", "id": "read",
            "method": "lithe/host/credentials/get",
            "params": { "key": "connection.prod" }
        }));
        let event = harness
            .await_event(|event| event.kind == "hostRequest")
            .clone();
        assert_eq!(event.method.as_deref(), Some("lithe/host/credentials/get"));
        let request = event.result.expect("the request is described");
        assert_eq!(request["service"], "credentials");
        assert_eq!(request["params"], json!({ "key": "connection.prod" }));
        let read_id = request["hostRequestID"].as_str().unwrap().to_string();
        host_response(
            &harness,
            &read_id,
            Some(json!({ "secret": "s3cret" })),
            None,
        )
        .expect("the host answers once");
        assert_eq!(
            await_reply(&harness, "read")["result"],
            json!({ "secret": "s3cret" })
        );
        assert!(host_response(&harness, &read_id, None, None).is_err());

        harness.server.send(json!({
            "jsonrpc": "2.0", "id": "write",
            "method": "lithe/host/credentials/set",
            "params": { "key": "connection.prod", "secret": "s3cret" }
        }));
        let event = harness
            .await_event(|event| {
                event.kind == "hostRequest"
                    && event.method.as_deref() == Some("lithe/host/credentials/set")
            })
            .clone();
        let write_id = event.result.unwrap()["hostRequestID"]
            .as_str()
            .unwrap()
            .to_string();
        assert_ne!(write_id, read_id);
        host_response(&harness, &write_id, None, Some("The keychain is locked."))
            .expect("the host reports its failure");
        let reply = await_reply(&harness, "write");
        assert_eq!(reply["error"]["data"]["code"], "plugin.host.failed");
        assert_eq!(reply["error"]["message"], "The keychain is locked.");
    }

    /// Host services start with protocol version 2 and only for the services
    /// the plugin's permissions grant; refusals never reach the host.
    #[test]
    fn host_services_need_version_2_and_a_grant() {
        for (version, services, code) in [
            (1, &["credentials"][..], "plugin.host.unavailable"),
            (2, &[][..], "plugin.host.permissionDenied"),
        ] {
            let mut harness = host_service_backend(version, services);
            harness.server.send(json!({
                "jsonrpc": "2.0", "id": "read",
                "method": "lithe/host/credentials/get",
                "params": { "key": "connection.prod" }
            }));
            let reply = await_reply(&harness, "read");
            assert_eq!(reply["error"]["data"]["code"], code, "version {version}");
            harness.poll();
            assert!(harness
                .events
                .iter()
                .all(|event| event.kind != "hostRequest"));
        }
    }

    /// A host that stops answering cannot make a backend grow the session's
    /// state: requests beyond the bound fail at once.
    #[test]
    fn unanswered_host_requests_are_bounded() {
        let harness = host_service_backend(2, &["credentials"]);
        let limit = super::super::plugin_function::MAX_PENDING_HOST_REQUESTS;
        for index in 0..=limit {
            harness.server.send(json!({
                "jsonrpc": "2.0", "id": format!("read-{index}"),
                "method": "lithe/host/credentials/get",
                "params": { "key": "connection.prod" }
            }));
        }
        let reply = await_reply(&harness, &format!("read-{limit}"));
        assert_eq!(reply["error"]["data"]["code"], "plugin.host.failed");
        assert_eq!(
            harness.session().lock_state().unwrap().host_requests.len(),
            limit
        );
    }

    /// From version 3 Core answers capability discovery itself, listing
    /// only the session's grants; the host never sees the request.
    #[test]
    fn capability_discovery_is_answered_by_core() {
        let mut harness = host_service_backend(3, &["workspace"]);
        harness.server.send(json!({
            "jsonrpc": "2.0", "id": "caps",
            "method": "lithe/host/getCapabilities"
        }));
        let reply = await_reply(&harness, "caps");
        assert_eq!(reply["result"]["protocolVersion"], 3);
        assert_eq!(reply["result"]["backendAuthority"], "local");
        assert!(reply["result"]["services"]["workspace"].is_object());
        assert!(reply["result"]["services"]["credentials"].is_null());
        harness.poll();
        assert!(harness
            .events
            .iter()
            .all(|event| event.kind != "hostRequest"));
    }

    /// Editor options the host declared at start are reported with the
    /// methods they belong to, and only when those methods are granted.
    #[test]
    fn capability_discovery_reports_granted_editor_options() {
        use crate::plugins::editor_actions::{EditorHostOptions, REGISTER_PROVIDERS};
        let mut harness = Harness::start(|request| {
            request.plugin_id = Some(FUNCTION_PLUGIN.to_string());
            request.host_services = vec![REGISTER_PROVIDERS.to_string()];
            request.host_options.editor = Some(EditorHostOptions {
                action_icons: vec!["run".into(), "test-failed".into()],
                action_source_bytes: 1024 * 1024,
                provider_types: vec!["hover".into(), "codeLens".into()],
            });
        });
        harness.server.complete_initialize(json!({
            "experimental": { "litheFunctions": { "version": 3 } }
        }));
        harness.await_state(LspLifecycleState::Ready);
        harness.server.send(json!({
            "jsonrpc": "2.0", "id": "caps",
            "method": "lithe/host/getCapabilities"
        }));
        let reply = await_reply(&harness, "caps");
        let editor = &reply["result"]["services"]["editor"];
        assert_eq!(editor["methods"], json!([REGISTER_PROVIDERS]));
        assert_eq!(
            editor["options"],
            json!({ "providerTypes": ["hover", "codeLens"] })
        );
        assert!(reply["result"]["limits"]["editorActionSourceBytes"].is_null());
        harness.poll();
        assert!(harness
            .events
            .iter()
            .all(|event| event.kind != "hostRequest"));
    }

    /// Host options belong to a plugin backend and must be ones Core can
    /// enforce.
    #[test]
    fn start_contract_rejects_unenforceable_host_options() {
        use crate::plugins::editor_actions::EditorHostOptions;
        let server = ScriptedServer::new();
        let mut request = start_request(&server);
        let options = EditorHostOptions {
            action_icons: vec!["run".into()],
            action_source_bytes: 1024 * 1024,
            provider_types: Vec::new(),
        };
        request.host_options.editor = Some(options.clone());
        request.plugin_id = None;
        assert!(validate_start_request(&request).is_err());
        request.plugin_id = Some(FUNCTION_PLUGIN.to_string());
        assert!(validate_start_request(&request).is_ok());
        for invalid in [
            EditorHostOptions {
                action_source_bytes: 2 * 1024 * 1024,
                ..options.clone()
            },
            EditorHostOptions {
                action_icons: vec!["Run Fast".into()],
                ..options.clone()
            },
            EditorHostOptions {
                provider_types: vec!["diagnostics".into()],
                ..options.clone()
            },
        ] {
            request.host_options.editor = Some(invalid);
            assert!(validate_start_request(&request).is_err());
        }
    }

    /// From version 3 a field a method does not define is answered as an
    /// unsupported option naming it, so a backend can retry without it; the
    /// host never sees the request.
    #[test]
    fn an_unknown_option_is_named_to_a_version_3_backend() {
        let mut harness = host_service_backend(3, &["workspace"]);
        harness.server.send(json!({
            "jsonrpc": "2.0", "id": "folders",
            "method": "lithe/host/workspace/getFolders",
            "params": {
                "context": { "contextID": "w-1", "generation": 1 },
                "includeHidden": true
            }
        }));
        let reply = await_reply(&harness, "folders");
        assert_eq!(reply["error"]["code"], -32018);
        assert_eq!(
            reply["error"]["data"]["code"],
            "plugin.host.unsupportedOption"
        );
        assert_eq!(
            reply["error"]["data"]["details"],
            json!({ "option": "includeHidden" })
        );
        harness.poll();
        assert!(harness
            .events
            .iter()
            .all(|event| event.kind != "hostRequest"));
    }

    /// From version 3 a host failure's code reaches the backend when it is
    /// one a host may report; an unknown code is `plugin.host.failed`.
    #[test]
    fn typed_host_failures_reach_a_version_3_backend() {
        let mut harness = host_service_backend(3, &["workspace"]);
        for (id, code, expected, rpc_code) in [
            (
                "a",
                "plugin.host.contextExpired",
                "plugin.host.contextExpired",
                -32011,
            ),
            ("b", "plugin.function.unknown", "plugin.host.failed", -32603),
        ] {
            harness.server.send(json!({
                "jsonrpc": "2.0", "id": id,
                "method": "lithe/host/workspace/getFolders",
                "params": { "context": { "contextID": "w1", "generation": 1 } }
            }));
            let event = harness
                .await_event(|event| event.kind == "hostRequest")
                .clone();
            let host_request_id = event.result.unwrap()["hostRequestID"]
                .as_str()
                .unwrap()
                .to_string();
            harness.events.clear();
            host_response(
                &harness,
                &host_request_id,
                None,
                Some(&format!("{code}|The workspace closed.")),
            )
            .expect("the host reports its failure");
            let reply = await_reply(&harness, id);
            assert_eq!(reply["error"]["data"]["code"], expected, "{code}");
            assert_eq!(reply["error"]["code"], rpc_code, "{code}");
        }
    }

    /// A host failure's details reach a version 3 backend under
    /// `error.data.details`, next to the stable code.
    #[test]
    fn host_failure_details_reach_a_version_3_backend() {
        let mut harness = host_service_backend(3, &["workspace"]);
        harness.server.send(json!({
            "jsonrpc": "2.0", "id": "folders",
            "method": "lithe/host/workspace/getFolders",
            "params": { "context": { "contextID": "w1", "generation": 1 } }
        }));
        let host_request_id = harness
            .await_event(|event| event.kind == "hostRequest")
            .clone()
            .result
            .unwrap()["hostRequestID"]
            .as_str()
            .unwrap()
            .to_string();
        let response: PluginHostResponse = serde_json::from_value(json!({
            "sessionId": harness.session_id,
            "hostRequestID": host_request_id,
            "error": {
                "message": "The context changed.",
                "code": "plugin.host.contextExpired",
                "details": { "generation": 2 }
            }
        }))
        .expect("documented wire shape");
        harness
            .session()
            .host_response(response)
            .expect("the host reports its failure");
        let reply = await_reply(&harness, "folders");
        assert_eq!(reply["error"]["data"]["code"], "plugin.host.contextExpired");
        assert_eq!(
            reply["error"]["data"]["details"],
            json!({ "generation": 2 })
        );
    }

    /// `lsp.hostNotify` writes an admitted notification to the backend and
    /// refuses one the session was not granted.
    #[test]
    fn host_notifications_reach_a_version_3_backend() {
        let harness = host_service_backend(3, &["workspace"]);
        let notify = |method: &str, params: Value| {
            let request: PluginHostNotification = serde_json::from_value(json!({
                "sessionId": harness.session_id,
                "method": method,
                "params": params,
            }))
            .expect("documented wire shape");
            harness.session().host_notify(request)
        };
        assert!(notify(
            "lithe/host/workspace/didChangeContexts",
            json!({ "revision": 2 })
        )
        .expect("an admitted notification"));
        assert!(harness
            .server
            .await_notification("lithe/host/workspace/didChangeContexts"));
        assert!(notify("lithe/build/run", json!({})).is_err());
    }

    /// A version 2 backend never receives a notification it cannot read.
    #[test]
    fn host_notifications_skip_a_version_2_backend() {
        let harness = host_service_backend(2, &["workspace"]);
        let request: PluginHostNotification = serde_json::from_value(json!({
            "sessionId": harness.session_id,
            "method": "lithe/host/workspace/didChangeContexts",
            "params": { "revision": 2 },
        }))
        .expect("documented wire shape");
        assert!(!harness
            .session()
            .host_notify(request)
            .expect("a known notification"));
    }

    /// A backend that cancels its own host request is answered at once, the
    /// host learns which request to stop, and its late answer is refused.
    #[test]
    fn a_backend_can_cancel_its_host_request() {
        let mut harness = host_service_backend(3, &["workspace"]);
        harness.server.send(json!({
            "jsonrpc": "2.0", "id": "list",
            "method": "lithe/host/workspace/listContexts"
        }));
        let host_request_id = harness
            .await_event(|event| event.kind == "hostRequest")
            .clone()
            .result
            .unwrap()["hostRequestID"]
            .as_str()
            .unwrap()
            .to_string();
        harness.server.send(json!({
            "jsonrpc": "2.0", "method": "$/cancelRequest", "params": { "id": "list" }
        }));
        let cancelled = harness
            .await_event(|event| event.kind == "hostRequestCancelled")
            .clone();
        assert_eq!(
            cancelled.result.unwrap()["hostRequestID"],
            json!(host_request_id)
        );
        let reply = await_reply(&harness, "list");
        assert_eq!(reply["error"]["data"]["code"], "plugin.host.cancelled");
        assert!(host_response(&harness, &host_request_id, Some(json!({})), None).is_err());
    }

    /// A call's workspace context reaches a version 3 backend as
    /// `params.context`, and a malformed reference never leaves Core.
    #[test]
    fn invocations_carry_the_workspace_context_from_version_3() {
        let harness = plugin_backend(json!({
            "litheFunctions": { "version": 3, "functions": [{ "id": "snapshot.refresh" }] }
        }));
        let call = |context: Value| {
            let operation_id = harness.engine.next_operation_id();
            harness.session().function_request(
                PluginFunctionRequest {
                    session_id: harness.session_id.clone(),
                    operation_id: Some(operation_id.clone()),
                    function: super::super::plugin_function::FunctionReference {
                        plugin_id: FUNCTION_PLUGIN.to_string(),
                        function_id: "snapshot.refresh".to_string(),
                    },
                    params: json!({}),
                    timeout_milliseconds: None,
                    context: Some(context),
                },
                operation_id,
                None,
            )
        };
        let error = call(json!({ "contextID": "w/1", "generation": 1 }))
            .expect_err("a malformed context is refused");
        assert_eq!(
            error.details.as_deref(),
            Some("plugin.function.invalidParams")
        );
        call(json!({ "contextID": "w1", "generation": 2 })).expect("sent");
        let request_id = harness
            .server
            .await_request("lithe/function/invoke")
            .expect("the call should reach the backend");
        assert_eq!(
            harness.written_request(&request_id)["params"]["context"],
            json!({ "contextID": "w1", "generation": 2 })
        );
    }

    /// Requests and notifications of a plugin backend to its own language
    /// server (plan API-25). The stub servers are Metals-like (a gate and a
    /// command that runs one at a time) and rust-analyzer-like (neither), so
    /// no case depends on one language.
    mod plugin_owned_server {
        use super::*;

        const PLUGIN: &str = "dev.lithe.metals";
        const SERVER: &str = "metals";
        const STATUS: &str = "metals/status";

        /// The policy of the Metals-like server. `gated` adds the gate that
        /// holds requests until the server reports it is ready.
        fn metals_policy(gated: bool) -> Value {
            let mut policy = json!({
                "serverID": SERVER,
                "requestMethods": [
                    "textDocument/definition",
                    "workspace/executeCommand",
                    "metals/slow",
                    "metals/didFocus"
                ],
                "commands": ["build-import", "build-connect"],
                "serializedCommands": ["build-import"],
                "forwardNotifications": [STATUS],
            });
            if gated {
                policy["gates"] = json!([{
                    "id": "imported",
                    "until": "notification",
                    "method": STATUS,
                    "match": { "text": "ready" }
                }]);
            }
            policy
        }

        /// A rust-analyzer-like server: no gate, no serialized command.
        fn rust_analyzer_policy() -> Value {
            json!({
                "serverID": SERVER,
                "requestMethods": ["experimental/runnables"],
            })
        }

        fn start(policy: Value) -> Harness {
            let mut harness = Harness::start(move |request| {
                request.plugin_id = Some(PLUGIN.to_string());
                request.session_policy =
                    Some(serde_json::from_value(policy).expect("the policy should decode"));
            });
            harness.server.complete_initialize(ready_capabilities());
            harness.await_state(LspLifecycleState::Ready);
            harness
        }

        /// The `lsp.pluginServerRequest` payload the host sends.
        fn wire(harness: &Harness, operation_id: &str, method: &str, params: Value) -> Value {
            json!({
                "sessionId": harness.session_id,
                "operationId": operation_id,
                "pluginId": PLUGIN,
                "serverID": SERVER,
                "method": method,
                "params": params,
            })
        }

        fn send(harness: &Harness, wire: Value) -> Result<(), CoreError> {
            let operation_id = wire["operationId"].as_str().unwrap().to_string();
            let request: PluginServerRequest =
                serde_json::from_value(wire).expect("documented wire shape");
            harness
                .session()
                .plugin_server_request(request, operation_id)
        }

        fn call(
            harness: &Harness,
            operation_id: &str,
            method: &str,
            params: Value,
        ) -> Result<(), CoreError> {
            send(harness, wire(harness, operation_id, method, params))
        }

        fn run_command(
            harness: &Harness,
            operation_id: &str,
            command: &str,
        ) -> Result<(), CoreError> {
            call(
                harness,
                operation_id,
                "workspace/executeCommand",
                json!({ "command": command, "arguments": [] }),
            )
        }

        fn notify(harness: &Harness, method: &str, params: Value) -> Result<bool, CoreError> {
            let request: PluginServerNotify = serde_json::from_value(json!({
                "sessionId": harness.session_id,
                "pluginId": PLUGIN,
                "serverID": SERVER,
                "method": method,
                "params": params,
            }))
            .expect("documented wire shape");
            harness.session().plugin_server_notify(request)
        }

        /// The server reports `text` through its status notification.
        fn report_status(harness: &Harness, text: &str) {
            harness.server.send(json!({
                "jsonrpc": "2.0",
                "method": STATUS,
                "params": { "text": text }
            }));
        }

        /// Waits until Core has applied the status notification of `text`. The
        /// notification is forwarded to the backend, so the forwarded event
        /// proves the engine already processed it.
        fn await_status_seen(harness: &mut Harness, text: &str) {
            harness.await_event(|event| {
                event.kind == "pluginServerNotification"
                    && event
                        .result
                        .as_ref()
                        .is_some_and(|result| result["params"]["text"] == text)
            });
        }

        fn reply(harness: &Harness, request_id: &str, result: Value) {
            harness.server.send(json!({
                "jsonrpc": "2.0", "id": request_id, "result": result
            }));
        }

        fn completed(harness: &mut Harness, operation_id: &str) -> LspRuntimeEvent {
            harness
                .await_event(|event| {
                    event.kind == "requestCompleted"
                        && event.operation_id.as_deref() == Some(operation_id)
                })
                .clone()
        }

        fn error_code(event: &LspRuntimeEvent) -> &str {
            &event.error.as_ref().expect("the request failed").code
        }

        fn written(harness: &Harness, method: &str) -> usize {
            harness
                .server
                .messages()
                .iter()
                .filter(|message| message["method"] == method)
                .count()
        }

        fn refusal_code(error: CoreError) -> String {
            error.details.expect("a refusal names its plugin.host code")
        }

        /// The server's result reaches the backend untouched, even for a
        /// method whose result Lithe normalizes for its own editor.
        #[test]
        fn a_declared_request_returns_the_servers_own_result() {
            let mut harness = start(metals_policy(false));
            call(
                &harness,
                "def-1",
                "textDocument/definition",
                json!({ "textDocument": { "uri": "file:///workspace/A.scala" } }),
            )
            .expect("a declared method is sent");
            let request_id = harness
                .server
                .await_request("textDocument/definition")
                .expect("the request should reach the server");
            let location = json!({
                "uri": "jar:file:///cache/lib.jar!/Lib.scala",
                "range": {
                    "start": { "line": 1, "character": 2 },
                    "end": { "line": 1, "character": 5 }
                }
            });
            reply(&harness, &request_id, json!([location]));

            let event = completed(&mut harness, "def-1");
            assert_eq!(event.result, Some(json!({ "value": [location] })));
            assert!(event.error.is_none());
        }

        #[test]
        fn a_server_without_gates_or_commands_sends_at_once() {
            let mut harness = start(rust_analyzer_policy());
            call(&harness, "run-1", "experimental/runnables", json!({}))
                .expect("a declared method is sent");
            let request_id = harness
                .server
                .await_request("experimental/runnables")
                .expect("nothing holds the request");
            reply(&harness, &request_id, json!([]));
            assert_eq!(
                completed(&mut harness, "run-1").result,
                Some(json!({ "value": [] }))
            );
        }

        #[test]
        fn a_server_error_keeps_its_code_and_message_as_details() {
            let mut harness = start(metals_policy(false));
            call(&harness, "slow-1", "metals/slow", json!({})).unwrap();
            let request_id = harness.server.await_request("metals/slow").unwrap();
            harness.server.send(json!({
                "jsonrpc": "2.0",
                "id": request_id,
                "error": { "code": -32001, "message": "Build server is not connected." }
            }));

            let event = completed(&mut harness, "slow-1");
            assert_eq!(error_code(&event), "plugin.host.languageServerError");
            assert_eq!(
                event.error.unwrap().details,
                Some(json!({ "code": -32001, "message": "Build server is not connected." }))
            );
        }

        #[test]
        fn a_method_the_plugin_did_not_declare_never_reaches_the_server() {
            let harness = start(metals_policy(false));
            let error = call(&harness, "bad-1", "textDocument/rename", json!({}))
                .expect_err("an undeclared method is refused");
            assert_eq!(refusal_code(error), "plugin.host.methodNotDeclared");

            let error = run_command(&harness, "bad-2", "wipe-workspace")
                .expect_err("an undeclared command is refused");
            assert_eq!(refusal_code(error), "plugin.host.methodNotDeclared");
            assert_eq!(written(&harness, "textDocument/rename"), 0);
            assert_eq!(written(&harness, "workspace/executeCommand"), 0);
        }

        /// The host resolves the session, so a call that names another plugin
        /// or server, or a session without a policy, is the host's mistake and
        /// must not reach any server.
        #[test]
        fn a_session_of_another_contribution_is_refused() {
            let harness = start(metals_policy(false));
            for (plugin_id, server_id) in [("dev.lithe.other", SERVER), (PLUGIN, "other-server")] {
                let mut foreign = wire(&harness, "foreign-1", "metals/slow", json!({}));
                foreign["pluginId"] = json!(plugin_id);
                foreign["serverID"] = json!(server_id);
                let error = send(&harness, foreign).expect_err("a foreign contribution is refused");
                assert_eq!(refusal_code(error), "plugin.host.foreignContribution");
            }
            assert_eq!(written(&harness, "metals/slow"), 0);

            let plain = Harness::ready();
            let error = call(&plain, "plain-1", "metals/slow", json!({}))
                .expect_err("a session without a policy is no plugin server");
            assert_eq!(refusal_code(error), "plugin.host.foreignContribution");
        }

        #[test]
        fn requests_wait_for_the_gate_and_are_sent_in_order() {
            let mut harness = start(metals_policy(true));
            call(&harness, "first", "metals/slow", json!({ "n": 1 })).unwrap();
            call(
                &harness,
                "second",
                "textDocument/definition",
                json!({ "n": 2 }),
            )
            .unwrap();
            assert_eq!(written(&harness, "metals/slow"), 0);

            // A status that does not match the gate leaves it closed.
            report_status(&harness, "importing");
            await_status_seen(&mut harness, "importing");
            assert_eq!(written(&harness, "metals/slow"), 0);
            assert_eq!(written(&harness, "textDocument/definition"), 0);

            report_status(&harness, "ready");
            let first = harness.server.await_request("metals/slow").unwrap();
            let second = harness
                .server
                .await_request("textDocument/definition")
                .unwrap();
            let messages = harness.server.messages();
            let position = |id: &str| messages.iter().position(|message| message["id"] == id);
            assert!(
                position(&first) < position(&second),
                "arrival order is kept"
            );

            reply(&harness, &first, json!("one"));
            assert_eq!(
                completed(&mut harness, "first").result,
                Some(json!({ "value": "one" }))
            );
        }

        #[test]
        fn a_held_request_can_be_cancelled_without_touching_the_server() {
            let mut harness = start(metals_policy(true));
            call(&harness, "held-1", "metals/slow", json!({})).unwrap();
            harness
                .session()
                .cancel_operation("held-1")
                .expect("a held request can be cancelled");

            let event = completed(&mut harness, "held-1");
            assert_eq!(error_code(&event), "plugin.host.cancelled");

            // Opening the gate afterwards sends nothing: the request is gone.
            report_status(&harness, "ready");
            await_status_seen(&mut harness, "ready");
            assert_eq!(written(&harness, "metals/slow"), 0);
            assert_eq!(written(&harness, "$/cancelRequest"), 0);
        }

        #[test]
        fn a_held_request_times_out_while_it_waits() {
            let mut harness = start(metals_policy(true));
            let mut held = wire(&harness, "held-1", "metals/slow", json!({}));
            held["timeoutMilliseconds"] = json!(1);
            send(&harness, held).unwrap();

            let event = completed(&mut harness, "held-1");
            assert_eq!(error_code(&event), "plugin.host.timeout");
            assert_eq!(written(&harness, "metals/slow"), 0);
        }

        #[test]
        fn a_sent_request_times_out_and_is_cancelled_on_the_server() {
            let mut harness = start(metals_policy(false));
            let mut slow = wire(&harness, "slow-1", "metals/slow", json!({}));
            slow["timeoutMilliseconds"] = json!(1);
            send(&harness, slow).unwrap();
            let request_id = harness.server.await_request("metals/slow").unwrap();

            let event = completed(&mut harness, "slow-1");
            assert_eq!(error_code(&event), "plugin.host.timeout");
            let cancel = harness
                .server
                .await_notification_at("$/cancelRequest", 0)
                .expect("the server is told to stop");
            assert_eq!(cancel["params"]["id"], json!(request_id));
        }

        /// A second request for a serialized command does not start a second
        /// run; both finish with the answer of the one that runs.
        #[test]
        fn a_serialized_command_joins_the_one_that_runs() {
            let mut harness = start(metals_policy(false));
            run_command(&harness, "import-1", "build-import").unwrap();
            let request_id = harness
                .server
                .await_request("workspace/executeCommand")
                .unwrap();
            run_command(&harness, "import-2", "build-import").unwrap();
            // A command that is not serialized is independent of the first.
            run_command(&harness, "connect-1", "build-connect").unwrap();
            harness
                .server
                .await_request_at("workspace/executeCommand", 1)
                .expect("an independent command is sent");
            assert_eq!(written(&harness, "workspace/executeCommand"), 2);

            reply(&harness, &request_id, json!({ "imported": 3 }));
            for operation_id in ["import-1", "import-2"] {
                let event = completed(&mut harness, operation_id);
                assert_eq!(event.result, Some(json!({ "value": { "imported": 3 } })));
            }
            assert!(!harness
                .events
                .iter()
                .any(|event| event.operation_id.as_deref() == Some("connect-1")));

            // The command can run again once the first run is over.
            run_command(&harness, "import-3", "build-import").unwrap();
            harness
                .server
                .await_request_at("workspace/executeCommand", 2)
                .expect("a finished command can run again");
        }

        #[test]
        fn cancelling_a_joiner_leaves_the_running_command_alone() {
            let mut harness = start(metals_policy(false));
            run_command(&harness, "import-1", "build-import").unwrap();
            let request_id = harness
                .server
                .await_request("workspace/executeCommand")
                .unwrap();
            run_command(&harness, "import-2", "build-import").unwrap();
            harness.session().cancel_operation("import-2").unwrap();
            assert_eq!(
                error_code(&completed(&mut harness, "import-2")),
                "plugin.host.cancelled"
            );
            assert_eq!(written(&harness, "$/cancelRequest"), 0);

            reply(&harness, &request_id, json!(null));
            assert_eq!(
                completed(&mut harness, "import-1").result,
                Some(json!({ "value": null }))
            );
        }

        #[test]
        fn only_declared_server_notifications_are_forwarded() {
            let mut harness = start(metals_policy(false));
            harness.server.send(json!({
                "jsonrpc": "2.0",
                "method": "metals/unlisted",
                "params": { "text": "private" }
            }));
            report_status(&harness, "indexing");
            await_status_seen(&mut harness, "indexing");

            let forwarded: Vec<_> = harness
                .events
                .iter()
                .filter(|event| event.kind == "pluginServerNotification")
                .collect();
            assert_eq!(forwarded.len(), 1);
            assert_eq!(
                forwarded[0].result,
                Some(json!({
                    "serverID": SERVER,
                    "method": STATUS,
                    "params": { "text": "indexing" }
                }))
            );
        }

        #[test]
        fn a_declared_notification_is_sent_and_a_command_is_not_a_notification() {
            let harness = start(metals_policy(false));
            let sent = notify(
                &harness,
                "metals/didFocus",
                json!({ "uri": "file:///A.scala" }),
            );
            assert!(sent.expect("a declared notification is sent"));
            let message = harness
                .server
                .await_notification_at("metals/didFocus", 0)
                .expect("the server receives it");
            assert_eq!(message["params"], json!({ "uri": "file:///A.scala" }));

            let error = notify(&harness, "workspace/executeCommand", json!({}))
                .expect_err("commands run as requests only");
            assert_eq!(refusal_code(error), "plugin.host.methodNotDeclared");
            let error = notify(&harness, "metals/unlisted", json!({}))
                .expect_err("an undeclared notification is refused");
            assert_eq!(refusal_code(error), "plugin.host.methodNotDeclared");
        }

        /// New settings replace the stored configuration, so they also answer
        /// the server's own `workspace/configuration` requests.
        #[test]
        fn changed_configuration_goes_through_the_plugin_configuration() {
            let harness = start(metals_policy(false));
            let settings = json!({ "metals": { "scalafmt": true } });
            let sent = notify(
                &harness,
                "workspace/didChangeConfiguration",
                json!({ "settings": settings }),
            );
            assert!(sent.expect("the change is accepted"));
            let change = harness
                .server
                .await_notification_at("workspace/didChangeConfiguration", 0)
                .expect("the server receives the change");
            assert_eq!(change["params"]["settings"], settings);

            let error = notify(
                &harness,
                "workspace/didChangeConfiguration",
                json!({ "settings": 1 }),
            )
            .expect_err("settings must be an object");
            assert_eq!(refusal_code(error), "plugin.host.invalidParams");
        }

        #[test]
        fn a_stopped_server_fails_what_is_in_flight_and_refuses_new_calls() {
            let mut harness = start(metals_policy(false));
            call(&harness, "slow-1", "metals/slow", json!({})).unwrap();
            call(&harness, "focus-1", "metals/didFocus", json!({})).unwrap();
            harness.server.await_request("metals/slow").unwrap();
            harness.server.await_request("metals/didFocus").unwrap();

            harness.server.exit(Some(1));
            harness.await_state(LspLifecycleState::Failed);
            for operation_id in ["slow-1", "focus-1"] {
                let event = completed(&mut harness, operation_id);
                assert_eq!(error_code(&event), "plugin.host.languageServerUnavailable");
            }

            let error = call(&harness, "late-1", "metals/slow", json!({}))
                .expect_err("a stopped server takes no requests");
            assert_eq!(refusal_code(error), "plugin.host.languageServerUnavailable");
        }

        #[test]
        fn a_gated_request_still_waiting_fails_when_the_server_stops() {
            let mut harness = start(metals_policy(true));
            call(&harness, "held-1", "metals/slow", json!({})).unwrap();

            harness.server.exit(Some(1));
            harness.await_state(LspLifecycleState::Failed);
            let event = completed(&mut harness, "held-1");
            assert_eq!(error_code(&event), "plugin.host.languageServerUnavailable");
        }

        #[test]
        fn an_invalid_policy_is_refused_at_start() {
            let refused = |plugin_id: Option<&str>, policy: Value| {
                let server = ScriptedServer::new();
                let engine = LspEngine::with_launcher(server.launcher());
                let mut request = start_request(&server);
                request.plugin_id = plugin_id.map(ToString::to_string);
                request.session_policy = Some(serde_json::from_value(policy).unwrap());
                match engine.start_server(request) {
                    Err(error) => matches!(error.code, ErrorCode::InvalidRequest),
                    Ok(_) => false,
                }
            };
            // The server ID is no protocol name.
            assert!(refused(Some(PLUGIN), json!({ "serverID": "" })));
            // A serialized command must also be a declared command.
            assert!(refused(
                Some(PLUGIN),
                json!({ "serverID": SERVER, "serializedCommands": ["build-import"] })
            ));
            // A host-owned server has no backend, so it cannot have a policy.
            assert!(refused(None, metals_policy(false)));
        }
    }
}
