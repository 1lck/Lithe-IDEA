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
    /// Exact severity set for independent level toggles; an empty set matches nothing.
    #[serde(default)]
    pub levels: Option<Vec<LogLevel>>,
    /// Inclusive RFC3339 lower bound, compared as an instant.
    pub since: Option<String>,
    /// Inclusive RFC3339 upper bound, compared as an instant.
    pub until: Option<String>,
    /// Independent window bounds intersect export bounds; an empty intersection matches nothing.
    #[serde(default)]
    pub filter_since: Option<String>,
    /// Inclusive upper bound from the window selection.
    #[serde(default)]
    pub filter_until: Option<String>,
    /// Session basename to exclusive sequence watermark; session-relative sources use the empty key.
    #[serde(default)]
    pub after_sequences: BTreeMap<String, u64>,
    /// Case-insensitive substring across the message, identities, and context.
    pub search: Option<String>,
    /// Exact key=value matches; reserved fields may also be queried.
    #[serde(default)]
    pub fields: BTreeMap<String, String>,
    /// Exact operation identity.
    pub op: Option<String>,
    /// Return the newest 1 through 10000 matches, in ascending time/sequence order.
    pub limit: Option<usize>,
    /// Optional 1024-byte expression, intersected with all existing filters.
    #[serde(default)]
    pub expression: Option<String>,
    /// Optional event distribution resolution, strictly 1 through 240.
    #[serde(default)]
    pub histogram_buckets: Option<usize>,
}
/// One owned structured event with its physical source location.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QueriedLogRecord {
    /// Canonical redacted disk line for native presentation and frozen exports.
    pub line: String,
    /// Logical channel, resolved from metadata or the validated source path.
    pub channel: String,
    /// Source file relative to the host log root or session.
    pub relative_path: String,
    /// One-based physical line number, including headers and skipped lines.
    pub line_number: usize,
    /// FNV-1a 64 over length-prefixed channel/level/event/message UTF-8, in that order.
    pub fold_key: String,
    /// Parsed event instant in milliseconds since Unix epoch.
    pub epoch_ms: i64,
    /// Relative to the first filtered operation match before the output limit; absent without op.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub op_offset_ms: Option<i64>,
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
/// Unfiltered counts over every successfully decoded record in the supplied byte budget.
#[derive(Debug, Default, Serialize)]
pub struct ChannelCounts {
    /// Total decoded events before any query filters.
    pub total: usize,
    /// Number of WARN events in this count scope.
    pub warn: usize,
    /// Number of ERROR events in this count scope.
    pub error: usize,
}
/// Per-severity event counts for one half-open histogram bucket.
#[derive(Debug, Default, Clone, Serialize)]
pub struct HistogramBucket {
    /// Number of DEBUG events in this bucket.
    pub debug: usize,
    /// Number of INFO events in this bucket.
    pub info: usize,
    /// Number of WARN events in this count scope.
    pub warn: usize,
    /// Number of ERROR events in this count scope.
    pub error: usize,
}
/// Uniform integer-millisecond buckets, including empty buckets; end is exclusive.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LogHistogram {
    /// Inclusive first bucket boundary, milliseconds since Unix epoch.
    pub start_epoch_ms: i64,
    /// Exclusive final bucket boundary, milliseconds since Unix epoch.
    pub end_epoch_ms: i64,
    /// Uniform positive bucket width in milliseconds.
    pub bucket_ms: i64,
    /// Ascending time buckets, including empty buckets.
    pub buckets: Vec<HistogramBucket>,
}
/// All filtered operation matches before the output limit, with inclusive first/last instants.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OpSummary {
    /// Exact operation identity supplied by the query.
    pub op: String,
    /// Matching event count before output limiting.
    pub count: usize,
    /// Earliest matching instant in Unix milliseconds; zero for an empty result.
    pub first_epoch_ms: i64,
    /// Latest matching instant in Unix milliseconds; zero for an empty result.
    pub last_epoch_ms: i64,
    /// Elapsed milliseconds from first to last match; zero for an empty result.
    pub duration_ms: i64,
}
/// Owned merged evidence and explicit incompleteness indicators.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LogQueryV2Response {
    /// Highest decoded sequence per supplied session, before query filters and output limits.
    pub session_sequences: BTreeMap<String, u64>,
    /// Newest bounded matches in ascending parsed time, sequence, path, and line order.
    pub records: Vec<QueriedLogRecord>,
    /// Counts over all filtered matches, including matches omitted by the output limit.
    pub channel_counts: BTreeMap<String, ChannelSeverityCounts>,
    /// True if a partial first line, input budget, or output limit omitted evidence.
    pub truncated: bool,
    /// Invalid physical lines; intentionally discarded partial first lines are excluded.
    pub skipped_invalid_lines: usize,
    /// Minimum consecutive equal fold keys needed for native collapsing.
    pub fold_minimum_run: usize,
    /// Unfiltered per-channel counts over supplied successfully decoded evidence.
    pub channels: BTreeMap<String, ChannelCounts>,
    /// Excludes only since/until from the query predicates; null when disabled or empty.
    pub histogram: Option<LogHistogram>,
    /// Absent without an explicit op request, including when the expression filters op.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub op_summary: Option<OpSummary>,
}

