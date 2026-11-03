//! 控制台动作与渲染：复制、堆栈跳转和虚拟化输出列表。

use std::rc::Rc;

use gpui_kit::base::TextSelection;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{
    Disableable as _, Icon, IconName, Selectable as _, Sizable as _, Theme, h_flex, v_flex,
    v_virtual_list,
};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, ClipboardItem, Context, FontWeight, InteractiveElement as _, MouseButton,
    MouseMoveEvent, ScrollEvent, ScrollStrategy, StatefulInteractiveElement as _, Styled as _,
    TextStyleRefinement, WhiteSpace, Window, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheIcon, LitheMetrics, LitheTokens, icon, mono_font_family};

use crate::console::{AnsiPalette, ConsoleCaretHandler, console_line_element, console_scrollbar};

use super::session::RunMode;
use super::{
    CONSOLE_ACTION_STRIPE_WIDTH, CONSOLE_CONTEXT, CONSOLE_LINE_HEIGHT, CopySelection,
    PANEL_PADDING, RunPanel,
};

impl RunPanel {
    /// 把行数变化同步给虚拟化列表。
    ///
    /// 行数变化时跟随最新输出。虚拟列表的行数在渲染时传入，
    /// 这里只负责把贴底跟随落成滚动指令；退出 System 行追加后
    /// 会话已不处于运行态，跟随不再要求运行中。
    pub(super) fn sync_console_lines(&mut self) {
        let count = self.selected_line_count();
        if self.console.sync_line_count(count, CONSOLE_LINE_HEIGHT)
            && self.console_follow_tail
            && count > 0
        {
            self.console
                .scroll_to_item(count - 1, ScrollStrategy::Bottom);
        }
    }

    /// 回到最新输出（macOS 的 “Jump to latest”）。
    pub(super) fn scroll_to_latest(&mut self, cx: &mut Context<Self>) {
        self.console_follow_tail = true;
        let count = self.selected_line_count();
        if count > 0 {
            self.console
                .scroll_to_item(count - 1, ScrollStrategy::Bottom);
        }
        cx.notify();
    }

    /// ⌘C / Ctrl+C：优先复制选择范围，没有选择时复制整段输出。
    fn on_copy_selection(
        &mut self,
        _: &CopySelection,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let text = if let Some(text) = self.copy_logical_selection() {
            text
        } else {
            let selected = TextSelection::selected_text(window, cx);
            if selected.trim().is_empty() {
                self.selected_output()
            } else {
                selected
            }
        };
        if !text.is_empty() {
            cx.write_to_clipboard(ClipboardItem::new_string(text));
        }
    }

    fn copy_logical_selection(&self) -> Option<String> {
        let sel = self.console.selection.as_ref()?;
        if sel.anchor == sel.cursor {
            return None;
        }
        let ((start_line, start_col), (end_line, end_col)) = sel.normalized();
        let count = self.selected_line_count();
        let mut parts = Vec::new();
        for line_idx in start_line..=end_line.min(count.saturating_sub(1)) {
            let line_text = self.selected_line_text(line_idx);
            let len = line_text.len();
            if line_idx == start_line && line_idx == end_line {
                let start = start_col.min(len);
                let end = end_col.min(len);
                parts.push(line_text[start..end].to_string());
            } else if line_idx == start_line {
                let start = start_col.min(len);
                parts.push(line_text[start..].to_string());
            } else if line_idx == end_line {
                let end = end_col.min(len);
                parts.push(line_text[..end].to_string());
            } else {
                parts.push(line_text);
            }
        }
        let joined = parts.join("\n");
        (!joined.trim().is_empty()).then_some(joined)
    }

    /// 复制按钮与控制台快捷键共用同一份文本。
    fn copy_output(&mut self, cx: &mut Context<Self>) {
        let text = self.selected_output();
        if !text.is_empty() {
            cx.write_to_clipboard(ClipboardItem::new_string(text));
        }
    }

    /// 控制台里的堆栈帧 / 错误行行号（0 基）。macOS 的 Previous/Next Stack Trace
    /// 在这些位置之间跳转。
    fn stack_trace_lines(&self) -> Vec<usize> {
        let Some(session) = self
            .selected_id
            .as_ref()
            .and_then(|id| self.sessions.get(id))
        else {
            return Vec::new();
        };
        (0..session.display_line_count())
            .filter(|index| is_stack_trace_line(session.line_at(*index)))
            .collect()
    }

