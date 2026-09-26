//! Read-only subscription quota probe for the AI coding CLIs on this machine.
//!
//! Note: .agents/notes/implemented/feature/2026-09-24-windows-local-ai-usage-and-quota.md
//!
//! The official usage endpoints only accept a subscription token, and that token
//! is the user's own CLI login. It never crosses the IPC boundary: the credential
//! read, the HTTP request and the response parsing all happen here, and the
//! frontend receives either quota windows or one stable failure category.

use chrono::{DateTime, SecondsFormat};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::io::Read as _;
use std::path::{Path, PathBuf};
use std::time::Duration;
use tauri::Manager;
use tauri_plugin_http::reqwest;

/// Official endpoints, pinned to the official hosts. Redirects stay disabled so
/// the credential can never be handed to a redirect target.
const CLAUDE_USAGE_URL: &str = "https://api.anthropic.com/api/oauth/usage";
/// The endpoint rejects requests without this opt-in header.
const CLAUDE_OAUTH_BETA: &str = "oauth-2025-04-20";
const CODEX_USAGE_URL: &str = "https://chatgpt.com/backend-api/wham/usage";
const OFFICIAL_ANTHROPIC_HOST: &str = "api.anthropic.com";

const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);
/// A quota payload is a few kilobytes; anything larger is not a quota payload.
const MAX_RESPONSE_BYTES: usize = 512 * 1024;
/// Configuration files are small; the cap only stops a pathological read.
const MAX_CONFIG_BYTES: u64 = 1024 * 1024;

const SECONDS_PER_FIVE_HOURS: u64 = 18_000;
const SECONDS_PER_WEEK: u64 = 604_800;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum QuotaPlatform {
    Claude,
    Codex,
}

/// How this machine reaches the platform.
///
/// Only `auth` - an official subscription login - has a queryable usage
/// endpoint. An API key is answered with 401 by that endpoint, and a custom
/// relay owns its own quota, so both are reported as `unsupported` rather than
/// as an expired credential.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum QuotaConnection {
    Auth,
    Api,
    Relay,
    None,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum QuotaFailure {
    Unsupported,
    Unavailable,
    Unauthorized,
    Forbidden,
    RateLimited,
    Timeout,
    Network,
    Unparsable,
}

/// One quota window.
///
/// `used_percent` stays absent when the source did not report it: writing 0
/// would read as "this window is unused".
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaWindow {
    /// Window id, also the badge text, for example `5h`, `7d` or `45m`.
    pub key: String,
    pub used_percent: Option<f64>,
    /// RFC 3339 timestamp, absent when the source did not report one.
    pub resets_at: Option<String>,
    pub limit_seconds: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlatformQuota {
    pub platform: QuotaPlatform,
    pub connection: QuotaConnection,
    pub windows: Vec<QuotaWindow>,
    /// Absent means the query succeeded.
    pub failure: Option<QuotaFailure>,
    /// Technical detail such as the HTTP status. Never carries a credential.
    pub detail: Option<String>,
    /// Local locations probed this time; the panel lists them instead of
    /// reading the machine silently.
    pub scanned_paths: Vec<String>,
    pub plan: Option<String>,
    pub fetched_at: Option<i64>,
}

/// The local configuration that decides whether a quota query is possible.
struct LocalCredential {
    connection: QuotaConnection,
    access_token: Option<String>,
    account_id: Option<String>,
    scanned_paths: Vec<String>,
}

impl LocalCredential {
    fn new(connection: QuotaConnection, scanned_paths: Vec<String>) -> Self {
        Self {
            connection,
            access_token: None,
            account_id: None,
            scanned_paths,
        }
    }
}
fn read_optional(path: &Path) -> Option<String> {
    let file = std::fs::File::open(path).ok()?;
    let mut text = String::new();
    file.take(MAX_CONFIG_BYTES).read_to_string(&mut text).ok()?;
    Some(text)
}

fn json_file(path: &Path) -> Option<Value> {
    serde_json::from_str(&read_optional(path)?).ok()
}

fn object_at<'a>(value: &'a Value, key: &str) -> Option<&'a Value> {
    value.get(key).filter(|entry| entry.is_object())
}

fn text_at(value: &Value, path: &[&str]) -> Option<String> {
    let mut cursor = value;
    for key in path {
        cursor = cursor.get(*key)?;
    }
    let text = cursor.as_str()?.trim();
    if text.is_empty() {
        None
    } else {
        Some(text.to_string())
    }
}

