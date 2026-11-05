//! Editor language-feature providers a plugin backend registers through
//! `lithe/host/editor/registerProviders`.
//!
//! Core validates registrations and the LSP 3.17 shaped results of each
//! provider function, and owns the per-type answer budgets. Hosts own the
//! document versions, the calls and the merge with language-server results:
//! a language server answers first and a plugin only supplements it. Core
//! never interprets selectors, function names or result payloads beyond
//! their shape, so no tool or language has a branch here.

use super::editor_actions::{normalize_names, uri, Location, LspPosition, LspRange};
use crate::lsp::interface::plugin_function::is_function_id;
use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::BTreeSet;

/// Provider types Core can validate, in the order the contract lists them.
pub const PROVIDER_TYPES: &[&str] = &[
    "definition",
    "hover",
    "completion",
    "codeLens",
    "foldingRange",
    "semanticTokens",
    "documentLink",
];

const MAX_BYTES: usize = 1024 * 1024;
const MAX_SELECTOR_ENTRIES: usize = 32;
const MAX_TRIGGER_CHARACTERS: usize = 16;
const MAX_LEGEND_ENTRIES: usize = 64;
const MAX_LOCATIONS: usize = 100;
const MAX_COMPLETION_ITEMS: usize = 5000;
const MAX_CODE_LENSES: usize = 1000;
const MAX_FOLDING_RANGES: usize = 5000;
const MAX_DOCUMENT_LINKS: usize = 1000;
const MAX_HOVER_BYTES: usize = 64 * 1024;
/// Semantic token integers: five per token, 1 MiB of 4-byte integers.
const MAX_SEMANTIC_TOKEN_INTEGERS: usize = 1024 * 1024 / 4;
const MAX_TEXT_CHARS: usize = 4096;

/// How long the host waits for one provider answer, in milliseconds. A late
/// answer is dropped, like one for an older document version.
fn budget_ms(kind: &str) -> u64 {
    match kind {
        "hover" | "completion" => 400,
        "definition" => 1500,
        _ => 2000,
    }
}

fn invalid(message: impl Into<String>) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, message)
}

fn identifier(value: &str) -> bool {
    !value.is_empty() && value.len() <= 128 && !value.chars().any(char::is_control)
}

