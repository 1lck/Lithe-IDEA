//! 控制台动作与渲染：复制、堆栈跳转和虚拟化输出列表。
//!
//! 输出区与动作条对齐 macOS `OutputTextView`：左侧 28pt 动作条（上一条 /
//! 下一条堆栈帧、软换行、滚动到底、打印、清空），虚拟化逐行渲染、ANSI
//! 着色、跨视口选区，以及「不在底部时显示 Jump to latest」浮层。

use std::rc::Rc;

use gpui_kit::assets::IconName;
use gpui_kit::base::TextSelection;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{
    h_flex, v_flex, v_virtual_list, Disableable as _, Icon, Selectable as _, Sizable as _, Theme,
};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, px, AnyElement, ClipboardItem, Context, InteractiveElement as _, IntoElement, MouseButton,
    MouseMoveEvent, ParentElement as _, Pixels, ScrollEvent, ScrollStrategy, SharedString,
    Styled as _, TextStyle, TextStyleRefinement, WhiteSpace, Window,
};
use lithe_ui::i18n::tr;
use lithe_ui::{icon, mono_font_family, LitheIcon, LitheMetrics, LitheTokens};

use crate::console::{console_line_element, console_scrollbar, AnsiPalette, ConsoleCaretHandler};

use super::{
    CopySelection, RunPanel, CONSOLE_ACTION_STRIPE_WIDTH, CONSOLE_CONTEXT, CONSOLE_LINE_HEIGHT,
    OUTPUT_MIN_WIDTH, PANEL_PADDING,
};

/// 距底部多少像素内仍视为“在底部”，与 macOS `bottomThreshold` 的 80pt 一致。
const CONSOLE_BOTTOM_THRESHOLD: f32 = 80.0;

impl RunPanel {
    /// 把行数变化同步给虚拟化列表，并按软换行设置重新测量行高。
    ///
    /// 关闭软换行时每行固定 [`CONSOLE_LINE_HEIGHT`]；开启后按控制台宽度
    /// 把折行后的文本量成多倍行高。换行开关或宽度变化会让旧行高失效，
    /// 此时整体重新测量，否则虚拟列表仍按单行排布，折行内容会互相覆盖。
    pub(super) fn sync_console_lines(&mut self, window: &mut Window) {
        let count = self.selected_line_count();
        let viewport_width = self.console.handle.bounds().size.width;
        // 首帧列表还没绘制过时拿不到宽度；用一个保守的窄宽度测量，宁可多留
        // 空白也不让折行内容互相覆盖。下一帧拿到真实宽度会重新测量。
        let width = if viewport_width <= px(0.0) {
            px(OUTPUT_MIN_WIDTH)
        } else {
            viewport_width
        };
        // 关闭软换行时行高与宽度无关；只有开启时宽度才参与键，避免拖动面板
        // 宽度时做无意义的重排。像素取整避免亚像素抖动反复重建。
        let layout_key = (
            self.wrap_output,
            if self.wrap_output {
                viewport_width.as_f32().round() as i32
            } else {
                0
            },
        );
        if self.console_layout_key != Some(layout_key) {
            self.console_layout_key = Some(layout_key);
            self.console.invalidate_layout();
        }

        let wrap = self.wrap_output;
        let selected = self.selected_id.clone();
        let session = selected.as_ref().and_then(|id| self.sessions.get(id));
        // 与 `console_text_style` 保持同一字体/字号，但直接在渲染期构造样式：
        // `Window::with_text_style` 只允许在 request_layout/prepaint/paint 调用，
        // 在 `Render::render` 里使用会在调试构建触发断言。
        let mut style = window.text_style();
        style.font_family = mono_font_family().into();
        style.font_size = px(LitheMetrics::CODE_FONT_SIZE).into();
        style.white_space = WhiteSpace::Normal;
        let rem_size = window.rem_size();
        let font_size = style.font_size.to_pixels(rem_size);
        let line_height = px(CONSOLE_LINE_HEIGHT);
        let measured_row_height =
            window.pixel_snap(style.line_height.to_pixels(font_size.into(), rem_size));
        let row_height = if measured_row_height < line_height {
            line_height
        } else {
            measured_row_height
        };
        // 闭包只需要读窗口（测量文本），用不可变引用避免与列表的可变借用纠缠。
        let window: &Window = &*window;

        let changed = self.console.sync_line_count_with(count, |index| {
            let Some(session) = session else {
                return line_height;
            };
            if !wrap {
                return line_height;
            }
            wrapped_console_line_height(window, &style, session.line_at(index), width, row_height)
        });
        // 行数变化交给虚拟化列表；是否跟随末尾由 `FollowMode::Tail` 自己决定，
        // 用户上翻后框架会暂停跟随，回到底部时自动恢复，不需要再比对偏移量。
        if changed && self.console_follow_tail && count > 0 {
            self.console
                .scroll_to_item(count - 1, ScrollStrategy::Bottom);
        }
        // 最后一行可能是尚未遇到换行的半行，内容会持续变长；折行高度需要
        // 跟着更新，否则开启软换行后长行只按单行高度绘制。
        if wrap && count > 0 {
            if let Some(session) = session {
                let height = wrapped_console_line_height(
                    window,
                    &style,
                    session.line_at(count - 1),
                    width,
                    row_height,
                );
                self.console.set_line_height(count - 1, height);
            }
        }
    }

