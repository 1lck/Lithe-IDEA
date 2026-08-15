//! Deterministic GitHub request planning and response normalization.
//!
//! Network transport and credential storage remain platform-owned. This module
//! keeps GitHub REST paths, payloads, response shapes, and error translation
//! identical for the macOS and Windows products.

use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request to derive a GitHub repository identity from one Git remote URL.
pub struct ParseRemoteRequest {
    /// HTTPS or SSH Git remote URL.
    pub remote_url: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
/// Stable repository identity used by GitHub operations.
pub struct GitHubRepository {
    /// GitHub account or organization that owns the repository.
    pub owner: String,
    /// Repository name without a trailing `.git` suffix.
    pub name: String,
}

impl GitHubRepository {
    fn path(&self) -> Result<String, CoreError> {
        validate_repository_component(&self.owner, "owner")?;
        validate_repository_component(&self.name, "name")?;
        Ok(format!("{}/{}", self.owner, self.name))
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Shared input for one GitHub request-plan operation.
pub struct RequestPlanRequest {
    /// Stable operation name documented in `shared/contracts/github.md`.
    pub operation: String,
    /// Repository required by repository-scoped operations.
    #[serde(default)]
    pub repository: Option<GitHubRepository>,
    /// Pull request number required by pull-request-scoped operations.
    #[serde(default)]
    pub pull_number: Option<u64>,
    /// OAuth application's public client identifier.
    #[serde(default)]
    pub client_id: Option<String>,
    /// Device authorization code returned by GitHub.
    #[serde(default)]
    pub device_code: Option<String>,
    /// Pull request title.
    #[serde(default)]
    pub title: Option<String>,
    /// Pull request description or comment/review body.
    #[serde(default)]
    pub body: Option<String>,
    /// Source branch for pull request creation.
    #[serde(default)]
    pub head: Option<String>,
    /// Target branch for pull request creation or update.
    #[serde(default)]
    pub base: Option<String>,
    /// Whether a new pull request starts as a draft.
    #[serde(default)]
    pub draft: Option<bool>,
    /// Open/closed/all filter or update value.
    #[serde(default)]
    pub state: Option<String>,
    /// Review event: APPROVE, REQUEST_CHANGES, or COMMENT.
    #[serde(default)]
    pub event: Option<String>,
    /// Merge method: merge, squash, or rebase.
    #[serde(default)]
    pub merge_method: Option<String>,
    /// Optional labels for issue metadata updates.
    #[serde(default)]
    pub labels: Option<Vec<String>>,
    /// Optional assignee logins for issue metadata updates.
    #[serde(default)]
    pub assignees: Option<Vec<String>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
/// Platform-neutral HTTP request description produced by Rust Core.
pub struct GitHubRequestPlan {
    /// Trusted host selector resolved by the platform adapter.
    pub host: GitHubHost,
    /// Uppercase HTTP method.
    pub method: String,
    /// Absolute path on the selected host.
    pub path: String,
    /// Deterministically ordered query parameters.
    pub query: BTreeMap<String, String>,
    /// Optional JSON request body encoded as UTF-8 text.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub body: Option<String>,
    /// Whether the platform must attach a GitHub bearer credential.
    pub requires_authentication: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
/// Trusted GitHub host used by a request plan.
pub enum GitHubHost {
    /// GitHub's REST API host (`api.github.com`).
    Api,
    /// GitHub's browser/OAuth host (`github.com`).
    Web,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Raw HTTP response submitted by a platform adapter for normalization.
pub struct NormalizeResponseRequest {
    /// Operation originally used to build the request plan.
    pub operation: String,
    /// HTTP response status.
    pub status: u16,
    /// UTF-8 response body, or an empty string for a bodyless response.
    pub body: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
/// Normalized GitHub user identity.
pub struct GitHubUser {
    /// GitHub login.
    pub login: String,
    /// User profile URL on GitHub.
    pub url: String,
    /// Optional avatar image URL.
    pub avatar_url: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
/// Normalized GitHub label.
pub struct GitHubLabel {
    /// Stable label name.
    pub name: String,
    /// Six-character RGB value without `#` when supplied by GitHub.
    pub color: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
/// Normalized pull request used by both list and detail surfaces.
pub struct GitHubPullRequest {
    /// Repository-local pull request number.
    pub number: u64,
    /// Current pull request title.
    pub title: String,
    /// Markdown description; absent GitHub values normalize to an empty string.
    pub body: String,
    /// GitHub state such as `open` or `closed`.
    pub state: String,
    /// Whether the pull request is a draft.
    pub is_draft: bool,
    /// Browser URL for this pull request.
    pub url: String,
    /// Pull request author.
    pub author: GitHubUser,
    /// Source branch name.
    pub head_ref: String,
    /// Source repository full name when available.
    pub head_repository: Option<String>,
    /// Target branch name.
    pub base_ref: String,
    /// Target repository full name when available.
    pub base_repository: Option<String>,
    /// ISO-8601 creation timestamp.
    pub created_at: String,
    /// ISO-8601 last-update timestamp.
    pub updated_at: String,
    /// Whether GitHub reports the pull request as merged.
    pub is_merged: bool,
    /// Mergeability is null while GitHub is still computing it.
    pub is_mergeable: Option<bool>,
    /// Added line count when supplied by the detail endpoint.
    pub additions: Option<u64>,
    /// Deleted line count when supplied by the detail endpoint.
    pub deletions: Option<u64>,
    /// Changed file count when supplied by the detail endpoint.
    pub changed_files: Option<u64>,
    /// Conversation comment count.
    pub comments_count: u64,
    /// Labels sorted by name for deterministic rendering.
    pub labels: Vec<GitHubLabel>,
    /// Assignees sorted by login for deterministic rendering.
    pub assignees: Vec<GitHubUser>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
/// Normalized pull request conversation comment.
pub struct GitHubComment {
    /// GitHub database identifier.
    pub id: u64,
    /// Comment author.
    pub author: GitHubUser,
    /// Markdown comment body.
    pub body: String,
    /// ISO-8601 creation timestamp.
    pub created_at: String,
    /// ISO-8601 last-update timestamp.
    pub updated_at: String,
    /// Browser URL for this comment.
    pub url: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
/// Normalized file summary for one pull request.
pub struct GitHubPullRequestFile {
    /// Repository-relative path.
    pub path: String,
    /// GitHub status such as `added`, `modified`, or `removed`.
    pub status: String,
    /// Added line count.
    pub additions: u64,
    /// Deleted line count.
    pub deletions: u64,
    /// Unified patch when GitHub supplies one.
    pub patch: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
/// Normalized GitHub branch offered by pull-request creation surfaces.
pub struct GitHubBranch {
    /// Full branch name without the `refs/heads/` prefix.
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
/// Normalized commit metadata included in a branch comparison.
pub struct GitHubComparisonCommit {
    /// Full Git commit identifier.
    pub sha: String,
    /// Complete commit subject and body returned by GitHub.
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
/// Normalized branch comparison used by pull-request generation workflows.
pub struct GitHubComparison {
    /// Commits in GitHub comparison order.
    pub commits: Vec<GitHubComparisonCommit>,
    /// Changed files sorted by repository-relative path.
    pub files: Vec<GitHubPullRequestFile>,
}

/// Parses one supported GitHub remote URL.
pub fn parse_remote(request: ParseRemoteRequest) -> Result<GitHubRepository, CoreError> {
    let value = request.remote_url.trim().trim_end_matches('/');
    let repository_path = if let Some(path) = value.strip_prefix("https://github.com/") {
        path
    } else if let Some(path) = value.strip_prefix("git@github.com:") {
        path
    } else if let Some(path) = value.strip_prefix("ssh://git@github.com/") {
        path
    } else {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "The Git remote is not a supported GitHub URL",
        ));
    };
    let repository_path = repository_path
        .strip_suffix(".git")
        .unwrap_or(repository_path);
    let mut components = repository_path.split('/');
    let owner = components.next().unwrap_or_default();
    let name = components.next().unwrap_or_default();
    if components.next().is_some() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "The GitHub remote must identify one repository",
        ));
    }
    validate_repository_component(owner, "owner")?;
    validate_repository_component(name, "name")?;
    Ok(GitHubRepository {
        owner: owner.to_string(),
        name: name.to_string(),
    })
}

/// Builds one deterministic GitHub HTTP request description.
pub fn request_plan(request: RequestPlanRequest) -> Result<GitHubRequestPlan, CoreError> {
    let mut query = BTreeMap::new();
    let operation = request.operation.as_str();
    let (host, method, path, body, requires_authentication) = match operation {
        "deviceCode" => {
            let client_id = required_text(request.client_id.as_deref(), "clientId")?;
            (
                GitHubHost::Web,
                "POST",
                "/login/device/code".to_string(),
                Some(json!({
                    "client_id": client_id,
                    "scope": "repo read:user"
                })),
                false,
            )
        }
        "deviceToken" => {
            let client_id = required_text(request.client_id.as_deref(), "clientId")?;
            let device_code = required_text(request.device_code.as_deref(), "deviceCode")?;
            (
                GitHubHost::Web,
                "POST",
                "/login/oauth/access_token".to_string(),
                Some(json!({
                    "client_id": client_id,
                    "device_code": device_code,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
                })),
                false,
            )
        }
        "currentUser" => (GitHubHost::Api, "GET", "/user".to_string(), None, true),
        "listBranches" => {
            let repository = repository_path(&request)?;
            query.insert("per_page".to_string(), "100".to_string());
            (
                GitHubHost::Api,
                "GET",
                format!("/repos/{repository}/branches"),
                None,
                true,
            )
        }
        "compareBranches" => {
            let repository = repository_path(&request)?;
            let base = required_text(request.base.as_deref(), "base")?;
            let head = required_text(request.head.as_deref(), "head")?;
            (
                GitHubHost::Api,
                "GET",
                format!(
                    "/repos/{repository}/compare/{}...{}",
                    encode_path_component(base),
                    encode_path_component(head)
                ),
                None,
                true,
            )
        }
        "listPullRequests" => {
            let repository = repository_path(&request)?;
            let state = request.state.as_deref().unwrap_or("open");
            if !matches!(state, "open" | "closed" | "all") {
                return Err(invalid_field("state"));
            }
            query.insert("state".to_string(), state.to_string());
            query.insert("sort".to_string(), "updated".to_string());
            query.insert("direction".to_string(), "desc".to_string());
            query.insert("per_page".to_string(), "100".to_string());
            (
                GitHubHost::Api,
                "GET",
                format!("/repos/{repository}/pulls"),
                None,
                true,
            )
        }
        "getPullRequest" => pull_request_plan(&request, "GET", "", None)?,
        "createPullRequest" => {
            let repository = repository_path(&request)?;
            let title = required_text(request.title.as_deref(), "title")?;
            let head = required_text(request.head.as_deref(), "head")?;
            let base = required_text(request.base.as_deref(), "base")?;
            (
                GitHubHost::Api,
                "POST",
                format!("/repos/{repository}/pulls"),
                Some(json!({
                    "title": title,
                    "body": request.body.unwrap_or_default(),
                    "head": head,
                    "base": base,
                    "draft": request.draft.unwrap_or(false)
                })),
                true,
            )
        }
        "updatePullRequest" => {
            let mut body = serde_json::Map::new();
            if let Some(title) = request.title.as_ref() {
                body.insert("title".into(), json!(title));
            }
            if let Some(value) = request.body.as_ref() {
                body.insert("body".into(), json!(value));
            }
            if let Some(base) = request.base.as_ref() {
                body.insert("base".into(), json!(base));
            }
            if let Some(state) = request.state.as_ref() {
                if !matches!(state.as_str(), "open" | "closed") {
                    return Err(invalid_field("state"));
                }
                body.insert("state".into(), json!(state));
            }
            if body.is_empty() {
                return Err(invalid_field("updatePullRequest fields"));
            }
            pull_request_plan(&request, "PATCH", "", Some(Value::Object(body)))?
        }
        "listPullRequestFiles" => pull_request_plan(&request, "GET", "/files", None)?,
        "listPullRequestComments" => {
            let repository = repository_path(&request)?;
            let number = pull_number(&request)?;
            (
                GitHubHost::Api,
                "GET",
                format!("/repos/{repository}/issues/{number}/comments"),
                None,
                true,
            )
        }
        "createPullRequestComment" => {
            let repository = repository_path(&request)?;
            let number = pull_number(&request)?;
            let body = required_text(request.body.as_deref(), "body")?;
            (
                GitHubHost::Api,
                "POST",
                format!("/repos/{repository}/issues/{number}/comments"),
                Some(json!({"body": body})),
                true,
            )
        }
        "createPullRequestReview" => {
            let event = required_text(request.event.as_deref(), "event")?.to_ascii_uppercase();
            if !matches!(event.as_str(), "APPROVE" | "REQUEST_CHANGES" | "COMMENT") {
                return Err(invalid_field("event"));
            }
            let body = request.body.as_deref().unwrap_or_default();
            if event == "REQUEST_CHANGES" && body.trim().is_empty() {
                return Err(invalid_field("body"));
            }
            pull_request_plan(
                &request,
                "POST",
                "/reviews",
                Some(json!({"event": event, "body": body})),
            )?
        }
        "mergePullRequest" => {
            let method = request.merge_method.as_deref().unwrap_or("squash");
            if !matches!(method, "merge" | "squash" | "rebase") {
                return Err(invalid_field("mergeMethod"));
            }
            pull_request_plan(
                &request,
                "PUT",
                "/merge",
                Some(json!({"merge_method": method})),
            )?
        }
        "updatePullRequestMetadata" => {
            let repository = repository_path(&request)?;
            let number = pull_number(&request)?;
            let labels = request.labels.unwrap_or_default();
            let assignees = request.assignees.unwrap_or_default();
            (
                GitHubHost::Api,
                "PATCH",
                format!("/repos/{repository}/issues/{number}"),
                Some(json!({"labels": labels, "assignees": assignees})),
                true,
            )
        }
        _ => {
            return Err(
                CoreError::new(ErrorCode::NotSupported, "Unsupported GitHub operation")
                    .with_details(request.operation),
            )
        }
    };
    Ok(GitHubRequestPlan {
        host,
        method: method.to_string(),
        path,
        query,
        body: body.map(|value| value.to_string()),
        requires_authentication,
    })
}

/// Normalizes one GitHub HTTP response or returns a stable cross-platform error.
pub fn normalize_response(request: NormalizeResponseRequest) -> Result<Value, CoreError> {
    let value = if request.body.trim().is_empty() {
        Value::Null
    } else {
        serde_json::from_str::<Value>(&request.body).map_err(|error| {
            CoreError::new(ErrorCode::ParseFailed, "GitHub returned invalid JSON")
                .with_details(error.to_string())
        })?
    };
    if !(200..300).contains(&request.status) {
        return Err(response_error(request.status, &value));
    }
    match request.operation.as_str() {
        "deviceCode" => normalize_device_code(value),
        "deviceToken" => normalize_device_token(value),
        "currentUser" => Ok(serde_json::to_value(normalize_user(&value)?).expect("user encodes")),
        "listBranches" => normalize_branch_list(value),
        "compareBranches" => normalize_comparison(value),
        "listPullRequests" => normalize_pull_request_list(value),
        "getPullRequest" | "createPullRequest" | "updatePullRequest" => Ok(serde_json::to_value(
            normalize_pull_request(&value)?,
        )
        .expect("pull request encodes")),
        "listPullRequestFiles" => normalize_file_list(value),
        "listPullRequestComments" => normalize_comment_list(value),
        "createPullRequestComment" => {
            Ok(serde_json::to_value(normalize_comment(&value)?).expect("comment encodes"))
        }
        "createPullRequestReview" | "updatePullRequestMetadata" => Ok(value),
        "mergePullRequest" => normalize_merge(value),
        _ => Err(CoreError::new(
            ErrorCode::NotSupported,
            "Unsupported GitHub response operation",
        )
        .with_details(request.operation)),
    }
}

fn repository_path(request: &RequestPlanRequest) -> Result<String, CoreError> {
    request
        .repository
        .as_ref()
        .ok_or_else(|| invalid_field("repository"))?
        .path()
}

fn pull_number(request: &RequestPlanRequest) -> Result<u64, CoreError> {
    request
        .pull_number
        .filter(|number| *number > 0)
        .ok_or_else(|| invalid_field("pullNumber"))
}

fn pull_request_plan<'a>(
    request: &RequestPlanRequest,
    method: &'a str,
    suffix: &str,
    body: Option<Value>,
) -> Result<(GitHubHost, &'a str, String, Option<Value>, bool), CoreError> {
    let repository = repository_path(request)?;
    let number = pull_number(request)?;
    Ok((
        GitHubHost::Api,
        method,
        format!("/repos/{repository}/pulls/{number}{suffix}"),
        body,
        true,
    ))
}

fn required_text<'a>(value: Option<&'a str>, field: &str) -> Result<&'a str, CoreError> {
    value
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| invalid_field(field))
}

fn invalid_field(field: &str) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, "Invalid GitHub request").with_details(field)
}

fn validate_repository_component(value: &str, field: &str) -> Result<(), CoreError> {
    let valid = !value.is_empty()
        && value.len() <= 100
        && !matches!(value, "." | "..")
        && value.chars().all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '-' | '_' | '.')
        });
    if valid {
        Ok(())
    } else {
        Err(invalid_field(field))
    }
}

