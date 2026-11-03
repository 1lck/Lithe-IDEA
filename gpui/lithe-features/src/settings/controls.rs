//! 设置页可复用的行、卡片与控件。
//!
//! 从原 `settings.rs` 尾部等价拆出；这些形状被多个页面复用，签名与行为
//! 与拆分前完全一致。

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::Input;
use gpui_kit::component::switch::Switch;
use gpui_kit::component::{Disableable as _, Sizable as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, ClickEvent, App, FontWeight, IntoElement, ParentElement as _, SharedString,
    Styled, Window, div, px, Entity,
};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheMetrics, LitheTokens, MONO_FONT_FAMILY};

use super::state::{
    ChoiceAction, StepperAction, ToggleAction, SETTINGS_BUTTON_HEIGHT, SETTINGS_BUTTON_RADIUS,
    SETTINGS_CONTROL_GAP, SETTINGS_OPTION_MIN_WIDTH, SETTINGS_STEPPER_WIDTH,
};
use super::SettingsView;

/// 运行配置编辑器的一行只读详情。
pub(super) fn run_detail_line(
    label: &'static str,
    value: String,
    monospaced: bool,
    tokens: LitheTokens,
) -> AnyElement {
    let mut value_element = div()
        .flex_1()
        .min_w(px(0.0))
        .truncate()
        .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
        .text_color(tokens.primary_text)
        .child(value);
    if monospaced {
        value_element = value_element.font_family(MONO_FONT_FAMILY);
    }
    h_flex()
        .w_full()
        .items_center()
        .gap(px(8.0))
        .child(
            div()
                .w(px(120.0))
                .flex_shrink_0()
                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                .text_color(tokens.secondary_text)
                .child(tr(label)),
        )
        .child(value_element)
        .into_any_element()
}

/// 运行配置编辑器的文本字段：标签、控件与可选说明。
pub(super) fn run_text_field(
    label: &'static str,
    control: AnyElement,
    hint: Option<&'static str>,
    tokens: LitheTokens,
) -> AnyElement {
    let mut field = v_flex()
        .w_full()
        .gap(px(4.0))
        .child(
            div()
                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                .text_color(tokens.primary_text)
                .child(tr(label)),
        )
        .child(control);
    if let Some(hint) = hint {
        field = field.child(
            div()
                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                .text_color(tokens.secondary_text)
                .child(tr(hint)),
        );
    }
    field.into_any_element()
}

/// 分组标题 + 可选说明 + 设置行。
///
/// 对齐 Tauri `Section`：没有卡片背景和圆角，标题右侧是一条细分隔线，行与行
/// 之间靠间距分开，而不是每行画一条底线。
pub(super) fn section_card(
    title: &'static str,
    note: Option<&'static str>,
    body: AnyElement,
    tokens: LitheTokens,
) -> AnyElement {
    let mut section = div().w_full().flex().flex_col().gap(px(10.0)).child(
        div()
            .w_full()
            .flex()
            .items_center()
            .gap(px(8.0))
            .child(
                div()
                    .flex_shrink_0()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(tokens.secondary_text)
                    .child(tr(title)),
            )
            .child(div().flex_1().h(px(1.0)).bg(tokens.divider)),
    );

    if let Some(note) = note {
        section = section.child(
            div()
                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                .text_color(tokens.secondary_text)
                .child(tr(note)),
        );
    }

    section.child(body).into_any_element()
}

/// 只读说明。用于诚实标出本构建尚未接入的能力。
pub(super) fn note_card(text: SharedString, tokens: LitheTokens) -> AnyElement {
    div()
        .w_full()
        .flex()
        .flex_col()
        .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
        .text_color(tokens.secondary_text)
        .child(text)
        .into_any_element()
}

/// 小号说明文字，用于状态与健康计数。
pub(super) fn caption_line(text: SharedString, tokens: LitheTokens) -> AnyElement {
    div()
        .w_full()
        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
        .text_color(tokens.tertiary_text)
        .child(text)
        .into_any_element()
}

/// 右对齐的等宽路径。
pub(super) fn code_text(text: SharedString, tokens: LitheTokens) -> AnyElement {
    div()
        .max_w(px(352.0))
        .text_right()
        .font_family(MONO_FONT_FAMILY)
        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
        .text_color(tokens.secondary_text)
        .child(text)
        .into_any_element()
}

/// 带说明的设置行：说明在标签下方，控件靠右。
pub(super) fn described_row(
    label: &'static str,
    description: Option<SharedString>,
    control: AnyElement,
    tokens: LitheTokens,
) -> AnyElement {
    let mut text = v_flex().min_w(px(0.0)).gap(px(2.0)).child(
        div()
            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
            .text_color(tokens.primary_text)
            .child(tr(label)),
    );
    if let Some(description) = description {
        text = text.child(
            div()
                .max_w(px(420.0))
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(tokens.tertiary_text)
                .child(description),
        );
    }
    div()
        .w_full()
        .flex()
        .flex_wrap()
        .items_center()
        .justify_between()
        .gap_x(px(8.0))
        .gap_y(px(4.0))
        .child(text)
        .child(control)
        .into_any_element()
}

