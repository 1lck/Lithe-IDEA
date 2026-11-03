//! Merges bounded native log tails into structured timelines, including read-only v1 compatibility.

use super::channel::{validate_segment, LogChannel, LogError};
use super::logging::{sanitize_log_text_unbounded, LOG_CATEGORIES, MAX_LOG_EXPORT_BYTES};
use super::record::{decode_line, DecodedLogLine, LogLevel, LogRecord};
use super::redaction::redact_log_field;
use chrono::{DateTime, FixedOffset};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// One native text tail. Offsets describe the supplied evidence without reading the file again.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LogSourceV2 {
    /// File relative to a session, sessions/name/, or a legacy category directory.
    pub relative_path: String,
    /// Bounded UTF-8 tail, possibly starting inside a physical line.
    pub text: String,
    /// True when the first supplied line is incomplete and must be discarded.
    #[serde(default)]
    pub starts_mid_line: bool,
    /// One-based line number at the tail's start, including a discarded partial line.
    #[serde(default = "first_line")]
    pub first_line_number: usize,
}
fn first_line() -> usize {
    1
}

/// Stateless query over host-owned evidence; missing filters include all records.
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LogQueryV2Request {
    /// Bounded native tails; Core enforces an additional aggregate 10 MiB input limit.
    #[serde(default)]
    pub sources: Vec<LogSourceV2>,
    /// Root or segmented prefixes matched on slash boundaries.
    #[serde(default)]
    pub channel_prefixes: Vec<String>,
    /// Inclusive minimum severity.
    pub minimum_level: Option<LogLevel>,
    /// Inclusive RFC3339 lower bound, compared as an instant.
    pub since: Option<String>,
    /// Inclusive RFC3339 upper bound, compared as an instant.
    pub until: Option<String>,
    /// Case-insensitive substring across the message, identities, and context.
    pub search: Option<String>,
    /// Exact key=value matches; reserved fields may also be queried.
    #[serde(default)]
    pub fields: BTreeMap<String, String>,
    /// Exact operation identity.
    pub op: Option<String>,
    /// Return the newest 1 through 10000 matches, in ascending time/sequence order.
    pub limit: Option<usize>,
}
/// One owned structured event with its physical source location.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QueriedLogRecord {
    /// Logical channel, resolved from metadata or the validated source path.
    pub channel: String,
    /// Source file relative to the host log root or session.
    pub relative_path: String,
    /// One-based physical line number, including headers and skipped lines.
    pub line_number: usize,
    /// Redacted structured event.
    #[serde(flatten)]
    pub record: LogRecord,
}
/// Counts among all filtered matches, before applying the output limit.
#[derive(Debug, Default, Serialize)]
pub struct ChannelSeverityCounts {
    /// Number of matching WARN events.
    pub warn: usize,
    /// Number of matching ERROR events.
    pub error: usize,
}
/// Owned merged evidence and explicit incompleteness indicators.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LogQueryV2Response {
    /// Newest bounded matches in ascending parsed time, sequence, path, and line order.
    pub records: Vec<QueriedLogRecord>,
    /// Counts over all filtered matches, including matches omitted by the output limit.
    pub channel_counts: BTreeMap<String, ChannelSeverityCounts>,
    /// True if a partial first line, input budget, or output limit omitted evidence.
    pub truncated: bool,
    /// Invalid physical lines; intentionally discarded partial first lines are excluded.
    pub skipped_invalid_lines: usize,
}

fn parse_time(value: &str) -> Result<DateTime<FixedOffset>, LogError> {
    DateTime::parse_from_rfc3339(value).map_err(|_| LogError::new(-32035, "Invalid timestamp"))
}
fn source_channel(path: &str) -> Result<(String, bool), LogError> {
    if path.contains(['\\', ':'])
        || path.chars().any(char::is_control)
        || path
            .split('/')
            .any(|p| p.is_empty() || p == "." || p == "..")
    {
        return Err(LogError::new(-32050, "Invalid query source path"));
    }
    let parts: Vec<_> = path.split('/').collect();
    if parts.len() == 2
        && LOG_CATEGORIES.contains(&parts[0])
        && parts[1].starts_with("lithe.")
        && parts[1].ends_with(".log")
    {
        let channel = match parts[0] {
            "application" => "app",
            "language" => "lsp",
            "git" => "vcs",
            "performance" => "perf",
            other => other,
        };
        return Ok((channel.into(), true));
    }
    let relative = if parts.first() == Some(&"sessions") {
        if parts.len() < 3 {
            return Err(LogError::new(-32050, "Invalid query source path"));
        }
        super::channel::parse_session_directory_name(parts[1])?;
        parts[2..].join("/")
    } else {
        path.into()
    };
    let stem = relative
        .strip_suffix(".log")
        .ok_or_else(|| LogError::new(-32050, "Invalid query source path"))?;
    // The rotation delimiter is outside the channel alphabet. Dotted numeric
    // channel IDs (e.g. server.1) remain active identities, even without a header.
    let stem = if let Some((base, suffix)) = stem.rsplit_once('~') {
        let index = suffix
            .parse::<u32>()
            .map_err(|_| LogError::new(-32050, "Invalid query source path"))?;
        if index == 0 || index.to_string() != suffix {
            return Err(LogError::new(-32050, "Invalid query source path"));
        }
        base
    } else {
        stem
    };
    if stem == "_overflow" {
        return Ok(("_overflow".into(), false));
    }
    let channel = LogChannel::parse(stem)?;
    Ok((channel.as_str().into(), false))
}

