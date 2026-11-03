//! IntelliJ 提交区：Amend 行、消息输入框、校验提示、提交按钮行，以及
//! 工作区提交会话的覆盖层（Review 卡 / 推送目标追问 / 批量结果）。
//!
//! 拆分自原 `git.rs`。会话数据是对 Core `git.workspaceCommitPrepare/Step`
//! 响应的最小本地解析：`session` 原样保存用于回传，只提取渲染需要的
//! camelCase 字段（对齐 Tauri `git-commit-panel.tsx` + `git-workspace-commit-*`）。

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::Textarea;
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, Context, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _, Window, div, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheMetrics, LitheTokens};
use serde_json::Value;

use super::model::{
    COMMIT_ACTIONS_HEIGHT, COMMIT_INPUT_RADIUS, COMMIT_MESSAGE_HEIGHT, COMMIT_METADATA_HEIGHT,
    COMMIT_PADDING_X, bool_field, string_field,
};
use super::{ChangeStatusCounts, GitPanel};

/// 推送目标追问（对齐 Core `PushTargetQuestion` / Tauri push-target prompt）。
#[derive(Debug, Clone)]
pub(crate) struct PushTargetQuestionView {
    pub(crate) repository_id: String,
    pub(crate) local_branch: String,
    pub(crate) remote: String,
    pub(crate) upstream: String,
    pub(crate) upstream_branch: String,
}

/// 逐仓库结果行（对齐 Core `RepositoryResult`）。
#[derive(Debug, Clone)]
pub(crate) struct CommitResultRow {
    pub(crate) repository_id: String,
    pub(crate) committed: bool,
    pub(crate) pushed: bool,
    pub(crate) status: String,
    pub(crate) detail: String,
}

/// 工作区提交会话的本地状态。`session` 是 Core 返回的不透明延续，
/// 原样回传给下一个 step；其余字段只服务渲染。
#[derive(Debug, Clone)]
pub(crate) struct CommitSessionState {
    pub(crate) session: Value,
    pub(crate) repositories: Vec<String>,
    pub(crate) results: Vec<CommitResultRow>,
    pub(crate) push: bool,
    pub(crate) busy: bool,
    pub(crate) finished: bool,
    pub(crate) succeeded: bool,
    pub(crate) can_retry: bool,
    pub(crate) cancel_requested: bool,
    pub(crate) stopped: bool,
    pub(crate) command_failed: bool,
    pub(crate) requires_confirmation: bool,
    pub(crate) review_visible: bool,
    pub(crate) pending_questions: Vec<PushTargetQuestionView>,
}