    /// 控制台当前是否停在底部（对齐 macOS `OutputTextView.bottomThreshold`）。
    fn console_at_bottom(&self) -> bool {
        let offset = self.console.handle.offset();
        let max_offset = self.console.handle.max_offset();
        (-offset.y + px(CONSOLE_BOTTOM_THRESHOLD)) >= max_offset.y
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
                    .icon(icon(LitheIcon::WrapText))
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
                    .child(Icon::new(IconName::ArrowDownToLine).with_size(px(14.0)))
                    .tooltip(tr("Scroll to the End"))
                    .disabled(!has_output)
                    .on_click(cx.listener(|this, _, _window, cx| this.scroll_to_latest(cx))),
            )
            .child(
                Button::new("lithe-run:print-output")
                    .ghost()
                    .small()
                    .child(Icon::new(IconName::Printer).with_size(px(14.0)))
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

    /// 选中配置的内容区：详情 tab 或控制台。
    ///
    /// macOS `configurationContent` 在 Console tab 只渲染输出，不再叠加
    /// 「Configuration details / Process output」之类的标题行。
    pub(super) fn render_content(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        if self.show_details {
            return self.render_details(tokens, cx);
        }
        div()
            .id("lithe-run-content")
            .size_full()
            .min_w(px(0.0))
            .min_h(px(0.0))
            .bg(tokens.editor)
            .child(self.render_output_pane(
                tr("Start this configuration to see its output here."),
                tokens,
                cx,
            ))
            .into_any_element()
    }

    /// 控制台输出区；项目级输出与单配置输出共用。
    pub(super) fn render_output_pane(
        &self,
        empty_message: &'static str,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        if !self.selected_has_output() {
            return super::render::empty_output_state(empty_message, tokens);
        }
        let at_bottom = self.console_at_bottom();

        // 行样式只在渲染可视行时构造，不再对整段输出做全文排版。
        let text_style = self.console_text_style(tokens);
        let item_sizes = self.console.item_sizes.clone();
        let console_caret = self.console.caret_snapshot();
        let palette = AnsiPalette::new(Theme::global(cx).is_dark());
        let owner = cx.weak_entity();
        let line_tokens = tokens;
        let selection_snapshot = self.console.selection;

        let console = div()
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
            .child(
                div()
                    .id("lithe-run-output")
                    .relative()
                    .size_full()
                    .p(px(PANEL_PADDING))
                    .on_scroll(cx.listener(|this, event: &ScrollEvent, window, cx| {
                        this.console.on_scroll(event, window, cx);
                        // 用户上翻后暂停跟随，回到底部自动恢复；与 macOS 的
                        // “不在底部才显示 Jump to latest”同一判据。
                        let at_bottom = this.console_at_bottom();
                        if this.console_follow_tail != at_bottom {
                            this.console_follow_tail = at_bottom;
                        }
                    }))
                    .on_mouse_move(cx.listener(|this, event: &MouseMoveEvent, window, cx| {
                        // 拖选不改变 hover 或滚动；按住左键拖动时主动
                        // 请求一帧，让选区背景随鼠标即时更新。
                        if event.pressed_button.is_some()
                            && (TextSelection::has_selection(window, cx)
                                || this.console.has_selection())
                        {
                            window.refresh();
                        }
                    }))
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
                                                    this.console.set_caret(index, offset);
                                                    this.console.begin_selection(index, offset);
                                                    cx.notify();
                                                });
                                            })
                                        };
                                        let on_drag: ConsoleCaretHandler = {
                                            let owner = owner.clone();
                                            Rc::new(move |offset, _window, cx| {
                                                let _ = owner.update(cx, |this, cx| {
                                                    this.console.update_selection(index, offset);
                                                    cx.notify();
                                                });
                                            })
                                        };
                                        let raw_line = this.selected_line_text(index);
                                        // System 行（退出提示等）用弱化色，
                                        // 不按普通输出或严重级别着色。
                                        let mut line_style = text_style.clone();
                                        if this.selected_line_is_system(index) {
                                            line_style.color = Some(line_tokens.tertiary_text);
                                        }
                                        let selected_range = selection_snapshot.and_then(|sel| {
                                            sel.range_for_line(index, raw_line.len())
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
                    )),
            );

        let pane = h_flex()
            .flex_1()
            .h_full()
            .min_h(px(0.0))
            .min_w(px(0.0))
            .items_stretch()
            .child(self.render_console_stripe(tokens, cx))
            .child(div().flex_1().min_w(px(0.0)).child(console));

        div()
            .relative()
            .size_full()
            .min_h(px(0.0))
            .min_w(px(0.0))
            .bg(tokens.editor)
            .child(pane)
            .when(!at_bottom, |this| {
                this.child(
                    div()
                        .id("lithe-run-jump-to-latest")
                        .absolute()
                        .bottom(px(10.0))
                        .right(px(14.0))
                        .child(
                            Button::new("lithe-run:jump-to-latest")
                                .small()
                                .label(tr("Jump to latest"))
                                .on_click(cx.listener(|this, _, _window, cx| {
                                    this.scroll_to_latest(cx);
                                })),
                        ),
                )
            })
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

