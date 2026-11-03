//! Terminal 页：默认 Shell 选择（检测 + 重新检测）、字号与回滚。
//!
//! Shell 检测复用终端面板同一数据源 `lithe_terminal::shell`（PATH 探测 +
//! Windows 的 WSL 分发），不在设置页新写平台枚举；「系统默认」为
//! `terminal_default_shell = None`。PTY 启动时的消费接线见 PR 报告遗留项。

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{Disableable as _, Sizable as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, ClickEvent, Context, IntoElement, ParentElement as _, SharedString, Styled,
    Window, div, px,
};
use lithe_terminal::shell::Shell;
use lithe_ui::i18n::tr;
use lithe_ui::{LitheMetrics, LitheTokens};

use crate::settings::controls::{
    note_card, readonly_row, section_card, stepper_row, string_or_placeholder,
};
use crate::settings::state::{
    DEFAULT_TERMINAL_FONT_SIZE, DEFAULT_TERMINAL_SCROLLBACK, MAX_EDITOR_FONT_SIZE,
    MAX_TERMINAL_SCROLLBACK, MIN_EDITOR_FONT_SIZE, MIN_TERMINAL_SCROLLBACK,
    SETTINGS_BUTTON_HEIGHT, SETTINGS_BUTTON_RADIUS, SETTINGS_CONTROL_GAP,
    SETTINGS_OPTION_MIN_WIDTH, SETTINGS_SECTION_GAP, StepperAction,
};
use crate::settings::SettingsView;

/// 检测到的一个 shell 行。
#[derive(Clone, Debug)]
pub(in crate::settings) struct TerminalShellRow {
    shell: Shell,
    available: bool,
}

impl SettingsView {
    pub(in crate::settings) fn render_terminal(
        &mut self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        // 首次渲染做一次发现；「重新检测」按钮强制重跑。
        if self.terminal_shells.is_none() {
            self.detect_terminal_shells();
        }

        let display = div().w_full().flex().flex_col().child(stepper_row(
            "Font size",
            "lithe-settings:terminal-font-size",
            self.settings.terminal_font_size,
            MIN_EDITOR_FONT_SIZE,
            MAX_EDITOR_FONT_SIZE,
            DEFAULT_TERMINAL_FONT_SIZE,
            StepperAction::TerminalFontSize,
            SharedString::from(format!(
                "{} pt",
                self.settings.terminal_font_size.round() as i32
            )),
            cx,
            tokens,
        ));

        // 回滚行数用步进器而不是固定档位：磁盘上可能保存着 3000 这类
        // 非预设值，固定按钮会显示成“无选中”，重新打开时回显错误。
        let scrollback = div().w_full().flex().flex_col().child(stepper_row(
            "Scrollback",
            "lithe-settings:terminal-scrollback",
            self.settings.terminal_scrollback as f32,
            MIN_TERMINAL_SCROLLBACK as f32,
            MAX_TERMINAL_SCROLLBACK as f32,
            DEFAULT_TERMINAL_SCROLLBACK as f32,
            StepperAction::TerminalScrollback,
            SharedString::from(self.settings.terminal_scrollback.to_string()),
            cx,
            tokens,
        ));

        let shell_card = self.render_terminal_shell_card(tokens, cx);

        div()
            .w_full()
            .flex()
            .flex_col()
            .gap(px(SETTINGS_SECTION_GAP))
            .child(shell_card)
            .child(section_card(
                "Display",
                None,
                display.into_any_element(),
                tokens,
            ))
            .child(section_card(
                "Scrollback",
                None,
                scrollback.into_any_element(),
                tokens,
            ))
            .child(note_card(
                SharedString::from(tr(
                    "The selection is saved as the default for new terminals; running terminals keep their current shell.",
                )),
                tokens,
            ))
            .into_any_element()
    }

