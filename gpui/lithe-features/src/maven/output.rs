//! Maven 构建输出面板（底部停靠）。
//!
//! 对齐 Tauri `maven-run-pane.tsx`：标题行（Run - Maven + 状态 + 动作）、
//! 任务错误条、测试汇总条，主体是「失败/诊断侧栏 + 进程输出」。全部状态
//! 来自 [`MavenPanel`]——两个面板读同一份任务状态，避免复制会话管理。

use std::path::PathBuf;
use std::rc::Rc;

use gpui_kit::base::TextSelection;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{
    Disableable as _, Sizable as _, Theme, h_flex, v_flex, v_virtual_list,
};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, Context, Entity, FontWeight, InteractiveElement as _, IntoElement,
    MouseMoveEvent, ParentElement, Render, ScrollEvent, ScrollStrategy, SharedString,
    StatefulInteractiveElement as _, Styled, Subscription, TextStyleRefinement, WhiteSpace, Window,
    div, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheIcon, LitheMetrics, LitheTokens, current_tokens, icon, mono_font_family};

use crate::console::{
    AnsiPalette, ConsoleCaretHandler, ConsoleHost, ConsoleScroll, console_line_element,
    console_scrollbar,
};
use super::model::TaskStatus;
use super::session::DiagnosticSeverity;
use super::view::{MavenPanel, MavenPanelEvent};

/// 输出行高度，与 Run 面板控制台一致。
const CONSOLE_LINE_HEIGHT: f32 = 18.0;
/// 输出内边距。
const PANEL_PADDING: f32 = 12.0;
/// 输出面板图标按钮尺寸，对齐 Tauri `icon-xs`（24px）。
const OUTPUT_ACTION_BUTTON_SIZE: f32 = 24.0;
/// 输出面板图标尺寸，对齐 Tauri 的 `size-3.5`（14px）。
const OUTPUT_ACTION_ICON_SIZE: f32 = 14.0;
/// 左侧栏宽度。对齐 Tauri `w-72`。
const SIDEBAR_WIDTH: f32 = 288.0;

type OpenLocationHandler =
    Rc<dyn Fn(PathBuf, Option<u32>, Option<u32>, &mut Window, &mut App) + 'static>;

/// Maven 构建输出面板。
pub struct MavenOutputPanel {
    maven: Entity<MavenPanel>,
    console: ConsoleScroll,
    on_open_location: Option<OpenLocationHandler>,
    on_hide: Option<Rc<dyn Fn(&mut Window, &mut App) + 'static>>,
    _state_subscription: Option<Subscription>,
}

impl ConsoleHost for MavenOutputPanel {
    fn console(&mut self) -> &mut ConsoleScroll {
        &mut self.console
    }
}

impl MavenOutputPanel {
    pub fn new(maven: Entity<MavenPanel>, _window: &mut Window, cx: &mut Context<Self>) -> Self {
        let subscription = cx.subscribe(&maven, |_, _, _: &MavenPanelEvent, cx| {
            cx.notify();
        });
        Self {
            maven,
            console: ConsoleScroll::new(),
            on_open_location: None,
            on_hide: None,
            _state_subscription: Some(subscription),
        }
    }

    pub fn on_open_location(
        &mut self,
        handler: impl Fn(PathBuf, Option<u32>, Option<u32>, &mut Window, &mut App) + 'static,
    ) {
        self.on_open_location = Some(Rc::new(handler));
    }

    pub fn on_hide(&mut self, handler: impl Fn(&mut Window, &mut App) + 'static) {
        self.on_hide = Some(Rc::new(handler));
    }

    fn open_location(
        &self,
        path: &str,
        line: Option<u32>,
        column: Option<u32>,
        window: &mut Window,
        cx: &mut App,
    ) {
        let Some(handler) = self.on_open_location.clone() else {
            return;
        };
        handler(
            self.maven.read(cx).resolve_path(path),
            line,
            column,
            window,
            cx,
        );
    }