impl CommitSessionState {
    /// 从 `git.workspaceCommitPrepare` 响应构建；响应形状不对时返回 `None`。
    pub(crate) fn from_prepare(value: Value, push: bool) -> Option<Self> {
        let session = value.get("session").cloned()?;
        let plan = session.get("plan").cloned().unwrap_or(Value::Null);

        let repositories = plan
            .get("repositories")
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .filter_map(|item| item.get("id").and_then(Value::as_str))
                    .map(String::from)
                    .collect()
            })
            .unwrap_or_default();

        let results = session
            .get("results")
            .and_then(Value::as_object)
            .map(|map| {
                let mut rows: Vec<CommitResultRow> = map
                    .iter()
                    .map(|(id, result)| CommitResultRow {
                        repository_id: id.clone(),
                        committed: bool_field(result.get("committed")),
                        pushed: bool_field(result.get("pushed")),
                        status: string_field(result.get("status")),
                        detail: string_field(result.get("detail")),
                    })
                    .collect();
                rows.sort_by(|a, b| a.repository_id.cmp(&b.repository_id));
                rows
            })
            .unwrap_or_default();

        let pending_questions = value
            .get("pushTargetQuestions")
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .map(|item| PushTargetQuestionView {
                        repository_id: string_field(item.get("repositoryId")),
                        local_branch: string_field(item.get("localBranch")),
                        remote: string_field(item.get("remote")),
                        upstream: string_field(item.get("upstream")),
                        upstream_branch: string_field(item.get("upstreamBranch")),
                    })
                    .collect()
            })
            .unwrap_or_default();

        Some(Self {
            finished: bool_field(session.get("finished")),
            succeeded: bool_field(session.get("succeeded")),
            can_retry: bool_field(session.get("canRetry")),
            requires_confirmation: bool_field(value.get("requiresConfirmation")),
            results,
            repositories,
            session,
            push,
            busy: false,
            cancel_requested: false,
            stopped: false,
            command_failed: false,
            review_visible: true,
            pending_questions,
        })
    }

    /// 计划里的提交说明。重试与推送目标追问后的 `prepare` 必须带同一条
    /// 消息（Core 拒绝空消息），因此从原计划的 `message` 字段读回。
    pub(crate) fn plan_message(&self) -> String {
        self.session
            .get("plan")
            .and_then(|plan| plan.get("message"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string()
    }

    /// 计划里的 Amend 标记（重试时保持原来的提交形态）。
    pub(crate) fn plan_amend(&self) -> bool {
        self.session
            .get("plan")
            .and_then(|plan| plan.get("amend"))
            .and_then(Value::as_bool)
            .unwrap_or(false)
    }

    /// 计划里的 includeParentReferences（重试时沿用原计划的选择）。
    pub(crate) fn plan_include_parent_references(&self) -> bool {
        self.session
            .get("plan")
            .and_then(|plan| plan.get("includeParentReferences"))
            .and_then(Value::as_bool)
            .unwrap_or(false)
    }

    /// 把 step 响应写回会话状态（results / finished / cursor 等）。
    pub(crate) fn apply_step(&mut self, value: &Value) {
        if let Some(session) = value.get("session") {
            self.session = session.clone();
            self.finished = bool_field(session.get("finished"));
            self.succeeded = bool_field(session.get("succeeded"));
            self.can_retry = bool_field(session.get("canRetry"));
            if let Some(results) = session.get("results").and_then(Value::as_object) {
                let mut rows: Vec<CommitResultRow> = results
                    .iter()
                    .map(|(id, result)| CommitResultRow {
                        repository_id: id.clone(),
                        committed: bool_field(result.get("committed")),
                        pushed: bool_field(result.get("pushed")),
                        status: string_field(result.get("status")),
                        detail: string_field(result.get("detail")),
                    })
                    .collect();
                rows.sort_by(|a, b| a.repository_id.cmp(&b.repository_id));
                self.results = rows;
            }
        }
    }
}

impl GitPanel {
    /// IntelliJ 提交区：分隔线之上是变更树，之下依次是 Amend 行、消息输入框、
    /// 校验提示与提交按钮行。几何对齐 Tauri `git-commit-panel`（gap 6px、内边距
    /// `3px 11px 6px`），不为它再套一层卡片边框。
    pub(crate) fn render_bottom(
        &self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let message = self
            .commit_input
            .as_ref()
            .map(|input| input.read(cx).value())
            .unwrap_or_default();
        // 提交与索引写操作同一时刻只允许一个；Amend 开关同样在期间锁定。
        let busy = self.committing
            || self.pending_action.is_some()
            || self.commit_session.as_ref().is_some_and(|s| s.busy);
        let staged_count = self.staged_count();
        let has_no_changes = staged_count == 0;
        let has_no_message = message.trim().is_empty();
        let can_commit = self.root.is_some()
            && self
                .status
                .as_ref()
                .is_some_and(|status| status.branch.is_some())
            && !busy
            && !has_no_changes
            && !has_no_message;
        // AI 生成按钮的可用性规则与 Tauri `isGenerateDisabled` 一致：
        // 未启用 / 没有暂存文件 / 正在提交时都禁用。
        let can_generate = self.ai_commit_enabled && !has_no_changes && !busy;
        let legend = ChangeStatusCounts::from_status(self.status.as_ref());

        // --- Amend 行：[x] Amend last commit ........ AI   {N} staged  🕘 ---
        let amend_row = h_flex()
            .w_full()
            .flex_shrink_0()
            .h(px(COMMIT_METADATA_HEIGHT))
            .items_center()
            .gap(px(7.0))
            .px(px(1.0))
            .child(
                // 受控开关：点击只写入请求值，由本视图重绘后回显。
                gpui_kit::component::checkbox::Checkbox::new("lithe-git:amend")
                    .small()
                    .flex_shrink_0()
                    .checked(self.amend)
                    .label(tr("Amend"))
                    .disabled(busy)
                    .on_change(cx.listener(|this, checked: &bool, _window, cx| {
                        this.amend = *checked;
                        cx.notify();
                    })),
            )
            .child(
                div()
                    .flex_shrink_0()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.accent)
                    .child(tr("last commit")),
            )
            .child(div().flex_1())
            // AI 生成按钮。GPUI 构建没有 HTTP 客户端，生成能力由 Agent 面板
            // 承担，所以这里只对齐位置与可用性；关掉设置里的开关即禁用。
            .child(
                Button::new("lithe-git:generate-message")
                    .secondary()
                    .small()
                    .flex_shrink_0()
                    .label(tr("AI"))
                    .icon(Icon::new(gpui_kit::assets::IconName::Sparkles))
                    .tooltip(tr("Generate commit message with AI"))
                    .disabled(!can_generate)
                    .on_click(cx.listener(|this, _, window, cx| {
                        // 生成动作不在本构建里；点击把用户带去配置页，避免
                        // 留下一个点了没反应的按钮。
                        this.open_ai_settings(window, cx);
                    })),
            )
            .child(
                div()
                    .flex_shrink_0()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.tertiary_text)
                    .child(tr("{count} staged").replace("{count}", &staged_count.to_string())),
            )
            // 提交图例：N added / N modified / N deleted（对齐 buildCommitLegend）。
            .when(legend.total() > 0, |this| {
                this.child(render_commit_legend(legend, tokens))
            })
            // 对齐 Tauri Amend 行右端的 `History` 回滚时钟图标。
            .child(
                Icon::new(gpui_kit::assets::IconName::RotateCcwClock)
                    .flex_shrink_0()
                    .text_color(tokens.tertiary_text),
            );

        // --- 消息输入框：1px 中性边框，聚焦时换成强调色，出错时换成错误色。 ---
        let focused = self.commit_focused;
        let has_error = self.error.is_some()
            || self
                .commit_hint
                .is_some_and(|hint| hint.no_message && has_no_message);
        let border_color = if has_error {
            tokens.error
        } else if focused {
            tokens.accent
        } else {
            tokens.panel_border
        };

        let input = match self.commit_input.as_ref() {
            Some(input) => Textarea::new(input)
                .w_full()
                .h_full()
                // 外框由下面的 message_box 提供，输入框自己不再画一层背景和描边，
                // 否则套在一起会出现双边框。
                .appearance(false)
                .bordered(false)
                .aria_label(tr("Commit message"))
                .into_any_element(),
            None => div()
                .w_full()
                .h(px(LitheMetrics::TREE_ROW_HEIGHT))
                .px(px(9.0))
                .flex()
                .items_center()
                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                .text_color(tokens.tertiary_text)
                .child(tr("Commit message"))
                .into_any_element(),
        };

        let message_box = div()
            .w_full()
            .flex_shrink_0()
            .h(px(COMMIT_MESSAGE_HEIGHT))
            .overflow_hidden()
            .rounded(px(COMMIT_INPUT_RADIUS))
            .border_1()
            .border_color(border_color)
            .bg(tokens.editor)
            .child(input);

        // --- 校验提示：只在键盘提交被拦下、且用户还没改掉对应问题时出现。 ---
        // 与 Tauri 一致：补上文件或消息后，那一半提示自动消失。
        let visible_hint = self.commit_hint.and_then(|hint| {
            let no_changes = hint.no_changes && has_no_changes;
            let no_message = hint.no_message && has_no_message;
            // 每个分支都直接传字面量，i18n 生成脚本才会把三条文案收进词表。
            if no_changes && no_message {
                Some(tr("Select files to commit and specify commit message"))
            } else if no_changes {
                Some(tr("Select files to commit"))
            } else if no_message {
                Some(tr("Specify commit message"))
            } else {
                None
            }
        });

        // --- 按钮行：[提交] [提交并推送...] ......... 设置 ---
        let actions_row = h_flex()
            .w_full()
            .flex_shrink_0()
            .h(px(COMMIT_ACTIONS_HEIGHT))
            .items_center()
            .gap(px(6.0))
            .px(px(1.0))
            .child(
                Button::new("lithe-git:commit")
                    .primary()
                    .small()
                    .label(if self.committing {
                        tr("Committing...")
                    } else {
                        tr("Commit")
                    })
                    .disabled(!can_commit)
                    .on_click(cx.listener(|this, _, window, cx| this.commit(window, cx))),
            )
            .child(
                Button::new("lithe-git:commit-and-push")
                    .small()
                    .label(tr("Commit and Push..."))
                    .disabled(!can_commit)
                    .on_click(cx.listener(|this, _, window, cx| this.commit_and_push(window, cx))),
            )
            .child(div().flex_1())
            .child(
                Button::new("lithe-git:commit-settings")
                    .ghost()
                    .with_size(px(COMMIT_ACTIONS_HEIGHT - 6.0))
                    .rounded(px(4.0))
                    .icon(Icon::new(gpui_kit::assets::IconName::Settings))
                    .tooltip(tr("AI & Commit settings"))
                    .on_click(cx.listener(|this, _, window, cx| this.open_ai_settings(window, cx))),
            );

        v_flex()
            .id("lithe-git-commit-area")
            .w_full()
            .flex_shrink_0()
            .min_h_0()
            .gap(px(6.0))
            .px(px(COMMIT_PADDING_X))
            .pt(px(3.0))
            .pb(px(6.0))
            .bg(tokens.sidebar)
            .border_t_1()
            .border_color(tokens.divider)
            .child(amend_row)
            .child(message_box)
            .when_some(visible_hint, |this, hint| {
                this.child(
                    h_flex()
                        .w_full()
                        .flex_shrink_0()
                        .items_center()
                        .gap(px(6.0))
                        .child(
                            Icon::new(gpui_kit::assets::IconName::CircleAlert)
                                .flex_shrink_0()
                                .text_color(tokens.error),
                        )
                        .child(
                            div()
                                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                                .text_color(tokens.error)
                                .child(hint),
                        ),
                )
            })
            .child(actions_row)
            .into_any_element()
    }

    /// 打开设置页 AI & Commit。没有注册回调时静默返回（独立预览面板）。
    pub(crate) fn open_ai_settings(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(handler) = self.on_open_ai_settings.clone() else {
            return;
        };
        handler(window, cx);
    }

    /// 工作区提交会话覆盖层：Review 卡 / 推送目标追问 / 结果列表。
    /// 没有会话时返回 `None`。
    pub(crate) fn render_commit_session_overlay(
        &self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let session = self.commit_session.as_ref()?;
        let mut card = v_flex()
            .id("lithe-git-commit-session")
            .w(px(520.0))
            .max_h(px(420.0))
            .rounded(px(LitheMetrics::MENU_RADIUS))
            .border_1()
            .border_color(tokens.panel_border)
            .bg(tokens.raised)
            .p(px(16.0))
            .gap(px(10.0))
            .overflow_y_scroll()
            .on_click(cx.listener(|_, _, _, cx| cx.stop_propagation()));

        let title: &'static str = if !session.pending_questions.is_empty() {
            tr("Push target")
        } else if session.finished {
            tr("Commit result")
        } else if session.requires_confirmation {
            tr("Review commit")
        } else {
            tr("Committing...")
        };
        card = card.child(
            div()
                .text_size(px(14.0))
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(tokens.primary_text)
                .child(title),
        );

        // 推送目标追问：列出问题与两个目的地选项（对齐 git-push-target-prompt）。
        if !session.pending_questions.is_empty() {
            for question in &session.pending_questions {
                card = card
                    .child(
                        div()
                            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                            .text_color(tokens.secondary_text)
                            .child(format!(
                                "{}: {} → {}:{}",
                                question.repository_id,
                                question.local_branch,
                                question.remote,
                                question.upstream_branch
                            )),
                    )
                    .child(
                        h_flex()
                            .gap(px(8.0))
                            .child(
                                Button::new(SharedString::from(format!(
                                    "lithe-git:push-target-publish:{}",
                                    question.repository_id
                                )))
                                .small()
                                .primary()
                                .label(tr("Publish"))
                                .disabled(session.busy)
                                .on_click(cx.listener({
                                    let id = question.repository_id.clone();
                                    move |this, _, _, cx| {
                                        this.answer_push_target(id.clone(), "publish", cx)
                                    }
                                })),
                            )
                            .child(
                                Button::new(SharedString::from(format!(
                                    "lithe-git:push-target-upstream:{}",
                                    question.repository_id
                                )))
                                .small()
                                .label(tr("Use upstream"))
                                .disabled(session.busy)
                                .on_click(cx.listener({
                                    let id = question.repository_id.clone();
                                    move |this, _, _, cx| {
                                        this.answer_push_target(id.clone(), "upstream", cx)
                                    }
                                })),
                            ),
                    );
            }
            return Some(backdrop(self, card, tokens, cx));
        }

        // Review 卡：仓库列表与本次将执行的动作（对齐 workspace-commit-review）。
        if session.review_visible && session.requires_confirmation {
            for repository in &session.repositories {
                card = card.child(
                    div()
                        .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                        .text_color(tokens.secondary_text)
                        .child(repository.clone()),
                );
            }
            card = card.child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(if session.push {
                        tr("Commit and push the listed repositories.")
                    } else {
                        tr("Commit the listed repositories.")
                    }),
            );
            card = card.child(
                h_flex()
                    .w_full()
                    .justify_end()
                    .gap(px(8.0))
                    .child(
                        Button::new("lithe-git:session-review-close")
                            .ghost()
                            .small()
                            .label(tr("Close"))
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.dismiss_commit_review(cx);
                            })),
                    )
                    .child(
                        Button::new("lithe-git:session-review-confirm")
                            .primary()
                            .small()
                            .label(tr("Commit"))
                            .disabled(session.busy)
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.confirm_commit_review(cx);
                            })),
                    ),
            );
            return Some(backdrop(self, card, tokens, cx));
        }

        // 结果列表：每个仓库一行 committed / pushed / status / detail。
        for result in &session.results {
            let summary = if result.detail.is_empty() {
                if result.committed && (!session.push || result.pushed) {
                    tr("Done").to_string()
                } else {
                    result.status.clone()
                }
            } else {
                format!("{}: {}", result.status, result.detail)
            };
            card = card.child(
                h_flex()
                    .w_full()
                    .items_center()
                    .gap(px(6.0))
                    .child(
                        div()
                            .min_w(px(0.0))
                            .flex_1()
                            .truncate()
                            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                            .text_color(tokens.primary_text)
                            .child(result.repository_id.clone()),
                    )
                    .child(
                        div()
                            .flex_shrink_0()
                            .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                            .text_color(if result.committed && (!session.push || result.pushed) {
                                tokens.success
                            } else {
                                tokens.error
                            })
                            .child(summary),
                    ),
            );
        }
        if session.busy {
            card = card.child(
                h_flex()
                    .gap(px(6.0))
                    .items_center()
                    .child(
                        gpui_kit::component::spinner::Spinner::new().small(),
                    )
                    .child(
                        div()
                            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                            .text_color(tokens.secondary_text)
                            .child(if session.cancel_requested {
                                tr("Stopping…")
                            } else {
                                tr("Committing...")
                            }),
                    ),
            );
        }

        // 会话动作行：Stop（进行中）/ Retry（失败可重试）/ Dismiss（结束后）。
        let mut actions = h_flex().w_full().justify_end().gap(px(8.0));
        if !session.finished {
            actions = actions.child(
                Button::new("lithe-git:session-stop")
                    .danger()
                    .small()
                    .label(tr("Stop"))
                    .disabled(!session.busy || session.cancel_requested)
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.stop_commit_session(cx);
                    })),
            );
        } else {
            if session.can_retry && !session.succeeded {
                actions = actions.child(
                    Button::new("lithe-git:session-retry")
                        .primary()
                        .small()
                        .label(tr("Retry"))
                        .disabled(session.busy)
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.retry_commit_session(cx);
                        })),
                );
            }
            actions = actions.child(
                Button::new("lithe-git:session-dismiss")
                    .ghost()
                    .small()
                    .label(tr("Dismiss"))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.dismiss_commit_session(cx);
                    })),
            );
        }
        card = card.child(actions);

        Some(backdrop(self, card, tokens, cx))
    }
}

