//! Credential-free JSON entry points for CLI configuration discovery and parsing.
//!
//! `ai.configuration.sources` names the files a platform reads for a source, and
//! `ai.configuration.parse` applies the shared rules to their text. Responses
//! carry metadata and a credential locator only; hosts resolve the locator
//! natively, so secrets never appear in a response, error, or diagnostic.

use super::configuration::{
    self, codex_model, configuration_sources, ConfigurationFiles, DetectedConfiguration,
    INVALID_AUTHENTICATION, INVALID_CONFIG,
};
use crate::protocol::{CoreError, ErrorCode};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::PathBuf;

/// Largest accepted file text; matches the Windows host's native read bound.
const MAXIMUM_FILE_BYTES: usize = 1024 * 1024;
/// Bounds the environment snapshot a platform may pass.
const MAXIMUM_ENVIRONMENT_ENTRIES: usize = 4096;
const MAXIMUM_ENVIRONMENT_VALUE_BYTES: usize = 32 * 1024;
/// Oversized input; stable so platforms can explain the limit.
const TOO_LARGE: &str = "AI_CONFIGURATION_TOO_LARGE";

/// Fixed messages only: parser diagnostics may quote a pasted credential.
fn invalid(code: &'static str) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, code)
}

fn bounded_environment(environment: &BTreeMap<String, String>) -> Result<(), CoreError> {
    if environment.len() > MAXIMUM_ENVIRONMENT_ENTRIES
        || environment
            .iter()
            .any(|(name, value)| name.len() + value.len() > MAXIMUM_ENVIRONMENT_VALUE_BYTES)
    {
        return Err(invalid(TOO_LARGE));
    }
    Ok(())
}

/// Implements `ai.configuration.sources`: the native files of one source.
pub fn configuration_sources_command(payload: Value) -> Result<Value, CoreError> {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase", deny_unknown_fields)]
    struct Request {
        /// `codex` or `claude`.
        source: String,
        /// Absolute home directory of the current user.
        home: PathBuf,
        /// Directory overrides such as `CODEX_HOME`; other variables are ignored.
        #[serde(default)]
        environment: BTreeMap<String, String>,
    }
    let request: Request = serde_json::from_value(payload).map_err(|_| invalid(INVALID_CONFIG))?;
    bounded_environment(&request.environment)?;
    if !request.home.is_absolute() {
        return Err(invalid(INVALID_CONFIG));
    }
    let files = configuration_sources(&request.source, &request.home, &request.environment)
        .map_err(invalid)?;
    Ok(json!({ "files": files }))
}

/// Implements `ai.configuration.parse` without consulting files or the host environment.
///
/// Strict mode returns `null` when nothing is configured, and `provider: null`
/// with `issue` when the configuration parses but is not a usable provider.
/// Draft mode (`allowIncomplete`) parses editor text only: it ignores the
/// environment and keeps missing endpoint and model fields empty.
pub fn parse_configuration_command(payload: Value) -> Result<Value, CoreError> {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase", deny_unknown_fields)]
    struct Request {
        /// `codex` (TOML plus `auth.json`) or `claude` (JSON files).
        source: String,
        /// File text keyed like the `ai.configuration.sources` result.
        #[serde(default)]
        files: ConfigurationFiles,
        /// Process environment snapshot for strict parsing.
        #[serde(default)]
        environment: BTreeMap<String, String>,
        /// Editor-only parsing preserves empty fields instead of applying CLI defaults.
        #[serde(default)]
        allow_incomplete: bool,
    }
    let request: Request = serde_json::from_value(payload).map_err(|_| invalid(INVALID_CONFIG))?;
    let files = &request.files;
    if [
        &files.config,
        &files.auth,
        &files.settings,
        &files.credentials,
        &files.root,
    ]
    .iter()
    .any(|text| text.len() > MAXIMUM_FILE_BYTES)
    {
        return Err(invalid(TOO_LARGE));
    }
    bounded_environment(&request.environment)?;
    let source = request.source.as_str();
    if request.allow_incomplete {
        let detected = match source {
            "codex" => configuration::parse_codex_draft(&files.config, &files.auth),
            "claude" => configuration::parse_claude_draft(&files.settings),
            _ => Err(INVALID_CONFIG),
        }
        .map_err(invalid)?;
        let model = detected.provider.model.clone();
        return Ok(response(model, Ok(detected)));
    }
    if !matches!(source, "codex" | "claude") {
        return Err(invalid(INVALID_CONFIG));
    }
    if !configuration::is_configured(source, files, &request.environment) {
        return Ok(Value::Null);
    }
    let environment = &request.environment;
    if source == "claude" {
        // Claude has no incomplete state: every parse failure is malformed input.
        let detected = configuration::parse_claude(
            &files.settings,
            &files.credentials,
            &files.root,
            environment,
        )
        .map_err(invalid)?;
        return Ok(response(detected.provider.model.clone(), Ok(detected)));
    }
    // Malformed TOML or auth JSON is an error; an incomplete provider still reports the model.
    let model = codex_model(&files.config).map_err(invalid)?;
    match configuration::parse_codex(&files.config, &files.auth, environment) {
        Ok(detected) => Ok(response(model, Ok(detected))),
        Err(INVALID_AUTHENTICATION) => Err(invalid(INVALID_AUTHENTICATION)),
        Err(code) => Ok(response(model, Err(code))),
    }
}

/// Serializes metadata only; the credential value is `#[serde(skip)]`.
fn response(model: String, detected: Result<DetectedConfiguration, &'static str>) -> Value {
    match detected {
        Ok(detected) => json!({
            "model": model,
            "provider": detected.provider,
            "issue": null,
            "reasoningEffort": detected.reasoning_effort,
            "hasCredential": detected.has_credential,
            "credential": detected.credential_locator,
            "unsupportedAuthentication": detected.unsupported_authentication,
        }),
        Err(code) => json!({
            "model": model,
            "provider": null,
            "issue": code,
            "reasoningEffort": null,
            "hasCredential": false,
            "credential": null,
            "unsupportedAuthentication": false,
        }),
    }
}
