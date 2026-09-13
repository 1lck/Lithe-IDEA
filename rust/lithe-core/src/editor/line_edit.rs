//! Deterministic line-level editing transforms shared by both products.
//!
//! The algorithms operate on UTF-16 code units so offsets map directly onto
//! NSTextView ranges on macOS and JavaScript string indices on Windows. The
//! transforms are pure: they take the source text plus a selection and return
//! the replacement text, the replaced range, and the selection to restore.
//! Platform code only applies the result through its native text engine.

use serde::{Deserialize, Serialize};

use crate::protocol::{CoreError, ErrorCode};

/// Line-level editing operations supported by `editor.lineEdit`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LineEditOperation {
    /// Toggle the line comment prefix on the covered lines.
    ToggleLineComment,
    /// Duplicate the caret line or the selected text below it.
    DuplicateLine,
    /// Remove the covered lines.
    DeleteLine,
    /// Move the covered lines up by one line.
    MoveLineUp,
    /// Move the covered lines down by one line.
    MoveLineDown,
    /// Insert a copy of the covered lines above them.
    CopyLineUp,
    /// Insert a copy of the covered lines below them.
    CopyLineDown,
}

/// Request for `editor.lineEdit`. All offsets are UTF-16 code units.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LineEditRequest {
    pub operation: LineEditOperation,
    pub source: String,
    #[serde(default)]
    pub selection_start: usize,
    #[serde(default)]
    pub selection_length: usize,
    /// Line comment token; required by `ToggleLineComment`.
    #[serde(default)]
    pub comment_token: Option<String>,
}

/// Request for `editor.lineCommentToken`.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LineCommentTokenRequest {
    /// File extension, file name (including dotfiles such as `.env`), or
    /// language id, matched case-insensitively.
    pub identifier: String,
}

/// Result of `editor.lineEdit`. When `applied` is false the operation is a
/// no-op (for example moving the first line up) and the caller must not
/// modify its text view. Otherwise `text` replaces
/// `[replacedStart, replacedStart + replacedLength)` and `selection` is the
/// range to restore, all in UTF-16 code units.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LineEditOutcome {
    pub applied: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub replaced_start: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub replaced_length: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub selection_start: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub selection_length: Option<usize>,
}

impl LineEditOutcome {
    fn not_applied() -> Self {
        Self {
            applied: false,
            text: None,
            replaced_start: None,
            replaced_length: None,
            selection_start: None,
            selection_length: None,
        }
    }

    fn applied(
        text: String,
        replaced_start: usize,
        replaced_length: usize,
        selection_start: usize,
        selection_length: usize,
    ) -> Self {
        Self {
            applied: true,
            text: Some(text),
            replaced_start: Some(replaced_start),
            replaced_length: Some(replaced_length),
            selection_start: Some(selection_start),
            selection_length: Some(selection_length),
        }
    }
}

/// Result of `editor.lineCommentToken`. `token` is `None` for file types
/// without a line comment token; callers must not intercept the shortcut.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LineCommentToken {
    pub token: Option<String>,
}

/// Resolves the line comment token for a file extension, file name, or
/// language id. The table is the single shared source of truth; it covers
/// file extensions (`swift`, `py`), language ids (`python`, `javascript`),
/// and dotfile names whose basename matches an entry (`.env`).
pub fn line_comment_token(request: LineCommentTokenRequest) -> LineCommentToken {
    let key = request.identifier.to_lowercase();
    let token = lookup_line_comment_token(&key).or_else(|| {
        // Dotfiles report an empty pathExtension on macOS, so callers pass
        // the basename: fall back to the segment after the last dot so
        // `.env` resolves through `env` and `Foo.py` through `py`.
        let last_segment = key.rsplit('.').next()?;
        if last_segment.is_empty() || last_segment == key {
            return None;
        }
        lookup_line_comment_token(last_segment)
    });
    LineCommentToken {
        token: token.map(str::to_string),
    }
}