/// 日志页的互斥筛选行；与 [`choice_row`] 的区别是直接调用视图方法。
pub(super) fn log_choice_row(
    label: &'static str,
    id_prefix: &'static str,
    options: &'static [(&'static str, &'static str)],
    selected: &str,
    apply: fn(&mut SettingsView, &'static str, &mut gpui_kit::Context<SettingsView>),
    cx: &mut gpui_kit::Context<SettingsView>,
    tokens: LitheTokens,
) -> AnyElement {
    let mut controls = h_flex().flex_wrap().gap(px(SETTINGS_CONTROL_GAP));
    for &(value, title) in options {
        let is_selected = selected.eq_ignore_ascii_case(value);
        controls = controls.child(
            Button::new(format!("{id_prefix}:{value}"))
                .small()
                .h(px(SETTINGS_BUTTON_HEIGHT))
                .rounded(px(SETTINGS_BUTTON_RADIUS))
                .min_w(px(SETTINGS_OPTION_MIN_WIDTH))
                .when(is_selected, |button| button.primary())
                .when(!is_selected, |button| button.secondary())
                .label(tr(title))
                .on_click(cx.listener(move |this, _: &ClickEvent, _window, cx| {
                    apply(this, value, cx);
                })),
        );
    }
    setting_row(
        label,
        controls.into_any_element(),
        SharedString::default(),
        tokens,
    )
}

/// 小号设置按钮。
pub(super) fn log_button(
    id: &'static str,
    label: String,
    disabled: bool,
    handler: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
) -> AnyElement {
    Button::new(id)
        .small()
        .h(px(SETTINGS_BUTTON_HEIGHT))
        .rounded(px(SETTINGS_BUTTON_RADIUS))
        .secondary()
        .label(label)
        .disabled(disabled)
        .on_click(handler)
        .into_any_element()
}

/// 行内确认条，替代 Tauri 的 `showConfirmDialog`。
pub(super) fn confirm_strip(
    id: &'static str,
    message: SharedString,
    confirm_label: String,
    cancel_label: String,
    on_confirm: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    on_cancel: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    tokens: LitheTokens,
) -> AnyElement {
    let confirm_id = format!("{id}:confirm");
    let cancel_id = format!("{id}:cancel");
    div()
        .w_full()
        .flex()
        .flex_col()
        .gap(px(6.0))
        .rounded(px(LitheMetrics::CONTROL_RADIUS))
        .border_1()
        .border_color(tokens.divider)
        .bg(tokens.raised)
        .p(px(8.0))
        .child(
            div()
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(tokens.secondary_text)
                .child(message),
        )
        .child(
            h_flex()
                .gap(px(SETTINGS_CONTROL_GAP))
                .child(
                    Button::new(confirm_id)
                        .small()
                        .h(px(SETTINGS_BUTTON_HEIGHT))
                        .rounded(px(SETTINGS_BUTTON_RADIUS))
                        .primary()
                        .label(confirm_label)
                        .on_click(on_confirm),
                )
                .child(
                    Button::new(cancel_id)
                        .small()
                        .h(px(SETTINGS_BUTTON_HEIGHT))
                        .rounded(px(SETTINGS_BUTTON_RADIUS))
                        .secondary()
                        .label(cancel_label)
                        .on_click(on_cancel),
                ),
        )
        .into_any_element()
}

/// 日志模块 id → 页面名称。
pub(super) fn log_category_title(category: &str) -> String {
    use super::state::LOG_CATEGORY_OPTIONS;
    let value = if category == "app" { "application" } else { category };
    LOG_CATEGORY_OPTIONS
        .iter()
        .find(|(id, _)| *id == value)
        .map(|(_, title)| tr(title).to_string())
        .unwrap_or_else(|| category.to_string())
}

/// 回退原因 → 说明文案，与 Tauri `settings.logs.fallback.*` 对齐。
pub(super) fn log_fallback_description(reason: &str) -> SharedString {
    SharedString::from(match reason {
        "notWritable" => tr(
            "The configured directory is not writable. This session is writing to the default location.",
        ),
        "unavailable" => tr(
            "The configured directory is unavailable. This session is writing to the default location.",
        ),
        _ => tr(
            "Application file logging is unavailable. Lithe is continuing with console diagnostics only.",
        ),
    })
}

/// 由外部子系统拥有、当前不可编辑的状态块。
pub(super) fn status_card(text: SharedString, tokens: LitheTokens) -> AnyElement {
    div()
        .w_full()
        .flex()
        .flex_col()
        .gap(px(SETTINGS_CONTROL_GAP))
        .child(
            div()
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(tokens.tertiary_text)
                .child(tr("Status")),
        )
        .child(
            div()
                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                .text_color(tokens.primary_text)
                .child(text),
        )
        .into_any_element()
}

/// “标签 + 控件”行。
///
/// 对齐 Tauri `SettingRow`：标签和控件在同一行、从左排布，空间不足时换行；
/// 不再使用固定标签列、右侧 badge 或每行分隔线。
pub(super) fn setting_row(
    label: &'static str,
    control: AnyElement,
    _value: SharedString,
    tokens: LitheTokens,
) -> AnyElement {
    div()
        .w_full()
        .min_h(px(28.0))
        .flex()
        .flex_wrap()
        .items_center()
        .gap_x(px(8.0))
        .gap_y(px(4.0))
        .child(
            div()
                .min_w(px(0.0))
                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                .text_color(tokens.primary_text)
                .child(tr(label)),
        )
        .child(div().min_w(px(0.0)).flex().items_center().child(control))
        .into_any_element()
}

/// 只读的“标签 + 值”行，排版与 [`setting_row`] 一致。
pub(super) fn readonly_row(label: &'static str, value: SharedString, tokens: LitheTokens) -> AnyElement {
    div()
        .w_full()
        .min_h(px(28.0))
        .flex()
        .flex_wrap()
        .items_center()
        .gap_x(px(8.0))
        .gap_y(px(4.0))
        .child(
            div()
                .min_w(px(0.0))
                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                .text_color(tokens.primary_text)
                .child(tr(label)),
        )
        .child(
            div()
                .min_w(px(0.0))
                .truncate()
                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                .text_color(tokens.secondary_text)
                .child(value),
        )
        .into_any_element()
}

/// 一组互斥选项按钮。值不变时 `commit` 不会触发，因此点击不会多余写盘。
pub(super) fn choice_row(
    label: &'static str,
    id_prefix: &'static str,
    options: &'static [(&'static str, &'static str)],
    selected: &str,
    action: ChoiceAction,
    cx: &mut gpui_kit::Context<SettingsView>,
    tokens: LitheTokens,
) -> AnyElement {
    let mut controls = div()
        .flex()
        .flex_row()
        .items_center()
        .flex_wrap()
        .gap(px(SETTINGS_CONTROL_GAP));

    for &(value, title) in options {
        let is_selected = selected.eq_ignore_ascii_case(value);
        controls = controls.child(
            Button::new(format!("{id_prefix}:{value}"))
                .small()
                // 同一组选项统一高度、圆角和最小宽度。
                .h(px(SETTINGS_BUTTON_HEIGHT))
                .rounded(px(SETTINGS_BUTTON_RADIUS))
                .min_w(px(SETTINGS_OPTION_MIN_WIDTH))
                .when(is_selected, |button| button.primary())
                .when(!is_selected, |button| button.secondary())
                .label(tr(title))
                .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                    this.apply_choice(action, value, window, cx);
                })),
        );
    }

    setting_row(
        label,
        controls.into_any_element(),
        SharedString::default(),
        tokens,
    )
}

