//! 状态栏里的 Java 项目准备项与展开面板。
//!
//! 对照 macOS `ProjectPreparationStatusView`：折叠时只显示状态图标和当前阶段，
//! 展开时按固定顺序列出四个阶段，用 `›` 标当前、`·` 标其它，不额外追认完成。

use gpui_kit::component::{Icon, IconName, Sizable as _};
use gpui_kit::{
    AnyElement, App, InteractiveElement as _, IntoElement, ParentElement as _, StatefulInteractiveElement as _,
    Styled as _, WeakEntity, Window, deferred, div, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::components::status_bar::StatusBarItem;
use lithe_ui::{LitheMetrics, LitheTokens};

use super::java::JavaLanguageServiceModel;
use crate::run::model::{PreparationPhase, PreparationStatus};

/// 状态栏条目；没有准备状态或会话停止时不显示，与 macOS 一致。
pub fn status_item(
    model: &JavaLanguageServiceModel,
    owner: WeakEntity<JavaLanguageServiceModel>,
    tokens: LitheTokens,
) -> Option<StatusBarItem> {
    let preparation = model.preparation()?;
    if preparation.phase == PreparationPhase::Stopped {
        return None;
    }
    let loading = preparation.status == PreparationStatus::Loading;
    let failed = preparation.status == PreparationStatus::Failed;
    let icon_name = if loading {
        IconName::RotateCw
    } else if failed {
        IconName::TriangleAlert
    } else {
        IconName::CircleCheck
    };
    let icon_color = if loading {
        tokens.accent
    } else if failed {
        tokens.error
    } else {
        tokens.success
    };
    let text_color = if failed {
        tokens.error
    } else {
        tokens.secondary_text
    };
    let label = preparation.phase.label().to_string();

    Some(StatusBarItem::element(
        "lithe-status-java-preparation",
        div()
            .id("lithe-status-java-preparation")
            .flex()
            .flex_row()
            .items_center()
            .gap(px(LitheMetrics::STATUS_BAR_ICON_GAP))
            .cursor_pointer()
            .hover(|style| style.bg(tokens.hover))
            .on_click(move |_, _, cx| {
                let _ = owner.update(cx, |model, cx| model.toggle_expanded(cx));
            })
            .child(
                Icon::new(icon_name)
                    .with_size(px(LitheMetrics::STATUS_BAR_ICON_SIZE))
                    .text_color(icon_color),
            )
            .child(
                div()
                    .truncate()
                    .text_size(px(LitheMetrics::STATUS_BAR_FONT_SIZE))
                    .text_color(text_color)
                    .child(label),
            )
            .into_any_element(),
    ))
}

/// 展开面板；打开详情不触发任何准备动作。
pub fn render_panel(
    model: &JavaLanguageServiceModel,
    tokens: LitheTokens,
    owner: WeakEntity<JavaLanguageServiceModel>,
    on_settings: impl Fn(&mut Window, &mut App) + 'static,
    on_logs: impl Fn(&mut Window, &mut App) + 'static,
) -> Option<AnyElement> {
    let preparation = model.preparation()?;
    if !model.is_expanded() || preparation.phase == PreparationPhase::Stopped {
        return None;
    }

    let mut phases = gpui_kit::v_flex().gap(px(4.0));
    for phase in [
        PreparationPhase::Starting,
        PreparationPhase::Importing,
        PreparationPhase::Configuring,
        PreparationPhase::Building,
    ] {
        let current = preparation.phase == phase;
        let prefix = if current { "› " } else { "· " };
        phases = phases.child(
            div()
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(if current {
                    tokens.primary_text
                } else {
                    tokens.tertiary_text
                })
                .child(format!("{prefix}{}", phase.label())),
        );
    }

    let close = owner.clone();
    Some(
        deferred(
            div()
                .id("lithe-status-java-preparation-panel")
                .absolute()
                .bottom(px(LitheMetrics::STATUS_BAR_HEIGHT))
                .right(px(16.0))
                .w(px(330.0))
                .p(px(16.0))
                .gap(px(12.0))
                .bg(tokens.raised)
                .border_1()
                .border_color(tokens.panel_border)
                .rounded(px(8.0))
                .on_mouse_down_out(move |_, _, cx| {
                    let _ = close.update(cx, |model, cx| {
                        if model.is_expanded() {
                            model.toggle_expanded(cx);
                        }
                    });
                })
                .child(
                    div()
                        .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                        .text_color(tokens.primary_text)
                        .child(preparation.phase.label()),
                )
                .child(phases)
                .child(
                    div()
                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                        .text_color(tokens.tertiary_text)
                        .child(tr(
                            "The Java workspace must finish preparation before launch. Background indexing does not block running; compilation runs before launch.",
                        )),
                )
                .child(
                    gpui_kit::h_flex()
                        .gap(px(16.0))
                        .items_center()
                        .child(panel_action(
                            "lithe-status-java-preparation-settings",
                            tr("Language service settings and retry"),
                            tokens,
                            on_settings,
                        ))
                        .child(panel_action(
                            "lithe-status-java-preparation-logs",
                            tr("View logs"),
                            tokens,
                            on_logs,
                        )),
                ),
        )
        .into_any_element(),
    )
}

fn panel_action(
    id: &'static str,
    label: &'static str,
    tokens: LitheTokens,
    handler: impl Fn(&mut Window, &mut App) + 'static,
) -> AnyElement {
    div()
        .id(id)
        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
        .text_color(tokens.link)
        .cursor_pointer()
        .hover(|style| style.underline())
        .on_click(move |_, window, cx| handler(window, cx))
        .child(label)
        .into_any_element()
}
