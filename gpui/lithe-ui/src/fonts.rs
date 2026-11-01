//! 字体安装。
//!
//! 本轮不复制字体二进制：优先使用 Inter / JetBrains Mono，若系统没有安装，
//! 回退到平台实际提供的 UI / 等宽字体。日志按列对齐依赖真正的等宽字体，
//! 因此不能在缺少 JetBrains Mono 时回退到比例字体。

use std::sync::OnceLock;

use gpui_kit::component::Theme;
use gpui_kit::{App, px};

use crate::LitheMetrics;

pub const UI_FONT_FAMILY: &str = "Inter";
pub const MONO_FONT_FAMILY: &str = "JetBrains Mono";

/// UI 字体候选：优先 Inter，其次各平台常见无衬线字体。
const UI_CANDIDATES: &[&str] = &[
    "Inter",
    "Segoe UI",
    "Helvetica Neue",
    "Noto Sans",
    "DejaVu Sans",
    "Arial",
];

/// 等宽字体候选：优先 JetBrains Mono，其次各平台自带等宽字体。
#[cfg(target_os = "macos")]
const MONO_CANDIDATES: &[&str] = &[
    "JetBrains Mono",
    "SF Mono",
    "Menlo",
    "Monaco",
    "DejaVu Sans Mono",
    "Courier New",
];

/// 等宽字体候选：优先 JetBrains Mono，其次各平台自带等宽字体。
#[cfg(not(target_os = "macos"))]
const MONO_CANDIDATES: &[&str] = &[
    "JetBrains Mono",
    "Cascadia Mono",
    "Cascadia Code",
    "Consolas",
    "DejaVu Sans Mono",
    "Liberation Mono",
    "Noto Sans Mono",
    "Courier New",
];

static RESOLVED_UI_FONT: OnceLock<String> = OnceLock::new();
static RESOLVED_MONO_FONT: OnceLock<String> = OnceLock::new();

/// 实际安装到主题里的 UI 字体；`install_fonts` 运行前返回首选值。
pub fn ui_font_family() -> &'static str {
    RESOLVED_UI_FONT
        .get()
        .map_or(UI_FONT_FAMILY, String::as_str)
}

/// 实际安装到主题里的等宽字体；`install_fonts` 运行前返回首选值。
pub fn mono_font_family() -> &'static str {
    RESOLVED_MONO_FONT
        .get()
        .map_or(MONO_FONT_FAMILY, String::as_str)
}

fn first_available(available: &[String], candidates: &'static [&'static str]) -> &'static str {
    candidates
        .iter()
        .copied()
        .find(|candidate| {
            available
                .iter()
                .any(|name| name.eq_ignore_ascii_case(candidate))
        })
        .unwrap_or(candidates[0])
}

pub fn install_fonts(cx: &mut App) {
    let available = cx.text_system().all_font_names();
    // 只记录第一次解析结果：字体列表在进程内稳定，主题切换不应反复枚举。
    let ui = RESOLVED_UI_FONT.get_or_init(|| first_available(&available, UI_CANDIDATES).to_string());
    let mono =
        RESOLVED_MONO_FONT.get_or_init(|| first_available(&available, MONO_CANDIDATES).to_string());

    Theme::update(cx, |theme| {
        theme.font_family = (*ui).clone().into();
        theme.mono_font_family = (*mono).clone().into();
        theme.font_size = px(LitheMetrics::UI_FONT_SIZE);
        theme.mono_font_size = px(LitheMetrics::CODE_FONT_SIZE);
    });

    // TODO: 打包阶段把 Inter / JetBrains Mono 的字体文件注册进 `TextSystem`
    // （例如 `cx.text_system().add_fonts(...)`），让所有平台都使用同一套字体。
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_string()).collect()
    }

    #[test]
    fn picks_the_first_installed_candidate() {
        let available = names(&["Consolas", "Segoe UI"]);
        assert_eq!(first_available(&available, MONO_CANDIDATES), "Consolas");
        assert_eq!(first_available(&available, UI_CANDIDATES), "Segoe UI");
    }

    #[test]
    fn falls_back_to_the_preferred_family_when_nothing_matches() {
        let available = names(&["Some Unknown Font"]);
        assert_eq!(
            first_available(&available, MONO_CANDIDATES),
            MONO_CANDIDATES[0]
        );
        assert_eq!(first_available(&available, UI_CANDIDATES), UI_CANDIDATES[0]);
    }

    #[test]
    fn matching_ignores_ascii_case() {
        let available = names(&["consolas"]);
        assert_eq!(first_available(&available, MONO_CANDIDATES), "Consolas");
    }
}
