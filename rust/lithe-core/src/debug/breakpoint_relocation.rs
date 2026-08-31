//! Deterministic source-breakpoint relocation across UTF-16 editor edits.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::protocol::{CoreError, ErrorCode};

use super::SourceBreakpoint;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// One native-editor replacement expressed in document-relative UTF-16 offsets.
pub struct DebugSourceEdit {
    /// Inclusive start offset in the source text before the edit.
    pub start_utf16_offset: usize,
    /// Exclusive end offset in the source text before the edit.
    pub end_utf16_offset: usize,
    /// Text inserted in place of the edited range.
    pub replacement: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Relocates requested breakpoints after one exact editor mutation.
pub struct RelocateBreakpointsRequest {
    /// Complete source text before the mutation.
    pub source: String,
    pub edit: DebugSourceEdit,
    #[serde(default)]
    pub breakpoints: Vec<SourceBreakpoint>,
}

#[derive(Debug, Clone, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
/// Stable breakpoint set after applying one source edit.
pub struct RelocateBreakpointsResult {
    pub breakpoints: Vec<SourceBreakpoint>,
}

/// Moves breakpoint anchors with inserted or removed source text.
pub fn relocate_breakpoints(
    request: RelocateBreakpointsRequest,
) -> Result<RelocateBreakpointsResult, CoreError> {
    let source_utf16_length = request.source.encode_utf16().count();
    if request.edit.start_utf16_offset > request.edit.end_utf16_offset
        || request.edit.end_utf16_offset > source_utf16_length
    {
        return Err(invalid_request(
            "Debug source edit offsets must form a valid UTF-16 range.",
        ));
    }

    let start_byte = byte_index_at_utf16_offset(&request.source, request.edit.start_utf16_offset)?;
    let end_byte = byte_index_at_utf16_offset(&request.source, request.edit.end_utf16_offset)?;
    let mut updated_source = String::with_capacity(
        request.source.len() - (end_byte - start_byte) + request.edit.replacement.len(),
    );
    updated_source.push_str(&request.source[..start_byte]);
    updated_source.push_str(&request.edit.replacement);
    updated_source.push_str(&request.source[end_byte..]);

    let replacement_utf16_length = request.edit.replacement.encode_utf16().count();
    let mut relocated = BTreeMap::new();
    for breakpoint in request.breakpoints {
        let anchor = breakpoint_anchor_utf16_offset(&request.source, &breakpoint)?;
        let anchor_was_replaced = request.edit.start_utf16_offset < request.edit.end_utf16_offset
            && anchor >= request.edit.start_utf16_offset
            && anchor < request.edit.end_utf16_offset;
        let relocated_anchor = relocate_anchor(
            anchor,
            request.edit.start_utf16_offset,
            request.edit.end_utf16_offset,
            replacement_utf16_length,
        );
        let (line, column) = position_at_utf16_offset(&updated_source, relocated_anchor)?;
        let relocated_breakpoint = SourceBreakpoint {
            line,
            column: breakpoint.column.map(|_| column),
            enabled: breakpoint.enabled,
            condition: breakpoint.condition,
            hit_condition: breakpoint.hit_condition,
            log_message: breakpoint.log_message,
        };
        let identity = (
            relocated_breakpoint.line,
            relocated_breakpoint.column.unwrap_or(0),
        );
        match relocated.get(&identity) {
            Some((existing_anchor_was_replaced, _))
                if !existing_anchor_was_replaced || anchor_was_replaced => {}
            _ => {
                // Preserve conditions and log settings from code that survived the edit
                // when a removed anchor collapses onto the same resulting position.
                relocated.insert(identity, (anchor_was_replaced, relocated_breakpoint));
            }
        }
    }
    Ok(RelocateBreakpointsResult {
        breakpoints: relocated
            .into_values()
            .map(|(_, breakpoint)| breakpoint)
            .collect(),
    })
}

fn breakpoint_anchor_utf16_offset(
    source: &str,
    breakpoint: &SourceBreakpoint,
) -> Result<usize, CoreError> {
    if breakpoint.line < 1 || breakpoint.column.is_some_and(|column| column < 1) {
        return Err(invalid_request(
            "Debug breakpoint line and column values must be one-based.",
        ));
    }
    let line_index = usize::try_from(breakpoint.line - 1)
        .map_err(|_| invalid_request("Debug breakpoint line is out of range."))?;
    let line_starts = line_start_utf16_offsets(source);
    let Some(&line_start) = line_starts.get(line_index) else {
        return Err(invalid_request("Debug breakpoint line is out of range."));
    };
    let line_end = line_starts
        .get(line_index + 1)
        .copied()
        .map(|offset| offset.saturating_sub(1))
        .unwrap_or_else(|| source.encode_utf16().count());
    let column = match breakpoint.column {
        Some(column) => usize::try_from(column - 1)
            .map_err(|_| invalid_request("Debug breakpoint column is out of range."))?,
        None => first_non_whitespace_utf16_column(source, line_start, line_end)?,
    };
    let anchor = line_start.saturating_add(column);
    if anchor > line_end {
        return Err(invalid_request("Debug breakpoint column is out of range."));
    }
    Ok(anchor)
}

fn first_non_whitespace_utf16_column(
    source: &str,
    line_start: usize,
    line_end: usize,
) -> Result<usize, CoreError> {
    let start_byte = byte_index_at_utf16_offset(source, line_start)?;
    let end_byte = byte_index_at_utf16_offset(source, line_end)?;
    let mut column = 0;
    for character in source[start_byte..end_byte].chars() {
        if !character.is_whitespace() {
            return Ok(column);
        }
        column += character.len_utf16();
    }
    Ok(0)
}

fn relocate_anchor(
    anchor: usize,
    edit_start: usize,
    edit_end: usize,
    replacement_length: usize,
) -> usize {
    if anchor < edit_start {
        return anchor;
    }
    if anchor > edit_end || (anchor == edit_end && edit_start != edit_end) {
        return anchor - (edit_end - edit_start) + replacement_length;
    }
    edit_start + replacement_length
}

fn line_start_utf16_offsets(source: &str) -> Vec<usize> {
    let mut values = vec![0];
    let mut offset = 0;
    for character in source.chars() {
        offset += character.len_utf16();
        if character == '\n' {
            values.push(offset);
        }
    }
    values
}

fn position_at_utf16_offset(source: &str, offset: usize) -> Result<(i64, i64), CoreError> {
    let source_length = source.encode_utf16().count();
    if offset > source_length {
        return Err(invalid_request(
            "Relocated debug breakpoint offset is outside the edited source.",
        ));
    }
    let line_starts = line_start_utf16_offsets(source);
    let line_index = line_starts.partition_point(|line_start| *line_start <= offset) - 1;
    let column = offset - line_starts[line_index];
    Ok(((line_index + 1) as i64, (column + 1) as i64))
}

fn byte_index_at_utf16_offset(source: &str, target: usize) -> Result<usize, CoreError> {
    let mut utf16_offset = 0;
    for (byte_offset, character) in source.char_indices() {
        if utf16_offset == target {
            return Ok(byte_offset);
        }
        utf16_offset += character.len_utf16();
        if utf16_offset > target {
            return Err(invalid_request(
                "Debug source edit offsets cannot split a UTF-16 surrogate pair.",
            ));
        }
    }
    if utf16_offset == target {
        return Ok(source.len());
    }
    Err(invalid_request(
        "Debug source edit offset is outside the source text.",
    ))
}

fn invalid_request(message: &str) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, message)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn breakpoint(line: i64) -> SourceBreakpoint {
        SourceBreakpoint {
            line,
            column: None,
            enabled: true,
            condition: Some("ready".to_string()),
            hit_condition: None,
            log_message: None,
        }
    }

    #[test]
    fn insertion_before_statement_moves_line_breakpoint_with_its_code() {
        let source = "class Main {\n    void run() {}\n}\n";
        let line_start = source.find("    void").unwrap();
        let result = relocate_breakpoints(RelocateBreakpointsRequest {
            source: source.to_string(),
            edit: DebugSourceEdit {
                start_utf16_offset: line_start,
                end_utf16_offset: line_start,
                replacement: "\n".to_string(),
            },
            breakpoints: vec![breakpoint(2)],
        })
        .unwrap();

        assert_eq!(result.breakpoints, vec![breakpoint(3)]);
    }

    #[test]
    fn editing_after_statement_anchor_keeps_breakpoint_on_its_line() {
        let source = "class Main {\n    void run() {}\n}\n";
        let edit_offset = source.find("run").unwrap() + "run".len();
        let result = relocate_breakpoints(RelocateBreakpointsRequest {
            source: source.to_string(),
            edit: DebugSourceEdit {
                start_utf16_offset: edit_offset,
                end_utf16_offset: edit_offset,
                replacement: "Now".to_string(),
            },
            breakpoints: vec![breakpoint(2)],
        })
        .unwrap();

        assert_eq!(result.breakpoints, vec![breakpoint(2)]);
    }

    #[test]
    fn deleting_preceding_lines_moves_breakpoint_up() {
        let source = "class Main {\n    int value;\n    void run() {}\n}\n";
        let deletion_start = source.find("    int").unwrap();
        let deletion_end = source.find("    void").unwrap();
        let result = relocate_breakpoints(RelocateBreakpointsRequest {
            source: source.to_string(),
            edit: DebugSourceEdit {
                start_utf16_offset: deletion_start,
                end_utf16_offset: deletion_end,
                replacement: String::new(),
            },
            breakpoints: vec![breakpoint(3)],
        })
        .unwrap();

        assert_eq!(result.breakpoints, vec![breakpoint(2)]);
    }

    #[test]
    fn utf16_offsets_preserve_columns_after_non_bmp_text() {
        let source = "class Main {\n    String icon = \"🚀\"; run();\n}\n";
        let anchor_byte = source.find("run").unwrap();
        let anchor_utf16 = source[..anchor_byte].encode_utf16().count();
        let mut expected = breakpoint(2);
        expected.column = Some(29);
        let result = relocate_breakpoints(RelocateBreakpointsRequest {
            source: source.to_string(),
            edit: DebugSourceEdit {
                start_utf16_offset: anchor_utf16,
                end_utf16_offset: anchor_utf16,
                replacement: "next".to_string(),
            },
            breakpoints: vec![SourceBreakpoint {
                line: 2,
                column: Some(25),
                ..breakpoint(2)
            }],
        })
        .unwrap();

        assert_eq!(result.breakpoints, vec![expected]);
    }

    #[test]
    fn breakpoints_that_collapse_to_one_location_are_deduplicated() {
        let source = "first();\nsecond();\n";
        let mut deleted_breakpoint = breakpoint(1);
        deleted_breakpoint.condition = Some("deleted".to_string());
        let mut surviving_breakpoint = breakpoint(2);
        surviving_breakpoint.condition = Some("surviving".to_string());
        let result = relocate_breakpoints(RelocateBreakpointsRequest {
            source: source.to_string(),
            edit: DebugSourceEdit {
                start_utf16_offset: 0,
                end_utf16_offset: "first();\n".len(),
                replacement: String::new(),
            },
            breakpoints: vec![deleted_breakpoint, surviving_breakpoint.clone()],
        })
        .unwrap();

        surviving_breakpoint.line = 1;
        assert_eq!(result.breakpoints, vec![surviving_breakpoint]);
    }

    #[test]
    fn edit_cannot_split_a_utf16_surrogate_pair() {
        let error = relocate_breakpoints(RelocateBreakpointsRequest {
            source: "🚀".to_string(),
            edit: DebugSourceEdit {
                start_utf16_offset: 1,
                end_utf16_offset: 1,
                replacement: String::new(),
            },
            breakpoints: vec![],
        })
        .unwrap_err();

        assert!(matches!(error.code, ErrorCode::InvalidRequest));
    }
}
