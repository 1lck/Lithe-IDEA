//! Discourse user API key authorization shared by every platform host.

use crate::protocol::{CoreError, ErrorCode};
use base64::engine::general_purpose::{STANDARD, URL_SAFE, URL_SAFE_NO_PAD};
use base64::Engine;
use rand::rngs::OsRng;
use rand::RngCore;
use reqwest::blocking::{Client, Response};
use reqwest::header::{ACCEPT, CONTENT_LENGTH, USER_AGENT};
use rsa::pkcs1::{EncodeRsaPublicKey, LineEnding};
use rsa::{Oaep, RsaPrivateKey, RsaPublicKey};
use serde::{Deserialize, Serialize};
use sha1::Sha1;
use std::collections::HashMap;
use std::io::Read;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use url::Url;

const AUTHORIZATION_PATH: &str = "user-api-key/new";
const AUTHORIZATION_LIFETIME: Duration = Duration::from_secs(10 * 60);
const RSA_BITS: usize = 2048;
const MAX_RESPONSE_BYTES: u64 = 5 * 1024 * 1024;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const CLIENT_USER_AGENT: &str = "Lithe/0.1 DiscourseClient";

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Parameters needed to begin an external-browser Discourse authorization.
pub(crate) struct DiscourseAuthorizationBeginRequest {
    /// HTTPS origin of the Discourse installation, without credentials.
    origin: String,
    /// Stable application identifier recorded by Discourse.
    client_id: String,
    /// User-visible application name shown on the approval screen.
    application_name: String,
    /// Platform callback URL that receives the encrypted payload.
    auth_redirect: String,
    /// Least-privilege user API key scopes requested from the user.
    scopes: Vec<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
/// Browser URL and opaque flow identifier returned to a platform host.
pub(crate) struct DiscourseAuthorizationBeginResponse {
    /// Opaque identifier needed to complete this in-memory authorization flow.
    flow_id: String,
    /// Fully encoded URL that the platform must open in the default browser.
    authorization_url: String,
    /// Unix timestamp after which the callback is rejected.
    expires_at: u64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Callback submitted by a platform after its URL scheme is invoked.
pub(crate) struct DiscourseAuthorizationCompleteRequest {
    /// Opaque identifier returned by the begin command.
    flow_id: String,
    /// Complete callback URL received from the operating system.
    callback_url: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
/// Verified credential returned for storage in the platform credential vault.
pub(crate) struct DiscourseAuthorizationCredential {
    /// Per-user API key issued and revocable by the Discourse installation.
    user_api_key: String,
    /// User API protocol version reported by the server payload.
    api_version: u64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Shared authentication and site fields used by Discourse API commands.
struct DiscourseAPIContext {
    /// HTTPS origin of the Discourse installation.
    origin: String,
    /// Per-user API key loaded from the platform credential vault.
    user_api_key: String,
    /// Stable client identifier used during authorization.
    client_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request for latest or top topic summaries.
pub(crate) struct DiscourseTopicsRequest {
    #[serde(flatten)]
    context: DiscourseAPIContext,
    /// Feed kind: `latest` or `top`.
    feed: String,
    /// Optional top period such as `daily`, `weekly`, or `monthly`.
    #[serde(default)]
    period: Option<String>,
    /// Optional zero-based Discourse pagination index.
    #[serde(default)]
    page: Option<u32>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request for one topic and its currently returned post stream.
pub(crate) struct DiscourseTopicRequest {
    #[serde(flatten)]
    context: DiscourseAPIContext,
    /// Positive Discourse topic identifier.
    topic_id: u64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request for the visible category catalog.
pub(crate) struct DiscourseCategoriesRequest {
    #[serde(flatten)]
    context: DiscourseAPIContext,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request for a bounded Discourse search page.
pub(crate) struct DiscourseSearchRequest {
    #[serde(flatten)]
    context: DiscourseAPIContext,
    /// Search syntax accepted by the Discourse installation.
    query: String,
    /// Optional one-based search result page.
    #[serde(default)]
    page: Option<u32>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request to revoke a user API key on its issuing site.
pub(crate) struct DiscourseRevokeRequest {
    #[serde(flatten)]
    context: DiscourseAPIContext,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
/// Stable topic summary rendered by both platform clients.
pub(crate) struct DiscourseTopicSummary {
    id: u64,
    slug: String,
    title: String,
    #[serde(default)]
    posts_count: u64,
    #[serde(default)]
    reply_count: u64,
    #[serde(default)]
    views: u64,
    #[serde(default)]
    like_count: u64,
    #[serde(default)]
    category_id: Option<u64>,
    #[serde(default)]
    created_at: Option<String>,
    #[serde(default)]
    last_posted_at: Option<String>,
    #[serde(default)]
    last_poster_username: Option<String>,
    #[serde(default)]
    pinned: bool,
    #[serde(default)]
    closed: bool,
    #[serde(default)]
    archived: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
/// Normalized topic page returned by latest and top feeds.
pub(crate) struct DiscourseTopicsResponse {
    topics: Vec<DiscourseTopicSummary>,
    more_topics_url: Option<String>,
}

#[derive(Debug, Deserialize)]
struct TopicListEnvelope {
    topic_list: TopicList,
}

#[derive(Debug, Deserialize)]
struct TopicList {
    #[serde(default)]
    topics: Vec<DiscourseTopicSummary>,
    #[serde(default)]
    more_topics_url: Option<String>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
/// Stable category metadata independent of Discourse theme fields.
pub(crate) struct DiscourseCategory {
    id: u64,
    name: String,
    slug: String,
    #[serde(default)]
    color: Option<String>,
    #[serde(default)]
    topic_count: u64,
    #[serde(default)]
    description_text: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CategoryEnvelope {
    category_list: CategoryList,
}

#[derive(Debug, Deserialize)]
struct CategoryList {
    #[serde(default)]
    categories: Vec<DiscourseCategory>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
/// Deterministically ordered visible category catalog.
pub(crate) struct DiscourseCategoriesResponse {
    categories: Vec<DiscourseCategory>,
}

#[derive(Debug, Deserialize)]
struct TopicEnvelope {
    id: u64,
    title: String,
    slug: String,
    post_stream: PostStream,
}

#[derive(Debug, Deserialize)]
struct PostStream {
    #[serde(default)]
    posts: Vec<DiscoursePost>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
/// Sanitized post content and attribution for a topic stream.
pub(crate) struct DiscoursePost {
    id: u64,
    post_number: u64,
    username: String,
    #[serde(default)]
    name: Option<String>,
    cooked: String,
    #[serde(default)]
    created_at: Option<String>,
    #[serde(default)]
    updated_at: Option<String>,
    #[serde(default)]
    reply_count: u64,
    #[serde(default)]
    reads: u64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
/// One topic with sanitized post HTML in ascending post order.
pub(crate) struct DiscourseTopicResponse {
    id: u64,
    title: String,
    slug: String,
    posts: Vec<DiscoursePost>,
}

#[derive(Debug, Deserialize)]
struct SearchEnvelope {
    #[serde(default)]
    topics: Vec<DiscourseTopicSummary>,
    #[serde(default)]
    posts: Vec<DiscoursePost>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
/// Normalized topic and sanitized post matches from a search page.
pub(crate) struct DiscourseSearchResponse {
    topics: Vec<DiscourseTopicSummary>,
    posts: Vec<DiscoursePost>,
}

/// Lists latest or top topics through the Rust-owned HTTP client.
pub(crate) fn topics(
    request: DiscourseTopicsRequest,
) -> Result<DiscourseTopicsResponse, CoreError> {
    let mut url = api_url(
        &request.context,
        match request.feed.as_str() {
            "latest" => "latest.json",
            "top" => "top.json",
            _ => {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Topic feed must be latest or top",
                ))
            }
        },
    )?;
    if request.feed == "top" {
        if let Some(period) = request.period {
            const PERIODS: &[&str] = &["all", "yearly", "quarterly", "monthly", "weekly", "daily"];
            if !PERIODS.contains(&period.as_str()) {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Unsupported top topic period",
                ));
            }
            url.query_pairs_mut().append_pair("period", &period);
        }
    }
    if let Some(page) = request.page {
        url.query_pairs_mut().append_pair("page", &page.to_string());
    }
    let envelope: TopicListEnvelope = get_json(&request.context, url)?;
    Ok(DiscourseTopicsResponse {
        topics: envelope.topic_list.topics,
        more_topics_url: envelope.topic_list.more_topics_url,
    })
}

/// Reads and sanitizes one topic stream through the Rust-owned HTTP client.
pub(crate) fn topic(request: DiscourseTopicRequest) -> Result<DiscourseTopicResponse, CoreError> {
    if request.topic_id == 0 {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Topic ID must be positive",
        ));
    }
    let envelope: TopicEnvelope = get_json(
        &request.context,
        api_url(&request.context, &format!("t/{}.json", request.topic_id))?,
    )?;
    Ok(DiscourseTopicResponse {
        id: envelope.id,
        title: envelope.title,
        slug: envelope.slug,
        posts: sanitize_posts(envelope.post_stream.posts),
    })
}

/// Lists visible categories through the Rust-owned HTTP client.
pub(crate) fn categories(
    request: DiscourseCategoriesRequest,
) -> Result<DiscourseCategoriesResponse, CoreError> {
    let envelope: CategoryEnvelope = get_json(
        &request.context,
        api_url(&request.context, "categories.json")?,
    )?;
    Ok(DiscourseCategoriesResponse {
        categories: envelope.category_list.categories,
    })
}

/// Searches topics and posts through the Rust-owned HTTP client.
pub(crate) fn search(
    request: DiscourseSearchRequest,
) -> Result<DiscourseSearchResponse, CoreError> {
    let query = required_single_line(&request.query, "query")?;
    let mut url = api_url(&request.context, "search.json")?;
    url.query_pairs_mut().append_pair("q", query);
    if let Some(page) = request.page {
        url.query_pairs_mut().append_pair("page", &page.to_string());
    }
    let envelope: SearchEnvelope = get_json(&request.context, url)?;
    Ok(DiscourseSearchResponse {
        topics: envelope.topics,
        posts: sanitize_posts(envelope.posts),
    })
}

/// Revokes the credential on the issuing Discourse installation.
pub(crate) fn revoke(request: DiscourseRevokeRequest) -> Result<serde_json::Value, CoreError> {
    let url = api_url(&request.context, "user-api-key/revoke")?;
    let response = authenticated_request(&request.context, reqwest::Method::POST, url)?.send();
    checked_response(response)?;
    Ok(serde_json::json!({}))
}

struct PendingAuthorization {
    private_key: RsaPrivateKey,
    nonce: String,
    auth_redirect: String,
    expires_at: u64,
}

#[derive(Deserialize)]
struct EncryptedAuthorizationPayload {
    key: String,
    nonce: String,
    api: u64,
}

fn pending_authorizations() -> &'static Mutex<HashMap<String, PendingAuthorization>> {
    static PENDING: OnceLock<Mutex<HashMap<String, PendingAuthorization>>> = OnceLock::new();
    PENDING.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Creates an ephemeral RSA key and returns a browser authorization URL.
pub(crate) fn begin_authorization(
    request: DiscourseAuthorizationBeginRequest,
) -> Result<DiscourseAuthorizationBeginResponse, CoreError> {
    let origin = validated_origin(&request.origin)?;
    let auth_redirect = validated_redirect(&request.auth_redirect)?;
    let client_id = required_single_line(&request.client_id, "clientId")?;
    let application_name = required_single_line(&request.application_name, "applicationName")?;
    let scopes = validated_scopes(request.scopes)?;
    let now = unix_timestamp()?;

    let private_key = RsaPrivateKey::new(&mut OsRng, RSA_BITS).map_err(|error| {
        CoreError::new(ErrorCode::Unknown, "Could not create an authorization key")
            .with_details(error.to_string())
    })?;
    let public_key = RsaPublicKey::from(&private_key)
        .to_pkcs1_pem(LineEnding::LF)
        .map_err(|error| {
            CoreError::new(ErrorCode::Unknown, "Could not encode the authorization key")
                .with_details(error.to_string())
        })?;
    let flow_id = random_identifier(16);
    let nonce = random_identifier(32);
    let expires_at = now + AUTHORIZATION_LIFETIME.as_secs();
    let authorization_url = build_authorization_url(
        origin,
        client_id,
        application_name,
        &auth_redirect,
        &scopes,
        &nonce,
        public_key.as_str(),
    );

    let mut pending = pending_authorizations()
        .lock()
        .map_err(|_| CoreError::new(ErrorCode::Unknown, "Authorization state is unavailable"))?;
    pending.retain(|_, authorization| authorization.expires_at > now);
    pending.insert(
        flow_id.clone(),
        PendingAuthorization {
            private_key,
            nonce,
            auth_redirect,
            expires_at,
        },
    );

    Ok(DiscourseAuthorizationBeginResponse {
        flow_id,
        authorization_url,
        expires_at,
    })
}

/// Decrypts one callback and consumes its authorization flow to prevent replay.
pub(crate) fn complete_authorization(
    request: DiscourseAuthorizationCompleteRequest,
) -> Result<DiscourseAuthorizationCredential, CoreError> {
    let callback = Url::parse(&request.callback_url).map_err(|error| {
        CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid authorization callback URL",
        )
        .with_details(error.to_string())
    })?;
    let now = unix_timestamp()?;
    let authorization = pending_authorizations()
        .lock()
        .map_err(|_| CoreError::new(ErrorCode::Unknown, "Authorization state is unavailable"))?
        .remove(&request.flow_id)
        .ok_or_else(|| {
            CoreError::new(
                ErrorCode::InvalidRequest,
                "Authorization session was not found or was already used",
            )
        })?;
    if authorization.expires_at <= now {
        return Err(CoreError::new(
            ErrorCode::TimedOut,
            "Authorization session expired",
        ));
    }
    if !same_callback_target(&callback, &authorization.auth_redirect) {
        return Err(CoreError::new(
            ErrorCode::PermissionDenied,
            "Authorization callback target did not match the requested redirect",
        ));
    }
    let encrypted_payload = callback
        .query_pairs()
        .find_map(|(name, value)| (name == "payload").then(|| value.into_owned()))
        .ok_or_else(|| {
            CoreError::new(
                ErrorCode::InvalidRequest,
                "Authorization callback did not contain a payload",
            )
        })?;
    let encrypted_payload = decode_payload(&encrypted_payload)?;
    let decrypted = authorization
        .private_key
        .decrypt(Oaep::new::<Sha1>(), &encrypted_payload)
        .map_err(|_| {
            CoreError::new(
                ErrorCode::PermissionDenied,
                "Authorization payload could not be decrypted",
            )
        })?;
    let payload: EncryptedAuthorizationPayload =
        serde_json::from_slice(&decrypted).map_err(|error| {
            CoreError::new(ErrorCode::ParseFailed, "Authorization payload was invalid")
                .with_details(error.to_string())
        })?;
    if payload.nonce != authorization.nonce {
        return Err(CoreError::new(
            ErrorCode::PermissionDenied,
            "Authorization nonce did not match",
        ));
    }
    if payload.key.trim().is_empty() {
        return Err(CoreError::new(
            ErrorCode::ParseFailed,
            "Authorization payload did not contain a user API key",
        ));
    }

