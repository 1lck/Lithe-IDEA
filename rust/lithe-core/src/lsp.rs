use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::error::{CoreError, ErrorCode};

const BUILTIN_LANGUAGE_PROVIDERS: &str = include_str!("../resources/lsp/language-providers.json");

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LspProviderCatalog {
    pub version: u32,
    pub providers: Vec<LspProviderDescriptor>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub diagnostics: Vec<LspProviderConfigDiagnostic>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LspProviderConfigDiagnostic {
    pub path: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LspProviderDescriptor {
    pub id: String,
    pub display_name: String,
    pub file_extensions: Vec<String>,
    pub file_names: Vec<String>,
    pub file_name_prefixes: Vec<String>,
    pub capabilities: Vec<LspProviderCapability>,
    pub activation_policy: LspActivationPolicy,
    pub language_id: Option<String>,
    pub language_ids_by_extension: BTreeMap<String, String>,
    pub language_ids_by_file_name: BTreeMap<String, String>,
    pub language_server_launch: Option<LspServerLaunchDescriptor>,
}

#[derive(Debug, Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LspServerLaunchDescriptor {
    pub executable_names: Vec<String>,
    #[serde(default)]
    pub arguments: Vec<String>,
}

#[derive(Debug, Clone, Copy, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum LspProviderCapability {
    Run,
    LanguageServer,
    DebugAdapter,
    Formatting,
    Testing,
}

#[derive(Debug, Clone, Copy, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum LspActivationPolicy {
    OnDemand,
    Always,
}

