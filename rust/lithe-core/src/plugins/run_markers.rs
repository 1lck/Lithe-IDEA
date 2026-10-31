//! Editor Run markers answered by a plugin, `runMarkers` 1.
//!
//! A plugin names, per language it declares, the backend function that lists
//! the runnable places of one document version and the UI command that runs
//! one of them. The host asks the function with the document text, passes the
//! raw answer to `plugins.declarative.decodeRunMarkers`, and draws what Core
//! returns in the gutter and editor context menu next to the built-in Java
//! markers. Running a marker sends the plugin its `commands/didRun` with a
//! `runMarker` describing the place, so the plugin executes it with its own
//! backend (an HTTP request, a script, a test) through APIs it already has.
//!
//! Neither the host nor Core parses source: the provider decides what is
//! runnable, in any language or custom format, which is the rule the Java
//! markers already follow with JDT.
//!
//! Note: the decision is recorded in .agents/notes/implemented/architecture/2026-10-31-plugin-grammars-and-run-markers.md

use super::declarative::{PluginRejection, Validation};
use crate::lsp::interface::plugin_function::is_function_id;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeSet;

/// Most markers in one document.
pub(crate) const MAX_MARKERS: usize = 1000;
/// Longest marker ID, in UTF-8 bytes.
pub(crate) const MAX_MARKER_ID_BYTES: usize = 256;
/// Longest marker title, in characters.
const MAX_TITLE_CHARS: usize = 200;
/// Largest provider answer, in UTF-8 JSON bytes.
const MAX_RESULT_BYTES: usize = 1024 * 1024;
/// `runMarkers[]`: one language's marker provider.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct RunMarkerProviderDeclaration {
    #[serde(rename = "languageID")]
    pub(crate) language_id: String,
    /// Backend function that lists the markers of a document version.
    pub(crate) function: String,
    /// `ui.commands[]` ID that runs one marker.
    pub(crate) command: String,
}

impl RunMarkerProviderDeclaration {
    pub(crate) fn validate(
        &self,
        field: &str,
        languages: &BTreeSet<&str>,
        commands: &BTreeSet<&str>,
    ) -> Validation<()> {
        let invalid = super::declarative::invalid;
        if !languages.contains(self.language_id.as_str()) {
            return Err(invalid(
                format!("{field}.languageID"),
                "Run markers are provided only for a language the plugin declares.",
            ));
        }
        if !is_function_id(&self.function) {
            return Err(invalid(
                format!("{field}.function"),
                "The provider is a backend function ID such as markers.list.",
            ));
        }
        if !commands.contains(self.command.as_str()) {
            return Err(invalid(
                format!("{field}.command"),
                "The command that runs a marker must be one of the plugin's ui.commands.",
            ));
        }
        Ok(())
    }
}

/// What a marker runs, for the gutter icon and the menu wording.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
enum MarkerKind {
    /// One runnable unit, such as a request or a script entry.
    Run,
    /// One test.
    Test,
    /// A group of tests, drawn with the run-all icon.
    TestSuite,
}

#[derive(Debug, Deserialize)]
struct RawMarker {
    id: Value,
    line: Value,
    #[serde(default, rename = "endLine")]
    end_line: Option<Value>,
    kind: Value,
    title: Value,
}

fn output_error(message: impl Into<String>) -> PluginRejection {
    PluginRejection::new("plugin.runMarkers.invalidOutput", message)
}