    Ok(DiscourseAuthorizationCredential {
        user_api_key: payload.key,
        api_version: payload.api,
    })
}

fn validated_origin(value: &str) -> Result<Url, CoreError> {
    let mut url = Url::parse(value).map_err(|error| {
        CoreError::new(ErrorCode::InvalidRequest, "Invalid Discourse origin")
            .with_details(error.to_string())
    })?;
    if url.scheme() != "https"
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.path() != "/"
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Discourse origin must be an HTTPS origin without credentials",
        ));
    }
    url.set_path("/");
    Ok(url)
}

fn validated_redirect(value: &str) -> Result<String, CoreError> {
    let url = Url::parse(value).map_err(|error| {
        CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid authorization redirect URL",
        )
        .with_details(error.to_string())
    })?;
    if url.scheme().is_empty()
        || url.host_str().is_none()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Authorization redirect must contain a scheme and host without query parameters",
        ));
    }
    Ok(url.to_string())
}

fn required_single_line<'a>(value: &'a str, field: &str) -> Result<&'a str, CoreError> {
    let trimmed = value.trim();
    if trimmed.is_empty() || trimmed.contains(['\r', '\n']) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            format!("{field} must be a non-empty single-line value"),
        ));
    }
    Ok(trimmed)
}

fn validated_scopes(scopes: Vec<String>) -> Result<String, CoreError> {
    const ALLOWED: &[&str] = &[
        "bookmarks_calendar",
        "message_bus",
        "notifications",
        "one_time_password",
        "push",
        "read",
        "session_info",
        "user_status",
        "write",
    ];
    let mut scopes = scopes
        .into_iter()
        .map(|scope| scope.trim().to_string())
        .collect::<Vec<_>>();
    scopes.sort();
    scopes.dedup();
    if scopes.is_empty()
        || scopes
            .iter()
            .any(|scope| !ALLOWED.contains(&scope.as_str()))
    {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Authorization scopes contained an unsupported value",
        ));
    }
    Ok(scopes.join(","))
}

