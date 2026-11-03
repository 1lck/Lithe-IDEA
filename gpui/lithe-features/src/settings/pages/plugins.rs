//! Plugins 页：依赖插件宿主落地，当前保持诚实状态卡。

use gpui_kit::{AnyElement, IntoElement, ParentElement as _, SharedString, Styled, div, px};
use lithe_ui::i18n::tr;
use lithe_ui::LitheTokens;

use crate::settings::controls::status_card;
use crate::settings::state::SETTINGS_SECTION_GAP;
use crate::settings::SettingsView;

impl SettingsView {
    pub(in crate::settings) fn render_plugins(&self, tokens: LitheTokens) -> AnyElement {
        div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(status_card(
                SharedString::from(tr("Plugin system is not available in the GPUI build yet.")),
                tokens,
            ))
            .into_any_element()
    }
}
