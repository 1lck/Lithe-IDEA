//! Pull 对话框：`git.pullPreflight` 结果回显 + 策略 / auto-stash 选择。
//!
//! 从 `git_dialogs.rs` 拆出（两个文件都保持在 1500 行以内），语义对齐
//! Tauri `git-pull-dialog.tsx` + `use-git-pull-workflow.ts`：打开时展示真实的
//! 上游、领先 / 落后、分叉与本地脏改动；没有上游时禁用确认并说明原因。

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::checkbox::Checkbox;
use gpui_kit::component::{Disableable as _, Sizable as _, h_flex, v_flex};
use gpui_kit::{
    AppContext as _, Context, InteractiveElement as _, IntoElement, ParentElement as _,
    SharedString, StatefulInteractiveElement as _, Styled as _, div, px,
};
use lithe_features::git::execute_git_command;
use lithe_ui::i18n::tr;
use serde_json::Value;

use super::git_dialogs::{GitDialogView, PullMode, PullPreviewData};

impl GitDialogView {
    /// Pull 对话框的 preflight：解析 Core `git.pullPreflight` 的真实分支状态；
    /// 失败把错误留在状态行（保留 stderr 展示，对齐 Tauri pull workflow）。
    pub(crate) fn run_pull_preflight(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(root_text) = root.to_str().map(str::to_string) else {
            return;
        };
        self.loading = true;
        let client = self.client;
        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move {
                    execute_git_command(
                        &client,
                        "git.pullPreflight",
                        serde_json::json!({ "root": root_text }),
                    )
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.loading = false;
                match raw {
                    Ok(value) => {
                        this.pull_preview = Some(PullPreviewData {
                            upstream: value
                                .get("upstream")
                                .and_then(Value::as_str)
                                .map(str::to_string),
                            ahead: value
                                .get("ahead")
                                .and_then(Value::as_u64)
                                .unwrap_or(0) as usize,
                            behind: value
                                .get("behind")
                                .and_then(Value::as_u64)
                                .unwrap_or(0) as usize,
                            diverged: value
                                .get("diverged")
                                .and_then(Value::as_bool)
                                .unwrap_or(false),
                            has_local_changes: value
                                .get("hasLocalChanges")
                                .and_then(Value::as_bool)
                                .unwrap_or(false),
                        });
                    }
                    Err(error) => {
                        this.error = Some(error.to_string());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    // --- Pull（对齐 Tauri git-pull-dialog：策略 + auto-stash） ----------------

    pub(crate) fn render_pull(
        &mut self,
        tokens: lithe_ui::LitheTokens,
        cx: &mut Context<Self>,
    ) -> gpui_kit::AnyElement {
        let mode = self.pull_mode;
        let preview = self.pull_preview.clone();
        let mut form = v_flex().gap(px(6.0));

        // 预检结果回显：上游 / 领先落后 / 分叉 / 本地改动。没有上游时 Core
        // 无法直接 pull，禁用确认并说明原因（不伪造可执行状态）。
        let has_upstream = preview
            .as_ref()
            .is_some_and(|preview| preview.upstream.is_some());
        match preview.as_ref() {
            Some(preview) => {
                form = form.child(
                    div()
                        .text_size(px(12.0))
                        .text_color(tokens.primary_text)
                        .child(match preview.upstream.as_deref() {
                            Some(upstream) => {
                                tr("Upstream: {upstream}").replace("{upstream}", upstream)
                            }
                            None => tr("No upstream is configured for this branch.").to_string(),
                        }),
                );
                if preview.upstream.is_some() {
                    form = form.child(
                        div()
                            .text_size(px(11.5))
                            .text_color(tokens.tertiary_text)
                            .child(
                                tr("Behind {behind}, ahead {ahead}")
                                    .replace("{behind}", &preview.behind.to_string())
                                    .replace("{ahead}", &preview.ahead.to_string()),
                            ),
                    );
                }
                if preview.diverged {
                    form = form.child(
                        div()
                            .text_size(px(11.5))
                            .text_color(tokens.warning)
                            .child(tr(
                                "The branches have diverged; fast-forward is not possible.",
                            )),
                    );
                }
                if preview.has_local_changes {
                    form = form.child(
                        div()
                            .text_size(px(11.5))
                            .text_color(tokens.warning)
                            .child(tr("Local changes are not committed.")),
                    );
                }
            }
            None => {
                form = form.child(
                    div()
                        .text_size(px(11.5))
                        .text_color(tokens.tertiary_text)
                        .child(if self.loading {
                            tr("Checking the upstream branch…")
                        } else {
                            tr("Pull state is unavailable.")
                        }),
                );
            }
        }

        for candidate in [PullMode::FfOnly, PullMode::Merge, PullMode::Rebase] {
            form = form.child(
                h_flex()
                    .id(SharedString::from(candidate.wire()))
                    .cursor_pointer()
                    .rounded(px(4.0))
                    .px(px(6.0))
                    .py(px(2.0))
                    .hover(|style| style.bg(tokens.hover))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.pull_mode = candidate;
                        cx.notify();
                    }))
                    .child(Self::radio_row(
                        "lithe-git-dialog:pull-mode-item",
                        self.pull_mode == candidate,
                        candidate.label(),
                        tokens,
                    )),
            );
        }
        form = form
            .child(
                Checkbox::new("lithe-git-dialog:pull-auto-stash")
                    .small()
                    .checked(self.pull_auto_stash)
                    .label(tr("Auto stash local changes"))
                    .on_change(cx.listener(|this, checked: &bool, _window, cx| {
                        this.pull_auto_stash = *checked;
                        cx.notify();
                    })),
            )
            .child(
                h_flex()
                    .justify_end()
                    .gap(px(8.0))
                    .child(Self::cancel_button("lithe-git-dialog:pull-cancel", cx))
                    .child(
                        Button::new("lithe-git-dialog:pull-confirm")
                            .primary()
                            .small()
                            .label(tr("Pull"))
                            // 没有上游时 Core 的 pull 必然失败：先禁用并给出原因。
                            .disabled(self.action_disabled() || !has_upstream)
                            .on_click(cx.listener(move |this, _, _, cx| {
                                // mode 语义见 Core `pull`；autoStash 覆盖本地
                                // 未提交改动的保护场景（camelCase 契约）。
                                let payload = serde_json::json!({
                                    "operation": "pull",
                                    "mode": mode.wire(),
                                    "autoStash": this.pull_auto_stash,
                                });
                                this.run_write(payload, cx);
                            })),
                    ),
            );
        form.into_any_element()
    }
}
