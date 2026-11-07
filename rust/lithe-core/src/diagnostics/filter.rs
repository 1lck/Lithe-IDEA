//! Parses and composes bounded log filters; hosts only render UTF-16 diagnostics and submit queries.

use super::channel::LogError;
use super::record::{LogLevel, LogRecord};
use regex::{Regex, RegexBuilder};
use serde::{Deserialize, Serialize};

const EXPRESSION_BYTES: usize = 1024;
const REGEX_CHARS: usize = 256;
const REGEX_BYTES: usize = 1024 * 1024;

/// Stable filter operators shared by query evaluation and native context menus.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FilterKind {
    /// Inclusive minimum severity.
    LevelAtLeast,
    /// Exact severity.
    Level,
    /// Case-insensitive operation prefix.
    Op,
    /// Case-insensitive event prefix.
    Event,
    /// Case-insensitive channel prefix, without slash-boundary restrictions.
    Channel,
    /// Case-insensitive, linear-time message regular expression.
    Regex,
    /// Case-insensitive field-value substring.
    Field,
    /// Case-insensitive substring across the existing search scope.
    Text,
}
/// An owned term; keys are present only for field terms.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
pub struct FilterTerm {
    /// Predicate operator shared with the native filter editor.
    pub kind: FilterKind,
    /// Case-insensitive context or reserved field key; absent for other operators.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
    /// Decoded predicate value without quotes or delimiters.
    pub value: String,
    /// True reverses this predicate before intersecting it with other terms.
    #[serde(default)]
    pub negate: bool,
}
/// Half-open UTF-16 offsets include the negation prefix and quotes, for SwiftUI highlighting.
#[derive(Debug, Serialize)]
pub struct ParsedFilterTerm {
    /// Owned predicate independent of its source spelling.
    #[serde(flatten)]
    pub term: FilterTerm,
    /// Inclusive UTF-16 offset in the original expression.
    pub start: usize,
    /// Exclusive UTF-16 offset in the original expression.
    pub end: usize,
}
/// Stable technical diagnostics; hosts localize codes instead of displaying these English descriptions.
#[derive(Debug, Serialize)]
pub struct FilterDiagnostic {
    /// Inclusive UTF-16 offset in the original expression.
    pub start: usize,
    /// Exclusive UTF-16 offset in the original expression.
    pub end: usize,
    /// Stable diagnostic identity for host localization.
    pub code: &'static str,
    /// Fixed English technical description; hosts present localized code text.
    pub message: &'static str,
}
/// Bounded expression input; no clock or I/O participates in parsing.
#[derive(Debug, Deserialize)]
pub struct ParseLogFilterRequest {
    /// User filter expression, limited to 1024 UTF-8 bytes.
    pub expression: String,
}
/// Valid terms and all recoverable syntax diagnostics, in original source order.
#[derive(Debug, Serialize)]
pub struct ParsedLogFilter {
    /// Valid predicates in source order.
    pub terms: Vec<ParsedFilterTerm>,
    /// Recoverable syntax diagnostics in source order.
    pub errors: Vec<FilterDiagnostic>,
}
/// Context-menu composition preserves unrelated original tokens and their order.
#[derive(Debug, Deserialize)]
pub struct ComposeLogFilterRequest {
    /// User filter expression, limited to 1024 UTF-8 bytes.
    pub expression: String,
    /// Owned predicate independent of its source spelling.
    pub term: FilterTerm,
}
/// The composed expression, still subject to the same 1024-byte budget.
#[derive(Debug, Serialize)]
pub struct ComposedLogFilter {
    /// User filter expression, limited to 1024 UTF-8 bytes.
    pub expression: String,
}

struct CompiledTerm {
    term: FilterTerm,
    regex: Option<Regex>,
    needle: String,
    start: usize,
    end: usize,
}
/// Per-query compiled predicates, never stored globally or recompiled for each record.
pub(super) struct CompiledFilter(Vec<CompiledTerm>);