fn build_authorization_url(
    mut origin: Url,
    client_id: &str,
    application_name: &str,
    auth_redirect: &str,
    scopes: &str,
    nonce: &str,
    public_key: &str,
) -> String {
    origin.set_path(AUTHORIZATION_PATH);
    origin
        .query_pairs_mut()
        .append_pair("application_name", application_name)
        .append_pair("client_id", client_id)
        .append_pair("auth_redirect", auth_redirect)
        .append_pair("scopes", scopes)
        .append_pair("nonce", nonce)
        .append_pair("public_key", public_key)
        .append_pair("padding", "oaep");
    origin.into()
}

fn same_callback_target(callback: &Url, expected: &str) -> bool {
    Url::parse(expected).is_ok_and(|expected| {
        callback.scheme() == expected.scheme()
            && callback.host_str() == expected.host_str()
            && callback.port_or_known_default() == expected.port_or_known_default()
            && callback.path() == expected.path()
    })
}

fn decode_payload(value: &str) -> Result<Vec<u8>, CoreError> {
    let normalized = value.replace('-', "+").replace('_', "/");
    let padded = format!("{normalized}{}", "=".repeat((4 - normalized.len() % 4) % 4));
    STANDARD
        .decode(&padded)
        .or_else(|_| URL_SAFE.decode(value))
        .map_err(|error| {
            CoreError::new(
                ErrorCode::ParseFailed,
                "Authorization payload was not valid Base64",
            )
            .with_details(error.to_string())
        })
}