fn lookup_line_comment_token(identifier: &str) -> Option<&'static str> {
    match identifier {
        // C family and other double-slash languages
        "c" | "h" | "cpp" | "cc" | "cxx" | "hpp" | "hxx" | "java" | "kt" | "kts" | "swift"
        | "js" | "jsx" | "mjs" | "cjs" | "ts" | "tsx" | "go" | "rs" | "cs" | "csharp" | "php"
        | "dart" | "scala" | "groovy" | "m" | "mm" | "zig" | "javascript" | "javascriptreact"
        | "typescript" | "typescriptreact" | "kotlin" => Some("//"),
        // Hash languages
        "py" | "python" | "rb" | "ruby" | "sh" | "bash" | "zsh" | "shell" | "yml" | "yaml"
        | "toml" | "ini" | "cfg" | "conf" | "properties" | "env" | "dotenv" | "r" | "rmarkdown"
        | "pl" | "elixir" | "ex" => Some("#"),
        // Dash languages
        "sql" | "lua" | "hs" | "haskell" => Some("--"),
        _ => None,
    }
}

/// Applies a line-level editing operation. Returns a no-op outcome instead of
/// an error for legitimate boundary cases such as moving the first line up.
pub fn line_edit(request: LineEditRequest) -> Result<LineEditOutcome, CoreError> {
    let units: Vec<u16> = request.source.encode_utf16().collect();
    // A caret between the \r and \n of a CRLF pair is not a position text
    // engines can represent; normalize it to the end of the terminated line
    // so the mapped selection always lands on an acceptable offset.
    let selection_start = normalize_crlf_caret(&units, request.selection_start.min(units.len()));
    let selection_end = normalize_crlf_caret(
        &units,
        (selection_start + request.selection_length).min(units.len()),
    );
    let selection_length = selection_end.saturating_sub(selection_start);
    let token = request.comment_token.as_deref();
    let outcome = match request.operation {
        LineEditOperation::ToggleLineComment => {
            let Some(token) = token else {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "toggleLineComment requires commentToken",
                ));
            };
            toggle_line_comment(&units, selection_start, selection_length, token)
        }
        LineEditOperation::DuplicateLine => {
            duplicate_line(&units, selection_start, selection_length)
        }
        LineEditOperation::DeleteLine => delete_line(&units, selection_start, selection_length),
        LineEditOperation::MoveLineUp => {
            move_lines(&units, selection_start, selection_length, MoveDirection::Up)
        }
        LineEditOperation::MoveLineDown => move_lines(
            &units,
            selection_start,
            selection_length,
            MoveDirection::Down,
        ),
        LineEditOperation::CopyLineUp => {
            copy_lines(&units, selection_start, selection_length, CopyDirection::Up)
        }
        LineEditOperation::CopyLineDown => copy_lines(
            &units,
            selection_start,
            selection_length,
            CopyDirection::Down,
        ),
    };
    match outcome {
        Some(edit) => {
            let text = String::from_utf16(&edit.replacement).map_err(|_| {
                CoreError::new(ErrorCode::Unknown, "Line edit produced invalid UTF-16")
            })?;
            // The contract guarantees the returned selection fits inside the
            // edited document; clamp as the final safeguard so no mapping
            // edge case can hand an out-of-bounds range to a text engine.
            let edited_length = units.len() - edit.replaced_length + edit.replacement.len();
            let selection_start = edit.selection_start.min(edited_length);
            let selection_length = edit.selection_length.min(edited_length - selection_start);
            Ok(LineEditOutcome::applied(
                text,
                edit.replaced_start,
                edit.replaced_length,
                selection_start,
                selection_length,
            ))
        }
        None => Ok(LineEditOutcome::not_applied()),
    }
}

/// A pending text transformation expressed in UTF-16 units: `replacement`
/// substitutes `[replaced_start, replaced_start + replaced_length)`.
struct LineEdit {
    replacement: Vec<u16>,
    replaced_start: usize,
    replaced_length: usize,
    selection_start: usize,
    selection_length: usize,
}