/// 一行输出在给定宽度下折行后的绘制高度。
///
/// 虚拟列表按传入的行高摆放每一行，软换行开启后必须用折行后的真实行数
/// 计算高度，否则后续行仍按单行高度定位，折出来的文本会被下一行覆盖。
/// 这里用绘制时的同一字体、字号和宽度交给 GPUI 重新排版；测量前按绘制
/// 规则去掉 ANSI 控制序列并展开 Tab，避免把不可见字符算进行宽。
fn wrapped_console_line_height(
    window: &Window,
    style: &TextStyle,
    text: &str,
    wrap_width: Pixels,
    row_height: Pixels,
) -> Pixels {
    if text.is_empty() || wrap_width <= px(0.0) {
        return row_height;
    }
    // 渲染时会把 Tab 展开成制表位、去掉 ANSI 转义；这里先还原成可见文本，
    // 否则含颜色/Tab 的长行会误判行宽。
    let visible = super::state::strip_ansi(text);
    let shaped: SharedString = if visible.contains('\t') {
        SharedString::from(visible.replace('\t', "        "))
    } else {
        SharedString::from(visible)
    };
    let font_size = style.font_size.to_pixels(window.rem_size());
    let runs = [style.to_run(shaped.len())];
    let Ok(lines) =
        window
            .text_system()
            .shape_text(shaped, font_size, &runs, Some(wrap_width), None)
    else {
        return row_height;
    };
    let mut total = px(0.0);
    for line in &lines {
        total += line.size(row_height).height;
    }
    if total < row_height {
        row_height
    } else {
        total
    }
}

/// 判断一行是否是堆栈帧（Java 的 `at x.y.Foo.bar(Foo.java:42)` 或带
/// `file:line` 的 `at ` 行）。上一/下一条堆栈帧按这些行跳转，与 macOS
/// `ConsoleToolbarAction.previous/next` 的定位依据一致。
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
