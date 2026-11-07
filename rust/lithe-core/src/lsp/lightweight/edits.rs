//! UTF-16-aware text edit validation and application.

use crate::lsp::interface::{
    LspDocumentContentChange, LspPosition, LspPositionResponse, LspRange, LspRangeResponse,
};
use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Source text and LSP edits to validate and apply as one operation.
pub struct ApplyTextEditsRequest {
    pub text: String,
    #[serde(default)]
    pub edits: Vec<LspTextEdit>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Replacement expressed in LSP UTF-16 coordinates.
pub struct LspTextEdit {
    pub range: LspRange,
    pub new_text: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Text-only response shared by edit and snippet commands.
pub struct TextResponse {
    pub text: String,
}

/// Applies non-overlapping edits from the end of the document toward the start.
///
/// Validation and ordering are shared with `editor.planTextEdits` through
/// [`plan_replacements`]; only the position policy differs (LSP wire
/// semantics clamp a column past the line end and resolve a position inside a
/// surrogate pair to the character start).
pub fn apply_text_edits(request: ApplyTextEditsRequest) -> Result<TextResponse, CoreError> {
    let index = TextLineIndex::new(&request.text);
    let edits = request
        .edits
        .into_iter()
        .map(|edit| RawTextEdit {
            start: (edit.range.start.line, edit.range.start.utf16_column),
            end: (edit.range.end.line, edit.range.end.utf16_column),
            text: edit.new_text,
        })
        .collect();
    let replacements =
        plan_replacements(&index, edits, PositionPolicy::LspLenient).map_err(|rejection| {
            match rejection.reason {
                EditRejectionReason::OverlappingRanges => CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Language server returned overlapping text edits.",
                )
                .with_details("overlappingEdits"),
                _ => invalid_range_error(),
            }
        })?;

    let mut text = request.text;
    for replacement in replacements.into_iter().rev() {
        text.replace_range(replacement.start..replacement.end, &replacement.text);
    }
    Ok(TextResponse { text })
}

/// How a position that does not name an exact code-unit boundary is treated.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PositionPolicy {
    /// LSP wire semantics: a column past the line end clamps before the line
    /// terminator and a column inside a surrogate pair resolves to the start of
    /// that character. Missing and negative lines or columns are rejected.
    LspLenient,
    /// Plugin editor API semantics: every position must name an existing line,
    /// a column within that line's content and a code-unit boundary.
    Strict,
}

/// Zero-based line and UTF-16 column pair with the edit's replacement text.
pub(crate) struct RawTextEdit {
    pub start: (i64, i64),
    pub end: (i64, i64),
    pub text: String,
}

/// One validated replacement in byte offsets of the planned text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PlannedReplacement {
    /// Position of the edit in the caller's batch.
    pub index: usize,
    pub start: usize,
    pub end: usize,
    pub text: String,
}

/// Stable rejection classes for one edit batch.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum EditRejectionReason {
    /// A position names a line or column that does not exist.
    RangeOutOfBounds,
    /// `start` is after `end`.
    Reversed,
    /// A position falls between the two code units of a surrogate pair.
    SplitsSurrogatePair,
    /// Two edits overlap; zero-length insertions at a shared boundary do not.
    OverlappingRanges,
}

/// First rejection found in a batch, with indices in the caller's order.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct EditRejection {
    pub reason: EditRejectionReason,
    pub edit_index: usize,
    /// The lower-priority partner of an overlap; `None` for single-edit faults.
    pub other_edit_index: Option<usize>,
}

/// Line table of a text in byte offsets. `\r\n`, `\n` and a lone `\r` each
/// terminate one line, as the LSP specification and Monaco define them.
pub(crate) struct TextLineIndex<'a> {
    text: &'a str,
    line_starts: Vec<usize>,
    /// Byte offset just before each line's terminator (or the text end).
    content_ends: Vec<usize>,
    /// Distinct terminators in first-seen order.
    separators: Vec<&'static str>,
}

impl<'a> TextLineIndex<'a> {
    pub(crate) fn new(text: &'a str) -> Self {
        let bytes = text.as_bytes();
        let mut line_starts = vec![0];
        let mut content_ends = Vec::new();
        let mut separators: Vec<&'static str> = Vec::new();
        let mut index = 0;
        while index < bytes.len() {
            let separator = match bytes[index] {
                b'\r' if bytes.get(index + 1) == Some(&b'\n') => "\r\n",
                b'\r' => "\r",
                b'\n' => "\n",
                _ => {
                    index += 1;
                    continue;
                }
            };
            content_ends.push(index);
            index += separator.len();
            line_starts.push(index);
            if !separators.contains(&separator) {
                separators.push(separator);
            }
        }
        content_ends.push(bytes.len());
        Self {
            text,
            line_starts,
            content_ends,
            separators,
        }
    }