#[derive(Clone, Copy)]
enum MoveDirection {
    Up,
    Down,
}

#[derive(Clone, Copy)]
enum CopyDirection {
    Up,
    Down,
}

fn is_separator(char_value: u16) -> bool {
    char_value == 0x0A || char_value == 0x0D
}

/// Normalizes an offset that falls between the `\r` and `\n` of a CRLF
/// pair onto the end of the line the separator terminates.
fn normalize_crlf_caret(units: &[u16], offset: usize) -> usize {
    if offset > 0 && offset < units.len() && units[offset - 1] == 0x0D && units[offset] == 0x0A {
        offset - 1
    } else {
        offset
    }
}

/// Line separator length at `index` (`\r\n` is 2, `\n` or `\r` is 1).
fn separator_length(units: &[u16], index: usize) -> usize {
    if units[index] == 0x0D && index + 1 < units.len() && units[index + 1] == 0x0A {
        2
    } else {
        1
    }
}

/// Bounds of the line at `offset`. An offset on a line separator belongs to
/// the line terminated by that separator; an offset at EOF describes the
/// empty line after the last separator. Manual scanning keeps the ownership
/// of empty trailing lines deterministic.
fn line_bounds(units: &[u16], offset: usize) -> LineBounds {
    let length = units.len();
    let location = offset.min(length);
    if location == length {
        let mut start = 0;
        let mut index = length;
        while index > 0 {
            index -= 1;
            if is_separator(units[index]) {
                let separator_start =
                    if units[index] == 0x0A && index > 0 && units[index - 1] == 0x0D {
                        index - 1
                    } else {
                        index
                    };
                start = separator_start + separator_length(units, separator_start);
                break;
            }
        }
        return LineBounds {
            start,
            content_end: length,
            end_with_separator: length,
        };
    }
    let separator_start = if is_separator(units[location]) {
        if units[location] == 0x0A && location > 0 && units[location - 1] == 0x0D {
            location - 1
        } else {
            location
        }
    } else {
        let mut index = location;
        while index < length && !is_separator(units[index]) {
            index += 1;
        }
        index
    };
    let separator_end = if separator_start < length {
        separator_start + separator_length(units, separator_start)
    } else {
        length
    };
    let mut start = 0;
    let mut index = separator_start;
    while index > 0 {
        index -= 1;
        if is_separator(units[index]) {
            let separator_start_index =
                if units[index] == 0x0A && index > 0 && units[index - 1] == 0x0D {
                    index - 1
                } else {
                    index
                };
            start = separator_start_index + separator_length(units, separator_start_index);
            break;
        }
    }
    LineBounds {
        start,
        content_end: separator_start,
        end_with_separator: separator_end,
    }
}

struct LineBounds {
    start: usize,
    content_end: usize,
    end_with_separator: usize,
}

/// Content ranges of the complete lines covered by the selection. The first
/// line is the one containing the selection start; the last line is the one
/// containing the last selected character, so a selection ending exactly at
/// a line start excludes that line (matching IDEA semantics).
fn covered_lines(units: &[u16], selection_start: usize, selection_length: usize) -> Vec<Range> {
    if units.is_empty() {
        return Vec::new();
    }
    let mut bounds = line_bounds(units, selection_start);
    let mut spans = Vec::new();
    let last_end_with_separator = if selection_length > 0 {
        let last_index = (selection_start + selection_length - 1).min(units.len() - 1);
        line_bounds(units, last_index).end_with_separator
    } else {
        bounds.end_with_separator
    };
    loop {
        spans.push(Range {
            start: bounds.start,
            end: bounds.content_end,
        });
        if bounds.end_with_separator >= last_end_with_separator
            || bounds.end_with_separator >= units.len()
        {
            break;
        }
        bounds = line_bounds(units, bounds.end_with_separator);
    }
    spans
}

#[derive(Clone, Copy)]
struct Range {
    start: usize,
    end: usize,
}

