//! Local usage collection for the AI coding CLIs installed on this machine.
//!
//! Claude Code and Codex both write a JSONL log per session under the home
//! directory. Those logs need no proxy and no account access, but they are
//! large - a heavy user accumulates well over a gigabyte - so the reading and
//! the parsing happen here and only the distilled per-request records cross
//! the IPC boundary.
//!
//! Collection is incremental. The caller hands back the per-file state from the
//! previous run, and only the bytes appended since then are read and parsed.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::{Instant, UNIX_EPOCH};

/// Records are always attributed to the local session logs, never to a proxy.
const SOURCE_LOCAL_SESSION: &str = "local-session";

/// No single file is read beyond this, so one pathological log cannot stall the
/// whole scan. Everything under the cap is read in full.
const MAX_BYTES_PER_FILE: u64 = 512 * 1024 * 1024;

/// Guards the walk against a directory cycle through a junction or symlink.
const MAX_WALK_DEPTH: usize = 12;

/// Markers that a line can carry usage. A session log is mostly message
/// content, so this cheap check runs before any JSON parsing.
const USAGE_MARKER: &str = "\"usage\"";
const TURN_CONTEXT_MARKER: &str = "turn_context";
const THREAD_SETTINGS_MARKER: &str = "thread_settings";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum UsagePlatform {
    Claude,
    Codex,
}

/// One log directory to scan, for example `~/.claude/projects`.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageRoot {
    pub platform: UsagePlatform,
    pub directory: String,
}

/// Where the previous run stopped in one file, plus the session context that
/// the Codex log keeps on separate lines.
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageFileState {
    pub offset: u64,
    pub modified_ms: i64,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub effort: Option<String>,
}