fn random_identifier(byte_count: usize) -> String {
    let mut bytes = vec![0_u8; byte_count];
    OsRng.fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

fn unix_timestamp() -> Result<u64, CoreError> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .map_err(|error| {
            CoreError::new(ErrorCode::Unknown, "System clock is before the Unix epoch")
                .with_details(error.to_string())
        })
}

fn api_url(context: &DiscourseAPIContext, path: &str) -> Result<Url, CoreError> {
    if context.user_api_key.trim().is_empty() || context.client_id.trim().is_empty() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Discourse credential and client ID are required",
        ));
    }
    validated_origin(&context.origin)?
        .join(path)
        .map_err(|error| {
            CoreError::new(ErrorCode::InvalidRequest, "Invalid Discourse API path")
                .with_details(error.to_string())
        })
}

fn authenticated_request(
    context: &DiscourseAPIContext,
    method: reqwest::Method,
    url: Url,
) -> Result<reqwest::blocking::RequestBuilder, CoreError> {
    let client = Client::builder()
        .timeout(REQUEST_TIMEOUT)
        .build()
        .map_err(|error| network_error("Could not initialize the Discourse client", error))?;
    Ok(client
        .request(method, url)
        .header(ACCEPT, "application/json")
        .header(USER_AGENT, CLIENT_USER_AGENT)
        .header("User-Api-Key", context.user_api_key.trim())
        .header("User-Api-Client-Id", context.client_id.trim()))
}

