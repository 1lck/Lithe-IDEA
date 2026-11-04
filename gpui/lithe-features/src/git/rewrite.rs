//! 历史改写与提交动作的模态覆盖层（undo / edit message / delete / reset /
//! cherry-pick / revert），以及引用动作的确认与输入弹窗。
//!
//! 拆分自原 `git.rs`。执行语义对齐 Tauri use-git-history-mutations：先
//! `git.historyRewritePreview`（或 rebasePreview），确认后把预览的
//! expectedState 原样回传 `git.write`。

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::{Sizable as _, h_flex, v_flex};
use gpui_kit::{
    AnyElement, AppContext as _, Context, Div, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, Stateful, StatefulInteractiveElement as _, Styled as _,
    Window, div, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheMetrics, LitheTokens, MONO_FONT_FAMILY};
use serde_json::Value;

use super::model::{bool_field, command_failure_detail, parse_command, root_text, string_field};
use super::{
    BranchPromptAction, CommitAction, GitPanel, RewriteOperation, RewritePreview,
    execute_git_command,
};

impl GitPanel {
    /// 提交动作弹窗分发。
    pub(crate) fn render_commit_action_overlay(
        &mut self,
        action: CommitAction,
        window: &mut Window,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        match action {
            CommitAction::Rewrite { operation, .. } => {
                let preview = self
                    .pending_rewrite_preview
                    .as_ref()
                    .map(|boxed| (**boxed).clone());
                self.render_rewrite_confirm(operation, preview, tokens, cx)
            }
            CommitAction::EditMessageInput { .. } => {
                let preview = self
                    .pending_rewrite_preview
                    .as_ref()
                    .map(|boxed| (**boxed).clone())
                    .unwrap_or_default();
                self.render_edit_message_input(preview, window, tokens, cx)
            }
            CommitAction::Reset { revision } => {
                self.render_reset_mode_choice(revision, tokens, cx)
            }
            CommitAction::Simple { title, message, .. } => {
                self.render_simple_commit_confirm(title, message, tokens, cx)
            }
        }
    }

    /// 模态弹窗外壳（与引用确认相同的结构）。
    pub(crate) fn modal_shell(
        &self,
        id: &'static str,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> Stateful<Div> {
        v_flex()
            .id(id)
            .w(px(440.0))
            .rounded(px(LitheMetrics::MENU_RADIUS))
            .border_1()
            .border_color(tokens.panel_border)
            .bg(tokens.raised)
            .p(px(16.0))
            .gap(px(10.0))
            .on_click(cx.listener(|_, _, _, cx| cx.stop_propagation()))
    }

    /// 复制任意文本到剪贴板（提交哈希 / 说明共用）。
    pub(crate) fn copy_text(&self, text: &str, _window: &mut Window, cx: &mut Context<Self>) {
        cx.write_to_clipboard(gpui_kit::ClipboardItem::new_string(text.to_string()));
        cx.notify();
    }

