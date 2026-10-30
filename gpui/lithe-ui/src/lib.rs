//! Lithe 的 GPUI 基础 UI 层。
//!
//! 本 crate 只提供主题 token、字体、图标、i18n 静态表和 Phase 0 的共享控件；
//! 业务与布局分别属于 `lithe-features` 和 `lithe-workbench`。
//!
//! ```ignore
//! gpui_kit::init(cx);
//! lithe_ui::install_fonts(cx);
//! lithe_ui::install_theme(cx, LitheThemeKind::Lithe, true);
//! ```

// `#[derive(IntoElement)]` 生成的代码使用 `gpui::...` 路径；应用只依赖
// `gpui-kit` 时，需要把 Kit 本身别名为 `gpui`，否则派生代码找不到该 crate。
extern crate gpui_kit as gpui;

mod assets;
mod fonts;
mod i18n_zh;
pub mod icons;
mod metrics;
mod theme;
mod tokens;

pub mod components;
pub mod i18n;
pub mod shortcut;

pub use assets::{APP_LOGO_PATH, LitheAssets};
pub use fonts::{MONO_FONT_FAMILY, UI_FONT_FAMILY, install_fonts};
pub use i18n::{language, set_language, tr};
pub use icons::{LitheIcon, icon};
pub use metrics::LitheMetrics;
pub use theme::{current_tokens, install_theme, toggle_dark};
pub use tokens::{LitheThemeKind, LitheTokens};
