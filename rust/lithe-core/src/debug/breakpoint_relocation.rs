//! Deterministic source-breakpoint relocation across UTF-16 editor edits.

use std::collections::BTreeMap;
use std::sync::{Mutex, OnceLock};

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
    #[serde(default)]
    pub source: String,
    #[serde(default)]
    pub edit: Option<DebugSourceEdit>,
    /// Original-source edits, validated and applied together before projecting lines.
    #[serde(default)]
    pub edits: Vec<DebugSourceEdit>,
    /// Optional ephemeral snapshot identity; version one supplies the complete source.
    #[serde(default)]
    pub document: Option<DebugSourceDocument>,
    #[serde(default)]
    pub breakpoints: Vec<SourceBreakpoint>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Versioned, process-local source snapshot, isolated from installed resources.
pub struct DebugSourceDocument {
    pub id: String,
    pub version: u64,
}

struct SourceSnapshot {
    last_used: std::time::Instant,
    version: u64,
    source: String,
}

const MAX_SNAPSHOT_BYTES: usize = 16 * 1024 * 1024;
const MAX_SNAPSHOTS: usize = 4;
type SnapshotCache = BTreeMap<String, SourceSnapshot>;
static SNAPSHOTS: OnceLock<Mutex<SnapshotCache>> = OnceLock::new();

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
    if let Some(document) = &request.document {
        if document.id.is_empty() || document.id.len() > 128 || document.version == 0 {
            return Err(invalid_request("Invalid debug source snapshot identity."));
        }
        let mut cache = SNAPSHOTS
            .get_or_init(|| Mutex::new(BTreeMap::new()))
            .lock()
            .map_err(|_| invalid_request("Debug source snapshots are unavailable."))?;
        let source = if document.version == 1 {
            request.source.clone()
        } else {
            let snapshot = cache
                .get(&document.id)
                .filter(|entry| entry.version.checked_add(1) == Some(document.version))
                .ok_or_else(|| invalid_request("Debug source snapshot is missing or stale."))?;
            snapshot.source.clone()
        };
        if source.len() > MAX_SNAPSHOT_BYTES {
            return Err(invalid_request(
                "Debug source snapshot exceeds its size limit.",
            ));
        }
        let (result, updated) =
            relocate_batch(source, request.edit, request.edits, request.breakpoints)?;
        if updated.len() > MAX_SNAPSHOT_BYTES {
            return Err(invalid_request(
                "Debug source snapshot exceeds its size limit.",
            ));
        }
        if !cache.contains_key(&document.id) && cache.len() >= MAX_SNAPSHOTS {
            if let Some(key) = cache
                .iter()
                .min_by_key(|(_, entry)| entry.last_used)
                .map(|(key, _)| key.clone())
            {
                cache.remove(&key);
            }
        }
        cache.insert(
            document.id.clone(),
            SourceSnapshot {
                last_used: std::time::Instant::now(),
                version: document.version,
                source: updated,
            },
        );
        return Ok(result);
    }
    relocate_batch(
        request.source,
        request.edit,
        request.edits,
        request.breakpoints,
    )
    .map(|(result, _)| result)
}