    /// 跳到上一条 / 下一条堆栈帧。
    ///
    /// 虚拟化列表支持按行定位，不再需要旧实现的“行号 × 行高”像素换算——
    /// 那种换算在开启软换行后只是近似位置，跳转会偏。
    fn jump_stack_trace(&mut self, forward: bool, cx: &mut Context<Self>) {
        let lines = self.stack_trace_lines();
        if lines.is_empty() {
            return;
        }
        // 虚拟列表的滚动偏移是像素；行高固定（Nowrap 单行），换算是精确的。
        let current = (-self.console.handle.offset().y / px(CONSOLE_LINE_HEIGHT)).round() as usize;
        let target = if forward {
            lines.iter().copied().filter(|line| *line > current).min()
        } else {
            lines.iter().copied().filter(|line| *line < current).max()
        };
        let Some(target) = target else {
            return;
        };
        // 跳转后暂停跟随，否则下一块输出会立刻把视图拉回末尾。
        self.console_follow_tail = false;
        self.console.scroll_to_item(target, ScrollStrategy::Top);
        cx.notify();
    }

    /// 打印控制台输出。GPUI 没有系统打印对话框，这里把输出写到临时文件再用
    /// 系统默认程序打开，由该程序负责打印；写盘失败时保持界面不变。
    fn print_output(&mut self, cx: &mut Context<Self>) {
        let text = self.selected_output();
        if text.is_empty() {
            return;
        }
        let path = std::env::temp_dir().join("lithe-run-output.txt");
        if std::fs::write(&path, text).is_err() {
            return;
        }
        let url = format!("file:///{}", path.to_string_lossy().replace('\\', "/"));
        let _ = lithe_platform::current().open_url(&url);
        cx.notify();
    }

    /// 控制台左侧动作条。对齐 macOS `OutputTextView.consoleToolbar` 的六项动作：
    /// 上一条 / 下一条堆栈帧、软换行、滚动到底、打印、清空。
    fn render_console_stripe(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let has_output = self.selected_has_output();
        let has_stack = !self.stack_trace_lines().is_empty();

        v_flex()
            .id("lithe-run-console-actions")
            .w(px(CONSOLE_ACTION_STRIPE_WIDTH))
            .flex_shrink_0()
            .h_full()
            .items_center()
            .gap(px(2.0))
            .pt(px(4.0))
            .min_h(px(0.0))
            .bg(tokens.sidebar)
            .border_r_1()
            .border_color(tokens.divider)
            .child(
                Button::new("lithe-run:prev-stack-trace")
                    .ghost()
                    .small()
                    .child(Icon::new(IconName::ArrowUp).with_size(px(14.0)))
                    .tooltip(tr("Previous Stack Trace"))
                    .disabled(!has_stack)
                    .on_click(cx.listener(|this, _, _window, cx| {
                        this.jump_stack_trace(false, cx);
                    })),
            )
            .child(
                Button::new("lithe-run:next-stack-trace")
                    .ghost()
                    .small()
                    .child(Icon::new(IconName::ArrowDown).with_size(px(14.0)))
                    .tooltip(tr("Next Stack Trace"))
                    .disabled(!has_stack)
                    .on_click(cx.listener(|this, _, _window, cx| {
                        this.jump_stack_trace(true, cx);
                    })),
            )
            .child(
                Button::new("lithe-run:stripe-wrap")
                    .ghost()
                    .small()
                    .child(Icon::new(IconName::Menu).with_size(px(14.0)))
                    .tooltip(tr("Use soft wraps"))
                    .selected(self.wrap_output)
                    .on_click(cx.listener(|this, _, _window, cx| {
                        this.wrap_output = !this.wrap_output;
                        cx.notify();
                    })),
            )
            .child(
                Button::new("lithe-run:scroll-to-end")
                    .ghost()
                    .small()
                    .icon(icon(LitheIcon::ChevronDown))
                    .tooltip(tr("Scroll to the End"))
                    .disabled(!has_output)
                    .on_click(cx.listener(|this, _, _window, cx| this.scroll_to_latest(cx))),
            )
            .child(
                Button::new("lithe-run:print-output")
                    .ghost()
                    .small()
                    .child(Icon::new(IconName::FileText).with_size(px(14.0)))
                    .tooltip(tr("Print"))
                    .disabled(!has_output)
                    .on_click(cx.listener(|this, _, _window, cx| this.print_output(cx))),
            )
            .child(
                Button::new("lithe-run:stripe-clear")
                    .ghost()
                    .small()
                    .child(Icon::new(IconName::Delete).with_size(px(14.0)))
                    .tooltip(tr("Clear Console"))
                    .disabled(!has_output)
                    .on_click(cx.listener(|this, _, _window, cx| this.clear_output(cx))),
            )
            .into_any_element()
    }