fn invalid() -> LogError {
    LogError::new(-32060, "Invalid log filter expression")
}
fn level(value: &str) -> Option<LogLevel> {
    match value.to_ascii_lowercase().as_str() {
        "debug" | "dbg" => Some(LogLevel::Debug),
        "info" | "inf" => Some(LogLevel::Info),
        "warn" | "wrn" => Some(LogLevel::Warn),
        "error" | "err" => Some(LogLevel::Error),
        _ => None,
    }
}
fn field_key(key: &str) -> bool {
    !key.is_empty()
        && key
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_.".contains(&b))
}
fn compile_regex(pattern: &str) -> Result<Regex, &'static str> {
    if pattern.chars().count() > REGEX_CHARS {
        return Err("regexTooLong");
    }
    RegexBuilder::new(pattern)
        .case_insensitive(true)
        .size_limit(REGEX_BYTES)
        .dfa_size_limit(REGEX_BYTES)
        .build()
        .map_err(|_| "invalidRegex")
}
// Quotes use JSON-style escaping for quote/backslash only. Regex escapes stay untouched.
fn unquote(value: &str) -> Result<String, &'static str> {
    if !value.starts_with('"') {
        return if value.contains('"') {
            Err("invalidQuote")
        } else {
            Ok(value.into())
        };
    }
    if !value.ends_with('"') || value.len() < 2 {
        return Err("unterminatedQuote");
    }
    let mut result = String::new();
    let mut chars = value[1..value.len() - 1].chars();
    while let Some(c) = chars.next() {
        match c {
            '\\' => match chars.next() {
                Some(c @ ('\\' | '"')) => result.push(c),
                _ => return Err("invalidEscape"),
            },
            '"' => return Err("invalidQuote"),
            c => result.push(c),
        }
    }
    Ok(result)
}
fn term(raw: &str) -> Result<(FilterTerm, Option<Regex>), &'static str> {
    let negate = raw.starts_with('-') && raw.len() > 1;
    let body = if negate { &raw[1..] } else { raw };
    let lower = body.to_ascii_lowercase();
    let (kind, key, value) = if lower.starts_with("level>=") {
        (FilterKind::LevelAtLeast, None, unquote(&body[7..])?)
    } else if body.starts_with('/') {
        if body.len() < 2 || !body.ends_with('/') {
            return Err("unterminatedRegex");
        }
        (FilterKind::Regex, None, body[1..body.len() - 1].into())
    } else if body.starts_with('"') {
        (FilterKind::Text, None, unquote(body)?)
    } else if let Some(at) = body.find([':', '=']).filter(|at| field_key(&body[..*at])) {
        let key = body[..at].to_ascii_lowercase();
        let kind = match key.as_str() {
            "level" => FilterKind::Level,
            "op" => FilterKind::Op,
            "event" => FilterKind::Event,
            "channel" => FilterKind::Channel,
            _ => FilterKind::Field,
        };
        // Reserved operators have one spelling; '=' remains available for ordinary fields.
        if kind != FilterKind::Field && body.as_bytes()[at] != b':' {
            return Err("invalidOperator");
        }
        (
            kind,
            (kind == FilterKind::Field).then_some(key),
            unquote(&body[at + 1..])?,
        )
    } else {
        (FilterKind::Text, None, unquote(body)?)
    };
    if value.is_empty() {
        return Err("emptyValue");
    }
    let value = if matches!(kind, FilterKind::Level | FilterKind::LevelAtLeast) {
        level(&value)
            .ok_or("invalidLevel")?
            .label()
            .to_ascii_lowercase()
    } else {
        value
    };
    let regex = if kind == FilterKind::Regex {
        Some(compile_regex(&value)?)
    } else {
        None
    };
    Ok((
        FilterTerm {
            kind,
            key,
            value,
            negate,
        },
        regex,
    ))
}
fn diagnostic(expression: &str, start: usize, end: usize, code: &'static str) -> FilterDiagnostic {
    FilterDiagnostic {
        start: expression[..start].encode_utf16().count(),
        end: expression[..end].encode_utf16().count(),
        code,
        message: match code {
            "expressionTooLong" => "Filter exceeds 1024 UTF-8 bytes",
            "regexTooLong" => "Regex exceeds 256 characters",
            "invalidRegex" => "Invalid or oversized regular expression",
            "invalidLevel" => "Unknown log severity",
            "emptyValue" => "Filter value is empty",
            "unterminatedRegex" => "Unterminated regular expression",
            "unterminatedQuote" => "Unterminated quoted value",
            "invalidEscape" => "Only quote and backslash may be escaped in quoted values",
            "invalidOperator" => "Reserved filters require a colon",
            _ => "Invalid quoted value",
        },
    }
}
fn parse(expression: &str) -> (CompiledFilter, Vec<FilterDiagnostic>) {
    let mut terms = Vec::new();
    let mut errors = Vec::new();
    if expression.len() > EXPRESSION_BYTES {
        // Cap diagnostic work too; byte length is known without scanning an unbounded input.
        errors.push(FilterDiagnostic {
            start: 0,
            end: 0,
            code: "expressionTooLong",
            message: "Filter exceeds 1024 UTF-8 bytes",
        });
        return (CompiledFilter(terms), errors);
    }
    let mut iter = expression.char_indices().peekable();
    while let Some((start, c)) = iter.next() {
        if c.is_whitespace() {
            continue;
        }
        let body = expression[start..]
            .strip_prefix('-')
            .filter(|s| !s.starts_with(char::is_whitespace))
            .unwrap_or(&expression[start..]);
        let is_regex = body.starts_with('/');
        let mut quoted = c == '"';
        let mut escaped = false;
        let mut regex_closed = false;
        let mut end = expression.len();
        while let Some(&(at, c)) = iter.peek() {
            if c.is_whitespace() && !quoted && (!is_regex || regex_closed) {
                end = at;
                break;
            }
            iter.next();
            if escaped {
                escaped = false;
                continue;
            }
            if c == '\\' && (quoted || is_regex) {
                escaped = true;
                continue;
            }
            if is_regex {
                if c == '/' && at > start + usize::from(expression[start..].starts_with('-')) {
                    regex_closed = true;
                }
            } else if c == '"' {
                quoted = !quoted;
            }
        }
        match term(&expression[start..end]) {
            Ok((term, regex)) => terms.push(CompiledTerm {
                needle: term.value.to_lowercase(),
                term,
                regex,
                start,
                end,
            }),
            Err(code) => errors.push(diagnostic(expression, start, end, code)),
        }
    }
    (CompiledFilter(terms), errors)
}
/// Parses without rejecting incomplete user drafts; ranges use UTF-16 code units, not UTF-8 bytes.
pub fn parse_log_filter(request: ParseLogFilterRequest) -> ParsedLogFilter {
    let (compiled, errors) = parse(&request.expression);
    ParsedLogFilter {
        terms: compiled
            .0
            .into_iter()
            .map(|t| ParsedFilterTerm {
                start: request.expression[..t.start].encode_utf16().count(),
                end: request.expression[..t.end].encode_utf16().count(),
                term: t.term,
            })
            .collect(),
        errors,
    }
}
fn quote(value: &str) -> String {
    format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
}
fn render(term: &FilterTerm) -> String {
    let value = if term
        .value
        .chars()
        .any(|c| c.is_whitespace() || c == '"' || c == '\\')
    {
        quote(&term.value)
    } else {
        term.value.clone()
    };
    let body = match term.kind {
        FilterKind::LevelAtLeast => format!("level>={value}"),
        FilterKind::Level => format!("level:{value}"),
        FilterKind::Op => format!("op:{value}"),
        FilterKind::Event => format!("event:{value}"),
        FilterKind::Channel => format!("channel:{value}"),
        FilterKind::Field => format!("{}:{value}", term.key.as_deref().unwrap_or("")),
        FilterKind::Regex => format!("/{}/", term.value),
        // Always quote text so reserved syntax and a leading '-' remain literal.
        FilterKind::Text => quote(&term.value),
    };
    format!("{}{body}", if term.negate { "-" } else { "" })
}
/// Replaces matching positive terms at their first position; identical negative terms are idempotent.
/// Invalid drafts/terms or a composed expression over budget return -32060.
pub fn compose_log_filter(request: ComposeLogFilterRequest) -> Result<ComposedLogFilter, LogError> {
    if request.term.value.len() > EXPRESSION_BYTES
        || request
            .term
            .key
            .as_ref()
            .is_some_and(|k| k.len() > EXPRESSION_BYTES)
    {
        return Err(invalid());
    }
    if request.term.kind != FilterKind::Field && request.term.key.is_some() {
        return Err(invalid());
    }
    let rendered = render(&request.term);
    let (new, errors) = parse(&rendered);
    if !errors.is_empty() || new.0.len() != 1 {
        return Err(invalid());
    }
    let canonical = &new.0[0].term;
    if canonical.kind != request.term.kind
        || canonical.negate != request.term.negate
        || canonical.key != request.term.key.as_ref().map(|k| k.to_ascii_lowercase())
    {
        return Err(invalid());
    }
    let (old, errors) = parse(&request.expression);
    if !errors.is_empty() {
        return Err(invalid());
    }
    let same_value = |a: &FilterTerm, b: &FilterTerm| {
        a.kind == b.kind
            && a.key == b.key
            && (if a.kind == FilterKind::Regex {
                a.value == b.value
            } else {
                a.value.to_lowercase() == b.value.to_lowercase()
            })
    };
    if canonical.negate
        && old
            .0
            .iter()
            .any(|t| t.term.negate && same_value(&t.term, canonical))
    {
        return Ok(ComposedLogFilter {
            expression: request.expression,
        });
    }
    let mut expression = String::new();
    let mut cursor = 0;
    let mut replaced = false;
    for t in &old.0 {
        if !canonical.negate
            && !t.term.negate
            && t.term.kind == canonical.kind
            && t.term.key == canonical.key
        {
            expression.push_str(&request.expression[cursor..t.start]);
            if !replaced {
                expression.push_str(&rendered);
                replaced = true;
            }
            cursor = t.end;
        }
    }
    expression.push_str(&request.expression[cursor..]);
    if !replaced {
        if !expression.is_empty() && !expression.ends_with(char::is_whitespace) {
            expression.push(' ');
        }
        expression.push_str(&rendered);
    }
    if expression.len() > EXPRESSION_BYTES {
        return Err(invalid());
    }
    Ok(ComposedLogFilter { expression })
}
/// Matches the exact same message/identity/context scope as the legacy search argument.
pub(super) fn search_matches(record: &LogRecord, channel: &str, needle: &str) -> bool {
    format!(
        "{} {} {} {} {:?}",
        channel,
        record.event,
        record.op.as_deref().unwrap_or(""),
        record.msg,
        record.fields
    )
    .to_lowercase()
    .contains(needle)
}
impl CompiledFilter {
    pub(super) fn compile(expression: &str) -> Result<Self, LogError> {
        let (filter, errors) = parse(expression);
        if errors.is_empty() {
            Ok(filter)
        } else {
            Err(invalid())
        }
    }
    pub(super) fn matches(&self, record: &LogRecord, channel: &str) -> bool {
        self.0.iter().all(|t| {
            let value = &t.needle;
            let matched = match t.term.kind {
                FilterKind::LevelAtLeast => record.level >= level(value).expect("validated level"),
                FilterKind::Level => Some(record.level) == level(value),
                FilterKind::Op => record
                    .op
                    .as_ref()
                    .is_some_and(|op| op.to_lowercase().starts_with(value)),
                FilterKind::Event => record.event.to_lowercase().starts_with(value),
                FilterKind::Channel => channel.to_lowercase().starts_with(value),
                FilterKind::Regex => t
                    .regex
                    .as_ref()
                    .expect("compiled regex")
                    .is_match(&record.msg),
                FilterKind::Text => search_matches(record, channel, value),
                FilterKind::Field => {
                    let field = match t.term.key.as_deref().unwrap_or("") {
                        "ts" => Some(record.ts.clone()),
                        "level" => Some(record.level.label().into()),
                        "seq" => Some(record.seq.to_string()),
                        "event" => Some(record.event.clone()),
                        "op" => record.op.clone(),
                        "msg" => Some(record.msg.clone()),
                        key => record
                            .fields
                            .iter()
                            .find(|(k, _)| k.eq_ignore_ascii_case(key))
                            .map(|(_, v)| v.clone()),
                    };
                    field.is_some_and(|s| s.to_lowercase().contains(value))
                }
            };
            matched != t.term.negate
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn quoted_terms_utf16_aliases_and_invalid_patterns() {
        let parsed = parse_log_filter(ParseLogFilterRequest {
            expression: "\"😀 a\" server:\"a b\" -event:Fail LEVEL>=WrN - /a b/".into(),
        });
        assert!(parsed.errors.is_empty(), "{:?}", parsed.errors);
        assert_eq!((parsed.terms[0].start, parsed.terms[0].end), (0, 6));
        assert_eq!(parsed.terms[1].start, 7);
        assert_eq!(parsed.terms[1].term.value, "a b");
        assert_eq!(parsed.terms[3].term.value, "warn");
        assert_eq!(parsed.terms[4].term.value, "-");
        for expression in [
            "level:bad",
            "server:",
            "\"open",
            "/[/",
            "level=info",
            "/open",
            "op:\"bad\\n\"",
        ] {
            assert!(
                !parse_log_filter(ParseLogFilterRequest {
                    expression: expression.into()
                })
                .errors
                .is_empty(),
                "{expression}"
            );
            assert_eq!(
                CompiledFilter::compile(expression).err().unwrap().code,
                -32060
            );
        }
        for expression in ["x".repeat(1025), format!("/{}/", "a".repeat(257))] {
            assert!(!parse_log_filter(ParseLogFilterRequest { expression })
                .errors
                .is_empty());
        }
    }
    #[test]
    fn composition_replaces_only_positive_matching_keys_and_preserves_other_source() {
        let compose = |expression: &str, value| {
            compose_log_filter(
                serde_json::from_value(json!({"expression":expression,"term":value})).unwrap(),
            )
            .unwrap()
            .expression
        };
        let value = json!({"kind":"field","key":"server","value":"a b","negate":false});
        assert_eq!(
            compose(
                "foo  server:old plugin:p -server:hidden server:other",
                value
            ),
            "foo  server:\"a b\" plugin:p -server:hidden "
        );
        let neg = json!({"kind":"event","value":"failed","negate":true});
        assert_eq!(
            compose("foo -event:FAILED", neg.clone()),
            "foo -event:FAILED"
        );
        assert_eq!(compose("foo", neg), "foo -event:failed");
        for value in ["-literal", "event:literal", "a\"b\\c"] {
            let expression = compose("", json!({"kind":"text","value":value}));
            let parsed = parse_log_filter(ParseLogFilterRequest { expression });
            assert!(parsed.errors.is_empty());
            assert_eq!(parsed.terms[0].term.value, value);
            assert!(!parsed.terms[0].term.negate);
        }
    }
    #[test]
    fn predicates_match_prefixes_fields_regex_negation_and_search_scope() {
        let record = LogRecord {
            ts: "2026-11-03T00:00:00.000Z".into(),
            level: LogLevel::Warn,
            seq: 1,
            event: "app.failed".into(),
            op: Some("ABC-12".into()),
            msg: "A failure".into(),
            fields: [("server".into(), "TOOL-A".into())].into(),
        };
        for expression in [
            "level>=inf level:wrn op:abc event:APP channel:LS server=ol /FAIL/",
            "TOOL-A",
            "-plugin:p",
            "seq:1",
        ] {
            assert!(
                CompiledFilter::compile(expression)
                    .unwrap()
                    .matches(&record, "lsp/tool-a"),
                "{expression}"
            );
        }
        for expression in ["-event:app", "level:err", "server:missing", "/success/"] {
            assert!(
                !CompiledFilter::compile(expression)
                    .unwrap()
                    .matches(&record, "lsp/tool-a"),
                "{expression}"
            );
        }
    }
}
