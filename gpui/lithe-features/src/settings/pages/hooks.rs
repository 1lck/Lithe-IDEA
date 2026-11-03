//! Hooks 页：用户 Agent 生命周期钩子库的查看与维护。
//!
//! 数据源是共享 Core 的 `agent.hooks` 命令（`lithe_agent_host::hooks`，与
//! Tauri 宿主同一条链路）：read/save/remove/sync 全部经 `execute_raw`，写操作
//! 带 `expectedRevision` 冲突保护；`dataDirectory` 复用设置存储目录；阻塞调用
//! 走 `background_spawn` + generation 丢弃过期结果。
//!
//! Hook 编辑用行内表单（plan-01 §4.12 的最小形态）；agents 多选用按钮组，
//! 草稿枚举（事件 / matcher）用互斥按钮直接改草稿，不需要 Window。

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputState};
use gpui_kit::component::{Disableable as _, Sizable as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, ClickEvent, Context, Entity, IntoElement, ParentElement as _, SharedString,
    Styled, Window, div, px,
};
use lithe_core_client::CoreClient;
use lithe_ui::i18n::tr;
use lithe_ui::{LitheMetrics, LitheTokens};

use crate::settings::controls::{note_card, section_card};
use crate::settings::state::{
    SETTINGS_BUTTON_HEIGHT, SETTINGS_BUTTON_RADIUS, SETTINGS_CONTROL_GAP, SETTINGS_SECTION_GAP,
};
use crate::settings::SettingsView;

/// 生命周期事件（kebab-case，与 Core serde 一致）。
pub(in crate::settings) const HOOK_EVENTS: [&'static str; 5] = [
    "turn-end",
    "after-tool",
    "before-tool",
    "prompt",
    "session-start",
];