/// Offset of the first non-whitespace character of a line's content,
/// relative to the content start; blank lines return the content length.
fn first_content_offset(units: &[u16], range: Range) -> usize {
    let mut offset = range.start;
    while offset < range.end && (units[offset] == 0x20 || units[offset] == 0x09) {
        offset += 1;
    }
    offset - range.start
}

fn toggle_line_comment(
    units: &[u16],
    selection_start: usize,
    selection_length: usize,
    token: &str,
) -> Option<LineEdit> {
    let spans = covered_lines(units, selection_start, selection_length);
    let first = *spans.first()?;
    let last = *spans.last()?;
    let token_units: Vec<u16> = token.encode_utf16().collect();

    struct LineInfo {
        content_start: usize,
        content: Vec<u16>,
        first_content_offset: usize,
    }
    let line_infos: Vec<LineInfo> = spans
        .iter()
        .map(|span| LineInfo {
            content_start: span.start,
            content: units[span.start..span.end].to_vec(),
            first_content_offset: first_content_offset(units, *span),
        })
        .collect();
    let non_blank: Vec<&LineInfo> = line_infos
        .iter()
        .filter(|info| {
            info.content
                .iter()
                .any(|char_value| *char_value != 0x20 && *char_value != 0x09)
        })
        .collect();
    if non_blank.is_empty() {
        return None;
    }

    struct PositionEdit {
        position: usize,
        removed_length: usize,
        inserted: Vec<u16>,
    }
    let all_commented = non_blank
        .iter()
        .all(|info| info.content[info.first_content_offset..].starts_with(&token_units));
    let position_edits: Vec<PositionEdit> = if all_commented {
        non_blank
            .iter()
            .map(|info| {
                // The token is guaranteed to follow the leading whitespace;
                // the space probe must use content-local indices so lines
                // beyond the first one cannot index out of bounds.
                let mut removed_length = token_units.len();
                let after_token = info.first_content_offset + token_units.len();
                if after_token < info.content.len() && info.content[after_token] == 0x20 {
                    removed_length += 1;
                }
                PositionEdit {
                    position: info.content_start + info.first_content_offset,
                    removed_length,
                    inserted: Vec::new(),
                }
            })
            .collect()
    } else {
        non_blank
            .iter()
            .map(|info| PositionEdit {
                position: info.content_start + info.first_content_offset,
                removed_length: 0,
                inserted: {
                    let mut inserted = token_units.clone();
                    inserted.push(0x20);
                    inserted
                },
            })
            .collect()
    };

    let region_start = first.start;
    let region_end = last.end;
    let mut rebuilt: Vec<u16> = Vec::with_capacity(region_end - region_start + token_units.len());
    let mut cursor = region_start;
    for edit in &position_edits {
        rebuilt.extend_from_slice(&units[cursor..edit.position]);
        rebuilt.extend_from_slice(&edit.inserted);
        cursor = edit.position + edit.removed_length;
    }
    rebuilt.extend_from_slice(&units[cursor..region_end]);

    let (selection_start, selection_length) = map_selection(
        selection_start,
        selection_start + selection_length,
        &position_edits
            .iter()
            .map(|edit| (edit.position, edit.removed_length, edit.inserted.len()))
            .collect::<Vec<_>>(),
    );
    Some(LineEdit {
        replacement: rebuilt,
        replaced_start: region_start,
        replaced_length: region_end - region_start,
        selection_start,
        selection_length,
    })
}

