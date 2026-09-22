//! Parses externally supplied configuration text without reading files or process environment.

use super::{ChatTokenLimitField, Provider};
use serde::Serialize;
use serde_json::Value;
use std::collections::BTreeMap;

/// Discovered profile plus an ephemeral credential that is never serialized to a UI.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DetectedConfiguration {
    /// Editable metadata is locked by the UI when source is not local.
    pub provider: Provider,
    /// Indicates whether the source contains a supported API credential.
    pub has_credential: bool,
    /// Host-only credential, not persisted or returned across IPC.
    #[serde(skip)]
    pub credential: Option<String>,
}

/// Parses Codex TOML plus API-key auth. OAuth credentials are not interpreted as API keys.
pub fn parse_codex(
    config: &str,
    auth: &str,
    environment: &BTreeMap<String, String>,
) -> Result<DetectedConfiguration, &'static str> {
    let value: toml::Value = toml::from_str(config).map_err(|_| "AI_COMMIT_INVALID_CONFIG")?;
    let profile = value
        .get("profile")
        .and_then(toml::Value::as_str)
        .and_then(|name| value.get("profiles")?.get(name));
    let setting = |key: &str| {
        profile
            .and_then(|v| v.get(key))
            .or_else(|| value.get(key))
            .and_then(toml::Value::as_str)
    };
    let provider_name = setting("model_provider").unwrap_or("openai");
    let provider = value
        .get("model_providers")
        .and_then(|v| v.get(provider_name));
    let option = |key: &str| {
        provider
            .and_then(|v| v.get(key))
            .and_then(toml::Value::as_str)
    };
    let endpoint = option("base_url")
        .or_else(|| (provider_name == "openai").then_some("https://api.openai.com/v1"))
        .ok_or("AI_COMMIT_INVALID_CONFIG")?;
    let model = setting("model")
        .filter(|s| !s.is_empty())
        .ok_or("AI_COMMIT_INVALID_CONFIG")?;
    let auth: Value = serde_json::from_str(auth).unwrap_or(Value::Null);
    let uses_openai_auth = provider
        .and_then(|v| v.get("requires_openai_auth"))
        .and_then(toml::Value::as_bool)
        .unwrap_or(provider_name == "openai");
    let env_key = option("env_key").map(str::trim);
    if env_key.is_some_and(str::is_empty) {
        return Err("AI_COMMIT_INVALID_CONFIG");
    }
    let bearer_token = option("experimental_bearer_token");
    // An explicit provider credential source must never fall back to another account.
    let credential = if let Some(key) = env_key {
        first_nonempty([environment.get(key).map(String::as_str)])
    } else if bearer_token.is_some() {
        first_nonempty([bearer_token])
    } else if uses_openai_auth {
        first_nonempty([
            auth["OPENAI_API_KEY"].as_str(),
            auth["api_key"].as_str(),
            environment.get("OPENAI_API_KEY").map(String::as_str),
        ])
    } else {
        None
    }
    .map(str::to_owned);
    let protocol = match option("wire_api").unwrap_or("responses") {
        "responses" => "responses",
        "chat" | "chat_completions" => "chatCompletions",
        _ => return Err("AI_COMMIT_INVALID_CONFIG"),
    };
    let mut configuration = detected(
        "codex",
        &format!("Codex · {provider_name}"),
        endpoint,
        model,
        protocol,
        "bearer",
        credential,
    );
    configuration.provider.requires_api_key =
        uses_openai_auth || env_key.is_some() || bearer_token.is_some();
    Ok(configuration)
}

/// Parses Claude JSON sources and supported environment overrides, including model aliases.
pub fn parse_claude(
    settings: &str,
    credentials: &str,
    root: &str,
    environment: &BTreeMap<String, String>,
) -> Result<DetectedConfiguration, &'static str> {
    fn object(text: &str) -> Result<Value, &'static str> {
        if text.is_empty() {
            return Ok(Value::Null);
        }
        let value: Value = serde_json::from_str(text).map_err(|_| "AI_COMMIT_INVALID_CONFIG")?;
        if !value.is_object() {
            return Err("AI_COMMIT_INVALID_CONFIG");
        }
        Ok(value)
    }
    let settings = object(settings)?;
    let credentials = object(credentials)?;
    let root = object(root)?;
    let env = |key: &str| {
        first_nonempty([
            settings["env"][key].as_str(),
            environment.get(key).map(String::as_str),
        ])
    };
    let key = first_nonempty([
        settings["env"]["ANTHROPIC_API_KEY"].as_str(),
        settings["apiKey"].as_str(),
        root["apiKey"].as_str(),
        credentials["apiKey"].as_str(),
        env("ANTHROPIC_API_KEY"),
    ]);
    let token = first_nonempty([
        env("ANTHROPIC_AUTH_TOKEN"),
        settings["authToken"].as_str(),
        root["authToken"].as_str(),
    ]);
    let credential = key.or(token).map(str::to_owned);
    let endpoint = first_nonempty([
        env("ANTHROPIC_BASE_URL"),
        env("ANTHROPIC_API_URL"),
        settings["apiBaseUrl"].as_str(),
        root["apiBaseUrl"].as_str(),
    ])
    .unwrap_or("https://api.anthropic.com/v1");
    let model = first_nonempty([
        env("ANTHROPIC_MODEL"),
        settings["model"].as_str(),
        root["model"].as_str(),
    ])
    .unwrap_or("claude-sonnet-4-5");
    let alias_key = format!("ANTHROPIC_DEFAULT_{}_MODEL", model.to_uppercase());
    let alias_name_key = format!("{alias_key}_NAME");
    let model = if matches!(
        model.to_lowercase().as_str(),
        "sonnet" | "opus" | "haiku" | "fable"
    ) {
        env(&alias_key)
            .or_else(|| env(&alias_name_key))
            .unwrap_or(model)
    } else {
        model
    };
    Ok(detected(
        "claude",
        "Claude",
        endpoint,
        model,
        "anthropicMessages",
        if key.is_some() { "apiKey" } else { "bearer" },
        credential,
    ))
}

fn first_nonempty<'a>(values: impl IntoIterator<Item = Option<&'a str>>) -> Option<&'a str> {
    values
        .into_iter()
        .flatten()
        .map(str::trim)
        .find(|s| !s.is_empty())
}

fn detected(
    source: &str,
    name: &str,
    endpoint: &str,
    model: &str,
    protocol: &str,
    authentication: &str,
    credential: Option<String>,
) -> DetectedConfiguration {
    DetectedConfiguration {
        provider: Provider {
            id: format!("imported-{source}"),
            name: name.into(),
            endpoint: endpoint.into(),
            model: model.into(),
            api_protocol: protocol.into(),
            authentication: authentication.into(),
            source: source.into(),
            requires_api_key: true,
            allows_insecure_http: false,
            chat_token_limit_field: ChatTokenLimitField::default(),
        },
        has_credential: credential.is_some(),
        credential,
    }
}