impl Default for LspActivationPolicy {
    fn default() -> Self {
        Self::OnDemand
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LspProviderConfigDocument {
    #[serde(default = "default_config_version")]
    version: u32,
    #[serde(default)]
    providers: Vec<LspProviderPatch>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LspProviderPatch {
    id: String,
    #[serde(default)]
    display_name: Option<String>,
    #[serde(default)]
    file_extensions: Option<Vec<String>>,
    #[serde(default)]
    file_names: Option<Vec<String>>,
    #[serde(default)]
    file_name_prefixes: Option<Vec<String>>,
    #[serde(default)]
    capabilities: Option<Vec<LspProviderCapability>>,
    #[serde(default)]
    activation_policy: Option<LspActivationPolicy>,
    #[serde(default)]
    language_id: Option<String>,
    #[serde(default)]
    language_ids_by_extension: Option<BTreeMap<String, String>>,
    #[serde(default)]
    language_ids_by_file_name: Option<BTreeMap<String, String>>,
    #[serde(default)]
    language_server_launch: Option<LspServerLaunchDescriptor>,
    #[serde(default)]
    disabled: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApplyTextEditsRequest {
    pub text: String,
    #[serde(default)]
    pub edits: Vec<LspTextEdit>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LspTextEdit {
    pub range: LspRange,
    pub new_text: String,
}

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
pub struct TextResponse {
    pub text: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlainSnippetRequest {
    pub value: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BuiltinRequest {
    pub file_path: String,
    pub text: String,
    pub position: LspPosition,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BuiltinNavigationRequest {
    pub file_path: String,
    pub text: String,
    pub position: LspPosition,
    pub method: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BuiltinCompletionResponse {
    pub items: Vec<BuiltinCompletionItem>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BuiltinCompletionItem {
    pub label: String,
    pub insert_text: String,
    pub kind: Option<i32>,
    pub detail: Option<String>,
    pub text_edit: LspTextEditResponse,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LspTextEditResponse {
    pub range: LspRangeResponse,
    pub new_text: String,
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

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BuiltinHoverResponse {
    pub hover: Option<BuiltinHover>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BuiltinHover {
    pub contents: String,
    pub is_markdown: bool,
    pub range: LspRangeResponse,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BuiltinNavigationResponse {
    pub locations: Vec<BuiltinLocation>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BuiltinLocation {
    pub file_path: String,
    pub range: LspRangeResponse,
    pub is_read_only: bool,
    pub display_path: Option<String>,
}

#[derive(Debug, Clone)]
struct IdentifierOccurrence {
    value: String,
    start: usize,
    end: usize,
    range: LspRangeResponse,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LspClientState {
    #[serde(default = "default_next_request_id")]
    pub next_request_id: u64,
    #[serde(default)]
    pub initialized: bool,
    #[serde(default)]
    pub server_capabilities: Vec<String>,
    #[serde(default)]
    pub open_documents: BTreeMap<String, LspClientDocument>,
    #[serde(default)]
    pub pending_requests: BTreeMap<String, String>,
    #[serde(default)]
    pub diagnostics: BTreeMap<String, Vec<LspClientDiagnostic>>,
}

impl Default for LspClientState {
    fn default() -> Self {
        Self {
            next_request_id: default_next_request_id(),
            initialized: false,
            server_capabilities: Vec::new(),
            open_documents: BTreeMap::new(),
            pending_requests: BTreeMap::new(),
            diagnostics: BTreeMap::new(),
        }
    }
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
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientInitializeRequest {
    #[serde(default)]
    pub state: LspClientState,
    pub root_uri: String,
    #[serde(default)]
    pub process_id: Option<i64>,
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
    pub diagnostics: Option<Vec<LspClientDiagnostic>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

pub fn provider_catalog_json(workspace_root: Option<&Path>) -> String {
    let catalog = provider_catalog(workspace_root);
    serde_json::to_string(&catalog)
        .unwrap_or_else(|_| "{\"version\":1,\"providers\":[]}".to_string())
}

pub fn apply_text_edits(request: ApplyTextEditsRequest) -> Result<TextResponse, CoreError> {
    let mut replacements = Vec::new();
    for edit in request.edits {
        let start = utf16_position_to_byte_offset(&request.text, edit.range.start)?;
        let end = utf16_position_to_byte_offset(&request.text, edit.range.end)?;
        if end < start {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Language server returned an invalid text range.",
            )
            .with_details("invalidRange"));
        }
        replacements.push((start, end, edit.new_text));
    }
    replacements.sort_by_key(|(start, _, _)| *start);
    for pair in replacements.windows(2) {
        if pair[0].1 > pair[1].0 {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Language server returned overlapping text edits.",
            )
            .with_details("overlappingEdits"));
        }
    }

    let mut text = request.text;
    for (start, end, replacement) in replacements.into_iter().rev() {
        text.replace_range(start..end, &replacement);
    }
    Ok(TextResponse { text })
}

pub fn plain_snippet(request: PlainSnippetRequest) -> TextResponse {
    TextResponse {
        text: snippet_plain_text(&request.value),
    }
}

pub fn builtin_completions(
    request: BuiltinRequest,
) -> Result<BuiltinCompletionResponse, CoreError> {
    validate_file_path(&request.file_path)?;
    let cursor = utf16_position_to_byte_offset(&request.text, request.position)?;
    let prefix = identifier_prefix_at(&request.text, cursor);
    let start_column = request.position.utf16_column - prefix.encode_utf16().count() as i64;
    let replacement_range = LspRangeResponse {
        start: LspPositionResponse {
            line: request.position.line,
            utf16_column: start_column.max(0),
        },
        end: LspPositionResponse {
            line: request.position.line,
            utf16_column: request.position.utf16_column,
        },
    };

    let mut seen = BTreeMap::<String, i32>::new();
    for occurrence in identifier_occurrences(&request.text) {
        if occurrence.value == prefix {
            continue;
        }
        if !prefix.is_empty() && !occurrence.value.starts_with(&prefix) {
            continue;
        }
        let kind = builtin_completion_kind(&request.text, occurrence.start);
        seen.entry(occurrence.value).or_insert(kind);
    }

    let items = seen
        .into_iter()
        .take(80)
        .map(|(label, kind)| BuiltinCompletionItem {
            insert_text: label.clone(),
            label,
            kind: Some(kind),
            detail: Some("Current file symbol".to_string()),
            text_edit: LspTextEditResponse {
                range: replacement_range,
                new_text: String::new(),
            },
        })
        .map(|mut item| {
            item.text_edit.new_text = item.insert_text.clone();
            item
        })
        .collect();
    Ok(BuiltinCompletionResponse { items })
}

pub fn builtin_hover(request: BuiltinRequest) -> Result<BuiltinHoverResponse, CoreError> {
    validate_file_path(&request.file_path)?;
    let cursor = utf16_position_to_byte_offset(&request.text, request.position)?;
    let Some(identifier) = identifier_at(&request.text, cursor) else {
        return Ok(BuiltinHoverResponse { hover: None });
    };
    Ok(BuiltinHoverResponse {
        hover: Some(BuiltinHover {
            contents: format!("`{}`", identifier.value),
            is_markdown: true,
            range: identifier.range,
        }),
    })
}

pub fn builtin_navigation(
    request: BuiltinNavigationRequest,
) -> Result<BuiltinNavigationResponse, CoreError> {
    validate_file_path(&request.file_path)?;
    let cursor = utf16_position_to_byte_offset(&request.text, request.position)?;
    let Some(identifier) = identifier_at(&request.text, cursor) else {
        return Ok(BuiltinNavigationResponse {
            locations: Vec::new(),
        });
    };
    let mut occurrences: Vec<_> = identifier_occurrences(&request.text)
        .into_iter()
        .filter(|occurrence| occurrence.value == identifier.value)
        .collect();

    if request.method == "textDocument/definition"
        || request.method == "textDocument/declaration"
        || request.method == "textDocument/typeDefinition"
    {
        let declarations: Vec<_> = occurrences
            .iter()
            .filter(|occurrence| looks_like_declaration(&request.text, occurrence.start))
            .cloned()
            .collect();
        if !declarations.is_empty() {
            occurrences = declarations;
        }
    } else if request.method == "textDocument/implementation" {
        occurrences.retain(|occurrence| occurrence.start != identifier.start);
    }

    let locations = occurrences
        .into_iter()
        .take(200)
        .map(|occurrence| BuiltinLocation {
            file_path: request.file_path.clone(),
            range: occurrence.range,
            is_read_only: false,
            display_path: None,
        })
        .collect();
    Ok(BuiltinNavigationResponse { locations })
}

pub fn client_initialize(request: ClientInitializeRequest) -> Result<LspClientResponse, CoreError> {
    validate_uri(&request.root_uri)?;
    let mut state = request.state;
    let id = allocate_request(&mut state, "initialize");
    let message = json_rpc_request(
        &id,
        "initialize",
        json!({
            "processId": request.process_id,
            "rootUri": request.root_uri,
            "capabilities": {
                "textDocument": {
                    "synchronization": {
                        "didSave": true
                    },
                    "completion": {
                        "dynamicRegistration": true,
                        "completionItem": {
                            "snippetSupport": true,
                            "documentationFormat": ["markdown", "plaintext"]
                        }
                    },
                    "hover": {
                        "dynamicRegistration": true,
                        "contentFormat": ["markdown", "plaintext"]
                    },
                    "definition": { "dynamicRegistration": true },
                    "declaration": { "dynamicRegistration": true },
                    "typeDefinition": { "dynamicRegistration": true },
                    "implementation": { "dynamicRegistration": true },
                    "references": { "dynamicRegistration": true },
                    "rename": { "dynamicRegistration": true },
                    "formatting": { "dynamicRegistration": true },
                    "codeAction": {
                        "dynamicRegistration": true,
                        "codeActionLiteralSupport": {
                            "codeActionKind": {
                                "valueSet": ["quickfix", "refactor", "source"]
                            }
                        }
                    },
                    "publishDiagnostics": {
                        "relatedInformation": true
                    }
                },
                "workspace": {
                    "applyEdit": true,
                    "workspaceEdit": {
                        "documentChanges": true
                    },
                    "executeCommand": { "dynamicRegistration": true }
                }
            }
        }),
    )?;
    Ok(client_response(state, vec![message], Vec::new()))
}

pub fn client_open_document(
    request: ClientOpenDocumentRequest,
) -> Result<LspClientResponse, CoreError> {
    validate_uri(&request.uri)?;
    let mut state = request.state;
    let document = LspClientDocument {
        uri: request.uri.clone(),
        language_id: request.language_id,
        version: 1,
        text: request.text,
    };
    let message = json_rpc_notification(
        "textDocument/didOpen",
        json!({
            "textDocument": {
                "uri": document.uri,
                "languageId": document.language_id,
                "version": document.version,
                "text": document.text
            }
        }),
    )?;
    state.open_documents.insert(request.uri, document);
    Ok(client_response(state, vec![message], Vec::new()))
}

pub fn client_change_document(
    request: ClientChangeDocumentRequest,
) -> Result<LspClientResponse, CoreError> {
    validate_uri(&request.uri)?;
    let mut state = request.state;
    let Some(document) = state.open_documents.get_mut(&request.uri) else {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Cannot change a document that is not open in the LSP client.",
        ));
    };
    document.version += 1;
    document.text = request.text;
    let message = json_rpc_notification(
        "textDocument/didChange",
        json!({
            "textDocument": {
                "uri": document.uri,
                "version": document.version
            },
            "contentChanges": [{
                "text": document.text
            }]
        }),
    )?;
    Ok(client_response(state, vec![message], Vec::new()))
}

pub fn client_feature_request(
    request: ClientFeatureRequest,
) -> Result<LspClientResponse, CoreError> {
    validate_uri(&request.uri)?;
    validate_lsp_method(&request.method)?;
    let params = feature_request_params(&request)?;
    let uri = request.uri.clone();
    let method = request.method.clone();
    let mut state = request.state;
    if !state.open_documents.contains_key(&uri) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Cannot request LSP features for a document that is not open.",
        ));
    }
    let id = allocate_request(&mut state, &method);
    let message = json_rpc_request(&id, &method, params)?;
    Ok(client_response(state, vec![message], Vec::new()))
}

pub fn client_apply_server_message(
    request: ClientApplyServerMessageRequest,
) -> Result<LspClientResponse, CoreError> {
    let mut state = request.state;
    let message: Value = serde_json::from_str(&request.message).map_err(|error| {
        CoreError::new(ErrorCode::InvalidRequest, "Invalid LSP server JSON message")
            .with_details(error.to_string())
    })?;
    let mut responses = Vec::new();
    let mut events = Vec::new();

    if let Some(method) = message.get("method").and_then(Value::as_str) {
        match method {
            "textDocument/publishDiagnostics" => {
                if let Some(params) = message.get("params") {
                    let uri = params
                        .get("uri")
                        .and_then(Value::as_str)
                        .unwrap_or_default();
                    validate_uri(uri)?;
                    let diagnostics = parse_diagnostics(params.get("diagnostics"));
                    state
                        .diagnostics
                        .insert(uri.to_string(), diagnostics.clone());
                    events.push(LspClientEvent {
                        kind: "diagnostics".to_string(),
                        request_id: None,
                        method: None,
                        uri: Some(uri.to_string()),
                        diagnostics: Some(diagnostics),
                        result: None,
                        error: None,
                    });
                }
            }
            "client/registerCapability" => {
                apply_dynamic_registration(&mut state, &message);
                if let Some(id) = lsp_message_id(&message) {
                    responses.push(json_rpc_result(&id, Value::Null)?);
                }
            }
            "client/unregisterCapability" => {
                apply_dynamic_unregistration(&mut state, &message);
                if let Some(id) = lsp_message_id(&message) {
                    responses.push(json_rpc_result(&id, Value::Null)?);
                }
            }
            _ => {
                events.push(LspClientEvent {
                    kind: "notification".to_string(),
                    request_id: None,
                    method: Some(method.to_string()),
                    uri: None,
                    diagnostics: None,
                    result: message.get("params").cloned(),
                    error: None,
                });
            }
        }
    } else if let Some(id) = lsp_message_id(&message) {
        let pending = state.pending_requests.remove(&id);
        if pending.as_deref() == Some("initialize") {
            if let Some(result) = message.get("result") {
                state.server_capabilities = feature_names_from_capabilities(
                    result.get("capabilities").unwrap_or(&Value::Null),
                );
                state.initialized = true;
                responses.push(json_rpc_notification("initialized", json!({}))?);
            }
        }
        let result = lsp_feature_result_for_method(pending.as_deref(), message.get("result"));
        events.push(LspClientEvent {
            kind: if message.get("error").is_some() {
                "error".to_string()
            } else {
                "response".to_string()
            },
            request_id: Some(id),
            method: pending,
            uri: None,
            diagnostics: None,
            result,
            error: message.get("error").map(|value| value.to_string()),
        });
    }

    Ok(client_response(state, responses, events))
}

pub fn provider_catalog(workspace_root: Option<&Path>) -> LspProviderCatalog {
    let mut diagnostics = Vec::new();
    let mut document = match parse_document(BUILTIN_LANGUAGE_PROVIDERS, "builtin:lsp") {
        Ok(document) => document,
        Err(message) => {
            diagnostics.push(LspProviderConfigDiagnostic {
                path: "builtin:lsp".to_string(),
                message,
            });
            LspProviderConfigDocument {
                version: 1,
                providers: Vec::new(),
            }
        }
    };

    if let Some(root) = workspace_root {
        let path = project_config_path(root);
        if path.is_file() {
            match std::fs::read_to_string(&path) {
                Ok(raw) => match parse_document(&raw, &path.display().to_string()) {
                    Ok(project_document) => {
                        document = merge_documents(document, project_document);
                    }
                    Err(message) => diagnostics.push(LspProviderConfigDiagnostic {
                        path: path.display().to_string(),
                        message,
                    }),
                },
                Err(error) => diagnostics.push(LspProviderConfigDiagnostic {
                    path: path.display().to_string(),
                    message: error.to_string(),
                }),
            }
        }
    }

    let mut providers = Vec::new();
    for patch in document.providers {
        if patch.disabled {
            continue;
        }
        providers.push(LspProviderDescriptor::from_patch(patch));
    }
    LspProviderCatalog {
        version: document.version,
        providers,
        diagnostics,
    }
}

fn parse_document(raw: &str, source: &str) -> Result<LspProviderConfigDocument, String> {
    serde_json::from_str(raw).map_err(|error| format!("{source}: {error}"))
}

fn merge_documents(
    mut base: LspProviderConfigDocument,
    project: LspProviderConfigDocument,
) -> LspProviderConfigDocument {
    base.version = project.version.max(base.version);
    for patch in project.providers {
        if let Some(existing) = base
            .providers
            .iter_mut()
            .find(|provider| provider.id == patch.id)
        {
            existing.apply(patch);
        } else {
            base.providers.push(patch);
        }
    }
    base
}

fn project_config_path(root: &Path) -> PathBuf {
    root.join(".lithe")
        .join("lsp")
        .join("language-providers.json")
}

fn default_config_version() -> u32 {
    1
}

fn default_next_request_id() -> u64 {
    1
}

fn client_response(
    state: LspClientState,
    messages: Vec<String>,
    events: Vec<LspClientEvent>,
) -> LspClientResponse {
    LspClientResponse {
        state,
        messages,
        events,
    }
}

fn allocate_request(state: &mut LspClientState, method: &str) -> String {
    let id = state.next_request_id.to_string();
    state.next_request_id += 1;
    state
        .pending_requests
        .insert(id.clone(), method.to_string());
    id
}

fn json_rpc_request(id: &str, method: &str, params: Value) -> Result<String, CoreError> {
    encode_json_rpc(json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": method,
        "params": params
    }))
}

fn json_rpc_notification(method: &str, params: Value) -> Result<String, CoreError> {
    encode_json_rpc(json!({
        "jsonrpc": "2.0",
        "method": method,
        "params": params
    }))
}

fn json_rpc_result(id: &str, result: Value) -> Result<String, CoreError> {
    encode_json_rpc(json!({
        "jsonrpc": "2.0",
        "id": id,
        "result": result
    }))
}

fn encode_json_rpc(value: Value) -> Result<String, CoreError> {
    serde_json::to_string(&value).map_err(|error| {
        CoreError::new(ErrorCode::Unknown, "Could not encode LSP JSON-RPC message")
            .with_details(error.to_string())
    })
}

fn validate_uri(value: &str) -> Result<(), CoreError> {
    if value.trim().is_empty() || value.contains('\0') {
        Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "LSP request requires a valid URI.",
        ))
    } else {
        Ok(())
    }
}

fn validate_lsp_method(method: &str) -> Result<(), CoreError> {
    match method {
        "textDocument/completion"
        | "textDocument/hover"
        | "textDocument/definition"
        | "textDocument/declaration"
        | "textDocument/typeDefinition"
        | "textDocument/implementation"
        | "textDocument/references"
        | "textDocument/rename"
        | "textDocument/formatting"
        | "textDocument/codeAction"
        | "completionItem/resolve"
        | "codeAction/resolve"
        | "workspace/executeCommand" => Ok(()),
        _ => Err(CoreError::new(
            ErrorCode::NotSupported,
            "Unsupported LSP client request method.",
        )
        .with_details(method.to_string())),
    }
}

fn feature_request_params(request: &ClientFeatureRequest) -> Result<Value, CoreError> {
    let text_document = json!({ "uri": request.uri });
    match request.method.as_str() {
        "textDocument/completion"
        | "textDocument/hover"
        | "textDocument/definition"
        | "textDocument/declaration"
        | "textDocument/typeDefinition"
        | "textDocument/implementation" => Ok(json!({
            "textDocument": text_document,
            "position": lsp_position_json(required_position(request)?)
        })),
        "textDocument/references" => Ok(json!({
            "textDocument": text_document,
            "position": lsp_position_json(required_position(request)?),
            "context": { "includeDeclaration": true }
        })),
        "textDocument/rename" => Ok(json!({
            "textDocument": text_document,
            "position": lsp_position_json(required_position(request)?),
            "newName": request.new_name.clone().unwrap_or_default()
        })),
        "textDocument/formatting" => Ok(json!({
            "textDocument": text_document,
            "options": {
                "tabSize": 4,
                "insertSpaces": true,
                "trimTrailingWhitespace": true,
                "insertFinalNewline": true,
                "trimFinalNewlines": true
            }
        })),
        "textDocument/codeAction" => Ok(json!({
            "textDocument": text_document,
            "range": lsp_range_json(required_range(request)?),
            "context": {
                "diagnostics": request
                    .diagnostics
                    .iter()
                    .map(lsp_diagnostic_json)
                    .collect::<Vec<_>>()
            }
        })),
        _ => Ok(json!({ "textDocument": text_document })),
    }
}

fn required_position(request: &ClientFeatureRequest) -> Result<LspPosition, CoreError> {
    request.position.ok_or_else(|| {
        CoreError::new(
            ErrorCode::InvalidRequest,
            "This LSP request requires a text document position.",
        )
    })
}

fn required_range(request: &ClientFeatureRequest) -> Result<LspRange, CoreError> {
    request.range.ok_or_else(|| {
        CoreError::new(
            ErrorCode::InvalidRequest,
            "This LSP request requires a text document range.",
        )
    })
}

fn lsp_position_json(position: LspPosition) -> Value {
    json!({
        "line": position.line,
        "character": position.utf16_column
    })
}

fn lsp_range_json(range: LspRange) -> Value {
    json!({
        "start": lsp_position_json(range.start),
        "end": lsp_position_json(range.end)
    })
}

fn lsp_diagnostic_json(diagnostic: &LspClientDiagnostic) -> Value {
    json!({
        "range": {
            "start": {
                "line": diagnostic.range.start.line,
                "character": diagnostic.range.start.utf16_column
            },
            "end": {
                "line": diagnostic.range.end.line,
                "character": diagnostic.range.end.utf16_column
            }
        },
        "severity": diagnostic.severity,
        "message": diagnostic.message,
        "source": diagnostic.source,
        "code": diagnostic.code
    })
}

fn lsp_message_id(message: &Value) -> Option<String> {
    message.get("id").and_then(|id| match id {
        Value::String(value) => Some(value.clone()),
        Value::Number(value) => Some(value.to_string()),
        _ => None,
    })
}

fn parse_diagnostics(value: Option<&Value>) -> Vec<LspClientDiagnostic> {
    value
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|item| {
                    Some(LspClientDiagnostic {
                        range: parse_lsp_range(item.get("range")?)?,
                        severity: item.get("severity").and_then(Value::as_i64),
                        message: item
                            .get("message")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_string(),
                        source: item
                            .get("source")
                            .and_then(Value::as_str)
                            .map(str::to_string),
                        code: item.get("code").and_then(|code| match code {
                            Value::String(value) => Some(value.clone()),
                            Value::Number(value) => Some(value.to_string()),
                            _ => None,
                        }),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

fn parse_lsp_range(value: &Value) -> Option<LspRangeResponse> {
    Some(LspRangeResponse {
        start: parse_lsp_position(value.get("start")?)?,
        end: parse_lsp_position(value.get("end")?)?,
    })
}

fn parse_lsp_position(value: &Value) -> Option<LspPositionResponse> {
    Some(LspPositionResponse {
        line: value.get("line")?.as_i64()?,
        utf16_column: value.get("character")?.as_i64()?,
    })
}

fn lsp_feature_result_for_method(method: Option<&str>, result: Option<&Value>) -> Option<Value> {
    let result = result?;
    match method {
        Some("textDocument/completion") => Some(json!({
            "items": parse_completion_items(result)
        })),
        Some("textDocument/hover") => Some(json!({
            "hover": parse_hover(result)
        })),
        Some("textDocument/rename") => Some(json!({
            "changes": parse_workspace_edit(result)
        })),
        Some("textDocument/formatting") => Some(json!({
            "edits": result
                .as_array()
                .map(|edits| edits.iter().filter_map(parse_lsp_text_edit_value).collect::<Vec<_>>())
                .unwrap_or_default()
        })),
        Some("textDocument/codeAction") => Some(json!({
            "actions": parse_code_actions(result)
        })),
        Some("textDocument/definition")
        | Some("textDocument/declaration")
        | Some("textDocument/typeDefinition")
        | Some("textDocument/implementation")
        | Some("textDocument/references") => Some(json!({
            "locations": parse_locations(result)
        })),
        _ => Some(result.clone()),
    }
}

fn parse_completion_items(result: &Value) -> Vec<Value> {
    let values = result
        .as_array()
        .or_else(|| result.get("items").and_then(Value::as_array));
    let Some(values) = values else {
        return Vec::new();
    };
    values
        .iter()
        .filter_map(|item| {
            let label = item.get("label").and_then(Value::as_str)?;
            let insert_text = item
                .get("insertText")
                .and_then(Value::as_str)
                .or_else(|| {
                    item.get("textEdit")
                        .and_then(|edit| edit.get("newText"))
                        .and_then(Value::as_str)
                })
                .unwrap_or(label);
            Some(json!({
                "label": label,
                "insertText": insert_text,
                "kind": item.get("kind").and_then(Value::as_i64),
                "detail": item.get("detail").and_then(Value::as_str),
                "documentation": completion_documentation(item.get("documentation")),
                "sortText": item.get("sortText").and_then(Value::as_str),
                "filterText": item.get("filterText").and_then(Value::as_str),
                "textEdit": item.get("textEdit").and_then(parse_lsp_text_edit_value),
                "additionalTextEdits": item
                    .get("additionalTextEdits")
                    .and_then(Value::as_array)
                    .map(|edits| edits.iter().filter_map(parse_lsp_text_edit_value).collect::<Vec<_>>())
                    .unwrap_or_default(),
                "data": item.get("data").cloned().unwrap_or(Value::Null)
            }))
        })
        .collect()
}

fn completion_documentation(value: Option<&Value>) -> Option<String> {
    match value? {
        Value::String(text) => Some(text.clone()),
        Value::Object(object) => object
            .get("value")
            .and_then(Value::as_str)
            .map(ToString::to_string),
        _ => None,
    }
}

fn parse_hover(result: &Value) -> Option<Value> {
    if result.is_null() {
        return None;
    }
    let contents = hover_contents(result.get("contents").unwrap_or(result))?;
    let range = result.get("range").and_then(parse_lsp_range_value);
    Some(json!({
        "contents": contents.0,
        "isMarkdown": contents.1,
        "range": range
    }))
}

fn hover_contents(value: &Value) -> Option<(String, bool)> {
    match value {
        Value::String(text) => Some((text.clone(), false)),
        Value::Object(object) => {
            if let Some(value) = object.get("value").and_then(Value::as_str) {
                let is_markdown = object
                    .get("kind")
                    .and_then(Value::as_str)
                    .map(|kind| kind == "markdown")
                    .unwrap_or(false);
                Some((value.to_string(), is_markdown))
            } else if let Some(value) = object.get("language").and_then(Value::as_str) {
                Some((value.to_string(), true))
            } else {
                None
            }
        }
        Value::Array(values) => {
            let parts: Vec<_> = values
                .iter()
                .filter_map(hover_contents)
                .map(|(text, _)| text)
                .collect();
            if parts.is_empty() {
                None
            } else {
                Some((parts.join("\n\n"), true))
            }
        }
        _ => None,
    }
}

fn parse_locations(result: &Value) -> Vec<Value> {
    let values: Vec<&Value> = if let Some(array) = result.as_array() {
        array.iter().collect()
    } else if result.is_object() {
        vec![result]
    } else {
        Vec::new()
    };
    values
        .into_iter()
        .filter_map(|location| {
            let uri = location
                .get("uri")
                .or_else(|| location.get("targetUri"))
                .and_then(Value::as_str)?;
            let range = location
                .get("range")
                .or_else(|| location.get("targetSelectionRange"))
                .or_else(|| location.get("targetRange"))
                .and_then(parse_lsp_range_value)?;
            Some(json!({
                "filePath": file_path_from_uri(uri),
                "range": range,
                "isReadOnly": false,
                "displayPath": Value::Null
            }))
        })
        .collect()
}

fn parse_code_actions(result: &Value) -> Vec<Value> {
    let Some(values) = result.as_array() else {
        return Vec::new();
    };
    values
        .iter()
        .filter_map(|action| {
            let title = action.get("title").and_then(Value::as_str)?;
            let command = if action.get("command").and_then(Value::as_str).is_some() {
                parse_lsp_command(action)
            } else {
                action.get("command").and_then(parse_lsp_command)
            };
            Some(json!({
                "title": title,
                "kind": action.get("kind").and_then(Value::as_str),
                "isPreferred": action
                    .get("isPreferred")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
                "edit": action.get("edit").map(|edit| json!({
                    "changes": parse_workspace_edit(edit)
                })),
                "command": command,
                "data": action.get("data").cloned().unwrap_or(Value::Null)
            }))
        })
        .collect()
}

fn parse_lsp_command(value: &Value) -> Option<Value> {
    Some(json!({
        "title": value.get("title").and_then(Value::as_str).unwrap_or_default(),
        "command": value.get("command").and_then(Value::as_str)?,
        "arguments": value
            .get("arguments")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default()
    }))
}

fn parse_workspace_edit(result: &Value) -> serde_json::Map<String, Value> {
    let mut changes = serde_json::Map::new();
    if let Some(entries) = result.get("changes").and_then(Value::as_object) {
        for (uri, edits) in entries {
            let parsed = edits
                .as_array()
                .map(|edits| {
                    edits
                        .iter()
                        .filter_map(parse_lsp_text_edit_value)
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            changes.insert(file_path_from_uri(uri), json!(parsed));
        }
    }
    if let Some(document_changes) = result.get("documentChanges").and_then(Value::as_array) {
        for change in document_changes {
            let Some(uri) = change
                .get("textDocument")
                .and_then(|document| document.get("uri"))
                .and_then(Value::as_str)
            else {
                continue;
            };
            let parsed = change
                .get("edits")
                .and_then(Value::as_array)
                .map(|edits| {
                    edits
                        .iter()
                        .filter_map(parse_lsp_text_edit_value)
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            changes.insert(file_path_from_uri(uri), json!(parsed));
        }
    }
    changes
}

fn parse_lsp_text_edit_value(value: &Value) -> Option<Value> {
    Some(json!({
        "range": parse_lsp_range_value(value.get("range")?)?,
        "newText": value.get("newText").and_then(Value::as_str).unwrap_or_default()
    }))
}

fn parse_lsp_range_value(value: &Value) -> Option<Value> {
    Some(json!({
        "start": parse_lsp_position_value(value.get("start")?)?,
        "end": parse_lsp_position_value(value.get("end")?)?
    }))
}

fn parse_lsp_position_value(value: &Value) -> Option<Value> {
    Some(json!({
        "line": value.get("line").and_then(Value::as_i64).unwrap_or(0),
        "utf16Column": value
            .get("character")
            .or_else(|| value.get("utf16Column"))
            .and_then(Value::as_i64)
            .unwrap_or(0)
    }))
}

fn file_path_from_uri(uri: &str) -> String {
    uri.strip_prefix("file://").unwrap_or(uri).to_string()
}

fn feature_names_from_capabilities(capabilities: &Value) -> Vec<String> {
    let mut values = Vec::new();
    add_capability(
        &mut values,
        capabilities,
        "definitionProvider",
        "definition",
    );
    add_capability(
        &mut values,
        capabilities,
        "declarationProvider",
        "declaration",
    );
    add_capability(
        &mut values,
        capabilities,
        "typeDefinitionProvider",
        "typeDefinition",
    );
    add_capability(
        &mut values,
        capabilities,
        "implementationProvider",
        "implementation",
    );
    add_capability(
        &mut values,
        capabilities,
        "referencesProvider",
        "references",
    );
    add_capability(&mut values, capabilities, "hoverProvider", "hover");
    add_capability(
        &mut values,
        capabilities,
        "completionProvider",
        "completion",
    );
    add_capability(&mut values, capabilities, "renameProvider", "rename");
    add_capability(
        &mut values,
        capabilities,
        "documentFormattingProvider",
        "formatting",
    );
    add_capability(
        &mut values,
        capabilities,
        "codeActionProvider",
        "codeActions",
    );
    add_capability(
        &mut values,
        capabilities,
        "executeCommandProvider",
        "executeCommand",
    );
    if capabilities
        .get("completionProvider")
        .and_then(|value| value.get("resolveProvider"))
        .and_then(Value::as_bool)
        == Some(true)
    {
        insert_unique(&mut values, "completionResolve");
    }
    if capabilities
        .get("codeActionProvider")
        .and_then(|value| value.get("resolveProvider"))
        .and_then(Value::as_bool)
        == Some(true)
    {
        insert_unique(&mut values, "codeActionResolve");
    }
    values
}

fn add_capability(values: &mut Vec<String>, capabilities: &Value, key: &str, feature: &str) {
    match capabilities.get(key) {
        Some(Value::Bool(true)) => insert_unique(values, feature),
        Some(Value::Object(_)) => insert_unique(values, feature),
        _ => {}
    }
}

fn apply_dynamic_registration(state: &mut LspClientState, message: &Value) {
    let Some(registrations) = message
        .get("params")
        .and_then(|params| params.get("registrations"))
        .and_then(Value::as_array)
    else {
        return;
    };
    for registration in registrations {
        if let Some(feature) = registration
            .get("method")
            .and_then(Value::as_str)
            .and_then(feature_name_for_method)
        {
            insert_unique(&mut state.server_capabilities, feature);
        }
        if registration
            .get("registerOptions")
            .and_then(|options| options.get("resolveProvider"))
            .and_then(Value::as_bool)
            == Some(true)
        {
            if registration.get("method").and_then(Value::as_str) == Some("textDocument/completion")
            {
                insert_unique(&mut state.server_capabilities, "completionResolve");
            }
            if registration.get("method").and_then(Value::as_str) == Some("textDocument/codeAction")
            {
                insert_unique(&mut state.server_capabilities, "codeActionResolve");
            }
        }
    }
}

fn apply_dynamic_unregistration(state: &mut LspClientState, message: &Value) {
    let Some(unregistrations) = message
        .get("params")
        .and_then(|params| {
            params
                .get("unregistrations")
                .or_else(|| params.get("unregisterations"))
        })
        .and_then(Value::as_array)
    else {
        return;
    };
    for unregistration in unregistrations {
        if let Some(feature) = unregistration
            .get("method")
            .and_then(Value::as_str)
            .and_then(feature_name_for_method)
        {
            state
                .server_capabilities
                .retain(|existing| existing != feature);
        }
    }
}

fn feature_name_for_method(method: &str) -> Option<&'static str> {
    match method {
        "textDocument/definition" => Some("definition"),
        "textDocument/declaration" => Some("declaration"),
        "textDocument/typeDefinition" => Some("typeDefinition"),
        "textDocument/implementation" => Some("implementation"),
        "textDocument/references" => Some("references"),
        "textDocument/hover" => Some("hover"),
        "textDocument/completion" => Some("completion"),
        "textDocument/rename" => Some("rename"),
        "textDocument/formatting" => Some("formatting"),
        "textDocument/codeAction" => Some("codeActions"),
        "workspace/executeCommand" => Some("executeCommand"),
        _ => None,
    }
}

fn insert_unique(values: &mut Vec<String>, value: &str) {
    if !values.iter().any(|existing| existing == value) {
        values.push(value.to_string());
    }
}

impl LspProviderPatch {
    fn apply(&mut self, patch: LspProviderPatch) {
        if patch.display_name.is_some() {
            self.display_name = patch.display_name;
        }
        if patch.file_extensions.is_some() {
            self.file_extensions = patch.file_extensions;
        }
        if patch.file_names.is_some() {
            self.file_names = patch.file_names;
        }
        if patch.file_name_prefixes.is_some() {
            self.file_name_prefixes = patch.file_name_prefixes;
        }
        if patch.capabilities.is_some() {
            self.capabilities = patch.capabilities;
        }
        if patch.activation_policy.is_some() {
            self.activation_policy = patch.activation_policy;
        }
        if patch.language_id.is_some() {
            self.language_id = patch.language_id;
        }
        if patch.language_ids_by_extension.is_some() {
            self.language_ids_by_extension = patch.language_ids_by_extension;
        }
        if patch.language_ids_by_file_name.is_some() {
            self.language_ids_by_file_name = patch.language_ids_by_file_name;
        }
        if patch.language_server_launch.is_some() {
            self.language_server_launch = patch.language_server_launch;
        }
        self.disabled = patch.disabled;
    }
}

impl LspProviderDescriptor {
    fn from_patch(patch: LspProviderPatch) -> Self {
        let id = normalized_id(&patch.id);
        let display_name = patch
            .display_name
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| id.clone());
        let capabilities = patch.capabilities.unwrap_or_else(|| {
            vec![
                LspProviderCapability::LanguageServer,
                LspProviderCapability::Formatting,
            ]
        });
        Self {
            id: id.clone(),
            display_name,
            file_extensions: normalized_values(patch.file_extensions.unwrap_or_default(), true),
            file_names: normalized_values(patch.file_names.unwrap_or_default(), false),
            file_name_prefixes: normalized_values(
                patch.file_name_prefixes.unwrap_or_default(),
                false,
            ),
            capabilities,
            activation_policy: patch.activation_policy.unwrap_or_default(),
            language_id: patch.language_id.filter(|value| !value.trim().is_empty()),
            language_ids_by_extension: normalized_map(
                patch.language_ids_by_extension.unwrap_or_default(),
                true,
            ),
            language_ids_by_file_name: normalized_map(
                patch.language_ids_by_file_name.unwrap_or_default(),
                false,
            ),
            language_server_launch: patch.language_server_launch,
        }
    }
}

fn normalized_id(value: &str) -> String {
    value.trim().to_ascii_lowercase()
}

fn normalized_values(values: Vec<String>, trim_dot: bool) -> Vec<String> {
    let mut result = Vec::new();
    for value in values {
        let normalized = normalized_key(&value, trim_dot);
        if !normalized.is_empty() && !result.contains(&normalized) {
            result.push(normalized);
        }
    }
    result
}

fn normalized_map(values: BTreeMap<String, String>, trim_dot: bool) -> BTreeMap<String, String> {
    values
        .into_iter()
        .filter_map(|(key, value)| {
            let key = normalized_key(&key, trim_dot);
            if key.is_empty() || value.trim().is_empty() {
                None
            } else {
                Some((key, value))
            }
        })
        .collect()
}

fn normalized_key(value: &str, trim_dot: bool) -> String {
    let mut value = value.trim().to_ascii_lowercase();
    if trim_dot {
        value = value.trim_start_matches('.').to_string();
    }
    value
}

fn validate_file_path(value: &str) -> Result<(), CoreError> {
    if value.trim().is_empty() {
        Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "LSP builtin request requires a file path.",
        ))
    } else {
        Ok(())
    }
}

fn utf16_position_to_byte_offset(text: &str, position: LspPosition) -> Result<usize, CoreError> {
    if position.line < 0 || position.utf16_column < 0 {
        return Err(invalid_range_error());
    }
    let line = usize::try_from(position.line).map_err(|_| invalid_range_error())?;
    let column = usize::try_from(position.utf16_column).map_err(|_| invalid_range_error())?;
    let Some((start, contents_end)) = line_bounds(text, line) else {
        return Err(invalid_range_error());
    };
    Ok(byte_offset_for_utf16_column(
        text,
        start,
        contents_end,
        column,
    ))
}

fn invalid_range_error() -> CoreError {
    CoreError::new(
        ErrorCode::InvalidRequest,
        "Language server returned an invalid text range.",
    )
    .with_details("invalidRange")
}

fn line_bounds(text: &str, target_line: usize) -> Option<(usize, usize)> {
    let bytes = text.as_bytes();
    let mut line = 0;
    let mut start = 0;
    for (index, byte) in bytes.iter().enumerate() {
        if *byte == b'\n' {
            if line == target_line {
                let contents_end = if index > start && bytes[index - 1] == b'\r' {
                    index - 1
                } else {
                    index
                };
                return Some((start, contents_end));
            }
            line += 1;
            start = index + 1;
        }
    }
    if line == target_line {
        Some((start, text.len()))
    } else {
        None
    }
}

fn byte_offset_for_utf16_column(
    text: &str,
    start: usize,
    contents_end: usize,
    column: usize,
) -> usize {
    let mut units = 0;
    for (relative, character) in text[start..contents_end].char_indices() {
        let next_units = units + character.len_utf16();
        if next_units > column {
            return start + relative;
        }
        units = next_units;
        if units == column {
            return start + relative + character.len_utf8();
        }
    }
    contents_end
}

fn byte_offset_to_lsp_position(text: &str, offset: usize) -> LspPositionResponse {
    let offset = offset.min(text.len());
    let mut line = 0_i64;
    let mut column = 0_i64;
    for (index, character) in text.char_indices() {
        if index >= offset {
            break;
        }
        if character == '\n' {
            line += 1;
            column = 0;
        } else {
            column += character.len_utf16() as i64;
        }
    }
    LspPositionResponse {
        line,
        utf16_column: column,
    }
}

fn range_for_offsets(text: &str, start: usize, end: usize) -> LspRangeResponse {
    LspRangeResponse {
        start: byte_offset_to_lsp_position(text, start),
        end: byte_offset_to_lsp_position(text, end),
    }
}

fn identifier_occurrences(text: &str) -> Vec<IdentifierOccurrence> {
    let mut values = Vec::new();
    let mut current_start: Option<usize> = None;
    for (index, character) in text.char_indices() {
        if is_identifier_character(character) {
            if current_start.is_none() {
                current_start = Some(index);
            }
        } else if let Some(start) = current_start.take() {
            push_identifier(text, start, index, &mut values);
        }
    }
    if let Some(start) = current_start {
        push_identifier(text, start, text.len(), &mut values);
    }
    values
}

fn push_identifier(text: &str, start: usize, end: usize, values: &mut Vec<IdentifierOccurrence>) {
    let value = &text[start..end];
    if value.chars().next().is_some_and(is_identifier_start)
        && !is_language_keyword(value)
        && value.len() <= 120
    {
        values.push(IdentifierOccurrence {
            value: value.to_string(),
            start,
            end,
            range: range_for_offsets(text, start, end),
        });
    }
}

fn identifier_at(text: &str, cursor: usize) -> Option<IdentifierOccurrence> {
    identifier_occurrences(text)
        .into_iter()
        .find(|occurrence| occurrence.start <= cursor && cursor <= occurrence.end)
}

fn identifier_prefix_at(text: &str, cursor: usize) -> String {
    let mut start = cursor.min(text.len());
    while start > 0 {
        let Some((previous_index, previous)) = text[..start].char_indices().next_back() else {
            break;
        };
        if !is_identifier_character(previous) {
            break;
        }
        start = previous_index;
    }
    text[start..cursor.min(text.len())].to_string()
}

fn is_identifier_start(character: char) -> bool {
    character == '_' || character.is_alphabetic()
}

fn is_identifier_character(character: char) -> bool {
    character == '_' || character.is_alphanumeric()
}

fn is_language_keyword(value: &str) -> bool {
    matches!(
        value,
        "as" | "async"
            | "await"
            | "break"
            | "case"
            | "catch"
            | "class"
            | "const"
            | "continue"
            | "def"
            | "default"
            | "defer"
            | "do"
            | "else"
            | "enum"
            | "export"
            | "extends"
            | "false"
            | "final"
            | "fn"
            | "for"
            | "func"
            | "function"
            | "if"
            | "impl"
            | "import"
            | "in"
            | "interface"
            | "let"
            | "match"
            | "mod"
            | "mut"
            | "nil"
            | "null"
            | "package"
            | "private"
            | "protected"
            | "public"
            | "return"
            | "self"
            | "static"
            | "struct"
            | "switch"
            | "this"
            | "throw"
            | "throws"
            | "trait"
            | "true"
            | "try"
            | "type"
            | "var"
            | "while"
    )
}

fn builtin_completion_kind(text: &str, start: usize) -> i32 {
    if looks_like_declaration_with_keywords(
        text,
        start,
        &["class", "struct", "enum", "interface", "trait"],
    ) {
        7
    } else if looks_like_declaration_with_keywords(text, start, &["func", "function", "def", "fn"])
    {
        3
    } else {
        6
    }
}

fn looks_like_declaration(text: &str, start: usize) -> bool {
    looks_like_declaration_with_keywords(
        text,
        start,
        &[
            "class",
            "struct",
            "enum",
            "interface",
            "trait",
            "func",
            "function",
            "def",
            "fn",
            "let",
            "var",
            "const",
            "type",
        ],
    )
}

fn looks_like_declaration_with_keywords(text: &str, start: usize, keywords: &[&str]) -> bool {
    let line_start = text[..start].rfind('\n').map_or(0, |index| index + 1);
    let prefix = &text[line_start..start];
    let tokens: Vec<&str> = prefix
        .split(|character: char| !is_identifier_character(character))
        .filter(|token| !token.is_empty())
        .collect();
    tokens
        .last()
        .is_some_and(|token| keywords.iter().any(|keyword| keyword == token))
}

fn snippet_plain_text(value: &str) -> String {
    let mut output = String::new();
    let mut chars = value.chars().peekable();
    while let Some(character) = chars.next() {
        if character != '$' {
            output.push(character);
            continue;
        }
        match chars.peek().copied() {
            Some('{') => {
                chars.next();
                if !consume_digits(&mut chars) {
                    output.push_str("${");
                    continue;
                }
                match chars.peek().copied() {
                    Some(':') => {
                        chars.next();
                        output.push_str(&consume_until_placeholder_end(&mut chars));
                    }
                    Some('}') => {
                        chars.next();
                    }
                    _ => output.push('$'),
                }
            }
            Some(next) if next.is_ascii_digit() => {
                consume_digits(&mut chars);
            }
            _ => output.push('$'),
        }
    }
    output
}

fn consume_digits<I>(chars: &mut std::iter::Peekable<I>) -> bool
where
    I: Iterator<Item = char>,
{
    let mut consumed = false;
    while chars
        .peek()
        .is_some_and(|character| character.is_ascii_digit())
    {
        chars.next();
        consumed = true;
    }
    consumed
}

fn consume_until_placeholder_end<I>(chars: &mut std::iter::Peekable<I>) -> String
where
    I: Iterator<Item = char>,
{
    let mut value = String::new();
    for character in chars.by_ref() {
        if character == '}' {
            break;
        }
        value.push(character);
    }
    value
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temporary_root(label: &str) -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock should be valid")
            .as_nanos();
        std::env::temp_dir().join(format!("lithe-lsp-{label}-{}-{nonce}", std::process::id()))
    }

    #[test]
    fn builtin_catalog_describes_market_lsp_providers() {
        let catalog = provider_catalog(None);
        let ids: Vec<_> = catalog
            .providers
            .iter()
            .map(|provider| provider.id.as_str())
            .collect();
        assert!(ids.starts_with(&["java", "go", "python", "node", "rust"]));
        assert!(ids.contains(&"swift"));
        assert!(ids.contains(&"clangd"));
        assert!(ids.contains(&"dockerfile"));
        assert!(ids.contains(&"graphql"));
        let clangd = catalog
            .providers
            .iter()
            .find(|provider| provider.id == "clangd")
            .expect("clangd provider should exist");
        assert_eq!(
            clangd.language_ids_by_extension.get("m"),
            Some(&"objective-c".to_string())
        );
        let swift = catalog
            .providers
            .iter()
            .find(|provider| provider.id == "swift")
            .expect("swift provider should exist");
        let swift_launch = swift
            .language_server_launch
            .as_ref()
            .expect("swift launch descriptor should exist");
        assert_eq!(
            swift_launch.executable_names,
            vec!["sourcekit-lsp".to_string()]
        );
    }

    #[test]
    fn project_config_extends_and_overrides_builtin_catalog() {
        let root = temporary_root("project-config");
        fs::create_dir_all(root.join(".lithe/lsp")).unwrap();
        fs::write(
            root.join(".lithe/lsp/language-providers.json"),
            r#"{
              "version": 1,
              "providers": [
                {
                  "id": "roc",
                  "displayName": "Roc",
                  "fileExtensions": ["roc"],
                  "capabilities": ["languageServer", "formatting"],
                  "activationPolicy": "onDemand",
                  "languageId": "roc"
                },
                {
                  "id": "swift",
                  "fileExtensions": ["swift", "swiftinterface"],
                  "languageServerLaunch": {
                    "executableNames": ["custom-sourcekit-lsp"],
                    "arguments": ["--stdio"]
                  }
                },
                {
                  "id": "perl",
                  "disabled": true
                }
              ]
            }"#,
        )
        .unwrap();

        let catalog = provider_catalog(Some(&root));
        assert!(catalog
            .providers
            .iter()
            .any(|provider| provider.id == "roc"));
        let swift = catalog
            .providers
            .iter()
            .find(|provider| provider.id == "swift")
            .expect("swift provider should still exist");
        assert!(swift
            .file_extensions
            .contains(&"swiftinterface".to_string()));
        let swift_launch = swift
            .language_server_launch
            .as_ref()
            .expect("swift launch descriptor should be overridden");
        assert_eq!(
            swift_launch.executable_names,
            vec!["custom-sourcekit-lsp".to_string()]
        );
        assert_eq!(swift_launch.arguments, vec!["--stdio".to_string()]);
        assert!(!catalog
            .providers
            .iter()
            .any(|provider| provider.id == "perl"));

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn ffi_json_is_a_standalone_catalog_document() {
        let raw = provider_catalog_json(None);
        let value: Value = serde_json::from_str(&raw).expect("catalog should be JSON");
        assert_eq!(value["version"], 1);
        assert!(value["providers"].as_array().unwrap().len() > 10);
        assert!(value.get("ok").is_none());
        assert!(value.get("command").is_none());
    }

    #[test]
    fn text_edits_use_lsp_utf16_positions() {
        let response = apply_text_edits(ApplyTextEditsRequest {
            text: "one 😀\ntwo three\n".to_string(),
            edits: vec![
                LspTextEdit {
                    range: LspRange {
                        start: LspPosition {
                            line: 0,
                            utf16_column: 4,
                        },
                        end: LspPosition {
                            line: 0,
                            utf16_column: 6,
                        },
                    },
                    new_text: "rocket".to_string(),
                },
                LspTextEdit {
                    range: LspRange {
                        start: LspPosition {
                            line: 1,
                            utf16_column: 4,
                        },
                        end: LspPosition {
                            line: 1,
                            utf16_column: 9,
                        },
                    },
                    new_text: "four".to_string(),
                },
            ],
        })
        .unwrap();

        assert_eq!(response.text, "one rocket\ntwo four\n");
    }

    #[test]
    fn text_edits_reject_invalid_and_overlapping_ranges() {
        let invalid = apply_text_edits(ApplyTextEditsRequest {
            text: "one line".to_string(),
            edits: vec![LspTextEdit {
                range: LspRange {
                    start: LspPosition {
                        line: 9,
                        utf16_column: 0,
                    },
                    end: LspPosition {
                        line: 9,
                        utf16_column: 1,
                    },
                },
                new_text: "x".to_string(),
            }],
        })
        .unwrap_err();
        assert_eq!(invalid.details.as_deref(), Some("invalidRange"));

        let overlapping = apply_text_edits(ApplyTextEditsRequest {
            text: "one line".to_string(),
            edits: vec![
                LspTextEdit {
                    range: LspRange {
                        start: LspPosition {
                            line: 0,
                            utf16_column: 0,
                        },
                        end: LspPosition {
                            line: 0,
                            utf16_column: 4,
                        },
                    },
                    new_text: "a".to_string(),
                },
                LspTextEdit {
                    range: LspRange {
                        start: LspPosition {
                            line: 0,
                            utf16_column: 2,
                        },
                        end: LspPosition {
                            line: 0,
                            utf16_column: 6,
                        },
                    },
                    new_text: "b".to_string(),
                },
            ],
        })
        .unwrap_err();
        assert_eq!(overlapping.details.as_deref(), Some("overlappingEdits"));
    }

    #[test]
    fn snippet_plain_text_removes_tab_stops_and_keeps_defaults() {
        assert_eq!(snippet_plain_text("print(${1:value})$0"), "print(value)");
        assert_eq!(snippet_plain_text("${1:let} ${2:name} = $3"), "let name = ");
    }

    #[test]
    fn builtin_completion_returns_current_file_identifiers_for_prefix() {
        let response = builtin_completions(BuiltinRequest {
            file_path: "/tmp/main.swift".to_string(),
            text: "struct RocketShip {}\nlet rocketSpeed = Roc\n".to_string(),
            position: LspPosition {
                line: 1,
                utf16_column: 19,
            },
        })
        .unwrap();

        assert!(response.items.iter().any(|item| item.label == "RocketShip"));
        let item = response
            .items
            .iter()
            .find(|item| item.label == "RocketShip")
            .unwrap();
        assert_eq!(item.text_edit.range.start.utf16_column, 18);
        assert_eq!(item.text_edit.new_text, "RocketShip");
    }

    #[test]
    fn builtin_hover_returns_current_identifier_range() {
        let response = builtin_hover(BuiltinRequest {
            file_path: "/tmp/main.rs".to_string(),
            text: "fn launch() {}\n".to_string(),
            position: LspPosition {
                line: 0,
                utf16_column: 4,
            },
        })
        .unwrap();

        let hover = response.hover.unwrap();
        assert_eq!(hover.contents, "`launch`");
        assert_eq!(hover.range.start.utf16_column, 3);
        assert_eq!(hover.range.end.utf16_column, 9);
    }

    #[test]
    fn builtin_navigation_prefers_declarations_and_finds_references() {
        let text = "let service = 1\nprint(service)\n";
        let definitions = builtin_navigation(BuiltinNavigationRequest {
            file_path: "/tmp/main.swift".to_string(),
            text: text.to_string(),
            position: LspPosition {
                line: 1,
                utf16_column: 8,
            },
            method: "textDocument/definition".to_string(),
        })
        .unwrap();
        assert_eq!(definitions.locations.len(), 1);
        assert_eq!(definitions.locations[0].range.start.line, 0);
        assert_eq!(definitions.locations[0].range.start.utf16_column, 4);

        let references = builtin_navigation(BuiltinNavigationRequest {
            file_path: "/tmp/main.swift".to_string(),
            text: text.to_string(),
            position: LspPosition {
                line: 1,
                utf16_column: 8,
            },
            method: "textDocument/references".to_string(),
        })
        .unwrap();
        assert_eq!(references.locations.len(), 2);
    }

    #[test]
    fn client_core_initializes_and_applies_server_capabilities() {
        let initialized = client_initialize(ClientInitializeRequest {
            state: LspClientState::default(),
            root_uri: "file:///tmp/project".to_string(),
            process_id: Some(42),
        })
        .unwrap();
        assert_eq!(
            initialized.state.pending_requests.get("1").unwrap(),
            "initialize"
        );
        let initialize_message: Value =
            serde_json::from_str(&initialized.messages[0]).expect("initialize JSON");
        assert_eq!(initialize_message["method"], "initialize");
        assert_eq!(
            initialize_message["params"]["rootUri"],
            "file:///tmp/project"
        );

        let applied = client_apply_server_message(ClientApplyServerMessageRequest {
            state: initialized.state,
            message: r#"{
                "jsonrpc": "2.0",
                "id": "1",
                "result": {
                    "capabilities": {
                        "definitionProvider": true,
                        "hoverProvider": true,
                        "completionProvider": { "resolveProvider": true },
                        "codeActionProvider": { "resolveProvider": true }
                    }
                }
            }"#
            .to_string(),
        })
        .unwrap();

        assert!(applied.state.initialized);
        assert!(applied.state.pending_requests.is_empty());
        assert!(applied
            .state
            .server_capabilities
            .contains(&"definition".to_string()));
        assert!(applied
            .state
            .server_capabilities
            .contains(&"completionResolve".to_string()));
        assert_eq!(applied.messages.len(), 1);
        let initialized_notification: Value =
            serde_json::from_str(&applied.messages[0]).expect("initialized JSON");
        assert_eq!(initialized_notification["method"], "initialized");
    }

    #[test]
    fn client_core_tracks_documents_and_feature_requests() {
        let opened = client_open_document(ClientOpenDocumentRequest {
            state: LspClientState::default(),
            uri: "file:///tmp/project/main.rs".to_string(),
            language_id: "rust".to_string(),
            text: "fn main() {}\n".to_string(),
        })
        .unwrap();
        assert_eq!(
            opened
                .state
                .open_documents
                .get("file:///tmp/project/main.rs")
                .unwrap()
                .version,
            1
        );
        let did_open: Value = serde_json::from_str(&opened.messages[0]).unwrap();
        assert_eq!(did_open["method"], "textDocument/didOpen");

        let changed = client_change_document(ClientChangeDocumentRequest {
            state: opened.state,
            uri: "file:///tmp/project/main.rs".to_string(),
            text: "fn main() { launch(); }\n".to_string(),
        })
        .unwrap();
        assert_eq!(
            changed
                .state
                .open_documents
                .get("file:///tmp/project/main.rs")
                .unwrap()
                .version,
            2
        );
        let did_change: Value = serde_json::from_str(&changed.messages[0]).unwrap();
        assert_eq!(did_change["method"], "textDocument/didChange");

        let requested = client_feature_request(ClientFeatureRequest {
            state: changed.state,
            uri: "file:///tmp/project/main.rs".to_string(),
            method: "textDocument/definition".to_string(),
            position: Some(LspPosition {
                line: 0,
                utf16_column: 12,
            }),
            new_name: None,
            range: None,
            diagnostics: Vec::new(),
        })
        .unwrap();
        assert_eq!(
            requested.state.pending_requests.get("1").unwrap(),
            "textDocument/definition"
        );
        let request_message: Value = serde_json::from_str(&requested.messages[0]).unwrap();
        assert_eq!(request_message["method"], "textDocument/definition");
        assert_eq!(request_message["params"]["position"]["character"], 12);
    }

    #[test]
    fn client_core_shapes_feature_responses_for_swift_models() {
        let opened = client_open_document(ClientOpenDocumentRequest {
            state: LspClientState::default(),
            uri: "file:///tmp/project/main.rs".to_string(),
            language_id: "rust".to_string(),
            text: "fn main() { la }\n".to_string(),
        })
        .unwrap();
        let requested = client_feature_request(ClientFeatureRequest {
            state: opened.state,
            uri: "file:///tmp/project/main.rs".to_string(),
            method: "textDocument/completion".to_string(),
            position: Some(LspPosition {
                line: 0,
                utf16_column: 14,
            }),
            new_name: None,
            range: None,
            diagnostics: Vec::new(),
        })
        .unwrap();
        let completed = client_apply_server_message(ClientApplyServerMessageRequest {
            state: requested.state,
            message: r#"{
                "jsonrpc": "2.0",
                "id": "1",
                "result": {
                    "items": [{
                        "label": "launch",
                        "kind": 3,
                        "detail": "fn()",
                        "textEdit": {
                            "range": {
                                "start": { "line": 0, "character": 12 },
                                "end": { "line": 0, "character": 14 }
                            },
                            "newText": "launch"
                        }
                    }]
                }
            }"#
            .to_string(),
        })
        .unwrap();

        let result = completed.events[0].result.as_ref().unwrap();
        assert_eq!(result["items"][0]["label"], "launch");
        assert_eq!(
            result["items"][0]["textEdit"]["range"]["start"]["utf16Column"],
            12
        );

        let rename = client_feature_request(ClientFeatureRequest {
            state: completed.state,
            uri: "file:///tmp/project/main.rs".to_string(),
            method: "textDocument/rename".to_string(),
            position: Some(LspPosition {
                line: 0,
                utf16_column: 12,
            }),
            new_name: Some("start".to_string()),
            range: None,
            diagnostics: Vec::new(),
        })
        .unwrap();
        let renamed = client_apply_server_message(ClientApplyServerMessageRequest {
            state: rename.state,
            message: r#"{
                "jsonrpc": "2.0",
                "id": "2",
                "result": {
                    "changes": {
                        "file:///tmp/project/main.rs": [{
                            "range": {
                                "start": { "line": 0, "character": 12 },
                                "end": { "line": 0, "character": 18 }
                            },
                            "newText": "start"
                        }]
                    }
                }
            }"#
            .to_string(),
        })
        .unwrap();
        let rename_result = renamed.events[0].result.as_ref().unwrap();
        assert_eq!(
            rename_result["changes"]["/tmp/project/main.rs"][0]["newText"],
            "start"
        );

        let formatting = client_feature_request(ClientFeatureRequest {
            state: renamed.state,
            uri: "file:///tmp/project/main.rs".to_string(),
            method: "textDocument/formatting".to_string(),
            position: None,
            new_name: None,
            range: None,
            diagnostics: Vec::new(),
        })
        .unwrap();
        let formatted = client_apply_server_message(ClientApplyServerMessageRequest {
            state: formatting.state,
            message: r#"{
                "jsonrpc": "2.0",
                "id": "3",
                "result": [{
                    "range": {
                        "start": { "line": 0, "character": 2 },
                        "end": { "line": 0, "character": 2 }
                    },
                    "newText": " "
                }]
            }"#
            .to_string(),
        })
        .unwrap();
        let format_result = formatted.events[0].result.as_ref().unwrap();
        assert_eq!(
            format_result["edits"][0]["range"]["start"]["utf16Column"],
            2
        );

        let code_actions = client_feature_request(ClientFeatureRequest {
            state: formatted.state,
            uri: "file:///tmp/project/main.rs".to_string(),
            method: "textDocument/codeAction".to_string(),
            position: None,
            new_name: None,
            range: Some(LspRange {
                start: LspPosition {
                    line: 0,
                    utf16_column: 0,
                },
                end: LspPosition {
                    line: 0,
                    utf16_column: 0,
                },
            }),
            diagnostics: vec![LspClientDiagnostic {
                range: LspRangeResponse {
                    start: LspPositionResponse {
                        line: 0,
                        utf16_column: 12,
                    },
                    end: LspPositionResponse {
                        line: 0,
                        utf16_column: 18,
                    },
                },
                severity: Some(2),
                message: "rename suggestion".to_string(),
                source: Some("rust-analyzer".to_string()),
                code: None,
            }],
        })
        .unwrap();
        let code_action_request: Value = serde_json::from_str(&code_actions.messages[0]).unwrap();
        assert_eq!(code_action_request["method"], "textDocument/codeAction");
        assert_eq!(
            code_action_request["params"]["context"]["diagnostics"][0]["range"]["start"]
                ["character"],
            12
        );
        let code_actioned = client_apply_server_message(ClientApplyServerMessageRequest {
            state: code_actions.state,
            message: r#"{
                "jsonrpc": "2.0",
                "id": "4",
                "result": [{
                    "title": "Apply rename",
                    "kind": "quickfix",
                    "isPreferred": true,
                    "edit": {
                        "changes": {
                            "file:///tmp/project/main.rs": [{
                                "range": {
                                    "start": { "line": 0, "character": 12 },
                                    "end": { "line": 0, "character": 18 }
                                },
                                "newText": "start"
                            }]
                        }
                    },
                    "command": {
                        "title": "Apply",
                        "command": "rust-analyzer.applySourceChange",
                        "arguments": [{ "label": "rename" }]
                    },
                    "data": { "id": "action-1" }
                }]
            }"#
            .to_string(),
        })
        .unwrap();
        let action_result = code_actioned.events[0].result.as_ref().unwrap();
        assert_eq!(action_result["actions"][0]["title"], "Apply rename");
        assert_eq!(
            action_result["actions"][0]["edit"]["changes"]["/tmp/project/main.rs"][0]["newText"],
            "start"
        );
        assert_eq!(
            action_result["actions"][0]["command"]["command"],
            "rust-analyzer.applySourceChange"
        );
    }

    #[test]
    fn client_core_applies_diagnostics_and_dynamic_registrations() {
        let state = LspClientState::default();
        let diagnostics = client_apply_server_message(ClientApplyServerMessageRequest {
            state,
            message: r#"{
                "jsonrpc": "2.0",
                "method": "textDocument/publishDiagnostics",
                "params": {
                    "uri": "file:///tmp/project/main.py",
                    "diagnostics": [{
                        "range": {
                            "start": { "line": 2, "character": 4 },
                            "end": { "line": 2, "character": 9 }
                        },
                        "severity": 1,
                        "source": "pyright",
                        "code": "reportGeneralTypeIssues",
                        "message": "Example diagnostic"
                    }]
                }
            }"#
            .to_string(),
        })
        .unwrap();
        let stored = diagnostics
            .state
            .diagnostics
            .get("file:///tmp/project/main.py")
            .unwrap();
        assert_eq!(stored[0].message, "Example diagnostic");
        assert_eq!(stored[0].range.start.utf16_column, 4);
        assert_eq!(diagnostics.events[0].kind, "diagnostics");

        let registered = client_apply_server_message(ClientApplyServerMessageRequest {
            state: diagnostics.state,
            message: r#"{
                "jsonrpc": "2.0",
                "id": 77,
                "method": "client/registerCapability",
                "params": {
                    "registrations": [{
                        "id": "formatting",
                        "method": "textDocument/formatting",
                        "registerOptions": {}
                    }]
                }
            }"#
            .to_string(),
        })
        .unwrap();
        assert!(registered
            .state
            .server_capabilities
            .contains(&"formatting".to_string()));
        let response: Value = serde_json::from_str(&registered.messages[0]).unwrap();
        assert_eq!(response["id"], "77");
    }
}
