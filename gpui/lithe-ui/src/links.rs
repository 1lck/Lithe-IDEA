//! 对外链接的唯一常量入口。
//!
//! 真源以仓库 `origin` 远端为准（`git remote -v` 为
//! `https://github.com/1lck/Lithe-IDEA.git`），并与 Tauri 的
//! `windows/tauri/src/config/services.json` 保持一致：
//! 仓库地址为 `1lck/Lithe-IDEA`，文档站为 `https://lithe.top/docs`。
//!
//! 菜单、设置页和更新检查统一从这里取链接，不在调用处重复写死字符串；
//! 后续更换仓库或站点只需改这一个文件。

/// GitHub 仓库所有者。
pub const REPOSITORY_OWNER: &str = "1lck";

/// GitHub 仓库名。
pub const REPOSITORY_NAME: &str = "Lithe-IDEA";

/// 仓库主页。
pub const REPOSITORY_URL: &str = "https://github.com/1lck/Lithe-IDEA";

/// 全部发布页。
pub const RELEASES_URL: &str = "https://github.com/1lck/Lithe-IDEA/releases";

/// 最新正式发布页（Tauri `stable` 通道的下载入口）。
pub const LATEST_RELEASE_URL: &str = "https://github.com/1lck/Lithe-IDEA/releases/latest";

/// Auto Build 发布页（Tauri `autobuild` 通道的下载入口）。
pub const AUTOBUILD_RELEASE_URL: &str = "https://github.com/1lck/Lithe-IDEA/releases/tag/AutoBuild";

/// 更新日志。
pub const CHANGELOG_URL: &str = "https://github.com/1lck/Lithe-IDEA/blob/preview/CHANGELOG.md";

/// Bug 报告表单（模板名与 Tauri 对齐）。
pub const BUG_REPORT_URL: &str =
    "https://github.com/1lck/Lithe-IDEA/issues/new?template=01-bug.yml";

/// 功能请求表单（模板名与 Tauri 对齐）。
pub const FEATURE_REQUEST_URL: &str =
    "https://github.com/1lck/Lithe-IDEA/issues/new?template=02-feature.yml";

/// 文档站（对齐 Tauri `services.docsUrl`）。
pub const DOCS_URL: &str = "https://lithe.top/docs";

/// GitHub Releases API：最新正式发布。
pub const LATEST_RELEASE_API_URL: &str =
    "https://api.github.com/repos/1lck/Lithe-IDEA/releases/latest";

/// 拼出某个版本对应的发布页标签地址。
///
/// 与 Tauri 的 `${githubReleasesBaseUrl}/tag/v${version}` 一致：
/// 传入带 `v` 前缀或不带前缀的版本号都得到同一条地址。
pub fn release_tag_url(version: &str) -> String {
    let trimmed = version.trim();
    let tag = if trimmed.starts_with('v') || trimmed.starts_with('V') {
        trimmed.to_string()
    } else {
        format!("v{trimmed}")
    };
    format!("{RELEASES_URL}/tag/{tag}")
}

#[cfg(test)]
mod tests {
    use super::release_tag_url;

    #[test]
    fn release_tag_url_normalizes_version_prefix() {
        assert_eq!(
            release_tag_url("1.2.3"),
            "https://github.com/1lck/Lithe-IDEA/releases/tag/v1.2.3"
        );
        assert_eq!(
            release_tag_url("v1.2.3"),
            "https://github.com/1lck/Lithe-IDEA/releases/tag/v1.2.3"
        );
    }
}
