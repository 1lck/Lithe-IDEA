//! Parses externally supplied Codex and Claude configuration without reading files or process environment.
//!
//! This module is the single owner of CLI configuration rules shared by commit
//! generation and Agent providers: which files belong to a source, profile and
//! provider selection, defaults, model aliases, and the precedence among
//! credential sources. Platforms read the named files natively and pass their
//! text in. Results that cross a JSON boundary never contain a secret: they
//! name where the effective credential lives through [`CredentialLocator`], and
//! only an in-process host reads [`DetectedConfiguration::credential`].

use super::{ChatTokenLimitField, Provider};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// Malformed or unusable configuration; shared with the commit error catalog.
pub(super) const INVALID_CONFIG: &str = "AI_COMMIT_INVALID_CONFIG";
/// A Codex `auth.json` that is not an object or whose API key is not a string.
pub(super) const INVALID_AUTHENTICATION: &str = "AI_CONFIGURATION_INVALID_AUTHENTICATION";
/// Codex TOML that fails to parse and contains typographic quotes, usually pasted from a document.
pub(super) const SMART_QUOTES: &str = "AI_CONFIGURATION_SMART_QUOTES";

/// One native file a configuration source may read. Serialized names are the
/// stable keys of [`ConfigurationFiles`] and of file credential locators.
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "camelCase")]
pub enum ConfigurationFile {
    /// Codex `config.toml`.
    Config,
    /// Codex `auth.json`.
    Auth,
    /// Claude `settings.json`.
    Settings,
    /// Claude `.credentials.json`.
    Credentials,
    /// Claude `~/.claude.json`.
    Root,
}

/// Text of the files of one source, as read by the platform. A missing or
/// unreadable-but-absent file is an empty string; callers report read failures
/// themselves instead of passing partial text.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ConfigurationFiles {
    /// Codex TOML configuration.
    #[serde(default)]
    pub config: String,
    /// Codex API-key authentication JSON.
    #[serde(default)]
    pub auth: String,
    /// Claude settings JSON.
    #[serde(default)]
    pub settings: String,
    /// Claude credentials JSON.
    #[serde(default)]
    pub credentials: String,
    /// Claude root configuration JSON.
    #[serde(default)]
    pub root: String,
}

/// Where the effective credential lives. Hosts resolve it natively against the
/// same file text or environment they passed in, so secrets never cross IPC.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum CredentialLocator {
    /// A process environment variable.
    Environment {
        /// Variable name, for example `OPENAI_API_KEY`.
        name: String,
    },
    /// A string value inside one of the source files.
    File {
        /// File the value lives in.
        file: ConfigurationFile,
        /// Object keys from the document root to the string value.
        path: Vec<String>,
    },
}

/// One file the platform should read for a source, in deterministic order.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ConfigurationSourceFile {
    /// Key under which the text is passed back in [`ConfigurationFiles`].
    pub file: ConfigurationFile,
    /// Absolute native path built from the platform's home directory.
    pub path: PathBuf,
}

/// Discovered profile plus an ephemeral credential that is never serialized to a UI.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DetectedConfiguration {
    /// Editable metadata is locked by the UI when source is not local.
    pub provider: Provider,
    /// Indicates whether the source contains a supported API credential.
    pub has_credential: bool,
    /// Location of the effective credential, present exactly when `has_credential` is true.
    pub credential_locator: Option<CredentialLocator>,
    /// CLI reasoning effort selection (`model_reasoning_effort`), when configured.
    pub reasoning_effort: Option<String>,
    /// The CLI authenticates through a route Lithe cannot reproduce (cloud
    /// provider or key helper), so no static credential is authoritative.
    pub unsupported_authentication: bool,
    /// Host-only credential, not persisted or returned across IPC.
    #[serde(skip)]
    pub credential: Option<String>,
}

