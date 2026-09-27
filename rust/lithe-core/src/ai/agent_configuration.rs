//! Bounded provider metadata parsing for Agent settings; hosts retain credentials and persistence.

use crate::protocol::{CoreError, ErrorCode};
use serde::Deserialize;
use serde_json::Value;
use std::collections::BTreeMap;

/// Parses pasted configuration without consulting files or the host environment.
/// Responses and failures never include authentication material or raw input.
pub fn parse_provider_configuration(payload: Value) -> Result<Value, CoreError> {
    #[derive(Deserialize)]
    struct Request {
        /// CLI configuration format, either `codex` or `claude`.
        source: String,
        /// UTF-8 TOML or JSON, limited to 64 KiB before parsing.
        configuration: String,
    }
    let invalid = || {
        CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid Agent provider configuration",
        )
    };
    let request: Request = serde_json::from_value(payload).map_err(|_| invalid())?;
    if request.configuration.len() > 64 * 1024 || request.configuration.trim().is_empty() {
        return Err(invalid());
    }
    let environment = BTreeMap::new();
    let detected = match request.source.as_str() {
        "codex" => super::parse_codex(&request.configuration, "{}", &environment),
        "claude" => super::parse_claude(&request.configuration, "", "", &environment),
        _ => return Err(invalid()),
    }
    .map_err(|_| invalid())?;
    // Serialize metadata only; even the credential-presence flag stays host-owned.
    serde_json::to_value(detected.provider).map_err(|_| invalid())
}