fn legacy_record(line: &str) -> Result<LogRecord, LogError> {
    let mut parts = line.splitn(2, ' ');
    let ts = parse_time(parts.next().unwrap_or(""))?
        .with_timezone(&chrono::Utc)
        .to_rfc3339_opts(chrono::SecondsFormat::AutoSi, true);
    let rest = parts.next().unwrap_or("").trim_start();
    let (label, mut body) = rest
        .split_once(' ')
        .ok_or_else(|| LogError::new(-32041, "Invalid line syntax"))?;
    let level = LogLevel::parse(label)?;
    body = body.trim_start();
    let mut fields = BTreeMap::new();
    let mut seq = 0;
    while ["[session=", "[scope=", "[sequence="]
        .iter()
        .any(|prefix| body.starts_with(prefix))
    {
        let tail = &body[1..];
        let (tag, rest) = tail
            .split_once(']')
            .ok_or_else(|| LogError::new(-32041, "Invalid line syntax"))?;
        let (key, value) = tag
            .split_once('=')
            .ok_or_else(|| LogError::new(-32041, "Invalid line syntax"))?;
        match key {
            "sequence" => {
                seq = value
                    .parse()
                    .map_err(|_| LogError::new(-32044, "Invalid sequence number"))?;
            }
            "session" | "scope" => {
                fields.insert(key.into(), value.into());
            }
            _ => return Err(LogError::new(-32041, "Invalid line syntax")),
        }
        body = rest.trim_start();
    }
    // Native v1 writers append schema_version and scalar context after the message.
    let (msg, context) = body.split_once(" schema_version=1").unwrap_or((body, ""));
    let mut op = None;
    for (key, value) in legacy_context(context)? {
        match key.as_str() {
            "sequence" => {
                seq = value
                    .parse()
                    .map_err(|_| LogError::new(-32044, "Invalid sequence number"))?;
            }
            "operationID" | "operation_id" | "op" => {
                op = Some(value);
            }
            _ => {
                fields.insert(key, value);
            }
        }
    }
    Ok(LogRecord {
        ts,
        level,
        seq,
        event: "legacy".into(),
        op,
        msg: msg.into(),
        fields,
    })
}
// V1 hosts emitted JSON strings/objects as well as bare values. Scan balanced JSON
// without splitting inside quotes or nested containers; preserve objects as compact text.
fn legacy_context(mut input: &str) -> Result<Vec<(String, String)>, LogError> {
    let invalid = || LogError::new(-32041, "Invalid line syntax");
    let mut fields = Vec::new();
    input = input.trim_start();
    while !input.is_empty() {
        let (key, rest) = input.split_once('=').ok_or_else(invalid)?;
        if key.is_empty() || key.chars().any(char::is_whitespace) {
            return Err(invalid());
        }
        let mut quoted = false;
        let mut escaped = false;
        let mut depth = 0usize;
        let mut end = rest.len();
        for (index, c) in rest.char_indices() {
            if escaped {
                escaped = false;
                continue;
            }
            if quoted && c == '\\' {
                escaped = true;
                continue;
            }
            if c == '"' {
                quoted = !quoted;
                continue;
            }
            if !quoted {
                match c {
                    '{' | '[' => depth += 1,
                    '}' | ']' => depth = depth.checked_sub(1).ok_or_else(invalid)?,
                    ' ' if depth == 0 => {
                        end = index;
                        break;
                    }
                    _ => {}
                }
            }
        }
        if quoted || escaped || depth != 0 {
            return Err(invalid());
        }
        let value = &rest[..end];
        if value.is_empty() {
            return Err(invalid());
        }
        let value = if value.starts_with('"') {
            serde_json::from_str::<String>(value).map_err(|_| invalid())?
        } else {
            value.to_owned()
        };
        fields.push((key.into(), value));
        input = rest[end..].trim_start();
    }
    Ok(fields)
}