fn normalize_device_code(value: Value) -> Result<Value, CoreError> {
    let object = object(&value)?;
    Ok(json!({
        "deviceCode": text(object, "device_code")?,
        "userCode": text(object, "user_code")?,
        "verificationURI": text(object, "verification_uri")?,
        "expiresIn": integer(object, "expires_in")?,
        "interval": integer(object, "interval")?
    }))
}

fn normalize_device_token(value: Value) -> Result<Value, CoreError> {
    let object = object(&value)?;
    if let Some(token) = object.get("access_token").and_then(Value::as_str) {
        return Ok(json!({
            "status": "authorized",
            "accessToken": token,
            "tokenType": object.get("token_type").and_then(Value::as_str).unwrap_or("bearer"),
            "scope": object.get("scope").and_then(Value::as_str).unwrap_or("")
        }));
    }
    let error = object
        .get("error")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let status = match error {
        "authorization_pending" => "pending",
        "slow_down" => "slowDown",
        "expired_token" => "expired",
        "access_denied" => "denied",
        _ => "failed",
    };
    Ok(json!({
        "status": status,
        "error": error,
        "message": object.get("error_description").and_then(Value::as_str),
        "interval": object.get("interval").and_then(Value::as_u64)
    }))
}

fn normalize_pull_request_list(value: Value) -> Result<Value, CoreError> {
    let array = value.as_array().ok_or_else(parse_shape_error)?;
    let mut requests = array
        .iter()
        .map(normalize_pull_request)
        .collect::<Result<Vec<_>, _>>()?;
    requests.sort_by(|left, right| right.number.cmp(&left.number));
    Ok(serde_json::to_value(requests).expect("pull request list encodes"))
}

