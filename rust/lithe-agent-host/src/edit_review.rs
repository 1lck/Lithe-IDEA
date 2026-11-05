//! Agent edit evidence: one normalization of ACP diff reports and one rollback planner.
//!
//! The Host annotates every presented tool update that restates its diffs with
//! `_meta.lithe.diffs`, so both desktop products store identical evidence and
//! revert eligibility. Text limits count Unicode scalar values: Rust `char`,
//! Swift `unicodeScalars` and JavaScript code points agree on them, unlike
//! grapheme clusters or UTF-16 code units. Rollback planning is pure text work;
//! path containment, encoding, guarded writes and Trash stay with the platform.
//! Contract: `shared/contracts/agent-edit-review.md`.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// Largest `oldText`/`newText` kept per diff, in Unicode scalar values.
pub const TEXT_LIMIT_SCALARS: usize = 32_768;
/// Content entries inspected per update; any beyond make every diff incomplete.
pub const CONTENT_LIMIT: usize = 100;
/// Appended to bounded text so a reader sees that the excerpt is shortened.
const TRUNCATION_MARKER: &str = "\n[...]";

/// One normalized diff of a tool update, as stored by both platforms.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiffEvidence {
    /// Path exactly as the Agent reported it; platforms resolve it in the workspace.
    pub path: String,
    /// Previous text, or `None` when the Agent reported none (insertion or creation).
    pub old_text: Option<String>,
    /// Reported text after the edit; empty when the Agent omitted it.
    pub new_text: String,
    /// Explicit upstream operation (`add`, `delete`, `update`), never inferred.
    pub operation: Option<String>,
    /// Upstream-reported added lines; `None` when the Agent did not report them.
    pub additions: Option<u64>,
    /// Upstream-reported removed lines; `None` when the Agent did not report them.
    pub deletions: Option<u64>,
    /// The texts are not a complete copy of what the Agent changed.
    pub truncated: bool,
    /// The evidence alone is sufficient to plan a rollback of this diff.
    pub revertible: bool,
}

/// Adds `_meta.lithe.diffs` to a `tool_call` or `tool_call_update` that restates
/// its diffs. Updates without diff information are left untouched, so platforms
/// keep earlier evidence exactly when the Agent sent none.
pub fn annotate(update: &mut Value) {
    if !matches!(
        update["sessionUpdate"].as_str(),
        Some("tool_call" | "tool_call_update")
    ) {
        return;
    }
    let Some(diffs) = evidence(update) else {
        return;
    };
    let Ok(diffs) = serde_json::to_value(diffs) else {
        return;
    };
    if !update["_meta"].is_object() {
        update["_meta"] = json!({});
    }
    if !update["_meta"]["lithe"].is_object() {
        update["_meta"]["lithe"] = json!({});
    }
    update["_meta"]["lithe"]["diffs"] = diffs;
}

/// Diff evidence an update determines, or `None` when it carries no diff information.
pub fn evidence(update: &Value) -> Option<Vec<DiffEvidence>> {
    let content = update["content"].as_array();
    let reported = content.map(|content| content_diffs(content));
    if let Some(written) = claude_write(update, reported.as_deref()) {
        return Some(vec![written]);
    }
    reported
}

fn content_diffs(content: &[Value]) -> Vec<DiffEvidence> {
    let overflow = content.len() > CONTENT_LIMIT;
    content
        .iter()
        .take(CONTENT_LIMIT)
        .filter(|entry| entry["type"] == "diff")
        .filter_map(|entry| {
            let path = entry["path"].as_str()?;
            let old = entry["oldText"].as_str();
            let new = entry["newText"].as_str();
            let operation = entry["_meta"]["kind"].as_str().map(str::to_owned);
            let stats = &entry["_meta"]["jetbrains"]["air"]["diffStats"];
            let stats_valid = stats["version"].as_i64() == Some(1);
            let stat = |key: &str| stats_valid.then(|| stats[key].as_u64()).flatten();
            let truncated = overflow
                || new.is_none()
                || entry["isTruncated"].as_bool() == Some(true)
                || old.is_some_and(exceeds_limit)
                || new.is_some_and(exceeds_limit);
            Some(diff(
                path,
                old,
                new.unwrap_or(""),
                operation,
                (stat("added"), stat("removed")),
                truncated,
            ))
        })
        .collect()
}

