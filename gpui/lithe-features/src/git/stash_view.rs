//! Stash 分段页：列表、搜索过滤、Apply / Pop / Drop 与 Stash 弹窗。
//!
//! 对齐 Tauri `git-view.tsx` 的 Stash 段 + `stash/git-stash-modal.tsx`：
//! - 列表来自 Core `git.stashes { root }`（Git 原生最新在前）；
//! - 行动作 Apply / Pop 走 `git.write stashApply/stashPop`，Drop 先确认；
//! - per-row loading 用 `stash_action_loading`（按 stash 的稳定 oid 记录）；
//! - Stash 弹窗提供 message + include-untracked，提交到
//!   `git.write stashPush { paths, includeUntracked, message }`。

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::checkbox::Checkbox;
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, AppContext as _, Context, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _, Window, div, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheMetrics, LitheTokens};

use super::model::{STASH_ROW_HEIGHT, command_failure_detail, parse_command, parse_stashes, root_text};
use super::{CoreStash, GitPanel, execute_git_command};

/// Stash 弹窗的作用域：全部未暂存（View Options 菜单）或右键所选文件。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum StashPushScope {
    AllUnstaged,
    Selected,
}

impl GitPanel {
    /// 切到 Stash 分段时触发列表加载；切回提交分段只清状态不加载。
    pub fn set_stash_visible(&mut self, visible: bool, cx: &mut Context<Self>) {
        if self.stash_visible == visible {
            return;
        }
        self.stash_visible = visible;
        if visible {
            self.load_stashes(cx);
        }
        cx.notify();
    }

