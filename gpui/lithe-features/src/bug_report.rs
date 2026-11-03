//! Bug 报告环境信息：生成与 Tauri 对齐的文本并写入剪贴板。
//!
//! 字段对齐 Tauri 的 `settings.general.bugReportTemplate`
//! （`windows/tauri/src/features/settings/components/tabs/general-settings.tsx`
//! 的 `buildBugReport`）：应用版本、平台、系统版本。GPUI 另补充架构与构建类型，
//! 便于排查平台相关问题。
//!
//! 报告正文保持英文：它会被粘贴到英文 GitHub Issue 模板里，属于提交的数据而不是
//! 界面控件文案，因此不参与界面翻译。

#[cfg(any(target_os = "macos", target_os = "windows"))]
use std::process::Command;

use gpui_kit::{App, ClipboardItem};

/// 当前构建版本，与设置页和 About 显示一致。
pub fn app_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

/// 收集到的环境信息。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnvironmentInfo {
    pub app_version: String,
    /// 与 Tauri `os.platform()` 相同的取值：`windows` / `macos` / `linux`。
    pub platform: String,
    pub os_version: String,
    /// 目标架构，例如 `x86_64`、`aarch64`。
    pub arch: String,
    pub development_build: bool,
}

/// 读取当前构建的环境信息。
pub fn environment_info() -> EnvironmentInfo {
    EnvironmentInfo {
        app_version: app_version().to_string(),
        platform: std::env::consts::OS.to_string(),
        os_version: os_version().unwrap_or_else(|| "unknown".to_string()),
        arch: std::env::consts::ARCH.to_string(),
        development_build: cfg!(debug_assertions),
    }
}

/// 生成完整的 Bug 报告文本，格式与 Tauri 模板一致并补充架构与构建类型。
pub fn environment_report() -> String {
    format_report(&environment_info())
}

/// 按给定环境信息生成报告文本（纯函数，便于测试）。
pub fn format_report(info: &EnvironmentInfo) -> String {
    let build = if info.development_build {
        "debug"
    } else {
        "release"
    };
    format!(
        "Environment\n\n\
         - App: Lithe {version}\n\
         - OS: {platform} {os_version}\n\
         - Arch: {arch}\n\
         - Build: {build}\n\n\
         Problem\n\n\
         Describe the issue here. Steps to reproduce, expected vs actual.\n",
        version = info.app_version,
        platform = info.platform,
        os_version = info.os_version,
        arch = info.arch,
        build = build,
    )
}

/// 把环境报告写入剪贴板，返回写入的文本，供调用方随后打开反馈页。
pub fn copy_environment_report(cx: &mut App) -> String {
    let report = environment_report();
    cx.write_to_clipboard(ClipboardItem::new_string(report.clone()));
    report
}

#[cfg(target_os = "macos")]
fn os_version() -> Option<String> {
    let output = Command::new("sw_vers")
        .arg("-productVersion")
        .output()
        .ok()?;
    let version = String::from_utf8(output.stdout).ok()?;
    let version = version.trim();
    (!version.is_empty()).then(|| version.to_string())
}

#[cfg(target_os = "windows")]
fn os_version() -> Option<String> {
    // 与 Tauri 的 Windows 版本展示一致，使用内核版本 10.0.<build>。
    let output = Command::new("reg")
        .args([
            "query",
            r"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion",
            "/v",
            "CurrentBuild",
        ])
        .output()
        .ok()?;
    let stdout = String::from_utf8(output.stdout).ok()?;
    let build = stdout
        .lines()
        .filter(|line| line.contains("REG_SZ") || line.contains("REG_DWORD"))
        .filter_map(|line| line.split_whitespace().last())
        .find(|token| token.chars().all(|ch| ch.is_ascii_digit()))?;
    Some(format!("10.0.{build}"))
}

#[cfg(target_os = "linux")]
fn os_version() -> Option<String> {
    let release = std::fs::read_to_string("/etc/os-release").ok()?;
    release
        .lines()
        .find_map(|line| line.strip_prefix("PRETTY_NAME="))
        .map(|value| value.trim_matches('"').to_string())
}

#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
fn os_version() -> Option<String> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn report_contains_aligned_fields() {
        let info = EnvironmentInfo {
            app_version: "0.1.0".to_string(),
            platform: "windows".to_string(),
            os_version: "10.0.26100".to_string(),
            arch: "x86_64".to_string(),
            development_build: true,
        };
        let report = format_report(&info);
        assert!(report.starts_with("Environment\n"));
        assert!(report.contains("- App: Lithe 0.1.0"));
        assert!(report.contains("- OS: windows 10.0.26100"));
        assert!(report.contains("- Arch: x86_64"));
        assert!(report.contains("- Build: debug"));
        assert!(report.contains("Problem\n"));
        assert!(report.ends_with('\n'));
    }
}