/// The pinned Claude adapter forwards the SDK's public `FileWriteOutput`. Its
/// complete text replaces newline-less hunks, and its explicit `create` type is
/// the only proof that a null previous text means file creation.
fn claude_write(update: &Value, reported: Option<&[DiffEvidence]>) -> Option<DiffEvidence> {
    let claude = &update["_meta"]["claudeCode"];
    if claude["toolName"] != "Write" {
        return None;
    }
    let response = &claude["toolResponse"];
    let path = response["filePath"].as_str().filter(|path| !path.is_empty())?;
    let new = response["content"].as_str()?;
    let old = response["originalFile"].as_str();
    let operation = match response["type"].as_str()? {
        "create" => "add",
        "update" if old.is_some() => "update",
        _ => return None,
    };
    let old = (operation == "update").then_some(old).flatten();
    // Statistics stay upstream-scoped: only complete hunks of the same update
    // may describe the whole write.
    let hunks: Vec<&DiffEvidence> = reported
        .unwrap_or_default()
        .iter()
        .filter(|diff| diff.path == path)
        .collect();
    let complete = !hunks.iter().any(|diff| diff.truncated);
    let total = |field: fn(&DiffEvidence) -> Option<u64>| {
        if !complete || hunks.is_empty() {
            return None;
        }
        hunks
            .iter()
            .try_fold(0u64, |sum, diff| sum.checked_add(field(diff)?))
    };
    let stats = (total(|diff| diff.additions), total(|diff| diff.deletions));
    let truncated = exceeds_limit(new) || old.is_some_and(exceeds_limit);
    Some(diff(
        path,
        old,
        new,
        Some(operation.to_owned()),
        stats,
        truncated,
    ))
}

fn diff(
    path: &str,
    old: Option<&str>,
    new: &str,
    operation: Option<String>,
    (additions, deletions): (Option<u64>, Option<u64>),
    truncated: bool,
) -> DiffEvidence {
    let revertible = is_revertible(truncated, old.is_some(), operation.as_deref());
    DiffEvidence {
        path: path.to_owned(),
        old_text: old.map(bounded),
        new_text: bounded(new),
        operation,
        additions,
        deletions,
        truncated,
        revertible,
    }
}

/// A null previous text is only reversible with explicit creation metadata,
/// because some Agents report an inserted excerpt the same way.
fn is_revertible(truncated: bool, has_old: bool, operation: Option<&str>) -> bool {
    !truncated && (has_old || operation == Some("add"))
}

fn exceeds_limit(text: &str) -> bool {
    text.chars().nth(TEXT_LIMIT_SCALARS).is_some()
}

fn bounded(text: &str) -> String {
    match text.char_indices().nth(TEXT_LIMIT_SCALARS) {
        Some((end, _)) => format!("{}{TRUNCATION_MARKER}", &text[..end]),
        None => text.to_owned(),
    }
}

/// Payload of `agent.edits.reversePlan`: one file's evidence plus its disk text.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ReverseRequest {
    /// Evidence in tool execution order; the newest diff is reversed first.
    pub diffs: Vec<ReverseDiff>,
    /// Some tool that touched the file has not completed yet.
    #[serde(default)]
    pub pending: bool,
    /// Some tool touched the file without diff evidence, or moved it.
    #[serde(default)]
    pub missing_evidence: bool,
    /// Current decoded disk text, or `None` when the file does not exist.
    pub disk: Option<String>,
}

/// One diff of [`ReverseRequest`], as stored from [`DiffEvidence`].
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReverseDiff {
    /// Previous text; `None` without creation metadata is not reversible.
    pub old_text: Option<String>,
    /// Reported text after the edit.
    pub new_text: String,
    /// Explicit upstream operation of the diff.
    #[serde(default)]
    pub operation: Option<String>,
    /// ACP `kind` of the tool that reported the diff. A `delete` tool marks an
    /// operation-less diff as a deletion.
    #[serde(default)]
    pub tool_kind: Option<String>,
    /// The diff texts are incomplete.
    pub truncated: bool,
}

/// What the platform must do to reverse one file's Agent edits.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "action", rename_all = "camelCase")]
pub enum ReversePlan {
    /// Write `text` with the platform's guarded write, keeping the disk encoding.
    Write {
        /// Restored text, in the disk's dominant line ending where text was matched.
        text: String,
    },
    /// Move the existing file to recoverable Trash; it did not exist before.
    Trash,
    /// The disk already matches the state before the edits.
    None,
    /// Rollback is unsafe; nothing may be written.
    Conflict {
        /// Stable reason code, localized by the platform.
        reason: ConflictReason,
    },
}

/// Stable rollback conflict codes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ConflictReason {
    /// The evidence is pending, missing, truncated or lacks original content.
    Incomplete,
    /// The disk no longer matches the evidence (edited, missing or ambiguous).
    Changed,
}

