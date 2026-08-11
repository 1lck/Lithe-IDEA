use super::types::*;
use crate::protocol::{CoreError, ErrorCode};
use serde_json::{json, Value};

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
                    "synchronization": {},
                    "completion": {
                        "dynamicRegistration": true,
                        "completionItem": {
                            "snippetSupport": false,
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
                    "configuration": true,
                    "workspaceEdit": {
                        "documentChanges": true
                    },
                    "executeCommand": { "dynamicRegistration": true }
                },
                "window": {
                    "workDoneProgress": true
                }
            },
            "initializationOptions": request.initialization_options
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

pub fn client_close_document(
    request: ClientCloseDocumentRequest,
) -> Result<LspClientResponse, CoreError> {
    validate_uri(&request.uri)?;
    let mut state = request.state;
    let Some(document) = state.open_documents.remove(&request.uri) else {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Cannot close a document that is not open in the LSP client.",
        ));
    };
    let message = json_rpc_notification(
        "textDocument/didClose",
        json!({
            "textDocument": {
                "uri": document.uri
            }
        }),
    )?;
    Ok(client_response(state, vec![message], Vec::new()))
}

pub fn client_shutdown(request: ClientShutdownRequest) -> Result<LspClientResponse, CoreError> {
    let mut state = request.state;
    if state.shutdown_requested {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "LSP client shutdown has already been requested.",
        ));
    }
    let id = allocate_request(&mut state, "shutdown");
    state.shutdown_requested = true;
    let message = json_rpc_message_without_params(Some(&id), "shutdown")?;
    Ok(client_response(state, vec![message], Vec::new()))
}

pub(crate) fn client_feature_request_canonical(
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
        let request_id = message.get("id");
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
                if let Some(id) = request_id {
                    responses.push(json_rpc_result(id, Value::Null)?);
                }
            }
            "client/unregisterCapability" => {
                apply_dynamic_unregistration(&mut state, &message);
                if let Some(id) = request_id {
                    responses.push(json_rpc_result(id, Value::Null)?);
                }
            }
            "workspace/configuration" => {
                if let Some(id) = request_id {
                    let item_count = message
                        .get("params")
                        .and_then(|params| params.get("items"))
                        .and_then(Value::as_array)
                        .map_or(0, Vec::len);
                    responses.push(json_rpc_result(
                        id,
                        Value::Array(vec![Value::Null; item_count]),
                    )?);
                }
            }
            "workspace/workspaceFolders" | "window/workDoneProgress/create" => {
                if let Some(id) = request_id {
                    responses.push(json_rpc_result(id, Value::Null)?);
                }
            }
            _ => {
                if let Some(id) = request_id {
                    responses.push(json_rpc_error(id, -32601, "Method not found")?);
                } else {
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
        if pending.as_deref() == Some("shutdown") {
            state.initialized = false;
            state.shutdown_requested = false;
            state.server_capabilities.clear();
            state.open_documents.clear();
            state.diagnostics.clear();
            responses.push(json_rpc_message_without_params(None, "exit")?);
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

fn json_rpc_message_without_params(id: Option<&str>, method: &str) -> Result<String, CoreError> {
    let mut message = json!({
        "jsonrpc": "2.0",
        "method": method
    });
    if let Some(id) = id {
        message["id"] = Value::String(id.to_string());
    }
    encode_json_rpc(message)
}

fn json_rpc_result(id: &Value, result: Value) -> Result<String, CoreError> {
    encode_json_rpc(json!({
        "jsonrpc": "2.0",
        "id": id,
        "result": result
    }))
}

fn json_rpc_error(id: &Value, code: i64, message: &str) -> Result<String, CoreError> {
    encode_json_rpc(json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": {
            "code": code,
            "message": message
        }
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
        "completionItem/resolve" => request.completion_item.clone().ok_or_else(|| {
            CoreError::new(
                ErrorCode::InvalidRequest,
                "This LSP request requires a completion item.",
            )
        }),
        "codeAction/resolve" => request.code_action.clone().ok_or_else(|| {
            CoreError::new(
                ErrorCode::InvalidRequest,
                "This LSP request requires a code action.",
            )
        }),
        "workspace/executeCommand" => request.command.clone().ok_or_else(|| {
            CoreError::new(
                ErrorCode::InvalidRequest,
                "This LSP request requires a command.",
            )
        }),
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
        Some("completionItem/resolve") => parse_completion_item(result).map(|item| {
            json!({
                "item": item
            })
        }),
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
        Some("codeAction/resolve") => parse_code_action(result).map(|action| {
            json!({
                "action": action
            })
        }),
        Some("workspace/executeCommand") => Some(json!({ "ok": true })),
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
        .filter_map(|item| parse_completion_item(item))
        .collect()
}

fn parse_completion_item(item: &Value) -> Option<Value> {
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
    values.iter().filter_map(parse_code_action).collect()
}

fn parse_code_action(action: &Value) -> Option<Value> {
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

pub(crate) fn file_path_from_uri(uri: &str) -> String {
    let path = uri.strip_prefix("file://").unwrap_or(uri);
    let mut decoded = Vec::with_capacity(path.len());
    let bytes = path.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            if let (Some(high), Some(low)) =
                (hex_value(bytes[index + 1]), hex_value(bytes[index + 2]))
            {
                decoded.push((high << 4) | low);
                index += 3;
                continue;
            }
        }
        decoded.push(bytes[index]);
        index += 1;
    }
    String::from_utf8(decoded).unwrap_or_else(|_| path.to_string())
}

fn hex_value(value: u8) -> Option<u8> {
    match value {
        b'0'..=b'9' => Some(value - b'0'),
        b'a'..=b'f' => Some(value - b'a' + 10),
        b'A'..=b'F' => Some(value - b'A' + 10),
        _ => None,
    }
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