/// 工具族 matcher（camelCase，与 Core serde 一致）。
pub(in crate::settings) const HOOK_MATCHERS: [&'static str; 3] = ["all", "shell", "edit"];

/// 支持的 Agent 运行时。
pub(in crate::settings) const HOOK_AGENTS: [&'static str; 2] = ["codex-acp", "claude-acp"];

/// timeout 范围：1–86400 秒；留空继承 Agent 默认。
pub(in crate::settings) const HOOK_TIMEOUT_MIN: u64 = 1;
pub(in crate::settings) const HOOK_TIMEOUT_MAX: u64 = 86_400;

/// 一条 Hook 的可编辑草稿。
#[derive(Clone, Debug, Default)]
pub(in crate::settings) struct HookDraft {
    pub(in crate::settings) id: Option<String>,
    pub(in crate::settings) event: &'static str,
    pub(in crate::settings) matcher: &'static str,
    pub(in crate::settings) agents: Vec<&'static str>,
}

/// Hooks 页状态与缓存快照。
#[derive(Clone, Debug, Default)]
pub(in crate::settings) struct HooksState {
    pub(in crate::settings) generation: u64,
    pub(in crate::settings) loading: bool,
    pub(in crate::settings) saving: bool,
    pub(in crate::settings) loaded: bool,
    /// `agent.hooks` read 的 Library revision；写入必须带上。
    pub(in crate::settings) revision: Option<String>,
    /// `(id, name, description, event, matcher, command, timeout, agents 数组, enabled, configured, needsSync, pendingRemoval)`。
    pub(in crate::settings) hooks: Vec<HookSummary>,
    /// 目标端问题（issue 非空或 disabled 的条目）。
    pub(in crate::settings) targets: Vec<TargetIssue>,
    pub(in crate::settings) error: Option<String>,
    pub(in crate::settings) notice: Option<String>,
    pub(in crate::settings) conflict: bool,
    /// 行内编辑器：`Some` 表示「新建/编辑」展开。
    pub(in crate::settings) editing: Option<HookDraft>,
    /// 编辑器输入框的回填值（渲染帧应用，需要 Window）。
    pub(in crate::settings) editing_inputs: Option<HookEditInputs>,
    /// read 时透传保存的目标端 FileGuard；save/remove 需要原样携带。
    pub(in crate::settings) file_guards: Vec<serde_json::Value>,
}

#[derive(Clone, Debug)]
pub(in crate::settings) struct HookSummary {
    pub(in crate::settings) id: String,
    pub(in crate::settings) name: String,
    pub(in crate::settings) description: String,
    pub(in crate::settings) event: String,
    pub(in crate::settings) matcher: String,
    pub(in crate::settings) command: String,
    pub(in crate::settings) timeout: Option<u64>,
    pub(in crate::settings) agents: Vec<String>,
    pub(in crate::settings) enabled: bool,
    pub(in crate::settings) configured_agents: Vec<String>,
    pub(in crate::settings) needs_sync: bool,
    pub(in crate::settings) pending_removal: bool,
}

#[derive(Clone, Debug)]
pub(in crate::settings) struct TargetIssue {
    pub(in crate::settings) agent_id: String,
    pub(in crate::settings) file: String,
    pub(in crate::settings) issue: String,
    pub(in crate::settings) disabled: bool,
}

impl SettingsView {
    pub(in crate::settings) fn render_hooks(
        &mut self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        if !self.hooks.loaded && !self.hooks.loading {
            self.reload_hooks(cx);
        }

        let mut column = v_flex().w_full().gap(px(SETTINGS_SECTION_GAP));
        if let Some(notice) = self.hooks.notice.clone() {
            column = column.child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(SharedString::from(notice)),
            );
        }
        if let Some(error) = self.hooks.error.clone() {
            if !self.hooks.conflict {
                column = column.child(
                    div()
                        .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                        .text_color(tokens.error)
                        .child(SharedString::from(error)),
                );
            }
        }
        if self.hooks.conflict {
            column = column.child(
                h_flex()
                    .w_full()
                    .items_center()
                    .justify_between()
                    .gap(px(SETTINGS_CONTROL_GAP))
                    .child(
                        div()
                            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                            .text_color(tokens.warning)
                            .child(tr(
                                "The hook library changed since it was loaded. Reload and try again.",
                            )),
                    )
                    .child(
                        Button::new("lithe-settings:hooks-reload")
                            .small()
                            .h(px(SETTINGS_BUTTON_HEIGHT))
                            .rounded(px(SETTINGS_BUTTON_RADIUS))
                            .secondary()
                            .label(tr("Reload"))
                            .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                                this.reload_hooks(cx);
                            })),
                    ),
            );
        }

        column
            .child(self.render_hooks_library(tokens, cx))
            .child(self.render_hooks_editor(tokens, cx))
            .child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.tertiary_text)
                    .child(tr(
                        "Hooks run native agent commands on lifecycle events. Lithe stores the library and syncs native Codex / Claude files on Save.",
                    )),
            )
            .into_any_element()
    }

    fn render_hooks_library(
        &mut self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let mut body = v_flex()
            .w_full()
            .gap(px(SETTINGS_CONTROL_GAP))
            .child(
                h_flex()
                    .w_full()
                    .items_center()
                    .justify_between()
                    .gap(px(SETTINGS_CONTROL_GAP))
                    .child(
                        div()
                            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                            .text_color(tokens.secondary_text)
                            .child(SharedString::from(format!(
                                "{} {} {}",
                                tr("Library"),
                                self.hooks.hooks.len(),
                                tr("hooks")
                            ))),
                    )
                    .child(
                        Button::new("lithe-settings:hooks-new")
                            .small()
                            .h(px(SETTINGS_BUTTON_HEIGHT))
                            .rounded(px(SETTINGS_BUTTON_RADIUS))
                            .secondary()
                            .label(tr("New hook"))
                            .disabled(self.hooks.saving || self.hooks.loading)
                            .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                                this.hooks.editing = Some(HookDraft {
                                    id: None,
                                    event: HOOK_EVENTS[0],
                                    matcher: HOOK_MATCHERS[0],
                                    agents: Vec::new(),
                                });
                                cx.notify();
                            })),
                    ),
            );

        if self.hooks.loading {
            body = body.child(note_card(SharedString::from(tr("Working…")), tokens));
        } else {
            for target in self.hooks.targets.clone() {
                if target.issue.is_empty() && !target.disabled {
                    continue;
                }
                let reason = if target.disabled {
                    format!("{} ({})", target.agent_id, tr("Disabled"))
                } else {
                    target.agent_id.clone()
                };
                body = body.child(
                    div()
                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                        .text_color(tokens.warning)
                        .child(SharedString::from(format!(
                            "{}: {} · {} {}/{}",
                            reason,
                            target.issue,
                            tr("File"),
                            target.file,
                            tr("target")
                        ))),
                );
            }

            for hook in self.hooks.hooks.clone() {
                let id = hook.id.clone();
                // 三个按钮的 `move` 闭包各拿一份 id，`id` 本身继续用于按钮
                // element id 的 format，避免 move 后借用。
                let toggle_id = id.clone();
                let edit_id = id.clone();
                let remove_id = id.clone();
                let enabled = hook.enabled;
                let mut badges = h_flex().gap(px(6.0));
                if hook.needs_sync {
                    badges = badges.child(
                        div()
                            .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                            .text_color(tokens.warning)
                            .child(tr("Needs sync")),
                    );
                }
                if hook.pending_removal {
                    badges = badges.child(
                        div()
                            .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                            .text_color(tokens.error)
                            .child(tr("Removal pending")),
                    );
                }
                let agents = if hook.agents.is_empty() {
                    tr("No agent selected").to_string()
                } else {
                    hook.agents.join(", ")
                };
                body = body.child(
                    v_flex()
                        .w_full()
                        .p(px(8.0))
                        .rounded(px(LitheMetrics::CONTROL_RADIUS))
                        .border_1()
                        .border_color(tokens.divider)
                        .gap(px(SETTINGS_CONTROL_GAP))
                        .child(
                            h_flex()
                                .w_full()
                                .items_center()
                                .gap(px(SETTINGS_CONTROL_GAP))
                                .child(
                                    div()
                                        .min_w(px(80.0))
                                        .truncate()
                                        .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                                        .text_color(tokens.primary_text)
                                        .child(SharedString::from(hook.name)),
                                )
                                .child(
                                    div()
                                        .flex_1()
                                        .min_w(px(0.0))
                                        .truncate()
                                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                                        .text_color(tokens.secondary_text)
                                        .child(SharedString::from(format!(
                                            "{} · {} · {} · {}",
                                            hook.event, hook.matcher, agents, hook.command,
                                        ))),
                                )
                                .child(badges)
                                .child(
                                    Button::new(SharedString::from(format!(
                                        "lithe-settings:hook-toggle:{id}"
                                    )))
                                    .small()
                                    .h(px(SETTINGS_BUTTON_HEIGHT))
                                    .rounded(px(SETTINGS_BUTTON_RADIUS))
                                    .secondary()
                                    .label(if enabled {
                                        tr("Disable")
                                    } else {
                                        tr("Enable")
                                    })
                                    .disabled(
                                        hook.pending_removal || self.hooks.saving,
                                    )
                                    .on_click(cx.listener(
                                        move |this, _: &ClickEvent, _window, cx| {
                                            this.toggle_hook_enabled(&toggle_id, !enabled, cx);
                                        },
                                    )),
                                )
                                .child(
                                    Button::new(SharedString::from(format!(
                                        "lithe-settings:hook-edit:{id}"
                                    )))
                                    .small()
                                    .h(px(SETTINGS_BUTTON_HEIGHT))
                                    .rounded(px(SETTINGS_BUTTON_RADIUS))
                                    .secondary()
                                    .label(tr("Edit"))
                                    .disabled(hook.pending_removal || self.hooks.saving)
                                    .on_click(cx.listener(
                                        move |this, _: &ClickEvent, _window, cx| {
                                            this.begin_hook_edit(&edit_id);
                                            cx.notify();
                                        },
                                    )),
                                )
                                .child(
                                    Button::new(SharedString::from(format!(
                                        "lithe-settings:hook-remove:{id}"
                                    )))
                                    .small()
                                    .h(px(SETTINGS_BUTTON_HEIGHT))
                                    .rounded(px(SETTINGS_BUTTON_RADIUS))
                                    .secondary()
                                    .label(tr("Remove"))
                                    .disabled(hook.pending_removal || self.hooks.saving)
                                    .on_click(cx.listener(
                                        move |this, _: &ClickEvent, _window, cx| {
                                            this.remove_hook(&remove_id, cx);
                                        },
                                    )),
                                ),
                        )
                        .child(
                            div()
                                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                                .text_color(tokens.tertiary_text)
                                .child(SharedString::from(hook.description)),
                        ),
                );
            }
            if self.hooks.hooks.is_empty() {
                body = body.child(note_card(
                    SharedString::from(tr(
                        "No hooks yet. Use “New hook” to add lifecycle commands for Codex or Claude.",
                    )),
                    tokens,
                ));
            }
        }

        section_card("Hooks", None, body.into_any_element(), tokens)
    }

    /// 行内新建 / 编辑表单。
    fn render_hooks_editor(
        &mut self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(draft) = self.hooks.editing.clone() else {
            return div().into_any_element();
        };

        let mut body = v_flex()
            .w_full()
            .gap(px(SETTINGS_CONTROL_GAP))
            .child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.primary_text)
                    .child(if draft.id.is_some() {
                        tr("Edit hook")
                    } else {
                        tr("New hook")
                    }),
            )
            .child(Input::new(&self.hook_name_input).small().w_full())
            .child(Input::new(&self.hook_instruction_input).small().w_full());

        // 事件 / matcher：互斥按钮直接改草稿（不需要 Window）。
        body = body
            .child(draft_choice_row(
                "Event",
                "lithe-settings:hook-event",
                HookDraftChoice::Event,
                draft.event,
                tokens,
                cx,
            ))
            .child(draft_choice_row(
                "Matcher",
                "lithe-settings:hook-matcher",
                HookDraftChoice::Matcher,
                draft.matcher,
                tokens,
                cx,
            ));

        body = body
            .child(Input::new(&self.hook_command_input).small().w_full())
            .child(
                h_flex()
                    .w_full()
                    .gap(px(SETTINGS_CONTROL_GAP))
                    .child(Input::new(&self.hook_timeout_input).small().w(px(140.0)))
                    .child(
                        div()
                            .flex_1()
                            .min_w(px(0.0))
                            .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                            .text_color(tokens.tertiary_text)
                            .child(tr("Leave empty to inherit the agent timeout.")),
                    ),
            );

        // agents 多选按钮组（1–2 个；重复选择即取消）。
        let mut agents_row = h_flex().gap(px(SETTINGS_CONTROL_GAP));
        for agent in HOOK_AGENTS {
            let label = if agent == "codex-acp" { "Codex" } else { "Claude" };
            let selected = draft.agents.contains(&agent);
            agents_row = agents_row.child(
                Button::new(format!("lithe-settings:hook-agents:{agent}"))
                    .small()
                    .h(px(SETTINGS_BUTTON_HEIGHT))
                    .rounded(px(SETTINGS_BUTTON_RADIUS))
                    .when(selected, |b| b.primary())
                    .when(!selected, |b| b.secondary())
                    .label(tr(label))
                    .on_click(cx.listener(move |this, _: &ClickEvent, _window, cx| {
                        if let Some(current) = this.hooks.editing.as_mut() {
                            if let Some(index) =
                                current.agents.iter().position(|value| *value == agent)
                            {
                                current.agents.remove(index);
                            } else if current.agents.len() < 2 {
                                current.agents.push(agent);
                            }
                        }
                        cx.notify();
                    })),
            );
        }
        body = body
            .child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(tr("Runs on")),
            )
            .child(agents_row)
            .child(
                h_flex()
                    .w_full()
                    .justify_end()
                    .gap(px(SETTINGS_CONTROL_GAP))
                    .child(
                        Button::new("lithe-settings:hook-cancel")
                            .small()
                            .h(px(SETTINGS_BUTTON_HEIGHT))
                            .rounded(px(SETTINGS_BUTTON_RADIUS))
                            .secondary()
                            .label(tr("Cancel"))
                            .on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                                this.hooks.editing = None;
                                this.hooks.editing_inputs = None;
                                for input in [
                                    &this.hook_name_input,
                                    &this.hook_instruction_input,
                                    &this.hook_command_input,
                                    &this.hook_timeout_input,
                                ] {
                                    input.update(cx, |state, cx| {
                                        state.set_value(String::new(), window, cx)
                                    });
                                }
                                cx.notify();
                            })),
                    )
                    .child(
                        Button::new("lithe-settings:hook-save")
                            .small()
                            .h(px(SETTINGS_BUTTON_HEIGHT))
                            .rounded(px(SETTINGS_BUTTON_RADIUS))
                            .primary()
                            .label(tr("Save hook"))
                            .disabled(self.hooks.saving)
                            .on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                                this.save_hook(window, cx);
                            })),
                    ),
            );

        section_card(
            if draft.id.is_some() { "Edit hook" } else { "New hook" },
            None,
            body.into_any_element(),
            tokens,
        )
    }

    /// 列表条目进入编辑器：草稿 + 输入框回填（回填需要 Window，挂在
    /// `editing_inputs`，渲染帧应用）。
    pub(in crate::settings) fn begin_hook_edit(&mut self, id: &str) {
        if let Some(hook) = self.hooks.hooks.iter().find(|hook| hook.id == id) {
            self.hooks.editing = Some(HookDraft {
                id: Some(hook.id.clone()),
                event: hook_event_static(&hook.event),
                matcher: hook_matcher_static(&hook.matcher),
                agents: hook.agents.iter().filter_map(|a| hook_agent_static(a)).collect(),
            });
            self.hooks.editing_inputs = Some(HookEditInputs {
                name: hook.name.clone(),
                description: hook.description.clone(),
                command: hook.command.clone(),
                timeout: hook
                    .timeout
                    .map(|value| value.to_string())
                    .unwrap_or_default(),
            });
        }
    }
}

