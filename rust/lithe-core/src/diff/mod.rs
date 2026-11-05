//! Neutral line comparison of two host-supplied texts and the shared pairing of
//! removed and added lines used by every side-by-side diff in Core.
//!
//! Hosts own reading the texts (snapshots, buffers, agent proposals) and every
//! presentation detail; Core owns line splitting, the diff algorithm, and how a
//! block of removals is aligned against a block of additions.

use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use similar::{capture_diff_slices, Algorithm, DiffOp};

/// Largest UTF-8 size accepted for each compared side. Local History snapshots
/// are capped at 2 MiB, but the current buffer and agent proposals are not, so
/// the bound only rejects inputs that would make one response unreasonably big.
const MAX_TEXT_BYTES: usize = 16 * 1024 * 1024;

/// Largest `removed.len() * added.len()` product the similarity alignment
/// accepts. Beyond this the quadratic table costs more than the pairing is
/// worth, so blocks fall back to positional pairing.
pub(crate) const MAX_ALIGNMENT_CELLS: usize = 4096;

/// Minimum Dice coefficient for two lines to be considered a modification of
/// each other rather than an unrelated delete plus insert.
const MIN_PAIR_SIMILARITY: f32 = 0.5;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// Two complete texts owned by the caller; Core never reads files for this command.
pub struct CompareTextsRequest {
    /// Baseline side, for example an older Local History snapshot.
    pub old_text: String,
    /// Compared side, for example the current editor buffer.
    pub new_text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
/// Side-by-side rendering category of one aligned row.
pub enum TextDiffRowKind {
    /// Both sides hold the same line.
    Context,
    /// A removed line paired with a similar added line.
    Changed,
    /// A line only present in the new text.
    Addition,
    /// A line only present in the old text.
    Removal,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
/// One aligned side-by-side row with one-based line numbers.
pub struct TextDiffRow {
    pub old_line: Option<usize>,
    pub new_line: Option<usize>,
    /// Old-side text; for `context` rows it is also the new-side text.
    pub left: Option<String>,
    /// New-side text; omitted for `context` rows, whose sides are identical.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub right: Option<String>,
    pub kind: TextDiffRowKind,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
/// Unified rendering category of one line.
pub enum TextDiffLineKind {
    Context,
    Removed,
    Added,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
/// One unified line in original order: each changed block lists its removals
/// before its additions, matching `git diff` output.
pub struct TextDiffLine {
    pub kind: TextDiffLineKind,
    pub content: String,
    pub old_line: Option<usize>,
    pub new_line: Option<usize>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
/// Complete line comparison projected both side by side and unified.
pub struct CompareTextsResponse {
    pub rows: Vec<TextDiffRow>,
    pub lines: Vec<TextDiffLine>,
    /// Logical line count of the old text after line-ending normalization.
    pub old_line_count: usize,
    /// Logical line count of the new text after line-ending normalization.
    pub new_line_count: usize,
    pub additions: usize,
    pub deletions: usize,
}

/// Command adapter for `diff.compareTexts`.
pub(crate) fn compare_texts_command(payload: Value) -> Result<Value, CoreError> {
    let request: CompareTextsRequest = serde_json::from_value(payload).map_err(|error| {
        CoreError::new(ErrorCode::InvalidRequest, "Invalid text comparison request")
            .with_details(error.to_string())
    })?;
    let response = compare_texts(&request)?;
    Ok(serde_json::to_value(response).expect("text comparison should encode"))
}

/// Compares two texts line by line.
///
/// `\r\n`, `\r`, and `\n` all terminate a line and are not part of its content,
/// so a file whose only change is its line-ending style compares as identical.
/// One final terminator does not create an extra empty line, and empty text has
/// no lines. Lines are matched with the patience algorithm, and each block of
/// removals and additions is aligned by similarity. Errors with
/// `invalid_request` when either side exceeds the size bound.
pub fn compare_texts(request: &CompareTextsRequest) -> Result<CompareTextsResponse, CoreError> {
    if request.old_text.len() > MAX_TEXT_BYTES || request.new_text.len() > MAX_TEXT_BYTES {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Text is too large to compare",
        ));
    }
    let old = split_lines(&request.old_text);
    let new = split_lines(&request.new_text);
    let mut builder = ComparisonBuilder::default();
    for operation in capture_diff_slices(Algorithm::Patience, &old, &new) {
        match operation {
            DiffOp::Equal {
                old_index,
                new_index,
                len,
            } => {
                builder.flush(&old, &new);
                for offset in 0..len {
                    builder.context(
                        old_index + offset,
                        new_index + offset,
                        old[old_index + offset],
                    );
                }
            }
            DiffOp::Delete {
                old_index, old_len, ..
            } => builder.removed.extend(old_index..old_index + old_len),
            DiffOp::Insert {
                new_index, new_len, ..
            } => builder.added.extend(new_index..new_index + new_len),
            DiffOp::Replace {
                old_index,
                old_len,
                new_index,
                new_len,
            } => {
                builder.removed.extend(old_index..old_index + old_len);
                builder.added.extend(new_index..new_index + new_len);
            }
        }
    }
    builder.flush(&old, &new);
    Ok(CompareTextsResponse {
        rows: builder.rows,
        lines: builder.lines,
        old_line_count: old.len(),
        new_line_count: new.len(),
        additions: builder.additions,
        deletions: builder.deletions,
    })
}

/// Accumulates one pending changed block between context runs.
#[derive(Default)]
struct ComparisonBuilder {
    rows: Vec<TextDiffRow>,
    lines: Vec<TextDiffLine>,
    /// Zero-based old-side indexes of the pending block, ascending.
    removed: Vec<usize>,
    /// Zero-based new-side indexes of the pending block, ascending.
    added: Vec<usize>,
    additions: usize,
    deletions: usize,
}

impl ComparisonBuilder {
    fn context(&mut self, old_index: usize, new_index: usize, text: &str) {
        self.rows.push(TextDiffRow {
            old_line: Some(old_index + 1),
            new_line: Some(new_index + 1),
            left: Some(text.to_string()),
            right: None,
            kind: TextDiffRowKind::Context,
        });
        self.lines.push(TextDiffLine {
            kind: TextDiffLineKind::Context,
            content: text.to_string(),
            old_line: Some(old_index + 1),
            new_line: Some(new_index + 1),
        });
    }