/// One request worth of usage.
///
/// Every token field is optional on purpose: a source that does not report a
/// number is reported as absent rather than as zero, because zero reads as
/// "this request was free".
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageRecord {
    pub platform: UsagePlatform,
    pub source: String,
    /// Claude uses `message.id`, Codex uses `response_id`.
    pub dedup_key: String,
    pub session_id: Option<String>,
    /// UTC milliseconds.
    pub ts: i64,
    pub model: Option<String>,
    pub input_tokens: Option<i64>,
    pub output_tokens: Option<i64>,
    pub cache_read_tokens: Option<i64>,
    pub cache_write_tokens: Option<i64>,
    pub total_tokens: Option<i64>,
    pub effort: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum UsageFileStatus {
    /// New bytes were appended; the previous state carried over.
    Appended,
    /// The file has to be read from the start again - it shrank, it was
    /// replaced by different content of the same length, or it is new. The
    /// session context is cleared with it.
    Rewritten,
    /// Nothing new since the last run.
    Unchanged,
    /// The file could not be read; its previous state is kept as it was.
    Failed,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageFileScan {
    pub path: String,
    pub state: UsageFileState,
    pub status: UsageFileStatus,
    pub bytes_read: u64,
    pub record_count: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageRootScan {
    pub platform: UsagePlatform,
    pub directory: String,
    pub exists: bool,
    pub file_count: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageCollection {
    pub records: Vec<UsageRecord>,
    pub files: Vec<UsageFileScan>,
    pub roots: Vec<UsageRootScan>,
    pub elapsed_ms: u64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageCollectRequest {
    pub roots: Vec<UsageRoot>,
    /// Per-file state from the previous run, keyed by absolute path.
    #[serde(default)]
    pub known: HashMap<String, UsageFileState>,
}

// Note: .agents/notes/implemented/feature/2026-09-24-windows-local-ai-usage-and-quota.md
#[tauri::command]
pub async fn usage_collect(request: UsageCollectRequest) -> Result<UsageCollection, String> {
    tauri::async_runtime::spawn_blocking(move || collect(&request))
        .await
        .map_err(|error| format!("Usage collection task failed: {error}"))
}

pub fn collect(request: &UsageCollectRequest) -> UsageCollection {
    let started = Instant::now();
    let mut records = Vec::new();
    let mut files = Vec::new();
    let mut roots = Vec::new();

    for root in &request.roots {
        let directory = Path::new(&root.directory);
        let discovered = discover_session_files(directory);

        roots.push(UsageRootScan {
            platform: root.platform,
            directory: root.directory.clone(),
            exists: directory.is_dir(),
            file_count: discovered.len(),
        });

        for path in discovered {
            let key = path.to_string_lossy().to_string();
            let previous = request.known.get(&key).cloned().unwrap_or_default();

            // A single unreadable file is reported and skipped: the rest of the
            // scan is still worth returning.
            let (state, status, bytes_read, record_count) =
                match collect_file(&root.platform, &path, &previous) {
                    Ok((state, status, bytes, parsed)) => {
                        let count = parsed.len();
                        records.extend(parsed);
                        (state, status, bytes, count)
                    }
                    Err(_) => (previous, UsageFileStatus::Failed, 0, 0),
                };

            files.push(UsageFileScan {
                path: key,
                state,
                status,
                bytes_read,
                record_count,
            });
        }
    }

    UsageCollection {
        records: collapse_duplicates(records),
        files,
        roots,
        elapsed_ms: started.elapsed().as_millis() as u64,
    }
}

/// One record per dedup key, out of the several lines that legitimately carry
/// it.
///
/// Claude Code writes an assistant message once per content block and Codex
/// writes an event per response, so the same `message.id` or `response_id`
/// arrives again and again in a single pass, each line reporting the usage as it
/// stood at that moment. Handing all of them over would make the array mean two
/// different things at once - a log of lines and a list of requests - and any
/// caller summing it would count the same request several times.
///
/// The most complete line wins rather than the last one: the count grows while
/// the reply streams, but a line that carries no usage of its own can still be
/// written last.
fn collapse_duplicates(records: Vec<UsageRecord>) -> Vec<UsageRecord> {
    let mut positions: HashMap<(UsagePlatform, String), usize> = HashMap::new();
    let mut unique: Vec<UsageRecord> = Vec::new();

    for record in records {
        let key = (record.platform, record.dedup_key.clone());
        match positions.get(&key) {
            Some(&index) => {
                if is_more_complete(&record, &unique[index]) {
                    unique[index] = record;
                }
            }
            None => {
                positions.insert(key, unique.len());
                unique.push(record);
            }
        }
    }

    unique
}

fn is_more_complete(candidate: &UsageRecord, current: &UsageRecord) -> bool {
    match (candidate.total_tokens, current.total_tokens) {
        (Some(candidate), Some(current)) => candidate > current,
        // A line that states nothing cannot improve on one that states a total.
        (Some(_), None) => true,
        (None, Some(_)) => false,
        (None, None) => false,
    }
}

fn discover_session_files(directory: &Path) -> Vec<PathBuf> {
    let mut files = Vec::new();
    walk(directory, MAX_WALK_DEPTH, &mut files);
    // Sorted so a scan is reproducible; the caller keys state by path anyway.
    files.sort();
    files
}

fn walk(directory: &Path, depth: usize, files: &mut Vec<PathBuf>) {
    if depth == 0 {
        return;
    }
    let Ok(entries) = fs::read_dir(directory) else {
        return;
    };

    for entry in entries.flatten() {
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        let path = entry.path();
        if file_type.is_dir() {
            walk(&path, depth - 1, files);
        } else if file_type.is_file() && is_session_log(&path) {
            files.push(path);
        }
    }
}

/// Session logs are JSONL. The same directories also hold plain notes.
fn is_session_log(path: &Path) -> bool {
    match path.extension() {
        Some(extension) => extension.eq_ignore_ascii_case("jsonl"),
        None => false,
    }
}

fn modified_ms(metadata: &fs::Metadata) -> i64 {
    metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0)
}

/// Codex carries the model and the reasoning effort on context lines, so the
/// value has to survive from one line to the next - and from one run to the
/// next, which is why it lives in the persisted file state.
#[derive(Debug, Clone, Default)]
struct SessionContext {
    model: Option<String>,
    effort: Option<String>,
}

fn collect_file(
    platform: &UsagePlatform,
    path: &Path,
    previous: &UsageFileState,
) -> std::io::Result<(UsageFileState, UsageFileStatus, u64, Vec<UsageRecord>)> {
    let metadata = fs::metadata(path)?;
    let size = metadata.len();
    let modified = modified_ms(&metadata);

    let mut state = previous.clone();
    let must_restart = must_restart(previous, size, modified);

    let start = if must_restart {
        // The content this state described is gone, so the inherited session
        // context goes with it.
        state = UsageFileState {
            offset: 0,
            modified_ms: modified,
            model: None,
            effort: None,
        };
        0
    } else {
        state.offset
    };
    state.modified_ms = modified;

    if start >= size {
        return Ok((state, UsageFileStatus::Unchanged, 0, Vec::new()));
    }

    // A file the collector has never seen is reported like a rewrite, because
    // that is what it is: the reading starts at the beginning. A file seen
    // before whose first line is still incomplete is not a rewrite - only
    // nothing has been consumed from it yet.
    let is_new_file = previous.offset == 0 && previous.modified_ms == 0;
    let status = if must_restart || is_new_file {
        UsageFileStatus::Rewritten
    } else {
        UsageFileStatus::Appended
    };

    let mut buffer = read_from(path, start, size)?;
    // Only whole lines are consumed. A half written line stays in the file and
    // is picked up by the next run.
    let consumed = match buffer.iter().rposition(|byte| *byte == b'\n') {
        Some(position) => position + 1,
        None => 0,
    };
    buffer.truncate(consumed);
    state.offset = start + consumed as u64;

    let mut context = SessionContext {
        model: state.model.clone(),
        effort: state.effort.clone(),
    };
    let mut records = Vec::new();
    for line in buffer.split(|byte| *byte == b'\n') {
        // JSONL is UTF-8 by definition, so a line that is not valid UTF-8 is
        // damaged and cannot be trusted for token counts.
        let Ok(line) = std::str::from_utf8(line) else {
            continue;
        };
        let line = line.strip_suffix('\r').unwrap_or(line);
        if let Some(record) = parse_line(line, platform, &mut context) {
            records.push(record);
        }
    }

    state.model = context.model;
    state.effort = context.effort;
    Ok((state, status, consumed as u64, records))
}

/// Whether the position from the previous run can still be trusted.
///
/// An offset past the end means the file was truncated. An offset at the end
/// with a different modification time means the content was replaced by other
/// content of the same length - resuming there would silently skip it.
fn must_restart(previous: &UsageFileState, size: u64, modified: i64) -> bool {
    previous.offset > size
        || (previous.offset == size && previous.offset > 0 && previous.modified_ms != modified)
}

fn read_from(path: &Path, start: u64, size: u64) -> std::io::Result<Vec<u8>> {
    let mut file = File::open(path)?;
    file.seek(SeekFrom::Start(start))?;

    let budget = (size - start).min(MAX_BYTES_PER_FILE);
    let mut buffer = vec![0_u8; budget as usize];
    let mut filled = 0_usize;
    while filled < buffer.len() {
        let read = file.read(&mut buffer[filled..])?;
        if read == 0 {
            break;
        }
        filled += read;
    }
    buffer.truncate(filled);
    Ok(buffer)
}

/// Returns `None` for any line that carries no usage: that is the common case,
/// not an error.
fn parse_line(
    line: &str,
    platform: &UsagePlatform,
    context: &mut SessionContext,
) -> Option<UsageRecord> {
    if line.is_empty()
        || !(line.contains(USAGE_MARKER)
            || line.contains(TURN_CONTEXT_MARKER)
            || line.contains(THREAD_SETTINGS_MARKER))
    {
        return None;
    }

    match platform {
        UsagePlatform::Claude => parse_claude_line(line),
        UsagePlatform::Codex => parse_codex_line(line, context),
    }
}

/// Claude Code: `~/.claude/projects/<project>/<session>.jsonl`.
///
/// An `assistant` line holds `message.id`, `message.model` and
/// `message.usage{input_tokens, output_tokens, cache_creation_input_tokens,
/// cache_read_input_tokens}`, all of them on one line.
fn parse_claude_line(line: &str) -> Option<UsageRecord> {
    let root: serde_json::Value = serde_json::from_str(line).ok()?;
    if text_at(&root, &["type"]).as_deref() != Some("assistant") {
        return None;
    }

    let message = root.get("message")?;
    let usage = message.get("usage")?;

    let dedup_key = text_at(message, &["id"])?;
    let timestamp = text_at(&root, &["timestamp"])?;
    let ts = iso_to_millis(&timestamp)?;

    let input = integer_at(usage, "input_tokens");
    let output = integer_at(usage, "output_tokens");
    let cache_write = integer_at(usage, "cache_creation_input_tokens");
    let cache_read = integer_at(usage, "cache_read_input_tokens");

    Some(UsageRecord {
        platform: UsagePlatform::Claude,
        source: SOURCE_LOCAL_SESSION.to_string(),
        dedup_key,
        session_id: text_at(&root, &["sessionId"]),
        ts,
        model: text_at(message, &["model"]),
        input_tokens: input,
        output_tokens: output,
        cache_read_tokens: cache_read,
        cache_write_tokens: cache_write,
        // Claude reports `input_tokens` without the cache, and gives no total,
        // so the total exists only when all four parts are present.
        total_tokens: sum_if_complete(&[input, output, cache_write, cache_read]),
        // The effort is on the same line as the usage, so nothing is inherited.
        effort: text_at(&root, &["effort"]),
    })
}

/// Codex: `~/.codex/sessions/<year>/<month>/<day>/rollout-*.jsonl`.
///
/// A `token_usage_record` line holds the per-response usage in `payload.usage`
/// and the dedup key in `payload.response_id`. `turn_token_usage` and
/// `thread_token_usage` on the same line are running totals and must not be
/// summed. Neither the model nor the effort is on that line, so both are
/// inherited from the context lines.
fn parse_codex_line(line: &str, context: &mut SessionContext) -> Option<UsageRecord> {
    let root: serde_json::Value = serde_json::from_str(line).ok()?;
    let payload = root.get("payload")?;

    match text_at(&root, &["type"]).as_deref() {
        Some("turn_context") => {
            apply_codex_settings(context, payload);
            return None;
        }
        Some("event_msg") => {
            if text_at(payload, &["type"]).as_deref() == Some("thread_settings_applied") {
                if let Some(settings) = payload.get("thread_settings") {
                    apply_codex_settings(context, settings);
                }
            }
            return None;
        }
        Some("token_usage_record") => {}
        _ => return None,
    }

    let usage = payload.get("usage")?;
    let dedup_key = text_at(payload, &["response_id"])?;
    let timestamp = text_at(&root, &["timestamp"])?;
    let ts = iso_to_millis(&timestamp)?;

    let input = integer_at(usage, "input_tokens");
    let output = integer_at(usage, "output_tokens");

    // Codex states the total explicitly, and its `input_tokens` already
    // contains the cached part, so the cache is never added on top.
    let total = integer_at(usage, "total_tokens").or(match (input, output) {
        (Some(input), Some(output)) => Some(input + output),
        _ => None,
    });

    Some(UsageRecord {
        platform: UsagePlatform::Codex,
        source: SOURCE_LOCAL_SESSION.to_string(),
        dedup_key,
        session_id: text_at(payload, &["session_id"]),
        ts,
        model: context.model.clone(),
        input_tokens: input,
        output_tokens: output,
        cache_read_tokens: integer_at(usage, "cached_input_tokens"),
        cache_write_tokens: integer_at(usage, "cache_write_input_tokens"),
        total_tokens: total,
        effort: context.effort.clone(),
    })
}

/// Settings lines nest the same three carries differently across Codex
/// versions, so every known location is tried in order.
fn codex_effort(settings: &serde_json::Value) -> Option<String> {
    const PATHS: [&[&str]; 5] = [
        &["effort"],
        &["reasoning_effort"],
        &["thread_settings", "reasoning_effort"],
        &[
            "thread_settings",
            "collaboration_mode",
            "settings",
            "reasoning_effort",
        ],
        &["collaboration_mode", "settings", "reasoning_effort"],
    ];

    PATHS.iter().find_map(|path| text_at(settings, path))
}

fn apply_codex_settings(context: &mut SessionContext, settings: &serde_json::Value) {
    if let Some(model) = text_at(settings, &["model"]) {
        context.model = Some(model);
    }
    // A context line that omits the effort keeps the previous one.
    if let Some(effort) = codex_effort(settings) {
        context.effort = Some(effort);
    }
}

fn text_at(value: &serde_json::Value, path: &[&str]) -> Option<String> {
    let mut cursor = value;
    for key in path {
        cursor = cursor.get(key)?;
    }
    let text = cursor.as_str()?;
    if text.is_empty() {
        return None;
    }
    Some(text.to_string())
}

fn integer_at(value: &serde_json::Value, key: &str) -> Option<i64> {
    let number = value.get(key)?;
    if let Some(integer) = number.as_i64() {
        return Some(integer);
    }
    let float = number.as_f64()?;
    if !float.is_finite() {
        return None;
    }
    Some(float as i64)
}

/// A partial usage block yields no total at all rather than a number built
/// from whichever parts happened to be present.
fn sum_if_complete(parts: &[Option<i64>]) -> Option<i64> {
    let mut total = 0_i64;
    for part in parts {
        total += (*part)?;
    }
    Some(total)
}

fn iso_to_millis(value: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|time| time.timestamp_millis())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn claude_line(message_id: &str, input_tokens: i64) -> String {
        format!(
            concat!(
                r#"{{"type":"assistant","timestamp":"2026-05-01T10:00:00.000Z","sessionId":"s-1","#,
                r#""effort":"high","message":{{"id":"{}","model":"claude-opus-4-1","#,
                r#""usage":{{"input_tokens":{},"output_tokens":20,"#,
                r#""cache_creation_input_tokens":5,"cache_read_input_tokens":7}}}}}}"#
            ),
            message_id, input_tokens
        )
    }

    fn codex_context_line(effort_json: &str) -> String {
        format!(
            r#"{{"type":"turn_context","timestamp":"2026-05-01T09:00:00.000Z","payload":{{"model":"gpt-5.2-codex"{effort_json}}}}}"#
        )
    }

    fn codex_usage_line(response_id: &str) -> String {
        format!(
            concat!(
                r#"{{"type":"token_usage_record","timestamp":"2026-05-01T09:00:10.000Z","payload":{{"#,
                r#""session_id":"s-2","response_id":"{}","usage":{{"input_tokens":1000,"#,
                r#""cached_input_tokens":400,"cache_write_input_tokens":0,"output_tokens":100,"#,
                r#""total_tokens":1100}},"turn_token_usage":{{"input_tokens":99999}}}}}}"#
            ),
            response_id
        )
    }

    fn parse(line: &str, platform: UsagePlatform) -> Option<UsageRecord> {
        parse_line(line, &platform, &mut SessionContext::default())
    }

    fn record(line: &str, platform: UsagePlatform) -> UsageRecord {
        parse(line, platform).expect("line should yield a record")
    }

    /// Same line as `claude_line`, with the output count spelled out: it is the
    /// number that grows while a reply streams.
    fn claude_line_with_output(message_id: &str, output_tokens: i64) -> String {
        format!(
            concat!(
                r#"{{"type":"assistant","timestamp":"2026-05-01T10:00:00.000Z","sessionId":"s-1","#,
                r#""message":{{"id":"{}","model":"claude-opus-4-1","#,
                r#""usage":{{"input_tokens":100,"output_tokens":{},"#,
                r#""cache_creation_input_tokens":5,"cache_read_input_tokens":7}}}}}}"#
            ),
            message_id, output_tokens
        )
    }

    fn temp_path(name: &str) -> PathBuf {
        let mut path = std::env::temp_dir();
        path.push(format!("lithe-usage-{}-{name}", std::process::id()));
        let _ = fs::remove_file(&path);
        path
    }

    fn scan(
        path: &Path,
        platform: UsagePlatform,
        previous: &UsageFileState,
    ) -> (UsageFileState, UsageFileStatus, Vec<UsageRecord>) {
        let (state, status, _, records) =
            collect_file(&platform, path, previous).expect("scan should succeed");
        (state, status, records)
    }

    fn append(path: &Path, text: &str) {
        let mut file = fs::OpenOptions::new().append(true).open(path).unwrap();
        file.write_all(text.as_bytes()).unwrap();
    }

    #[test]
    fn claude_line_totals_the_four_components() {
        let record = record(&claude_line("msg-1", 100), UsagePlatform::Claude);

        assert_eq!(record.dedup_key, "msg-1");
        assert_eq!(record.session_id.as_deref(), Some("s-1"));
        assert_eq!(record.model.as_deref(), Some("claude-opus-4-1"));
        assert_eq!(record.effort.as_deref(), Some("high"));
        assert_eq!(record.input_tokens, Some(100));
        assert_eq!(record.output_tokens, Some(20));
        assert_eq!(record.cache_write_tokens, Some(5));
        assert_eq!(record.cache_read_tokens, Some(7));
        // `input_tokens` excludes the cache, so all four parts add up.
        assert_eq!(record.total_tokens, Some(132));
        assert_eq!(
            chrono::DateTime::from_timestamp_millis(record.ts)
                .unwrap()
                .to_rfc3339(),
            "2026-05-01T10:00:00+00:00"
        );
    }

    #[test]
    fn claude_lines_that_are_not_assistant_turns_are_ignored() {
        let user_line = r#"{"type":"user","timestamp":"2026-05-01T10:00:00.000Z","message":{"id":"msg-u","usage":{"input_tokens":1}}}"#;
        let assistant_without_usage = r#"{"type":"assistant","timestamp":"2026-05-01T10:00:00.000Z","message":{"id":"msg-a","model":"m"}}"#;

        assert!(parse(user_line, UsagePlatform::Claude).is_none());
        assert!(parse(assistant_without_usage, UsagePlatform::Claude).is_none());
    }

    #[test]
    fn claude_line_without_every_usage_part_has_no_total() {
        let partial = r#"{"type":"assistant","timestamp":"2026-05-01T10:00:00.000Z","message":{"id":"msg-p","model":"m","usage":{"input_tokens":10,"output_tokens":2}}}"#;

        let record = record(partial, UsagePlatform::Claude);

        assert_eq!(record.total_tokens, None);
        assert_eq!(record.output_tokens, Some(2));
    }

    #[test]
    fn claude_lines_without_a_dedup_key_or_timestamp_are_dropped() {
        let no_id = r#"{"type":"assistant","timestamp":"2026-05-01T10:00:00.000Z","message":{"model":"m","usage":{"input_tokens":1}}}"#;
        let no_timestamp = r#"{"type":"assistant","message":{"id":"msg-t","model":"m","usage":{"input_tokens":1}}}"#;
        let broken_timestamp = r#"{"type":"assistant","timestamp":"yesterday","message":{"id":"msg-b","model":"m","usage":{"input_tokens":1}}}"#;

        assert!(parse(no_id, UsagePlatform::Claude).is_none());
        assert!(parse(no_timestamp, UsagePlatform::Claude).is_none());
        assert!(parse(broken_timestamp, UsagePlatform::Claude).is_none());
    }

    #[test]
    fn codex_records_inherit_the_model_and_the_effort_from_the_context() {
        let mut context = SessionContext::default();

        assert!(parse_line(
            &codex_context_line(r#","effort":"medium""#),
            &UsagePlatform::Codex,
            &mut context
        )
        .is_none());

        let record = parse_line(
            &codex_usage_line("resp-1"),
            &UsagePlatform::Codex,
            &mut context,
        )
        .expect("usage line should yield a record");

        assert_eq!(record.model.as_deref(), Some("gpt-5.2-codex"));
        assert_eq!(record.effort.as_deref(), Some("medium"));
        assert_eq!(record.session_id.as_deref(), Some("s-2"));
        assert_eq!(record.input_tokens, Some(1000));
        assert_eq!(record.cache_read_tokens, Some(400));
        // The running totals on the same line are not summed in.
        assert_eq!(record.total_tokens, Some(1100));
    }

    #[test]
    fn codex_finds_the_effort_in_any_known_nesting() {
        let cases = [
            (r#","effort":"high""#, "high"),
            (r#","reasoning_effort":"low""#, "low"),
            (
                r#","thread_settings":{"reasoning_effort":"minimal"}"#,
                "minimal",
            ),
            (
                r#","thread_settings":{"collaboration_mode":{"settings":{"reasoning_effort":"xhigh"}}}"#,
                "xhigh",
            ),
            (
                r#","collaboration_mode":{"settings":{"reasoning_effort":"none"}}"#,
                "none",
            ),
        ];

        for (effort_json, expected) in cases {
            let mut context = SessionContext::default();
            parse_line(
                &codex_context_line(effort_json),
                &UsagePlatform::Codex,
                &mut context,
            );

            assert_eq!(context.effort.as_deref(), Some(expected), "{effort_json}");
        }
    }

    #[test]
    fn codex_reads_the_settings_applied_event() {
        let settings_line = r#"{"type":"event_msg","timestamp":"2026-05-01T09:00:01.000Z","payload":{"type":"thread_settings_applied","thread_settings":{"model":"deepseek-flash","reasoning_effort":"high"}}}"#;
        let mut context = SessionContext::default();

        assert!(parse_line(settings_line, &UsagePlatform::Codex, &mut context).is_none());
        assert_eq!(context.model.as_deref(), Some("deepseek-flash"));
        assert_eq!(context.effort.as_deref(), Some("high"));
    }

    #[test]
    fn codex_keeps_the_previous_effort_when_a_later_context_omits_it() {
        let mut context = SessionContext::default();

        parse_line(
            &codex_context_line(r#","effort":"high""#),
            &UsagePlatform::Codex,
            &mut context,
        );
        parse_line(&codex_context_line(""), &UsagePlatform::Codex, &mut context);

        assert_eq!(context.effort.as_deref(), Some("high"));
        assert_eq!(context.model.as_deref(), Some("gpt-5.2-codex"));
    }

    #[test]
    fn codex_falls_back_to_input_plus_output_for_the_total() {
        let line = r#"{"type":"token_usage_record","timestamp":"2026-05-01T09:00:10.000Z","payload":{"session_id":"s-2","response_id":"resp-2","usage":{"input_tokens":100,"output_tokens":20}}}"#;

        let record = record(line, UsagePlatform::Codex);

        assert_eq!(record.total_tokens, Some(120));
        assert_eq!(record.effort, None);
    }

    #[test]
    fn lines_without_usage_are_not_records() {
        assert!(parse("", UsagePlatform::Claude).is_none());
        assert!(parse("", UsagePlatform::Codex).is_none());
        assert!(parse("   ", UsagePlatform::Claude).is_none());
        assert!(parse("{ not json", UsagePlatform::Claude).is_none());
        assert!(parse(
            r#"{"type":"event_msg","payload":{"type":"agent_message"}}"#,
            UsagePlatform::Codex
        )
        .is_none());
    }

    #[test]
    fn a_file_is_read_once_and_then_only_appended_bytes_are_read() {
        let path = temp_path("append");
        fs::write(&path, format!("{}\n", claude_line("msg-1", 100))).unwrap();

        let (first, first_status, first_records) =
            scan(&path, UsagePlatform::Claude, &UsageFileState::default());
        assert_eq!(first_status, UsageFileStatus::Rewritten);
        assert_eq!(first_records.len(), 1);
        assert_eq!(first.offset, fs::metadata(&path).unwrap().len());

        let (second, second_status, second_records) = scan(&path, UsagePlatform::Claude, &first);
        assert_eq!(second_status, UsageFileStatus::Unchanged);
        assert!(second_records.is_empty());
        assert_eq!(second.offset, first.offset);

        append(&path, &format!("{}\n", claude_line("msg-2", 200)));

        let (third, third_status, third_records) = scan(&path, UsagePlatform::Claude, &second);
        assert_eq!(third_status, UsageFileStatus::Appended);
        assert_eq!(third_records.len(), 1);
        assert_eq!(third_records[0].dedup_key, "msg-2");
        assert_eq!(third.offset, fs::metadata(&path).unwrap().len());

        let _ = fs::remove_file(&path);
    }

    #[test]
    fn a_shortened_file_is_read_again_without_the_discarded_context() {
        let path = temp_path("shortened");
        fs::write(
            &path,
            format!(
                "{}\n{}\n",
                codex_context_line(r#","effort":"high""#),
                codex_usage_line("resp-1")
            ),
        )
        .unwrap();

        let (first, _, first_records) =
            scan(&path, UsagePlatform::Codex, &UsageFileState::default());
        assert_eq!(first_records.len(), 1);
        assert_eq!(first.model.as_deref(), Some("gpt-5.2-codex"));

        // The log was replaced by a shorter one: resume is impossible, and the
        // model that belonged to the discarded lines must not survive.
        fs::write(&path, format!("{}\n", codex_usage_line("resp-2"))).unwrap();

        let (second, second_status, second_records) = scan(&path, UsagePlatform::Codex, &first);
        assert_eq!(second_status, UsageFileStatus::Rewritten);
        assert_eq!(second.offset, fs::metadata(&path).unwrap().len());
        assert_eq!(second_records.len(), 1);
        assert_eq!(second_records[0].dedup_key, "resp-2");
        assert_eq!(second_records[0].model, None);
        assert_eq!(second.model, None);

        let _ = fs::remove_file(&path);
    }

    #[test]
    fn a_line_without_a_newline_waits_for_the_next_scan() {
        let path = temp_path("partial");
        let line = claude_line("msg-9", 42);
        fs::write(&path, &line).unwrap();

        let (first, _, first_records) =
            scan(&path, UsagePlatform::Claude, &UsageFileState::default());
        assert!(first_records.is_empty());
        assert_eq!(first.offset, 0);

        append(&path, "\n");

        let (second, second_status, second_records) = scan(&path, UsagePlatform::Claude, &first);
        assert_eq!(second_status, UsageFileStatus::Appended);
        assert_eq!(second_records.len(), 1);
        assert_eq!(second.offset, fs::metadata(&path).unwrap().len());

        let _ = fs::remove_file(&path);
    }

    #[test]
    fn a_line_ending_in_a_carriage_return_still_parses() {
        let path = temp_path("crlf");
        fs::write(&path, format!("{}\r\n", claude_line("msg-crlf", 5))).unwrap();

        let (_, _, records) = scan(&path, UsagePlatform::Claude, &UsageFileState::default());

        assert_eq!(records.len(), 1);
        assert_eq!(records[0].dedup_key, "msg-crlf");
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn an_offset_past_the_end_or_a_replaced_file_cannot_be_resumed() {
        let state = UsageFileState {
            offset: 100,
            modified_ms: 1_000,
            model: None,
            effort: None,
        };

        assert!(must_restart(&state, 100, 2_000));
        assert!(must_restart(&state, 50, 1_000));
        assert!(!must_restart(&state, 100, 1_000));
        assert!(!must_restart(&state, 150, 2_000));
        // A file the collector has never seen starts at the beginning anyway.
        assert!(!must_restart(&UsageFileState::default(), 0, 7));
    }

    fn collect_from_root(root: &Path, known: HashMap<String, UsageFileState>) -> UsageCollection {
        collect(&UsageCollectRequest {
            roots: vec![UsageRoot {
                platform: UsagePlatform::Claude,
                directory: root.to_string_lossy().to_string(),
            }],
            known,
        })
    }

    #[test]
    fn collect_walks_nested_directories_and_ignores_other_files() {
        let root = temp_path("walk-root");
        let nested = root.join("project").join("session");
        fs::create_dir_all(&nested).unwrap();
        fs::write(
            nested.join("session.jsonl"),
            format!("{}\n", claude_line("msg-nested", 10)),
        )
        .unwrap();
        fs::write(root.join("MEMORY.md"), "not a session log").unwrap();

        let collection = collect_from_root(&root, HashMap::new());

        assert_eq!(collection.roots.len(), 1);
        assert!(collection.roots[0].exists);
        assert_eq!(collection.roots[0].file_count, 1);
        assert_eq!(collection.records.len(), 1);
        assert_eq!(collection.files.len(), 1);
        assert_eq!(collection.files[0].status, UsageFileStatus::Rewritten);

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn collect_hands_back_the_state_that_makes_the_next_run_incremental() {
        let root = temp_path("state-root");
        let session = root.join("session.jsonl");
        fs::create_dir_all(&root).unwrap();
        fs::write(&session, format!("{}\n", claude_line("msg-state", 10))).unwrap();

        let first = collect_from_root(&root, HashMap::new());
        let known = first
            .files
            .iter()
            .map(|file| (file.path.clone(), file.state.clone()))
            .collect();
        let second = collect_from_root(&root, known);

        assert_eq!(second.records.len(), 0);
        assert_eq!(second.files[0].status, UsageFileStatus::Unchanged);
        assert_eq!(second.files[0].bytes_read, 0);

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_message_written_once_per_content_block_is_collected_once() {
        let root = temp_path("dedupe-root");
        fs::create_dir_all(&root).unwrap();
        let session = root.join("session.jsonl");
        // Claude Code rewrites the whole usage on every line of one message, so
        // the same id arrives several times in a single pass.
        fs::write(
            &session,
            format!(
                "{}\n{}\n{}\n",
                claude_line_with_output("msg-dup", 20),
                claude_line_with_output("msg-dup", 40),
                claude_line_with_output("msg-other", 20)
            ),
        )
        .unwrap();

        let collection = collect_from_root(&root, HashMap::new());

        assert_eq!(collection.records.len(), 2);
        // 100 input + 40 output + 5 cache write + 7 cache read
        let repeated = collection
            .records
            .iter()
            .find(|record| record.dedup_key == "msg-dup")
            .expect("the repeated message is reported");
        assert_eq!(repeated.total_tokens, Some(152));
        // Keys keep the order they were first seen in, so the array stays
        // chronological for the caller.
        assert_eq!(collection.records[0].dedup_key, "msg-dup");
        assert_eq!(collection.records[1].dedup_key, "msg-other");

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn collapse_duplicates_keeps_the_most_complete_record() {
        let bigger = record(&claude_line_with_output("msg-1", 40), UsagePlatform::Claude);
        let smaller = record(&claude_line_with_output("msg-1", 20), UsagePlatform::Claude);

        // A later line that reports less does not win for being later.
        let collapsed = collapse_duplicates(vec![bigger.clone(), smaller.clone()]);
        assert_eq!(collapsed.len(), 1);
        assert_eq!(collapsed[0].total_tokens, bigger.total_tokens);

        let collapsed = collapse_duplicates(vec![smaller, bigger.clone()]);
        assert_eq!(collapsed.len(), 1);
        assert_eq!(collapsed[0].total_tokens, bigger.total_tokens);

        // Different keys are different requests.
        let other = record(&claude_line_with_output("msg-2", 20), UsagePlatform::Claude);
        assert_eq!(collapse_duplicates(vec![bigger, other]).len(), 2);
    }

    #[test]
    fn a_missing_root_is_reported_instead_of_failing_the_scan() {
        let root = temp_path("missing-root");
        let collection = collect_from_root(&root, HashMap::new());

        assert_eq!(collection.roots.len(), 1);
        assert!(!collection.roots[0].exists);
        assert_eq!(collection.roots[0].file_count, 0);
        assert!(collection.records.is_empty());
        assert!(collection.files.is_empty());
    }

    #[test]
    fn a_vanished_file_is_dropped_from_the_scan() {
        let root = temp_path("vanished-root");
        let session = root.join("session.jsonl");
        fs::create_dir_all(&root).unwrap();
        fs::write(&session, format!("{}\n", claude_line("msg-a", 10))).unwrap();

        let first = collect_from_root(&root, HashMap::new());
        let known: HashMap<String, UsageFileState> = first
            .files
            .iter()
            .map(|file| (file.path.clone(), file.state.clone()))
            .collect();
        assert_eq!(first.records.len(), 1);

        // Session logs are rotated away by their own tools: losing one costs
        // its lines, not the scan. The records already collected stay with the
        // caller, which is why they are persisted on that side.
        let _ = fs::remove_file(&session);
        let second = collect_from_root(&root, known);

        assert_eq!(second.records.len(), 0);
        assert!(second.files.is_empty());

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_file_that_cannot_be_opened_reports_an_error() {
        let missing = temp_path("gone");

        assert!(
            collect_file(&UsagePlatform::Claude, &missing, &UsageFileState::default()).is_err()
        );
    }
}
