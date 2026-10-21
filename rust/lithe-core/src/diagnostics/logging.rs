//! Pure application-log policy, recursive redaction, and bounded timeline queries.
//! Native adapters own queues, clocks, files, and snapshots; Core never opens a log.

use super::redaction::{redact_text, RedactTextRequest};
use chrono::{DateTime, FixedOffset};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

/// Stable coarse routing domains. Subsystems specialize `scope`, not directories.
pub const LOG_CATEGORIES: [&str; 6] = [
    "application",
    "language",
    "run",
    "git",
    "plugins",
    "performance",
];
/// Maximum bytes in a persisted record, including metadata and a newline.
pub const MAX_LOG_LINE_BYTES: usize = 4096;
/// Shared per-file rotation threshold.
pub const MAX_LOG_FILE_BYTES: u64 = 10 * 1024 * 1024;
/// Combined disk budget, including legacy logs; performance has its own smaller budget.
pub const MAX_LOG_TOTAL_BYTES: u64 = 100 * 1024 * 1024;
/// Performance sampling must not consume the general error-log budget.
pub const MAX_PERFORMANCE_BYTES: u64 = 20 * 1024 * 1024;
/// A diagnostic session expires automatically after fifteen minutes.
pub const DIAGNOSTIC_DURATION_MS: u64 = 15 * 60 * 1000;
/// Total uncompressed log evidence accepted into one export or timeline query.
pub const MAX_LOG_EXPORT_BYTES: usize = 10 * 1024 * 1024;

/// Untrusted host event before serialization. Correlation fields remain structured.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LogEventRequest {
    /// Stable subsystem scope such as language.java; never a path.
    pub scope: String,
    /// Human-readable lifecycle fact; credentials are scrubbed before persistence.
    pub message: String,
    #[serde(default)]
    /// Bounded structured context, recursively scrubbed before serialization.
    pub fields: BTreeMap<String, Value>,
}

/// Sanitized metadata shared by both native formatters.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PreparedLogEvent {
    /// One fixed routing domain from LOG_CATEGORIES.
    pub category: String,
    /// Stable subsystem scope such as language.java; never a path.
    pub scope: String,
    /// Human-readable lifecycle fact; credentials are scrubbed before persistence.
    pub message: String,
    /// Bounded structured context, recursively scrubbed before serialization.
    pub fields: BTreeMap<String, Value>,
}

/// Resolves an event's coarse file category without trusting it as a filesystem path.
pub fn log_category(scope: &str) -> &'static str {
    let scope = scope.to_ascii_lowercase();
    let prefix = scope.split(['.', ':', '/', '[']).next().unwrap_or("");
    match prefix {
        "lsp" | "language" | "editor" | "index" => "language",
        "run" | "debug" | "build" | "maven" | "gradle" => "run",
        "git" | "vcs" => "git",
        "plugin" | "plugins" | "module" => "plugins",
        "perf" | "performance" | "memory" | "fps" => "performance",
        _ => "application",
    }
}

fn truncate(value: &str, limit: usize) -> String {
    if value.len() <= limit {
        return value.to_owned();
    }
    let mut end = limit.saturating_sub(16).min(value.len());
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}…[truncated]", &value[..end])
}

/// Redacts text before it is escaped or persisted. Also bounds adversarial messages.
pub fn sanitize_log_text(value: &str) -> String {
    // Bound regex work before parsing, while retaining enough lookahead to scrub
    // a quoted secret crossing the eventual message boundary.
    let bounded = truncate(value, MAX_LOG_LINE_BYTES * 4);
    redact_text(RedactTextRequest { text: bounded }).redacted
}

/// Scrubs an already bounded native snapshot without imposing a per-event cutoff.
/// Hosts must bound file reads before calling this function.
pub fn sanitize_log_text_unbounded(value: &str) -> String {
    redact_text(RedactTextRequest {
        text: value.to_owned(),
    })
    .redacted
}

fn sensitive_key(key: &str) -> bool {
    let key = key.to_ascii_lowercase().replace(['_', '-'], "");
    [
        "password",
        "token",
        "authorization",
        "secret",
        "apikey",
        "cookie",
        "source",
        "content",
        "buffer",
        "history",
        "environment",
    ]
    .iter()
    .any(|part| key.contains(part))
}

