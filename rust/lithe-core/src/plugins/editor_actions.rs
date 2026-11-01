//! Independent editor actions for tool plugins, not language/build/run providers.
//!
//! Core validates presentation and opaque function bindings. Plugin parsers own
//! their business facts; hosts own document versions, session leases and clicks.

use crate::lsp::interface::plugin_function::is_function_id;
use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeSet;

const MAX_ACTIONS: usize = 1000;
const MAX_BYTES: usize = 1024 * 1024;

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Registration {
    id: String,
    function: String,
    selector: Selector,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Selector {
    #[serde(default)]
    file_extensions: Vec<String>,
    #[serde(default)]
    file_names: Vec<String>,
}

#[derive(Debug, Deserialize, Serialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(deny_unknown_fields)]
struct Position {
    line: usize,
    column: usize,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Range {
    start: Position,
    end: Position,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Invocation {
    #[serde(rename = "functionID")]
    function_id: String,
    /// Plugin-private data: Core never interprets tool names or selectors.
    #[serde(default = "empty_params")]
    params: Value,
}

fn empty_params() -> Value {
    json!({})
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Action {
    id: String,
    range: Range,
    title: String,
    /// Presentation only; never identifies a Run/Test/Debug domain operation.
    icon: String,
    invoke: Invocation,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ResultList {
    actions: Vec<Action>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Payload {
    kind: String,
    value: Value,
    #[serde(default)]
    text: String,
}

fn invalid(message: impl Into<String>) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, message)
}

fn identifier(value: &str) -> bool {
    !value.is_empty() && value.len() <= 128 && !value.chars().any(char::is_control)
}

fn registration(value: Value) -> Result<Value, CoreError> {
    let mut item: Registration = serde_json::from_value(value)
        .map_err(|_| invalid("An editor action registration needs id, function and selector."))?;
    if !identifier(&item.id) || !is_function_id(&item.function) {
        return Err(invalid(
            "Invalid editor action registration or function ID.",
        ));
    }
    if item.selector.file_extensions.len() + item.selector.file_names.len() > 32
        || item.selector.file_extensions.is_empty() && item.selector.file_names.is_empty()
    {
        return Err(invalid(
            "An editor selector has 1 to 32 file names/extensions.",
        ));
    }
    for extension in &mut item.selector.file_extensions {
        *extension = extension.trim_start_matches('.').to_lowercase();
    }
    for name in &mut item.selector.file_names {
        *name = name.to_lowercase();
    }
    for name in item
        .selector
        .file_extensions
        .iter()
        .chain(&item.selector.file_names)
    {
        if !identifier(name) || name.contains(['/', '\\', '*', '?', ':']) {
            return Err(invalid(
                "An editor selector contains literal file names/extensions only.",
            ));
        }
    }
    item.selector.file_extensions.sort();
    item.selector.file_extensions.dedup();
    item.selector.file_names.sort();
    item.selector.file_names.dedup();
    serde_json::to_value(item).map_err(|_| invalid("Cannot encode editor registration."))
}

fn actions(value: Value, text: &str) -> Result<Value, CoreError> {
    let mut result: ResultList = serde_json::from_value(value)
        .map_err(|_| invalid("An editor action result is { actions: [...] }."))?;
    if result.actions.len() > MAX_ACTIONS || text.len() > 128 * 1024 {
        return Err(invalid(
            "The editor action result or document exceeds its limit.",
        ));
    }
    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    let lines: Vec<&str> = normalized.split('\n').collect();
    let valid_position = |position: &Position| {
        lines
            .get(position.line.wrapping_sub(1))
            .is_some_and(|line| {
                let line = line.strip_suffix('\r').unwrap_or(line);
                if position.column == 0 {
                    return false;
                }
                let target = position.column - 1;
                let mut offset = 0;
                for character in line.chars() {
                    if offset == target {
                        return true;
                    }
                    offset += character.len_utf16();
                }
                offset == target
            })
    };
    let mut ids = BTreeSet::new();
    for item in &result.actions {
        if !identifier(&item.id)
            || !ids.insert(&item.id)
            || item.title.trim().is_empty()
            || item.title.chars().count() > 200
            || item.title.chars().any(char::is_control)
            || !["run", "run-all"].contains(&item.icon.as_str())
            || !is_function_id(&item.invoke.function_id)
            || !item.invoke.params.is_object()
            || item.range.start > item.range.end
            || !valid_position(&item.range.start)
            || !valid_position(&item.range.end)
        {
            return Err(invalid(
                "Invalid editor action identity, range, presentation or invocation.",
            ));
        }
    }
    result
        .actions
        .sort_by(|a, b| a.range.start.cmp(&b.range.start).then(a.id.cmp(&b.id)));
    serde_json::to_value(result.actions).map_err(|_| invalid("Cannot encode editor actions."))
}

/// Validates an independent registration (`kind: registration`) or a parser
/// result (`kind: actions`, with its exact text). No I/O or tool parsing occurs.
pub fn decode_command(payload: Value) -> Result<Value, CoreError> {
    let payload: Payload = serde_json::from_value(payload)
        .map_err(|_| invalid("Invalid editor action validation payload."))?;
    if payload.value.to_string().len() > MAX_BYTES {
        return Err(invalid("Editor action data exceeds 1 MiB."));
    }
    match payload.kind.as_str() {
        "registration" => Ok(json!({"registration": registration(payload.value)?})),
        "actions" => Ok(json!({"actions": actions(payload.value, &payload.text)?})),
        _ => Err(invalid("Unknown editor action validation kind.")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn different_tools_share_registration_and_opaque_invocations() {
        for (extension, function) in [("http", "requests.send"), ("sql", "queries.execute")] {
            let registration = decode_command(json!({"kind":"registration", "value":{
                "id":"actions", "function":"actions.collect", "selector":{"fileExtensions":[extension]}
            }})).unwrap();
            assert_eq!(
                registration["registration"]["selector"]["fileExtensions"][0],
                extension
            );
            let result = decode_command(json!({"kind":"actions", "text":"hello\nworld", "value":{"actions":[{
                "id":"a", "range":{"start":{"line":1,"column":1},"end":{"line":2,"column":6}},
                "title":"Execute", "icon":"run", "invoke":{"functionID":function,"params":{"opaque":[1,2]}}
            }]}})).unwrap();
            assert_eq!(
                result["actions"][0]["invoke"]["params"]["opaque"],
                json!([1, 2])
            );
        }
    }

    #[test]
    fn invalid_ranges_and_duplicate_ids_reject_the_whole_result() {
        let item = json!({"id":"a","range":{"start":{"line":1,"column":1},"end":{"line":1,"column":3}},
            "title":"Execute","icon":"run","invoke":{"functionID":"action.execute","params":{}}});
        for (text, items) in [
            ("x", json!([item.clone()])),
            ("abc", json!([item.clone(), item])),
        ] {
            assert!(decode_command(
                json!({"kind":"actions","text":text,"value":{"actions":items}})
            )
            .is_err());
        }
        // Column 2 splits an astral character's UTF-16 surrogate pair.
        assert!(
            decode_command(json!({"kind":"actions","text":"😀","value":{"actions":[{
                "id":"a","range":{"start":{"line":1,"column":2},"end":{"line":1,"column":3}},
                "title":"Execute","icon":"run","invoke":{"functionID":"action.execute"}
            }]}}))
            .is_err()
        );
    }
}
