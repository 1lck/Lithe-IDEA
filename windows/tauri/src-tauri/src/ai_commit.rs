// Note: .agents/notes/implemented/feature/2026-09-22-windows-ai-commit-design.md
// Native configuration, credential, cancellation and HTTP boundary. Core owns pure rules.
use lithe_core::ai::{
    self, CommitFile, CommitOptions, CommitRequestPlan, ConfigurationFile, ConfigurationFiles,
    DetectedConfiguration, Provider, PullRequestComparison, PullRequestOptions,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap};
use std::io::Read;
use std::path::Path;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;
use tauri::{AppHandle, Manager};
use tauri_plugin_http::reqwest;

const CONFIG_BYTES: u64 = 1_048_576;
const RESPONSE_BYTES: usize = 2_097_152;
type Cancellations = Mutex<HashMap<String, tokio::sync::watch::Sender<bool>>>;
static CANCELLATIONS: OnceLock<Cancellations> = OnceLock::new();

fn cancellations() -> &'static Cancellations {
    CANCELLATIONS.get_or_init(Default::default)
}
struct Operation(String);
impl Drop for Operation {
    fn drop(&mut self) {
        if let Ok(mut operations) = cancellations().lock() {
            operations.remove(&self.0);
        }
    }
}

fn validate_credential_requirement(
    provider: &Provider,
    credential: Option<&str>,
) -> Result<(), &'static str> {
    if provider.requires_api_key && credential.is_none_or(|key| key.trim().is_empty()) {
        return Err("AI_COMMIT_MISSING_KEY");
    }
    Ok(())
}

fn read_optional(path: &Path) -> Result<String, String> {
    let file = match std::fs::File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(String::new()),
        Err(_) => return Err("AI_COMMIT_CONFIG_READ_FAILED".into()),
    };
    let mut text = String::new();
    file.take(CONFIG_BYTES + 1)
        .read_to_string(&mut text)
        .map_err(|_| "AI_COMMIT_CONFIG_READ_FAILED")?;
    if text.len() as u64 > CONFIG_BYTES {
        return Err("AI_COMMIT_CONFIG_TOO_LARGE".into());
    }
    Ok(text)
}

/// Reads the files Core names for one CLI source and applies the shared rules.
/// The credential stays in this host process; callers never return it to the UI.
pub(crate) fn load_source(
    app: &AppHandle,
    source: &str,
) -> Result<Option<DetectedConfiguration>, String> {
    let home = app
        .path()
        .home_dir()
        .map_err(|_| "AI_COMMIT_CONFIG_READ_FAILED")?;
    let environment: BTreeMap<String, String> = std::env::vars().collect();
    let mut files = ConfigurationFiles::default();
    for entry in ai::configuration_sources(source, &home, &environment).map_err(str::to_owned)? {
        let text = read_optional(&entry.path)?;
        match entry.file {
            ConfigurationFile::Config => files.config = text,
            ConfigurationFile::Auth => files.auth = text,
            ConfigurationFile::Settings => files.settings = text,
            ConfigurationFile::Credentials => files.credentials = text,
            ConfigurationFile::Root => files.root = text,
        }
    }
    ai::detect(source, &files, &environment).map_err(str::to_owned)
}

