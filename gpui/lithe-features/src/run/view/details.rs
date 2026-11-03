//! 配置详情区、Java 项目准备状态条与诊断横幅。

use gpui_kit::component::alert::Alert;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{Icon, IconName, Sizable as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, Context, FontWeight, InteractiveElement as _, IntoElement, ParentElement as _,
    SharedString, StatefulInteractiveElement as _, Styled as _, div, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheMetrics, LitheTokens, mono_font_family};

use super::java_decision;
use super::model::{PreparationPhase, PreparationStatus};
use super::{PANEL_PADDING, RunPanel};

impl RunPanel {
    pub(super) fn render_details(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let Some(configuration) = self.selected_configuration() else {
            return empty_state(tokens, tr("Select a run configuration to see its details."));
        };
        let edit_id = configuration.id.clone();
        let mut details = v_flex()
            .id("lithe-run-details")
            .flex_1()
            .min_w(px(0.0))
            .min_h(px(0.0))
            .overflow_y_scroll()
            .gap(px(10.0))
            .p(px(16.0))
            .bg(tokens.editor)
            .child(
                h_flex()
                    .w_full()
                    .items_center()
                    .gap(px(8.0))
                    .child(
                        div()
                            .text_size(px(13.0))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(tokens.primary_text)
                            .child(tr("Configuration details")),
                    )
                    .child(div().flex_1())
                    .child(
                        Button::new("lithe-run:details-edit")
                            .small()
                            .h(px(24.0))
                            .rounded(px(6.0))
                            .secondary()
                            .label(tr("Edit Configuration…"))
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.invoke_open_settings(&edit_id, window, cx);
                            })),
                    ),
            );

        let mut rows: Vec<(&'static str, String, bool)> = vec![
            (tr("Type"), configuration.kind_title(), false),
            (
                tr("Category"),
                configuration.execution.title().to_string(),
                false,
            ),
            (tr("Provider"), configuration.provider.clone(), true),
            (
                tr("Working directory"),
                configuration.working_directory().to_string(),
                true,
            ),
        ];
        if let Some(module) = configuration
            .module()
            .filter(|value| !value.trim().is_empty())
        {
            rows.push((tr("Module"), module.to_string(), true));
        }
        if let Some(main_class) = configuration
            .main_class()
            .filter(|value| !value.trim().is_empty())
        {
            rows.push((tr("Main class"), main_class.to_string(), true));
        }
        if !configuration.java_home_path.trim().is_empty() {
            rows.push((tr("JDK home"), configuration.java_home_path.clone(), true));
        }
        if !configuration.maven_executable_path.trim().is_empty() {
            rows.push((
                tr("Maven"),
                configuration.maven_executable_path.clone(),
                true,
            ));
        }
        if !configuration.maven_java_home_path.trim().is_empty() {
            rows.push((
                tr("Maven JDK"),
                configuration.maven_java_home_path.clone(),
                true,
            ));
        }
        if !configuration.jvm_arguments.is_empty() {
            rows.push((
                tr("VM arguments"),
                configuration.jvm_arguments.join(" "),
                true,
            ));
        }
        rows.push((
            tr("Program arguments"),
            configuration.program_arguments.join(" "),
            true,
        ));
        rows.push((
            tr("Environment"),
            configuration
                .env
                .iter()
                .map(|(key, value)| format!("{key}={value}"))
                .collect::<Vec<_>>()
                .join("\n"),
            true,
        ));
        rows.push((
            tr("Source"),
            configuration.source_title().to_string(),
            false,
        ));
        rows.push((tr("Configuration ID"), configuration.id.clone(), true));
        for (label, value, monospaced) in rows {
            details = details.child(detail_row(label, value, monospaced, tokens));
        }
        details.into_any_element()
    }

    /// 顶部项目准备状态条（对齐 macOS `ProjectPreparationStatusView`）。
    pub(super) fn render_preparation_status(
        &self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let preparation = match self.java_language.read(cx).preparation() {
            Some(preparation) => preparation.clone(),
            None => return div().into_any_element(),
        };
        if preparation.phase == PreparationPhase::Stopped {
            return div().into_any_element();
        }

        let expanded = self.preparation_expanded;
        let chevron = if expanded {
            IconName::ChevronDown
        } else {
            IconName::ChevronRight
        };

        let is_loading = preparation.status == PreparationStatus::Loading;
        let is_failed = preparation.status == PreparationStatus::Failed;
        let label = preparation.phase.label().to_string();

        let summary_icon = if is_loading {
            Icon::new(IconName::RotateCw)
                .with_size(px(13.0))
                .text_color(tokens.accent)
        } else if is_failed {
            Icon::new(IconName::TriangleAlert)
                .with_size(px(14.0))
                .text_color(tokens.error)
        } else {
            Icon::new(IconName::CircleCheck)
                .with_size(px(14.0))
                .text_color(tokens.success)
        };

        let summary = h_flex()
            .id("lithe-run-preparation-status")
            .w_full()
            .h(px(26.0))
            .items_center()
            .gap(px(6.0))
            .px(px(12.0))
            .bg(tokens.sidebar)
            .when(!expanded, |this| {
                this.border_b_1().border_color(tokens.divider)
            })
            .cursor_pointer()
            .hover(|style| style.bg(tokens.hover))
            .on_click(cx.listener(|this, _, _window, cx| {
                this.preparation_expanded = !this.preparation_expanded;
                cx.notify();
            }))
            .child(
                Icon::new(chevron)
                    .with_size(px(12.0))
                    .text_color(tokens.secondary_text),
            )
            .child(summary_icon)
            .child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .when(is_failed, |this| this.text_color(tokens.error))
                    .when(!is_failed, |this| this.text_color(tokens.secondary_text))
                    .child(label),
            );

        if !expanded {
            return summary.into_any_element();
        }

        // 与 macOS 一致：固定列出四个阶段，`›` 标当前、`·` 标其它；
        // 不把未发生的阶段画成已完成。
        let mut phase_list = v_flex().gap(px(4.0));
        for phase in [
            PreparationPhase::Starting,
            PreparationPhase::Importing,
            PreparationPhase::Configuring,
            PreparationPhase::Building,
        ] {
            let is_current = preparation.phase == phase;
            let prefix = if is_current { "› " } else { "· " };
            phase_list = phase_list.child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .when(is_current, |this| this.font_weight(FontWeight::MEDIUM))
                    .text_color(if is_current {
                        tokens.primary_text
                    } else {
                        tokens.tertiary_text
                    })
                    .child(format!("{prefix}{}", phase.label())),
            );
        }

        let details = v_flex()
            .id("lithe-run-preparation-status-details")
            .w_full()
            .px(px(24.0))
            .py(px(8.0))
            .gap(px(8.0))
            .bg(tokens.sidebar)
            .border_b_1()
            .border_color(tokens.divider)
            .child(phase_list)
            .child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.tertiary_text)
                    .child(tr(
                        "The Java workspace must finish preparation before launch. Background indexing does not block running; compilation runs before launch.",
                    )),
            )
            .child(
                h_flex()
                    .gap(px(16.0))
                    .items_center()
                    .child(
                        div()
                            .id("lithe-run-preparation-settings-btn")
                            .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                            .text_color(tokens.link)
                            .cursor_pointer()
                            .hover(|style| style.underline())
                            .on_click(cx.listener(|this, _, window, cx| {
                                if let Some(handler) = &this.on_open_settings {
                                    handler("language", window, cx);
                                }
                            }))
                            .child(tr("Language service settings and retry")),
                    )
                    .child(
                        div()
                            .id("lithe-run-preparation-logs-btn")
                            .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                            .text_color(tokens.link)
                            .cursor_pointer()
                            .hover(|style| style.underline())
                            .on_click(cx.listener(|this, _, window, cx| {
                                if let Some(handler) = &this.on_open_settings {
                                    handler("logs", window, cx);
                                }
                            }))
                            .child(tr("View logs")),
                    ),
            );

        v_flex()
            .w_full()
            .child(summary)
            .child(details)
            .into_any_element()
    }

    /// 配置诊断提示条。对齐 macOS `configurationNotice`：Core 会为每个配置各返回
    /// 一条诊断（`RunDiagnostic.id` 指向具体配置），逐条铺开会把同一句话重复几十
    /// 遍，所以这里只展示一条——优先 staleFingerprint，否则取第一条。
    pub(super) fn render_banners(
        &self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        let mut banners = Vec::new();
        if let Some(error) = &self.error {
            banners.push(
                Alert::error(SharedString::from("lithe-run:launch-error"), error.clone())
                    .banner()
                    .into_any_element(),
            );
        }
        if let Some(decision) = &self.launch_decision {
            banners.push(java_decision::render_java_launch_decision_banner(
                decision, tokens, cx,
            ));
        }
        let notice = self
            .diagnostics
            .iter()
            .find(|diagnostic| diagnostic.code == "staleFingerprint")
            .or_else(|| self.diagnostics.first());
        banners.extend(notice.map(|diagnostic| {
            Alert::warning(
                SharedString::from("lithe-run:diagnostic"),
                SharedString::from(diagnostic.message.clone()),
            )
            .banner()
            .into_any_element()
        }));
        banners
    }
}

#[allow(dead_code)]
fn empty_state(tokens: LitheTokens, message: &str) -> AnyElement {
    v_flex()
        .w_full()
        .flex_1()
        .min_h(px(0.0))
        .items_center()
        .justify_center()
        .px(px(PANEL_PADDING))
        .child(
            div()
                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                .text_color(tokens.secondary_text)
                .child(message.to_string()),
        )
        .into_any_element()
}

#[allow(dead_code)]
fn detail_row(label: &str, value: String, monospaced: bool, tokens: LitheTokens) -> AnyElement {
    h_flex()
        .w_full()
        .items_start()
        .gap(px(12.0))
        .child(
            div()
                .w(px(150.0))
                .flex_shrink_0()
                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                .text_color(tokens.secondary_text)
                .child(label.to_string()),
        )
        .child(
            div()
                .min_w(px(0.0))
                .flex_1()
                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                .text_color(tokens.primary_text)
                .when(monospaced, |this| this.font_family(mono_font_family()))
                .child(value),
        )
        .into_any_element()
}
