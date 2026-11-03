//! Owns generated event metadata and strict validation of encoded catalog fields.

use super::channel::validate_segment;
use super::record::LogLevel;
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

/// Closed logical field vocabulary; there is no arbitrary JSON/raw field type.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FieldType {
    /// Signed 64-bit integer.
    Int,
    /// Boolean flag.
    Bool,
    /// Nonnegative integer milliseconds, encoded with an `_ms` suffix.
    Duration,
    /// Unsigned byte count.
    Bytes,
    /// Validated opaque channel segment.
    Id,
    /// Short controlled machine word, never a user-provided command line.
    Token,
    /// Bounded component version, without whitespace.
    Version,
    /// Path input; the persistence boundary must redact it.
    Path,
    /// Error expanded to the named message plus `_code` and `_domain` fields.
    Error,
    /// Upstream-only diagnostic, redacted and limited to 1 KiB before persistence.
    Text,
}

/// A generated operation phase. Hosts filter started events by the DEBUG severity.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SpanPhase {
    /// Operation start at DEBUG severity, available to verbose diagnostics in every build.
    Started,
    /// Successful terminal observation with duration.
    Finished,
    /// Failed terminal observation with duration and structured error.
    Failed,
}

/// One logical field declaration, borrowed from the compiled catalog.
#[derive(Debug)]
pub struct FieldMetadata {
    /// Logical key before duration/error expansion.
    pub name: &'static str,
    /// Closed field type.
    pub field_type: FieldType,
    /// Whether every encoded component must be present.
    pub required: bool,
    /// Meaning and units for maintainers.
    pub description: &'static str,
    /// Why upstream free text cannot be represented by structured context.
    pub reason: Option<&'static str>,
}

/// Immutable metadata; owned by the binary, never loaded from runtime resources.
#[derive(Debug)]
pub struct EventMetadata {
    /// Stable dotted event identity.
    pub id: &'static str,
    /// Fixed root and validated identifier placeholders.
    pub channel: &'static str,
    /// Canonical severity.
    pub level: LogLevel,
    /// English message template; persistence owns interpolation and redaction.
    pub message: &'static str,
    /// Logical fields before disk-key expansion.
    pub fields: &'static [FieldMetadata],
    /// Operation phase, when generated from a span.
    pub span: Option<SpanPhase>,
    /// Maximum events per minute for this event and channel.
    pub rate: u32,
    /// Module responsible for maintaining the event.
    pub owner: &'static str,
}

// The comment gate requires module-level inner docs in every .rs file. Rust
// rejects those docs through include!, so load the generated table as a module.
#[path = "catalog_generated.rs"]
mod generated;
pub use generated::EVENTS;

/// Finds borrowed metadata in logarithmic time without allocating.
pub fn event_by_id(id: &str) -> Option<&'static EventMetadata> {
    EVENTS
        .binary_search_by_key(&id, |event| event.id)
        .ok()
        .map(|index| &EVENTS[index])
}

/// Closed catalog failure classifications; each has a distinct host error code.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CatalogErrorCode {
    /// No declaration owns the supplied event identity.
    UnknownEvent,
    /// A required encoded field component is absent.
    MissingField,
    /// An encoded value violates its declaration.
    InvalidField,
    /// An undeclared encoded key was supplied.
    UnknownField,
}

/// A field-contract violation. The value itself is deliberately excluded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CatalogError {
    /// Stable machine-readable classification.
    pub code: CatalogErrorCode,
    /// Logical or encoded key; absent for unknown event IDs.
    pub field: Option<String>,
}

fn invalid(code: CatalogErrorCode, field: &str) -> CatalogError {
    CatalogError {
        code,
        field: Some(field.to_owned()),
    }
}

fn word(value: &Value, max: usize, extra: &[u8]) -> bool {
    value.as_str().is_some_and(|text| {
        !text.is_empty()
            && text.len() <= max
            && text
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || extra.contains(&byte))
    })
}

fn scalar_matches(kind: FieldType, value: &Value) -> bool {
    match kind {
        FieldType::Int => value.as_i64().is_some(),
        FieldType::Bool => value.is_boolean(),
        FieldType::Duration | FieldType::Bytes => value.as_u64().is_some(),
        FieldType::Id => value
            .as_str()
            .is_some_and(|text| validate_segment(text).is_ok()),
        FieldType::Token => word(value, 64, b"._:/-$"),
        FieldType::Version => word(value, 64, b"._+-"),
        FieldType::Path => value.as_str().is_some_and(|text| {
            !text.is_empty() && text.len() <= 4096 && !text.chars().any(char::is_control)
        }),
        FieldType::Text | FieldType::Error => value
            .as_str()
            .is_some_and(|text| text.len() <= 1024 && !text.chars().any(char::is_control)),
    }
}