    fn render_header(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let maven = self.maven.read(cx);
        let running = maven.task_status() == TaskStatus::Running
            || maven.task_status() == TaskStatus::Stopping;
        let stopping = maven.task_status() == TaskStatus::Stopping;
        let has_test_run = maven.has_last_test_run();
        let can_clear = maven.can_clear_output();
        let status_text = match maven.task_status() {
            TaskStatus::Running => Some((tr("Running").to_string(), tokens.success)),
            TaskStatus::Stopping => Some((tr("Stopping").to_string(), tokens.warning)),
            TaskStatus::Cancelled => Some((tr("Cancelled").to_string(), tokens.warning)),
            TaskStatus::Failed => Some((tr("Failed").to_string(), tokens.error)),
            TaskStatus::Idle => match maven.task_exit_code() {
                Some(code) if code == 0 => Some((tr("Succeeded").to_string(), tokens.success)),
                Some(_) => Some((tr("Failed").to_string(), tokens.error)),
                None => None,
            },
        };
        let title = match maven.task_title() {
            Some(title) if !title.is_empty() => {
                SharedString::from(format!("{} - {} - {}", tr("Run"), tr("Maven"), title))
            }
            _ => SharedString::from(format!("{} - {}", tr("Run"), tr("Maven"))),
        };

        let mut header = h_flex()
            .h(px(LitheMetrics::TOOL_WINDOW_HEADER_HEIGHT))
            .w_full()
            .flex_shrink_0()
            .items_center()
            .gap(px(8.0))
            .px(px(12.0))
            .border_b_1()
            .border_color(tokens.divider)
            .bg(tokens.tool_header)
            .child(
                icon(LitheIcon::Maven)
                    .with_size(px(16.0))
                    .text_color(tokens.primary_text),
            )
            .child(
                div()
                    .min_w(px(0.0))
                    .flex_shrink_1()
                    .truncate()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(tokens.primary_text)
                    .child(title),
            );

        if let Some((text, color)) = status_text {
            header = header.child(
                div()
                    .flex_shrink_0()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(color)
                    .child(text),
            );
        }

        header = header
            .child(div().flex_1())
            .child(
                Button::new("lithe-maven-output:stop")
                    .ghost()
                    .with_size(px(OUTPUT_ACTION_BUTTON_SIZE))
                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                    .icon(
                        icon(LitheIcon::Stop)
                            .with_size(px(OUTPUT_ACTION_ICON_SIZE))
                            .text_color(tokens.warning),
                    )
                    .tooltip(tr("Stop Maven task"))
                    .accessibility_label(tr("Stop Maven task"))
                    .disabled(!running || stopping)
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.maven
                            .update(cx, |panel, panel_cx| panel.stop_task(panel_cx));
                    })),
            )
            .child(
                Button::new("lithe-maven-output:rerun-tests")
                    .ghost()
                    .with_size(px(OUTPUT_ACTION_BUTTON_SIZE))
                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                    .icon(icon(LitheIcon::Refresh).with_size(px(OUTPUT_ACTION_ICON_SIZE)))
                    .tooltip(tr("Rerun test"))
                    .accessibility_label(tr("Rerun test"))
                    .disabled(!has_test_run || running)
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.maven
                            .update(cx, |panel, panel_cx| panel.rerun_last_test(panel_cx));
                    })),
            )
            .child(
                Button::new("lithe-maven-output:clear")
                    .ghost()
                    .with_size(px(OUTPUT_ACTION_BUTTON_SIZE))
                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                    .icon(icon(LitheIcon::Trash).with_size(px(OUTPUT_ACTION_ICON_SIZE)))
                    .tooltip(tr("Clear build output"))
                    .accessibility_label(tr("Clear build output"))
                    .disabled(!can_clear)
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.maven
                            .update(cx, |panel, panel_cx| panel.clear_output(panel_cx));
                    })),
            )
            .child(
                Button::new("lithe-maven-output:minimize")
                    .ghost()
                    .with_size(px(OUTPUT_ACTION_BUTTON_SIZE))
                    .rounded(px(LitheMetrics::CONTROL_RADIUS))
                    .icon(icon(LitheIcon::Minus).with_size(px(OUTPUT_ACTION_ICON_SIZE)))
                    .tooltip(tr("Minimize"))
                    .accessibility_label(tr("Minimize"))
                    .on_click(cx.listener(|this, _, window, cx| {
                        if let Some(handler) = this.on_hide.clone() {
                            handler(window, cx);
                        }
                    })),
            );
        header.into_any_element()
    }

    /// 任务级错误（启动失败、非零退出码）。
    fn render_task_error(&self, tokens: LitheTokens, cx: &Context<Self>) -> Option<AnyElement> {
        let error = self.maven.read(cx).task_error()?.to_string();
        Some(
            h_flex()
                .w_full()
                .flex_shrink_0()
                .items_start()
                .gap(px(8.0))
                .px(px(12.0))
                .py(px(8.0))
                .bg(tokens.warning.alpha(0.10))
                .border_b_1()
                .border_color(tokens.divider)
                .child(
                    icon(LitheIcon::Warning)
                        .with_size(px(14.0))
                        .text_color(tokens.warning),
                )
                .child(
                    div()
                        .min_w(px(0.0))
                        .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                        .text_color(tokens.primary_text)
                        .child(error),
                )
                .into_any_element(),
        )
    }

    /// 测试汇总条：通过 / 失败 / 跳过 / 总数。
    fn render_test_summary(&self, tokens: LitheTokens, cx: &Context<Self>) -> Option<AnyElement> {
        let results = self.maven.read(cx).task_test_results()?.clone();
        let item = |icon_kind: LitheIcon, color, label: String| {
            h_flex()
                .gap(px(6.0))
                .child(icon(icon_kind).with_size(px(14.0)).text_color(color))
                .child(
                    div()
                        .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                        .text_color(tokens.primary_text)
                        .child(label),
                )
        };
        Some(
            h_flex()
                .w_full()
                .flex_shrink_0()
                .flex_wrap()
                .items_center()
                .gap(px(16.0))
                .px(px(12.0))
                .py(px(8.0))
                .border_b_1()
                .border_color(tokens.divider)
                .child(item(
                    LitheIcon::Tests,
                    tokens.success,
                    tr("Passed: {count}").replace("{count}", &results.passed.to_string()),
                ))
                .child(item(
                    LitheIcon::Problems,
                    tokens.error,
                    tr("Failed: {count}").replace("{count}", &results.failed_count().to_string()),
                ))
                .child(item(
                    LitheIcon::Minus,
                    tokens.warning,
                    tr("Skipped: {count}").replace("{count}", &results.skipped.to_string()),
                ))
                .child(
                    div()
                        .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                        .text_color(tokens.secondary_text)
                        .child(
                            tr("Total: {count}").replace("{count}", &results.tests_run.to_string()),
                        ),
                )
                .into_any_element(),
        )
    }

    /// 失败 / 诊断侧栏；没有内容时不占宽度。
    fn render_sidebar(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> Option<AnyElement> {
        let maven = self.maven.read(cx);
        let failures = maven
            .task_test_results()
            .map(|results| results.failure_details.clone())
            .unwrap_or_default();
        let issues = maven.task_issues().to_vec();
        if failures.is_empty() && issues.is_empty() {
            return None;
        }

        let mut sidebar = v_flex()
            .id("lithe-maven-output-sidebar")
            .w(px(SIDEBAR_WIDTH))
            .flex_shrink_0()
            .h_full()
            .min_h(px(0.0))
            .overflow_y_scroll()
            .border_r_1()
            .border_color(tokens.divider)
            .bg(tokens.sidebar);

        if !failures.is_empty() {
            let mut section = v_flex();
            section = section.child(
                div()
                    .px(px(12.0))
                    .py(px(8.0))
                    .border_b_1()
                    .border_color(tokens.divider)
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(tokens.secondary_text)
                    .child(format!("{} ({})", tr("Test failures"), failures.len())),
            );
            for failure in failures {
                let location = failure.location();
                let second_line = if !location.is_empty() {
                    location
                } else if let Some(message) = failure.message.as_ref() {
                    message.clone()
                } else {
                    tr("Source location unavailable").to_string()
                };
                let open_path = failure.path.clone();
                let open_line = failure.line;
                let open_column = failure.column;
                section = section.child(
                    div()
                        .id(SharedString::from(format!(
                            "lithe-maven-failure:{}",
                            failure.name
                        )))
                        .w_full()
                        .flex_shrink_0()
                        .px(px(12.0))
                        .py(px(6.0))
                        .gap(px(2.0))
                        .hover(|style| style.bg(tokens.hover))
                        .when(open_path.is_some(), |this| this.cursor_pointer())
                        .on_click(cx.listener(move |this, _, window, cx| {
                            if let Some(path) = open_path.clone() {
                                this.open_location(&path, open_line, open_column, window, cx);
                            }
                        }))
                        .child(
                            h_flex()
                                .gap(px(6.0))
                                .child(
                                    icon(LitheIcon::Problems)
                                        .with_size(px(14.0))
                                        .text_color(tokens.error),
                                )
                                .child(
                                    div()
                                        .min_w(px(0.0))
                                        .truncate()
                                        .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                                        .font_weight(FontWeight::MEDIUM)
                                        .text_color(tokens.primary_text)
                                        .child(failure.name.clone()),
                                ),
                        )
                        .child(
                            div()
                                .min_w(px(0.0))
                                .pl(px(20.0))
                                .truncate()
                                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                                .text_color(tokens.secondary_text)
                                .child(second_line),
                        ),
                );
            }
            sidebar = sidebar.child(section);
        }

        if !issues.is_empty() {
            let mut section = v_flex();
            section = section.child(
                div()
                    .px(px(12.0))
                    .py(px(8.0))
                    .border_b_1()
                    .border_color(tokens.divider)
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(tokens.secondary_text)
                    .child(format!("{} ({})", tr("Build Output"), issues.len())),
            );
            for issue in issues {
                let is_error = issue.severity == DiagnosticSeverity::Error;
                let open_path = issue.path.clone();
                let open_line = Some(issue.line);
                let open_column = issue.column;
                let location = issue.location();
                section = section.child(
                    div()
                        .id(SharedString::from(format!(
                            "lithe-maven-issue:{}:{}",
                            issue.path, issue.line
                        )))
                        .w_full()
                        .flex_shrink_0()
                        .px(px(12.0))
                        .py(px(6.0))
                        .gap(px(2.0))
                        .hover(|style| style.bg(tokens.hover))
                        .cursor_pointer()
                        .on_click(cx.listener(move |this, _, window, cx| {
                            let path = open_path.clone();
                            this.open_location(&path, open_line, open_column, window, cx);
                        }))
                        .child(
                            h_flex()
                                .gap(px(6.0))
                                .child(icon(LitheIcon::Warning).with_size(px(14.0)).text_color(
                                    if is_error {
                                        tokens.error
                                    } else {
                                        tokens.warning
                                    },
                                ))
                                .child(
                                    div()
                                        .min_w(px(0.0))
                                        .truncate()
                                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                                        .text_color(tokens.primary_text)
                                        .child(location),
                                ),
                        )
                        .child(
                            div()
                                .min_w(px(0.0))
                                .pl(px(20.0))
                                .truncate()
                                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                                .text_color(tokens.secondary_text)
                                .child(issue.message.clone()),
                        ),
                );
            }
            sidebar = sidebar.child(section);
        }

        Some(sidebar.into_any_element())
    }

    fn console_text_style(&self, tokens: LitheTokens) -> TextStyleRefinement {
        TextStyleRefinement {
            font_family: Some(mono_font_family().into()),
            font_size: Some(px(LitheMetrics::CODE_FONT_SIZE).into()),
            color: Some(tokens.primary_text),
            white_space: Some(WhiteSpace::Nowrap),
            ..Default::default()
        }
    }
}