fn config_directory(
    environment: &BTreeMap<String, String>,
    variable: &str,
    fallback: PathBuf,
) -> PathBuf {
    environment
        .get(variable)
        .map(|value| value.trim())
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or(fallback)
}

/// Claude Code connection detection, in the CLI's own priority order: a custom
/// base address wins over an API key, which wins over the official subscription.
fn claude_credential(home: &Path, environment: &BTreeMap<String, String>) -> LocalCredential {
    let directory = config_directory(environment, "CLAUDE_CONFIG_DIR", home.join(".claude"));
    let settings_path = directory.join("settings.json");
    let credentials_path = directory.join(".credentials.json");
    let scanned_paths = vec![
        settings_path.to_string_lossy().into_owned(),
        credentials_path.to_string_lossy().into_owned(),
    ];

    let settings = json_file(&settings_path).unwrap_or(Value::Null);
    let environment_block = object_at(&settings, "env").cloned().unwrap_or(Value::Null);
    let base_url = text_at(&environment_block, &["ANTHROPIC_BASE_URL"]);
    let has_api_credential = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"]
        .iter()
        .any(|key| text_at(&environment_block, &[key]).is_some())
        || text_at(&settings, &["apiKeyHelper"]).is_some();

    if base_url
        .as_deref()
        .is_some_and(|url| !url.contains(OFFICIAL_ANTHROPIC_HOST))
    {
        return LocalCredential::new(QuotaConnection::Relay, scanned_paths);
    }
    if has_api_credential {
        return LocalCredential::new(QuotaConnection::Api, scanned_paths);
    }

    let credentials = json_file(&credentials_path).unwrap_or(Value::Null);
    match text_at(&credentials, &["claudeAiOauth", "accessToken"]) {
        Some(access_token) => LocalCredential {
            connection: QuotaConnection::Auth,
            access_token: Some(access_token),
            account_id: None,
            scanned_paths,
        },
        None => LocalCredential::new(QuotaConnection::None, scanned_paths),
    }
}

/// Codex connection detection. `auth.json` can hold both an API key and a
/// subscription token, and the API key wins.
fn codex_credential(home: &Path, environment: &BTreeMap<String, String>) -> LocalCredential {
    let directory = config_directory(environment, "CODEX_HOME", home.join(".codex"));
    let auth_path = directory.join("auth.json");
    let scanned_paths = vec![auth_path.to_string_lossy().into_owned()];

    let auth = json_file(&auth_path).unwrap_or(Value::Null);
    if text_at(&auth, &["OPENAI_API_KEY"]).is_some() {
        return LocalCredential::new(QuotaConnection::Api, scanned_paths);
    }

    match text_at(&auth, &["tokens", "access_token"]) {
        Some(access_token) => LocalCredential {
            connection: QuotaConnection::Auth,
            access_token: Some(access_token),
            account_id: text_at(&auth, &["tokens", "account_id"]),
            scanned_paths,
        },
        None => LocalCredential::new(QuotaConnection::None, scanned_paths),
    }
}

fn resolve_credential(
    platform: QuotaPlatform,
    home: Option<&Path>,
    environment: &BTreeMap<String, String>,
) -> LocalCredential {
    match home {
        Some(home) => match platform {
            QuotaPlatform::Claude => claude_credential(home, environment),
            QuotaPlatform::Codex => codex_credential(home, environment),
        },
        None => LocalCredential::new(QuotaConnection::None, Vec::new()),
    }
}

/// Whether a connection can query an usage endpoint at all, and what to report
/// when it cannot.
fn gated_failure(connection: QuotaConnection) -> Option<QuotaFailure> {
    match connection {
        QuotaConnection::Auth => None,
        QuotaConnection::Api | QuotaConnection::Relay => Some(QuotaFailure::Unsupported),
        QuotaConnection::None => Some(QuotaFailure::Unavailable),
    }
}

fn failure_for_status(status: u16) -> Option<QuotaFailure> {
    match status {
        401 => Some(QuotaFailure::Unauthorized),
        403 => Some(QuotaFailure::Forbidden),
        429 => Some(QuotaFailure::RateLimited),
        status if !(200..300).contains(&status) => Some(QuotaFailure::Network),
        _ => None,
    }
}

/// The endpoint reports 0-100 per cent. Out of range and missing both mean "not
/// reported".
fn used_percent(value: Option<&Value>) -> Option<f64> {
    value?
        .as_f64()
        .filter(|percent| (0.0..=100.0).contains(percent))
}

