//! Git Log 的 Console 分段：渲染进程级 Git 执行记录。
//!
//! 从 `log_view.rs` 拆出，保持 Git Log 主文件在 1500 行以内；渲染内容与拆分前
//! 一致（最新一条在最上面，空状态说明当前构建不保留执行日志）。

use gpui_kit::component::{Icon, Sizable as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, FontWeight, InteractiveElement as _, IntoElement, ParentElement as _,
    StatefulInteractiveElement as _, Styled as _, div, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheTokens, MONO_FONT_FAMILY};

use super::GitPanel;

impl GitPanel {
    /// Git 执行控制台分段。
    ///
    /// 数据来自 `execute_git_command` 的进程级环形缓冲：只记录写命令
    /// （status / diff / history / references 等只读查询不进入），因此这里
    /// 是真实的执行日志，而不是占位文案。没有记录时保留原来的空状态。
    pub(super) fn render_log_console(&self, tokens: LitheTokens) -> AnyElement {
        let entries = super::git_console_entries();
        if entries.is_empty() {
            return v_flex()
                .id("lithe-git-log-console")
                .flex_1()
                .size_full()
                .min_h_0()
                .items_center()
                .justify_center()
                .gap(px(8.0))
                .p(px(24.0))
                .bg(tokens.editor)
                .child(
                    Icon::new(gpui_kit::assets::IconName::Terminal)
                        .with_size(px(26.0))
                        .text_color(tokens.tertiary_text),
                )
                .child(
                    div()
                        .text_size(px(12.0))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(tokens.primary_text)
                        .child(tr("No Git command history")),
                )
                .child(
                    div()
                        .max_w(px(420.0))
                        .text_size(px(11.5))
                        .text_color(tokens.secondary_text)
                        .child(tr(
                            "Git commands report their result in the panel status line; this build keeps no execution journal, so no entries are listed here.",
                        )),
                )
                .into_any_element();
        }

        // 最新一条在最上面：控制台刚打开时不用滚到底部才能看到刚才的结果。
        let mut list = v_flex()
            .id("lithe-git-log-console")
            .flex_1()
            .size_full()
            .min_w_0()
            .min_h_0()
            .overflow_y_scroll()
            .bg(tokens.editor);
        for entry in entries.iter().rev() {
            let status_color = if entry.succeeded {
                tokens.success
            } else {
                tokens.error
            };
            let mut row = v_flex()
                .w_full()
                .min_w_0()
                .gap(px(2.0))
                .px(px(8.0))
                .py(px(4.0))
                .border_b_1()
                .border_color(tokens.divider)
                .child(
                    h_flex()
                        .w_full()
                        .min_w_0()
                        .items_center()
                        .gap(px(6.0))
                        .child(
                            div()
                                .flex_shrink_0()
                                .font_family(MONO_FONT_FAMILY)
                                .text_size(px(10.5))
                                .text_color(tokens.tertiary_text)
                                .child(entry.time.clone()),
                        )
                        .child(
                            div()
                                .flex_shrink_0()
                                .font_family(MONO_FONT_FAMILY)
                                .text_size(px(11.5))
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(tokens.primary_text)
                                .child(entry.command.clone()),
                        )
                        .child(
                            div()
                                .flex_shrink_0()
                                .text_size(px(10.5))
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(status_color)
                                .child(format!(
                                    "{} · exit {}",
                                    if entry.succeeded {
                                        tr("Succeeded")
                                    } else {
                                        tr("Failed")
                                    },
                                    entry.exit_code
                                )),
                        )
                        .when(!entry.repository.is_empty(), |this| {
                            this.child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .truncate()
                                    .text_size(px(10.5))
                                    .text_color(tokens.tertiary_text)
                                    .child(entry.repository.clone()),
                            )
                        }),
                );
            if !entry.arguments.is_empty() {
                row = row.child(
                    div()
                        .w_full()
                        .min_w_0()
                        .font_family(MONO_FONT_FAMILY)
                        .text_size(px(10.5))
                        .text_color(tokens.secondary_text)
                        .child(entry.arguments.clone()),
                );
            }
            if !entry.output.is_empty() {
                row = row.child(
                    div()
                        .w_full()
                        .min_w_0()
                        .mt(px(2.0))
                        .rounded(px(3.0))
                        .bg(tokens.sidebar)
                        .p(px(4.0))
                        .font_family(MONO_FONT_FAMILY)
                        .text_size(px(10.5))
                        .text_color(tokens.secondary_text)
                        .child(entry.output.clone()),
                );
            }
            list = list.child(row);
        }
        list.into_any_element()
    }
}