fn field_matches(record: &LogRecord, key: &str, value: &str) -> bool {
    match key {
        "ts" => record.ts == value,
        "level" => record.level.label() == value,
        "seq" => record.seq.to_string() == value,
        "event" => record.event == value,
        "op" => record.op.as_deref() == Some(value),
        "msg" => record.msg == value,
        _ => record.fields.get(key).is_some_and(|v| v == value),
    }
}
fn redact_record(mut record: LogRecord) -> LogRecord {
    record.msg = sanitize_log_text_unbounded(&record.msg);
    for (key, value) in &mut record.fields {
        *value = redact_log_field(key, value);
    }
    record
}

/// Parses and merges only supplied evidence. Invalid lines are counted; invalid query arguments fail.
/// Channel counts use the same filters as records, before limiting the newest returned matches.
pub fn query_logs_v2(request: LogQueryV2Request) -> Result<LogQueryV2Response, LogError> {
    for prefix in &request.channel_prefixes {
        if prefix != "_overflow" {
            LogChannel::parse(prefix)?;
        }
    }
    for key in request.fields.keys() {
        validate_segment(key)?;
    }
    let since = request.since.as_deref().map(parse_time).transpose()?;
    let until = request.until.as_deref().map(parse_time).transpose()?;
    if since.zip(until).is_some_and(|(a, b)| a > b) {
        return Err(LogError::new(-32052, "Query time range is reversed"));
    }
    let mut response = LogQueryV2Response {
        records: Vec::new(),
        channel_counts: BTreeMap::new(),
        truncated: false,
        skipped_invalid_lines: 0,
    };
    let needle = request.search.as_deref().unwrap_or("").to_lowercase();
    let mut remaining = MAX_LOG_EXPORT_BYTES;
    let limit = request.limit.unwrap_or(2000).clamp(1, 10000);
    let mut records = BTreeMap::new();
    for (source_index, source) in request.sources.into_iter().enumerate() {
        let (mut channel, legacy) = source_channel(&source.relative_path)?;
        if source.first_line_number == 0 {
            return Err(LogError::new(-32050, "Invalid query source path"));
        }
        let mut start = 0;
        for (index, line) in source.text.split_terminator('\n').enumerate() {
            let physical_bytes = line.len() + usize::from(start + line.len() < source.text.len());
            start += physical_bytes;
            if physical_bytes > remaining {
                response.truncated = true;
                break;
            }
            remaining -= physical_bytes;
            if index == 0 && source.starts_mid_line {
                response.truncated = true;
                continue;
            }
            let line = line.strip_suffix('\r').unwrap_or(line);
            let parsed = if legacy {
                legacy_record(line).map(DecodedLogLine::Record)
            } else {
                decode_line(line)
            };
            let record = match parsed {
                Ok(DecodedLogLine::Header(header)) => {
                    if index == 0 && source.first_line_number == 1 && !source.starts_mid_line {
                        channel = header.channel;
                    } else {
                        response.skipped_invalid_lines += 1;
                    }
                    continue;
                }
                Ok(DecodedLogLine::Record(record)) => redact_record(record),
                Err(_) => {
                    response.skipped_invalid_lines += 1;
                    continue;
                }
            };
            if !request.channel_prefixes.is_empty()
                && !request
                    .channel_prefixes
                    .iter()
                    .any(|prefix| channel == *prefix || channel.starts_with(&format!("{prefix}/")))
            {
                continue;
            }
            let time = parse_time(&record.ts)?;
            if request
                .minimum_level
                .is_some_and(|level| record.level < level)
                || since.is_some_and(|bound| time < bound)
                || until.is_some_and(|bound| time > bound)
                || request
                    .op
                    .as_ref()
                    .is_some_and(|op| record.op.as_ref() != Some(op))
                || !request
                    .fields
                    .iter()
                    .all(|(key, value)| field_matches(&record, key, value))
            {
                continue;
            }
            if !needle.is_empty() {
                let text = format!(
                    "{} {} {} {} {:?}",
                    channel,
                    record.event,
                    record.op.as_deref().unwrap_or(""),
                    record.msg,
                    record.fields
                )
                .to_lowercase();
                if !text.contains(&needle) {
                    continue;
                }
            }
            let counts = response.channel_counts.entry(channel.clone()).or_default();
            if record.level == LogLevel::Warn {
                counts.warn += 1;
            }
            if record.level == LogLevel::Error {
                counts.error += 1;
            }
            let line_number = source.first_line_number.saturating_add(index);
            // Include source ordinal so duplicate snapshots remain separate evidence.
            let key = (
                time,
                record.seq,
                source.relative_path.clone(),
                line_number,
                source_index,
            );
            records.insert(
                key,
                QueriedLogRecord {
                    channel: channel.clone(),
                    relative_path: source.relative_path.clone(),
                    line_number,
                    record,
                },
            );
            if records.len() > limit {
                records.pop_first();
                response.truncated = true;
            }
        }
    }
    response.records = records.into_values().collect();
    Ok(response)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn headerless_queries_preserve_dotted_channels_rotations_and_reserved_filters() {
        let line = "2026-11-03T08:00:01.123Z WARN seq=1 event=vcs.git.failed msg=failed";
        let response = query_logs_v2(
            serde_json::from_value(json!({
                "sources": [
                    {"relativePath":"vcs/git.1.log", "text":line},
                    {"relativePath":"vcs/git~1.log", "text":line},
                    {"relativePath":"_overflow~1.log", "text":line}
                ],
                "fields":{"level":"WARN", "ts":"2026-11-03T08:00:01.123Z"}
            }))
            .unwrap(),
        )
        .unwrap();
        assert_eq!(
            response
                .records
                .iter()
                .map(|r| r.channel.as_str())
                .collect::<Vec<_>>(),
            vec!["_overflow", "vcs/git.1", "vcs/git"]
        );
        assert_eq!(response.channel_counts["vcs/git.1"].warn, 1);
    }

    #[test]
    fn queries_redact_prefixed_credentials_in_existing_v1_and_v2_files() {
        let request = json!({"sources":[
            {"relativePath":"app.log", "text":"2026-11-03T08:00:00.000Z INFO seq=1 event=app.test.finished msg=finished client_secret=synthetic-secret"},
            {"relativePath":"application/lithe.previous.log", "text":"2026-11-03T08:00:01Z INFO legacy schema_version=1 auth_token=synthetic-token"}
        ]});
        let response = query_logs_v2(serde_json::from_value(request).unwrap()).unwrap();
        assert_eq!(response.records.len(), 2);
        assert_eq!(
            response.records[0].record.fields["client_secret"],
            "<redacted>"
        );
        assert_eq!(
            response.records[1].record.fields["auth_token"],
            "<redacted>"
        );
    }

    #[test]
    fn query_headers_filters_and_invalid_arguments_preserve_source_evidence() {
        let header = "#lithe-log v2 session=abcdef12-3456-7890-abcd-ef1234567890 pid=42 app=1.0 channel=vcs/git started=2026-11-03T08:00:00.000Z";
        let line = "2026-11-03T08:00:01.123Z ERROR seq=9 event=vcs.git.failed op=op1 msg=failed exit_code=128";
        let response = query_logs_v2(serde_json::from_value(json!({"sources":[{"relativePath":"vcs/git~2.log","text":format!("{header}\n{line}\n{header}\n"),"firstLineNumber":1}],"fields":{"exit_code":"128"},"search":"FAILED"})).unwrap()).unwrap();
        assert_eq!(response.records.len(), 1);
        assert_eq!(response.records[0].line_number, 2);
        assert_eq!(response.channel_counts["vcs/git"].error, 1);
        assert_eq!(response.skipped_invalid_lines, 1);
        for (request, code) in [
            (json!({"since":"invalid"}), -32035),
            (
                json!({"since":"2026-11-03T00:00:00Z","until":"2026-11-02T00:00:00Z"}),
                -32052,
            ),
            (
                json!({"sources":[{"relativePath":"../app.log","text":""}]}),
                -32050,
            ),
        ] {
            assert_eq!(
                query_logs_v2(serde_json::from_value(request).unwrap())
                    .unwrap_err()
                    .code,
                code
            );
        }
    }

    #[test]
    fn query_byte_budget_reports_omitted_native_evidence() {
        let result = query_logs_v2(serde_json::from_value(json!({"sources":[{"relativePath":"app.log","text":"x".repeat(MAX_LOG_EXPORT_BYTES + 1)}]})).unwrap()).unwrap();
        assert!(result.truncated);
        assert_eq!(result.skipped_invalid_lines, 0);
        assert!(result.records.is_empty());
    }
}
