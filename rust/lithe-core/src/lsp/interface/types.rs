use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LspRange {
    pub start: LspPosition,
    pub end: LspPosition,
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LspPosition {
    pub line: i64,
    pub utf16_column: i64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LspTextEditResponse {
    pub range: LspRangeResponse,
    pub new_text: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LspInlayHintResponse {
    pub position: LspPositionResponse,
    pub label: String,
    pub kind: Option<i64>,
    pub tooltip: Option<String>,
    pub padding_left: bool,
    pub padding_right: bool,
    pub text_edits: Vec<Value>,
    pub data: Option<Value>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LspFoldingRangeResponse {
    pub start_line: i64,
    pub start_utf16_column: Option<i64>,
    pub end_line: i64,
    pub end_utf16_column: Option<i64>,
    pub kind: Option<String>,
    pub collapsed_text: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LspCodeLensResponse {
    pub range: LspRangeResponse,
    pub command: Option<Value>,
    pub data: Option<Value>,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LspRangeResponse {
    pub start: LspPositionResponse,
    pub end: LspPositionResponse,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LspPositionResponse {
    pub line: i64,
    pub utf16_column: i64,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
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
pub struct LspClientDocument {
    pub uri: String,
    pub language_id: String,
    pub version: i64,
    pub text: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
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
pub struct LspClientDiagnosticRelatedInformation {
    pub location: LspClientDiagnosticLocation,
    pub message: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LspClientDiagnosticLocation {
    pub uri: String,
    pub range: LspRangeResponse,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
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
pub struct ClientOpenDocumentRequest {
    #[serde(default)]
    pub state: LspClientState,
    pub uri: String,
    pub language_id: String,
    pub text: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientChangeDocumentRequest {
    #[serde(default)]
    pub state: LspClientState,
    pub uri: String,
    pub text: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientCloseDocumentRequest {
    #[serde(default)]
    pub state: LspClientState,
    pub uri: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientShutdownRequest {
    #[serde(default)]
    pub state: LspClientState,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
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
pub struct ClientApplyServerMessageRequest {
    #[serde(default)]
    pub state: LspClientState,
    pub message: String,
}
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LspClientResponse {
    pub state: LspClientState,
    pub messages: Vec<String>,
    pub events: Vec<LspClientEvent>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LspClientEvent {
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