/// 编辑器输入框回填值；渲染帧 set_value。
#[derive(Clone, Debug, Default)]
pub(in crate::settings) struct HookEditInputs {
    pub(in crate::settings) name: String,
    pub(in crate::settings) description: String,
    pub(in crate::settings) command: String,
    pub(in crate::settings) timeout: String,
}

/// event / matcher / agents 的静态化映射。
fn hook_event_static(event: &str) -> &'static str {
    HOOK_EVENTS
        .iter()
        .copied()
        .find(|value| *value == event)
        .unwrap_or(HOOK_EVENTS[0])
}

fn hook_matcher_static(matcher: &str) -> &'static str {
    HOOK_MATCHERS
        .iter()
        .copied()
        .find(|value| *value == matcher)
        .unwrap_or(HOOK_MATCHERS[0])
}

fn hook_agent_static(agent: &str) -> Option<&'static str> {
    HOOK_AGENTS.iter().copied().find(|value| *value == agent)
}

/// 事件 / matcher 的互斥按钮行；草稿仅保存在 `hooks.editing`，点选即生效。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::settings) enum HookDraftChoice {
    Event,
    Matcher,
}

fn draft_choice_row(
    label: &'static str,
    id: &'static str,
    choice: HookDraftChoice,
    selected: &'static str,
    tokens: LitheTokens,
    cx: &mut Context<SettingsView>,
) -> AnyElement {
    let options: &'static [&'static str] = match choice {
        HookDraftChoice::Event => &HOOK_EVENTS,
        HookDraftChoice::Matcher => &HOOK_MATCHERS,
    };
    let owner = cx.weak_entity();
    let mut buttons = h_flex().gap(px(SETTINGS_CONTROL_GAP));
    for option in options {
        let is_selected = *option == selected;
        let owner = owner.clone();
        let value = *option;
        buttons = buttons.child(
            Button::new(format!("{id}:{option}"))
                .small()
                .h(px(SETTINGS_BUTTON_HEIGHT))
                .rounded(px(SETTINGS_BUTTON_RADIUS))
                .min_w(px(84.0))
                .when(is_selected, |b| b.primary())
                .when(!is_selected, |b| b.secondary())
                .label(SharedString::from(mask_option_title(choice, option)))
                .on_click(move |_, _, cx| {
                    let _ = owner.update(cx, |this, cx| {
                        if let Some(current) = this.hooks.editing.as_mut() {
                            match choice {
                                HookDraftChoice::Event => current.event = value,
                                HookDraftChoice::Matcher => current.matcher = value,
                            }
                        }
                        cx.notify();
                    });
                }),
        );
    }
    div()
        .w_full()
        .flex()
        .flex_wrap()
        .items_center()
        .gap_x(px(8.0))
        .child(
            div()
                .w(px(120.0))
                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                .text_color(tokens.primary_text)
                .child(tr(label)),
        )
        .child(buttons)
        .into_any_element()
}

