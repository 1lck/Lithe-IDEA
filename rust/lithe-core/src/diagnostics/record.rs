//! Encodes and strictly decodes bounded structured log lines without native I/O or clocks.

use super::channel::{valid_uuid, LogChannel, LogError};
use super::redaction::{redact_log_field, redact_text, RedactTextRequest};
use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

/// Maximum UTF-8 bytes including the record's terminating newline.
pub const MAX_RECORD_BYTES: usize = 8 * 1024;
const RESERVED: [&str; 6] = ["seq", "event", "op", "msg", "ts", "level"];

/// Ordered severity shared by the encoder and query filters.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "UPPERCASE")]
pub enum LogLevel {
    /// Detailed diagnostic evidence.
    Debug,
    /// Normal lifecycle evidence.
    Info,
    /// Recoverable failure or degraded operation.
    Warn,
    /// Failed operation.
    Error,
}
impl LogLevel {
    /// Returns the canonical disk label.
    pub fn label(self) -> &'static str {
        match self {
            Self::Debug => "DEBUG",
            Self::Info => "INFO",
            Self::Warn => "WARN",
            Self::Error => "ERROR",
        }
    }
    pub(crate) fn parse(value: &str) -> Result<Self, LogError> {
        match value {
            "DEBUG" => Ok(Self::Debug),
            "INFO" => Ok(Self::Info),
            "WARN" => Ok(Self::Warn),
            "ERROR" => Ok(Self::Error),
            _ => Err(LogError::new(-32045, "Invalid log level")),
        }
    }
}

/// Owned event input. Scalar context values are normalized to their textual disk representation.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StructuredLogEvent {
    /// Caller-supplied RFC3339 instant, normalized to UTC milliseconds during encoding.
    pub ts: String,
    /// One of DEBUG, INFO, WARN, ERROR.
    pub level: LogLevel,
    /// Session-local monotonic sequence; zero is allowed.
    pub seq: u64,
    /// Stable event identity, stored as a nonempty bare value.
    pub event: String,
    /// Optional opaque correlation identity, stored as a nonempty bare value.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub op: Option<String>,
    /// Human-readable fact, redacted before escaping.
    pub msg: String,
    /// Unique non-reserved keys; values must be JSON scalars, not arrays or objects.
    #[serde(default)]
    pub fields: BTreeMap<String, Value>,
}

/// Owned, sanitized disk record. Context values are strings after scalar normalization.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LogRecord {
    /// Canonical UTC millisecond timestamp.
    pub ts: String,
    /// Canonical severity.
    pub level: LogLevel,
    /// Unpadded decimal sequence on disk.
    pub seq: u64,
    /// Stable event identity.
    pub event: String,
    /// Optional operation correlation.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub op: Option<String>,
    /// Redacted, decoded message.
    pub msg: String,
    /// Decoded context in deterministic key order.
    pub fields: BTreeMap<String, String>,
}

/// Immutable metadata written as the first line of each host-owned file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LogFileHeader {
    /// Full process-session UUID.
    pub session: String,
    /// Native process identifier.
    pub pid: u32,
    /// Application version, represented by a nonempty bare token.
    pub app: String,
    /// Validated logical channel identity.
    pub channel: String,
    /// Start instant, normalized to UTC milliseconds.
    pub started: String,
}

/// A decoded line is either immutable file metadata or an ordinary record.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", content = "value", rename_all = "camelCase")]
pub enum DecodedLogLine {
    /// First-line metadata; queries do not treat it as an event.
    Header(LogFileHeader),
    /// An ordinary or system event.
    Record(LogRecord),
}

pub(crate) fn normalize_timestamp(value: &str) -> Result<String, LogError> {
    let time = DateTime::parse_from_rfc3339(value)
        .map_err(|_| LogError::new(-32035, "Invalid timestamp"))?;
    let result = time
        .with_timezone(&Utc)
        .to_rfc3339_opts(SecondsFormat::Millis, true);
    if result.len() != 24 {
        return Err(LogError::new(-32035, "Invalid timestamp"));
    }
    Ok(result)
}
fn bare(value: &str) -> bool {
    !value.is_empty()
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._:/@+-".contains(&b))
}
fn field_key(key: &str) -> Result<(), LogError> {
    if key.is_empty()
        || key.len() > 64
        || !key.as_bytes()[0].is_ascii_lowercase()
        || !key
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
    {
        return Err(LogError::new(-32037, "Invalid field key"));
    }
    if RESERVED.contains(&key) {
        return Err(LogError::new(-32038, "Reserved context key"));
    }
    Ok(())
}
fn identity(value: &str) -> Result<(), LogError> {
    if bare(value) {
        Ok(())
    } else {
        Err(LogError::new(-32048, "Invalid event or operation identity"))
    }
}
fn scrub(value: &str) -> String {
    redact_text(RedactTextRequest { text: value.into() }).redacted
}

