//! 全局字体：内嵌 JetBrains Mono，并把它设为工作台的默认字体族。
//!
//! 内嵌而不依赖系统安装，保证任意 Linux 机器上 UI、编辑器与终端字体一致，
//! 不会因缺字体悄悄回退到别的族。字体以 SIL OFL 1.1 分发，许可证见
//! `assets/fonts/OFL.txt`。
//!
//! Note: 内嵌理由、字体族唯一来源与主题切换后的重设要求见
//! `.agents/notes/implemented/feature/2026-09-26-linux-bundled-jetbrains-mono-default-font.md`。

use std::borrow::Cow;

use gpui_kit::component::Theme;
use gpui_kit::{App, SharedString};

/// 内嵌字体族名，也是全局 UI 默认字体与编辑器/等宽字体的出厂默认值。
pub const FAMILY: &str = "JetBrains Mono";

const REGULAR: &[u8] = include_bytes!("../assets/fonts/JetBrainsMono-Regular.ttf");
const BOLD: &[u8] = include_bytes!("../assets/fonts/JetBrainsMono-Bold.ttf");
const ITALIC: &[u8] = include_bytes!("../assets/fonts/JetBrainsMono-Italic.ttf");
const BOLD_ITALIC: &[u8] = include_bytes!("../assets/fonts/JetBrainsMono-BoldItalic.ttf");

/// 把内嵌字体注册进 GPUI 文本系统。
///
/// 注册失败只降级为系统回退字体，不阻断启动；粗体/斜体用于代码与终端样式。
pub fn register(cx: &App) {
    let fonts = vec![
        Cow::Borrowed(&REGULAR[..]),
        Cow::Borrowed(&BOLD[..]),
        Cow::Borrowed(&ITALIC[..]),
        Cow::Borrowed(&BOLD_ITALIC[..]),
    ];
    if let Err(error) = cx.text_system().add_fonts(fonts) {
        tracing::warn!("failed to register bundled JetBrains Mono: {error}");
    }
}

/// 把 UI 字体与等宽字体族装回主题。
///
/// UI 用内嵌的 [`FAMILY`] 作为全局默认；等宽家族跟随设置里的「编辑器字体」，
/// 这样设置弹窗的选择会真正作用到编辑器、代码显示与终端。必须在每次
/// `Theme::change` **之后**调用：`change` 会按当前主题重新应用配置并可能覆盖
/// 字体字段。
pub fn apply_theme(cx: &mut App) {
    let mono = mono_family(cx);
    let theme = Theme::global_mut(cx);
    theme.font_family = FAMILY.into();
    theme.mono_font_family = mono;
}

/// 当前生效的等宽字体族：编辑器、代码显示与终端共用。
///
/// 来源是设置 `fontFamily`（默认 [`FAMILY`]）；为空时回退到内嵌默认字体，
/// 保证任何情况下都是可用的等宽字体。
pub fn mono_family(cx: &App) -> SharedString {
    let configured = crate::settings::get(cx).font_family.trim();
    if configured.is_empty() {
        FAMILY.into()
    } else {
        SharedString::from(configured.to_string())
    }
}