/// Maps a selection through the position edits. Offsets before an insertion
/// point are unchanged, offsets after it shift by the insertion length, and
/// offsets inside a removed span tighten to that span's start while keeping
/// the displacement accumulated by earlier edits.
fn map_selection(
    selection_start: usize,
    selection_end: usize,
    edits: &[(usize, usize, usize)],
) -> (usize, usize) {
    fn map_offset(offset: usize, edits: &[(usize, usize, usize)]) -> usize {
        let mut mapped = offset;
        for &(position, removed_length, inserted_length) in edits {
            if removed_length == 0 {
                if offset > position {
                    mapped += inserted_length;
                }
            } else if offset >= position + removed_length {
                mapped -= removed_length;
            } else if offset > position {
                // Signed arithmetic keeps the displacement accumulated by
                // earlier removals; the result never goes below the mapped
                // start of the edited region.
                mapped = (position as i64 + mapped as i64 - offset as i64).max(0) as usize;
            }
        }
        mapped
    }
    let lower = selection_start.min(selection_end);
    let upper = selection_end.max(selection_start);
    let mapped_lower = map_offset(lower, edits);
    let mapped_upper = map_offset(upper, edits);
    if mapped_lower <= mapped_upper {
        (mapped_lower, mapped_upper - mapped_lower)
    } else {
        (mapped_upper, mapped_lower - mapped_upper)
    }
}

fn duplicate_line(
    units: &[u16],
    selection_start: usize,
    selection_length: usize,
) -> Option<LineEdit> {
    if selection_length > 0 {
        // Duplicate the selected text as-is right after it and select the
        // copy, matching IDEA behavior.
        let end = selection_start + selection_length;
        return Some(LineEdit {
            replacement: units[selection_start..end].to_vec(),
            replaced_start: end,
            replaced_length: 0,
            selection_start: end,
            selection_length,
        });
    }
    // An empty document still has one empty line; duplicating it inserts a
    // newline and moves the caret behind it, matching IDEA duplicate-line.
    if units.is_empty() {
        return Some(LineEdit {
            replacement: vec![0x0A],
            replaced_start: 0,
            replaced_length: 0,
            selection_start: 1,
            selection_length: 0,
        });
    }
    let bounds = line_bounds(units, selection_start);
    let separator_length = bounds.end_with_separator - bounds.content_end;
    let content = units[bounds.start..bounds.content_end].to_vec();
    let separator: Vec<u16> = if separator_length > 0 {
        units[bounds.content_end..bounds.end_with_separator].to_vec()
    } else {
        vec![0x0A]
    };
    let mut replacement = Vec::with_capacity(content.len() + separator.len());
    if separator_length > 0 {
        replacement.extend_from_slice(&content);
        replacement.extend_from_slice(&separator);
    } else {
        replacement.extend_from_slice(&separator);
        replacement.extend_from_slice(&content);
    }
    // The caret lands on the same column of the duplicated line.
    Some(LineEdit {
        replacement,
        replaced_start: bounds.end_with_separator,
        replaced_length: 0,
        selection_start: selection_start + content.len() + separator.len(),
        selection_length: 0,
    })
}

fn delete_line(units: &[u16], selection_start: usize, selection_length: usize) -> Option<LineEdit> {
    let spans = covered_lines(units, selection_start, selection_length);
    let first = *spans.first()?;
    let last = *spans.last()?;
    // Remove the covered lines together with their trailing separator so no
    // empty line is left behind; an EOF line without a separator simply ends
    // the removed span at its content end.
    let removed_end = line_bounds(units, last.end).end_with_separator;
    let replaced_start = first.start;
    let replaced_length = removed_end - first.start;
    let remaining = units.len() - replaced_length;
    let selection_start = replaced_start.min(remaining);
    Some(LineEdit {
        replacement: Vec::new(),
        replaced_start,
        replaced_length,
        selection_start,
        selection_length: 0,
    })
}