/// Escapes a value using the v2 grammar; the returned text contains no physical line break.
pub fn encode_value(value: &str) -> String {
    if bare(value) {
        return value.into();
    }
    let mut encoded = String::from("\"");
    for c in value.chars() {
        match c {
            '"' => encoded.push_str("\\\""),
            '\\' => encoded.push_str("\\\\"),
            '\n' => encoded.push_str("\\n"),
            '\r' => encoded.push_str("\\r"),
            '\t' => encoded.push_str("\\t"),
            c if c.is_control() => encoded.push_str(&format!("\\u{{{:02X}}}", c as u32)),
            c => encoded.push(c),
        }
    }
    encoded.push('"');
    encoded
}

fn render(record: &LogRecord) -> String {
    let mut line = format!(
        "{} {} seq={} event={}",
        record.ts,
        record.level.label(),
        record.seq,
        record.event
    );
    if let Some(op) = &record.op {
        line.push_str(&format!(" op={op}"));
    }
    line.push_str(&format!(" msg={}", encode_value(&record.msg)));
    for (key, value) in &record.fields {
        if key == "truncated" {
            continue;
        }
        line.push_str(&format!(" {key}={}", encode_value(value)));
    }
    if let Some(value) = record.fields.get("truncated") {
        line.push_str(&format!(" truncated={}", encode_value(value)));
    }
    line
}

// Prefix size is measured after escaping, so UTF-8 and control escapes share the same byte budget.
fn truncate_to_encoded_budget(value: &mut String, budget: usize) {
    let mut size = 2;
    let mut end = 0;
    for (offset, c) in value.char_indices() {
        let cost = match c {
            '"' | '\\' | '\n' | '\r' | '\t' => 2,
            c if c.is_control() => format!("\\u{{{:02X}}}", c as u32).len(),
            c => c.len_utf8(),
        };
        if size + cost > budget {
            break;
        }
        size += cost;
        end = offset + c.len_utf8();
    }
    value.truncate(end);
}

/// Redacts and encodes one event. Longest context values shrink first, then the message.
/// If mandatory identities or field-key overhead cannot fit, returns -32046 instead of dropping keys.
/// The returned line excludes its newline; the 8 KiB budget reserves that byte.
pub fn encode_record(event: StructuredLogEvent) -> Result<String, LogError> {
    identity(&event.event)?;
    if let Some(op) = &event.op {
        identity(op)?;
    }
    let mut fields = BTreeMap::new();
    for (key, value) in event.fields {
        field_key(&key)?;
        let text = match value {
            Value::String(text) => text,
            Value::Array(_) | Value::Object(_) => {
                return Err(LogError::new(-32047, "Context value must be a JSON scalar"))
            }
            value => value.to_string(),
        };
        fields.insert(key.clone(), redact_log_field(&key, &text));
    }
    let mut record = LogRecord {
        ts: normalize_timestamp(&event.ts)?,
        level: event.level,
        seq: event.seq,
        event: event.event,
        op: event.op,
        msg: scrub(&event.msg),
        fields,
    };
    let mut line = render(&record);
    if line.len() < MAX_RECORD_BYTES {
        return Ok(line);
    }
    record.fields.insert("truncated".into(), "1".into());
    let mut keys: Vec<_> = record
        .fields
        .keys()
        .filter(|k| k.as_str() != "truncated")
        .cloned()
        .collect();
    keys.sort_by(|a, b| {
        encode_value(&record.fields[b])
            .len()
            .cmp(&encode_value(&record.fields[a]).len())
            .then_with(|| a.cmp(b))
    });
    line = render(&record);
    for key in keys {
        if line.len() < MAX_RECORD_BYTES {
            break;
        }
        let value = record.fields.get_mut(&key).expect("collected field key");
        let available = encode_value(value)
            .len()
            .saturating_sub(line.len() + 1 - MAX_RECORD_BYTES);
        truncate_to_encoded_budget(value, available);
        line = render(&record);
    }
    if line.len() >= MAX_RECORD_BYTES {
        let available = encode_value(&record.msg)
            .len()
            .saturating_sub(line.len() + 1 - MAX_RECORD_BYTES);
        truncate_to_encoded_budget(&mut record.msg, available);
        line = render(&record);
    }
    if line.len() >= MAX_RECORD_BYTES {
        return Err(LogError::new(-32046, "Record cannot fit the line budget"));
    }
    Ok(line)
}

