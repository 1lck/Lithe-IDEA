//! Canonical semantic hashes for complete Agent-owned MCP entries.

use super::model::hex;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

/// Hashes a Claude entry, including its name and every nested unknown field.
pub(crate) fn claude_source_hash(name: &str, entry: &Value) -> String {
    digest(name, canonical_json(entry))
}

/// Hashes a Codex entry without losing TOML value types or unknown fields.
pub(crate) fn codex_source_hash(name: &str, entry: &toml::Value) -> String {
    digest(name, canonical_toml(entry))
}

fn digest(name: &str, entry: Value) -> String {
    // Length-delimited JSON avoids delimiter collisions in arbitrary user data.
    let bytes = serde_json::to_vec(&json!([name, entry])).expect("canonical values serialize");
    hex(&Sha256::digest(bytes))
}

fn canonical_json(value: &Value) -> Value {
    match value {
        Value::Object(entries) => {
            let mut entries: Vec<_> = entries.iter().collect();
            entries.sort_by(|left, right| left.0.cmp(right.0));
            // An array of pairs preserves sorted order even with preserve_order.
            json!([
                "object",
                entries
                    .into_iter()
                    .map(|(key, value)| { json!([key, canonical_json(value)]) })
                    .collect::<Vec<_>>()
            ])
        }
        Value::Array(values) => json!([
            "array",
            values.iter().map(canonical_json).collect::<Vec<_>>()
        ]),
        _ => json!(["scalar", value]),
    }
}

fn canonical_toml(value: &toml::Value) -> Value {
    // Type tags distinguish datetimes from strings and integers from floats.
    match value {
        toml::Value::String(value) => json!(["string", value]),
        toml::Value::Integer(value) => json!(["integer", value]),
        toml::Value::Float(value) => json!(["float", value.to_bits()]),
        toml::Value::Boolean(value) => json!(["boolean", value]),
        toml::Value::Datetime(value) => json!(["datetime", value.to_string()]),
        toml::Value::Array(values) => json!([
            "array",
            values.iter().map(canonical_toml).collect::<Vec<_>>()
        ]),
        toml::Value::Table(entries) => {
            let mut entries: Vec<_> = entries.iter().collect();
            entries.sort_by(|left, right| left.0.cmp(right.0));
            json!([
                "table",
                entries
                    .into_iter()
                    .map(|(key, value)| { json!([key, canonical_toml(value)]) })
                    .collect::<Vec<_>>()
            ])
        }
    }
}
