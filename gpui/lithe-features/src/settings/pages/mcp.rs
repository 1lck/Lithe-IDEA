//! MCP 页：配置文件的发现、解析、预览与复制。
//!
//! 事实来源对齐 plan-01 §4.11 与 Tauri `mcp-settings.tsx`；Core 侧提供
//! `mcp.parseConfiguration`（对 codex/claude 配置做归一化 server 表）。
//!
//! 诚实边界：Tauri 的「启用 / 权限」是 host MCP 会话（连接状态）的字段，
//! gpui 构建暂无 host MCP 会话层，因此这里展示解析结果与配置快照，不提供
//! 假开关；启用与权限跟随 Agent 面板（连接由 Agent 宿主管理）。

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{InputState, Textarea};
use gpui_kit::component::{Disableable as _, Sizable as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, ClickEvent, Context, Entity, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, Styled, div, px,
};
use lithe_core_client::CoreClient;
use lithe_ui::i18n::tr;
use lithe_ui::{LitheMetrics, LitheTokens};

use crate::settings::controls::{caption_line, project_root_label, readonly_row, section_card};
use crate::settings::state::{
    SETTINGS_BUTTON_HEIGHT, SETTINGS_BUTTON_RADIUS, SETTINGS_CONTROL_GAP, SETTINGS_SECTION_GAP,
};
use crate::settings::SettingsView;

/// 支持的配置来源（与 Core `parse_configuration` 的 source 分支一致）。
pub(in crate::settings) const MCP_SOURCES: [(&'static str, &'static str); 2] =
    [("codex", "Codex"), ("claude", "Claude")];

impl Default for McpState {
    fn default() -> Self {
        Self {
            generation: 0,
            loading: false,
            source: MCP_SOURCES[0].0,
            servers: Vec::new(),
            error: None,
            prefilled: false,
        }
    }
}

/// MCP 页状态。
#[derive(Clone, Debug)]
pub(in crate::settings) struct McpState {
    pub(in crate::settings) generation: u64,
    pub(in crate::settings) loading: bool,
    pub(in crate::settings) source: &'static str,
    /// 解析成功的服务器表（name · transport · 关键参数）。
    pub(in crate::settings) servers: Vec<ServerLine>,
    pub(in crate::settings) error: Option<String>,
    /// 预载的配置文本（首次发现时从 `~/.codex/config.toml` / `~/.claude.json`
    /// 读入；文件缺失时留空并提示）。
    pub(in crate::settings) prefilled: bool,
}

#[derive(Clone, Debug)]
pub(in crate::settings) struct ServerLine {
    name: String,
    detail: String,
    source: String,
}

impl SettingsView {
    pub(in crate::settings) fn render_mcp(&mut self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        // 未打开项目也可用（Tauri mcp-settings 要求打开项目是因为它同时管理
        // project scope；这里的预览来自用户级文件，因此只显示项目根提示）。
        let body = v_flex()
            .w_full()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(self.render_mcp_scope(tokens, cx))
            .child(self.render_mcp_configuration(tokens, cx))
            .into_any_element();

        body
    }

    fn render_mcp_scope(
        &mut self,
        tokens: LitheTokens,
        _cx: &mut Context<Self>,
    ) -> AnyElement {
        let stack = v_flex()
            .w_full()
            .gap(px(SETTINGS_CONTROL_GAP))
            .child(readonly_row("Project", project_root_label(self.context.project_root.as_ref()), tokens))
            .child(caption_line(
                SharedString::from(tr(
                    "MCP sessions are owned by the Agent panel; this page inspects and validates the underlying configuration files.",
                )),
                tokens,
            ));
        section_card("Scope", None, stack.into_any_element(), tokens)
    }