/// Plans a rollback of one file's edits, newest first.
///
/// Matching tolerates LF evidence against CRLF files: ACP diffs carry LF while
/// a document read keeps the disk's line endings. Only the matched span is
/// rewritten, in the disk's dominant line ending, so unrelated lines keep theirs.
pub fn reverse_plan(request: &ReverseRequest) -> ReversePlan {
    let conflict = |reason| ReversePlan::Conflict { reason };
    let eligible = !request.pending
        && !request.missing_evidence
        && !request.diffs.is_empty()
        && request.diffs.iter().all(|diff| {
            is_revertible(
                diff.truncated,
                diff.old_text.is_some(),
                diff.operation.as_deref(),
            )
        });
    if !eligible {
        return conflict(ConflictReason::Incomplete);
    }
    let mut restored = request.disk.clone();
    for diff in request.diffs.iter().rev() {
        let deletion = match diff.operation.as_deref() {
            Some(operation) => operation == "delete",
            None => diff.tool_kind.as_deref() == Some("delete"),
        };
        restored = match (deletion, diff.old_text.as_deref(), restored) {
            // A deleted file is restored only while its path is still free.
            (true, Some(old), None) => Some(old.to_owned()),
            (true, _, _) => return conflict(ConflictReason::Changed),
            // Creation: remove only the exact created content.
            (false, None, Some(current)) if canonical(&current).0 == canonical(&diff.new_text).0 => {
                None
            }
            (false, None, _) => return conflict(ConflictReason::Changed),
            (false, Some(old), Some(current)) => {
                match unique_replacement(&current, &diff.new_text, old) {
                    Some(text) => Some(text),
                    None => return conflict(ConflictReason::Changed),
                }
            }
            (false, Some(_), None) => return conflict(ConflictReason::Changed),
        };
    }
    match (restored, request.disk.as_deref()) {
        (None, None) => ReversePlan::None,
        (None, Some(_)) => ReversePlan::Trash,
        (Some(text), Some(disk)) if text == disk => ReversePlan::None,
        (Some(text), _) => ReversePlan::Write { text },
    }
}

/// Replaces exactly one occurrence of `new` in `current` with `old`.
/// Complete snapshots match verbatim; excerpts must be nonempty and unambiguous,
/// including overlapping occurrences.
fn unique_replacement(current: &str, new: &str, old: &str) -> Option<String> {
    if current == new {
        return Some(old.to_owned());
    }
    if new.is_empty() {
        return None;
    }
    let ending = dominant_line_ending(current);
    let disk_new = with_line_ending(new, ending);
    let disk_old = with_line_ending(old, ending);
    if let Some(start) = unique_occurrence(current, &disk_new)? {
        return Some(splice(current, start, start + disk_new.len(), &disk_old));
    }
    // Mixed line endings defeat the exact match; compare canonically and map
    // the matched span back to original byte offsets.
    let (canonical_current, offsets) = canonical(current);
    let canonical_new = canonical(new).0;
    let start = unique_occurrence(&canonical_current, &canonical_new)??;
    let end = start + canonical_new.len();
    let original = |index: usize| offsets.get(index).copied().unwrap_or(current.len());
    Some(splice(current, original(start), original(end), &disk_old))
}

/// `Some(Some(index))` for one match, `Some(None)` for none, `None` for several.
fn unique_occurrence(haystack: &str, needle: &str) -> Option<Option<usize>> {
    let Some(first) = haystack.find(needle) else {
        return Some(None);
    };
    // Resume one character later so overlapping repeats count as ambiguous.
    let next = first + haystack[first..].chars().next().map_or(1, char::len_utf8);
    if haystack[next..].contains(needle) {
        None
    } else {
        Some(Some(first))
    }
}

fn splice(text: &str, start: usize, end: usize, replacement: &str) -> String {
    format!("{}{replacement}{}", &text[..start], &text[end..])
}

/// LF-normalized text plus, per canonical byte, its original byte offset.
fn canonical(text: &str) -> (String, Vec<usize>) {
    let mut normalized = String::with_capacity(text.len());
    let mut offsets = Vec::with_capacity(text.len());
    let bytes = text.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'\r' {
            offsets.push(index);
            normalized.push('\n');
            index += if bytes.get(index + 1) == Some(&b'\n') {
                2
            } else {
                1
            };
            continue;
        }
        let character = text[index..].chars().next().unwrap_or_default();
        for _ in 0..character.len_utf8() {
            offsets.push(index);
        }
        normalized.push(character);
        index += character.len_utf8();
    }
    (normalized, offsets)
}

fn dominant_line_ending(text: &str) -> &'static str {
    if text.contains("\r\n") {
        "\r\n"
    } else {
        "\n"
    }
}

fn with_line_ending(text: &str, ending: &str) -> String {
    let normalized = canonical(text).0;
    if ending == "\n" {
        normalized
    } else {
        normalized.replace('\n', ending)
    }
}

#[cfg(test)]
mod tests;