fn bounded(value: &str) -> bool {
    value.chars().count() <= MAX_TEXT_CHARS
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Selector {
    #[serde(default)]
    languages: Vec<String>,
    #[serde(default)]
    file_extensions: Vec<String>,
    #[serde(default)]
    file_names: Vec<String>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Legend {
    token_types: Vec<String>,
    #[serde(default)]
    token_modifiers: Vec<String>,
}

/// One provider entry: the plugin function the host calls and the options
/// its type takes. `budgetMs` is Core's output, never the plugin's input.
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Provider {
    function: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    trigger_characters: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    legend: Option<Legend>,
    #[serde(default, skip_deserializing)]
    budget_ms: u64,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Registration {
    id: String,
    selector: Selector,
    providers: Map<String, Value>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Payload {
    kind: String,
    value: Value,
    /// Provider types the host routes; a registration naming another type
    /// is refused as an unsupported option.
    #[serde(default)]
    types: Vec<String>,
    /// For `kind: result`, the provider type that answered.
    #[serde(default, rename = "type")]
    provider_type: Option<String>,
    /// For a semantic tokens result, the legend the provider registered.
    #[serde(default)]
    legend: Option<Legend>,
}

fn registration(value: Value, types: &[String]) -> Result<Value, CoreError> {
    if types.is_empty()
        || types
            .iter()
            .any(|kind| !PROVIDER_TYPES.contains(&kind.as_str()))
    {
        return Err(invalid("Invalid host provider types."));
    }
    let mut item: Registration = serde_json::from_value(value).map_err(|_| {
        invalid("An editor provider registration needs id, selector and providers.")
    })?;
    let selector = &mut item.selector;
    if !identifier(&item.id)
        || selector.languages.len() + selector.file_extensions.len() + selector.file_names.len()
            > MAX_SELECTOR_ENTRIES
        || selector.languages.is_empty()
            && selector.file_extensions.is_empty()
            && selector.file_names.is_empty()
        || !selector.languages.iter().all(|language| {
            identifier(language) && !language.contains(['/', '\\', '*', '?', ':', ' '])
        })
    {
        return Err(invalid(
            "An editor provider registration has an id and 1 to 32 literal selector entries.",
        ));
    }
    // The contract matches every selector entry case-insensitively, so the
    // host only ever compares lowercased language IDs.
    for language in selector.languages.iter_mut() {
        *language = language.to_lowercase();
    }
    selector.languages.sort();
    selector.languages.dedup();
    normalize_names(&mut selector.file_extensions, &mut selector.file_names)?;
    if item.providers.is_empty() {
        return Err(invalid("An editor provider registration names a provider."));
    }
    let mut providers = Map::new();
    for (kind, value) in std::mem::take(&mut item.providers) {
        if !types.contains(&kind) {
            return Err(CoreError::new(
                ErrorCode::NotSupported,
                "The host does not route this editor provider type.",
            )
            .with_details(format!("providers.{kind}")));
        }
        let mut provider: Provider = serde_json::from_value(value)
            .map_err(|_| invalid(format!("Invalid {kind} provider.")))?;
        let triggers: BTreeSet<&String> = provider.trigger_characters.iter().collect();
        let options_fit = match kind.as_str() {
            "completion" => {
                provider.legend.is_none()
                    && provider.trigger_characters.len() <= MAX_TRIGGER_CHARACTERS
                    && triggers.len() == provider.trigger_characters.len()
                    && provider.trigger_characters.iter().all(|character| {
                        character.chars().count() == 1
                            && !character
                                .chars()
                                .any(|c| c.is_control() || c.is_whitespace())
                    })
            }
            "semanticTokens" => {
                provider.trigger_characters.is_empty()
                    && provider.legend.as_ref().is_some_and(legend_valid)
            }
            _ => provider.trigger_characters.is_empty() && provider.legend.is_none(),
        };
        if !is_function_id(&provider.function) || !options_fit {
            return Err(invalid(format!("Invalid {kind} provider options.")));
        }
        provider.budget_ms = budget_ms(&kind);
        let provider = serde_json::to_value(provider)
            .map_err(|_| invalid("Cannot encode editor provider."))?;
        providers.insert(kind, provider);
    }
    item.providers = providers;
    serde_json::to_value(item).map_err(|_| invalid("Cannot encode editor provider registration."))
}

fn legend_valid(legend: &Legend) -> bool {
    let names = |list: &[String]| {
        list.len() <= MAX_LEGEND_ENTRIES
            && list.iter().collect::<BTreeSet<_>>().len() == list.len()
            && list.iter().all(|name| {
                !name.is_empty()
                    && name.len() <= 64
                    && name
                        .chars()
                        .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '.')
            })
    };
    !legend.token_types.is_empty() && names(&legend.token_types) && names(&legend.token_modifiers)
}

fn range(value: &Value) -> Option<Value> {
    let range: LspRange = serde_json::from_value(value.clone()).ok()?;
    range.ordered().then(|| json!(range))
}

fn string<'a>(item: &'a Value, key: &str) -> Option<&'a str> {
    item.get(key).and_then(Value::as_str)
}

/// `null`, a `Location`, a `Location[]` or a `LocationLink[]`, normalized
/// to `{ locations }` (a link becomes its target selection).
fn definition(value: Value) -> Result<Value, CoreError> {
    let items = match value {
        Value::Null => Vec::new(),
        Value::Array(items) => items,
        item => vec![item],
    };
    if items.len() > MAX_LOCATIONS {
        return Err(invalid("A definition result has at most 100 locations."));
    }
    let mut locations = Vec::with_capacity(items.len());
    for item in items {
        let location = if item.get("targetUri").is_some() {
            json!({"uri": item["targetUri"], "range": item.get("targetSelectionRange").unwrap_or(&item["targetRange"])})
        } else {
            item
        };
        let location: Location = serde_json::from_value(location)
            .ok()
            .filter(Location::valid)
            .ok_or_else(|| invalid("Invalid definition location."))?;
        locations.push(location);
    }
    Ok(json!({ "locations": locations }))
}

/// `null` or a `Hover`, normalized to `{ contents: [{ kind, value }], range? }`.
fn hover(value: Value) -> Result<Value, CoreError> {
    if value.is_null() {
        return Ok(json!({ "contents": [] }));
    }
    let failure = || invalid("Invalid hover result.");
    let contents = value.get("contents").ok_or_else(failure)?;
    let parts: Vec<&Value> = match contents {
        Value::Array(parts) => parts.iter().collect(),
        part => vec![part],
    };
    let mut normalized = Vec::with_capacity(parts.len());
    let mut bytes = 0;
    for part in parts {
        let (kind, text) = match part {
            Value::String(text) => ("markdown", text.clone()),
            part => match (
                string(part, "kind"),
                string(part, "language"),
                string(part, "value"),
            ) {
                (Some(kind @ ("markdown" | "plaintext")), None, Some(text)) => {
                    (kind, text.to_string())
                }
                // A MarkedString with a language is a fenced code block.
                (None, Some(language), Some(text))
                    if identifier(language) && !language.contains('`') =>
                {
                    ("markdown", format!("```{language}\n{text}\n```"))
                }
                _ => return Err(failure()),
            },
        };
        bytes += text.len();
        normalized.push(json!({ "kind": kind, "value": text }));
    }
    if bytes > MAX_HOVER_BYTES {
        return Err(invalid("A hover result exceeds 64 KiB."));
    }
    let mut result = json!({ "contents": normalized });
    if let Some(value) = value.get("range") {
        result["range"] = range(value).ok_or_else(failure)?;
    }
    Ok(result)
}

fn text_edit(value: &Value) -> Option<Value> {
    let new_text = string(value, "newText").filter(|text| text.len() <= MAX_BYTES)?;
    if let Some(edit_range) = value.get("range") {
        return Some(json!({ "range": range(edit_range)?, "newText": new_text }));
    }
    Some(json!({
        "newText": new_text,
        "insert": range(value.get("insert")?)?,
        "replace": range(value.get("replace")?)?,
    }))
}

fn documentation(value: &Value) -> Option<Value> {
    match value {
        Value::String(text) => bounded(text).then(|| json!({ "kind": "plaintext", "value": text })),
        part => match (string(part, "kind"), string(part, "value")) {
            (Some(kind @ ("markdown" | "plaintext")), Some(value))
                if value.len() <= MAX_HOVER_BYTES =>
            {
                Some(json!({ "kind": kind, "value": value }))
            }
            _ => None,
        },
    }
}

/// `null`, a `CompletionItem[]` or a `CompletionList`, normalized to
/// `{ isIncomplete, items }`. Only presentation and edit fields are kept:
/// there is no resolve round trip and no command.
fn completion(value: Value) -> Result<Value, CoreError> {
    let (incomplete, items) = match value {
        Value::Null => (false, Vec::new()),
        Value::Array(items) => (false, items),
        Value::Object(mut list) => (
            list.get("isIncomplete")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            match list.remove("items") {
                Some(Value::Array(items)) => items,
                _ => return Err(invalid("A completion list has items.")),
            },
        ),
        _ => return Err(invalid("Invalid completion result.")),
    };
    if items.len() > MAX_COMPLETION_ITEMS {
        return Err(invalid("A completion result has at most 5000 items."));
    }
    let mut normalized = Vec::with_capacity(items.len());
    for item in &items {
        let label = string(item, "label")
            .filter(|label| !label.is_empty() && bounded(label))
            .ok_or_else(|| invalid("A completion item has a label."))?;
        let mut entry = json!({ "label": label });
        for key in ["detail", "sortText", "filterText"] {
            if let Some(value) = item.get(key) {
                let value = value.as_str().filter(|value| bounded(value));
                entry[key] =
                    json!(value.ok_or_else(|| invalid(format!("Invalid completion {key}.")))?);
            }
        }
        if let Some(value) = item.get("insertText") {
            let value = value.as_str().filter(|value| value.len() <= MAX_BYTES);
            entry["insertText"] =
                json!(value.ok_or_else(|| invalid("Invalid completion insertText."))?);
        }
        if let Some(details) = item.get("labelDetails") {
            let mut normalized = Map::new();
            for key in ["detail", "description"] {
                if let Some(value) = details.get(key) {
                    let value = value.as_str().filter(|value| bounded(value));
                    normalized.insert(
                        key.into(),
                        json!(value.ok_or_else(|| invalid("Invalid completion labelDetails."))?),
                    );
                }
            }
            entry["labelDetails"] = Value::Object(normalized);
        }
        if let Some(kind) = item.get("kind") {
            entry["kind"] = json!(kind
                .as_u64()
                .filter(|kind| (1..=25).contains(kind))
                .ok_or_else(|| invalid("Invalid completion kind."))?);
        }
        if let Some(format) = item.get("insertTextFormat") {
            entry["insertTextFormat"] = json!(format
                .as_u64()
                .filter(|format| matches!(format, 1 | 2))
                .ok_or_else(|| invalid("Invalid completion insertTextFormat."))?);
        }
        if let Some(tags) = item.get("tags") {
            let tags = tags
                .as_array()
                .filter(|tags| tags.iter().all(|tag| tag.as_u64() == Some(1)));
            entry["tags"] = json!(tags.ok_or_else(|| invalid("Invalid completion tags."))?);
        }
        if let Some(value) = item.get("documentation") {
            entry["documentation"] =
                documentation(value).ok_or_else(|| invalid("Invalid completion documentation."))?;
        }
        if let Some(value) = item.get("textEdit") {
            entry["textEdit"] =
                text_edit(value).ok_or_else(|| invalid("Invalid completion textEdit."))?;
        }
        if let Some(edits) = item.get("additionalTextEdits") {
            let edits = edits
                .as_array()
                .filter(|edits| edits.len() <= 100)
                .and_then(|edits| {
                    edits
                        .iter()
                        .map(|edit| text_edit(edit).filter(|edit| edit.get("range").is_some()))
                        .collect::<Option<Vec<_>>>()
                });
            entry["additionalTextEdits"] =
                json!(edits.ok_or_else(|| invalid("Invalid completion additionalTextEdits."))?);
        }
        if let Some(characters) = item.get("commitCharacters") {
            let characters = characters.as_array().filter(|list| {
                list.len() <= MAX_TRIGGER_CHARACTERS
                    && list
                        .iter()
                        .all(|c| c.as_str().is_some_and(|c| c.chars().count() == 1))
            });
            entry["commitCharacters"] =
                json!(characters.ok_or_else(|| invalid("Invalid completion commitCharacters."))?);
        }
        normalized.push(entry);
    }
    Ok(json!({ "isIncomplete": incomplete, "items": normalized }))
}

/// `null` or a `CodeLens[]`. Every lens carries its `command`: `command` is
/// a function of the registering plugin and `arguments` holds at most one
/// params object for it.
fn code_lens(value: Value) -> Result<Value, CoreError> {
    let items = list(value, MAX_CODE_LENSES, "code lens")?;
    let mut lenses = Vec::with_capacity(items.len());
    for item in &items {
        let failure =
            || invalid("A code lens has a range and a command { title, command, arguments? }.");
        let command = item.get("command").ok_or_else(failure)?;
        let title = string(command, "title")
            .filter(|title| {
                !title.trim().is_empty()
                    && title.chars().count() <= 200
                    && !title.chars().any(char::is_control)
            })
            .ok_or_else(failure)?;
        let function = string(command, "command")
            .filter(|id| is_function_id(id))
            .ok_or_else(failure)?;
        let params = match command.get("arguments") {
            None => json!({}),
            Some(Value::Array(arguments)) if arguments.is_empty() => json!({}),
            Some(Value::Array(arguments)) if arguments.len() == 1 && arguments[0].is_object() => {
                arguments[0].clone()
            }
            _ => return Err(failure()),
        };
        let lens_range = item.get("range").and_then(range).ok_or_else(failure)?;
        lenses.push(json!({ "range": lens_range, "command": { "title": title, "command": function, "arguments": [params] } }));
    }
    Ok(json!({ "lenses": lenses }))
}

fn folding_range(value: Value) -> Result<Value, CoreError> {
    let items = list(value, MAX_FOLDING_RANGES, "folding range")?;
    let mut ranges = Vec::with_capacity(items.len());
    for item in &items {
        let failure = || invalid("A folding range has startLine <= endLine.");
        let line = |key: &str| {
            item.get(key)
                .map(|value| value.as_u64().filter(|n| *n <= u64::from(u32::MAX)))
        };
        let (Some(Some(start)), Some(Some(end))) = (line("startLine"), line("endLine")) else {
            return Err(failure());
        };
        if start > end {
            return Err(failure());
        }
        let mut entry = json!({ "startLine": start, "endLine": end });
        if let Some(kind) = item.get("kind") {
            entry["kind"] = json!(kind
                .as_str()
                .filter(|kind| identifier(kind))
                .ok_or_else(failure)?);
        }
        ranges.push(entry);
    }
    Ok(json!({ "ranges": ranges }))
}

fn semantic_tokens(value: Value, legend: Option<&Legend>) -> Result<Value, CoreError> {
    let legend = legend.ok_or_else(|| invalid("A semantic tokens result needs its legend."))?;
    if value.is_null() {
        return Ok(json!({ "data": [] }));
    }
    let failure = || invalid("Invalid semantic tokens data.");
    let data = value
        .get("data")
        .and_then(Value::as_array)
        .ok_or_else(failure)?;
    if data.len() % 5 != 0 || data.len() > MAX_SEMANTIC_TOKEN_INTEGERS {
        return Err(failure());
    }
    let mut integers = Vec::with_capacity(data.len());
    for (index, value) in data.iter().enumerate() {
        let value = value
            .as_u64()
            .filter(|n| *n <= u64::from(u32::MAX))
            .ok_or_else(failure)?;
        let valid = match index % 5 {
            3 => (value as usize) < legend.token_types.len(),
            4 => legend.token_modifiers.len() >= 32 || value >> legend.token_modifiers.len() == 0,
            _ => true,
        };
        if !valid {
            return Err(failure());
        }
        integers.push(value);
    }
    Ok(json!({ "data": integers }))
}

fn document_link(value: Value) -> Result<Value, CoreError> {
    let items = list(value, MAX_DOCUMENT_LINKS, "document link")?;
    let mut links = Vec::with_capacity(items.len());
    for item in &items {
        let failure = || invalid("A document link has a range and an absolute target URI.");
        let target = string(item, "target")
            .filter(|target| uri(target))
            .ok_or_else(failure)?;
        let mut entry = json!({ "range": item.get("range").and_then(range).ok_or_else(failure)?, "target": target });
        if let Some(tooltip) = item.get("tooltip") {
            entry["tooltip"] = json!(tooltip
                .as_str()
                .filter(|value| bounded(value))
                .ok_or_else(failure)?);
        }
        links.push(entry);
    }
    Ok(json!({ "links": links }))
}

fn list(value: Value, limit: usize, what: &str) -> Result<Vec<Value>, CoreError> {
    match value {
        Value::Null => Ok(Vec::new()),
        Value::Array(items) if items.len() <= limit => Ok(items),
        Value::Array(_) => Err(invalid(format!("A {what} result exceeds {limit} items."))),
        _ => Err(invalid(format!("A {what} result is an array."))),
    }
}

/// The inputs of the definition merge: the requested place and the two
/// answers, each a list of validated locations.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DefinitionMerge {
    document_uri: String,
    position: LspPosition,
    #[serde(default)]
    server: Vec<Location>,
    #[serde(default)]
    plugin: Vec<Location>,
}