fn normalize_branch_list(value: Value) -> Result<Value, CoreError> {
    let array = value.as_array().ok_or_else(parse_shape_error)?;
    let mut branches = array
        .iter()
        .map(|value| {
            let object = object(value)?;
            Ok(GitHubBranch {
                name: text(object, "name")?.to_string(),
            })
        })
        .collect::<Result<Vec<_>, CoreError>>()?;
    branches.sort_by(|left, right| left.name.cmp(&right.name));
    branches.dedup_by(|left, right| left.name == right.name);
    Ok(serde_json::to_value(branches).expect("branch list encodes"))
}

fn normalize_pull_request(value: &Value) -> Result<GitHubPullRequest, CoreError> {
    let object = object(value)?;
    let mut labels = object
        .get("labels")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|label| {
            let object = label.as_object()?;
            Some(GitHubLabel {
                name: object.get("name")?.as_str()?.to_string(),
                color: object
                    .get("color")
                    .and_then(Value::as_str)
                    .map(str::to_string),
            })
        })
        .collect::<Vec<_>>();
    labels.sort_by(|left, right| left.name.cmp(&right.name));
    let mut assignees = object
        .get("assignees")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .map(normalize_user)
        .collect::<Result<Vec<_>, _>>()?;
    assignees.sort_by(|left, right| left.login.cmp(&right.login));
    let head = object
        .get("head")
        .and_then(Value::as_object)
        .ok_or_else(parse_shape_error)?;
    let base = object
        .get("base")
        .and_then(Value::as_object)
        .ok_or_else(parse_shape_error)?;
    Ok(GitHubPullRequest {
        number: integer(object, "number")?,
        title: text(object, "title")?.to_string(),
        body: object
            .get("body")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        state: text(object, "state")?.to_string(),
        is_draft: object
            .get("draft")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        url: text(object, "html_url")?.to_string(),
        author: normalize_user(object.get("user").ok_or_else(parse_shape_error)?)?,
        head_ref: text(head, "ref")?.to_string(),
        head_repository: head
            .get("repo")
            .and_then(Value::as_object)
            .and_then(|repo| repo.get("full_name"))
            .and_then(Value::as_str)
            .map(str::to_string),
        base_ref: text(base, "ref")?.to_string(),
        base_repository: base
            .get("repo")
            .and_then(Value::as_object)
            .and_then(|repo| repo.get("full_name"))
            .and_then(Value::as_str)
            .map(str::to_string),
        created_at: text(object, "created_at")?.to_string(),
        updated_at: text(object, "updated_at")?.to_string(),
        is_merged: object
            .get("merged")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        is_mergeable: object.get("mergeable").and_then(Value::as_bool),
        additions: object.get("additions").and_then(Value::as_u64),
        deletions: object.get("deletions").and_then(Value::as_u64),
        changed_files: object.get("changed_files").and_then(Value::as_u64),
        comments_count: object.get("comments").and_then(Value::as_u64).unwrap_or(0),
        labels,
        assignees,
    })
}