    fn render_mcp_configuration(
        &mut self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        // 首次渲染自动读取用户级配置文件。
        if !self.mcp.prefilled {
            self.prefill_mcp_configuration(cx);
            self.mcp.prefilled = true;
        }

        let source_owner = cx.weak_entity();
        let mut body = v_flex()
            .w_full()
            .gap(px(SETTINGS_CONTROL_GAP))
            .child(
                // 来源选择（codex = config.toml；claude = .claude.json）。
                h_flex().gap(px(SETTINGS_CONTROL_GAP)).children(
                    MCP_SOURCES
                        .iter()
                        .map(|&(value, title)| {
                            let owner = source_owner.clone();
                            let selected = self.mcp.source == value;
                            Button::new(format!("lithe-settings:mcp-source:{value}"))
                                .small()
                                .h(px(SETTINGS_BUTTON_HEIGHT))
                                .rounded(px(SETTINGS_BUTTON_RADIUS))
                                .min_w(px(96.0))
                                .when(selected, |b| b.primary())
                                .when(!selected, |b| b.secondary())
                                .label(tr(title))
                                .on_click(move |_, _, cx| {
                                    let _ = owner.update(cx, |this, cx| {
                                        this.mcp.source = value;
                                        this.mcp.servers.clear();
                                        this.mcp.prefilled = false;
                                        cx.notify();
                                    });
                                })
                        }),
                ),
            )
            .child(
                Textarea::new(&self.mcp_config_input)
                    .w_full()
                    .h(px(200.0))
                    .font_family(lithe_ui::MONO_FONT_FAMILY),
            );

        body = body.child(
            h_flex()
                .w_full()
                .justify_end()
                .gap(px(SETTINGS_CONTROL_GAP))
                .child(
                    Button::new("lithe-settings:mcp-reload")
                        .small()
                        .h(px(SETTINGS_BUTTON_HEIGHT))
                        .rounded(px(SETTINGS_BUTTON_RADIUS))
                        .secondary()
                        .label(tr("Reload file"))
                        .disabled(self.mcp.loading)
                        .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                            this.prefill_mcp_configuration(cx);
                            cx.notify();
                        })),
                )
                .child(
                    Button::new("lithe-settings:mcp-parse")
                        .small()
                        .h(px(SETTINGS_BUTTON_HEIGHT))
                        .rounded(px(SETTINGS_BUTTON_RADIUS))
                        .primary()
                        .label(tr("Validate configuration"))
                        .disabled(self.mcp.loading)
                        .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                            this.parse_mcp_configuration(cx);
                        })),
                )
                .child(
                    // gpui-kit Clipboard 组件自带复制 + copied 反馈。
                    gpui_kit::component::clipboard::Clipboard::new("lithe-settings:mcp-copy")
                        .value(self.mcp_config_input.read(cx).value().to_string())
                        .accessibility_label(tr("Copy configuration")),
                ),
        );

        if self.mcp.loading {
            body = body.child(caption_line(SharedString::from(tr("Working…")), tokens));
        }
        if let Some(error) = self.mcp.error.clone() {
            body = body.child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.error)
                    .child(SharedString::from(error)),
            );
        }
        if !self.mcp.servers.is_empty() {
            for server in self.mcp.servers.clone() {
                body = body.child(
                    div()
                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                        .font_family(lithe_ui::MONO_FONT_FAMILY)
                        .text_color(tokens.secondary_text)
                        .child(SharedString::from(format!(
                            "{} · {}",
                            server.name, server.detail
                        ))),
                );
            }
        } else if !self.mcp.loading && self.mcp.error.is_none() {
            body = body.child(caption_line(
                SharedString::from(tr(
                    "No servers parsed yet. “Validate configuration” normalizes the source file.",
                )),
                tokens,
            ));
        }

        section_card(
            "Configuration",
            Some("MCP servers are a user-level Codex / Claude configuration; sessions run through the Agent panel."),
            body.into_any_element(),
            tokens,
        )
    }

    /// 从用户级配置文件预载文本（Codex → config.toml，Claude → ~/.claude.json）。
    /// 文件读取在后台完成，写回 textarea 需要在回调里 set_value。
    pub(in crate::settings) fn prefill_mcp_configuration(&mut self, cx: &mut Context<Self>) {
        let source = self.mcp.source;
        self.mcp.generation = self.mcp.generation.wrapping_add(1);
        let generation = self.mcp.generation;
        self.mcp.loading = true;
        cx.spawn(async move |this, cx| {
            let text = cx.background_executor().spawn(async move { read_mcp_file(source) }).await;
            let _ = this.update(cx, |this, cx| {
                if this.mcp.generation != generation {
                    return;
                }
                this.mcp.loading = false;
                this.mcp.error = None;
                match text {
                    Ok((value, path)) => {
                        this.mcp_pending_text = Some((value, path));
                    }
                    Err(error) => {
                        this.mcp.error = Some(error);
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 用 Core 的 `mcp.parseConfiguration` 归一化 server 表（校验 + 结果行）。
    pub(in crate::settings) fn parse_mcp_configuration(&mut self, cx: &mut Context<Self>) {
        let content = self.mcp_config_input.read(cx).value().to_string();
        if content.trim().is_empty() {
            self.mcp.error = Some(tr("The configuration text is empty.").to_string());
            cx.notify();
            return;
        }
        self.mcp.generation = self.mcp.generation.wrapping_add(1);
        let generation = self.mcp.generation;
        self.mcp.loading = true;
        self.mcp.error = None;
        self.mcp.servers.clear();
        cx.notify();

        let source = self.mcp.source;
        let mut payload = serde_json::json!({
            "source": source,
            "scope": "global",
            "content": content,
        });
        if let Some(root) = self.context.project_root.as_ref() {
            payload["projectPath"] =
                serde_json::Value::String(root.to_string_lossy().into_owned());
        }
        let client = CoreClient::new();
        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_executor().spawn(async move {
                    client.execute_raw("mcp.parseConfiguration", payload)
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.mcp.generation != generation {
                    return;
                }
                this.mcp.loading = false;
                match raw {
                    Ok(value) => {
                        this.mcp.servers = parse_mcp_servers(&value, source);
                        this.mcp.error = None;
                        cx.notify();
                    }
                    Err(error) => {
                        this.mcp.error = Some(error.to_string());
                        cx.notify();
                    }
                }
            });
        })
        .detach();
    }

    // codex / claude 的 scope：这里只处理用户级（global）文件的预览；
    // claude 支持 project scope，本页只读用户级文件（与 Tauri 一致的语义）。
}


/// 读取 MCP 配置文件：`(完整文本, 路径)`；不存在返回空串 + 提示。
fn read_mcp_file(source: &'static str) -> Result<(String, String), String> {
    let home = std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(std::path::PathBuf::from)
        .filter(|home| !home.as_os_str().is_empty())
        .ok_or_else(|| tr("Could not determine the user home directory.").to_string())?;
    let path = match source {
        "claude" => home.join(".claude.json"),
        _ => home.join(".codex").join("config.toml"),
    };
    match std::fs::read_to_string(&path) {
        Ok(text) => Ok((text, path.to_string_lossy().into_owned())),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            // 文件不存在是常见状态：空文本 + 路径让界面显示中性提示。
            Ok((String::new(), path.to_string_lossy().into_owned()))
        }
        Err(_) => Err(format!(
            "{}: {}",
            tr("Could not read the configuration file."),
            path.display()
        )),
    }
}

/// 解析 Core 响应里的 servers 数组为展示行。
fn parse_mcp_servers(value: &serde_json::Value, source: &'static str) -> Vec<ServerLine> {
    value
        .get("servers")
        .and_then(serde_json::Value::as_array)
        .map(|servers| {
            servers
                .iter()
                .map(|server| {
                    let name = server
                        .get("name")
                        .or_else(|| server.get("id"))
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("unnamed")
                        .to_string();
                    let mut detail_parts = Vec::new();
                    for key in ["transport", "kind", "type", "command", "url"] {
                        if let Some(value) = server.get(key) {
                            if let Some(text) = value.as_str() {
                                detail_parts.push(text.to_string());
                            }
                        }
                    }
                    ServerLine {
                        name,
                        detail: detail_parts.join(" · "),
                        source: source.to_string(),
                    }
                })
                .collect()
        })
        .unwrap_or_default()
}