/// 布尔开关行：标签、勾选态与写入动作。
pub(super) fn toggle_row(
    label: &'static str,
    id: &'static str,
    checked: bool,
    action: ToggleAction,
    cx: &mut gpui_kit::Context<SettingsView>,
    tokens: LitheTokens,
) -> AnyElement {
    setting_row(
        label,
        switch_control(
            id,
            checked,
            label,
            cx.listener(move |this, checked: &bool, window, cx| {
                this.apply_toggle(action, *checked, window, cx);
            }),
        ),
        on_off(checked),
        tokens,
    )
}

/// 带标题的单行输入框；隐藏路径模式在 GPUI 侧用逗号分隔。
pub(super) fn pattern_field(
    label: &'static str,
    state: &Entity<gpui_kit::component::input::InputState>,
    tokens: LitheTokens,
) -> AnyElement {
    div()
        .w_full()
        .flex()
        .flex_col()
        .gap(px(6.0))
        .child(
            div()
                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                .text_color(tokens.primary_text)
                .child(tr(label)),
        )
        .child(Input::new(state).small())
        .into_any_element()
}

/// 带标题的多行文本域；对齐 Tauri 隐藏路径的两个 Textarea。
pub(super) fn pattern_textarea_field(
    label: &'static str,
    state: &Entity<gpui_kit::component::input::TextareaState>,
    tokens: LitheTokens,
) -> AnyElement {
    div()
        .w_full()
        .flex()
        .flex_col()
        .gap(px(6.0))
        .child(
            div()
                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                .text_color(tokens.primary_text)
                .child(tr(label)),
        )
        .child(gpui_kit::component::input::Textarea::new(state).w_full())
        .into_any_element()
}