fn mask_option_title(choice: HookDraftChoice, value: &'static str) -> &'static str {
    match choice {
        HookDraftChoice::Event => match value {
            "turn-end" => "Turn end",
            "after-tool" => "After tool",
            "before-tool" => "Before tool",
            "prompt" => "Prompt submitted",
            _ => "Session start",
        },
        HookDraftChoice::Matcher => match value {
            "all" => "All tools",
            "shell" => "Shell commands",
            _ => "File edits",
        },
    }
}

// ---------------------------------------------------------------------------
// agent.hooks 命令（读 / 写 / 删 / 同步，全部 background_spawn + generation）
// ---------------------------------------------------------------------------

impl SettingsView {
    /// 读取 Library 快照；FileGuard 原样保留供写入操作透传。
    pub(in crate::settings) fn reload_hooks(&mut self, cx: &mut Context<Self>) {
        if self.hooks.loading {
            return;
        }
        self.hooks.generation = self.hooks.generation.wrapping_add(1);
        let generation = self.hooks.generation;
        self.hooks.loading = true;
        self.hooks.error = None;
        self.hooks.conflict = false;
        cx.notify();

        let mut payload = serde_json::json!({ "action": "read" });
        if let Some(directory) = crate::settings::app_data_dir() {
            payload["dataDirectory"] = serde_json::Value::String(
                directory.to_string_lossy().into_owned(),
            );
        }
        let client = CoreClient::new();
        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_executor().spawn(async move {
                    client.execute_raw("agent.hooks", payload)
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.hooks.generation != generation {
                    return;
                }
                this.hooks.loading = false;
                this.hooks.loaded = true;
                match raw {
                    Ok(value) => {
                        apply_hooks_library(&mut this.hooks, &value);
                        cx.notify();
                    }
                    Err(error) => {
                        this.hooks.error = Some(error.to_string());
                        cx.notify();
                    }
                }
            });
        })
        .detach();
    }

    /// 启用 / 禁用一条 Hook（全量保存，带 expectedRevision）。
    pub(in crate::settings) fn toggle_hook_enabled(&mut self, id: &str, enabled: bool, cx: &mut Context<Self>) {
        let Some(summary) = self
            .hooks
            .hooks
            .iter()
            .find(|hook| hook.id == id)
            .cloned()
        else {
            return;
        };
        self.dispatch_hook_write(HookMutation::Save {
            hook: HookSummary {
                enabled,
                ..summary
            },
        }, cx);
    }

    /// 删除一条 Hook（`agent.hooks` remove；Core 负责原生文件的移除）。
    pub(in crate::settings) fn remove_hook(&mut self, id: &str, cx: &mut Context<Self>) {
        self.dispatch_hook_write(
            HookMutation::Remove {
                id: id.to_string(),
            },
            cx,
        );
    }

    /// 把编辑器草稿写回库（校验 + 保存；需要 Window 清空输入框）。
    pub(in crate::settings) fn save_hook(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(draft) = self.hooks.editing.clone() else {
            return;
        };
        let name = self.hook_name_input.read(cx).value().trim().to_string();
        let description = self
            .hook_instruction_input
            .read(cx)
            .value()
            .chars()
            .take(200)
            .collect::<String>();
        let command = self
            .hook_command_input
            .read(cx)
            .value()
            .chars()
            .take(32_768)
            .collect::<String>();
        let timeout_text = self.hook_timeout_input.read(cx).value().trim().to_string();

        // 校验（对齐 Tauri validHook）。
        let name_ok = name.len() >= 1
            && name.len() <= 80
            && name
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-');
        let command_ok = !command.trim().is_empty() && !command.contains('\0');
        let agents_ok = !draft.agents.is_empty() && draft.agents.len() <= 2;
        let matcher_ok = draft.matcher == "all"
            || draft.event == "before-tool"
            || draft.event == "after-tool";
        // timeout：留空 = None（继承），否则解析失败 / 越界就是校验错误。
        let timeout = if timeout_text.trim().is_empty() {
            Some(None)
        } else {
            timeout_text
                .trim()
                .parse::<u64>()
                .ok()
                .filter(|value| (HOOK_TIMEOUT_MIN..=HOOK_TIMEOUT_MAX).contains(value))
                .map(Some)
        };
        let timeout_ok = timeout.is_some();
        let timeout = timeout.flatten();
        if !name_ok || !command_ok || !agents_ok || !matcher_ok || !timeout_ok {
            self.hooks.error =
                Some(hook_validation_error(name_ok, command_ok, agents_ok, matcher_ok, timeout_ok));
            cx.notify();
            return;
        }

        let summary = HookSummary {
            id: draft.id.clone().unwrap_or_else(|| format!("hook-{}", hook_new_suffix())),
            name,
            description,
            event: draft.event.to_string(),
            matcher: draft.matcher.to_string(),
            command,
            timeout,
            agents: draft.agents.iter().map(|value| value.to_string()).collect(),
            enabled: true,
            configured_agents: Vec::new(),
            needs_sync: false,
            pending_removal: false,
        };
        let result = self.commit_hook_mutation(HookMutation::Save { hook: summary }, cx);

        match result {
            Ok(()) => {
                self.hooks.editing = None;
                self.hooks.editing_inputs = None;
                for input in [
                    &self.hook_name_input,
                    &self.hook_instruction_input,
                    &self.hook_command_input,
                    &self.hook_timeout_input,
                ] {
                    input.update(cx, |state, cx| {
                        state.set_value(String::new(), window, cx)
                    });
                }
                self.reload_hooks(cx);
            }
            Err(error) => {
                self.hooks.error = Some(error);
                cx.notify();
            }
        }
    }
}