    /// 加载 stash 列表（对齐 git-view.tsx 的 stash 段初始化）。
    pub(crate) fn load_stashes(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(root_text) = root_text(&root) else {
            return;
        };
        let generation = self.generation;
        let client = self.client;
        self.loading_stashes = true;
        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move {
                    execute_git_command(&client, "git.stashes", serde_json::json!({ "root": root_text }))
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.loading_stashes = false;
                match raw {
                    Ok(value) => {
                        this.stashes = parse_stashes(&value);
                    }
                    Err(error) => {
                        this.error = Some(SharedString::from(error.to_string()));
                    }
                }
                cx.notify();
            });
        })
        .detach();
        // Saved Changes 与 stash 列表同页加载，避免两个入口读到不同快照。
        self.load_shelves(cx);
        cx.notify();
    }

    /// 对某条 stash 执行动作；oid 用作 per-row loading 的稳定键。
    pub(crate) fn run_stash_action(
        &mut self,
        stash: CoreStash,
        action: StashAction,
        cx: &mut Context<Self>,
    ) {
        if self.pending_action.is_some() || self.committing {
            return;
        }
        if action == StashAction::Drop {
            // Drop 是破坏性动作：先确认（对齐 Tauri showConfirmDialog）。
            self.pending_stash_drop = Some(stash);
            cx.notify();
            return;
        }
        self.execute_stash_write(stash, action, cx);
    }

    fn execute_stash_write(&mut self, stash: CoreStash, action: StashAction, cx: &mut Context<Self>) {
        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(root_text) = root_text(&root) else {
            return;
        };
        let (operation, success, failure) = match action {
            StashAction::Apply => (
                "stashApply",
                tr("Stash applied"),
                tr("Stash action failed"),
            ),
            StashAction::Pop => ("stashPop", tr("Stash popped"), tr("Stash action failed")),
            StashAction::Drop => ("stashDrop", tr("Stash dropped"), tr("Stash action failed")),
        };
        // Core 的 stash 写入优先接受不可变对象 id（stash 位置会随新的 push
        // 变化）；没有 oid 时回退到 `stash@{n}` 位置引用。
        let reference = if stash.oid.is_empty() {
            stash.reference.clone()
        } else {
            stash.oid.clone()
        };
        let oid = stash.oid.clone();
        let generation = self.generation;
        let client = self.client;
        self.stash_action_loading.insert(oid.clone());
        self.error = None;
        self.notice = None;
        cx.notify();

        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move {
                    execute_git_command(&client, 
                        "git.write",
                        serde_json::json!({
                            "root": root_text,
                            "operation": operation,
                            "reference": reference,
                        }),
                    )
                })
                .await;

            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.stash_action_loading.remove(&oid);
                match raw {
                    Ok(value) => match parse_command(&value) {
                        Ok(command) if command.exit_code == 0 => {
                            this.reload_all(cx);
                            this.load_stashes(cx);
                            this.notice = Some(SharedString::from(success));
                        }
                        Ok(command) => {
                            this.error = Some(SharedString::from(command_failure_detail(
                                &command, failure,
                            )));
                        }
                        Err(message) => {
                            this.error = Some(SharedString::from(message));
                        }
                    },
                    Err(error) => {
                        this.error = Some(SharedString::from(error.to_string()));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(crate) fn cancel_stash_drop(&mut self, cx: &mut Context<Self>) {
        if self.pending_stash_drop.take().is_some() {
            cx.notify();
        }
    }

    pub(crate) fn confirm_stash_drop(&mut self, cx: &mut Context<Self>) {
        let Some(stash) = self.pending_stash_drop.take() else {
            return;
        };
        self.execute_stash_write(stash, StashAction::Drop, cx);
    }

    /// 打开 Stash 弹窗（View Options「Stash All Unstaged」/ 右键「Stash 所选」）。
    pub(crate) fn request_stash_push(
        &mut self,
        scope: StashPushScope,
        paths: Vec<String>,
        cx: &mut Context<Self>,
    ) {
        if self.pending_action.is_some() || self.committing {
            return;
        }
        self.pending_stash_push = Some((scope, paths));
        self.stash_message_input = None;
        self.stash_include_untracked = false;
        cx.notify();
    }

    pub(crate) fn cancel_stash_push(&mut self, cx: &mut Context<Self>) {
        if self.pending_stash_push.take().is_some() {
            self.stash_message_input = None;
            cx.notify();
        }
    }

    /// 确认 Stash：message 为空时用默认文案（对齐 Tauri stashMessageDefault*）。
    pub(crate) fn confirm_stash_push(&mut self, cx: &mut Context<Self>) {
        let Some((scope, paths)) = self.pending_stash_push.take() else {
            return;
        };
        self.stash_message_input = None;
        let paths = match scope {
            // 全部未暂存：收集所有处于工作区维度且未暂存的路径。
            StashPushScope::AllUnstaged => self
                .status
                .as_ref()
                .map(|status| {
                    status
                        .changes
                        .iter()
                        .filter(|change| change.worktree && !change.staged)
                        .map(|change| change.path.clone())
                        .collect()
                })
                .unwrap_or_default(),
            StashPushScope::Selected => paths,
        };
        if paths.is_empty() {
            return;
        }
        let message = self
            .stash_message_text
            .take()
            .filter(|value| !value.trim().is_empty());

        let Some(root) = self.root.clone() else {
            return;
        };
        let Some(root_text) = root_text(&root) else {
            return;
        };
        let include_untracked = self.stash_include_untracked;
        let generation = self.generation;
        let client = self.client;
        self.stash_busy = true;
        cx.notify();

        cx.spawn(async move |this, cx| {
            let raw = cx
                .background_spawn(async move {
                    execute_git_command(&client, 
                        "git.write",
                        serde_json::json!({
                            "root": root_text,
                            "operation": "stashPush",
                            "paths": paths,
                            "includeUntracked": include_untracked,
                            "message": message.unwrap_or_default(),
                        }),
                    )
                })
                .await;

            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.stash_busy = false;
                match raw {
                    Ok(value) => match parse_command(&value) {
                        Ok(command) if command.exit_code == 0 => {
                            this.reload_all(cx);
                            this.load_stashes(cx);
                            this.notice = Some(SharedString::from(tr("Changes stashed")));
                        }
                        Ok(command) => {
                            this.error = Some(SharedString::from(command_failure_detail(
                                &command,
                                tr("Stash failed"),
                            )));
                        }
                        Err(message) => {
                            this.error = Some(SharedString::from(message));
                        }
                    },
                    Err(error) => {
                        this.error = Some(SharedString::from(error.to_string()));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// 惰性创建 stash message 输入框（需要 Window，只能在 render 期调用）。
    pub(crate) fn ensure_stash_message_input(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.pending_stash_push.is_none() || self.stash_message_input.is_some() {
            return;
        }
        let input = cx.new(|cx| {
            InputState::new(window, cx).placeholder(tr("Stash message"))
        });
        cx.subscribe_in(
            &input,
            window,
            |this, input, event: &InputEvent, _window, cx| {
                if matches!(event, InputEvent::Change) {
                    // 文本真源在输入框实体；弹窗确认时再读取。
                    this.stash_message_text = Some(input.read(cx).value().to_string());
                }
            },
        )
        .detach();
        self.stash_message_input = Some(input);
        cx.notify();
    }

    // -----------------------------------------------------------------------
    // 渲染
    // -----------------------------------------------------------------------

    /// Stash 分段页主体：搜索框 + 列表 + 行动作。
    pub(crate) fn render_stash_view(
        &mut self,
        window: &mut Window,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        // 惰性创建搜索框。
        if self.stash_filter_input.is_none() {
            let input =
                cx.new(|cx| InputState::new(window, cx).placeholder(tr("Search stashes")));
            cx.subscribe_in(
                &input,
                window,
                |_this, _input, event: &InputEvent, _window, cx| {
                    if matches!(event, InputEvent::Change) {
                        // 过滤关键字由输入框持有；同步到状态用于计数。
                        cx.notify();
                    }
                },
            )
            .detach();
            self.stash_filter_input = Some(input);
        }
        if let Some(input) = self.stash_filter_input.as_ref() {
            self.stash_filter = input.read(cx).value().trim().to_lowercase();
        }
        let filter = self.stash_filter.clone();
        let visible: Vec<&CoreStash> = self
            .stashes
            .iter()
            .filter(|stash| {
                filter.is_empty() || stash.message.to_lowercase().contains(&filter)
            })
            .collect();

        let mut list = v_flex()
            .id("lithe-git-stash-list")
            .size_full()
            .min_h_0()
            .min_w_0()
            .bg(tokens.sidebar)
            .overflow_y_scroll();

        if self.stashes.is_empty() {
            list = list.child(
                div()
                    .flex_1()
                    .flex()
                    .items_center()
                    .justify_center()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(if self.loading_stashes {
                        tr("Loading…")
                    } else {
                        tr("No stashes")
                    }),
            );
        } else if visible.is_empty() {
            list = list.child(
                div()
                    .flex_1()
                    .flex()
                    .items_center()
                    .justify_center()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(tr("No matching stashes")),
            );
        } else {
            // 过滤结果在下方计数里还要读，按引用迭代避免 move。
            for stash in &visible {
                list = list.child(self.render_stash_row(stash, tokens, cx));
            }
        }

        let toolbar = h_flex()
            .w_full()
            .flex_shrink_0()
            .h(px(40.0))
            .items_center()
            .gap(px(8.0))
            .px(px(8.0))
            .bg(tokens.sidebar)
            .border_b_1()
            .border_color(tokens.divider)
            .child(
                div()
                    .w(px(220.0))
                    .child(
                        self.stash_filter_input
                            .clone()
                            .map(|input| Input::new(&input).small().into_any_element())
                            .unwrap_or_else(|| div().into_any_element()),
                    ),
            )
            .child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.tertiary_text)
                    .child(format!("{}/{}", visible.len(), self.stashes.len())),
            );

        v_flex()
            .id("lithe-git-stash-view")
            .size_full()
            .min_h_0()
            .bg(tokens.sidebar)
            .child(toolbar)
            .child(list)
            // Saved Changes（本地 shelf）：与 stash 列表同页，语义对齐 Tauri
            // `git-saved-changes.tsx` 的「保存的更改」区。
            .child(self.render_shelves_section(tokens, cx))
            .into_any_element()
    }

    /// 单条 stash 行：`stash@{n}` + message + Apply / Pop / Drop。
    fn render_stash_row(
        &self,
        stash: &CoreStash,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let busy = self.pending_action.is_some()
            || self.committing
            || self.stash_busy
            // shelf 的导出 / 应用同样改写工作区，与 stash 动作互斥。
            || self.shelf_busy
            || !self.stash_action_loading.is_empty();
        let loading = self.stash_action_loading.contains(&stash.oid);
        let index_label = stash.reference.clone();
        let message = if stash.message.is_empty() {
            tr("(No message)").to_string()
        } else {
            stash.message.clone()
        };
        let meta = stash.date.clone();

        h_flex()
            .id(SharedString::from(format!(
                "lithe-git:stash:{}",
                stash.oid
            )))
            .w_full()
            .flex_shrink_0()
            .h(px(STASH_ROW_HEIGHT))
            .px(px(10.0))
            .items_center()
            .gap(px(8.0))
            .hover(|style| style.bg(tokens.hover))
            .child(
                Icon::new(gpui_kit::assets::IconName::Archive)
                    .with_size(px(14.0))
                    .text_color(tokens.secondary_text),
            )
            .child(
                div()
                    .flex_shrink_0()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .font_family(lithe_ui::MONO_FONT_FAMILY)
                    .text_color(tokens.link)
                    .child(index_label),
            )
            .child(
                v_flex()
                    .min_w(px(0.0))
                    .flex_1()
                    .gap(px(1.0))
                    .child(
                        div()
                            .min_w(px(0.0))
                            .truncate()
                            .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                            .text_color(tokens.primary_text)
                            .child(message),
                    )
                    .when(!meta.is_empty(), |this| {
                        this.child(
                            div()
                                .min_w(px(0.0))
                                .truncate()
                                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                                .text_color(tokens.tertiary_text)
                                .child(meta),
                        )
                    }),
            )
            .child(
                Button::new(SharedString::from(format!(
                    "lithe-git:stash-apply:{}",
                    stash.oid
                )))
                .ghost()
                .xsmall()
                .label(if loading { tr("Applying…") } else { tr("Apply") })
                .disabled(busy && !loading)
                .on_click(cx.listener({
                    let stash = stash.clone();
                    move |this, _, _, cx| this.run_stash_action(stash.clone(), StashAction::Apply, cx)
                })),
            )
            .child(
                Button::new(SharedString::from(format!(
                    "lithe-git:stash-pop:{}",
                    stash.oid
                )))
                .ghost()
                .xsmall()
                .label(tr("Pop"))
                .disabled(busy && !loading)
                .on_click(cx.listener({
                    let stash = stash.clone();
                    move |this, _, _, cx| this.run_stash_action(stash.clone(), StashAction::Pop, cx)
                })),
            )
            .child(
                Button::new(SharedString::from(format!(
                    "lithe-git:stash-drop:{}",
                    stash.oid
                )))
                .ghost()
                .xsmall()
                .label(tr("Drop"))
                .disabled(busy && !loading)
                .on_click(cx.listener({
                    let stash = stash.clone();
                    move |this, _, _, cx| this.run_stash_action(stash.clone(), StashAction::Drop, cx)
                })),
            )
            .into_any_element()
    }

    /// Drop 确认覆盖层。
    pub(crate) fn render_stash_drop_confirm(
        &self,
        stash: &CoreStash,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let message = if stash.message.is_empty() {
            stash.reference.clone()
        } else {
            stash.message.clone()
        };
        div()
            .id("lithe-git-stash-drop-backdrop")
            .absolute()
            .inset_0()
            .flex()
            .items_center()
            .justify_center()
            .bg(tokens.window.alpha(0.62))
            .on_click(cx.listener(|this, _, _, cx| this.cancel_stash_drop(cx)))
            .child(
                v_flex()
                    .id("lithe-git-stash-drop-dialog")
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
                            .child(tr("Drop stash?")),
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
                                Button::new("lithe-git-stash-drop-cancel")
                                    .ghost()
                                    .small()
                                    .label(tr("Cancel"))
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.cancel_stash_drop(cx);
                                    })),
                            )
                            .child(
                                Button::new("lithe-git-stash-drop-confirm")
                                    .danger()
                                    .small()
                                    .label(tr("Drop"))
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.confirm_stash_drop(cx);
                                    })),
                            ),
                    ),
            )
            .into_any_element()
    }

    /// Stash 弹窗（message + include-untracked + 确认 / 取消）。
    pub(crate) fn render_stash_push_overlay(
        &mut self,
        window: &mut Window,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        // 先克隆出作用域与路径：后面 `ensure_stash_message_input` 需要可变
        // 借用 self，不能同时持有 `pending_stash_push` 的引用。
        let (scope, paths) = self.pending_stash_push.clone()?;
        self.ensure_stash_message_input(window, cx);
        // 「全部未暂存」的作用域在确认时才展开为路径，弹窗计数需要从当前
        // status 现算，否则会显示 0。
        let count = match scope {
            super::stash_view::StashPushScope::AllUnstaged => self
                .status
                .as_ref()
                .map(|status| {
                    status
                        .changes
                        .iter()
                        .filter(|change| change.worktree && !change.staged)
                        .count()
                })
                .unwrap_or(0),
            super::stash_view::StashPushScope::Selected => paths.len(),
        };
        let mut dialog = v_flex()
            .id("lithe-git-stash-push")
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
                    .child(tr("Stash changes")),
            )
            .child(
                div()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(tr("{count} files").replace("{count}", &count.to_string())),
            );
        if let Some(input) = self.stash_message_input.as_ref() {
            dialog = dialog.child(Input::new(input).small().w_full());
        }
        dialog = dialog.child(
            h_flex()
                .items_center()
                .gap(px(6.0))
                .child(
                    Checkbox::new("lithe-git:stash-include-untracked")
                        .small()
                        .checked(self.stash_include_untracked)
                        .on_change(cx.listener(|this, checked: &bool, _window, cx| {
                            this.stash_include_untracked = *checked;
                            cx.notify();
                        })),
                )
                .child(
                    div()
                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                        .text_color(tokens.secondary_text)
                        .child(tr("Include untracked files")),
                ),
        );
        dialog = dialog.child(
            h_flex()
                .w_full()
                .justify_end()
                .gap(px(8.0))
                .child(
                    Button::new("lithe-git-stash-push-cancel")
                        .ghost()
                        .small()
                        .label(tr("Cancel"))
                        .disabled(self.stash_busy)
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.cancel_stash_push(cx);
                        })),
                )
                .child(
                    Button::new("lithe-git-stash-push-confirm")
                        .primary()
                        .small()
                        .label(tr("Stash"))
                        .disabled(self.stash_busy)
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.confirm_stash_push(cx);
                        })),
                ),
        );

        Some(
            div()
                .id("lithe-git-stash-push-backdrop")
                .absolute()
                .inset_0()
                .flex()
                .items_center()
                .justify_center()
                .bg(tokens.window.alpha(0.62))
                .on_click(cx.listener(|this, _, _, cx| this.cancel_stash_push(cx)))
                .child(dialog)
                .into_any_element(),
        )
    }
}

/// stash 行动作。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum StashAction {
    Apply,
    Pop,
    Drop,
}