/// 会话卡的半透明背景层；点击背景不关闭会话（避免误触丢结果），
/// 只拦截冒泡。这里没有取消路径——Stop / Dismiss / Close 都在卡内。
fn backdrop(
    _panel: &GitPanel,
    card: gpui_kit::Stateful<gpui_kit::Div>,
    tokens: LitheTokens,
    cx: &mut Context<GitPanel>,
) -> AnyElement {
    div()
        .id("lithe-git-commit-session-backdrop")
        .absolute()
        .inset_0()
        .flex()
        .items_center()
        .justify_center()
        .bg(tokens.window.alpha(0.62))
        .on_click(cx.listener(|_, _, _, cx| cx.stop_propagation()))
        .child(card)
        .into_any_element()
}

/// 提交图例：N added / N modified / N deleted（对齐 Tauri buildCommitLegend：
/// untracked 计入 added、rename 计入 modified）。
fn render_commit_legend(counts: ChangeStatusCounts, tokens: LitheTokens) -> AnyElement {
    let mut legend = h_flex().flex_shrink_0().gap(px(6.0));
    for (count, color, label) in [
        (
            counts.added,
            tokens.success,
            format!("{} {}", counts.added, tr("added")),
        ),
        (
            counts.modified,
            tokens.warning,
            format!("{} {}", counts.modified, tr("modified")),
        ),
        (
            counts.deleted,
            tokens.error,
            format!("{} {}", counts.deleted, tr("deleted")),
        ),
    ] {
        if count == 0 {
            continue;
        }
        legend = legend.child(
            div()
                .flex_shrink_0()
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(color)
                .child(label),
        );
    }
    legend.into_any_element()
}