/// Validates normalized disk fields: duration uses `<name>_ms`; errors use
/// `<name>`, `<name>_code` (integer or token) and `<name>_domain` (token).
/// Optional errors are all-or-none. This checks shape and limits, not privacy:
/// callers must still use Core redaction before persistence. No values are logged.
pub fn validate_fields(id: &str, fields: &BTreeMap<String, Value>) -> Result<(), CatalogError> {
    let event = event_by_id(id).ok_or(CatalogError {
        code: CatalogErrorCode::UnknownEvent,
        field: None,
    })?;
    let mut allowed = BTreeSet::new();
    for field in event.fields {
        let encoded = match field.field_type {
            FieldType::Duration => vec![(format!("{}_ms", field.name), FieldType::Duration)],
            FieldType::Error => vec![
                (field.name.to_owned(), FieldType::Error),
                (format!("{}_code", field.name), FieldType::Token),
                (format!("{}_domain", field.name), FieldType::Token),
            ],
            kind => vec![(field.name.to_owned(), kind)],
        };
        let present = encoded
            .iter()
            .filter(|(key, _)| fields.contains_key(key))
            .count();
        for (key, kind) in &encoded {
            allowed.insert(key.clone());
            match fields.get(key) {
                None if field.required || present > 0 => {
                    return Err(invalid(CatalogErrorCode::MissingField, key))
                }
                Some(value) => {
                    let numeric_code = field.field_type == FieldType::Error
                        && key.ends_with("_code")
                        && value.as_i64().is_some();
                    if !numeric_code && !scalar_matches(*kind, value) {
                        return Err(invalid(CatalogErrorCode::InvalidField, key));
                    }
                }
                None => {}
            }
        }
    }
    if let Some(key) = fields.keys().find(|key| !allowed.contains(*key)) {
        return Err(invalid(CatalogErrorCode::UnknownField, key));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn catalog_lookup_and_span_contract() {
        assert!(EVENTS.windows(2).all(|pair| pair[0].id < pair[1].id));
        assert!(event_by_id("not.an.event").is_none());
        let event = event_by_id("vcs.git.command.failed").unwrap();
        assert_eq!(event.channel, "vcs/{provider}");
        assert_eq!(event.span, Some(SpanPhase::Failed));
        let fields = BTreeMap::from([
            ("provider".into(), json!("git")),
            ("command".into(), json!("fetch")),
            ("duration_ms".into(), json!(311)),
            ("error".into(), json!("fetch failed")),
            ("error_code".into(), json!(128)),
            ("error_domain".into(), json!("git")),
        ]);
        assert_eq!(validate_fields(event.id, &fields), Ok(()));
        for (key, value) in [
            ("duration_ms", json!(-1)),
            ("provider", json!("../bad")),
            ("command", json!("fetch --token secret")),
        ] {
            let mut invalid = fields.clone();
            invalid.insert(key.into(), value);
            assert_eq!(
                validate_fields(event.id, &invalid).unwrap_err().code,
                CatalogErrorCode::InvalidField
            );
        }
        let mut missing = fields.clone();
        missing.remove("error_domain");
        assert_eq!(
            validate_fields(event.id, &missing).unwrap_err().code,
            CatalogErrorCode::MissingField
        );
        let mut extra = fields;
        extra.insert("raw".into(), json!("forbidden"));
        assert_eq!(
            validate_fields(event.id, &extra).unwrap_err().code,
            CatalogErrorCode::UnknownField
        );
    }

    #[test]
    fn catalog_text_and_optional_error_are_bounded() {
        let mut fields = BTreeMap::from([
            ("server".into(), json!("java")),
            ("diagnostic".into(), json!("upstream diagnostic")),
        ]);
        assert!(validate_fields("lsp.stderr.received", &fields).is_ok());
        fields.insert("diagnostic".into(), json!("x".repeat(1025)));
        assert_eq!(
            validate_fields("lsp.stderr.received", &fields)
                .unwrap_err()
                .code,
            CatalogErrorCode::InvalidField
        );
        let fields = BTreeMap::from([("failure_code".into(), json!("request_failed"))]);
        assert!(validate_fields("remote.upload.abort_failed", &fields).is_ok());
        let fields = BTreeMap::from([
            ("plugin".into(), json!("io.example")),
            ("language".into(), json!("java")),
            ("error".into(), json!("failed")),
        ]);
        assert_eq!(
            validate_fields("plugins.grammar.load_failed", &fields)
                .unwrap_err()
                .code,
            CatalogErrorCode::MissingField
        );
    }
}
