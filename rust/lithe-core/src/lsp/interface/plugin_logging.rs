//! Validates plugin diagnostic facts before handing them to the host's single writer.

use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};

pub(super) const FEATURE: &str = "litheLogging";
pub(super) const METHOD: &str = "lithe/log";
const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;

/// Closed facts select catalog severity; a plugin cannot choose a disk event or channel.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
enum Kind {
    OperationFinished,
    OperationFailed,
    Degraded,
    Recovered,
}

/// Only scalar diagnostic metadata crosses this ingress; arbitrary messages are forbidden.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Input {
    kind: Kind,
    operation: String,
    duration_ms: Option<u64>,
    code: Option<String>,
    count: Option<u64>,
    operation_id: Option<String>,
}

pub(super) fn negotiated(capabilities: &Value) -> bool {
    capabilities.pointer("/experimental/litheLogging/version") == Some(&json!(1))
}

fn token(value: &str, limit: usize) -> bool {
    !value.is_empty()
        && value.len() <= limit
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._:/-$".contains(&b))
}

fn known_operation(operation: &str, functions: &BTreeSet<String>) -> bool {
    functions.contains(operation)
        || matches!(
            operation,
            "initialize" | "shutdown" | "notification" | "function-call" | "result-encoding"
        )
        || operation == super::keymap_provider::IMPORT_METHOD
        || super::build_provider::is_build_method(operation)
        || crate::vcs::is_vcs_method(operation)
}

/// A catalog fact with no plugin-selected identity, message, severity, or raw error text.
pub(super) struct Fact {
    pub(super) event: &'static str,
    pub(super) fields: BTreeMap<String, Value>,
    /// Wire correlation is resolved to the owning host operation by the runtime.
    pub(super) wire_operation: Option<String>,
}

/// Rejects unknown fields and unregistered operations without echoing private input.
pub(super) fn decode(plugin: &str, functions: &BTreeSet<String>, params: &Value) -> Option<Fact> {
    let input = Input::deserialize(params).ok()?;
    if !token(&input.operation, 64)
        || !known_operation(&input.operation, functions)
        || input.code.as_deref().is_some_and(|code| !token(code, 64))
        || input
            .operation_id
            .as_deref()
            .is_some_and(|op| !token(op, 128))
        || input
            .duration_ms
            .is_some_and(|value| value > MAX_SAFE_INTEGER)
        || input.count.is_some_and(|value| value > MAX_SAFE_INTEGER)
    {
        return None;
    }
    let (event, needs_duration, needs_code) = match input.kind {
        Kind::OperationFinished => ("plugins.operation.finished", true, false),
        Kind::OperationFailed => ("plugins.operation.failed", true, true),
        Kind::Degraded => ("plugins.operation.fallback_selected", false, true),
        Kind::Recovered => ("plugins.operation.recovery_finished", false, true),
    };
    if needs_duration != input.duration_ms.is_some() || needs_code != input.code.is_some() {
        return None;
    }
    let mut fields = BTreeMap::from([
        ("plugin".into(), json!(plugin)),
        ("operation".into(), json!(input.operation)),
    ]);
    if let Some(duration) = input.duration_ms {
        fields.insert("duration_ms".into(), json!(duration));
    }
    if let Some(code) = input.code {
        fields.insert("code".into(), json!(code));
    }
    if let Some(count) = input.count {
        fields.insert("count".into(), json!(count));
    }
    Some(Fact {
        event,
        fields,
        wire_operation: input.operation_id,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shared_plugin_logging_fixture_matches_ingress_and_catalog() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../../../shared/contracts/plugins/v1/fixtures/plugin-logging.json"
        ))
        .unwrap();
        let functions = fixture["registeredFunctions"]
            .as_array()
            .unwrap()
            .iter()
            .map(|value| value.as_str().unwrap().to_owned())
            .collect();
        for (index, input) in fixture["notifications"]
            .as_array()
            .unwrap()
            .iter()
            .enumerate()
        {
            let fact = decode(fixture["plugin"].as_str().unwrap(), &functions, input).unwrap();
            assert_eq!(fact.event, fixture["events"][index]);
            let mut record = crate::diagnostics::record::StructuredLogEvent {
                ts: "2026-11-04T00:00:00.000Z".into(),
                seq: 0,
                level: crate::diagnostics::catalog::event_by_id(fact.event)
                    .unwrap()
                    .level,
                event: fact.event.into(),
                op: None,
                msg: String::new(),
                fields: fact.fields,
            };
            let channel =
                crate::diagnostics::record::prepare_catalog_event(&mut record, &Value::Null)
                    .unwrap();
            assert_eq!(channel, fixture["channel"]);
            assert_eq!(
                serde_json::to_value(record.level).unwrap(),
                fixture["levels"][index]
            );
        }
        for input in fixture["rejected"].as_array().unwrap() {
            assert!(decode(fixture["plugin"].as_str().unwrap(), &functions, input).is_none());
        }
    }

    #[test]
    fn plugin_facts_choose_catalog_severity_and_reject_private_payloads() {
        let functions = BTreeSet::from(["database.call".into()]);
        for (kind, expected, level) in [
            ("operationFinished", "plugins.operation.finished", "INFO"),
            ("operationFailed", "plugins.operation.failed", "ERROR"),
            ("degraded", "plugins.operation.fallback_selected", "WARN"),
            ("recovered", "plugins.operation.recovery_finished", "WARN"),
        ] {
            let mut input =
                json!({"kind":kind,"operation":"database.call", "operationId":"request-7"});
            if kind.starts_with("operation") {
                input["durationMs"] = json!(15);
            }
            if kind != "operationFinished" {
                input["code"] = json!("database.unavailable");
            }
            let fact = decode("io.example.database", &functions, &input).unwrap();
            assert_eq!(fact.event, expected);
            crate::diagnostics::catalog::validate_fields(fact.event, &fact.fields).unwrap();
            let metadata = crate::diagnostics::catalog::event_by_id(expected).unwrap();
            assert_eq!(serde_json::to_value(metadata.level).unwrap(), level);
            assert_eq!(fact.wire_operation.as_deref(), Some("request-7"));
            for (field, value) in [
                ("message", json!("SELECT private_source")),
                ("level", json!("INFO")),
                ("channel", json!("app")),
                ("durationMs", json!(-1)),
                ("code", json!("secret value")),
                ("operation", json!("unregistered.query")),
                ("count", json!(9_007_199_254_740_992_u64)),
            ] {
                let mut invalid = input.clone();
                invalid[field] = value;
                assert!(
                    decode("io.example.database", &functions, &invalid).is_none(),
                    "{field}"
                );
            }
        }
        // Protocol requests are accepted by their wire method without a function registration.
        for operation in [
            "lithe/build/model",
            "lithe/vcs/status",
            "lithe/keymap/import",
        ] {
            let input = json!({"kind":"operationFinished","operation":operation,"durationMs":3});
            let fact = decode("io.example.database", &BTreeSet::new(), &input).unwrap();
            assert_eq!(fact.fields["operation"], operation);
        }
        assert!(negotiated(
            &json!({"experimental":{"litheLogging":{"version":1}}})
        ));
        assert!(!negotiated(
            &json!({"experimental":{"litheLogging":{"version":2}}})
        ));
    }
}