/// Files a source reads. `CODEX_HOME` and `CLAUDE_CONFIG_DIR` replace the
/// default directories when nonblank; `~/.claude.json` always stays in home.
pub fn configuration_sources(
    source: &str,
    home: &Path,
    environment: &BTreeMap<String, String>,
) -> Result<Vec<ConfigurationSourceFile>, &'static str> {
    let directory = |variable: &str, default: &str| {
        environment
            .get(variable)
            .map(|value| value.trim())
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(default))
    };
    let file = |file, path: PathBuf| ConfigurationSourceFile { file, path };
    match source {
        "codex" => {
            let directory = directory("CODEX_HOME", ".codex");
            Ok(vec![
                file(ConfigurationFile::Config, directory.join("config.toml")),
                file(ConfigurationFile::Auth, directory.join("auth.json")),
            ])
        }
        "claude" => {
            let directory = directory("CLAUDE_CONFIG_DIR", ".claude");
            Ok(vec![
                file(ConfigurationFile::Settings, directory.join("settings.json")),
                file(
                    ConfigurationFile::Credentials,
                    directory.join(".credentials.json"),
                ),
                file(ConfigurationFile::Root, home.join(".claude.json")),
            ])
        }
        _ => Err(INVALID_CONFIG),
    }
}

/// Whether the files and environment describe a configuration at all. Codex
/// needs its TOML; Claude also counts any `ANTHROPIC_*` environment override.
pub fn is_configured(
    source: &str,
    files: &ConfigurationFiles,
    environment: &BTreeMap<String, String>,
) -> bool {
    match source {
        "codex" => !files.config.trim().is_empty(),
        "claude" => {
            [&files.settings, &files.credentials, &files.root]
                .iter()
                .any(|text| !text.trim().is_empty())
                || environment.keys().any(|key| key.starts_with("ANTHROPIC_"))
        }
        _ => false,
    }
}

/// Detects one installed CLI source. `Ok(None)` means nothing is configured.
pub fn detect(
    source: &str,
    files: &ConfigurationFiles,
    environment: &BTreeMap<String, String>,
) -> Result<Option<DetectedConfiguration>, &'static str> {
    if !matches!(source, "codex" | "claude") {
        return Err(INVALID_CONFIG);
    }
    if !is_configured(source, files, environment) {
        return Ok(None);
    }
    match source {
        "codex" => parse_codex(&files.config, &files.auth, environment),
        _ => parse_claude(
            &files.settings,
            &files.credentials,
            &files.root,
            environment,
        ),
    }
    .map(Some)
}

/// Parses Codex TOML plus API-key auth. OAuth credentials are not interpreted as API keys.
pub fn parse_codex(
    config: &str,
    auth: &str,
    environment: &BTreeMap<String, String>,
) -> Result<DetectedConfiguration, &'static str> {
    parse_codex_configuration(config, auth, environment, false)
}

/// Reads editable fields without requiring a complete provider or adding CLI defaults.
pub(super) fn parse_codex_draft(
    config: &str,
    auth: &str,
) -> Result<DetectedConfiguration, &'static str> {
    parse_codex_configuration(config, auth, &BTreeMap::new(), true)
}

/// Parsed Codex TOML with the active profile applied to top-level selections.
struct CodexDocument {
    value: toml::Value,
    profile: Option<String>,
}

impl CodexDocument {
    fn parse(config: &str) -> Result<Self, &'static str> {
        let value: toml::Value = toml::from_str(config).map_err(|_| {
            // Typographic quotes are the common cause when TOML is pasted from a
            // document; a dedicated code lets the UI say so without quoting input.
            if config.contains('\u{201C}') || config.contains('\u{201D}') {
                SMART_QUOTES
            } else {
                INVALID_CONFIG
            }
        })?;
        let profile = value
            .get("profile")
            .and_then(toml::Value::as_str)
            .filter(|name| value.get("profiles").and_then(|p| p.get(*name)).is_some())
            .map(str::to_owned);
        Ok(Self { value, profile })
    }

    /// A profile value wins over the top-level value of the same key.
    fn setting(&self, key: &str) -> Option<&str> {
        self.profile
            .as_deref()
            .and_then(|name| self.value.get("profiles")?.get(name)?.get(key))
            .or_else(|| self.value.get(key))
            .and_then(toml::Value::as_str)
    }
}

/// The CLI's model selection even when no usable provider is configured.
pub(super) fn codex_model(config: &str) -> Result<String, &'static str> {
    Ok(CodexDocument::parse(config)?
        .setting("model")
        .map(str::trim)
        .unwrap_or_default()
        .to_owned())
}

/// Parses an `auth.json` document; blank text is an empty object.
fn codex_auth(auth: &str) -> Result<Value, &'static str> {
    if auth.trim().is_empty() {
        return Ok(Value::Object(Default::default()));
    }
    let value: Value = serde_json::from_str(auth).map_err(|_| INVALID_AUTHENTICATION)?;
    if !value.is_object() {
        return Err(INVALID_AUTHENTICATION);
    }
    // ChatGPT login stores `null`; any other non-string key is malformed.
    for key in ["OPENAI_API_KEY", "api_key"] {
        if !matches!(value.get(key), None | Some(Value::Null | Value::String(_))) {
            return Err(INVALID_AUTHENTICATION);
        }
    }
    Ok(value)
}