fn rfc3339_or_none(value: Option<&Value>) -> Option<String> {
    let text = value?.as_str()?.trim();
    DateTime::parse_from_rfc3339(text).ok()?;
    Some(text.to_string())
}

fn reset_from_unix_seconds(value: Option<&Value>) -> Option<String> {
    let seconds = value?.as_i64().filter(|seconds| *seconds > 0)?;
    Some(DateTime::from_timestamp(seconds, 0)?.to_rfc3339_opts(SecondsFormat::Millis, true))
}

/// Keys a window by its length, never by `primary`/`secondary` position: on Pro
/// accounts the primary window is currently the seven day one.
fn window_key_for_seconds(seconds: u64) -> String {
    match seconds {
        SECONDS_PER_FIVE_HOURS => "5h".to_string(),
        SECONDS_PER_WEEK => "7d".to_string(),
        seconds => format!("{}m", (seconds as f64 / 60.0).round() as u64),
    }
}
fn claude_windows(root: &Value) -> Vec<QuotaWindow> {
    const FIELDS: [(&str, &str, u64); 4] = [
        ("five_hour", "5h", SECONDS_PER_FIVE_HOURS),
        ("seven_day", "7d", SECONDS_PER_WEEK),
        ("seven_day_opus", "7dOpus", SECONDS_PER_WEEK),
        ("seven_day_sonnet", "7dSonnet", SECONDS_PER_WEEK),
    ];

    let mut windows = Vec::new();
    for (field, key, limit_seconds) in FIELDS {
        let Some(window) = object_at(root, field) else {
            continue;
        };
        windows.push(QuotaWindow {
            key: key.to_string(),
            used_percent: used_percent(window.get("utilization")),
            resets_at: rfc3339_or_none(window.get("resets_at")),
            limit_seconds: Some(limit_seconds),
        });
    }
    windows
}

fn codex_windows(root: &Value) -> Vec<QuotaWindow> {
    let rate_limit = object_at(root, "rate_limit");
    let mut windows = Vec::new();
    for field in ["primary_window", "secondary_window"] {
        let Some(window) = rate_limit.and_then(|value| object_at(value, field)) else {
            continue;
        };
        // Without a length there is no way to tell five hours from seven days,
        // so the window is dropped instead of guessed.
        let Some(limit_seconds) = window
            .get("limit_window_seconds")
            .and_then(Value::as_u64)
            .filter(|seconds| *seconds > 0)
        else {
            continue;
        };
        windows.push(QuotaWindow {
            key: window_key_for_seconds(limit_seconds),
            used_percent: used_percent(window.get("used_percent")),
            resets_at: reset_from_unix_seconds(window.get("reset_at")),
            limit_seconds: Some(limit_seconds),
        });
    }
    windows
}

struct QuotaPayload {
    windows: Vec<QuotaWindow>,
    plan: Option<String>,
}

fn parse_payload(platform: QuotaPlatform, body: &str) -> Result<QuotaPayload, String> {
    let root: Value = serde_json::from_str(body).map_err(|error| error.to_string())?;
    if !root.is_object() {
        return Err("Response is not an object".to_string());
    }

    let (windows, plan) = match platform {
        QuotaPlatform::Claude => (claude_windows(&root), None),
        QuotaPlatform::Codex => (
            codex_windows(&root),
            root.get("plan_type")
                .and_then(Value::as_str)
                .map(str::to_string),
        ),
    };

    // Only windows the source actually reported are kept; a missing window is
    // not backfilled, because that would read as "this window is unused".
    if windows.is_empty() {
        return Err("No usable quota window in the response".to_string());
    }
    Ok(QuotaPayload { windows, plan })
}

struct RequestFailure {
    failure: QuotaFailure,
    detail: Option<String>,
}

async fn request_body(url: &str, headers: &[(&str, String)]) -> Result<String, RequestFailure> {
    // Never follow a redirect that would carry the credential elsewhere.
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(REQUEST_TIMEOUT)
        .build()
        .map_err(|error| RequestFailure {
            failure: QuotaFailure::Network,
            detail: Some(error.to_string()),
        })?;

    let mut request = client.get(url).header("Accept", "application/json");
    for (name, value) in headers {
        request = request.header(*name, value);
    }

    let mut response = request.send().await.map_err(|error| RequestFailure {
        failure: if error.is_timeout() {
            QuotaFailure::Timeout
        } else {
            QuotaFailure::Network
        },
        detail: Some(error.to_string()),
    })?;

    let status = response.status().as_u16();
    if let Some(failure) = failure_for_status(status) {
        return Err(RequestFailure {
            failure,
            detail: Some(format!("HTTP {status}")),
        });
    }

    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|error| RequestFailure {
        failure: QuotaFailure::Network,
        detail: Some(error.to_string()),
    })? {
        if bytes.len() + chunk.len() > MAX_RESPONSE_BYTES {
            return Err(RequestFailure {
                failure: QuotaFailure::Unparsable,
                detail: Some("Response is too large".to_string()),
            });
        }
        bytes.extend_from_slice(&chunk);
    }

    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

