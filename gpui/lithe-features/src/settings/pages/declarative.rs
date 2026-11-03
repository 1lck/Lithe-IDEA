//! Declarative Plugins 页（诚实占位）。
//!
//! 契约 v1 的宿主在共享 Core 内（`rust/lithe-core/src/plugins/` 与
//! `plugins.declarative.*` 命令），但 Tauri 形态的安装 / 会话 / Web 工具窗
//! 桥（`declarative_plugins_*`，`windows/tauri/src-tauri/src/plugin_host/`）
//! 没有等价的 gpui 通道：列表状态不在 Core 里。与本页相关的清单服务落地于
//! 插件宿主桥接（plan-01 §4.15 的 M5 项），因此这里只展示契约语义与来源
//! 说明，不造假开关或假列表——「占位必须与 Tauri 语义一致并注释说明缺什么」。

use gpui_kit::component::{Sizable as _, v_flex};
use gpui_kit::{AnyElement, Context, IntoElement, ParentElement as _, SharedString, Styled, div, px};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheMetrics, LitheTokens};

use crate::settings::controls::{readonly_row, section_card};
use crate::settings::state::SETTINGS_SECTION_GAP;
use crate::settings::SettingsView;

impl SettingsView {
    pub(in crate::settings) fn render_declarative_plugins(
        &self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let _ = cx;
        let card = v_flex()
            .w_full()
            .gap(px(10.0))
            .child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(tr(
                        "Declarative plugins follow contract v1: packages are reviewed before install, run only host-launched processes, and can expose Web tool windows.",
                    )),
            )
            .child(readonly_row(
                "Host",
                SharedString::from(tr(
                    "The contract v1 host is part of the shared Core; the GPUI build has not wired the install and session bridge yet.",
                )),
                tokens,
            ))
            .child(readonly_row(
                "Import",
                SharedString::from(tr(
                    "Importing a .zip package requires the host bridge (install review with version, permission and program declarations).",
                )),
                tokens,
            ));

        v_flex()
            .w_full()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(section_card(
                "Declarative Plugins",
                Some("This page matches Tauri's declarative-plugins section; management lands when the plugin host bridge arrives."),
                card.into_any_element(),
                tokens,
            ))
            .into_any_element()
    }
}