/// Encodes validated file metadata without a trailing newline.
pub fn encode_header(header: &LogFileHeader) -> Result<String, LogError> {
    if !valid_uuid(&header.session) || !bare(&header.app) {
        return Err(LogError::new(-32040, "Invalid file header"));
    }
    if header.channel != "_overflow" {
        LogChannel::parse(&header.channel)?;
    }
    let line = format!(
        "#lithe-log v2 session={} pid={} app={} channel={} started={}",
        header.session.to_ascii_lowercase(),
        header.pid,
        header.app,
        header.channel,
        normalize_timestamp(&header.started)?
    );
    if line.len() >= MAX_RECORD_BYTES {
        return Err(LogError::new(-32046, "Record cannot fit the line budget"));
    }
    Ok(line)
}

fn parse_pairs(mut input: &str) -> Result<Vec<(String, String)>, LogError> {
    let mut result = Vec::new();
    while !input.is_empty() {
        let (key, rest) = input
            .split_once('=')
            .ok_or_else(|| LogError::new(-32041, "Invalid line syntax"))?;
        if key.is_empty()
            || !key
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
        {
            return Err(LogError::new(-32037, "Invalid field key"));
        }
        let (value, consumed) = parse_value(rest)?;
        result.push((key.into(), value));
        input = &rest[consumed..];
        if !input.is_empty() {
            input = input
                .strip_prefix(' ')
                .ok_or_else(|| LogError::new(-32041, "Invalid line syntax"))?;
            if input.is_empty() || input.starts_with(' ') {
                return Err(LogError::new(-32041, "Invalid line syntax"));
            }
        }
    }
    Ok(result)
}
fn parse_value(input: &str) -> Result<(String, usize), LogError> {
    if !input.starts_with('"') {
        let value = input.split(' ').next().unwrap_or("");
        if !bare(value) {
            return Err(LogError::new(-32041, "Invalid line syntax"));
        }
        return Ok((value.into(), value.len()));
    }
    let mut chars = input.char_indices().skip(1);
    let mut value = String::new();
    while let Some((offset, c)) = chars.next() {
        match c {
            '"' => {
                if bare(&value) {
                    return Err(LogError::new(-32041, "Invalid line syntax"));
                }
                return Ok((value, offset + 1));
            }
            '\\' => {
                let (_, escape) = chars
                    .next()
                    .ok_or_else(|| LogError::new(-32042, "Invalid value escape"))?;
                value.push(match escape {
                    '"' => '"',
                    '\\' => '\\',
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    'u' => {
                        if chars.next().map(|(_, c)| c) != Some('{') {
                            return Err(LogError::new(-32042, "Invalid value escape"));
                        }
                        let mut hex = String::new();
                        loop {
                            let (_, c) = chars
                                .next()
                                .ok_or_else(|| LogError::new(-32042, "Invalid value escape"))?;
                            if c == '}' {
                                break;
                            }
                            if !c.is_ascii_hexdigit() || hex.len() >= 6 {
                                return Err(LogError::new(-32042, "Invalid value escape"));
                            }
                            hex.push(c);
                        }
                        if hex.len() != 2 {
                            return Err(LogError::new(-32042, "Invalid value escape"));
                        }
                        u32::from_str_radix(&hex, 16)
                            .ok()
                            .and_then(char::from_u32)
                            .filter(|c| c.is_control())
                            .ok_or_else(|| LogError::new(-32042, "Invalid value escape"))?
                    }
                    _ => return Err(LogError::new(-32042, "Invalid value escape")),
                });
            }
            c if c.is_control() => return Err(LogError::new(-32041, "Invalid line syntax")),
            c => value.push(c),
        }
    }
    Err(LogError::new(-32041, "Invalid line syntax"))
}
fn decimal(value: &str) -> Result<u64, LogError> {
    if value.is_empty()
        || (value.len() > 1 && value.starts_with('0'))
        || !value.bytes().all(|b| b.is_ascii_digit())
    {
        return Err(LogError::new(-32044, "Invalid sequence number"));
    }
    value
        .parse()
        .map_err(|_| LogError::new(-32044, "Invalid sequence number"))
}