fn now_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as i64)
        .unwrap_or_default()
}

async fn probe(
    platform: QuotaPlatform,
    home: Option<&Path>,
    environment: &BTreeMap<String, String>,
) -> PlatformQuota {
    let credential = resolve_credential(platform, home, environment);
    let mut snapshot = PlatformQuota {
        platform,
        connection: credential.connection,
        windows: Vec::new(),
        failure: None,
        detail: None,
        scanned_paths: credential.scanned_paths.clone(),
        plan: None,
        fetched_at: None,
    };

    if let Some(failure) = gated_failure(credential.connection) {
        snapshot.failure = Some(failure);
        return snapshot;
    }
    let Some(access_token) = credential.access_token.clone() else {
        snapshot.failure = Some(QuotaFailure::Unavailable);
        return snapshot;
    };

    let url = match platform {
        QuotaPlatform::Claude => CLAUDE_USAGE_URL,
        QuotaPlatform::Codex => CODEX_USAGE_URL,
    };
    let mut headers = vec![("Authorization", format!("Bearer {access_token}"))];
    match platform {
        QuotaPlatform::Claude => headers.push(("anthropic-beta", CLAUDE_OAUTH_BETA.to_string())),
        QuotaPlatform::Codex => {
            if let Some(account_id) = credential.account_id.clone() {
                headers.push(("ChatGPT-Account-Id", account_id));
            }
        }
    }

    match request_body(url, &headers).await {
        Ok(body) => match parse_payload(platform, &body) {
            Ok(payload) => {
                snapshot.windows = payload.windows;
                snapshot.plan = payload.plan;
                snapshot.fetched_at = Some(now_millis());
            }
            Err(detail) => {
                snapshot.failure = Some(QuotaFailure::Unparsable);
                snapshot.detail = Some(detail);
            }
        },
        Err(error) => {
            snapshot.failure = Some(error.failure);
            snapshot.detail = error.detail;
        }
    }

    snapshot
}