/// Merges the language server's definitions with the plugins' as the
/// indices each side keeps. The server's answer comes first and plugins only
/// add to it: a plugin location that repeats one already kept is dropped, and
/// a server location that is the requested place itself (the caret already
/// sits on the declaration) yields when a plugin answered.
fn merge_definitions(value: Value) -> Result<Value, CoreError> {
    let merge: DefinitionMerge = serde_json::from_value(value)
        .map_err(|_| invalid("A definition merge has documentUri, position, server and plugin."))?;
    let places = merge.server.iter().chain(merge.plugin.iter());
    if !uri(&merge.document_uri)
        || merge.server.len() > MAX_LOCATIONS
        || merge.plugin.len() > MAX_LOCATIONS
        || !places.into_iter().all(Location::valid)
    {
        return Err(invalid("Invalid definition merge."));
    }
    let own_place = |location: &Location| {
        location.uri == merge.document_uri
            && location.range.start <= merge.position
            && merge.position < location.range.end
    };
    let yields = !merge.plugin.is_empty();
    let server: Vec<usize> = (0..merge.server.len())
        .filter(|&index| !(yields && own_place(&merge.server[index])))
        .collect();
    let mut plugin: Vec<usize> = Vec::new();
    for (index, location) in merge.plugin.iter().enumerate() {
        let repeats = server.iter().any(|&kept| merge.server[kept] == *location)
            || plugin.iter().any(|&kept| merge.plugin[kept] == *location);
        if !repeats {
            plugin.push(index);
        }
    }
    Ok(json!({ "server": server, "plugin": plugin }))
}