    pub(super) fn render_content(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let selected_config = self.selected_configuration();

        let details_header = div()
            .w_full()
            .px(px(14.0))
            .py(px(8.0))
            .border_b_1()
            .border_color(tokens.divider)
            .child(
                div()
                    .text_size(px(12.0))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(tokens.secondary_text)
                    .child(tr("Configuration details")),
            )
            .when_some(selected_config, |this, config| {
                this.child(
                    div()
                        .pt(px(2.0))
                        .text_size(px(14.0))
                        .font_weight(FontWeight::BOLD)
                        .text_color(tokens.primary_text)
                        .child(config.name.clone()),
                )
                .child(
                    h_flex()
                        .pt(px(4.0))
                        .gap(px(20.0))
                        .text_size(px(12.0))
                        .child(
                            h_flex()
                                .gap(px(6.0))
                                .child(div().text_color(tokens.secondary_text).child(tr("Type")))
                                .child(
                                    div()
                                        .text_color(tokens.primary_text)
                                        .child(config.kind_title()),
                                ),
                        )
                        .when_some(config.main_class(), |this, main_class| {
                            this.child(
                                h_flex()
                                    .gap(px(6.0))
                                    .child(
                                        div()
                                            .text_color(tokens.secondary_text)
                                            .child(tr("Main class")),
                                    )
                                    .child(
                                        div()
                                            .text_color(tokens.primary_text)
                                            .font_family(mono_font_family())
                                            .child(main_class.to_string()),
                                    ),
                            )
                        }),
                )
            });

        let output_area = v_flex()
            .flex_1()
            .min_h(px(0.0))
            .min_w(px(0.0))
            .child(
                h_flex()
                    .px(px(14.0))
                    .pt(px(8.0))
                    .gap(px(8.0))
                    .items_center()
                    .child(
                        div()
                            .text_size(px(12.0))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(tokens.secondary_text)
                            .child(tr("Process output")),
                    )
                    .when_some(self.selected_run_mode(), |this, mode| {
                        this.child(
                            div()
                                .px(px(6.0))
                                .rounded(px(3.0))
                                .border_1()
                                .border_color(tokens.divider)
                                .bg(tokens.sidebar)
                                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                                .text_color(tokens.secondary_text)
                                .child(mode_label(mode)),
                        )
                    }),
            )
            .child(div().flex_1().min_h(px(0.0)).min_w(px(0.0)).child(
                if !self.selected_has_output() {
                    div()
                        .size_full()
                        .px(px(14.0))
                        .pt(px(10.0))
                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                        .text_color(tokens.secondary_text)
                        .child(tr("Run a configuration to see process output."))
                        .into_any_element()
                } else {
                    // 行样式只在渲染可视行时构造，不再对整段输出做全文排版。
                    let text_style = self.console_text_style(tokens);
                    let item_sizes = self.console.item_sizes.clone();
                    let console_caret = self.console.caret_snapshot();
                    let palette = AnsiPalette::new(Theme::global(cx).is_dark());
                    let owner = cx.weak_entity();
                    let line_tokens = tokens;
                    div()
                        .id("lithe-run-console")
                        .relative()
                        .size_full()
                        .key_context(CONSOLE_CONTEXT)
                        .track_focus(&self.console_focus)
                        .on_action(cx.listener(Self::on_copy_selection))
                        .on_mouse_down(
                            MouseButton::Left,
                            cx.listener(|this, _, window, cx| this.console_focus.focus(window, cx)),
                        )
                        .child({
                            let selection_snapshot = self.console.selection;
                            div()
                                .id("lithe-run-output")
                                .relative()
                                .size_full()
                                .p(px(PANEL_PADDING))
                                .on_scroll(cx.listener(|this, event: &ScrollEvent, window, cx| {
                                    this.console.on_scroll(event, window, cx);
                                }))
                                .on_mouse_move(cx.listener(
                                    |this, event: &MouseMoveEvent, window, cx| {
                                        // 拖选不改变 hover 或滚动；按住左键拖动时主动
                                        // 请求一帧，让选区背景随鼠标即时更新。
                                        if event.pressed_button.is_some()
                                            && (TextSelection::has_selection(window, cx)
                                                || this.console.has_selection())
                                        {
                                            window.refresh();
                                        }
                                    },
                                ))
                                .on_mouse_up(
                                    MouseButton::Left,
                                    cx.listener(|this, _, _, cx| {
                                        this.console.end_selection();
                                        cx.notify();
                                    }),
                                )
                                // 控制台用 v_virtual_list：行高固定（Nowrap 单行），
                                // 只排版可视行，并暴露 ScrollHandle 给平滑滚动。
                                .child(
                                    v_virtual_list(
                                        cx.entity(),
                                        "lithe-run-output-lines",
                                        item_sizes,
                                        move |this, range, _window, _cx| {
                                            range
                                                .map(|index| {
                                                    let on_caret: ConsoleCaretHandler = {
                                                        let owner = owner.clone();
                                                        Rc::new(move |offset, _window, cx| {
                                                            let _ = owner.update(cx, |this, cx| {
                                                                this.console
                                                                    .set_caret(index, offset);
                                                                this.console
                                                                    .begin_selection(index, offset);
                                                                cx.notify();
                                                            });
                                                        })
                                                    };
                                                    let on_drag: ConsoleCaretHandler = {
                                                        let owner = owner.clone();
                                                        Rc::new(move |offset, _window, cx| {
                                                            let _ = owner.update(cx, |this, cx| {
                                                                this.console.update_selection(
                                                                    index, offset,
                                                                );
                                                                cx.notify();
                                                            });
                                                        })
                                                    };
                                                    let raw_line = this.selected_line_text(index);
                                                    // System 行（退出提示等）用弱化色，
                                                    // 不按普通输出或严重级别着色。
                                                    let mut line_style = text_style.clone();
                                                    if this.selected_line_is_system(index) {
                                                        line_style.color =
                                                            Some(line_tokens.tertiary_text);
                                                    }
                                                    let selected_range = selection_snapshot
                                                        .and_then(|sel| {
                                                            sel.range_for_line(
                                                                index,
                                                                raw_line.len(),
                                                            )
                                                        });
                                                    console_line_element(
                                                        format!("lithe-run-line:{index}"),
                                                        index,
                                                        &raw_line,
                                                        line_style,
                                                        &palette,
                                                        line_tokens,
                                                        console_caret
                                                            .filter(|(line, _)| *line == index)
                                                            .map(|(_, offset)| offset),
                                                        Some(on_caret),
                                                        selected_range,
                                                        Some(on_drag),
                                                        CONSOLE_LINE_HEIGHT,
                                                    )
                                                })
                                                .collect::<Vec<_>>()
                                        },
                                    )
                                    .track_scroll(&self.console.handle)
                                    .size_full(),
                                )
                                .child(console_scrollbar(
                                    &self.console.handle,
                                    "lithe-run-output-scrollbar",
                                ))
                        })
                        .into_any_element()
                },
            ));

        let body = if self.show_details {
            self.render_details(tokens, cx)
        } else {
            v_flex()
                .flex_1()
                .min_h(px(0.0))
                .min_w(px(0.0))
                .child(details_header)
                .child(output_area)
                .into_any_element()
        };

        v_flex()
            .id("lithe-run-content")
            .size_full()
            .min_w(px(0.0))
            .min_h(px(0.0))
            .bg(tokens.editor)
            .child(body)
            .into_any_element()
    }