/// “- 值 +”数值步进器，末尾附带恢复默认值的按钮。
#[allow(clippy::too_many_arguments)]
pub(super) fn stepper_row(
    label: &'static str,
    id_prefix: &'static str,
    current: f32,
    min: f32,
    max: f32,
    default: f32,
    action: StepperAction,
    value: SharedString,
    cx: &mut gpui_kit::Context<SettingsView>,
    tokens: LitheTokens,
) -> AnyElement {
    let controls = div()
        .flex()
        .flex_row()
        .items_center()
        .gap(px(SETTINGS_CONTROL_GAP))
        .child(
            Button::new(format!("{id_prefix}:decrease"))
                .small()
                .h(px(SETTINGS_BUTTON_HEIGHT))
                .w(px(SETTINGS_STEPPER_WIDTH))
                .rounded(px(SETTINGS_BUTTON_RADIUS))
                .secondary()
                .label(tr("-"))
                .disabled(current <= min)
                .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                    this.apply_step(action, -1, window, cx);
                })),
        )
        .child(
            Button::new(format!("{id_prefix}:increase"))
                .small()
                .h(px(SETTINGS_BUTTON_HEIGHT))
                .w(px(SETTINGS_STEPPER_WIDTH))
                .rounded(px(SETTINGS_BUTTON_RADIUS))
                .secondary()
                .label(tr("+"))
                .disabled(current >= max)
                .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                    this.apply_step(action, 1, window, cx);
                })),
        )
        // “↺”是语言无关符号，避免为设置页新增未翻译的英文按钮。
        .child(
            Button::new(format!("{id_prefix}:reset"))
                .small()
                .h(px(SETTINGS_BUTTON_HEIGHT))
                .w(px(SETTINGS_STEPPER_WIDTH))
                .rounded(px(SETTINGS_BUTTON_RADIUS))
                .secondary()
                .label("↺")
                .disabled((current - default).abs() < 0.5)
                .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                    this.apply_reset(action, window, cx);
                })),
        );

    setting_row(label, controls.into_any_element(), value, tokens)
}

/// 编辑器字体预览块：跟随所选字体族、字号与连字设置（对齐 Tauri
/// `settings-panels.tsx` 的预览块）。
///
/// `font_family` 为空时使用内置等宽字体（与编辑器实际生效值一致）。
pub(super) fn font_preview(
    font_family: &str,
    font_size: f32,
    ligatures: bool,
    tokens: LitheTokens,
) -> AnyElement {
    let family = if font_family.trim().is_empty() {
        lithe_ui::mono_font_family().to_string()
    } else {
        font_family.trim().to_string()
    };
    let sample = if ligatures {
        "The quick brown fox 0123456789\nif (a != b) { x => a->b; } // fi fl"
    } else {
        "The quick brown fox 0123456789\nif (a != b) { x => a->b; }"
    };

    v_flex()
        .w_full()
        .gap(px(SETTINGS_CONTROL_GAP))
        .child(
            div()
                .w_full()
                .p(px(10.0))
                .rounded(px(LitheMetrics::CONTROL_RADIUS))
                .border_1()
                .border_color(tokens.divider)
                .bg(tokens.raised)
                .text_size(px(font_size.max(9.0).min(32.0)))
                .font_family(family.as_str())
                .text_color(tokens.primary_text)
                .child(sample),
        )
        .child(
            div()
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(tokens.tertiary_text)
                .child(SharedString::from(format!(
                    "{} · {} pt",
                    family,
                    font_size.round() as i32
                ))),
        )
        .into_any_element()
}

/// 统一构造一个小号受控 Switch。
pub(super) fn switch_control(
    id: &'static str,
    checked: bool,
    label: &'static str,
    handler: impl Fn(&bool, &mut Window, &mut App) + 'static,
) -> AnyElement {
    Switch::new(id)
        .small()
        .checked(checked)
        .accessibility_label(tr(label))
        .on_change(handler)
        .into_any_element()
}

/// 开关当前值的 badge 文案。
pub(super) fn on_off(checked: bool) -> SharedString {
    SharedString::from(if checked { tr("On") } else { tr("Off") })
}

pub(super) fn project_root_label(root: Option<&std::path::PathBuf>) -> SharedString {
    match root {
        Some(path) => SharedString::from(path.display().to_string()),
        None => SharedString::from(tr("No project open")),
    }
}

pub(super) fn string_or_placeholder(value: &str, placeholder: &'static str) -> SharedString {
    if value.trim().is_empty() {
        SharedString::from(tr(placeholder))
    } else {
        SharedString::from(value.to_string())
    }
}
