//! 跳转到行（Go to Line）小弹窗。
//!
//! 对齐 Tauri `editor.goToLine` 入口：数字输入 + Enter 确认，确认后通过
//! [`GoToLineEvent::Confirm`] 把 1-based 行号交给上层，由 `EditorView::go_to_line`
//! 做钳制与跳转；本模块不直接操作编辑器。

use gpui_kit::assets::IconName;
use gpui_kit::component::input::InputEvent;
use gpui_kit::component::{h_flex, v_flex, Icon};
use gpui_kit::{
    div, px, rgba, Context, EventEmitter, FocusHandle, InteractiveElement as _, IntoElement,
    KeyDownEvent, ParentElement as _, Render, Styled as _, Subscription, Window,
};

use crate::theme::ThemeColors;
use crate::workbench::search_input::SearchInput;

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
    /// 搜索框（复用统一搜索输入实现：IME / 粘贴由组件处理）。
    search: SearchInput,
    _search_subscription: Subscription,
    /// 打开时需要在下一帧复位并聚焦搜索框（只做一次）。
    pending_reset: bool,
    /// 需要对输入框施加的净化值（只允许数字、最长 6 位）；渲染时应用。
    pending_sanitized: Option<String>,
}

impl EventEmitter<GoToLineEvent> for GoToLineModal {}

impl GoToLineModal {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let search = SearchInput::new(
            crate::i18n::menu_text(cx, "goToLine.placeholder"),
            window,
            cx,
        );
        let _search_subscription = search.subscribe(cx, |this, event, cx| match event {
            InputEvent::Change => {
                let raw = this.search.value(cx);
                // 只保留 ASCII 数字，最多 6 位（对齐原有单行数字输入限制）。
                let sanitized: String =
                    raw.chars().filter(|c| c.is_ascii_digit()).take(6).collect();
                this.input = sanitized.clone();
                if sanitized != raw {
                    this.pending_sanitized = Some(sanitized);
                }
                cx.notify();
            }
            InputEvent::PressEnter { .. } => this.confirm(cx),
            _ => {}
        });
        Self {
            input: String::new(),
            focus_handle: cx.focus_handle(),
            search,
            _search_subscription,
            pending_reset: true,
            pending_sanitized: None,
        }
    }

    /// 复位到初始状态：清空输入。
    pub fn reset(&mut self, cx: &mut Context<Self>) {
        self.input.clear();
        self.pending_reset = true;
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
        // 打开后只复位/聚焦搜索框一次；不要每帧抢焦点（否则输入框打不进字）。
        if self.pending_reset {
            self.pending_reset = false;
            self.search.set_value("", window, cx);
            self.search.focus(window, cx);
        }
        if let Some(sanitized) = self.pending_sanitized.take() {
            self.search.set_value(sanitized, window, cx);
        }

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
            .on_key_down(cx.listener(|_this, event: &KeyDownEvent, _window, cx| {
                // 字符输入由搜索框处理；这里只管 Esc（回车经搜索框的
                // `InputEvent::PressEnter` 分发到 `confirm`）。
                if event.keystroke.key.as_str() == "escape" {
                    cx.emit(GoToLineEvent::Close);
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
                            .child(self.search.element())
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