    /// 控制台行的文本样式。等宽字体 + 按需软换行，整份列表共用一份。
    fn console_text_style(&self, tokens: LitheTokens) -> TextStyleRefinement {
        TextStyleRefinement {
            font_family: Some(mono_font_family().into()),
            font_size: Some(px(LitheMetrics::CODE_FONT_SIZE).into()),
            color: Some(tokens.primary_text),
            white_space: Some(if self.wrap_output {
                WhiteSpace::Normal
            } else {
                WhiteSpace::Nowrap
            }),
            ..Default::default()
        }
    }

    /// 取当前会话第 `index` 行的文本，供虚拟化列表逐行渲染。
    fn selected_line_text(&self, index: usize) -> String {
        self.selected_id
            .as_ref()
            .and_then(|id| self.sessions.get(id))
            .map(|session| session.line_at(index).to_string())
            .unwrap_or_default()
    }

    /// 当前会话第 `index` 行是否是 System 行。
    fn selected_line_is_system(&self, index: usize) -> bool {
        self.selected_id
            .as_ref()
            .and_then(|id| self.sessions.get(id))
            .is_some_and(|session| session.is_system_line(index))
    }
}

/// 「进程输出」后面那颗标签的文案。
fn mode_label(mode: RunMode) -> &'static str {
    match mode {
        RunMode::JvmDirect => tr("Direct JVM"),
        RunMode::MavenGoal => tr("Maven goal"),
        RunMode::BuildToolGoal => tr("Build tool goal"),
        RunMode::Process => tr("Command"),
    }
}

/// 判断一行是否是堆栈帧（Java 的 `at x.y.Foo.bar(Foo.java:42)` 或带
/// `file:line` 的 `at ` 行）。上一/下一条堆栈帧按这些行跳转，与 macOS
/// `ConsoleToolbarAction.previous/next` 的定位依据一致。
#[allow(dead_code)]
fn is_stack_trace_line(line: &str) -> bool {
    let trimmed = line.trim_start();
    let frame = trimmed
        .strip_prefix("at ")
        .or_else(|| trimmed.strip_prefix("Caused by: "))
        .unwrap_or(trimmed);
    if let Some(open) = frame.rfind('(') {
        let inner = frame[open + 1..].trim_end_matches(')');
        if let Some((file, line_number)) = inner.rsplit_once(':') {
            return !file.is_empty()
                && line_number
                    .chars()
                    .all(|character| character.is_ascii_digit());
        }
    }
    false
}
