//! 更新检查：查询 GitHub Releases 并按版本号给出真实结果。
//!
//! 行为对齐 Tauri 的 `windows/tauri/src/features/settings/stores/update.store.ts`：
//! 稳定通道查询最新正式发布并与当前版本比较；Auto Build 通道没有单调递增的
//! 版本号，因此与 Tauri 一样走发布页手动下载。网络失败、限流、无发布、响应
//! 不合法都会返回具体原因，绝不伪造“已是最新”。
//!
//! 阻塞式 HTTP 请求必须在 `cx.background_spawn` 中执行，视图线程只合并在结果。

use std::cmp::Ordering;
use std::time::Duration;

use lithe_ui::i18n::tr;
use lithe_ui::links;

/// 单次更新检查的超时时间。
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);

/// GitHub API 要求提供 User-Agent。
const USER_AGENT: &str = concat!("Lithe-GPUI/", env!("CARGO_PKG_VERSION"));

/// 当前构建版本（与设置页、About 显示一致）。
pub const CURRENT_VERSION: &str = env!("CARGO_PKG_VERSION");

/// 一次更新检查的结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UpdateCheckOutcome {
    /// 发布源存在比当前构建更新的版本。
    Available(UpdateRelease),
    /// 当前构建已经是发布源上的最新版本。
    UpToDate,
    /// 该通道只能从发布页手动下载，未做版本比较。
    ManualDownload { release_url: String },
    /// 检查失败，携带面向用户的具体原因。
    Failed(UpdateCheckFailure),
}

/// 发布源上的新版本信息，字段与 Tauri 的 `UpdateInfo` 对齐。
// 部分字段对齐 Tauri 数据模型，供后续更新详情 UI 使用。
#[allow(dead_code)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UpdateRelease {
    pub current_version: String,
    pub target_version: String,
    pub release_date: Option<String>,
    pub release_notes: Option<String>,
    pub release_url: String,
}

/// 更新检查失败的分类，`code` 与 Tauri 的错误码保持一致。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UpdateCheckFailureKind {
    /// 发布源没有正式发布。
    NoPublishedRelease,
    /// GitHub 共享 API 限流。
    RateLimited,
    /// 其他非成功 HTTP 状态。
    HttpStatus,
    /// 请求超时。
    TimedOut,
    /// 无法建立连接或读取响应。
    ConnectionFailed,
    /// 响应内容不是预期的发布 JSON。
    InvalidResponse,
}

impl UpdateCheckFailureKind {
    /// 稳定的错误码，与 Tauri `UpdateErrorCode` 同名。
    #[allow(dead_code)]
    pub fn code(self) -> &'static str {
        match self {
            Self::NoPublishedRelease => "no_published_release",
            Self::RateLimited => "rate_limited",
            Self::HttpStatus => "http_status",
            Self::TimedOut => "timed_out",
            Self::ConnectionFailed => "connection_failed",
            Self::InvalidResponse => "invalid_response",
        }
    }
}

/// 更新检查失败，`detail` 是上游诊断信息（不翻译）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UpdateCheckFailure {
    pub kind: UpdateCheckFailureKind,
    pub detail: String,
}

impl UpdateCheckFailure {
    fn new(kind: UpdateCheckFailureKind, detail: impl Into<String>) -> Self {
        Self {
            kind,
            detail: detail.into(),
        }
    }

    /// 面向用户的具体失败原因。
    pub fn message(&self) -> String {
        match self.kind {
            UpdateCheckFailureKind::NoPublishedRelease => {
                tr("No published release is available yet.").to_string()
            }
            UpdateCheckFailureKind::RateLimited => tr(
                "GitHub rejected the update request because a shared API limit was reached. \
                 Open the Release page or try again after the limit resets.",
            )
            .to_string(),
            UpdateCheckFailureKind::HttpStatus => {
                tr("The update server returned HTTP {status}.").replace("{status}", &self.detail)
            }
            UpdateCheckFailureKind::TimedOut => {
                tr("The update request timed out. Try again later.").to_string()
            }
            UpdateCheckFailureKind::ConnectionFailed => {
                tr("Could not reach the update server: {detail}")
                    .replace("{detail}", &self.detail)
            }
            UpdateCheckFailureKind::InvalidResponse => {
                tr("The update server returned an unexpected response.").to_string()
            }
        }
    }
}

/// 所选通道对应的发布页地址，供“打开下载页”按钮复用。
pub fn release_page_url(channel: &str) -> &'static str {
    if channel.eq_ignore_ascii_case("autobuild") {
        links::AUTOBUILD_RELEASE_URL
    } else {
        links::LATEST_RELEASE_URL
    }
}

