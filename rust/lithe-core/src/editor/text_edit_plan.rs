//! Plugin document edit planning (`editor.planTextEdits`).
//!
//! The host reads the live buffer and owns versions, undo grouping and the
//! editor surface; Core validates one-based plugin positions with the same
//! line index, ordering and overlap rules as `lsp.applyTextEdits`, and returns
//! UTF-16 offsets plus replacement text in the document's line ending.

use crate::lsp::{
    normalize_line_breaks, plan_replacements, EditRejection, EditRejectionReason, PositionPolicy,
    RawTextEdit, TextLineIndex,
};
use crate::protocol::{CoreError, ErrorCode};
use serde::Deserialize;
use serde_json::{json, Value};

/// One-based line and UTF-16 column, as the plugin editor API defines them.
#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(deny_unknown_fields)]
struct Position {
    line: u64,
    column: u64,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Range {
    start: Position,
    end: Position,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Edit {
    range: Range,
    text: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    text: String,
    #[serde(default)]
    edits: Vec<Edit>,
    /// Extra positions that must exist in `text`, such as reported selections.
    #[serde(default)]
    positions: Vec<Position>,
}

/// Converts a one-based plugin position to the zero-based pair the shared
/// planner resolves. Zero and values beyond `i64` are out of bounds.
fn zero_based(position: Position) -> (i64, i64) {
    let convert = |value: u64| {
        value
            .checked_sub(1)
            .and_then(|value| i64::try_from(value).ok())
            .unwrap_or(-1)
    };
    (convert(position.line), convert(position.column))
}

fn reason_name(reason: EditRejectionReason) -> &'static str {
    match reason {
        EditRejectionReason::RangeOutOfBounds => "rangeOutOfBounds",
        EditRejectionReason::Reversed => "reversed",
        EditRejectionReason::SplitsSurrogatePair => "splitsSurrogatePair",
        EditRejectionReason::OverlappingRanges => "overlappingRanges",
    }
}

/// Plans a plugin edit batch against the exact text it was based on.
///
/// Returns `{ lineEnding, lineSeparator, edits, rejection }`. `edits` is the
/// stable application order with `index`, `utf16Offset`, `utf16Length`,
/// `text` (line breaks in `lineSeparator`) and `normalizedText` (LF). When the
/// batch is invalid, `edits` is empty and `rejection` names the first fault
/// with `reason`, the caller-order `editIndex`/`otherEditIndex`, or
/// `positionIndex` for a failed extra position. An empty batch still reports
/// the document's line ending.
pub(crate) fn plan_command(payload: Value) -> Result<Value, CoreError> {
    let request: Request = serde_json::from_value(payload).map_err(|error| {
        CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid editor text edit plan request",
        )
        .with_details(error.to_string())
    })?;
    let index = TextLineIndex::new(&request.text);
    let line_ending = index.line_ending();
    let separator = index.insertion_separator();
    let respond = |edits: Vec<Value>, rejection: Value| {
        Ok(json!({
            "lineEnding": line_ending,
            "lineSeparator": separator,
            "edits": edits,
            "rejection": rejection,
        }))
    };

    for (position_index, position) in request.positions.iter().enumerate() {
        if let Err(reason) = index.resolve(zero_based(*position), PositionPolicy::Strict) {
            return respond(
                Vec::new(),
                json!({"reason": reason_name(reason), "positionIndex": position_index}),
            );
        }
    }

    let edits = request
        .edits
        .into_iter()
        .map(|edit| RawTextEdit {
            start: zero_based(edit.range.start),
            end: zero_based(edit.range.end),
            text: edit.text,
        })
        .collect();
    let planned = match plan_replacements(&index, edits, PositionPolicy::Strict) {
        Ok(planned) => planned,
        Err(EditRejection {
            reason,
            edit_index,
            other_edit_index,
        }) => {
            return respond(
                Vec::new(),
                json!({
                    "reason": reason_name(reason),
                    "editIndex": edit_index,
                    "otherEditIndex": other_edit_index,
                }),
            );
        }
    };

    // Offsets are ascending, so one forward walk converts every byte offset.
    let mut walked_bytes = 0;
    let mut walked_units = 0;
    let mut utf16_at = |byte: usize| {
        walked_units += request.text[walked_bytes..byte].encode_utf16().count();
        walked_bytes = byte;
        walked_units
    };
    let edits = planned
        .into_iter()
        .map(|edit| {
            let offset = utf16_at(edit.start);
            let end = utf16_at(edit.end);
            let normalized = normalize_line_breaks(&edit.text, "\n");
            let text = if separator == "\n" {
                normalized.clone()
            } else {
                normalized.replace('\n', separator)
            };
            json!({
                "index": edit.index,
                "utf16Offset": offset,
                "utf16Length": end - offset,
                "text": text,
                "normalizedText": normalized,
            })
        })
        .collect();
    respond(edits, Value::Null)
}
