//! Translation between SourceKit-LSP extensions and the generic LSP model.

use crate::lsp::interface::ClientFeatureRequest;
use serde_json::{json, Value};

pub(crate) fn adapt_feature_request(mut request: ClientFeatureRequest) -> ClientFeatureRequest {
    request.completion_item = request
        .completion_item
        .as_ref()
        .map(swift_completion_item_to_lsp);
    request.code_action = request.code_action.as_ref().map(swift_code_action_to_lsp);
    request.command = request.command.as_ref().and_then(swift_command_to_lsp);
    request
}

pub(crate) fn swift_completion_item_to_lsp(item: &Value) -> Value {
    let mut object = serde_json::Map::new();
    copy_string_field(item, &mut object, "label");
    copy_string_field(item, &mut object, "detail");
    copy_string_field(item, &mut object, "documentation");
    copy_string_field(item, &mut object, "insertText");
    copy_string_field(item, &mut object, "sortText");
    copy_string_field(item, &mut object, "filterText");
    if let Some(kind) = item.get("kind").and_then(Value::as_i64) {
        object.insert("kind".to_string(), json!(kind));
    }
    if let Some(edit) = item.get("textEdit").and_then(swift_text_edit_to_lsp) {
        object.insert("textEdit".to_string(), edit);
    }
    if let Some(edits) = item.get("additionalTextEdits").and_then(Value::as_array) {
        object.insert(
            "additionalTextEdits".to_string(),
            json!(edits
                .iter()
                .filter_map(swift_text_edit_to_lsp)
                .collect::<Vec<_>>()),
        );
    }
    if let Some(data) = item.get("data") {
        object.insert("data".to_string(), data.clone());
    }
    Value::Object(object)
}

pub(crate) fn swift_code_action_to_lsp(action: &Value) -> Value {
    let mut object = serde_json::Map::new();
    copy_string_field(action, &mut object, "title");
    copy_string_field(action, &mut object, "kind");
    if let Some(is_preferred) = action.get("isPreferred").and_then(Value::as_bool) {
        object.insert("isPreferred".to_string(), json!(is_preferred));
    }
    if let Some(edit) = action.get("edit").and_then(swift_workspace_edit_to_lsp) {
        object.insert("edit".to_string(), edit);
    }
    if let Some(command) = action.get("command").and_then(swift_command_to_lsp) {
        object.insert("command".to_string(), command);
    }
    if let Some(data) = action.get("data") {
        object.insert("data".to_string(), data.clone());
    }
    Value::Object(object)
}

fn swift_workspace_edit_to_lsp(value: &Value) -> Option<Value> {
    let changes = value.get("changes")?.as_object()?;
    let mut parsed_changes = serde_json::Map::new();
    for (path, edits) in changes {
        let uri = if path.starts_with("file://") {
            path.clone()
        } else {
            format!("file://{path}")
        };
        parsed_changes.insert(
            uri,
            json!(edits
                .as_array()
                .map(|values| values
                    .iter()
                    .filter_map(swift_text_edit_to_lsp)
                    .collect::<Vec<_>>())
                .unwrap_or_default()),
        );
    }
    Some(json!({ "changes": parsed_changes }))
}

pub(crate) fn swift_command_to_lsp(value: &Value) -> Option<Value> {
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

fn copy_string_field(source: &Value, target: &mut serde_json::Map<String, Value>, field: &str) {
    if let Some(value) = source.get(field).and_then(Value::as_str) {
        target.insert(field.to_string(), json!(value));
    }
}

fn swift_text_edit_to_lsp(value: &Value) -> Option<Value> {
    Some(json!({
        "range": swift_range_to_lsp(value.get("range")?)?,
        "newText": value.get("newText").and_then(Value::as_str).unwrap_or_default()
    }))
}

fn swift_range_to_lsp(value: &Value) -> Option<Value> {
    Some(json!({
        "start": swift_position_to_lsp(value.get("start")?)?,
        "end": swift_position_to_lsp(value.get("end")?)?
    }))
}

fn swift_position_to_lsp(value: &Value) -> Option<Value> {
    Some(json!({
        "line": value.get("line").and_then(Value::as_i64).unwrap_or(0),
        "character": value
            .get("utf16Column")
            .or_else(|| value.get("character"))
            .and_then(Value::as_i64)
            .unwrap_or(0)
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn completion_items_translate_swift_utf16_positions() {
        let item = json!({
            "label": "print",
            "data": { "token": 7 },
            "textEdit": {
                "range": {
                    "start": { "line": 2, "utf16Column": 3 },
                    "end": { "line": 2, "utf16Column": 5 }
                },
                "newText": "print()"
            }
        });

        let converted = swift_completion_item_to_lsp(&item);
        assert_eq!(converted["textEdit"]["range"]["start"]["character"], 3);
        assert_eq!(converted["textEdit"]["newText"], "print()");
        assert_eq!(converted["data"]["token"], 7);
    }

    #[test]
    fn code_actions_translate_workspace_paths_to_file_uris() {
        let action = json!({
            "title": "Apply fix",
            "edit": {
                "changes": {
                    "/tmp/main.swift": [{
                        "range": {
                            "start": { "line": 0, "utf16Column": 0 },
                            "end": { "line": 0, "utf16Column": 1 }
                        },
                        "newText": "x"
                    }]
                }
            }
        });

        let converted = swift_code_action_to_lsp(&action);
        assert!(converted["edit"]["changes"]["file:///tmp/main.swift"].is_array());
    }

    #[test]
    fn commands_require_a_command_identifier() {
        assert!(swift_command_to_lsp(&json!({ "title": "Missing" })).is_none());
    }
}