fn clean_key(key: &str) -> String {
    key.chars()
        .take(80)
        .map(|c| {
            if c.is_ascii_alphanumeric() || "._-".contains(c) {
                c
            } else {
                '_'
            }
        })
        .collect()
}

fn scrub(value: Value, depth: usize, remaining: &mut usize) -> Value {
    if *remaining < 64 {
        return Value::String("[truncated]".into());
    }
    // One aggregate allowance bounds both traversal nodes and retained payload
    // before events enter a native queue, rather than only truncating disk lines.
    *remaining -= 64;
    match value {
        Value::Object(fields) if depth < 4 => {
            let mut result = serde_json::Map::new();
            for (key, value) in fields.into_iter().take(24) {
                if *remaining < 64 {
                    break;
                }
                let value = if sensitive_key(&key) {
                    Value::String("<redacted>".into())
                } else {
                    scrub(value, depth + 1, remaining)
                };
                let key = clean_key(&key);
                *remaining = remaining.saturating_sub(key.len() + 16);
                result.insert(key, value);
            }
            Value::Object(result)
        }
        Value::Array(values) if depth < 4 => {
            let mut result = Vec::new();
            for value in values.into_iter().take(24) {
                if *remaining < 64 {
                    break;
                }
                result.push(scrub(value, depth + 1, remaining));
            }
            Value::Array(result)
        }
        Value::String(text) => {
            let text = truncate(&sanitize_log_text(&text), (*remaining).min(1024));
            *remaining = remaining.saturating_sub(text.len());
            Value::String(text)
        }
        Value::Object(_) | Value::Array(_) => Value::String("[max-depth]".into()),
        other => other,
    }
}

/// Applies recursive privacy rules before flattening nested JSON into log fields.
pub fn prepare_log_event(request: LogEventRequest) -> PreparedLogEvent {
    let scope: String = request
        .scope
        .chars()
        .take(120)
        .map(|c| {
            if c.is_ascii_alphanumeric() || "._-".contains(c) {
                c
            } else {
                '_'
            }
        })
        .collect();
    let mut remaining = 2048usize;
    let mut fields = BTreeMap::new();
    for (key, value) in request.fields.into_iter().take(24) {
        if remaining < 64 {
            break;
        }
        let value = if sensitive_key(&key) {
            Value::String("<redacted>".into())
        } else {
            scrub(value, 0, &mut remaining)
        };
        let key = clean_key(&key);
        remaining = remaining.saturating_sub(key.len() + 16);
        fields.insert(key, value);
    }
    PreparedLogEvent {
        category: log_category(&scope).into(),
        scope,
        message: truncate(
            &sanitize_log_text(&request.message)
                .replace("\r\n", "\\n")
                .replace('\n', "\\n")
                .replace('\r', "\\r"),
            2048,
        ),
        fields,
    }
}

/// One bounded native file tail. The category is metadata, never a write destination.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LogSource {
    /// One fixed routing domain from LOG_CATEGORIES.
    pub category: String,
    /// UTF-8 evidence collected through a bounded native read.
    pub text: String,
}

/// Query over host-collected tails. `sessionId` is exact; missing values mean all.
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LogQueryRequest {
    #[serde(default)]
    /// Bounded native tails to merge; Core never reads their files.
    pub sources: Vec<LogSource>,
    /// One fixed routing domain from LOG_CATEGORIES.
    pub category: Option<String>,
    /// Inclusive severity filter; absent means all levels.
    pub minimum_level: Option<String>,
    /// Exact opaque process-session identity; absent means all sessions.
    pub session_id: Option<String>,
    /// Case-insensitive free-text filter over sanitized lines.
    pub search: Option<String>,
    /// Inclusive UTC RFC3339 lower bound; absent means no lower bound.
    pub since: Option<String>,
    /// Inclusive UTC RFC3339 upper bound; absent means no upper bound.
    pub until: Option<String>,
    /// Maximum returned lines, clamped to 1 through 10000.
    pub limit: Option<usize>,
}

