//! 忽略规则写入（.gitignore / .local exclude）。
//!
//! 对齐 Tauri `git-status-panel.tsx:854-907`：右键「加入 .gitignore / .local
//! exclude」需要确认后追加规则行。`.gitignore` 与 `.git/info/exclude` 都是
//! 普通文本文件，内容读写走 `CoreClient::read_file/write_file`（仓库内路径，
//! 不直接触碰平台文件系统），确认覆盖层沿用丢弃确认的模态结构。

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{Sizable as _, h_flex, v_flex};
use gpui_kit::{
    AnyElement, AppContext as _, Context, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _, div, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheMetrics, LitheTokens};

use super::GitPanel;

/// 忽略规则的目标文件。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum IgnoreTarget {
    /// 仓库根的 `.gitignore`（对仓库可见）。
    Gitignore,
    /// `.git/info/exclude`（只对本仓库本地生效，不入库）。
    LocalExclude,
}

impl IgnoreTarget {
    fn file_path(self) -> &'static str {
        match self {
            IgnoreTarget::Gitignore => ".gitignore",
            IgnoreTarget::LocalExclude => ".git/info/exclude",
        }
    }

    fn title(self) -> &'static str {
        match self {
            IgnoreTarget::Gitignore => tr("Add to .gitignore"),
            IgnoreTarget::LocalExclude => tr("Add to .local exclude"),
        }
    }

    /// 规则行：目录条目追加 `/` 前缀的目录规则即可覆盖其下所有文件。
    fn rule_for(path: &str) -> String {
        if path.ends_with('/') {
            format!("/{path}*")
        } else {
            format!("/{path}")
        }
    }
}

impl GitPanel {
    /// 右键「加入忽略」入口：记录待确认项并弹出确认覆盖层。
    pub(crate) fn request_add_to_ignore(
        &mut self,
        target: IgnoreTarget,
        paths: &[String],
        cx: &mut Context<Self>,
    ) {
        if self.pending_action.is_some() || self.committing || paths.is_empty() {
            return;
        }
        self.pending_ignore = Some((target, paths.to_vec()));
        cx.notify();
    }

    /// 读取现有规则文件并追加规则行；写回成功后刷新状态。
    pub(crate) fn confirm_add_to_ignore(&mut self, cx: &mut Context<Self>) {
        let Some((target, paths)) = self.pending_ignore.take() else {
            return;
        };
        let Some(root) = self.root.clone() else {
            return;
        };
        let rules: Vec<String> = paths.iter().map(|p| IgnoreTarget::rule_for(p)).collect();
        let file_path = target.file_path();
        let success: &'static str = target.title();
        let generation = self.generation;
        let client = self.client;
        cx.notify();

        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move {
                    // 先读现有内容再整体写回，保留无关行与注释；read_file 对
                    // 不存在的文件返回错误，此时按空文件处理。
                    let existing = client
                        .read_file(&root, file_path)
                        .map(|result| result.text)
                        .unwrap_or_default();
                    let mut text = existing;
                    if !text.is_empty() && !text.ends_with('\n') {
                        text.push('\n');
                    }
                    for rule in &rules {
                        text.push_str(rule);
                        text.push('\n');
                    }
                    client.write_file(&root, file_path, &text)
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                match raw {
                    Ok(_) => {
                        this.reload_all(cx);
                        this.notice = Some(SharedString::from(success));
                    }
                    Err(error) => {
                        this.error = Some(SharedString::from(error.to_string()));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(crate) fn cancel_add_to_ignore(&mut self, cx: &mut Context<Self>) {
        if self.pending_ignore.take().is_some() {
            cx.notify();
        }
    }

    /// 忽略确认覆盖层。
    pub(crate) fn render_ignore_confirm(
        &self,
        target: IgnoreTarget,
        paths: &[String],
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let title = target.title();
        let summary = if paths.len() == 1 {
            paths.first().cloned().unwrap_or_default()
        } else {
            tr("{count} files").replace("{count}", &paths.len().to_string())
        };

        div()
            .id("lithe-git-ignore-backdrop")
            .absolute()
            .inset_0()
            .flex()
            .items_center()
            .justify_center()
            .bg(tokens.window.alpha(0.62))
            .on_click(cx.listener(|this, _, _, cx| this.cancel_add_to_ignore(cx)))
            .child(
                v_flex()
                    .id("lithe-git-ignore-dialog")
                    .w(px(420.0))
                    .rounded(px(LitheMetrics::MENU_RADIUS))
                    .border_1()
                    .border_color(tokens.panel_border)
                    .bg(tokens.raised)
                    .p(px(16.0))
                    .gap(px(10.0))
                    .on_click(cx.listener(|_, _, _, cx| cx.stop_propagation()))
                    .child(
                        div()
                            .text_size(px(14.0))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(tokens.primary_text)
                            .child(title),
                    )
                    .child(
                        div()
                            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                            .text_color(tokens.secondary_text)
                            .child(format!("{}: {summary}", tr("Paths"))),
                    )
                    .child(
                        h_flex()
                            .w_full()
                            .justify_end()
                            .gap(px(8.0))
                            .child(
                                Button::new("lithe-git-ignore-cancel")
                                    .ghost()
                                    .small()
                                    .label(tr("Cancel"))
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.cancel_add_to_ignore(cx);
                                    })),
                            )
                            .child(
                                Button::new("lithe-git-ignore-confirm")
                                    .primary()
                                    .small()
                                    .label(tr("Add"))
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.confirm_add_to_ignore(cx);
                                    })),
                            ),
                    ),
            )
            .into_any_element()
    }
}