fn secret_key(id: &str) -> Result<String, String> {
    if id.is_empty()
        || id.len() > 128
        || !id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
    {
        return Err("AI_COMMIT_INVALID_PROVIDER".into());
    }
    Ok(format!("lithe.ai.commit.{id}"))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GenerateArgs {
    operation_id: String,
    provider: Provider,
    options: CommitOptions,
    files: Vec<CommitFile>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PullRequestArgs {
    operation_id: String,
    provider: Provider,
    options: PullRequestOptions,
    comparison: PullRequestComparison,
}

/// Registers a cancellable request; the guard removes it when the request ends.
fn begin_operation(
    operation_id: &str,
) -> Result<(Operation, tokio::sync::watch::Receiver<bool>), String> {
    if operation_id.is_empty() || operation_id.len() > 128 {
        return Err("AI_COMMIT_INVALID_OPTIONS".into());
    }
    let (sender, receiver) = tokio::sync::watch::channel(false);
    let mut operations = cancellations()
        .lock()
        .map_err(|_| "AI_COMMIT_INTERNAL_ERROR")?;
    if operations.len() >= 4 || operations.contains_key(operation_id) {
        return Err("AI_COMMIT_BUSY".into());
    }
    operations.insert(operation_id.to_owned(), sender);
    Ok((Operation(operation_id.to_owned()), receiver))
}

pub async fn dispatch(app: AppHandle, command: &str, args: Value) -> Result<Value, String> {
    match command {
        "ai_commit_detect" => tauri::async_runtime::spawn_blocking(move || {
            let mut configurations = Vec::new();
            let mut warnings = Vec::new();
            for source in ["codex", "claude"] {
                match load_source(&app, source) {
                    Ok(Some(configuration)) => configurations.push(configuration),
                    Ok(None) => {}
                    Err(code) => warnings.push(json!({"source":source,"code":code})),
                }
            }
            Ok(json!({"configurations":configurations,"warnings":warnings}))
        })
        .await
        .map_err(|_| "AI_COMMIT_INTERNAL_ERROR")?,
        "ai_commit_key" => {
            let id = args["id"].as_str().ok_or("AI_COMMIT_INVALID_PROVIDER")?;
            let key = secret_key(id)?;
            tauri::async_runtime::spawn_blocking(move || match args["action"].as_str() {
                Some("save") => {
                    let value = args["value"]
                        .as_str()
                        .ok_or("AI_COMMIT_MISSING_KEY")?
                        .trim();
                    if value.is_empty() {
                        return Err("AI_COMMIT_MISSING_KEY".into());
                    }
                    crate::secure_storage::store_secure_secret(app, key, value.into())
                        .map_err(|_| "AI_COMMIT_KEY_FAILED")?;
                    Ok(json!(true))
                }
                Some("remove") => {
                    crate::secure_storage::remove_secure_secret(app, key)
                        .map_err(|_| "AI_COMMIT_KEY_FAILED")?;
                    Ok(json!(false))
                }
                Some("status") => Ok(json!(crate::secure_storage::get_secure_secret(app, key)
                    .map_err(|_| "AI_COMMIT_KEY_FAILED")?
                    .is_some())),
                _ => Err("AI_COMMIT_INVALID_OPTIONS".into()),
            })
            .await
            .map_err(|_| "AI_COMMIT_INTERNAL_ERROR")?
        }
        "ai_commit_cancel" => {
            if let Some(id) = args["operationId"].as_str() {
                if let Some(sender) = cancellations()
                    .lock()
                    .map_err(|_| "AI_COMMIT_INTERNAL_ERROR")?
                    .get(id)
                {
                    let _ = sender.send(true);
                }
            }
            Ok(Value::Null)
        }
        "ai_commit_generate" => {
            let args: GenerateArgs =
                serde_json::from_value(args).map_err(|_| "AI_COMMIT_INVALID_OPTIONS")?;
            let (_operation, mut receiver) = begin_operation(&args.operation_id)?;
            tokio::select! {
                _ = receiver.changed() => Err("AI_COMMIT_CANCELLED".into()),
                result = tokio::time::timeout(Duration::from_secs(45), generate(app, args)) => result.map_err(|_| "AI_COMMIT_TIMEOUT")?,
            }
        }
        "ai_commit_pull_request" => {
            let args: PullRequestArgs =
                serde_json::from_value(args).map_err(|_| "AI_COMMIT_INVALID_OPTIONS")?;
            let (_operation, mut receiver) = begin_operation(&args.operation_id)?;
            tokio::select! {
                _ = receiver.changed() => Err("AI_COMMIT_CANCELLED".into()),
                result = tokio::time::timeout(Duration::from_secs(45), generate_pull_request(app, args)) => result.map_err(|_| "AI_COMMIT_TIMEOUT")?,
            }
        }
        _ => Err("AI_COMMIT_INVALID_OPTIONS".into()),
    }
}

async fn generate(app: AppHandle, args: GenerateArgs) -> Result<Value, String> {
    let (provider, credential) = resolve_provider(app, args.provider).await?;
    let plan = ai::plan_commit(&provider, &args.options, &args.files)?;
    let response = send(&provider, credential, plan).await?;
    let message = ai::decode_message(&provider.api_protocol, &response, args.options.include_body)?;
    Ok(json!({"message":message}))
}

async fn generate_pull_request(app: AppHandle, args: PullRequestArgs) -> Result<Value, String> {
    let (provider, credential) = resolve_provider(app, args.provider).await?;
    let plan = ai::plan_pull_request(&provider, &args.options, &args.comparison)?;
    let response = send(&provider, credential, plan).await?;
    let description = ai::decode_pull_request(&provider.api_protocol, &response)?;
    serde_json::to_value(description).map_err(|_| "AI_COMMIT_INTERNAL_ERROR".into())
}

/// Refreshes imported profiles from their source and reads the credential natively.
async fn resolve_provider(
    app: AppHandle,
    provider: Provider,
) -> Result<(Provider, Option<String>), String> {
    let (provider, credential) = tauri::async_runtime::spawn_blocking(move || {
        let mut provider = provider;
        let credential = if provider.source == "local" {
            crate::secure_storage::get_secure_secret(app, secret_key(&provider.id)?)
                .map_err(|_| "AI_COMMIT_KEY_FAILED")?
        } else {
            let configuration =
                load_source(&app, &provider.source)?.ok_or("AI_COMMIT_CONFIG_MISSING")?;
            // Only the explicit HTTP consent remains app-owned for imported profiles.
            let allow_http = provider.allows_insecure_http;
            provider = configuration.provider;
            provider.allows_insecure_http = allow_http;
            configuration.credential
        };
        Ok::<_, String>((provider, credential))
    })
    .await
    .map_err(|_| "AI_COMMIT_INTERNAL_ERROR")??;
    validate_credential_requirement(&provider, credential.as_deref()).map_err(str::to_owned)?;
    Ok((provider, credential))
}

/// Sends a Core-planned request and returns the bounded JSON response.
async fn send(
    provider: &Provider,
    credential: Option<String>,
    plan: CommitRequestPlan,
) -> Result<Value, String> {
    // Never follow a redirect carrying credentials to a different server.
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(45))
        .build()
        .map_err(|_| "AI_COMMIT_NETWORK_ERROR")?;
    let mut request = client
        .post(plan.url)
        .header("Accept", "application/json")
        .json(&plan.body);
    if let Some(key) = credential.filter(|key| !key.is_empty()) {
        request = if provider.authentication == "apiKey" {
            request.header("x-api-key", key)
        } else {
            request.bearer_auth(key)
        };
    }
    if provider.api_protocol == "anthropicMessages" {
        request = request.header("anthropic-version", "2023-06-01");
    }
    let mut response = request.send().await.map_err(|error| {
        if error.is_timeout() {
            "AI_COMMIT_TIMEOUT"
        } else {
            "AI_COMMIT_NETWORK_ERROR"
        }
    })?;
    if !response.status().is_success() {
        return Err(format!("AI_COMMIT_HTTP_{}", response.status().as_u16()));
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| "AI_COMMIT_NETWORK_ERROR")?
    {
        if bytes.len() + chunk.len() > RESPONSE_BYTES {
            return Err("AI_COMMIT_RESPONSE_TOO_LARGE".into());
        }
        bytes.extend_from_slice(&chunk);
    }
    serde_json::from_slice(&bytes).map_err(|_| "AI_COMMIT_INVALID_RESPONSE".into())
}

#[cfg(test)]
mod tests {
    use super::{validate_credential_requirement, Provider};
    use lithe_core::ai::ChatTokenLimitField;

    fn provider(requires_api_key: bool) -> Provider {
        Provider {
            id: "fixture".into(),
            name: "Fixture".into(),
            endpoint: "https://example.test/v1".into(),
            model: "fixture-model".into(),
            api_protocol: "responses".into(),
            authentication: "bearer".into(),
            source: "codex".into(),
            requires_api_key,
            allows_insecure_http: false,
            chat_token_limit_field: ChatTokenLimitField::default(),
        }
    }

    #[test]
    fn keyless_provider_does_not_require_a_credential() {
        assert!(validate_credential_requirement(&provider(false), None).is_ok());
        assert!(validate_credential_requirement(&provider(false), Some(" ")).is_ok());
    }

    #[test]
    fn authenticated_provider_rejects_missing_or_blank_credentials() {
        for credential in [None, Some(""), Some(" \t ")] {
            assert_eq!(
                validate_credential_requirement(&provider(true), credential),
                Err("AI_COMMIT_MISSING_KEY")
            );
        }
        assert!(validate_credential_requirement(&provider(true), Some("fixture-key")).is_ok());
    }
}
