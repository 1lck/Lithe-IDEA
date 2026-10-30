//! 输入弹窗。
//!
//! 工作台的 New File / New Folder / New Project 共用同一个输入卡片：标题、
//! 可选描述、单行输入框和“取消 / 确认”。组件只表达交互，不校验业务名称；
//! 确认时总是把输入框里的原文交给调用方。

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::{Disableable as _, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    App, AppContext as _, ClickEvent, Context, Entity, EventEmitter, FontWeight,
    InteractiveElement as _, IntoElement, KeyDownEvent, ParentElement, Render, SharedString,
    StatefulInteractiveElement as _, Styled, Subscription, Window, div, px,
};

use crate::{LitheMetrics, current_tokens, tr};

/// 输入弹窗的事件。
pub enum PromptEvent {
    /// 用户确认，携带输入框当前内容（可能为空字符串）。
    Confirm(SharedString),
    /// 用户取消。
    Cancel,
}

/// 弹窗文案与初始值。
pub struct PromptSpec {
    pub title: SharedString,
    pub description: Option<SharedString>,
    pub placeholder: SharedString,
    pub initial: SharedString,
    pub confirm_label: SharedString,
}

impl PromptSpec {
    pub fn new(title: impl Into<SharedString>, placeholder: impl Into<SharedString>) -> Self {
        Self {
            title: title.into(),
            description: None,
            placeholder: placeholder.into(),
            initial: SharedString::from(""),
            confirm_label: tr("Create").into(),
        }
    }

    pub fn description(mut self, text: impl Into<SharedString>) -> Self {
        self.description = Some(text.into());
        self
    }

    pub fn initial(mut self, text: impl Into<SharedString>) -> Self {
        self.initial = text.into();
        self
    }

    pub fn confirm_label(mut self, text: impl Into<SharedString>) -> Self {
        self.confirm_label = text.into();
        self
    }
}

/// 卡片宽度，与工作台其它确认卡片保持一致。
const PROMPT_WIDTH: f32 = 420.0;
/// 卡片内边距。
const PROMPT_PADDING: f32 = 16.0;
/// 卡片内元素间距。
const PROMPT_GAP: f32 = 10.0;
/// 按钮之间与右侧的间距。
const PROMPT_BUTTON_GAP: f32 = 8.0;
/// 键盘上下文；工作台若要追加按键绑定，可复用这个字符串。
const PROMPT_KEY_CONTEXT: &str = "LithePrompt";

impl EventEmitter<PromptEvent> for LithePrompt {}

/// 输入弹窗实体。
///
/// 调用方用 `cx.new(|cx| LithePrompt::new(spec, window, cx))` 创建，订阅
/// [`PromptEvent`] 决定确认后的业务动作，并在事件到达后自行关闭覆盖层。
pub struct LithePrompt {
    spec: PromptSpec,
    input: Entity<InputState>,
    /// 输入变化时重绘，让确认按钮的 disabled 状态跟随内容。
    _input_subscription: Subscription,
}

impl LithePrompt {
    /// 创建后立即把焦点放进输入框。
    pub fn new(spec: PromptSpec, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let input = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder(spec.placeholder.clone())
                .default_value(spec.initial.clone())
        });

        let subscription =
            cx.subscribe(&input, |this, _input, event: &InputEvent, cx| match event {
                InputEvent::PressEnter {
                    secondary: false,
                    shift: false,
                } => this.emit_confirm(cx),
                InputEvent::Change => cx.notify(),
                _ => {}
            });

        input.update(cx, |state, cx| state.focus(window, cx));

        Self {
            spec,
            input,
            _input_subscription: subscription,
        }
    }

    /// 当前输入内容。
    pub fn value(&self, cx: &App) -> SharedString {
        self.input.read(cx).value()
    }

    fn emit_confirm(&mut self, cx: &mut Context<Self>) {
        let value = self.input.read(cx).value();
        cx.emit(PromptEvent::Confirm(value));
    }

    fn emit_cancel(&mut self, cx: &mut Context<Self>) {
        cx.emit(PromptEvent::Cancel);
    }
}

impl Render for LithePrompt {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let tokens = current_tokens(cx);
        let value = self.input.read(cx).value();
        let confirm_disabled = value.as_str().trim().is_empty();

        div()
            .id("lithe-prompt-overlay")
            .absolute()
            .inset_0()
            .size_full()
            .flex()
            .items_center()
            .justify_center()
            .occlude()
            .key_context(PROMPT_KEY_CONTEXT)
            // Enter 交给输入框自身的 InputEvent，Escape 在这里收口；两者都
            // 只在弹窗获得焦点时生效，不注册全局按键绑定。
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, _window, cx| {
                if event.keystroke.key.as_str() == "escape" {
                    cx.stop_propagation();
                    this.emit_cancel(cx);
                }
            }))
            .child(
                div()
                    .id("lithe-prompt-backdrop")
                    .absolute()
                    .inset_0()
                    .size_full()
                    .occlude()
                    .bg(tokens.window.alpha(0.62))
                    .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                        this.emit_cancel(cx);
                    })),
            )
            .child(
                div()
                    .id("lithe-prompt-panel")
                    .occlude()
                    .flex()
                    .flex_col()
                    .w(px(PROMPT_WIDTH))
                    .rounded(px(LitheMetrics::PANE_RADIUS))
                    .overflow_hidden()
                    .bg(tokens.raised)
                    .border_1()
                    .border_color(tokens.panel_border)
                    .p(px(PROMPT_PADDING))
                    .gap(px(PROMPT_GAP))
                    .child(
                        div()
                            .w_full()
                            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(tokens.primary_text)
                            .child(self.spec.title.clone()),
                    )
                    .when_some(self.spec.description.clone(), |this, description| {
                        this.child(
                            div()
                                .w_full()
                                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                                .text_color(tokens.secondary_text)
                                .child(description),
                        )
                    })
                    .child(
                        Input::new(&self.input)
                            .w_full()
                            .aria_label(self.spec.title.clone()),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .justify_end()
                            .gap(px(PROMPT_BUTTON_GAP))
                            .child(
                                Button::new("lithe-prompt-cancel")
                                    .ghost()
                                    .small()
                                    .tab_stop(false)
                                    .label(tr("Cancel"))
                                    .accessibility_label(tr("Cancel"))
                                    .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                                        this.emit_cancel(cx);
                                    })),
                            )
                            .child(
                                Button::new("lithe-prompt-confirm")
                                    .primary()
                                    .small()
                                    .tab_stop(false)
                                    .disabled(confirm_disabled)
                                    .label(self.spec.confirm_label.clone())
                                    .accessibility_label(self.spec.confirm_label.clone())
                                    .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                                        this.emit_confirm(cx);
                                    })),
                            ),
                    ),
            )
    }
}
