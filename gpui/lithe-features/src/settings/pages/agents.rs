//! Agents 页：连接状态 + 真实安装状态（Agent 宿主目录）。
//!
//! 数据源：`lithe_agent_host::install::status`（与 Agent 面板同一条宿主链路，
//! Tauri 的 agent-settings-section 即可读安装 / CLI 检测）。安装 / 更新 /
//! 卸载动作属于 Agent 面板的长驻任务（面板通道拥有进度与预检详情），设置页
//! 只呈现快照与跳板，不提供假按钮。
//!
//! 诚实边界：启用开关、观察模型调用、Codex 订阅模式、自定义 Agent 的
//! command/arguments 以及 Provider 的 CRUD 走 Agent 会话配置（panel store），
//! 本构建未接线，见 plan-01 §4.14 与 PR 报告遗留项。

use gpui_kit::component::v_flex;
use gpui_kit::{AnyElement, Context, IntoElement, ParentElement as _, SharedString, Styled, div, px};
use lithe_agent_host::install::{AgentStatus, ManagementStatus};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheMetrics, LitheTokens};

use crate::settings::controls::{caption_line, readonly_row, section_card, status_card};
use crate::settings::state::{SETTINGS_CONTROL_GAP, SETTINGS_SECTION_GAP};
use crate::settings::SettingsView;

/// Agents 页的宿主安装状态缓存。AI Providers 页复用同一份快照。
#[derive(Debug, Default)]
pub(in crate::settings) struct AgentsState {
    pub(in crate::settings) loaded: bool,
    pub(in crate::settings) status: Option<ManagementStatus>,
}

/// SettingsView 的 Agents 页部分。
impl SettingsView {
    pub(in crate::settings) fn render_agents(
        &mut self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        // 宿主目录探测是一次文件 / env 扫描；首次渲染缓存，不进渲染循环。
        if !self.agents.loaded {
            self.refresh_agents_status();
            self.agents.loaded = true;
        }

        let mut column = v_flex().w_full().gap(px(SETTINGS_SECTION_GAP));

        // 连接状态（原 stub 语义：SettingsContext.agent_status）。
        let connection = v_flex()
            .w_full()
            .gap(px(SETTINGS_CONTROL_GAP))
            .child(readonly_row(
                "Status",
                if self.context.agent_status.trim().is_empty() {
                    SharedString::from(tr("No agent is connected."))
                } else {
                    SharedString::from(self.context.agent_status.clone())
                },
                tokens,
            ))
            .child(
                div()
                    .w_full()
                    .flex()
                    .justify_end()
                    .child(self.open_agent_button("lithe-settings:open-agent-agents", cx)),
            );
        column = column
            .child(section_card("Agent connection", None, connection.into_any_element(), tokens));

        // 安装状态卡片（真实数据源；与 Agent 面板同源）。
        let mut status_body = v_flex().w_full().gap(px(SETTINGS_CONTROL_GAP));
        match self.agents.status.as_ref() {
            None => {
                status_body = status_body.child(
                    div()
                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                        .text_color(tokens.secondary_text)
                        .child(tr("Inspecting installed agents…")),
                );
            }
            Some(status) => {
                status_body = status_body
                    .child(readonly_row(
                        "Node runtime",
                        present_or_unknown(&status.environment.node),
                        tokens,
                    ));
                if let Some(npm) = status.environment.npm.as_ref() {
                    status_body = status_body.child(readonly_row(
                        "npm",
                        SharedString::from(npm.version.clone()),
                        tokens,
                    ));
                }
                for agent in status.agents.iter() {
                    status_body = status_body.child(render_agent_status(agent, tokens));
                }
            }
        }

        column
            .child(section_card(
                "Installed agents",
                Some(
                    "Install, update and uninstall run from the Agent panel with its progress and preflight checks.",
                ),
                status_body.into_any_element(),
                tokens,
            ))
            .child(status_card(
                SharedString::from(tr(
                    "Enable switch, model-call observation, Codex subscription mode, custom agents and provider maintenance live in the Agent panel; wiring them to a global store lands with the agent session channel.",
                )),
                tokens,
            ))
            .into_any_element()
    }

    /// 首次渲染时探测宿主安装状态（进程内缓存，与 Agent 面板同源）。
    /// AI Providers 页复用同一份快照展示运行时可选项。
    pub(in crate::settings) fn refresh_agents_status(&mut self) {
        if let Some(directory) = crate::settings::app_data_dir() {
            self.agents.status = Some(lithe_agent_host::install::status(&directory, &|| false));
        }
    }
}

/// 单个 Agent 的安装状态展示块（不泛化：字段少且语义各异）。
fn render_agent_status(agent: &AgentStatus, tokens: LitheTokens) -> AnyElement {
    let installed_line = match (is_installed(&agent.installed_version), agent.verified) {
        (true, _) => tr("Installed"),
        (false, true) => tr("Not installed"),
        (false, false) => tr("Catalog entry unavailable"),
    };
    let mut block = v_flex()
        .w_full()
        .gap(px(2.0))
        .child(
            div()
                .w_full()
                .flex()
                .flex_wrap()
                .items_center()
                .gap_x(px(8.0))
                .child(
                    div()
                        .min_w(px(0.0))
                        .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                        .text_color(tokens.primary_text)
                        .child(SharedString::from(agent.name.clone())),
                )
                .child(
                    div()
                        .min_w(px(0.0))
                        .truncate()
                        .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                        .text_color(tokens.secondary_text)
                        .child(SharedString::from(installed_line)),
                ),
        )
        .child(caption_line(
            SharedString::from(agent_summary(agent)),
            tokens,
        ));
    if let Some(version) = agent.installed_version.as_deref() {
        block = block.child(caption_line(
            SharedString::from(format!("{} · v{}", tr("Installed version"), version)),
            tokens,
        ));
    }
    for issue in agent.issues.iter() {
        block = block.child(
            div()
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(tokens.warning)
                .child(SharedString::from(issue.clone())),
        );
    }
    block.into_any_element()
}

fn is_installed(version: &Option<String>) -> bool {
    version
        .as_deref()
        .map(|value| !value.trim().is_empty())
        .unwrap_or(false)
}

fn present_or_unknown(
    tool: &Option<lithe_agent_host::environment::DetectedTool>,
) -> SharedString {
    match tool {
        Some(detected) => SharedString::from(detected.version.clone()),
        None => SharedString::from(tr("Unknown")),
    }
}

fn agent_summary(agent: &AgentStatus) -> String {
    let mut parts = vec![format!("v{}", agent.version)];
    if let Some(cli) = agent.cli.as_ref() {
        parts.push(format!("{}: {}", cli.name, cli.command));
    }
    parts.join(" · ")
}