/// Ordered display text with an explicit indication of incomplete evidence.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LogQueryResponse {
    /// Chronologically merged filtered lines, without a trailing newline.
    pub content: String,
    /// True when the input-byte or returned-line budget omitted evidence.
    pub truncated: bool,
    /// Matching lines before the returned-line limit is applied.
    pub matched_lines: usize,
}

fn severity(level: &str) -> u8 {
    match level.to_ascii_uppercase().as_str() {
        "DEBUG" | "TRACE" => 0,
        "WARN" | "WARNING" => 2,
        "ERROR" | "FATAL" => 3,
        _ => 1,
    }
}

/// Merges module files into a stable timeline and applies the same filters on both hosts.
pub fn query_logs(request: LogQueryRequest) -> LogQueryResponse {
    let mut lines = Vec::new();
    let mut remaining = MAX_LOG_EXPORT_BYTES;
    let mut truncated = false;
    let needle = request.search.as_deref().unwrap_or("").to_lowercase();
    let since = request.since.as_deref().and_then(parse_timestamp);
    let until = request.until.as_deref().and_then(parse_timestamp);
    for source in request.sources {
        if request
            .category
            .as_ref()
            .is_some_and(|c| c != &source.category)
        {
            continue;
        }
        if source.text.len() > remaining {
            truncated = true;
        }
        for line in source.text.lines() {
            if line.len() > remaining {
                truncated = true;
                break;
            }
            remaining = remaining.saturating_sub(line.len() + 1);
            let mut parts = line.split_whitespace();
            let time = parts.next().unwrap_or("");
            let level = parts.next().unwrap_or("INFO");
            if request
                .minimum_level
                .as_ref()
                .is_some_and(|l| severity(level) < severity(l))
            {
                continue;
            }
            if request
                .session_id
                .as_ref()
                .is_some_and(|s| !line.contains(&format!("[session={s}]")))
            {
                continue;
            }
            if since.is_some() || until.is_some() {
                let Some(timestamp) = parse_timestamp(time) else {
                    continue;
                };
                if since.is_some_and(|bound| timestamp < bound)
                    || until.is_some_and(|bound| timestamp > bound)
                {
                    continue;
                }
            }
            if !needle.is_empty() && !line.to_lowercase().contains(&needle) {
                continue;
            }
            lines.push(line.to_owned());
        }
    }
    // Compare instants, including legacy offsets and varying fractional precision.
    // Stable ties preserve source ordering for legacy records without a sequence.
    lines.sort_by(|left, right| {
        fn key(line: &str) -> (Option<DateTime<FixedOffset>>, &str, u64) {
            let timestamp = parse_timestamp(line.split_whitespace().next().unwrap_or(""));
            let session = line
                .split_once("[session=")
                .and_then(|(_, tail)| tail.split_once(']'))
                .map(|(session, _)| session)
                .unwrap_or("");
            let sequence = line
                .split_once("sequence=")
                .map(|(_, tail)| {
                    tail.chars()
                        .take_while(char::is_ascii_digit)
                        .collect::<String>()
                })
                .and_then(|digits| digits.parse().ok())
                .unwrap_or(0);
            (timestamp, session, sequence)
        }
        key(left).cmp(&key(right))
    });
    let matched_lines = lines.len();
    let limit = request.limit.unwrap_or(2000).clamp(1, 10000);
    if lines.len() > limit {
        lines.drain(..lines.len() - limit);
        truncated = true;
    }
    LogQueryResponse {
        content: lines.join("\n"),
        truncated,
        matched_lines,
    }
}