fn move_lines(
    units: &[u16],
    selection_start: usize,
    selection_length: usize,
    direction: MoveDirection,
) -> Option<LineEdit> {
    let spans = covered_lines(units, selection_start, selection_length);
    let first = *spans.first()?;
    let last = *spans.last()?;
    let block_start = first.start;
    let last_bounds = line_bounds(units, last.end);
    let block_end = last_bounds.end_with_separator;
    let block_content = units[block_start..block_end].to_vec();
    let block_separator_length = block_end - last_bounds.content_end;

    let region: Range;
    let text: Vec<u16>;
    let displacement: isize;
    // When the block loses its trailing separator the selection end must
    // tighten to the block content end; otherwise it maps unchanged.
    let mut selection_end_limit = block_end;
    match direction {
        MoveDirection::Up => {
            if block_start == 0 {
                return None;
            }
            // block_start - 1 is the last character of the previous line's
            // separator, so line_bounds attributes it to that line.
            let above_bounds = line_bounds(units, block_start - 1);
            let above_start = above_bounds.start;
            let above_with_separator = units[above_start..block_start].to_vec();
            let above_separator_length = block_start - above_bounds.content_end;
            let above_content = above_with_separator
                [..above_with_separator.len() - above_separator_length]
                .to_vec();
            let above_separator = above_with_separator
                [above_with_separator.len() - above_separator_length..]
                .to_vec();
            region = Range {
                start: above_start,
                end: block_end,
            };
            if block_separator_length > 0 {
                // Regular swap: both the block and the previous line carry
                // their own separators.
                text = [block_content, above_with_separator].concat();
            } else {
                // The block is the last line without a newline; the original
                // separator moves between the block and the previous line.
                text = [block_content, above_separator, above_content].concat();
            }
            displacement = above_start as isize - block_start as isize;
        }
        MoveDirection::Down => {
            if block_end >= units.len() {
                return None;
            }
            let below_bounds = line_bounds(units, block_end);
            let below_end = below_bounds.end_with_separator;
            let below_with_separator = units[block_end..below_end].to_vec();
            let below_separator_length = below_end - below_bounds.content_end;
            region = Range {
                start: block_start,
                end: below_end,
            };
            if below_separator_length > 0 {
                text = [below_with_separator, block_content].concat();
                displacement = below_end as isize - block_end as isize;
            } else {
                // The next line is the last one without a newline; the block
                // separator moves between the next line and the block.
                let block_content_without_separator =
                    block_content[..block_content.len() - block_separator_length].to_vec();
                let block_separator =
                    block_content[block_content.len() - block_separator_length..].to_vec();
                text = [
                    below_with_separator,
                    block_separator,
                    block_content_without_separator,
                ]
                .concat();
                displacement = (below_end - block_end + block_separator_length) as isize;
                selection_end_limit = last_bounds.content_end;
            }
        }
    }

    let selection_end = (selection_start + selection_length).min(selection_end_limit);
    let new_start = (selection_start as isize + displacement).max(0) as usize;
    let new_end = (selection_end as isize + displacement).max(new_start as isize) as usize;
    Some(LineEdit {
        replacement: text,
        replaced_start: region.start,
        replaced_length: region.end - region.start,
        selection_start: new_start,
        selection_length: new_end - new_start,
    })
}

fn copy_lines(
    units: &[u16],
    selection_start: usize,
    selection_length: usize,
    direction: CopyDirection,
) -> Option<LineEdit> {
    let spans = covered_lines(units, selection_start, selection_length);
    let first = *spans.first()?;
    let last = *spans.last()?;
    let block_start = first.start;
    let last_bounds = line_bounds(units, last.end);
    let block_end = last_bounds.end_with_separator;
    let block_content = units[block_start..block_end].to_vec();
    let block_separator_length = block_end - last_bounds.content_end;

    match direction {
        CopyDirection::Up => {
            // Insert a copy of the block directly above it. The separator
            // after the copied content separates the copy from the original;
            // an EOF block without one gains a newline. The replacement is a
            // pure insertion, so it must not repeat the original tail.
            let mut replacement = block_content.clone();
            if block_separator_length == 0 {
                replacement.push(0x0A);
            }
            Some(LineEdit {
                replacement,
                replaced_start: block_start,
                replaced_length: 0,
                // The original block keeps its offsets, so the selection
                // stays on it unchanged.
                selection_start,
                selection_length,
            })
        }
        CopyDirection::Down => {
            // Copying downward behaves like duplicating the line or the
            // selected text.
            duplicate_line(units, selection_start, selection_length)
        }
    }
}
