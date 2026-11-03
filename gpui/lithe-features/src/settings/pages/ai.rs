//! AI Providers 页：运行时（已安装 ACP adapter）快照 + 自动补全开关。
//!
//! 诚实边界（见 plan-01 §4.13 与 PR 报告）：
//! - Provider / Model 选择、API Key、自定义 Provider、Ollama 与 ACP 会话选项
//!   都由 Agent 面板的会话状态拥有；GPUI 构建还没有把它抽成可持久化的全局
//!   store，因此这里不提供假选择器（也不写影子配置）。
//! - 清空 Agent 历史需要设置页拿到 Agent 面板实体；当前通道只有
//!   `on_open_agent`，清理动作留在 Agent 面板。
//! - 运行时快照来自与 Agents 页同源的 `lithe_agent_host::install::status`。

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{Sizable as _, v_flex};
use gpui_kit::{AnyElement, ClickEvent, Context, IntoElement, ParentElement as _, SharedString, Styled, div, px};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheMetrics, LitheTokens};

use crate::settings::controls::{caption_line, note_card, readonly_row, section_card, toggle_row};
use crate::settings::state::{
    SETTINGS_BUTTON_HEIGHT, SETTINGS_BUTTON_RADIUS, SETTINGS_CONTROL_GAP, SETTINGS_SECTION_GAP,
    ToggleAction,
};
use crate::settings::SettingsView;

impl SettingsView {
    pub(in crate::settings) fn render_ai_providers(
        &mut self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        // 运行时快照与 Agents 页共用一次探测（`lithe_agent_host`，非阻塞）。
        if !self.agents.loaded {
            self.refresh_agents_status();
            self.agents.loaded = true;
        }

        let card = v_flex()
            .w_full()
            .gap(px(SETTINGS_CONTROL_GAP))
            .child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(tr(
                        "AI providers are managed from the Agent panel. This page does not edit provider settings or API keys.",
                    )),
            )
            .child(self.open_agent_button("lithe-settings:open-agent-providers", cx));

        // 运行时：已安装 adapter 是真实可用的 Provider 来源。
        let mut runtime = v_flex().w_full().gap(px(2.0));
        match self.agents.status.as_ref() {
            None => {
                runtime = runtime.child(caption_line(
                    SharedString::from(tr("Inspecting installed agent runtimes…")),
                    tokens,
                ));
            }
            Some(status) => {
                let installed: Vec<_> = status
                    .agents
                    .iter()
                    .filter(|agent| agent.installed_version.is_some())
                    .collect();
                if installed.is_empty() {
                    runtime = runtime.child(note_card(
                        SharedString::from(tr(
                            "No ACP adapter is installed. Install one from the Agent panel to use AI features.",
                        )),
                        tokens,
                    ));
                }
                for agent in installed {
                    let version = agent
                        .installed_version
                        .clone()
                        .unwrap_or_else(|| tr("Unknown").to_string());
                    runtime = runtime.child(readonly_row(
                        "Agent runtime",
                        SharedString::from(format!("{} · v{}", agent.name, version)),
                        tokens,
                    ));
                }
            }
        }

        let autocomplete = v_flex().w_full().child(toggle_row(
            "AI Autocomplete",
            "lithe-settings:ai-autocomplete",
            self.settings.ai_autocomplete,
            ToggleAction::AiAutocomplete,
            cx,
            tokens,
        ));

        v_flex()
            .w_full()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(section_card(
                "Providers",
                None,
                card.into_any_element(),
                tokens,
            ))
            .child(section_card(
                "Runtimes",
                Some(
                    "Installed agent runtimes are the providers available to this build.",
                ),
                runtime.into_any_element(),
                tokens,
            ))
            .child(section_card(
                "Autocomplete",
                None,
                autocomplete.into_any_element(),
                tokens,
            ))
            .child(note_card(
                SharedString::from(tr(
                    "Provider, model, API key, Ollama and ACP session options live in the Agent panel; clearing the agent history is done from the Agent panel in this build.",
                )),
                tokens,
            ))
            .into_any_element()
    }

    /// Library 二级页（Instructions / Skills）的跳板；Hooks 与 Mcp 已有独立
    /// 完整页面，Agents 在 pages/agents.rs。
    pub(in crate::settings) fn render_agent_library_page(
        &self,
        page: crate::settings::state::SettingsPage,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let explanation = match page {
            crate::settings::state::SettingsPage::Instructions => {
                "Agent instructions are edited from the Agent panel. This page does not edit project or global instruction files."
            }
            _ => {
                "Skills are discovered and managed by the Agent panel. This page does not install or edit skills."
            }
        };

        let card = v_flex()
            .w_full()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(tr(explanation)),
            )
            .child(self.open_agent_button("lithe-settings:open-agent-library", cx));

        v_flex()
            .w_full()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(section_card(
                page.title(),
                None,
                card.into_any_element(),
                tokens,
            ))
            .into_any_element()
    }

    /// “打开 Agent 面板”按钮；Providers / Agents / Library 三处共用。
    pub(in crate::settings) fn open_agent_button(&self, id: &'static str, cx: &mut Context<Self>) -> AnyElement {
        Button::new(id)
            .small()
            .h(px(SETTINGS_BUTTON_HEIGHT))
            .rounded(px(SETTINGS_BUTTON_RADIUS))
            .secondary()
            .label(tr("Open Agent"))
            .on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                this.invoke_open_agent(window, cx);
            }))
            .into_any_element()
    }
}