fn normalize_user(value: &Value) -> Result<GitHubUser, CoreError> {
    let object = object(value)?;
    Ok(GitHubUser {
        login: text(object, "login")?.to_string(),
        url: object
            .get("html_url")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        avatar_url: object
            .get("avatar_url")
            .and_then(Value::as_str)
            .map(str::to_string),
    })
}

fn normalize_comment_list(value: Value) -> Result<Value, CoreError> {
    let array = value.as_array().ok_or_else(parse_shape_error)?;
    let mut comments = array
        .iter()
        .map(normalize_comment)
        .collect::<Result<Vec<_>, _>>()?;
    comments.sort_by_key(|comment| comment.id);
    Ok(serde_json::to_value(comments).expect("comment list encodes"))
}

fn normalize_comment(value: &Value) -> Result<GitHubComment, CoreError> {
    let object = object(value)?;
    Ok(GitHubComment {
        id: integer(object, "id")?,
        author: normalize_user(object.get("user").ok_or_else(parse_shape_error)?)?,
        body: text(object, "body")?.to_string(),
        created_at: text(object, "created_at")?.to_string(),
        updated_at: text(object, "updated_at")?.to_string(),
        url: object
            .get("html_url")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
    })
}

fn normalize_file_list(value: Value) -> Result<Value, CoreError> {
    let array = value.as_array().ok_or_else(parse_shape_error)?;
    let mut files = array
        .iter()
        .map(|value| {
            let object = object(value)?;
            Ok(GitHubPullRequestFile {
                path: text(object, "filename")?.to_string(),
                status: text(object, "status")?.to_string(),
                additions: integer(object, "additions")?,
                deletions: integer(object, "deletions")?,
                patch: object
                    .get("patch")
                    .and_then(Value::as_str)
                    .map(str::to_string),
            })
        })
        .collect::<Result<Vec<_>, CoreError>>()?;
    files.sort_by(|left, right| left.path.cmp(&right.path));
    Ok(serde_json::to_value(files).expect("file list encodes"))
}

