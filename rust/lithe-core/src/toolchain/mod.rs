//! Plugin-owned toolchain policy; hosts supply trust, filesystem and probe facts.
//!
//! No manager configuration, native scanning or process lifecycle belongs here.

pub(crate) mod definitions;
pub(crate) mod paths;
pub(crate) mod pins;
pub(crate) mod query;
mod resolution;

use crate::plugins::declarative::{PluginRejection, Validation};
use crate::protocol::CoreError;
use serde_json::{json, Value};

fn command(
    input: Value,
    operation: fn(&Value) -> Validation<Value>,
    key: &str,
) -> Result<Value, CoreError> {
    let result = if input.to_string().len() > 4 * 1024 * 1024 {
        Err(PluginRejection::new(
            "plugin.toolchain.limitExceeded",
            "Toolchain input exceeds its byte budget.",
        ))
    } else {
        operation(&input)
    };
    Ok(match result {
        Ok(value) => json!({"status":"ok",key:value}),
        Err(error) => json!({"status":"rejected","error":error}),
    })
}

/// Registers definitions using independently verified host package identities.
pub fn registry_command(input: Value) -> Result<Value, CoreError> {
    command(input, definitions::registry, "registry")
}

/// Validates one provider reply against its request and host filesystem facts.
pub fn decode_reply_command(input: Value) -> Result<Value, CoreError> {
    command(input, query::decode, "snapshot")
}

/// Reads the nearest directory pin without opening or writing native files.
pub fn resolve_pins_command(input: Value) -> Result<Value, CoreError> {
    command(input, pins::resolve, "resolution")
}

/// Resolves one tool using the same validated registry and candidate snapshot.
pub fn resolve_command(input: Value) -> Result<Value, CoreError> {
    command(input, resolution::resolve, "resolution")
}

/// Extracts and compares a version using only its enabled plugin definition.
pub fn check_version_command(input: Value) -> Result<Value, CoreError> {
    command(input, resolution::check_version, "version")
}

/// Produces bounded scan declarations, not a native scan or tool-name table.
pub fn discovery_plan_command(input: Value) -> Result<Value, CoreError> {
    command(input, resolution::discovery_plan, "plan")
}
