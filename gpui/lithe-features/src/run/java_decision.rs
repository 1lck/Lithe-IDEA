//! Java 启动决策横幅（UI 对齐 Tauri `JavaLaunchDecisionBanner`，行为对齐 macOS）。
//!
//! 当 Java / Spring Boot 项目启动前构建未成功完成时（例如项目报告了编译错误），
//! 暂停启动流程并在 Run 面板顶部展示决策横幅，由用户决定是仍然运行、对此工作区
//! 始终继续、重建 Java 索引、打开日志还是取消。

use std::path::PathBuf;

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{Sizable as _, h_flex, v_flex};
use gpui_kit::{
    AnyElement, Context, FontWeight, IntoElement, ParentElement, Styled, div, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::icons::{LitheIcon, icon};
use lithe_ui::{LitheMetrics, LitheTokens};

use super::model::RunConfiguration;
use super::view::RunPanel;
use crate::language::JavaBuildFailure;

/// 一次被构建失败暂停的 Java 启动决策数据。
#[derive(Clone, Debug)]
pub struct JavaLaunchDecision {
    pub configuration: RunConfiguration,
    pub failure: JavaBuildFailure,
    /// 决策期间保留的 Current File 源文件；非 Current File 配置为 `None`。
    pub current_file: Option<PathBuf>,
}

impl JavaLaunchDecision {
    pub fn from_failure(
        configuration: RunConfiguration,
        failure: JavaBuildFailure,
        current_file: Option<PathBuf>,
    ) -> Self {
        Self {
            configuration,
            failure,
            current_file,
        }
    }
}

/// 渲染与 Tauri `JavaLaunchDecisionBanner` 对齐的决策横幅。
pub fn render_java_launch_decision_banner(
    decision: &JavaLaunchDecision,
    tokens: LitheTokens,
    cx: &mut Context<RunPanel>,
) -> AnyElement {
    let name = decision.configuration.name.clone();
    let title =
        tr("The Java build for {name} did not finish successfully").replace("{name}", &name);
    let failure = &decision.failure;
    let report = failure.report.as_ref();
    let can_rebuild = report
        .and_then(|report| report.recovery.as_deref())
        .is_some_and(|recovery| recovery == "rebuildJavaIndex");
    let builder_failed_earlier = failure.code == "javaBuildFailed"
        || report.is_some_and(|report| report.builder_failed_earlier);
    let workspace_scope = report
        .and_then(|report| report.marker_scope.as_deref())
        .is_some_and(|scope| scope == "workspace");
    let elapsed = report.and_then(|report| report.elapsed_milliseconds);
    let config_id = decision.configuration.id.clone();

    let accent_btn = Button::new("lithe-run-decision:continue")
        .primary()
        .xsmall()
        .label(tr("Run Anyway"))
        .on_click(cx.listener(|this, _, _, cx| {
            this.continue_java_launch(false, cx);
        }));

    let always_btn = Button::new("lithe-run-decision:always")
        .secondary()
        .xsmall()
        .label(tr("Always Continue in This Workspace"))
        .on_click(cx.listener(|this, _, _, cx| {
            this.continue_java_launch(true, cx);
        }));

    let rebuild_btn = if can_rebuild {
        Some(
            Button::new("lithe-run-decision:rebuild")
                .secondary()
                .xsmall()
                .label(tr("Rebuild Java Index"))
                .on_click(cx.listener(|this, _, _, cx| {
                    this.rebuild_java_index(cx);
                })),
        )
    } else {
        None
    };

    let logs_btn = Button::new("lithe-run-decision:logs")
        .ghost()
        .xsmall()
        .label(tr("Open Logs"))
        .on_click(cx.listener(move |this, _, window, cx| {
            this.open_decision_logs(&config_id, window, cx);
        }));

    let cancel_btn = Button::new("lithe-run-decision:cancel")
        .ghost()
        .xsmall()
        .label(tr("Cancel"))
        .on_click(cx.listener(|this, _, _, cx| {
            this.cancel_java_launch(cx);
        }));

    let mut explanation = v_flex()
        .min_w(px(0.0))
        .flex_1()
        .gap(px(2.0))
        .child(
            div()
                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                .font_weight(FontWeight::MEDIUM)
                .text_color(tokens.primary_text)
                .child(title),
        )
        .child(
            div()
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(tokens.secondary_text)
                .child(failure.message.clone()),
        );
    if builder_failed_earlier {
        explanation = explanation.child(
            div()
                .mt(px(4.0))
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(tokens.secondary_text)
                .child(tr(
                    "The Java language-service builder failed in this session, so these error markers may be stale. You can run the existing output or rebuild the index.",
                )),
        );
    }
    if workspace_scope {
        explanation = explanation.child(
            div()
                .mt(px(4.0))
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(tokens.secondary_text)
                .child(tr("Workspace (may include unrelated modules)")),
        );
    }
    if let Some(milliseconds) = elapsed {
        explanation = explanation.child(
            div()
                .mt(px(4.0))
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(tokens.secondary_text)
                .child(
                    tr(
                        "Build response time: {milliseconds} ms. This is evidence only and does not decide whether you may run.",
                    )
                    .replace("{milliseconds}", &milliseconds.to_string()),
                ),
        );
    }

    v_flex()
        .w_full()
        .flex_shrink_0()
        .gap(px(8.0))
        .px(px(12.0))
        .py(px(8.0))
        .bg(tokens.warning.opacity(0.10))
        .border_b_1()
        .border_color(tokens.warning.opacity(0.30))
        .child(
            h_flex()
                .items_start()
                .gap(px(8.0))
                .child(
                    div().pt(px(2.0)).child(
                        icon(LitheIcon::Warning)
                            .with_size(px(14.0))
                            .text_color(tokens.warning),
                    ),
                )
                .child(explanation),
        )
        .child(
            h_flex()
                .pl(px(22.0))
                .gap(px(8.0))
                .items_center()
                .child(accent_btn)
                .child(always_btn)
                .children(rebuild_btn)
                .child(logs_btn)
                .child(cancel_btn),
        )
        .into_any_element()
}