/// Validates a provider's `{ markers: [...] }` answer for a document of
/// `line_count` lines. Lines are one-based; `endLine` defaults to `line` and
/// is clamped to the document. Unknown fields are ignored; any malformed
/// marker, a duplicate ID or line, or an oversized list rejects the answer.
pub(crate) fn decode_markers(result: &Value, line_count: u64, command: &str) -> Validation<Value> {
    if serde_json::to_vec(result).map_or(true, |bytes| bytes.len() > MAX_RESULT_BYTES) {
        return Err(output_error("The run marker answer is larger than 1 MiB."));
    }
    let Some(markers) = result.get("markers").and_then(Value::as_array) else {
        return Err(output_error("The run marker answer is { markers: [...] }."));
    };
    if markers.len() > MAX_MARKERS {
        return Err(output_error("A document has at most 1000 run markers."));
    }
    let mut ids = BTreeSet::new();
    let mut lines = BTreeSet::new();
    let mut decoded = Vec::with_capacity(markers.len());
    for (index, marker) in markers.iter().enumerate() {
        let raw: RawMarker = serde_json::from_value(marker.clone()).map_err(|_| {
            output_error(format!(
                "Run marker {index} needs id, line, kind and title."
            ))
        })?;
        let id = raw
            .id
            .as_str()
            .filter(|id| {
                !id.is_empty()
                    && id.len() <= MAX_MARKER_ID_BYTES
                    && !id.chars().any(char::is_control)
            })
            .ok_or_else(|| {
                output_error(format!(
                    "Run marker {index} has an id of 1 to 256 bytes without control characters."
                ))
            })?;
        let line = raw
            .line
            .as_u64()
            .filter(|line| (1..=line_count).contains(line))
            .ok_or_else(|| output_error(format!("Run marker {index} is outside the document.")))?;
        let end_line = match raw.end_line {
            None | Some(Value::Null) => line,
            Some(value) => value
                .as_u64()
                .filter(|end| *end >= line)
                .ok_or_else(|| output_error(format!("Run marker {index} ends before it starts.")))?
                .min(line_count),
        };
        let kind: MarkerKind = serde_json::from_value(raw.kind).map_err(|_| {
            output_error(format!(
                "Run marker {index} has kind run, test, or testSuite."
            ))
        })?;
        let title = raw
            .title
            .as_str()
            .map(str::trim)
            .filter(|title| {
                !title.is_empty()
                    && title.chars().count() <= MAX_TITLE_CHARS
                    && !title.chars().any(char::is_control)
            })
            .ok_or_else(|| {
                output_error(format!(
                    "Run marker {index} has a title of 1 to 200 characters on one line."
                ))
            })?;
        if !ids.insert(id.to_string()) {
            return Err(output_error(format!("Run marker ID {id} appears twice.")));
        }
        if !lines.insert(line) {
            return Err(output_error(format!(
                "Line {line} has more than one run marker."
            )));
        }
        decoded.push((line, id.to_string(), end_line, kind, title.to_string()));
    }
    decoded.sort();
    Ok(Value::Array(
        decoded
            .into_iter()
            .map(|(line, id, end_line, kind, title)| {
                json!({
                    "id": id,
                    "line": line,
                    "endLine": end_line,
                    "kind": kind,
                    "title": title,
                    "command": command,
                })
            })
            .collect(),
    ))
}

/// Whether `value` is the `runMarker` of a `commands/didRun`:
/// `{ id, languageID, path, line, version }` with a workspace-relative path.
pub(crate) fn is_did_run_marker(value: &Value) -> bool {
    let Some(object) = value.as_object() else {
        return false;
    };
    object
        .keys()
        .all(|key| ["id", "languageID", "path", "line", "version"].contains(&key.as_str()))
        && object.get("id").and_then(Value::as_str).is_some_and(|id| {
            !id.is_empty() && id.len() <= MAX_MARKER_ID_BYTES && !id.chars().any(char::is_control)
        })
        && object
            .get("languageID")
            .and_then(Value::as_str)
            .is_some_and(|id| !id.is_empty() && id.len() <= 128)
        && object
            .get("path")
            .and_then(Value::as_str)
            .is_some_and(|path| {
                path.len() <= 4096 && super::declarative::is_safe_relative_path(path)
            })
        && object
            .get("line")
            .and_then(Value::as_u64)
            .is_some_and(|line| line >= 1)
        && object.get("version").is_some_and(Value::is_u64)
}
