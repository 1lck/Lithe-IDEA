use std::path::{Path, PathBuf};

use lithe_ui::components::status_bar::{LitheStatusBar, StatusBarItem};
use gpui_kit::component::{h_flex, v_flex};
use gpui_kit::{
    AnyElement, Context, FontWeight, Hsla, InteractiveElement as _, IntoElement,
    ParentElement as _, RenderOnce as _, SharedString, StatefulInteractiveElement as _, Styled as _, WeakEntity, Window, div, px,
};
use lithe_features::editor::DiagnosticItem;
use lithe_ui::i18n::tr;
use lithe_ui::icons::LitheIcon;
use lithe_ui::{current_tokens, LitheMetrics, LitheTokens};

use super::{theme_display_name, theme_kind_for, Workbench};

impl Workbench {
    pub(super) fn render_status_bar(&self, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let mut left = vec![
            StatusBarItem::new("lithe-status-project", self.project_name())
                .icon(LitheIcon::Project),
            StatusBarItem::new(
                "lithe-status-git-count",
                format!("{} {}", self.git_change_count, tr("changes")),
            )
            .icon(LitheIcon::Changes),
        ];

        if let Some(tab) = self.current_tab() {
            left.push(
                StatusBarItem::new("lithe-status-file", tab.display_path.clone()).icon(tab.icon),
            );
        }

        if let Some(message) = &self.status_message {
            left.push(StatusBarItem::new("lithe-status-message", message.clone()));
        }

        let position = format!(
            "{} {}, {} {}",
            tr("Ln"),
            self.cursor_line,
            tr("Col"),
            self.cursor_column
        );

        let theme = format!(
            "{} · {}",
            theme_display_name(theme_kind_for(&self.settings.theme)),
            if self.settings.dark {
                tr("Dark")
            } else {
                tr("Light")
            }
        );

        let memory = format!("{} {}", tr("RAM"), self.memory_text);

        let right = [
            StatusBarItem::new("lithe-status-memory", memory),
            StatusBarItem::new("lithe-status-theme", theme),
            StatusBarItem::new("lithe-status-position", position),
            StatusBarItem::new("lithe-status-encoding", tr("UTF-8")),
            StatusBarItem::new("lithe-status-indent", tr("4 spaces")),
        ];

        LitheStatusBar::new(left, right)
            .render(window, cx)
            .into_any_element()
    }

    /// Problems 工具窗：按文件分组的诊断列表。
    pub(super) fn render_problems(&self, cx: &mut Context<Self>) -> AnyElement {
        let tokens = current_tokens(cx);
        let owner = cx.weak_entity();

        let error_count = self
            .problems
            .iter()
            .filter(|problem| problem.severity & 8 != 0)
            .count();
        let warning_count = self
            .problems
            .iter()
            .filter(|problem| problem.severity & 4 != 0)
            .count();

        let summary = h_flex()
            .id("lithe-problems-summary")
            .w_full()
            .flex_shrink_0()
            .items_center()
            .gap(px(12.))
            .px(px(12.))
            .py(px(8.))
            .border_b(px(1.))
            .border_color(tokens.divider)
            .child(problem_count(
                tokens.error,
                error_count,
                tr("Errors"),
                tokens,
            ))
            .child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.tertiary_text)
                    .child("·"),
            )
            .child(problem_count(
                tokens.warning,
                warning_count,
                tr("Warnings"),
                tokens,
            ));

        let mut list = v_flex()
            .id("lithe-problems-list")
            .w_full()
            .flex_1()
            .min_h(px(0.))
            .overflow_y_scroll();

        if self.problems.is_empty() {
            list = list.child(
                div()
                    .size_full()
                    .flex()
                    .items_center()
                    .justify_center()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.tertiary_text)
                    .child(tr("No problems detected")),
            );
        } else {
            let mut last_path: Option<&Path> = None;
            for (index, problem) in self.problems.iter().enumerate() {
                if last_path != Some(problem.path.as_path()) {
                    last_path = Some(problem.path.as_path());
                    list = list.child(problem_group_header(
                        self.problem_display_path(&problem.path),
                        tokens,
                    ));
                }
                list = list.child(problem_row(index, problem, owner.clone(), tokens));
            }
        }

        v_flex()
            .id("lithe-problems")
            .size_full()
            .min_h(px(0.))
            .min_w(px(0.))
            .child(summary)
            .child(list)
            .into_any_element()
    }

    pub(super) fn problem_display_path(&self, path: &Path) -> SharedString {
        if let Some(root) = self.project_root.as_deref() {
            if let Ok(relative) = path.strip_prefix(root) {
                let text = relative.to_string_lossy().replace('\\', "/");
                if !text.is_empty() {
                    return text.into();
                }
            }
        }
        path.to_string_lossy().into_owned().into()
    }

    pub(super) fn open_problem(&mut self, path: PathBuf, window: &mut Window, cx: &mut Context<Self>) {
        let requested = match self.project_root.as_deref() {
            Some(root) => path
                .strip_prefix(root)
                .map(|relative| relative.to_path_buf())
                .unwrap_or_else(|_| path.to_path_buf()),
            None => path,
        };
        self.open_file_from_tree(requested, window, cx);
    }
}

fn problem_count(
    color: Hsla,
    count: usize,
    label: &'static str,
    tokens: LitheTokens,
) -> AnyElement {
    h_flex()
        .items_center()
        .gap(px(5.))
        .child(div().size(px(6.)).rounded_full().bg(color))
        .child(
            div()
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(tokens.secondary_text)
                .child(format!("{count} {label}")),
        )
        .into_any_element()
}

fn problem_group_header(path: SharedString, tokens: LitheTokens) -> AnyElement {
    div()
        .w_full()
        .truncate()
        .px(px(12.))
        .pt(px(8.))
        .pb(px(4.))
        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
        .font_weight(FontWeight::MEDIUM)
        .text_color(tokens.secondary_text)
        .child(path)
        .into_any_element()
}

fn problem_row(
    index: usize,
    problem: &DiagnosticItem,
    owner: WeakEntity<Workbench>,
    tokens: LitheTokens,
) -> AnyElement {
    let path = problem.path.clone();
    h_flex()
        .id(format!("lithe-problem-row:{index}"))
        .w_full()
        .items_center()
        .gap(px(8.))
        .px(px(12.))
        .py(px(4.))
        .hover(|style| style.bg(tokens.hover))
        .cursor_pointer()
        .on_click(move |_, window, cx| {
            let path = path.clone();
            let _ = owner.update(cx, |this, cx| this.open_problem(path, window, cx));
        })
        .child(
            div()
                .size(px(6.))
                .flex_shrink_0()
                .rounded_full()
                .bg(if problem.severity & 8 != 0 {
                    tokens.error
                } else {
                    tokens.warning
                }),
        )
        .child(
            div()
                .flex_1()
                .min_w(px(0.))
                .truncate()
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(tokens.primary_text)
                .child(problem.message.clone()),
        )
        .child(
            div()
                .flex_shrink_0()
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(tokens.tertiary_text)
                .child(format!("{}:{}", problem.line, problem.column)),
        )
        .into_any_element()
}