fn normalize_comparison(value: Value) -> Result<Value, CoreError> {
    let comparison = object(&value)?;
    let commits = comparison
        .get("commits")
        .and_then(Value::as_array)
        .ok_or_else(parse_shape_error)?
        .iter()
        .map(|value| {
            let object = object(value)?;
            let commit = object
                .get("commit")
                .and_then(Value::as_object)
                .ok_or_else(parse_shape_error)?;
            Ok(GitHubComparisonCommit {
                sha: text(object, "sha")?.to_string(),
                message: text(commit, "message")?.to_string(),
            })
        })
        .collect::<Result<Vec<_>, CoreError>>()?;
    let files_value = comparison
        .get("files")
        .cloned()
        .unwrap_or_else(|| Value::Array(Vec::new()));
    let files =
        serde_json::from_value::<Vec<GitHubPullRequestFile>>(normalize_file_list(files_value)?)
            .map_err(|error| {
                CoreError::new(
                    ErrorCode::ParseFailed,
                    "GitHub returned an unexpected response",
                )
                .with_details(error.to_string())
            })?;
    Ok(serde_json::to_value(GitHubComparison { commits, files })
        .expect("comparison response encodes"))
}

fn encode_path_component(value: &str) -> String {
    let mut encoded = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            encoded.push(char::from(byte));
        } else {
            encoded.push_str(&format!("%{byte:02X}"));
        }
    }
    encoded
}