impl Render for MavenOutputPanel {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let tokens = current_tokens(cx);
        let line_count = self.maven.read(cx).task_line_count();
        let task_running = matches!(
            self.maven.read(cx).task_status(),
            TaskStatus::Running | TaskStatus::Stopping
        );
        if self
            .console
            .sync_line_count(line_count, CONSOLE_LINE_HEIGHT)
            && task_running
            && line_count > 0
        {
            // 任务运行期间新输出到达时贴底跟随；任务结束后停在原位，允许回看。
            self.console
                .scroll_to_item(line_count - 1, ScrollStrategy::Bottom);
        }
        self.console.sync_display();
        let has_output = line_count > 0;
        let text_style = self.console_text_style(tokens);

        let output_area = div()
            .flex_1()
            .min_h(px(0.0))
            .min_w(px(0.0))
            .child(if has_output {
                // 控制台用 v_virtual_list：行高固定（Nowrap 单行），只排版可视行，
                // 并暴露 ScrollHandle 以便给滚轮加平滑插值。
                let maven = self.maven.clone();
                let item_sizes = self.console.item_sizes.clone();
                let line_text_style = text_style.clone();
                let palette = AnsiPalette::new(Theme::global(cx).is_dark());
                let line_tokens = tokens;
                let console_caret = self.console.caret_snapshot();
                let owner = cx.weak_entity();
                div()
                    .id("lithe-maven-output-console")
                    .relative()
                    .size_full()
                    .p(px(PANEL_PADDING))
                    .on_scroll(cx.listener(|this, event: &ScrollEvent, window, cx| {
                        this.console.on_scroll(event, window, cx);
                    }))
                    .on_mouse_move(cx.listener(|_, event: &MouseMoveEvent, window, cx| {
                        // 拖选不改变 hover 或滚动，GPUI 不会为此重绘；
                        // 按住左键拖动时主动请求一帧，让每行文本在
                        // prepaint 中拿到新的选择范围并即时绘制高亮。
                        if event.pressed_button.is_some()
                            && TextSelection::has_selection(window, cx)
                        {
                            window.refresh();
                        }
                    }))
                    .child(
                        v_virtual_list(
                            cx.entity(),
                            "lithe-maven-output-lines",
                            item_sizes,
                            move |_, range, _window, cx| {
                                let panel = maven.read(cx);
                                range
                                    .map(|index| {
                                        let on_caret: ConsoleCaretHandler = {
                                            let owner = owner.clone();
                                            Rc::new(move |offset, _window, cx| {
                                                let _ = owner.update(cx, |this, cx| {
                                                    this.console.set_caret(index, offset);
                                                    cx.notify();
                                                });
                                            })
                                        };
                                        console_line_element(
                                            format!("lithe-maven-output-line:{index}"),
                                            index,
                                            panel.task_line_at(index),
                                            line_text_style.clone(),
                                            &palette,
                                            line_tokens,
                                            console_caret
                                                .filter(|(line, _)| *line == index)
                                                .map(|(_, offset)| offset),
                                            Some(on_caret),
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
                        "lithe-maven-output-scrollbar",
                    ))
                    .into_any_element()
            } else {
                div()
                    .size_full()
                    .px(px(14.0))
                    .pt(px(10.0))
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(tr("Run a Maven lifecycle phase to see output."))
                    .into_any_element()
            });

        let mut panel = v_flex()
            .size_full()
            .min_h(px(0.0))
            .min_w(px(0.0))
            .bg(tokens.editor)
            .text_color(tokens.primary_text)
            .child(self.render_header(tokens, cx));

        if let Some(error) = self.render_task_error(tokens, cx) {
            panel = panel.child(error);
        }
        if let Some(summary) = self.render_test_summary(tokens, cx) {
            panel = panel.child(summary);
        }
        panel = panel.child(
            h_flex()
                .flex_1()
                .min_h(px(0.0))
                .min_w(px(0.0))
                .items_stretch()
                .children(self.render_sidebar(tokens, cx))
                .child(output_area),
        );

        panel.into_any_element()
    }
}