/// 执行一次更新检查。阻塞，调用方必须放到后台线程。
pub fn check_for_updates(channel: &str) -> UpdateCheckOutcome {
    if channel.eq_ignore_ascii_case("autobuild") {
        return UpdateCheckOutcome::ManualDownload {
            release_url: links::AUTOBUILD_RELEASE_URL.to_string(),
        };
    }

    let client = match reqwest::blocking::Client::builder()
        .timeout(REQUEST_TIMEOUT)
        .user_agent(USER_AGENT)
        .build()
    {
        Ok(client) => client,
        Err(error) => {
            return UpdateCheckOutcome::Failed(UpdateCheckFailure::new(
                UpdateCheckFailureKind::ConnectionFailed,
                short_detail(&error.to_string()),
            ));
        }
    };

    let response = match client
        .get(links::LATEST_RELEASE_API_URL)
        .header(reqwest::header::ACCEPT, "application/vnd.github+json")
        .send()
    {
        Ok(response) => response,
        Err(error) => {
            let kind = if error.is_timeout() {
                UpdateCheckFailureKind::TimedOut
            } else {
                UpdateCheckFailureKind::ConnectionFailed
            };
            return UpdateCheckOutcome::Failed(UpdateCheckFailure::new(
                kind,
                short_detail(&error.to_string()),
            ));
        }
    };

    let status = response.status();
    if !status.is_success() {
        let failure = failure_for_status(status, response.headers());
        return UpdateCheckOutcome::Failed(failure);
    }

    let body = match response.text() {
        Ok(body) => body,
        Err(error) => {
            return UpdateCheckOutcome::Failed(UpdateCheckFailure::new(
                UpdateCheckFailureKind::ConnectionFailed,
                short_detail(&error.to_string()),
            ));
        }
    };

    match parse_latest_release(&body) {
        Ok(release) => {
            if is_newer(CURRENT_VERSION, &release.target_version) {
                UpdateCheckOutcome::Available(release)
            } else {
                UpdateCheckOutcome::UpToDate
            }
        }
        Err(failure) => UpdateCheckOutcome::Failed(failure),
    }
}

fn failure_for_status(
    status: reqwest::StatusCode,
    headers: &reqwest::header::HeaderMap,
) -> UpdateCheckFailure {
    if status == reqwest::StatusCode::NOT_FOUND {
        return UpdateCheckFailure::new(UpdateCheckFailureKind::NoPublishedRelease, "404");
    }
    let rate_limited = status == reqwest::StatusCode::TOO_MANY_REQUESTS
        || status == reqwest::StatusCode::FORBIDDEN
            && headers
                .get("x-ratelimit-remaining")
                .and_then(|value| value.to_str().ok())
                .is_some_and(|value| value.trim() == "0");
    if rate_limited {
        return UpdateCheckFailure::new(
            UpdateCheckFailureKind::RateLimited,
            status.as_u16().to_string(),
        );
    }
    UpdateCheckFailure::new(
        UpdateCheckFailureKind::HttpStatus,
        status.as_u16().to_string(),
    )
}

fn parse_latest_release(body: &str) -> Result<UpdateRelease, UpdateCheckFailure> {
    let value: serde_json::Value =
        serde_json::from_str(body).map_err(|_| invalid_response())?;
    if value.get("draft").and_then(|draft| draft.as_bool()) == Some(true) {
        return Err(UpdateCheckFailure::new(
            UpdateCheckFailureKind::NoPublishedRelease,
            "draft",
        ));
    }

    let tag = value
        .get("tag_name")
        .and_then(|tag| tag.as_str())
        .map(str::trim)
        .filter(|tag| !tag.is_empty())
        .ok_or_else(invalid_response)?;
    let target_version = normalize_version(tag).ok_or_else(invalid_response)?;

    let release_url = value
        .get("html_url")
        .and_then(|url| url.as_str())
        .map(str::trim)
        .filter(|url| url.starts_with("https://"))
        .map(str::to_string)
        .unwrap_or_else(|| links::release_tag_url(&target_version));

    let release_date = value
        .get("published_at")
        .and_then(|date| date.as_str())
        .map(str::trim)
        .filter(|date| !date.is_empty())
        .map(str::to_string);

    let release_notes = value
        .get("body")
        .and_then(|body| body.as_str())
        .map(str::trim)
        .filter(|body| !body.is_empty())
        .map(str::to_string);

    Ok(UpdateRelease {
        current_version: CURRENT_VERSION.to_string(),
        target_version,
        release_date,
        release_notes,
        release_url,
    })
}