    fn flush(&mut self, old: &[&str], new: &[&str]) {
        if self.removed.is_empty() && self.added.is_empty() {
            return;
        }
        let removed: Vec<&str> = self.removed.iter().map(|index| old[*index]).collect();
        let added: Vec<&str> = self.added.iter().map(|index| new[*index]).collect();
        for (left, right) in pair_lines(&removed, &added) {
            let left_index = left.map(|position| self.removed[position]);
            let right_index = right.map(|position| self.added[position]);
            let kind = match (left_index.is_some(), right_index.is_some()) {
                (true, true) => TextDiffRowKind::Changed,
                (true, false) => TextDiffRowKind::Removal,
                (false, true) => TextDiffRowKind::Addition,
                (false, false) => continue,
            };
            self.rows.push(TextDiffRow {
                old_line: left_index.map(|index| index + 1),
                new_line: right_index.map(|index| index + 1),
                left: left_index.map(|index| old[index].to_string()),
                right: right_index.map(|index| new[index].to_string()),
                kind,
            });
        }
        for index in self.removed.drain(..) {
            self.lines.push(TextDiffLine {
                kind: TextDiffLineKind::Removed,
                content: old[index].to_string(),
                old_line: Some(index + 1),
                new_line: None,
            });
            self.deletions += 1;
        }
        for index in self.added.drain(..) {
            self.lines.push(TextDiffLine {
                kind: TextDiffLineKind::Added,
                content: new[index].to_string(),
                old_line: None,
                new_line: Some(index + 1),
            });
            self.additions += 1;
        }
    }
}

/// Splits text into logical lines without their terminators.
fn split_lines(text: &str) -> Vec<&str> {
    let mut lines = Vec::new();
    let bytes = text.as_bytes();
    let mut start = 0;
    let mut index = 0;
    while index < bytes.len() {
        match bytes[index] {
            b'\n' => {
                lines.push(&text[start..index]);
                index += 1;
                start = index;
            }
            b'\r' => {
                lines.push(&text[start..index]);
                index += if bytes.get(index + 1) == Some(&b'\n') {
                    2
                } else {
                    1
                };
                start = index;
            }
            _ => index += 1,
        }
    }
    if start < bytes.len() {
        lines.push(&text[start..]);
    }
    lines
}

/// Character-bigram Dice coefficient over the trimmed lines, in [0, 1].
///
/// Bigrams tolerate the reindentation and small edits that dominate real diffs,
/// where a prefix/suffix comparison would score a mid-line change at zero.
pub(crate) fn line_similarity(left: &str, right: &str) -> f32 {
    let left = left.trim();
    let right = right.trim();
    if left == right {
        return 1.0;
    }
    if left.is_empty() || right.is_empty() {
        return 0.0;
    }

    let bigrams = |text: &str| -> Vec<[char; 2]> {
        let chars: Vec<char> = text.chars().collect();
        if chars.len() < 2 {
            // Treat a single character as one bigram against itself so short
            // lines can still match rather than always scoring zero.
            return vec![[chars[0], chars[0]]];
        }
        chars.windows(2).map(|pair| [pair[0], pair[1]]).collect()
    };

    let left_bigrams = bigrams(left);
    let mut right_bigrams = bigrams(right);
    let total = left_bigrams.len() + right_bigrams.len();

    // Multiset intersection: each right bigram is consumed by at most one match.
    let mut shared = 0usize;
    for bigram in &left_bigrams {
        if let Some(position) = right_bigrams.iter().position(|other| other == bigram) {
            right_bigrams.swap_remove(position);
            shared += 1;
        }
    }

    (2 * shared) as f32 / total as f32
}

/// Pairs a block of removed lines with a block of added lines.
///
/// Positional pairing forced `removed[i]` onto `added[i]` regardless of content,
/// so deleting 3 lines and adding 5 unrelated ones produced three bogus
/// "changed" rows. This aligns the two blocks by similarity instead, keeping the
/// matching non-crossing so line numbers stay monotonic in the rendered list.
/// Each returned pair indexes into `removed` and `added`.
pub(crate) fn pair_lines(removed: &[&str], added: &[&str]) -> Vec<(Option<usize>, Option<usize>)> {
    let rows = removed.len();
    let columns = added.len();

    // A lone removal against a lone addition has no competing alignment, so it
    // reads as a modification however dissimilar the two lines are. Applying the
    // similarity floor here would split every single-line edit into a delete
    // plus an insert.
    if rows == 1 && columns == 1 {
        return vec![(Some(0), Some(0))];
    }

    if rows == 0 || columns == 0 || rows * columns > MAX_ALIGNMENT_CELLS {
        return (0..rows.max(columns))
            .map(|index| {
                (
                    if index < rows { Some(index) } else { None },
                    if index < columns { Some(index) } else { None },
                )
            })
            .collect();
    }

    let paired_score = |i: usize, j: usize, score: &[Vec<f32>]| {
        let similarity = line_similarity(removed[i], added[j]);
        if similarity >= MIN_PAIR_SIMILARITY {
            similarity + score[i + 1][j + 1]
        } else {
            f32::NEG_INFINITY
        }
    };

    // score[i][j] = best total similarity aligning removed[i..] with added[j..].
    let mut score = vec![vec![0f32; columns + 1]; rows + 1];
    for i in (0..rows).rev() {
        for j in (0..columns).rev() {
            let best_skip = score[i + 1][j].max(score[i][j + 1]);
            score[i][j] = paired_score(i, j, &score).max(best_skip);
        }
    }

    let mut pairs = Vec::with_capacity(rows.max(columns));
    let (mut i, mut j) = (0usize, 0usize);
    while i < rows && j < columns {
        let paired = paired_score(i, j, &score);
        if paired >= score[i + 1][j] && paired >= score[i][j + 1] {
            pairs.push((Some(i), Some(j)));
            i += 1;
            j += 1;
        } else if score[i + 1][j] >= score[i][j + 1] {
            pairs.push((Some(i), None));
            i += 1;
        } else {
            pairs.push((None, Some(j)));
            j += 1;
        }
    }
    while i < rows {
        pairs.push((Some(i), None));
        i += 1;
    }
    while j < columns {
        pairs.push((None, Some(j)));
        j += 1;
    }

    pairs
}

#[cfg(test)]
mod tests;