/// Strictly decodes one physical line, distinguishing metadata from records.
/// Invalid timestamps, escaping, ordering, duplicates, and oversized lines return owned errors.
pub fn decode_line(line: &str) -> Result<DecodedLogLine, LogError> {
    if line.len() >= MAX_RECORD_BYTES {
        return Err(LogError::new(-32046, "Record cannot fit the line budget"));
    }
    if let Some(input) = line.strip_prefix("#lithe-log v2 ") {
        let pairs = parse_pairs(input)?;
        if pairs.iter().map(|(k, _)| k.as_str()).collect::<Vec<_>>()
            != ["session", "pid", "app", "channel", "started"]
        {
            return Err(LogError::new(-32040, "Invalid file header"));
        }
        let header = LogFileHeader {
            session: pairs[0].1.clone(),
            pid: pairs[1]
                .1
                .parse()
                .map_err(|_| LogError::new(-32040, "Invalid file header"))?,
            app: pairs[2].1.clone(),
            channel: pairs[3].1.clone(),
            started: pairs[4].1.clone(),
        };
        if encode_header(&header)? != line {
            return Err(LogError::new(-32040, "Invalid file header"));
        }
        return Ok(DecodedLogLine::Header(header));
    }
    let mut parts = line.splitn(3, ' ');
    let ts = parts.next().unwrap_or("");
    if normalize_timestamp(ts)? != ts {
        return Err(LogError::new(-32035, "Invalid timestamp"));
    }
    let level = LogLevel::parse(parts.next().unwrap_or(""))?;
    let pairs = parse_pairs(parts.next().unwrap_or(""))?;
    let keys: Vec<_> = pairs.iter().map(|(k, _)| k.as_str()).collect();
    let has_op = keys.get(2) == Some(&"op");
    let prefix: &[&str] = if has_op {
        &["seq", "event", "op", "msg"]
    } else {
        &["seq", "event", "msg"]
    };
    if !keys.starts_with(prefix) {
        return Err(LogError::new(
            -32043,
            "Missing or misordered reserved fields",
        ));
    }
    let seq = decimal(&pairs[0].1)?;
    identity(&pairs[1].1)?;
    let op = has_op.then(|| pairs[2].1.clone());
    if let Some(op) = &op {
        identity(op)?;
    }
    let mut fields = BTreeMap::new();
    for (key, value) in &pairs[prefix.len()..] {
        field_key(key)?;
        if fields.insert(key.clone(), value.clone()).is_some() {
            return Err(LogError::new(-32039, "Duplicate context key"));
        }
    }
    Ok(DecodedLogLine::Record(LogRecord {
        ts: ts.into(),
        level,
        seq,
        event: pairs[1].1.clone(),
        op,
        msg: pairs[prefix.len() - 1].1.clone(),
        fields,
    }))
}

/// Batch boundary retains each raw JSON event so malformed items do not reject valid siblings.
#[derive(Debug, Deserialize)]
pub struct EncodeLogBatchRequest {
    /// Input order is preserved in the response.
    pub events: Vec<Value>,
}
/// Exactly one encoded line or owned failure for one batch item.
#[derive(Debug, Serialize)]
pub struct EncodedLogResult {
    /// UTF-8 line excluding the newline, absent on error.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub line: Option<String>,
    /// Stable item-specific failure, absent on success.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<LogError>,
}
/// Owned batch output with one entry per input item.
#[derive(Debug, Serialize)]
pub struct EncodeLogBatchResponse {
    /// Results in caller input order.
    pub results: Vec<EncodedLogResult>,
}
/// Encodes a batch independently, preserving errors without aborting subsequent events.
pub fn encode_log_batch(request: EncodeLogBatchRequest) -> EncodeLogBatchResponse {
    let results = request
        .events
        .into_iter()
        .map(|value| {
            let encoded = serde_json::from_value(value)
                .map_err(|_| LogError::new(-32051, "Invalid structured event shape"))
                .and_then(encode_record);
            match encoded {
                Ok(line) => EncodedLogResult {
                    line: Some(line),
                    error: None,
                },
                Err(error) => EncodedLogResult {
                    line: None,
                    error: Some(error),
                },
            }
        })
        .collect();
    EncodeLogBatchResponse { results }
}

