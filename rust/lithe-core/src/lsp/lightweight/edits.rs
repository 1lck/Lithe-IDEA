use crate::lsp::interface::{LspPosition, LspPositionResponse, LspRange, LspRangeResponse};
use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};

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

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TextResponse {
    pub text: String,
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

pub(super) fn range_for_offsets(text: &str, start: usize, end: usize) -> LspRangeResponse {
    LspRangeResponse {
        start: byte_offset_to_lsp_position(text, start),
        end: byte_offset_to_lsp_position(text, end),
    }
}