fn normalize_merge(value: Value) -> Result<Value, CoreError> {
    let object = object(&value)?;
    Ok(json!({
        "merged": object.get("merged").and_then(Value::as_bool).unwrap_or(false),
        "message": object.get("message").and_then(Value::as_str).unwrap_or(""),
        "sha": object.get("sha").and_then(Value::as_str)
    }))
}

fn response_error(status: u16, value: &Value) -> CoreError {
    let message = value
        .as_object()
        .and_then(|object| object.get("message"))
        .and_then(Value::as_str)
        .unwrap_or("GitHub request failed");
    let code = match status {
        401 | 403 => ErrorCode::PermissionDenied,
        400 | 404 | 409 | 422 => ErrorCode::InvalidRequest,
        _ => ErrorCode::Unknown,
    };
    CoreError::new(code, message).with_details(format!("httpStatus={status}"))
}

fn object(value: &Value) -> Result<&serde_json::Map<String, Value>, CoreError> {
    value.as_object().ok_or_else(parse_shape_error)
}

fn text<'a>(object: &'a serde_json::Map<String, Value>, key: &str) -> Result<&'a str, CoreError> {
    object
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(parse_shape_error)
}

fn integer(object: &serde_json::Map<String, Value>, key: &str) -> Result<u64, CoreError> {
    object
        .get(key)
        .and_then(Value::as_u64)
        .ok_or_else(parse_shape_error)
}

fn parse_shape_error() -> CoreError {
    CoreError::new(
        ErrorCode::ParseFailed,
        "GitHub response did not match the expected shape",
    )
}