fn get_json<T: for<'de> Deserialize<'de>>(
    context: &DiscourseAPIContext,
    url: Url,
) -> Result<T, CoreError> {
    let response = authenticated_request(context, reqwest::Method::GET, url)?.send();
    let bytes = read_limited_response(checked_response(response)?)?;
    serde_json::from_slice(&bytes).map_err(|error| {
        CoreError::new(ErrorCode::ParseFailed, "Discourse returned invalid JSON")
            .with_details(error.to_string())
    })
}

fn checked_response(response: Result<Response, reqwest::Error>) -> Result<Response, CoreError> {
    let response = response.map_err(|error| network_error("Discourse request failed", error))?;
    let status = response.status();
    if status.is_success() {
        return Ok(response);
    }
    let (code, message) = match status.as_u16() {
        401 | 403 => (
            ErrorCode::PermissionDenied,
            "LINUX DO authorization was rejected or has expired",
        ),
        404 => (
            ErrorCode::InvalidRequest,
            "Discourse resource was not found",
        ),
        429 => (ErrorCode::TimedOut, "Discourse rate limit was reached"),
        _ => (ErrorCode::Unknown, "Discourse request was unsuccessful"),
    };
    Err(CoreError::new(code, message).with_details(status.as_u16().to_string()))
}

