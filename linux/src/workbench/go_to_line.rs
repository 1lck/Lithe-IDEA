//! 跳转到行（Go to Line）小弹窗。
//!
//! 对齐 Tauri `editor.goToLine` 入口：数字输入 + Enter 确认，确认后通过
//! [`GoToLineEvent::Confirm`] 把 1-based 行号交给上层，由 `EditorView::go_to_line`
//! 做钳制与跳转；本模块不直接操作编辑器。

use gpui_kit::assets::IconName;
use gpui_kit::component::{h_flex, v_flex, Icon};
use gpui_kit::{
    div, px, rgba, Context, EventEmitter, FocusHandle, InteractiveElement as _, IntoElement,
    KeyDownEvent, ParentElement as _, Render, Styled as _, Window,
};

use crate::theme::ThemeColors;

/// 跳转到行弹窗对外事件。
#[derive(Debug, Clone)]
pub enum GoToLineEvent {
    /// 确认跳转，携带 1-based 行号。
    Confirm(u32),
    /// 请求关闭弹窗。
    Close,
}

/// 居中的单行输入小弹窗。
pub struct GoToLineModal {
    pub input: String,
    pub focus_handle: FocusHandle,
}

impl EventEmitter<GoToLineEvent> for GoToLineModal {}

impl GoToLineModal {
    pub fn new(cx: &mut Context<Self>) -> Self {
        Self {
            input: String::new(),
            focus_handle: cx.focus_handle(),
        }
    }

    /// 复位到初始状态：清空输入。
    pub fn reset(&mut self, cx: &mut Context<Self>) {
        self.input.clear();
        cx.notify();
    }

    /// 解析输入并确认：仅接受 `>= 1` 的数字，其余输入忽略。
    fn confirm(&self, cx: &mut Context<Self>) {
        if let Ok(n) = self.input.trim().parse::<u32>() {
            if n >= 1 {
                cx.emit(GoToLineEvent::Confirm(n));
            }
        }
    }
}

impl Render for GoToLineModal {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // 请求聚焦以接收按键输入
        window.focus(&self.focus_handle, cx);

        // 全屏半透明遮罩：点击空白处关闭
        div()
            .id("go-to-line-backdrop")
            .track_focus(&self.focus_handle)
            .absolute()
            .inset_0()
            .bg(rgba(0x00000088))
            .flex()
            .items_center()
            .justify_center()
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, _window, cx| {
                let key = event.keystroke.key.as_str();
                match key {
                    "escape" => {
                        cx.emit(GoToLineEvent::Close);
                    }
                    "enter" => {
                        this.confirm(cx);
                    }
                    "backspace" => {
                        this.input.pop();
                        cx.notify();
                    }
                    _ => {
                        // 无修饰键时只接受 ASCII 数字，最多 6 位。
                        if !event.keystroke.modifiers.control
                            && !event.keystroke.modifiers.alt
                            && !event.keystroke.modifiers.platform
                            && this.input.len() < 6
                        {
                            let mut digit: Option<char> = None;
                            if let Some(ch) = &event.keystroke.key_char {
                                let mut chars = ch.chars();
                                if let (Some(c), None) = (chars.next(), chars.next()) {
                                    if c.is_ascii_digit() {
                                        digit = Some(c);
                                    }
                                }
                            } else if key.chars().count() == 1 {
                                if let Some(c) = key.chars().next() {
                                    if c.is_ascii_digit() {
                                        digit = Some(c);
                                    }
                                }
                            }
                            if let Some(c) = digit {
                                this.input.push(c);
                                cx.notify();
                            }
                        }
                    }
                }
            }))
            .on_mouse_down(
                gpui_kit::MouseButton::Left,
                cx.listener(|_this, _event, _window, cx| {
                    cx.emit(GoToLineEvent::Close);
                }),
            )
            .child(
                v_flex()
                    .id("go-to-line-card")
                    .w(px(400.0))
                    .bg(ThemeColors::surface())
                    .border_1()
                    .border_color(ThemeColors::border())
                    .rounded_lg()
                    .shadow_lg()
                    .overflow_hidden()
                    .on_mouse_down(
                        gpui_kit::MouseButton::Left,
                        cx.listener(|_this, _event, _window, cx| {
                            // 卡片内点击不冒泡到遮罩，避免误关闭
                            cx.stop_propagation();
                        }),
                    )
                    .child(
                        // 标题行
                        h_flex()
                            .h(px(36.0))
                            .w_full()
                            .items_center()
                            .px_4()
                            .border_b_1()
                            .border_color(ThemeColors::border())
                            .text_sm()
                            .text_color(ThemeColors::foreground())
                            .child(crate::i18n::menu_text(cx, "goToLine.title").to_string()),
                    )
                    .child(
                        // 输入行：行号图标 + 输入串/占位 + Enter 徽标
                        h_flex()
                            .h(px(52.0))
                            .w_full()
                            .items_center()
                            .gap_2p5()
                            .px_4()
                            .border_b_1()
                            .border_color(ThemeColors::border())
                            .child(
                                Icon::new(IconName::Hash)
                                    .size(px(16.0))
                                    .text_color(ThemeColors::primary()),
                            )
                            .child(
                                h_flex()
                                    .flex_1()
                                    .items_center()
                                    .gap_1()
                                    .child(
                                        div()
                                            .text_sm()
                                            .text_color(if self.input.is_empty() {
                                                ThemeColors::subtle_foreground()
                                            } else {
                                                ThemeColors::foreground()
                                            })
                                            .child(if self.input.is_empty() {
                                                crate::i18n::menu_text(cx, "goToLine.placeholder")
                                                    .to_string()
                                            } else {
                                                self.input.clone()
                                            }),
                                    )
                                    .child(
                                        // 静态光标条，提示可输入
                                        div().w(px(2.0)).h(px(16.0)).bg(ThemeColors::primary()),
                                    ),
                            )
                            .child(shortcut_badge("Enter")),
                    )
                    .child(
                        // 底部提示行
                        div()
                            .w_full()
                            .px_4()
                            .py_2()
                            .text_xs()
                            .text_color(ThemeColors::subtle_foreground())
                            .child(crate::i18n::menu_text(cx, "goToLine.hint").to_string()),
                    ),
            )
    }
}

/// 快捷键/键位徽标。
fn shortcut_badge(label: &str) -> impl IntoElement {
    div()
        .px_1p5()
        .py(px(1.0))
        .rounded_sm()
        .bg(ThemeColors::accent())
        .border_1()
        .border_color(ThemeColors::border())
        .text_xs()
        .text_color(ThemeColors::muted_foreground())
        .child(label.to_string())
}