/// Constructs ordinary log.repeated evidence using explicit caller-supplied time and counts.
pub fn repeated_event(
    ts: &str,
    seq: u64,
    of: &str,
    count: u64,
    first: &str,
    last: &str,
) -> StructuredLogEvent {
    StructuredLogEvent {
        ts: ts.into(),
        level: LogLevel::Info,
        seq,
        event: "log.repeated".into(),
        op: None,
        msg: "Repeated events".into(),
        fields: BTreeMap::from([
            ("count".into(), count.into()),
            ("first".into(), first.into()),
            ("last".into(), last.into()),
            ("of".into(), of.into()),
        ]),
    }
}
/// Constructs ordinary log.dropped evidence without introducing a special disk format.
pub fn dropped_event(ts: &str, seq: u64, count: u64) -> StructuredLogEvent {
    StructuredLogEvent {
        ts: ts.into(),
        level: LogLevel::Warn,
        seq,
        event: "log.dropped".into(),
        op: None,
        msg: "Dropped events".into(),
        fields: BTreeMap::from([("count".into(), count.into())]),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::diagnostics::{channel, query_v2, retention};
    use serde_json::json;

    fn fixture() -> Value {
        serde_json::from_str(include_str!(
            "../../../../shared/fixtures/diagnostics/logging-v2.json"
        ))
        .unwrap()
    }

    #[test]
    fn structured_credential_keys_are_redacted_and_reserved_keys_rejected() {
        let mut event = dropped_event("2026-11-03T08:00:00Z", 1, 2);
        event.fields = BTreeMap::from([
            ("client_secret".into(), json!("synthetic credential value")),
            ("auth_token".into(), json!("synthetic-token")),
            ("db_password".into(), json!("synthetic-password")),
            ("tokens".into(), json!(42)),
        ]);
        let line = encode_record(event.clone()).unwrap();
        let DecodedLogLine::Record(record) = decode_line(&line).unwrap() else {
            panic!("expected record")
        };
        for key in ["client_secret", "auth_token", "db_password"] {
            assert_eq!(record.fields[key], "<redacted>");
        }
        assert_eq!(record.fields["tokens"], "42");
        for key in ["ts", "level"] {
            event.fields.insert(key.into(), json!("reserved"));
            assert_eq!(encode_record(event.clone()).unwrap_err().code, -32038);
            event.fields.remove(key);
        }
    }

    #[test]
    fn overflow_headers_use_the_same_codec_as_ordinary_channels() {
        let header = LogFileHeader {
            session: "abcdef12-3456-7890-abcd-ef1234567890".into(),
            pid: 1,
            app: "1.0".into(),
            channel: "_overflow".into(),
            started: "2026-11-03T08:00:00.000Z".into(),
        };
        assert_eq!(
            decode_line(&encode_header(&header).unwrap()).unwrap(),
            DecodedLogLine::Header(header)
        );
    }

    #[test]
    fn shared_fixture_roundtrips_escaping_and_enforces_byte_budgets() {
        let fixture = fixture();
        assert_eq!(fixture["limits"]["lineBytes"], MAX_RECORD_BYTES);
        for case in fixture["roundtrips"].as_array().unwrap() {
            let line =
                encode_record(serde_json::from_value(case["input"].clone()).unwrap()).unwrap();
            assert!(!line.contains(['\n', '\r']));
            if let Some(expected) = case.get("line") {
                assert_eq!(line, expected.as_str().unwrap());
            }
            let DecodedLogLine::Record(record) = decode_line(&line).unwrap() else {
                panic!("expected record")
            };
            assert_eq!(record.msg, case["message"].as_str().unwrap());
            assert_eq!(record.fields["exit_code"], "128");
            assert_eq!(
                encode_record(
                    serde_json::from_value(serde_json::to_value(record).unwrap()).unwrap()
                )
                .unwrap(),
                line
            );
        }
        for case in fixture["truncations"].as_array().unwrap() {
            let line =
                encode_record(serde_json::from_value(case["input"].clone()).unwrap()).unwrap();
            assert!(line.len() < MAX_RECORD_BYTES);
            assert_eq!(line.lines().count(), 1);
            let DecodedLogLine::Record(record) = decode_line(&line).unwrap() else {
                panic!("expected record")
            };
            assert_eq!(record.fields["truncated"], "1");
            if case["keepSmall"] == true {
                assert_eq!(record.fields["small"], "keep");
            }
        }
    }

    #[test]
    fn shared_fixture_rejects_malformed_lines_and_channels() {
        let fixture = fixture();
        for case in fixture["invalidLines"].as_array().unwrap() {
            assert_eq!(
                decode_line(case["line"].as_str().unwrap())
                    .unwrap_err()
                    .code,
                case["code"].as_i64().unwrap() as i32,
                "{case}"
            );
        }
        for case in fixture["channels"].as_array().unwrap() {
            let result = channel::LogChannel::parse(case["channel"].as_str().unwrap());
            if let Some(code) = case["code"].as_i64() {
                assert_eq!(result.unwrap_err().code, code as i32);
            } else {
                assert_eq!(
                    channel::relative_log_path(
                        &result.unwrap(),
                        case["rotation"].as_u64().unwrap() as u32
                    ),
                    case["path"].as_str().unwrap()
                );
            }
        }
        for value in fixture["segments"]["valid"].as_array().unwrap() {
            assert!(channel::validate_segment(value.as_str().unwrap()).is_ok());
        }
        for value in fixture["segments"]["invalid"].as_array().unwrap() {
            assert_eq!(
                channel::validate_segment(value.as_str().unwrap())
                    .unwrap_err()
                    .code,
                -32033
            );
        }
    }

    #[test]
    fn shared_fixture_plans_session_and_plugin_retention_without_a_clock() {
        let fixture = fixture();
        for case in fixture["retention"].as_array().unwrap() {
            let plan = retention::plan_log_retention(
                serde_json::from_value(case["request"].clone()).unwrap(),
            )
            .unwrap();
            assert_eq!(
                serde_json::to_value(&plan.deletions).unwrap(),
                case["deletions"],
                "{}",
                case["name"]
            );
            assert_eq!(
                json!(plan
                    .warnings
                    .iter()
                    .map(|w| &w.plugin_id)
                    .collect::<Vec<_>>()),
                case["warningPlugins"],
                "{}",
                case["name"]
            );
        }
        assert!(!retention::should_rotate(retention::CHANNEL_SEGMENT_BYTES));
        assert!(retention::should_rotate(
            retention::CHANNEL_SEGMENT_BYTES + 1
        ));
        assert_eq!(
            retention::rotation_indices_to_delete(&[3, 0, 1, 2, 3]),
            vec![2, 3]
        );
        assert_eq!(
            retention::rotation_paths_to_delete(
                &channel::LogChannel::parse("vcs/git").unwrap(),
                &[0, 1, 2]
            ),
            vec!["vcs/git~2.log"]
        );
    }

    #[test]
    fn shared_fixture_queries_v1_v2_and_partial_native_tails() {
        let fixture = fixture();
        for case in fixture["queries"].as_array().unwrap() {
            let result =
                query_v2::query_logs_v2(serde_json::from_value(case["request"].clone()).unwrap())
                    .unwrap();
            assert_eq!(
                json!(result
                    .records
                    .iter()
                    .map(|r| &r.record.msg)
                    .collect::<Vec<_>>()),
                case["messages"],
                "{}",
                case["name"]
            );
            assert_eq!(
                json!(result
                    .records
                    .iter()
                    .map(|r| &r.channel)
                    .collect::<Vec<_>>()),
                case["channels"]
            );
            assert_eq!(
                json!(result
                    .records
                    .iter()
                    .map(|r| &r.record.event)
                    .collect::<Vec<_>>()),
                case["events"]
            );
            assert_eq!(
                json!(result
                    .records
                    .iter()
                    .map(|r| r.record.seq)
                    .collect::<Vec<_>>()),
                case["sequences"]
            );
            assert_eq!(json!(result.skipped_invalid_lines), case["invalid"]);
            assert_eq!(json!(result.truncated), case["truncated"]);
            if let Some(counts) = case["warnCounts"].as_object() {
                for (channel, count) in counts {
                    assert_eq!(json!(result.channel_counts[channel].warn), *count);
                }
            }
            if let Some(counts) = case["errorCounts"].as_object() {
                for (channel, count) in counts {
                    assert_eq!(json!(result.channel_counts[channel].error), *count);
                }
            }
            if let Some(lines) = case.get("lineNumbers") {
                assert_eq!(
                    json!(result
                        .records
                        .iter()
                        .map(|r| r.line_number)
                        .collect::<Vec<_>>()),
                    *lines
                );
            }
        }
    }

    #[test]
    fn headers_batch_errors_and_system_events_share_the_public_codec() {
        let header = LogFileHeader {
            session: "abcdef12-3456-7890-abcd-ef1234567890".into(),
            pid: 123,
            app: "1.0.0-preview".into(),
            channel: "vcs/git".into(),
            started: "2026-11-03T08:00:00.000Z".into(),
        };
        assert_eq!(
            decode_line(&encode_header(&header).unwrap()).unwrap(),
            DecodedLogLine::Header(header)
        );
        let event = dropped_event("2026-11-03T08:00:00Z", 1, 5);
        let batch = encode_log_batch(EncodeLogBatchRequest {
            events: vec![
                json!(event),
                json!({"level":"invalid"}),
                json!(repeated_event(
                    "2026-11-03T08:00:01Z",
                    2,
                    "app.ready",
                    4,
                    "first",
                    "last"
                )),
            ],
        });
        assert!(batch.results[0]
            .line
            .as_ref()
            .unwrap()
            .contains("event=log.dropped"));
        assert_eq!(batch.results[1].error.as_ref().unwrap().code, -32051);
        assert!(batch.results[2]
            .line
            .as_ref()
            .unwrap()
            .contains("event=log.repeated"));
        let mut event = event;
        event.msg = "password=fixture-secret /home/example/project".into();
        event.fields.insert("token".into(), "fixture-token".into());
        let line = encode_record(event).unwrap();
        assert!(!line.contains("fixture-secret"));
        assert!(!line.contains("fixture-token"));
        assert!(line.contains("<HOME>"));
        assert!(decode_line(&line).is_ok());
    }

    #[test]
    fn diagnostics_v2_commands_dispatch_with_stable_domain_errors() {
        let cases = [
            ("diagnostics.encodeLogBatch", json!({"events":[]})),
            ("diagnostics.queryLogsV2", json!({"sources":[]})),
            (
                "diagnostics.planLogRetention",
                json!({"currentSession":"", "now":"2026-11-03T00:00:00Z"}),
            ),
            (
                "diagnostics.resolveLogChannel",
                json!({"channel":"vcs/git"}),
            ),
        ];
        for (command, payload) in cases {
            let response: Value = serde_json::from_str(&crate::runtime::execute_json(
                &json!({"id":"fixture", "version":1, "command":command, "payload":payload})
                    .to_string(),
            ))
            .unwrap();
            assert_eq!(response["ok"], true, "{response}");
            assert!(response["data"].get("error").is_none(), "{response}");
        }
        let response: Value = serde_json::from_str(&crate::runtime::execute_json(&json!({"version":1,"command":"diagnostics.resolveLogChannel","payload":{"channel":"vcs/.."}}).to_string())).unwrap();
        assert_eq!(response["data"]["error"]["code"], -32033);
    }

    #[test]
    fn mandatory_overhead_and_non_scalar_fields_fail_without_losing_siblings() {
        let mut event = dropped_event("2026-11-03T00:00:00Z", 1, 1);
        event.event = "a".repeat(MAX_RECORD_BYTES);
        assert_eq!(encode_record(event.clone()).unwrap_err().code, -32046);
        event.event = "app.ready".into();
        event
            .fields
            .insert("nested".into(), json!({"value":"context"}));
        assert_eq!(encode_record(event.clone()).unwrap_err().code, -32047);
        event.fields.clear();
        event.fields.insert("seq".into(), json!(2));
        assert_eq!(encode_record(event).unwrap_err().code, -32038);
    }
}