    /// 引用动作确认弹窗（对齐 Tauri `showConfirmDialog` 的模态确认）。
    pub(crate) fn render_reference_confirm(
        &self,
        confirm: super::rewrite::ReferenceConfirm,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let title = confirm.title;
        div()
            .id("lithe-git-reference-confirm-backdrop")
            .absolute()
            .inset_0()
            .flex()
            .items_center()
            .justify_center()
            .bg(tokens.window.alpha(0.62))
            .on_click(cx.listener(|this, _, _, cx| {
                this.cancel_reference_action(cx);
            }))
            .child(
                v_flex()
                    .id("lithe-git-reference-confirm-dialog")
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
                            .child(confirm.message.clone()),
                    )
                    .child(
                        h_flex()
                            .w_full()
                            .justify_end()
                            .gap(px(8.0))
                            .child(
                                Button::new("lithe-git-ref-confirm-cancel")
                                    .ghost()
                                    .small()
                                    .label(tr("Cancel"))
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.cancel_reference_action(cx);
                                    })),
                            )
                            .child(
                                Button::new("lithe-git-ref-confirm-ok")
                                    .danger()
                                    .small()
                                    .label(title)
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.confirm_reference_action(cx);
                                    })),
                            ),
                    ),
            )
            .into_any_element()
    }

    /// 分支输入弹窗（新建 / 重命名）。GPUI 的 LithePrompt 绑定在工作台覆盖层，
    /// 面板内没有可复用的输入弹窗，这里用与确认弹窗相同的模态结构内置输入框。
    pub(crate) fn render_branch_prompt(
        &mut self,
        action: BranchPromptAction,
        source: super::model::CoreReference,
        window: &mut Window,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let (title, _label) = match action {
            BranchPromptAction::Create => (tr("New Branch"), tr("Branch name")),
            BranchPromptAction::Rename => (tr("Rename"), tr("Branch name")),
        };
        let source_desc = source.short_name.clone();
        div()
            .id("lithe-git-branch-prompt-backdrop")
            .absolute()
            .inset_0()
            .flex()
            .items_center()
            .justify_center()
            .bg(tokens.window.alpha(0.62))
            .on_click(cx.listener(|this, _, _, cx| {
                this.cancel_branch_prompt(cx);
            }))
            .child(
                v_flex()
                    .id("lithe-git-branch-prompt-dialog")
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
                            .child(format!("{}: {source_desc}", tr("Source"))),
                    )
                    .children(self.branch_input_element(window, cx))
                    .child(
                        h_flex()
                            .w_full()
                            .justify_end()
                            .gap(px(8.0))
                            .child(
                                Button::new("lithe-git-branch-prompt-cancel")
                                    .ghost()
                                    .small()
                                    .label(tr("Cancel"))
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.cancel_branch_prompt(cx);
                                    })),
                            )
                            .child(
                                Button::new("lithe-git-branch-prompt-ok")
                                    .primary()
                                    .small()
                                    .label(title)
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.submit_branch_prompt(cx);
                                    })),
                            ),
                    ),
            )
            .into_any_element()
    }

    /// 历史改写确认弹窗：展示受影响提交，确认后带 expectedState 执行。
    fn render_rewrite_confirm(
        &self,
        operation: RewriteOperation,
        preview: Option<RewritePreview>,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let title = operation.title();
        let affected = preview
            .as_ref()
            .map(|preview| preview.affected_commit_summary())
            .unwrap_or_else(|| tr("Loading…").to_string());
        let suggestion = preview
            .as_ref()
            .map(|preview| preview.suggested_message.clone())
            .unwrap_or_default();

        let backdrop = div()
            .id("lithe-git-rewrite-backdrop")
            .absolute()
            .inset_0()
            .flex()
            .items_center()
            .justify_center()
            .bg(tokens.window.alpha(0.62))
            .on_click(cx.listener(|this, _, _, cx| {
                this.cancel_commit_action(cx);
            }));

        let mut dialog = self
            .modal_shell("lithe-git-rewrite-dialog", tokens, cx)
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
                    .child(affected),
            );

        if operation == RewriteOperation::EditCommitMessage && !suggestion.is_empty() {
            dialog = dialog.child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .font_family(MONO_FONT_FAMILY)
                    .text_color(tokens.primary_text)
                    .child(suggestion),
            );
        }

        dialog = dialog.child(
            h_flex()
                .w_full()
                .justify_end()
                .gap(px(8.0))
                .child(
                    Button::new("lithe-git-rewrite-cancel")
                        .ghost()
                        .small()
                        .label(tr("Cancel"))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.cancel_commit_action(cx);
                        })),
                )
                .child(
                    Button::new("lithe-git-rewrite-ok")
                        .danger()
                        .small()
                        .label(title)
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.confirm_commit_action(cx);
                        })),
                ),
        );

        backdrop.child(dialog).into_any_element()
    }

    /// 编辑提交消息输入弹窗（预填 Core 的 suggestedMessage）。
    fn render_edit_message_input(
        &mut self,
        preview: RewritePreview,
        window: &mut Window,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        // 复用分支输入实体：弹窗打开时惰性创建并预填 suggestedMessage。
        if self.branch_input.is_none() {
            let initial = preview.suggested_message.clone();
            let input = cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder(tr("Commit message"))
                    .default_value(initial)
            });
            cx.subscribe_in(
                &input,
                window,
                |this: &mut Self, _input, event: &InputEvent, _window, cx| match event {
                    InputEvent::PressEnter { .. } => {
                        this.confirm_edit_message(cx);
                    }
                    InputEvent::Change | InputEvent::Focus | InputEvent::Blur => {}
                },
            )
            .detach();
            self.branch_input = Some(input);
            cx.notify();
        }

        let backdrop = div()
            .id("lithe-git-edit-message-backdrop")
            .absolute()
            .inset_0()
            .flex()
            .items_center()
            .justify_center()
            .bg(tokens.window.alpha(0.62))
            .on_click(cx.listener(|this, _, _, cx| {
                this.cancel_commit_action(cx);
            }));

        let dialog = self
            .modal_shell("lithe-git-edit-message-dialog", tokens, cx)
            .child(
                div()
                    .text_size(px(14.0))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(tokens.primary_text)
                    .child(tr("Edit Commit Message")),
            )
            .children(
                self.branch_input
                    .clone()
                    .map(|input| Input::new(&input).small().into_any_element()),
            )
            .child(
                h_flex()
                    .w_full()
                    .justify_end()
                    .gap(px(8.0))
                    .child(
                        Button::new("lithe-git-edit-message-cancel")
                            .ghost()
                            .small()
                            .label(tr("Cancel"))
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.cancel_commit_action(cx);
                            })),
                    )
                    .child(
                        Button::new("lithe-git-edit-message-ok")
                            .primary()
                            .small()
                            .label(tr("Save"))
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.confirm_edit_message(cx);
                            })),
                    ),
            );

        backdrop.child(dialog).into_any_element()
    }

    /// 提交编辑消息：读取输入框内容并执行改写。
    pub(crate) fn confirm_edit_message(&mut self, cx: &mut Context<Self>) {
        let Some(preview) = self.pending_rewrite_preview.clone() else {
            self.cancel_commit_action(cx);
            return;
        };
        let message = self
            .branch_input
            .take()
            .map(|input| input.read(cx).value().to_string())
            .unwrap_or_default();
        self.commit_action = None;
        self.execute_rewrite(*preview, Some(message), cx);
    }

    /// Reset 模式选择弹窗（soft / mixed / hard，对齐 Tauri showChoiceDialog）。
    fn render_reset_mode_choice(
        &self,
        revision: String,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let short_hash: String = revision.chars().take(8).collect();
        let backdrop = div()
            .id("lithe-git-reset-backdrop")
            .absolute()
            .inset_0()
            .flex()
            .items_center()
            .justify_center()
            .bg(tokens.window.alpha(0.62))
            .on_click(cx.listener(|this, _, _, cx| {
                this.cancel_commit_action(cx);
            }));

        let mut dialog = self
            .modal_shell("lithe-git-reset-dialog", tokens, cx)
            .child(
                div()
                    .text_size(px(14.0))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(tokens.primary_text)
                    .child(tr("Reset to Commit")),
            )
            .child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .font_family(MONO_FONT_FAMILY)
                    .text_color(tokens.secondary_text)
                    .child(short_hash),
            );

        for (mode, label, danger) in [
            ("soft", tr("Soft - keep staged"), false),
            ("mixed", tr("Mixed - keep files"), false),
            ("hard", tr("Hard - discard changes"), true),
        ] {
            let revision = revision.clone();
            let mut button = Button::new(SharedString::from(format!("lithe-git-reset:{mode}")))
                .label(label)
                .small()
                .w_full();
            button = if danger {
                button.danger()
            } else {
                button.primary()
            };
            dialog = dialog.child(button.on_click(cx.listener(move |this, _, _, cx| {
                let revision = revision.clone();
                let title = tr("Reset to Commit");
                this.commit_action = None;
                this.run_simple_commit_write("reset", &revision, Some(mode), title, cx);
            })));
        }

        dialog = dialog.child(
            h_flex().w_full().justify_end().child(
                Button::new("lithe-git-reset-cancel")
                    .ghost()
                    .small()
                    .label(tr("Cancel"))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.cancel_commit_action(cx);
                    })),
            ),
        );

        backdrop.child(dialog).into_any_element()
    }

    /// 简单提交动作确认弹窗（cherry-pick / revert）。
    fn render_simple_commit_confirm(
        &self,
        title: &'static str,
        message: String,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let backdrop = div()
            .id("lithe-git-simple-confirm-backdrop")
            .absolute()
            .inset_0()
            .flex()
            .items_center()
            .justify_center()
            .bg(tokens.window.alpha(0.62))
            .on_click(cx.listener(|this, _, _, cx| {
                this.cancel_commit_action(cx);
            }));

        let dialog = self
            .modal_shell("lithe-git-simple-confirm-dialog", tokens, cx)
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
                    .child(message),
            )
            .child(
                h_flex()
                    .w_full()
                    .justify_end()
                    .gap(px(8.0))
                    .child(
                        Button::new("lithe-git-simple-confirm-cancel")
                            .ghost()
                            .small()
                            .label(tr("Cancel"))
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.cancel_commit_action(cx);
                            })),
                    )
                    .child(
                        Button::new("lithe-git-simple-confirm-ok")
                            .primary()
                            .small()
                            .label(title)
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.confirm_commit_action(cx);
                            })),
                    ),
            );

        backdrop.child(dialog).into_any_element()
    }

    /// 发起历史改写：先加载 `git.historyRewritePreview`，允许则进入确认，
    /// 编辑消息则进入输入步骤。
    pub(crate) fn begin_rewrite(
        &mut self,
        operation: RewriteOperation,
        revision: String,
        cx: &mut Context<Self>,
    ) {
        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(root_text) = root_text(&root) else {
            return;
        };
        if self.loading_rewrite_preview || self.is_reference_busy() {
            return;
        }

        let generation = self.generation;
        let client = self.client;
        self.loading_rewrite_preview = true;
        cx.notify();

        cx.spawn(async move |this, cx| {
            let payload = serde_json::json!({
                "root": root_text,
                "operation": operation.wire(),
                "revisions": [revision],
            });
            let raw = cx
                .background_spawn(async move {
                    execute_git_command(&client, "git.historyRewritePreview", payload)
                })
                .await;

            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.loading_rewrite_preview = false;
                match raw {
                    Ok(value) => {
                        let preview = parse_rewrite_preview(&value, operation);
                        if !preview.allowed || preview.expected_state.is_none() {
                            let detail = if preview.blockers.is_empty() {
                                tr("Git history operation failed").to_string()
                            } else {
                                preview.blockers.join("\n")
                            };
                            this.error = Some(SharedString::from(detail));
                        } else if operation == RewriteOperation::EditCommitMessage {
                            // 输入弹窗预填 Core 的 suggestedMessage。
                            this.pending_rewrite_preview = Some(Box::new(preview));
                            this.commit_action =
                                Some(CommitAction::EditMessageInput { revision });
                        } else {
                            this.commit_action = Some(CommitAction::Rewrite {
                                operation,
                                revision,
                            });
                            // 预览数据随动作一起保存，确认时直接取。
                            this.pending_rewrite_preview = Some(Box::new(preview));
                        }
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

    /// 执行历史改写：把预览的 expectedState 原样回传 `git.write`（对齐 Tauri
    /// `executeGitHistoryRewrite`）。编辑消息附带用户修改后的 message。
    pub(crate) fn execute_rewrite(
        &mut self,
        preview: RewritePreview,
        message: Option<String>,
        cx: &mut Context<Self>,
    ) {
        let Some(expected) = preview.expected_state.clone() else {
            return;
        };
        let operation = expected
            .get("operation")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let revisions: Vec<String> = expected
            .get("revisions")
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .filter_map(Value::as_str)
                    .map(String::from)
                    .collect()
            })
            .unwrap_or_default();
        if operation.is_empty() || revisions.is_empty() {
            return;
        }

        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(root_text) = root_text(&root) else {
            return;
        };

        let mut payload = serde_json::json!({
            "root": root_text,
            "operation": operation,
            "expectedState": expected,
        });
        if operation == "squashCommits" {
            payload["revisions"] = serde_json::Value::Array(
                revisions
                    .iter()
                    .map(|r| serde_json::Value::String(r.clone()))
                    .collect(),
            );
        } else {
            payload["revision"] = serde_json::Value::String(revisions[0].clone());
        }
        if let Some(text) = message {
            payload["message"] = serde_json::Value::String(text);
        }

        let generation = self.generation;
        let client = self.client;
        self.reference_mutation = Some("historyRewrite");
        self.error = None;
        self.notice = None;
        cx.notify();

        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move { execute_git_command(&client, "git.write", payload) })
                .await;

            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.reference_mutation = None;
                match raw {
                    Ok(value) => {
                        let command = parse_command(&value).unwrap_or_default();
                        if command.exit_code == 0 {
                            this.reload_all(cx);
                            this.notice = Some(SharedString::from(tr("History rewritten")));
                        } else {
                            this.error = Some(SharedString::from(command_failure_detail(
                                &command,
                                tr("Git history operation failed"),
                            )));
                        }
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

    /// 执行 reset / cherry-pick / revert 这类直接写操作。
    pub(crate) fn run_simple_commit_write(
        &mut self,
        operation: &'static str,
        revision: &str,
        mode: Option<&str>,
        title: &'static str,
        cx: &mut Context<Self>,
    ) {
        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(root_text) = root_text(&root) else {
            return;
        };
        if self.is_reference_busy() {
            return;
        }

        let mut payload = serde_json::json!({
            "root": root_text,
            "operation": operation,
            "revision": revision,
        });
        if let Some(mode) = mode {
            payload["mode"] = serde_json::Value::String(format!("--{mode}"));
        }

        let generation = self.generation;
        let client = self.client;
        self.reference_mutation = Some(title);
        self.error = None;
        self.notice = None;
        cx.notify();

        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move { execute_git_command(&client, "git.write", payload) })
                .await;

            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.reference_mutation = None;
                match raw {
                    Ok(value) => {
                        let command = parse_command(&value).unwrap_or_default();
                        if command.exit_code == 0 {
                            this.reload_all(cx);
                            this.notice = Some(SharedString::from(title));
                        } else {
                            this.error =
                                Some(SharedString::from(command_failure_detail(&command, title)));
                        }
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

    /// 确认当前挂起的提交动作。
    pub(crate) fn confirm_commit_action(&mut self, cx: &mut Context<Self>) {
        let Some(action) = self.commit_action.take() else {
            return;
        };
        self.pending_rewrite_preview = None;
        match action {
            CommitAction::Rewrite { .. } => {
                // 预览在 begin_rewrite 里已暂存。
                if let Some(preview) = self.pending_rewrite_preview.take() {
                    self.execute_rewrite(*preview, None, cx);
                }
            }
            CommitAction::Reset { revision } => {
                self.run_simple_commit_write(
                    "reset",
                    &revision,
                    Some("mixed"),
                    tr("Reset to Commit"),
                    cx,
                );
            }
            CommitAction::Simple {
                operation,
                revision,
                title,
                ..
            } => {
                self.run_simple_commit_write(operation, &revision, None, title, cx);
            }
            CommitAction::EditMessageInput { .. } => {
                // 输入步骤由专门弹窗处理；这里不应到达。
            }
        }
        cx.notify();
    }

    pub(crate) fn cancel_commit_action(&mut self, cx: &mut Context<Self>) {
        if self.commit_action.take().is_some() {
            self.pending_rewrite_preview = None;
            cx.notify();
        }
    }
}

/// 引用树等待确认的结构（对齐 Tauri `showConfirmDialog`）。
#[derive(Debug, Clone)]
pub(crate) struct ReferenceConfirm {
    /// Core `git.write` 的 operation 字段（checkoutAndRebase / merge / rebase /
    /// pull / deleteBranch 等）。
    pub(crate) operation: &'static str,
    pub(crate) reference: super::model::CoreReference,
    /// 确认弹窗标题（对齐 Tauri `t("git.log.action.${action}")`）。
    pub(crate) title: &'static str,
    pub(crate) message: String,
    /// 确认后展示的成功提示。
    pub(crate) success: &'static str,
}

/// 解析 `git.historyRewritePreview` 响应。
pub(crate) fn parse_rewrite_preview(value: &Value, operation: RewriteOperation) -> RewritePreview {
    let _ = operation;
    let blockers = value
        .get("blockers")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.get("message").and_then(Value::as_str))
                .map(String::from)
                .collect()
        })
        .unwrap_or_default();
    let selected_count = value
        .get("selectedCommits")
        .and_then(Value::as_array)
        .map(|items| items.len())
        .unwrap_or(0);

    RewritePreview {
        allowed: bool_field(value.get("allowed")),
        blockers,
        selected_count,
        suggested_message: string_field(value.get("suggestedMessage")),
        expected_state: value.get("expectedState").cloned(),
    }
}