/// 编辑器的落库动作形态；统一 payload 组装入口。
#[derive(Clone, Debug)]
enum HookMutation {
    Save { hook: HookSummary },
    Remove { id: String },
}

impl SettingsView {
    /// 直接同步写库（在拿到 Window 的回调里使用）。
    fn dispatch_hook_write(&mut self, mutation: HookMutation, cx: &mut Context<Self>) {
        if let Err(error) = self.commit_hook_mutation(mutation, cx) {
            self.hooks.error = Some(error);
        } else {
            self.reload_hooks(cx);
        }
        cx.notify();
    }

    /// 组装 payload 并（后台）执行 agent.hooks 写入；同步返回组包错误。
    fn commit_hook_mutation(
        &mut self,
        mutation: HookMutation,
        cx: &mut Context<Self>,
    ) -> Result<(), String> {
        let Some(revision) = self.hooks.revision.clone() else {
            return Err(tr("The hook library is not loaded yet.").to_string());
        };
        let mut payload = serde_json::json!({
            "expectedRevision": revision,
            "files": self.hooks.file_guards,
        });
        match mutation {
            HookMutation::Save { hook } => {
                if hook.name.len() > 80 {
                    return Err(hook_validation_error(true, true, true, true, true));
                }
                payload["action"] = serde_json::Value::String("save".into());
                payload["hook"] = hook_payload(&hook);
            }
            HookMutation::Remove { id } => {
                payload["action"] = serde_json::Value::String("remove".into());
                payload["id"] = serde_json::Value::String(id);
            }
        }
        if let Some(directory) = crate::settings::app_data_dir() {
            payload["dataDirectory"] = serde_json::Value::String(
                directory.to_string_lossy().into_owned(),
            );
        }

        self.hooks.generation = self.hooks.generation.wrapping_add(1);
        self.hooks.saving = true;
        let generation = self.hooks.generation;
        let client = CoreClient::new();
        self.hooks_busy_task(cx, generation, client, payload);
        Ok(())
    }