fn parse_timestamp(value: &str) -> Option<DateTime<FixedOffset>> {
    DateTime::parse_from_rfc3339(value).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn scrubs_nested_secrets_before_json_escaping_and_bounds_arrays() {
        let event = prepare_log_event(
            serde_json::from_value(json!({
                "scope":"language.java", "message":"started", "fields":{
                    "context":{"password":"fake-password","items":[{"accessToken":"fake-token"}]},
                    "sourceContent":"private source", "operationID":"operation-1"
                }
            }))
            .unwrap(),
        );
        let encoded = serde_json::to_string(&event).unwrap();
        assert!(!encoded.contains("fake-password"));
        assert!(!encoded.contains("fake-token"));
        assert!(!encoded.contains("private source"));
        assert!(encoded.contains("operation-1"));
        assert_eq!(event.category, "language");
    }

    #[test]
    fn queries_merge_categories_and_filter_sessions_levels_and_bounds() {
        let query: LogQueryRequest = serde_json::from_value(json!({"sources":[
            {"category":"git","text":"2026-10-20T01:00:02Z ERROR [session=a] failed\n"},
            {"category":"language","text":"2026-10-20T01:00:01Z INFO [session=a] ready\n2026-10-20T01:00:03Z WARN [session=b] failed\n"}
        ],"sessionId":"a","minimumLevel":"warn","limit":1})).unwrap();
        let result = query_logs(query);
        assert!(result.content.contains("ERROR"));
        assert!(!result.content.contains("ready"));
        assert!(!result.content.contains("session=b"));
        assert_eq!(result.matched_lines, 1);
    }

    #[test]
    fn long_quoted_secrets_remain_redacted_when_input_is_bounded() {
        let event = prepare_log_event(LogEventRequest {
            scope: "application".into(),
            message: format!("password=\"{}\"", "synthetic secret words ".repeat(2000)),
            fields: BTreeMap::new(),
        });
        assert!(!event.message.contains("synthetic"));
        assert!(!event.message.contains("secret words"));
    }

    #[test]
    fn queued_context_has_an_aggregate_budget_and_safe_field_names() {
        let request =
            serde_json::from_value(json!({"scope":"git.fetch","message":"completed","fields":{
                "context": vec![vec!["x".repeat(4000); 24]; 24], "line\nspoof": "safe"
            }}))
            .unwrap();
        let event = prepare_log_event(request);
        assert!(serde_json::to_vec(&event.fields).unwrap().len() < 4096);
        assert!(event.fields.keys().all(|key| !key.contains('\n')));
    }

    #[test]
    fn same_tick_events_keep_sequence_order_across_levels() {
        let result = query_logs(serde_json::from_value(json!({"sources":[{"category":"run","text":
            "2026-10-20T00:00:00.001Z ERROR [session=a] finished sequence=0002\n2026-10-20T00:00:00.001Z INFO [session=a] started sequence=0001"}]})).unwrap());
        assert!(result.content.find("started").unwrap() < result.content.find("finished").unwrap());
    }

    #[test]
    fn time_filters_and_ordering_compare_instants_from_the_shared_fixture() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/diagnostics/logging-v1.json"
        ))
        .unwrap();
        for case in fixture["timeQueries"].as_array().unwrap() {
            let result = query_logs(serde_json::from_value(case["request"].clone()).unwrap());
            let messages = result
                .content
                .lines()
                .map(|line| line.split_whitespace().last().unwrap())
                .collect::<Vec<_>>();
            assert_eq!(serde_json::json!(messages), case["messages"], "{case}");
        }
    }

    #[test]
    fn shared_fixture_pins_domains_and_budgets() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/diagnostics/logging-v1.json"
        ))
        .unwrap();
        assert_eq!(fixture["categories"], serde_json::json!(LOG_CATEGORIES));
        assert_eq!(fixture["limits"]["fileBytes"], MAX_LOG_FILE_BYTES);
        assert_eq!(fixture["limits"]["totalBytes"], MAX_LOG_TOTAL_BYTES);
        assert_eq!(fixture["limits"]["performanceBytes"], MAX_PERFORMANCE_BYTES);
        for case in fixture["cases"].as_array().unwrap() {
            assert_eq!(
                log_category(case["scope"].as_str().unwrap()),
                case["category"].as_str().unwrap()
            );
        }
    }

    #[test]
    fn domains_are_fixed_even_for_untrusted_scopes() {
        assert_eq!(log_category("perf.fps"), "performance");
        assert_eq!(log_category("git.fetch"), "git");
        assert_eq!(log_category("../../escape"), "application");
    }
}