    /// Wire name of the document's line ending: `lf`, `crlf`, `cr` or `mixed`.
    /// A text without terminators reports `lf`.
    pub(crate) fn line_ending(&self) -> &'static str {
        match self.separators.as_slice() {
            [] | ["\n"] => "lf",
            ["\r\n"] => "crlf",
            ["\r"] => "cr",
            _ => "mixed",
        }
    }

    /// Separator written for inserted line breaks: the first one in the text,
    /// LF when there is none.
    pub(crate) fn insertion_separator(&self) -> &'static str {
        self.separators.first().copied().unwrap_or("\n")
    }

    /// Resolves a zero-based line and UTF-16 column to a byte offset.
    pub(crate) fn resolve(
        &self,
        (line, column): (i64, i64),
        policy: PositionPolicy,
    ) -> Result<usize, EditRejectionReason> {
        let (Ok(line), Ok(column)) = (usize::try_from(line), usize::try_from(column)) else {
            return Err(EditRejectionReason::RangeOutOfBounds);
        };
        let (Some(&start), Some(&contents_end)) =
            (self.line_starts.get(line), self.content_ends.get(line))
        else {
            return Err(EditRejectionReason::RangeOutOfBounds);
        };
        let mut units = 0;
        for (relative, character) in self.text[start..contents_end].char_indices() {
            if units == column {
                return Ok(start + relative);
            }
            let next_units = units + character.len_utf16();
            if next_units > column {
                return match policy {
                    PositionPolicy::LspLenient => Ok(start + relative),
                    PositionPolicy::Strict => Err(EditRejectionReason::SplitsSurrogatePair),
                };
            }
            units = next_units;
        }
        if units == column || policy == PositionPolicy::LspLenient {
            Ok(contents_end)
        } else {
            Err(EditRejectionReason::RangeOutOfBounds)
        }
    }
}

/// Validates a whole batch before anything is applied and returns it in a
/// stable application order: by start, then end, then the caller's order.
/// Zero-length insertions at the same position keep the caller's order, and an
/// insertion at a replaced range's boundary is adjacent rather than
/// overlapping, independent of where it appears in the batch.
pub(crate) fn plan_replacements(
    index: &TextLineIndex<'_>,
    edits: Vec<RawTextEdit>,
    policy: PositionPolicy,
) -> Result<Vec<PlannedReplacement>, EditRejection> {
    let mut planned = Vec::with_capacity(edits.len());
    for (position, edit) in edits.into_iter().enumerate() {
        let reject = |reason| EditRejection {
            reason,
            edit_index: position,
            other_edit_index: None,
        };
        let start = index.resolve(edit.start, policy).map_err(reject)?;
        let end = index.resolve(edit.end, policy).map_err(reject)?;
        if end < start {
            return Err(reject(EditRejectionReason::Reversed));
        }
        planned.push(PlannedReplacement {
            index: position,
            start,
            end,
            text: edit.text,
        });
    }
    planned.sort_by_key(|edit| (edit.start, edit.end, edit.index));
    for pair in planned.windows(2) {
        if pair[1].start < pair[0].end {
            return Err(EditRejection {
                reason: EditRejectionReason::OverlappingRanges,
                edit_index: pair[0].index.min(pair[1].index),
                other_edit_index: Some(pair[0].index.max(pair[1].index)),
            });
        }
    }
    Ok(planned)
}

/// Rewrites every `\r\n`, `\r` and `\n` in `text` as `separator`.
pub(crate) fn normalize_line_breaks(text: &str, separator: &str) -> String {
    if !text.contains(['\r', '\n']) {
        return text.to_string();
    }
    let mut result = String::with_capacity(text.len());
    let mut characters = text.chars().peekable();
    while let Some(character) = characters.next() {
        match character {
            '\r' => {
                if characters.peek() == Some(&'\n') {
                    characters.next();
                }
                result.push_str(separator);
            }
            '\n' => result.push_str(separator),
            other => result.push(other),
        }
    }
    result
}

/// Applies ranged content changes sequentially in the given order.
pub(crate) fn apply_content_changes_sequential(
    text: &str,
    changes: &[LspDocumentContentChange],
) -> Result<String, CoreError> {
    let mut text = text.to_string();
    for change in changes {
        let Some(range) = change.range else {
            text = change.text.clone();
            continue;
        };
        let start = utf16_position_to_byte_offset(&text, range.start)?;
        let end = utf16_position_to_byte_offset(&text, range.end)?;
        if end < start {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Language server returned an invalid text range.",
            )
            .with_details("invalidRange"));
        }
        text.replace_range(start..end, &change.text);
    }
    Ok(text)
}

pub(super) fn utf16_position_to_byte_offset(
    text: &str,
    position: LspPosition,
) -> Result<usize, CoreError> {
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

// Shares the terminator rule of `TextLineIndex` (`\r\n`, `\n`, lone `\r`)
// so document sync, lightweight symbols and edit planning count lines alike.
fn line_bounds(text: &str, target_line: usize) -> Option<(usize, usize)> {
    let bytes = text.as_bytes();
    let mut line = 0;
    let mut start = 0;
    let mut index = 0;
    while index < bytes.len() {
        let terminator = match bytes[index] {
            b'\r' if bytes.get(index + 1) == Some(&b'\n') => 2,
            b'\r' | b'\n' => 1,
            _ => {
                index += 1;
                continue;
            }
        };
        if line == target_line {
            return Some((start, index));
        }
        line += 1;
        index += terminator;
        start = index;
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
    let mut characters = text.char_indices().peekable();
    while let Some((index, character)) = characters.next() {
        if index >= offset {
            break;
        }
        let crlf = character == '\r' && characters.peek().is_some_and(|(_, next)| *next == '\n');
        if character == '\n' || (character == '\r' && !crlf) {
            line += 1;
            column = 0;
        } else if !crlf {
            column += character.len_utf16() as i64;
        }
    }
    LspPositionResponse {
        line,
        utf16_column: column,
    }
}

pub(super) fn range_for_offsets(text: &str, start: usize, end: usize) -> LspRangeResponse {
    LspRangeResponse {
        start: byte_offset_to_lsp_position(text, start),
        end: byte_offset_to_lsp_position(text, end),
    }
}