fn invalid_response() -> UpdateCheckFailure {
    UpdateCheckFailure::new(UpdateCheckFailureKind::InvalidResponse, String::new())
}

/// 去掉可选的 `v` 前缀并校验基本版本格式。
fn normalize_version(version: &str) -> Option<String> {
    let trimmed = version.trim();
    let trimmed = trimmed
        .strip_prefix('v')
        .or_else(|| trimmed.strip_prefix('V'))
        .unwrap_or(trimmed);
    parse_version(trimmed).map(|_| trimmed.to_string())
}

/// 比较两个版本号；无法解析时返回 `None`。
pub fn compare_versions(left: &str, right: &str) -> Option<Ordering> {
    let (left_core, left_pre) = parse_version(left)?;
    let (right_core, right_pre) = parse_version(right)?;

    let max_len = left_core.len().max(right_core.len());
    for index in 0..max_len {
        let left = left_core.get(index).copied().unwrap_or(0);
        let right = right_core.get(index).copied().unwrap_or(0);
        match left.cmp(&right) {
            Ordering::Equal => {}
            ordering => return Some(ordering),
        }
    }

    match (left_pre, right_pre) {
        (None, None) => Some(Ordering::Equal),
        // 正式版本高于同号预发布版本。
        (None, Some(_)) => Some(Ordering::Greater),
        (Some(_), None) => Some(Ordering::Less),
        (Some(left), Some(right)) => Some(left.cmp(&right)),
    }
}

fn is_newer(current: &str, candidate: &str) -> bool {
    compare_versions(current, candidate) == Some(Ordering::Less)
}

fn parse_version(version: &str) -> Option<(Vec<u64>, Option<String>)> {
    let trimmed = version.trim();
    let trimmed = trimmed
        .strip_prefix('v')
        .or_else(|| trimmed.strip_prefix('V'))
        .unwrap_or(trimmed);
    if trimmed.is_empty() {
        return None;
    }
    let (core, pre) = match trimmed.split_once('-') {
        Some((core, pre)) if !pre.is_empty() => (core, Some(pre.to_ascii_lowercase())),
        Some(_) => return None,
        None => (trimmed, None),
    };
    let mut numbers = Vec::new();
    for part in core.split('.') {
        let digits: String = part.chars().take_while(|ch| ch.is_ascii_digit()).collect();
        if digits.is_empty() {
            return None;
        }
        numbers.push(digits.parse().ok()?);
    }
    if numbers.is_empty() {
        return None;
    }
    Some((numbers, pre))
}

fn short_detail(detail: &str) -> String {
    const LIMIT: usize = 200;
    let compact = detail.split_whitespace().collect::<Vec<_>>().join(" ");
    if compact.chars().count() <= LIMIT {
        compact
    } else {
        let truncated: String = compact.chars().take(LIMIT).collect();
        format!("{truncated}…")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compares_release_versions() {
        assert_eq!(compare_versions("1.2.3", "1.2.4"), Some(Ordering::Less));
        assert_eq!(compare_versions("1.2.3", "1.2.3"), Some(Ordering::Equal));
        assert_eq!(compare_versions("1.10.0", "1.9.9"), Some(Ordering::Greater));
        assert_eq!(compare_versions("v1.2", "1.2.0"), Some(Ordering::Equal));
    }

    #[test]
    fn prerelease_ranks_below_release() {
        assert_eq!(compare_versions("1.2.3-beta.1", "1.2.3"), Some(Ordering::Less));
        assert_eq!(compare_versions("1.2.3", "1.2.3-beta.1"), Some(Ordering::Greater));
    }

    #[test]
    fn rejects_malformed_versions() {
        assert_eq!(compare_versions("not-a-version", "1.2.3"), None);
        assert_eq!(compare_versions("1..3", "1.2.3"), None);
    }

    #[test]
    fn parses_release_payload() {
        let body = r#"{
            "tag_name": "v1.4.0",
            "html_url": "https://github.com/1lck/Lithe-IDEA/releases/tag/v1.4.0",
            "published_at": "2026-10-01T00:00:00Z",
            "body": "Release notes",
            "draft": false
        }"#;
        let release = parse_latest_release(body).expect("release");
        assert_eq!(release.target_version, "1.4.0");
        assert_eq!(release.release_date.as_deref(), Some("2026-10-01T00:00:00Z"));
        assert_eq!(release.release_notes.as_deref(), Some("Release notes"));
    }

    #[test]
    fn rejects_payload_without_tag() {
        let failure = parse_latest_release(r#"{"draft": false}"#).expect_err("missing tag");
        assert_eq!(failure.kind, UpdateCheckFailureKind::InvalidResponse);
    }
}
