//! In-process document symbols, references, renames, and semantic-token helpers.

use super::edits::{range_for_offsets, utf16_position_to_byte_offset};
use crate::lsp::interface::{
    LspPosition, LspPositionResponse, LspRangeResponse, LspTextEditResponse,
};
use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Document and cursor used by lightweight completion or hover.
pub struct BuiltinRequest {
    pub file_path: String,
    pub text: String,
    pub position: LspPosition,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Document, cursor, and LSP method used by lightweight navigation.
pub struct BuiltinNavigationRequest {
    pub file_path: String,
    pub text: String,
    pub position: LspPosition,
    pub method: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Deterministically ordered completion candidates from the current document.
pub struct BuiltinCompletionResponse {
    pub items: Vec<BuiltinCompletionItem>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Completion candidate expressed in the normalized Core response shape.
pub struct BuiltinCompletionItem {
    pub label: String,
    pub insert_text: String,
    /// Numeric LSP `CompletionItemKind`, when the fallback can infer one.
    pub kind: Option<i32>,
    pub detail: Option<String>,
    pub text_edit: LspTextEditResponse,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Optional hover result for the identifier at the cursor.
pub struct BuiltinHoverResponse {
    pub hover: Option<BuiltinHover>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Lightweight hover contents and the identifier range they describe.
pub struct BuiltinHover {
    pub contents: String,
    pub is_markdown: bool,
    pub range: LspRangeResponse,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Locations found by the lightweight navigation fallback.
pub struct BuiltinNavigationResponse {
    pub locations: Vec<BuiltinLocation>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// One normalized navigation target.
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

/// Produces prefix-matching identifiers from the current document.
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

/// Returns a minimal hover for the identifier under the cursor.
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

/// Finds same-document definitions, implementations, or references.
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