/// Validates a provider registration (`kind: registration`, with the
/// host's `types`) or one provider function's result (`kind: result`, with
/// its `type` and, for semantic tokens, the registered `legend`). Results
/// come back normalized. `kind: mergeDefinitions` applies the merge rule of
/// definitions. No I/O occurs.
pub fn decode_command(payload: Value) -> Result<Value, CoreError> {
    let payload: Payload = serde_json::from_value(payload)
        .map_err(|_| invalid("Invalid editor provider validation payload."))?;
    if payload.value.to_string().len() > MAX_BYTES {
        return Err(invalid("Editor provider data exceeds 1 MiB."));
    }
    match (payload.kind.as_str(), payload.provider_type.as_deref()) {
        ("registration", None) => {
            Ok(json!({ "registration": registration(payload.value, &payload.types)? }))
        }
        ("mergeDefinitions", None) => merge_definitions(payload.value),
        ("result", Some(kind)) => Ok(json!({ "result": match kind {
            "definition" => definition(payload.value)?,
            "hover" => hover(payload.value)?,
            "completion" => completion(payload.value)?,
            "codeLens" => code_lens(payload.value)?,
            "foldingRange" => folding_range(payload.value)?,
            "semanticTokens" => semantic_tokens(payload.value, payload.legend.as_ref())?,
            "documentLink" => document_link(payload.value)?,
            _ => return Err(invalid("Unknown editor provider type.")),
        }})),
        _ => Err(invalid("Unknown editor provider validation kind.")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn types() -> Vec<&'static str> {
        PROVIDER_TYPES.to_vec()
    }

    #[test]
    fn registrations_normalize_selectors_and_report_budgets() {
        // A second tool: resource-key navigation in `.properties` and template files.
        let decoded = decode_command(json!({"kind":"registration","types":types(),"value":{
            "id":"keys","selector":{"languages":["HTML","html"],"fileExtensions":[".Properties"],"fileNames":["Messages"]},
            "providers":{"definition":{"function":"keys.definition"},
                "completion":{"function":"keys.complete","triggerCharacters":["."]},
                "semanticTokens":{"function":"keys.tokens","legend":{"tokenTypes":["property"],"tokenModifiers":["declaration"]}}}
        }})).unwrap();
        let registration = &decoded["registration"];
        assert_eq!(registration["selector"]["languages"], json!(["html"]));
        assert_eq!(
            registration["selector"]["fileExtensions"],
            json!(["properties"])
        );
        assert_eq!(registration["selector"]["fileNames"], json!(["messages"]));
        assert_eq!(
            registration["providers"]["completion"]["budgetMs"],
            json!(400)
        );
        assert_eq!(
            registration["providers"]["definition"]["budgetMs"],
            json!(1500)
        );
        assert_eq!(
            registration["providers"]["semanticTokens"]["legend"]["tokenTypes"],
            json!(["property"])
        );
    }

    #[test]
    fn unknown_or_unrouted_types_are_unsupported_options() {
        for providers in [
            json!({"diagnostics":{"function":"keys.check"}}),
            json!({"hover":{"function":"keys.hover"}}),
        ] {
            let error = decode_command(
                json!({"kind":"registration","types":["definition"],"value":{
                "id":"keys","selector":{"fileExtensions":["properties"]},"providers":providers}}),
            )
            .unwrap_err();
            assert!(matches!(error.code, ErrorCode::NotSupported));
            assert!(error.details.unwrap().starts_with("providers."));
        }
    }

    #[test]
    fn registrations_reject_wrong_options_and_empty_selectors() {
        for value in [
            json!({"id":"k","selector":{},"providers":{"hover":{"function":"keys.hover"}}}),
            json!({"id":"k","selector":{"languages":["a/b"]},"providers":{"hover":{"function":"keys.hover"}}}),
            json!({"id":"k","selector":{"fileExtensions":["x"]},"providers":{}}),
            json!({"id":"k","selector":{"fileExtensions":["x"]},"providers":{"hover":{"function":"keys.hover","triggerCharacters":["."]}}}),
            json!({"id":"k","selector":{"fileExtensions":["x"]},"providers":{"completion":{"function":"keys.complete","triggerCharacters":["ab"]}}}),
            json!({"id":"k","selector":{"fileExtensions":["x"]},"providers":{"semanticTokens":{"function":"keys.tokens"}}}),
            json!({"id":"k","selector":{"fileExtensions":["x"]},"providers":{"hover":{"function":"keys.hover","budgetMs":10}}}),
        ] {
            assert!(
                decode_command(json!({"kind":"registration","types":types(),"value":value}))
                    .is_err()
            );
        }
    }

    fn place(uri: &str, line: u32, from: u32, to: u32) -> Value {
        json!({"uri":uri,"range":{"start":{"line":line,"character":from},"end":{"line":line,"character":to}}})
    }

    fn merged(server: Vec<Value>, plugin: Vec<Value>, line: u32, character: u32) -> Value {
        decode_command(json!({"kind":"mergeDefinitions","value":{
            "documentUri":"file:///work/app.go","position":{"line":line,"character":character},
            "server":server,"plugin":plugin}}))
        .unwrap()
    }

    #[test]
    fn definition_merge_keeps_the_server_first_and_dedupes() {
        let kept = merged(
            vec![place("file:///work/a.go", 1, 0, 3)],
            vec![
                place("file:///work/a.go", 1, 0, 3),
                place("file:///work/b.go", 2, 0, 3),
            ],
            9,
            9,
        );
        assert_eq!(kept, json!({"server":[0],"plugin":[1]}));
    }

    #[test]
    fn definition_merge_yields_a_server_self_location_to_plugins() {
        let own = place("file:///work/app.go", 4, 2, 8);
        let kept = merged(
            vec![own.clone()],
            vec![place("file:///work/b.go", 2, 0, 3)],
            4,
            5,
        );
        assert_eq!(kept, json!({"server":[],"plugin":[0]}));
        // Without a plugin answer the server's answer stands, and an end bound is exclusive.
        assert_eq!(
            merged(vec![own.clone()], vec![], 4, 5),
            json!({"server":[0],"plugin":[]})
        );
        assert_eq!(
            merged(vec![own], vec![place("file:///work/b.go", 2, 0, 3)], 4, 8),
            json!({"server":[0],"plugin":[0]})
        );
    }

    #[test]
    fn definition_merge_rejects_invalid_locations() {
        for value in [
            json!({"documentUri":"file:///work/app.go","position":{"line":0,"character":0},
                "server":[{"uri":"","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}}]}),
            json!({"documentUri":"file:///work/app.go","position":{"line":0,"character":0},"extra":1}),
            json!({"documentUri":"","position":{"line":0,"character":0}}),
        ] {
            assert!(decode_command(json!({"kind":"mergeDefinitions","value":value})).is_err());
        }
    }

    fn result(kind: &str, value: Value) -> Result<Value, CoreError> {
        decode_command(json!({"kind":"result","type":kind,"value":value,
            "legend":{"tokenTypes":["property","string"],"tokenModifiers":["declaration"]}}))
        .map(|value| value["result"].clone())
    }

    #[test]
    fn results_normalize_lsp_shapes() {
        let span = json!({"start":{"line":1,"character":2},"end":{"line":1,"character":8}});
        let link = json!({"targetUri":"file:///w/messages.properties","targetRange":span,"targetSelectionRange":span});
        assert_eq!(
            result("definition", json!([link])).unwrap()["locations"][0]["uri"],
            "file:///w/messages.properties"
        );
        assert_eq!(
            result("definition", Value::Null).unwrap(),
            json!({"locations":[]})
        );
        let hover = result(
            "hover",
            json!({"contents":[{"language":"properties","value":"a=b"},"plain"]}),
        )
        .unwrap();
        assert_eq!(hover["contents"][0]["value"], "```properties\na=b\n```");
        let completion = result("completion", json!({"isIncomplete":true,"items":[
            {"label":"app.title","kind":10,"data":{"private":1},"command":{"title":"x","command":"y"},
             "textEdit":{"newText":"app.title","insert":span,"replace":span}}]})).unwrap();
        assert_eq!(completion["isIncomplete"], true);
        assert!(
            completion["items"][0].get("data").is_none()
                && completion["items"][0].get("command").is_none()
        );
        let lenses = result("codeLens", json!([{"range":span,"command":{"title":"3 usages","command":"keys.usages","arguments":[{"key":"app.title"}]}}])).unwrap();
        assert_eq!(
            lenses["lenses"][0]["command"]["arguments"],
            json!([{"key":"app.title"}])
        );
        assert_eq!(
            result(
                "foldingRange",
                json!([{"startLine":0,"endLine":3,"kind":"region"}])
            )
            .unwrap()["ranges"][0]["endLine"],
            3
        );
        assert_eq!(
            result("semanticTokens", json!({"resultId":"1","data":[0,0,3,1,1]})).unwrap(),
            json!({"data":[0,0,3,1,1]})
        );
        assert_eq!(
            result(
                "documentLink",
                json!([{"range":span,"target":"https://example.com/keys"}])
            )
            .unwrap()["links"][0]["target"],
            "https://example.com/keys"
        );
    }

    #[test]
    fn results_outside_their_limits_are_rejected_whole() {
        let span = json!({"start":{"line":2,"character":0},"end":{"line":1,"character":0}});
        let lens = json!({"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"command":{"title":"Run","command":"keys.run"}});
        for (kind, value) in [
            ("definition", json!([{"uri":"file:///a","range":span}])),
            (
                "definition",
                json!(vec![
                    json!({"uri":"file:///a","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}}});
                    101
                ]),
            ),
            ("hover", json!({"contents":"x".repeat(MAX_HOVER_BYTES + 1)})),
            (
                "completion",
                json!(vec![json!({"label":"a"}); MAX_COMPLETION_ITEMS + 1]),
            ),
            ("completion", json!([{"label":"a","kind":26}])),
            (
                "codeLens",
                json!([{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}}}]),
            ),
            (
                "codeLens",
                json!([lens.clone(), {"range":lens["range"],"command":{"title":"Run","command":"keys.run","arguments":[1,2]}}]),
            ),
            ("foldingRange", json!([{"startLine":4,"endLine":1}])),
            ("semanticTokens", json!({"data":[0,0,3,2,0]})),
            ("semanticTokens", json!({"data":[0,0,3,0,2]})),
            ("semanticTokens", json!({"data":[0,0,3]})),
            (
                "documentLink",
                json!([{"range":lens["range"],"target":"relative"}]),
            ),
            ("documentLink", json!([{"range":lens["range"]}])),
            ("signatureHelp", json!(null)),
        ] {
            assert!(result(kind, value.clone()).is_err(), "{kind}: {value}");
        }
    }

    /// The shared contract fixture. Registration failures name the host
    /// code they become: Core's `not_supported` is `unsupportedOption`
    /// with `details.option`, any other refusal is `invalidParams`.
    #[test]
    fn contract_fixture_cases() {
        let fixture: Value = serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/contracts/plugins/v1/fixtures/editor/editor-providers.json"
        )))
        .unwrap();
        let types = &fixture["host"]["providerTypes"];
        assert_eq!(types, &json!(PROVIDER_TYPES));
        for case in fixture["registrations"].as_array().unwrap() {
            let name = case["name"].as_str().unwrap();
            let decoded =
                decode_command(json!({"kind":"registration","types":types,"value":case["params"]}));
            let expected = &case["expected"];
            match (expected["status"].as_str().unwrap(), decoded) {
                ("accepted", Ok(decoded)) => {
                    assert_eq!(decoded["registration"], expected["registration"], "{name}")
                }
                ("rejected", Err(error)) => {
                    let unsupported = matches!(error.code, ErrorCode::NotSupported);
                    let code = if unsupported {
                        "plugin.host.unsupportedOption"
                    } else {
                        "plugin.host.invalidParams"
                    };
                    assert_eq!(expected["code"], code, "{name}");
                    let details = error.details.map(|option| json!({ "option": option }));
                    assert_eq!(expected.get("details"), details.as_ref(), "{name}");
                }
                (status, decoded) => panic!("{name}: expected {status}, got {decoded:?}"),
            }
        }
        for case in fixture["results"].as_array().unwrap() {
            let name = case["name"].as_str().unwrap();
            let mut payload = json!({"kind":"result","type":case["type"],"value":case["value"]});
            if let Some(legend) = case.get("legend") {
                payload["legend"] = legend.clone();
            }
            let decoded = decode_command(payload);
            match case["expected"]["status"].as_str().unwrap() {
                "accepted" => assert_eq!(
                    decoded.unwrap_or_else(|error| panic!("{name}: {error:?}"))["result"],
                    case["expected"]["value"],
                    "{name}"
                ),
                _ => assert!(decoded.is_err(), "{name}"),
            }
        }
    }
}