    /// Tauri Terminal › Shell 的选择卡片。
    fn render_terminal_shell_card(
        &mut self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let mut body = v_flex()
            .w_full()
            .gap(px(SETTINGS_CONTROL_GAP))
            .child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(tr(
                        "Shells detected on this machine. Unavailable entries are dimmed.",
                    )),
            );
        if let Some(error) = self.terminal_shells_error.clone() {
            body = body.child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.error)
                    .child(SharedString::from(error)),
            );
        }

        if let Some(rows) = self.terminal_shells.clone() {
            let mut controls = h_flex()
                .flex_wrap()
                .gap(px(SETTINGS_CONTROL_GAP))
                // 首位固定「系统默认」，写入会清掉 shell id。
                .child(
                    Button::new("lithe-settings:terminal-shell-default")
                        .small()
                        .h(px(SETTINGS_BUTTON_HEIGHT))
                        .rounded(px(SETTINGS_BUTTON_RADIUS))
                        .min_w(px(SETTINGS_OPTION_MIN_WIDTH))
                        .when(self.settings.terminal_default_shell.is_none(), |b| {
                            b.primary()
                        })
                        .when(self.settings.terminal_default_shell.is_some(), |b| {
                            b.secondary()
                        })
                        .label(tr("System default"))
                        .on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                            this.set_terminal_default_shell(None, window, cx);
                        })),
                );
            for row in rows {
                let id = row.shell.id.clone();
                let selected =
                    self.settings.terminal_default_shell.as_deref() == Some(row.shell.id.as_str());
                let mut label = row.shell.name.clone();
                if let Some(dist) = row.shell.wsl_distribution.as_ref() {
                    label = format!("{label} ({dist})");
                }
                if !row.available {
                    label = format!("{} · {}", label, tr("Not found"));
                }
                controls = controls.child(
                    Button::new(SharedString::from(format!(
                        "lithe-settings:terminal-shell:{id}"
                    )))
                    .small()
                    .h(px(SETTINGS_BUTTON_HEIGHT))
                    .rounded(px(SETTINGS_BUTTON_RADIUS))
                    .min_w(px(SETTINGS_OPTION_MIN_WIDTH))
                    .when(selected, |button| button.primary())
                    .when(!selected & row.available, |button| button.secondary())
                    .when(!row.available, |button| button.ghost().disabled(true))
                    .label(SharedString::from(label))
                    .disabled(!row.available)
                    .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                        this.set_terminal_default_shell(Some(id.clone()), window, cx);
                    })),
                );
            }
            body = body
                .child(controls)
                .child(
                    h_flex()
                        .w_full()
                        .justify_end()
                        .child(
                            // Tauri settings-panels.tsx:454-464 的「重新检测」。
                            Button::new("lithe-settings:terminal-shell-rescan")
                                .small()
                                .h(px(SETTINGS_BUTTON_HEIGHT))
                                .rounded(px(SETTINGS_BUTTON_RADIUS))
                                .secondary()
                                .label(tr("Rescan installed shells"))
                                .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                                    this.detect_terminal_shells();
                                    cx.notify();
                                })),
                        ),
                )
                .child(self.render_runtime_shell_line(tokens));
        } else {
            body = body.child(note_card(
                SharedString::from(tr("Detecting installed shells…")),
                tokens,
            ));
        }

        section_card("Shell", None, body.into_any_element(), tokens)
    }

    /// 生效值行：用户选择优先，否则系统默认（COMSPEC / SHELL）。
    fn render_runtime_shell_line(&self, tokens: LitheTokens) -> AnyElement {
        let runtime = if let Some(id) = self.settings.terminal_default_shell.as_deref() {
            id.to_string()
        } else {
            std::env::var("COMSPEC")
                .or_else(|_| std::env::var("SHELL"))
                .unwrap_or_default()
        };
        readonly_row(
            "In effect",
            string_or_placeholder(&runtime, "System default"),
            tokens,
        )
        .into_any_element()
    }

    /// 重新检测 shell；完整目录来自 `Shell::get_shell_list`，可用性来自
    /// `get_available_shells`（与终端面板同一过滤规则），库存里“存在但不可用”
    /// 的条目置灰展示。
    fn detect_terminal_shells(&mut self) {
        let available_ids: std::collections::HashSet<String> = Shell::get_available_shells()
            .into_iter()
            .map(|shell| shell.id)
            .collect();
        let mut rows: Vec<TerminalShellRow> = Shell::get_shell_list()
            .into_iter()
            .map(|shell| {
                let available = available_ids.contains(&shell.id);
                TerminalShellRow { shell, available }
            })
            .collect();
        rows.sort_by(|a, b| {
            b.available
                .cmp(&a.available)
                .then_with(|| a.shell.name.cmp(&b.shell.name))
        });
        let error = if rows.iter().any(|row| row.available) {
            None
        } else {
            Some(tr("No shells were detected on this machine.").to_string())
        };
        self.terminal_shells = Some(rows);
        self.terminal_shells_error = error;
    }

    /// 保存默认 shell 选择（`None` = 系统默认）。
    pub(in crate::settings) fn set_terminal_default_shell(
        &mut self,
        shell: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let next = shell.filter(|value| !value.trim().is_empty());
        if self.settings.terminal_default_shell == next {
            return;
        }
        self.settings.terminal_default_shell = next;
        self.commit(window, cx);
    }

    /// 终端字号按步进调整；与编辑器字号共用 9–32 的取整与夹紧规则。
    pub(in crate::settings) fn adjust_terminal_font_size(
        &mut self,
        delta: i32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let next = crate::settings::state::normalized_font_size(
            self.settings.terminal_font_size + delta as f32,
            DEFAULT_TERMINAL_FONT_SIZE,
        );
        if (next - self.settings.terminal_font_size).abs() < f32::EPSILON {
            return;
        }
        self.settings.terminal_font_size = next;
        self.commit(window, cx);
    }

    /// 终端回滚行数按 500 行为一档调整；磁盘里的任意值都能正确显示和继续调整。
    pub(in crate::settings) fn adjust_terminal_scrollback(
        &mut self,
        step: i32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let delta = step as i64 * crate::settings::state::TERMINAL_SCROLLBACK_STEP as i64;
        let next = (self.settings.terminal_scrollback as i64 + delta).clamp(
            MIN_TERMINAL_SCROLLBACK as i64,
            MAX_TERMINAL_SCROLLBACK as i64,
        ) as u32;
        if next == self.settings.terminal_scrollback {
            return;
        }
        self.settings.terminal_scrollback = next;
        self.commit(window, cx);
    }
}