    fn hooks_busy_task(
        &mut self,
        cx: &mut Context<Self>,
        generation: u64,
        client: lithe_core_client::CoreClient,
        payload: serde_json::Value,
    ) {
        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_executor().spawn(async move { client.execute_raw("agent.hooks", payload) })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.hooks.generation != generation {
                    return;
                }
                this.hooks.saving = false;
                match raw {
                    Ok(value) => {
                        apply_hooks_library(&mut this.hooks, &value);
                        this.hooks.notice = Some(tr("Hooks saved.").to_string());
                        cx.notify();
                    }
                    Err(error) => {
                        let text = error.to_string();
                        this.hooks.conflict = text.contains("revision")
                            || text.contains("Revision");
                        this.hooks.error = Some(text);
                        cx.notify();
                    }
                }
            });
        })
        .detach();
    }
}

/// 汇总校验错误文案。
fn hook_validation_error(
    name_ok: bool,
    command_ok: bool,
    agents_ok: bool,
    matcher_ok: bool,
    timeout_ok: bool,
) -> String {
    let mut problems = Vec::new();
    if !name_ok {
        problems.push(tr("Name must use letters, numbers, _ or - (max 80)."));
    }
    if !command_ok {
        problems.push(tr("A non-empty command without NUL is required."));
    }
    if !agents_ok {
        problems.push(tr("Select one or two agents."));
    }
    if !matcher_ok {
        problems.push(tr("Only “All tools” is available for this event."));
    }
    if !timeout_ok {
        problems.push(tr("Timeout must be 1–86400 seconds or empty."));
    }
    problems.join(" ")
}