fn relocate_batch(
    mut source: String,
    edit: Option<DebugSourceEdit>,
    mut edits: Vec<DebugSourceEdit>,
    breakpoints: Vec<SourceBreakpoint>,
) -> Result<(RelocateBreakpointsResult, String), CoreError> {
    if let Some(edit) = edit {
        edits.push(edit);
    }
    edits.sort_by_key(|edit| (edit.start_utf16_offset, edit.end_utf16_offset));
    let source_length = source.encode_utf16().count();
    let mut previous_end = 0;
    for edit in &edits {
        if edit.start_utf16_offset < previous_end
            || edit.start_utf16_offset > edit.end_utf16_offset
            || edit.end_utf16_offset > source_length
        {
            return Err(invalid_request(
                "Debug source edits must form non-overlapping UTF-16 ranges.",
            ));
        }
        byte_index_at_utf16_offset(&source, edit.start_utf16_offset)?;
        byte_index_at_utf16_offset(&source, edit.end_utf16_offset)?;
        previous_end = edit.end_utf16_offset;
    }
    let mut anchors = breakpoints
        .into_iter()
        .map(|point| {
            let anchor = breakpoint_anchor_utf16_offset(&source, &point)?;
            Ok((point, anchor, false))
        })
        .collect::<Result<Vec<_>, CoreError>>()?;
    // Keep exact character anchors across every edit. A line-only intermediate
    // projection loses surviving code and can merge distinct breakpoints early.
    for edit in edits.iter().rev() {
        let start_byte = byte_index_at_utf16_offset(&source, edit.start_utf16_offset)?;
        let end_byte = byte_index_at_utf16_offset(&source, edit.end_utf16_offset)?;
        let replacement_length = edit.replacement.encode_utf16().count();
        for (_, anchor, replaced) in &mut anchors {
            *replaced |= edit.start_utf16_offset < edit.end_utf16_offset
                && *anchor >= edit.start_utf16_offset
                && *anchor < edit.end_utf16_offset;
            *anchor = relocate_anchor(
                *anchor,
                edit.start_utf16_offset,
                edit.end_utf16_offset,
                replacement_length,
            );
        }
        source.replace_range(start_byte..end_byte, &edit.replacement);
    }
    let mut relocated = BTreeMap::new();
    for (mut point, anchor, replaced) in anchors {
        let (line, column) = position_at_utf16_offset(&source, anchor)?;
        point.line = line;
        point.column = point.column.map(|_| column);
        let identity = (line, point.column.unwrap_or(0));
        match relocated.get(&identity) {
            Some((was_replaced, _)) if !was_replaced || replaced => {}
            _ => {
                relocated.insert(identity, (replaced, point));
            }
        }
    }
    Ok((
        RelocateBreakpointsResult {
            breakpoints: relocated.into_values().map(|(_, point)| point).collect(),
        },
        source,
    ))
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
    let mut line_end = line_starts
        .get(line_index + 1)
        .copied()
        .map(|offset| offset.saturating_sub(1))
        .unwrap_or_else(|| source.encode_utf16().count());
    if line_end > line_start {
        let units: Vec<u16> = source.encode_utf16().collect();
        if units.get(line_end - 1) == Some(&(b'\r' as u16)) {
            line_end -= 1;
        }
    }
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
    let mut characters = source.chars().peekable();
    while let Some(character) = characters.next() {
        offset += character.len_utf16();
        if character == '\r' && characters.peek() == Some(&'\n') {
            continue;
        }
        if character == '\n' || character == '\r' {
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
            edit: Some(DebugSourceEdit {
                start_utf16_offset: line_start,
                end_utf16_offset: line_start,
                replacement: "\n".to_string(),
            }),
            edits: vec![],
            document: None,
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
            edit: Some(DebugSourceEdit {
                start_utf16_offset: edit_offset,
                end_utf16_offset: edit_offset,
                replacement: "Now".to_string(),
            }),
            edits: vec![],
            document: None,
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
            edit: Some(DebugSourceEdit {
                start_utf16_offset: deletion_start,
                end_utf16_offset: deletion_end,
                replacement: String::new(),
            }),
            edits: vec![],
            document: None,
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
            edit: Some(DebugSourceEdit {
                start_utf16_offset: anchor_utf16,
                end_utf16_offset: anchor_utf16,
                replacement: "next".to_string(),
            }),
            edits: vec![],
            document: None,
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
            edit: Some(DebugSourceEdit {
                start_utf16_offset: 0,
                end_utf16_offset: "first();\n".len(),
                replacement: String::new(),
            }),
            edits: vec![],
            document: None,
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
            edit: Some(DebugSourceEdit {
                start_utf16_offset: 1,
                end_utf16_offset: 1,
                replacement: String::new(),
            }),
            edits: vec![],
            document: None,
            breakpoints: vec![],
        })
        .unwrap_err();

        assert!(matches!(error.code, ErrorCode::InvalidRequest));
    }
    #[test]
    fn batch_keeps_surviving_character_anchor_until_final_projection() {
        let (result, text) = relocate_batch(
            "aaa\nbbb".into(),
            None,
            vec![
                DebugSourceEdit {
                    start_utf16_offset: 1,
                    end_utf16_offset: 1,
                    replacement: "\n".into(),
                },
                DebugSourceEdit {
                    start_utf16_offset: 3,
                    end_utf16_offset: 4,
                    replacement: String::new(),
                },
            ],
            vec![breakpoint(2)],
        )
        .unwrap();
        assert_eq!(text, "a\naabbb");
        assert_eq!(result.breakpoints, vec![breakpoint(2)]);
    }

    #[test]
    fn lone_cr_and_crlf_keep_line_anchors() {
        for source in ["a\rb", "a\r\nb", "a\nb"] {
            let (result, _) = relocate_batch(
                source.into(),
                Some(DebugSourceEdit {
                    start_utf16_offset: 0,
                    end_utf16_offset: 0,
                    replacement: "x\r".into(),
                }),
                vec![],
                vec![breakpoint(2)],
            )
            .unwrap();
            assert_eq!(result.breakpoints, vec![breakpoint(3)]);
        }
    }

    #[test]
    fn source_snapshot_reuses_text_and_rejects_stale_versions() {
        let request = |version, source: &str| RelocateBreakpointsRequest {
            source: source.into(),
            edit: None,
            edits: vec![DebugSourceEdit {
                start_utf16_offset: 0,
                end_utf16_offset: 0,
                replacement: "\n".into(),
            }],
            document: Some(DebugSourceDocument {
                id: "snapshot-regression".into(),
                version,
            }),
            breakpoints: vec![breakpoint(version as i64)],
        };
        assert_eq!(
            relocate_breakpoints(request(1, "b")).unwrap().breakpoints[0].line,
            2
        );
        assert_eq!(
            relocate_breakpoints(request(2, "")).unwrap().breakpoints[0].line,
            3
        );
        assert!(relocate_breakpoints(request(2, "")).is_err());
    }
}