#[tauri::command]
pub async fn usage_quota(app: tauri::AppHandle, platform: QuotaPlatform) -> PlatformQuota {
    let home = app.path().home_dir().ok();
    let environment: BTreeMap<String, String> = std::env::vars().collect();
    probe(platform, home.as_deref(), &environment).await
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;

    /// A scratch configuration directory that removes itself when the test
    /// ends, including after an assertion failure.
    struct Scratch(PathBuf);

    impl Scratch {
        fn new(name: &str) -> Self {
            let mut directory = std::env::temp_dir();
            directory.push(format!("lithe-quota-{}-{name}", std::process::id()));
            let _ = fs::remove_dir_all(&directory);
            fs::create_dir_all(&directory).expect("scratch directory should be creatable");
            Self(directory)
        }

        fn write(&self, relative: &str, contents: &str) {
            let path = self.0.join(relative);
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent).expect("scratch parent should be creatable");
            }
            fs::write(path, contents).expect("scratch file should be writable");
        }

        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn environment() -> BTreeMap<String, String> {
        BTreeMap::new()
    }

    /// The fixture bodies come from cc-usage, which reads the same two
    /// endpoints from a machine that actually holds subscription tokens.
    const CLAUDE_BODY: &str = r#"{
        "five_hour": {"utilization": 12.5, "resets_at": "2026-09-24T10:00:00.000000+00:00"},
        "seven_day": {"utilization": 56.25},
        "seven_day_opus": {"utilization": 0.0},
        "seven_day_sonnet": null
    }"#;

    const CODEX_BODY: &str = r#"{
        "plan_type": "plus",
        "rate_limit": {
            "primary_window": {"used_percent": 71.0, "limit_window_seconds": 604800, "reset_at": 1780000000},
            "secondary_window": {"used_percent": 4.0, "limit_window_seconds": 18000, "reset_at": 1779990000}
        }
    }"#;

    #[test]
    fn claude_payload_reports_the_windows_it_carries() {
        let payload = parse_payload(QuotaPlatform::Claude, CLAUDE_BODY).expect("payload parses");

        let keys: Vec<&str> = payload.windows.iter().map(|w| w.key.as_str()).collect();
        assert_eq!(keys, ["5h", "7d", "7dOpus"]);
        assert_eq!(payload.windows[0].used_percent, Some(12.5));
        assert_eq!(
            payload.windows[0].limit_seconds,
            Some(SECONDS_PER_FIVE_HOURS)
        );
        assert_eq!(
            payload.windows[0].resets_at.as_deref(),
            Some("2026-09-24T10:00:00.000000+00:00")
        );
        // A window the source reported as 0 per cent is still a window.
        assert_eq!(payload.windows[2].used_percent, Some(0.0));
    }

    #[test]
    fn a_claude_window_without_a_percentage_keeps_the_window() {
        let body = r#"{"seven_day": {"utilization": null, "resets_at": "not-a-date"}}"#;
        let payload = parse_payload(QuotaPlatform::Claude, body).expect("payload parses");

        assert_eq!(payload.windows.len(), 1);
        assert_eq!(payload.windows[0].used_percent, None);
        assert_eq!(payload.windows[0].resets_at, None);
    }

    #[test]
    fn an_out_of_range_percentage_counts_as_not_reported() {
        let body = r#"{"five_hour": {"utilization": 180}}"#;
        let payload = parse_payload(QuotaPlatform::Claude, body).expect("payload parses");

        assert_eq!(payload.windows[0].used_percent, None);
    }

    #[test]
    fn a_payload_without_a_usable_window_is_unparsable() {
        assert!(parse_payload(QuotaPlatform::Claude, "{}").is_err());
        assert!(parse_payload(QuotaPlatform::Claude, "[]").is_err());
        assert!(parse_payload(QuotaPlatform::Claude, "not json").is_err());
    }

    #[test]
    fn codex_keys_windows_by_length_not_by_position() {
        // On Pro accounts the primary window is the seven day one, so keying by
        // position would label it as the five hour window.
        let payload = parse_payload(QuotaPlatform::Codex, CODEX_BODY).expect("payload parses");

        let keys: Vec<&str> = payload.windows.iter().map(|w| w.key.as_str()).collect();
        assert_eq!(keys, ["7d", "5h"]);
        assert_eq!(payload.windows[0].used_percent, Some(71.0));
        assert_eq!(payload.plan.as_deref(), Some("plus"));
    }

    #[test]
    fn codex_reset_seconds_become_a_timestamp() {
        let payload = parse_payload(QuotaPlatform::Codex, CODEX_BODY).expect("payload parses");

        assert_eq!(
            payload.windows[0].resets_at.as_deref(),
            Some("2026-05-28T20:26:40.000Z")
        );
    }

    #[test]
    fn a_codex_window_without_a_length_is_dropped() {
        let body = r#"{"rate_limit": {"primary_window": {"used_percent": 71.0}}}"#;

        assert!(parse_payload(QuotaPlatform::Codex, body).is_err());
    }

    #[test]
    fn only_a_subscription_has_a_queryable_usage_endpoint() {
        assert_eq!(gated_failure(QuotaConnection::Auth), None);
        // The endpoint answers 401 for an API key; calling that an expired
        // credential would send users off to sign in again.
        assert_eq!(
            gated_failure(QuotaConnection::Api),
            Some(QuotaFailure::Unsupported)
        );
        assert_eq!(
            gated_failure(QuotaConnection::Relay),
            Some(QuotaFailure::Unsupported)
        );
        assert_eq!(
            gated_failure(QuotaConnection::None),
            Some(QuotaFailure::Unavailable)
        );
    }

    #[test]
    fn http_status_maps_to_a_stable_failure() {
        assert_eq!(failure_for_status(200), None);
        assert_eq!(failure_for_status(299), None);
        assert_eq!(failure_for_status(401), Some(QuotaFailure::Unauthorized));
        assert_eq!(failure_for_status(403), Some(QuotaFailure::Forbidden));
        assert_eq!(failure_for_status(429), Some(QuotaFailure::RateLimited));
        assert_eq!(failure_for_status(500), Some(QuotaFailure::Network));
    }

    #[test]
    fn window_keys_follow_the_window_length() {
        assert_eq!(window_key_for_seconds(SECONDS_PER_FIVE_HOURS), "5h");
        assert_eq!(window_key_for_seconds(SECONDS_PER_WEEK), "7d");
        assert_eq!(window_key_for_seconds(2_700), "45m");
    }

    #[test]
    fn a_relay_address_is_not_a_subscription() {
        let scratch = Scratch::new("relay");
        scratch.write(
            ".claude/settings.json",
            r#"{"env": {"ANTHROPIC_BASE_URL": "http://127.0.0.1:15721"}}"#,
        );

        let credential = claude_credential(scratch.path(), &environment());

        assert_eq!(credential.connection, QuotaConnection::Relay);
        assert_eq!(credential.access_token, None);
        assert_eq!(credential.scanned_paths.len(), 2);
    }

    #[test]
    fn an_api_key_outranks_the_subscription_file() {
        let scratch = Scratch::new("api-key");
        scratch.write(
            ".claude/settings.json",
            r#"{"env": {"ANTHROPIC_API_KEY": "sk-test"}}"#,
        );
        scratch.write(
            ".claude/.credentials.json",
            r#"{"claudeAiOauth": {"accessToken": "subscription-token"}}"#,
        );

        let credential = claude_credential(scratch.path(), &environment());

        assert_eq!(credential.connection, QuotaConnection::Api);
        assert_eq!(credential.access_token, None);
    }

    #[test]
    fn an_official_subscription_yields_its_access_token() {
        let scratch = Scratch::new("subscription");
        scratch.write(
            ".claude/.credentials.json",
            r#"{"claudeAiOauth": {"accessToken": "subscription-token"}}"#,
        );

        let credential = claude_credential(scratch.path(), &environment());

        assert_eq!(credential.connection, QuotaConnection::Auth);
        assert_eq!(
            credential.access_token.as_deref(),
            Some("subscription-token")
        );
    }

    #[test]
    fn a_custom_config_directory_is_honoured() {
        let scratch = Scratch::new("config-dir");
        scratch.write(
            "elsewhere/.credentials.json",
            r#"{"claudeAiOauth": {"accessToken": "subscription-token"}}"#,
        );
        let mut variables = environment();
        variables.insert(
            "CLAUDE_CONFIG_DIR".to_string(),
            scratch
                .path()
                .join("elsewhere")
                .to_string_lossy()
                .into_owned(),
        );

        let credential = claude_credential(scratch.path(), &variables);

        assert_eq!(credential.connection, QuotaConnection::Auth);
    }

    #[test]
    fn a_codex_api_key_outranks_its_subscription_token() {
        let scratch = Scratch::new("codex-key");
        scratch.write(
            ".codex/auth.json",
            r#"{"OPENAI_API_KEY": "sk-test", "tokens": {"access_token": "subscription-token"}}"#,
        );

        let credential = codex_credential(scratch.path(), &environment());

        assert_eq!(credential.connection, QuotaConnection::Api);
        assert_eq!(credential.access_token, None);
    }

    #[test]
    fn a_codex_subscription_carries_its_account_id() {
        let scratch = Scratch::new("codex-account");
        scratch.write(
            ".codex/auth.json",
            r#"{"tokens": {"access_token": "subscription-token", "account_id": "account-1"}}"#,
        );

        let credential = codex_credential(scratch.path(), &environment());

        assert_eq!(credential.connection, QuotaConnection::Auth);
        assert_eq!(credential.account_id.as_deref(), Some("account-1"));
    }

    #[test]
    fn a_missing_home_directory_reports_no_credential() {
        let credential = resolve_credential(QuotaPlatform::Claude, None, &environment());

        assert_eq!(credential.connection, QuotaConnection::None);
        assert!(credential.scanned_paths.is_empty());
    }

    /// A connection that cannot be queried answers without touching the
    /// network, which is what keeps this reachable in a unit test.
    #[test]
    fn an_unqueryable_connection_fails_without_a_request() {
        let scratch = Scratch::new("gated");
        scratch.write(
            ".claude/settings.json",
            r#"{"env": {"ANTHROPIC_API_KEY": "sk-test"}}"#,
        );
        let snapshot = tauri::async_runtime::block_on(probe(
            QuotaPlatform::Claude,
            Some(scratch.path()),
            &environment(),
        ));

        assert_eq!(snapshot.connection, QuotaConnection::Api);
        assert_eq!(snapshot.failure, Some(QuotaFailure::Unsupported));
        assert!(snapshot.windows.is_empty());
        assert_eq!(snapshot.fetched_at, None);
    }
}