fn parse_time(value: &str) -> Result<DateTime<FixedOffset>, LogError> {
    DateTime::parse_from_rfc3339(value).map_err(|_| LogError::new(-32035, "Invalid timestamp"))
}
pub(super) fn source_channel(path: &str) -> Result<(String, bool), LogError> {
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
        && (parts[1] == "lithe.log" || parts[1].starts_with("lithe."))
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
pub(super) fn redact_record(mut record: LogRecord) -> LogRecord {
    record.msg = sanitize_log_text_unbounded(&record.msg);
    for (key, value) in &mut record.fields {
        *value = redact_log_field(key, value);
    }
    record
}

/// Parses and merges only supplied evidence. Invalid lines are counted; invalid query arguments fail.
/// Channel counts use the same filters as records, before limiting the newest returned matches.
pub fn query_logs_v2(request: LogQueryV2Request) -> Result<LogQueryV2Response, LogError> {
    let filter =
        super::filter::CompiledFilter::compile(request.expression.as_deref().unwrap_or(""))?;
    if request
        .histogram_buckets
        .is_some_and(|n| !(1..=240).contains(&n))
    {
        return Err(LogError::new(-32061, "Invalid histogram bucket count"));
    }
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
    let filter_since = request
        .filter_since
        .as_deref()
        .map(parse_time)
        .transpose()?;
    let filter_until = request
        .filter_until
        .as_deref()
        .map(parse_time)
        .transpose()?;
    if since.zip(until).is_some_and(|(a, b)| a > b) {
        return Err(LogError::new(-32052, "Query time range is reversed"));
    }
    if filter_since.zip(filter_until).is_some_and(|(a, b)| a > b) {
        return Err(LogError::new(-32052, "Query time range is reversed"));
    }
    for session in request
        .after_sequences
        .keys()
        .filter(|session| !session.is_empty())
    {
        super::channel::parse_session_directory_name(session)?;
    }
    let since = since.into_iter().chain(filter_since).max();
    let until = until.into_iter().chain(filter_until).min();
    let mut response = LogQueryV2Response {
        session_sequences: BTreeMap::new(),
        records: Vec::new(),
        channel_counts: BTreeMap::new(),
        truncated: false,
        skipped_invalid_lines: 0,
        fold_minimum_run: 3,
        channels: BTreeMap::new(),
        histogram: None,
        op_summary: request.op.as_ref().map(|op| OpSummary {
            op: op.clone(),
            count: 0,
            first_epoch_ms: 0,
            last_epoch_ms: 0,
            duration_ms: 0,
        }),
    };
    let needle = request.search.as_deref().unwrap_or("").to_lowercase();
    let mut remaining = MAX_LOG_EXPORT_BYTES;
    let limit = request.limit.unwrap_or(2000).clamp(1, 10000);
    let mut records = BTreeMap::new();
    // Only timestamps/severities are retained for histogram projection, bounded by native input bytes.
    let mut histogram_points = Vec::new();
    for (source_index, source) in request.sources.into_iter().enumerate() {
        let (mut channel, legacy) = source_channel(&source.relative_path)?;
        let session = source
            .relative_path
            .strip_prefix("sessions/")
            .and_then(|rest| rest.split_once('/'))
            .map_or("", |(session, _)| session);
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
            let all_counts = response.channels.entry(channel.clone()).or_default();
            let sequence = response
                .session_sequences
                .entry(session.to_owned())
                .or_default();
            *sequence = (*sequence).max(record.seq);
            all_counts.total += 1;
            all_counts.warn += usize::from(record.level == LogLevel::Warn);
            all_counts.error += usize::from(record.level == LogLevel::Error);
            if request
                .after_sequences
                .get(session)
                .is_some_and(|watermark| record.seq <= *watermark)
            {
                continue;
            }
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
                || request
                    .levels
                    .as_ref()
                    .is_some_and(|levels| !levels.contains(&record.level))
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
            if (!needle.is_empty() && !super::filter::search_matches(&record, &channel, &needle))
                || !filter.matches(&record, &channel)
            {
                continue;
            }
            let epoch_ms = time.timestamp_millis();
            if request.histogram_buckets.is_some() {
                histogram_points.push((epoch_ms, record.level));
            }
            if since.is_some_and(|bound| time < bound) || until.is_some_and(|bound| time > bound) {
                continue;
            }
            if let Some(summary) = &mut response.op_summary {
                if summary.count == 0 {
                    summary.first_epoch_ms = epoch_ms;
                    summary.last_epoch_ms = epoch_ms;
                }
                summary.count += 1;
                summary.first_epoch_ms = summary.first_epoch_ms.min(epoch_ms);
                summary.last_epoch_ms = summary.last_epoch_ms.max(epoch_ms);
                summary.duration_ms = summary.last_epoch_ms - summary.first_epoch_ms;
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
                    line: super::record::render(&record),
                    channel: channel.clone(),
                    relative_path: source.relative_path.clone(),
                    line_number,
                    fold_key: fold_key(&channel, &record),
                    epoch_ms,
                    op_offset_ms: None,
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
    if let Some(summary) = &response.op_summary {
        for record in &mut response.records {
            record.op_offset_ms = Some(record.epoch_ms - summary.first_epoch_ms);
        }
    }
    if let (Some(count), Some(start), Some(last)) = (
        request.histogram_buckets,
        histogram_points.iter().map(|p| p.0).min(),
        histogram_points.iter().map(|p| p.0).max(),
    ) {
        let bucket_ms = ((last - start + 1) + count as i64 - 1) / count as i64;
        let mut buckets = vec![HistogramBucket::default(); count];
        for (time, level) in histogram_points {
            let bucket = &mut buckets[((time - start) / bucket_ms) as usize];
            match level {
                LogLevel::Debug => bucket.debug += 1,
                LogLevel::Info => bucket.info += 1,
                LogLevel::Warn => bucket.warn += 1,
                LogLevel::Error => bucket.error += 1,
            }
        }
        response.histogram = Some(LogHistogram {
            start_epoch_ms: start,
            end_epoch_ms: start + bucket_ms * count as i64,
            bucket_ms,
            buckets,
        });
    }
    Ok(response)
}

// Length prefixes are fixed-width little-endian u64, so tuple boundaries and hashes remain stable
// across architectures and future releases; timestamps, seq, fields and op deliberately do not fold.
fn fold_key(channel: &str, record: &LogRecord) -> String {
    let mut hash = 0xcbf29ce484222325u64;
    for value in [channel, record.level.label(), &record.event, &record.msg] {
        for byte in (value.len() as u64)
            .to_le_bytes()
            .into_iter()
            .chain(value.bytes())
        {
            hash ^= u64::from(byte);
            hash = hash.wrapping_mul(0x100000001b3);
        }
    }
    format!("{hash:016x}")
}

#[cfg(test)]
mod tests {
    #[test]
    fn dotted_active_and_rotated_sources_have_distinct_channels() {
        for (path, expected) in [
            ("lsp/foo.1.log", "lsp/foo.1"),
            ("lsp/foo~1.log", "lsp/foo"),
            ("lsp/foo.1~2.log", "lsp/foo.1"),
            ("_overflow~2.log", "_overflow"),
        ] {
            assert_eq!(super::source_channel(path).unwrap().0, expected);
        }
        assert!(super::source_channel("lsp/foo~invalid.log").is_err());
    }

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

#[cfg(test)]
mod window_tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn export_time_bounds_intersect_and_clear_sequences_are_session_local() {
        let source = |session: &str, seq: u64, time: &str| {
            json!({
                "relativePath":format!("sessions/{session}/app.log"),
                "text":format!("{time} INFO seq={seq} event=app.ready msg=ready")
            })
        };
        let old = "2026-11-02T00-00-00_abcdef12";
        let current = "2026-11-03T00-00-00_12345678";
        let query = json!({"sources":[
            source(old, 5000, "2026-11-02T00:00:00.000Z"),
            source(current, 2, "2026-11-03T00:00:01.000Z")
        ],"afterSequences":{old:5000,current:1}});
        let result = query_logs_v2(serde_json::from_value(query.clone()).unwrap()).unwrap();
        assert_eq!(result.records.len(), 1);
        assert_eq!(result.records[0].record.seq, 2);
        let mut filtered = query.clone();
        filtered["since"] = json!("2026-11-02T00:00:00Z");
        filtered["filterSince"] = json!("2026-11-03T01:00:01+01:00");
        filtered["filterUntil"] = json!("2026-11-03T00:00:01.000Z");
        assert_eq!(
            query_logs_v2(serde_json::from_value(filtered.clone()).unwrap())
                .unwrap()
                .records
                .len(),
            1
        );
        filtered["since"] = json!("2026-11-03T00:00:02Z");
        assert!(query_logs_v2(serde_json::from_value(filtered).unwrap())
            .unwrap()
            .records
            .is_empty());
    }

    #[test]
    fn window_statistics_keep_full_distribution_and_unfiltered_channels() {
        let text = "2026-11-03T00:00:00.000Z WARN seq=1 event=app.failed op=one msg=failed\n2026-11-03T00:00:01.000Z WARN seq=2 event=app.failed op=one msg=failed\n2026-11-03T00:00:02.000Z ERROR seq=3 event=app.failed op=one msg=failed";
        let response = query_logs_v2(serde_json::from_value(json!({"sources":[{"relativePath":"app.log","text":text},{"relativePath":"vcs/git.log","text":text}],"channelPrefixes":["app"],"expression":"failed", "op":"one", "histogramBuckets":3,"since":"2026-11-03T00:00:01Z","limit":1})).unwrap()).unwrap();
        assert_eq!(response.channels["vcs/git"].total, 3);
        assert_eq!(response.channels["app"].error, 1);
        assert_eq!(response.channel_counts["app"].warn, 1);
        assert_eq!(response.fold_minimum_run, 3);
        let histogram = response.histogram.unwrap();
        assert_eq!(histogram.bucket_ms, 667);
        assert_eq!(
            histogram
                .buckets
                .iter()
                .map(|b| b.warn + b.error)
                .sum::<usize>(),
            3
        );
        assert_eq!(histogram.end_epoch_ms, 1793664002001);
        let summary = response.op_summary.unwrap();
        assert_eq!(summary.count, 2);
        assert_eq!(summary.duration_ms, 1000);
        assert_eq!(response.records[0].op_offset_ms, Some(1000));
        assert!(response.truncated);
        let all = query_logs_v2(
            serde_json::from_value(json!({"sources":[{"relativePath":"app.log","text":text}]}))
                .unwrap(),
        )
        .unwrap();
        assert_eq!(all.records[0].fold_key, all.records[1].fold_key);
        assert_ne!(all.records[1].fold_key, all.records[2].fold_key);
        assert!(all.op_summary.is_none());
        assert!(all.records[0].op_offset_ms.is_none());
        assert_eq!(all.records[0].epoch_ms, 1793664000000);
        // Fixed vector protects the byte encoding and hash across future releases.
        assert_eq!(all.records[0].fold_key, "c4d60ef213ff7102");
    }
    #[test]
    fn level_set_selects_exact_severities_and_empty_set_matches_nothing() {
        let text = "2026-11-03T00:00:00.000Z DEBUG seq=1 event=app.trace msg=a\n2026-11-03T00:00:01.000Z INFO seq=2 event=app.ready msg=b\n2026-11-03T00:00:02.000Z ERROR seq=3 event=app.failed msg=c";
        let query = |levels: serde_json::Value| {
            query_logs_v2(
                serde_json::from_value(
                    json!({"sources":[{"relativePath":"app.log","text":text}],"levels":levels}),
                )
                .unwrap(),
            )
            .unwrap()
        };
        let selected = query(json!(["DEBUG", "ERROR"]));
        assert_eq!(
            selected
                .records
                .iter()
                .map(|r| r.record.seq)
                .collect::<Vec<_>>(),
            [1, 3]
        );
        assert!(query(json!([])).records.is_empty());
        // Unfiltered sidebar counts still see every decoded record.
        assert_eq!(query(json!([])).channels["app"].total, 3);
    }
    #[test]
    fn empty_histogram_invalid_resolution_and_invalid_expression_are_distinct() {
        let response = query_logs_v2(
            serde_json::from_value(json!({"histogramBuckets":240,"op":"none"})).unwrap(),
        )
        .unwrap();
        assert!(response.histogram.is_none());
        assert_eq!(response.op_summary.unwrap().count, 0);
        for (request, code) in [
            (json!({"histogramBuckets":0}), -32061),
            (json!({"histogramBuckets":241}), -32061),
            (json!({"expression":"/[/"}), -32060),
        ] {
            assert_eq!(
                query_logs_v2(serde_json::from_value(request).unwrap())
                    .unwrap_err()
                    .code,
                code
            );
        }
    }
}