fn parse_codex_configuration(
    config: &str,
    auth: &str,
    environment: &BTreeMap<String, String>,
    allow_incomplete: bool,
) -> Result<DetectedConfiguration, &'static str> {
    let document = CodexDocument::parse(config)?;
    let auth = codex_auth(auth)?;
    let provider_name = document.setting("model_provider").unwrap_or("openai");
    let provider = document
        .value
        .get("model_providers")
        .and_then(|v| v.get(provider_name));
    let option = |key: &str| {
        provider
            .and_then(|v| v.get(key))
            .and_then(toml::Value::as_str)
    };
    let endpoint = option("base_url")
        .or_else(|| {
            (!allow_incomplete && provider_name == "openai").then_some("https://api.openai.com/v1")
        })
        .or_else(|| allow_incomplete.then_some(""))
        .ok_or(INVALID_CONFIG)?;
    let model = document
        .setting("model")
        .filter(|s| !s.is_empty())
        .or_else(|| allow_incomplete.then_some(""))
        .ok_or(INVALID_CONFIG)?;
    let uses_openai_auth = provider
        .and_then(|v| v.get("requires_openai_auth"))
        .and_then(toml::Value::as_bool)
        .unwrap_or(provider_name == "openai");
    let env_key = option("env_key").map(str::trim);
    if env_key.is_some_and(str::is_empty) {
        return Err(INVALID_CONFIG);
    }
    let bearer_token = option("experimental_bearer_token");
    let auth_field = |key: &str| {
        candidate(
            auth.get(key).and_then(Value::as_str),
            CredentialLocator::File {
                file: ConfigurationFile::Auth,
                path: vec![key.into()],
            },
        )
    };
    // An explicit provider credential source must never fall back to another account.
    let credential = if let Some(key) = env_key {
        first_candidate([environment_candidate(environment, key)])
    } else if bearer_token.is_some() {
        first_candidate([candidate(
            bearer_token,
            CredentialLocator::File {
                file: ConfigurationFile::Config,
                path: vec![
                    "model_providers".into(),
                    provider_name.into(),
                    "experimental_bearer_token".into(),
                ],
            },
        )])
    } else if uses_openai_auth || allow_incomplete {
        // An editor draft supplies its key through the pasted `auth.json` text.
        first_candidate([
            auth_field("OPENAI_API_KEY"),
            auth_field("api_key"),
            environment_candidate(environment, "OPENAI_API_KEY"),
        ])
    } else {
        None
    };
    let protocol = match option("wire_api").unwrap_or("responses") {
        "responses" => "responses",
        "chat" | "chat_completions" => "chatCompletions",
        _ => return Err(INVALID_CONFIG),
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
    configuration.reasoning_effort = document
        .setting("model_reasoning_effort")
        .map(str::trim)
        .filter(|effort| !effort.is_empty())
        .map(str::to_owned);
    Ok(configuration)
}

/// Parses Claude JSON sources and supported environment overrides, including model aliases.
pub fn parse_claude(
    settings: &str,
    credentials: &str,
    root: &str,
    environment: &BTreeMap<String, String>,
) -> Result<DetectedConfiguration, &'static str> {
    parse_claude_configuration(settings, credentials, root, environment, false)
}

/// Reads editable fields with aliases intact, leaving missing endpoint/model/key fields empty.
pub(super) fn parse_claude_draft(settings: &str) -> Result<DetectedConfiguration, &'static str> {
    parse_claude_configuration(settings.trim(), "", "", &BTreeMap::new(), true)
}