fn read_limited_response(response: Response) -> Result<Vec<u8>, CoreError> {
    if response
        .headers()
        .get(CONTENT_LENGTH)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<u64>().ok())
        .is_some_and(|length| length > MAX_RESPONSE_BYTES)
    {
        return Err(CoreError::new(
            ErrorCode::ParseFailed,
            "Discourse response exceeded the 5 MB limit",
        ));
    }
    let mut bytes = Vec::new();
    response
        .take(MAX_RESPONSE_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| {
            CoreError::new(ErrorCode::Unknown, "Could not read the Discourse response")
                .with_details(error.to_string())
        })?;
    if bytes.len() as u64 > MAX_RESPONSE_BYTES {
        return Err(CoreError::new(
            ErrorCode::ParseFailed,
            "Discourse response exceeded the 5 MB limit",
        ));
    }
    Ok(bytes)
}

fn sanitize_posts(mut posts: Vec<DiscoursePost>) -> Vec<DiscoursePost> {
    for post in &mut posts {
        post.cooked = ammonia::clean(&post.cooked);
    }
    posts.sort_by_key(|post| post.post_number);
    posts
}

fn network_error(message: &str, error: reqwest::Error) -> CoreError {
    let code = if error.is_timeout() {
        ErrorCode::TimedOut
    } else {
        ErrorCode::Unknown
    };
    // Library diagnostics can include the request URL but never request headers.
    CoreError::new(code, message).with_details(error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use rsa::pkcs1::DecodeRsaPublicKey;
    use serde_json::json;

    #[test]
    fn begin_builds_a_least_privilege_oaep_authorization_url() {
        let result = begin_authorization(DiscourseAuthorizationBeginRequest {
            origin: "https://linux.do".into(),
            client_id: "app.lithe.linux-do".into(),
            application_name: "Lithe".into(),
            auth_redirect: "lithe://auth/linux-do".into(),
            scopes: vec!["session_info".into(), "read".into(), "read".into()],
        })
        .unwrap();
        let url = Url::parse(&result.authorization_url).unwrap();
        let query = url.query_pairs().collect::<HashMap<_, _>>();

        assert_eq!(
            url.as_str().split('?').next().unwrap(),
            "https://linux.do/user-api-key/new"
        );
        assert_eq!(query["scopes"], "read,session_info");
        assert_eq!(query["padding"], "oaep");
        assert_eq!(query["auth_redirect"], "lithe://auth/linux-do");
        RsaPublicKey::from_pkcs1_pem(&query["public_key"]).unwrap();
    }

    #[test]
    fn rejects_insecure_origins_and_unknown_scopes() {
        for request in [
            DiscourseAuthorizationBeginRequest {
                origin: "http://linux.do".into(),
                client_id: "client".into(),
                application_name: "Lithe".into(),
                auth_redirect: "lithe://auth/linux-do".into(),
                scopes: vec!["read".into()],
            },
            DiscourseAuthorizationBeginRequest {
                origin: "https://linux.do".into(),
                client_id: "client".into(),
                application_name: "Lithe".into(),
                auth_redirect: "lithe://auth/linux-do".into(),
                scopes: vec!["admin".into()],
            },
        ] {
            assert!(begin_authorization(request).is_err());
        }
    }

    #[test]
    fn completes_an_oaep_callback_once_and_verifies_the_nonce() {
        let begun = begin_authorization(DiscourseAuthorizationBeginRequest {
            origin: "https://linux.do".into(),
            client_id: "app.lithe.linux-do".into(),
            application_name: "Lithe".into(),
            auth_redirect: "lithe://auth/linux-do".into(),
            scopes: vec!["read".into()],
        })
        .unwrap();
        let (public_key, nonce) = {
            let pending = pending_authorizations().lock().unwrap();
            let authorization = pending.get(&begun.flow_id).unwrap();
            (
                RsaPublicKey::from(&authorization.private_key),
                authorization.nonce.clone(),
            )
        };
        let cleartext = serde_json::to_vec(&json!({
            "key": "test-user-api-key",
            "nonce": nonce,
            "api": 4
        }))
        .unwrap();
        let encrypted = public_key
            .encrypt(&mut OsRng, Oaep::new::<Sha1>(), &cleartext)
            .unwrap();
        let mut callback = Url::parse("lithe://auth/linux-do").unwrap();
        callback
            .query_pairs_mut()
            .append_pair("payload", &URL_SAFE_NO_PAD.encode(encrypted));

        let completed = complete_authorization(DiscourseAuthorizationCompleteRequest {
            flow_id: begun.flow_id.clone(),
            callback_url: callback.to_string(),
        })
        .unwrap();

        assert_eq!(completed.user_api_key, "test-user-api-key");
        assert_eq!(completed.api_version, 4);
        assert!(
            complete_authorization(DiscourseAuthorizationCompleteRequest {
                flow_id: begun.flow_id,
                callback_url: callback.to_string(),
            })
            .is_err()
        );
    }

    #[test]
    fn sanitizes_and_orders_post_html() {
        let posts = sanitize_posts(vec![
            DiscoursePost {
                id: 2,
                post_number: 2,
                username: "second".into(),
                name: None,
                cooked: "<p>Safe</p><script>alert(1)</script>".into(),
                created_at: None,
                updated_at: None,
                reply_count: 0,
                reads: 0,
            },
            DiscoursePost {
                id: 1,
                post_number: 1,
                username: "first".into(),
                name: None,
                cooked: "<p>First</p>".into(),
                created_at: None,
                updated_at: None,
                reply_count: 0,
                reads: 0,
            },
        ]);

        assert_eq!(posts[0].post_number, 1);
        assert!(!posts[1].cooked.contains("script"));
        assert!(posts[1].cooked.contains("Safe"));
    }
}
