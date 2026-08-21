//! Serializable client state and wire models for the generic LSP implementation.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Half-open document range expressed in zero-based LSP coordinates.
pub struct LspRange {
    pub start: LspPosition,
    pub end: LspPosition,
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Zero-based LSP line and UTF-16 code-unit column.
pub struct LspPosition {
    pub line: i64,
    pub utf16_column: i64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Normalized text replacement returned to host applications.
pub struct LspTextEditResponse {
    pub range: LspRangeResponse,
    pub new_text: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Normalized inlay hint independent of provider-specific extensions.
pub struct LspInlayHintResponse {
    pub position: LspPositionResponse,
    pub label: String,
    /// Numeric LSP `InlayHintKind`, when supplied by the server.
    pub kind: Option<i64>,
    pub tooltip: Option<String>,
    pub padding_left: bool,
    pub padding_right: bool,
    pub text_edits: Vec<Value>,
    pub data: Option<Value>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Normalized folding range using UTF-16 columns when supplied by the server.
pub struct LspFoldingRangeResponse {
    pub start_line: i64,
    pub start_utf16_column: Option<i64>,
    pub end_line: i64,
    pub end_utf16_column: Option<i64>,
    /// Server-provided LSP fold category such as `comment`, `imports`, or `region`.
    pub kind: Option<String>,
    pub collapsed_text: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Normalized CodeLens payload awaiting an optional resolve operation.
pub struct LspCodeLensResponse {
    pub range: LspRangeResponse,
    pub command: Option<Value>,
    pub data: Option<Value>,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
/// Serializable form of an LSP document range.
pub struct LspRangeResponse {
    pub start: LspPositionResponse,
    pub end: LspPositionResponse,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
/// Serializable form of a zero-based LSP position.
pub struct LspPositionResponse {
    pub line: i64,
    pub utf16_column: i64,
}

#[derive(Debug, Clone, Copy, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
/// LSP `TextDocumentSyncKind` advertised by the server.
pub enum LspTextDocumentSyncKind {
    /// The server does not want document change notifications.
    None,
    /// The server expects complete document text on every change.
    #[default]
    Full,
    /// The server accepts range-based incremental `didChange` payloads.
    Incremental,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// One LSP `textDocument/didChange` content change.
pub struct LspDocumentContentChange {
    /// Inclusive start / exclusive end range; omitted for a full-document replacement.
    #[serde(default)]
    pub range: Option<LspRange>,
    #[serde(default)]
    pub text: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
/// Pure client protocol state carried between JSON command invocations.
pub struct LspClientState {
    #[serde(default = "default_next_request_id")]
    pub next_request_id: u64,
    #[serde(default)]
    pub initialized: bool,
    #[serde(default)]
    pub shutdown_requested: bool,
    #[serde(default)]
    pub server_capabilities: Vec<String>,
    #[serde(default)]
    /// Server `TextDocumentSyncKind`, used to choose full or incremental `didChange`.
    pub text_document_sync: LspTextDocumentSyncKind,
    #[serde(default)]
    pub open_documents: BTreeMap<String, LspClientDocument>,
    #[serde(default)]
    pub pending_requests: BTreeMap<String, String>,
    #[serde(default)]
    pub diagnostics: BTreeMap<String, Vec<LspClientDiagnostic>>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub diagnostic_versions: BTreeMap<String, i64>,
}

impl Default for LspClientState {
    fn default() -> Self {
        Self {
            next_request_id: default_next_request_id(),
            initialized: false,
            shutdown_requested: false,
            server_capabilities: Vec::new(),
            text_document_sync: LspTextDocumentSyncKind::Full,
            open_documents: BTreeMap::new(),
            pending_requests: BTreeMap::new(),
            diagnostics: BTreeMap::new(),
            diagnostic_versions: BTreeMap::new(),
        }
    }
}

fn default_next_request_id() -> u64 {
    1
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
/// Document version and contents currently synchronized with the server.
pub struct LspClientDocument {
    pub uri: String,
    pub language_id: String,
    pub version: i64,
    pub text: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
/// Diagnostic normalized to fields supported by every frontend.
pub struct LspClientDiagnostic {
    pub range: LspRangeResponse,
    pub severity: Option<i64>,
    pub message: String,
    pub source: Option<String>,
    pub code: Option<String>,
    #[serde(default)]
    pub tags: Vec<i64>,
    #[serde(default)]
    pub related_information: Vec<LspClientDiagnosticRelatedInformation>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
/// Related diagnostic message and its source location.
pub struct LspClientDiagnosticRelatedInformation {
    pub location: LspClientDiagnosticLocation,
    pub message: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
/// URI and range referenced by related diagnostic information.
pub struct LspClientDiagnosticLocation {
    pub uri: String,
    pub range: LspRangeResponse,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Inputs for constructing the LSP initialize request and initial client state.
pub struct ClientInitializeRequest {
    #[serde(default)]
    pub state: LspClientState,
    pub root_uri: String,
    #[serde(default)]
    pub process_id: Option<i64>,
    #[serde(default)]
    pub initialization_options: Option<Value>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Inputs for opening a complete document in pure client state.
pub struct ClientOpenDocumentRequest {
    #[serde(default)]
    pub state: LspClientState,
    pub uri: String,
    pub language_id: String,
    pub text: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Inputs for replacing a synchronized document's contents.
pub struct ClientChangeDocumentRequest {
    #[serde(default)]
    pub state: LspClientState,
    pub uri: String,
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub content_changes: Vec<LspDocumentContentChange>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Inputs for closing a document in pure client state.
pub struct ClientCloseDocumentRequest {
    #[serde(default)]
    pub state: LspClientState,
    pub uri: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Inputs for the LSP shutdown handshake.
pub struct ClientShutdownRequest {
    #[serde(default)]
    pub state: LspClientState,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Generic feature request translated into one provider-neutral JSON-RPC call.
pub struct ClientFeatureRequest {
    #[serde(default)]
    pub state: LspClientState,
    pub uri: String,
    pub method: String,
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

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Server JSON-RPC message to reduce into the current client state.
pub struct ClientApplyServerMessageRequest {
    #[serde(default)]
    pub state: LspClientState,
    pub message: String,
}
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Updated client state, outbound messages, and host-facing events.
pub struct LspClientResponse {
    pub state: LspClientState,
    pub messages: Vec<String>,
    pub events: Vec<LspClientEvent>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Normalized event produced while reducing a server message.
pub struct LspClientEvent {
    /// Pure-client event category: `diagnostics`, `notification`, `response`, or `error`.
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
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
    pub error: Option<String>,
}
