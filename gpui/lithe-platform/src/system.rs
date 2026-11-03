//! 系统级外观、shell 等桌面能力的查询。
//!
//! 这里只用标准库进程调用（不新增原生依赖），因此结果「尽力而为」：拿不到
//! 就返回 `None`，由调用方保持当前状态。GPUI 侧只消费结果；平台差异全部
//! 收敛在本文件的三组 `cfg` 块里。
//!
//! 三平台实现思路（与 plan-01 §4.2 一致）：
//! - Windows：`reg query` 读 `AppsUseLightTheme`（0 = 深色应用界面）。
//! - macOS：`defaults read -g AppleInterfaceStyle` 输出 `Dark` 即深色；键不存在
//!   （退出码非 0，Light 系统）时无法与命令失败区分，保守返回 `None`。
//! - Linux：`gsettings get org.gnome.desktop.interface color-scheme` 输出
//!   `'prefer-dark'` 即深色；未装 gsettings 或其它桌面返回 `None`。

use std::process::Command;

/// 系统 UI 的深浅色。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DarkMode {
    Light,
    Dark,
}

/// 查询系统当前外观；不可用时返回 `None`，调用方保留现有深浅色。
pub fn system_appearance() -> Option<DarkMode> {
    #[cfg(target_os = "windows")]
    {
        windows_appearance()
    }
    #[cfg(target_os = "macos")]
    {
        macos_appearance()
    }
    #[cfg(target_os = "linux")]
    {
        linux_appearance()
    }
    #[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "linux")))]
    {
        None
    }
}

#[cfg(target_os = "windows")]
fn windows_appearance() -> Option<DarkMode> {
    let output = Command::new("reg")
        .args([
            "query",
            r"HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
            "/v",
            "AppsUseLightTheme",
        ])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&output.stdout);
    // 查询输出包含 `AppsUseLightTheme REG_DWORD 0x0/0x1`。
    if text.contains("0x1") {
        Some(DarkMode::Light)
    } else if text.contains("0x0") {
        Some(DarkMode::Dark)
    } else {
        None
    }
}

#[cfg(target_os = "macos")]
fn macos_appearance() -> Option<DarkMode> {
    let output = Command::new("defaults")
        .args(["read", "-g", "AppleInterfaceStyle"])
        .output()
        .ok()?;
    if !output.status.success() {
        // 键不存在 = Light，但与命令异常无法区分：不上报，让调用方保留原值。
        return None;
    }
    let text = String::from_utf8_lossy(&output.stdout);
    if text.to_ascii_lowercase().contains("dark") {
        Some(DarkMode::Dark)
    } else {
        // Light 系统该键通常不存在；输出其他值时同样保守处理。
        None
    }
}

#[cfg(target_os = "linux")]
fn linux_appearance() -> Option<DarkMode> {
    let output = Command::new("gsettings")
        .args(["get", "org.gnome.desktop.interface", "color-scheme"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&output.stdout);
    if text.contains("prefer-dark") {
        Some(DarkMode::Dark)
    } else if text.contains("prefer-light") {
        Some(DarkMode::Light)
    } else {
        None
    }
}