/// HookSummary → agent.hooks 的 serde 形状（kebab-case 事件等）。
fn hook_payload(hook: &HookSummary) -> serde_json::Value {
    serde_json::json!({
        "id": hook.id,
        "name": hook.name,
        "description": hook.description,
        "event": hook.event,
        "matcher": hook.matcher,
        "command": hook.command,
        "timeoutSeconds": hook.timeout,
        "agents": hook.agents,
        "enabled": hook.enabled,
    })
}

/// 新 Hook 的本地 id 后缀（纳秒 + 计数，不引 uuid 依赖）。
fn hook_new_suffix() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: std::sync::atomic::AtomicU64 = AtomicU64::new(1);
    let value = NEXT.fetch_add(1, Ordering::Relaxed);
    format!(
        "{:x}-{:x}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|span| span.as_nanos())
            .unwrap_or(0),
        value
    )
}

/// 把 `agent.hooks` 的 Library 解析成页面状态。
fn apply_hooks_library(state: &mut HooksState, value: &serde_json::Value) {
    state.revision = value
        .get("revision")
        .and_then(serde_json::Value::as_str)
        .map(str::to_string);
    state.hooks = value
        .get("hooks")
        .and_then(|hooks| hooks.as_array())
        .map(|hooks| {
            hooks
                .iter()
                .map(|hook| HookSummary {
                    id: string_at(hook, "id"),
                    name: string_at(hook, "name"),
                    description: string_at(hook, "description"),
                    event: string_at(hook, "event"),
                    matcher: string_at(hook, "matcher"),
                    command: string_at(hook, "command"),
                    timeout: hook
                        .get("timeoutSeconds")
                        .and_then(serde_json::Value::as_u64),
                    agents: strings_at(hook, "agents"),
                    enabled: hook
                        .get("enabled")
                        .and_then(serde_json::Value::as_bool)
                        .unwrap_or(false),
                    configured_agents: strings_at(hook, "configuredAgents"),
                    needs_sync: hook
                        .get("needsSync")
                        .and_then(serde_json::Value::as_bool)
                        .unwrap_or(false),
                    pending_removal: hook
                        .get("pendingRemoval")
                        .and_then(serde_json::Value::as_bool)
                        .unwrap_or(false),
                })
                .collect()
        })
        .unwrap_or_default();
    let mut guards = Vec::new();
    state.targets = value
        .get("targets")
        .and_then(|targets| targets.as_array())
        .map(|targets| {
            targets
                .iter()
                .map(|target| {
                    if let Some(file) = target.get("file") {
                        if !file.is_null() {
                            guards.push(file.clone());
                        }
                    }
                    TargetIssue {
                        agent_id: string_at(target, "agentId"),
                        file: target
                            .get("file")
                            .and_then(|file| file.get("path"))
                            .and_then(serde_json::Value::as_str)
                            .unwrap_or_default()
                            .to_string(),
                        issue: target
                            .get("issue")
                            .and_then(serde_json::Value::as_str)
                            .unwrap_or_default()
                            .to_string(),
                        disabled: target
                            .get("disabled")
                            .and_then(serde_json::Value::as_bool)
                            .unwrap_or(false),
                    }
                })
                .collect()
        })
        .unwrap_or_default();
    state.file_guards = guards;
}

fn string_at(value: &serde_json::Value, key: &str) -> String {
    value
        .get(key)
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn strings_at(value: &serde_json::Value, key: &str) -> Vec<String> {
    value
        .get(key)
        .and_then(serde_json::Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(serde_json::Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

impl SettingsView {
    /// 编辑器打开时（`editing_inputs`）在渲染帧回填输入框；需要 Window。
    pub(in crate::settings) fn apply_hooks_pending(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(inputs) = self.hooks.editing_inputs.take() {
            for (input, value) in [
                (&self.hook_name_input, inputs.name),
                (&self.hook_instruction_input, inputs.description),
                (&self.hook_command_input, inputs.command),
                (&self.hook_timeout_input, inputs.timeout),
            ] {
                input.update(cx, |state, cx| state.set_value(value, window, cx));
            }
            cx.notify();
        }
    }
}
