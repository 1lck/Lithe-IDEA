//! 输入弹窗卡片。
//!
//! 工作台的 New File / New Folder / New Project 共用同一张输入卡片：标题、
//! 可选描述、单行输入框和“取消 / 确认”。组件只表达交互，不校验业务名称；
//! 确认时总是把输入框里的原文交给调用方。
//!
//! 遮罩、居中、面板底色与 Escape / 焦点归工作台的覆盖层系统所有；本组件只
//! 渲染卡片内容，避免同一渲染树里出现两套背板与重复的 `ElementId`。

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::{Disableable as _, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    App, AppContext as _, ClickEvent, Context, Entity, EventEmitter, FontWeight, IntoElement,
    ParentElement, Render, SharedString, Styled, Subscription, Window, div, px,
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

/// 卡片内元素间距。
const PROMPT_GAP: f32 = 10.0;
/// 按钮之间与右侧的间距。
const PROMPT_BUTTON_GAP: f32 = 8.0;

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

        // 卡片外壳（宽度、底色、圆角、内边距、遮罩与 Escape）由工作台的
        // 覆盖层提供；这里只排布内容，避免双层背板与重复的 ElementId。
        div()
            .flex()
            .flex_col()
            .w_full()
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
            )
    }
}