fn parse_claude_configuration(
    settings: &str,
    credentials: &str,
    root: &str,
    environment: &BTreeMap<String, String>,
    allow_incomplete: bool,
) -> Result<DetectedConfiguration, &'static str> {
    fn object(text: &str) -> Result<Value, &'static str> {
        if text.trim().is_empty() {
            return Ok(Value::Null);
        }
        let value: Value = serde_json::from_str(text).map_err(|_| INVALID_CONFIG)?;
        if !value.is_object() {
            return Err(INVALID_CONFIG);
        }
        Ok(value)
    }
    let settings = object(settings)?;
    let credentials = object(credentials)?;
    let root = object(root)?;
    fn in_file<'a>(file: ConfigurationFile, document: &'a Value, path: &[&str]) -> Candidate<'a> {
        let value = path
            .iter()
            .try_fold(document, |value, key| value.get(*key))
            .and_then(Value::as_str);
        candidate(
            value,
            CredentialLocator::File {
                file,
                path: path.iter().map(|key| (*key).to_owned()).collect(),
            },
        )
    }
    // `settings.env` overrides the process environment, as in Claude Code.
    let env_candidates = |key: &str| {
        [
            in_file(ConfigurationFile::Settings, &settings, &["env", key]),
            environment_candidate(environment, key),
        ]
    };
    let env = |key: &str| first_candidate(env_candidates(key)).map(|(value, _)| value);
    // File keys sit between `settings.env` and the inherited process environment.
    let key = first_candidate([
        in_file(
            ConfigurationFile::Settings,
            &settings,
            &["env", "ANTHROPIC_API_KEY"],
        ),
        in_file(ConfigurationFile::Settings, &settings, &["apiKey"]),
        in_file(ConfigurationFile::Root, &root, &["apiKey"]),
        in_file(ConfigurationFile::Credentials, &credentials, &["apiKey"]),
        environment_candidate(environment, "ANTHROPIC_API_KEY"),
    ]);
    let token = first_candidate(env_candidates("ANTHROPIC_AUTH_TOKEN").into_iter().chain([
        in_file(ConfigurationFile::Settings, &settings, &["authToken"]),
        in_file(ConfigurationFile::Root, &root, &["authToken"]),
    ]));
    // Claude Code prefers cloud-provider routes, then an auth token, then an API
    // key, and consults `apiKeyHelper` only without either. Lithe cannot run
    // cloud or helper routes, so those make no static credential authoritative.
    let enabled = |key: &str| env(key).is_some_and(|value| !matches!(value, "0" | "false"));
    let cloud_route = [
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX",
        "CLAUDE_CODE_USE_FOUNDRY",
    ]
    .iter()
    .any(|key| enabled(key));
    let helper = settings["apiKeyHelper"]
        .as_str()
        .is_some_and(|value| !value.trim().is_empty());
    let unsupported_authentication = cloud_route || (token.is_none() && key.is_none() && helper);
    let authentication = if token.is_some() {
        "bearer"
    } else if key.is_some() || allow_incomplete {
        "apiKey"
    } else {
        "bearer"
    };
    let credential = if cloud_route { None } else { token.or(key) };
    let endpoint = first_nonempty([
        env("ANTHROPIC_BASE_URL"),
        env("ANTHROPIC_API_URL"),
        settings["apiBaseUrl"].as_str(),
        root["apiBaseUrl"].as_str(),
    ])
    .unwrap_or(if allow_incomplete {
        ""
    } else {
        "https://api.anthropic.com/v1"
    });
    let model = first_nonempty([
        env("ANTHROPIC_MODEL"),
        settings["model"].as_str(),
        root["model"].as_str(),
    ])
    .unwrap_or(if allow_incomplete {
        ""
    } else {
        "claude-sonnet-4-5"
    });
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
    let mut configuration = detected(
        "claude",
        "Claude",
        endpoint,
        model,
        "anthropicMessages",
        authentication,
        credential,
    );
    configuration.unsupported_authentication = unsupported_authentication;
    Ok(configuration)
}

/// A credential value with its location; blank values are never candidates.
type Candidate<'a> = Option<(&'a str, CredentialLocator)>;

fn candidate(value: Option<&str>, locator: CredentialLocator) -> Candidate<'_> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| (value, locator))
}

fn environment_candidate<'a>(
    environment: &'a BTreeMap<String, String>,
    name: &str,
) -> Candidate<'a> {
    candidate(
        environment.get(name).map(String::as_str),
        CredentialLocator::Environment { name: name.into() },
    )
}

fn first_candidate<'a>(values: impl IntoIterator<Item = Candidate<'a>>) -> Candidate<'a> {
    values.into_iter().flatten().next()
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
    credential: Candidate<'_>,
) -> DetectedConfiguration {
    let (credential, credential_locator) = match credential {
        Some((value, locator)) => (Some(value.to_owned()), Some(locator)),
        None => (None, None),
    };
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
        credential_locator,
        reasoning_effort: None,
        unsupported_authentication: false,
        credential,
    }
}
