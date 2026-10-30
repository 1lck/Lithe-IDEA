//! 字体安装。
//!
//! 本轮不复制字体二进制：只把主题字体族设成 Inter / JetBrains Mono，由 GPUI
//! 在字体缺失时回退到系统字体。

use gpui_kit::App;
use gpui_kit::component::Theme;
use gpui_kit::px;

use crate::LitheMetrics;

pub const UI_FONT_FAMILY: &str = "Inter";
pub const MONO_FONT_FAMILY: &str = "JetBrains Mono";

pub fn install_fonts(cx: &mut App) {
    Theme::update(cx, |theme| {
        theme.font_family = UI_FONT_FAMILY.into();
        theme.mono_font_family = MONO_FONT_FAMILY.into();
        theme.font_size = px(LitheMetrics::UI_FONT_SIZE);
        theme.mono_font_size = px(LitheMetrics::CODE_FONT_SIZE);
    });

    // TODO: 打包阶段把 Inter / JetBrains Mono 的字体文件注册进 `TextSystem`
    // （例如 `cx.text_system().add_fonts(...)`）。在此之前依赖系统已安装字体，
    // 缺失时 GPUI 会回退到系统 UI / 等宽字体，不影响布局。
}
